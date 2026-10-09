import Foundation
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static var gbaRom: UTType { UTType(importedAs: "com.mattrb.dingbat.gba") }
    static var gbRom: UTType { UTType(importedAs: "com.mattrb.dingbat.gb") }
    static var gbcRom: UTType { UTType(importedAs: "com.mattrb.dingbat.gbc") }
    static var ndsRom: UTType { UTType(importedAs: "com.mattrb.dingbat.nds") }
}

/// One game in the library, named as the web names it: the ROM's file name,
/// extension and all ("Pokemon Emerald.gba"). Every record of the game is
/// keyed by it, as the web's IndexedDB keys and Drive's file names are
/// ("save:Pokemon Emerald.gba"), so the two stay one library:
///
///   Documents/roms/<name>                    the ROM (visible in Files)
///   games/<name>/rom.<ext>                   a link to it, which the core loads
///   games/<name>/rom.sav                     battery save   (save:<name>)
///   games/<name>/state<N>.state              slot N+1        (state:<name>[:slotN])
///   games/<name>/state<N>.meta.json          its thumbnail   (statemeta:...)
///   games/<name>/session.state|.json|.jpg    the session     (stateauto:<name>)
///   games/<name>/frame.jpg                   last screen     (frame:<name>)
///   games/<name>/art.png, cheats.cht         box art, cheats (this device only)
///   games/<name>/oldsave.json                a kept save     (oldsave:<name>)
///
/// games/ lives in Application Support. A game can be in the library with no
/// ROM here: on Drive only (downloads on demand) or missing.
struct RomEntry: Identifiable, Equatable, Hashable {
    /// The web's game name, the key of every record.
    let fileName: String

    init(fileName: String) { self.fileName = fileName }

    var id: String { fileName }
    var stem: String { (fileName as NSString).deletingPathExtension }
    /// What the person sees (web displayName).
    var name: String { stem }
    var ext: String { (fileName as NSString).pathExtension.lowercased() }
    /// web systemOf(): .gba GBA; .nds DS; .gbc/.cgb GBC; anything else GB.
    var system: String {
        switch ext {
        case "gba": return "GBA"
        case "nds": return "DS"
        case "gbc", "cgb": return "GBC"
        default: return "GB"
        }
    }
    var isGBA: Bool { system == "GBA" }
    /// A Nintendo DS game (web isNdsRomName): its own core, its own screens
    /// and controls, and nothing of it on Drive.
    var isNDS: Bool { system == "DS" }

    var url: URL { RomLibrary.romsDir.appendingPathComponent(fileName) }
    var dir: URL { RomLibrary.gamesDir.appendingPathComponent(fileName, isDirectory: true) }
    /// The path the core loads: a link to the ROM inside the game's folder, so
    /// the battery save it writes beside it (rom.sav) is this game's alone.
    var coreURL: URL { dir.appendingPathComponent("rom." + (ext.isEmpty ? "gb" : ext)) }
    var saveURL: URL { dir.appendingPathComponent("rom.sav") }
    func stateURL(slot: Int) -> URL { dir.appendingPathComponent("state\(slot).state") }
    func stateMetaURL(slot: Int) -> URL { dir.appendingPathComponent("state\(slot).meta.json") }
    var sessionURL: URL { dir.appendingPathComponent("session.state") }
    var sessionMetaURL: URL { dir.appendingPathComponent("session.json") }
    var sessionPicURL: URL { dir.appendingPathComponent("session.jpg") }
    var shotURL: URL { dir.appendingPathComponent("frame.jpg") }
    var artURL: URL { dir.appendingPathComponent("art.png") }
    var cheatsURL: URL { dir.appendingPathComponent("cheats.cht") }
    var oldSaveURL: URL { dir.appendingPathComponent("oldsave.json") }

    /// The ROM file is on this device.
    var isLocal: Bool { FileManager.default.fileExists(atPath: url.path) }

    var bytes: Int {
        if let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
            return n.intValue
        }
        return RomLibrary.shared.romSize(fileName)
    }
    var sizeText: String { RomEntry.formatBytes(bytes) }

    static func formatBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        if bytes >= 1 << 20 { return String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) }
        return "\(max(1, bytes >> 10)) KB"
    }

    var hasSave: Bool {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: saveURL.path))?[.size] as? NSNumber else { return false }
        return n.intValue > 0
    }
}

