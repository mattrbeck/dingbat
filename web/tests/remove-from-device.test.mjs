// "Remove from this device" (web/index.js removeGameFromDevice + the Manage
// ROMs row that offers it). The inverse of downloadGame: it frees this
// device's ROM bytes and nothing else — no tombstone, no Drive delete, and
// the save data stays put.
//
// The interesting half is the guard. Removing local bytes for a game that
// isn't actually on Drive would destroy the user's only copy, so this file
// pins down both layers of it: the button doesn't render unless this device
// has a record of the ROM being on Drive, and the action itself re-checks the
// live listing before deleting anything.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, eq, settle } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";

// Minimal appDataFolder: a listing plus alt=media downloads. Uploads and
// deletes are accepted so the assertions below can count them.
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
    { queueUp: [], queueDel: [], tomb: [], sigs, rmt: {}, connected: true };
};

// One local game: ROM bytes, box art, a battery save and a save state.
const seedLocal = (app, name, romBytes = u8(1, 2, 3, 4, 5, 6, 7, 8)) => {
  app.idb.set("recent", [{ name, ts: 100 }]);
  app.idb.set("rom:" + name, { name, data: romBytes });
  app.idb.set("art:" + name, u8(9, 9));
  app.idb.set("save:" + name, u8(7));
  app.idb.set("state:" + name, u8(6));
};

// navigator.storage.estimate() is a fixed number in the harness; make it
// report the fake IndexedDB's real byte weight so "did the storage figure
// drop?" is an honest question.
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
    return { usage };
  };
};

// The manage list's sort control lives in a wrapper the row code hides for
// short lists; the fake DOM has no parent links, so supply one.
const openManageList = async (app) => {
  app.document.getElementById("roms-sort").parentElement = { hidden: false };
  await app.api.refreshRomsManageList();
  await settle();
};

// Labels of the buttons on the row for `name`, in render order.
const rowButtons = (app, name) => {
  const list = app.document.getElementById("roms-manage-list");
  for (const row of list.children) {
    const [label, actions] = row.children;
    if (label.title === name) return actions.children.map((b) => b.textContent);
  }
  return null;
};

const rowButton = (app, name, text) => {
  const list = app.document.getElementById("roms-manage-list");
  for (const row of list.children) {
    if (row.children[0].title !== name) continue;
    return row.children[1].children.find((b) => b.textContent === text) || null;
  }
  return null;
};

// ── The action ──────────────────────────────────────────────────────────────

test("removeGameFromDevice frees the ROM and art, and nothing else", async () => {
  const app = await loadApp();
  const drive = makeDrive(["rom:A.gba", "save:A.gba"]);
  app.setFetch(drive.fetch);
  signIn(app, { "rom:A.gba": "sig" });
  seedLocal(app, "A.gba");

  assert.equal(await app.api.removeGameFromDevice("A.gba"), true);
  await settle();

  assert.equal(app.idb.get("rom:A.gba"), undefined, "ROM bytes freed");
  assert.equal(app.idb.get("art:A.gba"), undefined, "box art freed too");
  // The whole point: this is a local eviction, not a deletion.
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

test("the storage figure reflects the reclaim", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba"]).fetch);
  signIn(app, { "rom:A.gba": "sig" });
  seedLocal(app, "A.gba", new Uint8Array(64 * 1024));
  meterStorage(app);

  const before = (await app.sandbox.navigator.storage.estimate()).usage;
  await app.api.removeGameFromDevice("A.gba");
  await settle();
  const after = (await app.sandbox.navigator.storage.estimate()).usage;
  assert.ok(after < before - 60000,
    `the ROM's bytes must actually be gone (${before} -> ${after})`);

  // And the label the user reads is refreshed from that estimate.
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(app.document.getElementById("storage-info").textContent,
    app.api.formatBytes(after) + " used");
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

  // Watch every commit: the grid must go straight from the old tiles to the
  // new ones. An empty moment collapses #home's scrollHeight and throws the
  // user back to the top of their library.
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
  // Same shape as a never-downloaded game: a download glyph, no 2P button.
  const controls = grid.children[0].children.map((c) => c.className);
  assert.ok(controls.some((c) => c.includes("home-tile-dl")), "download glyph");
  assert.ok(!controls.some((c) => c.includes("home-tile-link")), "no 2P button");
});

// ── The guard: never take the last copy ─────────────────────────────────────

test("a game Drive does not hold is kept and queued instead of removed", async () => {
  const app = await loadApp();
  // sigs claims the ROM was uploaded, but the listing disagrees — exactly what
  // a wiped app folder or a different signed-in Google account looks like.
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

test("Remove is offered only for a local game Drive already has", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:Backed.gba"]).fetch);
  // Backed.gba: local + a sig  -> removable.
  // Fresh.gba:  local, upload still queued (no sig) -> NOT removable.
  // Cloud.gba:  on Drive only, no local bytes -> nothing to remove.
  signIn(app, { "rom:Backed.gba": "sig" });
  app.api.syncState.queueUp.push("rom:Fresh.gba");
  app.idb.set("recent", [
    { name: "Backed.gba", ts: 3 },
    { name: "Fresh.gba", ts: 2 },
    { name: "Cloud.gba", ts: 1 },
  ]);
  app.idb.set("rom:Backed.gba", { name: "Backed.gba", data: u8(1) });
  app.idb.set("rom:Fresh.gba", { name: "Fresh.gba", data: u8(2) });

  await openManageList(app);
  eq(rowButtons(app, "Backed.gba"), ["Reset", "Remove from device", "Delete"]);
  eq(rowButtons(app, "Fresh.gba"), ["Reset", "Delete"],
    "a game whose only copy is still local must not be evictable");
  eq(rowButtons(app, "Cloud.gba"), ["Delete"],
    "a Drive-only row has no local bytes to free");
});

test("a Drive delete already queued for the ROM withdraws Remove", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive([]).fetch);
  signIn(app, { "rom:A.gba": "sig" });
  app.api.syncState.queueDel.push("rom:A.gba");
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1) });

  await openManageList(app);
  eq(rowButtons(app, "A.gba"), ["Reset", "Delete"]);
});

