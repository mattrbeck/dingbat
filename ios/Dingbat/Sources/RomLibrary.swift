import Foundation
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static var gbaRom: UTType { UTType(importedAs: "com.mattrb.dingbat.gba") }
    static var gbRom: UTType { UTType(importedAs: "com.mattrb.dingbat.gb") }
    static var gbcRom: UTType { UTType(importedAs: "com.mattrb.dingbat.gbc") }
}

/// One game in the library. Its files are keyed by the ROM's file stem,
/// which the library keeps unique:
///
///   Documents/roms/<stem>.<ext>          the ROM (visible in the Files app)
///   Documents/roms/<stem>.sav            battery save (the core writes it)
///   Documents/states/<stem>.state        save-state slot 1 ("Quick")
///   Documents/states/<stem>.slotN.state  slots 2..9 (N = 1..8), + .png thumbs
///   Documents/sessions/<stem>.state      the session ("Resume"), + .json, .png
///   Documents/shots/<stem>.png           the library picture (last screen)
///   Documents/art/<stem>.png             box art from a zip
///   Documents/cheats/<stem>.cht          cheats (.cht text)
struct RomEntry: Identifiable, Equatable, Hashable {
    let url: URL

    var id: String { url.lastPathComponent }
    var fileName: String { url.lastPathComponent }
    var stem: String { url.deletingPathExtension().lastPathComponent }
    var name: String { stem }
    var ext: String { url.pathExtension.lowercased() }
    /// web systemOf(): .gba GBA; .gbc/.cgb GBC; anything else GB.
    var system: String {
        switch ext {
        case "gba": return "GBA"
        case "gbc", "cgb": return "GBC"
        default: return "GB"
        }
    }
    var isGBA: Bool { system == "GBA" }

    var bytes: Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }
    var sizeText: String { RomEntry.formatBytes(bytes) }

    static func formatBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        if bytes >= 1 << 20 { return String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) }
        return "\(max(1, bytes >> 10)) KB"
    }

    var saveURL: URL { url.deletingPathExtension().appendingPathExtension("sav") }
    func stateURL(slot: Int) -> URL {
        RomLibrary.statesDir.appendingPathComponent(slot == 0 ? "\(stem).state" : "\(stem).slot\(slot).state")
    }
    func stateThumbURL(slot: Int) -> URL {
        RomLibrary.statesDir.appendingPathComponent(slot == 0 ? "\(stem).png" : "\(stem).slot\(slot).png")
    }
    var sessionURL: URL { RomLibrary.sessionsDir.appendingPathComponent("\(stem).state") }
    var sessionMetaURL: URL { RomLibrary.sessionsDir.appendingPathComponent("\(stem).json") }
    var sessionPicURL: URL { RomLibrary.sessionsDir.appendingPathComponent("\(stem).png") }
    var shotURL: URL { RomLibrary.shotsDir.appendingPathComponent("\(stem).png") }
    var artURL: URL { RomLibrary.artDir.appendingPathComponent("\(stem).png") }
    var cheatsURL: URL { RomLibrary.cheatsDir.appendingPathComponent("\(stem).cht") }

    /// Every per-game file, for rename and delete.
    var allFiles: [URL] {
        var out = [url, saveURL, sessionURL, sessionMetaURL, sessionPicURL, shotURL, artURL, cheatsURL]
        for s in 0..<9 { out.append(stateURL(slot: s)); out.append(stateThumbURL(slot: s)) }
        return out
    }

    var hasSave: Bool {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: saveURL.path))?[.size] as? NSNumber else { return false }
        return n.intValue > 0
    }
}

/// What a session snapshot was taken with (web stateauto:<name> minus the
/// bytes, which sit in their own file).
struct SessionMeta: Codable {
    var ts: Double          // ms since 1970
    var saveSig: String?    // signature of the .sav the state carries
}

/// The library: ROM files plus a recency index (`library.json`, newest
/// first). ROMs dropped into Documents/roms by the Files app join on the
/// next refresh.
final class RomLibrary: ObservableObject {
    static let shared = RomLibrary()

    @Published private(set) var entries: [RomEntry] = []
    /// Bumped whenever a picture on disk changes, so tiles reload it.
    @Published var pictureGen = 0

    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let romsDir = docs.appendingPathComponent("roms", isDirectory: true)
    static let statesDir = docs.appendingPathComponent("states", isDirectory: true)
    static let sessionsDir = docs.appendingPathComponent("sessions", isDirectory: true)
    static let shotsDir = docs.appendingPathComponent("shots", isDirectory: true)
    static let artDir = docs.appendingPathComponent("art", isDirectory: true)
    static let cheatsDir = docs.appendingPathComponent("cheats", isDirectory: true)
    static let printsDir = docs.appendingPathComponent("prints", isDirectory: true)
    static let biosDir = docs.appendingPathComponent("bios", isDirectory: true)
    static let indexURL = docs.appendingPathComponent("library.json")
    static let gbaBiosURL = biosDir.appendingPathComponent("gba_bios.bin")
    static let gbcBootromURL = biosDir.appendingPathComponent("gbc_bootrom.bin")

