// Replaced automatically with the git commit hash during CI build.
const CACHE_VERSION = "dev";
// This build's install cache. Force update commits into a cache of its own
// (dingbat-<version>-<nonce>) and moves the pointer (POINTER, below) to it.
const CACHE_NAME = "dingbat-" + CACHE_VERSION;

const ASSETS = [
  "./",
  "./index.html",
  "./index.js",
  "./glpresent.js",
  "./saveimport.js",
  "./nds/ndsutil.js",
  "./nds/ndsaudio.js",
  "./clipmux.js",
  "./zipwrite.js",
  "./framegrid.js",
  "./flap.png",
  "./flap-dusk.png",
  "./ckptworker.js",
  "./sdputil.js",
  "./netplay.js",
  "./styles.css",
  "./em.js",
  "./em.wasm",
  "./site.webmanifest",
  "./apple-touch-icon-precomposed.png",
  "./favicon.svg",
  "./logo.svg",
  "./favicon-96x96.png",
  "./google-signin-dark.svg",
  "./google-signin-light.svg",
  "./version.txt",
];

// The DS core: nds/nds.js and the nds.wasm it loads, fetched only when a DS
// game starts (index.js, loadNdsCore), and nds/gpu3d.js, when its 3D is first
// drawn on the graphics card. Not precached (a GB/GBA player never pays for
// them), but kept once fetched, so a DS game also plays offline after it has
// once played online, and checked like the rest (lazyFrom).
const LAZY = [
  "./nds/nds.js",
  "./nds/nds.wasm",
  "./nds/gpu3d.js",
];

// deploy-pages.yml writes asset-manifest.json once every file is final:
// {version, files: {"./index.js": "<sha256 hex>", ...}, lazy: {...}}, one
// digest for each entry of ASSETS under `files` and of LAZY under `lazy`
// (.github/scripts/asset-manifest.mjs; "./" is index.html). Workers from
// before LAZY read `files` alone and check it lists exactly their ASSETS, so
// the DS core has a list of its own. A copy is kept only when its bytes hash
// to the digest its own build's manifest gives, so it may come from anywhere:
// a deploy landing mid-install, or a CDN edge still on the previous object,
// shows up as a digest that does not match, never as two builds in one
// cache. Each cache keeps the manifest it was filled under, at MANIFEST: the
// DS core's lazy fetches are checked against it.
const MANIFEST = "./asset-manifest.json";

// Which cache serves this build. One entry per version in a cache of its own,
// naming the live cache: moving it is one put, which lands whole or not at
// all, so a Force update switches every fetch from one whole cache to
// another. No entry: the install's CACHE_NAME. Older workers delete it with
// every other dingbat-* cache when they activate, and never read it.
const POINTER = "dingbat-live";
const pointerKey = (v) => "./live/" + v;

