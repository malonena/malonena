import AVFoundation
import SwiftUI

@main
struct SRTStreamerApp: App {
    init() {
        // 与 HaishinKit 官方 Examples/iOS/AppDelegate.swift 一致
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
