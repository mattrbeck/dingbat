import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

/// "Clip that!" and Record (web "Retroactive clip capture" and "Forward clip
/// recording"): the console's own picture (the framebuffer at 4x: no
/// filters, colour correction, LCD response, shade palette or border) and
/// sound (no enhanced music, audio smoothing or channel mutes) into an MP4.
///
/// A clip re-emulates a past range from the core's clip ring (one state per
/// second plus every frame's inputs) off screen, as fast as the encoder
/// takes it, with nothing timed by a clock: the frames are stamped by the
/// console's own frame rate and the sound is the core's. Record writes what
/// is played, stamped by the wall clock. Main thread only.
final class ClipExporter: ObservableObject {
    static let shared = ClipExporter()

    /// A clip being made: what, and how far along (0...1).
    @Published private(set) var export: (label: String, progress: Double)?
    @Published private(set) var recording = false

    /// Both consoles run 70224 dots a frame at 4 MiHz.
    static let frameTime = CMTime(value: 70224, timescale: 4_194_304)
    static let videoBitrate = 8_000_000
    static let audioRate: Double = 48000
    static let keyEvery = 120

    private var writer: Writer?
    private var gen = 0
    private var wasPaused = false
    private var recTimer: Timer?
    private var recStart: CFTimeInterval = 0

    // MARK: Clip that!

    /// Replay [startAgo, endAgo) frames before now into a video.
    func exportClip(startAgo: Int, endAgo: Int, slug: String, label: String) {
        let session = GameSession.shared
        guard export == nil, let game = session.game else { return }
        let frames = Int(dingbat_clip_begin(Int32(startAgo), Int32(endAgo)))
        guard frames > 0 else {
            AppModel.shared.toast("Not enough gameplay history yet")
            return
        }
        let w = Int(dingbat_fb_width()) * 4, h = Int(dingbat_fb_height()) * 4
        let url = Self.outputURL(game: game, slug: slug)
        guard let writer = Writer(url: url, width: w, height: h, realtime: false) else {
            dingbat_clip_abort()
            AppModel.shared.toast("Couldn't start the recorder")
            return
        }
        self.writer = writer
        gen += 1
        let myGen = gen
        // The player's pause, not the one the range sheet took.
        wasPaused = session.paused && !AppModel.shared.sheetPausedGame
        session.holdForClip(true)
        setNativeAudio(true)
        dingbat_audio_capture_clear()
        dingbat_audio_set_mode(1)
        export = (label, 0)
        var done = 0
        var lastProgress = CACurrentMediaTime()
        // Frames in ~12 ms batches, then a yield so the panel repaints and
        // Cancel is heard; the writer's readiness is the brake.
        var replayed = false
        func batch() {
            guard myGen == self.gen, self.export != nil else { return }
            let t0 = CACurrentMediaTime()
            while CACurrentMediaTime() - t0 < 0.012 {
                // The writer takes a picture only once the sound is ahead of
                // it, and the replay makes both together: so the replay runs
                // ahead, its pictures queued (raw, 77 KB each), and the
                // queue drains as the sound lets it.
                let before = writer.queuedFrames
                writer.drainVideo()
                writer.appendCapturedAudio()
                if writer.queuedFrames < before { lastProgress = CACurrentMediaTime() }
                if replayed {
                    // No more sound is coming: closing its track lets the
                    // last pictures through.
                    if dingbat_audio_captured_frames() == 0 { writer.endAudio() }
                    if writer.queuedFrames == 0 { break }
                    if !writer.videoReady { break }
                    continue
                }
                if writer.queuedFrames >= 120 { break }
                if Int(dingbat_clip_tick()) < 0 {
                    replayed = true
                    // Back to the live game now; the queue finishes the file.
                    writer.appendCapturedAudio()
                    dingbat_audio_set_mode(recording ? 3 : 0)
                    continue
                }
                writer.queueFrame(at: CMTimeMultiply(Self.frameTime, multiplier: Int32(done)))
                done += 1
                lastProgress = CACurrentMediaTime()
            }
            if CACurrentMediaTime() - lastProgress > 5 {
                Self.debug("stalled at \(done)/\(frames): \(writer.statusText)")
                dingbat_clip_abort()
                finish(save: false, gen: myGen, slug: slug)
                AppModel.shared.toast("Couldn't record the clip")
                return
            }
            export = (label, 0.95 * Double(done - writer.queuedFrames) / Double(max(1, frames)))
            if !replayed || writer.queuedFrames > 0 {
                DispatchQueue.main.async(execute: batch)
                return
            }
            writer.appendCapturedAudio()
            Self.debug("replayed \(done)/\(frames) frames")
            finish(save: true, gen: myGen, slug: slug)
        }
        DispatchQueue.main.async(execute: batch)
    }

