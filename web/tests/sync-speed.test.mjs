// What a sync costs in Drive round trips (web/e2e/sync-bench.mjs times it):
// several requests in flight at once, none for what has not changed, and no
// ROM read just to learn it is there.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";
import { makeDrive, makeClock, useClock } from "./drivefake.mjs";

const GAMES = ["A.gba", "B.gba", "C.gba", "D.gba"];

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
  app.idb.set("recent", GAMES.map((name, i) => ({ name, ts: i + 1 })));
  return app;
};

// A ROM record that counts how often its bytes are read.
const countedRom = (name, reads) => ({
  name,
  get data() { reads.n++; return u8(1, 2, 3, 4); },
});

const writes = (drive, from) =>
  drive.log.slice(from).filter((e) => e.method === "POST" || e.method === "PATCH");

test("a Sync now that changes nothing writes nothing to Drive", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  for (const g of GAMES) {
    app.idb.set("rom:" + g, { name: g, data: u8(1, 2, 3) });
    app.idb.set("save:" + g, u8(9, GAMES.indexOf(g)));
  }
  await app.runIn("runFullSync()");
  await settle();
  assert.ok(drive.get("library"), "the first sync wrote the library");
  const from = drive.log.length;
  await app.runIn("runFullSync()");
  await settle();
  eq(writes(drive, from), [], "no upload, not even the library's");
  const lists = drive.log.slice(from).filter((e) => e.url.includes("?spaces=appDataFolder"));
  assert.equal(lists.length, 2, "one listing for the flush, one for the pull");
});

test("Sync now reads no ROM Drive already holds, and a pull reads none to learn it is here", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  const reads = { n: 0 };
  app.idb.set("rom:A.gba", countedRom("A.gba", reads));
  app.idb.set("save:A.gba", u8(9, 1));
  await app.runIn("runFullSync()");
  await settle();
  assert.ok(drive.get("rom:A.gba"), "the ROM went up once");
  reads.n = 0;
  // Another device saves; this one pulls it and syncs again.
  const f = drive.get("save:A.gba");
  f.bytes = u8(9, 2);
  f.modifiedTime = new Date(Date.parse(f.modifiedTime) + 60e3).toISOString();
  await app.runIn("runFullSync()");
  await settle();
  eq(app.idb.get("save:A.gba"), u8(9, 2), "the other device's save landed");
  assert.equal(reads.n, 0, "the ROM's bytes were never read");
});

test("a pull keeps downloading while one download is slow, and writes in order", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await device(drive, clock);
  for (const g of GAMES) app.idb.set("rom:" + g, { name: g, data: u8(1) });
  for (const g of GAMES) drive.add("save:" + g, u8(7, GAMES.indexOf(g)));
  const firstId = drive.get("save:A.gba").id;
  const h = drive.hold((e) => e.url.includes(firstId) && e.url.includes("alt=media"));
  const pulling = app.api.pullSync();
  await h.reached;
  await settle();
  const fetched = drive.log.filter((e) => e.url.includes("alt=media")).length;
  assert.ok(fetched >= GAMES.length, `the other saves were fetched meanwhile (${fetched})`);
  assert.equal(app.idb.get("save:B.gba"), undefined, "but none written ahead of A's");
  h.release();
  await pulling;
  await settle();
  for (const g of GAMES) eq(app.idb.get("save:" + g), u8(7, GAMES.indexOf(g)));
});
