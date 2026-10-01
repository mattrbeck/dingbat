// A Drive-only game's tile while it comes down (index.js fetchTileGame and
// paintTileLoad): it says Opening or Downloading with the bytes, gives way
// when a later tap wins, says so when it fails, and a tap on the picture
// during a ↓ download turns it into an open.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, settle, gameTiles } from "./helpers.mjs";

const ROM = { "A.gba": 0x0a, "B.gba": 0x0b, "C.gba": 0x0c };
const MB2 = String(2 * 1024 * 1024);

// A stand-in core, enough for launchRom to boot a game and name it.
const boot = async () => {
  const app = await loadApp();
  app.runIn(`
    globalThis.core = { rom: 0 };
    globalThis.netMode = false;
    Object.assign(Module, {
      ccall: (fn, ret, types, args) => {
        if (fn !== "initFromEmscripten") return 0;
        const rom = FS.files.get(args[0]);
        core.rom = rom ? rom[0] : 0;
        return 0;
      },
      _wasm_state_size: () => 0, _wasm_state_data: () => 8, _wasm_load_state: () => 0,
      _malloc: () => 32, _free: () => {},
      memory: { buffer: new ArrayBuffer(64) },
    });
    storageReadyResolve();
  `);
  await app.runIn("Module.onRuntimeInitialized()");
  const games = Object.keys(ROM);
  app.idb.set("recent", games.map((name, i) => ({ name, ts: 100 - i })));
  for (const g of games) app.idb.set("rom:" + g, { name: g, data: u8(ROM[g], 1, 2, 3) });
  app.idb.delete("rom:B.gba"); // B is on Drive only
  app.api.gdriveToken = "test-token";
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: { "rom:B.gba": "s" }, rmt: {}, connected: true };
  return app;
};

// Drive with B on it, 2 MB by the listing. The bytes wait for `release()`;
// `fail` makes them a server error instead.
const drive = (app) => {
  const d = { fail: false, fetches: 0 };
  d.gate = new Promise((r) => { d.release = r; });
  app.setFetch(async (url) => {
    url = String(url);
    if (url.includes("spaces=appDataFolder")) {
      return jsonRes({ files: [{ id: "b", name: "rom:B.gba", size: MB2,
                                 modifiedTime: "2026-01-01T00:00:00Z" }] });
    }
    if (url.includes("alt=media")) {
      d.fetches++;
      await d.gate;
      return d.fail ? bytesRes(u8(), 500) : bytesRes(u8(0x0b, 1, 2, 3));
    }
    return jsonRes({});
  });
  return d;
};

const drain = async (n = 16) => { for (let i = 0; i < n; i++) await settle(); };
const named = (app) => app.api.currentOriginalName;
const tile = (app, name) => gameTiles(app).find((t) => t.dataset.rom === name);
const kid = (el, cls) => el?.children.find((c) => c.classList.contains(cls));
const launchOf = (app, name) => kid(tile(app, name), "home-tile-launch");
const says = (app, name) => {
  const over = kid(launchOf(app, name), "home-tile-load");
  return over ? [over.children[0].textContent, over.children[1].textContent] : null;
};
const has = (app, name, cls) => tile(app, name).classList.contains(cls);
const dlBusy = (app, name) => kid(tile(app, name), "home-tile-dl")?.classList.contains("is-busy");

const home = async (app) => {
  await app.api.refreshHomeRecent();
  await drain();
  assert.ok(tile(app, "B.gba") && has(app, "B.gba", "home-tile-cloud"), "B is a Drive tile");
};

test("a tap on a Drive-only tile says Opening, with the bytes, until the game starts", async () => {
  const app = await boot();
  const d = drive(app);
  await home(app);
  assert.equal(says(app, "B.gba"), null, "at rest, nothing over the picture");

  launchOf(app, "B.gba").click();
  await drain();
  assert.deepEqual(says(app, "B.gba"), ["Opening", "0.0 of 2.0 MB"]);
  assert.ok(has(app, "B.gba", "is-loading") && has(app, "B.gba", "is-opening"));
  assert.ok(dlBusy(app, "B.gba"), "the corner spins too");

  d.release();
  await drain(40);
  assert.equal(named(app), "B.gba", "and then it opens");
  assert.equal(app.runIn(`tileLoads.has("B.gba")`), false, "leaving nothing behind");
  assert.equal(says(app, "B.gba"), null);
  assert.ok(!has(app, "B.gba", "is-loading") && !has(app, "B.gba", "is-opening"));
});

test("a later tap elsewhere turns an opening tile back into a plain download", async () => {
  const app = await boot();
  const d = drive(app);
  await home(app);
  launchOf(app, "B.gba").click();
  await drain();
  launchOf(app, "C.gba").click(); // the player changes their mind
  await drain();
  assert.equal(named(app), "C.gba");
  assert.equal(says(app, "B.gba")[0], "Downloading", "B no longer claims it will open");
  assert.ok(!has(app, "B.gba", "is-opening"));

  d.release();
  await drain(40);
  assert.equal(named(app), "C.gba", "C stays");
  assert.ok(kid(tile(app, "B.gba"), "home-tile-done"), "B gets its check instead");
});

