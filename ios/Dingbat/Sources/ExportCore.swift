// The export's file formats, with nothing of the app in them (web
// zipwrite.js and index.js "Export"): the stored-only ZIP writer, the Game
// Boy Camera album read out of its save, the 2-bit greyscale PNG a photo is
// written as, and the names and stamps files get. Byte for byte the web's,
// so an export from either opens the same way (ios/e2e/export-core checks).
import Foundation
import zlib

enum ExportCore {
    // MARK: names

    /// File names from game names: the characters a filesystem refuses go.
    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|").union(CharacterSet(charactersIn: "\u{0}"..."\u{1f}"))
        let out = String(s.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "game" : out
    }

    /// "2026-10-07 11-48", local time (web exportStamp).
    static func stamp(_ ms: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    static func day(_ ms: Double) -> String { String(stamp(ms).prefix(10)) }

    /// "2026-10-08T07:16:41.123Z" (JavaScript's toISOString).
    static func iso(_ ms: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    // MARK: zip (PKWARE APPNOTE 4.3.7, 4.3.12, 4.3.16; UTF-8 names, 4.4.4)

    static func crc32(_ d: Data) -> UInt32 {
        d.withUnsafeBytes { p in
            UInt32(truncatingIfNeeded: zlib.crc32(0, p.bindMemory(to: UInt8.self).baseAddress, uInt(p.count)))
        }
    }

    /// MS-DOS date and time, local, two-second resolution; before 1980 is
    /// written as 1980-01-01.
    static func dosDateTime(_ d: Date) -> (date: UInt16, time: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let y = c.year ?? 1980
        if y < 1980 { return ((1 << 5) | 1, 0) }
        return (UInt16((y - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)),
                UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) >> 1))
    }

    enum ZipError: LocalizedError {
        case tooBig
        var errorDescription: String? { "too much data for a zip" }
    }

