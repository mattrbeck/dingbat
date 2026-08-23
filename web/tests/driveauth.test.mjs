// driveFetch's 401 retry and the gesture-gated token renewal, with a fake
// GIS (`google`) object injected so the real gdriveAcquireToken runs.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, settle } from "./helpers.mjs";

const installFakeGis = (app, { grant }) => {
  app.api.gisScriptPromise = Promise.resolve(); // pretend the GIS script loaded
  const calls = [];
  app.sandbox.google = {
    accounts: {
      oauth2: {
        initTokenClient: () => ({
          callback: null,
          error_callback: null,
          requestAccessToken(opts) {
            calls.push(opts);
            if (typeof grant === "function" ? grant(calls.length) : grant) {
              this.callback({ access_token: "fresh-token", expires_in: 3600 });
            } else {
              this.error_callback({ type: "popup_failed_to_open" });
            }
          },
        }),
        revoke: () => {},
      },
    },
  };
  return calls;
};

test("driveFetch retries once after a 401 with a silently refreshed token", async () => {
  const app = await loadApp();
  app.api.gdriveToken = "stale-token";
  installFakeGis(app, { grant: true });

  const auths = [];
  let calls = 0;
  app.setFetch(async (url, opts) => {
    auths.push(opts.headers.Authorization);
    return ++calls === 1 ? jsonRes({}, 401) : jsonRes({ ok: 1 });
  });

  const res = await app.api.driveFetch("https://www.googleapis.com/drive/v3/files/x");
  assert.equal(res.ok, true);
  assert.deepEqual(auths, ["Bearer stale-token", "Bearer fresh-token"]);
  assert.equal(app.api.gdriveToken, "fresh-token");
});

test("driveFetch drops the dead token when the silent re-grant fails", async () => {
  const app = await loadApp();
  app.api.gdriveToken = "stale-token";
  installFakeGis(app, { grant: false });
  app.setFetch(async () => jsonRes({}, 401));

  // Not "sign in again": the account stays linked and the next gesture re-grants.
  await assert.rejects(
    () => app.api.driveFetch("https://www.googleapis.com/drive/v3/files/x"),
    /Drive is reconnecting — your changes are saved/,
  );
  assert.equal(app.api.gdriveToken, null);
});

// --- Gesture-gated renewal -------------------------------------------------
// GIS issues ~1h tokens with no refresh token, and a re-grant needs a user
// gesture (popup); renewal happens before expiry on the next gesture.

const connected = async (app) => {
  app.api.syncState = { ...app.api.syncState, connected: true };
};

test("driveTokenStale is true with no token, and near expiry", async () => {
  const app = await loadApp();
  app.api.gdriveToken = null;
  assert.equal(app.api.driveTokenStale(), true, "no token");

  app.api.gdriveToken = "t";
  app.api.gdriveTokenExp = Date.now() + 55 * 60 * 1000;
  assert.equal(app.api.driveTokenStale(), false, "fresh token");

  app.api.gdriveTokenExp = Date.now() + 2 * 60 * 1000;
  assert.equal(app.api.driveTokenStale(), true, "inside the renew lead");
});

test("syncPollTick arms a gesture renewal for a near-expiry token", async () => {
  const app = await loadApp();
  await connected(app);
  const calls = installFakeGis(app, { grant: true });
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000; // expires in a minute
  app.setFetch(async () => jsonRes({ files: [] }));

  app.api.syncPollTick();
  assert.equal(calls.length, 0, "no token request before a gesture");

  await app.dispatchWin("pointerdown");
  await settle();
  assert.equal(calls.length, 1, "one token request");
  assert.equal(calls[0].prompt, "", "and it is the silent prompt:'' re-grant");
  assert.equal(app.api.gdriveToken, "fresh-token");
});

test("update buttons don't spend the renewal gesture (popup would be orphaned)", async () => {
  const app = await loadApp();
  await connected(app);
  const calls = installFakeGis(app, { grant: true });
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;
  app.setFetch(async () => jsonRes({ files: [] }));
  app.api.syncPollTick();

  // The update button is exempt.
  await app.dispatchWin("pointerdown", {
    target: { closest: (sel) => sel.includes("#update-btn") },
  });
  await settle();
  assert.equal(calls.length, 0, "update tap must not trigger the renewal");

  await app.dispatchWin("pointerdown", { target: { closest: () => null } });
  await settle();
  assert.equal(calls.length, 1, "ordinary tap still renews");
});

