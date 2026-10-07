import AVFoundation

/// AVAudioSourceNode pulling float32 stereo at 32768 Hz from the core's ring
/// (the engine resamples). The render block stays realtime-safe: no
/// allocation, no locks besides the ring's mutex, no calls into Nim.
///
/// The analog filter (Settings › Audio, GBA only) is the web's 12 kHz
/// biquad low-pass, Q 0.707: the GBA's output stage and speaker.
final class AudioOutput {
    static let shared = AudioOutput()

    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private var started = false
    private var category: AVAudioSession.Category?

    /// Read by the render thread; written from main. Word-sized flags.
    fileprivate let state = UnsafeMutablePointer<FilterState>.allocate(capacity: 1)

    struct FilterState {
        var enabled: Bool = false
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var x1L: Float = 0, x2L: Float = 0, y1L: Float = 0, y2L: Float = 0
        var x1R: Float = 0, x2R: Float = 0, y1R: Float = 0, y2R: Float = 0
    }

    private init() {
        state.initialize(to: FilterState())
        let fs = Double(dingbat_audio_sample_rate() > 0 ? dingbat_audio_sample_rate() : 32768)
        let w0 = 2 * Double.pi * 12000 / fs
        let alpha = sin(w0) / (2 * 0.707)
        let cw = cos(w0)
        let a0 = 1 + alpha
        state.pointee.b0 = Float((1 - cw) / 2 / a0)
        state.pointee.b1 = Float((1 - cw) / a0)
        state.pointee.b2 = Float((1 - cw) / 2 / a0)
        state.pointee.a1 = Float(-2 * cw / a0)
        state.pointee.a2 = Float((1 - alpha) / a0)
    }

    func setAnalogFilter(_ on: Bool) {
        if state.pointee.enabled != on {
            state.pointee.x1L = 0; state.pointee.x2L = 0; state.pointee.y1L = 0; state.pointee.y2L = 0
            state.pointee.x1R = 0; state.pointee.x2R = 0; state.pointee.y1R = 0; state.pointee.y2R = 0
        }
        state.pointee.enabled = on
    }

    func start() {
        guard node == nil else { return }
        refreshSession()

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(dingbat_audio_sample_rate()),
            channels: 2) else { return }

        let scratch = self.scratch
        let st = self.state
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var frames = Int(frameCount)
            if frames > 8192 { frames = 8192 }
            let got = Int(dingbat_audio_read(scratch, Int32(frames)))
            guard abl.count >= 2,
                  let leftRaw = abl[0].mData, let rightRaw = abl[1].mData else {
                return noErr
            }
            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right = rightRaw.assumingMemoryBound(to: Float.self)
            let f = st.pointee.enabled
            var s = st.pointee
            for i in 0..<Int(frameCount) {
                var l: Float = 0, r: Float = 0
                if i < got { l = scratch[2 * i]; r = scratch[2 * i + 1] }
                if f {
                    let yl = s.b0 * l + s.b1 * s.x1L + s.b2 * s.x2L - s.a1 * s.y1L - s.a2 * s.y2L
                    s.x2L = s.x1L; s.x1L = l; s.y2L = s.y1L; s.y1L = yl
                    let yr = s.b0 * r + s.b1 * s.x1R + s.b2 * s.x2R - s.a1 * s.y1R - s.a2 * s.y2R
                    s.x2R = s.x1R; s.x1R = r; s.y2R = s.y1R; s.y1R = yr
                    l = yl; r = yr
                }
                left[i] = l
                right[i] = r
            }
            if f { st.pointee = s }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.node = node

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended { try? self?.engine.start() }
        }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            try? self?.engine.start()
        }
        started = true
        try? engine.start()
    }

    /// "Play in Silent Mode": the playback category (plays with the ring/
    /// silent switch on, pauses other apps' audio) only while the game can be
    /// heard; ambient (mixes with other apps, follows the switch) whenever
    /// it is paused, muted, at volume 0, or Play in Silent Mode is off.
    func refreshSession() {
        let s = Settings.shared
        let session = GameSession.shared
        let audible = session.game != nil && !session.paused && !s.muted && s.volume > 0
        let want: AVAudioSession.Category = (s.playInSilent && audible) ? .playback : .ambient
        guard want != category else { return }
        category = want
        let av = AVAudioSession.sharedInstance()
        try? av.setCategory(want, mode: .default, options: want == .ambient ? [.mixWithOthers] : [])
        try? av.setActive(true)
        if started && !engine.isRunning { try? engine.start() }
    }
}
