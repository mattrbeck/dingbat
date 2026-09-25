// A deleted game loaded again, and the save it used to have.
//
// Delete a game, then load it again from its file, and a device that had not
// pulled the delete could hand the new copy its old save: its next sync
// uploaded the save, the library let it through (a newer entry drops the
// tombstone), and the deleting device pulled it into the new game. The delete
// is respected now. Every library entry has a generation, a new one when a
// game is loaded again after a delete; the tombstone keeps the generation it
// deleted and when. A save from an older generation is never applied to the
// newer game. It is kept aside, as "a save from before you deleted this
// game", in the game's menu and its Manage Saves, with a Restore that swaps
// it with the current save (so the Restore undoes itself), for 30 days from
// the delete, here and on Drive.
//
// formal/WebState/DriveLibrary.lean: bug_reimport_gets_deleted_save,
// regress_reimport_keeps_deleted_save_aside.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";
import { makeDrive, useClock } from "./drivefake.mjs";

const DAY = 24 * 3600 * 1000;

// makeClock's, with a way to let a month go by.
const makeClock = (start = Date.parse("2026-03-01T00:00:00Z")) => {
  let t = start;
  const clock = () => (t += 1000);
  clock.peek = () => t;
  clock.jump = (ms) => { t += ms; };
  return clock;
};

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
// The token outlives a jumped clock.
const renew = (app, clock) => { app.api.gdriveTokenExp = clock.peek() + 3600e3; };

const importGame = async (app, name, bytes) => {
  await app.api.addRecentRom(name, bytes);
  await settle();
};
const play = async (app, name, bytes) => {
  await app.api.touchRecent(name);
  await app.api.dbPut("save:" + name, bytes);
  app.api.markUpload("save:" + name);
};
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
const localKeys = (app, name) =>
  [...app.idb.keys()].filter((k) => typeof k === "string" && k.endsWith(":" + name)).sort();
const kept = (app, name) => app.idb.get("oldsave:" + name);
const tileMenuLabels = async (app, name) => {
  await app.api.openTileMenu(name, app.document.createElement("div"), null);
  const labels = app.document.getElementById("tile-menu-items").children
    .map((b) => b.children.find((c) => c.className === "tile-menu-label")?.textContent);
  app.api.closeTileMenu();
  return labels;
};

// Device 0 imports G and saves; device 1 downloads it and plays on.
const twoDevices = async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await importGame(d0, "G.gba", u8(10));
  await play(d0, "G.gba", u8(11));
  await flush(d0);
  await pull(d1);
  assert.equal(await d1.api.downloadGame("G.gba"), true);
  return { clock, drive, d0, d1 };
};

