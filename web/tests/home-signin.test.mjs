// The home-screen Drive slot: Sync when linked, Sign in otherwise, swapped
// by refreshSyncUI. "Linked" follows syncState.connected, not the ~1h token:
// keyed on the token, an hourly rollover looked like a logout.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, settle } from "./helpers.mjs";

// Fake GIS, as in driveauth.test.mjs.
const installFakeGis = (app, { grant = true } = {}) => {
  app.runIn("gisScriptPromise = Promise.resolve()");
  const calls = [];
  app.sandbox.google = {
    accounts: {
      oauth2: {
        initTokenClient: () => ({
          callback: null,
          error_callback: null,
          requestAccessToken(opts) {
            calls.push(opts);
            if (grant) this.callback({ access_token: "fresh-token", expires_in: 3600 });
            else this.error_callback({ type: "popup_closed" });
          },
        }),
        revoke: () => {},
      },
    },
  };
  return calls;
};

const slot = (app) => ({
  signin: app.elements.get("home-signin"),
  sync: app.elements.get("home-sync"),
});

test("signed out, the slot shows Sign in instead of Sync", async () => {
  const app = await loadApp();
  const { signin, sync } = slot(app);
  assert.equal(signin.hidden, false, "Sign in is the signed-out affordance");
  assert.equal(sync.hidden, true, "Sync has nothing to sync");
});

test("the slot swaps to Sync when the account links, and back when it goes", async () => {
  const app = await loadApp();
  const { signin, sync } = slot(app);

  app.api.syncState = { ...app.api.syncState, connected: true };
  app.api.gdriveToken = "a-token";
  app.runIn("refreshSyncUI()");
  assert.equal(signin.hidden, true, "signed in: no Sign in link");
  assert.equal(sync.hidden, false, "signed in: Sync is back");

  app.sandbox.google = { accounts: { oauth2: { revoke: () => {} } } };
  app.runIn("gdriveSignOut()");
  assert.equal(signin.hidden, false, "signed out again: Sign in returns");
  assert.equal(sync.hidden, true);
});

// Spending the renewal budget drops the token but keeps the account linked;
// Sync buys the new token at a moment the user chose.
test("a spent renewal budget keeps Sync, not Sign in", async () => {
  const app = await loadApp();
  const { signin, sync } = slot(app);
  app.api.syncState = { ...app.api.syncState, connected: true };
  installFakeGis(app, { grant: false });
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;
  app.runIn("refreshSyncUI()");
  assert.equal(sync.hidden, false, "starts linked");

  app.api.driveRenewFails = app.api.DRIVE_RENEW_MAX_FAILS - 1;
  await app.api.renewDriveToken();
  await settle();

  assert.equal(app.api.gdriveToken, null, "the dead token is dropped");
  assert.equal(sync.hidden, false, "but the slot still says Sync");
  assert.equal(signin.hidden, true, "and never demands a sign-in");
});

test("clicking Sign in asks Google for a token and then shows Sync", async () => {
  const app = await loadApp();
  const { signin, sync } = slot(app);
  const calls = installFakeGis(app, { grant: true });
  app.setFetch(async () => jsonRes({ files: [] }));

  const done = signin.dispatch("click");
  // gdriveConnect() must run on the click itself (the OAuth popup needs the
  // transient activation): nothing may be awaited before it.
  assert.equal(signin.disabled, true, "the control is busy from the click on");
  await done;
  await settle();

  assert.equal(calls.length, 1, "one token request");
  assert.equal(calls[0].prompt, undefined,
    "and it's the full consent popup, not the silent prompt:'' re-grant");
  assert.equal(app.api.gdriveToken, "fresh-token");
  assert.equal(signin.hidden, true, "the slot swapped to Sync");
  assert.equal(sync.hidden, false);
  assert.ok(app.toasts.includes("Connected to Google Drive"));
});

test("a cancelled sign-in leaves the Sign in link visible and clickable", async () => {
  const app = await loadApp();
  const { signin, sync } = slot(app);
  const calls = installFakeGis(app, { grant: false });

  await signin.dispatch("click");
  await settle();

  assert.equal(calls.length, 1);
  assert.equal(app.api.gdriveToken, null);
  assert.equal(signin.hidden, false, "still offered");
  assert.equal(signin.disabled, false, "and re-armed for another try");
  assert.equal(sync.hidden, true);
  assert.ok(app.toasts.some((t) => /Sign-in was canceled/.test(t)),
    "the failure is reported: " + JSON.stringify(app.toasts));
});
