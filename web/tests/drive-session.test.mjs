// Sign out and sign in while Drive work is in flight: a renewal popup that
// answers after Sign out, and a flush that is still running when the tab
// signs in to a different account. Replays formal/WebState/DriveSession.lean's
// Session traces against the real web/index.js, with a fake GIS whose grant
// the test delivers when it chooses, and one fake Drive per account (the
// token a request carries decides which Drive it reaches).

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle, jsonRes } from "./helpers.mjs";
import { makeDrive, makeClock, useClock, until } from "./drivefake.mjs";

// GIS whose popups stay open until the test answers them.
const installGis = (app) => {
  app.api.gisScriptPromise = Promise.resolve();
  const popups = [];
  app.sandbox.google = {
    accounts: {
      oauth2: {
        initTokenClient: () => ({
          callback: null,
          error_callback: null,
          requestAccessToken(opts) {
            const client = this;
            popups.push({
              opts,
              grant: (token) => client.callback({ access_token: token, expires_in: 3600 }),
              deny: () => client.error_callback({ type: "popup_closed" }),
            });
          },
        }),
        revoke: () => {},
      },
    },
  };
  return popups;
};

// token -> account; each account has its own Drive.
const makeAccounts = (clock) => {
  const who = { tok1: { sub: "a1", email: "one@x" }, tok2: { sub: "a2", email: "two@x" } };
  const drives = { a1: makeDrive({ clock }), a2: makeDrive({ clock }) };
  const traffic = [];
  const fetch = async (url, opts = {}) => {
    url = String(url);
    if (url.startsWith("https://oauth2.googleapis.com/tokeninfo")) {
      const tok = new URL(url).searchParams.get("access_token");
      traffic.push({ url, tok });
      return who[tok] ? jsonRes(who[tok]) : jsonRes({}, 400);
    }
    const tok = (opts.headers?.Authorization || "").replace("Bearer ", "");
    traffic.push({ url, tok, method: opts.method || "GET" });
    const acct = who[tok]?.sub;
    if (!acct) return jsonRes({}, 401);
    return drives[acct].fetch(url, opts);
  };
  return { drives, traffic, fetch };
};

const linked = async (clock, accounts, extra = {}) => {
  const app = await loadApp();
  useClock(app, clock);
  app.setFetch(accounts.fetch);
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
    sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "one@x", ...extra,
  };
  app.api.gdriveEmail = "one@x";
  app.idb.set("recent", []);
  return app;
};

// DriveSession.Session.bug_renewal_resurrects_token / regress_renewal_after_signout.
test("a renewal popup answered after Sign out does not sign the tab back in", async () => {
  const clock = makeClock();
  const accounts = makeAccounts(clock);
  const app = await linked(clock, accounts);
  const popups = installGis(app);
  app.api.gdriveToken = null;            // a background 401 dropped it...
  app.api.armDriveRenewOnGesture();      // ...and armed the renewal
  await app.dispatchWin("pointerdown");  // the tap on "Sign out" arms the popup first
  await until(() => popups.length === 1, "the renewal popup");
  app.api.gdriveSignOut();               // then its click signs out
  const before = accounts.traffic.length;
  popups[0].grant("tok1");               // the popup answers afterwards
  await settle();
  await settle();

  assert.equal(app.api.gdriveToken, null, "no token for a signed-out tab");
  assert.equal(app.api.syncState.token, null, "nor persisted for the next load");
  assert.equal(app.api.syncState.email, null, "the forgotten account stays forgotten");
  assert.equal(app.api.syncActive(), false);
  eq(accounts.traffic.slice(before), [], "and nothing leaves the tab");
  assert.equal(app.api.driveRenewFails, 0, "a sign-out is not a failed renewal");
});

// DriveSession.Session.bug_signed_out_tab_keeps_syncing / regress_signed_out_quiet.
test("a signed-out tab holding a token does not sync on the poll", async () => {
  const clock = makeClock();
  const accounts = makeAccounts(clock);
  const app = await linked(clock, accounts, { connected: false, queueUp: ["save:G.gba"] });
  app.api.gdriveToken = "tok1";          // however it got one
  await app.api.dbPut("save:G.gba", u8(1));
  assert.equal(app.api.syncActive(), false, "a token is not a session");
  app.api.syncPollTick();
  await app.api.flushSync();
  await app.api.pullSync();
  await settle();
  eq(accounts.traffic, [], "the poll, a flush and a pull send nothing");
});

