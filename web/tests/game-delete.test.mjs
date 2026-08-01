// "Delete everything for this game" — the completeness half of the two
// destructive paths in the Manage ROMs modal.
//
// saves.test.mjs / sync.test.mjs / remove-from-device.test.mjs already pin
// WHICH path does what to Drive. This file pins WHAT is left behind, because
// that is where the bug was: the auto-resume snapshot ("stateauto:<game>") and
// the cheat list ("cheats:<game>") were not in any delete path, so a deleted
// game kept offering "Last session saved 2m ago — Resume" and kept its cheats.
//
// The assertions are deliberately written as "here is every key the app stores;
// after the delete, these exact ones remain" rather than spot-checks of a few
// keys — a new per-game record that nobody taught the delete paths about shows
// up here as residue instead of quietly surviving in production.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, bytesRes, u8, eq, settle } from "./helpers.mjs";

// ── The inventory ───────────────────────────────────────────────────────────

// Every IndexedDB record web/index.js writes that is NOT tied to one game:
// the library index and its sort order, the Drive sync state, the two BIOS
// blobs, the printer gallery, and the settings blobs (SETTINGS_KEYS).
const GLOBAL_KEYS = [
  "recent", "roms_sort", "gdrive_sync", "prints", "bios:gba", "bios:gbc",
  "system", "audio", "colorCorrect", "video", "keybindings", "large-controls",
  "opaque-controls", "control-style", "joystick-mode", "hide-touch-on-gamepad",
  "runahead", "gb-palette",
];

// Every IndexedDB key web/index.js writes FOR one game. Spelled out here rather
// than imported from index.js on purpose: these tests are the independent
// statement of the contract. The "index.js agrees with this list" test below
// ties the two together, so a per-game record added to the app without being
// added here (or vice versa) fails loudly.
const perGameKeys = (n) => [
  "rom:" + n,                 // the ROM image
  "art:" + n,                 // box art pulled out of the zip it arrived in
  "save:" + n,                // battery save
  "save:" + n + "-p2",        // the 2P link partner's battery save
  "stateauto:" + n,           // auto-resume snapshot ("Resume" toast)
  "cheats:" + n,              // this game's cheat list
  // Nine manual save-state slots + their thumbnail/timestamp records. Slot 0
  // is the legacy un-suffixed key pair.
  "state:" + n, "statemeta:" + n,
  ...[1, 2, 3, 4, 5, 6, 7, 8].flatMap((s) =>
    ["state:" + n + ":slot" + s, "statemeta:" + n + ":slot" + s]),
];

// Keys of a game that Drive mirrors — parseDriveFileName recognises these and
// only these, so they are the ones a Delete can queue for remote deletion.
const syncableKeys = (n) =>
  perGameKeys(n).filter((k) =>
    !k.startsWith("art:") && !k.startsWith("stateauto:") && !k.startsWith("cheats:"));

// A plausible stored value for each key shape, so nothing downstream chokes on
// the fixture (statemeta is an object, cheats is text, the rest are bytes).
const seedValue = (key, name) => {
  if (key.startsWith("rom:")) return { name, data: u8(1, 2, 3, 4, 5, 6, 7, 8) };
  if (key.startsWith("statemeta:")) return { thumb: "data:image/png;base64,AA==", ts: 1000 };
  if (key.startsWith("stateauto:")) return { bytes: u8(5, 5, 5, 5), ts: 1000 };
  if (key.startsWith("cheats:")) return "[x] Infinite HP\n01ABCD01\n";
  return u8(7, 7);
};

// One game with EVERY kind of per-game data attached.
const seedGame = (app, name) => {
  for (const k of perGameKeys(name)) app.idb.set(k, seedValue(k, name));
};

// The globals, plus a recents index listing the games given.
const seedGlobals = (app, games) => {
  for (const k of GLOBAL_KEYS) app.idb.set(k, { stub: k });
  app.idb.set("recent", games.map((n, i) => ({ name: n, ts: 10 - i })));
};

const keysLeft = (app) => [...app.idb.keys()].sort();
const sorted = (a) => [...a].sort();

// ── Drive fakes ─────────────────────────────────────────────────────────────

