// web/sw.js's downloads of a whole build: the install, and Force update's
// reinstall. Each asset is its own fetch, so a deploy can land between two
// of them (ServiceWorker.lean's bug_install_across_deploy_mixes_cache): what
// gets cached must be one build's bytes or nothing. The install takes each
// asset from the first copy that hashes to its build's manifest (a dingbat-*
// cache, the HTTP cache, then the network), so it also must never download
// what it already holds (ServiceWorker.lean's net_only_after_a_miss), and the
// DS core's files it takes only when held (lazy_never_downloaded). Force
// update commits into a cache of its own and moves the pointer once that
// holds everything (regress_force_update_serves_half_written_cache). The
// fetch handler serves every load of the app from "./" whatever its query
// (navigation_query_is_the_shell), and checks each file of the DS core
// against the manifest its cache keeps (lazy_served_is_its_build). sw.js runs
// in a node:vm context against a scripted server whose deployed build the
// test moves on mid-download.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { execFileSync } from "node:child_process";
import vm from "node:vm";
import { buildManifest, fileFor, sha256, swAssets, swLazy } from "../../.github/scripts/asset-manifest.mjs";

const SW = readFileSync(new URL("../sw.js", import.meta.url), "utf8");
const ASSETS = swAssets(SW);
const LAZY = swLazy(SW);
const stamped = (v) => {
  const s = SW.replace('CACHE_VERSION = "dev"', `CACHE_VERSION = "${v}"`);
  assert.ok(s.includes(`CACHE_VERSION = "${v}"`), "CACHE_VERSION stamping failed");
  return s;
};

const ORIGIN = "https://dingbat.test";
// Any URL of the site as the worker names its assets: "./path", no query.
const bare = (u) => {
  const s = String(u?.url ?? u).split("?")[0];
  return s.startsWith(ORIGIN + "/") ? "./" + s.slice(ORIGIN.length + 1) : s;
};
const enc = new TextEncoder();
const POINTER = "dingbat-live";
const MANIFEST = "./asset-manifest.json";

// A build: every asset's bytes, the DS core's files too. `changed` lists the
// files whose bytes this build changed from `from` (version.txt always
// changes: it is the version).
const mkBuild = (version, from = null, changed = []) => {
  const files = {};
  for (const u of [...ASSETS, ...LAZY]) {
    const f = fileFor(u);
    files[f] = f === "version.txt" ? version
      : from && !changed.includes(f) ? from.files[f] : `${version}:${f}`;
  }
  const digests = (urls) => Object.fromEntries(urls.map((u) => [u, sha256(enc.encode(files[fileFor(u)]))]));
  const sizes = Object.fromEntries([...ASSETS, ...LAZY].map((u) => [u, enc.encode(files[fileFor(u)]).length]));
  const manifest = { version, files: digests(ASSETS), lazy: digests(LAZY), sizes };
  return { version, files, manifest };
};

class FakeCache {
  constructor(name, server) {
    this.name = name; this.server = server;
    this.entries = new Map(); // bare URL -> body text
    this.cacheControl = new Map(); // bare URL -> the Cache-Control it was kept with
  }
  async put(req, res) {
    const body = await res.text();
    this.server?.beforePut?.(this.name, bare(req));
    this.entries.set(bare(req), body);
    this.cacheControl.set(bare(req), res.headers.get("Cache-Control"));
    this.server?.onPut?.(this.name, bare(req));
  }
  // By URL, query and all (the worker puts bare URLs).
  async match(req) {
    const q = String(req?.url ?? req).split("?")[1];
    const k = bare(req) + (q ? "?" + q : "");
    return this.entries.has(k) ? new Response(this.entries.get(k)) : undefined;
  }
  async keys() { return [...this.entries.keys()].map((k) => ({ url: new URL(k, ORIGIN + "/").href })); }
  async delete(req) { return this.entries.delete(bare(req)); }
}

