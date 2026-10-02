// The DS paths of the main app (index.js "Nintendo DS", nds/ndsutil.js,
// nds/ndsaudio.js): file detection, the two-screen layout, stylus mapping,
// the audio ring, battery saves through a stand-in core, Drive exclusion and
// the state hook.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp, fakeFile, u8, eq, settle } from "./helpers.mjs";

const src = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const NdsUtil = vm.runInNewContext(src("nds/ndsutil.js") + "\nNdsUtil");
const audio = vm.runInNewContext(src("nds/ndsaudio.js") +
  "\n({ NdsAudioRing, createNdsAudio })", { Float32Array, Math });

// A 512-byte header with a valid header CRC (GBATEK: CRC-16 of 000h-15Dh at
// 15Eh), optionally the logo checksum CF56h at 15Ch.
const ndsHeader = ({ crc = true, logo = false, title = "DINGBATTEST", code = "ADGE" } = {}) => {
  const b = new Uint8Array(0x400);
  for (let i = 0; i < title.length; i++) b[i] = title.charCodeAt(i);
  for (let i = 0; i < 4; i++) b[0x0C + i] = code.charCodeAt(i);
  if (logo) { b[0x15C] = 0x56; b[0x15D] = 0xCF; }
  if (crc) {
    const c = NdsUtil.crc16(b, 0, 0x15E);
    b[0x15E] = c & 0xFF; b[0x15F] = c >> 8;
  }
  return b;
};

// --- ndsutil.js --------------------------------------------------------------

test("CRC-16 is GBATEK's GetCRC16 (the reflected A001h polynomial)", () => {
  const check = new TextEncoder().encode("123456789");
  assert.equal(NdsUtil.crc16(check, 0, check.length), 0x4B37); // CRC-16/MODBUS check value
});

test("a DS ROM is told by its header checksums, any one of them", () => {
  assert.equal(NdsUtil.isNdsName("Game (U).NDS"), true);
  assert.equal(NdsUtil.isNdsName("game.gba"), false);
  assert.equal(NdsUtil.looksLikeNdsRom(ndsHeader()), true, "header CRC");
  assert.equal(NdsUtil.looksLikeNdsRom(ndsHeader({ crc: false, logo: true })), true, "logo CRC");
  assert.equal(NdsUtil.looksLikeNdsRom(ndsHeader({ crc: false })), false, "neither");
  assert.equal(NdsUtil.looksLikeNdsRom(new Uint8Array(0x100)), false, "too short for a header");
  eq(NdsUtil.headerInfo(ndsHeader()), { title: "DINGBATTEST", code: "ADGE" });
});

test("automatic layout shows the screens whichever way they come out bigger", () => {
  // A tall box stacks, a wide one goes side by side, a tie stacks.
  let l = NdsUtil.layout(400, 900, "auto");
  assert.equal(l.mode, "stack");
  eq([l.w, l.h], [256, 384]);
  assert.equal(l.scale, Math.min(400 / 256, 900 / 384));
  l = NdsUtil.layout(1100, 400, "auto");
  assert.equal(l.mode, "side");
  eq([l.w, l.h], [512, 192]);
  assert.equal(NdsUtil.layout(512, 384, "auto").mode, "stack");
  // A preference wins whatever the room; the gap joins the frame.
  l = NdsUtil.layout(1100, 400, "stack", { gap: 8 });
  eq([l.mode, l.w, l.h], ["stack", 256, 392]);
  l = NdsUtil.layout(400, 900, "side", { gap: 8 });
  eq([l.mode, l.w, l.h], ["side", 520, 192]);
  // Integer scaling floors (never below 1x); the mode is still chosen on the
  // unrounded fit.
  l = NdsUtil.layout(1000, 800, "auto", { integer: true });
  eq([l.mode, l.scale, l.cssW, l.cssH], ["stack", 2, 512, 768]);
  assert.equal(NdsUtil.layout(100, 100, "stack", { integer: true }).scale, 1);
});

