// driveFetch's 401 retry: one silent token re-grant and replay; on re-grant
// failure the user is signed out locally. Uses a fake GIS (`google`) object
// injected into the vm context so the real gdriveAcquireToken runs.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes } from "./helpers.mjs";

const installFakeGis = (app, { grant }) => {
  app.api.gisScriptPromise = Promise.resolve(); // pretend the GIS script loaded
  app.sandbox.google = {
    accounts: {
      oauth2: {
        initTokenClient: () => ({
          callback: null,
          error_callback: null,
          requestAccessToken() {
            if (grant) this.callback({ access_token: "fresh-token" });
            else this.error_callback({ type: "popup_failed_to_open" });
          },
        }),
        revoke: () => {},
      },
    },
  };
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

test("driveFetch turns any non-ok status into a thrown error", async () => {
  const app = await loadApp();
  app.api.gdriveToken = "t";
  app.setFetch(async () => jsonRes({}, 503));
  await assert.rejects(
    () => app.api.driveFetch("https://www.googleapis.com/drive/v3/files"),
    /Drive request failed \(HTTP 503\)/,
  );
});
