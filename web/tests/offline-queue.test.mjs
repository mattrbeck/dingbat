// Intent recorded away from Drive. A device that has signed in once belongs
// to that account (syncState.acct, Google's subject id) whether or not it is
// signed in this minute, so a delete or a rename made offline or signed out
// is recorded and flushes when the same account comes back. A device that
// has never signed in records nothing. Every record is stamped with the
// moment it was asked for, so another device's newer write outranks it.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, jsonRes, bytesRes } from "./helpers.mjs";

const FILES_URL = "https://www.googleapis.com/drive/v3/files";
const TOKENINFO = "https://oauth2.googleapis.com/tokeninfo";

// A Drive stub whose listing is mutable, so a test can age a file.
const makeDrive = (names = [], { acct = "acct-1", email = "a@example.com" } = {}) => {
  const files = new Map(names.map((n, i) => [n, {
    id: "f" + i, name: n, size: "4", modifiedTime: "2026-01-01T00:00:00Z",
  }]));
  const deleted = [];
  const fetch = async (url, opts = {}) => {
    url = String(url);
    if (url.startsWith(TOKENINFO)) return jsonRes({ sub: acct, email });
    if (url.startsWith(FILES_URL + "?spaces=appDataFolder")) {
      return jsonRes({ files: [...files.values()] });
    }
    if (url.includes("alt=media")) return bytesRes(u8(1, 2, 3, 4));
    if (opts.method === "DELETE") {
      for (const [n, f] of files) if (url.includes("/" + f.id)) { deleted.push(n); files.delete(n); }
      return jsonRes({});
    }
    return jsonRes({ id: "up" });
  };
  return { files, deleted, fetch };
};

const blankSync = (over = {}) => ({
  queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
  sigs: {}, rmt: {}, delTs: {}, acct: null, parked: {}, connected: false, ...over,
});

const seed = (app, name = "A.gba") => {
  app.idb.set("recent", [{ name, ts: 100 }]);
  app.idb.set("rom:" + name, { name, data: u8(1, 2, 3, 4) });
  app.idb.set("save:" + name, u8(7));
};

// ── Who records, and who does not ──────────────────────────────────────────

test("never signed in: a delete records nothing, having nowhere to send it", async () => {
  const app = await loadApp();
  seed(app);
  app.api.syncState = blankSync();
  assert.equal(app.api.driveEnrolled(), false);

  await app.api.deleteGameEverywhere("A.gba");
  await settle();

  eq(app.api.syncState.queueDel, []);
  eq(app.api.syncState.tomb, []);
  assert.equal(app.idb.get("rom:A.gba"), undefined, "the local delete still happened");
});

test("signed out after signing in: the delete is recorded against that account", async () => {
  const app = await loadApp();
  seed(app);
  app.api.syncState = blankSync({ acct: "acct-1", connected: false });
  assert.equal(app.api.driveLinked(), false, "no live session");
  assert.equal(app.api.driveEnrolled(), true, "but the device belongs to an account");

  await app.api.deleteGameEverywhere("A.gba");
  await settle();

  assert.ok(app.api.syncState.queueDel.includes("rom:A.gba"));
  assert.ok(app.api.syncState.queueDel.includes("save:A.gba"));
  eq(app.api.syncState.tomb.map((t) => t.name), ["A.gba"], "and the tombstone is raised");
  assert.ok(app.api.syncState.tomb[0].ts > 0, "stamped when it was asked for");
});

test("offline while signed in already recorded: the session flag is what sign-out clears", async () => {
  const app = await loadApp();
  seed(app);
  app.api.syncState = blankSync({ acct: "acct-1", connected: true });
  app.setFetch(async () => { throw new Error("offline"); });

  await app.api.deleteGameEverywhere("A.gba");
  await settle();
  assert.ok(app.api.syncState.queueDel.includes("rom:A.gba"));

  await app.api.flushSync(); // the attempt fails
  await settle();
  assert.ok(app.api.syncState.queueDel.includes("rom:A.gba"),
    "the queue survives a failed flush");
});

// ── Coming back ────────────────────────────────────────────────────────────

test("signing back in carries out the delete queued while away", async () => {
  const app = await loadApp();
  const drive = makeDrive(["rom:A.gba", "save:A.gba"]);
  app.setFetch(drive.fetch);
  app.api.syncState = blankSync({
    acct: "acct-1",
    queueDel: ["rom:A.gba", "save:A.gba"],
    delTs: { "rom:A.gba": Date.parse("2026-02-01T00:00:00Z"),
             "save:A.gba": Date.parse("2026-02-01T00:00:00Z") },
    tomb: [{ name: "A.gba", ts: Date.parse("2026-02-01T00:00:00Z") }],
    connected: true,
  });
  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 3600e3;

  await app.api.flushSync();
  await settle();

  eq(drive.deleted.sort(), ["rom:A.gba", "save:A.gba"]);
  eq(app.api.syncState.queueDel, []);
  eq(Object.keys(app.api.syncState.delTs), [], "the stamps are spent with the queue");
});

test("a newer write on another device outranks an older queued delete", async () => {
  const app = await loadApp();
  const drive = makeDrive(["save:A.gba"]);
  // The other device wrote this save after the delete was asked for.
  drive.files.get("save:A.gba").modifiedTime = "2026-03-01T00:00:00Z";
  app.setFetch(drive.fetch);
  app.api.syncState = blankSync({
    acct: "acct-1",
    queueDel: ["save:A.gba"],
    delTs: { "save:A.gba": Date.parse("2026-02-01T00:00:00Z") },
    sigs: { "save:A.gba": "sig" },
    connected: true,
  });
  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 3600e3;

  await app.api.flushSync();
  await settle();

  eq(drive.deleted, [], "the newer write survives");
  assert.ok(drive.files.has("save:A.gba"));
  eq(app.api.syncState.queueDel, [], "and the delete is dropped, not retried forever");
  assert.equal(app.api.syncState.sigs["save:A.gba"], "sig",
    "what is known about the surviving file is left alone");
});

