// web/sw.js's downloads of a whole build: the install, and Force update's
// reinstall into the live cache. Each asset is its own fetch, so a deploy can
// land between two of them (ServiceWorker.lean's
// bug_install_across_deploy_mixes_cache): what gets cached must be one
// build's bytes or nothing. The install takes each asset from the first copy
// that hashes to its build's manifest (a dingbat-* cache, the HTTP cache, then
// the network), so it also must never download what it already holds
// (ServiceWorker.lean's held_never_downloaded). sw.js runs in a node:vm
// context against a scripted server whose deployed build the test moves on
// mid-download.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { execFileSync } from "node:child_process";
import vm from "node:vm";
import { buildManifest, fileFor, sha256, swAssets } from "../../.github/scripts/asset-manifest.mjs";

const SW = readFileSync(new URL("../sw.js", import.meta.url), "utf8");
const ASSETS = swAssets(SW);
const stamped = (v) => {
  const s = SW.replace('CACHE_VERSION = "dev"', `CACHE_VERSION = "${v}"`);
  assert.ok(s.includes(`CACHE_VERSION = "${v}"`), "CACHE_VERSION stamping failed");
  return s;
};

const bare = (u) => String(u?.url ?? u).split("?")[0];
const enc = new TextEncoder();

// A build: every asset's bytes. `changed` lists the files whose bytes this
// build changed from `from` (version.txt always changes: it is the version).
const mkBuild = (version, from = null, changed = []) => {
  const files = {};
  for (const u of ASSETS) {
    const f = fileFor(u);
    files[f] = f === "version.txt" ? version
      : from && !changed.includes(f) ? from.files[f] : `${version}:${f}`;
  }
  const manifest = { version, files: Object.fromEntries(ASSETS.map((u) => [u, sha256(enc.encode(files[fileFor(u)]))])) };
  return { version, files, manifest };
};

class FakeCache {
  constructor(name, server) { this.name = name; this.server = server; this.entries = new Map(); } // bare URL -> body text
  async put(req, res) {
    this.entries.set(bare(req), await res.text());
    this.server?.onPut?.(this.name, bare(req));
  }
  async match(req) {
    const k = bare(req);
    return this.entries.has(k) ? new Response(this.entries.get(k)) : undefined;
  }
}

