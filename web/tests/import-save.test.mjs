// The Manage Saves "Import save file" flow, driven through the real DOM event
// handlers: a picked .sav is re-keyed to the LOADED game's original name
// (whatever the .sav file was called), and the game is reloaded. Drive is not
// touched.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, fakeFile } from "./helpers.mjs";

// Drive the pickFile flow: click #load-save, then feed the created
// <input type=file> a fake file.
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

  // Both overwrite prompts fired (generic + name-mismatch warning)
  assert.equal(app.confirms.length, 2);
  assert.match(app.confirms[1], /doesn't match the name of the current game/);

  // Renamed: keyed to the running game, nothing under the .sav's own name
  eq(app.idb.get("save:NewName.gba"), u8(1, 2, 3));
  assert.equal(app.idb.get("save:OldName.gba"), undefined);
  assert.equal(app.idb.get("save:OldName.sav"), undefined);

  // The FS save the reloaded core reads was replaced too
  eq(app.sandbox.FS.files.get("rom.sav"), u8(1, 2, 3));

  // loadRom ran (game reloads immediately)
  assert.ok(app.document.body.classList.contains("running"));

  // No Drive traffic — a Drive copy only updates on the next manual backup
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
