// A pull downloading a game's file while the game is renamed here does not
// write it under the old name (formal/WebState/Thumbnails.lean,
// bug_pull_after_rename_orphans_frame / regress_pull_after_rename_orphans_frame).
//
// The rename moves the game's records to the new name; a picture (or save)
// written afterwards under the old one was an orphan, and a later rename of
// any game to that name failed: "already exists in your library".

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, settle } from "./helpers.mjs";
import { makeDrive, makeClock, useClock } from "./drivefake.mjs";

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

const drain = async (n = 20) => { for (let i = 0; i < n; i++) await settle(); };

for (const kind of ["frame", "save"]) {
  test(`a ${kind} downloading while its game is renamed does not land under the old name (bug_pull_after_rename_orphans_frame)`, async () => {
    const clock = makeClock();
    const drive = makeDrive({ clock });
    const app = await device(drive, clock);
    await app.api.addRecentRom("G.gba", u8(10));
    await drain();
    await app.api.flushSync();
    await drain();

    // Another device's newer file for G, which the next pull fetches...
    const f = drive.add(kind + ":G.gba", u8(1, 2, 3));
    const h = drive.hold((e) => e.method === "GET" && e.url.includes("/" + f.id + "?alt=media"));
    const pulling = app.api.pullSync();
    await h.reached;
    // ...while the person renames G.
    const r = await app.runIn(`renameGame("G.gba", "H.gba")`);
    assert.ok(r.ok, JSON.stringify(r));
    h.release();
    await pulling;
    await drain();

    assert.equal(app.idb.get(kind + ":G.gba"), undefined, "nothing under the old name");
    // The old name is free again: another game can take it.
    await app.api.addRecentRom("K.gba", u8(11));
    await drain();
    const back = await app.runIn(`renameGame("K.gba", "G.gba")`);
    assert.ok(back.ok, JSON.stringify(back));
  });
}

// A name renamed away from is released once a game holds it again here, and
// the pull writes that game's files under it once more
// (formal/WebState/DriveLibrary.lean: regress_remote_rename_into_away_name_skips_saves,
// regress_download_into_away_name_skips_saves). Before be44ad4c only a rename
// into the name here or a fresh import released it; every pull of the session
// then skipped the game's save, and this device's next save went up over the
// other device's progress.

const flush = async (app) => { await app.api.flushSync(); await drain(); };
const pull = async (app) => { await app.api.pullSync(); await drain(); };
const play = async (app, name, bytes) => {
  await app.api.touchRecent(name);
  await app.api.dbPut("save:" + name, bytes);
  app.api.markUpload("save:" + name);
};
const bytesOf = (v) => [...(v?.data ?? v ?? [])];
// Another device's newer save, as its flush leaves it on Drive.
const newerOnDrive = (drive, clock, name, bytes) => {
  const f = drive.get(name);
  f.bytes = bytes;
  f.modifiedTime = new Date(clock()).toISOString();
};

test("a name another device's rename brings back is written by the pull again (bug_remote_rename_into_away_name_skips_saves)", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await d0.api.addRecentRom("G.gba", u8(10));
  await d0.api.addRecentRom("X.gba", u8(30));
  await drain();
  await flush(d0);
  await pull(d1);
  assert.equal(await d1.api.downloadGame("X.gba"), true);

  // Device 0 renames G away; device 1 renames X into the freed G.
  const r = await d0.runIn(`renameGame("G.gba", "H.gba")`);
  assert.ok(r.ok, JSON.stringify(r));
  await flush(d0);
  await pull(d1);
  const r1 = await d1.runIn(`renameGame("X.gba", "G.gba")`);
  assert.ok(r1.ok, JSON.stringify(r1));
  await flush(d1);
  await play(d1, "G.gba", u8(31));
  await flush(d1);

  // Device 0's pull applies X -> G: device 0 holds that game under G now.
  await pull(d0);
  assert.deepEqual(bytesOf(d0.idb.get("rom:G.gba")), [30], "X's ROM moved under G");
  newerOnDrive(drive, clock, "save:G.gba", u8(32));
  await pull(d0);
  assert.deepEqual(bytesOf(d0.idb.get("save:G.gba")), [32], "device 1's save written under G");
});

test("a Drive-only game downloaded under a name renamed away from is written by the pull again (bug_download_into_away_name_skips_saves)", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock);
  const d1 = await device(drive, clock);
  await d0.api.addRecentRom("G.gba", u8(10));
  await drain();
  await flush(d0);
  const r = await d0.runIn(`renameGame("G.gba", "H.gba")`);
  assert.ok(r.ok, JSON.stringify(r));
  await flush(d0);

  // Device 1 loads another game as G and plays it; device 0 downloads it.
  await pull(d1);
  await d1.api.addRecentRom("G.gba", u8(20));
  await drain();
  await play(d1, "G.gba", u8(21));
  await flush(d1);
  await pull(d0);
  assert.equal(await d0.api.downloadGame("G.gba"), true);
  assert.deepEqual(bytesOf(d0.idb.get("save:G.gba")), [21]);

  // Device 1 plays on; device 0's next pull brings it down.
  newerOnDrive(drive, clock, "save:G.gba", u8(22));
  await pull(d0);
  assert.deepEqual(bytesOf(d0.idb.get("save:G.gba")), [22], "device 1's newer save written under G");
});