const FILES_URL = "https://www.googleapis.com/drive/v3/files";

// appDataFolder stand-in: lists, downloads, accepts uploads, records deletes.
const makeDrive = (seed = {}) => {
  const byName = new Map();
  let idc = 0;
  for (const [n, b] of Object.entries(seed)) {
    byName.set(n, { id: "f" + idc++, name: n, bytes: b });
  }
  const deleted = [];
  const fetch = async (url, opts = {}) => {
    url = String(url);
    const method = opts.method || "GET";
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [...byName.values()].map((f) => ({
        id: f.id, name: f.name, size: String(f.bytes.length),
        modifiedTime: "2026-01-01T00:00:00Z",
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
      if (ent) { deleted.push(ent[0]); byName.delete(ent[0]); }
      return jsonRes({}, 204);
    }
    return jsonRes({ id: "up" });
  };
  return { byName, deleted, fetch };
};

const signIn = (app, sigs = {}) => {
  app.api.gdriveToken = "test-token";
  app.api.syncState =
    { queueUp: [], queueDel: [], tomb: [], sigs, rmt: {}, connected: true };
};

// ── index.js agrees with the inventory above ────────────────────────────────

test("index.js's perGameKeys is exactly the per-game inventory this file pins", async () => {
  const app = await loadApp();
  // allPerGameKeys is what BOTH destructive paths enumerate from, so this is
  // the join between the app's idea of "everything for one game" and ours.
  eq(sorted(app.runIn("allPerGameKeys('A.gba')")), sorted(perGameKeys("A.gba")));

  // And the groups the two paths differ on are what their comments claim.
  const groups = app.runIn("perGameKeys('A.gba')");
  eq(sorted(groups.bytes), ["art:A.gba", "rom:A.gba"]);
  eq(groups.session, ["stateauto:A.gba"], "the resume snapshot is its own group");
  eq(groups.prefs, ["cheats:A.gba"]);
  eq(sorted(groups.saves), sorted(syncableKeys("A.gba").filter((k) => k !== "rom:A.gba")));
});

// ── Delete ──────────────────────────────────────────────────────────────────

test("Delete leaves nothing at all behind for the game (signed out)", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  seedGlobals(app, ["A.gba", "B.gb"]);
  seedGame(app, "A.gba");
  seedGame(app, "B.gb"); // bystander: must survive untouched

  await app.api.deleteGameEverywhere("A.gba");
  await settle();

  eq(keysLeft(app), sorted([...GLOBAL_KEYS, ...perGameKeys("B.gb")]),
    "every record keyed to A.gba is gone, and only those");
  eq((app.idb.get("recent") || []).map((r) => r.name), ["B.gb"],
    "and its library entry with them");
  for (const k of perGameKeys("B.gb")) {
    assert.ok(app.idb.get(k), "the other game's " + k + " survived");
  }
});

test("Delete takes the resume snapshot and the cheats — the reported bug", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  seedGlobals(app, ["A.gba"]);
  seedGame(app, "A.gba");

  await app.api.deleteGameEverywhere("A.gba");
  await settle();
  assert.equal(app.idb.get("stateauto:A.gba"), undefined,
    'no "Last session saved … Resume" data left');
  assert.equal(app.idb.get("cheats:A.gba"), undefined, "no cheats left");
});

test("a deleted game offers no Resume, no cheats, and no save states", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  seedGlobals(app, ["A.gba"]);
  seedGame(app, "A.gba");
  app.api.currentOriginalName = "A.gba";

  // #toast is a stack of .toast-item pills; an "offer" is one carrying a
  // tappable action, and .leaving ones are already retired (mid-fade).
  const toast = app.document.getElementById("toast");
  const offer = () => {
    const pill = toast.children.find((c) =>
      c.classList.contains("has-action") && !c.classList.contains("leaving"));
    return pill ? pill.children.map((c) => c.textContent).join(" ") : null;
  };
  // Retire the whole stack through the app's own path, as its timers would.
  const clearToast = () => app.runIn("toastItems.slice().forEach(dismissToast)");

  // Positive control: with the game's data present, all three fire.
  await app.runIn("offerAutoResume()");
  assert.match(offer() || "", /Resume/, "the Resume offer appears while the data exists");
  await app.api.restoreCheats();
  assert.equal(app.api.cheatList.length, 1, "the cheat is loaded");
  await app.runIn("renderStatesGrid()");
  eq(app.runIn("slotHasState"), new Array(9).fill(true), "all nine slots list");

  clearToast();
  await app.api.deleteGameEverywhere("A.gba");
  await settle();

  // The game is gone but still "loaded" — the harshest case, since every one
  // of these reads keys off currentOriginalName.
  await app.runIn("offerAutoResume()");
  assert.equal(offer(), null, "no Resume offer for a deleted game");
  await app.api.restoreCheats();
  eq(app.api.cheatList, [], "no cheats to apply");
  await app.runIn("renderStatesGrid()");
  eq(app.runIn("slotHasState"), new Array(9).fill(false), "no save states to list");
});

