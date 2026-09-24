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

// ── Rename markers ─────────────────────────────────────────────────────────

// DriveLibrary.bug_rename_undo_oscillates / regress_rename_undo_settles.
test("renaming a game back settles: its Drive files stop flipping names", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  await importGame(d0, "One.gba", u8(10));
  await play(d0, "One.gba", u8(11));
  await flush(d0);
  assert.equal((await d0.api.renameGame("One.gba", "Two.gba")).ok, true);
  await flush(d0);
  await pull(d0);
  assert.equal((await d0.api.renameGame("Two.gba", "One.gba")).ok, true);
  await flush(d0);

  for (let cycle = 0; cycle < 3; cycle++) {
    await pull(d0);
    await flush(d0);
    eq(drive.names(), ["rom:One.gba", "save:One.gba"], "cycle " + cycle + ": files stay put");
    eq(libNames(drive), ["One.gba"]);
    eq(localKeys(d0, "One.gba"), ["rom:One.gba", "save:One.gba"]);
  }
  eq(d0.toasts.filter((t) => t.includes("renamed on another device")), [],
    "the device is not told its own undo came from elsewhere");
  eq(d0.api.syncState.queueRen, []);
});

// DriveLibrary.bug_rename_undo_loses_save / regress_rename_undo_keeps_save.
test("after renaming a game back, a new save reaches Drive and stays there", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  await importGame(d0, "One.gba", u8(10));
  await play(d0, "One.gba", u8(11));
  await flush(d0);
  await d0.api.renameGame("One.gba", "Two.gba");
  await flush(d0);
  await pull(d0);
  await d0.api.renameGame("Two.gba", "One.gba");
  await flush(d0);
  await pull(d0);
  await flush(d0);

  await play(d0, "One.gba", u8(12));
  await flush(d0);
  await pull(d0);
  await flush(d0);
  eq(drive.get("save:One.gba")?.bytes, u8(12), "Drive holds the newest progress");
  assert.equal(drive.get("save:Two.gba"), null);

  const d1 = await device(drive, clock);
  await pull(d1);
  assert.equal(await d1.api.downloadGame("One.gba"), true);
  eq(d1.idb.get("save:One.gba"), u8(12), "a second device gets it too");
});

// DriveLibrary.bug_rename_into_retired_name / regress_rename_into_retired_name.
test("renaming a game into a name another game was renamed away from keeps them apart", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  await importGame(d0, "B.gba", u8(10));
  await importGame(d0, "A.gba", u8(20));
  await play(d0, "A.gba", u8(21));
  await flush(d0);
  await pull(d0);
  assert.equal((await d0.api.renameGame("B.gba", "C.gba")).ok, true);
  await flush(d0);
  await pull(d0);

  assert.equal((await d0.api.renameGame("A.gba", "B.gba")).ok, true);
  await flush(d0);
  await pull(d0);
  await flush(d0);

  eq(recentNames(d0), ["B.gba", "C.gba"], "two games on the grid");
  eq(libNames(drive), ["B.gba", "C.gba"], "and in the library");
  eq(d0.idb.get("rom:B.gba").data, u8(20), "A's ROM is B now");
  eq(d0.idb.get("save:B.gba"), u8(21), "with A's save beside it");
  assert.equal(d0.idb.get("save:C.gba"), undefined, "C's ROM did not gain A's save");
  eq(drive.get("rom:C.gba")?.bytes, u8(10));
  eq(drive.get("rom:B.gba")?.bytes, u8(20));
  eq(drive.get("save:B.gba")?.bytes, u8(21));
  assert.equal(drive.get("save:C.gba"), null);
});

// ── Stale commits ──────────────────────────────────────────────────────────

// Device 0 imports 7 and syncs; device 1 pulls and downloads it
// (DriveLibrary.setupA).
const setupA = async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await importGame(d0, "Seven.gba", u8(70));
  await flush(d0);
  await pull(d1);
  assert.equal(await d1.api.downloadGame("Seven.gba"), true);
  return { clock, drive, d0, d1 };
};

