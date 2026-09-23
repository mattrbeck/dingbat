// web/sw.js's downloads of a whole build: the install, and Force update's
// reinstall into the live cache. Each asset is its own fetch, so a deploy
// can land between two of them (ServiceWorker.lean's
// bug_install_across_deploy_mixes_cache): what gets cached must be one build
// or nothing. sw.js runs in a node:vm context against a scripted server
// whose deployed build the test moves on mid-download.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

// CI stamps the commit into CACHE_VERSION (deploy-pages.yml); so do we.
const BUILD_A = "aaaaaaa";
const SOURCE = readFileSync(new URL("../sw.js", import.meta.url), "utf8")
  .replace('CACHE_VERSION = "dev"', `CACHE_VERSION = "${BUILD_A}"`);
assert.ok(SOURCE.includes(`CACHE_VERSION = "${BUILD_A}"`), "CACHE_VERSION stamping failed");

const bare = (u) => String(u?.url ?? u).split("?")[0];

class FakeCache {
  constructor() { this.entries = new Map(); } // bare URL -> body
  async put(req, res) { this.entries.set(bare(req), await res.text()); }
  async match(req) {
    const k = bare(req);
    return this.entries.has(k) ? mkRes(this.entries.get(k)) : undefined;
  }
}
const mkRes = (body, status = 200) =>
  ({ ok: status >= 200 && status < 300, status, text: async () => body });

const setup = ({ deployed = BUILD_A } = {}) => {
  const server = {
    deployed,
    fetches: [],     // every URL the worker fetched, in order
    afterFetch: null, // (n) => called after the n-th fetch (1-based) is answered
  };
  const caches = new Map();
  const listeners = {};
  const sandbox = {
    Request: class { constructor(url) { this.url = url; } },
    fetch: async (url) => {
      await null; // a network round trip: other fetches interleave
      server.fetches.push(String(url));
      const path = bare(url);
      // Every asset's bytes say which build served them; version.txt is the build.
      const body = path === "./version.txt" ? server.deployed : `${server.deployed}:${path}`;
      const res = mkRes(body);
      server.afterFetch?.(server.fetches.length);
      return res;
    },
    caches: {
      open: async (name) => {
        if (!caches.has(name)) caches.set(name, new FakeCache());
        return caches.get(name);
      },
      keys: async () => [...caches.keys()],
      delete: async (name) => caches.delete(name),
      match: async () => undefined,
    },
    addEventListener: (type, fn) => { listeners[type] = fn; },
    skipWaiting() {},
    clients: { claim() {} },
    Date, Math, Promise, Error,
  };
  sandbox.self = sandbox;
  vm.runInContext(SOURCE, vm.createContext(sandbox), { filename: "web/sw.js" });

  // The install event; resolves to "installed" or "failed" as waitUntil settles.
  const install = () => {
    let p;
    listeners.install({ waitUntil: (x) => { p = x; } });
    return p.then(() => "installed", () => "failed");
  };
  // The menu's Force update: the "reinstalled" reply's ok flag.
  const reinstall = () => {
    let p;
    const replies = [];
    listeners.message({
      data: { type: "reinstall", nonce: 12345 },
      source: { postMessage: (m) => replies.push(m) },
      waitUntil: (x) => { p = x; },
    });
    return p.then(() => replies[0]?.ok);
  };
  // Which builds a cache's assets came from.
  const builds = (name) => {
    const c = caches.get(name);
    return new Set([...c.entries.values()].map((b) => b.split(":")[0]));
  };
  return { server, caches, install, reinstall, builds, liveName: "dingbat-" + BUILD_A };
};

test("an install that straddles a deploy fails, so the old worker stays " +
     "(bug_install_across_deploy_mixes_cache)", async () => {
  const sw = setup();
  sw.server.afterFetch = (n) => { if (n === 5) sw.server.deployed = "bbbbbbb"; };
  assert.equal(await sw.install(), "failed",
               "a cache holding two builds must never be installed");
});

test("an install whose server has already moved on fails", async () => {
  // sw.js from a lagging edge names build A; the assets would all be B.
  const sw = setup({ deployed: "bbbbbbb" });
  assert.equal(await sw.install(), "failed");
});

test("a quiet install caches every asset from its own build", async () => {
  const sw = setup();
  assert.equal(await sw.install(), "installed");
  assert.deepEqual([...sw.builds(sw.liveName)], [BUILD_A]);
  assert.equal(sw.caches.get(sw.liveName).entries.size, 15, "all ASSETS cached");
});

test("Force update that straddles a deploy leaves the live cache as it was", async () => {
  const sw = setup();
  assert.equal(await sw.install(), "installed");
  sw.server.deployed = "bbbbbbb"; // the deploy the stale edge is hiding
  const from = sw.server.fetches.length;
  sw.server.afterFetch = (n) => { if (n === from + 5) sw.server.deployed = "ccccccc"; };
  assert.equal(await sw.reinstall(), false, "the page falls back to the full reset");
  assert.deepEqual([...sw.builds(sw.liveName)], [BUILD_A],
                   "no page may boot from a half-rewritten cache");
  assert.deepEqual([...sw.caches.keys()], [sw.liveName], "no staging cache left behind");
});

test("a quiet Force update rewrites the live cache with the deployed build", async () => {
  const sw = setup();
  assert.equal(await sw.install(), "installed");
  sw.server.deployed = "bbbbbbb";
  assert.equal(await sw.reinstall(), true);
  assert.deepEqual([...sw.builds(sw.liveName)], ["bbbbbbb"]);
  assert.equal(sw.caches.get(sw.liveName).entries.size, 15);
  assert.deepEqual([...sw.caches.keys()], [sw.liveName], "no staging cache left behind");
});
