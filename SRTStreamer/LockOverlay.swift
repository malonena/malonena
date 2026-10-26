import SwiftUI
import UIKit

struct LockOverlay: View {
    @ObservedObject var model: StreamModel
    @Binding var isLocked: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var hintVisible = true
    @State private var progress: CGFloat = 0
    @State private var pressing = false
    @State private var hideWork: DispatchWorkItem?

    private var statusLine: String {
        if let e = model.cameraError { return "错误 · \(e)" }
        if model.isStreaming { return String(format: "推流中 · %.2f Mbps", model.sendMbps) }
        return model.status
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Text("推流中 · 长按 2 秒解锁").font(.footnote)
                Text(statusLine).font(.caption2.monospacedDigit()).lineLimit(2)
            }
            .foregroundColor(Color.gray.opacity(0.6))
            .opacity(hintVisible || pressing ? 1 : 0.04)
            .animation(.easeInOut(duration: 0.6), value: hintVisible)
            if pressing {
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.gray.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 80, height: 80)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showHint() }
        .onLongPressGesture(minimumDuration: 2, maximumDistance: 50, pressing: { p in
            pressing = p
            if p {
                showHint()
                progress = 0
                withAnimation(.linear(duration: 2)) { progress = 1 }
            } else {
                withAnimation(.none) { progress = 0 }
            }
        }, perform: { unlock() })
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.01
            UIApplication.shared.isIdleTimerDisabled = true
            showHint()
        }
        .onDisappear { UIScreen.main.brightness = savedBrightness }
        .onChange(of: scenePhase) { ph in
            if ph == .active {
                UIScreen.main.brightness = 0.01
                UIApplication.shared.isIdleTimerDisabled = true
                showHint()
            } else {
                UIScreen.main.brightness = savedBrightness
            }
        }
    }

    private func showHint() {
        hintVisible = true
        hideWork?.cancel()
        let w = DispatchWorkItem { hintVisible = false }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func unlock() {
        pressing = false
        UIScreen.main.brightness = savedBrightness
        isLocked = false
    }
}