    /// Every entry stored (method 0): states are deflated by the core and
    /// pictures are compressed already. No ZIP64: refused rather than
    /// written broken.
    static func zip(_ files: [(name: String, data: Data)], now: Date = Date()) throws -> Data {
        guard files.count <= 0xffff else { throw ZipError.tooBig }
        func le16(_ v: UInt16, _ to: inout Data) { to.append(UInt8(v & 0xff)); to.append(UInt8(v >> 8)) }
        func le32(_ v: UInt32, _ to: inout Data) { le16(UInt16(v & 0xffff), &to); le16(UInt16(v >> 16), &to) }
        let utf8: UInt16 = 0x0800, version: UInt16 = 20
        let (date, time) = dosDateTime(now)
        var out = Data(), central = Data()
        var offset = 0
        for f in files {
            let name = Data(f.name.utf8)
            let crc = crc32(f.data)
            let size = UInt32(truncatingIfNeeded: f.data.count)
            guard f.data.count <= Int(UInt32.max) else { throw ZipError.tooBig }
            le32(0x04034b50, &out); le16(version, &out); le16(utf8, &out); le16(0, &out)
            le16(time, &out); le16(date, &out); le32(crc, &out); le32(size, &out); le32(size, &out)
            le16(UInt16(name.count), &out); le16(0, &out)
            out.append(name)
            out.append(f.data)

            le32(0x02014b50, &central); le16(version, &central); le16(version, &central)
            le16(utf8, &central); le16(0, &central); le16(time, &central); le16(date, &central)
            le32(crc, &central); le32(size, &central); le32(size, &central)
            le16(UInt16(name.count), &central)
            le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central); le32(0, &central)
            le32(UInt32(truncatingIfNeeded: offset), &central)
            central.append(name)
            offset += 30 + name.count + f.data.count
            guard offset <= Int(UInt32.max) else { throw ZipError.tooBig }
        }
        guard offset + central.count <= Int(UInt32.max) else { throw ZipError.tooBig }
        let cenSize = central.count
        out.append(central)
        le32(0x06054b50, &out); le16(0, &out); le16(0, &out)
        le16(UInt16(files.count), &out); le16(UInt16(files.count), &out)
        le32(UInt32(cenSize), &out); le32(UInt32(offset), &out); le16(0, &out)
        return out
    }

    // MARK: Game Boy Camera
    // The cart's 128 KB of RAM holds 30 photo slots: slot k's 128x112
    // picture is 0xE00 bytes of 2bpp tiles (16 across, 14 down) at 0x2000 +
    // k * 0x1000. Which slots hold a photo, and where each sits in the album,
    // is a 30-byte table at 0x11B2: the photo's album number minus one, 0xFF
    // for an empty slot, followed by "Magic" and a checksum; the run is
    // repeated at 0x11D7 as a backup. Layout from Raphaël Boichot's public
    // write-up of the save format; Pan Docs covers the mapper, not the album.

    static let camW = 128, camH = 112

    /// [(album number, pixels 0 lightest ... 3)], in album order.
    static func cameraPhotos(rom: Data?, sav: Data?) -> [(number: Int, pixels: [UInt8])] {
        guard let rom, rom.count > 0x147, rom[rom.startIndex + 0x147] == 0xfc,
              let sav, sav.count >= 0x20000 else { return [] }
        let s = [UInt8](sav)
        let magic = Array("Magic".utf8)
        guard let at = [0x11b2, 0x11d7].first(where: { Array(s[($0 + 30)..<($0 + 35)]) == magic }) else { return [] }
        var out: [(number: Int, pixels: [UInt8])] = []
        for slot in 0..<30 {
            let n = Int(s[at + slot])
            if n >= 30 { continue }
            let base = 0x2000 + slot * 0x1000
            var px = [UInt8](repeating: 0, count: camW * camH)
            for ty in 0..<(camH / 8) {
                for tx in 0..<(camW / 8) {
                    let tile = base + (ty * (camW / 8) + tx) * 16
                    for row in 0..<8 {
                        let lo = s[tile + row * 2], hi = s[tile + row * 2 + 1]
                        for bit in 0..<8 {
                            let v = ((lo >> (7 - bit)) & 1) | (((hi >> (7 - bit)) & 1) << 1)
                            px[(ty * 8 + row) * camW + tx * 8 + bit] = v
                        }
                    }
                }
            }
            out.append((n + 1, px))
        }
        return out.sorted { $0.number < $1.number }
    }

    /// A 2-bit greyscale PNG (colour type 0, bit depth 2) whose zlib stream
    /// is stored blocks: four shades are all the format holds, and a photo
    /// is 3.6 KB.
    static func greyPng2(_ pixels: [UInt8], w: Int, h: Int) -> Data {
        let row = 1 + w / 4
        var raw = [UInt8](repeating: 0, count: row * h)
        for y in 0..<h {
            for x in 0..<w {
                // Shade 0 is the lightest; PNG grey 3 is white.
                raw[y * row + 1 + (x >> 2)] |= (3 - pixels[y * w + x]) << (6 - (x & 3) * 2)
            }
        }
        var z = Data([0x78, 0x01])
        var o = 0
        repeat {
            let n = min(0xffff, raw.count - o)
            let last: UInt8 = o + n >= raw.count ? 1 : 0
            z.append(contentsOf: [last, UInt8(n & 0xff), UInt8(n >> 8), UInt8(~n & 0xff), UInt8((~n >> 8) & 0xff)])
            z.append(contentsOf: raw[o..<(o + n)])
            o += n
        } while o < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for v in raw { a = (a + UInt32(v)) % 65521; b = (b + a) % 65521 }
        z.append(contentsOf: [UInt8(b >> 8), UInt8(b & 0xff), UInt8(a >> 8), UInt8(a & 0xff)])
        func u32(_ n: UInt32) -> Data { Data([UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]) }
        func chunk(_ type: String, _ d: Data) -> Data {
            var td = Data(type.utf8); td.append(d)
            var c = u32(UInt32(d.count)); c.append(td); c.append(u32(crc32(td)))
            return c
        }
        var ihdr = u32(UInt32(w)); ihdr.append(u32(UInt32(h))); ihdr.append(contentsOf: [2, 0, 0, 0, 0])
        var png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        png.append(chunk("IHDR", ihdr)); png.append(chunk("IDAT", z)); png.append(chunk("IEND", Data()))
        return png
    }

    // MARK: info.json

    /// What an export holds (web exportPackage's info.json), keys in the
    /// web's order and indented as JSON.stringify(info, null, 2) writes it.
    static func infoJSON(game: String, system: String, exportedMs: Double,
                         files: [(path: String, kind: String)]) -> Data {
        func str(_ s: String) -> String {
            let d = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            let t = String(decoding: d, as: UTF8.self)
            return String(t.dropFirst().dropLast())
        }
        var s = "{\n"
        s += "  \"app\": \"dingbat\",\n"
        s += "  \"format\": 1,\n"
        s += "  \"game\": \(str(game)),\n"
        s += "  \"system\": \(str(system)),\n"
        s += "  \"exported\": \(str(iso(exportedMs))),\n"
        if files.isEmpty {
            s += "  \"files\": []\n"
        } else {
            s += "  \"files\": [\n"
            s += files.map { "    {\n      \"path\": \(str($0.path)),\n      \"kind\": \(str($0.kind))\n    }" }
                .joined(separator: ",\n")
            s += "\n  ]\n"
        }
        s += "}\n"
        return Data(s.utf8)
    }

    /// A dingbat export's path -> kind, from its info.json; nil for any
    /// other zip (web exportKinds).
    static func exportKinds(_ info: Data?) -> [String: String]? {
        guard let info, let o = (try? JSONSerialization.jsonObject(with: info)) as? [String: Any],
              o["app"] as? String == "dingbat", let files = o["files"] as? [Any] else { return nil }
        var out: [String: String] = [:]
        for f in files {
            if let f = f as? [String: Any], let p = f["path"] as? String { out[p] = f["kind"] as? String ?? "" }
        }
        return out
    }
}
