// Frame pacing (the evenness of the picture's cadence, not latency) in
// headless Chromium: per animation-frame callback of the game loop, how many
// game frames ran, whether a picture was presented and which, against the
// ideal for the speed and the display's rate. Compares this tree's build
// with frame skipping (docs/frame-skip.md), the same with `?draw=all`, and a
// second build (MAIN_WEB: main's web/ with its own em.wasm), one page each,
// the measurements interleaved.
//
// Three clocks:
// - real: the headless browser's own requestAnimationFrame.
// - fake: an init script replaces requestAnimationFrame with a timer-driven
//   display whose callbacks get vsync-grid timestamps (the latest grid point
//   at or before the callback, as a browser's frame time is), so a callback
//   that overruns its vsync costs one. Its own lateness is reported.
// - virt: the page's performance.now() is a virtual clock that a cost model
//   advances per game frame (drawn or undrawn), present and tick, and each
//   callback runs at the virtual vsync after the last one ended. The game
//   loop's real code decides everything; only time is modelled, so a loaded
//   machine does not move the result. COST scales the model (a slower device).
//
//   node e2e/pacing-probe.mjs <game> [warmup frames]   # from web/, em.wasm built
//
// MAIN_WEB=<dir>, SECONDS=<s> (12), SETTLE=<s> (1.5), SET=<name> (gba-virt),
// GB=1 (Game Boy cost model), OUT=<file.json> (raw records),
// ONLY=<substring of a config name>.

import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
import { basename, join, normalize, extname } from "node:path";
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";

const WEB = new URL("..", import.meta.url).pathname;
const require = createRequire(WEB + "/package.json");
const playwright = require("playwright");

const ROM = process.argv[2];
const WARMUP = Number(process.argv[3] || 1500);
const SECONDS = Number(process.env.SECONDS || 12);
const SETTLE = Number(process.env.SETTLE || 1.5);
const SET = process.env.SET || "virt";
const MAIN_WEB = process.env.MAIN_WEB;
if (!ROM) { console.error("usage: node e2e/pacing-probe.mjs <game> [warmup]"); process.exit(2); }

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".webmanifest": "application/manifest+json" };
const serve = (root) => new Promise((resolve) => {
  const server = createServer(async (req, res) => {
    let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (path.endsWith("/")) path += "index.html";
    const file = normalize(join(root, path));
    if (!file.startsWith(normalize(root))) { res.writeHead(403).end(); return; }
    try {
      if (!(await stat(file)).isFile()) throw 0;
      res.writeHead(200, { "Content-Type": TYPES[extname(file)] || "application/octet-stream",
                           "Cache-Control": "no-store" });
      let body = await readFile(file);
      // FFDBG=1: fast-forward's pacing state after each tick, read-only
      if (process.env.FFDBG && path === "/index.js") {
        body = String(body).replace("ffStatNote(timestamp, n, t - t0, late);",
          "ffStatNote(timestamp, n, t - t0, late); window.__ffLast = [ffAimed, deadline - timestamp, ffReserveMs, " +
          "ffOverMs, ffFrameMs, typeof ffSkipMs === 'undefined' ? -1 : ffSkipMs, " +
          "typeof ffDrawMs === 'undefined' ? -1 : ffDrawMs, ffFree ? 1 : 0, ffProbing ? 1 : 0, late ? 1 : 0, ffVsyncMs];");
      }
      res.end(body);
    } catch { res.writeHead(404).end(); }
  });
  server.listen(0, "127.0.0.1", () =>
    resolve({ url: `http://127.0.0.1:${server.address().port}/`, close: () => server.close() }));
});

