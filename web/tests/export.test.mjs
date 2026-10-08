// Export… on a game's tile menu (index.js "Export"): which rows a game is
// offered, what is ticked, what lands in the file, and the Game Boy Camera's
// album read out of its save.

import test from "node:test";
import assert from "node:assert/strict";
import zlib from "node:zlib";
import vm from "node:vm";
import { loadApp, u8, eq, settle, gameTiles } from "./helpers.mjs";

const fns = (app) => vm.runInContext(`({
  exportInventory, exportPackage, exportTicked, cameraPhotos, greyPng2, unzip,
  openExportModal, EXPORT_TICKS_KEY, EXPORT_STATES_DIR,
})`, app.context);

const T = new Date(2026, 9, 7, 11, 48).getTime();
const jpeg = (n) => new Blob([u8(0xff, 0xd8, n)], { type: "image/jpeg" });
const png = (n) => new Blob([u8(0x89, 0x50, n)], { type: "image/png" });

// Every kind of record one game can have.
const seedEverything = (app, g = "Crystal.gbc") => {
  app.idb.set("recent", [{ name: g, ts: 100 }]);
  app.idb.set("rom:" + g, { name: g, data: u8(1, 2, 3, 4) });
  app.idb.set("save:" + g, u8(10, 11));
  app.idb.set("save:" + g + "-p2", u8(20));
  app.idb.set("state:" + g, u8(30, 31, 32));
  app.idb.set("statemeta:" + g, { thumb: "data:image/webp;base64,AAEC", ts: T });
  app.idb.set("state:" + g + ":slot3", u8(33));
  app.idb.set("stateauto:" + g, { bytes: u8(40), ts: T });
  app.idb.set("sessionpic:" + g, { ts: T, blob: jpeg(41) });
  app.idb.set("ckpts:" + g, { play: 5000, list: [{ slot: 0, ts: T }, { slot: 1, ts: T - 3600e3 }] });
  app.idb.set("ckpt0:" + g, { bytes: u8(50), ts: T, pic: jpeg(51) });
  app.idb.set("ckpt1:" + g, { bytes: u8(52), ts: T - 3600e3, pic: null });
  app.idb.set("oldsave:" + g, { data: u8(60), at: T, why: "replaced" });
  app.idb.set("frame:" + g, jpeg(70));
  app.idb.set("art:" + g, png(71));
  app.idb.set("cheats:" + g, [{ name: "Money", codes: "0199D8D6", enabled: true, error: "" }]);
  app.api.printerPhotos = [
    { ts: T, w: 160, h: 16, png: "data:image/png;base64,iVBORw==", game: g },
    { ts: T, w: 160, h: 16, png: "data:image/png;base64,iVBORw==", game: "Other.gb" },
  ];
};

test("every kind a game has is a row, grouped, in the design's order", async () => {
  const app = await loadApp();
  seedEverything(app);
  const inv = await fns(app).exportInventory("Crystal.gbc");
  eq(Array.from(inv, (i) => [i.kind, i.group, i.label]), [
    ["rom", "The game", "ROM"],
    ["save", "Progress", "Save file"],
    ["states", "Progress", "Save states"],
    ["kept", "Progress", "Replaced save"],
    ["prints", "Pictures", "Printed photos"],
    ["thumb", "Pictures", "Library thumbnail"],
    ["art", "Pictures", "Box art"],
    ["cheats", "Extras", "Cheats"],
  ]);
  const by = Object.fromEntries(Array.from(inv, (i) => [i.kind, i]));
  assert.equal(by.states.sub, "Quick, 1 slot, where you left off, 2 moments · dingbat only");
  assert.equal(by.save.sub, "Your in-game progress · .sav · with Player 2's");
  assert.equal(by.prints.sub, "1 Game Boy Printer photo · .png", "only this game's prints");
  assert.equal(by.cheats.sub, "1 code · .cht");
});

test("a game with only its ROM is offered only its ROM: no empty rows", async () => {
  const app = await loadApp();
  app.idb.set("rom:Tetris.gb", { name: "Tetris.gb", data: u8(1, 2) });
  app.api.printerPhotos = [];
  const inv = await fns(app).exportInventory("Tetris.gb");
  eq(Array.from(inv, (i) => i.kind), ["rom"]);
});

test("a game whose ROM is not here is still offered its saves", async () => {
  const app = await loadApp();
  app.idb.set("save:Lost.gba", u8(1));
  app.api.printerPhotos = [];
  eq(Array.from(await fns(app).exportInventory("Lost.gba"), (i) => i.kind), ["save"]);
});