test("↓ downloads without opening, then shows a check", async () => {
  const app = await boot();
  const d = drive(app);
  await home(app);
  kid(tile(app, "B.gba"), "home-tile-dl").click();
  await drain();
  assert.deepEqual(says(app, "B.gba"), ["Downloading", "0.0 of 2.0 MB"]);
  assert.ok(!has(app, "B.gba", "is-opening"), "no ring: it will not open");

  d.release();
  await drain(40);
  assert.equal(named(app), null, "nothing opened");
  assert.ok(app.idb.get("rom:B.gba"), "the game is on this device");
  assert.equal(says(app, "B.gba"), null);
  assert.ok(kid(tile(app, "B.gba"), "home-tile-done"), "a check for a moment");
});

test("a tap on the picture during a ↓ download opens it when it lands", async () => {
  const app = await boot();
  const d = drive(app);
  await home(app);
  kid(tile(app, "B.gba"), "home-tile-dl").click();
  await drain();
  launchOf(app, "B.gba").click();
  await drain();
  assert.equal(says(app, "B.gba")[0], "Opening", "the download became an open");

  d.release();
  await drain(40);
  assert.equal(named(app), "B.gba");
  assert.equal(d.fetches, 1, "one download, not two");
});

test("a failed download says so until the next tap, which tries again", async () => {
  const app = await boot();
  const d = drive(app);
  await home(app);
  d.fail = true;
  d.release();
  launchOf(app, "B.gba").click();
  await drain(40);
  assert.equal(named(app), null);
  assert.deepEqual(says(app, "B.gba"), ["Couldn’t download", "Tap to try again"]);
  assert.ok(has(app, "B.gba", "is-failed") && !has(app, "B.gba", "is-loading"));
  assert.ok(!dlBusy(app, "B.gba"), "↓ is offered again");

  d.fail = false;
  launchOf(app, "B.gba").click();
  await drain(40);
  assert.equal(named(app), "B.gba", "the retry opens it");
  assert.ok(!has(app, "B.gba", "is-failed"));
});

test("before Drive answers the sign-in, the tile says it is signing in", async () => {
  const app = await boot();
  drive(app);
  await home(app);
  app.runIn(`setTileLoad("B.gba", { open: {}, gen: loadGen, stage: "signin", got: 0, total: 0, run: null })`);
  assert.deepEqual(says(app, "B.gba"), ["Signing in…", "Google Drive"]);
  assert.ok(has(app, "B.gba", "is-opening"), "a tap to play is marked from the start");
  assert.ok(dlBusy(app, "B.gba"));
  app.runIn(`setTileLoad("B.gba", null)`);
  assert.equal(says(app, "B.gba"), null);
  assert.ok(!dlBusy(app, "B.gba"));
});

test("the hero showing a Drive-only game says it on its button, its tile being stood down", async () => {
  const app = await boot();
  drive(app);
  await home(app);
  app.runIn(`heroName = "B.gba"; heroCard.dataset.mode = "closed"; heroSession = false;`);
  const label = () => app.runIn(`heroResumeLabel.textContent`);
  app.runIn(`setTileLoad("B.gba", { open: {}, gen: loadGen, stage: "signin", got: 0, total: 0 })`);
  assert.equal(label(), "Signing in…");
  app.runIn(`setTileLoad("B.gba", { open: {}, gen: loadGen, stage: "download", got: 3, total: 8 })`);
  assert.equal(label(), "Opening · 37%");
  app.runIn(`setTileLoad("B.gba", { open: null, gen: 0, stage: "download", got: 4, total: 8 })`);
  assert.equal(label(), "Downloading · 50%");
  app.runIn(`setTileLoad("B.gba", { open: null, gen: 0, stage: "failed", got: 4, total: 8 })`);
  assert.equal(label(), "Try again");
  app.runIn(`setTileLoad("B.gba", null)`);
  assert.equal(label(), "Play", "and back to what it said");
  // Another game's load leaves the hero alone.
  app.runIn(`setTileLoad("C.gba", { open: null, gen: 0, stage: "download", got: 1, total: 2 })`);
  assert.equal(label(), "Play");
});

test("the bytes read in the total's unit", () => {
  return loadApp().then((app) => {
    assert.equal(app.runIn(`tileBytes(3.1 * 1024 * 1024, 8 * 1024 * 1024)`), "3.1 of 8.0 MB");
    assert.equal(app.runIn(`tileBytes(100 * 1024, 512 * 1024)`), "100 of 512 KB");
    assert.equal(app.runIn(`tileBytes(9e9, 1024 * 1024)`), "1.0 of 1.0 MB", "never past the total");
    assert.equal(app.runIn(`tileBytes(0, 0)`), "", "no total, nothing yet: nothing");
  });
});