// --- the page side: rAF replacement, clocks and the recorder ---------------
const INIT = () => {
  const nativeRAF = window.requestAnimationFrame.bind(window);
  const realNow = performance.now.bind(performance);
  let queue = [];
  let nextId = 1;
  let running = false;
  let pendingNative = false, pendingFake = false;
  const cfg = window.__raf = {
    mode: "real",       // "real" | "fake" | "virt" | "hold"
    hz: 60, jitter: 0, vrr: null, // vrr: "seg" (0.5 s 120 Hz / 0.5 s 60 Hz) | "alt"
    gen: 0,             // bumps on a change: the grid restarts
    rec: null,
    vnow: 0, offset: 0, cost: null,
  };
  // The page clock: real time plus an offset that only grows (leaving the
  // virtual clock never runs time backwards), or the virtual time
  const clock = () => cfg.mode === "virt" ? cfg.vnow : realNow() + cfg.offset;
  performance.now = clock;
  let rng = 1;
  const rand = () => { rng |= 0; rng = (rng + 0x6D2B79F5) | 0; let t = Math.imul(rng ^ (rng >>> 15), 1 | rng);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const gauss = () => Math.sqrt(-2 * Math.log(rand() + 1e-12)) * Math.cos(2 * Math.PI * rand());
  window.__spend = (ms) => {   // the cost model's time for one piece of work
    if (cfg.mode !== "virt" || !cfg.cost) return;
    cfg.vnow += Math.max(0.02, ms * cfg.cost.scale * (1 + cfg.cost.noise * gauss()));
  };
  const isTickMemo = new WeakMap();
  const isTick = (cb) => {
    let v = isTickMemo.get(cb);
    if (v === undefined) {
      const s = String(cb);
      v = s.includes("rollbackMode") && s.includes("fastForward") && s.includes("accumulator");
      isTickMemo.set(cb, v);
    }
    return v;
  };
  window.requestAnimationFrame = (cb) => {
    const id = nextId++;
    queue.push({ id, cb });
    if (!running) schedule();
    return id;
  };
  window.cancelAnimationFrame = (id) => { queue = queue.filter((e) => e.id !== id); };
  const run = (ts, late) => {
    const list = queue;
    queue = [];
    running = true;
    const P = window.__probe;
    for (const e of list) {
      if (!isTick(e.cb) || !P) { try { e.cb(ts); } catch (err) { console.error(err); } continue; }
      const f0 = P.frames, d0 = P.draws, u0 = P.unseen, s = clock();
      if (cfg.mode === "virt" && cfg.cost) {
        window.__spend(cfg.cost.tick);
        if (rand() < cfg.cost.spikeP) cfg.vnow += cfg.cost.spikeMs;
      }
      try { e.cb(ts); } catch (err) { console.error(err); }
      const r = cfg.rec;
      if (!r) continue;
      r.ts.push(ts); r.s.push(s); r.e.push(clock());
      r.f.push(P.frames - f0); r.d.push(P.draws - d0); r.h.push(P.hash);
      r.late.push(late); r.fi.push(P.frames); r.u.push(P.unseen - u0);
      r.dbg.push(window.__ffLast || null); window.__ffLast = null;
    }
    running = false;
    if (queue.length) schedule();
  };
  // The vsync grid (fake and virtual displays)
  let gv = 0, gk = 0, gGen = -1;
  const periodAt = (v, k) => {
    if (cfg.vrr === "seg") return ((v - cfg.t0) % 1000) < 500 ? 1000 / 120 : 1000 / 60;
    if (cfg.vrr === "alt") return k % 2 ? 1000 / 60 : 1000 / 120;
    return 1000 / cfg.hz;
  };
  const advanceTo = (now) => {  // grid cursor to the latest point <= now
    if (gGen !== cfg.gen) { gGen = cfg.gen; cfg.t0 = gv = now; gk = 0; }
    for (;;) { const p = periodAt(gv, gk); if (gv + p > now) break; gv += p; gk++; }
  };
  const ch = new MessageChannel();
  let target = 0;
  ch.port1.onmessage = () => {
    pendingFake = false;
    if (cfg.mode === "virt") {
      // Idle until the vsync after the last callback ended, then run
      advanceTo(clock());
      const ts = gv + periodAt(gv, gk);
      cfg.vnow = ts;
      advanceTo(ts);
      run(cfg.jitter ? ts + (rand() * 2 - 1) * cfg.jitter : ts, 0);
      return;
    }
    if (cfg.mode !== "fake") { if (queue.length && !running) schedule(); return; }
    const now = clock();
    advanceTo(now);
    if (gv < target - 0.001) {  // early (a timer can be): wait the rest
      pendingFake = true;
      setTimeout(() => ch.port2.postMessage(0), Math.max(0, target - now));
      return;
    }
    let ts = gv;
    if (cfg.jitter) ts += (Math.random() * 2 - 1) * cfg.jitter;
    run(ts, now - target);
  };
  const schedule = () => {
    if (cfg.mode === "hold") return;
    if (cfg.mode === "real") {
      if (pendingNative) return;
      pendingNative = true;
      nativeRAF((ts) => { pendingNative = false; if (cfg.mode === "real") run(ts + cfg.offset, 0); else if (queue.length) schedule(); });
      return;
    }
    if (pendingFake) return;
    pendingFake = true;
    if (cfg.mode === "virt") { ch.port2.postMessage(0); return; }
    const now = clock();
    advanceTo(now);
    target = gv + periodAt(gv, gk);
    // From a message handler: no nested-timer clamp
    setTimeout(() => ch.port2.postMessage(0), Math.max(0, target - now));
  };
  window.__rafSet = (o) => {
    const before = clock();
    Object.assign(cfg, o);
    if (cfg.mode === "virt") cfg.vnow = before;
    cfg.offset = Math.max(cfg.offset, before - realNow());
    if (o.seed) rng = o.seed;
    cfg.gen++;
    if (queue.length && !running) schedule();
  };
};

const INSTALL = () => {
  const P = window.__probe = { frames: 0, draws: 0, hash: 0, unseen: 0 };
  let marked = false;
  const un = Module._wasm_unseen_next;
  if (un) Module._wasm_unseen_next = (...a) => { const r = un(...a); marked = r === 1; return r; };
  const C = () => __raf.mode === "virt" ? __raf.cost : null;
  const lt = Module._loop_tick;
  Module._loop_tick = (...a) => {
    P.frames++; if (marked) P.unseen++;
    const skip = marked; marked = false;
    const r = lt(...a);
    const c = C(); if (c) __spend(skip ? c.skip : c.draw);
    return r;
  };
  const rt = Module._runahead_tick;
  Module._runahead_tick = (n) => {
    P.frames++; if (marked) P.unseen++;
    const skip = marked; marked = false;
    const r = rt(n);
    const c = C();
    if (c) {
      __spend(skip ? c.skip : c.draw);
      // Lookahead: a state save and load, n frames; on the skipping build
      // all but the last undrawn
      if (!skip && n > 0) {
        __spend(c.state * 2 + c.draw);
        for (let i = 1; i < n; i++) __spend(__lookSkip ? c.skip : c.draw);
      }
    }
    return r;
  };
  const draw = glRenderer.draw;
  glRenderer.draw = (...a) => {
    P.draws++;
    const c = C(); if (c) __spend(c.present);
    const ptr = Module._wasm_game_fb_ptr && Module._wasm_game_fb_ptr();
    if (ptr) {
      const [w, hh] = nativeRes();
      const v = new Uint16Array(Module.memory.buffer, ptr, Math.min(w * hh, 240 * 160));
      let h = 2166136261;
      for (let i = 0; i < v.length; i += 3) h = Math.imul(h ^ v[i], 16777619);
      P.hash = h >>> 0;
    }
    return draw(...a);
  };
  if (!muted) toggleMute();
};

// --- configurations ------------------------------------------------------
const MODES = {
  "1x": { ff: false, x2: false, slow: false, ra: 0 },
  "2x": { ff: false, x2: true, slow: false, ra: 0 },
  slow: { ff: false, x2: false, slow: true, ra: 0 },
  ff: { ff: true, x2: false, slow: false, ra: 0 },
  ra1: { ff: false, x2: false, slow: false, ra: 1 },
  ra2: { ff: false, x2: false, slow: false, ra: 2 },
};
const DISPLAYS = {
  real: { mode: "real" },
  "30": { hz: 30 }, "48": { hz: 48 }, "50": { hz: 50 }, "60": { hz: 60 }, "60j2": { hz: 60, jitter: 2 },
  "75": { hz: 75 }, "90": { hz: 90 }, "120": { hz: 120 }, "144": { hz: 144 },
  vrrseg: { vrr: "seg", hz: 80 }, vrralt: { vrr: "alt", hz: 80 },
};
// Cost model (ms of one at COST 1): a drawn and an undrawn game frame (GBA
// from the frontend measurements in docs/frame-skip.md: 2x 130 vs 107 ms of
// emulation a second; GB: undrawn -14% instructions), the present (upload +
// GL), the tick's own work, a run-ahead state save or load; per-piece noise
// and rare spikes (GC, compositor)
const COSTS = {
  gba: { draw: 1.1, skip: 0.7, present: 1.0, tick: 0.3, state: 0.15, noise: 0.1, spikeP: 0.005, spikeMs: 8 },
  gb: { draw: 0.6, skip: 0.52, present: 1.0, tick: 0.3, state: 0.08, noise: 0.1, spikeP: 0.005, spikeMs: 8 },
  // a slow phone (iPhone SE-class: ~5 ms a GBA frame, docs/frame-skip.md's
  // ratios), its GPU present cheap against the emulation
  phone: { draw: 5, skip: 3.3, present: 0.6, tick: 0.4, state: 0.6, noise: 0.1, spikeP: 0.005, spikeMs: 8 },
  gbphone: { draw: 2.7, skip: 2.3, present: 0.6, tick: 0.4, state: 0.3, noise: 0.1, spikeP: 0.005, spikeMs: 8 },
};
const BASE = process.env.GB ? "gb" : "gba";
const C = (d, m, clk, scale = 1, prof = BASE) => ({ d, m, clk, scale, prof });
const cross = (ds, ms, clk, scale = 1, prof = BASE) => ds.flatMap((d) => ms.map((m) => C(d, m, clk, scale, prof)));
const FAKE_D = ["30", "48", "50", "60", "60j2", "75", "90", "120", "144", "vrrseg", "vrralt"];
const SETS = {
  // the matrix on the virtual clock (load-proof)
  virt: [...cross(FAKE_D, ["1x", "2x", "ff", "ra2"], "virt"), ...cross(["30", "60", "120", "144"], ["slow", "ra1"], "virt")],
  // slower devices on the virtual clock
  "virt-load": [...cross(["60", "30", "120"], ["1x", "2x", "ra2", "ff"], "virt", 4),
    ...cross(["60", "30"], ["1x", "2x", "ra2", "ff"], "virt", 6),
    ...cross(["60", "30", "120", "50"], ["1x", "2x", "ra2", "ff"], "virt", 1, process.env.GB ? "gbphone" : "phone")],
  // wall clock (a loaded machine moves these)
  wall: [...cross(["real"], Object.keys(MODES), "wall"), ...cross(["30", "60", "60j2", "120", "144"], ["1x", "2x", "ff", "ra2"], "fake")],
  "wall-load": [...cross(["real", "60", "30"], ["1x", "2x"], "fake", 4), ...cross(["real", "60", "30"], ["1x", "2x"], "fake", 6),
    ...cross(["real", "60"], ["ra2", "ff"], "fake", 4), ...cross(["real", "60"], ["ra2", "ff"], "fake", 6)],
  wallq: [C("real", "1x", "wall"), C("real", "ff", "wall")],
  quick: [C("60", "1x", "virt"), C("60", "ff", "virt"), C("30", "1x", "virt"), C("60", "2x", "virt", 6)],
};
let configs = SETS[SET];
const nameOf = (c) => `${c.clk}/${c.d}/${c.m}${c.scale > 1 ? (c.clk === "virt" ? "/cost" : "/cpu") + c.scale + "x" : ""}${c.prof !== BASE ? "/" + c.prof : ""}`;
if (process.env.ONLY) configs = configs.filter((c) => nameOf(c).includes(process.env.ONLY));
if (process.env.DISP) { const ds = process.env.DISP.split(","); configs = configs.filter((c) => ds.includes(c.d)); }

// --- analysis -----------------------------------------------------------
const FRAME_TIME = 1000 / 59.7275;
const MARGIN = 0;  // ms the compositor needs after a callback ends (0: the next vsync)
const pct = (a, p) => { if (!a.length) return NaN; const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(p * s.length))]; };
const mean = (a) => a.reduce((x, y) => x + y, 0) / Math.max(1, a.length);
const sd = (a) => { const m = mean(a); return Math.sqrt(mean(a.map((x) => (x - m) ** 2))); };
const histo = (a) => { const h = {}; for (const x of a) h[x] = (h[x] || 0) + 1; return h; };
const analyse = (r, c) => {
  const D = DISPLAYS[c.d], M = MODES[c.m];
  const n = r.ts.length;
  const ivs = []; for (let i = 1; i < n; i++) ivs.push(r.ts[i] - r.ts[i - 1]);
  const P = c.d === "real" ? pct(ivs, 0.5) : D.vrr ? null : 1000 / D.hz;
  const step = M.x2 ? FRAME_TIME / 2 : M.slow ? FRAME_TIME * 2 : FRAME_TIME;
  const wall = (r.ts[n - 1] - r.ts[0]) / 1000;
  const frames = r.f.slice(1).reduce((a, b) => a + b, 0);
  const o = { n, wall: +wall.toFixed(2), fps: +(frames / wall).toFixed(1), hist: histo(r.f.slice(1)) };
  o.unseen = r.u.reduce((a, b) => a + b, 0);
  o.missed = P ? ivs.reduce((a, v) => a + Math.max(0, Math.round(v / P) - 1), 0) : NaN;
  o.work = +mean(r.e.map((e, i) => e - r.s[i])).toFixed(2);
  o.workP95 = +pct(r.e.map((e, i) => e - r.s[i]), 0.95).toFixed(2);
  o.late = c.clk === "fake" ? { mean: +mean(r.late).toFixed(2), p95: +pct(r.late, 0.95).toFixed(2), max: +Math.max(...r.late).toFixed(1) } : null;
  let stale = 0, presents = 0, lastH = null;
  for (let i = 0; i < n; i++) if (r.d[i] > 0) { presents++; if (r.f[i] > 0 && r.h[i] === lastH) stale++; lastH = r.h[i]; }
  o.presents = presents; o.stale = stale;
  // On screen: each refresh shows the newest picture whose callback ended
  // (plus MARGIN) by it. Fixed-rate displays only.
  if (P) {
    const t0 = r.ts[0];
    const slots = Math.floor((r.ts[n - 1] - t0) / P);
    const vis = new Array(slots + 1).fill(-1);
    let cur = r.fi[0], k = 1;
    for (let j = 0; j <= slots; j++) {
      const at = t0 + j * P + 1e-6;
      while (k < n && r.e[k] + MARGIN <= at) {
        if (r.d[k] > 0) cur = r.fi[k];
        k++;
      }
      vis[j] = cur;
    }
    const adv = []; for (let j = 1; j <= slots; j++) adv.push(vis[j] - vis[j - 1]);
    o.screen = { hist: histo(adv) };
    if (!M.ff) {
      const ideal = P / step;
      const lo = Math.floor(ideal + 1e-9), hi = Math.ceil(ideal - 1e-9);
      let oob = 0, rj = 0;
      for (let j = 0; j < adv.length; j++) {
        if (adv[j] < lo || adv[j] > hi) oob++;
        if (j && ((adv[j - 1] < lo && adv[j] > hi) || (adv[j - 1] > hi && adv[j] < lo))) rj++;
      }
      // the shown frame's distance from the game clock, per refresh
      const err = vis.map((v, j) => v - j * P / step);
      const em = mean(err);
      o.screen = { ...o.screen, ideal: +ideal.toFixed(4), oob, repeatJump: rj, oobPerMin: +(oob / (adv.length * P / 60000)).toFixed(1),
        errSd: +sd(err).toFixed(3), errP2P: +(Math.max(...err) - Math.min(...err)).toFixed(2) };
    } else {
      o.screen.sd = +sd(adv).toFixed(2);
    }
  }
  if (M.ff) {
    const f = r.f.slice(1);
    o.ff = { mean: +mean(f).toFixed(2), sd: +sd(f).toFixed(2), p5: pct(f, 0.05), p95: pct(f, 0.95), cv: +(sd(f) / mean(f)).toFixed(3) };
    if (P) {
      const per = [], vpt = [];
      for (let i = 1; i < n; i++) { const u = Math.max(1, Math.round((r.ts[i] - r.ts[i - 1]) / P)); per.push(r.f[i] / u); vpt.push(u); }
      o.ff.perVsync = { mean: +mean(per).toFixed(2), sd: +sd(per).toFixed(2), p5: +pct(per, 0.05).toFixed(1), p95: +pct(per, 0.95).toFixed(1) };
      o.ff.vsyncsPerTick = histo(vpt);
    }
    return o;
  }
  // Paced modes, per callback: a perfect sampler of the game clock runs
  // floor or ceil of interval/step frames; anything else breaks cadence
  let oob = 0, zero = 0, multi = 0;
  for (let i = 1; i < n; i++) {
    const want = (r.ts[i] - r.ts[i - 1]) / step, f = r.f[i];
    if (f < Math.floor(want + 1e-9) || f > Math.ceil(want - 1e-9)) oob++;
    if (f === 0) zero++;
    if (f >= 2) multi++;
  }
  o.paced = { zero, multi, oob };
  return o;
};

