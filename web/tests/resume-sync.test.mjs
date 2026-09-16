// The resume snapshot travels between devices through Drive, and the one
// thing it must never do is cost a save. Restoring a snapshot puts its cart
// RAM back and the next flush writes that over the battery save, so a
// snapshot is only ever taken, kept, sent or offered on top of the very save
// it was made against - and a newer one, on either side, is never displaced
// by an older one. When in doubt, nothing is offered.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, eq, settle } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";
const UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files";

// The appDataFolder fake from drive-frames.test.mjs. Payloads stay ASCII so
// the multipart body survives its text round-trip byte-for-byte. It ignores
// Range, as a server may: the header parse must work on a whole file too.
const makeDrive = (seed = {}) => {
  const byName = new Map();
  let idc = 0, mtc = 0;
  const nextMt = () => "2026-01-01T00:" + String(10 + mtc++).padStart(2, "0") + ":00Z";
  const put = (name, bytes) => {
    const prev = byName.get(name);
    byName.set(name, { id: prev ? prev.id : "f" + idc++, name, bytes, modifiedTime: nextMt() });
  };
  for (const [n, b] of Object.entries(seed)) put(n, b);
  const uploads = [];
  const fetch = async (url, opts = {}) => {
    url = String(url);
    const method = opts.method || "GET";
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [...byName.values()].map((f) => ({
        id: f.id, name: f.name, size: String(f.bytes.length), modifiedTime: f.modifiedTime,
      })) });
    }
    const dm = url.match(/\/drive\/v3\/files\/([^/?]+)\?alt=media/);
    if (dm && method === "GET") {
      const f = [...byName.values()].find((x) => x.id === dm[1]);
      return bytesRes(f ? f.bytes : u8());
    }
    const del = url.match(/\/drive\/v3\/files\/([^/?]+)$/);
    if (del && method === "DELETE") {
      const ent = [...byName.entries()].find(([, x]) => x.id === del[1]);
      if (ent) byName.delete(ent[0]);
      return jsonRes({}, 204);
    }
    if (url.startsWith(UPLOAD_URL + "?uploadType=multipart") && method === "POST") {
      const text = await opts.body.text();
      const name = text.match(/"name":"((?:[^"\\]|\\.)*)"/)[1];
      const marker = "application/octet-stream\r\n\r\n";
      const start = text.indexOf(marker) + marker.length;
      put(name, new TextEncoder().encode(text.slice(start, text.lastIndexOf("\r\n--"))));
      uploads.push(name);
      return jsonRes({ id: byName.get(name).id });
    }
    const media = url.match(/\/upload\/drive\/v3\/files\/([^/?]+)\?uploadType=media/);
    if (media && method === "PATCH") {
      const ent = [...byName.values()].find((x) => x.id === media[1]);
      if (ent) put(ent.name, new Uint8Array(await opts.body.arrayBuffer()));
      uploads.push(ent ? ent.name : "?");
      return jsonRes({ id: media[1] });
    }
    throw new Error("unexpected " + method + " " + url);
  };
  return { byName, uploads, fetch, put };
};

const signIn = (app, extra = {}) => {
  app.api.gdriveToken = "test-token";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true, ...extra };
};

const ascii = (s) => new TextEncoder().encode(s);
const sigOf = (app, bytes) =>
  app.runIn(`saveSignature(new Uint8Array(${JSON.stringify([...bytes])}))`);
// A snapshot file as another device would have written it.
const sessionFile = (app, { ts, save, state = "STATE" }) =>
  app.runIn(`encodeSession({ bytes: new TextEncoder().encode(${JSON.stringify(state)}),
                             ts: ${ts}, saveSig: ${JSON.stringify(save ? sigOf(app, save) : null)} })`);
const stateText = (rec) => new TextDecoder().decode(rec.bytes);

const OLD_SAVE = ascii("SAVE-1");
const NEW_SAVE = ascii("SAVE-2");

// A game held on this device, in the library.
const holdGame = (app, name) => {
  const recent = app.idb.get("recent") || [];
  app.idb.set("recent", [...recent, { name, ts: 1 }]);
  app.idb.set("rom:" + name, { name, data: ascii("ROM") });
};

const libraryFile = (names) =>
  ascii(JSON.stringify({ recents: names.map((name) => ({ name, ts: 1 })), tomb: [], ren: [] }));

const resumeOffers = (app) =>
  [...app.runIn("toastItems.filter((t) => t.label === 'Resume' && !t.gone).map((t) => t.msg)")];

