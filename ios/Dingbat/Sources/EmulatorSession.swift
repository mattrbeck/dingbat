import SwiftUI
import AVFoundation
import QuartzCore

/// Owns a running emulation: the CADisplayLink loop, the audio engine, and
/// every call into libdingbat.a. Core calls stay on the main thread; the
/// audio render block only touches the realtime-safe dingbat_audio_* API.
///
/// Pacing: the APU fills a 32768 Hz ring as emulation runs and the
/// AVAudioSourceNode drains it in real time. Each display tick runs frames
/// only while dingbat_audio_ahead() == 0 (bounded), so the audio clock paces
/// emulation; fast-forward drops audio-sync and the cap alone bounds speed.
final class EmulatorSession: NSObject, ObservableObject {

    @Published var image: CGImage?
    @Published var paused = false
    @Published var fastForward = false
    @Published var muted = false
    @Published var sleeping = false
    @Published var fps: Int = 0
    @Published var loadFailed = false
    @Published var stateToast: String?

    private(set) var rom: RomEntry?
    private var link: CADisplayLink?
    private var audio: AudioOutput?
    private var framesThisSecond = 0
    private var fpsWindowStart: CFTimeInterval = 0
    private var pausedForBackground = false

    // MARK: lifecycle

    func start(rom: RomEntry) {
        self.rom = rom
        dingbat_init()
        guard dingbat_load_rom(rom.url.path, nil) == 0 else {
            loadFailed = true
            return
        }
        let audio = AudioOutput()
        audio.start()
        self.audio = audio

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func stop() {
        link?.invalidate()
        link = nil
        audio?.stop()
        audio = nil
        NotificationCenter.default.removeObserver(self)
        dingbat_flush_save()
        saveThumbnail()
    }

    @objc private func appDidEnterBackground() {
        dingbat_flush_save()
        if !paused {
            paused = true
            pausedForBackground = true
        }
    }

    @objc private func appWillEnterForeground() {
        if pausedForBackground {
            paused = false
            pausedForBackground = false
        }
    }

    // MARK: frame loop

    @objc private func tick(_ link: CADisplayLink) {
        guard !paused, !loadFailed else { return }
        var ran = 0
        let cap = fastForward ? 8 : 4
        while dingbat_audio_ahead() == 0 && ran < cap {
            dingbat_run_frame()
            ran += 1
        }
        framesThisSecond += ran
        if ran > 0 && dingbat_frame_static() == 0 {
            image = Self.makeImage()
        }
        sleeping = dingbat_is_stopped() != 0

        let now = link.timestamp
        if fpsWindowStart == 0 { fpsWindowStart = now }
        if now - fpsWindowStart >= 1.0 {
            fps = Int(Double(framesThisSecond) / (now - fpsWindowStart) + 0.5)
            framesThisSecond = 0
            fpsWindowStart = now
        }
    }

    static func makeImage() -> CGImage? {
        guard let ptr = dingbat_framebuffer_rgba() else { return nil }
        let w = Int(dingbat_fb_width())
        let h = Int(dingbat_fb_height())
        let data = Data(bytes: UnsafeRawPointer(ptr), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    // MARK: controls

    func setInput(_ id: Int, _ down: Bool) {
        dingbat_set_input(Int32(id), down ? 1 : 0)
    }

    func togglePause() {
        paused.toggle()
        pausedForBackground = false
        if paused { dingbat_flush_save() }
    }

    func toggleFastForward() {
        fastForward.toggle()
        dingbat_set_fast_forward(fastForward ? 1 : 0)
    }

    func toggleMute() {
        muted.toggle()
        dingbat_set_volume(100, muted ? 1 : 0)
    }

    func reset() {
        _ = dingbat_reset()
        if fastForward { dingbat_set_fast_forward(1) }
        if muted { dingbat_set_volume(100, 1) }
    }

    // MARK: save states

    func saveState() {
        guard let rom else { return }
        let size = dingbat_state_size()
        guard size > 0, let ptr = dingbat_state_data() else { return }
        let data = Data(bytes: ptr, count: Int(size))
        do {
            try RomLibrary.ensureDir(RomLibrary.statesDir)
            try data.write(to: rom.stateURL)
            toast("State saved")
        } catch {
            toast("Save failed")
        }
    }

    func loadState() {
        guard let rom, let data = try? Data(contentsOf: rom.stateURL) else {
            toast("No saved state")
            return
        }
        let ok = data.withUnsafeBytes { buf -> Int32 in
            dingbat_load_state(buf.baseAddress, Int32(buf.count))
        }
        if ok == 1 {
            image = Self.makeImage()
            toast("State loaded")
        } else {
            toast("State rejected")
        }
    }

    private func toast(_ message: String) {
        stateToast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.stateToast == message { self?.stateToast = nil }
        }
    }

    private func saveThumbnail() {
        guard let rom, let image else { return }
        try? RomLibrary.ensureDir(RomLibrary.shotsDir)
        let ui = UIImage(cgImage: image)
        try? ui.pngData()?.write(to: rom.shotURL)
    }
}

/// AVAudioSourceNode pulling float32 stereo at 32768 Hz from the core's ring
/// (the engine resamples). The render block must stay realtime-safe: no
/// allocation, no locks besides the ring's mutex, no Swift calls into the core.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384)

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(dingbat_audio_sample_rate()),
            channels: 2) else { return }

        let scratch = self.scratch
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
            for i in 0..<Int(frameCount) {
                if i < got {
                    left[i] = scratch[2 * i]
                    right[i] = scratch[2 * i + 1]
                } else {
                    left[i] = 0
                    right[i] = 0
                }
            }
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
            if type == .ended {
                try? self?.engine.start()
            }
        }

        try? engine.start()
    }

    func stop() {
        engine.stop()
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        scratch.deallocate()
    }
}
