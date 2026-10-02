// Pokemon SoulSilver's battery save in the real app (headless Chromium), as
// a person does it: add the game, import a .sav through Manage Saves, CONTINUE
// into the overworld, save in the game, reload the page, CONTINUE from that
// save. With no BIOS/firmware dumps: the app's default (HLE BIOS, built-in
// firmware), which once ended CONTINUE in "A communication error has
// occurred" (docs/nds/saves.md). Optionally the same with firmware.bin set in
// Settings > Nintendo DS (the workaround on builds without the fix).
//
// LOCAL ONLY: needs the commercial ROM and a save, never in the repo or CI.
// Skips unless these are set:
//
//   DINGBAT_NDS_SOULSILVER=/path/PokemonSoulSilver.nds
//   DINGBAT_NDS_SOULSILVER_SAVE=/path/a.sav    # a save standing in New Bark Town
//   DINGBAT_NDS_FIRMWARE=/path/firmware.bin    # optional: the Settings test
//   DINGBAT_E2E_SHOTS=/dir                     # optional: screenshots (default: none)
//   node --test e2e/nds-soulsilver.e2e.mjs      # from web/ (wasm builds as nds.e2e.mjs)
//
// The run takes a few minutes: the game plays at its real speed.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, basename } from "node:path";
import { createRequire } from "node:module";
import { serveWeb, WEB, builtWeb, sleep } from "./devices.mjs";

const require = createRequire(join(WEB, "package.json"));
const playwright = require("playwright");
const ROM = process.env.DINGBAT_NDS_SOULSILVER || "";
const SAVE = process.env.DINGBAT_NDS_SOULSILVER_SAVE || "";
const FIRMWARE = process.env.DINGBAT_NDS_FIRMWARE || "";
const SHOTS = process.env.DINGBAT_E2E_SHOTS || "";
const missing = [
  ...(builtWeb() ? [] : ["web/em.wasm"]),
  ...(existsSync(join(WEB, "nds/nds.wasm")) ? [] : ["web/nds/nds.wasm"]),
  ...(ROM && existsSync(ROM) ? [] : ["DINGBAT_NDS_SOULSILVER"]),
  ...(SAVE && existsSync(SAVE) ? [] : ["DINGBAT_NDS_SOULSILVER_SAVE"]),
];
const skip = missing.length ? "missing: " + missing.join(", ") : false;
const NAME = basename(ROM);
const SAVE_KEY = "save:" + NAME;

let web, browser;
before(async () => {
  if (skip) return;
  if (SHOTS) mkdirSync(SHOTS, { recursive: true });
  web = await serveWeb();
  browser = await playwright.chromium.launch({ headless: true, args: [
    "--mute-audio", "--autoplay-policy=no-user-gesture-required",
    ...(process.platform === "darwin" ? ["--enable-gpu", "--use-angle=metal", "--ignore-gpu-blocklist"] : []),
  ] });
});
after(async () => { await browser?.close(); web?.close(); });

const ready = (page) => page.waitForFunction(
  () => document.body.classList.contains("runtime-ready"), null, { timeout: 30000 });
const newPage = async (ctx) => {
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("dialog", (d) => d.accept()); // the import's "overwrite?" questions
  await page.goto(web.url);
  await ready(page);
  return { page, errors };
};
const running = (page) => page.waitForFunction(() =>
  document.body.classList.contains("running") && ndsCoreGame !== null && !paused,
  null, { timeout: 120000 });
const frame = (page) => page.evaluate(() => ndsCore._nds_frame_count());
const framesPast = (page, n) => page.waitForFunction(
  (n) => ndsCore._nds_frame_count() >= n, n, { timeout: 240000, polling: 16 });

// A pick through the app's own file chooser.
const choose = async (page, clickSel, path) => {
  const [chooser] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator(clickSel).locator("visible=true").first().click(),
  ]);
  await chooser.setFiles(path);
};

// Keys: the default bindings (A = Z, Start = Return; Settings > Controls).
const KEY = { A: "KeyZ", B: "KeyX", START: "Enter", DOWN: "ArrowDown", UP: "ArrowUp" };
const press = async (page, key, at, hold = 3) => {
  await framesPast(page, at);
  await page.keyboard.down(KEY[key]);
  await framesPast(page, at + hold);
  await page.keyboard.up(KEY[key]);
};
// The stylus on bottom-screen pixel (x, y), through the canvas.
const touch = async (page, x, y, at, hold = 6) => {
  await framesPast(page, at);
  const p = await page.evaluate(([x, y]) => {
    const r = canvasEl.getBoundingClientRect();
    const b = NdsUtil.screenRects(ndsLay.mode, ndsLay.gap).bottom;
    return [r.left + (b.x + x + 0.5) * r.width / ndsLay.w, r.top + (b.y + y + 0.5) * r.height / ndsLay.h];
  }, [x, y]);
  await page.mouse.move(p[0], p[1]);
  await page.mouse.down();
  await framesPast(page, at + hold);
  await page.mouse.up();
};