test("the stylus maps client points to the bottom screen's pixels, scaled", () => {
  // Stacked at 2x with an 8-pixel gap, the canvas at (10, 20).
  const lay = NdsUtil.layout(512, 784, "stack", { gap: 8 });
  const rect = { left: 10, top: 20, width: 512, height: 784 };
  const at = (x, y) => NdsUtil.touchPoint(x, y, rect, lay);
  eq(at(10, 20 + 200 * 2), { x: 0, y: 0, inside: true }, "the bottom screen's corner");
  eq(at(10 + 511, 20 + (200 + 191) * 2 + 1), { x: 255, y: 191, inside: true });
  eq(at(10 + 100, 20 + 300), { x: 50, y: 0, inside: false }, "the top screen is not touchable");
  eq(at(10 + 100, 20 + 196 * 2), { x: 50, y: 0, inside: false }, "nor the gap");
  eq(at(10 + 600, 20 + 900), { x: 255, y: 191, inside: false }, "off the edge clamps");
  // Side by side, drawn at 1.5x: the bottom screen is the right one.
  const side = NdsUtil.layout(780, 288, "side", { gap: 8 });
  const r2 = { left: 0, top: 0, width: 780, height: 288 };
  eq(NdsUtil.touchPoint((264 + 30) * 1.5, 45, r2, side), { x: 30, y: 30, inside: true });
  eq(NdsUtil.touchPoint(100, 45, r2, side).inside, false);
});

test("app input ids map onto the core's buttons", () => {
  // Up Down Left Right A B Select Start L R X Y
  eq([...Array(12).keys()].map(NdsUtil.fromAppInput), [6, 7, 5, 4, 0, 1, 2, 3, 9, 8, 10, 11]);
  assert.equal(NdsUtil.fromAppInput(12), -1);
});

test("2x drops every other stereo frame; slow motion doubles each", () => {
  const s = new Float32Array([1, -1, 2, -2, 3, -3, 4, -4]);
  eq([...NdsUtil.speedAudio(s, 2)], [1, -1, 3, -3]);
  eq([...NdsUtil.speedAudio(s, 0.5)].slice(0, 8), [1, -1, 1, -1, 2, -2, 2, -2]);
  assert.equal(NdsUtil.speedAudio(s, 1), s);
});

test("BIOS and firmware dumps are told by name, then by size", () => {
  assert.equal(NdsUtil.biosKindOf("bios9.bin", 1), "bios9");
  assert.equal(NdsUtil.biosKindOf("x.bin", 16384), "bios7");
  assert.equal(NdsUtil.biosKindOf("x.bin", 262144), "firmware");
  assert.equal(NdsUtil.biosKindOf("x.bin", 5), null);
  assert.equal(NdsUtil.biosSizeOk("bios9", 4096), true);
  assert.equal(NdsUtil.biosSizeOk("bios9", 16384), false);
});

// --- ndsaudio.js -------------------------------------------------------------

test("the ring plays what is pushed, and a reset empties it without an underrun", () => {
  const ring = new audio.NdsAudioRing(32728.5, 32768, 64);
  const frames = 512;
  const data = new Float32Array(frames * 2).fill(0.5);
  ring.push(data);
  const L = new Float32Array(128), R = new Float32Array(128);
  ring.pull(L, R);
  assert.ok(L[127] > 0.4 && R[127] > 0.4, "steady input comes out (after the fade-in)");
  ring.reset();
  ring.pull(L, R);
  assert.equal(ring.stats().underruns, 0, "a reset is silence, not an underrun");
  ring.push(data);
  ring.pull(L, R);
  for (let i = 0; i < 8; i++) ring.pull(L, R); // drain it dry
  assert.equal(ring.stats().underruns, 1);
});

test("push counts the frames it hands over even though the send transfers them", () => {
  const out = audio.createNdsAudio();
  // Not attached: nothing is counted or sent.
  out.push(new Float32Array(20));
  assert.equal(out.stats().sent, 0);
  assert.equal(out.fillFrames(), null);
});

// --- index.js: a stand-in DS core -------------------------------------------

