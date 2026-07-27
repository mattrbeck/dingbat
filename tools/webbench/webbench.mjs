#!/usr/bin/env node
//
// webbench — A/B benchmark of the REAL deployed web front-end in a real
// browser, one build per HTTP origin.
//
// Why this exists: core optimisations that measure cleanly on native headless
// builds (tests/dingbat_bench.nim) were reported as invisible in the shipped
// web build, whose user-facing metric is the fps counter in uncapped
// fast-forward. Native numbers cannot answer that: the browser runs a
// different compiler (emcc -O3, and the wasm build is -d:danger while the
// native bench is -d:release), and the web frame loop wraps emulation in
// per-frame work that dingbat_bench never executes. This driver measures
// three things per (build, ROM) so those can be separated:
//
//   emu   — Module._benchFrames(N): emulation ONLY. No LUT convert, no rewind
//           snapshot, no audio, no present. The wasm analogue of the native
//           bench, and the number the core work should move.
//   tick  — Module._loop_tick() in a bare loop: emulation + prepare_game_frame
//           (BGR555 LUT convert) + the rewind ring's periodic state
//           serialize/XOR/deflate. This is what the app's frame loop calls.
//   ff    — the app's real uncapped fast-forward, driven by clicking the real
//           #fast-forward button and reading the app's own #fps counter. This
//           is exactly what the user measures.
//
// (emu vs tick) attributes any shortfall to loop_tick's non-emulation work;
// (tick vs ff) attributes the rest to the browser frame loop — RAF cadence,
// the 16 ms budget's quantisation, audio scheduling and presentation.
//
// Method notes, all of them load-bearing:
//   * One static server per build, so each build gets its own ORIGIN. That
//     makes the HTTP cache, IndexedDB and (blocked anyway) service worker
//     separate per build, with no cache-clearing step to forget.
//   * Service workers are BLOCKED in the browser context. A stale SW serving
//     a previous em.wasm would silently invalidate every number here.
//   * Builds are INTERLEAVED within each repetition and the order is rotated,
//     so thermal drift and E-core migration hit both arms equally.
//   * Every trial starts from a save state captured in-page after an
//     identical fixed-length boot, so all trials in all builds measure the
//     exact same emulated frames. States are captured per build (the state
//     format is not guaranteed stable across commits) but the boot is
//     deterministic, so they describe the same moment.
//   * Reported figure is BEST-of-N, not median: earlier perf work on this
//     machine saw median swing +/-3.8% while best-of-N held ~1.3%.
//   * Pass the same commit twice (--builds a,a) to measure the harness's own
//     noise floor.
//
// Usage:
//   node tools/webbench/webbench.mjs \
//     --root /path/to/builds \            # contains <commit>/web/em.wasm
//     --builds 1890a53,2b323ff \
//     --roms gb                     # or gba, all, or a comma list of names
//     --reps 3 [--headed] [--audio] [--json out.json]
//
// Playwright comes from web/node_modules of any dingbat checkout (npm ci in
// web/ then `npx playwright install chromium`).

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { extname, join, resolve, basename } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import {
  PAGE_PREP, PAGE_CORE_TRIALS, PAGE_FF, PAGE_RAF, PAGE_SHOT,
} from "./pagelib.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const REPO = resolve(HERE, "..", "..");

// --- Playwright resolution ---------------------------------------------------
// Playwright is a devDependency of web/package.json only, and a git worktree
// does not get the main checkout's node_modules — so try this checkout first,
// then walk out to the shared checkout that .claude/worktrees/* live under.
let pw;
const pwCandidates = [
  join(REPO, "web", "package.json"),
  join(REPO, "..", "..", "..", "web", "package.json"), // .claude/worktrees/<name>
];
try {
  pw = await import("playwright");
} catch {
  for (const c of pwCandidates) {
    if (pw || !existsSync(c)) continue;
    try { pw = createRequire(c)("playwright"); } catch {}
  }
}
if (!pw) {
  console.error(
    "Playwright not found. From a checkout's web/: `npm ci` then " +
      "`npx playwright install chromium`."
  );
  process.exit(2);
}

