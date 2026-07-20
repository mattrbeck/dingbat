// Save-data identity and deletion: the real romsWithSaveData / deleteSaveData /
// romsForManagement / linkSaveKey / key helpers from web/index.js.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq } from "./helpers.mjs";

test("key helpers use the full original name (extension included)", async () => {
  const { api } = await loadApp();
  assert.equal(api.romKey("X.gba"), "rom:X.gba");
  assert.equal(api.artKey("X.gba"), "art:X.gba");
  assert.equal(api.stateKey("X.gba"), "state:X.gba");
  assert.equal(api.linkSaveKey("X.gba", 0), "save:X.gba");
  assert.equal(api.linkSaveKey("X.gba", 1), "save:X.gba-p2");
  assert.equal(api.stripExt("X.gba"), "X");
});

test("romsWithSaveData folds -p2 saves and includes state-only games", async () => {
  const app = await loadApp();
  app.idb.set("save:A.gba", u8(1));
  app.idb.set("save:A.gba-p2", u8(2));      // folds into A.gba
  app.idb.set("save:B.gb-p2", u8(3));       // P2-only still surfaces B.gb
  app.idb.set("state:C.gbc", u8(4));        // state-only game
  app.idb.set("rom:D.gba", { name: "D.gba", data: u8(5) }); // rom-only: no save data
  app.idb.set("recent", []);
  eq(await app.api.romsWithSaveData(), ["A.gba", "B.gb", "C.gbc"]);
});

test("deleteSaveData wipes save, -p2 save, and state", async () => {
  const app = await loadApp();
  app.idb.set("save:A.gba", u8(1));
  app.idb.set("save:A.gba-p2", u8(2));
  app.idb.set("state:A.gba", u8(3));
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(9) });
  await app.api.deleteSaveData("A.gba");
  assert.equal(app.idb.get("save:A.gba"), undefined);
  assert.equal(app.idb.get("save:A.gba-p2"), undefined);
  assert.equal(app.idb.get("state:A.gba"), undefined);
  assert.ok(app.idb.get("rom:A.gba"), "ROM record untouched");
});

test("romsForManagement lists recents first (recency order), then orphans by name", async () => {
  const app = await loadApp();
  app.idb.set("recent", [
    { name: "New.gba", ts: 3 },
    { name: "Old.gba", ts: 1 },
  ]);
  app.idb.set("save:Old.gba", u8(1));         // in recents AND has a save
  app.idb.set("save:Zebra.gb", u8(2));        // orphan
  app.idb.set("state:Alpha.gbc", u8(3));      // orphan, state-only
  eq(await app.api.romsForManagement(), [
    { name: "New.gba", inRecent: true },
    { name: "Old.gba", inRecent: true },
    { name: "Alpha.gbc", inRecent: false },
    { name: "Zebra.gb", inRecent: false },
  ]);
});

test("isRomLoaded matches the single-player game and the link-mode ROM", async () => {
  const app = await loadApp();
  assert.equal(app.api.isRomLoaded("A.gba"), false);
  app.api.currentOriginalName = "A.gba";
  assert.equal(app.api.isRomLoaded("A.gba"), true);
  assert.equal(app.api.isRomLoaded("B.gba"), false);
  app.api.currentOriginalName = null;
  app.api.linkMode = true;
  app.runIn('linkRomEntry = { name: "L.gba" }');
  assert.equal(app.api.isRomLoaded("L.gba"), true);
  app.api.linkMode = false;
  assert.equal(app.api.isRomLoaded("L.gba"), false);
});

test("persistSave/restoreSave round-trip through the save: key", async () => {
  const app = await loadApp();
  app.sandbox.FS.files.set("rom.sav", u8(7, 7, 7));
  await app.api.persistSave("rom.gba", "Original Name.gba");
  eq(app.idb.get("save:Original Name.gba"), u8(7, 7, 7));

  app.sandbox.FS.files.delete("rom.sav");
  await app.api.restoreSave("rom.gba", "Original Name.gba");
  eq(app.sandbox.FS.files.get("rom.sav"), u8(7, 7, 7));
});

test("persistSave skips empty or missing FS saves", async () => {
  const app = await loadApp();
  await app.api.persistSave("rom.gba", "A.gba"); // no FS file
  assert.equal(app.idb.get("save:A.gba"), undefined);
  app.sandbox.FS.files.set("rom.sav", u8());
  await app.api.persistSave("rom.gba", "A.gba"); // empty FS file
  assert.equal(app.idb.get("save:A.gba"), undefined);
});

test("persistSave skips the IndexedDB write when the save is unchanged", async () => {
  const app = await loadApp();
  app.sandbox.FS.files.set("rom.sav", u8(1, 2, 3));
  await app.api.persistSave("rom.gba", "A.gba");
  eq(app.idb.get("save:A.gba"), u8(1, 2, 3));

  // Tamper with the stored copy out of band: an unchanged FS save must NOT
  // rewrite it (the dirty-check skips the clone + IDB write), so the tampered
  // value survives.
  app.idb.set("save:A.gba", u8(9, 9, 9));
  await app.api.persistSave("rom.gba", "A.gba");
  eq(app.idb.get("save:A.gba"), u8(9, 9, 9));

  // A real change to the FS save is persisted again.
  app.sandbox.FS.files.set("rom.sav", u8(1, 2, 4));
  await app.api.persistSave("rom.gba", "A.gba");
  eq(app.idb.get("save:A.gba"), u8(1, 2, 4));

  // A different game (different key) always writes the first time.
  await app.api.persistSave("rom.gba", "B.gba");
  eq(app.idb.get("save:B.gba"), u8(1, 2, 4));
});
