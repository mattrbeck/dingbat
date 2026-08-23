// Google Drive sync engine (web/index.js), via the vm harness.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, eq, settle } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";
const UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files";

// Stateful appDataFolder fake. Payloads stay ASCII so the multipart body
// survives the text round-trip byte-for-byte.
const makeDrive = (seed = {}) => {
  const byName = new Map();
  let idc = 0, mtc = 0;
  const nextMt = () => "2026-01-01T00:00:" + String(10 + mtc++).padStart(2, "0") + "Z";
  const put = (name, bytes) =>
    byName.set(name, { id: "f" + idc++, name, bytes, modifiedTime: nextMt() });
  for (const [n, b] of Object.entries(seed)) put(n, b);

  const fetch = async (url, opts = {}) => {
    url = String(url);
    const method = opts.method || "GET";
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [...byName.values()].map((f) => ({
        id: f.id, name: f.name, size: String(f.bytes.length),
        modifiedTime: f.modifiedTime,
      })) });
    }
    const dm = url.match(/\/drive\/v3\/files\/([^/?]+)\?alt=media/);
    if (dm && method === "GET") {
      const f = [...byName.values()].find((x) => x.id === dm[1]);
      return bytesRes(f ? f.bytes : u8());
    }
    // Metadata-only PATCH (driveRenameFile).
    const meta = url.match(/\/drive\/v3\/files\/([^/?]+)\?fields=/);
    if (meta && method === "PATCH") {
      const ent = [...byName.values()].find((x) => x.id === meta[1]);
      const { name } = JSON.parse(opts.body);
      if (ent) {
        byName.delete(ent.name);
        ent.name = name;
        ent.modifiedTime = nextMt();
        byName.set(name, ent);
      }
      return jsonRes(ent
        ? { id: ent.id, name: ent.name, modifiedTime: ent.modifiedTime } : {});
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
      const endIdx = text.lastIndexOf("\r\n--");
      const payload = text.slice(start, endIdx);
      const prev = byName.get(name);
      const id = prev ? prev.id : "f" + idc++;
      byName.set(name, {
        id, name, bytes: new TextEncoder().encode(payload), modifiedTime: nextMt(),
      });
      return jsonRes({ id });
    }
    const media = url.match(/\/upload\/drive\/v3\/files\/([^/?]+)\?uploadType=media/);
    if (media && method === "PATCH") {
      const ent = [...byName.values()].find((x) => x.id === media[1]);
      if (ent) {
        ent.bytes = new Uint8Array(await opts.body.arrayBuffer());
        ent.modifiedTime = nextMt();
      }
      return jsonRes({ id: media[1] });
    }
    throw new Error("unexpected " + method + " " + url);
  };
  return { byName, fetch, libraryJSON: () => {
    const f = byName.get("library");
    return f ? JSON.parse(new TextDecoder().decode(f.bytes)) : null;
  } };
};

const signIn = (app, extra = {}) => {
  app.api.gdriveToken = "test-token";
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true, ...extra };
};

// ── Signed-out gating ───────────────────────────────────────────────────────

test("signed out: syncActive is false and nothing queues", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  assert.equal(app.api.syncActive(), false);
  app.api.markUpload("save:Zelda.gba");
  app.api.markDelete("state:Zelda.gba");
  eq(app.api.syncState.queueUp, []);
  eq(app.api.syncState.queueDel, []);
});

test("signed out: Delete is local-only and issues no Drive request", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1, 2) });
  app.idb.set("save:A.gba", u8(9));
  await app.api.deleteGameEverywhere("A.gba");
  await settle();
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  assert.equal(app.idb.get("save:A.gba"), undefined);
  eq(app.api.syncState.tomb, [], "no tombstone when signed out");
  const driveCalls = app.fetchCalls.filter((c) => c.url.includes("googleapis.com"));
  assert.equal(driveCalls.length, 0, "no Drive requests when signed out");
});