// The storage and the server outlive a worker: setup({..., from: sw}) starts
// another worker over them (a cold start, or the next build's).
const setup = ({ worker, deployed = worker, http = {}, cachesHeld = {}, from = null }) => {
  /** @type {object[]} */
  const posted = []; // every message the worker posted its pages
  const server = from?.server || {
    deployed,      // the build the origin serves
    net: [],       // every network fetch the worker made, as "path?query"
    afterFetch: null,
    manifest404: false,
    offline: false,
    tamper: null,  // (path, query) => a body to send instead, or undefined
    timers: null,  // the grace timers held back, while an array
    onPut: null,   // (cache name, URL) after each put
    beforePut: null,
  };
  /** @type {Map<string, FakeCache>} */
  const caches = from?.caches || new Map();
  for (const [name, entries] of Object.entries(cachesHeld)) {
    const c = new FakeCache(name, server);
    for (const [k, v] of Object.entries(entries)) c.entries.set(k, v);
    caches.set(name, c);
  }
  const httpCache = from?.httpCache || new Map(Object.entries(http)); // bare URL -> body (what the page loaded)
  const listeners = {};
  const body = (b, path) => path === MANIFEST ? JSON.stringify(b.manifest)
    : b.files[path === "./" ? "index.html" : path.slice(2)];
  const sandbox = {
    Request: class { constructor(url) { this.url = new URL(url, ORIGIN + "/").href; } },
    Response,
    Headers,
    URL,
    location: new URL(ORIGIN + "/sw.js"),
    crypto: globalThis.crypto,
    // The Force update's grace before it drops the old cache: none here,
    // unless the test holds it (server.timers).
    setTimeout: (f) => (server.timers ? server.timers.push(f) : setTimeout(f, 0)),
    fetch: async (url, opts = {}) => {
      await null; // a round trip: other fetches interleave
      const path = bare(url);
      if (opts.cache === "only-if-cached") {
        if (opts.mode !== "same-origin") throw new TypeError("only-if-cached needs same-origin");
        if (!httpCache.has(path)) throw new TypeError("not in the HTTP cache");
        return new Response(httpCache.get(path));
      }
      const query = String(url?.url ?? url).split("?")[1];
      server.net.push(path + (query ? "?" + query : ""));
      if (server.offline) throw new TypeError("Failed to fetch");
      const b = server.deployed;
      let res;
      if (path === MANIFEST && server.manifest404) res = new Response("", { status: 404 });
      else {
        const t = server.tamper?.(path, query) ?? body(b, path);
        res = t === undefined ? new Response("", { status: 404 }) : new Response(t);
      }
      server.afterFetch?.(server.net.length, path);
      return res;
    },
    caches: {
      open: async (name) => {
        if (!caches.has(name)) caches.set(name, new FakeCache(name, server));
        return caches.get(name);
      },
      has: async (name) => caches.has(name),
      keys: async () => [...caches.keys()],
      // A deleted cache's handle lives on, holding whatever is put into it,
      // but no name reaches it any more (as in a browser).
      delete: async (name) => caches.delete(name),
      match: async (req, { cacheName } = {}) => caches.get(cacheName)?.match(req),
    },
    addEventListener: (type, fn) => { listeners[type] = fn; },
    skipWaiting() {},
    // One open page, keeping every message the worker posts it (progress).
    clients: {
      claim() {},
      matchAll: async () => [{ postMessage: (m) => posted.push({ ...m }) }],
    },
    Date, Math, Promise, Error, TypeError, Map, Object, Uint8Array, JSON, String,
  };
  sandbox.self = sandbox;
  vm.runInContext(stamped(worker.version), vm.createContext(sandbox), { filename: "web/sw.js" });

  const install = () => {
    let p;
    listeners.install({ waitUntil: (x) => { p = x; } });
    return p.then(() => "installed", (e) => "failed: " + e.message);
  };
  const activate = () => {
    let p;
    listeners.activate({ waitUntil: (x) => { p = x; } });
    return p;
  };
  // A Force update: `reply` once it answers, `settled` once its run is over
  // (the old cache's drop included).
  const reinstallRun = (nonce = 12345) => {
    let p, answered;
    const reply = new Promise((r) => { answered = r; });
    listeners.message({
      data: { type: "reinstall", nonce },
      source: { postMessage: (m) => answered({ ...m }) }, // out of the vm's realm, for deepEqual
      waitUntil: (x) => { p = x; },
    });
    return { settled: p, reply };
  };
  const reinstall = (nonce) => reinstallRun(nonce).reply;
  // A request from a page: `nav` for a load of the app.
  const fetchAs = async (path, { nav = false, query = "", clientId = "", resultingClientId = "" } = {}) => {
    let p;
    const waits = [];
    const request = { url: new URL(path + (query ? "?" + query : ""), ORIGIN + "/").href,
                      mode: nav ? "navigate" : "no-cors", method: "GET", cache: "default" };
    listeners.fetch({ request, clientId, resultingClientId,
                      respondWith: (x) => { p = x; }, waitUntil: (x) => waits.push(x) });
    const res = await p;
    await Promise.all(waits);
    return res.type === "error" ? null : await res.text();
  };
  // The live cache, as the pointer names it (no entry: the install's).
  const live = () => caches.get(POINTER)?.entries.get("./live/" + worker.version) ?? "dingbat-" + worker.version;
  const contents = (name) => Object.fromEntries([...caches.get(name)?.entries || []]);
  // Whether the cache `name` holds build b: every asset, any DS core file it
  // has, and the manifest it keeps, all b's.
  const isBuild = (name, b) => {
    const c = contents(name);
    return ASSETS.every((u) => c[u] === body(b, u)) &&
      LAZY.every((u) => c[u] === undefined || c[u] === body(b, u)) &&
      (c[MANIFEST] === undefined || JSON.parse(c[MANIFEST]).version === b.version);
  };
  // The assets the worker fetched from the network, bare.
  const downloads = () => server.net.map(bare).filter((p) => p !== MANIFEST);
  return { server, caches, httpCache, install, activate, reinstall, reinstallRun, fetchAs, live,
           contents, isBuild, downloads, body, posted, name: "dingbat-" + worker.version };
};

