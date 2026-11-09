// A library picture this device has never synced does not go over one on
// Drive it has not seen (index.js flush, "A picture this device has never
// synced"). Add pictures run offline, or while the pull was failing, takes
// a game's boot screen; coming back online the flush runs before the pull,
// and once sent that boot screen over the better picture another device had
// put on Drive. Now the picture stays queued, the pull brings Drive's down,
// and the entry drops. A picture over an older generation's (the game
// deleted and loaded again) still goes up, and so does any picture of a
// game whose picture has synced here before.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle } from "./helpers.mjs";
import { makeDrive } from "./drivefake.mjs";

const NAME = "frame:A.gba";
const ascii = (s) => new TextEncoder().encode(s);
const text = (f) => new TextDecoder().decode(f.bytes);
const blobText = async (b) => new TextDecoder().decode(new Uint8Array(await b.arrayBuffer()));

// This device: A.gba in its library with its ROM, and a picture of its own
// (the boot screen) queued for Drive. `sync` is the sync state's sigs/rmt.
const device = async (drive, { gen = 0, sync = {} } = {}) => {
  const app = await loadApp();
  app.setFetch(drive.fetch);
  app.api.gdriveToken = "test-token";
  app.api.gdriveTokenExp = Date.now() + 3600e3;
  app.api.syncState = { queueUp: [NAME], queueDel: [], queueRen: [], tomb: [], ren: [],
                        sigs: {}, rmt: {}, connected: true, ...sync };
  app.idb.set("recent", [{ name: "A.gba", ts: 1, ...(gen ? { gen } : {}) }]);
  app.idb.set("rom:A.gba", { name: "A.gba", data: ascii("ROM") });
  app.idb.set(NAME, new Blob([ascii("BOOT")], { type: "image/jpeg" }));
  return app;
};
// Drive with A.gba's ROM and another device's picture of it.
const driveWithPicture = (gen = 0) => {
  const drive = makeDrive({ seed: { "rom:A.gba": "ROM", [NAME]: "THEIRS" } });
  if (gen) drive.get(NAME).appProperties = { gen: String(gen) };
  return drive;
};
const pictureWrites = (drive) => drive.writes().filter((e) => e.name === NAME);

test("a picture never synced here waits while Drive holds one this device has not seen", async () => {
  const drive = driveWithPicture();
  const app = await device(drive);
  await app.api.flushSync();
  await settle();
  assert.equal(text(drive.get(NAME)), "THEIRS", "Drive's picture is not written over");
  assert.equal(pictureWrites(drive).length, 0);
  assert.ok(app.api.syncState.queueUp.includes(NAME), "still queued, for the pull to decide");
});

test("the pull then brings Drive's picture down, and the queued one drops", async () => {
  const drive = driveWithPicture();
  const app = await device(drive);
  await app.api.flushSync();
  await app.api.pullSync({ silent: true });
  await settle();
  assert.equal(await blobText(app.idb.get(NAME)), "THEIRS", "the tile shows Drive's picture");
  assert.ok(app.runIn("!!syncTimer"), "the pull schedules the flush that drops it");
  await app.api.flushSync();
  await settle();
  assert.ok(!app.api.syncState.queueUp.includes(NAME), "nothing left to send");
  assert.equal(pictureWrites(drive).length, 0, "and nothing was sent");
  assert.equal(text(drive.get(NAME)), "THEIRS");
});

test("a picture over an older generation's goes up (the game deleted and loaded again)", async () => {
  const drive = driveWithPicture(1);
  const app = await device(drive, { gen: 2 });
  await app.api.flushSync();
  await settle();
  assert.equal(text(drive.get(NAME)), "BOOT", "the old game's picture is written over");
  assert.equal(drive.get(NAME).appProperties?.gen, "2", "under this game's stamp");
  assert.ok(!app.api.syncState.queueUp.includes(NAME));
});

test("a picture of a game whose picture has synced here goes up as before", async () => {
  const drive = driveWithPicture();
  const app = await device(drive, { sync: { sigs: { [NAME]: "an older picture's" } } });
  await app.api.flushSync();
  await settle();
  assert.equal(text(drive.get(NAME)), "BOOT");
  assert.ok(!app.api.syncState.queueUp.includes(NAME));
});

