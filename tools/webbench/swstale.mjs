#!/usr/bin/env node
//
// swstale — reproduce "the deploy is current but the speedup is invisible".
//
// webbench.mjs proves the core wins are real and large in the browser. This
// script tests the other half: whether a client can be running the PREVIOUS
// em.wasm while every server-side check says the new build is live.
//
// Why that is possible by construction (web/sw.js + the top of web/index.js):
//   * In production CI stamps CACHE_VERSION, and the fetch handler is
//     CACHE-FIRST against only that version's cache. So a controlled tab is
//     served em.js/em.wasm/index.js out of the cache the OLD worker installed.
//   * A new worker installs but deliberately stays in `waiting` ("so an update
//     never force-reloads a tab mid-game"). Nothing swaps the assets until the
//     page posts skipWaiting — which only happens when the user clicks Update.
//   * index.js's update check reads version.txt with cache:"no-store", and
//     sw.js explicitly passes no-store requests straight to the network. So
//     "version.txt says 2b323ff" is a statement about the ORIGIN, not about
//     the bytes the tab is executing.
//   * That check is throttled to once per 24 h via localStorage
//     (UPDATE_CHECK_INTERVAL), so the button is not guaranteed to appear on
//     the first visit after a deploy either.
//
// The scenario, on ONE origin with a REAL (unblocked) service worker, with
// sw.js/version.txt stamped exactly the way .github/workflows/deploy-pages.yml
// stamps them:
//   1. serve OLD, load, reload so the worker controls the tab, measure FF fps
//   2. flip the server to NEW (the deploy), reload, measure FF fps again
//      -> if this still reads the OLD number while version.txt over the
//         network reads NEW, the reported symptom is reproduced
//   3. click the app's real Update button, wait for the reload, measure again
//      -> the new number should appear here
//
// Usage:
//   node tools/webbench/swstale.mjs --old 1890a53 --new 2b323ff --rom Shantae

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { extname, join, resolve, basename } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { PAGE_PREP, PAGE_FF, PAGE_WHICH_BUILD } from "./pagelib.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const REPO = resolve(HERE, "..", "..");

let pw;
try { pw = await import("playwright"); } catch {
  for (const c of [join(REPO, "web", "package.json"),
                   join(REPO, "..", "..", "..", "web", "package.json")]) {
    if (pw || !existsSync(c)) continue;
    try { pw = createRequire(c)("playwright"); } catch {}
  }
}
if (!pw) { console.error("Playwright not found (npm ci in web/)."); process.exit(2); }

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf("--" + n); return i < 0 ? d : argv[i + 1]; };
const flag = (n) => argv.includes("--" + n);

const BUILD_ROOT = resolve(arg("root", "/Users/matt/code/dbwebperf"));
const OLD = arg("old", "1890a53");
const NEW = arg("new", "2b323ff");
const HEADED = flag("headed");
const BOOT_FRAMES = Number(arg("boot", 900));
const FF_SAMPLES = Number(arg("ffsamples", 5));

const ROM_CANDIDATES = {
  Shantae: "/Users/matt/.claude/jobs/6997125c/tmp/gbsweep/roms/Shantae (USA).gbc",
  Crystal: "/Users/matt/.claude/jobs/6997125c/tmp/gbsweep/roms/Pokemon - Crystal Version (USA).gbc",
  Emerald: "/Users/matt/Documents/emu/gba/PokemonEmerald.gba",
};
const ROM_NAME = arg("rom", "Shantae");
const ROM_PATH = ROM_CANDIDATES[ROM_NAME];
if (!ROM_PATH || !existsSync(ROM_PATH)) {
  console.error(`unknown/missing --rom ${ROM_NAME}`); process.exit(2);
}

const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json", ".txt": "text/plain",
};

// The whole point: ONE origin whose content flips underneath the client, the
// way a Pages deploy does.
let live = OLD;

const srv = createServer(async (req, rq) => {
  try {
    let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (p.startsWith("/roms/")) {
      if (basename(p) !== basename(ROM_PATH)) { rq.writeHead(404); return rq.end(); }
      const body = await readFile(ROM_PATH);
      rq.writeHead(200, { "Content-Type": "application/octet-stream", "Cache-Control": "no-store" });
      return rq.end(body);
    }
    if (p === "/") p = "/index.html";
    const webDir = join(BUILD_ROOT, live, "web");
    // Emulate CI's stamping (.github/workflows/deploy-pages.yml): a real
    // CACHE_VERSION is what makes sw.js cache-first instead of the
    // network-first "dev" behaviour, so without this the bug cannot appear.
    if (p === "/sw.js") {
      let js = await readFile(join(webDir, "sw.js"), "utf8");
      js = js.replace('CACHE_VERSION = "dev"', `CACHE_VERSION = "${live}"`);
      rq.writeHead(200, { "Content-Type": "text/javascript", "Cache-Control": "no-cache" });
      return rq.end(js);
    }
    if (p === "/version.txt") {
      rq.writeHead(200, { "Content-Type": "text/plain", "Cache-Control": "no-cache" });
      return rq.end(live);
    }
    const file = join(webDir, p);
    if (!file.startsWith(webDir)) { rq.writeHead(403); return rq.end(); }
    const body = await readFile(file);
    rq.writeHead(200, {
      "Content-Type": MIME[extname(file).toLowerCase()] || "application/octet-stream",
      // Deliberately permissive, like GitHub Pages' max-age on assets; the SW
      // cache is the thing under test, not the HTTP cache.
      "Cache-Control": "max-age=600",
    });
    rq.end(body);
  } catch { rq.writeHead(404); rq.end("not found"); }
});
await new Promise((r) => srv.listen(0, "127.0.0.1", r));
const PORT = srv.address().port;
const URL_BASE = `http://127.0.0.1:${PORT}`;

