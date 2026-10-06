// A controller, and nothing else (index.js "Gamepad support"): the real
// build with a scripted standard-mapping pad in place of navigator's. From
// the library the pad finds a game and starts it, plays it (the test ROM's
// counter c goes up a frame while A is held), holds RT to fast-forward,
// opens the menu paused with R3 and Select+Start, and goes home from it.
//
//   node --test e2e/gamepad.e2e.mjs        # from web/, after the wasm build
//
// DINGBAT_E2E_SHOTS=<dir> saves a screenshot at each step.

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, sleep, WEB } from "./devices.mjs";
import { synctestRom } from "./synctest-rom.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;
const engine = process.env.DINGBAT_E2E_NO_CHROMIUM ? "webkit" : "chromium";
const SHOTS = process.env.DINGBAT_E2E_SHOTS;

// Standard-mapping indices.
const P = { A: 0, B: 1, X: 2, Y: 3, LB: 4, RB: 5, LT: 6, RT: 7, BACK: 8, START: 9,
  L3: 10, R3: 11, UP: 12, DOWN: 13, LEFT: 14, RIGHT: 15, GUIDE: 16 };

// Eight GB games and a GBA one: past LIB_BAR_MIN, so the filter bar shows,
// and two systems, so it has chips.
const GB_NAMES = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel"]
  .map((n) => n + ".gb");
const GBA_NAME = "Goodboy.gba";

let web = null;
let browser = null;
after(async () => { await browser?.close(); web?.close(); });

const until = async (page, fn, what, ms = 10000, arg) => {
  try { await page.waitForFunction(fn, arg, { timeout: ms }); }
  catch {
    if (SHOTS) await page.screenshot({ path: join(SHOTS, "failed.png") }).catch(() => {});
    const seen = await page.evaluate(() => ({ body: document.body.className, paused,
      focus: document.activeElement?.id || document.activeElement?.className,
      modals: [...document.querySelectorAll(".modal-overlay.open")].map((m) => m.id),
      toasts: [...document.querySelectorAll("#toast .toast-msg")].map((t) => t.textContent) })).catch(() => null);
    assert.fail("timed out waiting for " + what + ": " + JSON.stringify(seen));
  }
};