// ── Library merge semantics ─────────────────────────────────────────────────

test("mergeLibrary unions by name keeping the newest timestamp", async () => {
  const app = await loadApp();
  const merged = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: 10 }, { name: "B.gba", ts: 5 }], tomb: [] },
    { recents: [{ name: "A.gba", ts: 30 }, { name: "C.gba", ts: 7 }], tomb: [] },
  );
  eq(merged.recents.map((r) => r.name), ["A.gba", "C.gba", "B.gba"]);
  assert.equal(merged.recents.find((r) => r.name === "A.gba").ts, 30);
});

test("mergeLibrary drops tombstoned games; a newer re-upload supersedes", async () => {
  const app = await loadApp();
  let m1 = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: 10 }], tomb: [] },
    { recents: [], tomb: [{ name: "A.gba", ts: 20 }] },
  );
  eq(m1.recents.map((r) => r.name), []);
  eq(m1.tomb.map((t) => t.name), ["A.gba"]);

  let m2 = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: 50 }], tomb: [] },
    { recents: [], tomb: [{ name: "A.gba", ts: 20 }] },
  );
  eq(m2.recents.map((r) => r.name), ["A.gba"]);
  eq(m2.tomb, []);
});

// ── Dirty queue ─────────────────────────────────────────────────────────────

test("flushSync uploads queued files, records sigs, then skips unchanged", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("save:Game.gba", u8(65, 66, 67)); // "ABC"

  app.api.markUpload("save:Game.gba");
  eq(app.api.syncState.queueUp, ["save:Game.gba"]);
  await app.api.flushSync();
  await settle();

  assert.ok(drive.byName.has("save:Game.gba"), "uploaded");
  assert.ok(app.api.syncState.sigs["save:Game.gba"], "signature recorded");
  eq(app.api.syncState.queueUp, [], "queue drained");
  // modifiedTime advances on every write: the "was it re-uploaded?" probe.
  const mt1 = drive.byName.get("save:Game.gba").modifiedTime;

  app.api.markUpload("save:Game.gba");
  await app.api.flushSync();
  await settle();
  assert.equal(drive.byName.get("save:Game.gba").modifiedTime, mt1,
    "unchanged save was not re-uploaded");
});

test("flushSync deletes queued files from Drive", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "state:Game.gba": u8(70, 71) });
  app.setFetch(drive.fetch);
  signIn(app);

  app.api.markDelete("state:Game.gba");
  await app.api.flushSync();
  await settle();
  assert.ok(!drive.byName.has("state:Game.gba"), "removed from Drive");
  assert.ok(app.fetchCalls.some((c) => c.method === "DELETE"));
});

// ── Reset / Delete ──────────────────────────────────────────────────────────

test("resetGameSaves wipes save data but keeps the ROM", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1, 2) });
  app.idb.set("save:A.gba", u8(9));
  app.idb.set("state:A.gba", u8(8));

  await app.api.resetGameSaves("A.gba");
  await settle();
  assert.ok(app.idb.get("rom:A.gba"), "ROM kept");
  assert.equal(app.idb.get("save:A.gba"), undefined);
  assert.equal(app.idb.get("state:A.gba"), undefined);
  assert.ok(app.api.syncState.queueDel.includes("save:A.gba"),
    "save deletion mirrored to Drive");
});

test("deleteGameEverywhere clears local data and tombstones the game", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1, 2) });
  app.idb.set("save:A.gba", u8(9));

  await app.api.deleteGameEverywhere("A.gba");
  await settle();
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  assert.equal(app.idb.get("save:A.gba"), undefined);
  eq(app.idb.get("recent"), []);
  eq(app.api.syncState.tomb.map((t) => t.name), ["A.gba"]);
  assert.ok(app.api.syncState.queueDel.includes("rom:A.gba"));
});

// ── Poll doubles as flush retry ─────────────────────────────────────────────
// A flush that fails while navigator stays "online" gets no `online` event;
// the poll must retry the queued work.