const hex = (/** @type {ArrayBuffer} */ buf) =>
  [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const sha256 = async (/** @type {ArrayBuffer} */ buf) => hex(await crypto.subtle.digest("SHA-256", buf));
const digest = async (/** @type {Response} */ res) => sha256(await res.clone().arrayBuffer());

// The manifest the origin is serving now: a URL no edge has cached, past the
// HTTP cache. Refused unless it lists exactly ASSETS and LAZY and, given
// `want`, names that build.
const fetchManifest = async (want) => {
  const res = await fetch(MANIFEST + "?probe=" + Date.now() + "-" + Math.random(), { cache: "no-store" });
  if (!res.ok) throw new Error("manifest fetch failed: " + res.status);
  const m = await res.json();
  if (want !== undefined && m?.version !== want) {
    throw new Error("the server is on " + m?.version + ", not " + want);
  }
  const lists = (/** @type {*} */ o, /** @type {string[]} */ urls) =>
    Object.keys(o || {}).length === urls.length && urls.every((u) => typeof o[u] === "string");
  if (!lists(m?.files, ASSETS) || !lists(m?.lazy, LAZY)) {
    throw new Error("the manifest does not list this worker's assets");
  }
  return m;
};

// A download under a URL no copy of an older build sits behind (Pages' CDN
// propagates per object, so a bare URL can serve the previous build for a
// while), with cache: "reload" (skipping the browser HTTP cache; Pages serves
// a max-age).
const fetchFresh = (url, bust) =>
  fetch(url + (url.includes("?") ? "&" : "?") + "v=" + bust, { cache: "reload" });

// `res` when it is a whole response whose bytes hash to `want`, else null.
const verified = async (/** @type {Response | undefined | null} */ res, want) => {
  try {
    return res?.ok && (await digest(res)) === want ? res : null;
  } catch {
    return null;
  }
};

// Every dingbat-* cache holding assets: an older build's, this build's from
// an install that failed part-way, a Force update's.
const assetCaches = async () =>
  (await caches.keys()).filter((k) => k.startsWith("dingbat-") && k !== POINTER);

// A copy of an asset already on this device: in a dingbat-* cache (assetCaches),
// all keyed by bare URL whatever build wrote them; then in the HTTP cache,
// which holds what the page itself has just loaded (a first visit registers
// this worker only once the core is in: index.js, registerServiceWorker).
// only-if-cached never goes to the network: on a miss it fails, and the
// download in `collect` is the asset's one fetch. Vary is ignored: the digest
// is the check.
const heldCopy = async (urls, want, names) => {
  for (const name of names) {
    for (const u of urls) {
      const res = await verified(
        await caches.match(u, { cacheName: name, ignoreVary: true }).catch(() => undefined), want);
      if (res) return res;
    }
  }
  for (const u of urls) {
    const res = await verified(
      await fetch(u, { cache: "only-if-cached", mode: "same-origin" }).catch(() => null), want);
    if (res) return res;
  }
  return null;
};

// How far an install or a Force update has got, for the page's updating
// card (index.js, "Updating"): bytes in hand of the bytes to come, from the
// manifest's sizes. A held copy counts at once, a download as its bytes
// arrive. Posted to every open page at most every PROGRESS_MS, and once at
// the end; a manifest without sizes gives total 0 (the card shows motion,
// not a figure). Nothing here touches a cache.
const PROGRESS_MS = 150;
const tell = (/** @type {object} */ msg) => {
  const clients = /** @type {ServiceWorkerGlobalScope} */ (/** @type {*} */ (self)).clients;
  if (!clients) return;
  clients.matchAll({ type: "window", includeUncontrolled: true })
    .then((cs) => { for (const c of cs) c.postMessage(msg); })
    .catch(() => {});
};
const tracker = (/** @type {string} */ of, /** @type {number} */ total) => {
  let done = 0;
  let last = 0;
  const post = (end) => {
    const now = Date.now();
    if (!end && now - last < PROGRESS_MS) return;
    last = now;
    tell({ type: "progress", of, version: CACHE_VERSION, done: end ? total : Math.min(done, total), total });
  };
  return {
    add: (/** @type {number} */ n) => { done += n; post(false); },
    end: () => post(true),
  };
};
// The bytes one build's assets come to: one file per digest ("./" and
// "./index.html" are one), as `collect` fetches them.
const assetBytes = (m) => {
  const seen = new Map();
  for (const u of ASSETS) seen.set(m.files[u], m.sizes?.[u] || 0);
  return [...seen.values()].reduce((a, b) => a + b, 0);
};
// A download's bytes into `track` as they arrive, read off a clone (the
// response itself goes on to be checked and kept).
const countInto = (/** @type {Response} */ res, track) => {
  const reader = res.clone().body?.getReader();
  if (!reader) return;
  (async () => {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      track.add(value.byteLength);
    }
  })().catch(() => {});
};

// The manifest `m` itself, for the cache that will hold its build.
const manifestResponse = (m) =>
  new Response(JSON.stringify(m), { headers: { "Content-Type": "application/json" } });

// One build's assets as responses in hand, each checked against the manifest
// `m`. URLs with one digest ("./" and "./index.html") share one copy. With
// `reuse` (the install) a copy already held is taken before any download;
// otherwise, or when none is held, the asset is downloaded under `bust`. An
// asset no source has the right bytes for throws, failing the whole install
// or Force update. The install also takes each file of the DS core that is
// held with this build's digest (an older build's cache keeps the ones it
// fetched): never a download, since a player who never starts a DS game must
// not pay for one.
const collect = async (m, bust, reuse, track = null) => {
  const names = reuse ? await assetCaches() : [];
  /** @type {Map<string, string[]>} */
  const byDigest = new Map();
  for (const u of ASSETS) {
    const d = m.files[u];
    if (!byDigest.has(d)) byDigest.set(d, []);
    byDigest.get(d).push(u);
  }
  /** @type {Map<string, Response>} */
  const got = new Map();
  await Promise.all([...byDigest].map(async ([d, urls]) => {
    let res = reuse ? await heldCopy(urls, d, names) : null;
    if (res) track?.add(m.sizes?.[urls[0]] || 0);
    if (!res) {
      const net = await fetchFresh(urls[urls.length - 1], bust);
      if (!net.ok) throw new Error("asset fetch failed: " + urls[0] + " " + net.status);
      if (track) countInto(net, track);
      res = await verified(net, d);
      if (!res) throw new Error("not this build's bytes: " + urls[0]);
    }
    const copies = urls.map((_, i) => (i === urls.length - 1 ? res : res.clone()));
    urls.forEach((u, i) => got.set(u, copies[i]));
  }));
  if (reuse) {
    await Promise.all(LAZY.map(async (u) => {
      const res = await heldCopy([u], m.lazy[u], names);
      if (res) got.set(u, res);
    }));
  }
  return got;
};