// The design question left open by the web audit (formal/FINDINGS.md): device
// 0 deletes the game and loads it again; device 1, which has not pulled the
// delete, syncs its save. Device 0 got that save back in the new game.
test("a device that missed the delete does not hand its old save to the game loaded again", async () => {
  const { drive, d0, d1 } = await twoDevices();
  await play(d1, "G.gba", u8(12));          // progress on device 1, not yet sent
  await d0.api.deleteGameEverywhere("G.gba");
  await flush(d0);
  await importGame(d0, "G.gba", u8(10));    // the same file, loaded again
  await flush(d0);

  await flush(d1);                          // device 1 has not pulled the delete
  await pull(d0);
  assert.equal(d0.idb.get("save:G.gba"), undefined,
    "the game loaded again starts without the deleted game's save");
  assert.equal(drive.get("save:G.gba"), null, "and Drive holds no save for it");

  // Device 1 pulls: its copy of the deleted game gives way to the new one,
  // and its save is kept aside rather than lost.
  await pull(d1);
  assert.equal(d1.idb.get("save:G.gba"), undefined);
  eq(kept(d1, "G.gba")?.data, u8(12), "device 1 keeps its save aside");
  eq(localKeys(d1, "G.gba"), ["oldsave:G.gba"], "and nothing else of the deleted game");
  eq(recentNames(d1), ["G.gba"], "the game is still in its library");
  assert.ok(d1.toasts.some((t) => t.includes("deleted") && t.includes("30 days")),
    "and it says what happened: " + JSON.stringify(d1.toasts));

  await flush(d1);
  await pull(d0);
  eq(kept(d0, "G.gba")?.data, u8(12), "the kept save reaches the device that deleted the game");
  assert.equal(d0.idb.get("save:G.gba"), undefined, "without being applied");
  assert.ok(d0.toasts.some((t) => t.includes("from before you deleted it")),
    "and says so there too: " + JSON.stringify(d0.toasts));
  assert.ok((await tileMenuLabels(d0, "G.gba")).includes("Restore old save"),
    "the game's menu offers it");

  // Restored, it is the game's save everywhere, and nothing is offered in
  // its place: there was no save to keep.
  await d0.runIn(`restoreKeptSave("G.gba")`);
  eq(d0.idb.get("save:G.gba"), u8(12));
  assert.equal(kept(d0, "G.gba")?.data, null, "there was no save to keep in its place");
  assert.ok(!(await tileMenuLabels(d0, "G.gba")).includes("Restore old save"));
  await flush(d0);
  eq(drive.get("save:G.gba")?.bytes, u8(12));
  // Device 1 still holds the copy it kept: the restore outranks it there
  // too, so the save is not offered again anywhere.
  await pull(d1);
  await flush(d1);
  assert.equal(kept(d1, "G.gba")?.data, null, "the restore retires device 1's copy too");
  await pull(d0);
  assert.equal(kept(d0, "G.gba")?.data, null, "and device 1 does not send it back");
  assert.equal(await d1.api.downloadGame("G.gba"), true);
  eq(d1.idb.get("save:G.gba"), u8(12));
});

// Device 1 plays the game after the delete (a later play overrules a delete,
// as before), and device 0, not having pulled that, loads the game again: the
// save device 1 uploaded belongs to the deleted game.
test("a save uploaded for the deleted game is kept aside, not applied, after the game is loaded again", async () => {
  const { drive, d0, d1 } = await twoDevices();
  await d0.api.deleteGameEverywhere("G.gba");
  await flush(d0);
  await play(d1, "G.gba", u8(12));
  await flush(d1);
  eq(drive.get("save:G.gba")?.bytes, u8(12), "device 1's later play put its save on Drive");

  await importGame(d0, "G.gba", u8(10));
  await flush(d0);
  await pull(d0);
  assert.equal(d0.idb.get("save:G.gba"), undefined, "not applied to the game loaded again");
  eq(kept(d0, "G.gba")?.data, u8(12), "kept aside instead");
  await flush(d0);
  assert.equal(drive.get("save:G.gba"), null, "and taken off Drive, where it would be the new game's");

  await pull(d1);
  assert.equal(d1.idb.get("save:G.gba"), undefined, "device 1 gives way to the new game too");
  eq(kept(d1, "G.gba")?.data, u8(12));
});

// The same device, no second one: delete, load again, then sync. The flush
// used to read the newer entry as "the delete was not meant" and cancel the
// queued file deletes, so the old save stayed on Drive for every other device.
test("deleting and loading a game again before a sync still takes its old files off Drive", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  await importGame(d0, "G.gba", u8(10));
  await play(d0, "G.gba", u8(11));
  await d0.api.dbPut("state:G.gba", u8(5));
  d0.api.markUpload("state:G.gba");
  await flush(d0);
  await d0.api.deleteGameEverywhere("G.gba");
  await importGame(d0, "G.gba", u8(10));
  await flush(d0);
  eq(drive.names(), ["rom:G.gba"], "the old save and state are gone from Drive");

  const d2 = await device(drive, clock);
  await pull(d2);
  assert.equal(await d2.api.downloadGame("G.gba"), true);
  assert.equal(d2.idb.get("save:G.gba"), undefined, "a third device gets no old save");
});