// DriveLibrary.bug_delete_during_flush_resurrects / regress_delete_during_flush.
test("a delete made while a flush is uploading stays deleted on every device", async () => {
  const { drive, d0, d1 } = await setupA();
  await play(d0, "Seven.gba", u8(71));
  const h = drive.hold((e) => e.method === "POST" && e.url.includes("uploadType=multipart"));
  const flushing = d0.api.flushSync();
  await h.reached;                          // the save is on the wire
  await d0.api.deleteGameEverywhere("Seven.gba");
  h.release();
  await flushing;
  await settle();
  assert.ok(d0.api.syncState.tomb.some((t) => t.name === "Seven.gba"),
    "the flush's commit kept the tombstone the delete raised");

  await flush(d0);
  await pull(d0);
  await pull(d1);
  await flush(d1);
  await pull(d0);
  eq(libNames(drive), [], "not back in the library");
  eq(recentNames(d0), []);
  eq(recentNames(d1), [], "gone from the other device's grid");
  eq(localKeys(d1, "Seven.gba"), [], "and its files");
  eq(drive.names(), [], "and from Drive");
  assert.ok(drive.lib().tomb.some((t) => t.name === "Seven.gba"));
});

// Device 0 holds 7 and 8; the pull is downloading 8's newer save.
const pullInFlight = async ({ drive, d0, d1 }) => {
  await importGame(d0, "Eight.gba", u8(80));
  await flush(d0);
  await pull(d1);
  await d1.api.downloadGame("Eight.gba");
  await play(d1, "Eight.gba", u8(81));
  await flush(d1);
  const h = drive.hold((e) => e.method === "GET" && e.url.includes("alt=media") &&
                              drive.files.find((f) => e.url.includes("/" + f.id + "?"))?.name === "save:Eight.gba");
  let done = false;
  const pulling = d0.api.pullSync().then(() => { done = true; });
  await h.reached;
  return { release: async () => { h.release(); await pulling; await settle(); }, done: () => done };
};

// DriveLibrary.bug_delete_during_pull_resurrects / regress_delete_during_pull.
test("a delete made while a pull is downloading stays deleted", async () => {
  const s = await setupA();
  const { d0, drive } = s;
  const p = await pullInFlight(s);
  await d0.api.deleteGameEverywhere("Seven.gba");
  await p.release();
  eq(recentNames(d0), ["Eight.gba"], "no tile comes back");
  assert.ok(d0.api.syncState.tomb.some((t) => t.name === "Seven.gba"),
    "the pull's commit kept the tombstone");
  await flush(d0);
  assert.ok(drive.lib().tomb.some((t) => t.name === "Seven.gba"));
  eq(libNames(drive), ["Eight.gba"]);
});

// DriveLibrary.bug_import_during_pull_orphans / regress_import_during_pull.
test("a game imported while a pull is downloading keeps its tile and reaches the library", async () => {
  const s = await setupA();
  const { d0, drive } = s;
  const p = await pullInFlight(s);
  await importGame(d0, "Nine.gba", u8(90));
  await p.release();
  eq(recentNames(d0), ["Eight.gba", "Nine.gba", "Seven.gba"]);
  await flush(d0);
  await pull(d0);
  eq(recentNames(d0), ["Eight.gba", "Nine.gba", "Seven.gba"]);
  eq(libNames(drive), ["Eight.gba", "Nine.gba", "Seven.gba"]);
  assert.ok(drive.get("rom:Nine.gba"));
});

// DriveLibrary.bug_rename_during_pull_orphans / regress_rename_during_pull.
test("a rename made while a pull is downloading keeps its marker and its tile", async () => {
  const s = await setupA();
  const { d0, drive } = s;
  const p = await pullInFlight(s);
  assert.equal((await d0.api.renameGame("Seven.gba", "Siete.gba")).ok, true);
  await p.release();
  eq(recentNames(d0), ["Eight.gba", "Siete.gba"]);
  assert.ok(d0.api.syncState.ren.some((r) => r.from === "Seven.gba" && r.to === "Siete.gba"));
  await flush(d0);
  await pull(d0);
  eq(recentNames(d0), ["Eight.gba", "Siete.gba"]);
  eq(libNames(drive), ["Eight.gba", "Siete.gba"]);
  eq(localKeys(d0, "Siete.gba"), ["rom:Siete.gba"]);
  assert.ok(drive.get("rom:Siete.gba") && !drive.get("rom:Seven.gba"));
});

