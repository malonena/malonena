import AVFoundation
import SwiftUI

enum StabilizationOption: String, CaseIterable, Identifiable {
    case off = "关", standard = "标准", cinematic = "电影级", auto = "自动"
    var id: String { rawValue }
    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .auto: return .auto
        }
    }
}

@MainActor
final class CameraControl: ObservableObject {
    var device: AVCaptureDevice? { didSet { refreshRanges() } }
    var position: AVCaptureDevice.Position = .back

    @Published var manualExposure = false { didSet { applyExposure() } }
    @Published var iso: Float = 100
    @Published var shutterDenom: Double = 60 // 1/x 秒
    @Published var ev: Float = 0
    @Published var wbLocked = false { didSet { applyWB() } }
    @Published var temperature: Float = 5000
    @Published var manualFocus = false { didSet { applyFocus() } }
    @Published var lensPosition: Float = 0.5
    @Published var torch = false { didSet { applyTorch() } }
    @Published var stabilization: StabilizationOption = StabilizationOption(rawValue: UserDefaults.standard.string(forKey: "stab") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(stabilization.rawValue, forKey: "stab") }
    }

    @Published var minISO: Float = 50
    @Published var maxISO: Float = 1600
    @Published var minShutter: Double = 30
    @Published var maxShutter: Double = 8000
    @Published var minEV: Float = -2
    @Published var maxEV: Float = 2
    @Published var hasTorch = false

    private func refreshRanges() {
        guard let d = device else { return }
        let f = d.activeFormat
        minISO = f.minISO; maxISO = max(f.maxISO, f.minISO + 1)
        iso = min(max(iso, minISO), maxISO)
        let maxDur = CMTimeGetSeconds(f.maxExposureDuration)
        let minDur = CMTimeGetSeconds(f.minExposureDuration)
        minShutter = max(30, maxDur > 0 ? 1 / maxDur : 30)
        maxShutter = min(8000, minDur > 0 ? 1 / minDur : 8000)
        if maxShutter <= minShutter { maxShutter = minShutter + 1 }
        shutterDenom = min(max(shutterDenom, minShutter), maxShutter)
        minEV = max(d.minExposureTargetBias, -3); maxEV = min(d.maxExposureTargetBias, 3)
        hasTorch = d.hasTorch && d.isTorchAvailable
    }

    private func config(_ block: (AVCaptureDevice) -> Void) {
        guard let d = device else { return }
        do { try d.lockForConfiguration(); block(d); d.unlockForConfiguration() } catch {}
    }

    func reapply() {
        refreshRanges()
        applyExposure(); applyWB(); applyFocus(); applyTorch()
    }

    func applyExposure() {
        config { d in
            if manualExposure, d.isExposureModeSupported(.custom) {
                let isoV = min(max(iso, d.activeFormat.minISO), d.activeFormat.maxISO)
                var dur = CMTime(seconds: 1 / shutterDenom, preferredTimescale: 1_000_000)
                if CMTimeCompare(dur, d.activeFormat.minExposureDuration) < 0 { dur = d.activeFormat.minExposureDuration }
                if CMTimeCompare(dur, d.activeFormat.maxExposureDuration) > 0 { dur = d.activeFormat.maxExposureDuration }
                d.setExposureModeCustom(duration: dur, iso: isoV, completionHandler: nil)
            } else {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                d.setExposureTargetBias(min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias), completionHandler: nil)
            }
        }
    }

    func applyWB() {
        config { d in
            if wbLocked, d.isWhiteBalanceModeSupported(.locked) {
                var g = d.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0))
                let m = d.maxWhiteBalanceGain
                g.redGain = min(max(g.redGain, 1), m)
                g.greenGain = min(max(g.greenGain, 1), m)
                g.blueGain = min(max(g.blueGain, 1), m)
                d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
            } else if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    func applyFocus() {
        config { d in
            if manualFocus, d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil)
            } else if d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusMode = .continuousAutoFocus
            }
        }
    }

    func applyTorch() {
        config { d in
            guard d.hasTorch, d.isTorchAvailable else { return }
            let m: AVCaptureDevice.TorchMode = torch ? .on : .off
            if d.isTorchModeSupported(m) { d.torchMode = m }
        }
    }

    /// 点击对焦/测光；point 为视图内归一化坐标(0..1)，uiPortrait 表示预览为竖屏
    func focus(at p: CGPoint) {
        var poi = CGPoint(x: p.y, y: 1 - p.x)
        if position == .front { poi.y = p.x }
        config { d in
            if !manualFocus, d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = poi
                if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
            }
            if !manualExposure, d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = poi
                if d.isExposureModeSupported(.autoExpose) { d.exposureMode = .autoExpose }
            }
            d.isSubjectAreaChangeMonitoringEnabled = true
        }
    }
}

struct CameraPanel: View {
    @ObservedObject var cam: CameraControl
    var onStab: (StabilizationOption) -> Void
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("曝光", selection: $cam.manualExposure) { Text("自动曝光").tag(false); Text("手动曝光").tag(true) }
                .pickerStyle(.segmented)
            if cam.manualExposure {
                row("ISO \(Int(cam.iso))") {
                    Slider(value: $cam.iso, in: cam.minISO...cam.maxISO).onChange(of: cam.iso) { _ in cam.applyExposure() }
                }
                row("快门 1/\(Int(cam.shutterDenom))") {
                    Slider(value: $cam.shutterDenom, in: cam.minShutter...cam.maxShutter).onChange(of: cam.shutterDenom) { _ in cam.applyExposure() }
                }
            } else {
                row(String(format: "EV %+.1f", cam.ev)) {
                    Slider(value: $cam.ev, in: cam.minEV...max(cam.maxEV, cam.minEV + 0.1)).onChange(of: cam.ev) { _ in cam.applyExposure() }
                }
            }
            Picker("白平衡", selection: $cam.wbLocked) { Text("白平衡自动").tag(false); Text("白平衡锁定").tag(true) }
                .pickerStyle(.segmented)
            if cam.wbLocked {
                row("\(Int(cam.temperature))K") {
                    Slider(value: $cam.temperature, in: 2500...8000).onChange(of: cam.temperature) { _ in cam.applyWB() }
                }
            }
            Picker("对焦", selection: $cam.manualFocus) { Text("自动对焦").tag(false); Text("手动对焦").tag(true) }
                .pickerStyle(.segmented)
            if cam.manualFocus {
                row(String(format: "焦距 %.2f", cam.lensPosition)) {
                    Slider(value: $cam.lensPosition, in: 0...1).onChange(of: cam.lensPosition) { _ in cam.applyFocus() }
                }
            }
            HStack {
                if cam.hasTorch { Toggle("手电筒", isOn: $cam.torch).fixedSize() }
                Spacer()
                Text("防抖").font(.footnote)
                Picker("防抖", selection: Binding(get: { cam.stabilization }, set: { onStab($0) })) {
                    ForEach(StabilizationOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
        .font(.footnote)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack {
            Text(label).font(.caption.monospacedDigit()).frame(width: 90, alignment: .leading)
            c()
        }
    }
}
