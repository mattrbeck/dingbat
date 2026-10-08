// Export… (web index.js "Export"): one game's files, out of the app. The
// tile menu's Export… lists every kind of file the game has here, one
// checkbox each, ticked as last time; the ROM always starts unticked (the
// person most likely has it, and it is the one big file). A kind the game
// has nothing of is not offered. One file goes out as itself; more go out as
// one .zip with an info.json saying what each file is. Every state kind
// (the slots, where you left off, earlier moments) is one choice: none opens
// anywhere but dingbat.
//
// Where the web downloads, the app writes the file to its Exports folder
// (Files › dingbat › Exports) and offers the share sheet.
import Foundation
import UIKit

enum GameExport {
    struct File {
        /// Where it sits in the zip.
        var path: String
        var data: Data
        /// Its name when it goes out alone.
        var solo: String?
    }

    struct Item: Identifiable {
        let kind: String
        let group: String
        let label: String
        let sub: String
        let files: [File]
        var id: String { kind }
        var size: Int { files.reduce(0) { $0 + $1.data.count } }
    }

    static let statesDir = "dingbat save states/"
    /// Headings are clutter over a short list; from this many rows they group it.
    static let sectionMin = 5
    static var exportsDir: URL { RomLibrary.docs.appendingPathComponent("Exports", isDirectory: true) }

