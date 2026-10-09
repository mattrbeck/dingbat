// What not drawing the frames nobody sees (docs/frame-skip.md) buys in a
// browser: the same game, scene and speed with it on and with `?draw=all`,
// alternated. Fast-forward reports game frames a second; 2x and run-ahead,
// whose frame rate is fixed, report the milliseconds of emulation each
// second of play costs. A diagnostic, not a test: nothing is asserted but
// that the page ran and logged no error.
//
//   node e2e/frame-skip-probe.mjs <game.gba> [warmup frames]   # from web/, em.wasm built
//
// ROUNDS=<n> (3), ENGINE=chromium|webkit (chromium), SECONDS=<s> (5).

import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { serveWeb, sleep, WEB } from "./devices.mjs";

const ROM = process.argv[2];
const WARMUP = Number(process.argv[3] || 1500);
const ROUNDS = Number(process.env.ROUNDS || 3);
const SECONDS = Number(process.env.SECONDS || 5);
const ENGINE = process.env.ENGINE || "chromium";
if (!ROM) { console.error("usage: node e2e/frame-skip-probe.mjs <game.gba> [warmup frames]"); process.exit(2); }

const require = createRequire(WEB + "/package.json");
const playwright = require("playwright");
const web = await serveWeb();
const rom = readFileSync(ROM);

// One page: the game loaded, run uncapped to the scene, then each mode.
const run = async (browser, drawAll) => {
  const ctx = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1100, height: 860 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(web.url + (drawAll ? "?draw=all" : ""));
  await page.waitForFunction(() => typeof db !== "undefined" && !!db);
  const [chooser] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
  ]);
  await chooser.setFiles({ name: basename(ROM), mimeType: "application/octet-stream", buffer: rom });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused,
    null, { timeout: 30000 });
  // Game frames run, and the milliseconds they took, counted here (the
  // page's own count is its fps readout's, reset every second)
  await page.evaluate(() => {
    window.__probe = { frames: 0, ms: 0 };
    for (const name of ["_loop_tick", "_runahead_tick"]) {
      const f = Module[name];
      Module[name] = (...a) => {
        const s = performance.now();
        try { return f(...a); } finally { __probe.frames++; __probe.ms += performance.now() - s; }
      };
    }
    if (!muted) toggleMute();   // nothing to hear
    setFastForward(true);
  });
  await page.waitForFunction((w) => __probe.frames >= w, WARMUP, { timeout: 120000, polling: 200 });
  const measure = (mode) => page.evaluate(async ([mode, seconds]) => {
    setFastForward(mode === "ff");
    setSpeed2x(mode === "2x");
    runaheadFrames = mode === "runahead" ? 2 : 0;
    await new Promise((r) => setTimeout(r, 1000));
    const f0 = __probe.frames, m0 = __probe.ms, t0 = performance.now();
    await new Promise((r) => setTimeout(r, seconds * 1000));
    const s = (performance.now() - t0) / 1000;
    return { fps: (__probe.frames - f0) / s, emuMsPerS: (__probe.ms - m0) / s };
  }, [mode, SECONDS]);
  const out = { ff: await measure("ff"), "2x": await measure("2x"), runahead: await measure("runahead") };
  await ctx.close();
  if (errors.length) throw new Error("page errors: " + errors.join("; "));
  return out;
};

const browser = await playwright[ENGINE].launch({ headless: true });
const results = { skip: [], all: [] };
try {
  for (let r = 0; r < ROUNDS; r++) {
    for (const drawAll of r % 2 ? [true, false] : [false, true]) {
      const o = await run(browser, drawAll);
      results[drawAll ? "all" : "skip"].push(o);
      console.log(`round ${r + 1} ${drawAll ? "draw=all" : "skip    "}: ` +
        `ff ${o.ff.fps.toFixed(0)} fps, 2x ${o["2x"].emuMsPerS.toFixed(0)} ms/s (${o["2x"].fps.toFixed(0)} fps), ` +
        `run-ahead 2 ${o.runahead.emuMsPerS.toFixed(0)} ms/s (${o.runahead.fps.toFixed(0)} fps)`);
    }
  }
} finally {
  await browser.close();
  web.close();
}
const best = (k, f, pick) => pick(...results[k].map(f));
const ffS = best("skip", (o) => o.ff.fps, Math.max), ffA = best("all", (o) => o.ff.fps, Math.max);
const x2S = best("skip", (o) => o["2x"].emuMsPerS, Math.min), x2A = best("all", (o) => o["2x"].emuMsPerS, Math.min);
const raS = best("skip", (o) => o.runahead.emuMsPerS, Math.min), raA = best("all", (o) => o.runahead.emuMsPerS, Math.min);
const pct = (a, b) => `${a / b - 1 >= 0 ? "+" : ""}${((a / b - 1) * 100).toFixed(0)}%`;
console.log(`\n${basename(ROM)} on ${ENGINE}, best of ${ROUNDS}:`);
console.log(`  fast-forward: ${ffS.toFixed(0)} fps vs ${ffA.toFixed(0)} (${pct(ffS, ffA)})`);
console.log(`  2x:           ${x2S.toFixed(0)} ms of emulation a second vs ${x2A.toFixed(0)} (${pct(x2S, x2A)})`);
console.log(`  run-ahead 2:  ${raS.toFixed(0)} ms a second vs ${raA.toFixed(0)} (${pct(raS, raA)})`);
