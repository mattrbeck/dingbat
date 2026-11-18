// What reaches the page from outside the player's own hands: a webhook
// address and state metadata from Drive (whoever can write the account's
// files chooses them), and a ROM file named like a game already here.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { webcrypto } from "node:crypto";
import { loadApp, settle, eq, u8, fakeFile } from "./helpers.mjs";
import { makeDrive, makeClock, useClock } from "./drivefake.mjs";

const device = async (drive, clock) => {
  const app = await loadApp();
  useClock(app, clock);
  app.sandbox.FormData = FormData;
  app.sandbox.Blob = Blob;
  const posts = [];
  app.setFetch((url, opts) => {
    if (!/googleapis|google\.com/.test(String(url)) && opts?.method === "POST" && opts?.mode === "no-cors") {
      posts.push(String(url));
      return Promise.resolve({ ok: true });
    }
    return drive.fetch(url, opts);
  });
  app.api.gdriveToken = "tok";
  app.api.gdriveTokenExp = clock.peek() + 3600e3;
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
    sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
  };
  app.posts = posts;
  return app;
};
const eqBytes = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
const pull = async (app) => { await app.api.pullSync(); await settle(); };
const save = async (app) => { app.api.postSaveToHook("Game.gba", u8(1, 2, 3)); await settle(); };
const onDrive = (drive) => JSON.parse(new TextDecoder().decode(drive.get("save-hook").bytes));

// ---------------------------------------------------------------------------
// The save webhook
// ---------------------------------------------------------------------------

test("an address typed here is used; one that arrives from Drive waits to be allowed", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  const ask = d1.document.getElementById("save-hook-ask");

  await d0.api.setSaveHookUrl("http://mine.example/hook");
  await pull(d0);
  await save(d0);
  eq(d0.posts, ["http://mine.example/hook"], "typed here: sent");
  eq(Object.keys(onDrive(drive)).sort(), ["ts", "url"], "the allowance is this device's, not on Drive");

  await pull(d1);
  eq(d1.api.saveHook.url, "http://mine.example/hook", "the other device has the address");
  eq(d1.api.saveHook.ok, false, "and has not allowed it");
  assert.equal(ask.hidden, false, "it asks");
  assert.match(d1.document.getElementById("save-hook-ask-text").textContent, /mine\.example/);
  await save(d1);
  eq(d1.posts, [], "nothing is sent meanwhile");
  eq(d1.idb.get("save-hook").ok, false, "nor after a reload");

  d1.document.getElementById("save-hook-allow").click();
  await settle();
  assert.equal(ask.hidden, true);
  await save(d1);
  eq(d1.posts, ["http://mine.example/hook"], "allowed: sent");

  // The same address coming round again does not ask again.
  await pull(d1);
  eq(d1.api.saveHook.ok, true);
});

test("an address swapped on Drive is not sent to, and typing it here allows it", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await d0.api.setSaveHookUrl("http://mine.example/hook");
  await pull(d0);
  await pull(d1);
  d1.document.getElementById("save-hook-allow").click();
  await settle();

  // Someone else's write to the account's Drive file.
  await d0.api.setSaveHookUrl("http://theirs.example/take");
  await pull(d0);
  await pull(d1);
  eq(d1.api.saveHook.url, "http://theirs.example/take");
  eq(d1.api.saveHook.ok, false, "a different address is a new question");
  await save(d1);
  eq(d1.posts, []);

  await d1.api.setSaveHookUrl("http://theirs.example/take");
  eq(d1.api.saveHook.ok, true, "entered here by hand");
  await save(d1);
  eq(d1.posts, ["http://theirs.example/take"]);
});

test("removing the address needs no asking, and a record from an older build stays allowed", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await d0.api.setSaveHookUrl("http://mine.example/hook");
  await pull(d0);
  await pull(d1);
  await d0.api.setSaveHookUrl("");
  await pull(d0);
  await pull(d1);
  eq(d1.api.saveHook.url, "");
  assert.equal(d1.document.getElementById("save-hook-ask").hidden, true);

  const old = await loadApp();
  await old.api.dbPut("save-hook", { url: "http://kept.example/hook", ts: 5, dirty: false });
  await old.api.loadSaveHook();
  eq(old.api.saveHook.ok, true);
});

// ---------------------------------------------------------------------------
// State metadata
// ---------------------------------------------------------------------------

const PIC = "data:image/jpeg;base64,/9j/4AAQSkZJRg==";

test("state metadata keeps a picture and a time, and nothing else", async () => {
  const app = await loadApp();
  const clean = app.api.cleanStateMeta;
  eq(clean({ thumb: PIC, ts: 12 }), { thumb: PIC, ts: 12 });
  for (const thumb of [
    'x" onerror="alert(1)',
    PIC + '" onerror="alert(1)',
    "javascript:alert(1)",
    "https://elsewhere.example/a.png",
    "data:text/html;base64,PHNjcmlwdD4=",
    "data:image/svg+xml;base64,PHN2Zz4=",
    { toString: () => PIC },
    42,
  ]) eq(clean({ thumb, ts: 12 }), { ts: 12 }, String(thumb));
  eq(clean({ thumb: PIC, ts: "<img src=x onerror=alert(1)>" }), { thumb: PIC });
  eq(clean({ thumb: PIC, ts: 12, extra: "<b>" }), { thumb: PIC, ts: 12 });
  for (const v of [null, undefined, "str", 7, []]) eq(clean(v), {});
});

