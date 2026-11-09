// Replaced automatically with the git commit hash during CI build.
const CACHE_VERSION = "dev";
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

// deploy-pages.yml writes asset-manifest.json once every file is final:
// {version, files: {"./index.js": "<sha256 hex>", ...}}, one digest for each
// entry of ASSETS (.github/scripts/asset-manifest.mjs; "./" is index.html).
// An install keeps a copy of an asset only when its bytes hash to the digest
// its own build's manifest gives, so the copy may come from anywhere: a
// deploy landing mid-install, or a CDN edge still on the previous object,
// shows up as a digest that does not match, never as two builds in one
// cache.
const MANIFEST = "./asset-manifest.json";

const hex = (/** @type {ArrayBuffer} */ buf) =>
  [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const digest = async (/** @type {Response} */ res) =>
  hex(await crypto.subtle.digest("SHA-256", await res.clone().arrayBuffer()));

// The manifest the origin is serving now: a URL no edge has cached, past the
// HTTP cache. Refused unless it lists exactly ASSETS and, given `want`, names
// that build.
const fetchManifest = async (want) => {
  const res = await fetch(MANIFEST + "?probe=" + Date.now() + "-" + Math.random(), { cache: "no-store" });
  if (!res.ok) throw new Error("manifest fetch failed: " + res.status);
  const m = await res.json();
  if (want !== undefined && m?.version !== want) {
    throw new Error("the server is on " + m?.version + ", not " + want);
  }
  const files = m?.files || {};
  if (Object.keys(files).length !== ASSETS.length || !ASSETS.every((u) => typeof files[u] === "string")) {
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

// A copy of an asset already on this device: in a dingbat-* cache (an older
// build's, this build's from an install that failed part-way, a Force
// update's), all keyed by bare URL whatever build wrote them; then in the
// HTTP cache, which holds what the page itself has just loaded (a first visit
// registers this worker only once the core is in: index.js,
// registerServiceWorker). only-if-cached never goes to the network: on a
// miss it fails, and the download in `collect` is the asset's one fetch.
const heldCopy = async (urls, want, names) => {
  for (const name of names) {
    for (const u of urls) {
      const res = await verified(await caches.match(u, { cacheName: name }).catch(() => undefined), want);
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

// One build's assets as responses in hand, each checked against the manifest
// `m`. URLs with one digest ("./" and "./index.html") share one copy. With
// `reuse` (the install) a copy already held is taken before any download;
// otherwise, or when none is held, the asset is downloaded under `bust`. An
// asset no source has the right bytes for throws, failing the whole install
// or Force update.
const collect = async (m, bust, reuse) => {
  const names = reuse ? (await caches.keys()).filter((k) => k.startsWith("dingbat-")) : [];
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
    if (!res) {
      const net = await fetchFresh(urls[urls.length - 1], bust);
      if (!net.ok) throw new Error("asset fetch failed: " + urls[0] + " " + net.status);
      res = await verified(net, d);
      if (!res) throw new Error("not this build's bytes: " + urls[0]);
    }
    const copies = urls.map((_, i) => (i === urls.length - 1 ? res : res.clone()));
    urls.forEach((u, i) => got.set(u, copies[i]));
  }));
  return got;
};

// The responses into the cache `name`, then a check that the cache under that
// name holds every one: another worker's activation deletes every dingbat-*
// cache but its own, and one landing mid-put leaves the puts in a cache no
// name reaches any more.
const commit = async (name, got) => {
  const cache = await caches.open(name);
  await Promise.all(ASSETS.map((u) => cache.put(new Request(u), got.get(u))));
  const check = await caches.open(name);
  const kept = await Promise.all(ASSETS.map((u) => check.match(u)));
  if (!kept.every(Boolean)) throw new Error("the cache went away mid-install");
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
const install = async () => {
  if (CACHE_VERSION === "dev") return commit(CACHE_NAME, await collectDev(CACHE_VERSION));
  const m = await fetchManifest(CACHE_VERSION);
  await commit(CACHE_NAME, await collect(m, CACHE_VERSION, true));
};

self.addEventListener("install", (/** @type {ExtendableEvent} */ event) => {
  // Nothing serves this version's cache until activation, and a failed
  // install's leftovers are overwritten by the retry (which may reuse the
  // ones that hash right) or deleted by the next activation.
  event.waitUntil(install());
  // Stays in "waiting" until the page sends skipWaiting, so an update never
  // force-reloads a tab mid-game.
});

self.addEventListener("activate", (/** @type {ExtendableEvent} */ event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => key.startsWith("dingbat-") && key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      )
    )
  );
  /** @type {ServiceWorkerGlobalScope} */ (/** @type {*} */ (self)).clients.claim();
});

// Force update is the way out of an install gone wrong in a way this worker
// cannot see, most often a stale edge serving the previous sw.js so that no
// update can start. It downloads every asset again instead of reusing held
// copies: a copy that hashes right has the right bytes, but the person asked
// for a fresh download because something is off, and this way nothing held
// (a cached response's headers, a half-evicted cache) can carry it over. Each
// download is checked against the manifest the origin serves now, whatever
// build that is, so a deploy landing mid-download fails it (and the page
// takes its full reset). Every response is in hand before the first put into
// the live cache, which pages keep booting from meanwhile; those puts are
// still one per asset, not atomic.
const reinstall = async (nonce) => {
  const got = CACHE_VERSION === "dev"
    ? await collectDev(nonce)
    : await collect(await fetchManifest(), nonce, false);
  const live = await caches.open(CACHE_NAME);
  await Promise.all(ASSETS.map((u) => live.put(new Request(u), got.get(u))));
};

self.addEventListener("message", (/** @type {ExtendableMessageEvent} */ event) => {
  if (event.data?.type === "skipWaiting") /** @type {ServiceWorkerGlobalScope} */ (/** @type {*} */ (self)).skipWaiting();
  // Force update: download every asset again under a nonce no edge or HTTP
  // cache has seen, check it against the deployed manifest, put it into the
  // live cache, then ack so the page can reload (ok:false: the page's full
  // reset). Pages from before the manifest send the same message and read
  // the same reply.
  if (event.data?.type === "reinstall") {
    const reply = (ok) => event.source?.postMessage({ type: "reinstalled", ok });
    event.waitUntil(
      reinstall(event.data.nonce || Date.now()).then(
        () => reply(true),
        () => reply(false)
      )
    );
  }
});

self.addEventListener("fetch", (/** @type {FetchEvent} */ event) => {
  // Explicit network probes (the version.txt update check) bypass the cache.
  if (event.request.cache === "no-store") return;
  // Dev builds: CACHE_VERSION never changes, so cache-first would pin the
  // first-ever assets forever. Network-first, cache as offline fallback only.
  if (CACHE_VERSION === "dev") {
    event.respondWith(
      // no-cache: revalidate even when the browser's heuristic freshness
      // would keep a stale frontend next to a freshly rebuilt wasm.
      fetch(event.request, { cache: "no-cache" })
        .then((res) => {
          if (res.ok && event.request.method === "GET") {
            const copy = res.clone();
            caches
              .open(CACHE_NAME)
              .then((cache) => cache.put(event.request, copy))
              .catch(() => {});
          }
          return res;
        })
        .catch(() =>
          caches
            .open(CACHE_NAME)
            .then((cache) => cache.match(event.request))
            .then((cached) => cached || Response.error())
        )
    );
    return;
  }
  // Match only this version's cache: caches.match() searches every cache,
  // and an installed-but-waiting version's assets would skew with ours.
  // The DS core (nds/nds.js + nds.wasm, fetched only when a DS game starts,
  // and nds/gpu3d.js, when its 3D is first drawn on the graphics card)
  // are not precached; the first fetch of each is kept in this version's cache, so a
  // DS game also plays offline after it has once played online.
  const lazy = /\/nds\/(nds\.(js|wasm)|gpu3d\.js)$/.test(new URL(event.request.url).pathname);
  event.respondWith(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.match(event.request).then((cached) => {
        if (cached || !lazy) return cached || fetch(event.request);
        return fetch(event.request).then((res) => {
          if (res.ok) cache.put(event.request, res.clone()).catch(() => {});
          return res;
        });
      }))
  );
});