const A = mkBuild("aaaaaaa");
const B = mkBuild("bbbbbbb", A, ["index.js"]);            // an index.js-only update
const C = mkBuild("ccccccc", B, ["index.js", "em.wasm"]);
const D = mkBuild("ddddddd", C, ["index.js", "nds/nds.js", "nds/nds.wasm"]); // the DS core changes
const cacheOf = (b) => Object.fromEntries(ASSETS.map((u) => [u, b.files[fileFor(u)]]));
// The DS core as an older worker leaves it once a DS game has started: by
// bare URL, unchecked.
const lazyOf = (b, urls = LAZY) => Object.fromEntries(urls.map((u) => [u, b.files[fileFor(u)]]));
// What a first visit's page loaded itself (index.html's scripts and styles,
// em.js and em.wasm from index.js), by bare URL.
const PAGE_LOADS = ["./", "./index.js", "./glpresent.js", "./saveimport.js", "./nds/ndsutil.js",
  "./nds/ndsaudio.js", "./clipmux.js", "./zipwrite.js", "./framegrid.js", "./sdputil.js",
  "./netplay.js", "./styles.css", "./em.js", "./em.wasm", "./favicon.svg", "./logo.svg"];
const httpOf = (b, urls = PAGE_LOADS) => Object.fromEntries(urls.map((u) => [u, b.files[fileFor(u)]]));
// A worker of build b, installed and active, over nothing else.
const activeOn = async (b, o = {}) => {
  const sw = setup({ worker: b, ...o });
  assert.equal(await sw.install(), "installed");
  await sw.activate();
  sw.server.net.length = 0;
  return sw;
};

test("a first install with nothing held downloads each asset once, index.html once for ./ too", async () => {
  const sw = setup({ worker: A });
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, A));
  const d = sw.downloads();
  assert.equal(d.length, ASSETS.length - 1, "one download per distinct file: " + d.join(" "));
  assert.equal(new Set(d).size, d.length, "nothing downloaded twice");
  assert.ok(sw.server.net.every((u) => /\?(v=aaaaaaa|probe=)/.test(u)), "every fetch past the edges");
  assert.equal(JSON.parse(sw.contents(sw.name)[MANIFEST]).version, A.version, "the cache keeps its manifest");
  for (const u of LAZY) assert.ok(!sw.downloads().includes(u), u + ": the DS core is never precached");
});

test("a first visit's install takes what the page loaded from the HTTP cache", async () => {
  const sw = setup({ worker: A, http: httpOf(A) });
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, A));
  const d = sw.downloads();
  for (const u of PAGE_LOADS) assert.ok(!d.includes(u), u + " was downloaded again");
  assert.ok(!d.includes("./index.html"), "./index.html is ./'s bytes");
  assert.equal(d.length, ASSETS.length - 1 - PAGE_LOADS.length, d.join(" "));
});

test("an HTTP cache copy from another build is not taken: that asset is downloaded", async () => {
  const sw = setup({ worker: B, http: httpOf(A) });
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, B));
  assert.ok(sw.downloads().includes("./index.js"));
  assert.ok(!sw.downloads().includes("./em.wasm"));
});

test("an index.js-only update downloads index.js and version.txt, nothing else", async () => {
  const sw = setup({ worker: B, cachesHeld: { "dingbat-aaaaaaa": cacheOf(A) } });
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, B));
  assert.deepEqual(sw.downloads().sort(), ["./index.js", "./version.txt"]);
});