test("a kept save lasts 30 days from the delete, then leaves every device and Drive", async () => {
  const { clock, drive, d0, d1 } = await twoDevices();
  await play(d1, "G.gba", u8(12));
  await d0.api.deleteGameEverywhere("G.gba");
  await flush(d0);
  await importGame(d0, "G.gba", u8(10));
  await flush(d0);
  await flush(d1);
  await pull(d1);
  await flush(d1);
  await pull(d0);
  eq(kept(d0, "G.gba")?.data, u8(12));
  assert.ok(drive.get("oldsave:G.gba"));

  clock.jump(29 * DAY);
  renew(d0, clock);
  renew(d1, clock);
  await pull(d0);
  await flush(d0);
  eq(kept(d0, "G.gba")?.data, u8(12), "still there after 29 days");
  assert.ok(drive.get("oldsave:G.gba"));

  clock.jump(2 * DAY);
  renew(d0, clock);
  renew(d1, clock);
  await pull(d0);
  await flush(d0);
  assert.equal(kept(d0, "G.gba"), undefined, "gone after 31");
  assert.equal(drive.get("oldsave:G.gba"), null, "from Drive too");
  assert.ok(!(await tileMenuLabels(d0, "G.gba")).includes("Restore old save"));
  await pull(d1);
  await flush(d1);
  assert.equal(kept(d1, "G.gba"), undefined, "and from the other device");
  assert.equal(drive.get("oldsave:G.gba"), null, "which does not put it back");
});

test("restoring a kept save keeps the save it replaced, so a second restore undoes it", async () => {
  const { drive, d0, d1 } = await twoDevices();
  await play(d1, "G.gba", u8(12));
  await d0.api.deleteGameEverywhere("G.gba");
  await flush(d0);
  await importGame(d0, "G.gba", u8(10));
  await play(d0, "G.gba", u8(20));          // progress in the game loaded again
  await flush(d0);
  await flush(d1);
  await pull(d1);
  await flush(d1);
  await pull(d0);
  eq(d0.idb.get("save:G.gba"), u8(20));
  eq(kept(d0, "G.gba")?.data, u8(12));

  await d0.runIn(`restoreKeptSave("G.gba")`);
  eq(d0.idb.get("save:G.gba"), u8(12), "the kept save is the game's save now");
  eq(kept(d0, "G.gba")?.data, u8(20), "and the one it replaced is kept in its place");
  assert.ok((await tileMenuLabels(d0, "G.gba")).includes("Restore old save"));

  await d0.runIn(`restoreKeptSave("G.gba")`);
  eq(d0.idb.get("save:G.gba"), u8(20), "the second restore undoes the first");
  eq(kept(d0, "G.gba")?.data, u8(12));
  await flush(d0);
  eq(drive.get("save:G.gba")?.bytes, u8(20));
});

// mergeLibrary with generations. An entry or tombstone written before them
// has none, and is generation 0: those merge exactly as they always have.
test("mergeLibrary: a newer generation stands beside the tombstone of the one it replaced", () => {
  return (async () => {
    const app = await loadApp();
    const m = (a, b) => structuredClone(app.api.mergeLibrary(a, b));
    const lib = (recents = [], tomb = [], ren = []) => ({ recents, tomb, ren });

    // Without generations, what it always did: a newer play drops the
    // tombstone, an older one is dropped by it.
    eq(m(lib([{ name: "G", ts: 20 }]), lib([], [{ name: "G", ts: 10 }])),
      lib([{ name: "G", ts: 20 }], []));
    eq(m(lib([{ name: "G", ts: 5 }]), lib([], [{ name: "G", ts: 10 }])),
      lib([], [{ name: "G", ts: 10 }]));

    // Loaded again after the delete: both stand, the entry at generation 1.
    eq(m(lib([{ name: "G", ts: 20, imp: 20, gen: 1 }]), lib([], [{ name: "G", ts: 10 }])),
      lib([{ name: "G", ts: 20, imp: 20, gen: 1 }], [{ name: "G", ts: 10 }]));
    // A play of the deleted generation, however late, does not replace it.
    eq(m(lib([{ name: "G", ts: 20, imp: 20, gen: 1 }]),
         lib([{ name: "G", ts: 30 }], [{ name: "G", ts: 10 }])),
      lib([{ name: "G", ts: 20, imp: 20, gen: 1 }], [{ name: "G", ts: 10 }]));
    // A delete of generation 1 supersedes the tombstone of generation 0 and
    // removes an entry of either.
    eq(m(lib([{ name: "G", ts: 20, imp: 20, gen: 1 }], [{ name: "G", ts: 10 }]),
         lib([], [{ name: "G", ts: 25, gen: 1 }])),
      lib([], [{ name: "G", ts: 25, gen: 1 }]));
    eq(m(lib([{ name: "G", ts: 40 }]), lib([], [{ name: "G", ts: 25, gen: 1 }])),
      lib([], [{ name: "G", ts: 25, gen: 1 }]));
    // A rename carries the generation to the new name.
    eq(m(lib([{ name: "G", ts: 20, imp: 20, gen: 1 }]), lib([], [], [{ from: "G", to: "H", ts: 30 }])),
      lib([{ name: "H", ts: 20, imp: 30, gen: 1 }], [], [{ from: "G", to: "H", ts: 30 }]));
  })();
});

