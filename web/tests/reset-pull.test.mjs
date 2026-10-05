// A reset queues its Drive deletes before its first await, so a pull that is
// downloading the save does not write it back
// (formal/WebState/SavePersistence.lean, bug_file_reset_undone_by_pull).
//
// The shared library file under races and repeats: what a delete, import or
// rename made while a sync is in flight leaves behind, and what renaming a
// game back (or into a name another game left) does over many syncs.
//
// Each test replays a trace from formal/WebState/DriveLibrary.lean (named in
// the test) against the real web/index.js: one or two devices (loadApp
// instances) share one fake Drive and one clock, and a Drive request is held
// mid-flight so the person can act inside the sync's await, the way a tap
// lands while an upload is on the wire.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";
import { makeDrive, makeClock, useClock, until } from "./drivefake.mjs";

const device = async (drive, clock) => {
  const app = await loadApp();
  useClock(app, clock);
  app.setFetch(drive.fetch);
  app.api.gdriveToken = "tok";
  app.api.gdriveTokenExp = clock.peek() + 3600e3;
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
    sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
  };
  app.idb.set("recent", []);
  return app;
};

// Import (the file picker path: ROM, a fresh library entry, queued upload).
const importGame = async (app, name, bytes) => {
  await app.api.addRecentRom(name, bytes);
  await settle(); // markGameUpload queues from a .then
};
// A launch and a battery save, the way the page records them.
const play = async (app, name, bytes) => {
  await app.api.touchRecent(name);
  await app.api.dbPut("save:" + name, bytes);
  app.api.markUpload("save:" + name);
};

// "Games removed on another device": take `answer` when the modal is up.
const openModal = (app) =>
  app.document.body.children.find((c) => c.classList?.contains("sync-modal"));
const findButton = (node, label) => {
  if (node?.tagName === "BUTTON" && node.textContent === label) return node;
  for (const c of node?.children || []) {
    const b = findButton(c, label);
    if (b) return b;
  }
  return null;
};
const pull = async (app, answer = "Continue") => {
  let done = false;
  const p = app.api.pullSync().then(() => { done = true; });
  for (let i = 0; i < 400 && !done; i++) {
    await new Promise((r) => setTimeout(r, 0));
    const m = openModal(app);
    if (m) { await findButton(m, answer).click(); m.classList.remove("sync-modal"); }
  }
  await p;
  await settle();
};
const flush = async (app) => { await app.api.flushSync(); await settle(); };

const recentNames = (app) => (app.idb.get("recent") || []).map((r) => r.name).sort();
const libNames = (drive) => drive.lib().recents.map((r) => r.name).sort();
const localKeys = (app, name) =>
  [...app.idb.keys()].filter((k) => typeof k === "string" && k.endsWith(":" + name)).sort();


const stubCore = (app) => app.runIn(`
  globalThis.core = { rom: 0, ram: null, inits: [] };
  Object.assign(Module, {
    ccall: (fn, ret, types, args) => {
      if (fn !== "initFromEmscripten") return 0;
      const sav = FS.files.get(args[0].slice(0, args[0].lastIndexOf(".")) + ".sav");
      core.ram = sav ? Array.from(sav) : null;
      core.inits.push(args[0]);
      return 0;
    },
    _malloc: () => 32, _free: () => {},
    memory: { buffer: new ArrayBuffer(64) },
  });
  storageReadyResolve();
`);

for (const variant of ["resetCurrentSaveFile", "resetGameSaves"]) {
test(`the Saves panel's reset (${variant}) survives a pull downloading the save (bug_file_reset_undone_by_pull)`, async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await importGame(d0, "G.gba", u8(10));
  await play(d0, "G.gba", u8(11));
  await flush(d0);
  await pull(d1);
  await d1.api.downloadGame("G.gba");
  await play(d1, "G.gba", u8(12));            // newer progress elsewhere
  await flush(d1);

  stubCore(d0);
  await d0.runIn("Module.onRuntimeInitialized ? Module.onRuntimeInitialized() : null");
  const saveId = drive.get("save:G.gba").id;
  const h = drive.hold((e) => e.method === "GET" && e.url.includes("/" + saveId + "?alt=media"));
  const pulling = d0.api.pullSync();
  await h.reached;                              // the pull is downloading it...
  // ...when the person taps G (booted on its local save) and resets it in the Saves panel.
  d0.sandbox.FS.files.set("rom.gba", u8(10));
  d0.sandbox.FS.files.set("rom.sav", u8(11));
  d0.api.currentRomName = "rom.gba";
  d0.api.currentOriginalName = "G.gba";
  const resetting = variant === "resetCurrentSaveFile"
    ? d0.runIn("resetCurrentSaveFile()")
    : d0.runIn("(async () => { const g = detachLoadedGame(); await resetGameSaves('G.gba'); loadRom(g.romName, g.originalName); })()");
  h.release();
  await resetting;
  await pulling;
  for (let i = 0; i < 20; i++) await settle();
  console.log(variant, "inits:", JSON.stringify(d0.runIn("core.inits")), "core ram:", JSON.stringify(d0.runIn("core.ram")),
              "save:G:", JSON.stringify(d0.idb.get("save:G.gba") && [...d0.idb.get("save:G.gba")]));
  assert.equal(d0.idb.get("save:G.gba"), undefined, "the download did not write it back");
  assert.equal(d0.runIn("core.ram"), null, "the reboot starts fresh");
});
}