const stubModule = (app, stateText = "HERE") => app.runIn(`
  globalThis.__loads = 0;
  globalThis.Module = {
    ccall: () => {},
    _wasm_state_size: () => ${stateText.length},
    _wasm_state_data: () => 8,
    _wasm_load_state: () => { __loads++; return 1; },
    _malloc: () => 40, _free: () => {}, // clear of the state the capture reads
    memory: { buffer: (() => { const b = new ArrayBuffer(64);
      new Uint8Array(b, 8).set(new TextEncoder().encode(${JSON.stringify(stateText)})); return b; })() },
  };
`);

// ── The file ────────────────────────────────────────────────────────────────

test("the snapshot is a Drive kind whose header says when and against which save", async () => {
  const app = await loadApp();
  eq(app.api.parseDriveFileName("stateauto:A.gba"), { game: "A.gba", kind: "session" });

  const file = sessionFile(app, { ts: 1234, save: OLD_SAVE });
  const back = app.runIn("decodeSession")(file);
  assert.equal(back.ts, 1234);
  assert.equal(back.saveSig, sigOf(app, OLD_SAVE));
  assert.equal(stateText(back), "STATE");
  // A header read alone (the ranged request) needs no body.
  const head = app.runIn("decodeSession")(file.slice(0, 60), { body: false });
  assert.equal(head.ts, 1234);

  // A record from before saveSig existed proves nothing, so it is never sent.
  app.idb.set("stateauto:A.gba", { bytes: ascii("S"), ts: 5 });
  assert.equal(await app.runIn("readSyncBytes('stateauto:A.gba')"), null);
  assert.equal(app.runIn("decodeSession")(ascii("not a snapshot")), null);
});

// ── Down ────────────────────────────────────────────────────────────────────

test("a new device takes the snapshot that goes with the save it pulls, and offers it as another device's", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  // Listed BEFORE the save: the snapshot is still judged against the save
  // that came down in the same pull.
  drive.put("stateauto:A.gba", sessionFile(app, { ts: 5000, save: OLD_SAVE }));
  drive.put("save:A.gba", OLD_SAVE);
  drive.put("library", libraryFile(["A.gba"]));
  app.setFetch(drive.fetch);
  signIn(app);
  holdGame(app, "A.gba");

  await app.api.pullSync({ silent: true });
  const rec = app.idb.get("stateauto:A.gba");
  assert.ok(rec, "the snapshot came down");
  assert.equal(stateText(rec), "STATE");
  assert.equal(rec.elsewhere, true);

  stubModule(app);
  app.api.currentOriginalName = "A.gba";
  app.api.currentRomName = "rom.gba";
  await app.runIn("offerAutoResume()");
  eq(resumeOffers(app).length, 1);
  assert.match(resumeOffers(app)[0], /another device/);
});

test("a snapshot made against a different save is never taken — this device's newer save wins", async () => {
  const app = await loadApp();
  const drive = makeDrive({ library: libraryFile(["A.gba"]) });
  drive.put("stateauto:A.gba", sessionFile(app, { ts: 9e12, save: OLD_SAVE }));
  app.setFetch(drive.fetch);
  signIn(app);
  holdGame(app, "A.gba");
  // This device saved in game since; its own snapshot goes with that save.
  app.idb.set("save:A.gba", NEW_SAVE);
  const mine = { bytes: ascii("MINE"), ts: 10, saveSig: sigOf(app, NEW_SAVE) };
  app.idb.set("stateauto:A.gba", mine);

  await app.api.pullSync({ silent: true });
  assert.equal(stateText(app.idb.get("stateauto:A.gba")), "MINE",
               "however new the other one is, it belongs to another save");

  // And with no snapshot of its own, still nothing: a snapshot over the
  // wrong save is exactly how a save is lost.
  app.idb.delete("stateauto:A.gba");
  drive.put("stateauto:A.gba", sessionFile(app, { ts: 9e12 + 1, save: OLD_SAVE }));
  await app.api.pullSync({ silent: true });
  assert.equal(app.idb.get("stateauto:A.gba"), undefined);
});

