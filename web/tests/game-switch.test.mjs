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

// ── Finding 1: the shared rom.sav (GameLifecycle, SavePersistence) ──────────

test("a game with no save boots with none, not the last game's battery", async () => {
  const app = await boot();
  await playAThenHome(app);

  await play(app, "B.gba");
  assert.equal(core(app).ram, null, "B booted on no battery file");
  await autosave(app);
  assert.equal(app.idb.get("save:B.gba"), undefined, "save:B was never written");
});

// ── Finding 2: the outgoing core's flush at init (SavePersistence) ──────────
// The stand-in core above cannot run the real initFromEmscripten, so this is
// read from the source: by the time it runs, JS has persisted the outgoing
// game and written the incoming game's save to rom.sav, and a flush of the
// outgoing GB cart (dirty after a state load while paused) would replace it.

test("initFromEmscripten flushes no outgoing core over the incoming game's save", () => {
  const src = readFileSync(new URL("../../src/dingbat_wasm.nim", import.meta.url), "utf8");
  const start = src.indexOf("proc initFromEmscripten(");
  assert.ok(start >= 0);
  const body = src.slice(start, src.indexOf("\nproc ", start));
  assert.ok(body.includes("make_gba(path)"), "the whole proc");
  assert.doesNotMatch(body, /mbc_save|write_save/);
});

// What that flush was for is JS's to ask for: a core paused behind the home
// screen runs no frames, so RAM a state load gave it is in the core only
// until something flushes it. persistSave flushes the solo core first, so it
// lands in the outgoing game's own save, not nowhere and not the next game's.

const flushableCore = (app) => app.runIn(`
  core.dirty = false;
  Module._wasm_flush_save = () => {
    if (!core.dirty) return;
    FS.files.set("rom.sav", new Uint8Array(core.ram));
    core.dirty = false;
  };
`);

test("RAM a paused core holds unflushed is persisted as its own game's save", async () => {
  const app = await boot();
  flushableCore(app);
  await playAThenHome(app);
  // A state loaded while paused: the core's RAM, marked dirty, no frame run.
  app.runIn("core.ram = [0x0a, 9]; core.dirty = true;");

  await play(app, "B.gba");
  eq(app.idb.get("save:A.gba"), u8(0x0a, 9));
  assert.equal(core(app).ram, null, "B booted on no battery file");
});

// The Resume snapshot's signature says which battery the state carries: the
// RAM in the state, flushed, not a file the flush has not caught up with.
test("a snapshot of a paused core records the battery its state carries", async () => {
  const app = await boot();
  flushableCore(app);
  await playAThenHome(app);
  app.runIn("core.ram = [0x0a, 9]; core.dirty = true;");
  app.document.hidden = true;
  await app.dispatchDoc("visibilitychange");
  await drain();
  const auto = app.idb.get("stateauto:A.gba");
  assert.equal(auto.bytes[1], 9, "the state carries the loaded RAM");
  assert.equal(auto.saveSig, app.runIn("saveSignature(new Uint8Array([0x0a, 9]))"));
});

test("...and so is it when the game is closed", async () => {
  const app = await boot();
  flushableCore(app);
  await playAThenHome(app);
  app.runIn("core.ram = [0x0a, 9]; core.dirty = true;");

  assert.equal(await app.runIn("unloadGame()"), true);
  eq(app.idb.get("save:A.gba"), u8(0x0a, 9), "the close's flush wrote the core's RAM");
});

test("a game with a save boots on its own save", async () => {
  const app = await boot();
  const b = u8(0x0b, 7);
  app.idb.set("save:B.gba", b);
  await playAThenHome(app);
  await play(app, "B.gba");
  eq(core(app).ram, [...b]);
});

// ── Finding 3: a Drive pull landing during a load (both) ────────────────────

const FILES_URL = "https://www.googleapis.com/drive/v3/files";
const UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files";

