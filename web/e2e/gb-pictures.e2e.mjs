// A black-and-white game's four shades leave the core as greys (gb.nim
// DMG_COLORS) and every picture of it translates them into the shade palette:
// the library tile, a save slot's thumbnail, the export (clips, Record,
// screenshots), the ambient glow and both link-cable screens. The default
// palette is Night's, so each must come out purple.
//
//   node --test e2e/gb-pictures.e2e.mjs    # from web/, after the wasm build

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, sleep, WEB } from "./devices.mjs";
import { synctestRom } from "./synctest-rom.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;
const engine = process.env.DINGBAT_E2E_NO_CHROMIUM ? "webkit" : "chromium";

let web = null;
let browser = null;
after(async () => { await browser?.close(); web?.close(); });

test("a monochrome game's greys come out in the palette everywhere", { skip, timeout: 120000 }, async () => {
  web ??= await serveWeb();
  browser = await playwright[engine].launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.on("pageerror", (e) => console.log("pageerror:", e.message));
  await page.goto(web.url);
  await page.waitForFunction(() => typeof Module !== "undefined" && runtimeReady && typeof db !== "undefined" && !!db,
                             null, { timeout: 60000 });
  await page.evaluate(() => {
    // How purple a picture is: the share of its (visible) pixels bluer than
    // they are green. Every Night shade is, by 12 or more; a grey is not, nor
    // is the old amber.
    window.__purple = async (src, minAlpha = 255) => {
      const img = src instanceof HTMLCanvasElement ? src : await createImageBitmap(src);
      const c = document.createElement("canvas");
      c.width = img.width;
      c.height = img.height;
      const ctx = c.getContext("2d");
      ctx.drawImage(img, 0, 0);
      const d = ctx.getImageData(0, 0, c.width, c.height).data;
      let seen = 0, purple = 0;
      for (let i = 0; i < d.length; i += 4) {
        if (d[i + 3] < minAlpha) continue;
        seen++;
        if (d[i + 2] - d[i + 1] > 6) purple++;
      }
      return seen ? purple / seen : 0;
    };
  });
  const rom = Array.from(synctestRom());
  await page.evaluate(async (rom) => {
    await dbPut(romKey("Mono.gb"), { name: "Mono.gb", data: new Uint8Array(rom) });
    await bumpRecentIndex("Mono.gb");
    await openLibraryGame("Mono.gb", { resume: false });
  }, rom);
  await page.waitForFunction(() => currentOriginalName === "Mono.gb" && gbMonoPanel, null, { timeout: 20000 });
  await page.evaluate(() => {
    ambientGlowToggle.checked = true;
    ambientGlowToggle.dispatchEvent(new Event("change"));
  });
  await sleep(1500);

  const solo = await page.evaluate(async () => {
    // The core's own output: every pixel one of four greys.
    const [w, h] = gameRes();
    const raw = new Uint16Array(Module.memory.buffer, Module._wasm_native_fb_ptr(), w * h);
    const grey = raw.every((v) => (v & 31) === ((v >> 5) & 31) && (v & 31) === ((v >> 10) & 31));
    // The tile's picture as storeLastFrame encodes it (Playwright's WebKit
    // cannot put a Blob in IndexedDB, so not read back from there).
    const fb = copyFramebuffer();
    return {
      grey,
      tile: await __purple(await frameBlobFromFb(fb.heap, fb.w, fb.h)),
      slot: await __purple(await (await fetch(captureThumbnail())).blob()),
      exported: await __purple(nativeFrameCanvas()),
      glow: glowCanvas.hidden ? -1 : await __purple(glowCanvas, 64),
    };
  });
  assert.ok(solo.grey, "the core's own picture is greys");
  assert.ok(solo.tile > 0.95, "the library tile is in Night's shades: " + solo.tile);
  assert.ok(solo.slot > 0.95, "the slot thumbnail is in Night's shades: " + solo.slot);
  assert.ok(solo.exported > 0.95, "the export is in Night's shades: " + solo.exported);
  assert.ok(solo.glow > 0.95, "the ambient glow is in Night's shades: " + solo.glow);

  await page.evaluate(async (rom) => {
    await launchLinkRom({ name: "Mono.gb", data: new Uint8Array(rom) });
  }, rom);
  await page.waitForFunction(() => linkMode, null, { timeout: 20000 });
  await sleep(1000);
  const link = await page.evaluate(async () => [
    await __purple(document.getElementById("link-canvas-0")),
    await __purple(document.getElementById("link-canvas-1")),
  ]);
  assert.ok(link[0] > 0.95 && link[1] > 0.95, "both link screens are in Night's shades: " + link);
});