// Without Drive there is no second copy to come back from: a delete wipes
// every record of the game here, so loading it again starts clean. (A guard,
// not a regression: this held before the change too.)
test("without Drive, a game deleted and loaded again starts without its old save", async () => {
  const app = await loadApp();
  app.idb.set("recent", []);
  await importGame(app, "G.gba", u8(10));
  await play(app, "G.gba", u8(11));
  await app.api.deleteGameEverywhere("G.gba");
  await importGame(app, "G.gba", u8(10));
  eq(localKeys(app, "G.gba"), ["rom:G.gba"]);
  eq(app.api.syncState.tomb, []);
});

// The deleted game open on device 1 when the news arrives: nothing is wiped
// under it, and nothing of it goes up as the new game's. It gives way at the
// first pull after it closes.
test("a device playing the deleted game gives way once it closes, sending nothing up meanwhile", async () => {
  const { drive, d0, d1 } = await twoDevices();
  await d0.api.deleteGameEverywhere("G.gba");
  await flush(d0);
  await importGame(d0, "G.gba", u8(10));
  await flush(d0);

  d1.api.currentOriginalName = "G.gba";     // device 1 is in the game
  await pull(d1);
  eq(localKeys(d1, "G.gba"), ["rom:G.gba", "save:G.gba"], "nothing wiped under the running game");
  await play(d1, "G.gba", u8(13));
  await flush(d1);
  assert.equal(drive.get("save:G.gba"), null, "its save does not go up as the new game's");
  await pull(d1);
  await flush(d1);
  assert.equal(drive.get("save:G.gba"), null, "nor on the next sync");

  d1.api.currentOriginalName = null;        // closed
  await pull(d1);
  eq(localKeys(d1, "G.gba"), ["oldsave:G.gba"]);
  eq(kept(d1, "G.gba")?.data, u8(13));
});

test("Manage Saves offers the loaded game's kept save, with when it was saved", async () => {
  const { d0, d1 } = await twoDevices();
  await play(d1, "G.gba", u8(12));
  await d0.api.deleteGameEverywhere("G.gba");
  await flush(d0);
  await importGame(d0, "G.gba", u8(10));
  await flush(d0);
  await flush(d1);
  await pull(d1);
  await flush(d1);
  await pull(d0);

  const row = d0.document.getElementById("kept-save-row");
  d0.api.currentOriginalName = null;
  d0.runIn("openSavesModal()");
  await settle();
  assert.equal(row.hidden, true, "no game, no row");
  d0.runIn("closeSavesModal()");
  d0.api.currentOriginalName = "G.gba";
  d0.runIn("openSavesModal()");
  for (let i = 0; i < 5; i++) await settle();
  assert.equal(row.hidden, false);
  assert.equal(d0.document.getElementById("kept-save-label").textContent,
    "Save from before you deleted this game");
  assert.match(d0.document.getElementById("kept-save-sub").textContent,
    /^Saved .* · kept until /);
});
