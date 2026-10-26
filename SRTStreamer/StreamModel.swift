import AVFoundation
import Combine
import HaishinKit
import SRTHaishinKit
import SwiftUI
import UIKit
import VideoToolbox

enum ResolutionOption: String, CaseIterable, Identifiable {
    case p720 = "720p"
    case p1080 = "1080p"
    var id: String { rawValue }
    /// 竖屏尺寸
    var size: CGSize { self == .p720 ? CGSize(width: 720, height: 1280) : CGSize(width: 1080, height: 1920) }
    var preset: AVCaptureSession.Preset { self == .p720 ? .hd1280x720 : .hd1920x1080 }
}

enum ProfileOption: String, CaseIterable, Identifiable {
    case baseline = "Baseline"
    case main = "Main"
    var id: String { rawValue }
    var profileLevel: String {
        self == .baseline ? (kVTProfileLevel_H264_Baseline_AutoLevel as String) : (kVTProfileLevel_H264_Main_AutoLevel as String)
    }
}

@MainActor
final class StreamModel: ObservableObject {
    static let defaultURL = "srt://8.148.79.198:8890?streamid=publish:live:push:密钥"

    @AppStorage("srtURL") var urlText: String = StreamModel.defaultURL
    @AppStorage("latency") var latencyText: String = "200"
    @Published var resolution: ResolutionOption = .p720
    @Published var bitrateMbps: Int = 4
    @Published var profile: ProfileOption = .baseline

    @Published var isStreaming = false
    @Published var isBusy = false
    @Published var status = "未连接"
    @Published var cameraError: String?
    @Published var videoFrames = 0
    @Published var sendMbps: Double = 0
    @Published var sentKB: UInt64 = 0

    let previewView = MTHKView(frame: .zero)
    private let mixer = MediaMixer(multiCamSessionEnabled: false, multiTrackAudioMixingEnabled: false, useManualCapture: true)
    private var connection: SRTConnection?
    private var stream: SRTStream?
    private let counter = FrameCounter()
    private var position: AVCaptureDevice.Position = .back
    private var statsTimer: Timer?
    private var started = false

    // MARK: - 采集

    func setup() async {
        guard !started else { return }
        started = true
        let videoOK = await AVCaptureDevice.requestAccess(for: .video)
        let audioOK = await AVCaptureDevice.requestAccess(for: .audio)
        if !videoOK { cameraError = "没有摄像头权限，请在 设置 > SRT推流 中开启" }
        if !audioOK { status = "没有麦克风权限（仅视频）" }

        await mixer.setSessionPreset(resolution.preset)
        await mixer.setVideoOrientation(.portrait)
        await mixer.setFrameRate(30)
        await attachCamera()
        if audioOK {
            do { try await mixer.attachAudio(AVCaptureDevice.default(for: .audio)) }
            catch { status = "麦克风连接失败: \(error.localizedDescription)" }
        }
        await mixer.addOutput(previewView) // 预览始终直接来自 mixer
        await mixer.startRunning()
    }

    private func attachCamera() async {
        let pos = position
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) else {
            cameraError = "找不到摄像头设备"
            return
        }
        do {
            try await mixer.attachVideo(device, track: 0) { unit in
                unit.isVideoMirrored = (pos == .front)
            }
            cameraError = nil
        } catch {
            cameraError = "摄像头连接失败: \(error.localizedDescription)"
        }
    }

    func flipCamera() {
        position = (position == .back) ? .front : .back
        Task { await attachCamera() }
    }

    func applyResolution() {
        guard !isStreaming else { return }
        Task { await mixer.setSessionPreset(resolution.preset) }
    }

    // MARK: - URL 处理

    /// 去除空白、前导的 ':' 等杂字符，并追加 latency / mode=caller
    func normalizedURL() -> URL? {
        var s = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\u{200B}", with: "")
        if let r = s.range(of: "srt://", options: .caseInsensitive) {
            s = "srt://" + s[r.upperBound...]
        } else {
            while let f = s.first, !f.isLetter { s.removeFirst() }
        }
        s = s.replacingOccurrences(of: " ", with: "")
        guard s.lowercased().hasPrefix("srt://") else { return nil }
        let latency = Int(latencyText.trimmingCharacters(in: .whitespaces)) ?? 200
        if !s.contains("latency=") { s += (s.contains("?") ? "&" : "?") + "latency=\(latency)" }
        if !s.contains("mode=") { s += "&mode=caller" }
        if let u = URL(string: s) { return u }
        // 非 ASCII 字符（如中文密钥）需要编码
        if let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "/:?&="))) {
            return URL(string: enc)
        }
        return nil
    }

    // MARK: - 推流

    func toggle() {
        if isStreaming { Task { await stop() } } else { Task { await start() } }
    }

    private func start() async {
        guard !isBusy else { return }
        guard let url = normalizedURL() else { status = "SRT 地址格式错误"; return }
        if urlText.contains("密钥") { status = "请把地址里的“密钥”替换成你的推流密钥"; return }
        isBusy = true
        defer { isBusy = false }

        let connection = SRTConnection()
        let stream = SRTStream(connection: connection)
        self.connection = connection
        self.stream = stream
        counter.reset()

        // 1. 编码参数必须在 publish 前设置
        var v = VideoCodecSettings(
            videoSize: resolution.size,
            bitRate: bitrateMbps * 1_000_000,
            profileLevel: profile.profileLevel,
            scalingMode: .trim,
            bitRateMode: .average,
            maxKeyFrameIntervalDuration: 1,
            allowFrameReordering: false
        )
        v.frameInterval = 0
        await stream.setVideoSettings(v)
        var a = await stream.audioSettings
        a.bitRate = 128 * 1000
        await stream.setAudioSettings(a)

        // 2. 挂接输出（预览 + 帧计数），并把 stream 作为 mixer 的输出
        await stream.addOutput(counter)
        await mixer.addOutput(stream)
        if !(await mixer.isRunning) { await mixer.startRunning() }

        // 3. 关键：SRTStream.publish() 只有在已收到视频帧(videoInputFormat != nil)时
        //    才会让 TSWriter 期待视频轨，否则只发音频。所以先等摄像头帧到达 stream。
        status = "等待摄像头画面…"
        var waited = 0
        while counter.videoFrames == 0 && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        if counter.videoFrames == 0 {
            status = "未收到摄像头画面，无法推送视频"
            cameraError = cameraError ?? "摄像头没有输出画面"
            await teardown()
            return
        }

        // 4. 连接 + 推流
        status = "正在连接…"
        do {
            try await connection.connect(url)
        } catch {
            status = "连接失败: \(error)"
            await teardown()
            return
        }
        await stream.publish()
        isStreaming = true
        UIApplication.shared.isIdleTimerDisabled = true
        status = "推流中"
        startStats()
    }

    private func stop() async {
        await teardown()
        status = "已停止"
    }

    private func teardown() async {
        statsTimer?.invalidate()
        statsTimer = nil
        if let stream {
            await stream.close()
            await mixer.removeOutput(stream)
            await stream.removeOutput(counter)
        }
        await connection?.close()
        stream = nil
        connection = nil
        isStreaming = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func startStats() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.updateStats() }
        }
    }

    private func updateStats() async {
        videoFrames = counter.videoFrames
        guard let connection else { return }
        if let p = await connection.performanceData {
            sendMbps = p.mbpsSendRate
            sentKB = p.byteSentTotal / 1024
        }
        if !(await connection.connected) && isStreaming {
            status = "连接已断开"
            await teardown()
        }
    }
}