const setup = ({ worker, deployed = worker, http = {}, cachesHeld = {} }) => {
  const server = {
    deployed,      // the build the origin serves
    net: [],       // every network fetch the worker made, as "path?query"
    afterFetch: null,
    manifest404: false,
    onPut: null,   // (cache name, URL) after each put
  };
  /** @type {Map<string, FakeCache>} */
  const caches = new Map();
  for (const [name, entries] of Object.entries(cachesHeld)) {
    const c = new FakeCache(name, server);
    for (const [k, v] of Object.entries(entries)) c.entries.set(k, v);
    caches.set(name, c);
  }
  const httpCache = new Map(Object.entries(http)); // bare URL -> body (what the page loaded)
  const listeners = {};
  const body = (b, path) => path === "./asset-manifest.json" ? JSON.stringify(b.manifest)
    : b.files[path === "./" ? "index.html" : path.slice(2)];
  const sandbox = {
    Request: class { constructor(url) { this.url = url; } },
    Response,
    crypto: globalThis.crypto,
    fetch: async (url, opts = {}) => {
      await null; // a round trip: other fetches interleave
      const path = bare(url);
      if (opts.cache === "only-if-cached") {
        if (opts.mode !== "same-origin") throw new TypeError("only-if-cached needs same-origin");
        if (!httpCache.has(path)) throw new TypeError("not in the HTTP cache");
        return new Response(httpCache.get(path));
      }
      server.net.push(String(url));
      const b = server.deployed;
      let res;
      if (path === "./asset-manifest.json" && server.manifest404) res = new Response("", { status: 404 });
      else {
        const t = body(b, path);
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
      keys: async () => [...caches.keys()],
      // A deleted cache's handle lives on, holding whatever is put into it,
      // but no name reaches it any more (as in a browser).
      delete: async (name) => caches.delete(name),
      match: async (req, { cacheName } = {}) => caches.get(cacheName)?.match(req),
    },
    addEventListener: (type, fn) => { listeners[type] = fn; },
    skipWaiting() {},
    clients: { claim() {} },
    Date, Math, Promise, Error, TypeError, Map, Object, Uint8Array, JSON, String,
  };
  sandbox.self = sandbox;
  vm.runInContext(stamped(worker.version), vm.createContext(sandbox), { filename: "web/sw.js" });

  const install = () => {
    let p;
    listeners.install({ waitUntil: (x) => { p = x; } });
    return p.then(() => "installed", (e) => "failed: " + e.message);
  };
  const reinstall = () => {
    let p;
    const replies = [];
    listeners.message({
      data: { type: "reinstall", nonce: 12345 },
      source: { postMessage: (m) => replies.push(m) },
      waitUntil: (x) => { p = x; },
    });
    return p.then(() => ({ ...replies[0] })); // out of the vm's realm, for deepEqual
  };
  // Which build each asset of a cache holds: the builds' own bytes.
  const contents = (name) => Object.fromEntries([...caches.get(name)?.entries || []]);
  const isBuild = (name, b) => {
    const c = contents(name);
    return ASSETS.every((u) => c[u] === body(b, u));
  };
  // The assets the worker fetched from the network, bare.
  const downloads = () => server.net.map(bare).filter((p) => p !== "./asset-manifest.json");
  return { server, caches, install, reinstall, contents, isBuild, downloads, name: "dingbat-" + worker.version };
};

const A = mkBuild("aaaaaaa");
const B = mkBuild("bbbbbbb", A, ["index.js"]);            // an index.js-only update
const C = mkBuild("ccccccc", B, ["index.js", "em.wasm"]);
const cacheOf = (b) => Object.fromEntries(ASSETS.map((u) => [u, b.files[fileFor(u)]]));
// What a first visit's page loaded itself (index.html's scripts and styles,
// em.js and em.wasm from index.js), by bare URL.
const PAGE_LOADS = ["./", "./index.js", "./glpresent.js", "./saveimport.js", "./nds/ndsutil.js",
  "./nds/ndsaudio.js", "./clipmux.js", "./zipwrite.js", "./framegrid.js", "./sdputil.js",
  "./netplay.js", "./styles.css", "./em.js", "./em.wasm", "./favicon.svg", "./logo.svg"];
const httpOf = (b, urls = PAGE_LOADS) => Object.fromEntries(urls.map((u) => [u, b.files[fileFor(u)]]));

test("a first install with nothing held downloads each asset once, index.html once for ./ too", async () => {
  const sw = setup({ worker: A });
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, A));
  const d = sw.downloads();
  assert.equal(d.length, ASSETS.length - 1, "one download per distinct file: " + d.join(" "));
  assert.equal(new Set(d).size, d.length, "nothing downloaded twice");
  assert.ok(sw.server.net.every((u) => /\?(v=aaaaaaa|probe=)/.test(u)), "every fetch past the edges");
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
  const short = { ...A, manifest: { version: A.version, files: { ...A.manifest.files } } };
  delete short.manifest.files["./em.wasm"];
  const sw = setup({ worker: A, deployed: short });
  assert.match(await sw.install(), /does not list/);
  assert.equal(sw.caches.has(sw.name), false);
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

test("a quiet Force update downloads every asset again and rewrites the live cache", async () => {
  const sw = setup({ worker: A, cachesHeld: { "dingbat-aaaaaaa": cacheOf(A) }, deployed: B });
  assert.deepEqual(await sw.reinstall(), { type: "reinstalled", ok: true });
  assert.ok(sw.isBuild(sw.name, B), "the deployed build, every asset");
  assert.equal(sw.downloads().length, ASSETS.length - 1, "no held copy reused");
  assert.ok(sw.server.net.every((u) => /\?(v=12345|probe=)/.test(u)));
  assert.deepEqual([...sw.caches.keys()], [sw.name], "no staging cache");
});

test("Force update that straddles a deploy leaves the live cache as it was", async () => {
  const sw = setup({ worker: A, cachesHeld: { "dingbat-aaaaaaa": cacheOf(A) }, deployed: B });
  sw.server.afterFetch = (n) => { if (n === 3) sw.server.deployed = C; };
  assert.deepEqual(await sw.reinstall(), { type: "reinstalled", ok: false },
                   "the page falls back to the full reset");
  assert.ok(sw.isBuild(sw.name, A), "no page may boot from a half-rewritten cache");
});

test("Force update with no manifest deployed answers ok:false", async () => {
  const sw = setup({ worker: A, cachesHeld: { "dingbat-aaaaaaa": cacheOf(A) } });
  sw.server.manifest404 = true;
  assert.deepEqual(await sw.reinstall(), { type: "reinstalled", ok: false });
  assert.ok(sw.isBuild(sw.name, A));
});

test("a development build installs without a manifest", async () => {
  const D = mkBuild("dev");
  const sw = setup({ worker: D });
  sw.server.manifest404 = true;
  assert.equal(await sw.install(), "installed");
  assert.ok(sw.isBuild(sw.name, D));
});

// --- the manifest itself (deploy-pages.yml) -----------------------------

const site = () => {
  const dir = mkdtempSync(join(tmpdir(), "dingbat-manifest-"));
  for (const u of ASSETS) {
    const f = join(dir, fileFor(u));
    mkdirSync(dirname(f), { recursive: true });
    writeFileSync(f, "bytes of " + fileFor(u));
  }
  writeFileSync(join(dir, "sw.js"), stamped("abc1234"));
  return dir;
};
const script = new URL("../../.github/scripts/asset-manifest.mjs", import.meta.url).pathname;

test("the manifest lists exactly sw.js's ASSETS, ./ as index.html, under its CACHE_VERSION", () => {
  const dir = site();
  try {
    execFileSync(process.execPath, [script, dir], { stdio: "pipe" });
    const m = JSON.parse(readFileSync(join(dir, "asset-manifest.json"), "utf8"));
    assert.equal(m.version, "abc1234");
    assert.deepEqual(Object.keys(m.files), ASSETS);
    assert.equal(m.files["./"], m.files["./index.html"]);
    assert.equal(m.files["./em.wasm"], sha256(readFileSync(join(dir, "em.wasm"))));
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

test("a missing precached file fails the manifest, so the deploy", () => {
  const dir = site();
  try {
    rmSync(join(dir, "flap-dusk.png"));
    assert.throws(() => execFileSync(process.execPath, [script, dir], { stdio: "pipe" }));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
