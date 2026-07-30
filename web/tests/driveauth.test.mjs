// driveFetch's 401 retry: one silent token re-grant and replay; on re-grant
// failure the user is signed out locally. Uses a fake GIS (`google`) object
// injected into the vm context so the real gdriveAcquireToken runs.

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

test("driveFetch signs out locally when the silent re-grant fails", async () => {
  const app = await loadApp();
  app.api.gdriveToken = "stale-token";
  installFakeGis(app, { grant: false });
  app.setFetch(async () => jsonRes({}, 401));

  await assert.rejects(
    () => app.api.driveFetch("https://www.googleapis.com/drive/v3/files/x"),
    /Google session expired — sign in again/,
  );
  assert.equal(app.api.gdriveToken, null);
});

// --- Gesture-gated renewal -------------------------------------------------
// The GIS token flow issues ~1h tokens with no refresh token, and its re-grant
// needs a user gesture (popup). These cover the machinery that renews BEFORE
// expiry instead of hard-signing-out on the first background 401.

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

  // A tap on the update button is exempt: still armed, no token request.
  await app.dispatchWin("pointerdown", {
    target: { closest: (sel) => sel.includes("#update-btn") },
  });
  await settle();
  assert.equal(calls.length, 0, "update tap must not trigger the renewal");

  // The next ordinary tap pays as usual.
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

  // Simulate the renewed token ageing into the renew window again.
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;
  app.api.syncPollTick();
  await app.dispatchWin("keydown");
  await settle();
  assert.equal(calls.length, 2, "the one-shot latch reset after the first renew");
});

test("a background 401 does not end the session — it hands off to a gesture", async () => {
  const app = await loadApp();
  await connected(app);
  // Popup fails from the timer (no user activation), then succeeds on the tap.
  const calls = installFakeGis(app, { grant: (n) => n > 1 });
  app.api.gdriveToken = "dead-token";
  app.api.gdriveTokenExp = Date.now() + 30 * 60 * 1000;

  let n = 0;
  app.setFetch(async () => (++n === 1 ? jsonRes({}, 401) : jsonRes({ files: [] })));

  await assert.rejects(() => app.api.driveListAll(), /Google session expired/);
  assert.equal(app.api.gdriveToken, null, "the dead token is dropped");
  assert.equal(
    app.api.syncState.connected, true,
    "but we stay 'connected' so renewal can still run",
  );

  await app.dispatchWin("pointerdown");
  await settle();
  assert.equal(app.api.gdriveToken, "fresh-token", "next gesture restored it");
  assert.equal(calls.length, 2);
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