// Both screens from the core (RGBA), as a PNG in SHOTS; and how much of the
// bottom screen is the overworld's green touch menu (the title, the intro
// and the communication-error screen have none).
const shot = async (page, name) => {
  const r = await page.evaluate(() => {
    const t = ndsCore._nds_fb_top(), b = ndsCore._nds_fb_bottom();
    const n = 256 * 192 * 4;
    const top = ndsCore.HEAPU8.slice(t, t + n), bottom = ndsCore.HEAPU8.slice(b, b + n);
    let green = 0;
    for (let i = 0; i < n; i += 4) {
      const [r, g, bl] = [bottom[i], bottom[i + 1], bottom[i + 2]];
      if (g > 120 && g > r + 40 && g > bl + 20) green++;
    }
    const c = document.createElement("canvas");
    c.width = 256; c.height = 384;
    const ctx = c.getContext("2d");
    ctx.putImageData(new ImageData(new Uint8ClampedArray(top), 256, 192), 0, 0);
    ctx.putImageData(new ImageData(new Uint8ClampedArray(bottom), 256, 192), 0, 192);
    let h = 0x811c9dc5;
    for (let i = 0; i < n; i++) { h ^= top[i]; h = Math.imul(h, 0x01000193) >>> 0; }
    return { green: green / (256 * 192), png: c.toDataURL("image/png"), topHash: h };
  });
  if (SHOTS) {
    writeFileSync(join(SHOTS, name + ".png"), Buffer.from(r.png.split(",")[1], "base64"));
    await page.screenshot({ path: join(SHOTS, name + "-app.png") });
  }
  return r;
};

// Title -> CONTINUE -> the overworld (frames from boot: the p12 script's).
const continueGame = async (page) => {
  assert.ok(await frame(page) < 600, "booted afresh");
  await press(page, "START", 700);
  await press(page, "START", 1000);
  await press(page, "A", 1300);
  await framesPast(page, 1500);
};

const importSave = async (page, path) => {
  const f0 = await frame(page);
  await page.locator("#menu-btn").click();
  await page.locator("#manage-saves").click();
  await choose(page, "#load-save", path);
  // The import reboots the core in place on the new save.
  await page.waitForFunction((f0) => ndsCoreGame !== null && ndsCore._nds_frame_count() < f0,
                             f0, { timeout: 60000 });
  await running(page);
};

const stored = (page) => page.evaluate(async (k) => {
  const s = await dbGet(k);
  return s ? { len: s.length, sig: saveSignature(s) } : null;
}, SAVE_KEY);

test("SoulSilver: an imported save continues, saves in game, and continues after a reload",
     { skip, timeout: 900000 }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  // No dumps: HLE BIOS and the built-in firmware.
  const dumps = await page.evaluate(async () => (await ndsBiosFiles()));
  assert.deepEqual(dumps, { bios9: null, bios7: null, firmware: null });
  await choose(page, "#home-load, #lib-add, #home-solo-add", ROM);
  await running(page);
  await page.evaluate(() => setNdsLayout("stack"));
  await importSave(page, SAVE);
  const imported = readFileSync(SAVE);
  assert.equal((await stored(page)).len, imported.length, "the import is the stored save");

  await continueGame(page);
  const first = await shot(page, "ss-1-continue");
  assert.ok(first.green > 0.25, "CONTINUE reached the overworld (touch menu up): " + first.green);

  // A few steps down, then SAVE on the touch menu and A through its
  // questions ("save the game?", "overwrite?") until the menu is back.
  await press(page, "DOWN", 1560, 30);
  const f = (await frame(page)) + 60;
  await touch(page, 124, 76, f);
  let saved = null;
  for (let i = 0, at = f + 60; i < 60; i++, at += 60) {
    await press(page, "A", at);
    await framesPast(page, at + 40);
    saved = await shot(page, "ss-2-saved");
    if (i >= 4 && saved.green > 0.25) break;
  }
  assert.ok(saved.green > 0.25, "the save finished, back in the overworld: " + saved.green);
  await page.evaluate(() => persistSave(currentRomName, currentOriginalName));
  const after = await stored(page);
  assert.ok(after && after.len === 512 * 1024, "a 512K FLASH image is stored: " + after?.len);
  const importedSig = await page.evaluate((b) => saveSignature(new Uint8Array(b)), [...imported]);
  assert.notEqual(after.sig, importedSig, "the game wrote its save");

  // A new page: the game from its library tile, on the stored save.
  await page.reload();
  await ready(page);
  await page.locator(".home-tile, #hero-shot").locator("visible=true").first().click();
  await running(page);
  const booted = await page.evaluate(() => saveSignature(ndsSaveBytes()));
  assert.equal(booted, after.sig, "the core booted on the save written in game");
  await continueGame(page);
  const again = await shot(page, "ss-3-reload-continue");
  assert.ok(again.green > 0.25, "CONTINUE after the reload reached the overworld: " + again.green);
  assert.deepEqual(errors, []);
  await ctx.close();
});

test("SoulSilver: with firmware.bin set in Settings, CONTINUE works too",
     { skip: skip || (!FIRMWARE || !existsSync(FIRMWARE) ? "DINGBAT_NDS_FIRMWARE not set" : false),
       timeout: 600000 }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  // Settings > Nintendo DS > Firmware: Choose.
  const settings = page.locator("#settings-btn").locator("visible=true");
  if (await settings.count()) await settings.first().click();
  else { await page.locator("#menu-btn").click(); await page.locator("#open-settings").click(); }
  await page.locator("#settings-tab-ds").click();
  await choose(page, "#pick-nds-firmware", FIRMWARE);
  await page.waitForFunction(() => document.getElementById("nds-firmware-status").textContent !== "Built-in");
  await page.locator("#settings-close, #settings-close-list").locator("visible=true").first().click();
  await choose(page, "#home-load, #lib-add, #home-solo-add", ROM);
  await running(page);
  assert.ok((await page.evaluate(async () => (await ndsBiosFiles()).firmware?.length)) > 0);
  await importSave(page, SAVE);
  await continueGame(page);
  const r = await shot(page, "ss-fw-continue");
  assert.ok(r.green > 0.25, "CONTINUE reached the overworld: " + r.green);
  assert.deepEqual(errors, []);
  await ctx.close();
});