test("the gesture renewal re-arms, so a second expiry also renews", async () => {
  const app = await loadApp();
  await connected(app);
  const calls = installFakeGis(app, { grant: true });
  app.setFetch(async () => jsonRes({ files: [] }));

  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;
  app.api.syncPollTick();
  await app.dispatchWin("pointerdown");
  await settle();
  assert.equal(calls.length, 1);

  app.api.gdriveTokenExp = Date.now() + 60 * 1000;
  app.api.syncPollTick();
  await app.dispatchWin("keydown");
  await settle();
  assert.equal(calls.length, 2, "the one-shot latch reset after the first renew");
});

test("a background 401 does not end the session — it hands off to a gesture", async () => {
  const app = await loadApp();
  await connected(app);
  const calls = installFakeGis(app, { grant: true });
  app.state.userActivation = false; // a poll tick, not a tap
  app.api.gdriveToken = "dead-token";
  app.api.gdriveTokenExp = Date.now() + 30 * 60 * 1000;

  let n = 0;
  app.setFetch(async () => (++n === 1 ? jsonRes({}, 401) : jsonRes({ files: [] })));

  await assert.rejects(() => app.api.driveListAll(), /Drive is reconnecting/);
  assert.equal(calls.length, 0,
    "no popup is even attempted with no activation — it could only be refused");
  assert.equal(app.api.gdriveToken, null, "the dead token is dropped");
  assert.equal(
    app.api.syncState.connected, true,
    "but we stay 'connected' so renewal can still run",
  );

  app.state.userActivation = true;
  await app.dispatchWin("pointerdown");
  await settle();
  assert.equal(app.api.gdriveToken, "fresh-token", "next gesture restored it");
  assert.equal(calls.length, 1, "exactly one popup, the one that could work");
});

test("a doomed popup can't spend a strike from the renewal budget", async () => {
  const app = await loadApp();
  await connected(app);
  const calls = installFakeGis(app, { grant: true });
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;

  app.state.userActivation = false; // activation aged out mid-renewal
  await app.api.renewDriveToken();
  assert.equal(calls.length, 0);
  assert.equal(app.api.driveRenewFails, 0, "budget untouched");

  app.state.userActivation = true;
  await app.api.renewDriveToken();
  assert.equal(app.api.gdriveToken, "fresh-token");
});

test("renewal gives up only after DRIVE_RENEW_MAX_FAILS consecutive failures", async () => {
  const app = await loadApp();
  await connected(app);
  const calls = installFakeGis(app, { grant: false });
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;
  app.setFetch(async () => jsonRes({ files: [] }));

  app.api.syncPollTick();
  for (let i = 0; i < app.api.DRIVE_RENEW_MAX_FAILS + 2; i++) {
    await app.dispatchWin("pointerdown");
    await settle();
  }
  assert.equal(
    calls.length, app.api.DRIVE_RENEW_MAX_FAILS,
    "stops popping up once the budget is spent",
  );
  assert.equal(app.api.gdriveToken, null, "and finally shows signed-out");
});

test("renewal does not spend its budget while offline", async () => {
  const app = await loadApp();
  await connected(app);
  const calls = installFakeGis(app, { grant: false });
  app.sandbox.navigator.onLine = false;
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;

  await app.api.renewDriveToken();
  assert.equal(calls.length, 0, "no popup attempted offline");
  assert.equal(app.api.driveRenewFails, 0, "no failure counted");
  assert.equal(app.api.gdriveToken, "old-token", "session kept");
});

test("driveFetch turns any non-ok status into a thrown error", async () => {
  const app = await loadApp();
  app.api.gdriveToken = "t";
  app.setFetch(async () => jsonRes({}, 503));
  await assert.rejects(
    () => app.api.driveFetch("https://www.googleapis.com/drive/v3/files"),
    /Drive request failed \(HTTP 503\)/,
  );
});

// --- Naming the account: login_hint ----------------------------------------
// Without login_hint a re-grant shows an account chooser whenever the browser
// is signed in to more than one Google account; the email from the first
// token (scope includes "email") names the account on every re-grant.

