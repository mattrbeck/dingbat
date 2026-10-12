// What not drawing the frames nobody sees (docs/frame-skip.md) buys in a
// browser: the same game, scene and speed with it on and with `?draw=all`,
// alternated. Fast-forward reports game frames a second; 1x, 2x and
// run-ahead, whose frame rate is fixed, report the milliseconds of
// emulation each second of play costs (a tenth of that is the share of a
// core). A diagnostic, not a test: nothing is asserted but that the page
// ran and logged no error.
//
//   node e2e/frame-skip-probe.mjs <game> [warmup frames]   # from web/, em.wasm built
//
// ROUNDS=<n> (3), ENGINE=chromium|webkit (chromium), SECONDS=<s> (5),
// GPU=1 (Chromium on the GPU: --use-angle=metal --enable-gpu; plain
// headless reaches only ~120 fps at fast-forward), STATE=<file.state> (a
// scene to load after boot; the warmup then runs from it), WALK=LEFT,RIGHT
// (input held in turn, 250 ms each) or HOLD=A (held throughout),
// MODES=ff,1x,2x,ra1,ra2 (all), OUT=<file.json> (every round's numbers).

import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import { serveWeb, WEB } from "./devices.mjs";

const ROM = process.argv[2];
const WARMUP = Number(process.argv[3] || (process.env.STATE ? 120 : 1500));
const ROUNDS = Number(process.env.ROUNDS || 3);
const SECONDS = Number(process.env.SECONDS || 5);
const ENGINE = process.env.ENGINE || "chromium";
const MODES = (process.env.MODES || "ff,1x,2x,ra1,ra2").split(",");
const KEYS = ["UP", "DOWN", "LEFT", "RIGHT", "A", "B", "SELECT", "START", "L", "R"];
const key = (k) => { const i = KEYS.indexOf(k.toUpperCase()); if (i < 0) throw new Error("no key " + k); return i; };
const WALK = process.env.WALK ? process.env.WALK.split(",").map(key) : [];
const HOLD = process.env.HOLD ? process.env.HOLD.split(",").map(key) : [];
if (!ROM) { console.error("usage: node e2e/frame-skip-probe.mjs <game> [warmup frames]"); process.exit(2); }

const require = createRequire(WEB + "/package.json");
const playwright = require("playwright");
const web = await serveWeb();
const rom = readFileSync(ROM);
const state = process.env.STATE ? [...readFileSync(process.env.STATE)] : null;

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
  await page.evaluate(([state, walk, hold]) => {
    if (state) {
      const p = Module._malloc(state.length);
      Module.HEAPU8.set(state, p);
      const ok = Module._wasm_load_state(p, state.length, 0);
      Module._free(p);
      if (ok !== 1) throw new Error("state refused");
    }
    window.__probe = { frames: 0, ms: 0 };
    for (const name of ["_loop_tick", "_runahead_tick"]) {
      const f = Module[name];
      Module[name] = (...a) => {
        const s = performance.now();
        try { return f(...a); } finally { __probe.frames++; __probe.ms += performance.now() - s; }
      };
    }
    for (const k of hold) Module._setInput(k, 1);
    if (walk.length) {
      let i = 0;
      Module._setInput(walk[0], 1);
      setInterval(() => {
        Module._setInput(walk[i % walk.length], 0);
        i++;
        Module._setInput(walk[i % walk.length], 1);
      }, 250);
    }
    if (!muted) toggleMute();   // nothing to hear
    setFastForward(true);
  }, [state, WALK, HOLD]);
  await page.waitForFunction((w) => __probe.frames >= w, WARMUP, { timeout: 120000, polling: 200 });
  const measure = (mode) => page.evaluate(async ([mode, seconds]) => {
    setFastForward(mode === "ff");
    setSpeed2x(mode === "2x");
    runaheadFrames = mode === "ra1" ? 1 : mode === "ra2" ? 2 : 0;
    await new Promise((r) => setTimeout(r, 1000));
    const f0 = __probe.frames, m0 = __probe.ms, t0 = performance.now();
    await new Promise((r) => setTimeout(r, seconds * 1000));
    const s = (performance.now() - t0) / 1000;
    return { fps: (__probe.frames - f0) / s, emuMsPerS: (__probe.ms - m0) / s };
  }, [mode, SECONDS]);
  const out = {};
  for (const m of MODES) out[m] = await measure(m);
  await ctx.close();
  if (errors.length) throw new Error("page errors: " + errors.join("; "));
  return out;
};

const args = process.env.GPU === "1" && ENGINE === "chromium" ? ["--use-angle=metal", "--enable-gpu"] : [];
const browser = await playwright[ENGINE].launch({ headless: true, args });
const results = { skip: [], all: [] };
const show = (o) => MODES.map((m) => m === "ff" ? `ff ${o.ff.fps.toFixed(0)} fps`
  : `${m} ${o[m].emuMsPerS.toFixed(0)} ms/s (${o[m].fps.toFixed(0)} fps)`).join(", ");
try {
  for (let r = 0; r < ROUNDS; r++) {
    for (const drawAll of r % 2 ? [true, false] : [false, true]) {
      const o = await run(browser, drawAll);
      results[drawAll ? "all" : "skip"].push(o);
      console.log(`round ${r + 1} ${drawAll ? "draw=all" : "skip    "}: ${show(o)}`);
    }
  }
} finally {
  await browser.close();
  web.close();
}
if (process.env.OUT) writeFileSync(process.env.OUT, JSON.stringify(results, null, 1));
const best = (k, f, pick) => pick(...results[k].map(f));
const pct = (a, b) => `${a / b - 1 >= 0 ? "+" : ""}${((a / b - 1) * 100).toFixed(0)}%`;
console.log(`\n${basename(ROM)} on ${ENGINE}${args.length ? " (GPU)" : ""}, best of ${ROUNDS}:`);
for (const m of MODES) {
  if (m === "ff") {
    const s = best("skip", (o) => o.ff.fps, Math.max), a = best("all", (o) => o.ff.fps, Math.max);
    console.log(`  fast-forward: ${s.toFixed(0)} fps vs ${a.toFixed(0)} (${pct(s, a)})`);
  } else {
    const s = best("skip", (o) => o[m].emuMsPerS, Math.min), a = best("all", (o) => o[m].emuMsPerS, Math.min);
    console.log(`  ${m.padEnd(12)}  ${s.toFixed(0)} ms of emulation a second vs ${a.toFixed(0)} (${pct(s, a)})`);
  }
}