test("syncPollTick retries queued uploads after the backend heals", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  signIn(app);
  app.idb.set("save:Game.gba", u8(65, 66));

  app.setFetch(async () => { throw new TypeError("Failed to fetch"); });
  app.api.markUpload("save:Game.gba");
  await app.api.flushSync();
  await settle();
  eq(app.api.syncState.queueUp, ["save:Game.gba"], "queue survives the outage");
  assert.ok(!drive.byName.has("save:Game.gba"));

  app.setFetch(drive.fetch);
  app.api.syncPollTick();
  for (let i = 0; i < 10; i++) await settle(); // flush → pull chain
  assert.ok(drive.byName.has("save:Game.gba"), "poll retried the upload");
  eq(app.api.syncState.queueUp, [], "queue drained");
});

test("syncPollTick is a no-op when signed out", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  app.api.syncPollTick();
  await settle();
  const driveCalls = app.fetchCalls.filter((c) => c.url.includes("googleapis.com"));
  assert.equal(driveCalls.length, 0);
});

// ── Reconciliation: Drive lost files this device still holds ────────────────
// sigs remember what was once uploaded; the listing is the truth (a wiped
// app folder, or a different signed-in account).

test("flushSync uploads a queued file whose sig says synced but Drive lacks it", async () => {
  const app = await loadApp();
  const drive = makeDrive(); // empty — the "new account" case
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("rom:Game.gba", { name: "Game.gba", data: u8(1, 2, 3) });
  app.api.syncState.sigs["rom:Game.gba"] = app.runIn("sigOfBytes")(u8(1, 2, 3));

  app.api.markUpload("rom:Game.gba");
  await app.api.flushSync();
  await settle();
  assert.ok(drive.byName.has("rom:Game.gba"),
    "missing-on-Drive file re-uploads despite a matching sig");
});

test("pullSync queues local files missing from Drive, skipping tombstones", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    library: new TextEncoder().encode(JSON.stringify({
      recents: [], tomb: [{ name: "Dead.gba", ts: 99 }],
    })),
  });
  app.setFetch(drive.fetch);
  signIn(app);
  app.setConfirmResult(false); // tombstone prompt (if any): accept deletion
  app.idb.set("rom:Live.gba", { name: "Live.gba", data: u8(7) });
  app.idb.set("save:Live.gba", u8(8));
  app.idb.set("recent", [{ name: "Live.gba", ts: 5 }]);
  app.api.syncState.sigs["rom:Live.gba"] = "stale";
  app.api.syncState.sigs["save:Live.gba"] = "stale";

  await app.api.pullSync();
  await settle();
  assert.ok(app.api.syncState.queueUp.includes("rom:Live.gba"),
    "missing ROM queued for re-upload");
  assert.ok(app.api.syncState.queueUp.includes("save:Live.gba"),
    "missing save queued for re-upload");
  assert.ok(!app.api.syncState.queueUp.some((n) => n.includes("Dead.gba")),
    "tombstoned game not resurrected");

  await app.api.flushSync();
  await settle();
  assert.ok(drive.byName.has("rom:Live.gba") && drive.byName.has("save:Live.gba"),
    "flush lands both on Drive");
});

// ── On-demand download of a Drive-only game ────────────────────────────────

test("downloadGame pulls a Drive-only game's files into local storage", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    "rom:B.gba": u8(65, 65, 65),
    "save:B.gba": u8(66),
  });
  app.setFetch(drive.fetch);
  signIn(app);
  assert.equal(app.idb.get("rom:B.gba"), undefined, "not local yet");

  const ok = await app.api.downloadGame("B.gba");
  await settle();
  assert.equal(ok, true);
  eq(app.idb.get("rom:B.gba").data, u8(65, 65, 65), "ROM landed locally");
  eq(app.idb.get("save:B.gba"), u8(66), "its save came too");
  eq((app.idb.get("recent") || []).map((r) => r.name), ["B.gba"],
    "and it entered the recents index");
});