// A copy as this worker keeps it: its bytes and type, saying no-cache. The
// copy came with Pages' ten-minute max-age, and a page's memory cache honours
// that for a response a worker served it: after a Force update (the same
// worker still in charge) Chromium's reload ran the index.js the page before
// it had run, though the worker was serving the new one. Told no-cache, the
// page asks again on every load, and the worker answers from this cache
// as before.
const asked = (/** @type {Response} */ res) => {
  const headers = new Headers(res.headers);
  headers.set("Cache-Control", "no-cache");
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
};

// The responses into the cache `name` (with the manifest they were checked
// against, when there is one), each kept as `asked` makes it, then a check
// that the cache under that name holds every asset: another worker's
// activation deletes every dingbat-*
// cache but its own, and one landing mid-put leaves the puts in a cache no
// name reaches any more. The DS core's files are optional: one missing is
// fetched (and checked) when a DS game starts. The cache starts empty: what a
// failed attempt left there is in `got` already if it hashed right, and
// nothing else may stay beside the manifest.
const commit = async (name, got, m) => {
  await caches.delete(name);
  const cache = await caches.open(name);
  const puts = [...got].map(([u, res]) => cache.put(new Request(u), asked(res)));
  if (m) puts.push(cache.put(new Request(MANIFEST), manifestResponse(m)));
  await Promise.all(puts);
  const check = await caches.open(name);
  const kept = await Promise.all([...ASSETS, ...(m ? [MANIFEST] : [])].map((u) => check.match(u)));
  if (!kept.every(Boolean)) throw new Error("the cache went away mid-install");
};

// The live cache's name, read once per worker start: a worker started cold
// (browsers stop idle ones) finds it in POINTER. setLive moves it: the put,
// then this worker's copy, in one segment once the put is done, so no fetch
// in between reads anything but a whole cache (the old one stays until
// dropLater).
/** @type {Promise<string> | null} */
let live = null;
const liveName = () => (live ??= caches.match(pointerKey(CACHE_VERSION), { cacheName: POINTER })
  .then((r) => (r ? r.text() : CACHE_NAME))
  .catch(() => { live = null; return CACHE_NAME; }));
const setLive = async (name) => {
  const p = await caches.open(POINTER);
  await p.put(new Request(pointerKey(CACHE_VERSION)), new Response(name));
  live = Promise.resolve(name);
};

// A development build has no manifest (CACHE_VERSION is never stamped, and
// the fetch handler goes to the network first): the assets as served.
const collectDev = async (bust) => {
  /** @type {Map<string, Response>} */
  const got = new Map();
  await Promise.all(ASSETS.map(async (u) => {
    const res = await fetchFresh(u, bust);
    if (!res.ok) throw new Error("asset fetch failed: " + u + " " + res.status);
    got.set(u, res);
  }));
  return got;
};

// This worker's build into its own cache: the manifest first (refused when
// the origin has moved on to another build, whose worker then installs
// instead), then each asset from the first copy whose bytes are this build's.
// Then the pointer: a pointer for this version left by an earlier life of it
// (a registration gone with its caches kept) would otherwise outlive it.
const install = async () => {
  if (CACHE_VERSION === "dev") {
    await commit(CACHE_NAME, await collectDev(CACHE_VERSION), null);
  } else {
    const m = await fetchManifest(CACHE_VERSION);
    const track = tracker("install", assetBytes(m));
    const got = await collect(m, CACHE_VERSION, true, track);
    track.end();
    await commit(CACHE_NAME, got, m);
  }
  await setLive(CACHE_NAME);
};

self.addEventListener("install", (/** @type {ExtendableEvent} */ event) => {
  // Nothing serves this version's cache until activation, and a failed
  // install's leftovers are overwritten by the retry (which may reuse the
  // ones that hash right) or deleted by the next activation.
  event.waitUntil(install());
  // Stays in "waiting" until the page sends skipWaiting, so an update never
  // force-reloads a tab mid-game.
});

