// Two devices, one account, and work done on one of them while it was away
// from Drive. Every action carries the moment it was asked for, and the
// library merge settles what happened before a single file is touched, so
// the files can never be left disagreeing with the library.
//
// The rule the cases below pin: a play is evidence about whether a game
// should exist, and no evidence at all about what it is called. So a play
// after a delete cancels the delete, and a play after a rename does not
// cancel the rename — that device simply has not pulled it yet. Only a
// fresh import claiming the old name spends a rename.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, jsonRes, bytesRes } from "./helpers.mjs";

const FILES = "https://www.googleapis.com/drive/v3/files";
const UPLOAD = "https://www.googleapis.com/upload/drive/v3/files";
const MON = Date.parse("2026-02-02T00:00:00Z");
const TUE = Date.parse("2026-02-03T00:00:00Z"); // this device acts, away
const WED = Date.parse("2026-02-04T00:00:00Z"); // the other device acts
const JAN = "2026-01-01T00:00:00Z";             // when the ROM was uploaded

// The request shapes mirror index.js: a content write is a media PATCH to
// the upload host and must be matched before the metadata rename PATCH.
const makeDrive = ({ files = {}, lib = { recents: [], tomb: [], ren: [] } }) => {
  const map = new Map();
  let n = 0;
  for (const [name, mt] of Object.entries(files)) {
    map.set(name, { id: "f" + n++, name, modifiedTime: mt, size: "4" });
  }
  map.set("library", { id: "lib", name: "library", modifiedTime: JAN, size: "9" });
  const deleted = [], renamed = [];
  let libBody = lib;
  const idOf = (url) => url.match(/files\/([^?]+)/)?.[1];
  const fetch = async (url, opts = {}) => {
    url = String(url);
    if (url.startsWith("https://oauth2.googleapis.com/tokeninfo")) {
      return jsonRes({ sub: "a1", email: "e@x" });
    }
    if (url.startsWith(FILES + "?spaces=appDataFolder")) return jsonRes({ files: [...map.values()] });
    if (url.includes("alt=media")) {
      if (idOf(url) === "lib") return bytesRes(new TextEncoder().encode(JSON.stringify(libBody)));
      return bytesRes(u8(9, 9, 9, 9));
    }
    if (url.startsWith(UPLOAD)) {
      const text = opts.body?.text ? await opts.body.text() : String(opts.body || "");
      if (idOf(url) === "lib") { try { libBody = JSON.parse(text); } catch {} }
      return jsonRes({ id: idOf(url) || "up" });
    }
    if (opts.method === "DELETE") {
      const hit = [...map.entries()].find(([, f]) => f.id === idOf(url));
      if (hit) { deleted.push(hit[0]); map.delete(hit[0]); }
      return jsonRes({});
    }
    if (opts.method === "PATCH") {
      let body = {}; try { body = JSON.parse(opts.body); } catch {}
      const hit = [...map.entries()].find(([, f]) => f.id === idOf(url));
      if (hit && body.name) {
        renamed.push(hit[0] + " -> " + body.name);
        map.delete(hit[0]); hit[1].name = body.name; map.set(body.name, hit[1]);
      }
      return jsonRes({ modifiedTime: JAN });
    }
    return jsonRes({ id: "up" });
  };
  return {
    map, deleted, renamed, fetch,
    get lib() { return libBody; },
    names: () => [...map.keys()].filter((k) => k !== "library").sort(),
  };
};

const sync = (over = {}) => ({
  queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
  sigs: {}, rmt: {}, delTs: {}, acct: "a1", parked: {}, connected: true, ...over });

const signedIn = (app) => {
  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
};
const libNames = (d) => d.lib.recents.map((r) => r.name).sort();
const localNames = (app) => (app.idb.get("recent") || []).map((r) => r.name).sort();

// ── Delete ─────────────────────────────────────────────────────────────────

