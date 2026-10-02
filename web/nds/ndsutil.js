// --- Nintendo DS helpers for the main app (web/index.js) ---
// Pure functions only (no DOM, no wasm), so web/tests can pin them: file
// detection, the two-screen layout, stylus mapping and the button map. The
// DS core itself (web/nds/nds.js, src/dingbat_nds_wasm.nim) loads lazily
// when a DS game starts.

const NdsUtil = (() => {
  const W = 256, H = 192; // each screen (GBATEK "DS Video")
  // The core's video frame rate: 33513982 Hz / (2130 * 263) cycles a frame
  // (src/dingbat/nds/timing), the same 59.8261 Hz the dev page paces by.
  const FPS = 59.8261;
  // io/spu.nim SAMPLE_RATE: the ARM7 bus clock / 1024.
  const AUDIO_RATE = 33513982 / 1024;

  // Button ids as the core numbers them (NdsButton in
  // src/dingbat/nds/io/input.nim: KEYINPUT bits 0-9, then EXTKEYIN X/Y).
  const BTN = { A: 0, B: 1, SELECT: 2, START: 3, RIGHT: 4, LEFT: 5, UP: 6,
                DOWN: 7, R: 8, L: 9, X: 10, Y: 11 };
  // The app's input ids (web/index.js INPUT_NAMES: Up Down Left Right A B
  // Select Start L R, then X Y for the DS) -> the core's.
  const FROM_APP = [BTN.UP, BTN.DOWN, BTN.LEFT, BTN.RIGHT, BTN.A, BTN.B,
                    BTN.SELECT, BTN.START, BTN.L, BTN.R, BTN.X, BTN.Y];
  const fromAppInput = (id) =>
    Number.isInteger(id) && id >= 0 && id < FROM_APP.length ? FROM_APP[id] : -1;

  const isNdsName = (name) => /\.nds$/i.test(String(name || ""));

  // CRC-16 as GBATEK "BIOS Misc Functions" GetCRC16 states it (the header's
  // checksums use it with initial value FFFFh). The shifted constants carry
  // bits above 15 that later shifts bring down, so the sum stays 32-bit
  // until the end (the result is the reflected A001h CRC, "CRC-16/MODBUS").
  const CRC_VAL = [0xC0C1, 0xC181, 0xC301, 0xC601, 0xCC01, 0xD801, 0xF001, 0xA001];
  const crc16 = (bytes, start, end, init = 0xFFFF) => {
    let crc = init;
    for (let i = start; i < end; i++) {
      crc ^= bytes[i];
      for (let j = 0; j < 8; j++) {
        const carry = crc & 1;
        crc >>>= 1;
        if (carry) crc = (crc ^ (CRC_VAL[j] << (7 - j))) >>> 0;
      }
    }
    return crc & 0xFFFF;
  };

  // Any-signal-matches, like the GB/GBA check in index.js (homebrew is often
  // built without a valid logo): the header CRC at 15Eh over [000h-15Dh], or
  // the logo checksum CF56h at 15Ch (GBATEK "DS Cartridge Header": the BIOS
  // checks only that value).
  const looksLikeNdsRom = (bytes) => {
    if (!bytes || bytes.length < 0x200) return false;
    const rd16 = (o) => bytes[o] | (bytes[o + 1] << 8);
    if (rd16(0x15C) === 0xCF56) return true;
    return rd16(0x15E) === crc16(bytes, 0, 0x15E);
  };

  // Game title (header 000h, 12 ASCII bytes) and code (00Ch, 4 bytes).
  const headerInfo = (bytes) => {
    const ascii = (o, n) => {
      let s = "";
      for (let i = 0; i < n && o + i < bytes.length; i++) {
        const c = bytes[o + i];
        if (c === 0) break;
        s += c >= 0x20 && c < 0x7F ? String.fromCharCode(c) : "?";
      }
      return s.trim();
    };
    return { title: ascii(0, 12), code: ascii(0x0C, 4) };
  };

  // --- Two screens -------------------------------------------------------
  // The picture is one composite in layout pixels (a screen's own pixel at
  // 1x). The arrangement places the screens in it:
  //   stack   top over bottom, `gap` apart (256 x 384+gap)
  //   side    side by side (512+gap x 192)
  //   focus   one screen whole, the other at SMALL of its size below it or
  //           beside it, whichever shows the whole one bigger (a tie: below)
  //   single  one screen only
  //   auto    stack or side, whichever shows the screens bigger (a tie
  //           stacks, the console's own shape)
  // `swap` puts the bottom screen first: above / left in stack and side, the
  // whole (or only) one in focus and single. `rot` turns the whole picture a
  // quarter turn clockwise (1) or anticlockwise (3), for the games played
  // with the console held sideways like a book; 0 is upright.
  const ARRANGEMENTS = ["auto", "stack", "side", "focus", "single"];
  const SMALL = 1 / 3;
  // The gap between the screens, in layout pixels: none, a hinge line, or
  // the console's own. Console: Assumed, an estimate from a DS Lite's
  // published size (each half 73.9 mm deep closed) and its 62 x 46 mm
  // screens (0.24 mm a pixel): about 14 mm from the top screen to the hinge
  // and 8 mm on to the bottom screen, 22 mm or ~90 pixels. Worth a ruler on
  // a real console.
  const GAPS = { none: 0, hinge: 8, console: 90 };
  const ROTATIONS = [0, 1, 3];

  // The upright composite of one shape: its size and each screen's rect
  // (null for a screen not shown). Focus keeps at most a hinge's gap.
  const compose = (shape, gap = 0, swap = false) => {
    const first = swap ? "bottom" : "top", second = swap ? "top" : "bottom";
    const rects = { top: null, bottom: null };
    const r = (x, y, w = W, h = H) => ({ x, y, w, h });
    const g = Math.min(gap, GAPS.hinge), sw = W * SMALL, sh = H * SMALL;
    switch (shape) {
      case "side":
        rects[first] = r(0, 0); rects[second] = r(W + gap, 0);
        return { w: 2 * W + gap, h: H, rects };
      case "single":
        rects[first] = r(0, 0);
        return { w: W, h: H, rects };
      case "focus-below":
        rects[first] = r(0, 0); rects[second] = r((W - sw) / 2, H + g, sw, sh);
        return { w: W, h: H + g + sh, rects };
      case "focus-beside":
        rects[first] = r(0, 0); rects[second] = r(W + g, (H - sh) / 2, sw, sh);
        return { w: W + g + sw, h: H, rects };
      default: // stack
        rects[first] = r(0, 0); rects[second] = r(0, H + gap);
        return { w: W, h: 2 * H + gap, rects };
    }
  };

  // Integer scaling where it fits: whole multiples from 1x up, and a box
  // too small for 1x gets the plain fit (never a picture bigger than it).
  const fitScale = (availW, availH, w, h, integer) => {
    if (!(availW > 0 && availH > 0)) return 0;
    const s = Math.min(availW / w, availH / h);
    return integer && s >= 1 ? Math.floor(s) : s;
  };

  // The arrangement for a box of availW x availH: `mode` is the arrangement
  // (auto resolved), `shape` the composite drawn, w x h the picture as shown
  // (turned), uw x uh the upright composite, `rects` each screen's place in
  // it, and the scale that fits it.
  const layout = (availW, availH, pref = "auto",
                  { gap = 0, integer = false, swap = false, rot = 0 } = {}) => {
    rot = ROTATIONS.includes(rot) ? rot : 0;
    const turned = (c) => (rot ? [c.h, c.w] : [c.w, c.h]);
    // Compare unrounded fits even under integer scaling: a box that holds
    // 1.9x one way and 1.2x the other wants the first.
    const fit = (c) => fitScale(availW, availH, ...turned(c), false);
    const pick = (a, b) => {
      const ca = compose(a, gap, swap), cb = compose(b, gap, swap);
      return fit(cb) > fit(ca) ? [b, cb] : [a, ca];
    };
    let mode = ARRANGEMENTS.includes(pref) ? pref : "auto";
    let shape, c;
    if (mode === "auto") { [shape, c] = pick("stack", "side"); mode = shape; }
    else if (mode === "focus") [shape, c] = pick("focus-below", "focus-beside");
    else { shape = mode; c = compose(shape, gap, swap); }
    const [w, h] = turned(c);
    const scale = fitScale(availW, availH, w, h, integer);
    return { mode, shape, rot, swap, gap, uw: c.w, uh: c.h, w, h, rects: c.rects,
             scale, cssW: w * scale, cssH: h * scale };
  };

  // An upright rect of `lay`'s composite where it shows, turned.
  const turnRect = (r, lay) => lay.rot === 1 ? { x: lay.uh - r.y - r.h, y: r.x, w: r.h, h: r.w }
    : lay.rot === 3 ? { x: r.y, y: lay.uw - r.x - r.w, w: r.h, h: r.w }
    : { x: r.x, y: r.y, w: r.w, h: r.h };

  // What the presenter draws: each shown screen's place in the picture (in
  // layout pixels of the turned picture) and the turn it is drawn with.
  const views = (lay) => ["top", "bottom"].filter((s) => lay.rects[s])
    .map((screen) => ({ screen, dst: turnRect(lay.rects[screen], lay), rot: lay.rot }));

  // A client point on the canvas -> the upright composite's coordinates.
  // `rect` is the canvas's getBoundingClientRect() (the picture fills it:
  // the app sizes the box to the picture's aspect).
  const toComposite = (clientX, clientY, rect, lay) => {
    const dx = (clientX - rect.left) * lay.w / rect.width;
    const dy = (clientY - rect.top) * lay.h / rect.height;
    return lay.rot === 1 ? [dy, lay.uh - dx] : lay.rot === 3 ? [lay.uw - dy, dx] : [dx, dy];
  };

  // Which screen a client point is on: "top", "bottom" or null.
  const screenAt = (clientX, clientY, rect, lay) => {
    const [fx, fy] = toComposite(clientX, clientY, rect, lay);
    for (const s of ["bottom", "top"]) {
      const r = lay.rects[s];
      if (r && fx >= r.x && fx < r.x + r.w && fy >= r.y && fy < r.y + r.h) return s;
    }
    return null;
  };

  // A client point -> the bottom screen's pixel, exact at any scale,
  // arrangement and turn. `inside` says whether the point is on the bottom
  // screen at all; x/y are clamped to it either way, so a stylus dragged off
  // the edge stays on the edge. With the bottom screen not shown, nothing
  // is inside.
  const touchPoint = (clientX, clientY, rect, lay) => {
    const b = lay.rects && lay.rects.bottom;
    if (!b) return { x: 0, y: 0, inside: false };
    const [fx, fy] = toComposite(clientX, clientY, rect, lay);
    const px = Math.floor((fx - b.x) * W / b.w), py = Math.floor((fy - b.y) * H / b.h);
    const inside = px >= 0 && px < W && py >= 0 && py < H &&
      Number.isFinite(px) && Number.isFinite(py);
    return {
      x: Math.min(W - 1, Math.max(0, px || 0)),
      y: Math.min(H - 1, Math.max(0, py || 0)),
      inside,
    };
  };

  // The inverse: the client point at the centre of a screen's pixel (px, py),
  // or null when that screen is not shown. Tests aim the pointer with it.
  const clientPoint = (screen, px, py, rect, lay) => {
    const r = lay.rects[screen];
    if (!r) return null;
    const fx = r.x + (px + 0.5) * r.w / W, fy = r.y + (py + 0.5) * r.h / H;
    const [dx, dy] = lay.rot === 1 ? [lay.uh - fy, fx] : lay.rot === 3 ? [fy, lay.uw - fx] : [fx, fy];
    return [rect.left + dx * rect.width / lay.w, rect.top + dy * rect.height / lay.h];
  };

  // --- Microphone -----------------------------------------------------------
  // Web Audio's float samples (-1..1) as the int16 the core queues
  // (nds_push_mic), clamped.
  const micInt16 = (f32) => {
    const out = new Int16Array(f32.length);
    for (let i = 0; i < f32.length; i++) {
      const v = Math.max(-1, Math.min(1, f32[i] || 0));
      out[i] = Math.round(v * 32767);
    }
    return out;
  };
  // Blowing into the microphone, for a device without one: n samples of
  // white noise at about 60% of full scale. Assumed: blowing reads as loud
  // broadband noise, which is what a game's blow test listens for (a level
  // over a threshold).
  const BLOW_LEVEL = 20000;
  const blowNoise = (n, rnd = Math.random) => {
    const out = new Int16Array(n);
    for (let i = 0; i < n; i++) out[i] = Math.round((rnd() * 2 - 1) * BLOW_LEVEL);
    return out;
  };

  // Stereo float32 resampled by an integer-ish speed factor for 2x (every
  // other frame) and slow motion (each frame twice): pitch moves with speed,
  // as the GB/GBA cores' turbo does without pitch correction.
  const speedAudio = (src, speed) => {
    if (speed === 1) return src;
    const n = src.length >> 1;
    if (speed > 1) {
      const step = Math.round(speed), m = Math.floor(n / step);
      const out = new Float32Array(m * 2);
      for (let i = 0; i < m; i++) {
        out[2 * i] = src[2 * i * step];
        out[2 * i + 1] = src[2 * i * step + 1];
      }
      return out;
    }
    const rep = Math.round(1 / speed), out = new Float32Array(n * 2 * rep);
    for (let i = 0; i < n; i++) {
      for (let r = 0; r < rep; r++) {
        out[2 * (i * rep + r)] = src[2 * i];
        out[2 * (i * rep + r) + 1] = src[2 * i + 1];
      }
    }
    return out;
  };

  // BIOS / firmware dumps by name, else by size (GBATEK "DS Memory Map":
  // ARM9 BIOS 4 KB, ARM7 BIOS 16 KB; firmware flash 256 KB on a DS, 128 KB
  // on some iQue/DS Lite parts, 512 KB on a DSi).
  const BIOS_KINDS = ["bios9", "bios7", "firmware"];
  const biosKindOf = (fileName, size) => {
    const n = String(fileName || "").toLowerCase();
    if (/bios9|arm9/.test(n)) return "bios9";
    if (/bios7|arm7/.test(n)) return "bios7";
    if (/firm|fw/.test(n)) return "firmware";
    if (size === 4096) return "bios9";
    if (size === 16384) return "bios7";
    if (size === 131072 || size === 262144 || size === 524288) return "firmware";
    return null;
  };
  const BIOS_SIZES = { bios9: [4096], bios7: [16384], firmware: [131072, 262144, 524288] };
  const biosSizeOk = (kind, size) => (BIOS_SIZES[kind] || []).includes(size);

  return {
    W, H, FPS, AUDIO_RATE, BTN, FROM_APP, fromAppInput, isNdsName, crc16,
    looksLikeNdsRom, headerInfo, ARRANGEMENTS, SMALL, GAPS, ROTATIONS, compose, layout,
    turnRect, views, screenAt, touchPoint, clientPoint,
    micInt16, BLOW_LEVEL, blowNoise, speedAudio, BIOS_KINDS, biosKindOf, biosSizeOk,
  };
})();