// --- args -------------------------------------------------------------------
const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf("--" + name);
  return i < 0 ? dflt : argv[i + 1];
};
const flag = (name) => argv.includes("--" + name);

const BUILD_ROOT = resolve(arg("root", "/Users/matt/code/dbwebperf"));
const BUILDS = String(arg("builds", "1890a53,2b323ff")).split(",").filter(Boolean);
const REPS = Number(arg("reps", 3));
const HEADED = flag("headed");
const AUDIO = flag("audio");
const JSON_OUT = arg("json", null);
const SHOTS = arg("shots", null);
// webkit is JavaScriptCore + Safari's wasm tiering (BBQ/OMG), which is the
// engine the iOS/macOS Safari users actually run. A win that shows in V8 and
// not in JSC would be an engine story, so make it one flag away.
const ENGINE = String(arg("browser", "chromium"));
if (!["chromium", "webkit", "firefox"].includes(ENGINE)) {
  console.error(`--browser must be chromium|webkit|firefox`); process.exit(2);
}
const chromium = pw[ENGINE];

// Frame counts. BOOT is long enough to get past the logo/intro into an attract
// or title scene with music running (these optimisations are in the APU/PPU/
// timer paths, so a silent black boot screen would understate them).
const BOOT_FRAMES = Number(arg("boot", 900));
const TRIAL_FRAMES = Number(arg("frames", 300));
const EMU_TRIALS = Number(arg("emutrials", 5));
const FF_SAMPLES = Number(arg("ffsamples", 6));

// --- ROM sets ---------------------------------------------------------------
const GB_DIR = arg("gbdir", "/Users/matt/.claude/jobs/6997125c/tmp/gbsweep/roms");
const GBA_DIR = arg("gbadir", "/Users/matt/Documents/emu/gba");

const GB_ROMS = [
  ["Shantae", join(GB_DIR, "Shantae (USA).gbc")],
  ["Crystal", join(GB_DIR, "Pokemon - Crystal Version (USA).gbc")],
  ["AloneDark", join(GB_DIR, "Alone in the Dark - The New Nightmare (USA) (En,Fr,Es).gbc")],
  ["Blue", join(GB_DIR, "Pokemon - Blue Version (UE) (S).gb")],
];
const GBA_ROMS = [
  ["Emerald", join(GBA_DIR, "PokemonEmerald.gba")],
  ["GoldenSun", join(GBA_DIR, "GoldenSun.gba")],
  ["Mother3", join(GBA_DIR, "Mother 3 (Eng. Translation 1.1).gba")],
  ["Kirby", join(GBA_DIR, "KirbyNightmareInDreamland.gba")],
];

const romSpec = String(arg("roms", "all"));
let ROMS;
if (romSpec === "gb") ROMS = GB_ROMS;
else if (romSpec === "gba") ROMS = GBA_ROMS;
else if (romSpec === "all") ROMS = [...GB_ROMS, ...GBA_ROMS];
else {
  const want = romSpec.split(",").map((s) => s.trim().toLowerCase());
  ROMS = [...GB_ROMS, ...GBA_ROMS].filter(([n]) => want.includes(n.toLowerCase()));
}
for (const [n, p] of ROMS) {
  if (!existsSync(p)) { console.error(`missing ROM for ${n}: ${p}`); process.exit(2); }
}
if (!ROMS.length) { console.error("no ROMs selected"); process.exit(2); }

// --- static server ----------------------------------------------------------
const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json",
};

