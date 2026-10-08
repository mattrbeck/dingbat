// ZIP writer for the game export: every entry stored (method 0), names in
// UTF-8, built from bytes already in memory. Nothing here compresses:
// save states are deflated by the core, pictures are JPEG/PNG/WebP, and the
// rest (.sav, .cht, info.json) is a few KB, so deflate would cost time for
// almost no saving.
//
// Layout, per PKWARE's APPNOTE.TXT (4.3.7 local header, 4.3.12 central
// directory header, 4.3.16 end of central directory; bit 11 of the flags
// marks UTF-8 names, 4.4.4):
//   [local header + data] ... [central directory] [end record]
// No ZIP64: an export is one game, at most a 32 MB ROM plus its saves, far
// under the 4 GB and 65535-entry limits, and build() refuses anything past
// them rather than writing a file that would not open.
//
// The output is a list of byte arrays for a Blob to join, so a ROM is never
// copied into one big buffer on the way out.
//
// Classic script in the browser (window.ZipWrite); node module for tests.
(function (g) {
  const enc = new TextEncoder();

  // CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), table-driven.
  const CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();

  const crc32 = (bytes) => {
    let c = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };

  // MS-DOS date and time, local, two-second resolution. The format starts
  // in 1980, so anything earlier is written as 1980-01-01.
  const dosDateTime = (d) => {
    const y = d.getFullYear();
    if (y < 1980) return { date: (1 << 5) | 1, time: 0 };
    return {
      date: ((y - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate(),
      time: (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1),
    };
  };

  const FLAG_UTF8 = 0x0800;
  const VERSION = 20; // 2.0: what an entry in a folder needs to extract
  const MAX_U32 = 0xffffffff;

  // files: [{ name: "folder/file.ext", data: Uint8Array, date?: Date }]
  // Folders are implied by the names, as unzip tools expect. Names must be
  // unique; the caller decides what a clash becomes.
  const build = (files, now = new Date()) => {
    if (files.length > 0xffff) throw new Error("too many files for a zip");
    const parts = [];
    const central = [];
    let offset = 0;
    for (const f of files) {
      const name = enc.encode(f.name);
      const data = f.data;
      const crc = crc32(data);
      const { date, time } = dosDateTime(f.date || now);
      const local = new Uint8Array(30 + name.length);
      const lv = new DataView(local.buffer);
      lv.setUint32(0, 0x04034b50, true);
      lv.setUint16(4, VERSION, true);
      lv.setUint16(6, FLAG_UTF8, true);
      lv.setUint16(8, 0, true); // stored
      lv.setUint16(10, time, true);
      lv.setUint16(12, date, true);
      lv.setUint32(14, crc, true);
      lv.setUint32(18, data.length, true);
      lv.setUint32(22, data.length, true);
      lv.setUint16(26, name.length, true);
      lv.setUint16(28, 0, true);
      local.set(name, 30);

      const cen = new Uint8Array(46 + name.length);
      const cv = new DataView(cen.buffer);
      cv.setUint32(0, 0x02014b50, true);
      cv.setUint16(4, VERSION, true); // made by: MS-DOS attributes, 2.0
      cv.setUint16(6, VERSION, true);
      cv.setUint16(8, FLAG_UTF8, true);
      cv.setUint16(10, 0, true);
      cv.setUint16(12, time, true);
      cv.setUint16(14, date, true);
      cv.setUint32(16, crc, true);
      cv.setUint32(20, data.length, true);
      cv.setUint32(24, data.length, true);
      cv.setUint16(28, name.length, true);
      // extra, comment, disk number, internal and external attributes: 0
      cv.setUint32(42, offset, true);
      cen.set(name, 46);

      parts.push(local, data);
      central.push(cen);
      offset += local.length + data.length;
      if (offset > MAX_U32) throw new Error("too much data for a zip");
    }
    let cenSize = 0;
    for (const c of central) cenSize += c.length;
    if (offset + cenSize > MAX_U32) throw new Error("too much data for a zip");
    const end = new Uint8Array(22);
    const ev = new DataView(end.buffer);
    ev.setUint32(0, 0x06054b50, true);
    ev.setUint16(8, files.length, true);
    ev.setUint16(10, files.length, true);
    ev.setUint32(12, cenSize, true);
    ev.setUint32(16, offset, true);
    return [...parts, ...central, end];
  };

  const blob = (files, now) => new Blob(build(files, now), { type: "application/zip" });

  g.ZipWrite = { build, blob, crc32 };
})(typeof window !== "undefined" ? window : globalThis);