test("an old worker's cache (bare URLs, no digests) is reused by hashing it", async () => {
  // As origin/main's sw.js leaves it, a Force update's staging cache beside it.
  const sw = setup({ worker: C, cachesHeld: { "dingbat-aaaaaaa": cacheOf(A),
    "dingbat-reinstall-99": cacheOf(B) } });
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, C));
  assert.deepEqual(sw.downloads().sort(), ["./em.wasm", "./index.js", "./version.txt"]);
});

test("a held copy whose bytes are wrong is never kept", async () => {
  const bad = cacheOf(A);
  bad["./em.wasm"] = "truncated";
  bad["./styles.css"] = B.files["styles.css"] + " ";
  const sw = setup({ worker: B, cachesHeld: { "dingbat-aaaaaaa": bad } });
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, B));
  assert.deepEqual(sw.downloads().sort(), ["./em.wasm", "./index.js", "./styles.css", "./version.txt"]);
});

test("an install that straddles a deploy changing a file still to come fails " +
     "(regress_install_across_deploy_mixes_cache)", async () => {
  const sw = setup({ worker: B, deployed: B });
  sw.server.afterFetch = (n) => { if (n === 3) sw.server.deployed = C; };
  assert.match(await sw.install(), /^failed/, "a cache holding two builds must never be installed");
  assert.ok(!sw.caches.has(sw.name) || sw.contents(sw.name)["./em.wasm"] !== C.files["em.wasm"]);
});

test("a deploy mid-install that changes nothing still to come leaves the install one build", async () => {
  // C changes index.js and em.wasm; both are downloaded before it lands.
  const sw = setup({ worker: B, cachesHeld: { "dingbat-aaaaaaa": cacheOf(A) } });
  sw.server.afterFetch = (n) => { if (n === 3) sw.server.deployed = C; };
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, B), "B's bytes, every one");
});

test("an install whose server has already moved on fails before downloading anything", async () => {
  // sw.js from a lagging edge names build A; the origin serves B.
  const sw = setup({ worker: A, deployed: B });
  assert.match(await sw.install(), /the server is on bbbbbbb/);
  assert.deepEqual(sw.downloads(), []);
});

test("a manifest that does not list the worker's assets is refused", async () => {
  const short = { ...A, manifest: { ...A.manifest, files: { ...A.manifest.files } } };
  delete short.manifest.files["./em.wasm"];
  const sw = setup({ worker: A, deployed: short });
  assert.match(await sw.install(), /does not list/);
  assert.equal(sw.caches.has(sw.name), false);
});

test("a manifest without the DS core's digests (one from before them) is refused", async () => {
  const old = { ...A, manifest: { version: A.version, files: A.manifest.files } };
  const sw = setup({ worker: A, deployed: old });
  assert.match(await sw.install(), /does not list/);
});

test("no manifest (a deploy from before it existed) fails the install", async () => {
  const sw = setup({ worker: A });
  sw.server.manifest404 = true;
  assert.match(await sw.install(), /manifest fetch failed: 404/);
});

test("an activation deleting the cache mid-put fails the install instead of leaving it empty", async () => {
  const sw = setup({ worker: B, cachesHeld: { "dingbat-aaaaaaa": cacheOf(A) } });
  // The first put into dingbat-bbbbbbb lets another worker's activate run.
  let deleted = false;
  sw.server.onPut = (name) => {
    if (name === sw.name && !deleted) { deleted = true; sw.caches.delete(sw.name); }
  };
  assert.match(await sw.install(), /went away mid-install/);
  assert.ok(deleted);
});

test("a retry after a failed install reuses what that one verified", async () => {
  const sw = setup({ worker: B, cachesHeld: { "dingbat-bbbbbbb": { "./em.wasm": B.files["em.wasm"] } } });
  assert.equal(await sw.install(), "installed");
  assert.ok(!sw.downloads().includes("./em.wasm"));
});

test("a development build installs without a manifest", async () => {
  const Dev = mkBuild("dev");
  const sw = setup({ worker: Dev });
  sw.server.manifest404 = true;
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, Dev));
});

// --- The DS core ----------------------------------------------------------

test("an update carries the DS core an older worker fetched over, downloading none of it " +
     "(old_worker_ds_core_carried_over)", async () => {
  // 0b7f1b57's worker keeps the files a DS game fetched in its own cache.
  const sw = setup({ worker: B, cachesHeld: { "dingbat-aaaaaaa": { ...cacheOf(A), ...lazyOf(A) } } });
  assert.equal(await sw.install(), "installed");
  for (const u of LAZY) assert.equal(sw.contents(sw.name)[u], B.files[fileFor(u)], u + " carried over");
  assert.deepEqual(sw.downloads().sort(), ["./index.js", "./version.txt"]);
});