test("a Drive pull landing mid-load is neither overwritten nor overwrites Drive", async () => {
  const app = await boot({ games: ["A.gba"] });
  const local = u8(0x0a, 1);    // what this device last synced
  const remote = u8(0x0a, 2);   // another device's newer save
  app.idb.set("save:A.gba", local);
  const sig = app.runIn(`sigOfBytes(new Uint8Array(${JSON.stringify([...local])}))`);
  app.api.gdriveToken = "test-token";
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: { "save:A.gba": sig }, rmt: { "save:A.gba": "t1" },
                        connected: true };
  const drive = new Map([["save:A.gba", { id: "s", bytes: remote, modifiedTime: "t2" }]]);
  let download;
  const downloaded = new Promise((r) => { download = r; });
  let downloading = false;
  app.setFetch(async (url, opts = {}) => {
    url = String(url);
    const method = opts.method || "GET";
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [...drive].map(([name, f]) => ({
        id: f.id, name, size: String(f.bytes.length), modifiedTime: f.modifiedTime })) });
    }
    if (url.includes("?alt=media")) {
      downloading = true;
      await downloaded;
      return bytesRes(drive.get("save:A.gba").bytes);
    }
    if (url.startsWith(UPLOAD_URL)) {
      const f = drive.get("save:A.gba");
      if (method === "PATCH") f.bytes = new Uint8Array(await opts.body.arrayBuffer());
      return jsonRes({ id: f.id });
    }
    return jsonRes({ id: "x" });
  });

  const pulling = app.api.pullSync();
  for (let i = 0; i < 50 && !downloading; i++) await settle();
  assert.ok(downloading, "the pull is downloading A's save");
  await play(app, "A.gba");          // the player taps A meanwhile
  eq(core(app).ram, [...local]);
  download();
  await pulling;
  await drain();
  await autosave(app);               // the first 5 s tick after the boot
  await app.api.flushSync();
  await drain();

  eq(drive.get("save:A.gba").bytes, remote, "Drive keeps the other device's save");
  assert.ok(!app.api.syncState.queueUp.includes("save:A.gba"),
    "the unchanged local save is not queued over it");
});

// ── Findings 4 and 5: rollback link sessions (Netplay) ──────────────────────

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

// ── Finding 9: switches racing closes, taps, the page going away (GameLifecycle)

test("closing the paused game while another loads keeps each save its own", async () => {
  const app = await boot();
  const b = u8(0x0b, 5);
  app.idb.set("save:B.gba", b);
  const a = await playAThenHome(app);

  const gate = hold(app, "get", "save:B.gba");
  app.runIn(`launchRom("B.gba")`);        // tap B...
  await parked(gate);
  await app.runIn("unloadGame()");        // ...and the card's X
  gate.release();
  await drain();

  eq(app.idb.get("save:A.gba"), a, "save:A is A's");
  eq(app.idb.get("save:B.gba"), b, "save:B is B's");
  assert.equal(app.idb.get("stateauto:B.gba"), undefined, "no B resume point from A's core");
  coherent(app);
});

test("double-tapping two tiles boots the later game under its own name", async () => {
  const app = await boot();
  const b = u8(0x0b, 5);
  app.idb.set("save:B.gba", b);
  await playAThenHome(app);

  const gate = hold(app, "get", "save:B.gba");
  app.runIn(`launchRom("B.gba")`);
  await parked(gate);
  app.runIn(`launchRom("C.gba")`);        // the second tap, before B's boot
  await drain(30);
  gate.release();
  await drain(30);

  assert.equal(named(app), "C.gba");
  assert.equal(core(app).rom, ROM["C.gba"], "the core holds C");
  assert.equal(core(app).ram, null, "on C's (absent) battery");
  eq(app.idb.get("save:B.gba"), b, "save:B untouched");
  assert.equal(app.idb.get("stateauto:B.gba"), undefined, "no B resume point from another core");
});

test("double-tapping the same tile keeps the real resume point", async () => {
  const app = await boot();
  const real = { bytes: u8(0x0a, 9), ts: 1, saveSig: null };
  app.idb.set("stateauto:A.gba", real);

  app.runIn(`launchRom("A.gba"); launchRom("A.gba")`);
  await drain(30);

  assert.equal(named(app), "A.gba");
  eq(app.idb.get("stateauto:A.gba"), real, "not replaced by a snapshot of the fresh boot");
});

test("the page going away mid-switch writes nothing under the incoming name", async () => {
  const app = await boot();
  const b = u8(0x0b, 5);
  app.idb.set("save:B.gba", b);
  await playAThenHome(app);
  const a2 = gameSaves(app, 2); // unflushed, so pagehide has something to write

  const gate = hold(app, "get", "save:B.gba");
  app.runIn(`launchRom("B.gba")`);
  await parked(gate);
  await app.dispatchWin("pagehide");
  await drain();

  eq(app.idb.get("save:B.gba"), b, "save:B untouched");
  eq(app.idb.get("save:A.gba"), a2, "A's newest save went to save:A");
  assert.equal(app.idb.get("stateauto:B.gba"), undefined, "no B resume point from A's core");
  gate.release();
  await drain();
});

