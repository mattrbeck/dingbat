// Google Drive SYNC layer (web/index.js). Exercises the REAL app functions via
// the vm harness's runIn(), covering the invariants that matter most:
//   - signed-out / sync-off gating (requirement #5): nothing is ever queued;
//   - shouldSyncGame across all/selected/off modes;
//   - detachGameFromSync (requirement #4 "local-only");
//   - the debounced auto-upload engine: dirty save uploads, unchanged save is
//     skipped by signature, and queued deletes are propagated to Drive.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, eq, settle } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";
const UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files";

// A tiny stateful fake of the appDataFolder: list / upload / download / delete.
// Upload bodies are only inspected for the file name; stored bytes are a
// placeholder (the tests that skip-by-signature never download).
const makeDrive = (seed = []) => {
  const byName = new Map();
  let idc = 0, mtc = 0;
  const nextMt = () =>
    "2026-01-01T00:00:" + String(10 + mtc++).padStart(2, "0") + "Z";
  for (const [name, bytes] of seed) {
    byName.set(name, { id: "seed" + idc++, name, bytes, modifiedTime: nextMt() });
  }
  const listBody = () => ({
    files: [...byName.values()].map((f) => ({
      id: f.id, name: f.name, size: String(f.bytes.length),
      modifiedTime: f.modifiedTime,
    })),
  });
  const fetch = async (url, opts = {}) => {
    url = String(url);
    const method = opts.method || "GET";
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) return jsonRes(listBody());
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
      const prev = byName.get(name);
      byName.set(name, {
        id: prev ? prev.id : "up" + idc++, name,
        bytes: u8(0), modifiedTime: nextMt(),
      });
      return jsonRes({ id: byName.get(name).id });
    }
    const media = url.match(/\/upload\/drive\/v3\/files\/([^/?]+)\?uploadType=media/);
    if (media && method === "PATCH") {
      const ent = [...byName.values()].find((x) => x.id === media[1]);
      if (ent) ent.modifiedTime = nextMt();
      return jsonRes({ id: media[1] });
    }
    throw new Error("unexpected " + method + " " + url);
  };
  return { byName, fetch };
};

const signIn = (app, prefs) => {
  app.api.gdriveToken = "test-token";
  app.runIn(`syncPrefs = ${JSON.stringify({
    mode: null, selected: [], excluded: [], sigs: {}, rmt: {}, ...prefs,
  })}`);
};

// ── Requirement #5: signed-out and sync-off never touch the queues ──────────

test("signed out: shouldSyncGame is always false and nothing queues", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  app.runIn("syncPrefs.mode = 'all'"); // even with a stored mode…
  assert.equal(app.runIn("shouldSyncGame('Zelda.gba')"), false);
  app.runIn("markSyncUpload('save:Zelda.gba')");
  app.runIn("markSyncDelete('state:Zelda.gba')");
  assert.equal(app.runIn("syncUpQueue.size"), 0);
  assert.equal(app.runIn("syncDelQueue.size"), 0);
  assert.equal(app.runIn("syncActive()"), false);
});

test("signed in but mode 'off': nothing queues", async () => {
  const app = await loadApp();
  signIn(app, { mode: "off" });
  app.runIn("markSyncUpload('save:Zelda.gba')");
  assert.equal(app.runIn("syncUpQueue.size"), 0);
  assert.equal(app.runIn("syncActive()"), false);
});

// ── shouldSyncGame across modes ─────────────────────────────────────────────

test("mode 'all' syncs everything except excluded", async () => {
  const app = await loadApp();
  signIn(app, { mode: "all", excluded: ["Skip.gba"] });
  assert.equal(app.runIn("shouldSyncGame('Play.gba')"), true);
  assert.equal(app.runIn("shouldSyncGame('Skip.gba')"), false);
});

test("mode 'selected' syncs only the listed games", async () => {
  const app = await loadApp();
  signIn(app, { mode: "selected", selected: ["A.gba"] });
  assert.equal(app.runIn("shouldSyncGame('A.gba')"), true);
  assert.equal(app.runIn("shouldSyncGame('B.gba')"), false);
});

// ── Requirement #4: detach a game from sync ("local-only") ──────────────────

test("detachGameFromSync excludes in all-mode, de-selects in selected-mode", async () => {
  const app = await loadApp();
  signIn(app, { mode: "all", excluded: [] });
  app.runIn("detachGameFromSync('Gone.gba')");
  eq(app.runIn("syncPrefs.excluded"), ["Gone.gba"]);
  assert.equal(app.runIn("shouldSyncGame('Gone.gba')"), false);

  signIn(app, { mode: "selected", selected: ["Gone.gba", "Keep.gba"] });
  app.runIn("detachGameFromSync('Gone.gba')");
  eq(app.runIn("syncPrefs.selected"), ["Keep.gba"]);
});

// ── Auto-upload engine ──────────────────────────────────────────────────────

test("flushSync uploads a dirty save, then skips it when unchanged", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  app.setFetch(drive.fetch);
  signIn(app, { mode: "all" });
  app.idb.set("save:Game.gba", u8(1, 2, 3));

  app.runIn("markSyncUpload('save:Game.gba')");
  assert.equal(app.runIn("syncUpQueue.size"), 1);
  await app.runIn("flushSync()");
  await settle();

  assert.ok(drive.byName.has("save:Game.gba"), "save uploaded to Drive");
  const sig1 = app.runIn("syncPrefs.sigs['save:Game.gba']");
  assert.ok(sig1, "signature recorded after upload");
  const uploads1 = app.fetchCalls.filter(
    (c) => c.url.startsWith(UPLOAD_URL) && c.method === "POST").length;
  assert.equal(uploads1, 1);

  // Same bytes → signature matches → no second upload.
  app.runIn("markSyncUpload('save:Game.gba')");
  await app.runIn("flushSync()");
  await settle();
  const uploads2 = app.fetchCalls.filter(
    (c) => c.url.startsWith(UPLOAD_URL) && c.method === "POST").length;
  assert.equal(uploads2, 1, "unchanged save is not re-uploaded");
});

test("flushSync propagates a queued delete to Drive", async () => {
  const app = await loadApp();
  const drive = makeDrive([["state:Game.gba", u8(9, 9)]]);
  app.setFetch(drive.fetch);
  signIn(app, { mode: "all" });

  app.runIn("markSyncDelete('state:Game.gba')");
  assert.equal(app.runIn("syncDelQueue.size"), 1);
  await app.runIn("flushSync()");
  await settle();

  assert.ok(!drive.byName.has("state:Game.gba"), "state removed from Drive");
  const deletes = app.fetchCalls.filter((c) => c.method === "DELETE").length;
  assert.equal(deletes, 1);
});
