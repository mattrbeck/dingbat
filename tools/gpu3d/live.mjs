// The GPU 3D prototype in the real web app (docs/nds/gpu3d.md): loads a DS
// game and a save state in headless Chromium (DS Beta on), then
//  - checks the live GPU path against the core's software HD: both turned
//    on at the same frame, each frame's HD screens compared dot for dot;
//  - times frames unpaced (ndsGpuBench): native, software HD and GPU HD;
//  - writes a screenshot of the canvas with the GPU path on.
//
//   node tools/gpu3d/live.mjs ROM STATE [--k 4] [--frames 60] [--out DIR] [--engine webkit]
//
// Needs both wasm builds in web/ (tools/serve_nds_dev.sh's commands) and
// Playwright (web/: npm ci).

import { readFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { createRequire } from "node:module";
import { serveWeb, WEB } from "../../web/e2e/devices.mjs";

const args = process.argv.slice(2);
const opt = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : dflt; };
const K = Number(opt("--k", "4"));
const FRAMES = Number(opt("--frames", "60"));
const OUT = resolve(opt("--out", "gpu3d-live"));
const ENGINE = opt("--engine", "chromium");
const [romPath, statePath] = args;
mkdirSync(OUT, { recursive: true });
let req = createRequire(join(WEB, "package.json"));
let playwright;
try { playwright = req("playwright"); } catch {
  playwright = createRequire(join(WEB, "..", "..", "..", "..", "web", "package.json"))("playwright");
}

const web = await serveWeb();
const browser = await playwright[ENGINE].launch({ headless: true, args: ENGINE !== "chromium" ? [] : [
  "--mute-audio", "--autoplay-policy=no-user-gesture-required",
  "--enable-gpu", "--use-angle=metal", "--ignore-gpu-blocklist"] });
const page = await browser.newPage({ viewport: { width: 1200, height: 1600 } });
await page.addInitScript(() => { localStorage.setItem("ds-beta", "1"); localStorage.setItem("nds-gpu3d", "1"); });
page.on("pageerror", (e) => console.log("  [page error]", e.message));
page.on("console", (m) => { if (m.type() === "error") console.log("  [console]", m.text()); });
await page.goto(web.url);
await page.waitForFunction(() => document.body.classList.contains("runtime-ready"), null, { timeout: 30000 });
const [chooser] = await Promise.all([
  page.waitForEvent("filechooser"),
  page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
]);
await chooser.setFiles(romPath);
await page.waitForFunction(() => document.body.classList.contains("running") && ndsCoreGame !== null,
  null, { timeout: 120000 });

// pause the app's own loop (the measurements run frames themselves)
const state = readFileSync(statePath).toString("base64");
const info = await page.evaluate(async ({ state }) => {
  paused = true;
  const bytes = Uint8Array.from(atob(state), (c) => c.charCodeAt(0));
  const c = ndsCore;
  const p = c._malloc(bytes.length);
  c.HEAPU8.set(bytes, p);
  const ok = c._nds_state_load(p, bytes.length);
  c._free(p);
  const gl = canvasEl.getContext("webgl2");
  const dbg = gl.getExtension("WEBGL_debug_renderer_info");
  return { ok, frame: c._nds_frame_count(),
           renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER) };
}, { state });
console.log(`state loaded: ${info.ok}, frame ${info.frame}; ${info.renderer}`);