// Serves a build's web/ directory, plus /roms/<name> from the absolute ROM
// paths above (so the page can fetch a ROM it was never shipped with).
const startServer = (webDir, romMap) =>
  new Promise((res) => {
    const srv = createServer(async (req, rq) => {
      try {
        const url = new URL(req.url, "http://x");
        let p = decodeURIComponent(url.pathname);
        let file;
        if (p.startsWith("/roms/")) {
          file = romMap.get(basename(p));
          if (!file) { rq.writeHead(404); return rq.end("no such rom"); }
        } else {
          if (p === "/") p = "/index.html";
          file = join(webDir, p);
          if (!file.startsWith(webDir)) { rq.writeHead(403); return rq.end(); }
        }
        const body = await readFile(file);
        rq.writeHead(200, {
          "Content-Type": MIME[extname(file).toLowerCase()] || "application/octet-stream",
          // No caching: a build swap must never be served from memory cache.
          "Cache-Control": "no-store",
        });
        rq.end(body);
      } catch {
        rq.writeHead(404); rq.end("not found");
      }
    });
    srv.listen(0, "127.0.0.1", () => res({ srv, port: srv.address().port }));
  });

// --- in-page helpers --------------------------------------------------------
// All of these live in pagelib.mjs, shared with swstale.mjs. They run inside
// the real app's global scope and call the app's own functions — nothing about
// booting a ROM, stepping frames or reading the fps counter is reimplemented.

// --- driver -----------------------------------------------------------------
const romMap = new Map(ROMS.map(([, p]) => [basename(p), p]));

const servers = new Map();
for (const b of BUILDS) {
  if (servers.has(b)) continue; // same commit twice (noise floor) shares a server
  const webDir = join(BUILD_ROOT, b, "web");
  if (!existsSync(join(webDir, "em.wasm"))) {
    console.error(`no em.wasm in ${webDir} — build it first`);
    process.exit(2);
  }
  const { srv, port } = await startServer(webDir, romMap);
  servers.set(b, { srv, port, webDir });
  console.log(`serve ${b} -> http://127.0.0.1:${port}  (em.wasm ${(await readFile(join(webDir, "em.wasm"))).length} bytes)`);
}

const browser = await chromium.launch({
  headless: !HEADED,
  // Chromium-only switches; webkit/firefox reject unknown args.
  ...(ENGINE === "chromium" ? {
    args: [
      // Let the AudioContext actually start without a gesture, so the FF loop
      // exercises the same pushAudio path a real user gets. Without this the
      // audio branch is skipped and FF looks artificially cheap.
      ...(AUDIO ? ["--autoplay-policy=no-user-gesture-required"] : []),
      "--use-gl=angle",
    ],
  } : {}),
});
console.log(`engine: ${ENGINE} ${browser.version()} headless=${!HEADED} audio=${AUDIO}`);

// results[build][rom] = { emu: [msPerFrame...], tick: [...], ff: [fps...] }
const results = {};
const note = (b, r) => ((results[b] ??= {})[r] ??= { emu: [], tick: [], ff: [], raf: [] });

