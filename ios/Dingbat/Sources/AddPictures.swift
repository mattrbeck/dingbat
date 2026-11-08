import SwiftUI

/// Library pictures, in one go (web "Add pictures"): every game with no
/// picture is booted in the core without becoming the loaded game - its
/// session put back where it has one and stepped one render, otherwise run
/// through its boot toward a title screen, bounded in frames and in wall
/// clock - and the screen stored as its library picture. Its own save and
/// session are never touched: the ROM and battery go to scratch files.
/// Signed in, Drive-only games can come too: fetched into memory, pictured,
/// and not kept here. Offered once per device; the library head's Add
/// pictures any time there is something a run would open. A game that came
/// up blank is left out until it is played (`blankKey`).
final class AddPictures: ObservableObject {
    static let shared = AddPictures()

    static let resumeFrames = 2
    /// No session: through the logo to a title (10 s of play). Frames end
    /// a run, so the picture is the same however fast the core runs;
    /// `safetySeconds` is only a net for a core that hangs (web
    /// THUMBS_SAFETY_MS).
    static let bootFrames = 600
    static let safetySeconds = 10.0
    /// Frames between looks (for a blank screen, a launch, Stop).
    static let chunk = 30
    static let offeredKey = "thumbs_offered"
    /// The sheet's "Include games kept only on Drive", as last left: off
    /// until turned on. It decides whether Drive-only games keep Add
    /// pictures up (web THUMBS_DRIVE_KEY). Reset all settings forgets it.
    static let driveKey = "thumbs-drive"
    static var driveWanted: Bool {
        get { UserDefaults.standard.bool(forKey: driveKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: driveKey)
            RomLibrary.shared.pictureGen += 1  // Drive-only games count toward Add pictures, or stop
        }
    }

    /// Running: "Picturing 2 of 9 — name", and how far.
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0
    private var cancelled = false
    /// This run's games that came up blank.
    private var blankCount = 0

    struct Candidate { let entry: RomEntry; let local: Bool }

    /// Library games without a picture, less those a run came up blank on
    /// (`blankKey`). Drive-only ones only when asked, and only with a ROM on
    /// Drive to fetch.
    func candidates(includeDrive: Bool) -> [Candidate] {
        let fm = FileManager.default
        let blank = Self.blank
        return RomLibrary.shared.entries.compactMap { e in
            if fm.fileExists(atPath: e.shotURL.path) { return nil }
            if blank[e.fileName] != nil { return nil }
            // The batch boots games on the GB/GBA core: a DS game gets its
            // picture by being played (web).
            if e.isNDS { return nil }
            if e.isLocal { return Candidate(entry: e, local: true) }
            return includeDrive && DriveSync.shared.driveHasRom(e.fileName) ? Candidate(entry: e, local: false) : nil
        }
    }

    /// Something a run would open (the library head's Add pictures shows):
    /// Drive-only games count only with the sheet's Drive switch left on,
    /// since only then does the run fetch them.
    var anyToPicture: Bool {
        !candidates(includeDrive: DriveSync.shared.linked && Self.driveWanted).isEmpty
    }

    /// Something the sheet would offer: Drive-only games too, behind its
    /// switch, whenever signed in.
    private var anyToOffer: Bool { !candidates(includeDrive: DriveSync.shared.linked).isEmpty }

    // MARK: games that came up blank (web THUMBS_BLANK_KEY)

    /// Games a run came up blank on (still one colour after the boot and as
    /// long again), by file name. A run, and Add pictures, leave them out
    /// until the game is played: opening it, a new file for it, or a
    /// picture stored from play clears the mark, so one press does not run
    /// them again and again for nothing. This device's only.
    static let blankKey = "thumbsblank"
    static var blank: [String: Double] {
        UserDefaults.standard.dictionary(forKey: blankKey) as? [String: Double] ?? [:]
    }

    static func markBlank(_ name: String) {
        var b = blank
        b[name] = Date().timeIntervalSince1970 * 1000
        UserDefaults.standard.set(b, forKey: blankKey)
    }

    static func clearBlank(_ names: [String]) {
        var b = blank
        var hit = false
        for n in names where b.removeValue(forKey: n) != nil { hit = true }
        if hit { UserDefaults.standard.set(b, forKey: blankKey) }
    }