// 1. the live GPU path against the core's software HD, frame by frame
const cmp = await page.evaluate(async ({ k, frames }) => {
  const c = ndsCore;
  ndsDisplay = { ...ndsDisplay, hd: k };
  ndsApplyHd();
  await new Promise((r) => { const t = () => (ndsGpuMod ? r() : setTimeout(t, 20)); t(); });
  // both at once, from this frame: the same capture history
  c._nds_set_hd(k);
  c._nds_set_gpu(1);
  const gl = canvasEl.getContext("webgl2");
  const W = 256 * k, H = 384 * k;
  const out = new Uint32Array(W * H * 4);
  const fb = gl.createFramebuffer();
  let same = 0, total = 0, worst = 1;
  for (let f = 0; f < frames; f++) {
    c._nds_run_frame();
    c._nds_audio_clear();
    const t = ndsGpuTexture(gl, k);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    gl.readPixels(0, 0, W, H, gl.RGBA_INTEGER, gl.UNSIGNED_INT, out);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    const buf = c.HEAPU8.buffer;
    const top = new Uint16Array(buf, c._nds_hd_fb555_top(), W * H / 2);
    const bot = new Uint16Array(buf, c._nds_hd_fb555_bottom(), W * H / 2);
    let s = 0;
    for (let i = 0; i < W * H / 2; i++) {
      if (out[i * 4] === top[i]) s++;
      if (out[(i + W * H / 2) * 4] === bot[i]) s++;
    }
    same += s; total += W * H; worst = Math.min(worst, s / (W * H));
  }
  gl.deleteFramebuffer(fb);
  c._nds_set_hd(1);   // back to the app's own choice (GPU)
  ndsApplyHd();
  return { same, total, worst, frames };
}, { k: K, frames: FRAMES });
console.log(`live check, ${cmp.frames} frames at ${K}x: ${(100 * cmp.same / cmp.total).toFixed(4)}% of dots ` +
            `equal to the core's software HD (worst frame ${(100 * cmp.worst).toFixed(4)}%)`);

// 1b. the app's GPU path at 1x with the skip against the native screens:
// the same frames from the state, run once each way. Also how many of the
// core's own screens lack the 3D (the skip at work), and the pictures
// taken from the GPU (ndsGpuRgba) against the GPU's screens.
const chk1 = await page.evaluate(async ({ state, frames }) => {
  const c = ndsCore, gl = canvasEl.getContext("webgl2");
  const W = 256, H = 192;
  const load = () => {
    const bytes = Uint8Array.from(atob(state), (ch) => ch.charCodeAt(0));
    const p = c._malloc(bytes.length);
    c.HEAPU8.set(bytes, p);
    c._nds_state_load(p, bytes.length);
    c._free(p);
  };
  const screens = () => {
    const both = new Uint16Array(W * H * 2);
    both.set(new Uint16Array(c.HEAPU8.buffer, c._nds_fb555_top(), W * H), 0);
    both.set(new Uint16Array(c.HEAPU8.buffer, c._nds_fb555_bottom(), W * H), W * H);
    return both;
  };
  paused = true;
  window.ndsGpu3d(false);
  ndsDisplay = { ...ndsDisplay, hd: 1 };
  ndsApplyHd();
  load();
  const ref = [];
  for (let f = 0; f < frames; f++) { c._nds_run_frame(); c._nds_audio_clear(); ref.push(screens()); }
  window.ndsGpuSkip(true);
  window.ndsGpu3d(true);
  ndsApplyHd();
  await new Promise((r) => { const t = () => (ndsGpuMod ? r() : setTimeout(t, 20)); t(); });
  load();
  let same = 0, total = 0, coreShort = 0, rgbaSame = 0;
  for (let f = 0; f < frames; f++) {
    c._nds_run_frame(); c._nds_audio_clear();
    ndsGpuTexture(gl, 1);
    const gpu = ndsGpuState.g.read(ndsGpuState.g.screens);
    ndsGpuState.g.restore();
    const core = screens();
    for (let i = 0; i < W * H * 2; i++) {
      if (gpu[i] === ref[f][i]) same++;
      if (core[i] !== ref[f][i]) coreShort++;
    }
    total += W * H * 2;
    if (f === frames - 1) {
      const rgba = ndsGpuRgba();
      let ok = 0;
      for (let i = 0; i < W * H * 2; i++) {
        const o = rgba[i < W * H ? 0 : 1], j = (i % (W * H)) * 4, v = gpu[i];
        const r = v & 31, g = (v >> 5) & 31, b = (v >> 10) & 31;
        if (o[j] === ((r << 3) | (r >> 2)) && o[j + 1] === ((g << 3) | (g >> 2)) && o[j + 2] === ((b << 3) | (b >> 2))) ok++;
      }
      rgbaSame = ok / (W * H * 2);
    }
  }
  paused = false;
  return { same, total, coreShort, rgbaSame, frames };
}, { state, frames: FRAMES });
console.log(`1x with the skip, ${chk1.frames} frames: GPU screens ${(100 * chk1.same / chk1.total).toFixed(4)}% ` +
            `equal to the native ones; the core's own screens differ in ${chk1.coreShort} dots (the 3D left to the GPU); ` +
            `GPU pictures (ndsGpuRgba) ${(100 * chk1.rgbaSame).toFixed(2)}% equal to the GPU's screens`);