// A close that a later tap superseded says so, not "online session".
test("a Delete that a later tap superseded does not blame an online session", async () => {
  const app = await boot();
  await playAThenHome(app);
  const deleting = app.runIn(`deleteGameAction("A.gba")`); // unloadGame awaits...
  app.runIn(`launchRom("B.gba")`);                          // ...and a tap takes over
  assert.equal(await deleting, false, "not deleted");
  await drain();
  assert.ok(!app.toasts.includes("Exit the online session first"), app.toasts.join(" | "));
  assert.ok(app.toasts.some((t) => t.startsWith("Not deleted")), "says it was not deleted");
  assert.ok(app.idb.get("rom:A.gba"), "A is still in the library");
  assert.equal(named(app), "B.gba", "the tap's load went ahead");
});

// A Drive-only tile downloads before it launches, for seconds: a tile tapped
// meanwhile is the later tap, and wins.
test("a Drive-only game whose download finishes after another tap does not replace it", async () => {
  const app = await boot();
  app.idb.delete("rom:B.gba");       // B is on Drive only
  app.api.gdriveToken = "test-token";
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: { "rom:B.gba": "s" }, rmt: {}, connected: true };
  let download;
  const downloaded = new Promise((r) => { download = r; });
  app.setFetch(async (url) => {
    url = String(url);
    if (url.includes("spaces=appDataFolder")) {
      return jsonRes({ files: [{ id: "b", name: "rom:B.gba", size: "4",
                                 modifiedTime: "2026-01-01T00:00:00Z" }] });
    }
    if (url.includes("alt=media")) { await downloaded; return bytesRes(u8(0x0b, 1, 2, 3)); }
    return jsonRes({});
  });
  await app.api.refreshHomeRecent();
  await drain();
  const launchOf = (name) => gameTiles(app).map((t) =>
    t.children.find((c) => c.classList.contains("home-tile-launch")))
    .find((l) => l.title === name || l.title.startsWith(name + " — "));
  assert.ok(launchOf("B.gba") && launchOf("C.gba"), "both tiles on screen");

  launchOf("B.gba").click();         // the download starts
  await drain();
  launchOf("C.gba").click();         // the player changes their mind
  await drain();
  assert.equal(named(app), "C.gba");
  download();
  await drain(40);
  assert.ok(app.idb.get("rom:B.gba"), "B did download");
  assert.equal(named(app), "C.gba", "and did not replace C");
  assert.equal(core(app).rom, ROM["C.gba"]);
});

// The SIO link path (`?rollback=0`): launchNetRom boots the host's ROM the way
// loadRom boots a tile, and named it before its save was read the way loadRom
// used to.
const withNetplay = (app) => {
  const { sandbox } = app;
  sandbox.WebSocket = class { constructor() { this.readyState = 0; } send() {} close() {} };
  sandbox.RTCPeerConnection = class {};
  sandbox.BroadcastChannel = class { postMessage() {} close() {} };
  sandbox.navigator.onLine = true;
  sandbox.location.hostname = "localhost";
  sandbox.crypto = { getRandomValues: (a) => a };
  vm.runInContext(
    readFileSync(new URL("../sdputil.js", import.meta.url), "utf8") + "\n" +
    readFileSync(new URL("../netplay.js", import.meta.url), "utf8"),
    app.context, { filename: "web/netplay.js" });
  app.runIn(`
    const init = Module.ccall;
    Module.ccall = (fn, ret, types, args) =>
      fn === "netlink_init" ? (init("initFromEmscripten", null, ["string"], [args[0]]), 1)
                            : init(fn, ret, types, args);
  `);
};

test("the SIO link path names its game only once the core and save are in", async () => {
  const app = await boot();
  withNetplay(app);
  const b = u8(0x0b, 5);
  app.idb.set("save:B.gba", b);
  await playAThenHome(app);
  const a2 = gameSaves(app, 2); // unflushed, so pagehide has something to write

  const gate = hold(app, "get", "save:B.gba");
  app.runIn(`
    net = { rom: { name: "B.gba", data: new Uint8Array([0x0b, 1, 2, 3]) },
            isHost: true, attach: false, rxQueue: [] };
    globalThis.__launched = launchNetRom();
  `);
  await parked(gate);
  await app.dispatchWin("pagehide");  // the page goes away in the gap
  await drain();
  eq(app.idb.get("save:B.gba"), b, "save:B untouched");
  eq(app.idb.get("save:A.gba"), a2, "A's newest save went to save:A");
  gate.release();
  await app.runIn("__launched");
  assert.equal(named(app), "B.gba");
  eq(core(app).ram, [...b], "B booted on its own save");
  coherent(app);
});

