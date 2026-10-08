// Checkpoints: the session taken every minute of play, so a browser that
// crashes with the game on screen resumes about where it stopped, and the
// earlier moments kept for when the newest one is what crashes. The
// reported case: FireRed on an Android phone, a long session with no
// in-game save, the browser crashed, and the relaunch did not pick up where
// it left off - the session was only ever taken when the page was hidden.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, settle } from "./helpers.mjs";

const MIN = 60 * 1000;

// A core whose state image is 64 bytes, packed as itself (no worker here:
// the page path, wasm_pack_state, runs).
const stubModule = (app) => app.runIn(`
  globalThis.__forced = []; globalThis.__inits = [];
  globalThis.Module = {
    ccall: (fn, ret, types, args) => { __inits.push(args[0]); },
    _wasm_state_plain_size: () => 64,
    _wasm_state_size: () => 64,
    _wasm_state_data: () => 8,
    _wasm_pack_state: (ptr, len) => len,
    _wasm_load_state: () => { __loads = (globalThis.__loads || 0) + 1; return 1; },
    _wasm_flush_save: () => {},
    _malloc: () => 8, _free: () => {},
    memory: { buffer: new ArrayBuffer(256) },
  };
`);

const loaded = (app, name = "A.gba", romName = "rom.gba") => {
  app.api.currentOriginalName = name;
  app.api.currentRomName = romName;
};

const sigOf = (app, bytes) =>
  app.runIn(`saveSignature(new Uint8Array(${JSON.stringify([...bytes])}))`);

// Play `ms` and take the checkpoint that falls due.
const playAndCheckpoint = async (app, ms) => {
  app.runIn(`runPlayMs += ${ms}`);
  await app.runIn("takeCheckpoint()");
  await settle();
};

// ── Retention ───────────────────────────────────────────────────────────────

const entries = (app, list) => JSON.parse(JSON.stringify(list));
const keep = (app, list, crashSince = 0, now = Date.now()) =>
  entries(app, app.runIn(`keepCheckpoints(${JSON.stringify(list)}, ${crashSince}, ${now})`));

test("a long session keeps a spread: the newest, one a little back, one a long way back", async () => {
  const app = await loadApp();
  const now = Date.now();
  let list = [];
  // Three hours of play, a checkpoint a minute, thinned as they arrive.
  for (let i = 1; i <= 180; i++) {
    list.push({ slot: i, ts: now - (180 - i) * MIN, play: i * MIN, saveSig: null });
    list = keep(app, list, 0, now);
    assert.ok(list.length <= 7, "never more than the newest plus one per span");
  }
  const ages = list.map((e) => 180 - e.play / MIN).sort((a, b) => a - b);
  assert.equal(ages[0], 0, "the newest is kept");
  assert.ok(ages.some((a) => a > 0 && a <= 3), "one within three minutes");
  assert.ok(ages.some((a) => a > 10 && a <= 30), "one ten to thirty minutes back");
  assert.ok(ages.some((a) => a > 120), "one more than two hours back");
});

test("a week away does not thin them: the spread is in play time, not real time", async () => {
  const app = await loadApp();
  const now = Date.now();
  const week = 7 * 24 * 60 * MIN;
  const old = [0, 5, 20, 60, 300].map((back, i) =>
    ({ slot: i, ts: now - week - back * MIN, play: (200 - back) * MIN, saveSig: null }));
  const after = keep(app, [...old, { slot: 9, ts: now, play: 201 * MIN, saveSig: null }], 0, now);
  assert.equal(after.length, 6, "every earlier moment survives the first one back");
});

test("after a crash the moments from before it are frozen, however often it is reopened", async () => {
  const app = await loadApp();
  const now = Date.now();
  const crashAt = now - 60 * MIN;
  let list = [0, 2, 8, 25, 100].map((back, i) =>
    ({ slot: i, ts: crashAt - back * MIN - 1, play: (200 - back) * MIN, saveSig: null }));
  const before = list.map((e) => e.slot).sort();
  // The newest is resumed again and again, each run playing for a while
  // (taking checkpoints) and then crashing.
  for (let run = 0; run < 30; run++) {
    for (let m = 1; m <= 3; m++) {
      list.push({ slot: 100 + run * 3 + m, ts: crashAt + run * 5 * MIN + m * MIN,
                  play: (200 + run * 3 + m) * MIN, saveSig: null });
      list = keep(app, list, crashAt, now);
    }
    for (const s of before) {
      assert.ok(list.some((e) => e.slot === s), "moment " + s + " still kept after run " + run);
    }
    assert.ok(list.filter((e) => e.ts >= crashAt).length <= 2, "the crash runs share two places");
  }
});