test("a re-grant names the account, so no chooser can appear", async () => {
  const app = await loadApp();
  await connected(app);
  app.api.syncState = { ...app.api.syncState, email: "player@example.com" };
  const calls = installFakeGis(app, { grant: true });
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;
  app.setFetch(async () => jsonRes({ files: [] }));

  app.api.syncPollTick();
  await app.dispatchWin("pointerdown");
  await settle();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].login_hint, "player@example.com");
  assert.equal(calls[0].prompt, "");
});

test("the first connection carries no hint — the user picks the account", async () => {
  const app = await loadApp();
  const calls = installFakeGis(app, { grant: true });
  app.setFetch(async () => jsonRes({ files: [] }));

  await app.api.gdriveConnect();
  await settle();

  assert.equal(calls[0].prompt, undefined, "full consent flow");
  assert.equal(calls[0].login_hint, undefined, "and no account forced on them");
});

test("the account outlives the token: loadSyncState restores the hint", async () => {
  const app = await loadApp();
  await app.api.dbPut("gdrive_sync", {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], sigs: {}, rmt: {},
    connected: true, token: null, tokenExp: 0, email: "player@example.com",
  });
  await app.api.loadSyncState();
  const calls = installFakeGis(app, { grant: true });

  await app.api.gdriveAcquireToken("");
  assert.equal(calls[0].login_hint, "player@example.com",
    "a cold start still knows whose account to renew");
});

test("signing out forgets the account, so the next sign-in is free to differ", async () => {
  const app = await loadApp();
  await connected(app);
  app.api.syncState = { ...app.api.syncState, email: "player@example.com" };
  app.sandbox.google = { accounts: { oauth2: { revoke: () => {} } } };
  app.runIn("gdriveSignOut()");
  assert.equal(app.api.syncState.email, null);
});

// --- One popup at a time ---------------------------------------------------
// The GIS client's `callback` is overwritten per request, so overlapping
// requests orphan the first popup. Reachable: the window-level renewal
// listener (capture phase) runs before the Sign in button's own handler.
test("overlapping token requests share one popup", async () => {
  const app = await loadApp();
  await connected(app);
  const calls = installFakeGis(app, { grant: true });

  const a = app.api.gdriveAcquireToken("");
  const b = app.api.gdriveAcquireToken("");
  await Promise.all([a, b]);

  assert.equal(calls.length, 1, "one window, not two");
  assert.equal(app.api.gdriveToken, "fresh-token");

  await app.api.gdriveAcquireToken("");
  assert.equal(calls.length, 2);
});

// --- A token gap is not a sign-out -----------------------------------------
test("changes made without a token still queue, and flush when one arrives", async () => {
  const app = await loadApp();
  await connected(app);
  app.api.gdriveToken = null; // token aged out mid-session

  app.api.markUpload("save:Pokemon Crystal");
  assert.deepEqual([...app.api.syncState.queueUp], ["save:Pokemon Crystal"],
    "the save is remembered even with no way to send it");
  assert.equal(app.api.driveLinked(), true, "and the account is still linked");

  installFakeGis(app, { grant: true });
  app.api.gdriveToken = "fresh-token";
  const uploads = [];
  app.setFetch(async (url, opts) => {
    if (String(url).includes("/upload/")) uploads.push(String(url));
    return jsonRes({ files: [] });
  });
  await app.api.dbPut("save:Pokemon Crystal", new Uint8Array([1, 2, 3]));
  await app.api.flushSync();
  assert.ok(uploads.length >= 1, "the deferred save reached Drive");
  assert.deepEqual([...app.api.syncState.queueUp], []);
});

test("out of token and out of retries, the indicator says Paused, not Syncing", async () => {
  const app = await loadApp();
  await connected(app);
  app.api.gdriveToken = null;
  app.api.syncState = { ...app.api.syncState, queueUp: ["save:Zelda"] };

  app.api.driveRenewFails = 0;
  app.api.refreshSyncStatus();
  assert.equal(app.api.syncStatus, "syncing", "still trying: nothing to say");

  app.api.driveRenewFails = app.api.DRIVE_RENEW_MAX_FAILS;
  app.api.refreshSyncStatus();
  assert.equal(app.api.syncStatus, "paused",
    "given up quietly — one word, no modal, nothing lost");
});
