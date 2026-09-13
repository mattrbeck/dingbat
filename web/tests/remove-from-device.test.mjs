// removeGameFromDevice: frees this device's ROM bytes and nothing else. The
// guard has two layers, both pinned: the button renders only with a record
// of the ROM being on Drive, and the action re-checks the live listing.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, eq, settle } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";

const makeDrive = (names = []) => {
  const files = new Map(names.map((n, i) => [n, { id: "f" + i, name: n }]));
  const fetch = async (url, opts = {}) => {
    url = String(url);
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [...files.values()].map((f) => ({
        id: f.id, name: f.name, size: "3", modifiedTime: "2026-01-01T00:00:00Z",
      })) });
    }
    if (url.includes("alt=media")) return bytesRes(u8(65, 66, 67));
    return jsonRes({ id: "up" });
  };
  return { files, fetch };
};

const signIn = (app, sigs = {}) => {
  app.api.gdriveToken = "test-token";
  app.api.syncState =
    { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], sigs, rmt: {}, connected: true };
};

const seedLocal = (app, name, romBytes = u8(1, 2, 3, 4, 5, 6, 7, 8)) => {
  app.idb.set("recent", [{ name, ts: 100 }]);
  app.idb.set("rom:" + name, { name, data: romBytes });
  app.idb.set("art:" + name, u8(9, 9));
  app.idb.set("save:" + name, u8(7));
  app.idb.set("state:" + name, u8(6));
};

// Make navigator.storage.estimate() report the fake IndexedDB's byte weight.
const meterStorage = (app) => {
  const weigh = (v) => {
    if (!v) return 0;
    if (v.byteLength !== undefined) return v.byteLength;
    if (v.data?.byteLength !== undefined) return v.data.byteLength;
    return JSON.stringify(v)?.length || 0;
  };
  app.sandbox.navigator.storage.estimate = async () => {
    let usage = 0;
    for (const v of app.idb.values()) usage += weigh(v);
    return { usage, quota: app.state.storageQuota ?? 4 * 1024 * 1024 * 1024 };
  };
};

// ── The action ──────────────────────────────────────────────────────────────

test("removeGameFromDevice frees the ROM and art, and nothing else", async () => {
  const app = await loadApp();
  const drive = makeDrive(["rom:A.gba", "save:A.gba"]);
  app.setFetch(drive.fetch);
  signIn(app, { "rom:A.gba": "sig" });
  seedLocal(app, "A.gba");
  app.idb.set("frame:A.gba", new Blob([u8(1)]));

  assert.equal(await app.api.removeGameFromDevice("A.gba"), true);
  await settle();

  assert.equal(app.idb.get("rom:A.gba"), undefined, "ROM bytes freed");
  assert.equal(app.idb.get("art:A.gba"), undefined, "box art freed too");
  assert.ok(app.idb.get("frame:A.gba"), "the picture stays: mirrored, and the tile keeps its face");
  eq(app.idb.get("save:A.gba"), u8(7), "battery save kept");
  eq(app.idb.get("state:A.gba"), u8(6), "save state kept");
  eq(app.api.syncState.tomb, [], "no tombstone — other devices keep the game");
  eq((app.idb.get("recent") || []).map((r) => r.name), ["A.gba"],
    "the library entry stays, so the game still has a tile");
  assert.ok(drive.files.has("rom:A.gba"), "the Drive copy is untouched");
  assert.ok(!app.fetchCalls.some((c) => c.method === "DELETE"),
    "nothing was deleted from Drive");
});

test("the saves left behind are queued for Drive on the way out", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba"]).fetch);
  signIn(app, { "rom:A.gba": "sig" });
  seedLocal(app, "A.gba");

  await app.api.removeGameFromDevice("A.gba");
  await settle();
  const q = app.api.syncState.queueUp;
  assert.ok(q.includes("save:A.gba"), "battery save queued, got " + JSON.stringify(q));
  assert.ok(!q.includes("rom:A.gba"), "the ROM we just freed is not re-queued");
});

test("removing a game frees its bytes, and says so when the room was short",
  async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba"]).fetch);
  signIn(app, { "rom:A.gba": "sig" });
  seedLocal(app, "A.gba", new Uint8Array(64 * 1024));
  meterStorage(app);

  // Nearly full, so the head has something to say before and after.
  app.state.storageQuota = 70 * 1024;
  const before = (await app.sandbox.navigator.storage.estimate()).usage;
  await app.api.refreshHomeRecent();
  await settle();
  assert.match(app.document.getElementById("storage-info").textContent,
    /used$/, "a device this full says how full");

  await app.api.removeGameFromDevice("A.gba");
  await settle();
  const after = (await app.sandbox.navigator.storage.estimate()).usage;
  assert.ok(after < before - 60000,
    `the ROM's bytes must actually be gone (${before} -> ${after})`);

  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(app.document.getElementById("storage-info").textContent, "",
    "and the warning goes with them");
});