test("a month-old moment goes", async () => {
  const app = await loadApp();
  const now = Date.now();
  const list = [{ slot: 0, ts: now - 31 * 24 * 60 * MIN, play: MIN, saveSig: null },
                { slot: 1, ts: now, play: 2 * MIN, saveSig: null }];
  assert.deepEqual(keep(app, list, 0, now).map((e) => e.slot), [1]);
});

// ── Taking them ─────────────────────────────────────────────────────────────

test("a minute of play takes the session and keeps a checkpoint", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app);
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true };
  app.sandbox.FS.files.set("rom.sav", u8(1, 2, 3));

  app.runIn("runPlayMs = 59 * 1000");
  app.runIn("maybeCheckpoint(performance.now())");
  await settle();
  assert.equal(app.idb.get("stateauto:A.gba"), undefined, "not before the minute");

  app.runIn("runPlayMs = 61 * 1000");
  app.runIn("maybeCheckpoint(performance.now())");
  await settle();
  const auto = app.idb.get("stateauto:A.gba");
  assert.ok(auto?.bytes, "the session is taken while the game runs");
  assert.equal(auto.saveSig, sigOf(app, u8(1, 2, 3)), "with the battery it carries");
  const idx = app.idb.get("ckpts:A.gba");
  assert.equal(idx.list.length, 1);
  const rec = app.idb.get("ckpt" + idx.list[0].slot + ":A.gba");
  assert.ok(rec?.bytes, "and kept as a checkpoint");
  assert.equal(rec.ts, auto.ts);
});

test("Drive gets a checkpoint's session at most every five minutes; leaving sends the newest", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app);
  app.api.gdriveToken = "t";
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true };
  const queued = () => app.runIn("syncState.queueUp.includes('stateauto:A.gba')");
  await playAndCheckpoint(app, MIN);
  assert.ok(queued(), "the first one goes up");
  app.runIn("syncState.queueUp = []");
  await playAndCheckpoint(app, MIN);
  assert.equal(queued(), false, "the next minute's waits");
  // Main Menu / hide / close with nothing new since: the waiting one is sent.
  await app.runIn("persistAutoState()");
  await settle();
  assert.ok(queued(), "leaving the game sends the session it has");
});

test("where a picture will not store (Safari private browsing), the checkpoint is kept without it", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app);
  // The picture's writes fail, as a Blob does in WebKit's private browsing:
  // the session picture's, and the checkpoint's first try.
  const refused = [];
  let ckptTries = 0;
  app.state.idbFail = (op, key) => {
    if (op !== "put") return false;
    if (key === "sessionpic:A.gba" || (/^ckpt\d+:/.test(key) && ckptTries++ === 0)) {
      refused.push(key);
      return true;
    }
    return false;
  };
  const ts = Date.now();
  app.runIn(`sessionSnapTs.set('A.gba', ${ts})`);
  await app.runIn(`storeCheckpoint('A.gba', { bytes: new Uint8Array([1, 2]), ts: ${ts}, play: 60000,
                                              epoch: 0, saveSig: null, pic: { fake: "blob" } })`);
  await settle();
  assert.equal(refused.length, 2, "both picture writes were refused: " + refused.join(", "));
  assert.equal(app.idb.get("stateauto:A.gba").ts, ts, "the session is stored");
  const idx = app.idb.get("ckpts:A.gba");
  assert.equal(idx?.list.length, 1, "and the checkpoint");
  assert.equal(app.idb.get("ckpt" + idx.list[0].slot + ":A.gba").pic, null, "without its picture");
});

test("a newer snapshot taken while a checkpoint packs is not written back over", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app);
  app.runIn("runPlayMs = 61 * 1000");
  const late = app.runIn("takeCheckpoint()");
  // Before it lands: Main Menu takes the session as it is now.
  app.runIn("sessionMoved = true");
  await app.runIn("persistAutoState()");
  const newer = app.idb.get("stateauto:A.gba").ts;
  await late;
  await settle();
  assert.equal(app.idb.get("stateauto:A.gba").ts, newer);
});

test("a reset while a checkpoint packs is not undone by it", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app);
  app.runIn("runPlayMs = 61 * 1000");
  const late = app.runIn("takeCheckpoint()");
  await app.runIn("deleteKeys([autoStateKey('A.gba'), ...ckptKeys('A.gba')])");
  await late;
  await settle();
  assert.equal(app.idb.get("stateauto:A.gba"), undefined);
  assert.equal(app.idb.get("ckpts:A.gba"), undefined);
});

