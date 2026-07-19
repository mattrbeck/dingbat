// --- Minimal QR Code encoder (byte mode, ECC level M) -----------------------
// Self-contained, dependency-free. Written for dingbat's serverless "Nearby"
// pairing: it only has to turn the compact base64url pairing string (see
// sdputil.js, ~130–260 chars) into a QR matrix the other phone's camera can
// read. Scope is therefore deliberately narrow: 8-bit BYTE mode only, error
// correction level M (~15% recovery — the sweet spot for on-screen scanning),
// automatic smallest-fitting version (1–40), full mask selection by the standard
// penalty rules, and correct format/version information. Kanji/numeric/
// alphanumeric modes and other ECC levels are intentionally omitted.
//
// Implements ISO/IEC 18004. The Galois-field arithmetic, alignment-pattern
// positions, and per-version block tables are the canonical values from that
// standard.
//
// License: MIT. Original implementation for this project (no vendored code).
//   Copyright (c) 2026 dingbat contributors.
//   Permission is hereby granted, free of charge, to any person obtaining a copy
//   of this software and associated documentation files (the "Software"), to deal
//   in the Software without restriction... (standard MIT terms).
//
// API:
//   QR.encode(str) -> { size, modules }  modules[y][x] === true means a dark cell.
//   Throws if the data does not fit in a version-40 level-M byte-mode symbol.

