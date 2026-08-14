// GameShark-family save containers (web/saveimport.js) through the real
// import flow: a picked/dropped .sps/.xps/.gsv is unwrapped to its raw save
// bytes before anything is written, misnamed files are sniffed by content,
// and a file that claims a container extension but parses as neither is
// refused WITHOUT touching the existing save. The synthetic builders below
// mirror VBA-M's CPUWriteGSASnapshot byte for byte (the de-facto format
// spec — see the header comment in saveimport.js).

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, fakeFile } from "./helpers.mjs";

// Drive the pickFile flow: click #load-save, then feed the created
// <input type=file> a fake file. (Same shape as import-save.test.mjs.)
const importSav = async (app, name, bytes) => {
  await app.elements.get("load-save").dispatch("click");
  const input = app.document.body.children.at(-1);
  assert.equal(input.tagName, "INPUT");
  input.files = [fakeFile(name, bytes)];
  await input.dispatch("change");
  await settle(); // FileReader microtask + async callback
  await settle();
};

const bootFakeGame = (app) => {
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "NewName.gba";
  app.runIn("Module.ccall = () => {}"); // stub the wasm core boot
};

// --- Synthetic container builders -------------------------------------------

const strBytes = (s) => [...s].map((c) => c.charCodeAt(0));
const u32le = (v) => [v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255];

// A recognizable non-trivial save payload.
const patternSave = (len) => {
  const b = new Uint8Array(len);
  for (let i = 0; i < len; i++) b[i] = (i * 7 + 13) & 0xff;
  return b;
};

// Byte-for-byte what VBA-M's CPUWriteGSASnapshot emits (modulo its CRC's
// signed-char sign extension, which the importer ignores anyway).
const buildSps = (save, opts = {}) => {
  const {
    title = "Pokemon Test (U)",
    desc = "08/14/2026",
    notes = "dumped for the tests",
    platformTag = 0x000f0000,
    innerName = "TESTGAME 16CH",
  } = opts;
  const out = [];
  out.push(...u32le(13), ...strBytes("SharkPortSave"), ...u32le(platformTag));
  for (const s of [title, desc, notes]) out.push(...u32le(s.length), ...strBytes(s));
  out.push(...u32le(save.length + 0x1c));
  const inner = new Array(0x1c).fill(0);
  strBytes(innerName).slice(0, 16).forEach((b, i) => (inner[i] = b));
  inner[0x10] = 0x33; inner[0x11] = 0x44; // reserved (old checksum)
  inner[0x12] = 0x55;                     // complement check
  inner[0x13] = 0x31;                     // maker
  inner[0x14] = 1;                        // "1 save"
  let crc = 0;
  for (const b of inner) crc = (crc + ((b << crc % 0x18) >>> 0)) >>> 0;
  for (const b of save) crc = (crc + ((b << crc % 0x18) >>> 0)) >>> 0;
  // Assemble without spreading `save` (spreading 128 KiB+ overflows the stack).
  const file = new Uint8Array(out.length + inner.length + save.length + 4);
  file.set(out, 0);
  file.set(inner, out.length);
  file.set(save, out.length + inner.length);
  file.set(u32le(crc), out.length + inner.length + save.length);
  return file;
};

// The fixed GameShark SP layout: name at 0x0C, "xV4\x12" tag at 0x42C,
// save data from 0x430.
const buildGsv = (save, name = "TESTGAME 12C") => {
  const out = new Uint8Array(0x430 + save.length);
  out.set(strBytes(name).slice(0, 12), 0x0c);
  out.set([0x78, 0x56, 0x34, 0x12], 0x42c);
  out.set(save, 0x430);
  return out;
};

// --- Parser unit cases, through the same global index.js uses ---------------

test("SharkPortSave round-trip: unwrap returns exactly the embedded save", async () => {
  const app = await loadApp();
  const save = patternSave(0x10000);
  const r = app.sandbox.SaveImport.unwrap(buildSps(save), "file.sps");
  assert.equal(r.ok, true);
  assert.equal(r.format, "SharkPort");
  assert.equal(r.title, "Pokemon Test (U)");
  assert.equal(r.warning, null);
  eq(r.bytes, save);
});

test("an EEPROM-sized SharkPort payload (512 B) is accepted — VBA's 64 KiB import floor is a VBA quirk, not a format rule", async () => {
  const app = await loadApp();
  const save = patternSave(0x200);
  const r = app.sandbox.SaveImport.unwrap(buildSps(save), "zelda.sps");
  assert.equal(r.ok, true);
  eq(r.bytes, save);
});

test("a payload larger than any GBA save chip is refused (PS2 SharkPort files share the magic)", async () => {
  const app = await loadApp();
  const r = app.sandbox.SaveImport.unwrap(buildSps(patternSave(0x40000)), "ps2game.sps");
  assert.equal(r.ok, false);
  assert.match(r.error, /larger than any GBA save/);
});