test("a controller finds a game, starts it, plays it and goes home", { skip, timeout: 180000 }, async () => {
  web ??= await serveWeb();
  browser = await playwright[engine].launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.on("pageerror", (e) => console.log("pageerror:", e.message));
  // The pad: what navigator.getGamepads returns, driven from here. As a
  // browser does, it is handed over only from its first button press.
  await page.addInitScript(() => {
    window.__pad = new Array(17).fill(false);
    let shown = false;
    navigator.getGamepads = () => {
      shown ||= window.__pad.some(Boolean);
      return shown ? [{
        id: "scripted pad", index: 0, connected: true, mapping: "standard", timestamp: performance.now(),
        buttons: window.__pad.map((p) => ({ pressed: p, touched: p, value: p ? 1 : 0 })),
        axes: [0, 0, 0, 0],
      }] : [];
    };
  });
  let shot = 0;
  const snap = async (name) => {
    if (SHOTS) await page.screenshot({ path: join(SHOTS, String(++shot).padStart(2, "0") + "-" + name + ".png") });
  };
  // A press spans a few animation frames, as a thumb's does.
  const down = (b) => page.evaluate((b) => { window.__pad[b] = true; }, b);
  const up = (b) => page.evaluate((b) => { window.__pad[b] = false; }, b);
  const tap = async (...bs) => {
    for (const b of bs) { await down(b); await sleep(80); await up(b); await sleep(80); }
  };
  const focused = () => page.evaluate(() => {
    const el = document.activeElement;
    if (!el || el === document.body) return null;
    // A tile's game only for the tile itself, not its corner buttons.
    if (el.classList.contains("home-tile-launch")) return el.closest(".home-tile").dataset.rom;
    return el.id || el.className;
  });

  await page.goto(web.url);
  await until(page, () => typeof Module !== "undefined" && runtimeReady && typeof db !== "undefined" && !!db,
              "the runtime", 60000);
  // The library, stored as an import leaves it.
  const gb = Array.from(synctestRom());
  const gba = Array.from(readFileSync(join(WEB, "goodboy-demo-en.gba")));
  await page.evaluate(async ({ names, gb, gbaName, gba }) => {
    await dbPut(THUMBS_OFFER_KEY, Date.now());
    for (const name of names) {
      await dbPut(romKey(name), { name, data: new Uint8Array(gb) });
      await bumpRecentIndex(name);
    }
    await dbPut(romKey(gbaName), { name: gbaName, data: new Uint8Array(gba) });
    await bumpRecentIndex(gbaName);
    await refreshHomeRecent();
  }, { names: GB_NAMES, gb, gbaName: GBA_NAME, gba });
  await until(page, () => document.querySelectorAll(".home-tile:not([hidden])").length >= 9, "the tiles");
  await sleep(500);
  await snap("home");

  // First press: focus lands on the library's first game, nothing launches.
  await tap(P.DOWN);
  assert.equal(await focused(), GBA_NAME, "the first press focuses the most recent game");
  assert.ok(await page.evaluate(() => document.body.classList.contains("pad-nav")), "the pad's ring is on");
  assert.deepEqual(await page.evaluate(() => ({
    told: [...document.querySelectorAll("#toast .toast-msg")].some((t) => t.textContent === "Controller connected: scripted pad"),
    status: document.getElementById("pad-status").textContent,
  })), { told: true, status: "Connected: scripted pad" }, "the page says a controller is here");
  // Right, then down a row: spatial, through the grid.
  await tap(P.RIGHT);
  const right = await focused();
  assert.notEqual(right, GBA_NAME, "right moved");
  const before = await page.evaluate(() => document.activeElement.getBoundingClientRect().top);
  await tap(P.DOWN);
  const after1 = await page.evaluate(() => document.activeElement.getBoundingClientRect().top);
  assert.ok(await page.evaluate(() => document.activeElement.classList.contains("home-tile-launch")),
            "down stays on a tile");
  assert.ok(after1 > before || (await focused()) !== right, "down moved to the next row");
  await snap("focus-moved");

  // RB: the filter steps to the first system; LB back to every game.
  await tap(P.RB);
  const shownGb = await page.evaluate(() => document.querySelectorAll(".home-tile:not([hidden])").length);
  assert.ok(await page.evaluate(() => document.activeElement.classList.contains("home-tile-launch") &&
    !document.activeElement.closest(".home-tile").hidden), "focus went to a game still shown");
  await snap("filter");
  await tap(P.LB);
  const shownAll = await page.evaluate(() => document.querySelectorAll(".home-tile:not([hidden])").length);
  assert.ok(shownGb < shownAll, `RB narrowed the grid (${shownGb} of ${shownAll})`);
  // RT sorts (A–Z), LT back.
  await tap(P.RT);
  assert.equal(await page.evaluate(() => romsSort), "alpha");
  await sleep(300);
  await snap("sorted");
  await tap(P.LT);
  assert.equal(await page.evaluate(() => romsSort), "recent");
  await sleep(300);

  // Y: the focused tile's menu; B closes it.
  await tap(P.DOWN); // focus again after the re-render
  const game = await focused();
  await tap(P.Y);
  await until(page, () => tileMenuFor !== null, "the tile menu");
  await snap("tile-menu");
  await tap(P.DOWN);
  assert.ok(await page.evaluate(() => document.getElementById("tile-menu").contains(document.activeElement)),
            "the d-pad walks the tile menu");
  await tap(P.B);
  await until(page, () => tileMenuFor === null, "the tile menu closed");

  // Walk to a GB test game, then A starts it.
  for (let i = 0; i < 12 && !GB_NAMES.includes(await focused()); i++) await tap(P.RIGHT);
  const chosen = await focused();
  assert.ok(GB_NAMES.includes(chosen), "reached a GB game, at " + chosen);
  await tap(P.A);
  await until(page, () => document.body.classList.contains("running") && !paused &&
    !document.body.classList.contains("home-flying"), "the game running", 30000);
  assert.equal(await page.evaluate(() => currentOriginalName), chosen, "A started the focused game");
  await sleep(1500); // past the load's benchmark frames
  await snap("game");

  // A held plays: c goes up, and it reaches the battery.
  const counter = () => page.evaluate(() => {
    Module._wasm_flush_save?.();
    try { return FS.readFile(currentRomName.replace(/\.[^.]+$/, "") + ".sav")[0]; } catch { return 0; }
  });
  const c0 = await counter();
  await down(P.A); await sleep(400); await up(P.A); await sleep(100);
  const c1 = await counter();
  assert.ok(c1 > c0, `A held played the game (c ${c0} -> ${c1})`);

  // RT held: fast-forward, and back.
  await down(P.RT); await sleep(150);
  assert.equal(await page.evaluate(() => fastForward), true, "RT fast-forwards");
  await up(P.RT); await sleep(150);
  assert.equal(await page.evaluate(() => fastForward), false, "letting go gives 1x back");

  // R3: the menu, paused. B: closed, running.
  await tap(P.R3);
  assert.equal(await page.evaluate(() => !menuDropdown.hidden && paused), true, "R3 opened the menu paused");
  assert.equal(await focused(), "save-state", "the menu's first item has focus");
  await snap("menu");
  // Into a modal from it: down to Save States, A; B closes the modal, and
  // with nothing left open the game runs again.
  for (let i = 0; i < 4 && (await focused()) !== "open-states"; i++) await tap(P.DOWN);
  assert.equal(await focused(), "open-states");
  await tap(P.A);
  await until(page, () => document.getElementById("states-modal").classList.contains("open"), "Save States");
  await tap(P.RIGHT);
  assert.ok(await page.evaluate(() => document.getElementById("states-modal").contains(document.activeElement)),
            "the d-pad walks the modal");
  await snap("states-modal");
  await tap(P.B);
  await until(page, () => !document.getElementById("states-modal").classList.contains("open"), "Save States closed");
  await sleep(100);
  assert.equal(await page.evaluate(() => !paused), true, "the game runs again after the modal");
  await tap(P.R3);
  assert.equal(await page.evaluate(() => !menuDropdown.hidden && paused), true, "R3 opened the menu again");
  await tap(P.B);
  assert.equal(await page.evaluate(() => menuDropdown.hidden && !paused), true, "B closed it and the game runs");

  // Select+Start held: the menu again; down to Main Menu, A: home.
  await down(P.BACK); await down(P.START); await sleep(700);
  await up(P.START); await up(P.BACK); await sleep(80);
  assert.equal(await page.evaluate(() => !menuDropdown.hidden && paused), true, "the held chord opened the menu");
  for (let i = 0; i < 4 && (await focused()) !== "main-menu"; i++) await tap(P.DOWN);
  assert.equal(await focused(), "main-menu", "down reaches Main Menu");
  await tap(P.A);
  await until(page, () => !document.body.classList.contains("running"), "home");
  await sleep(900);
  await snap("home-again");
  assert.equal(await page.evaluate(() => paused), true, "the game stays paused behind home");

  // Start on the home screen: back into the game.
  await tap(P.START);
  await until(page, () => document.body.classList.contains("running") && !paused, "resumed", 10000);
  await snap("resumed");

  // The keyboard on the home screen: Enter on a focused tile starts that
  // game (it used to go to the core paused behind the page).
  await tap(P.R3);
  for (let i = 0; i < 4 && (await focused()) !== "main-menu"; i++) await tap(P.DOWN);
  await tap(P.A);
  await until(page, () => !document.body.classList.contains("running"), "home");
  await sleep(900);
  // The arrows walk the grid from a focused tile too.
  await page.focus(`.home-tile[data-rom="Bravo.gb"] .home-tile-launch`);
  await page.keyboard.press("ArrowRight");
  assert.equal(await focused(), "Alpha.gb", "ArrowRight moved to the next tile");
  await page.keyboard.press("Enter");
  await until(page, () => document.body.classList.contains("running") && currentOriginalName === "Alpha.gb",
              "Enter started the focused game", 30000);
});

