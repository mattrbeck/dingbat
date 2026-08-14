// Google Drive sync engine (web/index.js). Exercises the REAL functions via
// the vm harness:
//   - signed-out gating: nothing is ever queued;
//   - library merge semantics incl. tombstones and re-upload-supersedes;
//   - the persisted dirty queue and its signature-based skip;
//   - Reset / Delete (local + Drive, tombstone) and their signed-out form;
//   - on-demand download of a Drive-only game;
//   - renames: in-place remote renames (queueRen) and ren markers, the
//     tombstone-like record that migrates other devices to the new name.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, eq, settle } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";
const UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files";

// Minimal stateful appDataFolder: list / multipart-create / media-PATCH /
// download / delete. Test payloads stay ASCII so the multipart body survives
// the text round-trip byte-for-byte.
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
    // Metadata-only PATCH: the in-place rename driveRenameFile issues.
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
  // Tombstone newer than the entry -> the game stays deleted.
  let m1 = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: 10 }], tomb: [] },
    { recents: [], tomb: [{ name: "A.gba", ts: 20 }] },
  );
  eq(m1.recents.map((r) => r.name), []);
  eq(m1.tomb.map((t) => t.name), ["A.gba"]);

  // Re-uploaded after the delete -> the entry wins and the tombstone clears.
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
  // modifiedTime advances on every write, so it is the precise "was it
  // re-uploaded?" probe (an update would be a PATCH, not a second POST).
  const mt1 = drive.byName.get("save:Game.gba").modifiedTime;

  // Re-queue the same unchanged bytes: the signature short-circuits the upload.
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
// A flush that fails while the browser still thinks it's online (Drive
// outage, blocking proxy) gets no `online` event; the gentle poll must retry
// the queued work, or "will sync when you reconnect" never comes true.

test("syncPollTick retries queued uploads after the backend heals", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  signIn(app);
  app.idb.set("save:Game.gba", u8(65, 66));

  // Backend down (but navigator stays "online"): the flush fails and the
  // queue keeps the entry.
  app.setFetch(async () => { throw new TypeError("Failed to fetch"); });
  app.api.markUpload("save:Game.gba");
  await app.api.flushSync();
  await settle();
  eq(app.api.syncState.queueUp, ["save:Game.gba"], "queue survives the outage");
  assert.ok(!drive.byName.has("save:Game.gba"));

  // Backend heals; the next poll tick must drain the queue on its own.
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
// sigs remember what was once uploaded; the listing is the truth. A wiped app
// folder or a different signed-in account must not leave local games
// permanently "synced by sig" yet absent from Drive.

test("flushSync uploads a queued file whose sig says synced but Drive lacks it", async () => {
  const app = await loadApp();
  const drive = makeDrive(); // empty — the "new account" case
  app.setFetch(drive.fetch);
  signIn(app);
  app.idb.set("rom:Game.gba", { name: "Game.gba", data: u8(1, 2, 3) });
  // Pretend a past session uploaded this exact content (to another account).
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
  // Sigs claim both files were uploaded once.
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
  // Hold the upload open so the flush is genuinely mid-flight when the pull
  // arrives — otherwise the flush finishes first and there is no race to test.
  let release;
  const gate = new Promise((r) => { release = r; });
  app.setFetch(async (url, opts) => {
    if (String(url).includes("uploadType")) await gate;
    return drive.fetch(url, opts);
  });
  signIn(app);
  app.idb.set("save:Local.gba", u8(65));
  app.api.markUpload("save:Local.gba"); // give the flush real work to do

  // Regression: signing in on mobile fires visibilitychange (returning from the
  // OAuth sheet) while gdriveConnect runs its own sync. The old busy guard made
  // whichever op lost the race silently skip its pull, so a freshly signed-in
  // phone sat on an empty grid until the 3-minute poll rescued it.
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
  // Capping here would make every game past the 20th unreachable: invisible in
  // the grid and therefore impossible to download.
  assert.equal((app.idb.get("recent") || []).length, 25);
});

// ── Renames: in-place on Drive, migrated on other devices ──────────────────
// A rename is mirrored as a metadata PATCH per file (no bytes move), plus a
// `ren` marker in the shared library — the tombstone's constructive sibling —
// so every other device migrates its local records to the new name on its
// next sync instead of being told the game was deleted.

test("flushSync renames Drive files in place — content untouched, nothing re-uploaded", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "rom:A.gba": u8(65, 65), "save:A.gba": u8(66) });
  app.setFetch(drive.fetch);
  signIn(app);
  // Drive-only: nothing local but the library entry.
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
  // The name was renamed away, then a NEW game was imported under it.
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
  // This device still holds the game under its old name, art and cheats too.
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
  // The same pull then reconciles the renamed save against Drive, so rmt holds
  // a live modifiedTime — the point is that it tracks the NEW name only.
  assert.ok(app.api.syncState.rmt["save:B.gba"]);
  assert.equal(app.api.syncState.rmt["save:A.gba"], undefined);
  assert.equal(app.api.syncState.sigs["rom:A.gba"], undefined);
  eq((app.idb.get("recent") || []).map((r) => r.name), ["B.gba"]);
  assert.ok(!app.api.syncState.queueUp.some((n) => n.includes("A.gba")),
    "the old names were not re-uploaded to Drive");
  assert.ok(drive.byName.has("rom:B.gba") && !drive.byName.has("rom:A.gba"),
    "Drive is exactly as the renaming device left it");
});

test("pullSync defers the migration while the game is loaded, without resurrecting old names", async () => {
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

  await app.api.pullSync();
  await settle();

  assert.ok(app.idb.get("rom:A.gba"), "nothing is moved out from under the running game");
  assert.ok(!app.api.syncState.queueUp.some((n) => n.includes("A.gba")),
    "…and its old-name files are NOT queued back up to Drive");
  eq(app.api.syncState.ren.map((r) => r.from), ["A.gba"],
     "the marker is kept, so the next sync (game closed) migrates");

  // The game closes; the next pull completes the rename.
  app.api.currentRomName = null;
  app.api.currentOriginalName = null;
  await app.api.pullSync();
  await settle();
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  eq(app.idb.get("rom:B.gba").data, u8(65));
  eq(app.idb.get("save:B.gba"), u8(66));
});

test("two devices: a Drive-only rename on one lands whole on the other", async () => {
  // Device 1 renames a game it never downloaded; device 2 holds it locally.
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
  // This device saved the game offline: newer bytes, queued under the old name.
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
