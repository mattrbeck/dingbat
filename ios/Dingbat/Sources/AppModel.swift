import SwiftUI
import UIKit

/// App-level state: which screen is up, the hero, toasts and sheets (web:
/// body.running / showMainMenu / the hero / the toast stack / the modals).
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Screen { case home, play }

    /// Sheets and modals (web: #states-modal, #saves-modal, ...). One at a
    /// time; the game stays paused while any is up.
    enum Sheet: Identifiable, Equatable {
        case settings(section: String?)
        case states, saves, rewind, cheats, prints, report, clip
        case tileMenu(RomEntry), rename(RomEntry)
        var id: String {
            switch self {
            case .settings: return "settings"
            case .states: return "states"
            case .saves: return "saves"
            case .rewind: return "rewind"
            case .cheats: return "cheats"
            case .prints: return "prints"
            case .report: return "report"
            case .clip: return "clip"
            case .tileMenu(let e): return "tile:" + e.id
            case .rename(let e): return "rename:" + e.id
            }
        }
    }

    struct Toast: Identifiable {
        let id = UUID()
        var text: String
        var action: (label: String, run: () -> Void)?
        var duration: Double
        /// Dismissed when the player goes back to the home screen.
        var game: Bool
    }

    @Published var screen: Screen = .home
    /// The game played this visit, which heads the home screen (web
    /// playedThisVisit). Paused while it is the one in memory, else closed.
    @Published var heroGame: RomEntry?
    @Published var sheet: Sheet?
    @Published private(set) var toasts: [Toast] = []
    /// The in-game menu (hamburger) is open.
    @Published var menuOpen = false
    /// Phone landscape: the top bar is down (a tap on the picture toggles it).
    @Published var topbarOpen = false
    /// A controller is connected and Settings hides the touch controls.
    @Published var gamepadHidesTouch = false
    /// Unseen printed photos (the menu's dot).
    @Published var newPrints = false
    /// A game with no ROM here whose file the person is picking again
    /// ("Find the file…").
    @Published var relinking: RomEntry?
    /// A picked file of a different size than the game had: asked first.
    @Published var relinkConfirm: (entry: RomEntry, bytes: Data)?
    /// A Drive-only game coming down to be opened (the tile's "Opening").
    @Published var opening: String?
    /// Tiles whose download failed (until the next tap), or just finished
    /// (a check for 2 s).
    @Published var tileFailed = Set<String>()
    @Published var tileDone = Set<String>()

    /// "Games removed on another device": the games, answered by Continue
    /// (false) or Restore (true).
    @Published var tombstonePrompt: [String]?
    private var tombstoneAnswer: CheckedContinuation<Bool, Never>?

    let session = GameSession.shared
    let library = RomLibrary.shared
    let settings = Settings.shared

    private init() {
        session.onPrint = { [weak self] img in self?.printed(img) }
    }

    var heroPaused: Bool { heroGame != nil && session.game == heroGame }

    // MARK: toasts

    func toast(_ text: String, action: (String, () -> Void)? = nil, duration: Double? = nil, game: Bool = false) {
        let t = Toast(text: text, action: action.map { (label: $0.0, run: $0.1) },
                      duration: duration ?? (action == nil ? 2.2 : 8), game: game)
        toasts.append(t)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + t.duration) { [weak self] in
            self?.dismissToast(t.id)
        }
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    // MARK: navigation

    /// Open a game and go to the play screen. `resume`: put its session back
    /// in during the boot (the hero's Resume, a tile in Resume mode).
    func launch(_ entry: RomEntry, resume: Bool) {
        // No ROM here: Drive hands it back, or the person finds the file.
        if !entry.isLocal {
            if DriveSync.shared.driveHasRom(entry.fileName) { fetchThenLaunch(entry, resume: resume) }
            else { relinking = entry }
            return
        }
        toasts.removeAll { $0.game }
        let result = session.open(entry, resume: resume)
        guard result != .failed else {
            heroGame = heroGame.flatMap { library.entry(named: $0.fileName) }
            screen = .home
            toast("Couldn't start “\(entry.name)” — the file may not be a game", duration: 4)
            return
        }
        heroGame = entry
        menuOpen = false
        topbarOpen = false
        withAnimation(.easeOut(duration: 0.25)) { screen = .play }
        switch result {
        case .savedSince:
            toast("The game has saved since — starting from that save", duration: 4, game: true)
        case .resumeRejected(let why):
            toast(why + " Started from the in-game save instead.", duration: 6, game: true)
        case .ok where !resume:
            offerSession(entry)
        default:
            break
        }
    }

    /// Booted from the save with a session still standing: offer it (web
    /// offerAutoResume, "Last session saved 5m ago [Resume]").
    private func offerSession(_ entry: RomEntry) {
        guard let s = library.resumableSession(entry) else { return }
        toast("Last session saved \(Self.fmtAgo(s.meta.ts))", action: ("Resume", { [weak self] in
            guard let self, self.session.game == entry else { return }
            guard let now = self.library.resumableSession(entry) else {
                self.toast("The game has saved since — that session is gone")
                return
            }
            if self.session.apply(state: now.bytes, keepRewind: false) == nil {
                self.toast("Resumed")
            }
        }), duration: 8, game: true)
    }

    /// A tile tap (web openLibraryGame): the hero's game in memory resumes
    /// as it is; otherwise "Opening a game from the library" decides.
    func openLibraryGame(_ entry: RomEntry) {
        if session.game == entry {
            resumeFromHero()
            return
        }
        launch(entry, resume: settings.libraryOpen == .resume)
    }

    /// Back to the game in memory.
    func resumeFromHero() {
        guard session.game != nil else {
            if let h = heroGame { launch(h, resume: true) }
            return
        }
        menuOpen = false
        withAnimation(.easeOut(duration: 0.25)) { screen = .play }
        session.setPaused(false)
    }

    /// Main Menu: pause, store the picture and the session, flush the save,
    /// go home (web showMainMenu).
    func showMainMenu() {
        menuOpen = false
        topbarOpen = false
        session.setPaused(true)
        session.persistSession()
        session.storeLastFrame()
        dingbat_flush_save()
        toasts.removeAll { $0.game }
        withAnimation(.easeOut(duration: 0.25)) { screen = .home }
    }

    /// The paused hero's Close: the session is kept, the core goes.
    func closeGame() {
        session.close()
        library.refresh()
    }

    /// Whether opening the sheet paused the game, so its dismissal resumes
    /// it; a game the player had paused stays paused.
    var sheetPausedGame = false

    /// Whether the open menu paused the game (a controller's menu shortcut
    /// does; the hamburger does not), so closing it resumes.
    private var menuPausedGame = false

    func openMenu(paused: Bool) {
        if paused, session.game != nil, !session.paused {
            session.setPaused(true)
            menuPausedGame = true
        }
        withAnimation(.easeOut(duration: 0.15)) { menuOpen = true }
    }

    func closeMenu() {
        withAnimation(.easeOut(duration: 0.15)) { menuOpen = false }
        if menuPausedGame && sheet == nil && screen == .play { session.setPaused(false) }
        menuPausedGame = false
    }

    func toggleMenu() {
        if menuOpen { closeMenu() } else { openMenu(paused: false) }
    }

    func openSheet(_ s: Sheet) {
        menuOpen = false
        menuPausedGame = false
        sheetPausedGame = screen == .play && session.game != nil && !session.paused
        if sheetPausedGame { session.setPaused(true) }
        sheet = s
    }

    /// Ask whether games deleted on another device go here too (web
    /// confirmTombstones). True = Restore.
    @MainActor
    func confirmTombstones(_ games: [String]) async -> Bool {
        #if DEBUG
        // Dev hook for headless tests: `-answer-tombstones continue|restore`.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-answer-tombstones"), i + 1 < args.count {
            return args[i + 1] == "restore"
        }
        #endif
        tombstoneAnswer?.resume(returning: false)
        return await withCheckedContinuation { cont in
            tombstoneAnswer = cont
            tombstonePrompt = games
        }
    }

    func answerTombstones(restore: Bool) {
        tombstonePrompt = nil
        tombstoneAnswer?.resume(returning: restore)
        tombstoneAnswer = nil
    }

    // MARK: games with no ROM here

    /// A Drive-only game's tap (web fetchTileGame): down, then open. A tap
    /// on another tile meanwhile is the later word: this one just downloads.
    private func fetchThenLaunch(_ e: RomEntry, resume: Bool) {
        let name = e.fileName
        opening = name
        tileFailed.remove(name)
        Task { @MainActor in
            let ok = await DriveSync.shared.downloadGame(name)
            let mine = opening == name
            if mine { opening = nil }
            guard ok else { tileFailed.insert(name); return }
            if mine { launch(RomEntry(fileName: name), resume: resume) } else { markDone(name) }
        }
    }

    /// The tile's ↓ and the menu's Download to this device.
    func downloadOnly(_ e: RomEntry) {
        let name = e.fileName
        tileFailed.remove(name)
        Task { @MainActor in
            if await DriveSync.shared.downloadGame(name) { markDone(name) } else { tileFailed.insert(name) }
        }
    }

    private func markDone(_ name: String) {
        tileDone.insert(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tileDone.remove(name) }
    }

    /// Find the file: the picked bytes go under the game's own name, so its
    /// save pairs with it again (web relinkGameAction).
    func relink(_ e: RomEntry, to url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == e.ext else {
            toast("“\(e.name)” needs a .\(e.ext) file", duration: 4)
            return
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            toast("Couldn't read that file", duration: 4)
            return
        }
        let noted = library.romSize(e.fileName)
        if noted > 0 && noted != data.count {
            relinkConfirm = (e, data)
            return
        }
        finishRelink(e, data)
    }

    func finishRelink(_ e: RomEntry, _ data: Data) {
        relinkConfirm = nil
        do { try data.write(to: e.url, options: .atomic) } catch {
            toast("Couldn't keep that file", duration: 4)
            return
        }
        library.noteRomSize(e.fileName, data.count)
        DriveSync.shared.markGameUpload(e.fileName)
        library.pictureGen += 1
        library.refresh()
        toast("“\(e.name)” is back on this device")
    }

    // MARK: printer

    func printed(_ img: UIImage) {
        PrintStore.add(img)
        newPrints = true
        toast("Photo printed", action: ("View", { [weak self] in self?.openSheet(.prints) }), duration: 6)
    }

    static func fmtAgo(_ ts: Double) -> String {
        let m = Int(((Date().timeIntervalSince1970 * 1000 - ts) / 60000).rounded())
        if m < 1 { return "moments ago" }
        if m < 60 { return "\(m)m ago" }
        let h = Int((Double(m) / 60).rounded())
        if h < 48 { return "\(h)h ago" }
        return "\(Int((Double(h) / 24).rounded()))d ago"
    }
}

/// Game Boy Printer photos (web `prints`, newest first, up to 30).
enum PrintStore {
    static func all() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: RomLibrary.printsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func add(_ img: UIImage) {
        // 2x nearest neighbour, as the web gallery shows them.
        let size = CGSize(width: img.size.width * 2, height: img.size.height * 2)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let big = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        try? big.pngData()?.write(to: RomLibrary.printsDir.appendingPathComponent("print-\(stamp).png"))
        for old in all().dropFirst(30) { try? FileManager.default.removeItem(at: old) }
    }
}
