import SwiftUI

struct ContentView: View {
    @StateObject private var model = StreamModel()
    @AppStorage("autoOrientation") private var autoOrientation = true
    @State private var showSettings = false
    @State private var sliderZoom: Double = 1

    private var hasError: Bool {
        model.cameraError != nil || ["失败", "错误", "断开", "无法", "没有", "请把", "未收到"].contains { model.status.contains($0) }
    }
    private var statusColor: Color {
        if hasError { return .red }
        if model.isStreaming { return .green }
        if model.isBusy { return .yellow }
        return .gray
    }
    private var statusText: String {
        if let e = model.cameraError { return e }
        if model.status == "未连接" || model.status == "已停止" { return "待机" }
        return model.status
    }
    private var caption: String {
        let s = model.resolution.size
        var t = "\(autoOrientation ? "自动" : "竖屏") 9:16 · \(model.resolution.rawValue) \(Int(s.width))×\(Int(s.height)) · \(model.fps)fps · \(model.bitrateMbps).0Mbps"
        if model.isStreaming { t += String(format: " · 发送 %.2fMbps", model.sendMbps) }
        return t
    }
    private var zoomPresets: [Double] { model.hasUltraWide ? [0.5, 1.0, 2.0] : [1.0, 2.0] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewView(view: model.previewView).ignoresSafeArea()
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
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .task { await model.setup() }
        .onChange(of: model.zoom) { z in
            if abs(sliderZoom - Double(z)) > 0.001 { sliderZoom = Double(z) }
        }
    }

    private var topInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(hasError ? .red : .white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.55)))

            Text(caption)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.5)))

            HStack(spacing: 8) {
                CapsuleButton(icon: "rotate.right", title: autoOrientation ? "自动" : "竖屏") {
                    autoOrientation.toggle()
                }
                CapsuleButton(icon: "rectangle.on.rectangle", title: model.resolution.rawValue) {
                    model.resolution = (model.resolution == .p720) ? .p1080 : .p720
                    model.applyResolution()
                }
                .disabled(model.isStreaming)
                .opacity(model.isStreaming ? 0.5 : 1)
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
                Slider(value: $sliderZoom, in: (model.hasUltraWide ? 0.5 : 1.0)...10.0, onEditingChanged: { editing in
                    if !editing { model.setZoom(CGFloat(sliderZoom)) }
                })
                .accentColor(.yellow)
                .onChange(of: sliderZoom) { v in
                    // 同一镜头内实时变焦；跨越 1x 切换镜头在松手时进行
                    if (v < 1) == (model.zoom < 1) { model.setZoom(CGFloat(v)) }
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
    let icon: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
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
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
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

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("码率")) {
                    Picker("码率", selection: $model.bitrateMbps) {
                        ForEach(2...6, id: \.self) { Text("\($0)M").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section(header: Text("H.264 Profile")) {
                    Picker("Profile", selection: $model.profile) {
                        ForEach(ProfileOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section(header: Text("帧率")) {
                    Picker("帧率", selection: $model.fps) {
                        ForEach([24, 25, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.fps) { _ in model.applyFrameRate() }
                }
                Section(header: Text("分辨率")) {
                    Picker("分辨率", selection: $model.resolution) {
                        ForEach(ResolutionOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.resolution) { _ in model.applyResolution() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
