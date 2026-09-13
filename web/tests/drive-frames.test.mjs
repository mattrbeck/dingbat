// Library pictures on Drive: "frame:<name>" is a Drive kind. A capture
// queues an upload; the pull brings pictures down for every library game,
// held on this device or not, so a Drive-only tile shows the screen another
// device last saw. Remove from device keeps the picture; Delete removes it
// everywhere; a rename carries it.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, eq, settle, gameTiles } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";
const UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files";

// The stateful appDataFolder fake from sync.test.mjs, trimmed. Payloads stay
// ASCII so the multipart body survives the text round-trip byte-for-byte.
const makeDrive = (seed = {}) => {
  const byName = new Map();
  let idc = 0, mtc = 0;
  const nextMt = () => "2026-01-01T00:00:" + String(10 + mtc++).padStart(2, "0") + "Z";
  const put = (name, bytes) =>
    byName.set(name, { id: "f" + idc++, name, bytes, modifiedTime: nextMt() });
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
    const meta = url.match(/\/drive\/v3\/files\/([^/?]+)\?fields=/);
    if (meta && method === "PATCH") {
      const ent = [...byName.values()].find((x) => x.id === meta[1]);
      const { name } = JSON.parse(opts.body);
      if (ent) { byName.delete(ent.name); ent.name = name; ent.modifiedTime = nextMt(); byName.set(name, ent); }
      return jsonRes(ent ? { id: ent.id, name: ent.name, modifiedTime: ent.modifiedTime } : {});
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
      const payload = text.slice(start, text.lastIndexOf("\r\n--"));
      const prev = byName.get(name);
      const id = prev ? prev.id : "f" + idc++;
      byName.set(name, { id, name, bytes: new TextEncoder().encode(payload), modifiedTime: nextMt() });
      uploads.push(name);
      return jsonRes({ id });
    }
    const media = url.match(/\/upload\/drive\/v3\/files\/([^/?]+)\?uploadType=media/);
    if (media && method === "PATCH") {
      const ent = [...byName.values()].find((x) => x.id === media[1]);
      if (ent) { ent.bytes = new Uint8Array(await opts.body.arrayBuffer()); ent.modifiedTime = nextMt(); }
      uploads.push(ent ? ent.name : "?");
      return jsonRes({ id: media[1] });
    }
    throw new Error("unexpected " + method + " " + url);
  };
  return { byName, uploads, fetch };
};

const signIn = (app, extra = {}) => {
  app.api.gdriveToken = "test-token";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true, ...extra };
};

const ascii = (s) => new TextEncoder().encode(s);
const blobText = async (b) => new TextDecoder().decode(new Uint8Array(await b.arrayBuffer()));

test("frame:<name> is a Drive kind, and Blob <-> bytes round-trips", async () => {
  const app = await loadApp();
  eq(app.api.parseDriveFileName("frame:A.gba"), { game: "A.gba", kind: "frame" });

  app.idb.set("frame:A.gba", new Blob([ascii("JPEGBYTES")], { type: "image/jpeg" }));
  eq(await app.runIn("readSyncBytes('frame:A.gba')"), ascii("JPEGBYTES"));
  await app.runIn("writeSyncBytes('frame:B.gb', new TextEncoder().encode('PIC'))");
  const stored = app.idb.get("frame:B.gb");
  assert.ok(stored instanceof Blob);
  assert.equal(stored.type, "image/jpeg");
  assert.equal(await blobText(stored), "PIC");
  assert.equal(await app.runIn("readSyncBytes('frame:none.gba')"), null);
});

test("a capture queues its upload when signed in, and flush sends it", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  app.setFetch(drive.fetch);
  signIn(app);
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "A.gba";
  app.runIn(`
    globalThis.Module = { _wasm_fb_ptr: () => 16, memory: { buffer: new ArrayBuffer(16 + 240 * 160 * 4) } };
    const realCreate = document.createElement.bind(document);
    document.createElement = (tag) => {
      const el = realCreate(tag);
      if (tag === "canvas") el.toBlob = (cb, type) => cb(new Blob([new TextEncoder().encode("SHOT")], { type }));
      return el;
    };
  `);
  await app.runIn("storeLastFrame({ force: true })");
  eq(app.api.syncState.queueUp, ["frame:A.gba"]);

  await app.api.flushSync();
  eq(drive.uploads.filter((n) => n !== "library"), ["frame:A.gba"]);
  assert.equal(new TextDecoder().decode(drive.byName.get("frame:A.gba").bytes), "SHOT");
  eq(app.api.syncState.queueUp, []);
});

test("signed out, a capture queues nothing", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "A.gba";
  app.runIn(`
    globalThis.Module = { _wasm_fb_ptr: () => 16, memory: { buffer: new ArrayBuffer(16 + 240 * 160 * 4) } };
    const realCreate = document.createElement.bind(document);
    document.createElement = (tag) => {
      const el = realCreate(tag);
      if (tag === "canvas") el.toBlob = (cb, type) => cb(new Blob([new Uint8Array([1])], { type }));
      return el;
    };
  `);
  await app.runIn("storeLastFrame({ force: true })");
  assert.ok(app.idb.get("frame:A.gba") instanceof Blob, "stored locally all the same");
  eq(app.api.syncState.queueUp, []);
});