// Found by the model of the fixed code (DriveLibrary.regress_revived_chain):
// the renameGame claim alone is not enough when the game arriving at a
// retired name arrives by another device's rename marker. Device 0 renames
// A to B. Device 1 renames X into the freed name A and deletes it; device 0,
// not having pulled, plays X afterwards (so the delete is overruled and X
// lives on as A). The next merge then applied the stale A->B marker to it:
// X's save went under B, beside B's ROM, and X left the library.
test("a game renamed into a retired name by another device is not folded on by the old marker", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await importGame(d0, "A.gba", u8(10));
  await importGame(d0, "X.gba", u8(30));
  await flush(d0);
  await pull(d1);
  assert.equal((await d0.api.renameGame("A.gba", "B.gba")).ok, true);
  await flush(d0);
  await pull(d1);
  assert.equal((await d1.api.renameGame("X.gba", "A.gba")).ok, true);
  await flush(d1);
  await d1.api.deleteGameEverywhere("A.gba");
  await flush(d1);
  await play(d0, "X.gba", u8(31));
  await flush(d0);
  await pull(d0);
  await flush(d0);
  await pull(d0);

  eq(recentNames(d0), ["A.gba", "B.gba"], "X lives on as A, beside B");
  eq(libNames(drive), ["A.gba", "B.gba"]);
  eq(d0.idb.get("save:A.gba"), u8(31), "X's save stays with X's ROM");
  eq(d0.idb.get("rom:A.gba")?.data, u8(30));
  assert.equal(d0.idb.get("save:B.gba"), undefined, "B's ROM gained no save");
  eq(drive.get("save:A.gba")?.bytes, u8(31));
  assert.equal(drive.get("save:B.gba"), null);
});

// SavePersistence.open_pull_resurrects_reset_save (FINDINGS #7 family): a pull
// that downloaded a save before the person reset it (the game not loaded)
// wrote the old bytes back afterwards; the flush then deleted Drive's copy as
// the reset asked, and the next pull's reconcile uploaded the resurrected
// local copy again. The reset has to win over the in-flight download.
test("a save reset while a pull is downloading it stays reset, here and on Drive", async () => {
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

  const saveId = drive.get("save:G.gba").id;
  const h = drive.hold((e) => e.method === "GET" && e.url.includes("/" + saveId + "?alt=media"));
  const pulling = d0.api.pullSync();
  await h.reached;                              // the pull is downloading it...
  await d0.api.resetGameSaves("G.gba");         // ...when the person resets it
  h.release();
  await pulling;
  await settle();
  assert.equal(d0.idb.get("save:G.gba"), undefined, "the download did not write it back");

  await flush(d0);
  await pull(d0);
  await flush(d0);
  await pull(d0);
  assert.equal(d0.idb.get("save:G.gba"), undefined, "still reset here");
  assert.equal(drive.get("save:G.gba"), null, "and gone from Drive, not re-uploaded");
});

// Found while fixing the stale commits: renameGame (and applyRemoteRename)
// built the renamed sync state before its transaction and installed that
// copy after it, so a key queued in between (another game's save tick) was
// dropped.
test("a save queued while a rename's transaction is in flight stays queued", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  app.idb.set("rom:G.gba", { name: "G.gba", data: u8(1) });
  await app.api.dbPut("save:Other.gba", u8(3));
  let fired = false;
  app.state.idbFail = (op, key) => {
    if (!fired && op === "get" && key === "rom:H.gba") {
      fired = true;                     // inside dbMoveKeys' transaction
      app.api.markUpload("save:Other.gba");
    }
    return false;
  };
  assert.equal((await app.api.renameGame("G.gba", "H.gba")).ok, true);
  assert.ok(fired);
  assert.ok(app.api.syncState.queueUp.includes("save:Other.gba"),
    "the other game's save is still on its way to Drive");
  assert.ok(app.api.syncState.queueRen.some((q) => q.from === "rom:G.gba"));
});

