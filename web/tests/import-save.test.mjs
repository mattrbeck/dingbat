// "Import save file": a picked .sav is re-keyed to the loaded game's name,
// the game reloads, Drive is not touched.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, fakeFile } from "./helpers.mjs";

const importSav = async (app, name, bytes) => {
  await app.elements.get("load-save").dispatch("click");
  const input = app.document.body.children.at(-1);
  assert.equal(input.tagName, "INPUT");
  input.files = [fakeFile(name, bytes)];
  await input.dispatch("change");
  await settle(); // FileReader microtask + async callback
  await settle();
};

const bootFakeGame = (app) => {
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "NewName.gba";
  app.runIn("Module.ccall = () => {}"); // stub the wasm core boot
};

test("imported .sav is stored under the LOADED game's name, then the game reloads", async () => {
  const app = await loadApp();
  bootFakeGame(app);
  await importSav(app, "OldName.sav", u8(1, 2, 3));

  assert.equal(app.confirms.length, 2);
  assert.match(app.confirms[1], /doesn't match the name of the current game/);

  eq(app.idb.get("save:NewName.gba"), u8(1, 2, 3));
  assert.equal(app.idb.get("save:OldName.gba"), undefined);
  assert.equal(app.idb.get("save:OldName.sav"), undefined);

  eq(app.sandbox.FS.files.get("rom.sav"), u8(1, 2, 3));

  assert.ok(app.document.body.classList.contains("running"));

  // A Drive copy only updates on the next manual backup.
  assert.equal(app.fetchCalls.filter((c) => c.url.includes("googleapis")).length, 0);
});

test("a matching-name .sav asks only the generic overwrite question", async () => {
  const app = await loadApp();
  bootFakeGame(app);
  await importSav(app, "NewName.sav", u8(9));
  assert.equal(app.confirms.length, 1);
  eq(app.idb.get("save:NewName.gba"), u8(9));
});

test("declining the overwrite prompt imports nothing", async () => {
  const app = await loadApp({ confirmResult: false });
  bootFakeGame(app);
  await importSav(app, "OldName.sav", u8(1));
  assert.equal(app.idb.size, 0);
  assert.equal(app.sandbox.FS.files.size, 0);
});