    func cancelExport() {
        guard export != nil else { return }
        dingbat_clip_abort()
        finish(save: false, gen: gen, slug: "")
        AppModel.shared.toast("Clip cancelled")
    }

    private func finish(save: Bool, gen myGen: Int, slug: String) {
        guard myGen == gen, let writer else { return }
        gen += 1
        self.writer = nil
        dingbat_audio_set_mode(recording ? 3 : 0)
        dingbat_audio_capture_clear()
        if !recording { setNativeAudio(false) }
        GameSession.shared.holdForClip(false)
        if AppModel.shared.screen == .play && AppModel.shared.sheet == nil {
            GameSession.shared.setPaused(wasPaused)
        }
        GameRenderer.shared.present()
        guard save else {
            writer.cancel()
            export = nil
            return
        }
        export = (export?.label ?? "", 0.98)
        writer.finish { [weak self] url in
            DispatchQueue.main.async {
                self?.export = nil
                Self.deliver(url, empty: "The clip came out empty")
            }
        }
    }

    // MARK: Record

    /// Record from now until Stop (or five minutes).
    func toggleRecording() {
        if recording { stopRecording(); return }
        guard export == nil, let game = GameSession.shared.game else { return }
        let w = Int(dingbat_fb_width()) * 4, h = Int(dingbat_fb_height()) * 4
        guard let writer = Writer(url: Self.outputURL(game: game, slug: "clip"), width: w, height: h, realtime: true) else {
            AppModel.shared.toast("Couldn't start the recorder")
            return
        }
        self.writer = writer
        recording = true
        recStart = CACurrentMediaTime()
        setNativeAudio(true)
        dingbat_audio_capture_clear()
        dingbat_audio_set_mode(3)
        recTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopRecording() }
        }
        AppModel.shared.toast("Recording — pick Stop Recording to finish")
    }

    /// Each display tick that ran frames while recording (GameSession).
    func recordTick() {
        guard recording, let writer, export == nil else { return }
        let t = CMTime(seconds: CACurrentMediaTime() - recStart, preferredTimescale: 60000)
        if writer.videoReady { writer.appendFrame(at: t, dropLate: true) }
        writer.appendCapturedAudio(notBefore: t)
    }

    func stopRecording() {
        guard recording, let writer else { return }
        recording = false
        recTimer?.invalidate()
        recTimer = nil
        self.writer = nil
        dingbat_audio_set_mode(0)
        dingbat_audio_capture_clear()
        setNativeAudio(false)
        writer.finish { url in
            DispatchQueue.main.async { Self.deliver(url, empty: "The recording came out empty") }
        }
    }

    /// A game switch or close ends both.
    func gameLeaving() {
        if export != nil { cancelExport() }
        if recording { stopRecording() }
    }

    // MARK: helpers

    /// The console's own sound while recording: the player's mix comes back
    /// after (web setNativeAudio).
    private func setNativeAudio(_ on: Bool) {
        if on {
            dingbat_set_mp2k_hle(0)
            dingbat_set_fifo_interp(0)
            dingbat_set_channel_mutes(0)
            dingbat_set_volume(100, 0)
        } else {
            Settings.shared.apply()
            GameSession.shared.applyHle()
        }
    }

    private static func outputURL(game: RomEntry, slug: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let name = "\(game.stem)-\(slug)-\(f.string(from: Date())).mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Debug builds: what the export did, on stderr (`simctl launch --stderr`).
    static func debug(_ s: String) {
        #if DEBUG
        FileHandle.standardError.write(Data(("clip: " + s + "\n").utf8))
        #endif
    }

    private static func deliver(_ url: URL?, empty: String) {
        debug("delivered \(url?.lastPathComponent ?? "nothing")")
        guard let url, let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              n.intValue > 0 else {
            AppModel.shared.toast(empty)
            return
        }
        AppModel.shared.toast("Clip saved")
        Share.present([url])
    }
}

