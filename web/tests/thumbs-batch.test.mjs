// The one-time "Add pictures to your library?" offer and the batch behind
// it: every game without a picture is booted in the core (never as the
// loaded game), its last session restored where one exists, stepped, and
// its screen stored as "frame:<name>". Drive-only games, when asked for,
// are fetched into memory and never written to the device.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, jsonRes, bytesRes } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";

// A wasm stand-in: counts ticks and state loads; a 240x160 framebuffer at
// offset 16 of `memory`; a canvas whose toBlob yields a JPEG.
const stubModule = (app) => app.runIn(`
  globalThis.__ticks = 0; globalThis.__inits = []; globalThis.__loads = 0;
  globalThis.Module = {
    ccall: (fn, ret, types, args) => { __inits.push(args[0]); },
    _loop_tick: () => { __ticks++; },
    _clearAudioBuffer: () => {},
    _wasm_fb_ptr: () => 16,
    _wasm_load_state: () => { __loads++; return 1; },
    _malloc: () => 8, _free: () => {},
    memory: { buffer: new ArrayBuffer(16 + 240 * 160 * 4) },
  };
  const realCreate = document.createElement.bind(document);
  document.createElement = (tag) => {
    const el = realCreate(tag);
    if (tag === "canvas") el.toBlob = (cb, type) => cb(new Blob([new Uint8Array([0xff, 0xd8])], { type }));
    return el;
  };
`);

const seedLibrary = (app, names) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: 100 - i })));
  for (const n of names) app.idb.set("rom:" + n, { name: n, data: u8(1, 2, 3, 4) });
};

const framesOf = (app) => [...app.idb.keys()].filter((k) => k.startsWith("frame:")).sort();
const modalOpen = (app) => app.document.getElementById("thumbs-modal").classList.contains("open");

// ── The offer ───────────────────────────────────────────────────────────────

test("the offer opens once when a game has no picture, and records itself", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba", "B.gb"]);
  assert.equal(await app.api.maybeOfferThumbnails(), true);
  assert.ok(modalOpen(app));
  assert.ok(app.idb.get("thumbs_offered"), "the offer is recorded whatever the answer");

  app.document.getElementById("thumbs-not-now").click();
  assert.ok(!modalOpen(app));
  assert.equal(await app.api.maybeOfferThumbnails(), false, "never a second time");
});

test("no offer when every game already has a picture, and none is recorded", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  assert.equal(await app.api.maybeOfferThumbnails(), false);
  assert.equal(app.idb.get("thumbs_offered"), undefined);
});

test("no offer while a game is loaded (the batch would re-init its core)", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "A.gba";
  assert.equal(await app.api.maybeOfferThumbnails(), false);
  assert.equal(app.idb.get("thumbs_offered"), undefined, "not spent: offered later");
});

test("the Drive row shows only when signed in with a Drive-only game", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  await app.api.maybeOfferThumbnails();
  assert.equal(app.document.getElementById("thumbs-drive-row").hidden, true);

  const app2 = await loadApp();
  seedLibrary(app2, ["A.gba"]);
  app2.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "D.gba", ts: 1 }]);
  app2.api.gdriveToken = "t";
  app2.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                         sigs: {}, rmt: {}, connected: true };
  await app2.api.maybeOfferThumbnails();
  assert.equal(app2.document.getElementById("thumbs-drive-row").hidden, false);
  assert.equal(app2.document.getElementById("thumbs-drive-toggle").checked, false, "off by default");
});

// ── The batch ───────────────────────────────────────────────────────────────

test("every unpictured local game is booted, resumed where it can be, and pictured", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba", "B.gb", "C.gba"]);
  app.idb.set("stateauto:A.gba", { bytes: u8(9, 9, 9), ts: 1 });
  app.idb.set("save:B.gb", u8(5, 5));
  const cPicture = new Blob([u8(7)]);
  app.idb.set("frame:C.gba", cPicture);
  const recentBefore = JSON.stringify(app.idb.get("recent"));

  const n = await app.api.runThumbnailBatch();
  assert.equal(n, 2);
  eq(framesOf(app), ["frame:A.gba", "frame:B.gb", "frame:C.gba"]);
  assert.ok(app.idb.get("frame:A.gba") instanceof Blob);
  assert.equal(app.idb.get("frame:C.gba"), cPicture, "an existing picture is left alone");

  // A resumed from its session (one render); B booted through its logo.
  assert.equal(app.runIn("__loads"), 1);
  assert.equal(app.runIn("__ticks"), app.api.THUMBS_RESUME_FRAMES + app.api.THUMBS_BOOT_FRAMES);
  eq(app.runIn("__inits"), ["thumb.gba", "thumb.gb"], "scratch names, never rom.gba");

  // Nothing about the games themselves moved.
  assert.equal(JSON.stringify(app.idb.get("recent")), recentBefore, "play order untouched");
  assert.equal(app.api.currentRomName, null, "no game became the loaded game");
  assert.ok(!app.sandbox.FS.files.has("thumb.sav"), "the scratch battery save is gone");
  assert.ok(!modalOpen(app), "the box closes when the run ends");
  assert.ok(app.toasts.some((t) => /2 pictures added/.test(t)), app.toasts.join(" | "));
});

test("Drive-only games are fetched, pictured, and never written to the device", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba"]);
  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  app.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "D.gba", ts: 1 }]);
  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true };
  const downloads = [];
  app.setFetch(async (url, opts = {}) => {
    url = String(url);
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [
        { id: "r1", name: "rom:D.gba", size: "4", modifiedTime: "2026-01-01T00:00:00Z" },
        { id: "s1", name: "save:D.gba", size: "2", modifiedTime: "2026-01-01T00:00:00Z" },
      ] });
    }
    const dm = url.match(/\/files\/([^/?]+)\?alt=media/);
    if (dm) { downloads.push(dm[1]); return bytesRes(dm[1] === "r1" ? u8(1, 2, 3, 4) : u8(5, 5)); }
    return jsonRes({});
  });

  // Not asked for: skipped.
  assert.equal(await app.api.runThumbnailBatch({ includeDrive: false }), 0);
  eq(framesOf(app), ["frame:A.gba"]);

  assert.equal(await app.api.runThumbnailBatch({ includeDrive: true }), 1);
  eq(framesOf(app), ["frame:A.gba", "frame:D.gba"]);
  eq(downloads.sort(), ["r1", "s1"], "ROM and battery save were fetched");
  assert.equal(app.idb.get("rom:D.gba"), undefined, "the ROM never landed on this device");
  assert.equal(app.idb.get("save:D.gba"), undefined, "nor the save");
  eq(app.idb.get("recent").map((r) => r.name), ["A.gba", "D.gba"], "order untouched");
});

test("Stop ends the run after the game in hand", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba", "B.gba", "C.gba"]);
  // Cancel from inside the first game's frame loop (a task boundary).
  const p = app.api.runThumbnailBatch();
  await settle();
  app.document.getElementById("thumbs-stop").click();
  const n = await p;
  assert.equal(n, 0);
  eq(framesOf(app), []);
  assert.ok(app.toasts.some((t) => /No pictures added/.test(t)));
  assert.ok(!modalOpen(app));
});

test("a batch refuses to run over a loaded game", async () => {
  const app = await loadApp();
  stubModule(app);
  seedLibrary(app, ["A.gba"]);
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Other.gba";
  assert.equal(await app.api.runThumbnailBatch(), 0);
  eq(framesOf(app), []);
  assert.equal(app.runIn("__inits.length"), 0, "the core was not re-initialised");
});
