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
