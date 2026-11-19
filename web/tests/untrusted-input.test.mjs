// What reaches the page from outside the player's own hands: state metadata
// from Drive (whoever can write the account's files chooses it), and a ROM
// file named like a game already here.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { webcrypto } from "node:crypto";
import { deflateRawSync } from "node:zlib";
import { loadApp, settle, eq, u8, fakeFile } from "./helpers.mjs";
import { makeDrive, makeClock, useClock } from "./drivefake.mjs";

const device = async (drive, clock) => {
  const app = await loadApp();
  useClock(app, clock);
  app.setFetch(drive.fetch);
  app.api.gdriveToken = "tok";
  app.api.gdriveTokenExp = clock.peek() + 3600e3;
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
    sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
  };
  return app;
};
const eqBytes = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
const pull = async (app) => { await app.api.pullSync(); await settle(); };

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

const rom = (f) => new Uint8Array(readFileSync(new URL("../../tests/roms/" + f, import.meta.url)));

// A library holding "Pocket.gba" (linktest) with a save and a state, and a
// different file (gbaedge) dropped under the same name: the question is up.
const clash = async () => {
  const app = await loadApp();
  app.runIn("Module.ccall = () => {}");
  const mine = rom("linktest.gba");
  const theirs = rom("gbaedge.gba");
  await app.api.addRecentRom("Pocket.gba", mine);
  await app.api.dbPut("save:Pocket.gba", u8(42));
  await app.api.dbPut("state:Pocket.gba", u8(7, 7));
  app.api.handleRomFile(fakeFile("Pocket.gba", theirs));
  await settle();
  await settle();
  const modal = app.document.getElementById("rom-clash-modal");
  assert.ok(modal.classList.contains("open"), "asked which game the name is for");
  assert.match(app.document.getElementById("rom-clash-title").textContent, /named “Pocket”/);
  assert.match(app.document.getElementById("rom-clash-both-sub").textContent, /“Pocket \(2\)”/);
  eq(app.idb.get("rom:Pocket.gba").data, mine, "nothing is changed while it is asked");
  const answer = async (id) => {
    app.document.getElementById(id).click();
    await settle();
    await settle();
    assert.ok(!modal.classList.contains("open"));
  };
  return { app, mine, theirs, answer };
};
const libraryNames = (app) => app.idb.get("recent").map((r) => r.name).sort();
const genOfGame = (app, n) => app.idb.get("recent").find((r) => r.name === n)?.gen || 0;

test("a file under another game's name, Keep both: it goes in numbered, the first game untouched", async () => {
  const { app, mine, theirs, answer } = await clash();
  await answer("rom-clash-both");
  eq(app.idb.get("rom:Pocket.gba").data, mine, "the game that was here keeps its file");
  eq(app.idb.get("save:Pocket.gba"), u8(42), "and its save");
  eq(app.idb.get("rom:Pocket (2).gba").data, theirs, "the new one went in beside it");
  assert.equal(app.idb.get("save:Pocket (2).gba"), undefined, "with no save");
  eq(libraryNames(app), ["Pocket (2).gba", "Pocket.gba"]);

  // The same file again is that second game: no question, no third.
  app.api.handleRomFile(fakeFile("Pocket.gba", theirs));
  await settle();
  await settle();
  assert.ok(!app.document.getElementById("rom-clash-modal").classList.contains("open"));
  eq(libraryNames(app), ["Pocket (2).gba", "Pocket.gba"]);
});

test("Replace: the new file takes the name, the save and states stay, and it is the next generation", async () => {
  const { app, theirs, answer } = await clash();
  const before = genOfGame(app, "Pocket.gba");
  await answer("rom-clash-replace");
  eq(app.idb.get("rom:Pocket.gba").data, theirs, "the file under the name is the new one");
  eq(app.idb.get("save:Pocket.gba"), u8(42), "the save stays with the name");
  eq(app.idb.get("state:Pocket.gba"), u8(7, 7), "and the state");
  eq(libraryNames(app), ["Pocket.gba"], "one game");
  assert.equal(app.idb.get("rom:Pocket (2).gba"), undefined);
  eq(genOfGame(app, "Pocket.gba"), before + 1, "a new generation: Drive's file is replaced, not kept");
});

