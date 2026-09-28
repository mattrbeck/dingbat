// The account slot in the bar: Sign in when signed out, the account (with a
// sync badge) when linked, swapped by refreshSyncUI. Both open the account
// menu. "Linked" follows syncState.connected, not the ~1h token: keyed on
// the token, an hourly rollover looked like a logout.

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

const el = (app, id) => app.elements.get(id) ?? app.document.getElementById(id);
const signedIn = (app) => el(app, "account-btn").classList.contains("signed-in");
// The account menu's Google button, as a click on the slot leaves it.
const openMenu = (app) => {
  el(app, "account-btn").dispatch("click");
  return el(app, "account-google");
};

test("signed out, the slot says Sign in and its menu holds Google's button", async () => {
  const app = await loadApp();
  assert.equal(el(app, "account-slot").hidden, false);
  assert.equal(signedIn(app), false);
  assert.equal(el(app, "account-label").hidden, false, "the word is the signed-out affordance");
  openMenu(app);
  assert.equal(el(app, "account-pop").hidden, false);
  assert.equal(el(app, "acct-out").hidden, false, "the signed-out face, with Google's button");
  assert.equal(el(app, "acct-in").hidden, true);
});

test("the slot becomes the account when it links, and Sign in when it goes", async () => {
  const app = await loadApp();
  app.api.syncState = { ...app.api.syncState, connected: true };
  app.api.gdriveToken = "a-token";
  app.runIn("refreshSyncUI()");
  assert.equal(signedIn(app), true);
  assert.equal(el(app, "account-label").hidden, true);
  assert.equal(el(app, "account-btn").dataset.sync, "ok");

  app.sandbox.google = { accounts: { oauth2: { revoke: () => {} } } };
  app.runIn("gdriveSignOut()");
  assert.equal(signedIn(app), false, "signed out again: Sign in returns");
});

// Spending the renewal budget drops the token but keeps the account linked;
// Sync now buys the new token at a moment the user chose.
test("a spent renewal budget keeps the account, not Sign in", async () => {
  const app = await loadApp();
  app.api.syncState = { ...app.api.syncState, connected: true };
  installFakeGis(app, { grant: false });
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;
  app.runIn("refreshSyncUI()");
  assert.equal(signedIn(app), true, "starts linked");

  app.api.driveRenewFails = app.api.DRIVE_RENEW_MAX_FAILS - 1;
  await app.api.renewDriveToken();
  await settle();

  assert.equal(app.api.gdriveToken, null, "the dead token is dropped");
  assert.equal(signedIn(app), true, "but the slot is still the account");
});

test("Google's button asks for a token on the click, then the slot is the account", async () => {
  const app = await loadApp();
  const calls = installFakeGis(app, { grant: true });
  app.setFetch(async () => jsonRes({ files: [] }));

  const google = openMenu(app);
  const done = google.dispatch("click");
  // gdriveConnect() must run on the click itself (the OAuth popup needs the
  // transient activation): nothing may be awaited before it.
  assert.equal(google.disabled, true, "the control is busy from the click on");
  await done;
  await settle();

  assert.equal(calls.length, 1, "one token request");
  assert.equal(calls[0].prompt, undefined,
    "and it's the full consent popup, not the silent prompt:'' re-grant");
  assert.equal(app.api.gdriveToken, "fresh-token");
  assert.equal(signedIn(app), true);
  assert.ok(app.toasts.includes("Connected to Google Drive"));
});

test("a cancelled sign-in leaves Google's button there and clickable", async () => {
  const app = await loadApp();
  const calls = installFakeGis(app, { grant: false });

  const google = openMenu(app);
  await google.dispatch("click");
  await settle();

  assert.equal(calls.length, 1);
  assert.equal(app.api.gdriveToken, null);
  assert.equal(signedIn(app), false);
  assert.equal(el(app, "account-pop").hidden, false, "the menu is still open");
  assert.equal(el(app, "account-google").disabled, false, "and re-armed for another try");
  assert.ok(app.toasts.some((t) => /Sign-in was canceled/.test(t)),
    "the failure is reported: " + JSON.stringify(app.toasts));
});