// A rollback session owns the core from rollback_init (rbTryInit), before it
// starts: "Ready — waiting for your friend…" can last a whole cross-game ROM
// transfer. A game loaded then must end the session before it boots, not
// after (Netplay.regress_load_during_rollback_setup).
test("a load during a rollback session's setup ends the session first", async () => {
  const app = await boot();
  withNetplay(app);
  const a = await playAThenHome(app);
  app.runIn(`
    // rbTryInit: the session's cores replace the solo one (A's, flushed)
    net = { rb: { inited: true, localPlayer: 0 }, started: false, isHost: true };
    rbExt = ".gba";
    FS.files.set("rbrom0.gba", new Uint8Array([0x0a, 1, 2, 3]));
    FS.files.set("rbrom0.sav", new Uint8Array(core.ram));
    globalThis.__rbCore = { rom: 0x0a, ram: core.ram.slice() };
    core.rom = 0; core.ram = null;
    Module._rollback_exit_to_single = () => {
      if (!__rbCore) return 0;
      core.rom = __rbCore.rom; core.ram = __rbCore.ram; __rbCore = null;
      return 1;
    };
    Module._rollback_exit = () => { __rbCore = null; };
    document.getElementById("net-modal").classList.add("open"); // "Ready — waiting…"
  `);
  const b = u8(0x0b, 5);
  app.idb.set("save:B.gba", b);
  await play(app, "B.gba");
  await drain();
  eq(app.idb.get("save:B.gba"), b, "save:B is B's");
  eq(app.idb.get("save:A.gba"), a, "save:A is A's");
  assert.equal(core(app).rom, ROM["B.gba"], "the core B booted is the one running");
  assert.equal(app.api.currentRomName, "rom.gba");
  assert.equal(app.runIn("net"), null, "the session is gone");
});

// ...and the core itself drops a session's cores when a solo game boots, so a
// session JS failed to end cannot be promoted over it later.
test("initFromEmscripten drops a leftover rollback session", () => {
  const src = readFileSync(new URL("../../src/dingbat_wasm.nim", import.meta.url), "utf8");
  const start = src.indexOf("proc initFromEmscripten(");
  const body = src.slice(start, src.indexOf("\nproc ", start));
  assert.match(body, /\n\s+rollback_exit\(\)/);
});

// ── Finding 15: reset save data (SavePersistence) ───────────────────────────

// The library's Reset (resetGameAction) and the Saves panel's "Reset save
// file" (resetCurrentSaveFile) both delete several keys, save:<name> first.
for (const [label, call] of [["Reset", `resetGameAction("A.gba")`],
                             ["Reset save file", "resetCurrentSaveFile()"]]) {
  test(`an autosave landing inside ${label} does not bring the save back`, async () => {
    const app = await boot();
    await play(app, "A.gba");
    gameSaves(app, 1);
    await autosave(app);
    gameSaves(app, 2); // in-game save from the last few seconds, not yet flushed

    const gate = hold(app, "delete", "stateauto:A.gba");
    const resetting = app.runIn(call);
    await parked(gate);  // save:A is gone; the session delete is still to come
    assert.equal(app.idb.get("save:A.gba"), undefined);
    await autosave(app); // the 5 s tick between the deletes
    gate.release();
    await resetting;
    await drain();

    assert.equal(app.idb.get("save:A.gba"), undefined, "the save stays deleted");
    assert.equal(named(app), "A.gba", "rebooted");
    assert.equal(core(app).ram, null, "the reboot starts fresh");
    await autosave(app);
    assert.equal(app.idb.get("save:A.gba"), undefined);
  });
}

// ── Low: Resume after an unflushed save (both) ─────────────────────────────

const resumeOffered = async (app) => {
  const a1 = u8(0x0a, 1);
  app.idb.set("save:A.gba", a1);
  app.idb.set("stateauto:A.gba", {
    bytes: u8(0x0a, 1), ts: Date.now(),
    saveSig: app.runIn(`saveSignature(new Uint8Array(${JSON.stringify([...a1])}))`),
  });
  await play(app, "A.gba");
  const pill = app.document.getElementById("toast").children.find((c) =>
    c.classList.contains("has-action") && !c.classList.contains("leaving"));
  assert.ok(pill, "Resume offered: the snapshot matches the save");
  return pill;
};