// Deletes every dingbat-* cache `drop` picks.
const dropCaches = async (/** @type {(k: string) => boolean} */ drop) => {
  const keys = await caches.keys();
  await Promise.all(keys.filter(drop).map((k) => caches.delete(k)));
};

self.addEventListener("activate", (/** @type {ExtendableEvent} */ event) => {
  // Every cache but the live one and the pointer, and every other version's
  // pointer.
  event.waitUntil((async () => {
    const keep = await liveName();
    await dropCaches((k) => k.startsWith("dingbat-") && k !== keep && k !== POINTER);
    const p = await caches.open(POINTER);
    const mine = new URL(pointerKey(CACHE_VERSION), self.location.href).href;
    await Promise.all((await p.keys()).filter((r) => r.url !== mine).map((r) => p.delete(r)));
  })());
  /** @type {ServiceWorkerGlobalScope} */ (/** @type {*} */ (self)).clients.claim();
});

// Each page's boot from one cache: the one its navigation came from, by the
// page's client id, so a page loading while a Force update moves the pointer
// keeps booting from the cache its index.html came from. Kept until that
// cache is dropped (then the live one serves).
/** @type {Map<string, string>} */
const pins = new Map();
const GRACE_MS = 10000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The cache a Force update replaced, once every page booting from it has its
// assets: a fetch that read its name just before the move still finds it.
const dropLater = async (/** @type {string} */ prev) => {
  await sleep(GRACE_MS);
  for (const [k, v] of pins) if (v === prev) pins.delete(k);
  if (prev !== (await liveName())) await caches.delete(prev);
};

// Force update is the way out of an install gone wrong in a way this worker
// cannot see, most often a stale edge serving the previous sw.js so that no
// update can start. It downloads every asset again instead of reusing held
// copies: a copy that hashes right has the right bytes, but the person asked
// for a fresh download because something is off, and this way nothing held
// (a cached response's headers, a half-evicted cache) can carry it over; the
// files of the DS core the live cache holds come again too (a DS player keeps
// playing offline), a failed one left to its next lazy fetch. Each download
// is checked against the manifest the origin serves now, whatever build that
// is, so a deploy landing mid-download fails it (and the page takes its full
// reset). The download goes into a cache of its own, never the live one, and
// the pointer moves to it only once it holds everything: a page loading
// meanwhile, or this worker stopped at any point, sees the old cache whole or
// the new one whole. What an earlier Force update left part-way goes first.
const reinstall = async (nonce) => {
  const prev = await liveName();
  const m = CACHE_VERSION === "dev" ? null : await fetchManifest();
  // The DS core files the live cache holds come again too: they count.
  const lazyHeld = m ? (await Promise.all(LAZY.map(async (u) =>
    (await caches.match(u, { cacheName: prev }).catch(() => undefined)) ? u : null))).filter(Boolean) : [];
  const track = tracker("reinstall",
    m ? assetBytes(m) + lazyHeld.reduce((n, u) => n + (m.sizes?.[u] || 0), 0) : 0);
  const got = m ? await collect(m, nonce, false, track) : await collectDev(nonce);
  if (m) {
    await Promise.all(lazyHeld.map(async (u) => {
      const net = await fetchFresh(u, nonce).catch(() => null);
      if (net?.ok) countInto(net, track);
      const res = await verified(net, m.lazy[u]);
      if (res) got.set(u, res);
    }));
  }
  track.end();
  const name = CACHE_NAME + "-" + nonce + "-" + Math.random().toString(36).slice(2, 8);
  await dropCaches((k) => (k === CACHE_NAME || k.startsWith(CACHE_NAME + "-")) && k !== prev);
  await commit(name, got, m);
  await setLive(name);
  return prev;
};

// Two tabs' Force updates share one run.
/** @type {Promise<string> | null} */
let reinstalling = null;

self.addEventListener("message", (/** @type {ExtendableMessageEvent} */ event) => {
  if (event.data?.type === "skipWaiting") /** @type {ServiceWorkerGlobalScope} */ (/** @type {*} */ (self)).skipWaiting();
  // Force update: download every asset again under a nonce no edge or HTTP
  // cache has seen, check it against the deployed manifest, commit it to a
  // fresh cache and move the pointer there, then ack so the page can reload
  // (ok:false: the page's full reset). Pages from before the pointer send
  // the same message and read the same reply.
  if (event.data?.type === "reinstall") {
    const reply = (ok) => event.source?.postMessage({ type: "reinstalled", ok });
    const first = !reinstalling;
    const run = (reinstalling ??= reinstall(event.data.nonce || Date.now())
      .finally(() => { reinstalling = null; }));
    event.waitUntil(run.then(
      (prev) => { reply(true); return first ? dropLater(prev) : undefined; },
      () => reply(false)
    ));
  }
});