test("ticks: the ROM always starts off; everything else on unless last time said off", async () => {
  const app = await loadApp();
  const { exportTicked } = fns(app);
  assert.equal(exportTicked({}, "rom"), false);
  assert.equal(exportTicked({ rom: true }, "rom"), false, "never remembered on");
  assert.equal(exportTicked({}, "save"), true);
  assert.equal(exportTicked({ save: false }, "save"), false);
  assert.equal(exportTicked({ save: true }, "states"), true);
});

test("one file goes out as itself, named for the game", async () => {
  const app = await loadApp();
  seedEverything(app);
  const { exportInventory, exportPackage } = fns(app);
  const inv = await exportInventory("Crystal.gbc");
  const pkg = exportPackage("Crystal.gbc", inv.filter((i) => i.kind === "cheats"), T);
  assert.equal(pkg.fileName, "Crystal.cht");
  assert.equal(await pkg.blob.text(), "[x] Money\n0199D8D6\n\n");
});

test("a lone state goes out named for its game", async () => {
  const app = await loadApp();
  app.idb.set("state:Tetris.gb", u8(3));
  app.idb.set("state:Tetris.gb:slot4", u8(4));
  app.api.printerPhotos = [];
  const { exportInventory, exportPackage } = fns(app);
  const states = (await exportInventory("Tetris.gb")).find((i) => i.kind === "states");
  const one = (end) => exportPackage("Tetris.gb",
    [{ ...states, files: states.files.filter((f) => f.path.endsWith(end)) }]).fileName;
  assert.equal(one("Quick.state"), "Tetris.state");
  assert.equal(one("Slot 4.state"), "Tetris (Slot 4).state");
});

test("more than one goes out as a zip, every file where the design puts it", async () => {
  const app = await loadApp();
  seedEverything(app);
  const { exportInventory, exportPackage, unzip, EXPORT_STATES_DIR: S } = fns(app);
  const inv = await exportInventory("Crystal.gbc");
  const pkg = exportPackage("Crystal.gbc", inv.filter((i) => i.kind !== "rom"), T);
  assert.equal(pkg.fileName, "Crystal — dingbat 2026-10-07.zip");
  assert.equal(pkg.count, 7);
  const z = await unzip(await pkg.blob.arrayBuffer());
  const names = Array.from(z.entries, (e) => e.name);
  eq(names, [
    "info.json",
    "Crystal.sav", "Crystal (Player 2).sav",
    S + "Quick.state", S + "Quick.webp", S + "Slot 3.state",
    S + "Where you left off.state", S + "Where you left off.jpg",
    S + "Moments/2026-10-07 11-48.state", S + "Moments/2026-10-07 11-48.jpg",
    S + "Moments/2026-10-07 10-48.state",
    "old saves/Replaced save 2026-10-07.sav",
    "prints/2026-10-07 11-48.png",
    "pictures/Thumbnail.jpg", "pictures/Box art.png",
    "Crystal.cht",
  ]);
  const get = async (n) => new Uint8Array(await z.extract(z.entries.find((e) => e.name === n)));
  eq(Array.from(await get("Crystal.sav")), [10, 11]);
  eq(Array.from(await get(S + "Quick.state")), [30, 31, 32]);
  const info = JSON.parse(new TextDecoder().decode(await get("info.json")));
  assert.equal(info.app, "dingbat");
  assert.equal(info.game, "Crystal.gbc");
  assert.equal(info.system, "GBC");
  assert.equal(info.files.length, names.length - 1, "every other file, with its kind");
  eq(info.files.find((f) => f.path === "Crystal.sav"), { path: "Crystal.sav", kind: "save" });
});

// ── An export added back as a game ──────────────────────────────────────────
// Until import reads the rest, a zip of ours goes through Add a game: its ROM
// is the file info.json calls the ROM, and its box art is the file it calls
// box art - never the library thumbnail or a print, whichever is largest.

const gbRom = () => {
  const rom = new Uint8Array(0x150).fill(0x22);
  let chk = 0;
  for (let i = 0x134; i <= 0x14c; i++) chk = (chk - rom[i] - 1) & 0xff;
  rom[0x14d] = chk; // header checksum: passes the ROM check
  return rom;
};