(function (root) {
  "use strict";

  // ---- Galois field GF(256), primitive polynomial 0x11d --------------------
  const EXP = new Uint8Array(512);
  const LOG = new Uint8Array(256);
  (function initGf() {
    let x = 1;
    for (let i = 0; i < 255; i++) {
      EXP[i] = x;
      LOG[x] = i;
      x <<= 1;
      if (x & 0x100) x ^= 0x11d;
    }
    for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
  })();
  const gfMul = (a, b) => (a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]]);

  // Reed-Solomon generator polynomial of the given degree.
  function rsGenerator(degree) {
    let poly = [1];
    for (let d = 0; d < degree; d++) {
      const next = new Array(poly.length + 1).fill(0);
      for (let i = 0; i < poly.length; i++) {
        next[i] ^= poly[i];
        next[i + 1] ^= gfMul(poly[i], EXP[d]);
      }
      poly = next;
    }
    return poly;
  }
  function rsEncode(data, ecLen) {
    const gen = rsGenerator(ecLen);
    const res = new Array(ecLen).fill(0);
    for (let i = 0; i < data.length; i++) {
      const factor = data[i] ^ res[0];
      res.shift();
      res.push(0);
      // gen has ecLen+1 coefficients (gen[0] is the leading x^ecLen term, which
      // the division cancels); apply gen[1..ecLen] to the remainder.
      for (let j = 0; j < ecLen; j++) res[j] ^= gfMul(gen[j + 1], factor);
    }
    return res;
  }

  // ---- Per-version tables (ECC level M), ISO/IEC 18004 ---------------------
  // Each entry: [ecPerBlock, g1Blocks, g1DataCw, g2Blocks, g2DataCw]. Index by
  // version (1-based; index 0 is a placeholder).
  const M_BLOCKS = [
    null,
    [10, 1, 16, 0, 0],   // 1
    [16, 1, 28, 0, 0],   // 2
    [26, 1, 44, 0, 0],   // 3
    [18, 2, 32, 0, 0],   // 4
    [24, 2, 43, 0, 0],   // 5
    [16, 4, 27, 0, 0],   // 6
    [18, 4, 31, 0, 0],   // 7
    [22, 2, 38, 2, 39],  // 8
    [22, 3, 36, 2, 37],  // 9
    [26, 4, 43, 1, 44],  // 10
    [30, 1, 50, 4, 51],  // 11
    [22, 6, 36, 2, 37],  // 12
    [22, 8, 37, 1, 38],  // 13
    [24, 4, 40, 5, 41],  // 14
    [24, 5, 41, 5, 42],  // 15
    [28, 7, 45, 3, 46],  // 16
    [28, 10, 46, 1, 47], // 17
    [26, 9, 43, 4, 44],  // 18
    [26, 3, 44, 11, 45], // 19
    [26, 3, 41, 13, 42], // 20
    [26, 17, 42, 0, 0],  // 21
    [28, 17, 46, 0, 0],  // 22
    [28, 4, 47, 14, 48], // 23
    [28, 6, 45, 14, 46], // 24
    [28, 8, 47, 13, 48], // 25
    [28, 19, 46, 4, 47], // 26
    [28, 22, 45, 3, 46], // 27
    [28, 3, 45, 23, 46], // 28
    [28, 21, 45, 7, 46], // 29
    [28, 19, 47, 10, 48],// 30
    [28, 2, 46, 29, 47], // 31
    [28, 10, 46, 23, 47],// 32
    [28, 14, 46, 21, 47],// 33
    [28, 14, 46, 23, 47],// 34
    [28, 12, 47, 26, 48],// 35
    [28, 6, 47, 34, 48], // 36
    [28, 29, 46, 14, 47],// 37
    [28, 13, 46, 32, 47],// 38
    [28, 40, 47, 7, 48], // 39
    [28, 18, 47, 31, 48],// 40
  ];

  // Alignment pattern center coordinates per version (ISO/IEC 18004 Annex E).
  const ALIGN = [
    [], [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
    [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50], [6, 30, 54],
    [6, 32, 58], [6, 34, 62], [6, 26, 46, 66], [6, 26, 48, 70],
    [6, 26, 50, 74], [6, 30, 54, 78], [6, 30, 56, 82], [6, 30, 58, 86],
    [6, 34, 62, 90], [6, 28, 50, 72, 94], [6, 26, 50, 74, 98],
    [6, 30, 54, 78, 102], [6, 28, 54, 80, 106], [6, 32, 58, 84, 110],
    [6, 30, 58, 86, 114], [6, 34, 62, 90, 118], [6, 26, 50, 74, 98, 122],
    [6, 30, 54, 78, 102, 126], [6, 26, 52, 78, 104, 130],
    [6, 30, 56, 82, 108, 134], [6, 34, 60, 86, 112, 138],
    [6, 30, 58, 86, 114, 142], [6, 34, 62, 90, 118, 146],
    [6, 30, 54, 78, 102, 126, 150], [6, 24, 50, 76, 102, 128, 154],
    [6, 28, 54, 80, 106, 132, 158], [6, 32, 58, 84, 110, 136, 162],
    [6, 26, 54, 82, 110, 138, 166], [6, 30, 58, 86, 114, 142, 170],
  ];

  const dataCapacity = (v) => {
    const t = M_BLOCKS[v];
    return t[1] * t[2] + t[3] * t[4];
  };

  // ---- bit stream ----------------------------------------------------------
  function buildDataCodewords(bytes, version) {
    const totalData = dataCapacity(version);
    const bits = [];
    const push = (val, len) => { for (let i = len - 1; i >= 0; i--) bits.push((val >> i) & 1); };
    push(0b0100, 4); // byte mode
    const ccLen = version <= 9 ? 8 : 16; // char-count indicator width for byte mode
    push(bytes.length, ccLen);
    for (const b of bytes) push(b, 8);
    // Terminator (up to 4 zero bits) + pad to byte boundary.
    const cap = totalData * 8;
    for (let i = 0; i < 4 && bits.length < cap; i++) bits.push(0);
    while (bits.length % 8 !== 0) bits.push(0);
    // Pad bytes 0xEC / 0x11 alternating.
    const codewords = [];
    for (let i = 0; i < bits.length; i += 8) {
      let b = 0;
      for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
      codewords.push(b);
    }
    const pads = [0xec, 0x11];
    let pi = 0;
    while (codewords.length < totalData) codewords.push(pads[pi++ & 1]);
    return codewords;
  }

  // Split into blocks, compute EC, then interleave data + EC codewords.
  function interleave(codewords, version) {
    const [ecLen, g1, g1cw, g2, g2cw] = M_BLOCKS[version];
    const blocks = [];
    let pos = 0;
    for (let i = 0; i < g1; i++) { blocks.push(codewords.slice(pos, pos + g1cw)); pos += g1cw; }
    for (let i = 0; i < g2; i++) { blocks.push(codewords.slice(pos, pos + g2cw)); pos += g2cw; }
    const ecBlocks = blocks.map((b) => rsEncode(b, ecLen));
    const maxData = Math.max(g1cw, g2cw);
    const out = [];
    for (let i = 0; i < maxData; i++)
      for (const b of blocks) if (i < b.length) out.push(b[i]);
    for (let i = 0; i < ecLen; i++)
      for (const e of ecBlocks) out.push(e[i]);
    return out;
  }

  // ---- matrix construction -------------------------------------------------
  function makeMatrix(version) {
    const size = version * 4 + 17;
    const m = Array.from({ length: size }, () => new Array(size).fill(null)); // null=free
    const reserved = Array.from({ length: size }, () => new Array(size).fill(false));

    const setFn = (x, y, v) => { m[y][x] = v; reserved[y][x] = true; };

    const placeFinder = (ox, oy) => {
      for (let dy = -1; dy <= 7; dy++)
        for (let dx = -1; dx <= 7; dx++) {
          const x = ox + dx, y = oy + dy;
          if (x < 0 || y < 0 || x >= size || y >= size) continue;
          const inRing =
            (dx >= 0 && dx <= 6 && (dy === 0 || dy === 6)) ||
            (dy >= 0 && dy <= 6 && (dx === 0 || dx === 6));
          const inCore = dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4;
          setFn(x, y, inRing || inCore);
        }
    };
    placeFinder(0, 0);
    placeFinder(size - 7, 0);
    placeFinder(0, size - 7);

    // Timing patterns.
    for (let i = 8; i < size - 8; i++) {
      setFn(i, 6, i % 2 === 0);
      setFn(6, i, i % 2 === 0);
    }

    // Alignment patterns (skip where they'd collide with finders).
    const centers = ALIGN[version];
    for (const cy of centers)
      for (const cx of centers) {
        if ((cx <= 8 && cy <= 8) || (cx >= size - 9 && cy <= 8) || (cx <= 8 && cy >= size - 9)) continue;
        for (let dy = -2; dy <= 2; dy++)
          for (let dx = -2; dx <= 2; dx++) {
            const ring = Math.max(Math.abs(dx), Math.abs(dy));
            setFn(cx + dx, cy + dy, ring !== 1);
          }
      }

    // Dark module.
    setFn(8, size - 8, true);

    // Reserve format-info areas (filled later).
    for (let i = 0; i <= 8; i++) {
      if (i !== 6) { reserved[8][i] = true; reserved[i][8] = true; }
    }
    for (let i = 0; i < 8; i++) { reserved[8][size - 1 - i] = true; reserved[size - 1 - i][8] = true; }

    // Reserve version-info areas (version >= 7).
    if (version >= 7) {
      for (let i = 0; i < 6; i++)
        for (let j = 0; j < 3; j++) {
          reserved[i][size - 11 + j] = true;
          reserved[size - 11 + j][i] = true;
        }
    }
    return { m, reserved, size };
  }

  // Zig-zag data placement.
  function placeData(ctx, bytes) {
    const { m, reserved, size } = ctx;
    const bits = [];
    for (const b of bytes) for (let i = 7; i >= 0; i--) bits.push((b >> i) & 1);
    let bit = 0;
    let upward = true;
    for (let col = size - 1; col > 0; col -= 2) {
      if (col === 6) col--; // skip the timing column
      for (let r = 0; r < size; r++) {
        const y = upward ? size - 1 - r : r;
        for (let c = 0; c < 2; c++) {
          const x = col - c;
          if (reserved[y][x]) continue;
          m[y][x] = bit < bits.length ? bits[bit++] === 1 : false;
        }
      }
      upward = !upward;
    }
  }

  const MASKS = [
    (x, y) => (x + y) % 2 === 0,
    (x, y) => y % 2 === 0,
    (x, y) => x % 3 === 0,
    (x, y) => (x + y) % 3 === 0,
    (x, y) => (Math.floor(y / 2) + Math.floor(x / 3)) % 2 === 0,
    (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
    (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
    (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
  ];

  const applyMask = (ctx, maskFn) => {
    const { m, reserved, size } = ctx;
    const out = m.map((row) => row.slice());
    for (let y = 0; y < size; y++)
      for (let x = 0; x < size; x++)
        if (!reserved[y][x] && maskFn(x, y)) out[y][x] = !out[y][x];
    return out;
  };

  // BCH(15,5)-encoded 15-bit format info for level M + mask, XOR'd with 0x5412.
  function formatBits(mask) {
    const M_LEVEL = 0b00; // level M format indicator bits
    const data = (M_LEVEL << 3) | mask; // 5 data bits
    let rem = data << 10;
    for (let i = 4; i >= 0; i--) if ((rem >> (i + 10)) & 1) rem ^= 0x537 << i;
    return (((data << 10) | (rem & 0x3ff)) ^ 0x5412) & 0x7fff;
  }
  function placeFormat(matrix, size, mask) {
    const bits = formatBits(mask);
    const get = (i) => ((bits >> i) & 1) === 1;
    // Vertical copy down column 8 (and up the bottom-left).
    for (let i = 0; i < 15; i++) {
      const mod = get(i);
      if (i < 6) matrix[i][8] = mod;
      else if (i < 8) matrix[i + 1][8] = mod;
      else matrix[size - 15 + i][8] = mod;
    }
    // Horizontal copy along row 8 (from the right, then across the top-left).
    for (let i = 0; i < 15; i++) {
      const mod = get(i);
      if (i < 8) matrix[8][size - i - 1] = mod;
      else if (i < 9) matrix[8][15 - i] = mod; // -> col 7
      else matrix[8][15 - i - 1] = mod;
    }
    matrix[size - 8][8] = true; // fixed dark module
  }

  // 18-bit version info: Golay(18,6) BCH, for versions >= 7.
  function versionBits(version) {
    let rem = version << 12;
    for (let i = 5; i >= 0; i--) if ((rem >> (i + 12)) & 1) rem ^= 0x1f25 << i;
    return (version << 12) | (rem & 0xfff);
  }
  function placeVersion(matrix, size, version) {
    if (version < 7) return;
    const bits = versionBits(version);
    for (let i = 0; i < 18; i++) {
      const b = (bits >> i) & 1;
      const a = Math.floor(i / 3);
      const c = i % 3;
      matrix[a][size - 11 + c] = b === 1;
      matrix[size - 11 + c][a] = b === 1;
    }
  }

  // Penalty scoring for mask selection (the four standard rules).
  function penalty(matrix, size) {
    let score = 0;
    // Rule 1: runs of 5+ same-color in a row/col.
    for (let y = 0; y < size; y++) {
      let runC = 1, runR = 1;
      for (let x = 1; x < size; x++) {
        if (matrix[y][x] === matrix[y][x - 1]) { runC++; if (runC === 5) score += 3; else if (runC > 5) score++; } else runC = 1;
        if (matrix[x][y] === matrix[x - 1][y]) { runR++; if (runR === 5) score += 3; else if (runR > 5) score++; } else runR = 1;
      }
    }
    // Rule 2: 2x2 blocks.
    for (let y = 0; y < size - 1; y++)
      for (let x = 0; x < size - 1; x++) {
        const v = matrix[y][x];
        if (v === matrix[y][x + 1] && v === matrix[y + 1][x] && v === matrix[y + 1][x + 1]) score += 3;
      }
    // Rule 3: finder-like 1:1:3:1:1 patterns.
    const pat1 = [true, false, true, true, true, false, true, false, false, false, false];
    const pat2 = [false, false, false, false, true, false, true, true, true, false, true];
    for (let y = 0; y < size; y++)
      for (let x = 0; x <= size - 11; x++) {
        let ok1 = true, ok2 = true;
        for (let k = 0; k < 11; k++) {
          if (matrix[y][x + k] !== pat1[k]) ok1 = false;
          if (matrix[y][x + k] !== pat2[k]) ok2 = false;
        }
        if (ok1 || ok2) score += 40;
        let ok1v = true, ok2v = true;
        for (let k = 0; k < 11; k++) {
          if (matrix[x + k][y] !== pat1[k]) ok1v = false;
          if (matrix[x + k][y] !== pat2[k]) ok2v = false;
        }
        if (ok1v || ok2v) score += 40;
      }
    // Rule 4: dark/light balance.
    let dark = 0;
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (matrix[y][x]) dark++;
    const pct = (dark * 100) / (size * size);
    score += Math.floor(Math.abs(pct - 50) / 5) * 10;
    return score;
  }

  function encode(str, forceMask) {
    const bytes = [];
    // UTF-8 encode (the pairing string is ASCII base64url, but be safe).
    if (typeof TextEncoder !== "undefined") {
      for (const b of new TextEncoder().encode(str)) bytes.push(b);
    } else {
      for (let i = 0; i < str.length; i++) bytes.push(str.charCodeAt(i) & 0xff);
    }

    // Smallest version (level M, byte mode) that fits.
    let version = 0;
    for (let v = 1; v <= 40; v++) {
      const ccLen = v <= 9 ? 8 : 16;
      const needBits = 4 + ccLen + bytes.length * 8;
      if (needBits <= dataCapacity(v) * 8) { version = v; break; }
    }
    if (!version) throw new Error("data too large for a QR code");

    const codewords = buildDataCodewords(bytes, version);
    const finalData = interleave(codewords, version);

    const ctx = makeMatrix(version);
    placeData(ctx, finalData);

    // Try all 8 masks, keep the lowest penalty.
    let best = null, bestScore = Infinity, bestMask = 0;
    for (let mask = 0; mask < 8; mask++) {
      if (forceMask != null && mask !== forceMask) continue;
      const masked = applyMask(ctx, MASKS[mask]);
      placeFormat(masked, ctx.size, mask);
      placeVersion(masked, ctx.size, version);
      const p = penalty(masked, ctx.size);
      if (p < bestScore) { bestScore = p; best = masked; bestMask = mask; }
    }
    return { size: ctx.size, version, mask: bestMask, modules: best };
  }

  const QR = { encode };
  root.QR = QR;
  if (typeof module !== "undefined" && module.exports) module.exports = QR;
})(typeof window !== "undefined" ? window : globalThis);
