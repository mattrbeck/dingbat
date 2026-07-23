// Recent-ROM library: add/evict/delete against the real addRecentRom /
// bumpRecentIndex / deleteRecent / getRomBytes from web/index.js.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, fakeFile } from "./helpers.mjs";

test("addRecentRom stores rom:, art: and the metadata index", async () => {
  const app = await loadApp();
  const art = { fake: "blob" };
  await app.api.addRecentRom("A.gba", u8(1, 2, 3), art);
  await settle();

  eq(app.idb.get("rom:A.gba"), { name: "A.gba", data: u8(1, 2, 3) });
  eq(app.idb.get("art:A.gba"), art);
  eq(app.idb.get("recent").map((r) => r.name), ["A.gba"]);
  eq(await app.api.getRomBytes("A.gba"), u8(1, 2, 3));

  // Home grid unhides without a reload
  assert.equal(app.elements.get("home-recent-wrap").hidden, false);
});

test("re-adding an existing name moves it to the front, no duplicate", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("A.gba", u8(1));
  await app.api.addRecentRom("B.gba", u8(2));
  await app.api.addRecentRom("A.gba", u8(1));
  eq(app.idb.get("recent").map((r) => r.name), ["A.gba", "B.gba"]);
});

test("21st ROM evicts the oldest rom:+art: records but keeps its saves", async () => {
  const app = await loadApp();
  assert.equal(app.api.MAX_RECENT, 20);
  app.idb.set("save:Game0.gba", u8(9, 9));
  app.idb.set("state:Game0.gba", u8(8));
  for (let i = 0; i <= 20; i++) {
    await app.api.addRecentRom(`Game${i}.gba`, u8(i), { art: i });
  }
  const names = app.idb.get("recent").map((r) => r.name);
  assert.equal(names.length, 20);
  assert.ok(!names.includes("Game0.gba"), "oldest entry evicted from index");
  assert.equal(app.idb.get("rom:Game0.gba"), undefined, "evicted ROM bytes deleted");
  assert.equal(app.idb.get("art:Game0.gba"), undefined, "evicted art deleted");
  eq(app.idb.get("save:Game0.gba"), u8(9, 9), "save survives eviction");
  eq(app.idb.get("state:Game0.gba"), u8(8), "state survives eviction");

  // The evicted game is still reachable through the manage list as an orphan
  const rows = await app.api.romsForManagement();
  const orphan = rows.find((r) => r.name === "Game0.gba");
  assert.ok(orphan && orphan.inRecent === false);
});

test("deleteRecent removes index + rom + art but never save data", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("A.gba", u8(1), { a: 1 });
  app.idb.set("save:A.gba", u8(5));
  await app.api.deleteRecent("A.gba");
  await settle();
  eq(app.idb.get("recent"), []);
  assert.equal(app.idb.get("rom:A.gba"), undefined);
  assert.equal(app.idb.get("art:A.gba"), undefined);
  eq(app.idb.get("save:A.gba"), u8(5));
  // An empty library keeps the section visible (empty-state card, which hosts
  // the Drive sign-in entry point) but drops the "Recent"/Manage header.
  await settle();
  assert.equal(app.elements.get("home-recent-wrap").hidden, false);
  assert.equal(app.elements.get("home-recent-head").hidden, true);
});

test("X.gb and X.gbc key separately everywhere (full-name keying)", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("X.gb", u8(1));
  await app.api.addRecentRom("X.gbc", u8(2));
  eq(app.idb.get("rom:X.gb").data, u8(1));
  eq(app.idb.get("rom:X.gbc").data, u8(2));

  app.idb.set("save:X.gb", u8(11));
  app.idb.set("save:X.gbc", u8(22));
  eq(await app.api.romsWithSaveData(), ["X.gb", "X.gbc"]);
  await app.api.deleteSaveData("X.gb");
  assert.equal(app.idb.get("save:X.gb"), undefined);
  eq(app.idb.get("save:X.gbc"), u8(22), "sibling extension untouched");
});

test("getRomBytes returns null for missing or empty records", async () => {
  const app = await loadApp();
  assert.equal(await app.api.getRomBytes("Nope.gba"), null);
  app.idb.set("rom:Empty.gba", { name: "Empty.gba", data: u8() });
  assert.equal(await app.api.getRomBytes("Empty.gba"), null);
  // ArrayBuffer-stored data is converted
  app.idb.set("rom:Buf.gba", { name: "Buf.gba", data: u8(1, 2).buffer });
  eq(await app.api.getRomBytes("Buf.gba"), u8(1, 2));
});

test("handleRomFile rejects .sav/.state files — no path stores a mismatched-name save", async () => {
  const app = await loadApp();
  app.api.handleRomFile(fakeFile("OldName.sav", u8(1, 2)));
  app.api.handleRomFile(fakeFile("OldName.state", u8(1, 2)));
  await settle();
  assert.equal(app.alerts.length, 2);
  assert.match(app.alerts[0], /Unsupported file/);
  assert.equal(app.idb.size, 0, "nothing stored");
});

test("handleRomFile stores an accepted ROM under its full original file name", async () => {
  const app = await loadApp();
  app.runIn("Module.ccall = () => {}"); // stub the wasm boot
  app.api.handleRomFile(fakeFile("Some Game (U).gba", u8(1, 2, 3)));
  await settle();
  await settle();
  eq(app.idb.get("rom:Some Game (U).gba"), { name: "Some Game (U).gba", data: u8(1, 2, 3) });
  eq(app.idb.get("recent").map((r) => r.name), ["Some Game (U).gba"]);
});