// ── Deletes racing the flush's own uploads ─────────────────────────────────

const save = async (app, key, bytes) => {
  await app.api.dbPut(key, bytes);
  app.api.markUpload(key);
};
// Holds the next upload request (create or content PATCH).
const holdUpload = (drive) =>
  drive.hold((e) => e.url.includes("/upload/drive/v3/files"));

// Found by reading (index.js 2773-2779 at dd7ba741f): the outrank rule,
// meant for another device's newer write, read this device's own in-flight
// upload as one.
test("a delete asked for while the key's upload is in flight is not outranked by it", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await save(app, "save:G.gba", u8(1));
  const h = holdUpload(drive);
  const flushing = app.api.flushSync();
  await h.reached;
  await app.api.resetGameSaves("G.gba"); // the person resets the save
  h.release();
  await flushing;
  await settle();
  await app.api.flushSync();
  await settle();
  assert.equal(drive.get("save:G.gba"), null, "the reset reached Drive");
  eq(app.api.syncState.queueDel, []);
});

test("a key deleted before the flush reaches it is not uploaded at all", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await save(app, "save:G.gba", u8(1));
  await save(app, "state:G.gba", u8(5));
  const h = holdUpload(drive);           // save:G.gba goes first
  const flushing = app.api.flushSync();
  await h.reached;
  app.api.markDelete("state:G.gba");
  h.release();
  await flushing;
  await settle();
  await app.api.flushSync();
  await settle();
  eq(drive.names(), ["save:G.gba"]);
  assert.ok(!drive.log.some((e) => e.name === "state:G.gba"),
    "no request ever carried the deleted key");
});

// ── A pull and a load of the same game ─────────────────────────────────────
// A load reads a game's records and names the game only when its core boots
// (game-switch.test.mjs); until then the game is not "loaded", and the pull
// must not move or wipe the records under it. `loadingName` stands in for a
// load parked between its reads and the boot.

test("a rename from another device waits while the game it renames is loading", async () => {
  const { drive, d0, d1 } = await setupA();
  await play(d1, "Seven.gba", u8(71));
  assert.equal((await d0.api.renameGame("Seven.gba", "Nine.gba")).ok, true);
  await flush(d0);

  d1.runIn(`loadingName = "Seven.gba"`);
  await pull(d1);
  eq(localKeys(d1, "Seven.gba"), ["rom:Seven.gba", "save:Seven.gba"],
    "the records the load is reading stay where it reads them");
  eq(localKeys(d1, "Nine.gba"), []);

  d1.runIn("loadingName = null");
  await pull(d1);
  eq(localKeys(d1, "Seven.gba"), []);
  eq(localKeys(d1, "Nine.gba"), ["rom:Nine.gba", "save:Nine.gba"], "and move once it is done");
  eq(libNames(drive), ["Nine.gba"]);
});

test("a game deleted on another device is not wiped here while it is loading", async () => {
  const { d0, d1 } = await setupA();
  await play(d1, "Seven.gba", u8(71));
  await d0.api.deleteGameEverywhere("Seven.gba");
  await flush(d0);

  d1.runIn(`loadingName = "Seven.gba"`);
  await pull(d1, "Continue");
  eq(localKeys(d1, "Seven.gba"), ["rom:Seven.gba", "save:Seven.gba"],
    "the game being booted keeps its ROM and save");
});

// ── A Sync tap on a device that has not pulled yet ─────────────────────────

