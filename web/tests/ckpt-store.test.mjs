// storeCheckpoint re-checks that its moment is still current after storing
// the battery it carries (formal/WebState/SavePersistence.lean,
// bug_ckpt_store_*).
//
// Checkpoints: the session taken every minute of play, so a browser that
// crashes with the game on screen resumes about where it stopped, and the
// earlier moments kept for when the newest one is what crashes. The
// reported case: FireRed on an Android phone, a long session with no
// in-game save, the browser crashed, and the relaunch did not pick up where
// it left off - the session was only ever taken when the page was hidden.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, settle } from "./helpers.mjs";

const MIN = 60 * 1000;

// A core whose state image is 64 bytes, packed as itself (no worker here:
// the page path, wasm_pack_state, runs).
const stubModule = (app) => app.runIn(`
  globalThis.__forced = []; globalThis.__inits = [];
  globalThis.Module = {
    ccall: (fn, ret, types, args) => { __inits.push(args[0]); },
    _wasm_state_plain_size: () => 64,
    _wasm_state_size: () => 64,
    _wasm_state_data: () => 8,
    _wasm_pack_state: (ptr, len) => len,
    _wasm_load_state: () => { __loads = (globalThis.__loads || 0) + 1; return 1; },
    _wasm_flush_save: () => {},
    _malloc: () => 8, _free: () => {},
    memory: { buffer: new ArrayBuffer(256) },
  };
`);

const loaded = (app, name = "A.gba", romName = "rom.gba") => {
  app.api.currentOriginalName = name;
  app.api.currentRomName = romName;
};

const sigOf = (app, bytes) =>
  app.runIn(`saveSignature(new Uint8Array(${JSON.stringify([...bytes])}))`);

// Play `ms` and take the checkpoint that falls due.
const playAndCheckpoint = async (app, ms) => {
  app.runIn(`runPlayMs += ${ms}`);
  await app.runIn("takeCheckpoint()");
  await settle();
};

const hold = (app, op, key) => {
  const db = app.runIn("db");
  const realTx = db.transaction;
  const held = [];
  db.transaction = (...a) => {
    const tx = realTx(...a);
    const os = tx.objectStore;
    tx.objectStore = (...b) => {
      const store = os(...b);
      const real = store[op];
      store[op] = (...args) => {
        if ((op === "put" ? args[1] : args[0]) !== key) return real(...args);
        const r = {};
        held.push(() => {
          const inner = real(...args);
          inner.onsuccess = () => { r.result = inner.result; r.onsuccess?.(); };
          inner.onerror = () => { r.error = inner.error; r.onerror?.(); };
        });
        return r;
      };
      return store;
    };
    return tx;
  };
  return {
    get count() { return held.length; },
    release: () => { db.transaction = realTx; for (const f of held.splice(0)) f(); },
  };
};
const parked = async (gate) => {
  for (let i = 0; i < 80 && !gate.count; i++) await settle();
  assert.equal(gate.count, 1, "parked");
};

test("a session written while a checkpoint stores its battery is not written over (bug_ckpt_store_over_newer_session)", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app);
  app.sandbox.FS.files.set("rom.sav", u8(1, 2, 3));   // a battery not yet stored
  const gate = hold(app, "put", "save:A.gba");
  app.runIn("runPlayMs = 61 * 1000");
  const late = app.runIn("takeCheckpoint()");
  await parked(gate);                                  // storeCheckpoint awaits persistSave
  app.runIn("sessionMoved = true");
  await app.runIn("persistAutoState()");               // Main Menu / hide: the newer session
  const newer = app.idb.get("stateauto:A.gba").ts;
  gate.release();
  await late;
  for (let i = 0; i < 10; i++) await settle();
  assert.equal(app.idb.get("stateauto:A.gba").ts, newer, "the newer session stands");
});

test("a reset while a checkpoint stores its battery is not undone by it (bug_ckpt_store_undoes_session_reset)", async () => {
  const app = await loadApp();
  stubModule(app);
  loaded(app);
  app.sandbox.FS.files.set("rom.sav", u8(1, 2, 3));
  const gate = hold(app, "put", "save:A.gba");
  app.runIn("runPlayMs = 61 * 1000");
  const late = app.runIn("takeCheckpoint()");
  await parked(gate);
  await app.runIn("deleteKeys([autoStateKey('A.gba'), ...ckptKeys('A.gba')])");
  gate.release();
  await late;
  for (let i = 0; i < 10; i++) await settle();
  assert.equal(app.idb.get("stateauto:A.gba"), undefined, "the session stays deleted");
  assert.equal(app.idb.get("ckpts:A.gba"), undefined);
});