// The exports index.js uses, over a plain heap. Records what was booted.
const fakeCore = () => {
  const heap = new Uint8Array(1 << 22);
  let top = 1024;
  const alloc = (n) => { const p = top; top += (n + 15) & ~15; return p; };
  const c = {
    HEAPU8: heap, booted: [], buttons: [], touches: [], frames: 0,
    save: null, dirty: 0, romPtr: 0, romLen: 0,
    _malloc: alloc, _free() {},
    _nds_rom_alloc(n) { c.romLen = n; return (c.romPtr = alloc(n)); },
    _nds_boot(b9, b9n, b7, b7n, fw, fwn, sp, sn) {
      const rom = heap.slice(c.romPtr, c.romPtr + c.romLen);
      const save = sn ? heap.slice(sp, sp + sn) : null;
      c.booted.push({ how: "boot", rom, save, bios: [b9n, b7n, fwn] });
      c.save = save ? new Uint8Array(save) : null;
      return 1;
    },
    _nds_reboot(sp, sn) {
      const save = sn ? heap.slice(sp, sp + sn) : null;
      c.booted.push({ how: "reboot", save });
      c.save = save ? new Uint8Array(save) : null;
      return 1;
    },
    _nds_unload() { c.booted.push({ how: "unload" }); },
    _nds_run_frame() { c.frames++; },
    _nds_frame_count: () => c.frames,
    _nds_audio_frames: () => 0, _nds_audio_ptr: () => 0, _nds_audio_clear() {},
    _nds_set_button(id, d) { c.buttons.push([id, d]); },
    _nds_set_touch(x, y, d) { c.touches.push([x, y, d]); },
    _nds_fb555_top: () => 64, _nds_fb555_bottom: () => 64,
    _nds_fb_top: () => 64, _nds_fb_bottom: () => 64,
    // The chip, as the game left it: copied into the heap on request.
    _nds_save_size: () => (c.save ? c.save.length : 0),
    _nds_save_ptr() {
      if (!c.save) return 0;
      const p = 1 << 21;
      heap.set(c.save, p);
      return p;
    },
    _nds_save_dirty: () => c.dirty,
    _nds_save_clean() { c.dirty = 0; },
  };
  return c;
};

// An app with the stand-in core already fetched (loadNdsCore resolves it).
const appWithCore = async (opts) => {
  const app = await loadApp(opts);
  const core = fakeCore();
  app.context.__core = core;
  app.runIn("ndsCore = __core");
  return { app, core };
};

const ROM = (() => { const b = ndsHeader(); b[0x300] = 0xAB; return b; })();

test("a .nds is a DS game: system, library and boot on the DS core", async () => {
  const { app, core } = await appWithCore();
  assert.equal(app.runIn("systemOf('Pokemon (U).nds')"), "DS");
  await app.api.handleRomFile(fakeFile("Hello.nds", ROM));
  for (let i = 0; i < 20 && !core.booted.length; i++) await settle();
  assert.equal(core.booted.length, 1);
  assert.equal(core.booted[0].how, "boot");
  eq([...core.booted[0].rom], [...ROM], "the ROM went into the core's own buffer");
  eq(core.booted[0].bios, [0, 0, 0], "no dumps: HLE BIOS, built-in firmware");
  assert.equal(app.api.currentRomName, "rom.nds");
  assert.equal(app.api.currentOriginalName, "Hello.nds");
  assert.equal(app.runIn("ndsGameLoaded()"), true);
  assert.equal(app.document.body.classList.contains("nds-mode"), true);
  assert.equal(app.document.body.classList.contains("gb-mode"), false, "L/R stay");
  assert.ok(app.idb.get("rom:Hello.nds"), "kept in the library");
});