// 2. unpaced frame costs: native, software HD, GPU HD
const bench = await page.evaluate(async ({ k, frames }) => {
  const c = ndsCore;
  const res = {};
  const run = (name) => {
    window.ndsGpuBench(10);
    res[name] = window.ndsGpuBench(frames);
  };
  window.ndsGpu3d(false);
  ndsDisplay = { ...ndsDisplay, hd: 1 }; ndsApplyHd(); run("native");
  ndsDisplay = { ...ndsDisplay, hd: k }; ndsApplyHd(); run(`software ${k}x`);
  window.ndsGpu3d(true); run(`GPU ${k}x`);
  return res;
}, { k: K, frames: Math.max(FRAMES, 120) });
for (const [name, r] of Object.entries(bench)) {
  console.log(`  ${name}: core ${r.core.toFixed(2)} ms, picture ${r.picture.toFixed(2)} ms, ` +
              `total ${(r.core + r.picture).toFixed(2)} ms a frame`);
}

// 3. the picture's parts, each waited for: the JS (scene, bins, uploads),
// the 3D, the composite and capture; and how often the slot images changed
const parts = await page.evaluate(async ({ k, frames }) => {
  const c = ndsCore, gl = canvasEl.getContext("webgl2");
  window.ndsGpu3d(true);
  ndsDisplay = { ...ndsDisplay, hd: k }; ndsApplyHd();
  const W = 256, H = 192;
  const px = new Uint32Array(4);
  const fb = gl.createFramebuffer();
  const sync = (t) => {
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    gl.readPixels(0, 0, 1, 1, gl.RGBA_INTEGER, gl.UNSIGNED_INT, px);
  };
  ndsGpuTexture(gl, k);
  const g = ndsGpuState.g;
  const sum = { js: 0, render: 0, composite: 0, texChanges: 0, uploadsMs: 0 };
  let lastVer = -1;
  for (let f = 0; f < frames; f++) {
    c._nds_run_frame(); c._nds_audio_clear();
    const buf = c.HEAPU8.buffer;
    const scene = new Uint32Array(buf, c._nds_gpu_scene(), c._nds_gpu_scene_len());
    if (scene[7] !== lastVer) { sum.texChanges++; lastVer = scene[7]; }
    let t0 = performance.now();
    g.setScene(scene, new Uint8Array(buf, c._nds_gpu_tex(), 0x80000), new Uint8Array(buf, c._nds_gpu_pal(), 0x18000));
    sync(g.out3d.t);
    sum.js += performance.now() - t0;
    t0 = performance.now();
    g.render(); sync(g.out3d.t);
    sum.render += performance.now() - t0;
    t0 = performance.now();
    g.composite([new Uint16Array(buf, c._nds_fb555_top(), W * H), new Uint16Array(buf, c._nds_fb555_bottom(), W * H)],
      new Uint32Array(buf, c._nds_gpu_plane(), W * H * 4), new Uint32Array(buf, c._nds_gpu_plane2(), W * H * 4),
      new Uint32Array(buf, c._nds_gpu_lines(), H * 8));
    sync(g.screens.t);
    sum.composite += performance.now() - t0;
  }
  // the last frame's 3D drawn 30 times back to back (a busy GPU)
  g.render(); sync(g.out3d.t);
  const t0 = performance.now();
  for (let i = 0; i < 30; i++) { g.render(); sync(g.out3d.t); }
  sum.renderHot = (performance.now() - t0) / 30;
  g.restore();
  gl.deleteFramebuffer(fb);
  for (const key of ["js", "render", "composite"]) sum[key] /= frames;
  return sum;
}, { k: K, frames: Math.max(FRAMES, 120) });
console.log(`  GPU ${K}x picture parts (each waited for): scene JS + uploads ${parts.js.toFixed(2)} ms, ` +
            `3D ${parts.render.toFixed(2)} ms, composite + capture ${parts.composite.toFixed(2)} ms; ` +
            `slot images changed in ${parts.texChanges} of ${Math.max(FRAMES, 120)} frames; 3D back to back ${parts.renderHot.toFixed(2)} ms`);

