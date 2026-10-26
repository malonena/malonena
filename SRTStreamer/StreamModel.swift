import AVFoundation
import CallKit
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
        case .p720: return "标清720（1280×720）"
        case .p1080: return "高清1080（1920×1080）"
        case .k2: return "超清2K（2560×1440）"
        }
    }
    var cn: String {
        switch self {
        case .p720: return "标清720"
        case .p1080: return "高清1080"
        case .k2: return "超清2K"
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

enum StreamLine: String, CaseIterable, Identifiable {
    case one = "线路一"
    case two = "线路二"
    var id: String { rawValue }
    var path: String { self == .one ? "live" : "live2" }
    var user: String { self == .one ? "push" : "push2" }
    var prefix: String { "publish:\(path):\(user):" }
    var keyStore: String { self == .one ? "srtKey" : "srtKey2" }
}

enum QualityMode: String, CaseIterable, Identifiable {
    case smooth = "流畅"
    case high = "高质量"
    case auto = "自动"
    var id: String { rawValue }
}

enum ProfileOption: String, CaseIterable, Identifiable {
    case baseline = "Baseline"
    case main = "Main"
    var id: String { rawValue }
    var cn: String { self == .baseline ? "基础（兼容性好）" : "主要（画质更好）" }
    var profileLevel: String {
        self == .baseline ? (kVTProfileLevel_H264_Baseline_AutoLevel as String) : (kVTProfileLevel_H264_Main_AutoLevel as String)
    }
}

@MainActor
final class StreamModel: ObservableObject {
    static let defaultURL = "srt://8.148.79.198:8890?streamid=publish:live:push:密钥"

    static let defaultAddress = "srt://8.148.79.198:8890"
    static let keyPrefix = "publish:live:push:"
    /// 推流地址（不含密钥）
    @Published var addressText: String = StreamModel.loadAddress() {
        didSet {
            if let (addr, key, ln) = StreamModel.splitURL(addressText) {
                addressText = addr
                if let ln, ln != line { line = ln }
                if let key, !key.isEmpty { keyText = key }
                UserDefaults.standard.set(addr, forKey: "srtAddress")
                return
            }
            UserDefaults.standard.set(addressText, forKey: "srtAddress")
        }
    }
    /// 推流密钥
    @Published var keyText: String = UserDefaults.standard.string(forKey: StreamModel.savedLine.keyStore) ?? "" {
        didSet { UserDefaults.standard.set(keyText, forKey: line.keyStore) }
    }
    static var savedLine: StreamLine { StreamLine(rawValue: UserDefaults.standard.string(forKey: "streamLine") ?? "") ?? .one }
    /// 线路（每条线路单独保存密钥）
    @Published var line: StreamLine = StreamModel.savedLine {
        didSet {
            UserDefaults.standard.set(line.rawValue, forKey: "streamLine")
            keyText = UserDefaults.standard.string(forKey: line.keyStore) ?? ""
        }
    }
    /// 最终推流地址
    var urlText: String {
        var a = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        while a.hasSuffix("/") || a.hasSuffix("?") { a.removeLast() }
        let k = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return a + "?streamid=" + line.prefix + (k.isEmpty ? "密钥" : k)
    }
    /// 若粘贴的是带 streamid 的完整地址，拆出 (地址, 密钥)
    static func splitURL(_ s: String) -> (String, String?, StreamLine?)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let q = t.firstIndex(of: "?") else { return nil }
        let addr = String(t[..<q])
        let query = String(t[t.index(after: q)...])
        var key: String?
        var ln: StreamLine?
        for part in query.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 && kv[0] == "streamid" {
                var v = kv[1].removingPercentEncoding ?? kv[1]
                let parts = v.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 4 {
                    ln = StreamLine.allCases.first { $0.path == parts[1] && $0.user == parts[2] }
                    v = parts[3...].joined(separator: ":")
                } else if let i = v.lastIndex(of: ":") { v = String(v[v.index(after: i)...]) }
                key = (v == "密钥") ? nil : v
            }
        }
        return (addr, key, ln)
    }
    static func loadAddress() -> String {
        let d = UserDefaults.standard
        if let a = d.string(forKey: "srtAddress") { return a }
        // 迁移旧的完整地址
        if let old = d.string(forKey: "srtURL"), let (addr, key, _) = splitURL(old) {
            d.set(addr, forKey: "srtAddress")
            if let key, !key.isEmpty, d.string(forKey: "srtKey") == nil { d.set(key, forKey: "srtKey") }
            return addr.isEmpty ? defaultAddress : addr
        }
        return defaultAddress
    }
    @AppStorage("latency") var latencyText: String = "200"
    @Published var resolution: ResolutionOption = ResolutionOption(rawValue: UserDefaults.standard.string(forKey: "resolution") ?? "") ?? .p720 {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "resolution") }
    }
    @Published var bitrateKbps: Int = (UserDefaults.standard.object(forKey: "bitrateKbps") as? Int) ?? 6000 {
        didSet { UserDefaults.standard.set(bitrateKbps, forKey: "bitrateKbps"); retarget() }
    }
    /// 画质模式：流畅 = 手动码率的 60%；高质量 = 手动码率；自动 = 按网络在 [40%, 手动码率] 之间自适应
    @Published var qualityMode: QualityMode = QualityMode(rawValue: UserDefaults.standard.string(forKey: "qualityMode") ?? "") ?? .auto {
        didSet {
            UserDefaults.standard.set(qualityMode.rawValue, forKey: "qualityMode")
            if qualityMode != .auto && autoResolution != nil {
                autoResolution = nil
                Task { await applyLiveSize() }
            }
            retarget()
        }
    }
    /// 当前实际编码码率
    @Published var currentKbps: Int = 0
    private var goodSeconds = 0
    private var lastLoss: Int32 = 0
    private var lastDrop: Int32 = 0
    var minAutoKbps: Int { max(800, bitrateKbps * 4 / 10) }
    private var baseTargetKbps: Int {
        switch qualityMode {
        case .smooth: return max(800, bitrateKbps * 6 / 10)
        case .high, .auto: return bitrateKbps
        }
    }
    private func retarget() {
        let t = baseTargetKbps
        if qualityMode == .auto && isStreaming && currentKbps > 0 {
            currentKbps = min(max(currentKbps, minAutoKbps), t)
        } else {
            currentKbps = t
        }
        Task { await applyLiveBitrate() }
    }
    private var appliedKbps = 0
    private func applyLiveBitrate() async {
        guard let stream, currentKbps > 0, currentKbps != appliedKbps else { return }
        var v = await stream.videoSettings
        v.bitRate = currentKbps * 1000
        await stream.setVideoSettings(v)
        appliedKbps = currentKbps
    }
    private func lowerRes(_ r: ResolutionOption) -> ResolutionOption? {
        switch r { case .k2: return .p1080; case .p1080: return .p720; case .p720: return nil }
    }
    private func higherRes(_ r: ResolutionOption) -> ResolutionOption? {
        guard r != resolution else { return nil }
        switch r { case .p720: return .p1080; case .p1080: return .k2; case .k2: return nil }
    }
    /// 推流中直接修改编码尺寸（不断流，编码器自动重建会话）
    private func applyLiveSize() async {
        guard let stream else { return }
        var v = await stream.videoSettings
        v.videoSize = outputSize
        await stream.setVideoSettings(v)
        stallSeconds = 0
    }
    /// 自动模式：根据丢包/丢帧/发送缓冲调整码率
    private func adapt(_ p: SRTPerformanceData) async {
        let loss = p.pktSndLossTotal, drop = p.pktSndDropTotal
        let dLoss = loss - lastLoss, dDrop = drop - lastDrop
        lastLoss = loss; lastDrop = drop
        guard qualityMode == .auto else { return }
        let congested = dDrop > 0 || dLoss > 30 || p.msSndBuf > 800
        if congested {
            goodSeconds = 0
            if currentKbps <= minAutoKbps {
                floorSeconds += 1
                // 码率已到下限且持续拥塞 5 秒：降一级分辨率
                if floorSeconds >= 5, let lower = lowerRes(effectiveResolution) {
                    floorSeconds = 0
                    autoResolution = lower
                    await applyLiveSize()
                }
            } else { floorSeconds = 0 }
            currentKbps = max(minAutoKbps, currentKbps * 3 / 4)
        } else {
            floorSeconds = 0
            goodSeconds += 1
            if goodSeconds >= 8 && currentKbps < baseTargetKbps {
                goodSeconds = 0
                currentKbps = min(baseTargetKbps, currentKbps * 11 / 10 + 100)
            } else if goodSeconds >= 30 && autoResolution != nil {
                // 稳定 30 秒后升回一级分辨率
                goodSeconds = 0
                let up = higherRes(effectiveResolution)
                autoResolution = (up == nil || up == resolution) ? nil : up
                await applyLiveSize()
            }
        }
        await applyLiveBitrate()
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
    @Published var zoom: CGFloat = 1 {
        didSet { UserDefaults.standard.set(Double(zoom), forKey: "zoom") }
    }
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
    /// 降噪/指向麦克风（videoRecording 模式 + 心形指向）
    @Published var noiseReduction: Bool = (UserDefaults.standard.object(forKey: "noiseReduction") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(noiseReduction, forKey: "noiseReduction")
            configureAudioSession()
        }
    }
    @Published var micInfo: String = ""

    /// 配置音频会话：降噪开启时用 .videoRecording 模式（系统波束成形/降噪），并选择与镜头同向的内置麦克风 + 心形指向
    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: noiseReduction ? .videoRecording : .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
        } catch {
            micInfo = "音频会话配置失败"
            return
        }
        guard noiseReduction else { micInfo = "降噪关闭"; return }
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            micInfo = "未找到内置麦克风"; return
        }
        do { try session.setPreferredInput(builtIn) } catch {}
        let want: AVAudioSession.Orientation = (position == .front) ? .front : .back
        let sources = builtIn.dataSources ?? []
        let src = sources.first(where: { $0.orientation == want })
            ?? sources.first(where: { $0.orientation == .bottom })
            ?? sources.first
        guard let ds = src else { micInfo = "内置麦克风（无数据源）"; return }
        var pattern = "默认"
        if let pats = ds.supportedPolarPatterns {
            if pats.contains(.cardioid) {
                try? ds.setPreferredPolarPattern(.cardioid); pattern = "心形指向"
            } else if pats.contains(.subcardioid) {
                try? ds.setPreferredPolarPattern(.subcardioid); pattern = "次心形指向"
            }
        }
        try? builtIn.setPreferredDataSource(ds)
        let side: String
        switch ds.orientation {
        case .some(.front): side = "前置麦克风"
        case .some(.back): side = "后置麦克风"
        case .some(.bottom): side = "底部麦克风"
        default: side = "内置麦克风"
        }
        micInfo = "\(side) · \(pattern)"
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
    private var position: AVCaptureDevice.Position = (UserDefaults.standard.string(forKey: "cameraPosition") == "front") ? .front : .back {
        didSet { UserDefaults.standard.set(position == .front ? "front" : "back", forKey: "cameraPosition") }
    }
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
        let savedZoom = CGFloat((UserDefaults.standard.object(forKey: "zoom") as? Double) ?? 1)
        await attachCamera()
        setZoom(max(savedZoom, minZoom))
        micPermission = audioOK
        setupCallMonitoring()
        if audioOK {
            if isInCall {
                // 通话中：不挂麦克风，只推视频 + 静音音频
                audioSuspended = true
                toastText = "通话中，暂停声音采集"
            } else {
                do { try await mixer.attachAudio(AVCaptureDevice.default(for: .audio)) }
                catch { status = "麦克风连接失败: \(error.localizedDescription)" }
                await applyMicMute()
            }
        }
        await mixer.addOutput(previewView) // 预览始终直接来自 mixer
        await mixer.startRunning()
        // HaishinKit 挂载音频/启动会话后再设置，避免被覆盖
        configureAudioSession()
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
                if urlText.contains("密钥") { status = "请输入推流密钥" }
                else { status = "推流地址格式错误" }
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

    /// 自动模式下网络拥塞时可临时降低的实际推流分辨率（nil = 使用用户设置）
    @Published var autoResolution: ResolutionOption?
    var effectiveResolution: ResolutionOption { autoResolution ?? resolution }
    private var floorSeconds = 0
    var outputSize: CGSize {
        let s = effectiveResolution.size
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
            // 虚拟设备：1x 对应的 videoZoomFactor（iOS 18+ 用 displayVideoZoomFactorMultiplier，
            // 否则用 virtualDeviceSwitchOverVideoZoomFactors 首项，再否则双/三摄默认 2）
            let mult: CGFloat = {
                if #available(iOS 18.0, *) {
                    return max(dev.displayVideoZoomFactorMultiplier, 1)
                }
                if let first = dev.virtualDeviceSwitchOverVideoZoomFactors.first {
                    return CGFloat(truncating: first)
                }
                switch dev.deviceType {
                case .builtInDualWideCamera, .builtInTripleCamera: return 2
                default: return 1
                }
            }()
            let ultra = pos == .back && (
                dev.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera } ||
                dev.deviceType == .builtInDualWideCamera ||
                dev.deviceType == .builtInTripleCamera ||
                (mult > 1 && dev.minAvailableVideoZoomFactor < mult * 0.6)
            )
            hasUltraWide = ultra
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
        do {
            try await mixer.attachVideo(device, track: 0) { unit in
                unit.isVideoMirrored = (pos == .front)
                // 挂载时先关闭防抖（此时 unit 可能仍指向旧设备/旧连接），挂载完成后再按新格式安全设置
                unit.preferredVideoStabilizationMode = .off
            }
            cameraError = nil
            applyZoomFactor()
            await applyFrameRateNow()
            camera.reapply()
            applyStabilizationSafely(silent: true)
        } catch {
            cameraError = "摄像头连接失败: \(error.localizedDescription)"
        }
    }

    func flipCamera() {
        position = (position == .back) ? .front : .back
        zoom = 1
        Task {
            await attachCamera()
            configureAudioSession()
        }
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
        applyStabilizationSafely(silent: true) // 格式可能已变，重新按支持情况设置防抖
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

    /// 当前格式不支持的防抖模式直接赋值会抛 NSInvalidArgumentException 导致闪退，这里按 电影级→标准→关 降级
    static func safeStabMode(_ device: AVCaptureDevice?, _ want: AVCaptureVideoStabilizationMode) -> AVCaptureVideoStabilizationMode {
        guard let f = device?.activeFormat else { return .off }
        let chain: [AVCaptureVideoStabilizationMode]
        switch want {
        case .off: return .off
        case .auto: chain = [.auto, .standard]
        case .cinematic: chain = [.cinematic, .standard]
        default: chain = [want, .standard]
        }
        return chain.first { f.isVideoStabilizationModeSupported($0) } ?? .off
    }

    func setStabilization(_ m: StabilizationOption) {
        camera.stabilization = m
        applyStabilizationSafely(silent: false)
    }

    private func applyStabilizationSafely(silent: Bool) {
        let m = camera.stabilization
        let mode = StreamModel.safeStabMode(currentDevice, m.mode)
        if mode != m.mode && !silent {
            toastText = mode == .off ? "当前镜头/分辨率不支持防抖" : "当前格式不支持该防抖模式，已改用标准防抖"
        }
        Task {
            try? await mixer.configuration(video: 0) { unit in
                unit.preferredVideoStabilizationMode = mode
            }
        }
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
    // MARK: - 通话处理（通话占用麦克风时保持视频继续）

    @Published var toastText: String?
    @Published var audioSuspended = false
    private var micPermission = false
    private let callObserver = CXCallObserver()
    private var callDelegate: CallDelegate?
    private var callMonitorStarted = false
    private var silenceTimer: DispatchSourceTimer?

    var isInCall: Bool { callObserver.calls.contains { !$0.hasEnded } }

    private func setupCallMonitoring() {
        guard !callMonitorStarted else { return }
        callMonitorStarted = true
        let d = CallDelegate { [weak self] in
            Task { @MainActor in self?.callStateChanged() }
        }
        callDelegate = d
        callObserver.setDelegate(d, queue: .main)
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    if self.isInCall { await self.suspendAudio() }
                } else {
                    self.callStateChanged()
                }
            }
        }
        nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                .flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            Task { @MainActor in
                guard let self else { return }
                if reason == .audioDeviceInUseByAnotherClient {
                    await self.suspendAudio()
                }
            }
        }
        nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.callStateChanged() }
        }
    }

    private func callStateChanged() {
        Task {
            if isInCall {
                await suspendAudio()
            } else if audioSuspended {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if !isInCall { await resumeAudio() }
            }
        }
    }

    /// 通话开始：摘掉麦克风输入，让摄像头继续工作；推流用静音音频保持音轨
    func suspendAudio() async {
        guard !audioSuspended else { return }
        audioSuspended = true
        toastText = "通话中，暂停声音采集"
        try? await mixer.attachAudio(nil)
        if isStreaming || stream != nil { startSilence() }
        await kickCapture()
    }

    /// 通话结束：重新挂麦克风
    func resumeAudio() async {
        guard audioSuspended, micPermission else { return }
        do {
            configureAudioSession()
            try await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
            stopSilence()
            audioSuspended = false
            await applyMicMute()
            configureAudioSession()
            toastText = "通话结束，已恢复声音采集"
        } catch {
            // 仍被占用，稍后再试
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !isInCall { await resumeAudio() }
            return
        }
        await kickCapture()
    }

    /// 采集会话被中断后重新启动（不影响推流连接）
    private func kickCapture() async {
        stallSeconds = 0
        let f0 = counter.videoFrames
        try? await Task.sleep(nanoseconds: 700_000_000)
        if counter.videoFrames == f0 {
            if !(await mixer.isRunning) { await mixer.startRunning() }
            // 触发 HaishinKit 内部 session.startRunningIfNeeded()
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            try? await Task.sleep(nanoseconds: 700_000_000)
            if counter.videoFrames == f0 { await attachCamera() }
        }
        stallSeconds = 0
    }

    private func startSilence() {
        guard silenceTimer == nil, let stream else { return }
        silenceTimer = SilenceFeeder.make(stream)
    }

    private func stopSilence() {
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    func saveAll() {
        camera.save()
        UserDefaults.standard.set(Double(zoom), forKey: "zoom")
        UserDefaults.standard.synchronize()
    }

    func onForeground() {
        configureAudioSession()
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
        guard let url = normalizedURL() else { status = "推流地址格式错误"; return }
        if urlText.contains("密钥") { status = "请输入推流密钥"; return }
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
            bitRate: baseTargetKbps * 1000,
            profileLevel: profile.profileLevel,
            scalingMode: .trim,
            bitRateMode: .average,
            maxKeyFrameIntervalDuration: 1,
            allowFrameReordering: false
        )
        v.frameInterval = 0
        await stream.setVideoSettings(v)
        currentKbps = baseTargetKbps; appliedKbps = currentKbps; floorSeconds = 0
        goodSeconds = 0; lastLoss = 0; lastDrop = 0
        var a = await stream.audioSettings
        a.bitRate = 128 * 1000
        await stream.setAudioSettings(a)

        // 2. 挂接输出（预览 + 帧计数），并把 stream 作为 mixer 的输出
        await stream.addOutput(counter)
        await mixer.addOutput(stream)
        if !(await mixer.isRunning) { await mixer.startRunning() }
        if audioSuspended || !micPermission { startSilence() }
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
        autoResolution = nil
        await teardown()
        status = "已停止"
    }

    private func teardown() async {
        stopSilence()
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
            if isStreaming { await adapt(p) }
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

final class CallDelegate: NSObject, CXCallObserverDelegate {
    let onChange: () -> Void
    init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) { onChange() }
}

enum SilenceFeeder {
    nonisolated static func make(_ stream: SRTStream) -> DispatchSourceTimer? {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { return nil }
        let frames: AVAudioFrameCount = 1024
        var sampleTime: AVAudioFramePosition = 0
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "silence"))
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000.0 * Double(frames) / 48000)))
        t.setEventHandler {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
            buf.frameLength = frames
            if let ch = buf.floatChannelData { memset(ch[0], 0, Int(frames) * MemoryLayout<Float>.size) }
            let when = AVAudioTime(hostTime: mach_absolute_time(), sampleTime: sampleTime, atRate: 48000)
            sampleTime += AVAudioFramePosition(frames)
            Task { await stream.append(buf, when: when) }
        }
        t.resume()
        return t
    }
}
