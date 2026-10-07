import QuartzCore
import SwiftUI
import UIKit

/// The running game: the CADisplayLink loop and every call into
/// libdingbat.a that is about playing (web/index.js tick, loadRom, the speed
/// flags, rewind, save states, sessions). Core calls stay on the main thread;
/// the audio render block only touches the realtime-safe dingbat_audio_* API.
///
/// Pacing: the display clock, as the web paces by requestAnimationFrame.
/// Each tick owes frames for the time since the last one; on a 60 Hz display
/// (or a multiple) the game runs at exactly 60 frames a second, one per
/// refresh, 0.46% above the GBA's 59.73 so no refresh repeats or skips a
/// frame. The audio reader absorbs the difference between the two clocks by
/// resampling a hair (dingbat_ios_audio.c). 2x halves the samples per frame
/// and slow motion doubles them, so the same rule runs both. Fast-forward
/// runs frames for most of each display interval and plays what it can.
final class GameSession: NSObject, ObservableObject {
    static let shared = GameSession()

    enum Speed { case normal, fastForward, double, slow }

    @Published private(set) var game: RomEntry?
    @Published private(set) var paused = false
    @Published private(set) var speed: Speed = .normal
    @Published private(set) var rewinding = false
    @Published private(set) var fps: Int = 0
    /// web: the fps readout shows only when the count is not what the mode
    /// expects (always while fast-forwarding).
    @Published private(set) var fpsUnusual = false
    @Published private(set) var sleeping = false
    @Published private(set) var isGB = false
    @Published private(set) var mp2kAvailable = false
    @Published private(set) var hleActive = false
    /// Settings › Audio's HLE switched off for this game only (the top-bar
    /// note); never saved.
    @Published var hleSessionOff = false
    @Published private(set) var tiltKind: Int = 0
    @Published private(set) var hasCamera = false
    @Published private(set) var rumbling = false
    /// The presented picture's size in native pixels (256x224 once an SGB
    /// border arrives). Published only when it changes: a per-frame value
    /// here would rebuild every view observing the session 60 times a second.
    @Published private(set) var outSize = CGSize(width: 240, height: 160)
    /// Inputs currently held, by id (touch, controller and hardware keys
    /// merged), for the input display.
    @Published private(set) var held: Set<Int> = []

    private var link: CADisplayLink?
    private var framesThisSecond = 0
    private var fpsWindowStart: CFTimeInterval = 0
    private var pausedForBackground = false
    private var lastRewindPop: CFTimeInterval = 0
    private var playTime: CFTimeInterval = 0          // seconds run since the last checkpoint
    private var shotTime: CFTimeInterval = 0          // seconds run since the last library picture
    private var saveCheckTime: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var frameDebt: Double = 0                 // frames owed to the display clock
    private var sources: [String: Set<Int>] = [:]     // held inputs per source ("touch", "pad"...)
    /// Whether the game in memory moved since its last session snapshot
    /// (web sessionMoved): a game sitting paused takes no new snapshot.
    private(set) var sessionMoved = true
    private var lastSaveSig: String?
    private var rumbleWasOn = false