// The modes measured: "GPU" is the app's GPU path with the skip (the
// CPU's 3D left out of frames nothing on the machine reads), "GPU ... no
// skip" without it.
const modeSpec = (mode) => ({ gpu: mode.startsWith("GPU"), skip: !mode.includes("no skip"),
                              k: Number((mode.match(/(\d)x/) || [0, 1])[1]) });

// 4. paced play: the app's own loop from the state, emulated frames a
// second over 6 s, per mode (60 is full speed)
for (const mode of ["native", "GPU 1x", `software ${K}x`, `GPU ${K}x`]) {
  await page.evaluate(async ({ state, spec }) => {
    paused = true;
    window.ndsGpuSkip(spec.skip);
    window.ndsGpu3d(spec.gpu);
    ndsDisplay = { ...ndsDisplay, hd: spec.k };
    ndsApplyHd();
    const bytes = Uint8Array.from(atob(state), (ch) => ch.charCodeAt(0));
    const c = ndsCore, p = c._malloc(bytes.length);
    c.HEAPU8.set(bytes, p);
    c._nds_state_load(p, bytes.length);
    c._free(p);
    paused = false;
  }, { state, spec: modeSpec(mode) });
  await page.waitForTimeout(1000);
  const f0 = await page.evaluate(() => [ndsCore._nds_frame_count(), performance.now()]);
  await page.waitForTimeout(6000);
  const f1 = await page.evaluate(() => [ndsCore._nds_frame_count(), performance.now()]);
  console.log(`  paced, ${mode}: ${((f1[0] - f0[0]) * 1000 / (f1[1] - f0[1])).toFixed(1)} emulated frames a second`);
}

// 5. uncapped: from the state, frames run back to back with each one's
// picture drawn to the canvas (drawGame) as the app draws it, and only
// the last waited for, so the GPU's work overlaps the next frame's
// emulation as in fast-forward.
for (const mode of ["native", "GPU 1x no skip", "GPU 1x", "software 2x", "GPU 2x no skip", "GPU 2x",
                    `software ${K}x`, `GPU ${K}x no skip`, `GPU ${K}x`]) {
  const r = await page.evaluate(async ({ state, spec }) => {
    paused = true;
    window.ndsGpuSkip(spec.skip);
    window.ndsGpu3d(spec.gpu);
    ndsDisplay = { ...ndsDisplay, hd: spec.k };
    ndsApplyHd();
    await new Promise((r) => { const t = () => (!spec.gpu || ndsGpuMod ? r() : setTimeout(t, 20)); t(); });
    const c = ndsCore;
    const bytes = Uint8Array.from(atob(state), (ch) => ch.charCodeAt(0));
    const p = c._malloc(bytes.length);
    c.HEAPU8.set(bytes, p);
    c._nds_state_load(p, bytes.length);
    c._free(p);
    const gl = canvasEl.getContext("webgl2");
    const px = new Uint8Array(4);
    const frame = () => {
      c._nds_run_frame();
      c._nds_audio_clear();
      drawGame();
    };
    for (let i = 0; i < 30; i++) frame();
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
    const n = 300, t0 = performance.now();
    let coreMs = 0;
    for (let i = 0; i < n; i++) {
      const a = performance.now();
      c._nds_run_frame();
      c._nds_audio_clear();
      coreMs += performance.now() - a;
      drawGame();
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
    const ms = (performance.now() - t0) / n;
    return { fps: 1000 / ms, ms, core: coreMs / n };
  }, { state, spec: modeSpec(mode) });
  console.log(`  uncapped, ${mode}: ${r.fps.toFixed(1)} frames a second (${r.ms.toFixed(2)} ms a frame, ` +
              `of it the core ${r.core.toFixed(2)} ms)`);
}

// 6. a look at it: the GPU path on
await page.evaluate(() => { window.ndsGpuSkip(true); window.ndsGpu3d(true); });
await page.screenshot({ path: join(OUT, "live.png") });
console.log(`screenshot: ${join(OUT, "live.png")}`);
await browser.close();
web.close();