test("a held DS core file of another build is left behind, and nothing of the DS core downloads", async () => {
  // D changes nds.js and nds.wasm; gpu3d.js is C's bytes still.
  const sw = setup({ worker: D, cachesHeld: { "dingbat-ccccccc": { ...cacheOf(C), ...lazyOf(C) } } });
  assert.equal(await sw.install(), "installed");
  const c = sw.contents(sw.name);
  assert.equal(c["./nds/nds.js"], undefined);
  assert.equal(c["./nds/nds.wasm"], undefined);
  assert.equal(c["./nds/gpu3d.js"], D.files["nds/gpu3d.js"]);
  for (const u of LAZY) assert.ok(!sw.downloads().includes(u), u + " downloaded");
});

test("a DS core file is downloaded once, checked, kept, then served from the cache", async () => {
  const sw = await activeOn(A);
  assert.equal(await sw.fetchAs("./nds/nds.wasm"), A.files["nds/nds.wasm"]);
  assert.equal(sw.contents(sw.live())["./nds/nds.wasm"], A.files["nds/nds.wasm"]);
  assert.deepEqual(sw.server.net, ["./nds/nds.wasm"], "the bare URL, once");
  sw.server.offline = true;
  assert.equal(await sw.fetchAs("./nds/nds.wasm"), A.files["nds/nds.wasm"], "offline, from the cache");
  assert.equal(sw.server.net.length, 1);
});

test("a stale edge's DS core file is refused: the retry under a fresh URL gets the right one", async () => {
  const sw = await activeOn(B);
  // The edge still serves A's nds.wasm under the bare URL (B shares it), and
  // C's nds.js: wrong for B.
  sw.server.tamper = (path, q) => path === "./nds/nds.js" && !q ? C.files["nds/nds.js"] + "x" : undefined;
  assert.equal(await sw.fetchAs("./nds/nds.js"), B.files["nds/nds.js"]);
  assert.equal(sw.server.net.length, 2);
  assert.match(sw.server.net[1], /^\.\/nds\/nds\.js\?v=/);
  assert.equal(sw.contents(sw.live())["./nds/nds.js"], B.files["nds/nds.js"]);
});

test("a DS core file whose bytes are never this build's fails and is not kept " +
     "(regress_tampered_lazy_refused)", async () => {
  const sw = await activeOn(A);
  sw.server.deployed = D; // the origin moved on: its nds.wasm is D's
  assert.equal(await sw.fetchAs("./nds/nds.wasm"), null, "a network error, as the page sees it");
  assert.equal(sw.contents(sw.live())["./nds/nds.wasm"], undefined, "nothing kept");
  assert.equal(sw.server.net.length, 2, "the bare URL, then a fresh one");
  sw.server.deployed = A;
  assert.equal(await sw.fetchAs("./nds/nds.wasm"), A.files["nds/nds.wasm"], "the next try downloads again");
});

test("a DS core URL with a query (the dev server's stamp) is not the DS core: network, not kept", async () => {
  const sw = await activeOn(A);
  assert.equal(await sw.fetchAs("./nds/nds.js", { query: "v=123" }), A.files["nds/nds.js"]);
  assert.equal(sw.contents(sw.live())["./nds/nds.js"], undefined);
});

// --- Loads of the app ----------------------------------------------------

test("a load of the app with any query is served from ./ (navigation_query_is_the_shell)", async () => {
  const sw = await activeOn(A);
  sw.server.deployed = B; // a deploy: the network has B's index.html
  for (const query of ["", "2p", "gpu3d=1", "gpu3d=1&gpu3d-skip=0"]) {
    assert.equal(await sw.fetchAs("./", { nav: true, query }), A.files["index.html"], query);
    assert.equal(await sw.fetchAs("./index.html", { nav: true, query }), A.files["index.html"], query);
  }
  assert.deepEqual(sw.server.net, [], "no load of the app went to the network");
  sw.server.offline = true;
  assert.equal(await sw.fetchAs("./", { nav: true, query: "2p" }), A.files["index.html"], "offline");
});

test("a request with a query that is not a load of the app still misses, as before", async () => {
  const sw = await activeOn(A);
  sw.server.deployed = B;
  assert.equal(await sw.fetchAs("./index.js", { query: "v=9" }), B.files["index.js"]);
  await sw.fetchAs("./oauth-callback.html", { nav: true, query: "code=1" });
  assert.ok(sw.server.net.includes("./oauth-callback.html?code=1"), "another page: its own URL");
});

