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