// --- run ----------------------------------------------------------------
const branch = await serve(WEB);
const main = MAIN_WEB ? await serve(MAIN_WEB) : null;
const variants = [
  ...(main ? [{ name: "main", url: main.url, lookSkip: false }] : []),
  { name: "skip", url: branch.url, lookSkip: true },
  { name: "all", url: branch.url + "?draw=all", lookSkip: false },
];
// CHANNEL=chromium: full Chromium's headless mode (the shell draws WebGL in
// software, which bounds the wall clock); ARGS: extra Chromium flags;
// VIEWPORT=WxH (1100x860).
const browser = await playwright.chromium.launch({ headless: true,
  args: ["--mute-audio", ...(process.env.ARGS ? process.env.ARGS.split(" ") : [])],
  ...(process.env.CHANNEL ? { channel: process.env.CHANNEL } : {}) });
const [VW, VH] = (process.env.VIEWPORT || "1100x860").split("x").map(Number);
const rom = readFileSync(ROM);
const load = async (v) => {
  const ctx = await browser.newContext({ serviceWorkers: "block", viewport: { width: VW, height: VH } });
  await ctx.addInitScript(INIT);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(v.url);
  await page.waitForFunction(() => typeof db !== "undefined" && !!db, null, { timeout: 180000 });
  const [chooser] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
  ]);
  await chooser.setFiles({ name: basename(ROM), mimeType: "application/octet-stream", buffer: rom });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused,
    null, { timeout: 120000 });
  await page.evaluate(INSTALL);
  // Warm up on the virtual clock: fast-forward's learnt reserve would
  // otherwise carry a loaded machine's late ticks into every measurement
  await page.evaluate(([s, cost]) => {
    window.__lookSkip = s;
    __rafSet({ mode: "virt", hz: 60, cost: { ...cost, scale: 1 }, seed: 7 });
    setFastForward(true);
  }, [v.lookSkip, COSTS[BASE]]);
  await page.waitForFunction((w) => __probe.frames >= w, WARMUP, { timeout: 900000, polling: 250 });
  await page.evaluate(() => { setFastForward(false); __rafSet({ mode: "hold" }); });
  const cdp = await ctx.newCDPSession(page);
  return { ...v, ctx, page, cdp, errors };
};
const pages = [];
for (const v of variants) pages.push(await load(v));
console.log(`${basename(ROM)}: ${configs.length} configs x ${pages.length} builds, ${SECONDS} s each; warm at ${WARMUP}`);

