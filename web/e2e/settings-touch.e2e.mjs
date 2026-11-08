// Settings on a touch phone, tapped with a finger: every button in the
// sheet's headers does its own job. A touch screen grows small buttons'
// targets with an absolute ::after (styles.css, pointer: coarse); on a
// close button left unpositioned in a header row, that ::after once took the
// whole header as its box, so Back, Previous and Next all closed Settings.
// Each tap lands on the middle of the button, as a finger does, and the
// page decides what was hit - nothing is clicked by name.
//
// An iPhone (WebKit, Safari's engine) and an Android phone (Chromium).
//
//   node --test e2e/settings-touch.e2e.mjs    # from web/, after the wasm build

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, sleep, WEB } from "./devices.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;

let web = null;
const browsers = [];
after(async () => { for (const b of browsers) await b.close(); web?.close(); });

// Where Settings is: open or not, on the list or in a section, and which.
const where = (page) => page.evaluate(() => ({
  open: document.getElementById("settings-modal").classList.contains("open"),
  detail: document.getElementById("settings-frame").classList.contains("on-detail"),
  title: document.getElementById("settings-section-title").textContent.trim(),
}));

// A finger on the middle of what `selector` names, once it has stopped
// moving (the sheet slides in, and a section slides over the list).
const tap = async (page, selector) => {
  const el = page.locator(selector).locator("visible=true").first();
  await el.waitFor({ state: "visible", timeout: 5000 });
  let box = null;
  for (let i = 0; i < 50; i++) {
    const now = await el.boundingBox();
    if (now && box && now.x === box.x && now.y === box.y &&
        now.width === box.width && now.height === box.height) break;
    box = now;
    await sleep(100);
  }
  assert.ok(box, selector + " has a box on screen");
  await page.touchscreen.tap(box.x + box.width / 2, box.y + box.height / 2);
  await sleep(150);
};

// Until Settings is where `want` says (each key given must match).
const settle = async (page, want, what) => {
  try {
    await page.waitForFunction((want) => {
      const now = {
        open: document.getElementById("settings-modal").classList.contains("open"),
        detail: document.getElementById("settings-frame").classList.contains("on-detail"),
        title: document.getElementById("settings-section-title").textContent.trim(),
      };
      return Object.entries(want).every(([k, v]) => now[k] === v);
    }, want, { timeout: 3000 });
  } catch {
    assert.fail(what + ": wanted " + JSON.stringify(want) + ", got " + JSON.stringify(await where(page)));
  }
};

const PHONES = [
  { engine: "webkit", descriptor: "iPhone 13 Mini" },
  { engine: "chromium", descriptor: "Pixel 7" },
];

for (const { engine, descriptor } of PHONES) {
  test(`Settings on a touch phone (${descriptor}): Back, the arrows, a row and both ×s each do their own job`,
       { skip, timeout: 120000 }, async () => {
    web ??= await serveWeb();
    const browser = await playwright[engine].launch({ headless: true });
    browsers.push(browser);
    const ctx = await browser.newContext({ ...playwright.devices[descriptor], serviceWorkers: "block" });
    const page = await ctx.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(web.url);
    await page.waitForFunction(() => typeof db !== "undefined" && !!db, null, { timeout: 60000 });
    // The one-time offer to picture the library has been answered.
    await page.evaluate(() => dbPut(THUMBS_OFFER_KEY, Date.now()));
    await page.reload();
    await page.waitForFunction(() => typeof runtimeReady !== "undefined" && runtimeReady &&
      typeof db !== "undefined" && !!db, null, { timeout: 60000 });
    await sleep(500);

    // The touch styles are the ones under test, and the sheet layout.
    const media = await page.evaluate(() => ({
      coarse: matchMedia("(pointer: coarse)").matches,
      sheet: matchMedia("(max-width: 759px)").matches,
    }));
    assert.ok(media.coarse, "the phone has a coarse pointer");
    assert.ok(media.sheet, "Settings is a sheet at this width");

    // Opened from the library's gear, on the list. The list's × closes it.
    await tap(page, "#settings-btn");
    await settle(page, { open: true, detail: false }, "the gear opens Settings on the list");
    await tap(page, "#settings-close-list");
    await settle(page, { open: false }, "the list's × closes Settings");

    // A row opens its section.
    await tap(page, "#settings-btn");
    await settle(page, { open: true, detail: false }, "the gear opens Settings again");
    await tap(page, "#settings-tab-audio");
    await settle(page, { open: true, detail: true, title: "Audio" }, "the Audio row opens Audio");

    // Next and Previous step through the sections, Settings staying open.
    await tap(page, "#settings-next");
    await settle(page, { open: true, detail: true, title: "Play" }, "Next moves on to Play");
    await tap(page, "#settings-prev");
    await settle(page, { open: true, detail: true, title: "Audio" }, "Previous moves back to Audio");

    // Back goes to the list, Settings staying open.
    await tap(page, "#settings-back");
    await settle(page, { open: true, detail: false }, "Back returns to the list");

    // Another row, then the section's ×, which closes Settings.
    await tap(page, "#settings-tab-video");
    await settle(page, { open: true, detail: true, title: "Video" }, "the Video row opens Video");
    await tap(page, "#settings-close");
    await settle(page, { open: false }, "the section's × closes Settings");

    assert.deepEqual(errors, [], "no page errors");
    await ctx.close();
  });
}