test("the pull brings a picture down for a Drive-only game, and only the picture", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    "rom:D.gba": ascii("ROMBYTES"), "save:D.gba": ascii("SAVE"), "frame:D.gba": ascii("FACE"),
    "library": ascii(JSON.stringify({ recents: [{ name: "D.gba", ts: 5 }], tomb: [], ren: [] })),
  });
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", []);

  await app.api.pullSync({ silent: true });
  await settle();

  const pic = app.idb.get("frame:D.gba");
  assert.ok(pic instanceof Blob, "the picture came down");
  assert.equal(await blobText(pic), "FACE");
  assert.equal(app.idb.get("rom:D.gba"), undefined, "the ROM stays on Drive");
  assert.equal(app.idb.get("save:D.gba"), undefined, "so does the save (pulled with the ROM)");
  eq(app.idb.get("recent").map((r) => r.name), ["D.gba"], "the library entry arrived with it");

  // And the tile shows it.
  await app.api.refreshHomeRecent();
  await settle();
  const tile = gameTiles(app)[0];
  assert.ok(tile.className.includes("home-tile-cloud"));
  assert.ok(tile.children[0].children[0].children[0].className.includes("home-tile-frame"));
});

test("a picture for a game not in the library is left on Drive", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "frame:Stray.gba": ascii("FACE") });
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", []);
  await app.api.pullSync({ silent: true });
  await settle();
  assert.equal(app.idb.get("frame:Stray.gba"), undefined);
});

test("a newer picture from another device replaces this one's; the loaded game's is left alone", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    "rom:A.gba": ascii("ROM"), "frame:A.gba": ascii("THEIRS"),
    "rom:L.gba": ascii("ROM"), "frame:L.gba": ascii("THEIRS"),
  });
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "L.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: ascii("ROM") });
  app.idb.set("rom:L.gba", { name: "L.gba", data: ascii("ROM") });
  app.idb.set("frame:A.gba", new Blob([ascii("MINE")]));
  app.idb.set("frame:L.gba", new Blob([ascii("MINE")]));
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "L.gba"; // L is being played here

  await app.api.pullSync({ silent: true });
  await settle();
  assert.equal(await blobText(app.idb.get("frame:A.gba")), "THEIRS");
  assert.equal(await blobText(app.idb.get("frame:L.gba")), "MINE", "the running game paints its own");

  // Unchanged remotely: not fetched again (the library file is re-read each pull).
  const before = app.fetchCalls.length;
  const libId = drive.byName.get("library").id;
  await app.api.pullSync({ silent: true });
  const media = app.fetchCalls.slice(before)
    .map((c) => (c.url.match(/files\/([^/?]+)\?alt=media/) || [])[1])
    .filter((id) => id && id !== libId);
  eq(media, [], "no re-download");
});

test("Remove from device keeps the picture; Delete removes it everywhere", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "rom:A.gba": ascii("ROM"), "frame:A.gba": ascii("FACE") });
  app.setFetch(drive.fetch);
  signIn(app, { sigs: { "rom:A.gba": "sig" } });
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: ascii("ROM") });
  app.idb.set("frame:A.gba", new Blob([ascii("FACE")]));

  assert.equal(await app.api.removeGameFromDevice("A.gba"), true);
  await settle();
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  assert.ok(app.idb.get("frame:A.gba") instanceof Blob, "the tile keeps its face");

  await app.api.deleteGameEverywhere("A.gba");
  await settle();
  assert.equal(app.idb.get("frame:A.gba"), undefined);
  assert.ok(app.api.syncState.queueDel.includes("frame:A.gba"), "queued for Drive");
  await app.api.flushSync();
  assert.ok(!drive.byName.has("frame:A.gba"), "gone from Drive");
});

test("a rename carries the picture, here and on Drive", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "rom:Old.gba": ascii("ROM"), "frame:Old.gba": ascii("FACE") });
  app.setFetch(drive.fetch);
  signIn(app, { sigs: { "rom:Old.gba": "s", "frame:Old.gba": "s" } });
  app.idb.set("recent", [{ name: "Old.gba", ts: 1 }]);
  app.idb.set("rom:Old.gba", { name: "Old.gba", data: ascii("ROM") });
  app.idb.set("frame:Old.gba", new Blob([ascii("FACE")]));

  const res = await app.api.renameGame("Old.gba", "New.gba");
  assert.ok(res.ok, res.error);
  assert.equal(app.idb.get("frame:Old.gba"), undefined);
  assert.equal(await blobText(app.idb.get("frame:New.gba")), "FACE");
  assert.ok(app.api.syncState.queueRen.some((r) => r.from === "frame:Old.gba" && r.to === "frame:New.gba"));
  await app.api.flushSync();
  assert.ok(drive.byName.has("frame:New.gba") && !drive.byName.has("frame:Old.gba"));
});

test("downloading a Drive-only game brings its picture with the rest", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "rom:D.gba": ascii("ROMBYTES"), "frame:D.gba": ascii("FACE") });
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", [{ name: "D.gba", ts: 1 }]);
  assert.equal(await app.api.downloadGame("D.gba"), true);
  await settle();
  eq(app.idb.get("rom:D.gba").data, ascii("ROMBYTES"));
  assert.equal(await blobText(app.idb.get("frame:D.gba")), "FACE");
});