/// A session snapshot's header (web stateauto:<name> minus the bytes): the
/// JSON a session's Drive file carries, kept verbatim in session.json.
struct SessionMeta {
    var ts: Double                // ms since 1970
    /// The .sav signature the state carries. `nil` with `hasSaveSig` true is
    /// "taken with no save" and counts; absent is a snapshot from before the
    /// signature existed, never offered.
    var saveSig: String?
    var hasSaveSig: Bool
    var by: String?               // the device that took it (web deviceId)
    var dev: String?              // what kind of device ("iPhone")

    init(ts: Double, saveSig: String?, by: String?, dev: String?) {
        self.ts = ts
        self.saveSig = saveSig
        self.hasSaveSig = true
        self.by = by
        self.dev = dev
    }

    init?(json: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let ts = (o["ts"] as? NSNumber)?.doubleValue else { return nil }
        self.ts = ts
        self.hasSaveSig = o.keys.contains("saveSig")
        self.saveSig = o["saveSig"] as? String
        self.by = o["by"] as? String
        self.dev = o["dev"] as? String
    }

    /// The bundle header as the web writes it (sessionBundle): ts, saveSig,
    /// by, dev and the two lengths, in that order.
    func header(state: Int, pic: Int) -> Data {
        var o = JSObject()
        o["ts"] = .number(ts)
        if hasSaveSig { o["saveSig"] = saveSig.map { .string($0) } ?? .null }
        o["by"] = by.map { .string($0) } ?? .null
        o["dev"] = dev.map { .string($0) } ?? .null
        o["state"] = .number(Double(state))
        o["pic"] = .number(Double(pic))
        return JSValue.object(o).data()
    }
}

/// The library: the recency index ("recent" on the web: newest first,
/// `{ name, ts, imp?, gen? }`, the list the Drive library merges), the ROM
/// files, and every per-game record. Main thread only.
final class RomLibrary: ObservableObject {
    static let shared = RomLibrary()