for (const b of [OLD, NEW]) {
  const f = join(BUILD_ROOT, b, "web", "em.wasm");
  if (!existsSync(f)) { console.error(`no em.wasm for ${b}`); process.exit(2); }
  console.log(`${b}: em.wasm ${(await readFile(f)).length} bytes`);
}
console.log(`origin ${URL_BASE}, rom ${ROM_NAME}\n`);

const browser = await pw.chromium.launch({ headless: !HEADED, args: ["--use-gl=angle"] });
// Service workers are ALLOWED here (webbench.mjs blocks them); one context for
// the whole scenario so the registration and its caches survive the reloads.
const ctx = await browser.newContext({ viewport: { width: 900, height: 700 } });
const page = await ctx.newPage();
page.on("pageerror", () => {});

// sw.js calls clients.claim() on activate and index.js reloads on
// controllerchange, so the PAGE navigates itself at moments we do not control.
// Any evaluate racing that navigation dies with "execution context destroyed",
// and an explicit reload racing it dies with ERR_ABORTED. So poll instead of
// awaiting a specific navigation.
const pollPage = async (fn, timeoutMs = 30000, arg = undefined) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try { const v = await page.evaluate(fn, arg); if (v) return v; } catch {}
    await new Promise((r) => setTimeout(r, 400));
  }
  return null;
};
const reloadQuietly = async () => {
  try { await page.reload({ waitUntil: "load" }); }
  catch { await new Promise((r) => setTimeout(r, 1500)); } // the page beat us to it
};

const bootAndMeasure = async (label) => {
  const ready = await pollPage(
    () => typeof Module !== "undefined" && !!Module._benchFrames &&
          !!Module._loop_tick && typeof loadRom === "function", 60000
  );
  if (!ready) throw new Error("app never became ready");
  await page.mouse.click(450, 350);
  const which = await page.evaluate(PAGE_WHICH_BUILD);
  await page.evaluate(PAGE_PREP, { romFile: basename(ROM_PATH), bootFrames: BOOT_FRAMES });
  const ff = await page.evaluate(PAGE_FF, { samples: FF_SAMPLES });
  const fps = ff.fps.length ? Math.max(...ff.fps) : NaN;
  console.log(
    `${label}\n` +
    `  served to the tab : version=${which.servedVersion} em.wasm=${which.servedWasmBytes}B\n` +
    `  on the origin now : version=${which.networkVersion} em.wasm=${which.networkWasmBytes}B\n` +
    `  sw controls tab=${which.controlled} update-button=${which.updateButtonVisible} caches=[${which.cacheNames}]\n` +
    `  FAST-FORWARD      : ${fps} fps\n`
  );
  return { fps, which };
};

// --- 1. old build, worker in control ----------------------------------------
live = OLD;
await page.goto(`${URL_BASE}/index.html`, { waitUntil: "load" });
await pollPage(() => navigator.serviceWorker?.controller ? true : false, 40000);
const controlled = await pollPage(() => !!navigator.serviceWorker.controller, 20000);
if (!controlled) { console.error("service worker never took control"); process.exit(1); }
const before = await bootAndMeasure(`[1] running ${OLD}, service worker in control`);

// --- 2. the deploy happens; the user reloads --------------------------------
live = NEW;
console.log(`--- deploy: origin flipped to ${NEW} ---\n`);
await reloadQuietly();
// Give the browser time to fetch sw.js, install the new worker and let it
// settle into `waiting` (and to surface the update button if it will).
await new Promise((r) => setTimeout(r, 5000));
const after = await bootAndMeasure(`[2] origin is ${NEW}; tab reloaded (no Update click)`);

// --- 3. the user clicks Update ---------------------------------------------
console.log(`--- clicking the app's real Update button ---\n`);
try {
  await page.evaluate(() => { applyUpdate(); }); // reloads itself via controllerchange
} catch { /* the navigation it triggers can kill this very call */ }
// Wait until the tab is actually SERVED the new build (i.e. the new worker
// activated and swapped the cache), not merely until the reload happened.
const swapped = await pollPage(
  async (want) => {
    const v = (await (await fetch("version.txt")).text()).trim();
    return v === want ? v : false;
  }, 45000, NEW
);
console.log(`  tab is now served version: ${swapped || "(still " + OLD + ")"}\n`);
const updated = await bootAndMeasure(`[3] after clicking Update`);

await browser.close();
srv.close();

const pct = (a, b) => (Number.isFinite(a) && Number.isFinite(b) ? ((b / a - 1) * 100).toFixed(1) + "%" : "?");
console.log("=== summary (fast-forward fps) ===");
console.log(`  [1] running ${OLD}                : ${before.fps}`);
console.log(`  [2] origin ${NEW}, no Update click: ${after.fps}   (${pct(before.fps, after.fps)} vs [1])`);
console.log(`  [3] after Update                  : ${updated.fps}   (${pct(before.fps, updated.fps)} vs [1])`);
if (Number.isFinite(before.fps) && Number.isFinite(after.fps) &&
    Math.abs(after.fps / before.fps - 1) < 0.05) {
  console.log(
    "\nREPRODUCED: step [2] shows the origin serving the new build while the\n" +
    "tab still runs the old em.wasm at the old speed. Server-side checks\n" +
    "(version.txt, sw.js CACHE_VERSION, deploy logs) cannot detect this."
  );
}