// ── Concurrency: work is deferred, never dropped ───────────────────────────

test("a pull is deferred, not dropped, when another op is in flight", async () => {
  const app = await loadApp();
  const lib = { recents: [{ name: "FromDrive.gba", ts: 500 }], tomb: [] };
  const drive = makeDrive({ library: new TextEncoder().encode(JSON.stringify(lib)) });
  // Hold the upload open so the flush is mid-flight when the pull arrives.
  let release;
  const gate = new Promise((r) => { release = r; });
  app.setFetch(async (url, opts) => {
    if (String(url).includes("uploadType")) await gate;
    return drive.fetch(url, opts);
  });
  signIn(app);
  app.idb.set("save:Local.gba", u8(65));
  app.api.markUpload("save:Local.gba"); // give the flush real work to do

  // Pins: signing in on mobile fires visibilitychange (back from the OAuth
  // sheet) while gdriveConnect runs its own sync; neither may skip its pull.
  const flushing = app.api.flushSync();
  await settle();                       // flush is now parked on the upload
  const pulling = app.api.pullSync();   // old code dropped this on the floor
  release();
  await flushing;
  await pulling;
  await settle();

  const names = (app.idb.get("recent") || []).map((r) => r.name);
  assert.ok(names.includes("FromDrive.gba"),
    "pull ran despite the concurrent flush, got: " + JSON.stringify(names));
});

test("the merged library is not truncated at MAX_RECENT", async () => {
  const app = await loadApp();
  const recents = Array.from({ length: 25 }, (_, i) => ({ name: `G${i}.gba`, ts: 1000 - i }));
  const drive = makeDrive({
    library: new TextEncoder().encode(JSON.stringify({ recents, tomb: [] })),
  });
  app.setFetch(drive.fetch);
  signIn(app);

  await app.api.pullSync();
  await settle();
  // A cap here would make every game past the 20th impossible to download.
  assert.equal((app.idb.get("recent") || []).length, 25);
});

// ── Renames: in-place on Drive, migrated on other devices ──────────────────
// A metadata PATCH per file plus a `ren` marker in the shared library, so
// other devices migrate their local records on their next sync.

test("flushSync renames Drive files in place — content untouched, nothing re-uploaded", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "rom:A.gba": u8(65, 65), "save:A.gba": u8(66) });
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", [{ name: "A.gba", ts: 100 }]);

  const res = await app.api.renameGame("A.gba", "B.gba");
  assert.equal(res.ok, true, "a Drive-only game renames");
  await app.api.flushSync();
  await settle();

  assert.ok(drive.byName.has("rom:B.gba"), "the ROM answers to its new name");
  assert.ok(drive.byName.has("save:B.gba"));
  assert.ok(!drive.byName.has("rom:A.gba"), "…and no longer to the old one");
  eq(drive.byName.get("rom:B.gba").bytes, u8(65, 65), "bytes never moved");
  eq(app.api.syncState.queueRen, [], "the rename queue drained");
  assert.ok(!app.fetchCalls.some((c) => String(c.url).includes("uploadType") &&
            !String(c.url).includes("multipart")),
    "no content was uploaded");
  const lib = drive.libraryJSON();
  eq(lib.recents.map((r) => r.name), ["B.gba"]);
  assert.equal(lib.ren[0].from, "A.gba");
  assert.equal(lib.ren[0].to, "B.gba", "the marker is published for other devices");
  eq(lib.tomb, [], "and no tombstone: nothing was deleted");
});

test("flushSync deletes the old file when another device already made the renamed one", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "save:A.gba": u8(1), "save:B.gba": u8(2) });
  app.setFetch(drive.fetch);
  signIn(app, { queueRen: [{ from: "save:A.gba", to: "save:B.gba" }] });

  await app.api.flushSync();
  await settle();
  assert.ok(!drive.byName.has("save:A.gba"), "the duplicate is removed");
  eq(drive.byName.get("save:B.gba").bytes, u8(2), "the winner is untouched");
});