test("Delete mirrors to Drive: every synced key queued, tombstone raised", async () => {
  const app = await loadApp();
  const drive = makeDrive();
  app.setFetch(drive.fetch);
  signIn(app);
  seedGlobals(app, ["A.gba"]);
  seedGame(app, "A.gba");

  await app.api.deleteGameEverywhere("A.gba");
  await settle();

  eq(sorted(app.api.syncState.queueDel), sorted(syncableKeys("A.gba")),
    "exactly the keys Drive holds are queued for remote deletion");
  // The local-only three must NOT be queued — markDelete drops them anyway,
  // but a queue entry Drive can never satisfy would sit there forever.
  for (const k of ["art:A.gba", "stateauto:A.gba", "cheats:A.gba"]) {
    assert.ok(!app.api.syncState.queueDel.includes(k), k + " is not a Drive file");
  }
  eq(app.api.syncState.tomb.map((t) => t.name), ["A.gba"],
    "and the tombstone tells the other devices to drop it too");
  eq(keysLeft(app), sorted(GLOBAL_KEYS), "locally, nothing of A.gba is left");
});

test("a game deleted on another device is wiped just as completely here", async () => {
  const app = await loadApp();
  // Drive says A.gba was deleted (tombstone newer than our recents entry).
  const drive = makeDrive({
    library: new TextEncoder().encode(JSON.stringify({
      recents: [{ name: "B.gb", ts: 9 }],
      tomb: [{ name: "A.gba", ts: 1e12 }],
    })),
  });
  app.setFetch(drive.fetch);
  signIn(app);
  seedGlobals(app, ["A.gba", "B.gb"]);
  seedGame(app, "A.gba");
  seedGame(app, "B.gb");

  const pull = app.api.pullSync({ silent: true });
  // The "Games removed on another device" modal defaults to Continue (drop
  // the local copies) when dismissed.
  for (let i = 0; i < 50; i++) {
    if (app.document.body.children.some(
      (c) => String(c.className).includes("sync-modal"))) break;
    await settle();
  }
  await app.dispatchDoc("keydown", { key: "Escape" });
  await pull;
  await settle();

  for (const k of perGameKeys("A.gba")) {
    assert.equal(app.idb.get(k), undefined,
      k + " survived a tombstone — the pull path must wipe what Delete wipes");
  }
  for (const k of perGameKeys("B.gb")) {
    assert.ok(app.idb.get(k), "the game that was not deleted kept its " + k);
  }
});

// ── Remove from device ──────────────────────────────────────────────────────
//
// A DIFFERENT operation: free this device's copy, leave the Drive library
// alone so one tap brings the game back. It must therefore keep everything
// irreplaceable, and must not touch Drive at all.

test("Remove from device frees the ROM-shaped data and keeps every save", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "rom:A.gba": u8(1, 2, 3), "save:A.gba": u8(7, 7) });
  app.setFetch(drive.fetch);
  signIn(app, { "rom:A.gba": "sig" });
  seedGlobals(app, ["A.gba", "B.gb"]);
  seedGame(app, "A.gba");
  seedGame(app, "B.gb");

  assert.equal(await app.api.removeGameFromDevice("A.gba"), true);
  await settle();

  // Gone: the ROM bytes, the art that only decorates them, and the resume
  // snapshot of a game this device can no longer launch.
  const freed = ["rom:A.gba", "art:A.gba", "stateauto:A.gba"];
  const kept = perGameKeys("A.gba").filter((k) => !freed.includes(k));
  eq(keysLeft(app),
    sorted([...GLOBAL_KEYS, ...kept, ...perGameKeys("B.gb")]),
    "exactly the re-downloadable bulk is freed; everything else stays");
  for (const k of kept) assert.ok(app.idb.get(k), k + " must survive a local eviction");
  assert.ok(app.idb.get("cheats:A.gba"),
    "cheats are bytes and are not on Drive — evicting them could only lose work");
});