const measure = async (p, c, ci) => {
  const D = DISPLAYS[c.d], M = MODES[c.m];
  const virt = c.clk === "virt";
  if (!virt && c.scale > 1) await p.cdp.send("Emulation.setCPUThrottlingRate", { rate: c.scale });
  await p.page.evaluate(([D, M, virt, cost, seed]) => {
    setFastForward(false); setSpeed2x(false); setSlowMotion(false);
    // fast-forward after a moment at 1x on this display (its vsync mean is learnt at play)
    if (M.x2) setSpeed2x(true);
    if (M.slow) setSlowMotion(true);
    runaheadFrames = M.ra;
    __rafSet({ mode: D.mode === "real" ? "real" : virt ? "virt" : "fake", hz: D.hz || 60, jitter: D.jitter || 0,
      vrr: D.vrr || null, rec: null, cost, seed });
  }, [D, M, virt, virt ? { ...COSTS[c.prof], scale: c.scale } : null, 1000 + ci]);
  // Settle and measure: in virtual seconds on the virtual clock
  const waitFor = async (sec) => {
    if (!virt) { await new Promise((r) => setTimeout(r, sec * 1000)); return; }
    const v0 = await p.page.evaluate(() => performance.now());
    const t0 = Date.now();
    for (;;) {
      await new Promise((r) => setTimeout(r, 250));
      const v = await p.page.evaluate(() => performance.now());
      if (v - v0 >= sec * 1000 || Date.now() - t0 > 600000) return;
    }
  };
  if (M.ff) { await waitFor(1.5); await p.page.evaluate(() => setFastForward(true)); }
  await waitFor(SETTLE);
  await p.page.evaluate(() => { __raf.rec = { ts: [], s: [], e: [], f: [], d: [], h: [], late: [], fi: [], u: [], dbg: [] }; });
  await waitFor(SECONDS);
  const rec = await p.page.evaluate(() => { const r = __raf.rec; __raf.rec = null; __rafSet({ mode: "hold" }); return r; });
  if (!virt && c.scale > 1) await p.cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
  return rec;
};