test("flushSync uploads instead when Drive holds neither name but the bytes are here", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  app.setFetch(drive.fetch);
  signIn(app, { queueRen: [{ from: "save:A.gba", to: "save:B.gba" }] });
  app.idb.set("save:B.gba", u8(66, 66));

  await app.api.flushSync();
  await settle();
  eq(drive.byName.get("save:B.gba").bytes, u8(66, 66),
     "the rename beat the first upload, so the flush falls back to uploading");
});

test("mergeLibrary carries a renamed entry across, keeping its own recency", async () => {
  const app = await loadApp();
  const merged = app.api.mergeLibrary(
    { recents: [{ name: "B.gba", ts: 50 }], ren: [{ from: "A.gba", to: "B.gba", ts: 40 }] },
    { recents: [{ name: "A.gba", ts: 10 }, { name: "C.gba", ts: 5 }] }, // a stale device
  );
  eq(merged.recents.map((r) => r.name), ["B.gba", "C.gba"],
     "the stale device's old-name entry folds into the renamed one");
  assert.equal(merged.recents[0].ts, 50);
  eq(merged.ren.map((r) => r.from), ["A.gba"], "the marker stays for devices yet to sync");
});

test("mergeLibrary replays a rename chain oldest-first", async () => {
  const app = await loadApp();
  const merged = app.api.mergeLibrary(
    { ren: [{ from: "A.gba", to: "B.gba", ts: 10 }, { from: "B.gba", to: "C.gba", ts: 20 }] },
    { recents: [{ name: "A.gba", ts: 5 }] },
  );
  eq(merged.recents.map((r) => r.name), ["C.gba"], "A lands on C via B");
});

test("a newer entry under the old name supersedes the rename marker", async () => {
  const app = await loadApp();
  // Renamed away, then a new game imported under the freed name.
  const merged = app.api.mergeLibrary(
    { recents: [{ name: "B.gba", ts: 45 }], ren: [{ from: "A.gba", to: "B.gba", ts: 40 }] },
    { recents: [{ name: "A.gba", ts: 60 }] },
  );
  eq(merged.recents.map((r) => r.name).sort(), ["A.gba", "B.gba"],
     "the newcomer keeps the freed-up name, alongside the renamed game");
  eq(merged.ren, [], "the spent marker is dropped so it can never rename the newcomer");
});

test("pullSync migrates local records when another device renamed the game", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    "rom:B.gba": u8(65, 65),
    "save:B.gba": u8(66),
    library: new TextEncoder().encode(JSON.stringify({
      recents: [{ name: "B.gba", ts: 200 }],
      tomb: [],
      ren: [{ from: "A.gba", to: "B.gba", ts: 150 }],
    })),
  });
  app.setFetch(drive.fetch);
  signIn(app, { sigs: { "rom:A.gba": "sig-rom" }, rmt: { "save:A.gba": "mt" } });
  app.idb.set("recent", [{ name: "A.gba", ts: 100 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(65, 65) });
  app.idb.set("save:A.gba", u8(66));
  app.idb.set("art:A.gba", u8(9));
  app.idb.set("cheats:A.gba", "[x] codes\n");

  await app.api.pullSync();
  await settle();

  eq(app.idb.get("rom:B.gba").data, u8(65, 65), "the ROM moved locally");
  eq(app.idb.get("save:B.gba"), u8(66));
  eq(app.idb.get("art:B.gba"), u8(9), "unsynced records (art) moved too");
  assert.equal(app.idb.get("cheats:B.gba"), "[x] codes\n");
  assert.equal(app.idb.get("rom:A.gba"), undefined, "nothing left under the old name");
  assert.equal(app.api.syncState.sigs["rom:B.gba"], "sig-rom",
    "sync bookkeeping followed the files");
  // rmt must track the new name only.
  assert.ok(app.api.syncState.rmt["save:B.gba"]);
  assert.equal(app.api.syncState.rmt["save:A.gba"], undefined);
  assert.equal(app.api.syncState.sigs["rom:A.gba"], undefined);
  eq((app.idb.get("recent") || []).map((r) => r.name), ["B.gba"]);
  assert.ok(!app.api.syncState.queueUp.some((n) => n.includes("A.gba")),
    "the old names were not re-uploaded to Drive");
  assert.ok(drive.byName.has("rom:B.gba") && !drive.byName.has("rom:A.gba"),
    "Drive is exactly as the renaming device left it");
});

