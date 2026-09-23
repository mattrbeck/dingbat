// Replaced automatically with the git commit hash during CI build.
const CACHE_VERSION = "dev";
const CACHE_NAME = "dingbat-" + CACHE_VERSION;

const ASSETS = [
  "./",
  "./index.html",
  "./index.js",
  "./glpresent.js",
  "./saveimport.js",
  "./sdputil.js",
  "./netplay.js",
  "./styles.css",
  "./em.js",
  "./em.wasm",
  "./site.webmanifest",
  "./apple-touch-icon-precomposed.png",
  "./favicon.svg",
  "./favicon-96x96.png",
  "./version.txt",
];

// Fetch one asset and store it under its bare URL (fetch-time matching).
// The fetch uses a version-busted URL (fresh CDN cache keys; Pages' CDN
// propagates per-object, so bare URLs can serve the previous build for a
// while) with cache: "reload" (skips the browser HTTP cache; Pages serves
// multi-hour max-age). A failed fetch rejects so install fails whole rather
// than caching a partial build.
const fetchAndCache = (cache, url, bust) =>
  fetch(url + (url.includes("?") ? "&" : "?") + "v=" + bust, {
    cache: "reload",
  }).then((res) => {
    if (!res.ok) throw new Error("asset fetch failed: " + url + " " + res.status);
    return cache.put(new Request(url), res);
  });

// The build the origin is serving now: a URL no edge has cached, past the
// HTTP cache.
const probeVersion = () =>
  fetch("./version.txt?probe=" + Date.now() + "-" + Math.random(), { cache: "no-store" })
    .then((res) => {
      if (!res.ok) throw new Error("version probe failed: " + res.status);
      return res.text();
    })
    .then((t) => t.trim());

// Download one whole build into the cache `name`. Every asset is its own
// fetch, so a deploy landing between two of them would store two builds side
// by side, and the app would boot index.js against the other build's em.wasm
// until the next update. So the download is bracketed by probes: deploys only
// move forward, so the origin serving one build before the first fetch and
// after the last means every asset in between is that build (and an edge
// copy of a `?v=` URL was fetched while it was). `want` pins which build;
// anything else throws, failing the install or the reinstall whole.
const installAssets = async (name, bust, want) => {
  const before = await probeVersion();
  if (want !== undefined && before !== want) {
    throw new Error("the server is on " + before + ", not " + want);
  }
  const cache = await caches.open(name);
  await Promise.all(ASSETS.map((u) => fetchAndCache(cache, u, bust)));
  const got = (await (await cache.match("./version.txt"))?.text())?.trim();
  const after = await probeVersion();
  if (got !== before || after !== before) {
    throw new Error("a deploy landed mid-download: " + [before, got, after].join(" / "));
  }
};

self.addEventListener("install", (/** @type {ExtendableEvent} */ event) => {
  // Straight into this version's cache: nothing serves it until activation,
  // and a failed install's leftovers are overwritten by the retry or deleted
  // by the next activation.
  event.waitUntil(installAssets(CACHE_NAME, CACHE_VERSION, CACHE_VERSION));
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

// Force update's download goes to a staging cache (a "dingbat-" name, so the
// next activation sweeps one a crash left behind), not the live one, which
// pages keep booting from meanwhile: a failed or straddled download leaves
// the live cache as it was, and a good one lands in one burst of puts from
// responses already in hand rather than across the whole download. The
// burst is still one put per asset, not atomic.
const reinstall = async (nonce) => {
  const stagingName = "dingbat-reinstall-" + nonce;
  try {
    await installAssets(stagingName, nonce);
    const staging = await caches.open(stagingName);
    const live = await caches.open(CACHE_NAME);
    const got = await Promise.all(ASSETS.map((u) => staging.match(u)));
    await Promise.all(ASSETS.map((u, i) => live.put(new Request(u), got[i])));
  } finally {
    await caches.delete(stagingName);
  }
};

self.addEventListener("message", (/** @type {ExtendableMessageEvent} */ event) => {
  if (event.data?.type === "skipWaiting") /** @type {ServiceWorkerGlobalScope} */ (/** @type {*} */ (self)).skipWaiting();
  // Force update: re-download every asset under a nonce no edge or HTTP
  // cache has seen, into the live cache by way of reinstall's staging cache,
  // then ack so the page can reload (ok:false: the page's full reset). Used
  // when a stale edge keeps serving the old sw.js and a normal SW update
  // cannot run.
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
  event.respondWith(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.match(event.request))
      .then((cached) => cached || fetch(event.request))
  );
});
