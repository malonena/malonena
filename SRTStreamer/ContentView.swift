import SwiftUI

struct ContentView: View {
    @StateObject private var model = StreamModel()

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                PreviewView(view: model.previewView)
                    .background(Color.black)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.status).bold()
                    if model.isStreaming {
                        Text("视频帧: \(model.videoFrames)")
                        Text(String(format: "发送码率: %.2f Mbps", model.sendMbps))
                        Text("已发送: \(model.sentKB) KB")
                    }
                    if let err = model.cameraError {
                        Text(err).foregroundColor(.red)
                    }
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(6)
                .background(Color.black.opacity(0.5))
                .cornerRadius(6)
                .padding(8)
            }
            .frame(maxHeight: .infinity)

            Form {
                Section(header: Text("服务器")) {
                    TextField("SRT 地址", text: $model.urlText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .font(.footnote)
                    HStack {
                        Text("延迟(ms)")
                        TextField("200", text: $model.latencyText).keyboardType(.numberPad)
                    }
                }
                Section(header: Text("视频")) {
                    Picker("分辨率", selection: $model.resolution) {
                        ForEach(ResolutionOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.resolution) { _ in model.applyResolution() }
                    Picker("码率", selection: $model.bitrateMbps) {
                        ForEach(2...6, id: \.self) { Text("\($0)M").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("H.264", selection: $model.profile) {
                        ForEach(ProfileOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(model.isStreaming)
            }
            .frame(height: 300)

            HStack(spacing: 16) {
                Button(action: model.flipCamera) {
                    Label("翻转", systemImage: "camera.rotate")
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.gray.opacity(0.3)).cornerRadius(10)
                }
                Button(action: model.toggle) {
                    Text(model.isStreaming ? "停止推流" : (model.isBusy ? "连接中…" : "开始推流"))
                        .bold().foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(model.isStreaming ? Color.red : Color.blue).cornerRadius(10)
                }
                .disabled(model.isBusy)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .task { await model.setup() }
    }
}
