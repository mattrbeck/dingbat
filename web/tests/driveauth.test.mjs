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
  await connected(app); // a signed-out tab gets no re-grant (drive-session.test.mjs)
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

// --- Refresh tokens through the token broker -------------------------------
// With a refresh token and a live broker (the signaling server), renewal is
// a fetch with no gesture and no popup; any broker failure falls back to the
// gesture-gated popup above, unchanged.

const BROKER = "https://signal.test";

const withBroker = async (app, refresh = "rt-1") => {
  app.sandbox.NET_SIGNAL_URL = "wss://signal.test/signal";
  app.api.syncState = { ...app.api.syncState, connected: true, refresh };
};

// Broker replies by path; Drive calls get an empty listing.
const brokerFetch = (app, routes) => {
  const hits = [];
  app.setFetch(async (url, opts = {}) => {
    const u = String(url);
    if (u.startsWith(BROKER)) {
      const path = u.slice(BROKER.length);
      hits.push({ path, body: opts.body ? JSON.parse(opts.body) : null });
      const r = routes[path];
      if (r instanceof Error) throw r;
      const [status, obj] = typeof r === "function" ? r() : r || [404, {}];
      return jsonRes(obj, status);
    }
    return jsonRes({ files: [] });
  });
  return hits;
};

test("the broker URL follows the signaling socket's host", async () => {
  const app = await loadApp();
  assert.equal(app.api.driveBrokerBase(), "", "no netplay.js, no broker");
  app.sandbox.NET_SIGNAL_URL = "wss://signal.dingbat.gg/signal";
  assert.equal(app.api.driveBrokerBase(), "https://signal.dingbat.gg");
  app.sandbox.NET_SIGNAL_URL = "ws://192.168.1.5:8790";
  assert.equal(app.api.driveBrokerBase(), "http://192.168.1.5:8790");
});

test("a stale token renews through the broker with no gesture and no popup", async () => {
  const app = await loadApp();
  await withBroker(app);
  const calls = installFakeGis(app, { grant: true });
  const hits = brokerFetch(app, {
    "/oauth/refresh": [200, { access_token: "broker-token", expires_in: 3599 }],
  });
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;

  app.api.syncPollTick();
  await settle(); await settle();
  assert.equal(app.api.gdriveToken, "broker-token", "renewed before any gesture");
  assert.equal(calls.length, 0, "no popup");
  assert.equal(hits[0].path, "/oauth/refresh");
  assert.equal(hits[0].body.refresh_token, "rt-1");
  assert.equal(app.api.syncState.token, "broker-token", "persisted for a reload");
});

test("broker down: the refresh token is kept and the next gesture gets today's popup", async () => {
  const app = await loadApp();
  await withBroker(app);
  const calls = installFakeGis(app, { grant: true });
  brokerFetch(app, { "/oauth/refresh": new Error("offline") });
  app.api.gdriveToken = "old-token";
  app.api.gdriveTokenExp = Date.now() + 60 * 1000;

  app.api.syncPollTick();
  await settle(); await settle();
  assert.equal(calls.length, 0, "no popup without a gesture");
  assert.equal(app.api.syncState.refresh, "rt-1", "a down broker is not a dead grant");
  assert.ok(app.api.driveBrokerRetryAt > Date.now(), "the broker rests a minute");

  await app.dispatchWin("pointerdown");
  await settle();
  assert.equal(calls.length, 1, "the gesture falls back to the popup");
  assert.equal(calls[0].prompt, "");
  assert.equal(app.api.gdriveToken, "fresh-token");
});

test("a 502 from the broker also keeps the refresh token", async () => {
  const app = await loadApp();
  await withBroker(app);
  brokerFetch(app, { "/oauth/refresh": [502, { error: "upstream" }] });
  assert.equal(await app.api.driveRefreshSilently(), false);
  assert.equal(app.api.syncState.refresh, "rt-1");
});

test("a revoked grant drops the refresh token: back on popups for good", async () => {
  const app = await loadApp();
  await withBroker(app);
  brokerFetch(app, { "/oauth/refresh": [400, { error: "invalid_grant" }] });
  assert.equal(await app.api.driveRefreshSilently(), false);
  assert.equal(app.api.syncState.refresh, null);
  const saved = await app.api.dbGet("gdrive_sync");
  assert.equal(saved.refresh, null, "and the drop is saved");
});

test("a broker misconfiguration (400 invalid_client) keeps the token", async () => {
  const app = await loadApp();
  await withBroker(app);
  brokerFetch(app, { "/oauth/refresh": [400, { error: "invalid_client" }] });
  assert.equal(await app.api.driveRefreshSilently(), false);
  assert.equal(app.api.syncState.refresh, "rt-1");
});