const measure = async (build, romName, romPath) => {
  const { port } = servers.get(build);
  const ctx = await browser.newContext({
    serviceWorkers: "block",       // a stale SW would serve the wrong em.wasm
    viewport: { width: 900, height: 700 },
  });
  const page = await ctx.newPage();
  const errs = [];
  page.on("pageerror", (e) => errs.push(String(e)));
  try {
    await page.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil: "load" });
    await page.waitForFunction(
      () => typeof Module !== "undefined" && !!Module._benchFrames && !!Module._loop_tick,
      null, { timeout: 60000 }
    );
    // A real click satisfies any gesture gating before we start timing.
    await page.mouse.click(450, 350);
    await page.waitForFunction(() => typeof loadRom === "function", null, { timeout: 20000 });

    const prep = await page.evaluate(PAGE_PREP, {
      romFile: basename(romPath), bootFrames: BOOT_FRAMES,
    });
    if (SHOTS) {
      const { mkdir, writeFile } = await import("node:fs/promises");
      await mkdir(SHOTS, { recursive: true });
      const url = await page.evaluate(PAGE_SHOT);
      await writeFile(join(SHOTS, `${romName}-${build}.png`),
                      Buffer.from(url.split(",")[1], "base64"));
    }
    const raf = await page.evaluate(PAGE_RAF);
    const core = await page.evaluate(PAGE_CORE_TRIALS, {
      frames: TRIAL_FRAMES, trials: EMU_TRIALS,
    });
    const ff = await page.evaluate(PAGE_FF, { samples: FF_SAMPLES });

    const rec = note(build, romName);
    rec.emu.push(...core.emu);
    rec.tick.push(...core.tick);
    rec.ff.push(...ff.fps);
    rec.raf.push(raf);
    rec.stateBytes = prep.stateBytes;
    console.log(
      `  ${build} ${romName.padEnd(10)} emu ${Math.min(...core.emu).toFixed(3)}ms ` +
      `tick ${Math.min(...core.tick).toFixed(3)}ms ` +
      `ff ${ff.fps.length ? Math.max(...ff.fps) : "?"}fps ` +
      `raf ${raf.toFixed(1)}ms state ${(prep.stateBytes / 1024).toFixed(0)}KB` +
      (errs.length ? `  [pageerror: ${errs[0].slice(0, 80)}]` : "")
    );
  } catch (e) {
    console.error(`  ${build} ${romName} FAILED: ${e.message}`);
    if (errs.length) console.error(`    pageerror: ${errs[0].slice(0, 200)}`);
  } finally {
    await ctx.close();
  }
};

for (let rep = 0; rep < REPS; rep++) {
  // Rotate build order per repetition so drift cannot favour one arm.
  const order = BUILDS.map((_, i) => BUILDS[(i + rep) % BUILDS.length]);
  console.log(`\n--- rep ${rep + 1}/${REPS} (order: ${order.join(" ")}) ---`);
  for (const [romName, romPath] of ROMS) {
    for (const build of order) await measure(build, romName, romPath);
  }
}

await browser.close();
for (const { srv } of servers.values()) srv.close();

// --- report -----------------------------------------------------------------
const mn = (a) => (a.length ? Math.min(...a) : NaN);
const mx = (a) => (a.length ? Math.max(...a) : NaN);

console.log(`\n=== best-of-N (${REPS} reps x ${EMU_TRIALS} trials), lower ms / higher fps is better ===`);
const base = BUILDS[0];
const head = ["rom", "metric", ...BUILDS.map((b) => b.slice(0, 7)), "delta vs " + base.slice(0, 7)];
const rows = [head];
for (const [romName] of ROMS) {
  for (const metric of ["emu", "tick", "ff"]) {
    const vals = BUILDS.map((b) => {
      const r = results[b]?.[romName];
      if (!r) return NaN;
      return metric === "ff" ? mx(r.ff) : mn(r[metric]);
    });
    const b0 = vals[0];
    // ms: speedup = old/new. fps: speedup = new/old.
    const deltas = vals.map((v) =>
      !Number.isFinite(v) || !Number.isFinite(b0) ? "-"
        : (((metric === "ff" ? v / b0 : b0 / v) - 1) * 100).toFixed(1) + "%"
    );
    rows.push([
      romName, metric,
      ...vals.map((v) => (Number.isFinite(v) ? (metric === "ff" ? v.toFixed(0) : v.toFixed(3)) : "-")),
      deltas.slice(1).join("  "),
    ]);
  }
}
const w = head.map((_, i) => Math.max(...rows.map((r) => String(r[i] ?? "").length)));
for (const r of rows) console.log(r.map((c, i) => String(c ?? "").padEnd(w[i])).join("  "));

if (JSON_OUT) {
  const { writeFile } = await import("node:fs/promises");
  await writeFile(JSON_OUT, JSON.stringify({
    builds: BUILDS, reps: REPS, bootFrames: BOOT_FRAMES, trialFrames: TRIAL_FRAMES,
    headed: HEADED, audio: AUDIO, results,
  }, null, 2));
  console.log(`\nwrote ${JSON_OUT}`);
}