    /// Hooks the app installs (haptics, printer gallery, controllers).
    var onRumble: ((Bool) -> Void)?
    var onPrint: ((UIImage) -> Void)?
    var onTick: (() -> Void)?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification, object: nil)
    }

    var biosPath: String? {
        guard let g = game else { return nil }
        let url = g.isGBA ? RomLibrary.gbaBiosURL : RomLibrary.gbcBootromURL
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    // MARK: open / close

    enum OpenResult: Equatable { case ok, failed, resumed, savedSince, resumeRejected(String) }

    /// Boot a game. `resume` puts its session back in during the boot when
    /// one still counts (web launchRom {resume}); otherwise it boots from the
    /// in-game save.
    @discardableResult
    func open(_ entry: RomEntry, resume: Bool) -> OpenResult {
        ClipExporter.shared.gameLeaving()
        NetLink.shared.shutdown()
        if game != nil { leaveGame() }
        dingbat_init()
        let bios = entry.isGBA ? RomLibrary.gbaBiosURL : RomLibrary.gbcBootromURL
        let biosArg = FileManager.default.fileExists(atPath: bios.path) ? bios.path : nil
        let path = RomLibrary.shared.prepareCoreLink(entry)?.path ?? entry.url.path
        let rc = biosArg.map { dingbat_load_rom(path, $0) } ?? dingbat_load_rom(path, nil)
        guard rc == 0 else {
            // The old game was already left; nothing of it may stay loaded
            // (a later flush would write its battery over this one's files).
            dingbat_unload(1)
            stopLink()
            game = nil
            paused = false
            clearInputs()
            UIApplication.shared.isIdleTimerDisabled = false
            AudioOutput.shared.refreshSession()
            return .failed
        }
        game = entry
        isGB = dingbat_is_gb() != 0
        hleSessionOff = false
        applyHle()
        sessionMoved = true
        speed = .normal
        dingbat_set_fast_forward(0); dingbat_set_turbo(0); dingbat_set_slowmo(0)
        rewinding = false
        playTime = 0
        shotTime = 0
        lastSaveSig = RomLibrary.currentSaveSig(entry)
        lastFrameSig = nil
        RomLibrary.shared.touch(entry)
        RomLibrary.shared.noteRomSize(entry.fileName, entry.bytes)
        CheatStore.restore(for: entry)
        tiltKind = Int(dingbat_cart_has_tilt())
        hasCamera = dingbat_cart_has_camera() != 0
        var result = OpenResult.ok
        if resume {
            if let s = RomLibrary.shared.resumableSession(entry) {
                if let why = apply(state: s.bytes, keepRewind: false) {
                    result = .resumeRejected(why)
                } else {
                    result = .resumed
                    sessionMoved = false
                }
            } else if FileManager.default.fileExists(atPath: entry.sessionURL.path) {
                result = .savedSince
            }
        }
        paused = false
        AudioOutput.shared.start()
        AudioOutput.shared.setAnalogFilter(Settings.shared.analogFilter && entry.isGBA)
        AudioOutput.shared.refreshSession()
        startLink()
        GameRenderer.shared.present()
        UIApplication.shared.isIdleTimerDisabled = true
        return result
    }

    /// Leave the game in memory for another (web: a switch): snapshot the
    /// session, store the picture, flush the save.
    private func leaveGame() {
        persistSession()
        storeLastFrame()
        dingbat_flush_save()
    }

    /// Close: the session and picture are kept, the core goes (web
    /// unloadGame). The hero turns to closed.
    func close() {
        guard game != nil else { return }
        ClipExporter.shared.gameLeaving()
        NetLink.shared.shutdown()
        leaveGame()
        stopLink()
        dingbat_unload(1)
        game = nil
        paused = false
        speed = .normal
        rewinding = false
        clearInputs()
        UIApplication.shared.isIdleTimerDisabled = false
        AudioOutput.shared.refreshSession()
    }

    /// Let the game in memory go with nothing of it written: no session, no
    /// picture, no battery flush (Drive hand-off: another device's newer
    /// save and session land in its place).
    func discard() {
        guard game != nil else { return }
        ClipExporter.shared.gameLeaving()
        NetLink.shared.shutdown()
        stopLink()
        dingbat_unload(0)
        game = nil
        paused = false
        speed = .normal
        rewinding = false
        clearInputs()
        UIApplication.shared.isIdleTimerDisabled = false
        AudioOutput.shared.refreshSession()
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    // MARK: lifecycle

    @objc private func appDidEnterBackground() {
        guard game != nil else { return }
        persistSession()
        storeLastFrame()
        dingbat_flush_save()
        if !paused {
            setPaused(true)
            pausedForBackground = true
        }
    }

    @objc private func appWillEnterForeground() {
        if pausedForBackground {
            pausedForBackground = false
            if AppModel.shared.screen == .play { setPaused(false) }
        }
    }

    @objc private func appWillTerminate() {
        guard game != nil else { return }
        persistSession()
        dingbat_flush_save()
    }

    // MARK: frame loop

    /// A clip's replay owns the core: no frames of the live game meanwhile.
    private(set) var clipHold = false
    func holdForClip(_ on: Bool) {
        clipHold = on
        if !on { lastTick = 0 }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard game != nil, !clipHold else { return }
        let now = link.timestamp
        let dt = lastTick == 0 ? 0 : min(now - lastTick, 0.25)
        lastTick = now
        if paused {
            fpsAccount(now, ran: 0)
            return
        }
        var ran = 0
        if rewinding {
            // ~30 snapshots a second (10 frames each, ~5x realtime backward);
            // the pop presents the frame itself and queues no audio.
            if now - lastRewindPop >= 0.033 {
                lastRewindPop = now
                if dingbat_rewind_pop() != 0 {
                    sessionMoved = true
                    present()
                }
            }
            fpsAccount(now, ran: 0)
            return
        }
        if NetLink.shared.linked {
            ran = linkedFrames(link, dt: dt)
            if ran > 0 {
                sessionMoved = true
                saveCheckTime += dt
                present()
                if saveCheckTime >= 1 {
                    saveCheckTime = 0
                    checkSaveChanged()
                }
            }
            watchLinkIdle(now)
            fpsAccount(now, ran: ran)
            onTick?()
            return
        }
        switch speed {
        case .fastForward:
            // As many frames as fit in most of this display interval.
            let budget = max(0.004, link.targetTimestamp - CACurrentMediaTime() - 0.003)
            let t0 = CACurrentMediaTime()
            repeat {
                dingbat_run_frame()
                ran += 1
            } while CACurrentMediaTime() - t0 < budget && ran < 40
        case .normal, .double, .slow:
            let ahead = speed == .normal ? Settings.shared.runahead : 0
            let owed = framesOwed(link, dt: dt)
            for _ in 0..<owed {
                if ahead > 0 { dingbat_run_frame_ahead(Int32(ahead)) } else { dingbat_run_frame() }
                ran += 1
            }
            keepAudioAlive()
        }
        if ran > 0 {
            sessionMoved = true
            playTime += dt
            shotTime += dt
            saveCheckTime += dt
            if dingbat_frame_static() == 0 { present() }
            ClipExporter.shared.recordTick()
            pollPeripherals()
            // Checkpoint: the session again every minute of play, so an app
            // the system kills in the background (or a crash) resumes about
            // a minute back (web CHECKPOINT_PLAY_MS).
            if playTime >= 60 {
                playTime = 0
                persistSession()
            }
            if shotTime >= 60 {
                shotTime = 0
                storeLastFrame()
            }
            if saveCheckTime >= 1 {
                saveCheckTime = 0
                checkSaveChanged()
            }
        }
        sleeping = dingbat_is_stopped() != 0
        fpsAccount(now, ran: ran)
        onTick?()
    }

    /// Frames this display tick owes (web: the RAF accumulator). Rounded,
    /// not floored, so a refresh that lands a hair early or late still runs
    /// its one frame; a missed refresh is made up on the next.
    private func framesOwed(_ link: CADisplayLink, dt: CFTimeInterval) -> Int {
        let period = link.targetTimestamp - link.timestamp
        let hz = period > 0 ? 1 / period : 60
        let k = (hz / 60).rounded()
        // A display at a multiple of 60 Hz: one frame per refresh, exactly.
        let base = k >= 1 && abs(hz / 60 - k) < 0.03 ? 60.0 : 59.7275
        let mult = speed == .double ? 2.0 : speed == .slow ? 0.5 : 1.0
        let cap = speed == .double ? 8 : 4
        frameDebt += dt * base * mult
        let n = max(0, min(cap, Int(frameDebt.rounded())))
        frameDebt = min(1, max(-1, frameDebt - Double(n)))
        return n
    }

    /// No audio engine to drain the ring (stopped by an interruption that
    /// never reported its end): drop what queued so it cannot back up, and
    /// keep trying the engine.
    private func keepAudioAlive() {
        guard !AudioOutput.shared.isRunning else { return }
        dingbat_audio_clear()
        AudioOutput.shared.restartIfNeeded()
    }

    #if DEBUG
    static let audioStats = ProcessInfo.processInfo.arguments.contains("-audio-stats")
    #endif

    // MARK: online link

    /// The link idle watch (web RB_IDLE_*): only the emulated cable's
    /// activity counts, never game knowledge. Lenient until the cable has
    /// seen real use, tight after; both reset on every transfer.
    private var linkUsed = false
    private var linkBusy = false
    private var linkTransfers: Int32 = 0
    private var linkActivity: CFTimeInterval = 0

    /// One tick of linked play: frames while the audio wants them (or the
    /// clock, with no audio engine), each sent to the friend with this
    /// player's buttons. A stall (-1) waits for the friend's input.
    private func linkedFrames(_ link: CADisplayLink, dt: CFTimeInterval) -> Int {
        var bits: UInt16 = 0
        for id in held where id >= 0 && id < 10 { bits |= UInt16(1) << UInt16(id) }
        var ran = 0
        #if DEBUG
        if let stop = Self.linkStopAt, dingbat_rollback_head() >= stop {
            linkDebugDump()
            return 0
        }
        if Self.linkPress {
            // A changing pattern, so the friend mispredicts and rolls back.
            let h = Int(dingbat_rollback_head())
            bits = (h / 23) % 2 == 0 ? 1 << 4 : (h / 37) % 2 == 0 ? 1 << 3 : 0
        }
        #endif
        func step() -> Bool {
            #if DEBUG
            if let stop = Self.linkStopAt, dingbat_rollback_head() >= stop { return false }
            #endif
            let f = dingbat_rollback_tick(Int32(bits))
            guard f >= 0 else { return false }
            NetLink.shared.sendInput(frame: f, bits: bits)
            ran += 1
            return true
        }
        for _ in 0..<framesOwed(link, dt: dt) {
            // Stalled at the prediction window: wait for the friend.
            if !step() { frameDebt = 0; break }
        }
        keepAudioAlive()
        return ran
    }

    #if DEBUG
    /// `-link-stop-at F`: stop ticking at frame F; once the friend's inputs
    /// have caught up, log both cores' state hashes (ios/e2e/link.mjs
    /// compares them with the browser's). `-link-press`: scripted buttons.
    static let linkStopAt: Int32? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-link-stop-at"), i + 1 < a.count else { return nil }
        return Int32(a[i + 1])
    }()
    static let linkPress = ProcessInfo.processInfo.arguments.contains("-link-press")
    private var linkDumped = false
    private func linkDebugDump() {
        guard !linkDumped else { return }
        let head = dingbat_rollback_head(), conf = dingbat_rollback_confirmed()
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("linkdump.txt")
        guard conf == head - 1 else {
            try? "waiting head=\(head) confirmed=\(conf)\n".write(to: file, atomically: true, encoding: .utf8)
            return
        }
        linkDumped = true
        var out = "LINKDUMP head=\(head) confirmed=\(conf)"
        for p in Int32(0)...1 {
            let n = Int(dingbat_rollback_dump_size(p))
            var h: UInt32 = 0x811c9dc5
            if n > 0, let d = dingbat_rollback_dump_data() {
                let b = d.assumingMemoryBound(to: UInt8.self)
                for i in 0 ..< n { h = (h ^ UInt32(b[i])) &* 0x01000193 }
            }
            out += " p\(p)=\(n):\(String(h, radix: 16))"
        }
        try? (out + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    #endif

    private func watchLinkIdle(_ now: CFTimeInterval) {
        let t = dingbat_rollback_transfers()
        if t != linkTransfers {
            linkTransfers = t
            linkActivity = now
            if t > 0 { linkUsed = true }
            if t >= 300 { linkBusy = true }
        } else if linkUsed && now - linkActivity > (linkBusy ? 20 : 90) {
            linkUsed = false
            NetLink.shared.idleDisconnect()
        }
    }

    /// The session is about to take the core: nothing of the solo game's
    /// extras may run on into it.
    func linkWillStart() {
        ClipExporter.shared.gameLeaving()
        rewinding = false
        setSpeed(.normal)
    }

    /// Linked: the session's core is the game now (web enterRollbackMode).
    func enterLinked() {
        linkUsed = false
        linkBusy = false
        linkTransfers = 0
        linkActivity = CACurrentMediaTime()
        lastTick = 0
        frameDebt = 0
        // Not relayed: the friend unfreezes on its own start.
        if paused {
            paused = false
            UIApplication.shared.isIdleTimerDisabled = true
            AudioOutput.shared.refreshSession()
        }
        present()
    }

    /// The session handed this player's core back as the solo game.
    func leaveLinked() {
        if speed != .normal { setSpeed(.normal) }
        lastSaveSig = game.map { RomLibrary.currentSaveSig($0) } ?? nil
        sessionMoved = true
        guard let g = game, dingbat_loaded() != 0 else { return }
        // The kept core is the session's own: what the solo core carried
        // goes back on, as after a reset.
        CheatStore.restore(for: g)
        if hasCamera { _ = dingbat_camera_attach() }
        applyHle()
        present()
    }

    /// A session that took the core and could not run gives the game back
    /// as it was, still frozen under the link sheet.
    func restoreAfterFailedLink(_ state: Data) {
        guard let g = game, dingbat_loaded() == 0 else { return }
        open(g, resume: false)
        apply(state: state, keepRewind: false)
        setPaused(true, relay: false)
    }

    /// The friend paused or resumed: match without sending it back. A sheet
    /// holding the game keeps it, and closing the sheet gives the friend's
    /// choice back (web applyRemotePause).
    func remotePause(_ on: Bool) {
        let model = AppModel.shared
        if model.sheet != nil {
            model.sheetPausedGame = !on
            if on && !paused { setPaused(true, relay: false) }
            return
        }
        guard model.screen == .play else { return }
        setPaused(on, relay: false)
    }

    func remoteSpeed(_ on: Bool) {
        setSpeed(on ? .double : .normal, relay: false)
    }

    private func present() {
        GameRenderer.shared.present()
        let size = CGSize(width: Int(dingbat_out_width()), height: Int(dingbat_out_height()))
        if size != outSize { outSize = size }
    }

    private func fpsAccount(_ now: CFTimeInterval, ran: Int) {
        framesThisSecond += ran
        if fpsWindowStart == 0 { fpsWindowStart = now }
        guard now - fpsWindowStart >= 1.0 else { return }
        let f = Double(framesThisSecond) / (now - fpsWindowStart)
        framesThisSecond = 0
        fpsWindowStart = now
        let expected: Double
        switch (paused || rewinding, speed) {
        case (true, _): expected = 0
        case (_, .double): expected = 119.5
        case (_, .slow): expected = 29.9
        case (_, .fastForward): expected = -1
        default: expected = 59.7
        }
        let rounded = Int(f + 0.5)
        if fps != rounded { fps = rounded }
        #if DEBUG
        // `-audio-stats`: a line a second (fps, ring depth, reader underruns)
        // into tmp/audiostats.txt, for checking pacing in the simulator.
        if Self.audioStats {
            let line = String(format: "fps=%.1f speed=%@ depth=%d underruns=%d\n", f, "\(speed)",
                              dingbat_audio_queued_frames(), dingbat_audio_underruns())
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audiostats.txt")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        #endif
        let unusual = expected < 0 || abs(f - expected) > max(3, expected * 0.05)
        if fpsUnusual != unusual { fpsUnusual = unusual }
        let hle = dingbat_hle_audio_active() != 0
        if hleActive != hle { hleActive = hle }
        let avail = dingbat_mp2k_available() != 0
        if mp2kAvailable != avail { mp2kAvailable = avail }
    }

    private func pollPeripherals() {
        let on = Settings.shared.rumble && dingbat_rumble() != 0
        if on != rumbleWasOn {
            rumbleWasOn = on
            rumbling = on
            onRumble?(on)
        }
        while dingbat_printer_poll() > 0 {
            let h = Int(dingbat_printer_take())
            guard h > 0, let ptr = dingbat_printer_take_ptr() else { break }
            if let img = Self.grayImage(ptr, width: 160, height: h) { onPrint?(img) }
        }
    }

    /// An in-game save written since the last check (the core writes the
    /// .sav itself): the session that carried the old save is retired by
    /// its signature, and the save webhook hears about it.
    private func checkSaveChanged() {
        guard let g = game else { return }
        let sig = RomLibrary.currentSaveSig(g)
        guard sig != lastSaveSig else { return }
        lastSaveSig = sig
        DriveSync.shared.markUpload("save:" + g.fileName)
        SaveWebhook.post(game: g)
    }

    // MARK: input

    /// source: "touch", "pad", "key" — each source's held set is tracked so
    /// a release on one never lifts a press held on another.
    func setInput(_ id: Int, _ down: Bool, source: String = "touch") {
        var set = sources[source] ?? []
        if down { set.insert(id) } else { set.remove(id) }
        sources[source] = set
        let wasHeld = held.contains(id)
        let nowHeld = sources.values.contains { $0.contains(id) }
        if wasHeld != nowHeld {
            dingbat_set_input(Int32(id), nowHeld ? 1 : 0)
            if nowHeld { held.insert(id) } else { held.remove(id) }
        }
    }

    func clearInputs() {
        for id in held { dingbat_set_input(Int32(id), 0) }
        held = []
        sources = [:]
    }

    // MARK: pause / speed / rewind

    func setPaused(_ p: Bool, relay: Bool = true) {
        guard game != nil, paused != p else { return }
        paused = p
        if relay && NetLink.shared.linked { NetLink.shared.sendPause(p) }
        pausedForBackground = false
        // The screen stays awake while a game runs (web: Screen Wake Lock).
        UIApplication.shared.isIdleTimerDisabled = !p
        if p {
            rewinding = false
            if rumbleWasOn {
                rumbleWasOn = false
                rumbling = false
                onRumble?(false)
            }
            dingbat_flush_save()
            storeLastFrame()
        }
        AudioOutput.shared.refreshSession()
    }

    func togglePause() { setPaused(!paused) }

    func setSpeed(_ s: Speed, relay: Bool = true) {
        // Linked, only 2x: both sides run it together.
        if NetLink.shared.linked {
            guard s == .normal || s == .double else { return }
            if relay && s != speed { NetLink.shared.sendSpeed(s == .double) }
        }
        speed = s
        dingbat_set_fast_forward(s == .fastForward ? 1 : 0)
        dingbat_set_turbo(s == .double ? 1 : 0)
        dingbat_set_slowmo(s == .slow ? 1 : 0)
        dingbat_audio_set_free(s == .fastForward ? 1 : 0)
    }

    func toggleFastForward() { setSpeed(speed == .fastForward ? .normal : .fastForward) }
    func toggleDouble() { setSpeed(speed == .double ? .normal : .double) }

    func toggleSlowMotion() {
        setSpeed(speed == .slow ? .normal : .slow)
        AppModel.shared.toast(speed == .slow ? "Slow motion on (0.5x)" : "Slow motion off")
    }

    /// Hold-to-fast-forward (controller RT): restores the speed before it.
    private var speedBeforeHold: Speed = .normal
    func holdFastForward(_ down: Bool) {
        if down {
            speedBeforeHold = speed == .fastForward ? .normal : speed
            setSpeed(.fastForward)
        } else if speed == .fastForward {
            setSpeed(speedBeforeHold)
        }
    }

    func setRewinding(_ r: Bool) {
        guard game != nil, Settings.shared.rewind, !NetLink.shared.linked else { rewinding = false; return }
        if r && paused { setPaused(false) }
        rewinding = r
        if r { dingbat_audio_clear() }
    }

    /// One frame while paused; its audio is dropped.
    func stepFrame() {
        guard game != nil, !NetLink.shared.linked else { return }
        if !paused { setPaused(true) }
        dingbat_run_frame()
        dingbat_audio_clear()
        sessionMoved = true
        present()
    }

    func applyHle() {
        dingbat_set_mp2k_hle(Settings.shared.mp2kHle && !hleSessionOff ? 1 : 0)
    }

    // MARK: states

    /// The full state image (same bytes as desktop .state files).
    func captureState() -> Data? {
        guard game != nil else { return nil }
        let size = dingbat_state_size()
        guard size > 0, let ptr = dingbat_state_data() else { return nil }
        return Data(bytes: ptr, count: Int(size))
    }

    /// Apply a state; nil on success, else the sentence saying why not (web
    /// STATE_REJECT_COPY).
    @discardableResult
    func apply(state data: Data, keepRewind: Bool) -> String? {
        guard game != nil else { return "Load a game first" }
        let ok = data.withUnsafeBytes { buf -> Int32 in
            dingbat_load_state(buf.baseAddress, Int32(buf.count), keepRewind ? 1 : 0)
        }
        if ok == 1 {
            sessionMoved = true
            present()
            return nil
        }
        return Self.rejectCopy(data)
    }

    static func rejectCopy(_ data: Data) -> String {
        if data.count < 8 || String(decoding: data.prefix(8), as: UTF8.self) != "DGBSTATE" {
            return "That file isn't a dingbat save state."
        }
        switch dingbat_state_error_kind() {
        case 1: return "That file isn't a dingbat save state."
        case 2: return "That save state is for the other system — a Game Boy state can't load into a GBA game, or the reverse."
        case 3: return "That save state belongs to a different game. Load the game it was made in, then try again."
        case 4: return "That save state was made by a newer version of dingbat than this one. Update dingbat, then try again."
        case 5: return "That save state file is incomplete — the download or copy was cut short. Try getting the file again."
        case 6: return "That save state is damaged and can't be loaded. The game is still running and nothing was changed."
        case 7: return "There's no save state in that slot yet."
        default:
            let why = String(cString: dingbat_state_error())
            return why.isEmpty ? "That save state couldn't be loaded." : why.prefix(1).uppercased() + why.dropFirst()
        }
    }

    struct SlotInfo {
        var date: Date
        var thumb: UIImage?
    }

    /// A slot's time and thumbnail, from its meta record (web
    /// statemeta:<name>[:slotN] = { thumb: data URL, ts }); a slot with no
    /// meta (another build's) dates from its file.
    func slotInfo(_ slot: Int) -> SlotInfo? {
        guard let g = game else { return nil }
        let url = g.stateURL(slot: slot)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        guard let meta = try? Data(contentsOf: g.stateMetaURL(slot: slot)),
              let o = (try? JSONSerialization.jsonObject(with: meta)) as? [String: Any] else {
            return SlotInfo(date: date, thumb: nil)
        }
        var thumb: UIImage?
        if let s = o["thumb"] as? String, let comma = s.firstIndex(of: ","),
           let d = Data(base64Encoded: String(s[s.index(after: comma)...])) {
            thumb = UIImage(data: d)
        }
        let ts = (o["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? date
        return SlotInfo(date: ts, thumb: thumb)
    }

    /// Save to a slot (0 = Quick). Returns false when nothing was written.
    @discardableResult
    func saveState(slot: Int) -> Bool {
        guard let g = game, let data = captureState() else {
            AppModel.shared.toast("Couldn't capture the emulator state")
            return false
        }
        do {
            try RomLibrary.ensureDir(g.dir)
            try data.write(to: g.stateURL(slot: slot), options: .atomic)
            // 160 px wide, as the web's (which writes WebP; a JPEG data URL
            // reads the same everywhere).
            var meta = JSObject()
            if let jpg = currentImage(maxWidth: 160)?.jpegData(compressionQuality: 0.7) {
                meta["thumb"] = .string("data:image/jpeg;base64," + jpg.base64EncodedString())
            } else {
                meta["thumb"] = .null
            }
            meta["ts"] = .number(DriveSync.now())
            try? JSValue.object(meta).data().write(to: g.stateMetaURL(slot: slot), options: .atomic)
            DriveSync.shared.markUpload(RomLibrary.slotStateKey(g.fileName, slot))
            DriveSync.shared.markUpload(RomLibrary.slotMetaKey(g.fileName, slot))
            return true
        } catch {
            AppModel.shared.toast("Save state failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Load a slot with an Undo toast; false if empty or refused.
    @discardableResult
    func loadState(slot: Int) -> Bool {
        guard let g = game else { return false }
        guard let data = try? Data(contentsOf: g.stateURL(slot: slot)) else {
            AppModel.shared.toast(slot == 0 ? "No saved state for this game" : "Slot \(slot + 1) is empty")
            return false
        }
        let undo = captureState()
        if let why = apply(state: data, keepRewind: false) {
            AppModel.shared.toast(why, duration: 6)
            return false
        }
        AppModel.shared.toast("State loaded", action: undo.map { u in
            ("Undo", { [weak self] in
                self?.apply(state: u, keepRewind: false)
                AppModel.shared.toast("Back to before the load")
            })
        }, duration: 6, game: true)
        return true
    }

    func deleteState(slot: Int) {
        guard let g = game else { return }
        try? FileManager.default.removeItem(at: g.stateURL(slot: slot))
        try? FileManager.default.removeItem(at: g.stateMetaURL(slot: slot))
        DriveSync.shared.markDelete(RomLibrary.slotStateKey(g.fileName, slot))
        DriveSync.shared.markDelete(RomLibrary.slotMetaKey(g.fileName, slot))
    }

    /// Hard reset from the save, with Undo (web #reset).
    func reset() {
        guard game != nil, !NetLink.shared.holdsCore else { return }
        let undo = captureState()
        _ = dingbat_reset()
        // A reset builds a fresh core: cheats and the camera's feed go with
        // the old one (the web's reset is a whole loadRom, which restores both).
        if let g = game { CheatStore.restore(for: g) }
        if hasCamera { _ = dingbat_camera_attach() }
        applyHle()
        sessionMoved = true
        present()
        AppModel.shared.toast("Game reset", action: undo.map { u in
            ("Undo", { [weak self] in
                self?.apply(state: u, keepRewind: false)
                AppModel.shared.toast("Back to before the reset")
            })
        }, duration: 8, game: true)
    }

    // MARK: sessions and pictures

    /// Snapshot the session (web persistAutoState) when the game moved since
    /// the last one: the state, what save it carries, and its picture.
    func persistSession() {
        guard let g = game, sessionMoved else { return }
        guard !NetLink.shared.holdsCore else { dingbat_flush_save(); return }
        dingbat_flush_save()
        guard let bytes = captureState() else { return }
        let meta = SessionMeta(ts: DriveSync.now(), saveSig: RomLibrary.currentSaveSig(g),
                               by: DriveSync.deviceID, dev: DriveSync.deviceLabel)
        do {
            try RomLibrary.ensureDir(g.dir)
            // The old picture goes first: one left beside a newer snapshot
            // would be taken for its own (web sessionpic's ts check).
            try? FileManager.default.removeItem(at: g.sessionPicURL)
            try bytes.write(to: g.sessionURL, options: .atomic)
            try meta.header(state: bytes.count, pic: 0).write(to: g.sessionMetaURL, options: .atomic)
            if let jpg = currentImage()?.jpegData(compressionQuality: 0.75) {
                try? jpg.write(to: g.sessionPicURL, options: .atomic)
            }
            sessionMoved = false
            RomLibrary.shared.pictureGen += 1
            DriveSync.shared.markUpload("stateauto:" + g.fileName)
        } catch {}
    }

    /// Signature of the last picture stored, so an unchanged screen (a title
    /// screen left running) is neither rewritten nor sent again.
    private var lastFrameSig: String?

    /// The library picture: the last screen, a JPEG at 2x native as the
    /// web's (frame:<name>), mirrored on Drive.
    func storeLastFrame() {
        guard let g = game, let jpg = currentImage()?.jpegData(compressionQuality: 0.75) else { return }
        let sig = DriveSync.sig(jpg)
        guard sig != lastFrameSig else { return }
        lastFrameSig = sig
        try? RomLibrary.ensureDir(g.dir)
        try? jpg.write(to: g.shotURL, options: .atomic)
        RomLibrary.shared.pictureGen += 1
        DriveSync.shared.markUpload("frame:" + g.fileName)
    }

    /// The picture now, colour corrected (no filters or palette), optionally
    /// scaled down.
    func currentImage(maxWidth: Int? = nil) -> UIImage? {
        guard game != nil, let ptr = dingbat_framebuffer_rgba() else { return nil }
        let w = Int(dingbat_fb_width()), h = Int(dingbat_fb_height())
        let data = Data(bytes: UnsafeRawPointer(ptr), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        // 2x native, nearest neighbour, so the picture stays crisp when shown.
        let scale = maxWidth.map { CGFloat($0) / CGFloat(w) } ?? 2
        let size = CGSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            ctx.cgContext.draw(cg, in: CGRect(origin: .zero, size: size))
        }
    }

    static func grayImage(_ ptr: UnsafePointer<UInt8>, width: Int, height: Int) -> UIImage? {
        let data = Data(bytes: ptr, count: width * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// BGR555 thumbnails (rewind strips, state trailers) to an image.
    static func bgr555Image(_ ptr: UnsafeRawPointer, width: Int, height: Int) -> UIImage? {
        let src = ptr.assumingMemoryBound(to: UInt16.self)
        var rgba = [UInt32](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let v = UInt32(src[i])
            let r = (v & 31) * 255 / 31, g = ((v >> 5) & 31) * 255 / 31, b = ((v >> 10) & 31) * 255 / 31
            rgba[i] = 0xFF00_0000 | (b << 16) | (g << 8) | r
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Cheats per game, as .cht text (web cheats:<name>), re-applied on load.
enum CheatStore {
    static func load(for e: RomEntry) -> String {
        (try? String(contentsOf: e.cheatsURL, encoding: .utf8)) ?? ""
    }

    /// Store and apply; returns the core's parse errors ("" when clean).
    @discardableResult
    static func save(_ text: String, for e: RomEntry) -> String {
        if text.isEmpty { try? FileManager.default.removeItem(at: e.cheatsURL) }
        else { try? text.write(to: e.cheatsURL, atomically: true, encoding: .utf8) }
        return String(cString: dingbat_load_cheats(text))
    }

    static func restore(for e: RomEntry) {
        let text = load(for: e)
        if !text.isEmpty { _ = dingbat_load_cheats(text) }
    }
}

/// Settings › General › Advanced › Save webhook: every in-game save is also
/// POSTed there as multipart form data (save, game, savedAt); the response
/// is never read.
enum SaveWebhook {
    static func post(game: RomEntry) {
        let urlString = Settings.shared.saveWebhook.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty, let url = URL(string: urlString),
              let save = try? Data(contentsOf: game.saveURL), !save.isEmpty else { return }
        let boundary = "dingbat-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("game", game.fileName)
        field("savedAt", ISO8601DateFormatter().string(from: Date()))
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"save\"; filename=\"\(game.stem).sav\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(save)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }
}