test("the removed game re-renders as a Drive-only tile", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba", "rom:B.gba"]).fetch);
  signIn(app, { "rom:A.gba": "sig", "rom:B.gba": "sig" });
  app.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "B.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1, 2) });
  app.idb.set("rom:B.gba", { name: "B.gba", data: u8(3, 4) });
  await app.api.refreshHomeRecent();
  await settle();

  const grid = app.document.getElementById("home-recent");
  assert.equal(grid.children.length, 2);
  assert.ok(!grid.children[0].className.includes("home-tile-cloud"));

  // An empty moment collapses #home's scrollHeight (see homegrid.test.mjs).
  const sizes = [];
  const proto = Object.getPrototypeOf(grid);
  grid.replaceChildren = (...cs) => {
    proto.replaceChildren.apply(grid, cs);
    sizes.push(grid.children.length);
  };

  await app.api.removeGameFromDevice("A.gba");
  await app.api.refreshHomeRecent();
  await settle();

  assert.ok(!sizes.includes(0), "the grid was never emptied, saw " + JSON.stringify(sizes));
  assert.equal(grid.children.length, 2, "the game keeps its place in the library");
  assert.ok(grid.children[0].className.includes("home-tile-cloud"),
    "and now renders exactly like any other Drive-only game");
  const controls = grid.children[0].children.map((c) => c.className);
  assert.ok(controls.some((c) => c.includes("home-tile-dl")), "download glyph");
  assert.ok(!controls.some((c) => c.includes("home-tile-link")), "no 2P button");
});

// ── The guard: never take the last copy ─────────────────────────────────────

test("a game Drive does not hold is kept and queued instead of removed", async () => {
  const app = await loadApp();
  // sigs claims an upload but the listing disagrees (a wiped app folder, or
  // a different Google account).
  const drive = makeDrive(["save:A.gba"]);
  app.setFetch(drive.fetch);
  signIn(app, { "rom:A.gba": "stale-sig" });
  seedLocal(app, "A.gba");

  assert.equal(await app.api.removeGameFromDevice("A.gba"), false);
  await settle();
  assert.ok(app.idb.get("rom:A.gba"), "the only copy of the ROM survived");
  assert.ok(app.api.syncState.queueUp.includes("rom:A.gba"),
    "and it was queued for backup rather than deleted");
  assert.ok(app.toasts.some((t) => /not backed up/i.test(t)), app.toasts.join(" | "));
});

test("an unreachable Drive removes nothing", async () => {
  const app = await loadApp();
  app.setFetch(async () => { throw new Error("offline"); });
  signIn(app, { "rom:A.gba": "sig" });
  seedLocal(app, "A.gba");

  assert.equal(await app.api.removeGameFromDevice("A.gba"), false);
  await settle();
  assert.ok(app.idb.get("rom:A.gba"), "ROM kept when we can't verify the backup");
});

test("signed out, removeGameFromDevice is refused outright", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  seedLocal(app, "A.gba");

  assert.equal(await app.api.removeGameFromDevice("A.gba"), false);
  await settle();
  assert.ok(app.idb.get("rom:A.gba"), "ROM kept");
  assert.equal(app.fetchCalls.filter((c) => c.url.includes("googleapis.com")).length, 0);
});

// ── The guard, at the button ────────────────────────────────────────────────

// ── End to end through the button ───────────────────────────────────────────

// ── Learning that Drive already holds the ROM ───────────────────────────────
// A device that never uploaded a ROM (it was already on Drive when this
// device got the file) has no sig for it. The listing is then the only
// place it can learn there is a copy to fall back on, or Remove stays
// greyed for good however often the user syncs.

test("a pull records every ROM the listing holds, without downloading one", async () => {
  const app = await loadApp();
  const drive = makeDrive(["rom:A.gba"]);
  app.setFetch(drive.fetch);
  signIn(app); // no sigs at all: this device uploaded nothing
  seedLocal(app, "A.gba");

  await app.api.pullSync({ silent: true });
  await settle();

  assert.ok(app.api.syncState.rmt["rom:A.gba"], "the listing's ROM is recorded");
  eq(Object.keys(app.api.syncState.sigs), [], "and no bytes were hashed");
  assert.ok(!app.fetchCalls.some((c) => /alt=media/.test(String(c.url))),
    "the ROM itself was never downloaded");

  const f = app.api.gameFlags("A.gba", new Set(["A.gba"]), new Set());
  assert.equal(f.romOnDrive, true, "so Remove is offered");
});

test("a pull over a ROM Drive does not hold leaves Remove greyed", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive([]).fetch); // an empty app folder
  signIn(app);
  seedLocal(app, "A.gba");

  await app.api.pullSync({ silent: true });
  await settle();

  assert.equal(app.api.syncState.rmt["rom:A.gba"], undefined);
  assert.equal(app.api.gameFlags("A.gba", new Set(["A.gba"]), new Set()).romOnDrive, false);
});

test("a flush that skips an already-present ROM still records the copy", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba"]).fetch);
  signIn(app);
  seedLocal(app, "A.gba");
  app.api.syncState.queueUp.push("rom:A.gba");

  await app.api.flushSync();
  await settle();

  assert.ok(app.api.syncState.sigs["rom:A.gba"], "recorded");
  // makeDrive gives the first name file id "f0"; the library write is the
  // only other upload, and it is a create, not a write to that id.
  assert.ok(!app.fetchCalls.some((c) => c.url.includes("/f0") && c.method !== "GET"),
    "an immutable ROM already on Drive is still not re-uploaded");
  assert.equal(app.api.gameFlags("A.gba", new Set(["A.gba"]), new Set()).romOnDrive, true);
});

test("a queued delete outranks both records", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba"]).fetch);
  signIn(app, { "rom:A.gba": "sig" });
  seedLocal(app, "A.gba");
  app.api.syncState.rmt["rom:A.gba"] = "2026-01-01T00:00:00Z";
  app.api.syncState.queueDel.push("rom:A.gba");

  assert.equal(app.api.gameFlags("A.gba", new Set(["A.gba"]), new Set()).romOnDrive, false);
});
