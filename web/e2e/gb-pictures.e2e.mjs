// A black-and-white game's pictures wear the shade palette the screen does:
// the library tile, a save slot's thumbnail and both link-cable screens are
// made from the core's framebuffer, not by the shader, and once showed the
// core's own amber shades under the Night ones. Exports keep the console's
// own picture (index.js NATIVE_SCALE), which is the control: the same frame,
// amber.
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

test("a monochrome game's tile, slot and link screens take the palette", { skip, timeout: 120000 }, async () => {
  web ??= await serveWeb();
  browser = await playwright[engine].launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.on("pageerror", (e) => console.log("pageerror:", e.message));
  await page.goto(web.url);
  await page.waitForFunction(() => typeof Module !== "undefined" && runtimeReady && typeof db !== "undefined" && !!db,
                             null, { timeout: 60000 });
  await page.evaluate(() => {
    // How warm a picture is: the share of pixels redder than they are blue
    // by a margin. The core's shades are cream to brown (all warm); Night's
    // are white to violet, and any mix of them, blue at least as much as red.
    window.__warm = async (src) => {
      const img = src instanceof HTMLCanvasElement ? src : await createImageBitmap(src);
      const c = document.createElement("canvas");
      c.width = img.width;
      c.height = img.height;
      const ctx = c.getContext("2d");
      ctx.drawImage(img, 0, 0);
      const d = ctx.getImageData(0, 0, c.width, c.height).data;
      let warm = 0;
      for (let i = 0; i < d.length; i += 4) if (d[i] - d[i + 2] > 20) warm++;
      return warm / (d.length / 4);
    };
  });
  const rom = Array.from(synctestRom());
  await page.evaluate(async (rom) => {
    await dbPut(romKey("Mono.gb"), { name: "Mono.gb", data: new Uint8Array(rom) });
    await bumpRecentIndex("Mono.gb");
    await openLibraryGame("Mono.gb", { resume: false });
  }, rom);
  await page.waitForFunction(() => currentOriginalName === "Mono.gb" && gbMonoPanel, null, { timeout: 20000 });
  await sleep(1000);

  const solo = await page.evaluate(async () => {
    await storeLastFrame({ force: true });
    const tile = await __warm(await dbGet(frameKey("Mono.gb")));
    const slot = await __warm(await (await fetch(captureThumbnail())).blob());
    const exported = await __warm(nativeFrameCanvas());
    return { tile, slot, exported };
  });
  assert.ok(solo.exported > 0.5, "the export (control) is the console's amber: " + solo.exported);
  assert.ok(solo.tile < 0.01, "the library tile is in Night's shades: " + solo.tile);
  assert.ok(solo.slot < 0.01, "the slot thumbnail is in Night's shades: " + solo.slot);

  await page.evaluate(async (rom) => {
    await launchLinkRom({ name: "Mono.gb", data: new Uint8Array(rom) });
  }, rom);
  await page.waitForFunction(() => linkMode, null, { timeout: 20000 });
  await sleep(1000);
  const link = await page.evaluate(async () => [
    await __warm(document.getElementById("link-canvas-0")),
    await __warm(document.getElementById("link-canvas-1")),
  ]);
  assert.ok(link[0] < 0.01 && link[1] < 0.01, "both link screens are in Night's shades: " + link);
});