// --- Force update ---------------------------------------------------------

test("a quiet Force update downloads every asset again into a cache of its own, then moves the pointer",
  async () => {
    const sw = await activeOn(A);
    const before = sw.live();
    assert.deepEqual(await sw.reinstall(), { type: "reinstalled", ok: true });
    sw.server.deployed = B;
    const r = sw.reinstallRun(23456);
    assert.deepEqual(await r.reply, { type: "reinstalled", ok: true });
    await r.settled;
    assert.notEqual(sw.live(), before);
    assert.match(sw.live(), /^dingbat-aaaaaaa-23456-/);
    assert.ok(sw.isBuild(sw.live(), B), "the deployed build, every asset");
    assert.equal(JSON.parse(sw.contents(sw.live())[MANIFEST]).version, B.version);
    assert.ok(sw.server.net.filter((u) => /\?v=23456/.test(u)).length === ASSETS.length - 1,
              "no held copy reused");
    assert.deepEqual([...sw.caches.keys()].sort(), [POINTER, sw.live()].sort(), "the old cache dropped");
    assert.equal(await sw.fetchAs("./", { nav: true }), B.files["index.html"]);
  });

// The bytes a build's assets come to, one file per digest (index.js assetBytes).
const bytesOf = (b) => {
  const seen = new Map();
  for (const u of ASSETS) seen.set(b.manifest.files[u], b.manifest.sizes[u]);
  return [...seen.values()].reduce((x, y) => x + y, 0);
};
const settle = () => new Promise((r) => setTimeout(r, 0));

test("an install tells the open pages how far it has got, ending at the whole build", async () => {
  const sw = setup({ worker: B, cachesHeld: { "dingbat-aaaaaaa": cacheOf(A) } });
  assert.equal(await sw.install(), "installed");
  await settle();
  const p = sw.posted.filter((m) => m.type === "progress");
  assert.ok(p.length >= 1, "at least the end");
  assert.ok(p.every((m) => m.of === "install" && m.version === B.version && m.total === bytesOf(B)));
  assert.ok(p.every((m, i) => i === 0 || m.done >= p[i - 1].done), "never backwards");
  assert.equal(p.at(-1).done, p.at(-1).total, "the end is the whole");
});

test("a Force update tells the pages its own progress, the DS core it brings again included", async () => {
  const sw = await activeOn(A);
  await sw.fetchAs("./nds/nds.js"); // a DS game has run: the live cache holds that file
  sw.posted.length = 0;
  sw.server.deployed = B;
  const r = sw.reinstallRun(45678);
  assert.deepEqual(await r.reply, { type: "reinstalled", ok: true });
  await r.settled;
  await settle();
  const p = sw.posted.filter((m) => m.type === "progress");
  assert.ok(p.length >= 1);
  assert.ok(p.every((m) => m.of === "reinstall" && m.total === bytesOf(B) + B.manifest.sizes["./nds/nds.js"]));
  assert.equal(p.at(-1).done, p.at(-1).total);
});

test("a manifest without sizes (one from before them) installs as before, its progress without a total",
  async () => {
    const old = { ...B, manifest: { ...B.manifest, sizes: undefined } };
    const sw = setup({ worker: old, cachesHeld: { "dingbat-aaaaaaa": cacheOf(A) } });
    assert.equal(await sw.install(), "installed");
    await settle();
    assert.ok(sw.posted.filter((m) => m.type === "progress").every((m) => m.total === 0));
  });

test("every copy the worker keeps says no-cache, installed or Force-updated", async () => {
  // Kept with Pages' max-age, a copy the worker served let Chromium's reload
  // after a Force update run the index.js the page had already run.
  const sw = await activeOn(A);
  const kept = (name) => sw.caches.get(name).cacheControl;
  for (const u of ASSETS) assert.equal(kept(sw.live()).get(bare(u)), "no-cache", u);
  sw.server.deployed = B;
  const r = sw.reinstallRun(34567);
  assert.deepEqual(await r.reply, { type: "reinstalled", ok: true });
  await r.settled;
  for (const u of ASSETS) assert.equal(kept(sw.live()).get(bare(u)), "no-cache", u + ", Force-updated");
});