    @Published private(set) var entries: [RomEntry] = []
    /// Bumped whenever a picture on disk changes, so tiles reload it.
    @Published var pictureGen = 0

    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("dingbat", isDirectory: true)
    }()
    static let romsDir = docs.appendingPathComponent("roms", isDirectory: true)
    static let gamesDir = support.appendingPathComponent("games", isDirectory: true)
    static let printsDir = docs.appendingPathComponent("prints", isDirectory: true)
    static let biosDir = support.appendingPathComponent("bios", isDirectory: true)
    static let recentURL = support.appendingPathComponent("recent.json")
    static let romSizesURL = support.appendingPathComponent("romsizes.json")
    static let gbaBiosURL = biosDir.appendingPathComponent("gba_bios.bin")
    static let gbcBootromURL = biosDir.appendingPathComponent("gbc_bootrom.bin")

    static let romExtensions: Set<String> = ["gba", "gb", "gbc", "cgb", "sgb", "nds"]

    /// web NdsUtil.isNdsName.
    static func isNdsName(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "nds"
    }

    /// The recency index, newest first. Changed only through `updateRecent`.
    private(set) var recents: [JSObject] = []
    private var romSizes: [String: Int] = [:]

    init() {
        for dir in [Self.romsDir, Self.gamesDir, Self.printsDir, Self.biosDir] {
            try? Self.ensureDir(dir)
        }
        // Application Support is backed up, but nothing in it is the person's
        // to browse; keep Files showing only roms/ and prints/.
        LegacyLayout.migrate()
        if let data = try? Data(contentsOf: Self.recentURL),
           let arr = JSValue.parse(data)?.arrayValue {
            recents = arr.compactMap { v in
                guard let o = v.objectValue, let n = o.string("name"), !n.isEmpty else { return nil }
                return Lib.entry(name: n, ts: o.number("ts") ?? 0, imp: o.number("imp"), gen: Lib.gen(o))
            }
        }
        if let data = try? Data(contentsOf: Self.romSizesURL),
           let o = try? JSONDecoder().decode([String: Int].self, from: data) {
            romSizes = o
        }
        refresh()
    }

    static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: the index

    /// ROMs that arrived in Documents/roms through the Files app join the
    /// index as imports; the grid is the index.
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.romsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var added: [RomEntry] = []
        for f in files where Self.romExtensions.contains(f.pathExtension.lowercased()) {
            let name = f.lastPathComponent
            if !recents.contains(where: { $0.string("name") == name }) {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let ts = ((date ?? Date()).timeIntervalSince1970 * 1000).rounded()
                recents.append(Lib.entry(name: name, ts: ts, imp: ts, gen: 0))
                added.append(RomEntry(fileName: name))
            }
        }
        if !added.isEmpty {
            recents.sort { ($0.number("ts") ?? 0) > ($1.number("ts") ?? 0) }
            saveRecents()
            for e in added { DriveSync.shared.markGameUpload(e.fileName) }
        }
        publish()
    }

    private func publish() {
        entries = recents.compactMap { $0.string("name") }.map { RomEntry(fileName: $0) }
    }

    private func saveRecents() {
        try? Self.ensureDir(Self.support)
        try? JSValue.array(recents.map { .object($0) }).data().write(to: Self.recentURL, options: .atomic)
    }

    private var recentChain: Task<Void, Never>?

    /// Every change to the index goes through here, one at a time, each
    /// starting from the list the one before left (web updateRecent): an
    /// import, a play, a delete, a rename and both sync commits all read,
    /// change and write it back with awaits in between. `fn` returns the new
    /// list, or nil to leave it.
    @MainActor
    @discardableResult
    func updateRecent(_ fn: @escaping @MainActor ([JSObject]) async throws -> [JSObject]?) async rethrows -> [JSObject]? {
        let prev = recentChain
        var result: [JSObject]?
        var failure: Error?
        let task = Task { @MainActor in
            await prev?.value
            do {
                if let next = try await fn(self.recents) {
                    self.recents = next
                    self.saveRecents()
                    self.publish()
                    result = next
                }
            } catch { failure = error }
        }
        recentChain = task
        await task.value
        if let failure { try { throw failure }() }
        return result
    }

    func lastPlayed(_ e: RomEntry) -> Double {
        recents.first { $0.string("name") == e.fileName }?.number("ts") ?? 0
    }

    func gen(of name: String) -> Int {
        recents.first { $0.string("name") == name }.map(Lib.gen) ?? 0
    }

    func entry(named file: String) -> RomEntry? {
        entries.first { $0.fileName == file }
    }

    /// Move a game to the front (web bumpRecentIndex). `fresh` is a real
    /// import: a new claim on the name (`imp`), and the next generation after
    /// one this device deleted. `atLeast` raises the generation (a download of
    /// files written for a newer one).
    @MainActor
    func bump(_ name: String, fresh: Bool = false, gen atLeast: Int = 0) async {
        await updateRecent { all in
            DriveSync.shared.renamedAway.remove(name)
            let prev = all.first { $0.string("name") == name }
            var list = all.filter { $0.string("name") != name }
            var ts = (Date().timeIntervalSince1970 * 1000).rounded()
            // A relaunch under a not-yet-applied rename marker must not
            // outrank it; a re-import is a new claim.
            if !fresh, let m = DriveSync.shared.state.ren.first(where: { $0.from == name }),
               m.ts != 0, ts >= m.ts {
                ts = m.ts - 1
            }
            let imp = fresh ? ts : prev?.number("imp")
            var gen = max(prev.map(Lib.gen) ?? 0, atLeast)
            if fresh, let t = DriveSync.shared.state.tomb.first(where: { $0.name == name }) {
                gen = max(gen, t.gen + 1)
            }
            list.insert(Lib.entry(name: name, ts: ts, impFirst: imp, gen: gen), at: 0)
            return list
        }
    }

    /// A play moves the game to the front.
    func touch(_ e: RomEntry) {
        Task { @MainActor in await bump(e.fileName) }
    }

    // MARK: sizes

    func romSize(_ name: String) -> Int { romSizes[name] ?? 0 }

    func noteRomSize(_ name: String, _ n: Int) {
        guard n > 0, romSizes[name] != n else { return }
        romSizes[name] = n
        if let data = try? JSONEncoder().encode(romSizes) { try? data.write(to: Self.romSizesURL, options: .atomic) }
    }

    // MARK: import

    enum ImportError: LocalizedError {
        case unsupported, noRomInZip, unreadable(String), declined
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Unsupported file — pick a .gba, .gb, .gbc, .nds or a .zip"
            case .noRomInZip: return "No .gba, .gb, .gbc or .nds file inside that zip"
            case .unreadable(let m): return m
            case .declined: return nil
            }
        }
    }

    // ROM header sanity check (web looksLikeValidRom). Any signal matches
    // (homebrew is often raw objcopy output with no logo and an unfixed
    // checksum), and a failed check only asks, never blocks:
    //   .gba     byte 3 is 0xEA (ARM branch entry), OR the Nintendo logo at
    //            0x004, OR the header checksum at 0xBD (GBATEK).
    //   .gb/.gbc the Nintendo logo at 0x104, OR the header checksum at 0x14D
    //            (Pan Docs).
    private static let gbaLogoPrefix: [UInt8] = [0x24, 0xff, 0xae, 0x51, 0x69, 0x9a, 0xa2, 0x21]
    private static let gbLogoPrefix: [UInt8] = [0xce, 0xed, 0x66, 0x66, 0xcc, 0x0d, 0x00, 0x0b]

    static func looksLikeValidRom(_ d: Data, ext: String) -> Bool {
        if ext == "nds" { return NdsUtil.looksLikeNdsRom(d) }
        let b = [UInt8](d.prefix(0x150))
        func at(_ off: Int, _ ref: [UInt8]) -> Bool {
            off + ref.count <= b.count && ref.indices.allSatisfy { b[off + $0] == ref[$0] }
        }
        if ext == "gba" {
            if b.count >= 4 && b[3] == 0xea { return true }
            if b.count < 0xc0 { return false }
            if at(0x004, gbaLogoPrefix) { return true }
            var sum = 0
            for i in 0xa0...0xbc { sum += Int(b[i]) }
            return Int(b[0xbd]) == (-(sum + 0x19)) & 0xff
        }
        if b.count < 0x150 { return false }
        if at(0x104, gbLogoPrefix) { return true }
        var chk = 0
        for i in 0x134...0x14c { chk = (chk - Int(b[i]) - 1) & 0xff }
        return Int(b[0x14d]) == chk
    }

    /// The question before a suspect ROM is kept (web confirmSuspectRom).
    @MainActor
    static func confirmSuspect(_ d: Data, name: String, ext: String) async -> Bool {
        if looksLikeValidRom(d, ext: ext) { return true }
        let system = ext == "gba" ? "GBA" : ext == "nds" ? "Nintendo DS"
            : ext == "gbc" || ext == "cgb" ? "Game Boy Color" : "Game Boy"
        return await AppModel.shared.askRomWarn(
            "File Check Failed",
            "\"\(name)\" doesn't look like a valid \(system) ROM — it may be corrupt or not a game at all. Load it anyway?")
    }

    /// Import from the document picker (security-scoped URL) or an Open-in.
    /// The same file name again replaces the ROM and keeps its saves (the web
    /// keys games by file name too).
    @discardableResult
    @MainActor
    func importRom(from source: URL) async throws -> RomEntry {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        let data: Data
        do { data = try Data(contentsOf: source) } catch {
            throw ImportError.unreadable("Couldn't read that file: \(error.localizedDescription)")
        }
        if ext == "zip" {
            guard let z = ZipReader.extractRom(from: data) else { throw ImportError.noRomInZip }
            let inner = (z.name as NSString).pathExtension.lowercased()
            guard await Self.confirmSuspect(z.rom, name: z.name, ext: inner) else { throw ImportError.declined }
            let e = try await add(romData: z.rom, fileName: z.name)
            if let art = z.art, let img = UIImage(data: art), let png = img.pngData() {
                try? Self.ensureDir(e.dir)
                try? png.write(to: e.artURL)
                pictureGen += 1
            }
            return e
        }
        guard Self.romExtensions.contains(ext) else { throw ImportError.unsupported }
        guard await Self.confirmSuspect(data, name: source.lastPathComponent, ext: ext) else {
            throw ImportError.declined
        }
        return try await add(romData: data, fileName: source.lastPathComponent)
    }

    /// Bytes first, index second (web addRecentRom).
    @MainActor
    func add(romData: Data, fileName: String) async throws -> RomEntry {
        let e = RomEntry(fileName: fileName)
        do { try romData.write(to: e.url, options: .atomic) } catch {
            throw ImportError.unreadable("Couldn't keep that file: \(error.localizedDescription)")
        }
        noteRomSize(fileName, romData.count)
        await bump(fileName, fresh: true)
        DriveSync.shared.markGameUpload(fileName)
        return e
    }

    /// Builds before this one put the web embed's demo game in the library on
    /// first run (and, signed in, on Drive). It is the embed's alone: where
    /// this app put it there, it goes again, from Drive too, once.
    @MainActor
    func removeInstalledDemo() async {
        let d = UserDefaults.standard
        guard d.bool(forKey: "demo-installed") else { return }
        d.removeObject(forKey: "demo-installed")
        let e = RomEntry(fileName: "goodboy-demo-en.gba")
        guard entries.contains(e) else { return }
        if GameSession.shared.game == e { GameSession.shared.discard() }
        if AppModel.shared.heroGame == e { AppModel.shared.heroGame = nil }
        await delete(e)
    }

    /// The link the core loads, pointed at the ROM afresh (the app's
    /// container path changes between installs).
    func prepareCoreLink(_ e: RomEntry) -> URL? {
        guard e.isLocal else { return nil }
        let fm = FileManager.default
        try? Self.ensureDir(e.dir)
        try? fm.removeItem(at: e.coreURL)
        do { try fm.createSymbolicLink(at: e.coreURL, withDestinationURL: e.url) } catch { return nil }
        return e.coreURL
    }

    // MARK: per-game records (web perGameKeys)

    static let numStateSlots = 9

    static func slotStateKey(_ name: String, _ slot: Int) -> String {
        slot == 0 ? "state:" + name : "state:\(name):slot\(slot)"
    }
    static func slotMetaKey(_ name: String, _ slot: Int) -> String {
        slot == 0 ? "statemeta:" + name : "statemeta:\(name):slot\(slot)"
    }

    struct GameKeys {
        var bytes: [String], saves: [String], session: [String], prefs: [String], kept: [String]
        var all: [String] { bytes + saves + session + prefs + kept }
    }

    static func perGameKeys(_ name: String) -> GameKeys {
        var saves = ["save:" + name, "save:" + name + "-p2"]
        for s in 0..<numStateSlots { saves += [slotStateKey(name, s), slotMetaKey(name, s)] }
        return GameKeys(bytes: ["rom:" + name, "art:" + name, "frame:" + name],
                        saves: saves,
                        session: ["stateauto:" + name, "sessionpic:" + name],
                        prefs: ["cheats:" + name],
                        kept: ["oldsave:" + name])
    }

    /// The file(s) a key is stored in. A session is three files; the others one.
    static func files(forKey k: String) -> [URL] {
        func game(_ prefix: String) -> RomEntry? {
            k.hasPrefix(prefix) ? RomEntry(fileName: String(k.dropFirst(prefix.count))) : nil
        }
        if let e = game("rom:") { return [e.url] }
        if let e = game("art:") { return [e.artURL] }
        if let e = game("frame:") { return [e.shotURL] }
        if let e = game("cheats:") { return [e.cheatsURL] }
        if let e = game("oldsave:") { return [e.oldSaveURL] }
        if let e = game("stateauto:") { return [e.sessionURL, e.sessionMetaURL, e.sessionPicURL] }
        if let e = game("sessionpic:") { return [e.sessionPicURL] }
        if k.hasPrefix("save:") {
            let g = String(k.dropFirst(5))
            if g.hasSuffix("-p2") {
                return [RomEntry(fileName: String(g.dropLast(3))).dir.appendingPathComponent("rom-p2.sav")]
            }
            return [RomEntry(fileName: g).saveURL]
        }
        for (prefix, meta) in [("statemeta:", true), ("state:", false)] where k.hasPrefix(prefix) {
            var g = String(k.dropFirst(prefix.count))
            var slot = 0
            if let r = g.range(of: #":slot(\d+)$"#, options: .regularExpression) {
                slot = Int(g[r].dropFirst(5)) ?? 0
                g = String(g[..<r.lowerBound])
            }
            let e = RomEntry(fileName: g)
            return [meta ? e.stateMetaURL(slot: slot) : e.stateURL(slot: slot)]
        }
        return []
    }

    static func hasKey(_ k: String) -> Bool {
        guard let f = files(forKey: k).first else { return false }
        return FileManager.default.fileExists(atPath: f.path)
    }

    /// Remove keys (web deleteKeys).
    static func deleteKeys(_ keys: [String]) {
        for k in keys {
            for f in files(forKey: k) { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Anything of the game on this device besides the picture a pull
    /// brought (web holdsGame).
    func holdsGame(_ name: String) -> Bool {
        Self.perGameKeys(name).all.contains { $0 != "frame:" + name && Self.hasKey($0) }
    }

    func hasAnyLocalRecord(_ name: String) -> Bool {
        Self.perGameKeys(name).all.contains { Self.hasKey($0) }
    }

    // MARK: per-game actions

    /// web renameNameError: the validation for the Rename sheet. `raw` is
    /// the new name without its extension, which is kept.
    func renameError(_ e: RomEntry, to raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter a name" }
        if name.count > 100 { return "That name is too long" }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ||
           name.contains("/") || name.contains("\\") || name.contains(":") {
            return "A name can't contain / \\ or :"
        }
        if name.hasPrefix(".") { return "A name can't start with a dot" }
        if name.lowercased().hasSuffix("-p2") { return "A name can't end in “-p2”" }
        if name == e.stem { return "That's already its name" }
        let full = name + "." + (e.fileName as NSString).pathExtension
        if recents.contains(where: { $0.string("name") == full }) ||
            Self.perGameKeys(full).all.contains(where: Self.hasKey) {
            return "Another game already has that name"
        }
        return nil
    }

    /// Rename every record of the game in one go (web renameGame); Drive
    /// renames its files in place and other devices follow the marker.
    @MainActor
    @discardableResult
    func rename(_ e: RomEntry, to raw: String) async -> RomEntry? {
        let stem = raw.trimmingCharacters(in: .whitespaces)
        guard renameError(e, to: stem) == nil else { return nil }
        let newName = stem + "." + (e.fileName as NSString).pathExtension
        let fresh = RomEntry(fileName: newName)
        let ts = (Date().timeIntervalSince1970 * 1000).rounded()
        await updateRecent { recents in
            DriveSync.shared.renameLocal(from: e.fileName, to: newName, ts: ts)
            Self.moveRecords(from: e.fileName, to: newName)
            PrintStore.rename(from: e.fileName, to: newName)
            Checkpoints.move(from: e, to: fresh)
            CrashWatch.forget(e.fileName)
            guard let old = recents.first(where: { $0.string("name") == e.fileName }) else { return nil }
            var list = recents.filter { $0.string("name") != e.fileName }
            list.insert(Lib.entry(name: newName, ts: ts, impFirst: ts, gen: Lib.gen(old)), at: 0)
            return list
        }
        if let size = romSizes[e.fileName] { noteRomSize(newName, size) }
        pictureGen += 1
        DriveSync.shared.scheduleFlush()
        return fresh
    }

    /// Move every record of `from` to `to`. Collisions are skipped (left in
    /// place); returns the pairs skipped.
    @discardableResult
    static func moveRecords(from: String, to: String) -> [(String, String)] {
        let fm = FileManager.default
        let fk = perGameKeys(from).all, tk = perGameKeys(to).all
        var skipped: [(String, String)] = []
        try? ensureDir(RomEntry(fileName: to).dir)
        for (f, t) in zip(fk, tk) where f != "sessionpic:" + from {
            let src = files(forKey: f), dst = files(forKey: t)
            guard src.contains(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            if dst.contains(where: { fm.fileExists(atPath: $0.path) }) { skipped.append((f, t)); continue }
            for (s, d) in zip(src, dst) where fm.fileExists(atPath: s.path) { try? fm.moveItem(at: s, to: d) }
        }
        let oldDir = RomEntry(fileName: from).dir
        try? fm.removeItem(at: RomEntry(fileName: from).coreURL)
        if let left = try? fm.contentsOfDirectory(atPath: oldDir.path), left.isEmpty {
            try? fm.removeItem(at: oldDir)
        }
        return skipped
    }

    /// Reset save data: the battery save, every state and the session go
    /// (web resetGameSaves / deleteSaveData); Drive is told first.
    func resetSaveData(_ e: RomEntry) {
        DriveSync.shared.queueSaveDataDeletes(e.fileName)
        let k = Self.perGameKeys(e.fileName)
        Self.deleteKeys(k.saves + k.session)
        Checkpoints.delete(e)
        CrashWatch.forget(e.fileName)
        pictureGen += 1
    }

    func hasSaveData(_ e: RomEntry) -> Bool {
        let k = Self.perGameKeys(e.fileName)
        return (k.saves + k.session).contains(where: Self.hasKey)
    }

    /// Delete everywhere (web deleteGameEverywhere): every record goes, and
    /// a tombstone tells the other devices.
    @MainActor
    func delete(_ e: RomEntry) async {
        let name = e.fileName
        DriveSync.shared.markDeleteAll(Self.perGameKeys(name).all)
        Self.deleteKeys(Self.perGameKeys(name).all)
        try? FileManager.default.removeItem(at: e.dir)
        CrashWatch.forget(name)
        await updateRecent { list in
            DriveSync.shared.addTombstone(name, gen: list.first { $0.string("name") == name }.map(Lib.gen) ?? 0)
            return list.filter { $0.string("name") != name }
        }
        DriveSync.shared.saveState()
        DriveSync.shared.scheduleFlush()
        pictureGen += 1
    }

    /// Drop the entry and every record here, Drive untouched (a tombstone
    /// from another device, web deleteGameLocalData).
    func deleteLocalData(_ name: String) {
        let e = RomEntry(fileName: name)
        Self.deleteKeys(Self.perGameKeys(name).all)
        try? FileManager.default.removeItem(at: e.dir)
        pictureGen += 1
    }

    // MARK: sessions ("Resume")

    /// FNV-1a + length of the .sav (web saveSignature), nil with no save.
    static func saveSignature(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        var h: UInt32 = 0x811C9DC5
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { h ^= UInt32(b); h = h &* 0x0100_0193 }
        }
        return "\(h):\(data.count)"
    }

    static func currentSaveSig(_ e: RomEntry) -> String? {
        saveSignature(try? Data(contentsOf: e.saveURL))
    }

    func sessionMeta(_ e: RomEntry) -> SessionMeta? {
        guard let data = try? Data(contentsOf: e.sessionMetaURL) else { return nil }
        return SessionMeta(json: data)
    }

    /// The session where it can be resumed: one taken with the save stored
    /// now (web resumeSessionFor). A game that saved since boots from that
    /// save, so a snapshot can never roll an in-game save back.
    func resumableSession(_ e: RomEntry) -> (bytes: Data, meta: SessionMeta)? {
        guard let meta = sessionMeta(e), meta.hasSaveSig,
              let bytes = try? Data(contentsOf: e.sessionURL), !bytes.isEmpty else { return nil }
        guard meta.saveSig == Self.currentSaveSig(e) else { return nil }
        return (bytes, meta)
    }

    /// The picture a tile or the closed hero shows: the session's own picture
    /// while it belongs to a resumable session, else the last screen (nil:
    /// box art or the cartridge).
    func picture(for e: RomEntry, preferSession: Bool) -> UIImage? {
        if preferSession, resumableSession(e) != nil,
           let img = UIImage(contentsOfFile: e.sessionPicURL.path) { return img }
        return UIImage(contentsOfFile: e.shotURL.path)
    }

    func art(for e: RomEntry) -> UIImage? { UIImage(contentsOfFile: e.artURL.path) }

    /// The picture taken with the session (what a resume lands on).
    func sessionPicture(_ e: RomEntry) -> UIImage? { UIImage(contentsOfFile: e.sessionPicURL.path) }
}

/// Library entries (web `recent`), built in the web's key order so the
/// shared library file serializes as the web's does.
enum Lib {
    static func gen(_ o: JSObject) -> Int {
        guard let g = o.number("gen"), g > 0, g == g.rounded() else { return 0 }
        return Int(g)
    }

    /// withGen({ name, ts }, gen) with `imp` set after (mergeLibrary's order).
    static func entry(name: String, ts: Double, imp: Double?, gen: Int) -> JSObject {
        var o = JSObject([("name", .string(name)), ("ts", .number(ts))])
        if gen > 0 { o["gen"] = .number(Double(gen)) }
        if let imp, imp != 0 { o["imp"] = .number(imp) }
        return o
    }

    /// withGen(imp ? { name, ts, imp } : { name, ts }, gen) (bumpRecentIndex's
    /// and renameGame's order).
    static func entry(name: String, ts: Double, impFirst imp: Double?, gen: Int) -> JSObject {
        var o = JSObject([("name", .string(name)), ("ts", .number(ts))])
        if let imp, imp != 0 { o["imp"] = .number(imp) }
        if gen > 0 { o["gen"] = .number(Double(gen)) }
        return o
    }
}

/// The layout before Drive (files keyed by the stem in Documents/states,
/// sessions, shots...), moved under the web's keys once.
enum LegacyLayout {
    static func migrate() {
        let fm = FileManager.default
        let docs = RomLibrary.docs
        let key = "layout-v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }
        let roms = (try? fm.contentsOfDirectory(at: RomLibrary.romsDir, includingPropertiesForKeys: nil)) ?? []
        for rom in roms where RomLibrary.romExtensions.contains(rom.pathExtension.lowercased()) {
            let stem = rom.deletingPathExtension().lastPathComponent
            let e = RomEntry(fileName: rom.lastPathComponent)
            try? RomLibrary.ensureDir(e.dir)
            func move(_ from: URL, _ to: URL) {
                if fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
            }
            move(rom.deletingPathExtension().appendingPathExtension("sav"), e.saveURL)
            let states = docs.appendingPathComponent("states")
            for s in 0..<RomLibrary.numStateSlots {
                move(states.appendingPathComponent(s == 0 ? "\(stem).state" : "\(stem).slot\(s).state"), e.stateURL(slot: s))
                try? fm.removeItem(at: states.appendingPathComponent(s == 0 ? "\(stem).png" : "\(stem).slot\(s).png"))
            }
            let sessions = docs.appendingPathComponent("sessions")
            move(sessions.appendingPathComponent("\(stem).state"), e.sessionURL)
            move(sessions.appendingPathComponent("\(stem).json"), e.sessionMetaURL)
            try? fm.removeItem(at: sessions.appendingPathComponent("\(stem).png"))
            let shot = docs.appendingPathComponent("shots/\(stem).png")
            if let img = UIImage(contentsOfFile: shot.path), let jpg = img.jpegData(compressionQuality: 0.75) {
                try? jpg.write(to: e.shotURL)
            }
            try? fm.removeItem(at: shot)
            move(docs.appendingPathComponent("art/\(stem).png"), e.artURL)
            move(docs.appendingPathComponent("cheats/\(stem).cht"), e.cheatsURL)
        }
        for d in ["states", "sessions", "shots", "art", "cheats", "bios"] {
            let dir = docs.appendingPathComponent(d)
            if d == "bios" {
                for f in ["gba_bios.bin", "gbc_bootrom.bin"] {
                    let from = dir.appendingPathComponent(f)
                    let to = RomLibrary.biosDir.appendingPathComponent(f)
                    if fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
                }
            }
            if let left = try? fm.contentsOfDirectory(atPath: dir.path), left.isEmpty { try? fm.removeItem(at: dir) }
        }
        // The old recency index (file + ts) seeds the new one.
        let old = docs.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: old),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           !fm.fileExists(atPath: RomLibrary.recentURL.path) {
            let list: [JSValue] = arr.compactMap { o in
                guard let f = o["file"] as? String else { return nil }
                let ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
                return .object(Lib.entry(name: f, ts: ts.rounded(), imp: nil, gen: 0))
            }
            try? RomLibrary.ensureDir(RomLibrary.support)
            try? JSValue.array(list).data().write(to: RomLibrary.recentURL)
        }
        try? fm.removeItem(at: old)
    }
}