const results = [];
const raw = [];
const t0 = Date.now();
const line = (o) => {
  const sc = o.screen ? (o.screen.ideal !== undefined
    ? ` | screen ${JSON.stringify(o.screen.hist)} oob ${o.screen.oob} (${o.screen.oobPerMin}/min) rj ${o.screen.repeatJump} errSd ${o.screen.errSd}`
    : ` | screen ${JSON.stringify(o.screen.hist)} sd ${o.screen.sd}`) : "";
  return o.ff ? `ff ${o.ff.mean}±${o.ff.sd} [${o.ff.p5},${o.ff.p95}] ${o.fps}fps vs/tick ${JSON.stringify(o.ff.vsyncsPerTick)} unseen ${o.unseen}${sc}`
    : `cb ${JSON.stringify(o.hist)} oob ${o.paced.oob} miss ${o.missed} stale ${o.stale} unseen ${o.unseen}${sc}`;
};
try {
  for (const [ci, c] of configs.entries()) {
    const order = pages.map((_, i) => pages[(i + ci) % pages.length]);
    const row = { cfg: nameOf(c) };
    for (const p of order) {
      const rec = await measure(p, c, ci);
      row[p.name] = analyse(rec, c);
      raw.push({ cfg: row.cfg, build: p.name, rec });
    }
    results.push(row);
    console.log(`[${((Date.now() - t0) / 60000).toFixed(1)}m] ${row.cfg}`);
    for (const p of pages) {
      const o = row[p.name];
      console.log(`   ${p.name.padEnd(5)} ${line(o)}${o.late ? ` late ${o.late.mean}/${o.late.p95}/${o.late.max}` : ""} work ${o.work}/${o.workP95}`);
    }
    if (process.env.OUT) writeFileSync(process.env.OUT, JSON.stringify({ rom: basename(ROM), results }));
  }
} finally {
  for (const p of pages) if (p.errors.length) console.log(`${p.name} page errors: ${p.errors.slice(0, 5).join("; ")}`);
  if (process.env.OUT) writeFileSync(process.env.OUT, JSON.stringify({ rom: basename(ROM), results, raw }));
  await browser.close();
  branch.close(); main?.close();
}
