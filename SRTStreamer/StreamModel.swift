import AVFoundation
import Combine
import CoreMotion
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

enum RotationMode: String, CaseIterable, Identifiable {
    case auto = "自动（陀螺仪）"
    case portrait = "手动锁定竖屏"
    case landscape = "手动锁定横屏"
    var id: String { rawValue }
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

    // 断流自动重连
    @Published var autoReconnect: Bool = (UserDefaults.standard.object(forKey: "autoReconnect") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }
    @Published var autoStartOnLaunch: Bool = (UserDefaults.standard.object(forKey: "autoStartOnLaunch") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(autoStartOnLaunch, forKey: "autoStartOnLaunch") }
    }
    @Published var autoLockAfterStart: Bool = (UserDefaults.standard.object(forKey: "autoLockAfterStart") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(autoLockAfterStart, forKey: "autoLockAfterStart") }
    }
    @Published var isLocked = false
    @Published var audioLevel: Float = 0
    private var meterTimer: Timer?
    /// 声音采集（false = 静音，推流不断）
    @Published var micEnabled: Bool = (UserDefaults.standard.object(forKey: "micEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(micEnabled, forKey: "micEnabled")
            Task { await applyMicMute() }
        }
    }
    @Published var reconnectAttempt = 0
    @Published var isReconnecting = false
    private var wantStreaming = false
    private var reconnectTask: Task<Void, Never>?
    private var lastSentKB: UInt64 = 0
    private var stallSeconds = 0

    // 陀螺仪方向
    @Published var rotationMode: RotationMode = RotationMode(rawValue: UserDefaults.standard.string(forKey: "rotationMode") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(rotationMode.rawValue, forKey: "rotationMode"); syncOrientation() }
    }
    /// 物理方向（陀螺仪），用于 UI 旋转
    @Published var physicalOrientation: UIDeviceOrientation = .portrait
    private var orientationForCapture: UIDeviceOrientation = .portrait
    private let motion = CMMotionManager()

    /// UI 控件旋转角度
    var uiAngle: Double {
        let o: UIDeviceOrientation
        switch rotationMode {
        case .auto: o = physicalOrientation
        case .portrait: o = .portrait
        case .landscape: o = .landscapeLeft
        }
        switch o {
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        default: return 0
        }
    }
    var orientationLockedHint: Bool {
        isStreaming && rotationMode == .auto && aspect == .auto && physicalOrientation.isLandscape != deviceLandscape
    }

    let camera = CameraControl()

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
        startMotion()
        await mixer.setVideoOrientation(captureOrientation)
        await attachCamera()
        if audioOK {
            do { try await mixer.attachAudio(AVCaptureDevice.default(for: .audio)) }
            catch { status = "麦克风连接失败: \(error.localizedDescription)" }
            await applyMicMute()
        }
        await mixer.addOutput(previewView) // 预览始终直接来自 mixer
        await mixer.startRunning()
        if autoStartOnLaunch {
            await maybeAutoStart(thenLock: autoLockAfterStart)
        }
    }

    /// URL 可用（非空、可解析、不含占位「密钥」）
    var canAutoStart: Bool {
        guard let u = normalizedURL() else { return false }
        if urlText.contains("密钥") { return false }
        _ = u
        return true
    }

    private func maybeAutoStart(thenLock: Bool) async {
        guard canAutoStart, !isStreaming, !isBusy else { return }
        wantStreaming = true
        await start()
        if isStreaming || isReconnecting {
            if thenLock { isLocked = true }
        } else if thenLock {
            // 启动失败不锁屏
        }
    }

    /// 一键锁屏推流：立即锁屏并开始推流；失败则解锁并保留错误状态
    func oneTapLockStream() {
        Task { @MainActor in
            isLocked = true
            if isStreaming || isReconnecting { return }
            if !canAutoStart {
                if urlText.contains("密钥") { status = "请把地址里的“密钥”替换成你的推流密钥" }
                else { status = "SRT 地址格式错误" }
                isLocked = false
                return
            }
            wantStreaming = true
            await start()
            if !isStreaming {
                isLocked = false
                // status 已由 start() 写入
            }
        }
    }

    // MARK: - 方向

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.2
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            var o: UIDeviceOrientation?
            if g.x < -0.7 { o = .landscapeLeft }
            else if g.x > 0.7 { o = .landscapeRight }
            else if g.y < -0.7 { o = .portrait }
            else if g.y > 0.7 { o = .portraitUpsideDown }
            if let o, o != self.physicalOrientation {
                self.physicalOrientation = o
                self.syncOrientation()
            }
        }
    }

    /// 非推流时同步采集方向（推流中锁定，避免编码分辨率变化）
    func syncOrientation() {
        guard !isStreaming, !isBusy else { return }
        switch rotationMode {
        case .auto:
            let o = physicalOrientation
            if o.isLandscape { deviceLandscape = true; orientationForCapture = o }
            else { deviceLandscape = false; orientationForCapture = .portrait }
        case .portrait: deviceLandscape = false; orientationForCapture = .portrait
        case .landscape: deviceLandscape = true; orientationForCapture = .landscapeLeft
        }
        applyOrientation()
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
        if aspect == .auto && orientationForCapture == .landscapeRight { return .landscapeLeft }
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
        camera.device = dev
        camera.position = pos
        if let dev {
            // displayVideoZoomFactorMultiplier：虚拟设备上 1x 显示对应的 videoZoomFactor
            let mult = max(dev.displayVideoZoomFactorMultiplier, 1)
            let ultra = !dev.constituentDevices.isEmpty &&
                (dev.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera } ||
                 (dev.deviceType == .builtInDualWideCamera || dev.deviceType == .builtInTripleCamera ||
                  (dev.minAvailableVideoZoomFactor < mult * 0.6)))
            hasUltraWide = ultra && pos == .back
            zoomScale = hasUltraWide ? mult : 1
        } else {
            hasUltraWide = false
            zoomScale = 1
        }
        if !hasUltraWide && zoom < 1 { zoom = 1 }
        guard let device = dev else {
            cameraError = "找不到摄像头设备"
            return
        }
        let stab = camera.stabilization.mode
        do {
            try await mixer.attachVideo(device, track: 0) { unit in
                unit.isVideoMirrored = (pos == .front)
                unit.preferredVideoStabilizationMode = stab
            }
            cameraError = nil
            applyZoomFactor()
            await applyFrameRateNow()
            camera.reapply()
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
    var positionIsFront: Bool { position == .front }

    /// 尝试设置变焦。不支持的 0.5x 返回 false（调用方弹 toast）
    @discardableResult
    func setZoom(_ z: CGFloat) -> Bool {
        if z < 1 && !hasUltraWide { return false }
        zoom = min(max(z, minZoom), 10)
        applyZoomFactor()
        return true
    }

    private func applyZoomFactor() {
        guard let d = currentDevice else { return }
        // 用户 1x → videoZoomFactor = displayVideoZoomFactorMultiplier（虚拟设备）
        let factor = zoom * zoomScale
        let f = min(max(factor, d.minAvailableVideoZoomFactor), min(d.activeFormat.videoMaxZoomFactor, 20))
        do {
            try d.lockForConfiguration()
            d.videoZoomFactor = f
            d.unlockForConfiguration()
        } catch {}
    }

    func toggleMic() { micEnabled.toggle() }

    private func applyMicMute() async {
        var settings = await mixer.audioMixerSettings
        settings.isMuted = !micEnabled
        await mixer.setAudioMixerSettings(settings)
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
        if isStreaming || isReconnecting {
            wantStreaming = false
            cancelReconnect()
            Task { await stop() }
        } else {
            wantStreaming = true
            Task {
                await start()
                if !isStreaming { scheduleReconnect() }
            }
        }
    }

    func setStabilization(_ m: StabilizationOption) {
        camera.stabilization = m
        let mode = m.mode
        Task { try? await mixer.configuration(video: 0) { unit in unit.preferredVideoStabilizationMode = mode } }
    }

    // MARK: - 自动重连

    private var shouldReconnect: Bool { wantStreaming && (autoReconnect || isLocked) }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        reconnectAttempt = 0
    }

    func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }
        isReconnecting = true
        reconnectTask = Task { @MainActor in
            var attempt = 0
            while !Task.isCancelled && shouldReconnect && !isStreaming {
                let delay = min(5.0, pow(2.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled || !shouldReconnect { break }
                attempt += 1
                reconnectAttempt = attempt
                if !isBusy { await start() }
                if isStreaming { status = "推流中（已重连）" }
            }
            reconnectTask = nil
            isReconnecting = false
            if isStreaming { reconnectAttempt = 0 }
        }
    }

    /// 回到前台：若推流中断则自动重启
    func onForeground() {
        try? AVAudioSession.sharedInstance().setActive(true)
        Task {
            if !(await mixer.isRunning) { await mixer.startRunning() }
            if currentDevice == nil { await attachCamera() }
            let f0 = counter.videoFrames
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if isStreaming && counter.videoFrames == f0 { await attachCamera() }
        }
        if wantStreaming && !isStreaming && !isBusy {
            if !status.contains("断开") && !status.contains("失败") { status = "连接已断开（后台期间）" }
            scheduleReconnect()
        }
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
        await applyMicMute() // mid-stream mute must survive reconnect without dropping track

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
        meterTimer?.invalidate()
        meterTimer = nil
        audioLevel = 0
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
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.micEnabled {
                    self.audioLevel = 0
                    return
                }
                let p = self.counter.audioLevel
                // 转为 dB 刻度 (-50..0 dB → 0..1)
                let db = 20 * log10(max(p, 0.00001))
                self.audioLevel = max(0, min(1, (db + 50) / 50))
            }
        }
        lastSentKB = 0
        stallSeconds = 0
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
            scheduleReconnect()
            return
        }
        if isStreaming {
            if sentKB == lastSentKB { stallSeconds += 1 } else { stallSeconds = 0 }
            lastSentKB = sentKB
            if stallSeconds >= 3 {
                stallSeconds = 0
                status = "连接已断开（无数据发送）"
                await teardown()
                scheduleReconnect()
            }
        }
    }
}
