import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var model = StreamModel()
    @State private var showSettings = false
    @State private var sliderZoom: Double = 1
    @State private var showCamPanel = false
    @State private var focusPoint: CGPoint?
    @State private var toast: String?
    @Environment(\.scenePhase) private var scenePhase

    private var hasError: Bool {
        model.cameraError != nil || ["失败", "错误", "断开", "无法", "没有", "请把", "未收到"].contains { model.status.contains($0) }
    }
    private var statusColor: Color {
        if hasError { return .red }
        if model.isStreaming { return .red }
        if model.isBusy { return .yellow }
        return .gray
    }
    private var statusText: String {
        if let e = model.cameraError { return e }
        if model.status == "未连接" || model.status == "已停止" { return "待机" }
        return model.status
    }
    private var caption: String {
        let s = model.outputSize
        let ar = model.isLandscapeOutput ? "横屏" : "竖屏"
        let head = model.aspect == .auto ? "自动\(ar)" : ar
        let kb = model.isStreaming && model.currentKbps > 0 ? model.currentKbps : model.bitrateKbps
        var t = "\(model.line.rawValue) · \(head) · \(model.effectiveResolution.cn)\(model.autoResolution != nil ? "（自动降级）" : "") \(Int(s.width))×\(Int(s.height)) · \(model.effectiveFps)帧/秒 · \(model.qualityMode.rawValue) " + String(format: "%.1f兆比特/秒", Double(kb) / 1000)
        if model.isStreaming { t += String(format: " · 发送 %.2f兆比特/秒", model.sendMbps) }
        return t
    }
    private var zoomPresets: [Double] { [0.5, 1.0, 2.0] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewView(view: model.previewView).ignoresSafeArea()
                .opacity(model.isLocked ? 0 : 1)
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                        guard abs(v.translation.width) < 10, abs(v.translation.height) < 10 else { return }
                        model.camera.focus(at: CGPoint(x: v.location.x / geo.size.width, y: v.location.y / geo.size.height))
                        focusPoint = v.location
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { focusPoint = nil }
                    })
                if let fp = focusPoint {
                    RoundedRectangle(cornerRadius: 4).stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 70, height: 70).position(fp)
                }
            }
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                topInfo
                Spacer()
                zoomControls
                    .padding(.bottom, 6)
                bottomRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 0)
            .opacity(model.isLocked ? 0 : 1)
            if model.isLocked {
                LockOverlay(model: model, isLocked: $model.isLocked)
                    .zIndex(10)
            }
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .task { await model.setup() }
        .environment(\.uiAngle, model.uiAngle)
        .animation(.easeInOut(duration: 0.3), value: model.uiAngle)
        .onChange(of: model.isStreaming) { s in if !s { model.syncOrientation() } }
        .onChange(of: scenePhase) { ph in
            if ph == .active { model.onForeground() } else { model.saveAll() }
        }
        .onChange(of: model.toastText) { t in
            if let t { showToast(t); model.toastText = nil }
        }
        .onChange(of: model.zoom) { z in
            if abs(sliderZoom - Double(z)) > 0.001 { sliderZoom = Double(z) }
        }
    }

    private var topInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(color: statusColor, pulsing: model.isStreaming)
                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(hasError ? .red : .white)
                    .lineLimit(2)
                if model.isStreaming { AudioMeter(level: model.audioLevel) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.55)))

            Text(caption)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.5)))

            HStack(spacing: 12) {
                IconCircleButton(icon: "rectangle.on.rectangle") {
                    let all = ResolutionOption.allCases
                    model.resolution = all[((all.firstIndex(of: model.resolution) ?? 0) + 1) % all.count]
                    model.applyResolution()
                }
                .disabled(model.isStreaming)
                .opacity(model.isStreaming ? 0.5 : 1)
                IconCircleButton(icon: model.micEnabled ? "mic.fill" : "mic.slash.fill",
                                 tint: model.micEnabled ? .white : .orange) {
                    model.toggleMic()
                }
                IconCircleButton(icon: "slider.horizontal.3", tint: showCamPanel ? .yellow : .white) {
                    showCamPanel.toggle()
                }
            }
            if model.orientationLockedHint {
                Text("推流中已锁定方向，停止后生效")
                    .font(.caption2).foregroundColor(.yellow)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
            }
            if model.isReconnecting {
                Text("重连中…第\(model.reconnectAttempt)次")
                    .font(.caption2).foregroundColor(.orange)
            }
            if showCamPanel {
                ScrollView {
                    CameraPanel(cam: model.camera, onStab: { model.setStabilization($0) })
                }
                .frame(maxWidth: 360, maxHeight: 320)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.6)))
            }
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                IconCircleButton(icon: "lock.fill", bg: Color.red.opacity(0.35)) {
                    model.oneTapLockStream()
                }
            }
            HStack(spacing: 10) {
                Text(zoomLabel(model.zoom))
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundColor(.yellow)
                    .frame(width: 40)
                Slider(value: $sliderZoom, in: Double(model.minZoom)...10.0, onEditingChanged: { editing in
                    if !editing { model.setZoom(CGFloat(sliderZoom)) }
                })
                .accentColor(.yellow)
                .onChange(of: sliderZoom) { v in
                    model.setZoom(CGFloat(v))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.45)))
        }
    }

    private func showToast(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toast == msg { toast = nil }
        }
    }

    private func zoomLabel(_ z: CGFloat) -> String {
        if abs(z - z.rounded()) < 0.05 { return "\(Int(z.rounded()))倍" }
        return String(format: "%.1f倍", Double(z))
    }

    private var bottomRow: some View {
        HStack {
            RoundIconButton(icon: "gearshape.fill") { showSettings = true }
            Spacer()
            Button(action: model.toggle) {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                    if model.isStreaming {
                        RoundedRectangle(cornerRadius: 8).fill(Color.red).frame(width: 32, height: 32)
                    } else {
                        Circle().fill(Color.red).frame(width: 64, height: 64)
                    }
                    if model.isBusy {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: model.isStreaming)
            }
            .disabled(model.isBusy)
            Spacer()
            RoundIconButton(icon: "arrow.triangle.2.circlepath.camera") { model.flipCamera() }
        }
        .padding(.horizontal, 12)
    }
}