test("so does one when Drive's picture is the one this device last saw", async () => {
  const drive = driveWithPicture();
  const app = await device(drive, { sync: { rmt: { [NAME]: drive.get(NAME).modifiedTime } } });
  await app.api.flushSync();
  await settle();
  assert.equal(text(drive.get(NAME)), "BOOT");
  assert.ok(!app.api.syncState.queueUp.includes(NAME));
});

// The game being played: the pull never brings its picture down, so a
// picture of it never synced here once waited for the game to close, and
// then lost to Drive's older one. Now the pull marks Drive's seen while the
// game keeps its picture up to date, and the flush sends this device's.
// `pictured`: the game has stored a picture of its own since it loaded.
const openHere = (app, { pictured = true } = {}) => app.runIn(
  `currentRomName = "A.gba"; currentOriginalName = "A.gba"; lastFrameSig = ${pictured ? '"its own"' : "null"};`);

test("the open game's own picture goes up: the pull marks Drive's seen", async () => {
  const drive = driveWithPicture();
  const app = await device(drive);
  openHere(app);
  await app.api.flushSync();
  await app.api.pullSync({ silent: true });
  await settle();
  assert.equal(await blobText(app.idb.get(NAME)), "BOOT", "the open game's picture is not replaced");
  assert.equal(app.api.syncState.rmt[NAME], drive.get(NAME).modifiedTime, "Drive's is seen");
  assert.ok(app.runIn("!!syncTimer"), "the pull schedules the flush that sends it");
  await app.api.flushSync();
  await settle();
  assert.equal(text(drive.get(NAME)), "BOOT", "this device's picture is on Drive");
  assert.ok(!app.api.syncState.queueUp.includes(NAME));
});

test("not while the open game's session is held back (its picture is not kept then)", async () => {
  const drive = driveWithPicture();
  const app = await device(drive);
  openHere(app);
  app.runIn(`sessionHeldFor = "A.gba";`);
  await app.api.pullSync({ silent: true });
  await app.api.flushSync();
  await settle();
  assert.equal(text(drive.get(NAME)), "THEIRS", "Drive's picture is not written over");
  assert.ok(app.api.syncState.queueUp.includes(NAME), "still queued, for a later pull");
});

test("not before the open game has stored a picture of its own (the queued one may be older)", async () => {
  const drive = driveWithPicture();
  const app = await device(drive);
  openHere(app, { pictured: false });
  await app.api.pullSync({ silent: true });
  await app.api.flushSync();
  await settle();
  assert.equal(text(drive.get(NAME)), "THEIRS", "the boot screen does not go up");
  assert.ok(app.api.syncState.queueUp.includes(NAME));
});

test("not while a Switch to another device's newer moment of the game is on offer", async () => {
  const drive = driveWithPicture();
  const app = await device(drive);
  openHere(app);
  offered(app, drive, { since: false });
  await app.api.pullSync({ silent: true });
  await app.api.flushSync();
  await settle();
  assert.equal(text(drive.get(NAME)), "THEIRS", "Drive keeps the other device's picture");
  assert.ok(app.api.syncState.queueUp.includes(NAME));
});

test("but once this device's own session has gone up over the offered one, the picture goes too", async () => {
  const drive = driveWithPicture();
  const app = await device(drive);
  openHere(app);
  offered(app, drive, { since: true });
  await app.api.pullSync({ silent: true });
  await app.api.flushSync();
  await settle();
  assert.equal(text(drive.get(NAME)), "BOOT", "this device's picture is on Drive");
  assert.ok(!app.api.syncState.queueUp.includes(NAME));
});

// The other device's session of A.gba was offered here ("Switch"), and marked
// seen as an offer does. `since`: this device's own session has gone up over
// it since (the player kept playing here), so Drive's session is not the one
// offered any more.
function offered(app, drive, { since }) {
  const f = drive.add("stateauto:A.gba", ascii(since ? "MINE" : "THEIRS"));
  const at = since ? "2025-01-01T00:00:00.000Z" : f.modifiedTime;
  app.api.syncState.rmt["stateauto:A.gba"] = f.modifiedTime;
  app.runIn(`handoffStash = { game: "A.gba",
    news: [{ key: "stateauto:A.gba", f: { modifiedTime: ${JSON.stringify(at)} } }] };`);
}