test("Force update never writes into the live cache: a page loading mid-commit sees one build " +
     "(regress_force_update_serves_half_written_cache)", async () => {
  const sw = await activeOn(A);
  sw.server.deployed = C;
  const seen = [];
  sw.server.beforePut = (name) => {
    assert.notEqual(name, sw.live(), "a put into the live cache");
    if (name.startsWith("dingbat-aaaaaaa-")) {
      // Every put of the commit: a page boots from the live cache meanwhile.
      seen.push(Promise.all([sw.fetchAs("./index.js"), sw.fetchAs("./em.wasm")]));
    }
  };
  assert.deepEqual(await sw.reinstall(), { type: "reinstalled", ok: true });
  for (const [js, wasm] of await Promise.all(seen)) {
    assert.ok((js === A.files["index.js"] && wasm === A.files["em.wasm"]) ||
              (js === C.files["index.js"] && wasm === C.files["em.wasm"]), "mixed: " + js + " " + wasm);
  }
  assert.ok(seen.length > 0);
});

test("a worker stopped mid-commit leaves the old cache serving, and a cold start finds it " +
     "(force_kill_mid_commit_old_cache_serves)", async () => {
  const sw = await activeOn(A);
  sw.server.deployed = C;
  let puts = 0;
  // Killed after half the puts: nothing after them runs.
  sw.server.beforePut = (name) => { if (name.startsWith("dingbat-aaaaaaa-") && ++puts > 10) throw new Error("killed"); };
  assert.deepEqual(await sw.reinstall(), { type: "reinstalled", ok: false });
  sw.server.beforePut = null;
  // A cold start of the same worker: no memory, the same storage.
  const cold = setup({ worker: A, from: sw });
  assert.equal(cold.live(), "dingbat-aaaaaaa");
  assert.equal(await cold.fetchAs("./", { nav: true, query: "2p" }), A.files["index.html"]);
  assert.equal(await cold.fetchAs("./em.wasm"), A.files["em.wasm"]);
  // The next Force update drops what that one left, and lands.
  assert.deepEqual(await cold.reinstall(777), { type: "reinstalled", ok: true });
  assert.ok(cold.isBuild(cold.live(), C));
  assert.ok([...sw.caches.keys()].every((k) => k === POINTER || k === cold.live() || k === "dingbat-aaaaaaa"));
});

test("a worker stopped after the pointer moved starts cold on the new cache", async () => {
  const sw = await activeOn(A);
  sw.server.deployed = B;
  const r = sw.reinstallRun(31337);
  assert.deepEqual(await r.reply, { type: "reinstalled", ok: true });
  // Stopped before the old cache's drop: a cold start reads the pointer.
  const cold = setup({ worker: A, from: sw });
  assert.match(cold.live(), /^dingbat-aaaaaaa-31337-/);
  assert.equal(await cold.fetchAs("./index.js"), B.files["index.js"]);
  await r.settled;
});

test("Force update brings again the DS core files the live cache holds, checked", async () => {
  const sw = await activeOn(A);
  await sw.fetchAs("./nds/nds.js");
  sw.server.deployed = D;
  sw.server.net.length = 0;
  assert.deepEqual(await sw.reinstall(4242), { type: "reinstalled", ok: true });
  const c = sw.contents(sw.live());
  assert.equal(c["./nds/nds.js"], D.files["nds/nds.js"]);
  assert.equal(c["./nds/nds.wasm"], undefined, "not held before: not downloaded");
  assert.ok(sw.server.net.includes("./nds/nds.js?v=4242"));
  assert.ok(!sw.server.net.some((u) => u.startsWith("./nds/nds.wasm") || u.startsWith("./nds/gpu3d.js")));
});

test("two Force updates at once share one run", async () => {
  const sw = await activeOn(A);
  sw.server.deployed = B;
  const r1 = sw.reinstallRun(1);
  const r2 = sw.reinstallRun(2);
  assert.deepEqual(await r1.reply, { type: "reinstalled", ok: true });
  assert.deepEqual(await r2.reply, { type: "reinstalled", ok: true });
  await Promise.all([r1.settled, r2.settled]);
  assert.equal(sw.server.net.filter((u) => u.startsWith("./index.js?")).length, 1);
  assert.ok(sw.isBuild(sw.live(), B));
});

test("Force update that straddles a deploy leaves the live cache as it was", async () => {
  const sw = await activeOn(A);
  sw.server.deployed = B;
  sw.server.afterFetch = (n) => { if (n === 3) sw.server.deployed = C; };
  assert.deepEqual(await sw.reinstall(), { type: "reinstalled", ok: false },
                   "the page falls back to the full reset");
  assert.equal(sw.live(), sw.name);
  assert.ok(sw.isBuild(sw.name, A), "no page may boot from a half-rewritten cache");
});