// Sound, from the pad alone. Desktop Chrome lets a page play only after a
// click, tap or key press, and a gamepad press is none of those, so a game
// started from the pad comes up silent; the player is told why. Chromium
// only: everything here goes through CDP with userGesture off, because
// Playwright's own evaluate counts as a gesture and would unlock the sound.
test("a game the pad starts in silence says why", { skip: skip || (engine !== "chromium" && "Chromium only (CDP)"), timeout: 120000 }, async () => {
  web ??= await serveWeb();
  const b = await playwright.chromium.launch({ headless: true,
    args: ["--autoplay-policy=document-user-activation-required"] });
  try {
    const page = await b.newPage({ viewport: { width: 1280, height: 800 } });
    await page.addInitScript(() => {
      window.__pad = new Array(17).fill(false);
      navigator.getGamepads = () => [{
        id: "scripted pad", index: 0, connected: true, mapping: "standard", timestamp: performance.now(),
        buttons: window.__pad.map((p) => ({ pressed: p, touched: p, value: p ? 1 : 0 })),
        axes: [0, 0, 0, 0],
      }];
    });
    const cdp = await page.context().newCDPSession(page);
    const run = async (expression) => (await cdp.send("Runtime.evaluate",
      { expression, awaitPromise: true, returnByValue: true, userGesture: false })).result.value;
    const poll = async (expression, what, ms) => {
      const end = Date.now() + ms;
      while (!(await run(expression))) {
        if (Date.now() > end) assert.fail("timed out waiting for " + what);
        await sleep(100);
      }
    };
    await page.goto(web.url);
    await poll(`typeof Module !== "undefined" && runtimeReady && typeof db !== "undefined" && !!db`, "the runtime", 60000);
    await run(`(async () => {
      await dbPut(THUMBS_OFFER_KEY, Date.now());
      await dbPut(romKey("Alpha.gb"), { name: "Alpha.gb", data: new Uint8Array(${JSON.stringify(Array.from(synctestRom()))}) });
      await bumpRecentIndex("Alpha.gb");
      await refreshHomeRecent();
    })()`);
    await poll(`document.querySelectorAll(".home-tile-launch").length > 0`, "the tile", 10000);
    // A focuses the game, A again starts it.
    for (let i = 0; i < 2; i++) {
      await run("__pad[0] = true"); await sleep(80);
      await run("__pad[0] = false"); await sleep(150);
    }
    await poll(`document.body.classList.contains("running")`, "the game running", 30000);
    // Said a moment in; the boot's busy main thread can make that a few seconds.
    const told = `[...document.querySelectorAll("#toast .toast-msg")].some((t) => t.textContent.startsWith("No sound yet"))`;
    await poll(told, "the no-sound notice", 8000);
    const seen = await run(`({ activated: navigator.userActivation.hasBeenActive, sound: window.audioRunning() })`);
    assert.equal(seen.activated, false, "the page saw no gesture");
    assert.equal(seen.sound, false, "the sound is locked, as in desktop Chrome");
  } finally {
    await b.close();
  }
});
