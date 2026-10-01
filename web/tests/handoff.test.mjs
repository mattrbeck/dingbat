// Picking a game up on another device. The session (the Resume snapshot) is
// a Drive file, so pausing on one device and syncing makes the other's hero
// resume at that moment; and a game left paused here while another device
// played on is handed over to that device's newer copy, never resumed stale.
// The stand-in core is game-switch.test.mjs's: a state is [rom, battery].

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

// What another device does when it pauses at battery n: its save, and a
// session taken with it, written over Drive's copies.
const otherDevicePauses = async (app, drive, n, dev = "iPhone") => {
  const save = u8(0x0a, n);
  app.context.__rec = { bytes: u8(0x0a, n), ts: 777, by: "other-device", dev,
                        saveSig: app.runIn(`saveSignature(new Uint8Array([0x0a, ${n}]))`) };
  const bundle = await app.runIn(`sessionBundle("A.gba", __rec)`);
  const put = (name, bytes) => {
    const f = drive.get(name);
    f.bytes = bytes;
    f.modifiedTime = new Date(Date.parse(f.modifiedTime) + 60e3).toISOString();
  };
  put("save:A.gba", save);
  put("stateauto:A.gba", bundle);
};

const kicker = (app) => app.document.getElementById("hero-state").textContent;

test("a session is one Drive file, its picture and its device riding in it", async () => {
  const app = await loadApp();
  app.context.__pic = new Blob([u8(7, 7, 7)], { type: "image/jpeg" });
  app.idb.set("stateauto:A.gba", { bytes: u8(1, 2, 3), ts: 5, saveSig: "s1", by: "d1", dev: "iPad" });
  app.idb.set("sessionpic:A.gba", { ts: 5, blob: app.context.__pic });
  app.context.__b = await app.runIn(`readSyncBytes("stateauto:A.gba")`);
  assert.ok(app.api.parseDriveFileName("stateauto:A.gba").kind === "session");

  app.idb.delete("stateauto:A.gba");
  app.idb.delete("sessionpic:A.gba");
  await app.runIn(`writeSyncBytes("stateauto:A.gba", __b)`);
  const rec = app.idb.get("stateauto:A.gba");
  eq(rec.bytes, u8(1, 2, 3));
  eq([rec.ts, rec.saveSig, rec.by, rec.dev], [5, "s1", "d1", "iPad"]);
  const pic = app.idb.get("sessionpic:A.gba");
  assert.equal(pic.ts, 5, "the picture is stamped as this session's");
  eq(new Uint8Array(await pic.blob.arrayBuffer()), u8(7, 7, 7));

  // A picture of another moment does not ride along.
  app.idb.set("sessionpic:A.gba", { ts: 4, blob: app.context.__pic });
  app.context.__b = await app.runIn(`readSyncBytes("stateauto:A.gba")`);
  assert.equal(app.runIn(`sessionFromBundle(__b).pic`), null);
  assert.equal(app.runIn(`sessionFromBundle(new Uint8Array([1, 2, 3]))`), null, "junk is no session");
});

// A game played but never saved in: its session was taken with no save,
// and the other device, holding no save either, resumes it.
test("a session of a game with no save yet is offered on the other device", async () => {
  const app = await loadApp();
  app.idb.set("stateauto:A.gba", { bytes: u8(1, 2, 3), ts: 5, saveSig: null, by: "d1", dev: "Mac" });
  app.context.__b = await app.runIn(`readSyncBytes("stateauto:A.gba")`);
  app.idb.delete("stateauto:A.gba");
  await app.runIn(`writeSyncBytes("stateauto:A.gba", __b)`);
  assert.equal(app.idb.get("stateauto:A.gba").saveSig, null);
  assert.ok(await app.runIn(`resumeSessionFor("A.gba")`), "offered: no save here either");

  // One from before saveSig existed still is not.
  app.idb.set("stateauto:A.gba", { bytes: u8(1, 2, 3), ts: 5 });
  app.context.__b = await app.runIn(`readSyncBytes("stateauto:A.gba")`);
  app.idb.delete("stateauto:A.gba");
  await app.runIn(`writeSyncBytes("stateauto:A.gba", __b)`);
  assert.equal(await app.runIn(`resumeSessionFor("A.gba")`), null);
});

test("the Main Menu sends the session and the save made a moment ago", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await playAndPause(app, 4);   // no 5 s autosave ran in between
  await app.api.flushSync();
  await drain();
  eq(drive.get("save:A.gba").bytes, u8(0x0a, 4), "the save went up");
  const s = app.runIn(`sessionFromBundle(new Uint8Array(${JSON.stringify([...drive.get("stateauto:A.gba").bytes])}))`);
  eq(s.rec.bytes, u8(0x0a, 4), "and the session of that moment");
  assert.equal(s.rec.saveSig, app.runIn("saveSignature(new Uint8Array([0x0a, 4]))"));
});

