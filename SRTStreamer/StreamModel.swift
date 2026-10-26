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
    case k2 = "2K"
    var id: String { rawValue }
    /// 竖屏尺寸
    var size: CGSize {
        switch self {
        case .p720: return CGSize(width: 720, height: 1280)
        case .p1080: return CGSize(width: 1080, height: 1920)
        case .k2: return CGSize(width: 1440, height: 2560)
        }
    }
    var label: String {
        switch self {
        case .p720: return "720p (1280×720)"
        case .p1080: return "1080p (1920×1080)"
        case .k2: return "2K (2560×1440)"
        }
    }
    var preset: AVCaptureSession.Preset {
        switch self {
        case .p720: return .hd1280x720
        case .p1080: return .hd1920x1080
        case .k2: return .hd4K3840x2160 // 4K 采集再缩放到 2560×1440
        }
    }
    var captureDims: (Int32, Int32) {
        switch self {
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        case .k2: return (3840, 2160)
        }
    }
    var defaultKbps: Int {
        switch self {
        case .p720: return 4000
        case .p1080: return 6000
        case .k2: return 10000
        }
    }
}

enum AspectOption: String, CaseIterable, Identifiable {
    case auto = "自动"
    case landscape = "16:9"
    case portrait = "9:16"
    var id: String { rawValue }
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
    @Published var resolution: ResolutionOption = ResolutionOption(rawValue: UserDefaults.standard.string(forKey: "resolution") ?? "") ?? .p720 {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "resolution") }
    }
    @Published var bitrateKbps: Int = (UserDefaults.standard.object(forKey: "bitrateKbps") as? Int) ?? 6000 {
        didSet { UserDefaults.standard.set(bitrateKbps, forKey: "bitrateKbps") }
    }
    @Published var aspect: AspectOption = AspectOption(rawValue: UserDefaults.standard.string(forKey: "aspect") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(aspect.rawValue, forKey: "aspect"); applyOrientation() }
    }
    @Published var multiCam: Bool = (UserDefaults.standard.object(forKey: "multiCam") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(multiCam, forKey: "multiCam"); zoom = 1; Task { await attachCamera() } }
    }
    /// 实际生效帧率（设备不支持 60fps 时保持 30）
    @Published var effectiveFps: Int = 30
    @Published var deviceLandscape = false
    private var orientationObserver: NSObjectProtocol?
    @Published var profile: ProfileOption = ProfileOption(rawValue: UserDefaults.standard.string(forKey: "profile") ?? "") ?? .baseline {
        didSet { UserDefaults.standard.set(profile.rawValue, forKey: "profile") }
    }
    @Published var fps: Int = ((UserDefaults.standard.object(forKey: "fps") as? Int) == 60) ? 60 : 30 {
        didSet { UserDefaults.standard.set(fps, forKey: "fps") }
    }
    /// 用户视角的变焦倍数（0.5 = 超广角）
    @Published var zoom: CGFloat = 1
    @Published var hasUltraWide = false
    private var currentDevice: AVCaptureDevice?
    private var zoomScale: CGFloat = 1 // 用户倍数 → videoZoomFactor 的系数

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
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateDeviceOrientation()
        orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateDeviceOrientation()
                self?.applyOrientation()
            }
        }
        await mixer.setVideoOrientation(captureOrientation)
        await attachCamera()
        if audioOK {
            do { try await mixer.attachAudio(AVCaptureDevice.default(for: .audio)) }
            catch { status = "麦克风连接失败: \(error.localizedDescription)" }
        }
        await mixer.addOutput(previewView) // 预览始终直接来自 mixer
        await mixer.startRunning()
    }

    // MARK: - 方向

    private func updateDeviceOrientation() {
        let o = UIDevice.current.orientation
        if o.isLandscape { deviceLandscape = true } else if o == .portrait || o == .portraitUpsideDown { deviceLandscape = false }
    }

    var isLandscapeOutput: Bool {
        switch aspect {
        case .auto: return deviceLandscape
        case .landscape: return true
        case .portrait: return false
        }
    }

    var captureOrientation: AVCaptureVideoOrientation {
        guard isLandscapeOutput else { return .portrait }
        if aspect == .auto && UIDevice.current.orientation == .landscapeRight { return .landscapeLeft }
        return .landscapeRight
    }

    var outputSize: CGSize {
        let s = resolution.size
        return isLandscapeOutput ? CGSize(width: s.height, height: s.width) : s
    }

    func applyOrientation() {
        guard started, !isStreaming else { return }
        let o = captureOrientation
        Task { await mixer.setVideoOrientation(o) }
    }

    // MARK: - 摄像头

    private func pickDevice(_ pos: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if multiCam && pos == .back {
            if let d = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) { return d }
            if let d = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) { return d }
            if let d = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) { return d }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos)
    }

    private func attachCamera() async {
        let pos = position
        let dev = pickDevice(pos)
        currentDevice = dev
        if let dev, dev.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }) {
            hasUltraWide = true
            zoomScale = 2 // 虚拟设备 1.0 = 超广角，2.0 = 广角(1x)
        } else {
            hasUltraWide = false
            zoomScale = 1
        }
        if !hasUltraWide && zoom < 1 { zoom = 1 }
        guard let device = dev else {
            cameraError = "找不到摄像头设备"
            return
        }
        do {
            try await mixer.attachVideo(device, track: 0) { unit in
                unit.isVideoMirrored = (pos == .front)
            }
            cameraError = nil
            applyZoomFactor()
            await applyFrameRateNow()
        } catch {
            cameraError = "摄像头连接失败: \(error.localizedDescription)"
        }
    }

    func flipCamera() {
        position = (position == .back) ? .front : .back
        zoom = 1
        Task { await attachCamera() }
    }

    var minZoom: CGFloat { hasUltraWide ? 0.5 : 1 }

    func setZoom(_ z: CGFloat) {
        zoom = min(max(z, minZoom), 10)
        applyZoomFactor()
    }

    private func applyZoomFactor() {
        guard let d = currentDevice else { return }
        let factor = zoom * zoomScale
        let f = min(max(factor, d.minAvailableVideoZoomFactor), min(d.activeFormat.videoMaxZoomFactor, 20))
        do {
            try d.lockForConfiguration()
            d.videoZoomFactor = f
            d.unlockForConfiguration()
        } catch {}
    }

    /// 设备是否支持当前分辨率下的 60fps
    private func supports60() -> Bool {
        guard let d = currentDevice else { return false }
        let (w, h) = resolution.captureDims
        return d.formats.contains { f in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return dim.width == w && dim.height == h && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
        }
    }

    private func applyFrameRateNow() async {
        let target = (fps == 60 && supports60()) ? 60 : 30
        effectiveFps = target
        await mixer.setFrameRate(Float64(target))
    }

    func applyFrameRate() {
        guard !isStreaming else { return }
        Task { await applyFrameRateNow() }
    }

    func resetBitrate() { bitrateKbps = resolution.defaultKbps }

    func applyResolution() {
        guard !isStreaming else { return }
        bitrateKbps = resolution.defaultKbps
        Task {
            await mixer.setSessionPreset(resolution.preset)
            await applyFrameRateNow()
        }
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
        if latency > 0 && !s.contains("latency=") { s += (s.contains("?") ? "&" : "?") + "latency=\(latency)" }
        if !s.contains("mode=") { s += (s.contains("?") ? "&" : "?") + "mode=caller" }
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

        await mixer.setVideoOrientation(captureOrientation)
        // 1. 编码参数必须在 publish 前设置
        var v = VideoCodecSettings(
            videoSize: outputSize,
            bitRate: bitrateKbps * 1000,
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