test("Resume applies a snapshot taken with the live battery", async () => {
  const app = await boot();
  const pill = await resumeOffered(app);
  pill.onclick();     // the whole pill is the tap target
  await drain();
  assert.equal(core(app).applied, 1);
});

test("Resume is refused over RAM a paused core holds unflushed", async () => {
  const app = await boot();
  flushableCore(app);
  const pill = await resumeOffered(app);
  app.runIn("core.ram = [0x0a, 5]; core.dirty = true;"); // a state loaded while paused
  pill.onclick();
  await drain();
  assert.equal(core(app).applied, 0, "the snapshot was not applied over it");
});

test("Resume is refused once the game has saved in game, before any autosave", async () => {
  const app = await boot();
  const pill = await resumeOffered(app);
  gameSaves(app, 2); // saved in game; the autosave has not run yet
  pill.onclick();
  await drain();
  assert.equal(core(app).applied, 0, "the older snapshot was not applied");
});

// ── Import (SavePersistence, found by the model of the flush) ───────────────
// An imported save replaces the loaded game's. The reboot used to persist
// "the outgoing game" first - with the core's own RAM flushed over the
// imported file - and to snapshot the replaced session under the imported
// save's signature, so Resume would put the old battery back.

test("an imported save survives the reboot, and no Resume offers the replaced one", async () => {
  const app = await boot();
  flushableCore(app);
  app.api.gdriveToken = "test-token";
  app.api.syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true };
  await playAThenHome(app);
  app.runIn("core.ram = [0x0a, 7]; core.dirty = true;"); // a state loaded while paused

  const imported = u8(0x0a, 0x42);
  await app.runIn("applyImportedSave")(imported, "A.sav");
  await drain();
  eq(app.idb.get("save:A.gba"), imported, "save:A is the import");
  eq(core(app).ram, [...imported], "the game rebooted on it");
  assert.ok(app.api.syncState.queueUp.includes("save:A.gba"), "and it is queued for Drive");
  const offer = app.document.getElementById("toast").children.find((c) =>
    c.classList.contains("has-action") && !c.classList.contains("leaving"));
  if (offer) { offer.onclick(); await drain(); }
  assert.equal(core(app).applied, 0, "no Resume puts the replaced battery back");
  await autosave(app);
  eq(app.idb.get("save:A.gba"), imported);
});

// ── Low: the quota retry (SavePersistence) ──────────────────────────────────

test("a quota retry does not put older bytes back over a newer save", async () => {
  const app = await boot();
  await play(app, "A.gba");
  let failNext = true;
  app.state.idbFail = (op, key) => {
    if (op === "put" && key === "save:A.gba" && failNext) {
      failNext = false;
      const e = new Error("full"); e.name = "QuotaExceededError";
      return e;
    }
    return false;
  };
  const gate = hold(app, "delete", "rom:C.gba");
  gameSaves(app, 1);
  const first = autosave(app);       // rejected: gives up C's ROM, then retries
  await parked(gate);
  const v2 = gameSaves(app, 2);
  await autosave(app);               // the newer save lands meanwhile
  eq(app.idb.get("save:A.gba"), v2);
  gate.release();
  await first;
  await drain();
  eq(app.idb.get("save:A.gba"), v2, "the newer save stands");
  assert.ok(app.toasts.some((t) => t.includes("gave up its file")), "the eviction is still told");
});

// The same retry against a Reset (or a Delete) instead of a newer save:
// SavePersistence.open_quota_retry_resurrects_reset_save, now regress_*.
for (const [label, call] of [["Reset", `resetGameAction("A.gba")`],
                             ["Delete", `deleteGameAction("A.gba")`]]) {
  test(`a quota retry does not put a save back after ${label}`, async () => {
    const app = await boot();
    await play(app, "A.gba");
    let failNext = true;
    app.state.idbFail = (op, key) => {
      if (op === "put" && key === "save:A.gba" && failNext) {
        failNext = false;
        const e = new Error("full"); e.name = "QuotaExceededError";
        return e;
      }
      return false;
    };
    const gate = hold(app, "delete", "rom:C.gba");
    gameSaves(app, 1);
    const first = autosave(app);       // rejected: gives up C's ROM, then retries
    await parked(gate);
    await app.runIn(call);             // the user wipes the save meanwhile
    await drain();
    assert.equal(app.idb.get("save:A.gba"), undefined);
    gate.release();
    await first;
    await drain();
    assert.equal(app.idb.get("save:A.gba"), undefined, "the wiped save stays wiped");
  });
}