test("pullSync migrates a game that is OPEN right now, live, session and all", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    "rom:B.gba": u8(65),
    library: new TextEncoder().encode(JSON.stringify({
      recents: [{ name: "B.gba", ts: 200 }],
      tomb: [],
      ren: [{ from: "A.gba", to: "B.gba", ts: 150 }],
    })),
  });
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", [{ name: "A.gba", ts: 100 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(65) });
  app.idb.set("save:A.gba", u8(66));
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "A.gba"; // being played right now
  app.sandbox.FS.files.set("rom.sav", u8(66, 67)); // in-memory progress

  await app.api.pullSync();
  await settle();

  // As renameGame's own live rename: flush under the old name, move,
  // reattach the session to the new name.
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  eq(app.idb.get("rom:B.gba").data, u8(65));
  eq(app.idb.get("save:B.gba"), u8(66, 67), "the in-memory progress moved too");
  assert.equal(app.api.currentOriginalName, "B.gba",
    "the open game now answers to its new name");
  eq((app.idb.get("recent") || []).map((r) => r.name), ["B.gba"]);
});

test("a link session defers the migration AND the grid keeps the old name meanwhile", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    "rom:B.gba": u8(65),
    library: new TextEncoder().encode(JSON.stringify({
      recents: [{ name: "B.gba", ts: 200 }],
      tomb: [],
      ren: [{ from: "A.gba", to: "B.gba", ts: 150 }],
    })),
  });
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", [{ name: "A.gba", ts: 100 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(65) });
  app.idb.set("save:A.gba", u8(66));
  app.api.linkMode = true;
  app.api.linkRomEntry = { name: "A.gba" }; // a second core is writing these saves

  await app.api.pullSync();
  await settle();

  assert.ok(app.idb.get("rom:A.gba"), "nothing is moved out from under the link session");
  // The grid must not adopt the new name while the data sits under the old
  // one: a "Drive only" tile for a local game forks the library on download.
  eq((app.idb.get("recent") || []).map((r) => r.name), ["A.gba"],
     "the local grid keeps the old, installed name until the migration lands");
  assert.ok(app.idb.get("recent")[0].ts < 150,
     "…pinned older than the marker so it can never supersede the rename");
  assert.ok(!app.api.syncState.queueUp.some((n) => n.includes("A.gba")),
    "and old-name files are NOT queued back up to Drive");

  app.api.linkMode = false;
  app.api.linkRomEntry = null;
  await app.api.pullSync();
  await settle();
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  eq(app.idb.get("rom:B.gba").data, u8(65));
  eq(app.idb.get("save:B.gba"), u8(66));
  eq((app.idb.get("recent") || []).map((r) => r.name), ["B.gba"]);
});