test("between two snapshots of the same save, the later play wins either way round", async () => {
  const app = await loadApp();
  const drive = makeDrive({ library: libraryFile(["A.gba", "B.gba"]) });
  drive.put("stateauto:A.gba", sessionFile(app, { ts: 100, save: OLD_SAVE, state: "OLDER" }));
  drive.put("stateauto:B.gba", sessionFile(app, { ts: 300, save: OLD_SAVE, state: "NEWER" }));
  app.setFetch(drive.fetch);
  signIn(app);
  for (const g of ["A.gba", "B.gba"]) {
    holdGame(app, g);
    app.idb.set("save:" + g, OLD_SAVE);
    app.idb.set("stateauto:" + g, { bytes: ascii("MINE"), ts: 200, saveSig: sigOf(app, OLD_SAVE) });
  }

  await app.api.pullSync({ silent: true });
  assert.equal(stateText(app.idb.get("stateauto:A.gba")), "MINE", "an older one never displaces this one");
  assert.equal(stateText(app.idb.get("stateauto:B.gba")), "NEWER", "a later one does");
});

test("a snapshot this device can no longer restore gives way to one it can", async () => {
  const app = await loadApp();
  const drive = makeDrive({ library: libraryFile(["A.gba"]), "save:A.gba": NEW_SAVE });
  drive.put("stateauto:A.gba", sessionFile(app, { ts: 50, save: NEW_SAVE, state: "THEIRS" }));
  app.setFetch(drive.fetch);
  signIn(app);
  holdGame(app, "A.gba");
  app.idb.set("save:A.gba", OLD_SAVE);
  // Newer by the clock, but made against the save the pull is replacing.
  app.idb.set("stateauto:A.gba", { bytes: ascii("MINE"), ts: 999, saveSig: sigOf(app, OLD_SAVE) });

  await app.api.pullSync({ silent: true });
  eq(app.idb.get("save:A.gba"), NEW_SAVE);
  assert.equal(stateText(app.idb.get("stateauto:A.gba")), "THEIRS");
});

test("the game being played keeps its own snapshot", async () => {
  const app = await loadApp();
  const drive = makeDrive({ library: libraryFile(["A.gba"]) });
  drive.put("stateauto:A.gba", sessionFile(app, { ts: 9e12, save: OLD_SAVE }));
  app.setFetch(drive.fetch);
  signIn(app);
  holdGame(app, "A.gba");
  app.idb.set("save:A.gba", OLD_SAVE);
  app.api.currentOriginalName = "A.gba";
  app.api.currentRomName = "rom.gba";

  await app.api.pullSync({ silent: true });
  assert.equal(app.idb.get("stateauto:A.gba"), undefined);
});

test("a refused snapshot is not fetched again until the file or this device's save changes", async () => {
  const app = await loadApp();
  const drive = makeDrive({ library: libraryFile(["A.gba"]) });
  drive.put("stateauto:A.gba", sessionFile(app, { ts: 70, save: NEW_SAVE }));
  app.setFetch(drive.fetch);
  signIn(app);
  holdGame(app, "A.gba");
  app.idb.set("save:A.gba", OLD_SAVE);
  const id = drive.byName.get("stateauto:A.gba").id;
  const reads = () => app.fetchCalls.filter((c) => c.url.includes("/files/" + id + "?alt=media")).length;

  await app.api.pullSync({ silent: true });
  assert.equal(app.idb.get("stateauto:A.gba"), undefined);
  const first = reads();
  assert.equal(first, 1, "judged from the header alone; the state itself never came");
  const ranged = app.fetchCalls.find((c) => c.url.includes("/files/" + id + "?alt=media"));
  assert.match(ranged.opts.headers.Range, /^bytes=0-\d+$/);

  await app.api.pullSync({ silent: true });
  assert.equal(reads(), first, "nothing changed on either side: not asked again");

  // The save this snapshot belongs to arrives here by other means.
  app.idb.set("save:A.gba", NEW_SAVE);
  await app.api.pullSync({ silent: true });
  assert.ok(app.idb.get("stateauto:A.gba"), "re-judged, and now it belongs");
});

test("downloading a Drive-only game brings its snapshot, judged against the save that came with it", async () => {
  const app = await loadApp();
  const drive = makeDrive({ library: libraryFile(["D.gba"]) });
  drive.put("stateauto:D.gba", sessionFile(app, { ts: 40, save: OLD_SAVE }));
  drive.put("rom:D.gba", ascii("ROM"));
  drive.put("save:D.gba", OLD_SAVE);
  app.setFetch(drive.fetch);
  signIn(app, { connected: true });
  app.idb.set("recent", [{ name: "D.gba", ts: 1 }]);

  assert.equal(await app.runIn("downloadGame('D.gba')"), true);
  eq(app.idb.get("save:D.gba"), OLD_SAVE);
  assert.equal(stateText(app.idb.get("stateauto:D.gba")), "STATE");
});