/// One MP4: H.264 frames from the core's framebuffer at 4x, AAC from its
/// captured samples (32768 Hz, resampled to 48 kHz).
private final class Writer {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput
    private let width: Int, height: Int
    private let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 32768, channels: 2, interleaved: false)!
    private let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: ClipExporter.audioRate, channels: 2, interleaved: false)!
    private let converter: AVAudioConverter
    private var audioFrames: Int64 = 0          // samples written at 48 kHz
    private var lastVideo = CMTime.negativeInfinity
    private var started = false
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 65536 * 2)

    init?(url: URL, width: Int, height: Int, realtime: Bool) {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4),
              let conv = AVAudioConverter(from: srcFormat, to: dstFormat) else { return nil }
        writer = w
        converter = conv
        self.width = width
        self.height = height
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: ClipExporter.videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: ClipExporter.keyEvery,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = realtime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: ClipExporter.audioRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ])
        audio.expectsMediaDataInRealTime = realtime
        guard w.canAdd(video), w.canAdd(audio) else { return nil }
        w.add(video)
        w.add(audio)
        guard w.startWriting() else { return nil }
        w.startSession(atSourceTime: .zero)
        started = true
    }

    deinit { scratch.deallocate() }

    var videoReady: Bool { video.isReadyForMoreMediaData }

    /// Pictures waiting for the encoder: the raw BGR555 framebuffer and its time.
    private var queue: [(Data, CMTime)] = []
    var queuedFrames: Int { queue.count }

    func queueFrame(at t: CMTime) {
        guard let fb = dingbat_framebuffer() else { return }
        queue.append((Data(bytes: fb, count: (width / 4) * (height / 4) * 2), t))
    }

    func drainVideo() {
        while !queue.isEmpty && video.isReadyForMoreMediaData {
            let (data, t) = queue.removeFirst()
            data.withUnsafeBytes { raw in
                appendFrame(from: raw.bindMemory(to: UInt16.self).baseAddress!, at: t)
            }
        }
    }

    /// The core's framebuffer, raw (the console's own colours), 4x nearest.
    func appendFrame(at t: CMTime, dropLate: Bool = false) {
        guard let fb = dingbat_framebuffer() else { return }
        appendFrame(from: fb, at: t)
    }

    private func appendFrame(from fb: UnsafePointer<UInt16>, at t: CMTime) {
        guard started, let pool = adaptor.pixelBufferPool else { return }
        if t <= lastVideo { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt32.self)
        let stride = CVPixelBufferGetBytesPerRow(pb) / 4
        let fw = width / 4, fh = height / 4
        for y in 0..<fh {
            let row = base + (y * 4) * stride
            for x in 0..<fw {
                let v = UInt32(fb[y * fw + x])
                let r = (v & 31) * 255 / 31, g = ((v >> 5) & 31) * 255 / 31, b = ((v >> 10) & 31) * 255 / 31
                let px = 0xFF00_0000 | (r << 16) | (g << 8) | b   // BGRA in memory
                let o = x * 4
                row[o] = px; row[o + 1] = px; row[o + 2] = px; row[o + 3] = px
            }
            for k in 1..<4 { memcpy(row + k * stride, row, fw * 4 * 4) }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if adaptor.append(pb, withPresentationTime: t) { lastVideo = t }
    }

    /// Everything captured since the last call, resampled and encoded.
    /// `notBefore`: Record's wall clock (a pause leaves a gap, not a drift).
    func appendCapturedAudio(notBefore: CMTime? = nil) {
        guard started, !audioEnded else { return }
        // Taken only while the encoder wants it: what waits stays captured.
        while audio.isReadyForMoreMediaData {
            let n = Int(dingbat_audio_capture_take(scratch, 65536))
            if n == 0 { return }
            guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
            src.frameLength = AVAudioFrameCount(n)
            let l = src.floatChannelData![0], r = src.floatChannelData![1]
            for i in 0..<n { l[i] = scratch[2 * i]; r[i] = scratch[2 * i + 1] }
            let cap = AVAudioFrameCount(Double(n) * ClipExporter.audioRate / 32768 + 64)
            guard let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: dst, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return src
            }
            guard dst.frameLength > 0 else { continue }
            if let nb = notBefore {
                let want = Int64(nb.seconds * ClipExporter.audioRate) - Int64(dst.frameLength)
                if want > audioFrames { audioFrames = want }
            }
            guard let sb = Self.sampleBuffer(dst, at: audioFrames) else { return }
            audio.append(sb)
            audioFrames += Int64(dst.frameLength)
        }
    }

    private static func sampleBuffer(_ buf: AVAudioPCMBuffer, at frame: Int64) -> CMSampleBuffer? {
        let asbd = buf.format.streamDescription
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(ClipExporter.audioRate)),
                                        presentationTimeStamp: CMTime(value: frame, timescale: CMTimeScale(ClipExporter.audioRate)),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: fmt, sampleCount: CMItemCount(buf.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: buf.audioBufferList) == noErr else { return nil }
        return sb
    }

    private var audioEnded = false
    func endAudio() {
        guard !audioEnded else { return }
        audioEnded = true
        audio.markAsFinished()
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        guard started else { done(nil); return }
        video.markAsFinished()
        endAudio()
        writer.finishWriting { [writer] in
            if writer.status != .completed { ClipExporter.debug("finish failed: \(String(describing: writer.error))") }
            done(writer.status == .completed ? writer.outputURL : nil)
        }
    }

    var statusText: String { "status \(writer.status.rawValue) \(String(describing: writer.error)) v\(video.isReadyForMoreMediaData) a\(audio.isReadyForMoreMediaData) wrote \(audioFrames) captured \(dingbat_audio_captured_frames()) mode \(dingbat_audio_get_mode())" }

    func cancel() {
        writer.cancelWriting()
    }
}