    /// The marks of games that left the library or have a picture now
    /// (one from Drive, say) go (RomLibrary.publish).
    static func pruneBlank(_ names: Set<String>, pictured: (String) -> Bool) {
        let spent = blank.keys.filter { !names.contains($0) || pictured($0) }
        if !spent.isEmpty { clearBlank(Array(spent)) }
    }

    /// Once per device, with something to picture and nothing loaded. The
    /// sheet offers Drive-only games behind its switch whenever it opens.
    func maybeOffer() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.offeredKey), GameSession.shared.game == nil,
              AppModel.shared.sheet == nil, anyToOffer else { return }
        d.set(true, forKey: Self.offeredKey)  // one offer, whatever the answer
        AppModel.shared.openSheet(.addPictures)
    }

    /// The library head's entry: the same sheet.
    func open() {
        guard GameSession.shared.game == nil else {
            AppModel.shared.toast("Close the running game first")
            return
        }
        guard anyToOffer else {
            AppModel.shared.toast("Every game already has a picture")
            return
        }
        AppModel.shared.openSheet(.addPictures)
    }

    func cancel() { cancelled = true }

    @MainActor
    func run(includeDrive: Bool) async {
        guard !running else { return }
        guard GameSession.shared.game == nil else {
            AppModel.shared.toast("Close the running game first")
            return
        }
        let cands = candidates(includeDrive: includeDrive)
        running = true
        cancelled = false
        blankCount = 0
        var done = 0
        // Nobody hears it, and nothing may wait on the audio.
        let audioMode = dingbat_audio_get_mode()
        dingbat_audio_set_mode(2)
        dingbat_set_fast_forward(1)
        for (i, c) in cands.enumerated() where !cancelled && GameSession.shared.game == nil {
            status = "Picturing \(i + 1) of \(cands.count) — \(c.entry.name)"
            progress = Double(i) / Double(max(1, cands.count))
            if await pictureOne(c) {
                done += 1
                RomLibrary.shared.pictureGen += 1  // the grid fills in as it goes
            }
        }
        // The core is left empty unless a launch took it meanwhile.
        if GameSession.shared.game == nil {
            dingbat_unload(0)
            dingbat_set_fast_forward(0)
        }
        dingbat_audio_set_mode(audioMode)
        dingbat_audio_clear()
        running = false
        status = ""
        progress = 0
        // The games that came up blank leave Add pictures' count.
        if blankCount > 0 { RomLibrary.shared.pictureGen += 1 }
        if case .addPictures = AppModel.shared.sheet { AppModel.shared.sheet = nil }
        AppModel.shared.toast(done == 0 ? "No pictures added"
            : "\(done) \(done == 1 ? "picture" : "pictures") added" + (cancelled ? " before stopping" : ""))
    }

    @MainActor
    private func pictureOne(_ c: Candidate) async -> Bool {
        let e = c.entry
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("thumb")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let rom = dir.appendingPathComponent("thumb." + e.ext)
        let sav = dir.appendingPathComponent("thumb.sav")
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
        defer { try? fm.removeItem(at: sav) }
        var save: Data?
        if c.local {
            guard (try? fm.createSymbolicLink(at: rom, withDestinationURL: e.url)) != nil else { return false }
            save = try? Data(contentsOf: e.saveURL)
        } else {
            guard let got = await DriveSync.shared.fetchForPicture(e.fileName) else { return false }
            guard (try? got.rom.write(to: rom)) != nil else { return false }
            save = got.save
        }
        if let save, !save.isEmpty { try? save.write(to: sav) }
        guard !cancelled, GameSession.shared.game == nil else { return false }
        let bios = e.isGBA ? RomLibrary.gbaBiosURL : RomLibrary.gbcBootromURL
        let rc = fm.fileExists(atPath: bios.path) ? dingbat_load_rom(rom.path, bios.path) : dingbat_load_rom(rom.path, nil)
        guard rc == 0 else { return false }
        var frames = Self.bootFrames
        var deadline = CACurrentMediaTime() + Self.safetySeconds
        if c.local, let s = try? Data(contentsOf: e.sessionURL), !s.isEmpty,
           s.withUnsafeBytes({ dingbat_load_state($0.baseAddress, Int32($0.count), 0) }) == 1 {
            frames = Self.resumeFrames
            deadline = .infinity
        }
        guard await advance(frames, deadline) else { return false }
        // A blank screen (still on a boot's white, or in a fade): run on to
        // the next one that isn't, for up to as long again, in frames;
        // still blank, no picture, and the tile keeps its cartridge.
        if Self.coreBlank() {
            guard await advance(Self.bootFrames, CACurrentMediaTime() + Self.safetySeconds,
                                until: { !Self.coreBlank() }) else { return false }
            if Self.coreBlank() {
                Self.markBlank(e.fileName)  // left out until it is played
                blankCount += 1
                return false
            }
        }
        guard let jpg = GameSession.coreImage()?.jpegData(compressionQuality: 0.75) else { return false }
        try? RomLibrary.ensureDir(e.dir)
        guard (try? jpg.write(to: e.shotURL, options: .atomic)) != nil else { return false }
        DriveSync.shared.markUpload("frame:" + e.fileName)
        return true
    }

    /// Run the pictures core on: up to `frames` frames or until `deadline`,
    /// whichever comes first, in chunks so the app stays responsive,
    /// stopping early once `until()` holds (web thumbsAdvance). False when
    /// the run was stopped or a launch took the core meanwhile.
    @MainActor
    private func advance(_ frames: Int, _ deadline: CFTimeInterval, until: () -> Bool = { false }) async -> Bool {
        var ran = 0
        while ran < frames && CACurrentMediaTime() < deadline {
            // A launch takes the core: this one gives way.
            guard !cancelled, GameSession.shared.game == nil else { return false }
            let n = min(Self.chunk, frames - ran)
            for _ in 0..<n { dingbat_run_frame() }
            ran += n
            dingbat_audio_clear()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
            if until() { break }
        }
        return !cancelled && GameSession.shared.game == nil
    }

    /// The pictures core's screen is one colour (GameSession.framebufferBlank).
    private static func coreBlank() -> Bool {
        guard let p = dingbat_framebuffer_rgba() else { return true }
        return GameSession.framebufferBlank(p, width: Int(dingbat_fb_width()), height: Int(dingbat_fb_height()))
    }
}