const addBack = async (app, kinds) => {
  const { exportInventory, exportPackage } = fns(app);
  const inv = await exportInventory("Crystal.gbc");
  const pkg = exportPackage("Crystal.gbc", inv.filter((i) => kinds.includes(i.kind)), T);
  for (const k of [...app.idb.keys()]) if (k.endsWith(":Crystal.gbc")) app.idb.delete(k);
  const buf = await pkg.blob.arrayBuffer();
  // Adding it also boots it; the core is a stub.
  app.runIn(`globalThis.Module = { ccall: () => {}, _loop_tick: () => {}, _clearAudioBuffer: () => {},
    _wasm_fb_ptr: () => 16, _malloc: () => 8, _free: () => {},
    memory: { buffer: new ArrayBuffer(16 + 240 * 160 * 4) } };`);
  await vm.runInContext("handleZipFile", app.context)({ name: pkg.fileName, arrayBuffer: async () => buf });
  await settle();
};

test("an export with no box art adds back with no box art, however big its thumbnail", async () => {
  const app = await loadApp();
  seedEverything(app);
  app.idb.set("rom:Crystal.gbc", { name: "Crystal.gbc", data: gbRom() });
  app.idb.set("frame:Crystal.gbc", jpeg(70)); // the largest picture in the zip
  await addBack(app, ["rom", "thumb", "prints"]);
  eq(Array.from(app.idb.get("rom:Crystal.gbc").data), Array.from(gbRom()));
  assert.equal(app.idb.get("art:Crystal.gbc"), undefined);
});

test("an export with box art adds back with that box art", async () => {
  const app = await loadApp();
  seedEverything(app);
  app.idb.set("rom:Crystal.gbc", { name: "Crystal.gbc", data: gbRom() });
  app.idb.set("frame:Crystal.gbc", new Blob([new Uint8Array(500)], { type: "image/jpeg" }));
  await addBack(app, ["rom", "thumb", "art"]);
  const art = app.idb.get("art:Crystal.gbc");
  eq(Array.from(new Uint8Array(await art.arrayBuffer())), [0x89, 0x50, 71]);
});

// ── The Game Boy Camera's album ─────────────────────────────────────────────

const camRom = () => { const r = new Uint8Array(0x150); r[0x147] = 0xfc; return r; };
const camSave = ({ at = 0x11b2 } = {}) => {
  const s = new Uint8Array(0x20000);
  s.fill(0xff, at, at + 30);
  s[at + 2] = 0; // slot 2 holds album photo 1
  s[at + 0] = 4; // slot 0 holds album photo 5
  s.set(new TextEncoder().encode("Magic"), at + 30);
  // Slot 2's first tile, first row: pixel 0 is shade 3, pixel 1 shade 2.
  s[0x2000 + 2 * 0x1000] = 0b10000000;
  s[0x2000 + 2 * 0x1000 + 1] = 0b11000000;
  return s;
};

test("camera photos come out in album order, shades read from the tiles", async () => {
  const app = await loadApp();
  const photos = fns(app).cameraPhotos(camRom(), camSave());
  eq(Array.from(photos, (p) => p.number), [1, 5]);
  eq(Array.from(photos[0].pixels.subarray(0, 4)), [3, 2, 0, 0]);
  assert.equal(photos[0].pixels.length, 128 * 112);
});

test("the album's backup copy is read when the first is gone", async () => {
  const app = await loadApp();
  const s = camSave({ at: 0x11d7 });
  eq(Array.from(fns(app).cameraPhotos(camRom(), s), (p) => p.number), [1, 5]);
});

test("no camera cart, or no album, means no camera photos", async () => {
  const app = await loadApp();
  const { cameraPhotos } = fns(app);
  const notCam = camRom(); notCam[0x147] = 0x1b;
  eq(Array.from(cameraPhotos(notCam, camSave())), []);
  eq(Array.from(cameraPhotos(camRom(), new Uint8Array(0x20000))), [], "no Magic, no album");
  eq(Array.from(cameraPhotos(camRom(), new Uint8Array(0x8000))), [], "too small to be the camera's");
});

test("a camera game is offered its photos as PNGs", async () => {
  const app = await loadApp();
  app.idb.set("rom:Camera.gb", { name: "Camera.gb", data: camRom() });
  app.idb.set("save:Camera.gb", camSave());
  app.api.printerPhotos = [];
  const inv = await fns(app).exportInventory("Camera.gb");
  const cam = inv.find((i) => i.kind === "camera");
  assert.equal(cam.sub, "2 photos from the camera's album · .png");
  eq(Array.from(cam.files, (f) => f.path), ["camera/Photo 01.png", "camera/Photo 05.png"]);
});

