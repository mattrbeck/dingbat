// A linked friend's game found in this library (web rbRomId/rbFindLocalRom):
// a ROM's whole identity is its length, CRC-32 and FNV-1a over every byte,
// and a library copy stands in for the friend's only when its bytes measure
// the same. Measured identities are kept, by file size and modification
// time, so a later link reads only the likely match.
import Foundation
import zlib

struct RomIdentity: Codable, Equatable {
    let len: UInt32
    let crc: UInt32
    let fnv: UInt32

    init(len: UInt32, crc: UInt32, fnv: UInt32) {
        self.len = len; self.crc = crc; self.fnv = fnv
    }

    init(_ d: Data) {
        len = UInt32(truncatingIfNeeded: d.count)
        var c: uLong = 0, h: UInt32 = 0x811c9dc5
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard let base = p.bindMemory(to: UInt8.self).baseAddress else { return }
            c = zlib.crc32(0, base, uInt(p.count))
            for i in 0 ..< p.count { h = (h ^ UInt32(base[i])) &* 0x01000193 }
        }
        crc = UInt32(truncatingIfNeeded: c)
        fnv = h
    }
}

enum LinkRomLookup {
    private struct Known: Codable { let id: RomIdentity; let size: Int; let mtime: Double }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("link-rom-ids.json")
    }

    /// The bytes of a library game that is exactly `want`, or nil. Off the
    /// main thread; a first look at a big library stops after a few seconds
    /// (the friend is waiting on the answer) and goes further next time.
    static func find(_ want: RomIdentity, in entries: [RomEntry]) -> Data? {
        let fm = FileManager.default
        var cache = (try? JSONDecoder().decode([String: Known].self, from: Data(contentsOf: cacheURL))) ?? [:]
        func stat(_ e: RomEntry) -> (size: Int, mtime: Double)? {
            guard let a = try? fm.attributesOfItem(atPath: e.url.path),
                  let size = (a[.size] as? NSNumber)?.intValue else { return nil }
            return (size, (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }
        var known: [RomEntry] = [], fresh: [RomEntry] = []
        for e in entries where e.isLocal {
            guard let st = stat(e), st.size == Int(want.len) else { continue }
            if let k = cache[e.fileName], k.size == st.size, k.mtime == st.mtime {
                if k.id == want { known.append(e) }
            } else {
                fresh.append(e)
            }
        }
        let until = Date().addingTimeInterval(4)
        var changed = false
        defer {
            if changed, let d = try? JSONEncoder().encode(cache) {
                try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? d.write(to: cacheURL, options: .atomic)
            }
        }
        for e in known + fresh {
            if !known.contains(e) && Date() > until { break }
            guard let st = stat(e), let bytes = try? Data(contentsOf: e.url) else { continue }
            let id = RomIdentity(bytes)
            cache[e.fileName] = Known(id: id, size: st.size, mtime: st.mtime)
            changed = true
            if id == want { return bytes }
        }
        return nil
    }
}
