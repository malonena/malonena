import AVFoundation
import Foundation
import HaishinKit

/// 作为 SRTStream 的输出观察者，统计进入编码器的视频帧数。
/// SRTStream.append(_:) 在收到未压缩视频帧时会回调 outputs。
final class FrameCounter: HKStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _videoFrames: Int = 0
    private var _audioBuffers: Int = 0

    var videoFrames: Int { lock.lock(); defer { lock.unlock() }; return _videoFrames }
    var audioBuffers: Int { lock.lock(); defer { lock.unlock() }; return _audioBuffers }

    func reset() {
        lock.lock(); _videoFrames = 0; _audioBuffers = 0; lock.unlock()
    }

    func stream(_ stream: some HKStream, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        lock.lock(); _audioBuffers += 1; lock.unlock()
    }

    func stream(_ stream: some HKStream, didOutput video: CMSampleBuffer) {
        lock.lock(); _videoFrames += 1; lock.unlock()
    }
}
