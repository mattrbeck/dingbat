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
  // The picture is one composite frame: "stack" puts the top screen above
  // the bottom one (256 x 384+gap), "side" puts them side by side (512+gap x
  // 192). `pref` is "auto" | "stack" | "side"; auto takes whichever shows
  // the screens bigger in the box (a tie stacks, the console's own shape).
  const dims = (mode, gap = 0) =>
    mode === "side" ? [2 * W + gap, H] : [W, 2 * H + gap];

  const fitScale = (availW, availH, w, h, integer) => {
    if (!(availW > 0 && availH > 0)) return 0;
    const s = Math.min(availW / w, availH / h);
    return integer ? Math.max(1, Math.floor(s)) : s;
  };

  const layout = (availW, availH, pref = "auto", { gap = 0, integer = false } = {}) => {
    let mode = pref === "stack" || pref === "side" ? pref : null;
    if (!mode) {
      const [sw, sh] = dims("stack", gap), [ww, wh] = dims("side", gap);
      // Compare unrounded fits even under integer scaling: a box that holds
      // 1.9x one way and 1.2x the other wants the first.
      mode = fitScale(availW, availH, ww, wh, false) > fitScale(availW, availH, sw, sh, false)
        ? "side" : "stack";
    }
    const [w, h] = dims(mode, gap);
    const scale = fitScale(availW, availH, w, h, integer);
    return { mode, w, h, gap, scale, cssW: w * scale, cssH: h * scale };
  };

  // Where each screen sits in the composite frame, in its pixels.
  const screenRects = (mode, gap = 0) => mode === "side"
    ? { top: { x: 0, y: 0 }, bottom: { x: W + gap, y: 0 } }
    : { top: { x: 0, y: 0 }, bottom: { x: 0, y: H + gap } };

  // A client point on the canvas -> the bottom screen's pixel. `rect` is the
  // canvas's getBoundingClientRect() (the picture fills it: the app sizes
  // the box to the frame's aspect), `lay` is { mode, w, h, gap }. `inside`
  // says whether the point is on the bottom screen at all; x/y are clamped
  // to it either way, so a stylus dragged off the edge stays on the edge.
  const touchPoint = (clientX, clientY, rect, lay) => {
    const fx = (clientX - rect.left) * lay.w / rect.width;
    const fy = (clientY - rect.top) * lay.h / rect.height;
    const b = screenRects(lay.mode, lay.gap || 0).bottom;
    const px = Math.floor(fx - b.x), py = Math.floor(fy - b.y);
    const inside = px >= 0 && px < W && py >= 0 && py < H &&
      Number.isFinite(px) && Number.isFinite(py);
    return {
      x: Math.min(W - 1, Math.max(0, px || 0)),
      y: Math.min(H - 1, Math.max(0, py || 0)),
      inside,
    };
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
    looksLikeNdsRom, headerInfo, dims, layout, screenRects, touchPoint,
    speedAudio, BIOS_KINDS, biosKindOf, biosSizeOk,
  };
})();
