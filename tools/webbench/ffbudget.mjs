#!/usr/bin/env node
//
// ffbudget — is the fast-forward loop's fixed 16 ms per-tick budget the right
// number?
//
// web/index.js's fast-forward branch runs emulated frames until 16 ms of wall
// clock have passed, then presents once, then yields to requestAnimationFrame.
// On a 60 Hz display the RAF interval is 16.67 ms, so the tick has 0.67 ms of
// slack for the present, the RAF dispatch, and the overshoot of the last frame
// (the budget is checked AFTER each frame, so a tick always runs one frame too
// many, by up to a full frame time). When the total exceeds 16.67 ms the next
// animation frame lands a whole vsync later: 33.3 ms elapse having done only
// 16 ms of emulation, and throughput halves for that tick.
//
// That predicts something measurable: fast-forward fps should not be a smooth
// function of emulation speed, and a SMALLER budget — which wastes duty cycle
// but reliably fits inside one vsync — could beat the shipped 16 ms. It also
// predicts the effect is worse when frames are expensive (bigger overshoot).
//
// This measures achieved fps against budget, using the app's real loop_tick,
// present and audio calls in a real RAF loop, without modifying the app. It is
// a measurement tool, not a fix: it says what a budget change would buy before
// anyone edits the shipped loop.
//
// Usage:
//   node tools/webbench/ffbudget.mjs --builds 1890a53,2b323ff \
//     --roms Shantae,Emerald --budgets 4,8,10,12,14,16,18,24

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { extname, join, resolve, basename } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { PAGE_PREP } from "./pagelib.mjs";

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

const BUILD_ROOT = resolve(arg("root", "/Users/matt/code/dbwebperf"));
const BUILDS = String(arg("builds", "1890a53,2b323ff")).split(",").filter(Boolean);
const BUDGETS = String(arg("budgets", "4,8,12,14,16,18,24")).split(",").map(Number);
const SECONDS = Number(arg("seconds", 3));
const BOOT_FRAMES = Number(arg("boot", 900));

const ALL_ROMS = {
  Shantae: "/Users/matt/.claude/jobs/6997125c/tmp/gbsweep/roms/Shantae (USA).gbc",
  Crystal: "/Users/matt/.claude/jobs/6997125c/tmp/gbsweep/roms/Pokemon - Crystal Version (USA).gbc",
  AloneDark: "/Users/matt/.claude/jobs/6997125c/tmp/gbsweep/roms/Alone in the Dark - The New Nightmare (USA) (En,Fr,Es).gbc",
  Blue: "/Users/matt/.claude/jobs/6997125c/tmp/gbsweep/roms/Pokemon - Blue Version (UE) (S).gb",
  Emerald: "/Users/matt/Documents/emu/gba/PokemonEmerald.gba",
  GoldenSun: "/Users/matt/Documents/emu/gba/GoldenSun.gba",
  Kirby: "/Users/matt/Documents/emu/gba/KirbyNightmareInDreamland.gba",
};
const ROMS = String(arg("roms", "Shantae,Emerald")).split(",")
  .map((n) => [n, ALL_ROMS[n]]).filter(([n, p]) => p && existsSync(p));
if (!ROMS.length) { console.error("no ROMs selected"); process.exit(2); }

const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json",
};
const romMap = new Map(ROMS.map(([, p]) => [basename(p), p]));
const startServer = (webDir) => new Promise((res) => {
  const srv = createServer(async (req, rq) => {
    try {
      let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
      let file;
      if (p.startsWith("/roms/")) {
        file = romMap.get(basename(p));
        if (!file) { rq.writeHead(404); return rq.end(); }
      } else {
        if (p === "/") p = "/index.html";
        file = join(webDir, p);
        if (!file.startsWith(webDir)) { rq.writeHead(403); return rq.end(); }
      }
      const body = await readFile(file);
      rq.writeHead(200, {
        "Content-Type": MIME[extname(file).toLowerCase()] || "application/octet-stream",
        "Cache-Control": "no-store",
      });
      rq.end(body);
    } catch { rq.writeHead(404); rq.end(); }
  });
  srv.listen(0, "127.0.0.1", () => res({ srv, port: srv.address().port }));
});

