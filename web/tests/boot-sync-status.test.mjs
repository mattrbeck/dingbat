// The boot pull says so from the first frame: the account slot turns its
// ring while a linked device's first pull is out, and ends it with the tick
// (or offline) - not the tick over a library Drive has not been asked about.
// The boot hint (localStorage) lets index.html draw the same before
// index.js runs.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
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

// --- The boot hint's script (index.html) agrees with driveBootSyncs --------
// The same decision is written twice, once for before index.js runs; this
// runs the page's own script on the hint the app wrote, for each kind of
// boot, and holds the two to one answer.

const HTML = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const HINT_SCRIPT = [...HTML.matchAll(/<script>([\s\S]*?)<\/script>/g)]
  .map((m) => m[1]).find((src) => src.includes("dingbat_drive"));

// The script on the markup's slot (the signed-out outline): what it draws,
// from `hint` (a stored string).
const runHintScript = (hint, { onLine = true } = {}) => {
  const el = (id) => ({ id, dataset: {}, textContent: "", title: "", classes: new Set(),
                        classList: { add(c) { this.owner.classes.add(c); } },
                        setAttribute(k, v) { this[k] = v; } });
  const els = { "account-slot": el("account-slot"), "account-btn": el("account-btn"),
                "account-avatar": el("account-avatar") };
  for (const e of Object.values(els)) e.classList.owner = e;
  vm.runInNewContext(HINT_SCRIPT, {
    localStorage: { getItem: (k) => (k === "dingbat_drive" ? hint : null) },
    document: { getElementById: (id) => els[id] },
    navigator: { onLine }, JSON, Date,
  });
  return { signedIn: els["account-btn"].classes.has("signed-in"), sync: els["account-btn"].dataset.sync,
           initial: els["account-avatar"].textContent };
};

// The slot is in the bar from the first frame either way: shown in the
// markup, and the bar a library's (body.lib-has-games, which shows it) from
// the head's hint rather than from when index.js runs.
test("index.html shows the account slot before index.js runs", async () => {
  assert.match(HTML, /<div id="account-slot">/, "not hidden in the markup");
  // Its outline is index.js's signed-out drawing, so nothing changes when
  // index.js takes over.
  const app = await loadApp();
  assert.ok(HTML.includes('<span id="account-avatar" aria-hidden="true">' + app.runIn("PERSON_SVG") + "</span>"),
            "the markup's outline is PERSON_SVG");
  const bodyScript = [...HTML.matchAll(/<script>([\s\S]*?)<\/script>/g)]
    .map((m) => m[1]).find((src) => src.includes("lib-has-games"));
  const added = [];
  for (const pending of [true, false]) {
    added.length = 0;
    vm.runInNewContext(bodyScript, { document: {
      documentElement: { classList: { contains: (c) => pending && c === "home-pending" } },
      body: { classList: { add: (c) => added.push(c) } },
    } });
    assert.deepEqual(added, pending ? ["lib-has-games"] : []);
  }
});

test("index.html's hint script is there to test", () => {
  assert.ok(HINT_SCRIPT, "a <script> reading dingbat_drive");
});

for (const [what, state, broker] of [
  ["a live token", { token: "tok1", tokenExp: Date.now() + HOUR }, false],
  ["a token about to lapse", { token: "tok1", tokenExp: Date.now() + 2000 }, false],
  ["an expired token, no refresh token", { token: "tok1", tokenExp: Date.now() - HOUR }, false],
  ["no token, a refresh token and a broker", { token: null, tokenExp: 0, refresh: "rt", refreshAcct: "a1" }, true],
  ["no token, a refresh token but no broker", { token: null, tokenExp: 0, refresh: "rt", refreshAcct: "a1" }, false],
  ["a refresh token for another account", { token: null, tokenExp: 0, refresh: "rt", refreshAcct: "a2" }, true],
]) {
  test(`the hint script and driveBootSyncs agree: ${what}`, async () => {
    const app = await loadApp();
    if (broker) app.sandbox.NET_SIGNAL_URL = "wss://signal.example/signal";
    await app.api.dbPut("gdrive_sync", linkedState(state));
    await app.api.loadSyncState();
    const hint = app.localStorage.getItem("dingbat_drive");
    const drawn = runHintScript(hint);
    assert.equal(drawn.signedIn, true);
    assert.equal(drawn.initial, "O");
    assert.equal(drawn.sync === "syncing", app.runIn("driveBootSyncs()"));
    assert.equal(runHintScript(hint, { onLine: false }).sync, "ok", "offline: no ring");
  });
}

test("without a hint the hint script leaves the signed-out outline", () => {
  for (const h of [null, "not json"]) {
    assert.deepEqual(runHintScript(h), { signedIn: false, sync: undefined, initial: "" });
  }
});

// --- Drive reads have a deadline; uploads do not ----------------------------

