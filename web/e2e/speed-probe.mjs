// How fast each browser runs the game on this machine: animation frames
// ticked and game frames run in three seconds, per engine, window size and
// Chromium flags. A diagnostic, printed before the e2e run in CI (a machine
// with no GPU draws WebGL in software, and the window's size is its cost).
//
//   node e2e/speed-probe.mjs        # from web/, with em.wasm built

import { createRequire } from "node:module";
import { serveWeb, addGame, sleep, WEB } from "./devices.mjs";

const require = createRequire(WEB + "/package.json");
const playwright = require("playwright");
const web = await serveWeb();
const CONFIGS = [
  ["chromium", { width: 1100, height: 860 }, []],
  ["chromium", { width: 640, height: 480 }, []],
  ["chromium", { width: 1100, height: 860 }, ["--disable-gpu-vsync", "--disable-frame-rate-limit"]],
  ["chromium", { width: 1100, height: 860 }, [], "chromium"],   // the full browser's headless mode
  ["webkit", { width: 1100, height: 860 }, []],
];
for (const [engine, viewport, args, channel] of CONFIGS) {
  const browser = await playwright[engine].launch({ headless: true, args, ...(channel ? { channel } : {}) });
  try {
    const ctx = await browser.newContext({ serviceWorkers: "block", viewport });
    const page = await ctx.newPage();
    await page.goto(web.url);
    await page.waitForFunction(() => typeof db !== "undefined" && !!db);
    await addGame({ page, who: engine });
    await sleep(1000);
    const r = await page.evaluate(() => new Promise((resolve) => {
      let ticks = 0, frames = 0, emuMs = 0, drawMs = 0;
      const t0 = performance.now();
      const tick = Module._loop_tick;
      Module._loop_tick = (...a) => {
        frames++; const s = performance.now();
        try { return tick(...a); } finally { emuMs += performance.now() - s; }
      };
      const draw = glRenderer.draw;
      glRenderer.draw = (...a) => {
        const s = performance.now();
        try { return draw(...a); } finally { drawMs += performance.now() - s; }
      };
      const f = () => {
        ticks++;
        if (performance.now() - t0 < 3000) requestAnimationFrame(f);
        else {
          Module._loop_tick = tick; glRenderer.draw = draw;
          resolve({ ticks, frames, emu: (emuMs / frames).toFixed(1), draw: (drawMs / ticks).toFixed(1) });
        }
      };
      requestAnimationFrame(f);
    }));
    console.log(`${engine} ${viewport.width}x${viewport.height} ${args.join(" ") || "-"}: ` +
                `${r.ticks} animation frames, ${r.frames} game frames in 3 s` +
                ` (${r.emu} ms a game frame, ${r.draw} ms drawing a tick)` +
                (channel ? ` [channel ${channel}]` : ""));
  } catch (e) {
    console.log(`${engine} ${viewport.width}x${viewport.height} ${channel || ""}: ${e.message.split("\n")[0]}`);
  } finally {
    await browser.close();
  }
}
web.close();