// A faithful copy of index.js's fast-forward branch, with the budget as a
// parameter and a frame counter we can read. Same calls in the same order:
// loop_tick per frame, the audio branch per frame, one drawGame per tick.
// Deliberately does NOT touch the app's own loop (the app stays paused), so
// this measures the loop shape rather than fighting it.
const PAGE_FF_AT_BUDGET = ({ budget, seconds }) =>
  new Promise((resolve) => {
    window.__benchRestore();
    let frames = 0, ticks = 0, overruns = 0;
    const intervals = [];
    const t0 = performance.now();
    let lastTick = t0;
    const step = () => {
      const tickStart = performance.now();
      intervals.push(tickStart - lastTick);
      lastTick = tickStart;
      while (performance.now() - tickStart < budget) {
        Module._loop_tick();
        Module._clearAudioBuffer();
        frames++;
      }
      drawGame();
      ticks++;
      if (performance.now() - tickStart > 16.67) overruns++;
      if (performance.now() - t0 < seconds * 1000) requestAnimationFrame(step);
      else {
        const elapsed = (performance.now() - t0) / 1000;
        intervals.shift(); // the first interval is measured from setup, not a tick
        intervals.sort((a, b) => a - b);
        resolve({
          fps: frames / elapsed,
          framesPerTick: frames / ticks,
          tickHz: ticks / elapsed,
          medianInterval: intervals[Math.floor(intervals.length / 2)] || 0,
          overrunPct: (overruns / ticks) * 100,
        });
      }
    };
    requestAnimationFrame(step);
  });

const servers = new Map();
for (const b of BUILDS) {
  const webDir = join(BUILD_ROOT, b, "web");
  if (!existsSync(join(webDir, "em.wasm"))) { console.error(`no em.wasm for ${b}`); process.exit(2); }
  const { srv, port } = await startServer(webDir);
  servers.set(b, { srv, port });
}
const browser = await pw.chromium.launch({
  headless: true,
  args: ["--autoplay-policy=no-user-gesture-required", "--use-gl=angle"],
});

for (const [romName, romPath] of ROMS) {
  for (const build of BUILDS) {
    const ctx = await browser.newContext({ serviceWorkers: "block", viewport: { width: 900, height: 700 } });
    const page = await ctx.newPage();
    page.on("pageerror", () => {});
    try {
      await page.goto(`http://127.0.0.1:${servers.get(build).port}/index.html`, { waitUntil: "load" });
      await page.waitForFunction(
        () => typeof Module !== "undefined" && !!Module._loop_tick && typeof loadRom === "function",
        null, { timeout: 60000 }
      );
      await page.mouse.click(450, 350);
      await page.evaluate(PAGE_PREP, { romFile: basename(romPath), bootFrames: BOOT_FRAMES });
      // Park the app's own loop so only ours is stepping the core.
      await page.evaluate(() => { window.paused = true; });
      console.log(`\n${romName} / ${build}`);
      console.log(`  ${"budget".padStart(7)} ${"fps".padStart(7)} ${"frames/tick".padStart(11)} ${"tickHz".padStart(7)} ${"medIntvl".padStart(9)} ${"ticks>16.67ms".padStart(13)}`);
      for (const budget of BUDGETS) {
        const r = await page.evaluate(PAGE_FF_AT_BUDGET, { budget, seconds: SECONDS });
        console.log(
          `  ${String(budget).padStart(7)} ${r.fps.toFixed(0).padStart(7)} ` +
          `${r.framesPerTick.toFixed(1).padStart(11)} ${r.tickHz.toFixed(1).padStart(7)} ` +
          `${r.medianInterval.toFixed(2).padStart(9)} ${r.overrunPct.toFixed(0).padStart(12)}%`
        );
      }
    } catch (e) {
      console.error(`  ${build} ${romName} FAILED: ${e.message}`);
    } finally {
      await ctx.close();
    }
  }
}

await browser.close();
for (const { srv } of servers.values()) srv.close();
