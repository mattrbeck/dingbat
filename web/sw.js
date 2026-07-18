// Replaced automatically with the git commit hash during CI build.
const CACHE_VERSION = "dev";
const CACHE_NAME = "dingbat-" + CACHE_VERSION;

const ASSETS = [
  "./",
  "./index.html",
  "./index.js",
  "./netplay.js",
  "./styles.css",
  "./em.js",
  "./em.wasm",
  "./manifest.json",
  "./apple-touch-icon-precomposed.png",
  "./version.txt",
];

// Fetch one asset and store it under its BARE url (so fetch-time cache
// matching keeps working). The fetch itself uses a version-busted URL with
// cache: "reload": the query string gives each deploy fresh CDN cache keys
// (Pages' CDN propagates per-object, so bare URLs can serve the previous
// build for a while after a deploy), and "reload" skips the browser HTTP
// cache (Pages serves multi-hour max-age on assets). A failed fetch rejects
// so install fails whole rather than caching a partial build.
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

self.addEventListener("install", (event) => {
  event.waitUntil(installAssets(CACHE_VERSION));
  // Stay in "waiting" until the page confirms via the skipWaiting message,
  // so an update never force-reloads a tab mid-game.
});

self.addEventListener("activate", (event) => {
  // Delete old caches from previous versions
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => key.startsWith("dingbat-") && key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      )
    )
  );
  // Take control of all open tabs immediately
  self.clients.claim();
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "skipWaiting") self.skipWaiting();
  // Force update: re-download every asset straight from origin (the nonce
  // gives cache keys no CDN edge or HTTP cache has seen) into the LIVE
  // cache, then ack so the page can reload into the fresh copy. Used when
  // the deployed sw.js is unreachable (stale edge) so a normal SW update
  // can't run.
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

self.addEventListener("fetch", (event) => {
  // Explicit network probes (the version.txt update check) must bypass the cache
  if (event.request.cache === "no-store") return;
  // Dev builds: CACHE_VERSION never changes, so cache-first would pin the
  // first-ever assets forever (rebuilt em.wasm meets a stale frontend and
  // renders wrong). Serve network-first instead, refreshing the cache as we
  // go; the cache remains only an offline fallback. CI stamps a real version,
  // so production keeps the cache-first behavior below.
  if (CACHE_VERSION === "dev") {
    event.respondWith(
      // no-cache: revalidate with the dev server even when the browser's
      // HTTP cache still considers its copy fresh (heuristic freshness has
      // no revalidation, which is how stale-frontend/fresh-wasm skew happens)
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
  // Match only THIS version's cache: caches.match() searches every cache,
  // so while a new version sits installed-but-waiting the old worker could
  // serve the new version's assets (or vice versa) — version skew.
  event.respondWith(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.match(event.request))
      .then((cached) => cached || fetch(event.request))
  );
});
