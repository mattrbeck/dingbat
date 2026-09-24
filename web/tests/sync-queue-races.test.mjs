// The upload queue while a flush is on the wire: a key saved again while its
// own upload (or an earlier one in the same flush) is in flight. Replays
// formal/WebState/DriveSession.lean's Queue traces against the real
// web/index.js, holding the Drive request mid-flight. Deletes racing an
// upload are in library-races.test.mjs.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";
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
  app.idb.set("recent", [{ name: "G.gba", ts: 1 }]);
  return app;
};
const save = async (app, key, bytes) => {
  await app.api.dbPut(key, bytes);
  app.api.markUpload(key);
};
// Holds the next upload request (create or content PATCH).
const holdUpload = (drive) =>
  drive.hold((e) => e.url.includes("/upload/drive/v3/files"));

// DriveSession.Queue.bug_redirty_dropped / regress_redirty_kept.
test("a save made while its own upload is in flight still reaches Drive", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await save(app, "save:G.gba", u8(1));
  const h = holdUpload(drive);
  const flushing = app.api.flushSync();
  await h.reached;                       // version 1 is on the wire
  await save(app, "save:G.gba", u8(2));  // the next 5 s tick writes version 2
  h.release();
  await flushing;
  await settle();
  eq(app.api.syncState.queueUp, ["save:G.gba"], "version 2 is still queued");

  await app.api.flushSync();
  await settle();
  eq(drive.get("save:G.gba").bytes, u8(2), "and the next flush sends it");
  eq(app.api.syncState.queueUp, []);
});

// A key still queued (not yet reached by the running flush) is re-read when
// its turn comes, so a second save of it needs nothing extra.
test("a save of a key still waiting its turn uploads its newest bytes once", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  await save(app, "save:G.gba", u8(1));
  await save(app, "state:G.gba", u8(5));
  const h = holdUpload(drive);
  const flushing = app.api.flushSync();
  await h.reached;
  await save(app, "state:G.gba", u8(6));
  h.release();
  await flushing;
  await settle();
  eq(drive.get("state:G.gba").bytes, u8(6));
  eq(app.api.syncState.queueUp, [], "nothing left over");
  eq(drive.log.filter((e) => e.name === "state:G.gba").length, 1);
});