test("two devices: a Drive-only rename on one lands whole on the other", async () => {
  const drive = makeDrive({ "rom:A.gba": u8(65, 65), "save:A.gba": u8(66) });

  const dev1 = await loadApp();
  dev1.setFetch(drive.fetch);
  signIn(dev1);
  dev1.idb.set("recent", [{ name: "A.gba", ts: 100 }]);
  const res = await dev1.api.renameGame("A.gba", "B.gba");
  assert.equal(res.ok, true);
  await dev1.api.flushSync();
  await settle();

  const dev2 = await loadApp();
  dev2.setFetch(drive.fetch);
  signIn(dev2);
  dev2.idb.set("recent", [{ name: "A.gba", ts: 90 }]);
  dev2.idb.set("rom:A.gba", { name: "A.gba", data: u8(65, 65) });
  dev2.idb.set("save:A.gba", u8(66));

  await dev2.api.pullSync();
  await settle();
  eq(dev2.idb.get("rom:B.gba").data, u8(65, 65), "device 2 followed the rename");
  assert.equal(dev2.idb.get("rom:A.gba"), undefined);
  eq((dev2.idb.get("recent") || []).map((r) => r.name), ["B.gba"]);
  assert.ok(drive.byName.has("rom:B.gba") && !drive.byName.has("rom:A.gba"),
    "and Drive holds exactly one copy, under the new name");
});

test("a dirty save queued before the rename arrives still uploads, under the new name", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    "rom:B.gba": u8(65),
    "save:B.gba": u8(66), // Drive's copy: the OLD content, renamed in place
    library: new TextEncoder().encode(JSON.stringify({
      recents: [{ name: "B.gba", ts: 200 }],
      tomb: [],
      ren: [{ from: "A.gba", to: "B.gba", ts: 150 }],
    })),
  });
  app.setFetch(drive.fetch);
  // Newer bytes queued under the old name.
  signIn(app, { queueUp: ["save:A.gba"],
                sigs: { "save:A.gba": "old-sig" },
                rmt: { "save:A.gba": drive.byName.get("save:B.gba").modifiedTime } });
  app.idb.set("recent", [{ name: "A.gba", ts: 100 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(65) });
  app.idb.set("save:A.gba", u8(77, 77)); // the dirty bytes

  await app.api.pullSync();
  await settle();
  assert.ok(app.api.syncState.queueUp.includes("save:B.gba"),
    "the queued upload follows the rename instead of being dropped");
  await app.api.flushSync();
  await settle();
  eq(drive.byName.get("save:B.gba").bytes, u8(77, 77),
     "the offline progress reached Drive under the new name");
});

// Install + quick save in browser 1; rename from browser 2 where it was
// never downloaded; back in browser 1 the game is open and its quick save
// still queued when the visibilitychange flush+pull fires. Must end with one
// game under the new name, quick save intact locally and on Drive.
test("field repro: rename elsewhere while installed+open here with a queued quick save", async () => {
  const drive = makeDrive();

  // Browser 1.
  const b1 = await loadApp();
  b1.setFetch(drive.fetch);
  signIn(b1);
  b1.idb.set("recent", [{ name: "A.gba", ts: 100 }]);
  b1.idb.set("rom:A.gba", { name: "A.gba", data: u8(65, 65) });
  b1.idb.set("save:A.gba", u8(66));
  b1.api.markUpload("rom:A.gba");
  b1.api.markUpload("save:A.gba");
  await b1.api.flushSync();
  await settle();
  b1.idb.set("state:A.gba", u8(70, 70)); // the quick save
  b1.api.markUpload("state:A.gba");      // …queued, flush hasn't run yet
  b1.api.currentRomName = "rom.gba";
  b1.api.currentOriginalName = "A.gba";

  // Browser 2.
  const b2 = await loadApp();
  b2.setFetch(drive.fetch);
  signIn(b2);
  await b2.api.pullSync();
  await settle();
  assert.equal((await b2.api.renameGame("A.gba", "B.gba")).ok, true);
  await b2.api.flushSync();
  await settle();
  assert.ok(drive.byName.has("rom:B.gba") && !drive.byName.has("rom:A.gba"));

  // Back to browser 1: flush (under the old name, racing the rename), then pull.
  await b1.api.flushSync();
  await settle();
  assert.ok(drive.byName.has("state:A.gba"), "the raced upload landed old-named");
  await b1.api.pullSync();
  await settle();

  eq(b1.idb.get("rom:B.gba").data, u8(65, 65), "installed, under the new name");
  eq(b1.idb.get("state:B.gba"), u8(70, 70), "the quick save survived");
  assert.equal(b1.idb.get("rom:A.gba"), undefined);
  assert.equal(b1.idb.get("state:A.gba"), undefined);
  assert.equal(b1.api.currentOriginalName, "B.gba");
  eq((b1.idb.get("recent") || []).map((r) => r.name), ["B.gba"]);

  await b1.api.flushSync();
  await settle();
  assert.ok(!drive.byName.has("state:A.gba"), "no old-name orphan left on Drive");
  eq(drive.byName.get("state:B.gba").bytes, u8(70, 70));
});