test("a non-GBA platform tag imports with a warning instead of a hard reject (VBA ignores the tag entirely)", async () => {
  const app = await loadApp();
  const save = patternSave(0x8000);
  const r = app.sandbox.SaveImport.unwrap(
    buildSps(save, { platformTag: 0x2 }), "file.sps");
  assert.equal(r.ok, true);
  eq(r.bytes, save);
  assert.match(r.warning, /not marked as a GBA save/);
});

test("hostile length fields error out instead of slicing garbage", async () => {
  const app = await loadApp();
  const sps = buildSps(patternSave(0x2000));
  sps.set([0xff, 0xff, 0xff, 0xff], 4 + 13 + 4); // title length -> 4 GiB
  const r = app.sandbox.SaveImport.unwrap(sps, "evil.sps");
  assert.equal(r.ok, false);
  assert.match(r.error, /title field claims/);
});

test("a truncated SharkPort file errors out", async () => {
  const app = await loadApp();
  const r = app.sandbox.SaveImport.unwrap(
    buildSps(patternSave(0x10000)).slice(0, 5000), "cut.sps");
  assert.equal(r.ok, false);
  assert.match(r.error, /truncated or missing/);
});

test("GSV round-trip, including the 128 KiB cap on oversized files", async () => {
  const app = await loadApp();
  const save = patternSave(0x20000);
  const r = app.sandbox.SaveImport.unwrap(buildGsv(save), "file.gsv");
  assert.equal(r.ok, true);
  assert.equal(r.format, "GameShark SP");
  assert.equal(r.title, "TESTGAME 12C");
  eq(r.bytes, save);

  // Trailing junk past 128 KiB is dropped, matching VBA's fixed-size read.
  const long = app.sandbox.SaveImport.unwrap(
    buildGsv(patternSave(0x20000 + 64)), "file.gsv");
  assert.equal(long.bytes.length, 0x20000);
});

test("content beats extension: a SharkPort dump misnamed .sav still unwraps, raw bytes misnamed .srm pass through", async () => {
  const app = await loadApp();
  const save = patternSave(0x8000);
  const asSav = app.sandbox.SaveImport.unwrap(buildSps(save), "mislabeled.sav");
  assert.equal(asSav.format, "SharkPort");
  eq(asSav.bytes, save);

  const raw = patternSave(0x8000);
  const asSrm = app.sandbox.SaveImport.unwrap(raw, "game.srm");
  assert.equal(asSrm.ok, true);
  assert.equal(asSrm.format, null);
  eq(asSrm.bytes, raw);
});

// --- The full import flow ----------------------------------------------------

test("importing a .sps writes the UNWRAPPED save to FS and IndexedDB, never the container", async () => {
  const app = await loadApp();
  bootFakeGame(app);
  const save = patternSave(0x10000);
  await importSav(app, "SomeForumFile.sps", buildSps(save));

  eq(app.sandbox.FS.files.get("rom.sav"), save);
  eq(app.idb.get("save:NewName.gba"), save);
  assert.ok(app.document.body.classList.contains("running")); // game reloaded
  assert.ok(app.toasts.some((t) => /SharkPort save — Pokemon Test/.test(t)));
});

test("importing a .xps goes through the same SharkPort parser (Xploder ships the same container)", async () => {
  const app = await loadApp();
  bootFakeGame(app);
  const save = patternSave(0x8000);
  await importSav(app, "NewName.xps", buildSps(save));
  eq(app.sandbox.FS.files.get("rom.sav"), save);
  assert.equal(app.confirms.length, 1); // matching name: only the generic ask
});

test("importing a .gsv unwraps from the fixed 0x430 offset", async () => {
  const app = await loadApp();
  bootFakeGame(app);
  const save = patternSave(0x10000);
  await importSav(app, "NewName.gsv", buildGsv(save));
  eq(app.sandbox.FS.files.get("rom.sav"), save);
});

test("a corrupt file with a container extension is refused without touching the existing save", async () => {
  const app = await loadApp();
  bootFakeGame(app);
  await importSav(app, "broken.sps", patternSave(0x8000)); // raw bytes, no magic
  assert.equal(app.alerts.length, 1);
  assert.match(app.alerts[0], /isn't a recognizable GameShark or Xploder save/);
  assert.equal(app.idb.size, 0);
  assert.equal(app.sandbox.FS.files.size, 0);
  assert.equal(app.confirms.length, 0); // refused before any overwrite prompt
});

test("the platform-tag warning reaches the overwrite prompt", async () => {
  const app = await loadApp();
  bootFakeGame(app);
  const save = patternSave(0x8000);
  await importSav(app, "NewName.sps", buildSps(save, { platformTag: 0x2 }));
  assert.match(app.confirms[0], /not marked as a GBA save/);
  eq(app.sandbox.FS.files.get("rom.sav"), save); // warned, not blocked
});

test("a raw .srm imports exactly like a .sav", async () => {
  const app = await loadApp();
  bootFakeGame(app);
  const raw = patternSave(0x2000);
  await importSav(app, "NewName.srm", raw);
  eq(app.sandbox.FS.files.get("rom.sav"), raw);
  eq(app.idb.get("save:NewName.gba"), raw);
});