const SCOPE_PATH = new URL("./", self.location.href).pathname;
const LAZY_BY_PATH = new Map(LAZY.map((u) => [new URL(u, self.location.href).pathname, u]));
const TYPE_BY_EXT = { js: "text/javascript", wasm: "application/wasm" };

const cached = (key, name) =>
  caches.match(key, { cacheName: name }).catch(() => undefined);

// A file of the DS core for a page booted from the cache `name`: its copy,
// else a download checked against the manifest that cache holds (first the
// bare URL, as the HTTP cache or the edge has it, then once more past both),
// kept there. Bytes of any other build are never served or kept, so a stale
// edge cannot pair one build's nds.js with another's nds.wasm: the load fails
// and the next try downloads again. null when that cache holds no manifest
// (gone).
const lazyFrom = async (/** @type {FetchEvent} */ event, u, name) => {
  const hit = await cached(u, name);
  if (hit) return hit;
  const m = await cached(MANIFEST, name).then((r) => r?.json()).catch(() => null);
  const want = m?.lazy?.[u];
  if (typeof want !== "string") return null;
  const cache = await caches.open(name);
  const tries = [() => fetch(u), () => fetchFresh(u, Date.now() + "-" + Math.random())];
  for (const get of tries) {
    const res = await get().catch(() => null);
    if (!res?.ok) continue;
    const body = await res.arrayBuffer().catch(() => null);
    if (!body || (await sha256(body)) !== want) continue;
    // Its own response, not the download's: under the retry's URL a module
    // would resolve against ?v=.
    const type = res.headers.get("Content-Type") || TYPE_BY_EXT[u.split(".").pop()] || "";
    const out = new Response(body, { headers: { "Content-Type": type, "Cache-Control": "no-cache" } });
    event.waitUntil(cache.put(new Request(u), out.clone()).catch(() => {}));
    return out;
  }
  return Response.error();
};

self.addEventListener("fetch", (/** @type {FetchEvent} */ event) => {
  const req = event.request;
  // Explicit network probes (the version.txt update check) bypass the cache.
  if (req.cache === "no-store") return;
  const url = new URL(req.url);
  const same = url.origin === self.location.origin;
  // A load of the app, whatever its query (?2p, ?gpu3d=1, ...): the page
  // reads location.search itself, so every one is "./". As its own URL it
  // would miss the cache: offline nothing loads, and online index.html
  // would come from the network beside this cache's scripts and core.
  const shell = req.mode === "navigate" && same &&
    (url.pathname === SCOPE_PATH || url.pathname === SCOPE_PATH + "index.html");
  // Dev builds: CACHE_VERSION never changes, so cache-first would pin the
  // first-ever assets forever. Network-first, cache as offline fallback only.
  if (CACHE_VERSION === "dev") {
    event.respondWith(
      // no-cache: revalidate even when the browser's heuristic freshness
      // would keep a stale frontend next to a freshly rebuilt wasm.
      fetch(req, { cache: "no-cache" })
        .then((res) => {
          if (res.ok && req.method === "GET") {
            const copy = res.clone();
            liveName()
              .then((name) => caches.open(name))
              .then((cache) => cache.put(req, copy))
              .catch(() => {});
          }
          return res;
        })
        .catch(() =>
          liveName()
            .then((name) => cached(shell ? "./" : req, name))
            .then((hit) => hit || Response.error())
        )
    );
    return;
  }
  // Only the live cache serves: caches.match() across every cache would mix
  // an installed-but-waiting version's assets into ours.
  const lazy = same && !url.search && req.method === "GET" ? LAZY_BY_PATH.get(url.pathname) : undefined;
  event.respondWith((async () => {
    const now = await liveName();
    const name = shell ? now : pins.get(event.clientId) ?? now;
    if (shell && event.resultingClientId) {
      pins.set(event.resultingClientId, now);
      // The oldest page's pin goes first: it booted long ago.
      if (pins.size > 64) pins.delete(pins.keys().next().value);
    }
    if (lazy) {
      return (await lazyFrom(event, lazy, name)) ||
        (name !== now && (await lazyFrom(event, lazy, now))) || Response.error();
    }
    const key = shell ? "./" : req;
    const hit = (await cached(key, name)) || (name !== now ? await cached(key, now) : undefined);
    return hit || fetch(req);
  })());
});