test("Remove from device leaves the Drive side completely intact", async () => {
  const app = await loadApp();
  const drive = makeDrive({ "rom:A.gba": u8(1, 2, 3), "save:A.gba": u8(7, 7),
    "state:A.gba": u8(6) });
  app.setFetch(drive.fetch);
  signIn(app, { "rom:A.gba": "sig" });
  seedGlobals(app, ["A.gba"]);
  seedGame(app, "A.gba");

  await app.api.removeGameFromDevice("A.gba");
  await settle();

  eq(drive.deleted, [], "nothing was deleted from Drive");
  eq(sorted(drive.byName.keys()), sorted(["rom:A.gba", "save:A.gba", "state:A.gba"]),
    "the cloud copy is exactly as it was — this is what makes the game come back");
  eq(app.api.syncState.tomb, [], "no tombstone: the other devices keep the game");
  eq(app.api.syncState.queueDel, [], "and nothing is queued to delete remotely");
  eq((app.idb.get("recent") || []).map((r) => r.name), ["A.gba"],
    "the library entry stays, so the game still has a (Drive-only) tile");
  // The saves that stayed behind are pushed up, so the local copy is also a
  // backed-up copy.
  for (const k of ["save:A.gba", "save:A.gba-p2", "state:A.gba"]) {
    assert.ok(app.api.syncState.queueUp.includes(k), k + " queued for backup");
  }
  assert.ok(!app.api.syncState.queueUp.includes("rom:A.gba"),
    "the ROM we just freed is not re-queued");
});

// ── Cleanup for snapshots older builds already orphaned ─────────────────────

test("orphaned resume snapshots are swept, live ones are not", async () => {
  const app = await loadApp();
  app.idb.set("recent", [{ name: "Cloud.gba", ts: 2 }]);   // Drive-only tile
  app.idb.set("rom:Here.gb", { name: "Here.gb", data: u8(1) }); // stored, not in recents
  for (const n of ["Cloud.gba", "Here.gb", "Deleted.gba"]) {
    app.idb.set("stateauto:" + n, { bytes: u8(1), ts: 5 });
  }
  app.idb.set("cheats:Deleted.gba", "[x] c\n01ABCD01\n");

  await app.runIn("sweepOrphanedAutoStates()");
  await settle();

  assert.equal(app.idb.get("stateauto:Deleted.gba"), undefined,
    "a snapshot for a game that is neither stored nor in the library is dead");
  assert.ok(app.idb.get("stateauto:Cloud.gba"),
    "a Drive-only game has no rom: record but is still launchable");
  assert.ok(app.idb.get("stateauto:Here.gb"), "and neither is a stored ROM touched");
  assert.ok(app.idb.get("cheats:Deleted.gba"),
    "cheats the user typed are kept even when orphaned — the sweep is snapshots only");
});

// ── Reset (the third, non-destructive-to-the-ROM path) ──────────────────────

test("Reset drops the resume snapshot with the saves it duplicates", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  seedGlobals(app, ["A.gba"]);
  seedGame(app, "A.gba");

  await app.api.resetGameSaves("A.gba");
  await settle();

  assert.equal(app.idb.get("stateauto:A.gba"), undefined,
    'otherwise "Save reset — starting fresh" is followed by an offer to un-reset it');
  assert.ok(app.idb.get("rom:A.gba"), "the ROM stays — Reset is not a delete");
  assert.ok(app.idb.get("cheats:A.gba"), "and so do the cheats");
  for (const k of syncableKeys("A.gba").filter((k) => k !== "rom:A.gba")) {
    assert.equal(app.idb.get(k), undefined, k + " is save data and should be gone");
  }
});
