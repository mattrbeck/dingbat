import AVFoundation
import SwiftUI

/// A DS game's microphone (web ndsMicStart / ndsMicStop): asked for only
/// when the Screens panel's Microphone is turned on, never stored (the app
/// must not open the microphone on its own next time). The input is tapped
/// on its own engine, mixed to mono int16 and pushed at its own rate
/// (dingbat_nds_push_mic, on the main thread), nothing while paused or
/// while Blow is held (Blow owns the queue's rate). The audio session is
/// play-and-record while it listens (AudioOutput.refreshSession).
final class NdsMic: ObservableObject {
    static let shared = NdsMic()

    @Published private(set) var on = false
    /// The live level, 0...1, for the button's fill (web --mic-level).
    @Published private(set) var level: Double = 0

    private var engine: AVAudioEngine?

    func toggle() { if on { stop() } else { start() } }

    func start() {
        guard !on else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    AppModel.shared.toast("Microphone access was refused — hold Blow instead")
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        guard !on, GameSession.shared.isNDS else { return }
        on = true
        AudioOutput.shared.refreshSession()
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail()
            return
        }
        let rate = Int32(format.sampleRate.rounded())
        let chans = Int(format.channelCount)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            guard let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            var out = [Int16](repeating: 0, count: n)
            var sum: Float = 0
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<chans { v += ch[c][i] }
                v /= Float(chans)
                sum += v * v
                out[i] = Int16((max(-1, min(1, v)) * 32767).rounded())
            }
            let lvl = Double(min(1, (sum / Float(max(1, n))).squareRoot() * 4))
            DispatchQueue.main.async {
                guard self.on else { return }
                self.level = lvl
                let s = GameSession.shared
                guard s.isNDS, !s.paused, !NdsState.shared.blowing, dingbat_is_nds() != 0 else { return }
                out.withUnsafeBufferPointer { dingbat_nds_push_mic($0.baseAddress, Int32(n), rate) }
            }
        }
        do {
            try e.start()
            engine = e
        } catch {
            input.removeTap(onBus: 0)
            fail()
        }
    }

    private func fail() {
        on = false
        AudioOutput.shared.refreshSession()
        AppModel.shared.toast("The microphone could not start — hold Blow instead")
    }

    func stop() {
        guard on else { return }
        on = false
        level = 0
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        AudioOutput.shared.refreshSession()
    }
}