test("a game sitting paused takes no new snapshot when the tab hides", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await playAndPause(app, 4);
  const ts = app.idb.get("stateauto:A.gba").ts;
  await app.api.flushSync();
  await drain();
  app.document.hidden = true;
  await app.dispatchDoc("visibilitychange");
  await drain();
  assert.equal(app.idb.get("stateauto:A.gba").ts, ts, "the same moment, not restamped");
  eq(app.api.syncState.queueUp.filter((k) => k.startsWith("stateauto:")), [], "nothing to send");

  app.runIn("sessionMoved = true"); // frames ran
  await app.dispatchDoc("visibilitychange");
  await drain();
  assert.ok(app.idb.get("stateauto:A.gba").ts > ts, "a game that moved is snapshotted");
});

test("a game left paused here is handed to the newer copy another device synced", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await playAndPause(app, 4);
  await app.api.flushSync();
  await drain();
  await otherDevicePauses(app, drive, 9);
  const writes = drive.writes().length;

  await app.api.pullSync();
  await drain();

  assert.equal(app.api.currentOriginalName, null, "the stale copy in memory is let go");
  eq(app.idb.get("save:A.gba"), u8(0x0a, 9), "the other device's save is here");
  assert.equal(app.idb.get("stateauto:A.gba").by, "other-device", "and its session");
  assert.ok(app.toasts.some((t) => t.includes("was played on your iPhone since")), app.toasts.join(" | "));
  assert.match(kicker(app), /^On your iPhone · /);
  const sent = drive.writes().slice(writes).map((e) => e.name).filter((n) => n !== "library");
  eq(sent, [], "nothing of the stale copy was sent");

  // Resume goes to the other device's moment.
  app.runIn(`heroPrimary()`);
  await drain();
  eq(app.runIn("core.ram"), [0x0a, 9]);
});

test("a game being played is not yanked: Switch is offered, and takes the newer copy", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await playAndPause(app, 4);
  await app.api.flushSync();
  await drain();
  await otherDevicePauses(app, drive, 9);
  app.runIn("resumeGame()");
  // It plays on here meanwhile, and the tab hides: its session is held back,
  // Drive's being one this device has not seen.
  app.runIn("sessionMoved = true");
  app.document.hidden = true;
  app.document.visibilityState = "hidden";
  await app.dispatchDoc("visibilitychange");
  await drain();
  await app.api.flushSync();
  await drain();
  app.document.hidden = false;
  app.document.visibilityState = "visible";
  assert.equal(app.runIn(`sessionFromBundle(new Uint8Array(${JSON.stringify([...drive.get("stateauto:A.gba").bytes])})).rec.by`),
               "other-device", "the unseen session on Drive was not written over");

  await app.api.pullSync();
  await drain();
  assert.equal(app.api.currentOriginalName, "A.gba", "still playing");
  assert.ok(app.toasts.some((t) => t.includes("since you opened it here")), app.toasts.join(" | "));
  eq(app.idb.get("save:A.gba"), u8(0x0a, 4), "nothing applied under the running game");

  await app.runIn(`switchToHandoff("A.gba")`);
  await drain(30);
  assert.equal(app.api.currentOriginalName, null);
  eq(app.idb.get("save:A.gba"), u8(0x0a, 9));
  assert.equal(app.idb.get("stateauto:A.gba").by, "other-device");
  const onDrive = app.runIn(`sessionFromBundle(new Uint8Array(${JSON.stringify([...drive.get("stateauto:A.gba").bytes])}))`);
  assert.equal(onDrive.rec.by, "other-device", "the chosen session is Drive's copy");
  eq(drive.get("save:A.gba").bytes, u8(0x0a, 9));
});

test("kept playing instead, this device's newer session goes up once seen", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await playAndPause(app, 4);
  await app.api.flushSync();
  await drain();
  await otherDevicePauses(app, drive, 9);
  app.runIn("resumeGame()");
  await app.api.pullSync();            // offered, not taken
  await drain();
  app.runIn("sessionMoved = true; showMainMenu()");
  await drain();
  await app.api.flushSync();
  await drain();
  const s = app.runIn(`sessionFromBundle(new Uint8Array(${JSON.stringify([...drive.get("stateauto:A.gba").bytes])}))`);
  assert.notEqual(s.rec.by, "other-device", "the later moment, this one's, is Drive's now");
});

test("the paused hero says whether its moment has reached Drive", async () => {
  const app = await loadApp();
  app.api.syncState = { queueUp: ["stateauto:A.gba"], queueDel: [], queueRen: [], tomb: [],
                        ren: [], sigs: {}, rmt: {}, connected: true };
  app.api.currentOriginalName = "A.gba";
  assert.equal(app.runIn(`heroStateText("paused")`), "Paused · Syncing…");
  app.api.syncState.queueUp = [];
  assert.equal(app.runIn(`heroStateText("paused")`), "Paused · Synced");
  app.api.syncState.connected = false;
  assert.equal(app.runIn(`heroStateText("paused")`), "Paused", "signed out: no Drive to speak of");
});