// ── Up ──────────────────────────────────────────────────────────────────────

test("a snapshot goes up after the save it belongs to, and not once the game has saved past it", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  app.setFetch(drive.fetch);
  signIn(app);
  holdGame(app, "A.gba");
  app.idb.set("save:A.gba", OLD_SAVE);
  app.idb.set("stateauto:A.gba", { bytes: ascii("MINE"), ts: 10, saveSig: sigOf(app, OLD_SAVE) });
  app.api.syncState.queueUp = ["stateauto:A.gba", "save:A.gba"];

  await app.api.flushSync();
  eq(drive.uploads.filter((n) => n !== "library"), ["save:A.gba", "stateauto:A.gba"]);
  assert.equal(stateText(app.runIn("decodeSession")(drive.byName.get("stateauto:A.gba").bytes)), "MINE");

  // The game saves in game; the snapshot left from before is dead.
  app.idb.set("save:A.gba", NEW_SAVE);
  app.idb.set("stateauto:A.gba", { bytes: ascii("STALE"), ts: 20, saveSig: sigOf(app, OLD_SAVE) });
  app.api.syncState.queueUp = ["stateauto:A.gba"];
  await app.api.flushSync();
  assert.equal(stateText(app.runIn("decodeSession")(drive.byName.get("stateauto:A.gba").bytes)), "MINE",
               "a snapshot the save has moved past is not sent");
  eq(app.api.syncState.queueUp, []);
});

test("a snapshot is not sent over a later one on Drive, and one taken from Drive is never sent back", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  drive.put("stateauto:A.gba", sessionFile(app, { ts: 500, save: OLD_SAVE, state: "LATER" }));
  drive.put("stateauto:B.gba", sessionFile(app, { ts: 100, save: OLD_SAVE, state: "EARLIER" }));
  app.setFetch(drive.fetch);
  signIn(app);
  for (const g of ["A.gba", "B.gba", "C.gba"]) {
    holdGame(app, g);
    app.idb.set("save:" + g, OLD_SAVE);
  }
  // An offline device's session from earlier than Drive's: uploaded late, played early.
  app.idb.set("stateauto:A.gba", { bytes: ascii("MINE"), ts: 300, saveSig: sigOf(app, OLD_SAVE) });
  app.idb.set("stateauto:B.gba", { bytes: ascii("MINE"), ts: 300, saveSig: sigOf(app, OLD_SAVE) });
  app.idb.set("stateauto:C.gba",
              { bytes: ascii("FROM-DRIVE"), ts: 300, saveSig: sigOf(app, OLD_SAVE), elsewhere: true });
  app.api.syncState.queueUp = ["stateauto:A.gba", "stateauto:B.gba", "stateauto:C.gba"];

  await app.api.flushSync();
  const onDrive = (g) => stateText(app.runIn("decodeSession")(drive.byName.get("stateauto:" + g).bytes));
  assert.equal(onDrive("A.gba"), "LATER");
  assert.equal(onDrive("B.gba"), "MINE");
  assert.equal(drive.byName.has("stateauto:C.gba"), false);
});

// ── Taking the snapshot ─────────────────────────────────────────────────────

test("a paused game hidden again and again does not re-stamp its snapshot as new", async () => {
  const app = await loadApp();
  stubModule(app);
  app.api.currentOriginalName = "A.gba";
  app.api.currentRomName = "rom.gba";
  app.runIn("beginSession(); sessionPlayMs = 5 * 60 * 1000; sessionUnsavedMs = sessionPlayMs;");

  await app.runIn("persistAutoState()");
  const first = app.idb.get("stateauto:A.gba");
  assert.ok(first);
  await new Promise((r) => setTimeout(r, 5));
  await app.runIn("persistAutoState()");
  assert.equal(app.idb.get("stateauto:A.gba").ts, first.ts, "nothing was played in between");

  app.runIn("sessionUnsavedMs += 1000");
  await new Promise((r) => setTimeout(r, 5));
  await app.runIn("persistAutoState()");
  assert.ok(app.idb.get("stateauto:A.gba").ts > first.ts, "play since does");
});