test("a delete made away, then a play elsewhere: the game survives whole", async () => {
  const app = await loadApp();
  app.idb.set("recent", []);            // deleted here on Tuesday
  signedIn(app);
  const drive = makeDrive({
    files: { "rom:A.gba": JAN, "save:A.gba": new Date(WED).toISOString() },
    lib: { recents: [{ name: "A.gba", ts: WED }], tomb: [], ren: [] }, // played there
  });
  app.setFetch(drive.fetch);
  app.api.syncState = sync({
    queueDel: ["rom:A.gba", "save:A.gba"],
    delTs: { "rom:A.gba": TUE, "save:A.gba": TUE },
    tomb: [{ name: "A.gba", ts: TUE }],
  });

  await app.api.flushSync();
  await settle();

  eq(drive.deleted, [], "nothing is taken from Drive");
  eq(drive.names(), ["rom:A.gba", "save:A.gba"], "the ROM survives, not just the save");
  eq(libNames(drive), ["A.gba"], "and the game is still in the library");
  eq(drive.lib.tomb, [], "the tombstone is gone, not merely outvoted");
  eq(app.api.syncState.queueDel, [], "the queued deletes are cancelled, not retried");
  eq(Object.keys(app.api.syncState.delTs), []);
  eq(localNames(app), ["A.gba"], "and this device gets its tile back");
});

test("a delete made away that nobody contests still happens", async () => {
  const app = await loadApp();
  app.idb.set("recent", []);
  signedIn(app);
  const drive = makeDrive({
    files: { "rom:A.gba": JAN, "save:A.gba": JAN },
    lib: { recents: [{ name: "A.gba", ts: MON }], tomb: [], ren: [] }, // last played Monday
  });
  app.setFetch(drive.fetch);
  app.api.syncState = sync({
    queueDel: ["rom:A.gba", "save:A.gba"],
    delTs: { "rom:A.gba": TUE, "save:A.gba": TUE },
    tomb: [{ name: "A.gba", ts: TUE }],
  });

  await app.api.flushSync();
  await settle();

  eq(drive.deleted.sort(), ["rom:A.gba", "save:A.gba"]);
  eq(libNames(drive), [], "and the game leaves the library");
  eq(drive.lib.tomb.map((t) => t.name), ["A.gba"], "with a tombstone for the other devices");
  eq(localNames(app), []);
});

// ── Reset ──────────────────────────────────────────────────────────────────

test("a reset made away, then a play elsewhere: the newer save survives", async () => {
  const app = await loadApp();
  app.idb.set("recent", [{ name: "A.gba", ts: TUE }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1, 2, 3, 4) }); // reset keeps the ROM
  signedIn(app);
  const drive = makeDrive({
    files: { "rom:A.gba": JAN, "save:A.gba": new Date(WED).toISOString() },
    lib: { recents: [{ name: "A.gba", ts: WED }], tomb: [], ren: [] },
  });
  app.setFetch(drive.fetch);
  app.api.syncState = sync({ queueDel: ["save:A.gba"], delTs: { "save:A.gba": TUE } });

  await app.api.flushSync();
  await settle();

  eq(drive.deleted, [], "the later play outranks the older reset");
  assert.ok(drive.map.has("save:A.gba"));
});

test("a reset made away is still carried out on a save nobody has touched since", async () => {
  const app = await loadApp();
  app.idb.set("recent", [{ name: "A.gba", ts: TUE }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1, 2, 3, 4) });
  signedIn(app);
  const drive = makeDrive({
    files: { "rom:A.gba": JAN, "save:A.gba": JAN },
    lib: { recents: [{ name: "A.gba", ts: WED }], tomb: [], ren: [] }, // played, but no save written
  });
  app.setFetch(drive.fetch);
  app.api.syncState = sync({ queueDel: ["save:A.gba"], delTs: { "save:A.gba": TUE } });

  await app.api.flushSync();
  await settle();

  eq(drive.deleted, ["save:A.gba"],
    "a play does not shelter a save: only a later write to that save does");
  eq(libNames(drive), ["A.gba"], "and the game itself is untouched");
});

// ── Rename ─────────────────────────────────────────────────────────────────

