// --- Third-party save-file containers (GameShark/Xploder), unwrapped ---------
// Forum-traded GBA saves mostly aren't raw .sav bytes: they're wrapped in one
// of two GameShark-family containers, dumped from real cartridges with an
// InterAct SharkPort/GameShark SP or an Xploder, or exported by VisualBoyAdvance
// (whose importer/exporter is the de-facto spec — most files in the wild were
// written by it or are only known-good because it reads them). Layouts below
// were taken from VBA-M's source, not from format docs, because no docs exist:
//
// SharkPortSave (.sps, and .xps — Xploder ships the same container under its
// own extension; VBA-M routes both to CPUReadGSASnapshot):
//   u32  0x0D, then the 13 bytes "SharkPortSave"
//   u32  platform tag: 0x000F0000 = GBA (the same container exists for other
//        Shark devices; VBA ignores this word entirely, so treat a foreign tag
//        as a warning, not a hard reject)
//   u32 len + bytes    title      (free text, usually the game's name)
//   u32 len + bytes    description (VBA writes the dump date here)
//   u32 len + bytes    notes
//   u32 payloadLen     covers a 0x1C-byte inner header PLUS the save data
//   0x1C-byte inner header: 16 bytes ROM internal name (ROM[0xA0..0xB0)), then
//        ROM[0xBE], ROM[0xBF], ROM[0xBD], ROM[0xB0], a 0x01, and zero padding
//   payloadLen-0x1C bytes of raw save data
//   u32  checksum — NOT validated here, deliberately: VBA's importer never
//        checks it, and VBA's own writer computes it over *signed* chars
//        (implementation-defined sign extension), so files from other writers
//        legitimately disagree. Rejecting on it would refuse working files.
//
// GameShark SP snapshot (.gsv, VBA-M's CPUReadGSASPSnapshot): fixed offsets —
//   0x0C..0x18   12 bytes of ROM internal name
//   0x42C..0x430 the tag "xV4\x12" (little-endian 0x12345678)
//   0x430..      raw save data, at most 128 KiB
//
// Sniffing is by CONTENT, never by extension: forum files are routinely
// misnamed (.sav that's really a SharkPort dump, .sps that's really raw), and
// the magics are strong enough that a false positive is not a realistic risk.
// A file whose *extension* claims a container but whose bytes match neither is
// refused outright — writing an unparsed container over someone's save as if
// it were raw bytes is the one unrecoverable mistake this module exists to
// prevent. VBA's import also refuses SharkPort payloads under 64 KiB; that is
// a VBA quirk, not a format rule (hardware dumps of EEPROM games are 512 B or
// 8 KiB), so it is deliberately not copied.
//
// Loads as a plain classic script in the browser (sets window.SaveImport) and
// as a node module for the tests.
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

  // Header text fields, defanged for display in a toast/confirm: printable
  // ASCII only, trimmed. Internal names are fixed-width zero/space-padded.
  const cleanText = (b, off, len) => {
    let s = "";
    for (let i = off; i < off + len && i < b.length; i++)
      s += b[i] >= 0x20 && b[i] < 0x7f ? String.fromCharCode(b[i]) : " ";
    return s.replace(/\s+/g, " ").trim();
  };

  // null if the bytes are not a SharkPortSave; {ok:false, error} if they ARE
  // one but it's malformed; {ok:true, ...} on success. Same contract for _gsv.
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
      // Real fields are short strings; a huge length means a corrupt download
      // (and slicing by it would misread whatever bytes follow as save data).
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

  // The one entry point: bytes as picked/dropped -> bytes to hand to
  // applyImportedSave. Raw saves (including .srm, which is RetroArch's name
  // for byte-identical raw saves) pass through untouched — size fixup is the
  // core's job, since only it knows the cartridge's save chip.
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
