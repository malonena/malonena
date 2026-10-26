import SwiftUI

struct ContentView: View {
    @StateObject private var model = StreamModel()
    @State private var showSettings = false
    @State private var sliderZoom: Double = 1
    @State private var showCamPanel = false
    @State private var focusPoint: CGPoint?
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
        let ar = model.isLandscapeOutput ? "16:9" : "9:16"
        let head = model.aspect == .auto ? "自动 \(ar)" : ar
        var t = "\(head) · \(model.resolution.rawValue) \(Int(s.width))×\(Int(s.height)) · \(model.effectiveFps)fps · " + String(format: "%.1fMbps", Double(model.bitrateKbps) / 1000)
        if model.isStreaming { t += String(format: " · 发送 %.2fMbps", model.sendMbps) }
        return t
    }
    private var zoomPresets: [Double] { model.hasUltraWide ? [0.5, 1.0, 2.0] : [1.0, 2.0] }

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
                inputPanel
                bottomRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .opacity(model.isLocked ? 0 : 1)
            if model.isLocked {
                LockOverlay(model: model, isLocked: $model.isLocked)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .task { await model.setup() }
        .environment(\.uiAngle, model.uiAngle)
        .animation(.easeInOut(duration: 0.3), value: model.uiAngle)
        .onChange(of: model.isStreaming) { s in if !s { model.syncOrientation() } }
        .onChange(of: scenePhase) { ph in if ph == .active { model.onForeground() } }
        .onChange(of: model.zoom) { z in
            if abs(sliderZoom - Double(z)) > 0.001 { sliderZoom = Double(z) }
        }
    }

    private var topInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(color: statusColor, pulsing: model.isStreaming && !hasError)
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

            HStack(spacing: 8) {
                CapsuleButton(icon: "rotate.right", title: model.aspect.rawValue) {
                    let all = AspectOption.allCases
                    model.aspect = all[((all.firstIndex(of: model.aspect) ?? 0) + 1) % all.count]
                }
                .disabled(model.isStreaming)
                CapsuleButton(icon: "rectangle.on.rectangle", title: model.resolution.rawValue) {
                    let all = ResolutionOption.allCases
                    model.resolution = all[((all.firstIndex(of: model.resolution) ?? 0) + 1) % all.count]
                    model.applyResolution()
                }
                .disabled(model.isStreaming)
                .opacity(model.isStreaming ? 0.5 : 1)
                CapsuleButton(icon: "lock.fill", title: "一键锁屏推流") {
                    model.oneTapLockStream()
                }
                CapsuleButton(icon: "slider.horizontal.3", title: "参数") {
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
                CameraPanel(cam: model.camera, onStab: { model.setStabilization($0) })
                    .padding(10)
                    .frame(maxWidth: 360)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.6)))
            }
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Spacer()
                ForEach(zoomPresets, id: \.self) { z in
                    Button(action: { model.setZoom(CGFloat(z)) }) {
                        Text(z == 0.5 ? "0.5x" : "\(Int(z))x")
                            .font(.footnote.weight(.bold))
                            .foregroundColor(abs(Double(model.zoom) - z) < 0.01 ? .yellow : .white)
                            .rotationEffect(.degrees(model.uiAngle))
                            .frame(width: 44, height: 30)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                }
                Spacer()
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

    private func zoomLabel(_ z: CGFloat) -> String {
        if abs(z - z.rounded()) < 0.05 { return "\(Int(z.rounded()))x" }
        return String(format: "%.1fx", Double(z))
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("srt://host:port?streamid=...", text: $model.urlText)
                .font(.system(.footnote, design: .monospaced))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .lineLimit(1)
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
                .disabled(model.isStreaming)
            HStack(spacing: 8) {
                Text("Latency").font(.footnote).foregroundColor(.white.opacity(0.8))
                TextField("0", text: $model.latencyText)
                    .font(.system(.footnote, design: .monospaced))
                    .keyboardType(.numberPad)
                    .frame(width: 70)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6)))
                    .disabled(model.isStreaming)
                Text("ms (0=默认)").font(.footnote).foregroundColor(.white.opacity(0.6))
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.45)))
    }

    private var bottomRow: some View {
        HStack {
            RoundIconButton(icon: "gearshape.fill") { showSettings = true }
                .disabled(model.isStreaming)
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

struct RoundIconButton: View {
    @Environment(\.uiAngle) private var angle
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .rotationEffect(.degrees(angle))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
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

    private var zoomPresets: [Double] { model.hasUltraWide ? [0.5, 1.0, 2.0] : [1.0, 2.0] }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("视频"),
                        footer: Text("2K 用 4K 采集再缩放到 2560×1440。60fps 需要设备支持对应分辨率；不支持时会自动保持 30fps。")) {
                    Picker("画面比例", selection: $model.aspect) {
                        ForEach(AspectOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("分辨率", selection: $model.resolution) {
                        ForEach(ResolutionOption.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: model.resolution) { _ in
                        model.applyResolution()
                        kbps = Double(model.bitrateKbps)
                    }
                    Picker("帧率", selection: $model.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.fps) { _ in model.applyFrameRate() }
                }

                Section(header: Text("码率"), footer: Text("码率跟随分辨率：720p 4M / 1080p 6M / 2K 10M。")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("视频码率：\(Self.fmt(Int(kbps))) kbps (" + String(format: "%.1f", kbps / 1000) + " Mbps)")
                        Slider(value: $kbps, in: 1000...12000, step: 100, onEditingChanged: { editing in
                            if !editing { model.bitrateKbps = Int(kbps) }
                        })
                        .accentColor(.red)
                        .onChange(of: kbps) { v in model.bitrateKbps = Int(v) }
                    }
                    Button("恢复默认（\(model.resolution.rawValue) \(model.resolution.defaultKbps / 1000)M）") {
                        model.resetBitrate()
                        kbps = Double(model.bitrateKbps)
                    }
                }

                Section(header: Text("镜头 / 变焦"),
                        footer: Text("多镜头模式下变焦会自动切换超广角 / 广角 / 长焦。部分机型在多镜头模式下不支持手动对焦，需要时可关闭多镜头。")) {
                    Toggle("多镜头自动切换（支持 0.5x 超广角）", isOn: $model.multiCam)
                        .toggleStyle(SwitchToggleStyle(tint: .green))
                    HStack(spacing: 10) {
                        ForEach(zoomPresets, id: \.self) { z in
                            let sel = abs(Double(model.zoom) - z) < 0.01
                            Button(action: { model.setZoom(CGFloat(z)); sliderZoom = z }) {
                                Text(z == 0.5 ? "0.5x" : "\(Int(z))x")
                                    .font(.footnote.weight(.bold))
                                    .foregroundColor(sel ? .black : .white)
                                    .frame(width: 50, height: 30)
                                    .background(Capsule().fill(sel ? Color.yellow : Color.white.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("变焦：" + Self.zoomText(model.zoom))
                        Slider(value: $sliderZoom, in: Double(model.minZoom)...10.0)
                            .onChange(of: sliderZoom) { v in model.setZoom(CGFloat(v)) }
                    }
                }

                Section(header: Text("相机参数")) {
                    CameraPanel(cam: model.camera, onStab: { model.setStabilization($0) })
                }
                Section(header: Text("旋转"), footer: Text("自动模式用陀螺仪判断方向（系统锁定旋转时也有效）；推流中方向锁定，停止后生效。")) {
                    Picker("旋转", selection: $model.rotationMode) {
                        ForEach(RotationMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section(header: Text("推流"), footer: Text("自动开始推流仅在地址有效且不含「密钥」占位时生效。解锁不会停止推流。")) {
                    Toggle("断流自动重连", isOn: $model.autoReconnect)
                    Toggle("启动 App 后自动开始推流", isOn: $model.autoStartOnLaunch)
                    Toggle("自动推流后自动锁屏", isOn: $model.autoLockAfterStart)
                }
                Section(header: Text("H.264")) {
                    Picker("Profile", selection: $model.profile) {
                        ForEach(ProfileOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .disabled(model.isStreaming)
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
        if abs(z - z.rounded()) < 0.05 && z >= 1 { return "\(Int(z.rounded()))x" }
        return String(format: "%.1fx", Double(z))
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