test("Force update with no manifest deployed answers ok:false", async () => {
  const sw = await activeOn(A);
  sw.server.manifest404 = true;
  assert.deepEqual(await sw.reinstall(), { type: "reinstalled", ok: false });
  assert.ok(sw.isBuild(sw.name, A));
});

test("a page booting while the pointer moves keeps its navigation's cache", async () => {
  const sw = await activeOn(A);
  assert.equal(await sw.fetchAs("./", { nav: true, resultingClientId: "tab" }), A.files["index.html"]);
  sw.server.deployed = B;
  // The pointer moves, the old cache still there (its grace).
  sw.server.timers = [];
  const run = sw.reinstallRun(99);
  assert.deepEqual(await run.reply, { type: "reinstalled", ok: true });
  assert.equal(await sw.fetchAs("./index.js", { clientId: "tab" }), A.files["index.js"], "its own build");
  assert.equal(await sw.fetchAs("./index.js", { clientId: "other" }), B.files["index.js"], "a new page: B");
  const held = sw.server.timers;
  sw.server.timers = null;
  for (const f of held) f();
  await run.settled;
  // Once the old cache is gone, the live one serves it.
  assert.equal(await sw.fetchAs("./index.js", { clientId: "tab" }), B.files["index.js"]);
});

test("activation keeps the live cache and the pointer, and drops the rest", async () => {
  const sw = await activeOn(A);
  sw.server.deployed = B;
  assert.deepEqual(await sw.reinstall(5), { type: "reinstalled", ok: true });
  const aLive = sw.live();
  // The next build installs from that cache and activates.
  sw.server.deployed = C;
  const next = setup({ worker: C, from: sw, cachesHeld: { "dingbat-old-junk": { "./x": "y" } } });
  assert.equal(await next.install(), "installed");
  assert.deepEqual(next.server.net.filter((u) => u.includes("?v=ccccccc")).sort(),
                   ["./em.wasm?v=ccccccc", "./index.js?v=ccccccc", "./version.txt?v=ccccccc"].sort());
  await next.activate();
  assert.deepEqual([...sw.caches.keys()].sort(), ["dingbat-ccccccc", POINTER]);
  assert.deepEqual([...sw.caches.get(POINTER).entries.keys()], ["./live/ccccccc"]);
  assert.ok(!sw.caches.has(aLive));
});

// --- the manifest itself (deploy-pages.yml) -----------------------------

const site = () => {
  const dir = mkdtempSync(join(tmpdir(), "dingbat-manifest-"));
  for (const u of [...ASSETS, ...LAZY]) {
    const f = join(dir, fileFor(u));
    mkdirSync(dirname(f), { recursive: true });
    writeFileSync(f, "bytes of " + fileFor(u));
  }
  writeFileSync(join(dir, "sw.js"), stamped("abc1234"));
  return dir;
};
const script = new URL("../../.github/scripts/asset-manifest.mjs", import.meta.url).pathname;

test("the manifest lists exactly sw.js's ASSETS, ./ as index.html, and its LAZY apart, " +
     "under its CACHE_VERSION", () => {
  const dir = site();
  try {
    execFileSync(process.execPath, [script, dir], { stdio: "pipe" });
    const m = JSON.parse(readFileSync(join(dir, "asset-manifest.json"), "utf8"));
    assert.equal(m.version, "abc1234");
    assert.deepEqual(Object.keys(m.files), ASSETS, "files: what workers from before LAZY check");
    assert.deepEqual(Object.keys(m.lazy), LAZY);
    assert.deepEqual(LAZY, ["./nds/nds.js", "./nds/nds.wasm", "./nds/gpu3d.js"]);
    assert.equal(m.files["./"], m.files["./index.html"]);
    assert.equal(m.files["./em.wasm"], sha256(readFileSync(join(dir, "em.wasm"))));
    assert.equal(m.lazy["./nds/nds.wasm"], sha256(readFileSync(join(dir, "nds/nds.wasm"))));
    assert.deepEqual(buildManifest(dir), m, "the same bytes write the same manifest");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("the manifest script refuses an unstamped sw.js", () => {
  const dir = site();
  try {
    writeFileSync(join(dir, "sw.js"), SW);
    assert.throws(() => execFileSync(process.execPath, [script, dir], { stdio: "pipe" }));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("a missing precached file, or a missing DS core file, fails the manifest, so the deploy", () => {
  for (const f of ["flap-dusk.png", "nds/nds.wasm"]) {
    const dir = site();
    try {
      rmSync(join(dir, f));
      assert.throws(() => execFileSync(process.execPath, [script, dir], { stdio: "pipe" }), f);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }
});