test("a Drive read that never answers ends the pull as offline", async () => {
  const app = await loadApp();
  const ctls = [];
  app.sandbox.AbortController = class {
    constructor() { this.signal = new EventTarget(); ctls.push(this); }
    abort() { this.signal.dispatchEvent(new Event("abort")); }
  };
  const sent = [];
  app.setFetch((url, opts = {}) => new Promise((_, reject) => {
    sent.push({ url: String(url), opts });
    opts.signal?.addEventListener("abort", () => reject(new Error("aborted")));
  }));
  app.idb.set("recent", []);
  app.api.syncState = linkedState({ token: "tok1", tokenExp: Date.now() + HOUR });
  app.api.gdriveToken = "tok1";
  app.api.gdriveTokenExp = Date.now() + HOUR;
  const pull = app.api.pullSync({ silent: false });
  await until(() => sent.length === 1, "the listing asked");
  const ctl = ctls.find((c) => c.signal === sent[0].opts.signal);
  assert.ok(ctl, "the listing carries a deadline");
  ctl.abort();
  await pull;
  assert.equal(app.api.syncStatus, "offline");
});

test("an upload carries no deadline", async () => {
  const app = await loadApp();
  const sent = [];
  app.setFetch(async (url, opts = {}) => { sent.push(opts); return jsonRes({ id: "x" }); });
  app.api.syncState = linkedState({ token: "tok1", tokenExp: Date.now() + HOUR });
  app.api.gdriveToken = "tok1";
  await app.api.driveFetch("https://www.googleapis.com/upload/drive/v3/files", { method: "POST", body: "x" });
  assert.equal(sent[0].signal, undefined);
});

// --- A tap while the boot's pull is out -------------------------------------

const GAME = "Game.gb";
const hold = (app) => app.runIn(`holdForBootPull(${JSON.stringify(GAME)})`);

// A linked boot whose tokeninfo the test answers; Drive seeded as given.
const bootWith = async (seed) => {
  const app = await loadApp();
  const drive = makeDrive({ seed });
  const held = [];
  app.setFetch(async (url, opts = {}) => {
    url = String(url);
    if (url.startsWith("https://oauth2.googleapis.com/tokeninfo")) {
      return new Promise((resolve) => held.push(() => resolve(jsonRes({ sub: "a1", email: "one@x" }))));
    }
    return drive.fetch(url, opts);
  });
  app.idb.set("recent", []);
  await app.api.dbPut("gdrive_sync", linkedState({ token: "tok1", tokenExp: Date.now() + HOUR }));
  await app.api.loadSyncState();
  app.runIn("bootDriveHint = null; refreshSyncUI()");
  app.api.resumeDriveOnBoot();
  return { app, held };
};

test("a tap during the boot pull waits for Drive's newer session of the game", async () => {
  const { app, held } = await bootWith({ ["stateauto:" + GAME]: "a session from another device" });
  let opened = null;
  hold(app).then((v) => { opened = v; });
  await until(() => app.runIn(`tileLoads.get(${JSON.stringify(GAME)})?.stage`) === "check",
              "the tile says Checking Drive");
  held[0]();
  await until(() => opened !== null, "the hold let go");
  assert.equal(opened, true);
  assert.equal(app.runIn("firstPullDone"), true, "only once the pull had landed it");
  assert.equal(app.runIn(`tileLoads.has(${JSON.stringify(GAME)})`), false, "the tile is plain again");
});

test("a tap during the boot pull opens once the listing shows nothing newer", async () => {
  const { app, held } = await bootWith({});
  let opened = null;
  hold(app).then((v) => { opened = v; });
  await until(() => held.length === 1, "tokeninfo asked");
  assert.equal(opened, null, "no listing yet: held");
  held[0]();
  await until(() => opened !== null, "the hold let go");
  assert.equal(opened, true);
});

test("a later tap during the hold takes the open from it", async () => {
  const { app, held } = await bootWith({ ["stateauto:" + GAME]: "a session from another device" });
  let opened = null;
  hold(app).then((v) => { opened = v; });
  await until(() => held.length === 1, "tokeninfo asked");
  app.runIn("nextLoadGen()"); // another tile tapped
  held[0]();
  await until(() => opened !== null, "the hold let go");
  assert.equal(opened, false);
});

test("no boot pull out: a tap opens at once", async () => {
  const app = await loadApp();
  assert.equal(await hold(app), true);
});

// --- The update check asks again when the network comes back ---------------

test("an offline boot's update check is asked again on reconnect", async () => {
  const app = await loadApp();
  const btn = app.elements.get("update-btn");
  btn.hidden = true; // as the markup starts it (the fake DOM reads no attributes)
  assert.equal(app.runIn("updateAvailable"), false, "the boot's probe failed: no update known");
  app.setFetch(async (url, opts = {}) => {
    url = String(url);
    if (url.startsWith("version.txt")) {
      return { ok: true, text: async () => (opts.cache === "no-store" ? "new" : "old") };
    }
    if (url.startsWith("sw.js")) return { ok: true, text: async () => 'const CACHE_VERSION = "new";' };
    return jsonRes({}, 404);
  });
  await app.dispatchWin("online");
  await until(() => btn.hidden === false, "the Update button");
});