test("a slot whose stored picture is markup draws no picture, and no markup", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("G.gba", u8(1, 2, 3));
  await app.api.dbPut("state:G.gba", u8(9));
  await app.api.dbPut("statemeta:G.gba", { thumb: 'x" onerror="alert(1)', ts: '<img src=x onerror=alert(1)>' });
  await app.api.dbPut("state:G.gba:slot1", u8(9));
  await app.api.dbPut("statemeta:G.gba:slot1", { thumb: PIC, ts: 1700000000000 });
  await app.runIn('currentOriginalName = "G.gba"');
  await app.runIn("renderStatesGrid()");
  await settle();
  const grid = app.document.getElementById("states-grid");
  const walk = (el, out = []) => { out.push(el); for (const c of el.children || []) walk(c, out); return out; };
  const all = walk(grid);
  for (const el of all) {
    assert.ok(!/onerror/.test(el.innerHTML || ""), "nothing is written as markup");
    assert.ok(!/onerror/.test(el.src || ""), "nor into a src");
    assert.ok(!/onerror/.test(el.textContent || ""), "nor shown as text");
  }
  eq(all.filter((el) => el.src === PIC).length, 1, "the real picture still shows");
});

// ---------------------------------------------------------------------------
// A ROM named like a game already here
// ---------------------------------------------------------------------------

test("claimRomName: the same bytes are the same game, different bytes take a number", async () => {
  const app = await loadApp();
  const claim = app.api.claimRomName;
  eq(await claim("Game.gba", u8(1, 2, 3)), "Game.gba", "a new name");
  await app.api.addRecentRom("Game.gba", u8(1, 2, 3));
  eq(await claim("Game.gba", u8(1, 2, 3)), "Game.gba", "the same file again");
  eq(await claim("Game.gba", u8(9, 9, 9)), "Game (2).gba", "another game of that name");
  eq(await claim("Game.gba", u8(1, 2)), "Game (2).gba", "a shorter one too");

  await app.api.addRecentRom("Game (2).gba", u8(9, 9, 9));
  eq(await claim("Game.gba", u8(9, 9, 9)), "Game (2).gba", "the second one again is the second one");
  eq(await claim("Game.gba", u8(7, 7, 7)), "Game (3).gba", "a third");
  eq(await claim("No Extension", u8(1)), "No Extension");
  await app.api.addRecentRom("No Extension", u8(1));
  eq(await claim("No Extension", u8(2)), "No Extension (2)");
  await app.api.addRecentRom("A.B.gba", u8(1));
  eq(await claim("A.B.gba", u8(2)), "A.B (2).gba", "the number goes before the last dot");
});

test("claimRomName: a game here without its file is given its file back, unless the size says otherwise", async () => {
  const app = await loadApp();
  const claim = app.api.claimRomName;
  await app.api.addRecentRom("Game.gba", u8(1, 2, 3));
  await app.api.dbPut("save:Game.gba", u8(5));
  await app.api.evictLocalRom("Game.gba");
  assert.equal(app.idb.get("rom:Game.gba"), undefined, "the file made room");
  eq(await claim("Game.gba", u8(4, 5, 6)), "Game.gba", "the size on record matches: its file");
  eq(await claim("Game.gba", u8(4, 5, 6, 7)), "Game (2).gba", "another size: another game");
});

test("a file dropped under an existing game's name does not touch that game or its save", async () => {
  const app = await loadApp();
  app.runIn("Module.ccall = () => {}");
  const rom = (f) => new Uint8Array(readFileSync(new URL("../../tests/roms/" + f, import.meta.url)));
  const mine = rom("linktest.gba");
  const theirs = rom("gbaedge.gba");
  await app.api.addRecentRom("Pocket.gba", mine);
  await app.api.dbPut("save:Pocket.gba", u8(42));

  app.api.handleRomFile(fakeFile("Pocket.gba", theirs));
  await settle();
  await settle();
  eq(app.idb.get("rom:Pocket.gba").data, mine, "the game that was here keeps its file");
  eq(app.idb.get("save:Pocket.gba"), u8(42), "and its save");
  eq(app.idb.get("rom:Pocket (2).gba").data, theirs, "the new one went in beside it");
  assert.equal(app.idb.get("save:Pocket (2).gba"), undefined);
  eq(app.idb.get("recent").map((r) => r.name).sort(), ["Pocket (2).gba", "Pocket.gba"]);

  // The same file again is that second game, not a third.
  app.api.handleRomFile(fakeFile("Pocket.gba", theirs));
  await settle();
  await settle();
  eq(app.idb.get("recent").map((r) => r.name).sort(), ["Pocket (2).gba", "Pocket.gba"]);
});

// ---------------------------------------------------------------------------
// The same name on Drive, another game
// ---------------------------------------------------------------------------

