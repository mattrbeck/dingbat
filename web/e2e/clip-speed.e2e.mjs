// A clip records at 1x whatever speed the player last used. 2x and slow
// motion reshape the core's sample stream (half / twice the samples a
// frame) and are not part of a state, so a replay that inherited them came
// out with half or double the sound for its pictures: a 60 s clip with 30 s
// of audio (2026-10-08). Each frame of the replay must carry a 1x frame's
// samples, and the player's speed must be back on the live core afterwards.
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
  browser ??= await playwright.chromium.launch({ headless: true, args: ["--mute-audio"] });
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

for (const [speed, live] of [["2x", 0.5], ["slow", 2]]) {
  test(`a clip made at ${speed} has a 1x frame's sound per frame`, { skip, timeout: 120000 }, async () => {
    const { ctx, page } = await boot();
    try {
      const r = await page.evaluate((speed) => {
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
        const clip = mean(() => Module._clip_tick(), frames);
        const done = Module._clip_tick();
        const afterwards = mean(() => Module._loop_tick(), 30);
        return { frames, before, clip, done, afterwards };
      }, speed);
      assert.ok(r.frames >= 120, `the replay has frames (${r.frames})`);
      assert.equal(r.done, -1, "the replay ran out");
      assert.ok(Math.abs(r.before - PER_FRAME * live) < 3, `live at ${speed}: ${r.before}`);
      assert.ok(Math.abs(r.clip - PER_FRAME) < 3, `replay: ${r.clip} samples a frame, want ${PER_FRAME}`);
      assert.ok(Math.abs(r.afterwards - PER_FRAME * live) < 3, `${speed} back after: ${r.afterwards}`);
    } finally {
      await ctx.close();
    }
  });
}