struct CapsuleButton: View {
    @Environment(\.uiAngle) private var angle
    let icon: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).rotationEffect(.degrees(angle))
                Text(title)
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.55)))
        }
    }
}

struct IconCircleButton: View {
    @Environment(\.uiAngle) private var angle
    let icon: String
    var tint: Color = .white
    var bg: Color = Color.black.opacity(0.55)
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(bg)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(tint)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 48, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(FixedButtonStyle())
        .frame(width: 48, height: 48)
    }
}

struct FixedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct RoundIconButton: View {
    @Environment(\.uiAngle) private var angle
    let icon: String
    var tint: Color = .white
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .rotationEffect(.degrees(angle))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 50, height: 50)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: StreamModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var kbps: Double = 6000
    @State private var sliderZoom: Double = 1

    private var zoomPresets: [Double] { [0.5, 1.0, 2.0] }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("推流地址"),
                        footer: Text(model.isStreaming ? "推流中不可修改推流地址和密钥。" : "最终地址：推流地址?streamid=\(model.line.prefix)密钥。粘贴完整地址会自动识别线路并填入密钥。")) {
                    Picker("线路", selection: $model.line) {
                        ForEach(StreamLine.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("推流地址").frame(width: 72, alignment: .leading)
                        TextField("srt://主机:端口", text: $model.addressText)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                    }
                    HStack {
                        Text("密钥").frame(width: 72, alignment: .leading)
                        TextField("输入\(model.line.rawValue)推流密钥", text: $model.keyText)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    HStack {
                        Text("延迟").frame(width: 72, alignment: .leading)
                        TextField("0", text: $model.latencyText)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.numberPad)
                        Text("毫秒（0=默认）").foregroundColor(.secondary)
                    }
                }
                .disabled(model.isStreaming)
                Section(header: Text("视频"),
                        footer: Text(model.isStreaming ? "推流中不可修改分辨率、帧率和画面比例，停止推流后可修改。" : "超清2K 用 4K 采集再缩放到 2560×1440。60帧/秒需要设备支持对应分辨率；不支持时会自动保持 30帧/秒。")) {
                    Picker("画面比例", selection: $model.aspect) {
                        ForEach(AspectOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isStreaming)
                    Picker("分辨率", selection: $model.resolution) {
                        ForEach(ResolutionOption.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: model.resolution) { _ in
                        model.applyResolution()
                        kbps = Double(model.bitrateKbps)
                    }
                    .disabled(model.isStreaming)
                    if model.isStreaming {
                        Text("推流中不可修改分辨率").font(.footnote).foregroundColor(.secondary)
                    }
                    Picker("帧率", selection: $model.fps) {
                        Text("30帧/秒").tag(30)
                        Text("60帧/秒").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.fps) { _ in model.applyFrameRate() }
                    .disabled(model.isStreaming)
                }

                Section(header: Text("画质模式"), footer: Text("流畅：使用设定码率的 60%，优先保证不卡顿；高质量：使用设定码率；自动：根据网络丢包和发送缓冲自动在设定码率的 40%～100% 之间调节。推流中可随时切换。")) {
                    Picker("画质模式", selection: $model.qualityMode) {
                        ForEach(QualityMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if model.isStreaming {
                        Text("当前实际码率：\(Self.fmt(model.currentKbps)) 千比特/秒").font(.footnote).foregroundColor(.secondary)
                    }
                }
                Section(header: Text("码率"), footer: Text("默认码率跟随分辨率：标清720 4兆 / 高清1080 6兆 / 超清2K 10兆。推流中可实时调整。")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("视频码率：\(Self.fmt(Int(kbps))) 千比特/秒（" + String(format: "%.1f", kbps / 1000) + " 兆比特/秒）")
                        Slider(value: $kbps, in: 1000...12000, step: 100, onEditingChanged: { editing in
                            if !editing { model.bitrateKbps = Int(kbps) }
                        })
                        .accentColor(.red)
                        .onChange(of: kbps) { v in model.bitrateKbps = Int(v) }
                    }
                    Button("恢复默认（\(model.resolution.cn) \(model.resolution.defaultKbps / 1000)兆）") {
                        model.resetBitrate()
                        kbps = Double(model.bitrateKbps)
                    }
                }

                Section(header: Text("镜头 / 变焦"),
                        footer: Text("多镜头模式下变焦会自动切换超广角 / 广角 / 长焦。部分机型在多镜头模式下不支持手动对焦，需要时可关闭多镜头。")) {
                    Toggle("多镜头自动切换（支持 0.5倍超广角）", isOn: $model.multiCam)
                        .toggleStyle(SwitchToggleStyle(tint: .green))
                    HStack(spacing: 10) {
                        ForEach(zoomPresets, id: \.self) { z in
                            let unsupported = z < 1 && !model.hasUltraWide
                            Button(action: { if model.setZoom(CGFloat(z)) { sliderZoom = z } }) {
                                Text(z == 0.5 ? "0.5倍" : "\(Int(z))倍")
                                    .font(.footnote.weight(.bold))
                                    .foregroundColor(unsupported ? .gray :
                                        (abs(Double(model.zoom) - z) < 0.01 ? .yellow : .primary))
                                    .frame(width: 44, height: 30)
                                    .background(Capsule().fill(Color.secondary.opacity(unsupported ? 0.15 : 0.2)))
                            }
                            .disabled(unsupported)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("变焦：" + Self.zoomText(model.zoom))
                        Slider(value: $sliderZoom, in: Double(model.minZoom)...10.0)
                            .onChange(of: sliderZoom) { v in model.setZoom(CGFloat(v)) }
                    }
                }
                .disabled(model.isStreaming)

                Section(header: Text("相机")) {
                    NavigationLink(destination: CameraParamsPage(model: model)) {
                        Label("相机参数", systemImage: "slider.horizontal.3")
                    }
                }
                Section(header: Text("旋转"), footer: Text("自动模式用陀螺仪判断方向（系统锁定旋转时也有效）；推流中方向锁定，停止后生效。")) {
                    Picker("旋转", selection: $model.rotationMode) {
                        ForEach(RotationMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                .disabled(model.isStreaming)
                Section(header: Text("推流"), footer: Text("自动开始推流仅在地址有效且不含「密钥」占位时生效。解锁不会停止推流。静音时仍发送静音音频包，断流检测不受影响。")) {
                    Toggle("声音采集", isOn: $model.micEnabled)
                    Toggle("降噪/指向麦克风", isOn: $model.noiseReduction)
                    if !model.micInfo.isEmpty {
                        Text("当前麦克风：\(model.micInfo)").font(.footnote).foregroundColor(.secondary)
                    }
                    if #available(iOS 15.0, *) {
                        Button("系统麦克风模式（语音突显）") {
                            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                        }
                    }
                    Toggle("断流自动重连", isOn: $model.autoReconnect)
                        .disabled(model.isStreaming)
                    Toggle("启动应用后自动开始推流", isOn: $model.autoStartOnLaunch)
                        .disabled(model.isStreaming)
                    Toggle("自动推流后自动锁屏", isOn: $model.autoLockAfterStart)
                        .disabled(model.isStreaming)
                }
                Section(header: Text("编码格式"), footer: Text("推流中不可修改编码格式。")) {
                    Picker("编码档次", selection: $model.profile) {
                        ForEach(ProfileOption.allCases) { Text($0.cn).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(model.isStreaming)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Text("完成")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            kbps = Double(model.bitrateKbps)
            sliderZoom = Double(model.zoom)
        }
    }

    static func fmt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func zoomText(_ z: CGFloat) -> String {
        if abs(z - z.rounded()) < 0.05 && z >= 1 { return "\(Int(z.rounded()))倍" }
        return String(format: "%.1f倍", Double(z))
    }
}


private struct UIAngleKey: EnvironmentKey { static let defaultValue: Double = 0 }
extension EnvironmentValues {
    var uiAngle: Double {
        get { self[UIAngleKey.self] }
        set { self[UIAngleKey.self] = newValue }
    }
}

struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    var size: CGFloat = 8
    @State private var dim = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(pulsing && dim ? 0.2 : 1)
            .onAppear { start() }
            .onChange(of: pulsing) { _ in start() }
    }
    private func start() {
        dim = false
        guard pulsing else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
    }
}

struct AudioMeter: View {
    let level: Float
    var bars = 10
    var dim = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let on = Float(i) < level * Float(bars)
                RoundedRectangle(cornerRadius: 1)
                    .fill(color(i).opacity(on ? (dim ? 0.6 : 1) : 0.18))
                    .frame(width: 3, height: 5 + CGFloat(i) * 0.8)
            }
        }
        .animation(.linear(duration: 0.06), value: level)
    }
    private func color(_ i: Int) -> Color {
        let f = Double(i) / Double(bars - 1)
        return f < 0.6 ? .green : (f < 0.85 ? .yellow : .red)
    }
}

struct CameraParamsPage: View {
    @ObservedObject var model: StreamModel
    var body: some View {
        Form {
            Section(footer: Text("推流中不可修改相机参数。")) {
                CameraPanel(cam: model.camera, onStab: { model.setStabilization($0) })
            }
            .disabled(model.isStreaming)
        }
        .navigationTitle("相机参数")
        .navigationBarTitleDisplayMode(.inline)
    }
}