const X = u8(1, 1, 1, 1, 1, 1, 1, 1);   // the account's "Game.gba"
const Y = u8(2, 2, 2, 2, 2, 2, 2, 2);   // this device's: the same size, another file
const withCrypto = (app) => { app.sandbox.crypto = webcrypto; return app; };
const flush = async (app) => { await app.api.flushSync(); await settle(); };
const names = (app) => app.idb.get("recent").map((r) => r.name).sort();

// Device A's game, on Drive with its save.
const accountWithGame = async (drive, clock) => {
  const a = withCrypto(await device(drive, clock));
  a.idb.set("recent", [{ name: "Game.gba", ts: 100 }]);
  a.idb.set("rom:Game.gba", { name: "Game.gba", data: X });
  a.idb.set("save:Game.gba", u8(10, 10));
  await pull(a);
  await flush(a);
  eq(drive.get("rom:Game.gba").bytes, X);
  eq(drive.get("save:Game.gba").bytes, u8(10, 10));
  return a;
};

test("a device signing in with another game of the same name keeps both, each with its own save", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const a = await accountWithGame(drive, clock);

  const b = withCrypto(await device(drive, clock));
  b.idb.set("recent", [{ name: "Game.gba", ts: 200 }]);
  b.idb.set("rom:Game.gba", { name: "Game.gba", data: Y });
  b.idb.set("save:Game.gba", u8(20, 20));
  await pull(b);
  await flush(b);
  await pull(b);
  await flush(b);

  eq(b.idb.get("rom:Game (2).gba").data, Y, "this device's game moved to the numbered name");
  eq(b.idb.get("save:Game (2).gba"), u8(20, 20), "with its save");
  assert.equal(b.idb.get("rom:Game.gba"), undefined, "the account's game is not here until fetched");
  assert.ok(!b.idb.get("save:Game.gba") || !eqBytes(b.idb.get("save:Game.gba"), u8(20, 20)),
    "and this device's save is not under its name");
  eq(names(b), ["Game (2).gba", "Game.gba"], "both in the library");

  eq(drive.get("rom:Game.gba").bytes, X, "Drive's game is untouched");
  eq(drive.get("save:Game.gba").bytes, u8(10, 10), "and so is its save");
  eq(drive.get("rom:Game (2).gba").bytes, Y, "the moved game went up as its own");
  eq(drive.get("save:Game (2).gba").bytes, u8(20, 20));

  await pull(a);
  eq(a.idb.get("save:Game.gba"), u8(10, 10), "the first device still has its own save");
  eq(a.idb.get("rom:Game.gba").data, X);
  eq(names(a), ["Game (2).gba", "Game.gba"], "and sees the other game beside it");
});

test("the same file on both is one game, and syncs as before", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  await accountWithGame(drive, clock);

  const b = withCrypto(await device(drive, clock));
  b.idb.set("recent", [{ name: "Game.gba", ts: 50 }]);
  b.idb.set("rom:Game.gba", { name: "Game.gba", data: X });
  await pull(b);
  await flush(b);
  eq(names(b), ["Game.gba"]);
  eq(b.idb.get("save:Game.gba"), u8(10, 10), "the account's save comes down");
  assert.ok(!drive.get("rom:Game (2).gba"), "nothing was moved aside");
});

test("another size needs no digest to tell", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  await accountWithGame(drive, clock);

  const b = await device(drive, clock);   // no WebCrypto: an http: dev serve
  b.sandbox.crypto = { getRandomValues: (x) => x };
  b.idb.set("recent", [{ name: "Game.gba", ts: 200 }]);
  b.idb.set("rom:Game.gba", { name: "Game.gba", data: u8(3, 3, 3) });
  b.idb.set("save:Game.gba", u8(30));
  await pull(b);
  await flush(b);
  eq(b.idb.get("rom:Game (2).gba").data, u8(3, 3, 3));
  eq(b.idb.get("save:Game (2).gba"), u8(30));
  eq(drive.get("save:Game.gba").bytes, u8(10, 10));
});

test("a game this device has already synced is left alone", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  await accountWithGame(drive, clock);

  const b = withCrypto(await device(drive, clock));
  b.idb.set("recent", [{ name: "Game.gba", ts: 200 }]);
  b.idb.set("rom:Game.gba", { name: "Game.gba", data: Y });
  b.api.syncState.sigs["rom:Game.gba"] = "from-an-older-build";
  await pull(b);
  eq(names(b), ["Game.gba"]);
  eq(b.idb.get("rom:Game.gba").data, Y);
});

test("adding a file under the name of a game that is only on Drive: Drive's digest tells them apart", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  await accountWithGame(drive, clock);

  const b = withCrypto(await device(drive, clock));
  await pull(b);
  eq(names(b), ["Game.gba"], "listed from Drive, no file here");
  assert.equal(b.idb.get("rom:Game.gba"), undefined);
  eq(await b.api.claimRomName("Game.gba", X), "Game.gba", "its own file, given back");
  eq(await b.api.claimRomName("Game.gba", Y), "Game (2).gba", "another file of the same size");
});