// DriveSession.Session.bug_flush_crosses_accounts / regress_no_cross_account.
test("a flush running across Sign out and Sign in as another account stays in the first", async () => {
  const clock = makeClock();
  const accounts = makeAccounts(clock);
  const { a1, a2 } = accounts.drives;
  const app = await linked(clock, accounts, {
    tomb: [{ name: "Secret.gba", ts: 5 }],   // account 1 deleted this
  });
  const popups = installGis(app);
  app.api.gdriveToken = "tok1";
  app.api.gdriveTokenExp = clock.peek() + 3600e3;
  await app.api.dbPut("save:G.gba", u8(1));
  app.api.markUpload("save:G.gba");

  const h = a1.hold((e) => e.url.includes("/upload/drive/v3/files"));
  const flushing = app.api.flushSync();
  await h.reached;                        // account 1's upload is on the wire

  app.api.gdriveSignOut();
  const connecting = app.api.gdriveConnect();
  await until(() => popups.length === 1, "the sign-in popup");
  popups[0].grant("tok2");                // the person picks account 2
  await until(() => app.api.syncState.acct === "a2", "account 2 adopted");

  h.release();
  await flushing;
  await connecting;
  await settle();

  const a2lib = a2.named("library").map((f) => new TextDecoder().decode(f.bytes)).join("");
  assert.ok(!a2lib.includes("Secret.gba"), "account 1's tombstone never reached account 2's Drive");
  assert.ok(!app.api.syncState.tomb.some((t) => t.name === "Secret.gba"),
    "nor account 2's sync state");
  eq(app.api.syncState.parked.a1.tomb.map((t) => t.name), ["Secret.gba"],
    "it waits, parked, for account 1");
});

// Found while modelling the fix: a sign-in whose account cannot be confirmed
// (tokeninfo failed) left the previous account's queues loaded under the new
// account's token, with no race needed.
test("a sign-in that cannot confirm the account does not sync the previous one's work into it", async () => {
  const clock = makeClock();
  const accounts = makeAccounts(clock);
  const app = await linked(clock, accounts, {
    connected: false, email: null, tomb: [{ name: "Secret.gba", ts: 5 }],
  });
  const popups = installGis(app);
  const real = accounts.fetch;
  app.setFetch(async (url, opts) =>
    String(url).includes("tokeninfo") ? jsonRes({}, 503) : real(url, opts));
  const connecting = app.api.gdriveConnect();
  await until(() => popups.length === 1, "the sign-in popup");
  popups[0].grant("tok2");
  await assert.rejects(connecting, /account/i);
  await settle();
  assert.equal(app.api.syncState.connected, false, "not signed in");
  assert.equal(app.api.gdriveToken, null);
  eq(accounts.drives.a2.log, [], "and account 2's Drive untouched");
});

// A UI QA run (d3, phase 2b): the grid and the pictures a pull brings down
// are device-wide, so after syncing as one account, a game that is only on
// that account's Drive (a tile with its picture and nothing else here) was
// listed, and its picture uploaded, into the next account's Drive. Games
// with files here still go to whoever signs in; the other account's
// Drive-only ones leave with it, and come back when it does.
test("signing in as another account does not publish the last one's Drive-only games", async () => {
  const clock = makeClock();
  const accounts = makeAccounts(clock);
  const { a1, a2 } = accounts.drives;
  a1.add("rom:Zeta.gb", u8(1, 2));
  a1.add("frame:Zeta.gb", u8(9, 9, 9));
  a1.add("library", new TextEncoder().encode(JSON.stringify(
    { recents: [{ name: "Zeta.gb", ts: 5 }], tomb: [], ren: [] })));
  const app = await linked(clock, accounts);
  const popups = installGis(app);
  app.api.gdriveToken = "tok1";
  app.api.gdriveTokenExp = clock.peek() + 3600e3;
  await app.api.addRecentRom("Mine.gba", u8(7));    // a game with its file here
  await settle();
  await app.api.pullSync();
  await settle();
  eq((app.idb.get("recent") || []).map((r) => r.name).sort(), ["Mine.gba", "Zeta.gb"]);
  assert.ok(app.idb.get("frame:Zeta.gb"), "Zeta's picture came down as a1");

  app.api.gdriveSignOut();
  const signIn = async (tok) => {
    const n = popups.length;
    const connecting = app.api.gdriveConnect();
    await until(() => popups.length === n + 1, "the sign-in popup");
    popups[n].grant(tok);
    await connecting;
    await settle();
  };
  await signIn("tok2");
  assert.equal(app.api.syncState.acct, "a2");
  const libOf = (d) => JSON.parse(new TextDecoder().decode(d.get("library").bytes));
  eq(libOf(a2).recents.map((r) => r.name), ["Mine.gba"], "a2's library has this device's game only");
  eq(a2.names(), ["rom:Mine.gba"], "and none of a1's files");
  eq((app.idb.get("recent") || []).map((r) => r.name), ["Mine.gba"], "the grid shows a2's games");

  app.api.gdriveSignOut();
  await signIn("tok1");
  assert.equal(app.api.syncState.acct, "a1");
  eq((app.idb.get("recent") || []).map((r) => r.name).sort(), ["Mine.gba", "Zeta.gb"],
    "a1's Drive-only game is back");
  assert.ok(app.idb.get("frame:Zeta.gb"), "with its picture");
  eq(libOf(a1).recents.map((r) => r.name).sort(), ["Mine.gba", "Zeta.gb"]);
});
