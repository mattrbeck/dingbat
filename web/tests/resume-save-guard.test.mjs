// The Resume snapshot carries the cart's battery RAM as it was when taken,
// and restoring it marks that RAM dirty: the next flush writes it over the
// battery save (and Drive mirrors it). So a snapshot is only ever offered
// while the stored save is the one it was taken with. The reported case: save
// in game, go home, tap the same game, accept Resume - the in-game save was
// gone, locally and on Drive.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, settle, gameTiles } from "./helpers.mjs";

const stubModule = (app) => app.runIn(`
  globalThis.__inits = []; globalThis.__loads = 0;
  globalThis.Module = {
    ccall: (fn, ret, types, args) => { __inits.push(args[0]); },
    _wasm_state_size: () => 4,
    _wasm_state_data: () => 8,
    _wasm_load_state: () => { __loads++; return 1; },
    _malloc: () => 8, _free: () => {},
    memory: { buffer: new ArrayBuffer(64) },
  };
`);

const sigOf = (app, bytes) =>
  app.runIn(`saveSignature(new Uint8Array(${JSON.stringify([...bytes])}))`);

const offer = (app) => {
  const pill = app.document.getElementById("toast").children.find((c) =>
    c.classList.contains("has-action") && !c.classList.contains("leaving"));
  return pill || null;
};

const loaded = (app, name, romName) => {
  app.api.currentOriginalName = name;
  app.api.currentRomName = romName;
};

test("a snapshot records the battery save it was taken with", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app, "A.gbc", "rom.gbc");
  app.sandbox.FS.files.set("rom.sav", u8(1, 2, 3));

  await app.runIn("persistAutoState()");
  const auto = app.idb.get("stateauto:A.gbc");
  assert.ok(auto?.bytes, "snapshot stored");
  assert.equal(auto.saveSig, sigOf(app, u8(1, 2, 3)));
});

test("Resume is offered while the save is unchanged, and not after a newer save", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app, "A.gbc", "rom.gbc");

  app.idb.set("save:A.gbc", u8(1, 2, 3));
  app.idb.set("stateauto:A.gbc", { bytes: u8(9, 9), ts: Date.now(), saveSig: sigOf(app, u8(1, 2, 3)) });
  await app.runIn("offerAutoResume()");
  assert.ok(offer(app), "positive control: same save, offer shown");
  app.runIn("toastItems.slice().forEach(dismissToast)");

  // The game saved since the snapshot.
  app.idb.set("save:A.gbc", u8(4, 5, 6));
  await app.runIn("offerAutoResume()");
  assert.equal(offer(app), null, "a snapshot older than the save is never offered");
});

test("a snapshot from before the save was recorded is not offered", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app, "A.gbc", "rom.gbc");
  app.idb.set("save:A.gbc", u8(1, 2, 3));
  app.idb.set("stateauto:A.gbc", { bytes: u8(9, 9), ts: Date.now() });
  await app.runIn("offerAutoResume()");
  assert.equal(offer(app), null);
});

test("tapping Resume after the game has saved restores nothing", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app, "A.gbc", "rom.gbc");
  app.idb.set("save:A.gbc", u8(1, 2, 3));
  app.idb.set("stateauto:A.gbc", { bytes: u8(9, 9), ts: Date.now(), saveSig: sigOf(app, u8(1, 2, 3)) });
  await app.runIn("offerAutoResume()");
  const pill = offer(app);
  assert.ok(pill);

  // saved while the toast was up, and already flushed (the FS .sav is left as
  // the snapshot's, so only the stored save can refuse it)
  app.sandbox.FS.files.set("rom.sav", u8(1, 2, 3));
  app.idb.set("save:A.gbc", u8(4, 5, 6));
  pill.onclick(); // the whole pill is the tap target (pushToast)
  await settle(); await settle();
  assert.equal(app.runIn("__loads"), 0, "the stale state was not applied");
});

test("tapping the loaded game's tile resumes it instead of rebooting", async () => {
  const app = await loadApp();
  stubModule(app);
  app.idb.set("recent", [{ name: "A.gbc", ts: 100 }]);
  app.idb.set("rom:A.gbc", { name: "A.gbc", data: u8(1, 2, 3, 4) });
  loaded(app, "A.gbc", "rom.gbc");
  app.runIn("paused = true");
  await app.api.refreshHomeRecent();
  await settle();

  const tiles = gameTiles(app);
  assert.equal(tiles.length, 1);
  tiles[0].children.find((c) => c.classList.contains("home-tile-launch")).click();
  await settle(); await settle();
  assert.equal(app.runIn("paused"), false, "the game carries on");
  assert.deepEqual([...app.runIn("__inits")], [], "no reboot");
});
