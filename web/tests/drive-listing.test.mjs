// What a sync sees of Drive: every page of the listing, and every file
// called "library" when more than one device created one.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";
import { makeDrive, makeClock, useClock } from "./drivefake.mjs";

const device = async (drive, clock, recent = []) => {
  const app = await loadApp();
  useClock(app, clock);
  app.setFetch(drive.fetch);
  app.api.gdriveToken = "tok";
  app.api.gdriveTokenExp = clock.peek() + 3600e3;
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
    sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
  };
  app.idb.set("recent", recent);
  return app;
};
const names = (lib) => lib.recents.map((r) => r.name).sort();

// Found by reading: driveListAll asked for one page and ignored
// nextPageToken, so past a page of files the library could be missed and a
// second one created.
test("a library past the first page of the listing is found, not duplicated", async () => {
  const clock = makeClock();
  const seed = {};
  for (let i = 0; i < 7; i++) seed["save:G" + i + ".gba"] = u8(i);
  seed.library = { recents: [{ name: "Old.gba", ts: 5 }], tomb: [], ren: [] };
  const drive = makeDrive({ clock, seed, pageSize: 3 }); // library is file 8 of 8
  const app = await device(drive, clock, [{ name: "New.gba", ts: 9 }]);
  app.api.syncState.tomb = [{ name: "Gone.gba", ts: 1 }]; // gives the flush work
  await app.api.flushSync();
  await settle();
  eq(drive.named("library").length, 1, "one library file");
  eq(names(drive.lib()), ["New.gba", "Old.gba"], "holding both devices' games");
  assert.ok(drive.log.some((e) => e.url.includes("pageToken=")), "the listing was paged");
});

// Found by reading: two devices syncing for the first time can each create
// a "library" file; each then reads and writes whichever one its listing
// happened to name last, and neither sees the other's games.
test("two devices that each created a library end up with one holding both", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const d0 = await device(drive, clock, [{ name: "A.gba", ts: 10 }]);
  const d1 = await device(drive, clock, [{ name: "B.gba", ts: 11 }]);
  for (const d of [d0, d1]) d.api.syncState.tomb = [{ name: "X.gba", ts: 1 }];
  // Device 0 has listed Drive (no library yet) and is about to create one...
  const h = drive.hold((e) => e.method === "POST" && e.url.includes("uploadType=multipart"));
  const f0 = d0.api.flushSync();
  await h.reached;
  // ...when device 1 runs a whole flush and creates its own.
  await d1.api.flushSync();
  await settle();
  h.release();
  await f0;
  await settle();
  eq(drive.named("library").length, 2, "the race leaves two library files");
  const oldest = drive.named("library")[0].id;

  await d0.api.pullSync();
  await settle();
  eq(drive.named("library").length, 1, "the next sync keeps one");
  eq(drive.named("library")[0].id, oldest, "the oldest, which every device picks");
  eq(names(drive.lib()), ["A.gba", "B.gba"], "with both devices' games in it");
  eq((d0.idb.get("recent") || []).map((r) => r.name).sort(), ["A.gba", "B.gba"]);

  await d1.api.pullSync();
  await settle();
  eq((d1.idb.get("recent") || []).map((r) => r.name).sort(), ["A.gba", "B.gba"]);
  eq(drive.named("library").length, 1);
});

test("a library copy that cannot be read is neither trusted nor deleted", async () => {
  const clock = makeClock();
  const drive = makeDrive({ clock, seed: {
    library: { recents: [{ name: "A.gba", ts: 10 }], tomb: [], ren: [] } } });
  drive.addDuplicate("library", { recents: [{ name: "B.gba", ts: 11 }], tomb: [], ren: [] });
  const bad = drive.named("library")[1].id;
  const app = await device(drive, clock);
  const real = drive.fetch;
  app.setFetch(async (url, opts) =>
    String(url).includes("/" + bad + "?alt=media") ? { ok: false, status: 500 } : real(url, opts));
  await app.api.pullSync();
  await settle();
  eq(drive.named("library").length, 2, "the unread copy is left for a later sync");
  eq(app.idb.get("recent"), [], "and the failed pull changed nothing here");
});
