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

const installAssets = (bust) =>
  caches
    .open(CACHE_NAME)
    .then((cache) => Promise.all(ASSETS.map((u) => fetchAndCache(cache, u, bust))));

self.addEventListener("install", (/** @type {ExtendableEvent} */ event) => {
  event.waitUntil(installAssets(CACHE_VERSION));
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

self.addEventListener("message", (/** @type {ExtendableMessageEvent} */ event) => {
  if (event.data?.type === "skipWaiting") /** @type {ServiceWorkerGlobalScope} */ (/** @type {*} */ (self)).skipWaiting();
  // Force update: re-download every asset into the live cache under a nonce
  // no edge or HTTP cache has seen, then ack so the page can reload. Used
  // when a stale edge keeps serving the old sw.js and a normal SW update
  // cannot run.
  if (event.data?.type === "reinstall") {
    const reply = (ok) => event.source?.postMessage({ type: "reinstalled", ok });
    event.waitUntil(
      installAssets(event.data.nonce || Date.now()).then(
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