test("a delete still wins over a write that came before it", async () => {
  const app = await loadApp();
  const drive = makeDrive(["save:A.gba"]);
  drive.files.get("save:A.gba").modifiedTime = "2026-01-01T00:00:00Z";
  app.setFetch(drive.fetch);
  app.api.syncState = blankSync({
    acct: "acct-1",
    queueDel: ["save:A.gba"],
    delTs: { "save:A.gba": Date.parse("2026-02-01T00:00:00Z") },
    connected: true,
  });
  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 3600e3;

  await app.api.flushSync();
  await settle();
  eq(drive.deleted, ["save:A.gba"]);
});

test("the library merge settles a game the same way: newer play beats older delete", async () => {
  const app = await loadApp();
  const older = Date.parse("2026-02-01T00:00:00Z");
  const newer = Date.parse("2026-03-01T00:00:00Z");

  // Deleted here on the 1st, played on another device on the 1st of March.
  const kept = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: newer }], tomb: [], ren: [] },
    { recents: [], tomb: [{ name: "A.gba", ts: older }], ren: [] });
  eq(kept.recents.map((r) => r.name), ["A.gba"], "the newer play wins");
  eq(kept.tomb, []);

  // The other way round, the delete stands.
  const gone = app.api.mergeLibrary(
    { recents: [{ name: "A.gba", ts: older }], tomb: [], ren: [] },
    { recents: [], tomb: [{ name: "A.gba", ts: newer }], ren: [] });
  eq(gone.recents, []);
  eq(gone.tomb.map((t) => t.name), ["A.gba"]);
});

// ── More than one account on one device ────────────────────────────────────

test("a different account parks the first account's work and starts clean", async () => {
  const app = await loadApp();
  app.api.syncState = blankSync({
    acct: "acct-1",
    queueDel: ["rom:A.gba"],
    delTs: { "rom:A.gba": 1000 },
    tomb: [{ name: "A.gba", ts: 1000 }],
    sigs: { "rom:A.gba": "sig" },
    connected: false,
  });

  await app.api.adoptDriveAccount("acct-2");

  assert.equal(app.api.syncState.acct, "acct-2");
  eq(app.api.syncState.queueDel, [], "acct-2 starts with nothing of acct-1's");
  eq(app.api.syncState.tomb, []);
  eq(app.api.syncState.sigs, {}, "and knows nothing about acct-2's Drive yet");
  const parked = app.api.syncState.parked["acct-1"];
  assert.ok(parked, "acct-1's work is kept, not thrown away");
  eq(parked.queueDel, ["rom:A.gba"]);
  eq(parked.tomb.map((t) => t.name), ["A.gba"]);
});

test("the first account signing back in gets its work returned", async () => {
  const app = await loadApp();
  app.api.syncState = blankSync({ acct: "acct-1", queueDel: ["rom:A.gba"],
                                  tomb: [{ name: "A.gba", ts: 1000 }] });
  await app.api.adoptDriveAccount("acct-2");
  await app.api.adoptDriveAccount("acct-1");

  assert.equal(app.api.syncState.acct, "acct-1");
  eq(app.api.syncState.queueDel, ["rom:A.gba"], "waiting where it was left");
  eq(app.api.syncState.tomb.map((t) => t.name), ["A.gba"]);
  assert.equal(app.api.syncState.parked["acct-1"], undefined, "and no longer parked");
  assert.ok(app.toasts.some((t) => /saved for this account/i.test(t)),
    "the player is told: " + app.toasts.join(" | "));
});

test("the same account signing in again changes nothing", async () => {
  const app = await loadApp();
  app.api.syncState = blankSync({ acct: "acct-1", queueDel: ["rom:A.gba"] });
  await app.api.adoptDriveAccount("acct-1");
  eq(app.api.syncState.queueDel, ["rom:A.gba"]);
  eq(app.api.syncState.parked, {});
});

test("the account is learned at sign-in, from the id beside the address", async () => {
  const app = await loadApp();
  const drive = makeDrive([], { acct: "sub-123", email: "player@example.com" });
  app.setFetch(drive.fetch);
  app.api.syncState = blankSync();
  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 3600e3;

  await app.api.gdriveFetchEmail(); // what gdriveConnect calls once it holds a token
  await settle();

  assert.equal(app.api.syncState.acct, "sub-123");
  assert.equal(app.api.gdriveEmail, "player@example.com");
});

test("signing out keeps the account tag and the queue, and drops the address", async () => {
  const app = await loadApp();
  app.api.syncState = blankSync({ acct: "sub-123", connected: true,
                                  queueDel: ["rom:A.gba"], email: "player@example.com" });
  app.api.gdriveEmail = "player@example.com";

  app.api.gdriveSignOut();
  await settle();

  assert.equal(app.api.syncState.connected, false);
  assert.equal(app.api.gdriveEmail, null, "no address left behind");
  assert.equal(app.api.syncState.email, null);
  assert.equal(app.api.syncState.acct, "sub-123", "but the queue's owner is remembered");
  eq(app.api.syncState.queueDel, ["rom:A.gba"], "and the work waits for it");
  assert.equal(app.api.driveEnrolled(), true);
});
