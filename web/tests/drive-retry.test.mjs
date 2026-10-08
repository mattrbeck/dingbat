// Drive asking to slow down (429, 403 rateLimitExceeded) or briefly failing
// (5xx): driveFetch sends the request again after a short wait instead of
// failing the sync to "Offline". A 5xx is repeated only for a read or an
// in-place update, never a create or a delete, which may have happened.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, jsonRes, u8, eq, settle } from "./helpers.mjs";
import { makeDrive, makeClock, useClock } from "./drivefake.mjs";

const FILES = "https://www.googleapis.com/drive/v3/files";

// `refuse(entry)` says which requests get which error, and how many times.
const device = async (refusals) => {
  const clock = makeClock();
  const drive = makeDrive({ clock });
  const app = await loadApp();
  useClock(app, clock);
  const seen = [];
  app.setFetch(async (url, opts = {}) => {
    const method = opts.method || "GET";
    // A create names its file in the multipart body's metadata.
    let name = "";
    if (method === "POST" && opts.body?.text) {
      name = /"name":"([^"]+)"/.exec(await opts.body.text())?.[1] || "";
    }
    seen.push(method + " " + String(url) + (name ? " " + name : ""));
    for (const r of refusals) {
      if (r.times > 0 && r.when(String(url), method, name)) {
        r.times--;
        return jsonRes(r.body || {}, r.status);
      }
    }
    return drive.fetch(url, opts);
  });
  app.runIn("driveRetryMs = 1");
  app.api.gdriveToken = "tok";
  app.api.gdriveTokenExp = clock.peek() + 3600e3;
  app.api.syncState = {
    queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], delTs: {},
    sigs: {}, rmt: {}, acct: "a1", parked: {}, connected: true, email: "e@x",
  };
  app.idb.set("recent", [{ name: "G.gba", ts: 1 }]);
  app.idb.set("rom:G.gba", { name: "G.gba", data: u8(1, 2, 3) });
  return { app, drive, seen };
};

const listing = (url, m) => m === "GET" && url.startsWith(FILES + "?spaces=appDataFolder");
const create = (url, m) => m === "POST" && url.includes("/upload/");

test("a rate limit on any request is waited out, and the sync completes", async () => {
  const rate403 = { error: { errors: [{ reason: "userRateLimitExceeded" }] } };
  const { app, drive } = await device([
    { when: listing, status: 429, times: 2 },
    { when: create, status: 403, body: rate403, times: 1 },
  ]);
  await app.api.dbPut("save:G.gba", u8(9));
  app.api.markUpload("save:G.gba");
  await app.api.flushSync();
  await settle();
  eq(drive.get("save:G.gba").bytes, u8(9));
  eq(app.api.syncState.queueUp, []);
  assert.notEqual(app.runIn("syncStatus"), "offline");
});

test("a server error repeats a download, never a create", async () => {
  const { app, drive, seen } = await device([
    { when: (u, m) => m === "GET" && u.includes("alt=media"), status: 503, times: 1 },
    { when: (u, m, name) => create(u, m) && name === "state:G.gba", status: 500, times: 1 },
  ]);
  drive.add("save:G.gba", u8(4));
  await app.api.pullSync();
  await settle();
  eq(app.idb.get("save:G.gba"), u8(4), "the download went again and landed");

  await app.api.dbPut("state:G.gba", u8(7));
  app.api.markUpload("state:G.gba");
  await app.api.flushSync();
  await settle();
  assert.equal(seen.filter((s) => s.startsWith("POST ") && s.endsWith(" state:G.gba")).length, 1,
               "the create was sent once");
  assert.equal(app.runIn("syncStatus"), "offline", "and the flush reports the failure");
  assert.ok(app.api.syncState.queueUp.includes("state:G.gba"), "still queued for next time");
});

test("a refusal that is not Drive slowing down fails at once", async () => {
  const { app, seen } = await device([
    { when: listing, status: 403, body: { error: { errors: [{ reason: "insufficientPermissions" }] } }, times: 5 },
  ]);
  await app.api.dbPut("save:G.gba", u8(9));
  app.api.markUpload("save:G.gba");
  await app.api.flushSync();
  await settle();
  assert.equal(seen.filter((s) => s.includes("?spaces=appDataFolder")).length, 1);
  assert.equal(app.runIn("syncStatus"), "offline");
});

test("Drive's Retry-After is honoured, up to 10 s", async () => {
  const app = await loadApp();
  const wait = (status, after, method = "GET") => app.runIn("driveRetryWait")(
    { status, headers: { get: (h) => (h === "retry-after" ? after : null) }, json: async () => ({}) },
    method, 0);
  assert.equal(await wait(429, "3"), 3000);
  assert.equal(await wait(429, "120"), 10000);
  assert.equal(await wait(503, "2", "POST"), null, "a create is not repeated");
  assert.equal(await wait(503, "2", "DELETE"), null, "nor a delete");
  assert.equal(await wait(404, null), null);
});
