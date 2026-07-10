import Foundation
import UniformTypeIdentifiers

extension UTType {
    static var gbaRom: UTType { UTType(importedAs: "com.mattrb.dingbat.gba") }
    static var gbRom: UTType { UTType(importedAs: "com.mattrb.dingbat.gb") }
    static var gbcRom: UTType { UTType(importedAs: "com.mattrb.dingbat.gbc") }
}

struct RomEntry: Identifiable, Equatable {
    let url: URL

    var id: String { url.lastPathComponent }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var system: String {
        switch ext {
        case "gb": return "GB"
        case "gbc": return "GBC"
        default: return "GBA"
        }
    }
    var sizeText: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard bytes > 0 else { return "" }
        if bytes >= 1 << 20 {
            return String(format: "%.1f MB", Double(bytes) / Double(1 << 20))
        }
        return "\(bytes >> 10) KB"
    }
    var stem: String { url.deletingPathExtension().lastPathComponent }
    var stateURL: URL { RomLibrary.statesDir.appendingPathComponent(stem + ".state") }
    var shotURL: URL { RomLibrary.shotsDir.appendingPathComponent(stem + ".png") }
    var saveURL: URL { url.deletingPathExtension().appendingPathExtension("sav") }
}

/// ROMs live as plain files in Documents/roms (visible in the Files app via
/// UIFileSharingEnabled); battery saves are written by the core alongside
/// them, save states in Documents/states, thumbnails in Documents/shots.
final class RomLibrary: ObservableObject {
    @Published var entries: [RomEntry] = []
    @Published var importError: String?

    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let romsDir = docs.appendingPathComponent("roms", isDirectory: true)
    static let statesDir = docs.appendingPathComponent("states", isDirectory: true)
    static let shotsDir = docs.appendingPathComponent("shots", isDirectory: true)

    static let romExtensions: Set<String> = ["gba", "gb", "gbc"]

    init() {
        try? Self.ensureDir(Self.romsDir)
        installBundledDemo()
        refresh()
    }

    static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.romsDir, includingPropertiesForKeys: nil)) ?? []
        entries = files
            .filter { Self.romExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
            .map { RomEntry(url: $0) }
    }

    /// The homebrew demo shipped in the app bundle (read-only) is copied into
    /// Documents once so the core can write its battery save next to it.
    private func installBundledDemo() {
        guard let bundled = Bundle.main.url(forResource: "goodboy-demo-en", withExtension: "gba") else { return }
        let dest = Self.romsDir.appendingPathComponent(bundled.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.copyItem(at: bundled, to: dest)
    }

    /// Import from the Files document picker (security-scoped URL).
    func importRom(from source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard Self.romExtensions.contains(source.pathExtension.lowercased()) else {
            importError = "Not a .gba/.gb/.gbc file"
            return
        }
        do {
            let data = try Data(contentsOf: source)
            let dest = Self.romsDir.appendingPathComponent(source.lastPathComponent)
            try data.write(to: dest)
            refresh()
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    func delete(_ entry: RomEntry) {
        let fm = FileManager.default
        try? fm.removeItem(at: entry.url)
        try? fm.removeItem(at: entry.saveURL)
        try? fm.removeItem(at: entry.stateURL)
        try? fm.removeItem(at: entry.shotURL)
        refresh()
    }
}
