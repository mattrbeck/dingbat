// Settings on a touch screen, tapped with a finger: every button in its
// headers, and a row of its list, does its own job. A touch screen grows
// small buttons' targets with an absolute ::after (styles.css, pointer:
// coarse); on a close button left unpositioned in a header row, that ::after
// once took the whole header as its box - on a phone Back, Previous and Next
// all closed Settings, and on a tablet so did a tap on a row of the list.
// Each tap lands on the middle of the button, as a finger does, and
// the page decides what was hit - nothing is clicked by name.
//
// Phones: an iPhone (WebKit, Safari's engine) and an Android phone
// (Chromium), where Settings is a sheet - a list, and a section pushed over
// it with Back and Previous/Next. A tablet: an iPad, upright and on its
// side, where Settings is the list beside the section, with no Back and no
// arrows. What a layout does not show is not tapped.
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
const browsers = new Map();
const browser = async (engine) => {
  if (!browsers.has(engine)) browsers.set(engine, await playwright[engine].launch({ headless: true }));
  return browsers.get(engine);
};
after(async () => { for (const b of browsers.values()) await b.close(); web?.close(); });

// Where Settings is: open or not, on the list or in a section, and which.
const where = (page) => page.evaluate(() => ({
  open: document.getElementById("settings-modal").classList.contains("open"),
  detail: document.getElementById("settings-frame").classList.contains("on-detail"),
  title: document.getElementById("settings-section-title").textContent.trim(),
}));

const shown = (page, selector) => page.locator(selector).first().isVisible();

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

const DEVICES = [
  { engine: "webkit", descriptor: "iPhone 13 Mini", sheet: true },
  { engine: "chromium", descriptor: "Pixel 7", sheet: true },
  { engine: "webkit", descriptor: "iPad Pro 11", sheet: false },
  { engine: "webkit", descriptor: "iPad Pro 11 landscape", sheet: false },
];

for (const { engine, descriptor, sheet } of DEVICES) {
  test(`Settings on a touch screen (${descriptor}): each button and row does its own job`,
       { skip, timeout: 120000 }, async () => {
    web ??= await serveWeb();
    const ctx = await (await browser(engine)).newContext(
      { ...playwright.devices[descriptor], serviceWorkers: "block" });
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

    // The touch styles are the ones under test, in the layout this device gets.
    const media = await page.evaluate(() => ({
      coarse: matchMedia("(pointer: coarse)").matches,
      sheet: matchMedia("(max-width: 759px)").matches,
    }));
    assert.ok(media.coarse, "the screen is a coarse pointer");
    assert.equal(media.sheet, sheet, sheet ? "Settings is a sheet" : "Settings is list and section side by side");
    // In the sheet, a row opens its section over the list; side by side,
    // the section is always there.
    const inSection = sheet ? { detail: true } : {};

    // Opened from the library's gear, on the list. The list's ×, where
    // there is one, closes it.
    await tap(page, "#settings-btn");
    await settle(page, { open: true, detail: false }, "the gear opens Settings on the list");
    if (await shown(page, "#settings-close-list")) {
      await tap(page, "#settings-close-list");
      await settle(page, { open: false }, "the list's × closes Settings");
      await tap(page, "#settings-btn");
      await settle(page, { open: true, detail: false }, "the gear opens Settings again");
    } else {
      assert.ok(!sheet, "the sheet's list has a ×");
    }

    // A row opens its section.
    await tap(page, "#settings-tab-audio");
    await settle(page, { open: true, ...inSection, title: "Audio" }, "the Audio row opens Audio");

    // Next and Previous step through the sections, Settings staying open.
    if (await shown(page, "#settings-next")) {
      await tap(page, "#settings-next");
      await settle(page, { open: true, ...inSection, title: "Play" }, "Next moves on to Play");
      await tap(page, "#settings-prev");
      await settle(page, { open: true, ...inSection, title: "Audio" }, "Previous moves back to Audio");
    } else {
      assert.ok(!sheet, "the sheet's section has Previous and Next");
    }

    // Back goes to the list, Settings staying open.
    if (await shown(page, "#settings-back")) {
      await tap(page, "#settings-back");
      await settle(page, { open: true, detail: false }, "Back returns to the list");
    } else {
      assert.ok(!sheet, "the sheet's section has Back");
    }

    // Another row, then the section's ×, which closes Settings.
    await tap(page, "#settings-tab-video");
    await settle(page, { open: true, ...inSection, title: "Video" }, "the Video row opens Video");
    await tap(page, "#settings-close");
    await settle(page, { open: false }, "the section's × closes Settings");

    assert.deepEqual(errors, [], "no page errors");
    await ctx.close();
  });
}
