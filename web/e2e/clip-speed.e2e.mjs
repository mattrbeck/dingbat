// A clip records at 1x whatever speed the player last used. 2x and slow
// motion reshape the core's sample stream (half / twice the samples a
// frame) and are not part of a state, so a replay that inherited them came
// out with half or double the sound for its pictures: a 60 s clip with 30 s
// of audio (2026-10-08). Each frame of the replay must carry a 1x frame's
// samples, a speed set during the replay must wait for its end, and the
// player's speed must be on the live core afterwards, however it ended.
//
//   node --test e2e/clip-speed.e2e.mjs     # from web/, after the wasm build

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, WEB } from "./devices.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;
// WebKit where the rest of the job runs it (CI's software WebGL, devices.mjs).
const ENGINE = process.env.DINGBAT_E2E_NO_CHROMIUM ? "webkit" : "chromium";
const ROM = { name: "gbaedge.gba", bytes: readFileSync(join(WEB, "../tests/roms/gbaedge.gba")) };
// 280896 cycles a frame at 16 MiHz, 32768 samples a second.
const PER_FRAME = (280896 / 16777216) * 32768;

let web = null, browser = null;
after(async () => {
  await browser?.close();
  web?.close();
});

const boot = async () => {
  web ??= await serveWeb();
  browser ??= await playwright[ENGINE].launch({ headless: true });
  const ctx = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1100, height: 860 } });
  const page = await ctx.newPage();
  await page.goto(web.url);
  await page.waitForFunction(() => typeof db !== "undefined" && !!db);
  await page.evaluate(() => dbPut(THUMBS_OFFER_KEY, Date.now()));
  const [chooser] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
  ]);
  await chooser.setFiles({ name: ROM.name, mimeType: "application/octet-stream", buffer: ROM.bytes });
  await page.waitForFunction(() => document.body.classList.contains("running") &&
    !document.body.classList.contains("home-flying") && !paused, null, { timeout: 30000 });
  return { ctx, page };
};

// Paused at `speed` with history, then a replay of the last 180 frames:
// samples a frame live before, in the replay, and live after. `during`, if
// given, is the speed the player picks halfway through; `abort` ends the
// replay there with clip_abort instead of running it out.
const replay = (page, speed, { during = null, abort = false } = {}) =>
  page.evaluate(([speed, during, abort]) => {
    togglePause();
    applySpeed(speed);
    // History at this speed, stepped by hand: no wait on the display.
    for (let i = 0; i < 240; i++) { Module._loop_tick(); Module._clearAudioBuffer(); }
    const mean = (step, n) => {
      let sum = 0;
      for (let i = 0; i < n; i++) {
        Module._clearAudioBuffer();
        if (step() < 0) return -1;
        sum += Module._getAudioBufferLen() / 2;
      }
      Module._clearAudioBuffer();
      return sum / n;
    };
    const before = mean(() => Module._loop_tick(), 30);
    const frames = Module._clip_begin(180, 0);
    const half = Math.floor(frames / 2);
    let clip = mean(() => Module._clip_tick(), half);
    if (during) applySpeed(during);
    let done;
    if (abort) {
      Module._clip_abort();
      done = Module._clip_tick();
    } else {
      clip = (clip * half + mean(() => Module._clip_tick(), frames - half) * (frames - half)) / frames;
      done = Module._clip_tick();
    }
    const afterwards = mean(() => Module._loop_tick(), 30);
    return { frames, before, clip, done, afterwards };
  }, [speed, during, abort]);

const near = (got, want, what) =>
  assert.ok(Math.abs(got - want) < 3, `${what}: ${got} samples a frame, want ${want}`);

const RATE = { normal: 1, "2x": 0.5, slow: 2 };
const CASES = [
  ["2x", {}],
  ["slow", {}],
  ["2x", { abort: true }],
  ["normal", { during: "2x" }],
  ["slow", { during: "normal" }],
];

for (const [speed, opts] of CASES) {
  const name = `a clip made at ${speed}` +
    (opts.during ? `, ${opts.during} picked during it` : "") +
    (opts.abort ? `, cancelled` : "") + ", is 1x and leaves the player's speed";
  test(name, { skip, timeout: 120000 }, async () => {
    const { ctx, page } = await boot();
    try {
      const r = await replay(page, speed, opts);
      const live = RATE[opts.during || speed];
      assert.ok(r.frames >= 120, `the replay has frames (${r.frames})`);
      assert.equal(r.done, -1, "the replay is over");
      near(r.before, PER_FRAME * RATE[speed], `live at ${speed}`);
      near(r.clip, PER_FRAME, "the replay");
      near(r.afterwards, PER_FRAME * live, `live at ${opts.during || speed} after`);
    } finally {
      await ctx.close();
    }
  });
}