// New-name copies downloaded before the migration ran: an all-or-nothing
// move would abort on the first collision forever and strand the quick save.
test("a forked library heals per key: the quick save is rescued, duplicates deduped", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    "rom:B.gba": u8(65, 65),
    "save:B.gba": u8(66),
    library: new TextEncoder().encode(JSON.stringify({
      recents: [{ name: "B.gba", ts: 200 }],
      tomb: [],
      ren: [{ from: "A.gba", to: "B.gba", ts: 150 }],
    })),
  });
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", [{ name: "B.gba", ts: 200 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(65, 65) });
  app.idb.set("save:A.gba", u8(66));
  app.idb.set("state:A.gba", u8(70, 70)); // the quick save — no B copy exists
  // Freshly downloaded new-name copies (identical content).
  app.idb.set("rom:B.gba", { name: "B.gba", data: u8(65, 65) });
  app.idb.set("save:B.gba", u8(66));

  await app.api.pullSync();
  await settle();

  eq(app.idb.get("state:B.gba"), u8(70, 70),
     "the non-colliding quick save moved instead of being stranded");
  assert.equal(app.idb.get("rom:A.gba"), undefined,
    "the identical old-name ROM was dropped as a duplicate");
  assert.equal(app.idb.get("save:A.gba"), undefined);
  eq(app.idb.get("rom:B.gba").data, u8(65, 65));
});

test("a genuinely different colliding save is kept, visibly, under the old name", async () => {
  const app = await loadApp();
  const drive = makeDrive({
    "rom:B.gba": u8(65),
    library: new TextEncoder().encode(JSON.stringify({
      recents: [{ name: "B.gba", ts: 200 }],
      tomb: [],
      ren: [{ from: "A.gba", to: "B.gba", ts: 150 }],
    })),
  });
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("recent", [{ name: "B.gba", ts: 200 }]);
  app.idb.set("save:A.gba", u8(1, 1, 1)); // progress the fork left behind
  app.idb.set("rom:B.gba", { name: "B.gba", data: u8(65) });
  app.idb.set("save:B.gba", u8(2, 2, 2)); // different progress under the new name

  await app.api.pullSync();
  await settle();

  eq(app.idb.get("save:A.gba"), u8(1, 1, 1),
     "neither copy is silently lost — the old-name save stays as a visible orphan");
  eq(app.idb.get("save:B.gba"), u8(2, 2, 2));
});

test("relaunching a renamed-away game does not cancel the rename; a re-import does", async () => {
  const app = await loadApp();
  signIn(app, { ren: [{ from: "A.gba", to: "B.gba", ts: 5000 }] });
  app.idb.set("recent", [{ name: "A.gba", ts: 100 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(65) });

  // Relaunch pins recency just under the marker: still folded forward.
  await app.api.touchRecent("A.gba");
  assert.equal(app.idb.get("recent")[0].ts, 4999);

  // A real re-import is a new claim on the freed name and supersedes.
  await app.api.addRecentRom("A.gba", u8(9, 9));
  assert.ok(app.idb.get("recent")[0].ts > 5000);
});
