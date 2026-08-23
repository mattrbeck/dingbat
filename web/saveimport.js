// GameShark-family save containers (SharkPort/Xploder .sps/.xps, GameShark SP
// .gsv), unwrapped to raw save bytes. Struct layouts per VBA-M's save-state
// format (facts only):
//
// SharkPortSave (.sps; .xps is the same container under Xploder's extension):
//   u32 0x0D, then the 13 bytes "SharkPortSave"
//   u32 platform tag (0x000F0000 = GBA; other Shark devices share the
//       container, so a foreign tag is a warning, not a reject)
//   u32 len + bytes  x3: title, description, notes
//   u32 payloadLen   covers the 0x1C-byte inner header plus the save data
//   0x1C-byte inner header: 16 bytes ROM internal name (ROM[0xA0..0xB0)), then
//       ROM[0xBE], ROM[0xBF], ROM[0xBD], ROM[0xB0], 0x01, zero padding
//   payloadLen-0x1C bytes of raw save data
//   u32 checksum — not validated: writers sum over signed or unsigned chars
//       depending on build, so real files disagree with either variant.
//
// GameShark SP snapshot (.gsv), fixed offsets:
//   0x0C..0x18   12 bytes of ROM internal name
//   0x42C..0x430 tag "xV4\x12" (little-endian 0x12345678)
//   0x430..      raw save data, at most 128 KiB
//
// Sniffing is by content, never by extension (forum files are routinely
// misnamed). A file whose extension claims a container but whose bytes match
// neither is refused: writing an unparsed container over a save as raw bytes
// is unrecoverable. SharkPort payloads under 64 KiB are accepted (EEPROM
// dumps are 512 B or 8 KiB).
//
// Classic script in the browser (window.SaveImport); node module for tests.
(function (g) {
  const SHARKPORT_MAGIC = "SharkPortSave";
  const SHARKPORT_GBA_TAG = 0x000f0000;
  const SHARKPORT_INNER_HEADER = 0x1c;
  const GSV_SAVE_OFFSET = 0x430;
  const GSV_TAG_OFFSET = 0x42c;
  const MAX_GBA_SAVE = 0x20000; // FLASH1M, the largest GBA save chip
  const MIN_GBA_SAVE = 0x200;   // 4 Kbit EEPROM, the smallest

  const u32le = (b, off) =>
    (b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)) >>> 0;

  // Header text for display: printable ASCII only, trimmed.
  const cleanText = (b, off, len) => {
    let s = "";
    for (let i = off; i < off + len && i < b.length; i++)
      s += b[i] >= 0x20 && b[i] < 0x7f ? String.fromCharCode(b[i]) : " ";
    return s.replace(/\s+/g, " ").trim();
  };

  // null if not a SharkPortSave; {ok:false, error} if one but malformed;
  // {ok:true, ...} on success. Same contract for parseGsv.
  const parseSharkPort = (b) => {
    if (b.length < 4 + SHARKPORT_MAGIC.length) return null;
    if (u32le(b, 0) !== SHARKPORT_MAGIC.length) return null;
    if (cleanText(b, 4, SHARKPORT_MAGIC.length) !== SHARKPORT_MAGIC) return null;
    const bad = (error) => ({ ok: false, error });
    let off = 4 + SHARKPORT_MAGIC.length;
    if (off + 4 > b.length) return bad("file ends inside the SharkPort header");
    const platformTag = u32le(b, off);
    off += 4;
    const text = [];
    for (const field of ["title", "description", "notes"]) {
      if (off + 4 > b.length) return bad(`file ends before the ${field} field`);
      const len = u32le(b, off);
      off += 4;
      // A huge length is a corrupt download; slicing by it would misread
      // whatever follows as save data.
      if (len > 4096 || off + len > b.length)
        return bad(`the ${field} field claims ${len} bytes — corrupt file`);
      text.push(cleanText(b, off, len));
      off += len;
    }
    if (off + 4 > b.length) return bad("file ends before the save payload");
    const payloadLen = u32le(b, off);
    off += 4;
    const saveLen = payloadLen - SHARKPORT_INNER_HEADER;
    if (payloadLen < SHARKPORT_INNER_HEADER + MIN_GBA_SAVE || off + payloadLen > b.length)
      return bad("save payload is truncated or missing");
    if (saveLen > MAX_GBA_SAVE)
      return bad(`save payload is ${saveLen} bytes — larger than any GBA save` +
        " (a SharkPort file for a different console?)");
    const innerName = cleanText(b, off, 16);
    return {
      ok: true,
      format: "SharkPort",
      bytes: b.slice(off + SHARKPORT_INNER_HEADER, off + payloadLen),
      title: text[0] || innerName || null,
      warning: platformTag === SHARKPORT_GBA_TAG ? null :
        "this SharkPort file is not marked as a GBA save" +
        ` (platform tag 0x${platformTag.toString(16)})`,
    };
  };

  const parseGsv = (b) => {
    if (b.length < GSV_SAVE_OFFSET) return null;
    if (u32le(b, GSV_TAG_OFFSET) !== 0x12345678) return null;
    if (b.length < GSV_SAVE_OFFSET + MIN_GBA_SAVE)
      return { ok: false, error: "GameShark SP file has no save data after its header" };
    return {
      ok: true,
      format: "GameShark SP",
      bytes: b.slice(GSV_SAVE_OFFSET, GSV_SAVE_OFFSET + MAX_GBA_SAVE),
      title: cleanText(b, 0x0c, 12) || null,
      warning: null,
    };
  };

  // Entry point: picked/dropped bytes -> bytes for applyImportedSave. Raw
  // saves (including .srm) pass through untouched; size fixup is the core's
  // job, since only it knows the cartridge's save chip.
  const unwrap = (bytes, fileName) => {
    const parsed = parseSharkPort(bytes) || parseGsv(bytes);
    if (parsed) return parsed;
    const ext = (fileName.match(/\.[^.]+$/) || [""])[0].toLowerCase();
    if (ext === ".sps" || ext === ".xps" || ext === ".gsv")
      return {
        ok: false,
        error: `${fileName} has a GameShark-style extension but isn't a` +
          " recognizable GameShark or Xploder save — it may be truncated or" +
          " corrupt. Nothing was imported.",
      };
    return { ok: true, format: null, bytes, title: null, warning: null };
  };

  g.SaveImport = { unwrap };
})(typeof window !== "undefined" ? window : globalThis);