test("the PNG is a valid 2-bit greyscale image, shade 0 white", async () => {
  const app = await loadApp();
  const { cameraPhotos, greyPng2 } = fns(app);
  const p = cameraPhotos(camRom(), camSave())[0];
  const file = greyPng2(p.pixels, 128, 112);
  eq(Array.from(file.subarray(0, 8)), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const chunks = {};
  for (let o = 8; o < file.length;) {
    const dv = new DataView(file.buffer, file.byteOffset + o);
    const len = dv.getUint32(0);
    const type = new TextDecoder().decode(file.subarray(o + 4, o + 8));
    const body = file.subarray(o + 8, o + 8 + len);
    assert.equal(dv.getUint32(8 + len), zlib.crc32(file.subarray(o + 4, o + 8 + len)), type + " CRC");
    chunks[type] = body;
    o += 12 + len;
  }
  const ihdr = new DataView(chunks.IHDR.buffer, chunks.IHDR.byteOffset);
  eq([ihdr.getUint32(0), ihdr.getUint32(4), chunks.IHDR[8], chunks.IHDR[9]], [128, 112, 2, 0]);
  const raw = zlib.inflateSync(chunks.IDAT);
  assert.equal(raw.length, 112 * 33);
  assert.equal(raw[0], 0, "filter: none");
  // Shades 3, 2, 0, 0 are PNG greys 0, 1, 3, 3.
  assert.equal(raw[1], 0b00011111);
  assert.equal(raw[2], 0xff, "the rest of the row is white");
  assert.ok(chunks.IEND);
});

// ── The modal, from the tile ────────────────────────────────────────────────

const walk = (el, out = []) => {
  out.push(el);
  for (const c of el.children || []) if (c && typeof c === "object") walk(c, out);
  return out;
};
const modalOf = (app) => app.document.body.children.find((c) => c.classList?.contains("sync-modal"));

test("Export… opens the list ticked as it should be, and remembers what was unticked", async () => {
  const app = await loadApp();
  seedEverything(app);
  app.idb.set("thumbs_offered", 1);
  await app.api.refreshHomeRecent();
  await settle();
  const tile = gameTiles(app)[0];
  await tile.children.find((c) => c.classList.contains("home-tile-more")).click();
  await settle();
  const exportItem = app.document.getElementById("tile-menu-items").children
    .find((b) => b.children.some((c) => c.textContent === "Export…"));
  await exportItem.click();
  await settle();
  const modal = modalOf(app);
  assert.ok(modal, "the export box is up");
  const boxes = walk(modal).filter((e) => e.tagName === "INPUT");
  const ticked = Object.fromEntries(boxes.map((b) => [b.id, b.checked]));
  eq(ticked, { "export-pick-rom": false, "export-pick-save": true, "export-pick-states": true,
               "export-pick-kept": true, "export-pick-prints": true, "export-pick-thumb": true,
               "export-pick-art": true, "export-pick-cheats": true });
  assert.equal(walk(modal).filter((e) => e.classList?.contains("export-subhead")).length, 4,
               "eight rows: grouped");

  const save = boxes.find((b) => b.id === "export-pick-save");
  save.checked = false;
  await save.dispatch("change");
  const go = walk(modal).find((e) => e.tagName === "BUTTON" && /^Export/.test(e.textContent));
  assert.equal(go.textContent, "Export 6");

  const downloads = [];
  const make = app.document.createElement;
  app.document.createElement = (tag) => {
    const el = make(tag);
    if (tag === "a") el.addEventListener("click", () => downloads.push(el.download));
    return el;
  };
  await go.click();
  await settle();
  const d = new Date(), p = (n) => String(n).padStart(2, "0");
  const today = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  eq(downloads, ["Crystal — dingbat " + today + ".zip"]);
  const remembered = app.idb.get(fns(app).EXPORT_TICKS_KEY);
  assert.equal(remembered.save, false);
  assert.ok(!("rom" in remembered), "the ROM's tick is never kept");
});

test("a short list has no headings", async () => {
  const app = await loadApp();
  app.idb.set("rom:Tetris.gb", { name: "Tetris.gb", data: u8(1, 2) });
  app.idb.set("state:Tetris.gb", u8(3));
  app.api.printerPhotos = [];
  await fns(app).openExportModal("Tetris.gb");
  await settle();
  const modal = modalOf(app);
  assert.equal(walk(modal).filter((e) => e.classList?.contains("export-subhead")).length, 0);
  eq(walk(modal).filter((e) => e.tagName === "INPUT").map((b) => [b.id, b.checked]),
     [["export-pick-rom", false], ["export-pick-states", true]]);
});
