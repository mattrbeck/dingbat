import Compression
import Foundation

/// The web's unzip(): read a zip's central directory, take the first ROM
/// inside and the largest image (box art), or, for a dingbat export, the
/// ROM and box art its info.json names. Stored and deflated entries only.
enum ZipReader {
    struct Result {
        var name: String
        var rom: Data
        var art: Data?
    }

    private struct Entry {
        var name: String
        var method: UInt16
        var compSize: Int
        var size: Int
        var localOffset: Int
    }

    static func extractRom(from zip: Data) -> Result? {
        let b = [UInt8](zip)
        func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? u16(o) | u16(o + 2) << 16 : 0 }

        // End of central directory: scan back over a comment of up to 64 KiB.
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 0xFFFF) {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard u32(p) == 0x0201_4B50 else { break }
            let method = UInt16(u16(p + 10))
            let comp = u32(p + 20), size = u32(p + 24)
            let nlen = u16(p + 28), xlen = u16(p + 30), clen = u16(p + 32)
            let off = u32(p + 42)
            let nameBytes = p + 46 + nlen <= b.count ? Array(b[(p + 46)..<(p + 46 + nlen)]) : []
            let name = String(decoding: nameBytes, as: UTF8.self)
            entries.append(Entry(name: name, method: method, compSize: comp, size: size, localOffset: off))
            p += 46 + nlen + xlen + clen
        }

        func data(_ e: Entry) -> Data? {
            let lh = e.localOffset
            guard u32(lh) == 0x0403_4B50 else { return nil }
            let start = lh + 30 + u16(lh + 26) + u16(lh + 28)
            guard start + e.compSize <= b.count else { return nil }
            let raw = Data(b[start..<(start + e.compSize)])
            switch e.method {
            case 0: return raw
            case 8: return inflate(raw, size: e.size)
            default: return nil
            }
        }

        let romExts: Set<String> = ["gba", "gb", "gbc", "cgb", "sgb"]
        let imgExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
        func ext(_ n: String) -> String { (n as NSString).pathExtension.lowercased() }
        func base(_ n: String) -> String { (n as NSString).lastPathComponent }
        let visible = entries.filter { !$0.name.hasSuffix("/") && !base($0.name).hasPrefix(".") &&
                                       !$0.name.hasPrefix("__MACOSX") }
        // One of our own exports says what each file is (info.json): its box
        // art is the file it calls box art, or there is none; guessing would
        // make the library thumbnail or a printed photo the cover.
        let kinds = ExportCore.exportKinds(entries.first { $0.name == "info.json" }.flatMap { data($0) })
        let ofKind = { (k: String) in kinds.flatMap { kinds in entries.first { kinds[$0.name] == k } } }
        guard let romEntry = ofKind("rom") ?? visible.first(where: { romExts.contains(ext($0.name)) }),
              let rom = data(romEntry) else { return nil }
        // Anyone else's zip: the largest image is almost always the box art.
        let art = kinds != nil ? ofKind("art").flatMap { data($0) }
            : visible.filter { imgExts.contains(ext($0.name)) }.max { $0.size < $1.size }.flatMap { data($0) }
        return Result(name: base(romEntry.name), rom: rom, art: art)
    }

    /// Raw deflate (Apple's COMPRESSION_ZLIB is raw RFC 1951).
    private static func inflate(_ src: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        // A header can claim anything; no cartridge or picture is near this.
        guard !src.isEmpty, size <= 64 << 20 else { return nil }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return n == size ? out : nil
    }
}