test("Cancel, or closing the question: nothing is added and nothing changes", async () => {
  const { app, mine, answer } = await clash();
  await answer("rom-clash-cancel");
  eq(app.idb.get("rom:Pocket.gba").data, mine);
  eq(app.idb.get("save:Pocket.gba"), u8(42));
  eq(libraryNames(app), ["Pocket.gba"]);
  assert.equal(app.idb.get("rom:Pocket (2).gba"), undefined);
});

test("a replaced game goes up over Drive's file, and another device lets go of the old one", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const a = withCrypto(await device(drive, clock));
  a.idb.set("recent", [{ name: "Game.gba", ts: 100 }]);
  a.idb.set("rom:Game.gba", { name: "Game.gba", data: X });
  a.idb.set("save:Game.gba", u8(10, 10));
  await pull(a);
  await flush(a);
  const b = withCrypto(await device(drive, clock));
  b.idb.set("recent", [{ name: "Game.gba", ts: 50 }]);
  b.idb.set("rom:Game.gba", { name: "Game.gba", data: X });
  await pull(b);
  await flush(b);
  eq(b.idb.get("save:Game.gba"), u8(10, 10), "both devices hold the game and its save");

  await a.api.addRecentRom("Game.gba", Y, null, { replace: true });
  await settle();
  await pull(a);
  await flush(a);
  eq(drive.get("rom:Game.gba").bytes, Y, "Drive's file is the new one");
  eq(drive.get("save:Game.gba").bytes, u8(10, 10), "its save is still there");
  eq(a.idb.get("save:Game.gba"), u8(10, 10), "and still on the device that replaced it");

  await pull(b);
  await flush(b);
  assert.ok(!b.idb.get("rom:Game.gba") || eqBytes(b.idb.get("rom:Game.gba").data, Y),
    "the other device no longer runs the old file under the name");
  eq(drive.get("rom:Game.gba").bytes, Y, "and has not put the old one back");
});

// ---------------------------------------------------------------------------
// A zip that unpacks to more than it says
// ---------------------------------------------------------------------------

// One deflated entry; `claim` is the size the directory gives for it.
const zipOf = (name, data, claim = data.length) => {
  const comp = new Uint8Array(deflateRawSync(data));
  const nm = new TextEncoder().encode(name);
  const local = new Uint8Array(30 + nm.length + comp.length);
  const lv = new DataView(local.buffer);
  lv.setUint32(0, 0x04034b50, true); lv.setUint16(8, 8, true);
  lv.setUint32(18, comp.length, true); lv.setUint32(22, claim, true); lv.setUint16(26, nm.length, true);
  local.set(nm, 30); local.set(comp, 30 + nm.length);
  const cd = new Uint8Array(46 + nm.length);
  const cv = new DataView(cd.buffer);
  cv.setUint32(0, 0x02014b50, true); cv.setUint16(10, 8, true);
  cv.setUint32(20, comp.length, true); cv.setUint32(24, claim, true); cv.setUint16(28, nm.length, true);
  cd.set(nm, 46);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true); ev.setUint16(8, 1, true); ev.setUint16(10, 1, true);
  ev.setUint32(12, cd.length, true); ev.setUint32(16, local.length, true);
  const out = new Uint8Array(local.length + cd.length + end.length);
  out.set(local, 0); out.set(cd, local.length); out.set(end, local.length + cd.length);
  return out.buffer;
};

test("a zip entry comes out at the size the zip gives, or not at all", async () => {
  const app = await loadApp();
  app.sandbox.DecompressionStream = DecompressionStream;
  app.sandbox.Blob = Blob;
  const unzip = app.runIn("unzip");
  const data = new Uint8Array(200_000).map((_, i) => i % 7);

  const good = await unzip(zipOf("g.gba", data));
  eq(await good.extract(good.entries[0]), data, "an honest entry");

  // 8 MB of zeros, about 8 KB packed, in an entry that says 1000 bytes.
  const bomb = await unzip(zipOf("g.gba", new Uint8Array(8 << 20), 1000));
  await assert.rejects(bomb.extract(bomb.entries[0]), /larger than the zip says/);

  const short = await unzip(zipOf("g.gba", data, data.length + 5));
  await assert.rejects(short.extract(short.entries[0]), /cut short/);

  const huge = await unzip(zipOf("g.gba", data, 600 * 1024 * 1024));
  await assert.rejects(huge.extract(huge.entries[0]), /too large/);
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