test("an in-game save is stored once its file stops changing, not at the 5 s autosave", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app);
  let mtime = 1000;
  app.sandbox.FS.stat = () => ({ mtime, size: 2 });
  app.sandbox.FS.files.set("rom.sav", u8(1, 1));
  await app.runIn("watchBattery()"); // first look: what is there now
  assert.equal(app.idb.get("save:A.gba"), undefined);
  // The game writes its save over a few frames...
  app.sandbox.FS.files.set("rom.sav", u8(2, 2)); mtime = 1100;
  await app.runIn("watchBattery()");
  app.sandbox.FS.files.set("rom.sav", u8(3, 3)); mtime = 1200;
  await app.runIn("watchBattery()");
  assert.equal(app.idb.get("save:A.gba"), undefined, "not while it is still being written");
  // ...and stops.
  await app.runIn("watchBattery()");
  await settle();
  assert.deepEqual([...app.idb.get("save:A.gba")], [3, 3], "stored at the next look");
});

// ── Crashes ─────────────────────────────────────────────────────────────────

const marks = (app) => Object.keys(app.idb.get("playing") || {});
const crashesOf = (app, games, seen = []) => app.idb.set("crashes", { games, seen });

test("a run that ended without pausing or hiding counts as a crash", async () => {
  const app = await loadApp();
  app.idb.set("playing", { gone: { game: "A.gba", at: 1 } });
  await app.runIn("noteCrashedRuns()");
  assert.equal(app.runIn("crashStreak('A.gba')"), 1);
  assert.deepEqual(marks(app), [], "the mark is used up");
  assert.equal(app.idb.get("crashes").games["A.gba"].streak, 1, "and the count is stored");
});

test("a mark that comes back after it was counted is not counted again", async () => {
  const app = await loadApp();
  app.idb.set("playing", { gone: { game: "A.gba", at: 1 } });
  crashesOf(app, { "A.gba": { streak: 1, since: 5 } }, ["gone"]);
  await app.runIn("noteCrashedRuns()");
  assert.equal(app.runIn("crashStreak('A.gba')"), 1);
  assert.deepEqual(marks(app), []);
});

test("another tab still playing is not a crash", async () => {
  const app = await loadApp();
  app.idb.set("playing", { alive: { game: "A.gba", at: 1 } });
  app.runIn(`navigator.locks = { query: async () => ({ held: [{ name: "dingbat-page:alive" }] }) }`);
  await app.runIn("noteCrashedRuns()");
  assert.equal(app.runIn("crashStreak('A.gba')"), 0);
  assert.deepEqual(marks(app), ["alive"], "its mark is its own to clear");
});

test("playing marks the run; pausing after a clean minute clears the count", async () => {
  const app = await loadApp();
  crashesOf(app, { "A.gba": { streak: 2, since: 5 } });
  await app.runIn("noteCrashedRuns()");
  loaded(app);
  app.runIn("markPlaying()");
  await settle();
  assert.equal(marks(app).length, 1, "the run is marked while it plays");
  app.runIn("runPlayMs = 30 * 1000; clearPlaying()");
  await settle();
  assert.equal(app.runIn("crashStreak('A.gba')"), 2, "half a minute proves nothing");
  assert.deepEqual(marks(app), []);
  app.runIn("markPlaying(); runPlayMs = 61 * 1000; clearPlaying()");
  await settle();
  assert.equal(app.runIn("crashStreak('A.gba')"), 0);
  assert.equal(app.idb.get("crashes").games["A.gba"], undefined);
});

test("a core fault keeps the mark for the next boot", async () => {
  const app = await loadApp();
  loaded(app);
  app.runIn("markPlaying()");
  await settle();
  app.runIn("coreFaulted = true; clearPlaying()");
  await settle();
  assert.equal(marks(app).length, 1);
});

test("one crash resumes as usual; two in a row ask first", async () => {
  const app = await loadApp();
  crashesOf(app, { "A.gba": { streak: 1, since: 5 } });
  await app.runIn("noteCrashedRuns()");
  assert.equal(app.runIn("crashGate('A.gba')"), false, "the first is most likely the browser's");
  app.idb.set("playing", { gone: { game: "A.gba", at: 1 } });
  await app.runIn("noteCrashedRuns()");
  assert.equal(app.runIn("crashGate('A.gba')"), true);
  await settle();
  const modal = app.document.getElementById("moments-modal");
  assert.ok(modal.classList.contains("open"));
  assert.match(app.document.getElementById("moments-title").textContent, /stopped unexpectedly/);
  assert.equal(app.document.getElementById("moments-from-save").hidden, false);
});