test("a rename made away, then a play under the old name: the rename still lands", async () => {
  const app = await loadApp();
  app.idb.set("recent", [{ name: "B.gba", ts: TUE }]); // renamed here
  signedIn(app);
  const drive = makeDrive({
    files: { "rom:A.gba": JAN, "save:A.gba": JAN },
    lib: { recents: [{ name: "A.gba", ts: WED }], tomb: [], ren: [] }, // played there, old name
  });
  app.setFetch(drive.fetch);
  app.api.syncState = sync({
    queueRen: [{ from: "rom:A.gba", to: "rom:B.gba" }, { from: "save:A.gba", to: "save:B.gba" }],
    ren: [{ from: "A.gba", to: "B.gba", ts: TUE }],
  });

  await app.api.flushSync();
  await settle();

  eq(drive.names(), ["rom:B.gba", "save:B.gba"], "the files carry the new name");
  eq(libNames(drive), ["B.gba"], "and so does the library");
  eq(drive.lib.ren.map((r) => r.from + "->" + r.to), ["A.gba->B.gba"],
    "the marker stays, so the other device is migrated when it pulls");
});

test("a rename made away, then a fresh import of the old name: the import is left alone", async () => {
  const app = await loadApp();
  app.idb.set("recent", [{ name: "B.gba", ts: TUE }]);
  signedIn(app);
  const drive = makeDrive({
    files: { "rom:A.gba": JAN, "save:A.gba": JAN },
    // `imp` marks a real import, not a play: a different game holds the name.
    lib: { recents: [{ name: "A.gba", ts: WED, imp: WED }], tomb: [], ren: [] },
  });
  app.setFetch(drive.fetch);
  app.api.syncState = sync({
    queueRen: [{ from: "rom:A.gba", to: "rom:B.gba" }, { from: "save:A.gba", to: "save:B.gba" }],
    ren: [{ from: "A.gba", to: "B.gba", ts: TUE }],
  });

  await app.api.flushSync();
  await settle();

  eq(drive.renamed, [], "the new game's files are not carried off");
  eq(drive.names(), ["rom:A.gba", "save:A.gba"]);
  eq(libNames(drive), ["A.gba", "B.gba"], "both games exist");
  eq(drive.lib.ren, [], "and the marker is spent");
});

// ── The mark that tells them apart ─────────────────────────────────────────

test("importing a game marks it; playing it does not", async () => {
  const app = await loadApp();
  app.idb.set("recent", []);
  await app.api.bumpRecentIndex("A.gba", { fresh: true });
  const imported = app.idb.get("recent")[0];
  assert.ok(imported.imp > 0, "an import is stamped");
  assert.equal(imported.imp, imported.ts);

  await app.api.bumpRecentIndex("A.gba"); // played again
  const played = app.idb.get("recent")[0];
  assert.equal(played.imp, imported.imp, "a play keeps the original import mark");
  assert.ok(played.ts >= imported.ts);
});

test("the merge keeps the newest import mark from either device", async () => {
  const app = await loadApp();
  const merged = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: WED }], tomb: [], ren: [] },
    { recents: [{ name: "A.gba", ts: MON, imp: MON }], tomb: [], ren: [] });
  eq(merged.recents, [{ name: "A.gba", ts: WED, imp: MON }]);
});

test("a play under the old name does not spend a rename marker, an import does", async () => {
  const app = await loadApp();
  const marker = { from: "A.gba", to: "B.gba", ts: TUE };

  const played = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: WED }], tomb: [], ren: [marker] },
    { recents: [], tomb: [], ren: [] });
  eq(played.recents.map((r) => r.name), ["B.gba"], "renamed");
  eq(played.ren, [marker], "marker kept for devices that have not pulled yet");

  const reimported = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: WED, imp: WED }], tomb: [], ren: [marker] },
    { recents: [], tomb: [], ren: [] });
  eq(reimported.recents.map((r) => r.name), ["A.gba"], "left as its own game");
  eq(reimported.ren, [], "marker spent");
});

test("an import mark older than the rename does not save the old name", async () => {
  const app = await loadApp();
  // Imported Monday, renamed Tuesday: the rename is the later word.
  const merged = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: WED, imp: MON }], tomb: [], ren: [{ from: "A.gba", to: "B.gba", ts: TUE }] },
    { recents: [], tomb: [], ren: [] });
  eq(merged.recents.map((r) => r.name), ["B.gba"]);
});
