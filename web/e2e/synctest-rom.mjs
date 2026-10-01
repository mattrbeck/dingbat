// A 32 KB Game Boy ROM (MBC1 + RAM + battery) that stands in for a game.
// It keeps one counter, c, in work RAM, and every frame it shows it: the
// boot logo (left on screen by the boot) scrolls to (4c, 2c), and the
// colours cycle through four schemes with c / 2. So every value of c is its
// own picture, and the picture says how far the game has got; and two
// moments a couple of frames apart look nothing alike, the whole background
// having changed colour.
//
//   A held: c goes up one a frame and is written to the battery save
//           (0xA000) - playing and saving.
//   B held: c goes up one a frame and nothing is saved - playing without
//           saving, which only a save state (a session) can carry.
//
// At boot c is read back from the save.

export const SYNCTEST_NAME = "synctest.gb";

// A few SM83 instructions, with labels for the relative jumps and calls.
const assemble = (lines, origin) => {
  const labels = {};
  const fix = [];
  const out = [];
  for (const l of lines) {
    if (typeof l === "string") { labels[l] = origin + out.length; continue; }
    for (const b of l) {
      if (typeof b === "object") { fix.push({ at: out.length, ...b }); out.push(0); if (b.abs) out.push(0); }
      else out.push(b);
    }
  }
  for (const f of fix) {
    const target = labels[f.to];
    if (f.abs) { out[f.at] = target & 0xff; out[f.at + 1] = target >> 8; }
    else out[f.at] = (target - (origin + f.at + 1)) & 0xff;
  }
  return out;
};
const rel = (to) => ({ to });
const abs = (to) => ({ to, abs: true });

export const synctestRom = () => {
  const rom = new Uint8Array(0x8000);
  rom.set([0x00, 0xc3, 0x50, 0x01], 0x100); // nop; jp $0150
  rom.set(Buffer.from("CEED6666CC0D000B03730083000C000D0008111F8889000EDCCC6EE6" +
                      "DDDDD999BBBB67636E0EECCCDDDC999FBBB9333E", "hex"), 0x104);
  rom.set(Buffer.from("SYNCTEST", "latin1"), 0x134);
  rom[0x147] = 0x03; // MBC1+RAM+BATTERY
  rom[0x148] = 0x00; // 32 KB
  rom[0x149] = 0x02; // 8 KB RAM
  const code = assemble([
    [0x3e, 0x0a, 0xea, 0x00, 0x00],             // ld a,$0A ; ld ($0000),a   RAM on
    [0xfa, 0x00, 0xa0, 0xea, 0x00, 0xc0],       // c = save
    [0xcd, abs("show")],
    "loop",
    [0xf0, 0x44, 0xfe, 0x90, 0x20, rel("loop")], // wait for LY == 144
    [0x3e, 0x10, 0xe0, 0x00],                   // select the buttons
    [0xf0, 0x00, 0xf0, 0x00, 0x47],             // read P1 twice ; ld b,a
    [0xe6, 0x01, 0x20, rel("noA")],             // A (active low)
    [0x21, 0x00, 0xc0, 0x34],                   // c++
    [0x7e, 0xea, 0x00, 0xa0],                   // save = c
    [0xcd, abs("show"), 0x18, rel("next")],
    "noA",
    [0x78, 0xe6, 0x02, 0x20, rel("next")],      // B
    [0x21, 0x00, 0xc0, 0x34],                   // c++, unsaved
    [0xcd, abs("show")],
    "next",
    [0xf0, 0x44, 0xfe, 0x90, 0x28, rel("next")], // wait for LY != 144
    [0x18, rel("loop")],
    "show",
    [0xfa, 0x00, 0xc0, 0x87, 0xe0, 0x42],       // SCY = 2c
    [0x87, 0xe0, 0x43],                         // SCX = 4c
    // The scheme from c's bits 1-2, not 0-1: a browser that runs two frames
    // an animation frame moves c in even steps, and would only ever reach
    // two of the four schemes by the low bits.
    [0xfa, 0x00, 0xc0, 0xcb, 0x3f, 0xe6, 0x03, 0x5f, 0x16, 0x00], // de = (c >> 1) & 3
    [0x21, abs("palettes"), 0x19, 0x7e, 0xe0, 0x47],  // BGP = palettes[de]
    [0xc9],
    "palettes",                                 // background, logo
    [0xfc, 0x03, 0xa9, 0x56],                   // light/dark, dark/light, 1/2, 2/1
  ], 0x150);
  rom.set(code, 0x150);
  let chk = 0;
  for (let i = 0x134; i < 0x14d; i++) chk = (chk - rom[i] - 1) & 0xff;
  rom[0x14d] = chk;
  let sum = 0;
  for (let i = 0; i < rom.length; i++) if (i !== 0x14e && i !== 0x14f) sum += rom[i];
  rom[0x14e] = (sum >> 8) & 0xff;
  rom[0x14f] = sum & 0xff;
  return rom;
};