test("a run that ended cleanly but whose IndexedDB write was lost (a quitting browser) is no crash", async () => {
  const app = await loadApp({ localStorageSeed: {
    "dingbat_clean:quit": JSON.stringify({ game: "A.gba", long: false }) } });
  app.idb.set("playing", { quit: { game: "A.gba", at: 1, long: false } });
  await app.runIn("noteCrashedRuns()");
  assert.equal(app.runIn("crashStreak('A.gba')"), 0);
  assert.deepEqual(marks(app), []);
  assert.equal(app.lsMap.has("dingbat_clean:quit"), false, "the note is used up");
});

test("a long clean run whose write was lost still clears the count", async () => {
  const app = await loadApp({ localStorageSeed: {
    "dingbat_clean:quit": JSON.stringify({ game: "A.gba", long: true }) } });
  crashesOf(app, { "A.gba": { streak: 1, since: 5 } });
  app.idb.set("playing", { quit: { game: "A.gba", at: 1, long: true } });
  await app.runIn("noteCrashedRuns()");
  assert.equal(app.runIn("crashStreak('A.gba')"), 0);
});

test("a crash after a minute of play starts a new row: what it resumed did not stop it", async () => {
  const app = await loadApp();
  crashesOf(app, { "A.gba": { streak: 1, since: 5 } });
  app.idb.set("playing", { gone: { game: "A.gba", at: 1, long: true } });
  await app.runIn("noteCrashedRuns()");
  assert.equal(app.runIn("crashStreak('A.gba')"), 1, "two long sessions ended by quitting never ask");
  app.idb.set("playing", { gone2: { game: "A.gba", at: 2, long: false } });
  await app.runIn("noteCrashedRuns()");
  assert.equal(app.runIn("crashStreak('A.gba')"), 2, "a quick one after it does");
});

test("the mark says when a run has played a minute", async () => {
  const app = await loadApp();
  loaded(app);
  app.runIn("markPlaying()");
  await settle();
  assert.equal(Object.values(app.idb.get("playing"))[0].long, false);
  app.runIn("runPlayMs = 61 * 1000; notePlayingLong()");
  await settle();
  assert.equal(Object.values(app.idb.get("playing"))[0].long, true);
});

// ── Last gasp ───────────────────────────────────────────────────────────────

test("a quitting browser's session and unsaved battery are taken in at the next boot", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app);
  app.sandbox.FS.files.set("rom.sav", u8(4, 4));
  app.idb.set("save:A.gba", u8(1, 1)); // the autosave had not run
  await app.runIn("persistAutoState()"); // the close handlers' snapshot ...
  // ... whose IndexedDB write never lands: put it back as unstored.
  const rec = app.idb.get("stateauto:A.gba");
  app.idb.delete("stateauto:A.gba");
  app.runIn(`unstoredSnap = { name: "A.gba", bytes: new Uint8Array(${JSON.stringify([...rec.bytes])}),
             ts: ${rec.ts}, saveSig: ${JSON.stringify(rec.saveSig)}, play: 0 }`);
  app.runIn("leaveLastGasp()");
  assert.ok(app.lsMap.has("dingbat_lastgasp"));

  const next = await loadApp({ localStorageSeed: { dingbat_lastgasp: app.lsMap.get("dingbat_lastgasp") } });
  next.idb.set("save:A.gba", u8(1, 1));
  await next.runIn("takeLastGasp()");
  const auto = next.idb.get("stateauto:A.gba");
  assert.equal(auto.ts, rec.ts, "the session it closed on");
  assert.deepEqual([...next.idb.get("save:A.gba")], [4, 4], "with the battery it carried");
  assert.equal(next.lsMap.has("dingbat_lastgasp"), false);
  assert.equal(next.idb.get("lastgasp"), rec.ts);
});

test("a last gasp older than the stored session, or already taken in, changes nothing", async () => {
  const gasp = (ts) => JSON.stringify({ game: "A.gba", ts, saveSig: null, play: 0, page: "p",
                                        state: Buffer.from([7]).toString("base64"), sav: null });
  const app = await loadApp({ localStorageSeed: { dingbat_lastgasp: gasp(100) } });
  app.idb.set("stateauto:A.gba", { bytes: u8(9), ts: 200, saveSig: null });
  await app.runIn("takeLastGasp()");
  assert.equal(app.idb.get("stateauto:A.gba").ts, 200);

  const again = await loadApp({ localStorageSeed: { dingbat_lastgasp: gasp(300) } });
  again.idb.set("lastgasp", 300);
  await again.runIn("takeLastGasp()");
  assert.equal(again.idb.get("stateauto:A.gba"), undefined, "one that came back is not taken twice");
});