// The Sync button (runFullSync): queue every local file, flush, then pull,
// answering "Games removed on another device" with `answer`.
const syncTap = async (app, answer = "Continue") => {
  let done = false;
  const p = app.runIn("runFullSync()").then(() => { done = true; });
  for (let i = 0; i < 400 && !done; i++) {
    await new Promise((r) => setTimeout(r, 0));
    const m = openModal(app);
    if (m) { await findButton(m, answer).click(); m.classList.remove("sync-modal"); }
  }
  await p;
  await settle();
};

// DriveLibrary.regress_sync_tap_after_remote_delete (a UI QA run, d2/d2r):
// the flush uploaded any queued key Drive lacked without asking the library
// it had just merged, so a device that had not pulled a delete put the
// deleted game's files back on Drive, where nothing ever removed them; and a
// later re-import of the game on the deleting device pulled its OLD save back.
test("a Sync tap on a device that missed a delete does not put the game back on Drive", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await importGame(d0, "G.gba", u8(10));
  await play(d0, "G.gba", u8(11));
  await flush(d0);
  await pull(d1);
  assert.equal(await d1.api.downloadGame("G.gba"), true);
  await d0.api.deleteGameEverywhere("G.gba");
  await flush(d0);
  eq(drive.names(), [], "the delete reached Drive");

  await syncTap(d1);                       // d1 had not pulled the delete
  eq(drive.names(), [], "the Sync tap put nothing back");
  eq(recentNames(d1), [], "and d1 took the delete");
  assert.ok(drive.lib().tomb.some((t) => t.name === "G.gba"));

  await importGame(d0, "G.gba", u8(10));   // the same game, imported afresh
  await flush(d0);
  await pull(d0);
  assert.equal(d0.idb.get("save:G.gba"), undefined, "no old save comes back with it");
});

// Files of a deleted game that are on Drive anyway (put there by a build
// without the fix above, which a mixed-build household still runs) are
// removed by the next pull that sees the tombstone.
test("a pull removes Drive files of a game the library has deleted", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock, seed: {
    "rom:G.gba": u8(10), "save:G.gba": u8(11),
    library: { recents: [], tomb: [{ name: "G.gba", ts: 5 }], ren: [] },
  } });
  const d1 = await device(drive, clock);
  await pull(d1);
  await flush(d1);
  eq(drive.names(), [], "the orphans are gone");
});

// The same cause (d1 in the QA run): a device that had not pulled a rename
// uploaded the game once more under its old name.
test("a Sync tap on a device that missed a rename does not upload the old name", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await importGame(d0, "A.gba", u8(10));
  await play(d0, "A.gba", u8(11));
  await flush(d0);
  await pull(d1);
  assert.equal(await d1.api.downloadGame("A.gba"), true);
  assert.equal((await d0.api.renameGame("A.gba", "B.gba")).ok, true);
  await flush(d0);
  eq(drive.names(), ["rom:B.gba", "save:B.gba"]);

  await syncTap(d1);
  eq(drive.names(), ["rom:B.gba", "save:B.gba"], "no old-name file on Drive");
  eq(recentNames(d1), ["B.gba"], "and d1 took the rename");
  eq(d1.idb.get("save:B.gba"), u8(11));
  // The files the flush held back are queued under the new name now, and a
  // flush is on its way for them (else the lamp spins, the Sync button
  // disabled, until the next poll).
  assert.ok(d1.runIn("!!syncTimer"), "a flush is scheduled");
  await flush(d1);
  eq(d1.api.syncState.queueUp, [], "and it drains the queue");
  eq(drive.names(), ["rom:B.gba", "save:B.gba"]);
});

// Noticed in the same run (D5): an upload did not record the modifiedTime
// Drive gave it, so the next pull downloaded the file it had just sent.
test("a pull does not download what this device has just uploaded", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  await importGame(d0, "G.gba", u8(10));
  await play(d0, "G.gba", u8(11));
  await flush(d0);
  const id = drive.get("save:G.gba").id;
  const before = drive.log.length;
  await pull(d0);
  eq(drive.log.slice(before).filter((e) => e.url.includes("/" + id + "?alt=media")), [],
    "save:G.gba was not fetched back");
});
