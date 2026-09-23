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
import { loadApp, jsonRes, bytesRes, u8, eq, settle } from "./helpers.mjs";

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

// Play A until it has a save on this device, then go home.
const playAThenHome = async (app) => {
  await play(app, "A.gba");
  const a = gameSaves(app, 1);
  await autosave(app);
  eq(app.idb.get("save:A.gba"), a);
  await goHome(app);
  return a;
};

// The named game is the game in the core, on its own battery.
const coherent = (app) => {
  const n = named(app);
  if (n === null) return;
  assert.equal(core(app).rom, ROM[n], "the named game is the one in the core");
  if (core(app).ram) assert.equal(core(app).ram[0], ROM[n], "on its own battery");
};

// ── Findings 4 and 5: rollback link sessions ────────────────────────────────

const inRollback = (app) => app.runIn(`
  rollbackMode = true;
  globalThis.netShutdown = async () => {
    __shut.push(currentOriginalName);
    rollbackMode = false;
  };
`);

test("launching a game during a rollback session ends the session first", async () => {
  const app = await boot();
  await play(app, "A.gba");
  inRollback(app);
  await play(app, "B.gba");
  eq(app.runIn("__shut"), ["A.gba"], "the session was torn down while A was still named");
});

test("a rollback session that starts mid-load keeps the load from naming its game", async () => {
  const app = await boot();
  await play(app, "A.gba");
  const gate = hold(app, "put", "stateauto:A.gba");
  app.runIn(`launchRom("B.gba")`);
  await parked(gate);   // loadRom persisting the outgoing game...
  inRollback(app);      // ...when a session reaches rbStartIfReady
  gate.release();
  await drain();
  assert.equal(named(app), "A.gba", "the session's game stays named");
  assert.equal(app.runIn("rollbackMode"), true);
});

test("closing the tab during a rollback session tears it down (and persists it)", async () => {
  for (const ev of ["pagehide", "beforeunload"]) {
    const app = await boot();
    await play(app, "A.gba");
    inRollback(app);
    await app.dispatchWin(ev);
    eq(app.runIn("__shut"), ["A.gba"], ev);
  }
});