    private static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) " + (n == 1 ? one : many ?? one + "s")
    }

    private static func read(_ url: URL) -> Data? {
        guard let d = try? Data(contentsOf: url), !d.isEmpty else { return nil }
        return d
    }

    /// A data URL's bytes and extension (a slot's thumbnail).
    private static func dataURL(_ s: String?) -> (ext: String, data: Data)? {
        guard let s, s.hasPrefix("data:"), let comma = s.firstIndex(of: ","),
              s[..<comma].hasSuffix(";base64"),
              let d = Data(base64Encoded: String(s[s.index(after: comma)...])), !d.isEmpty else { return nil }
        let mime = String(s[s.index(s.startIndex, offsetBy: 5)..<comma].dropLast(7))
        let ext = ["image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp", "image/gif": ".gif"][mime] ?? ".png"
        return (ext, d)
    }

    /// The pictures a file carries, by its own bytes (a .jpg on disk is JPEG).
    private static func imgExt(_ d: Data) -> String {
        if d.starts(with: [0xff, 0xd8]) { return ".jpg" }
        if d.starts(with: [0x52, 0x49, 0x46, 0x46]) { return ".webp" }
        if d.starts(with: [0x47, 0x49, 0x46]) { return ".gif" }
        return ".png"
    }

    /// What this game has to export, as the sheet's rows (web exportInventory).
    static func inventory(_ e: RomEntry) -> [Item] {
        let base = ExportCore.safeName(e.stem.isEmpty ? e.fileName : e.stem)
        var items: [Item] = []
        func add(_ kind: String, _ group: String, _ label: String, _ sub: String, _ files: [File]) {
            let f = files.filter { !$0.data.isEmpty }
            if !f.isEmpty { items.append(Item(kind: kind, group: group, label: label, sub: sub, files: f)) }
        }

        let rom = read(e.url)
        add("rom", "The game", "ROM", ExportCore.safeName(e.fileName),
            [File(path: ExportCore.safeName(e.fileName), data: rom ?? Data())])

        let sav = read(e.saveURL)
        let sav2 = read(e.dir.appendingPathComponent("rom-p2.sav"))
        add("save", "Progress", "Save file",
            "Your in-game progress · .sav" + (sav2 != nil ? " · with Player 2's" : ""),
            [File(path: base + ".sav", data: sav ?? Data(), solo: base + ".sav"),
             File(path: base + " (Player 2).sav", data: sav2 ?? Data())])

        var states: [File] = []
        var slots = 0, quick = false
        for s in 0..<9 {
            guard let bytes = read(e.stateURL(slot: s)) else { continue }
            let label = s == 0 ? "Quick" : "Slot \(s)"
            if s == 0 { quick = true } else { slots += 1 }
            states.append(File(path: statesDir + label + ".state", data: bytes,
                               solo: base + (s == 0 ? "" : " (\(label))") + ".state"))
            let meta = read(e.stateMetaURL(slot: s)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            if let pic = dataURL(meta?["thumb"] as? String) {
                states.append(File(path: statesDir + label + pic.ext, data: pic.data))
            }
        }
        let auto = read(e.sessionURL)
        if let auto {
            states.append(File(path: statesDir + "Where you left off.state", data: auto,
                               solo: base + " (where you left off).state"))
            if let pic = read(e.sessionPicURL) {
                states.append(File(path: statesDir + "Where you left off" + imgExt(pic), data: pic))
            }
        }
        var moments = 0
        var taken = Set<String>()
        func unique(_ stem: String) -> String {
            var s = stem, i = 2
            while taken.contains(s) { s = stem + " (\(i))"; i += 1 }
            taken.insert(s)
            return s
        }
        for c in Checkpoints.readIndex(e).list {
            guard let bytes = read(Checkpoints.stateURL(e, c.slot)) else { continue }
            moments += 1
            let stem = unique(statesDir + "Moments/" + ExportCore.stamp(c.ts))
            states.append(File(path: stem + ".state", data: bytes,
                               solo: base + " (" + (stem as NSString).lastPathComponent + ").state"))
            if let pic = read(Checkpoints.picURL(e, c.slot)) {
                states.append(File(path: stem + imgExt(pic), data: pic))
            }
        }
        let what = [quick ? "Quick" : nil, slots > 0 ? plural(slots, "slot") : nil,
                    auto != nil ? "where you left off" : nil, moments > 0 ? plural(moments, "moment") : nil]
            .compactMap { $0 }.joined(separator: ", ")
        add("states", "Progress", "Save states", what + " · dingbat only", states)

        if let kept = DriveSync.shared.keptSave(e.fileName), let data = kept.data {
            let replaced = kept.why == "replaced"
            let when = kept.at > 0 ? ExportCore.day(kept.at) : ""
            let stem = (replaced ? "Replaced save" : "Save from before you deleted it") + (when.isEmpty ? "" : " " + when)
            add("kept", "Progress", replaced ? "Replaced save" : "Old save",
                (replaced ? "The save you replaced" : "From before you deleted it")
                    + (kept.at > 0 ? " · " + TileMenuView.fmtTime(kept.at) : "") + " · .sav",
                [File(path: "old saves/" + stem + ".sav", data: data, solo: base + " (" + stem.lowercased() + ").sav")])
        }

        let photos = ExportCore.cameraPhotos(rom: rom, sav: sav)
        add("camera", "Pictures", "Camera photos",
            plural(photos.count, "photo") + " from the camera's album · .png",
            photos.map { File(path: "camera/Photo " + String(format: "%02d", $0.number) + ".png",
                              data: ExportCore.greyPng2($0.pixels, w: ExportCore.camW, h: ExportCore.camH)) })

        var printFiles: [File] = []
        for url in PrintStore.all() where PrintStore.game(of: url) == e.fileName {
            guard let png = read(url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let ms = Double(name.dropFirst(6).prefix { $0.isNumber }) ?? 0
            printFiles.append(File(path: unique("prints/" + ExportCore.stamp(ms)) + ".png", data: png))
        }
        add("prints", "Pictures", "Printed photos",
            plural(printFiles.count, "Game Boy Printer photo") + " · .png", printFiles)

        if let frame = read(e.shotURL) {
            let x = imgExt(frame)
            add("thumb", "Pictures", "Library thumbnail", "The picture on its tile · " + x,
                [File(path: "pictures/Thumbnail" + x, data: frame, solo: base + x)])
        }
        if let art = read(e.artURL) {
            let x = imgExt(art)
            add("art", "Pictures", "Box art", "The cover it came with · " + x,
                [File(path: "pictures/Box art" + x, data: art, solo: base + " box art" + x)])
        }

        let cheats = CheatStore.load(for: e)
        let codes = CheatsView.parse(cheats).count
        if codes > 0 {
            add("cheats", "Extras", "Cheats", plural(codes, "code") + " · .cht",
                [File(path: base + ".cht", data: Data(cheats.utf8), solo: base + ".cht")])
        }
        return items
    }

    /// The name the chosen rows go out under, and how many files that is.
    static func fileName(_ e: RomEntry, _ chosen: [Item], now: Double) -> String {
        let files = chosen.flatMap(\.files)
        if files.count == 1, let f = files.first {
            return f.solo ?? (f.path as NSString).lastPathComponent
        }
        return ExportCore.safeName(e.stem.isEmpty ? e.fileName : e.stem) + " — dingbat " + ExportCore.day(now) + ".zip"
    }

    /// The chosen rows as one file in Exports (web exportPackage): one file
    /// bare, more as a zip with info.json in it.
    static func package(_ e: RomEntry, _ chosen: [Item], now: Double = Date().timeIntervalSince1970 * 1000) throws -> URL {
        let files = chosen.flatMap { it in it.files.map { (file: $0, kind: it.kind) } }
        let name = fileName(e, chosen, now: now)
        let data: Data
        if files.count == 1 {
            data = files[0].file.data
        } else {
            let info = ExportCore.infoJSON(game: e.fileName, system: e.system, exportedMs: now,
                                           files: files.map { ($0.file.path, $0.kind) })
            data = try ExportCore.zip([("info.json", info)] + files.map { ($0.file.path, $0.file.data) },
                                      now: Date(timeIntervalSince1970: now / 1000))
        }
        let fm = FileManager.default
        try fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        // Another export of the same name today replaces it.
        let url = exportsDir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: ticks (web export-ticks)

    private static let ticksKey = "export-ticks"
    static func ticked(_ kind: String) -> Bool {
        kind != "rom" && (UserDefaults.standard.dictionary(forKey: ticksKey)?[kind] as? Bool ?? true)
    }
    static func remember(_ on: [String: Bool]) {
        var t = UserDefaults.standard.dictionary(forKey: ticksKey) ?? [:]
        for (k, v) in on where k != "rom" { t[k] = v }
        UserDefaults.standard.set(t, forKey: ticksKey)
    }
}
