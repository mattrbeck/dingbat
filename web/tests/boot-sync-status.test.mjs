// The boot pull says so from the first frame: the account slot turns its
// ring while a linked device's first pull is out, and ends it with the tick
// (or offline) - not the tick over a library Drive has not been asked about.
// The boot hint (localStorage) lets index.html draw the same before
// index.js runs.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes } from "./helpers.mjs";
import { makeDrive, until } from "./drivefake.mjs";

const HOUR = 3600 * 1000;

const linkedState = (extra = {}) => ({
  queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], sigs: {}, rmt: {},
  delTs: {}, acct: "a1", parked: {}, connected: true, email: "one@x", ...extra,
});

// tokeninfo held until the test answers; everything else reaches one Drive.
const boot = async (state) => {
  const app = await loadApp();
  const drive = makeDrive();
  const held = [];
  app.setFetch(async (url, opts = {}) => {
    url = String(url);
    if (url.startsWith("https://oauth2.googleapis.com/tokeninfo")) {
      return new Promise((resolve, reject) => {
        held.push({ opts, answer: () => resolve(jsonRes({ sub: "a1", email: "one@x" })) });
        opts.signal?.addEventListener("abort", () => reject(new Error("aborted")));
      });
    }
    return drive.fetch(url, opts);
  });
  app.idb.set("recent", []);
  await app.api.dbPut("gdrive_sync", state);
  await app.api.loadSyncState();
  // As initStorage does just before resumeDriveOnBoot.
  app.runIn("bootDriveHint = null; refreshSyncUI()");
  return { app, held };
};

const badge = (app) => app.document.getElementById("account-btn").dataset.sync;

test("a linked boot with a live token rings before tokeninfo answers, then ticks", async () => {
  const { app, held } = await boot(linkedState({ token: "tok1", tokenExp: Date.now() + HOUR }));
  const done = app.api.resumeDriveOnBoot();
  assert.equal(app.api.syncStatus, "syncing", "said before the first await");
  assert.equal(badge(app), "syncing");
  await until(() => held.length === 1, "tokeninfo asked");
  held[0].answer();
  await done;
  await until(() => app.api.syncStatus === "done", "the boot pull's tick");
  assert.equal(badge(app), "ok");
});

test("a hung tokeninfo is cut off and the boot pull goes on, as offline would", async () => {
  const { app, held } = await boot(linkedState({ token: "tok1", tokenExp: Date.now() + HOUR }));
  // Controllers the test can fire, standing in for the deadline's timer.
  const ctls = [];
  app.sandbox.AbortController = class {
    constructor() { this.signal = new EventTarget(); ctls.push(this); }
    abort() { this.signal.dispatchEvent(new Event("abort")); }
  };
  app.api.resumeDriveOnBoot();
  await until(() => held.length === 1, "tokeninfo asked");
  const ctl = ctls.find((c) => c.signal === held[0].opts.signal);
  assert.ok(ctl, "tokeninfo carries a deadline");
  ctl.abort();
  await until(() => app.api.syncStatus === "done", "the pull ran on the kept token");
  assert.equal(app.api.gdriveToken, "tok1", "the token is kept");
});

test("a linked boot that needs a tap for its token shows no ring", async () => {
  const { app } = await boot(linkedState({ token: null, tokenExp: 0 }));
  await app.api.resumeDriveOnBoot();
  assert.equal(app.api.syncStatus, "idle");
  assert.equal(badge(app), "ok");
});

test("the boot hint holds the account's initial and how the next boot starts", async () => {
  const exp = Date.now() + HOUR;
  const { app } = await boot(linkedState({ token: "tok1", tokenExp: exp }));
  assert.deepEqual(JSON.parse(app.localStorage.getItem("dingbat_drive")),
                   { i: "O", exp, rt: false });
  app.sandbox.google = { accounts: { oauth2: { revoke: () => {} } } };
  app.runIn("gdriveSignOut()");
  await until(() => app.localStorage.getItem("dingbat_drive") == null, "signed out drops it");
});

test("the slot keeps the hint's drawing until initStorage has read this boot's state", async () => {
  const app = await loadApp({
    localStorageSeed: { dingbat_drive: JSON.stringify({ i: "O", exp: Date.now() + HOUR, rt: false }) },
  });
  assert.notEqual(badge(app), "", "the module-level render left the hint's slot alone");
  assert.ok(app.runIn("bootDriveHint"));
  await app.runIn("initStorage()");
  assert.equal(app.runIn("bootDriveHint"), null);
  // Nothing linked in this IndexedDB: the real state draws the signed-out slot.
  assert.equal(badge(app), "");
  assert.equal(app.localStorage.getItem("dingbat_drive"), null);
});