test("offline with a refresh token: no renewal loop, the listener is armed", async () => {
  const app = await loadApp();
  await withBroker(app);
  const calls = installFakeGis(app, { grant: true });
  const hits = brokerFetch(app, {});
  app.sandbox.navigator.onLine = false;
  app.api.gdriveToken = null;

  app.api.syncPollTick();
  await settle(); await settle();
  assert.equal(hits.length, 0, "nothing sent while offline");
  assert.equal(calls.length, 0);
  assert.ok((app.winListeners.pointerdown || []).length >= 1, "gesture listener armed");
});

test("driveFetch's 401 retry goes through the broker before any popup", async () => {
  const app = await loadApp();
  await withBroker(app);
  const calls = installFakeGis(app, { grant: true });
  app.api.gdriveToken = "stale-token";
  app.api.driveBrokerRetryAt = Date.now() + 60 * 1000; // forced past the rest period
  const auths = [];
  let driveCalls = 0;
  app.setFetch(async (url, opts = {}) => {
    if (String(url).startsWith(BROKER)) {
      return jsonRes({ access_token: "broker-token", expires_in: 3599 });
    }
    auths.push(opts.headers.Authorization);
    return ++driveCalls === 1 ? jsonRes({}, 401) : jsonRes({ ok: 1 });
  });

  const res = await app.api.driveFetch("https://www.googleapis.com/drive/v3/files/x");
  assert.equal(res.ok, true);
  assert.deepEqual(auths, ["Bearer stale-token", "Bearer broker-token"]);
  assert.equal(calls.length, 0, "no popup");
});

test("signing out revokes the refresh token and forgets it", async () => {
  const app = await loadApp();
  await withBroker(app);
  app.sandbox.google = { accounts: { oauth2: { revoke: () => {} } } };
  app.setFetch(async () => jsonRes({}));
  app.runIn("gdriveSignOut()");
  const revoke = app.fetchCalls.find((c) => c.url.startsWith("https://oauth2.googleapis.com/revoke"));
  assert.ok(revoke, "revoke called");
  assert.equal(revoke.opts.body, "token=rt-1");
  assert.equal(app.api.syncState.refresh, null);
});

test("the refresh token survives a reload", async () => {
  const app = await loadApp();
  await app.api.dbPut("gdrive_sync", {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], sigs: {}, rmt: {},
    connected: true, token: null, tokenExp: 0, email: "p@example.com", refresh: "rt-9",
  });
  await app.api.loadSyncState();
  assert.equal(app.api.syncState.refresh, "rt-9");
});

// The consent popup: window.open, then the code comes back from
// oauth-callback.html (here: a postMessage) and the broker trades it.
const installCodeFlow = (app) => {
  app.sandbox.URL = URL;
  app.sandbox.URLSearchParams = URLSearchParams;
  app.sandbox.crypto = globalThis.crypto;
  app.sandbox.location.origin = "https://dingbat.gg";
  app.sandbox.location.pathname = "/";
  const popup = { closed: false, location: { href: "" } };
  app.sandbox.open = () => popup;
  return { popup };
};

const popupState = async (popup) => {
  for (let i = 0; i < 20 && !popup.location.href; i++) await settle();
  return new URL(popup.location.href).searchParams.get("state");
};

const deliverCode = async (app, popup, code = "the-code") => {
  const state = await popupState(popup);
  await app.dispatchWin("message", {
    origin: "https://dingbat.gg", data: { type: "dingbat-oauth", state, code },
  });
  return new URL(popup.location.href);
};

test("the consent popup asks for offline access and stores the refresh token", async () => {
  const app = await loadApp();
  await withBroker(app, null);
  const { popup } = installCodeFlow(app);
  const hits = brokerFetch(app, {
    "/oauth/exchange": [200, { access_token: "at-1", expires_in: 3599, refresh_token: "rt-new" }],
  });

  const grant = app.api.driveCodeGrant("p@example.com");
  const url = await deliverCode(app, popup);
  await grant;

  assert.equal(url.origin + url.pathname, "https://accounts.google.com/o/oauth2/v2/auth");
  assert.equal(url.searchParams.get("access_type"), "offline");
  assert.equal(url.searchParams.get("prompt"), "consent");
  assert.equal(url.searchParams.get("response_type"), "code");
  assert.equal(url.searchParams.get("login_hint"), "p@example.com");
  assert.equal(url.searchParams.get("code_challenge_method"), "S256");
  assert.equal(url.searchParams.get("redirect_uri"), "https://dingbat.gg/oauth-callback.html");

  const ex = hits.find((h) => h.path === "/oauth/exchange");
  assert.equal(ex.body.code, "the-code");
  assert.equal(ex.body.redirect_uri, "https://dingbat.gg/oauth-callback.html");
  assert.ok(ex.body.code_verifier.length >= 43, "PKCE verifier sent");
  assert.equal(app.api.gdriveToken, "at-1");
  assert.equal(app.api.syncState.refresh, "rt-new");
});

