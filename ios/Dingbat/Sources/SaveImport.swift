import Foundation

/// GameShark-family save containers (SharkPort/Xploder .sps/.xps, GameShark
/// SP .gsv), unwrapped to raw save bytes — a port of web/saveimport.js.
///
/// SharkPortSave (.sps; .xps is the same container under Xploder's name):
///   u32 0x0D, then the 13 bytes "SharkPortSave"
///   u32 platform tag (0x000F0000 = GBA; a foreign tag is a warning only)
///   u32 len + bytes  x3: title, description, notes
///   u32 payloadLen   covers the 0x1C-byte inner header plus the save data
///   0x1C-byte inner header (16 bytes of ROM internal name first)
///   payloadLen-0x1C bytes of raw save data, then an unchecked checksum
///
/// GameShark SP snapshot (.gsv), fixed offsets:
///   0x0C..0x18 ROM internal name; 0x42C tag 0x12345678; 0x430.. the save
///   (at most 128 KiB)
///
/// Sniffed by content, never by extension; a file whose extension claims a
/// container but whose bytes match neither is refused, since writing an
/// unparsed container over a save as raw bytes is unrecoverable.
enum SaveImport {
    struct Result {
        var bytes: Data
        /// "SharkPort" / "GameShark SP", nil for a raw save.
        var format: String?
        var title: String?
        var warning: String?
    }

    enum Failure: Error { case bad(String) }

    private static let sharkMagic = "SharkPortSave"
    private static let sharkGbaTag: UInt32 = 0x000F_0000
    private static let sharkInner = 0x1C
    private static let gsvSave = 0x430
    private static let gsvTag = 0x42C
    private static let maxSave = 0x20000   // FLASH1M, the largest GBA save chip
    private static let minSave = 0x200     // 4 Kbit EEPROM, the smallest

    static func unwrap(_ data: Data, fileName: String) -> Swift.Result<Result, Failure> {
        let b = [UInt8](data)
        if let r = sharkPort(b) { return r }
        if let r = gsv(b) { return r }
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ["sps", "xps", "gsv"].contains(ext) {
            return .failure(.bad("\(fileName) has a GameShark-style extension but isn't a"
                + " recognizable GameShark or Xploder save — it may be truncated or"
                + " corrupt. Nothing was imported."))
        }
        return .success(Result(bytes: data, format: nil, title: nil, warning: nil))
    }

    private static func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
    }

    /// Header text for display: printable ASCII only, whitespace collapsed.
    private static func clean(_ b: [UInt8], _ off: Int, _ len: Int) -> String {
        var s = ""
        var i = off
        while i < off + len && i < b.count {
            s.append(b[i] >= 0x20 && b[i] < 0x7F ? Character(UnicodeScalar(b[i])) : " ")
            i += 1
        }
        return s.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    private static func sharkPort(_ b: [UInt8]) -> Swift.Result<Result, Failure>? {
        guard b.count >= 4 + sharkMagic.count, u32(b, 0) == UInt32(sharkMagic.count),
              clean(b, 4, sharkMagic.count) == sharkMagic else { return nil }
        func bad(_ m: String) -> Swift.Result<Result, Failure> { .failure(.bad(m)) }
        var off = 4 + sharkMagic.count
        if off + 4 > b.count { return bad("file ends inside the SharkPort header") }
        let tag = u32(b, off)
        off += 4
        var text: [String] = []
        for field in ["title", "description", "notes"] {
            if off + 4 > b.count { return bad("file ends before the \(field) field") }
            let len = Int(u32(b, off))
            off += 4
            // A huge length is a corrupt download; slicing by it would misread
            // whatever follows as save data.
            if len > 4096 || off + len > b.count { return bad("the \(field) field claims \(len) bytes — corrupt file") }
            text.append(clean(b, off, len))
            off += len
        }
        if off + 4 > b.count { return bad("file ends before the save payload") }
        let payload = Int(u32(b, off))
        off += 4
        let saveLen = payload - sharkInner
        if payload < sharkInner + minSave || off + payload > b.count {
            return bad("save payload is truncated or missing")
        }
        if saveLen > maxSave {
            return bad("save payload is \(saveLen) bytes — larger than any GBA save"
                + " (a SharkPort file for a different console?)")
        }
        let inner = clean(b, off, 16)
        let title = text[0].isEmpty ? (inner.isEmpty ? nil : inner) : text[0]
        return .success(Result(
            bytes: Data(b[(off + sharkInner)..<(off + payload)]),
            format: "SharkPort",
            title: title,
            warning: tag == sharkGbaTag ? nil
                : "this SharkPort file is not marked as a GBA save (platform tag 0x\(String(tag, radix: 16)))"))
    }

    private static func gsv(_ b: [UInt8]) -> Swift.Result<Result, Failure>? {
        guard b.count >= gsvSave, u32(b, gsvTag) == 0x1234_5678 else { return nil }
        if b.count < gsvSave + minSave {
            return .failure(.bad("GameShark SP file has no save data after its header"))
        }
        let title = clean(b, 0x0C, 12)
        return .success(Result(
            bytes: Data(b[gsvSave..<min(b.count, gsvSave + maxSave)]),
            format: "GameShark SP",
            title: title.isEmpty ? nil : title,
            warning: nil))
    }
}