// ── Going back ──────────────────────────────────────────────────────────────

const seedMoments = (app, saveNow, saveThen) => {
  app.idb.set("save:A.gba", saveNow);
  app.idb.set("stateauto:A.gba", { bytes: u8(9), ts: 3000, play: 3 * MIN, saveSig: sigOf(app, saveNow) });
  app.idb.set("ckpts:A.gba", { play: 3 * MIN, list: [
    { slot: 0, ts: 2000, play: 2 * MIN, saveSig: sigOf(app, saveNow) },
    { slot: 4, ts: 1000, play: MIN, saveSig: sigOf(app, saveThen) },
  ] });
  app.idb.set("ckpt0:A.gba", { bytes: u8(8), ts: 2000, play: 2 * MIN, saveSig: sigOf(app, saveNow), pic: null });
  app.idb.set("ckpt4:A.gba", { bytes: u8(7), ts: 1000, play: MIN, saveSig: sigOf(app, saveThen), pic: null });
};

test("the sheet lists where it stopped, then the earlier moments, newest first", async () => {
  const app = await loadApp();
  seedMoments(app, u8(1), u8(2));
  const list = app.runIn("listMoments('A.gba')");
  const got = JSON.parse(JSON.stringify(await list));
  assert.deepEqual(got.map((m) => m.kind + (m.slot ?? "")), ["session", "checkpoint0", "checkpoint4"]);
  await app.runIn("openMomentsModal('A.gba')");
  const cells = app.document.getElementById("moments-grid").children;
  assert.equal(cells.length, 3);
});

// The real boot, on a stub core: the moment goes in even though its battery
// is not the stored one (loadRom's `force`).
const bootable = (app) => {
  stubModule(app);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1, 2, 3, 4) });
};

test("going back past an in-game save keeps the newer save aside", async () => {
  const app = await loadApp();
  bootable(app);
  seedMoments(app, u8(1, 1), u8(2, 2));
  await app.runIn(`resumeMoment('A.gba', { kind: "checkpoint", slot: 4 })`);
  await settle();
  const kept = app.idb.get("oldsave:A.gba");
  assert.deepEqual([...kept.data], [1, 1], "Restore old save brings it back");
  assert.equal(kept.why, "replaced");
  assert.equal(app.api.currentOriginalName, "A.gba", "the game boots");
  assert.equal(app.runIn("globalThis.__loads || 0"), 1,
    "and the moment goes in, though its battery is the older one");
  assert.ok(!app.toasts.some((t) => /saved since/.test(t)), "with no 'saved since' refusal");
});

test("going back within the same save keeps nothing aside", async () => {
  const app = await loadApp();
  bootable(app);
  seedMoments(app, u8(1, 1), u8(2, 2));
  await app.runIn(`resumeMoment('A.gba', { kind: "checkpoint", slot: 0 })`);
  await settle();
  assert.equal(app.idb.get("oldsave:A.gba"), undefined);
  assert.equal(app.runIn("globalThis.__loads || 0"), 1);
});

test("the game's menu offers Resume from earlier only when there are earlier moments", async () => {
  const app = await loadApp();
  const labels = (moments) => app.runIn(`tileMenuEntries('A.gba', { moments: ${moments} })`)
    .map((b) => b.children.find((c) => c.classList.contains("tile-menu-label")).textContent);
  assert.ok(!labels(false).includes("Resume from earlier"));
  assert.ok(labels(true).includes("Resume from earlier"));
});

test("a game's checkpoints go with its reset and its delete", async () => {
  const app = await loadApp();
  seedMoments(app, u8(1), u8(2));
  await app.runIn("deleteSaveData('A.gba')");
  for (const k of ["ckpts:A.gba", "ckpt0:A.gba", "ckpt4:A.gba"]) {
    assert.equal(app.idb.get(k), undefined, k);
  }
});

test("checkpoint keys are never Drive files", async () => {
  const app = await loadApp();
  for (const k of ["ckpts:A.gba", "ckpt3:A.gba"]) {
    assert.equal(app.runIn(`parseDriveFileName(${JSON.stringify(k)})`), null, k);
  }
});
