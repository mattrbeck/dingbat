// dbPutRoomy's retry after other games' checkpoints made room: it must ask
// whether the save was superseded, as it does after a ROM gave way
// (formal/WebState/SavePersistence.lean, bug_ckpt_evict_retry_*).
//
// Loading, switching and closing games, against a stand-in core that does
// what the real one does with the emulator filesystem: it reads its ROM and
// its battery file when it is built, and it writes its battery file whenever
// the game saves. Every solo game is the FS file "rom.<ext>", so every solo
// game's battery file is the one "rom.sav"; what these tests guard is that a
// game only ever boots on, and only ever persists, its own save.
//
// Each trace is a counterexample found by the Lean models in formal/WebState/
// (named at each section), replayed through the real web/index.js. `hold`
// parks a flow at one of its awaits, so each interleaving is the one the
// model found, not whatever the fake IndexedDB's microtask order happens to be.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp, jsonRes, bytesRes, u8, eq, settle, gameTiles } from "./helpers.mjs";

// A ROM is [id, ...]; a battery save is [id of the game that wrote it, n].
const ROM = { "A.gba": 0x0a, "B.gba": 0x0b, "C.gba": 0x0c };

const boot = async ({ games = ["A.gba", "B.gba", "C.gba"] } = {}) => {
  const app = await loadApp();
  app.runIn(`
    globalThis.core = { rom: 0, ram: null, inits: [], applied: 0 };
    globalThis.__shut = [];
    globalThis.netMode = false;
    Object.assign(Module, {
      ccall: (fn, ret, types, args) => {
        if (fn !== "initFromEmscripten") return 0;
        const rom = FS.files.get(args[0]);
        const sav = FS.files.get(args[0].slice(0, args[0].lastIndexOf(".")) + ".sav");
        core.rom = rom ? rom[0] : 0;
        core.ram = sav ? Array.from(sav) : null;
        core.inits.push(core.rom);
        return 0;
      },
      // A state is [rom, battery]; the header check refuses another ROM's.
      _wasm_state_size: () => 2,
      _wasm_state_data: () => {
        const m = new Uint8Array(Module.memory.buffer);
        m[8] = core.rom; m[9] = core.ram ? core.ram[1] : 0;
        return 8;
      },
      _wasm_load_state: (ptr) => {
        const m = new Uint8Array(Module.memory.buffer);
        if (m[ptr] !== core.rom) return 0;
        core.applied++;
        return 1;
      },
      _malloc: () => 32, _free: () => {},
      memory: { buffer: new ArrayBuffer(64) },
    });
    storageReadyResolve();
  `);
  await app.runIn("Module.onRuntimeInitialized()");
  app.idb.set("recent", games.map((name, i) => ({ name, ts: 100 - i })));
  for (const g of games) app.idb.set("rom:" + g, { name: g, data: u8(ROM[g], 1, 2, 3) });
  return app;
};

const core = (app) => app.runIn("core");
const named = (app) => app.api.currentOriginalName;
const drain = async (n = 12) => { for (let i = 0; i < n; i++) await settle(); };

// The running game writes its battery RAM; the core flushes it to rom.sav.
const gameSaves = (app, n) => {
  const bytes = u8(core(app).rom, n);
  core(app).ram = [...bytes];
  app.sandbox.FS.files.set("rom.sav", bytes);
  return bytes;
};
// The 5 s autosave (its setInterval body).
const autosave = async (app) =>
  app.runIn("currentRomName && currentOriginalName && " +
            "persistSave(currentRomName, currentOriginalName)");
const play = async (app, name) => {
  app.runIn(`launchRom(${JSON.stringify(name)})`);
  await drain();
  assert.equal(named(app), name, "loaded " + name);
};
const goHome = async (app) => { app.runIn("showMainMenu()"); await drain(); };

// Holds IndexedDB requests (`op` = "get", "put" or "delete") on `key` until
// released: a load parked between restoreSave's read and the boot, a reset
// between its deletes.
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

const quotaOnce = (app) => {
  let failNext = true;
  app.state.idbFail = (op, key) => {
    if (op === "put" && key === "save:A.gba" && failNext) {
      failNext = false;
      const e = new Error("full"); e.name = "QuotaExceededError";
      return e;
    }
    return false;
  };
};

test("a write retried after checkpoints made room does not put older bytes over a newer save (bug_ckpt_evict_retry_writes_older_save)", async () => {
  const app = await boot();
  await play(app, "A.gba");
  app.idb.set("ckpt0:B.gba", { bytes: u8(1), ts: 1 });   // another game's earlier moment
  quotaOnce(app);
  const gate = hold(app, "delete", "ckpt0:B.gba");
  const v1 = gameSaves(app, 1);
  const first = autosave(app);       // rejected: gives up B's checkpoint, then retries
  await parked(gate);
  const v2 = gameSaves(app, 2);
  await autosave(app);               // the newer save lands meanwhile
  eq(app.idb.get("save:A.gba"), v2);
  gate.release();
  await first;
  await drain();
  eq(app.idb.get("save:A.gba"), v2, "the newer save stands");
});

for (const [label, call] of [["Reset", `resetGameAction("A.gba")`],
                             ["Delete", `deleteGameAction("A.gba")`]]) {
  test(`a write retried after checkpoints made room does not put a save back after ${label} (bug_ckpt_evict_retry_*)`, async () => {
    const app = await boot();
    await play(app, "A.gba");
    app.idb.set("ckpt0:B.gba", { bytes: u8(1), ts: 1 });
    quotaOnce(app);
    const gate = hold(app, "delete", "ckpt0:B.gba");
    gameSaves(app, 1);
    const first = autosave(app);
    await parked(gate);
    await app.runIn(call);
    await drain();
    assert.equal(app.idb.get("save:A.gba"), undefined);
    gate.release();
    await first;
    await drain();
    assert.equal(app.idb.get("save:A.gba"), undefined, "the wiped save stays wiped");
  });
}