test("a quota retry does not put a save back over an imported one", async () => {
  const app = await boot();
  await play(app, "A.gba");
  let failNext = true;
  app.state.idbFail = (op, key) => {
    if (op === "put" && key === "save:A.gba" && failNext) {
      failNext = false;
      const e = new Error("full"); e.name = "QuotaExceededError";
      return e;
    }
    return false;
  };
  const gate = hold(app, "delete", "rom:C.gba");
  gameSaves(app, 1);
  const first = autosave(app);
  await parked(gate);
  const imported = u8(0x0a, 0x42);
  await app.runIn("applyImportedSave")(imported, "A.sav");
  await drain();
  gate.release();
  await first;
  await drain();
  eq(app.idb.get("save:A.gba"), imported, "the import stands");
});

// ── Medium: a load under a pausing overlay (RunPause) ──────────────────────
// A game paused (so the Link modal did not freeze it), an overlay opened over
// it, and a ROM dropped meanwhile (or a download that finishes): the new game
// must not run behind the overlay, nor be frozen by it once it closes.

const reportOpen = (app) => app.document.getElementById("report-modal").classList.contains("open");
const pauseLit = (app) => app.document.getElementById("pause").classList.contains("paused");

test("a game loaded under Report a Bug does not run behind it", async () => {
  const app = await boot();
  await play(app, "A.gba");
  app.runIn("togglePause(); openReportModal()");
  assert.equal(reportOpen(app), true);
  await play(app, "B.gba");
  assert.ok(!(reportOpen(app) && !app.runIn("paused")), "not running behind the report");
});

test("closing Report a Bug after a load does not freeze the new game", async () => {
  const app = await boot();
  await play(app, "A.gba");
  app.runIn("togglePause(); openReportModal()");
  await play(app, "B.gba");
  app.runIn("closeReportModal()");
  assert.equal(app.runIn("paused"), pauseLit(app), "the pause button tells the truth");
  assert.equal(app.runIn("paused"), false, "the new game runs");
});

test("a game loaded under the Link Cable modal does not run behind it", async () => {
  const app = await boot();
  await play(app, "A.gba");
  app.runIn(`
    togglePause();
    globalThis.__netModal = true;  // openNetConnect over a paused game
    globalThis.netModalOpen = () => __netModal;
    globalThis.netDismissModal = () => { __netModal = false; };
  `);
  await play(app, "B.gba");
  assert.ok(!(app.runIn("__netModal") && !app.runIn("paused")), "not running behind the modal");
});

// ── Low: the picture filed during a switch (Thumbnails) ─────────────────────

test("a tab switch during a load files no picture under the incoming name", async () => {
  const app = await boot();
  // Pictures: the canvas stand-in "encodes" the framebuffer's first byte.
  app.runIn(`
    Module._wasm_fb_ptr = () => 16;
    Module.memory = { buffer: new ArrayBuffer(16 + 240 * 160 * 4) };
  `);
  let lastPut = 0;
  const realCreate = app.document.createElement;
  app.document.createElement = (tag) => {
    const el = realCreate(tag);
    if (tag === "canvas") {
      el.getContext = () => new Proxy({}, { get: (_t, p) => {
        if (p === "createImageData") {
          return (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) });
        }
        if (p === "putImageData") return (img) => { lastPut = img.data[0]; };
        return () => undefined;
      } });
      el.toBlob = (cb) => cb({ owner: lastPut });
    }
    return el;
  };
  const paint = () => new Uint8Array(app.runIn("Module.memory.buffer"), 16, 4).fill(core(app).rom);

  await play(app, "A.gba");
  paint();
  await goHome(app);
  const gate = hold(app, "get", "save:B.gba");
  app.runIn(`launchRom("B.gba")`);
  await parked(gate);
  app.document.hidden = true;
  await app.dispatchDoc("visibilitychange");
  await drain();
  const f = app.idb.get("frame:B.gba");
  assert.ok(!f || f.owner === ROM["B.gba"], "frame:B is not A's screen");
  gate.release();
  await drain();
});
