import SwiftUI

/// Library pictures, in one go (web "Add pictures"): every game with no
/// picture is booted in the core without becoming the loaded game - its
/// session put back where it has one and stepped one render, otherwise run
/// through its boot toward a title screen, bounded in frames and in wall
/// clock - and the screen stored as its library picture. Its own save and
/// session are never touched: the ROM and battery go to scratch files.
/// Signed in, Drive-only games can come too: fetched into memory, pictured,
/// and not kept here. Offered once per device; the library head's Add
/// pictures any time there is something to picture.
final class AddPictures: ObservableObject {
    static let shared = AddPictures()

    static let resumeFrames = 2
    static let bootFrames = 600
    static let bootSeconds = 2.5
    static let chunk = 30
    static let offeredKey = "thumbs_offered"

    /// Running: "Picturing 2 of 9 — name", and how far.
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0
    private var cancelled = false

    struct Candidate { let entry: RomEntry; let local: Bool }

    func candidates(includeDrive: Bool) -> [Candidate] {
        let fm = FileManager.default
        return RomLibrary.shared.entries.compactMap { e in
            if fm.fileExists(atPath: e.shotURL.path) { return nil }
            if e.isLocal { return Candidate(entry: e, local: true) }
            return includeDrive && DriveSync.shared.driveHasRom(e.fileName) ? Candidate(entry: e, local: false) : nil
        }
    }

    /// Something to picture (the library head's link shows).
    var anyToPicture: Bool { !candidates(includeDrive: DriveSync.shared.linked).isEmpty }

    /// Once per device, with something to picture and nothing loaded.
    func maybeOffer() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.offeredKey), GameSession.shared.game == nil,
              AppModel.shared.sheet == nil, anyToPicture else { return }
        d.set(true, forKey: Self.offeredKey)  // one offer, whatever the answer
        AppModel.shared.openSheet(.addPictures)
    }

    /// The library head's entry: the same sheet.
    func open() {
        guard GameSession.shared.game == nil else {
            AppModel.shared.toast("Close the running game first")
            return
        }
        guard anyToPicture else {
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
        var deadline = CACurrentMediaTime() + Self.bootSeconds
        if c.local, let s = try? Data(contentsOf: e.sessionURL), !s.isEmpty,
           s.withUnsafeBytes({ dingbat_load_state($0.baseAddress, Int32($0.count), 0) }) == 1 {
            frames = Self.resumeFrames
            deadline = .infinity
        }
        var ran = 0
        while ran < frames && CACurrentMediaTime() < deadline {
            // A launch takes the core: this one gives way.
            guard !cancelled, GameSession.shared.game == nil else { return false }
            for _ in 0..<min(Self.chunk, frames - ran) { dingbat_run_frame() }
            ran += Self.chunk
            dingbat_audio_clear()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        guard !cancelled, GameSession.shared.game == nil,
              let jpg = GameSession.coreImage()?.jpegData(compressionQuality: 0.75) else { return false }
        try? RomLibrary.ensureDir(e.dir)
        guard (try? jpg.write(to: e.shotURL, options: .atomic)) != nil else { return false }
        DriveSync.shared.markUpload("frame:" + e.fileName)
        return true
    }
}

/// web #thumbs-modal: the offer, then the run's progress with Stop.
struct AddPicturesView: View {
    @ObservedObject private var job = AddPictures.shared
    @ObservedObject private var drive = DriveSync.shared
    @Environment(\.palette) private var palette
    @State private var includeDrive = false

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
                Text("dingbat can open each game, pick up where you left off, take a picture of the screen for its library card, and close it again. It takes a few seconds a game. Your games and saves are not changed.")
                    .font(.system(size: 13.5))
                    .foregroundColor(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                SheetHint("You can do this later from Add pictures, above your library.")
                if drive.linked && job.candidates(includeDrive: true).contains(where: { !$0.local }) {
                    SheetToggleRow(label: "Include games kept only on Drive",
                                   sub: "Each one is fetched, pictured, and not kept on this device",
                                   isOn: $includeDrive)
                }
                HStack(spacing: 10) {
                    Spacer()
                    PadButton("Not now") { SheetNav.close() }
                        .buttonStyle(SheetButtonStyle(small: false))
                    PadButton("Add pictures") {
                        Task { @MainActor in await job.run(includeDrive: includeDrive) }
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