    static let romExtensions: Set<String> = ["gba", "gb", "gbc", "cgb", "sgb"]

    private struct IndexEntry: Codable { var file: String; var ts: Double }
    private var recency: [String: Double] = [:]

    init() {
        for dir in [Self.romsDir, Self.statesDir, Self.sessionsDir, Self.shotsDir, Self.artDir,
                    Self.cheatsDir, Self.printsDir, Self.biosDir] {
            try? Self.ensureDir(dir)
        }
        if let data = try? Data(contentsOf: Self.indexURL),
           let idx = try? JSONDecoder().decode([IndexEntry].self, from: data) {
            for e in idx { recency[e.file] = e.ts }
        }
        refresh()
    }

    static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.romsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let roms = files.filter { Self.romExtensions.contains($0.pathExtension.lowercased()) }
        for f in roms where recency[f.lastPathComponent] == nil {
            // A file that arrived through the Files app: place it by its date.
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            recency[f.lastPathComponent] = (date ?? Date()).timeIntervalSince1970 * 1000
        }
        entries = roms
            .sorted { (recency[$0.lastPathComponent] ?? 0) > (recency[$1.lastPathComponent] ?? 0) }
            .map { RomEntry(url: $0) }
        saveIndex()
    }

    private func saveIndex() {
        let idx = entries.map { IndexEntry(file: $0.fileName, ts: recency[$0.fileName] ?? 0) }
        if let data = try? JSONEncoder().encode(idx) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    func lastPlayed(_ e: RomEntry) -> Double { recency[e.fileName] ?? 0 }

    /// A play moves the game to the front (web addRecentRom).
    func touch(_ e: RomEntry) {
        recency[e.fileName] = Date().timeIntervalSince1970 * 1000
        refresh()
    }

    func entry(named file: String) -> RomEntry? {
        entries.first { $0.fileName == file }
    }

    // MARK: import

    enum ImportError: LocalizedError {
        case unsupported, noRomInZip, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Unsupported file — pick a .gba, .gb, .gbc or a .zip"
            case .noRomInZip: return "No .gba, .gb or .gbc file inside that zip"
            case .unreadable(let m): return m
            }
        }
    }

    /// A free stem: "Name", else "Name (2)", ... (stems key every file).
    private func freeStem(_ stem: String, ext: String, replacing: String? = nil) -> String {
        let taken = Set(entries.map { $0.stem.lowercased() }).subtracting([replacing?.lowercased() ?? ""])
        if !taken.contains(stem.lowercased()) { return stem }
        var n = 2
        while taken.contains("\(stem) (\(n))".lowercased()) { n += 1 }
        return "\(stem) (\(n))"
    }

    /// Import from the document picker (security-scoped URL) or an Open-in.
    /// The same file name again replaces the ROM and keeps its saves.
    @discardableResult
    func importRom(from source: URL) throws -> RomEntry {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        let data: Data
        do { data = try Data(contentsOf: source) } catch {
            throw ImportError.unreadable("Couldn't read that file: \(error.localizedDescription)")
        }
        if ext == "zip" {
            guard let z = ZipReader.extractRom(from: data) else { throw ImportError.noRomInZip }
            let e = try add(romData: z.rom, fileName: z.name)
            if let art = z.art, let img = UIImage(data: art), let png = img.pngData() {
                try? png.write(to: e.artURL)
                pictureGen += 1
            }
            return e
        }
        guard Self.romExtensions.contains(ext) else { throw ImportError.unsupported }
        return try add(romData: data, fileName: source.lastPathComponent)
    }

    private func add(romData: Data, fileName: String) throws -> RomEntry {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let stem = (fileName as NSString).deletingPathExtension
        let existing = entries.first { $0.fileName.lowercased() == fileName.lowercased() }
        let finalStem = existing?.stem ?? freeStem(stem, ext: ext)
        let dest = Self.romsDir.appendingPathComponent("\(finalStem).\(ext)")
        do { try romData.write(to: dest, options: .atomic) } catch {
            throw ImportError.unreadable("Couldn't keep that file: \(error.localizedDescription)")
        }
        recency[dest.lastPathComponent] = Date().timeIntervalSince1970 * 1000
        refresh()
        return RomEntry(url: dest)
    }

    /// The homebrew demo shipped in the bundle is copied in once.
    func installBundledDemo() {
        let key = "demo-installed"
        guard !UserDefaults.standard.bool(forKey: key),
              let bundled = Bundle.main.url(forResource: "goodboy-demo-en", withExtension: "gba") else { return }
        UserDefaults.standard.set(true, forKey: key)
        let dest = Self.romsDir.appendingPathComponent(bundled.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.copyItem(at: bundled, to: dest)
        refresh()
    }

    // MARK: per-game actions

    /// web renameNameError: the validation for the Rename sheet.
    func renameError(_ e: RomEntry, to raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter a name" }
        if name.count > 100 { return "That name is too long" }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ||
           name.contains("/") || name.contains("\\") || name.contains(":") {
            return "A name can't contain / \\ or :"
        }
        if name.hasPrefix(".") { return "A name can't start with a dot" }
        if name == e.stem { return "That's already its name" }
        if entries.contains(where: { $0 != e && $0.stem.lowercased() == name.lowercased() }) {
            return "Another game already has that name"
        }
        return nil
    }

    /// Rename every file of the game in one go.
    @discardableResult
    func rename(_ e: RomEntry, to raw: String) -> RomEntry? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard renameError(e, to: name) == nil else { return nil }
        let fresh = RomEntry(url: Self.romsDir.appendingPathComponent("\(name).\(e.ext)"))
        let fm = FileManager.default
        for (from, to) in zip(e.allFiles, fresh.allFiles) where fm.fileExists(atPath: from.path) {
            try? fm.moveItem(at: from, to: to)
        }
        recency[fresh.fileName] = recency.removeValue(forKey: e.fileName) ?? Date().timeIntervalSince1970 * 1000
        refresh()
        pictureGen += 1
        return fresh
    }

    /// Reset save data: the battery save, every state and the session go.
    func resetSaveData(_ e: RomEntry) {
        let fm = FileManager.default
        var files = [e.saveURL, e.sessionURL, e.sessionMetaURL, e.sessionPicURL]
        for s in 0..<9 { files.append(e.stateURL(slot: s)); files.append(e.stateThumbURL(slot: s)) }
        for f in files { try? fm.removeItem(at: f) }
        pictureGen += 1
    }

    func hasSaveData(_ e: RomEntry) -> Bool {
        let fm = FileManager.default
        if e.hasSave || fm.fileExists(atPath: e.sessionURL.path) { return true }
        return (0..<9).contains { fm.fileExists(atPath: e.stateURL(slot: $0).path) }
    }

    func delete(_ e: RomEntry) {
        for f in e.allFiles { try? FileManager.default.removeItem(at: f) }
        recency.removeValue(forKey: e.fileName)
        refresh()
        pictureGen += 1
    }

    // MARK: sessions ("Resume")

    /// FNV-1a + length of the .sav (web saveSignature), nil with no save.
    static func saveSignature(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        var h: UInt32 = 0x811C9DC5
        for b in data { h ^= UInt32(b); h = h &* 0x0100_0193 }
        return "\(h):\(data.count)"
    }

    static func currentSaveSig(_ e: RomEntry) -> String? {
        saveSignature(try? Data(contentsOf: e.saveURL))
    }

    func sessionMeta(_ e: RomEntry) -> SessionMeta? {
        guard let data = try? Data(contentsOf: e.sessionMetaURL) else { return nil }
        return try? JSONDecoder().decode(SessionMeta.self, from: data)
    }

    /// The session where it can be resumed: one taken with the save stored
    /// now (web resumeSessionFor). A game that saved since boots from that
    /// save, so a snapshot can never roll an in-game save back.
    func resumableSession(_ e: RomEntry) -> (bytes: Data, meta: SessionMeta)? {
        guard let meta = sessionMeta(e), let bytes = try? Data(contentsOf: e.sessionURL),
              !bytes.isEmpty else { return nil }
        guard meta.saveSig == Self.currentSaveSig(e) else { return nil }
        return (bytes, meta)
    }

    /// The picture a tile or the closed hero shows: the session's own picture
    /// while it belongs to a resumable session, else the last screen, else
    /// the box art (nil: draw the cartridge).
    func picture(for e: RomEntry, preferSession: Bool) -> UIImage? {
        if preferSession, resumableSession(e) != nil,
           let img = UIImage(contentsOfFile: e.sessionPicURL.path) { return img }
        if let img = UIImage(contentsOfFile: e.shotURL.path) { return img }
        return nil
    }

    func art(for e: RomEntry) -> UIImage? { UIImage(contentsOfFile: e.artURL.path) }
}