test("opening a game for a look does not replace the snapshot it could have resumed", async () => {
  const app = await loadApp();
  stubModule(app, "TITLE");
  app.api.currentOriginalName = "A.gba";
  app.api.currentRomName = "rom.gba";
  const theirs = { bytes: ascii("THEIRS"), ts: 10, saveSig: null, elsewhere: true };
  app.idb.set("stateauto:A.gba", theirs);

  app.runIn("beginSession(); sessionPlayMs = sessionUnsavedMs = 20 * 1000;");
  await app.runIn("persistAutoState()");
  assert.equal(stateText(app.idb.get("stateauto:A.gba")), "THEIRS", "twenty seconds at the title");

  app.runIn("sessionPlayMs = sessionUnsavedMs = 2 * 60 * 1000;");
  await app.runIn("persistAutoState()");
  assert.equal(stateText(app.idb.get("stateauto:A.gba")), "TITLE", "two minutes is a session");
});

test("a short session still replaces the snapshot when it was resumed from it, or saved past it", async () => {
  const app = await loadApp();
  stubModule(app, "NOW");
  app.api.currentOriginalName = "A.gba";
  app.api.currentRomName = "rom.gba";
  app.idb.set("stateauto:A.gba", { bytes: ascii("THEN"), ts: 10, saveSig: null });

  // Resumed: the short session carries that one on.
  app.runIn("beginSession()");
  assert.equal(app.runIn("applyStateBytes(new Uint8Array([1]))"), true);
  await app.runIn("persistAutoState()");
  assert.equal(stateText(app.idb.get("stateauto:A.gba")), "NOW");

  // Saved in game within seconds of a fresh boot: the old snapshot is dead
  // anyway, so the new one takes its place.
  app.idb.set("stateauto:A.gba", { bytes: ascii("THEN"), ts: 10, saveSig: null });
  app.runIn("beginSession(); sessionPlayMs = sessionUnsavedMs = 3000;");
  app.sandbox.FS.files.set("rom.sav", NEW_SAVE);
  await app.runIn("persistAutoState()");
  const rec = app.idb.get("stateauto:A.gba");
  assert.equal(stateText(rec), "NOW");
  assert.equal(rec.saveSig, sigOf(app, NEW_SAVE));
  eq(app.idb.get("save:A.gba"), NEW_SAVE, "and the save it names is stored with it");
});

test("taking a snapshot queues it for Drive when signed in", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive().fetch);
  signIn(app);
  stubModule(app);
  app.api.currentOriginalName = "A.gba";
  app.api.currentRomName = "rom.gba";
  app.runIn("beginSession(); sessionPlayMs = sessionUnsavedMs = 90 * 1000;");
  await app.runIn("persistAutoState()");
  assert.ok(app.api.syncState.queueUp.includes("stateauto:A.gba"));
});

// ── Removing ────────────────────────────────────────────────────────────────

test("resetting a save deletes the snapshot on Drive too", async () => {
  const app = await loadApp();
  signIn(app);
  holdGame(app, "A.gba");
  app.idb.set("save:A.gba", OLD_SAVE);
  app.idb.set("stateauto:A.gba", { bytes: ascii("S"), ts: 1, saveSig: sigOf(app, OLD_SAVE) });
  await app.runIn("resetGameSaves('A.gba')");
  assert.ok(app.api.syncState.queueDel.includes("stateauto:A.gba"));
  assert.equal(app.idb.get("stateauto:A.gba"), undefined);
});

test("Remove from device keeps a snapshot Drive does not have yet", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "rom:A.gba": ascii("ROM"), "rom:B.gba": ascii("ROM") });
  app.setFetch(drive.fetch);
  signIn(app, { sigs: { "rom:A.gba": "s", "rom:B.gba": "s" } });
  for (const g of ["A.gba", "B.gba"]) {
    holdGame(app, g);
    app.idb.set("save:" + g, OLD_SAVE);
    app.idb.set("stateauto:" + g, { bytes: ascii("S"), ts: 1, saveSig: sigOf(app, OLD_SAVE) });
  }
  // B's is already on Drive, byte for byte.
  const bFile = await app.runIn("readSyncBytes('stateauto:B.gba')");
  drive.put("stateauto:B.gba", bFile);
  app.api.syncState.sigs["stateauto:B.gba"] = sigOf(app, bFile);

  assert.equal(await app.runIn("removeGameFromDevice('A.gba')"), true);
  assert.equal(await app.runIn("removeGameFromDevice('B.gba')"), true);
  await settle();
  assert.ok(app.idb.get("stateauto:A.gba"), "the only copy stays");
  assert.equal(app.idb.get("stateauto:B.gba"), undefined, "a copy Drive holds goes");
});
