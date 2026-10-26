import AVFoundation
import Foundation
import HaishinKit

/// 作为 SRTStream 的输出观察者，统计进入编码器的视频帧数。
/// SRTStream.append(_:) 在收到未压缩视频帧时会回调 outputs。
final class FrameCounter: HKStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _videoFrames: Int = 0
    private var _audioBuffers: Int = 0
    private var _level: Float = 0

    /// 最近音频峰值 0..1（读取后衰减）
    var audioLevel: Float { lock.lock(); defer { lock.unlock() }; let v = _level; _level *= 0.6; return v }

    var videoFrames: Int { lock.lock(); defer { lock.unlock() }; return _videoFrames }
    var audioBuffers: Int { lock.lock(); defer { lock.unlock() }; return _audioBuffers }

    func reset() {
        lock.lock(); _videoFrames = 0; _audioBuffers = 0; lock.unlock()
    }

    func stream(_ stream: some HKStream, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        var peak: Float = 0
        if let pcm = audio as? AVAudioPCMBuffer {
            let n = Int(pcm.frameLength)
            if let f = pcm.floatChannelData {
                for c in 0..<Int(pcm.format.channelCount) { for i in 0..<n { peak = max(peak, abs(f[c][i])) } }
            } else if let d = pcm.int16ChannelData {
                for c in 0..<Int(pcm.format.channelCount) { for i in 0..<n { peak = max(peak, abs(Float(d[c][i]) / 32768)) } }
            } else if let d = pcm.int32ChannelData {
                for c in 0..<Int(pcm.format.channelCount) { for i in 0..<n { peak = max(peak, abs(Float(d[c][i]) / 2147483648)) } }
            }
        }
        lock.lock(); _audioBuffers += 1; _level = max(_level, min(peak, 1)); lock.unlock()
    }

    func stream(_ stream: some HKStream, didOutput video: CMSampleBuffer) {
        lock.lock(); _videoFrames += 1; lock.unlock()
    }
}
