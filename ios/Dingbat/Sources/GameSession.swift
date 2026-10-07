import QuartzCore
import SwiftUI
import UIKit

/// The running game: the CADisplayLink loop and every call into
/// libdingbat.a that is about playing (web/index.js tick, loadRom, the speed
/// flags, rewind, save states, sessions). Core calls stay on the main thread;
/// the audio render block only touches the realtime-safe dingbat_audio_* API.
///
/// Pacing: the APU fills a 32768 Hz ring as emulation runs and the audio
/// node drains it in real time. Each display tick runs frames only while
/// dingbat_audio_ahead() == 0 (bounded), so the audio clock paces emulation;
/// 2x drops every other sample and slow motion queues each twice, so the same
/// rule runs them at 2x and 0.5x. Fast-forward drops audio-sync and runs
/// frames for most of each display interval.
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
    /// Bumped on every presented frame that changed (for observers that
    /// sample the picture: glow, input overlay).
    @Published private(set) var frameGen = 0
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

    enum OpenResult { case ok, failed, resumed, savedSince }

    /// Boot a game. `resume` puts its session back in during the boot when
    /// one still counts (web launchRom {resume}); otherwise it boots from the
    /// in-game save.
    @discardableResult
    func open(_ entry: RomEntry, resume: Bool) -> OpenResult {
        if game != nil { leaveGame() }
        dingbat_init()
        let bios = entry.isGBA ? RomLibrary.gbaBiosURL : RomLibrary.gbcBootromURL
        let biosArg = FileManager.default.fileExists(atPath: bios.path) ? bios.path : nil
        let rc = biosArg.map { dingbat_load_rom(entry.url.path, $0) } ?? dingbat_load_rom(entry.url.path, nil)
        guard rc == 0 else {
            game = nil
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
        RomLibrary.shared.touch(entry)
        CheatStore.restore(for: entry)
        tiltKind = Int(dingbat_cart_has_tilt())
        hasCamera = dingbat_cart_has_camera() != 0
        var result = OpenResult.ok
        if resume {
            if let s = RomLibrary.shared.resumableSession(entry) {
                if apply(state: s.bytes, keepRewind: false) == nil {
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
        leaveGame()
        stopLink()
        dingbat_unload()
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

    @objc private func tick(_ link: CADisplayLink) {
        guard game != nil else { return }
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
            let cap = speed == .double ? 8 : 4
            let ahead = speed == .normal ? Settings.shared.runahead : 0
            while dingbat_audio_ahead() == 0 && ran < cap {
                if ahead > 0 { dingbat_run_frame_ahead(Int32(ahead)) } else { dingbat_run_frame() }
                ran += 1
            }
        }
        if ran > 0 {
            sessionMoved = true
            playTime += dt
            shotTime += dt
            saveCheckTime += dt
            if dingbat_frame_static() == 0 { present() }
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

    private func present() {
        GameRenderer.shared.present()
        frameGen &+= 1
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

    func setPaused(_ p: Bool) {
        guard game != nil, paused != p else { return }
        paused = p
        pausedForBackground = false
        if p {
            rewinding = false
            dingbat_flush_save()
            storeLastFrame()
        }
        AudioOutput.shared.refreshSession()
    }

    func togglePause() { setPaused(!paused) }

    func setSpeed(_ s: Speed) {
        speed = s
        dingbat_set_fast_forward(s == .fastForward ? 1 : 0)
        dingbat_set_turbo(s == .double ? 1 : 0)
        dingbat_set_slowmo(s == .slow ? 1 : 0)
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
        guard game != nil, Settings.shared.rewind else { rewinding = false; return }
        if r && paused { setPaused(false) }
        rewinding = r
        if r { dingbat_audio_clear() }
    }

    /// One frame while paused; its audio is dropped.
    func stepFrame() {
        guard game != nil else { return }
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

    func slotInfo(_ slot: Int) -> SlotInfo? {
        guard let g = game else { return nil }
        let url = g.stateURL(slot: slot)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return SlotInfo(date: date, thumb: UIImage(contentsOfFile: g.stateThumbURL(slot: slot).path))
    }

    /// Save to a slot (0 = Quick). Returns false when nothing was written.
    @discardableResult
    func saveState(slot: Int) -> Bool {
        guard let g = game, let data = captureState() else {
            AppModel.shared.toast("Couldn't capture the emulator state")
            return false
        }
        do {
            try data.write(to: g.stateURL(slot: slot), options: .atomic)
            if let png = currentImage(maxWidth: 160)?.pngData() {
                try? png.write(to: g.stateThumbURL(slot: slot), options: .atomic)
            }
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
        try? FileManager.default.removeItem(at: g.stateThumbURL(slot: slot))
    }

    /// Hard reset from the save, with Undo (web #reset).
    func reset() {
        guard game != nil else { return }
        let undo = captureState()
        _ = dingbat_reset()
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
        dingbat_flush_save()
        guard let bytes = captureState() else { return }
        let meta = SessionMeta(ts: Date().timeIntervalSince1970 * 1000,
                               saveSig: RomLibrary.currentSaveSig(g))
        do {
            try bytes.write(to: g.sessionURL, options: .atomic)
            try JSONEncoder().encode(meta).write(to: g.sessionMetaURL, options: .atomic)
            if let png = currentImage()?.pngData() {
                try? png.write(to: g.sessionPicURL, options: .atomic)
            }
            sessionMoved = false
            RomLibrary.shared.pictureGen += 1
        } catch {}
    }

    /// The library picture: the last screen (web frame:<name>).
    func storeLastFrame() {
        guard let g = game, let png = currentImage()?.pngData() else { return }
        try? png.write(to: g.shotURL, options: .atomic)
        RomLibrary.shared.pictureGen += 1
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
