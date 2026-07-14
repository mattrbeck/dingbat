// Replaced automatically with the git commit hash during CI build.
const CACHE_VERSION = "dev-iosupload";
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

self.addEventListener("install", (event) => {
  // cache: "no-cache" revalidates every asset with the server. Without it,
  // addAll fills the new version's cache from the browser HTTP cache (Pages
  // serves max-age=600), so an update within 10 minutes of a deploy could
  // mix old and new assets — the classic black-screen-after-update.
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      cache.addAll(ASSETS.map((u) => new Request(u, { cache: "no-cache" })))
    )
  );
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
});

self.addEventListener("fetch", (event) => {
  // Explicit network probes (the version.txt update check) must bypass the cache
  if (event.request.cache === "no-store") return;
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