test("a DS battery save is stored when the game writes it, and boots the next time", async () => {
  const { app, core } = await appWithCore();
  await app.api.handleRomFile(fakeFile("Saver.nds", ROM));
  for (let i = 0; i < 20 && !core.booted.length; i++) await settle();
  // The game writes its chip.
  core.save = u8(1, 2, 3, 4, 5, 6, 7, 8);
  core.dirty = 1;
  await app.api.persistSave("rom.nds", "Saver.nds");
  eq([...app.idb.get("save:Saver.nds")], [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.equal(core.dirty, 0, "marked stored");
  // Unchanged since: nothing written (the dirty flag is the gate).
  core.save = u8(9, 9, 9, 9, 9, 9, 9, 9);
  await app.api.persistSave("rom.nds", "Saver.nds");
  eq([...app.idb.get("save:Saver.nds")], [1, 2, 3, 4, 5, 6, 7, 8]);

  // A fresh page: the stored save goes into the core at the boot.
  const { app: app2, core: core2 } = await appWithCore();
  for (const [k, v] of app.idb) app2.idb.set(k, v);
  await app2.runIn("launchRom('Saver.nds')");
  for (let i = 0; i < 20 && !core2.booted.length; i++) await settle();
  eq([...core2.booted[0].save], [1, 2, 3, 4, 5, 6, 7, 8]);
});

test("reset and an imported .sav reboot the DS core in place on the new save", async () => {
  const { app, core } = await appWithCore({ confirmResult: true });
  await app.api.handleRomFile(fakeFile("Imp.nds", ROM));
  for (let i = 0; i < 20 && !core.booted.length; i++) await settle();
  await app.runIn("applyImportedSave(new Uint8Array([4, 3, 2, 1]), 'Imp.sav')");
  for (let i = 0; i < 20 && core.booted.length < 2; i++) await settle();
  assert.equal(core.booted[1].how, "reboot", "no second copy of the ROM");
  eq([...core.booted[1].save], [4, 3, 2, 1]);
  eq([...app.idb.get("save:Imp.nds")], [4, 3, 2, 1]);
});

test("a DS save import goes to the core whole: no GBA container sniffing, .dsv taken", async () => {
  const { app, core } = await appWithCore({ confirmResult: true });
  await app.api.handleRomFile(fakeFile("Big.nds", ROM));
  for (let i = 0; i < 20 && !core.booted.length; i++) await settle();
  // 512K whose bytes at 42Ch happen to read as a GameShark SP tag: for a GBA
  // game that is a container (cut to 128K), for a DS game just save data.
  const sav = new Uint8Array(512 * 1024).fill(0x11);
  sav.set([0x78, 0x56, 0x34, 0x12], 0x42C);
  await app.runIn("(b) => applyImportedSave(b, 'Big.sav')")(sav);
  for (let i = 0; i < 20 && core.booted.length < 2; i++) await settle();
  assert.equal(core.booted[1].save.length, 512 * 1024, "the whole file reached the core");
  assert.equal(app.idb.get("save:Big.nds").length, 512 * 1024);
  // A dropped .dsv is a save to import, not a ROM (the core strips its footer).
  app.runIn("handleDroppedFile")(fakeFile("Big.dsv", u8(7, 7, 7, 7)));
  for (let i = 0; i < 20 && core.booted.length < 3; i++) await settle();
  assert.equal(core.booted[2].how, "reboot");
  eq([...core.booted[2].save], [7, 7, 7, 7]);
});

test("a GB/GBA game after a DS one hands the DS core's memory back", async () => {
  const { app, core } = await appWithCore();
  await app.api.handleRomFile(fakeFile("First.nds", ROM));
  for (let i = 0; i < 20 && !core.booted.length; i++) await settle();
  const gba = new Uint8Array(0x200); gba[3] = 0xEA;
  app.sandbox.Module = { ccall() {}, _wasm_state_size: () => 0 };
  await app.api.handleRomFile(fakeFile("Second.gba", gba));
  for (let i = 0; i < 20 && core.booted.length < 2; i++) await settle();
  assert.equal(core.booted.at(-1).how, "unload");
  assert.equal(app.runIn("ndsGameLoaded()"), false);
  assert.equal(app.document.body.classList.contains("nds-mode"), false);
});

test("buttons and the stylus reach the DS core", async () => {
  const { app, core } = await appWithCore();
  await app.api.handleRomFile(fakeFile("Touch.nds", ROM));
  for (let i = 0; i < 20 && !core.booted.length; i++) await settle();
  app.runIn("routeP1Input(10, true); routeP1Input(4, true); routeP1Input(4, false)");
  eq(core.buttons, [[10, 1], [0, 1], [0, 0]], "X, then A down and up");
  // Stacked 1x frame on a canvas at (0, 0): (100, 300) is bottom-screen (100, 108).
  app.runIn("ndsLay = NdsUtil.layout(256, 392, 'stack', { gap: 8 })");
  app.elements.get("canvas").setBox(0, 0, 256, 392);
  const canvas = app.elements.get("canvas");
  const ev = (x, y) => ({ clientX: x, clientY: y, pointerId: 7, pointerType: "touch", button: 0 });
  await canvas.dispatch("pointerdown", ev(100, 300));
  await canvas.dispatch("pointermove", ev(300, 500));
  await canvas.dispatch("pointerup", ev(300, 500));
  eq(core.touches, [[100, 100, 1], [255, 191, 1], [255, 191, 0]]);
  core.touches.length = 0;
  await canvas.dispatch("pointerdown", ev(100, 50)); // the top screen
  eq(core.touches, [], "a touch never starts off the bottom screen");
});

test("X and Y keys are game keys only while a DS game runs", async () => {
  const { app, core } = await appWithCore();
  // Default preset: D = X, C = Y.
  assert.equal(app.runIn("boundInput('KeyD')"), undefined);
  await app.api.handleRomFile(fakeFile("Keys.nds", ROM));
  for (let i = 0; i < 20 && !core.booted.length; i++) await settle();
  assert.equal(app.runIn("boundInput('KeyD')"), 10);
  assert.equal(app.runIn("boundInput('KeyC')"), 11);
  assert.equal(app.runIn("boundInput('KeyZ')"), 4);
});

test("a 10-key profile from before X/Y keeps its keys and gains the defaults", async () => {
  const app = await loadApp();
  app.idb.set("keybindings", [101, 100, 115, 102, 107, 106, 108, 59, 119, 114]);
  await app.runIn("loadKeybindingsFromStorage()");
  // D is that profile's Down, so X gets no key; C is free for Y.
  eq(app.runIn("activeBindings.slice(10)"), [-1, 99]);
});

test("DS games never go to Drive: their files and library entries stay here", async () => {
  const { app } = await appWithCore();
  assert.equal(app.runIn("driveExcluded('save:Game.nds')"), true);
  assert.equal(app.runIn("driveExcluded('rom:Game.nds')"), true);
  assert.equal(app.runIn("driveExcluded('stateauto:Game.nds')"), true);
  assert.equal(app.runIn("driveExcluded('save:Game.gba')"), false);
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
    sigs: {}, rmt: {}, delTs: {}, acct: "acct-1", parked: {}, connected: false };
  assert.equal(app.api.driveEnrolled(), true);
  app.api.markUpload("save:Game.nds");
  app.api.markUpload("save:Game.gba");
  app.api.markDelete("rom:Game.nds");
  eq(app.api.syncState.queueUp, ["save:Game.gba"]);
  eq(app.api.syncState.queueDel, []);
  // The library file that goes up has no DS entry, tombstone or rename.
  app.context.__lib = { recents: [{ name: "A.nds", ts: 2 }, { name: "B.gba", ts: 1 }],
                        tomb: [{ name: "C.nds", ts: 1 }, { name: "F.gb", ts: 1 }],
                        ren: [{ from: "D.nds", to: "E.nds", ts: 1 }] };
  const sent = app.runIn("driveLibraryOf(__lib)");
  eq(sent.recents.map((e) => e.name), ["B.gba"]);
  eq(sent.tomb.map((t) => t.name), ["F.gb"]);
  eq(sent.ren, []);
});

test("save states stay off until the DS core exports them, then go through the hook", async () => {
  const { app, core } = await appWithCore();
  await app.api.handleRomFile(fakeFile("States.nds", ROM));
  for (let i = 0; i < 20 && !core.booted.length; i++) await settle();
  assert.equal(app.runIn("captureStateBytes()"), null);
  assert.equal(app.api.applyStateBytes(u8(1)), false);
  assert.equal(app.document.body.classList.contains("nds-states"), false);
  // The exports another branch is adding.
  core._nds_state_size = () => 3;
  core._nds_state_data = () => { core.HEAPU8.set([7, 8, 9], 4096); return 4096; };
  core._nds_state_load = (p, n) => (core.loaded = [...core.HEAPU8.slice(p, p + n)], 1);
  eq([...app.runIn("captureStateBytes()")], [7, 8, 9]);
  assert.equal(app.api.applyStateBytes(u8(5, 6)), true);
  eq(core.loaded, [5, 6]);
  app.runIn("ndsApplyModeClasses()");
  assert.equal(app.document.body.classList.contains("nds-states"), true);
});