test("a code with the wrong state or origin is ignored", async () => {
  const app = await loadApp();
  await withBroker(app, null);
  const { popup } = installCodeFlow(app);
  brokerFetch(app, { "/oauth/exchange": [200, { access_token: "at-1", expires_in: 3599 }] });

  const grant = app.api.driveCodeGrant(null);
  const state = await popupState(popup);
  await app.dispatchWin("message", {
    origin: "https://dingbat.gg", data: { type: "dingbat-oauth", state: "forged", code: "x" },
  });
  await app.dispatchWin("message", {
    origin: "https://evil.example", data: { type: "dingbat-oauth", state, code: "x" },
  });
  await settle();
  assert.equal(app.api.gdriveToken, null, "neither forged message was taken");
  const url = await deliverCode(app, popup);
  await grant;
  assert.equal(url.searchParams.get("prompt"), "select_account consent",
    "no hint: the account chooser too");
  assert.equal(app.api.gdriveToken, "at-1");
});

test("denying consent rejects as a cancel", async () => {
  const app = await loadApp();
  await withBroker(app, null);
  const { popup } = installCodeFlow(app);
  brokerFetch(app, {});
  const grant = app.api.driveCodeGrant(null);
  const state = await popupState(popup);
  await app.dispatchWin("message", {
    origin: "https://dingbat.gg", data: { type: "dingbat-oauth", state, error: "access_denied" },
  });
  await assert.rejects(grant, /Sign-in was canceled/);
});

test("the broker probe decides between the consent popup and the token flow", async () => {
  const app = await loadApp();
  app.sandbox.NET_SIGNAL_URL = "wss://signal.test/signal";
  brokerFetch(app, { "/oauth": new Error("down") });
  assert.equal(await app.api.probeDriveBroker(), false);

  const app2 = await loadApp();
  app2.sandbox.NET_SIGNAL_URL = "wss://signal.test/signal";
  brokerFetch(app2, { "/oauth": [200, { oauth: true }] });
  assert.equal(await app2.api.probeDriveBroker(), true);
});

// --- The broker and the Drive session --------------------------------------
// Sign out and Sign in end the session (drive-session.test.mjs); a broker
// answer is held to the same rule as a popup's.

test("a broker renewal that lands after sign-out is refused", async () => {
  const app = await loadApp();
  await withBroker(app);
  app.sandbox.google = { accounts: { oauth2: { revoke: () => {} } } };
  let release;
  const gate = new Promise((r) => { release = r; });
  app.setFetch(async (url) => {
    if (String(url).startsWith(BROKER)) {
      await gate;
      return jsonRes({ access_token: "late-token", expires_in: 3599 });
    }
    return jsonRes({});
  });

  const renewal = app.api.driveRefreshSilently({ force: true });
  await settle();
  app.runIn("gdriveSignOut()");
  release();
  assert.equal(await renewal, false);
  assert.equal(app.api.gdriveToken, null, "the tab stays signed out");
  assert.equal(app.api.syncState.token, null, "and nothing was persisted");
});

test("a Stay signed in grant that lands after sign-out is refused", async () => {
  const app = await loadApp();
  await withBroker(app, null);
  app.sandbox.google = { accounts: { oauth2: { revoke: () => {} } } };
  const { popup } = installCodeFlow(app);
  brokerFetch(app, {
    "/oauth/exchange": [200, { access_token: "at-1", expires_in: 3599, refresh_token: "rt-new" }],
  });

  const grant = app.api.driveCodeGrant("p@example.com");
  await popupState(popup);
  app.runIn("gdriveSignOut()");
  await deliverCode(app, popup);
  await assert.rejects(grant, /Signed out of Google Drive/);
  assert.equal(app.api.gdriveToken, null);
  assert.equal(app.api.syncState.refresh, null, "no refresh token kept either");
});

test("Sign in uses a known broker answer without waiting, so the popup opens in the tap", async () => {
  const app = await loadApp();
  await withBroker(app, null);
  app.api.syncState = { ...app.api.syncState, connected: false };
  const { popup } = installCodeFlow(app);
  let opened = 0;
  app.sandbox.open = () => { opened++; return popup; };
  brokerFetch(app, {
    "/oauth": [200, { oauth: true }],
    "/oauth/exchange": [200, { access_token: "at-1", expires_in: 3599, refresh_token: "rt-new" }],
  });
  app.api.driveBrokerOk = true;
  app.api.driveBrokerProbedAt = Date.now() - 5 * 60 * 1000; // stale, but known

  const connecting = app.api.gdriveConnect().catch(() => {});
  assert.equal(opened, 1, "window.open ran before the first await");
  await deliverCode(app, popup);
  await connecting;
  assert.equal(app.api.syncState.refresh, "rt-new");
});

test("a sign-in through the token flow drops a refresh token left from before", async () => {
  const app = await loadApp();
  await withBroker(app, "rt-old");
  installFakeGis(app, { grant: true });
  brokerFetch(app, {});
  app.api.driveBrokerOk = false;
  app.api.driveBrokerProbedAt = Date.now();

  await app.api.gdriveConnect().catch(() => {});
  assert.equal(app.api.gdriveToken, "fresh-token");
  assert.equal(app.api.syncState.refresh, null, "it may be another account's grant");
});