test("signed out, no row offers Remove", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  app.api.syncState =
    { queueUp: [], queueDel: [], tomb: [], sigs: { "rom:A.gba": "sig" }, rmt: {} };
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1) });

  await openManageList(app);
  eq(rowButtons(app, "A.gba"), ["Reset", "Delete"],
    "with no Drive to come back from, removing local bytes is just deleting");
  assert.equal(app.document.getElementById("roms-hint-remove").hidden, true,
    "the intro must not describe a Remove button that isn't there");
});

test("the intro's Remove sentence shows only while signed in", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba"]).fetch);
  signIn(app, { "rom:A.gba": "sig" });
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1) });

  await openManageList(app);
  assert.equal(app.document.getElementById("roms-hint-remove").hidden, false);
});

test("Sign out while the modal is open withdraws Remove from the rows", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba"]).fetch);
  signIn(app, { "rom:A.gba": "sig" });
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1) });

  // The modal is open (openManageList renders what openRomsModal would).
  app.document.getElementById("roms-modal").classList.add("open");
  await openManageList(app);
  eq(rowButtons(app, "A.gba"), ["Reset", "Remove from device", "Delete"]);

  app.runIn("gdriveSignOut()");
  await settle();
  await settle();
  eq(rowButtons(app, "A.gba"), ["Reset", "Delete"],
    "the stale Remove button is withdrawn without reopening the modal");
  assert.equal(app.document.getElementById("roms-hint-remove").hidden, true,
    "and the intro stops describing it");
});

test("the game currently loaded shows Remove disabled, not armed", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba"]).fetch);
  signIn(app, { "rom:A.gba": "sig" });
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(1) });
  app.api.currentOriginalName = "A.gba";

  await openManageList(app);
  const btn = rowButton(app, "A.gba", "Remove from device");
  assert.ok(btn, "the row still shows the action");
  assert.equal(btn.disabled, true, "but it can't be used on the running game");
});

// ── End to end through the button ───────────────────────────────────────────

test("two taps on Remove free the ROM; one tap only arms it", async () => {
  const app = await loadApp();
  app.setFetch(makeDrive(["rom:A.gba"]).fetch);
  signIn(app, { "rom:A.gba": "sig" });
  seedLocal(app, "A.gba");

  await openManageList(app);
  const btn = rowButton(app, "A.gba", "Remove from device");
  assert.ok(btn);

  await btn.click(); // arm
  await settle();
  assert.equal(btn.textContent, "Remove from this device?",
    "the confirm step says which device, so it can't be read as Delete");
  assert.ok(app.idb.get("rom:A.gba"), "arming alone removes nothing");

  await btn.click(); // confirm
  await settle();
  assert.equal(app.idb.get("rom:A.gba"), undefined, "ROM freed");
  eq(app.idb.get("save:A.gba"), u8(7), "save kept");
  assert.ok(app.toasts.some((t) => /save kept/i.test(t)),
    "the toast says the save survived: " + app.toasts.join(" | "));
  // The row re-renders without Remove — there is nothing local left to free.
  eq(rowButtons(app, "A.gba"), ["Reset", "Delete"]);
});