/// web #thumbs-modal: the offer, then the run's progress with Stop.
struct AddPicturesView: View {
    @ObservedObject private var job = AddPictures.shared
    @ObservedObject private var drive = DriveSync.shared
    @Environment(\.palette) private var palette
    /// As last left (AddPictures.driveWanted).
    @State private var includeDrive = AddPictures.driveWanted

    /// The Drive row means something only signed in, with a Drive-only game
    /// still unpictured.
    private var driveRow: Bool {
        drive.linked && job.candidates(includeDrive: true).contains(where: { !$0.local })
    }

    var body: some View {
        SheetChrome(title: "Add pictures to your library?", fit: true, onClose: close) {
            if job.running {
                Text(job.status)
                    .font(.system(size: 13.5))
                    .foregroundColor(palette.textDim)
                    .padding(.bottom, 10)
                ProgressView(value: job.progress)
                    .tint(palette.accent)
                    .padding(.bottom, 16)
                HStack {
                    Spacer()
                    PadButton("Stop") { job.cancel() }
                        .buttonStyle(SheetButtonStyle(small: false))
                }
            } else {
                Text("dingbat can open each game, pick up where you left off, take a picture of the screen for its library card, and close it again. It takes a moment per game. Your games and saves are not changed.")
                    .font(.system(size: 13.5))
                    .foregroundColor(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                SheetHint("You can do this later from Add pictures, above your library.")
                if driveRow {
                    SheetToggleRow(label: "Include games kept only on Drive",
                                   sub: "Each one is fetched, pictured, and not kept on this device",
                                   isOn: Binding(get: { includeDrive }, set: { on in
                                       includeDrive = on
                                       AddPictures.driveWanted = on
                                   }))
                }
                HStack(spacing: 10) {
                    Spacer()
                    PadButton("Not now") { SheetNav.close() }
                        .buttonStyle(SheetButtonStyle(small: false))
                    PadButton("Add pictures") {
                        let drive = driveRow && includeDrive
                        Task { @MainActor in await job.run(includeDrive: drive) }
                    }
                    .buttonStyle(SheetButtonStyle(kind: .primary, small: false))
                }
            }
        }
        .interactiveDismissDisabled(job.running)
    }

    private func close() {
        job.cancel()
        SheetNav.close()
    }
}
