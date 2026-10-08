// A checkpoint packing when the player taps Switch is of the copy being let
// go: it must not land over the copy chosen (formal/WebState/Handoff.lean,
// bug_checkpoint_after_switch / regress_checkpoint_after_switch).
//
// The device and its stand-in core are handoff.test.mjs's (a state is
// [rom, battery]); the checkpoint worker is a fake that holds its answer
// until the test lets it go, the way a phone's worker is still packing a
// GBA state when a tap lands.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";
import { makeDrive, makeClock, useClock } from "./drivefake.mjs";

const drain = async (n = 16) => { for (let i = 0; i < n; i++) await settle(); };

const device = async (drive, clock) => {
  const app = await loadApp();
  useClock(app, clock);
  app.runIn(`
    globalThis.core = { rom: 0, ram: null };
    globalThis.netMode = false;
    Object.assign(Module, {
      ccall: (fn, ret, types, args) => {
        if (fn !== "initFromEmscripten") return 0;
        const rom = FS.files.get(args[0]);
        const sav = FS.files.get(args[0].slice(0, args[0].lastIndexOf(".")) + ".sav");
        core.rom = rom ? rom[0] : 0;
        core.ram = sav ? Array.from(sav) : null;
        return 0;
      },
      _wasm_state_size: () => 2,
      _wasm_state_plain_size: () => 2,
      _wasm_state_data: () => {
        const m = new Uint8Array(Module.memory.buffer);
        m[8] = core.rom; m[9] = core.ram ? core.ram[1] : 0;
        return 8;
      },
      _wasm_load_state: (ptr) => {
        const m = new Uint8Array(Module.memory.buffer);
        if (m[ptr] !== core.rom) return 0;
        core.ram = [m[ptr], m[ptr + 1]];
        FS.files.set("rom.sav", new Uint8Array(core.ram));
        return 1;
      },
      _malloc: () => 32, _free: () => {},
      memory: { buffer: new ArrayBuffer(64) },
    });
    // ckptworker.js, held: each message waits in __packs until released.
    globalThis.__packs = [];
    globalThis.CompressionStream = class {};
    globalThis.Worker = class {
      postMessage(msg) {
        __packs.push(() => this.onmessage({ data: {
          id: msg.id, packed: msg.state, pic: null,
          saveSig: sigOfSave(msg.sav ? new Uint8Array(msg.sav) : null),
        } }));
      }
    };
    storageReadyResolve();
  `);
  await app.runIn("Module.onRuntimeInitialized()");
  app.setFetch(drive.fetch);
  app.api.gdriveToken = "tok";
  app.api.gdriveTokenExp = clock.peek() + 3600e3;
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
    sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
  };
  app.idb.set("recent", [{ name: "A.gba", ts: 1 }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: u8(0x0a, 1, 2, 3) });
  return app;
};

// Play A, write battery value n in game, go to the Main Menu.
const playAndPause = async (app, n) => {
  app.runIn(`launchRom("A.gba")`);
  await drain();
  assert.equal(app.api.currentOriginalName, "A.gba");
  app.runIn(`core.ram = [0x0a, ${n}]; FS.files.set("rom.sav", new Uint8Array(core.ram));
             sessionMoved = true;`);
  app.runIn("showMainMenu()");
  await drain();
};

// Another device paused at battery n and synced.
const otherDevicePauses = async (app, drive, n) => {
  app.context.__rec = { bytes: u8(0x0a, n), ts: 777, by: "other-device", dev: "iPhone",
                        saveSig: app.runIn(`saveSignature(new Uint8Array([0x0a, ${n}]))`) };
  const bundle = await app.runIn(`sessionBundle("A.gba", __rec)`);
  const put = (name, bytes) => {
    const f = drive.get(name);
    f.bytes = bytes;
    f.modifiedTime = new Date(Date.parse(f.modifiedTime) + 60e3).toISOString();
  };
  put("save:A.gba", u8(0x0a, n));
  put("stateauto:A.gba", bundle);
};

const sessOnDrive = (app, drive) =>
  app.runIn(`sessionFromBundle(new Uint8Array(${JSON.stringify([...drive.get("stateauto:A.gba").bytes])}))`).rec;

test("Switch tapped while a checkpoint packs: the checkpoint does not land over the chosen copy (bug_checkpoint_after_switch)", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await playAndPause(app, 4);
  await app.api.flushSync();
  await drain();
  await otherDevicePauses(app, drive, 9);

  // Back into the copy held here; a pull while it runs offers Switch.
  app.runIn("resumeGame()");
  await app.api.pullSync();
  await drain();
  assert.ok(app.toasts.some((t) => t.includes("since you opened it here")), app.toasts.join(" | "));
  assert.equal(app.api.currentOriginalName, "A.gba", "still playing");

  // It plays on, and a running tick takes a checkpoint; the worker packs it...
  app.runIn("core.ram = [0x0a, 4]; sessionMoved = true; runPlayMs = 61 * 1000");
  const ckpt = app.runIn("takeCheckpoint()");
  await drain();
  assert.equal(app.runIn("__packs.length"), 1, "the checkpoint is packing");

  // ...when the player taps Switch.
  await app.runIn(`switchToHandoff("A.gba")`);
  await drain(30);
  assert.equal(app.api.currentOriginalName, null, "the copy here is let go");
  assert.equal(app.idb.get("stateauto:A.gba").by, "other-device", "the chosen session landed");

  // The worker answers; the checkpoint goes on, and the device syncs.
  app.runIn("__packs.splice(0).forEach((f) => f())");
  await ckpt;
  await drain(30);
  await app.api.flushSync();
  await drain(30);

  assert.equal(app.idb.get("stateauto:A.gba").by, "other-device",
               "here: the chosen session, not the checkpoint of the copy turned down");
  assert.equal(sessOnDrive(app, drive).by, "other-device", "and on Drive");
  eq(drive.get("save:A.gba").bytes, u8(0x0a, 9));
  const s = await app.runIn(`resumeSessionFor("A.gba")`);
  eq(s.bytes, u8(0x0a, 9), "Resume goes to the chosen moment");
});
