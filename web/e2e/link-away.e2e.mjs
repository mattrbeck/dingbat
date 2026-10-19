// A linked friend whose tab goes to the background. Two players link through
// the real signaling server and real WebRTC; then B hides (visibilitychange)
// and its rAF stops, as a background tab's does. A stalls
// at the prediction limit, shows the "Friend switched away" card and keeps
// the session for longer than the 20 s idle window that used to end it; when
// B comes back the card goes and both play on, linked.
//
// The test ROM never touches the serial port, so each page counts nine
// transfers per simulated frame, as a GBA link game clocks its cable: the
// idle windows see a busy link that goes quiet only because A is stalled.
//
//   node --test e2e/link-away.e2e.mjs      # from web/, after the wasm build
//
// Chromium only (mDNS off, as in link-pairing).

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, sleep, WEB } from "./devices.mjs";
import { synctestRom, SYNCTEST_NAME as GAME } from "./synctest-rom.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;
const SIGNAL_PORT = 8795;
const AWAY_MS = 26000; // past the 20 s window a busy link idles out in

let web = null, signal = null, browser = null;
after(async () => {
  await browser?.close();
  signal?.kill();
  web?.close();
});

const startSignal = async () => {
  signal = spawn(process.execPath, [join(WEB, "signaling/server.js"), String(SIGNAL_PORT)],
    { stdio: "ignore" });
  for (let i = 0; ; i++) {
    try { await fetch(`http://127.0.0.1:${SIGNAL_PORT}/`); return; } catch {}
    if (i > 100) throw new Error("signaling server never came up");
    await sleep(50);
  }
};

const until = async (cond, what, ms) => {
  const end = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > end) assert.fail("timed out waiting for " + (typeof what === "function" ? await what() : what));
    await sleep(100);
  }
};

const player = async () => {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 } });
  const page = await ctx.newPage();
  await page.goto(web.url + "?signal=ws://127.0.0.1:" + SIGNAL_PORT);
  await page.waitForFunction(() => typeof Module !== "undefined" && runtimeReady &&
    typeof db !== "undefined" && !!db, null, { timeout: 60000 });
  await page.evaluate(() => dbPut(THUMBS_OFFER_KEY, Date.now()));
  await sleep(500);
  const [chooser] = await Promise.all([page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
  await chooser.setFiles({ name: GAME, mimeType: "application/octet-stream",
                           buffer: Buffer.from(synctestRom()) });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused,
    null, { timeout: 30000 });
  return { ctx, page };
};

const connect = async ({ page }, code) => {
  await page.evaluate(() => document.getElementById("net-connect").click());
  await page.locator("#net-code-input").fill(code);
  await page.locator("#net-join-go").click();
};

// Nine serial transfers per frame the core actually simulates.
const busyCable = ({ page }) => page.evaluate(() => {
  const tick = Module._rollback_tick;
  let n = 0;
  Module._rollback_tick = (b) => { const f = tick(b); if (f >= 0) n += 9; return f; };
  Module._rollback_transfers = () => n;
});

// A background tab: document.hidden flips, visibilitychange fires, and rAF
// stops (its callbacks are held and run on return). Headless Chromium never
// hides a page, and won't freeze one it thinks is visible.
const setHidden = ({ page }, hidden) => page.evaluate((h) => {
  if (h) {
    window.__raf = window.requestAnimationFrame;
    window.__rafHeld = [];
    window.requestAnimationFrame = (cb) => { window.__rafHeld.push(cb); return 0; };
  } else {
    window.requestAnimationFrame = window.__raf;
    for (const cb of window.__rafHeld) window.__raf(cb);
  }
  Object.defineProperty(document, "hidden", { configurable: true, get: () => h });
  Object.defineProperty(document, "visibilityState", { configurable: true, get: () => (h ? "hidden" : "visible") });
  document.dispatchEvent(new Event("visibilitychange"));
}, hidden);

const linked = (p) => p.page.evaluate(() => !!net?.started);
const netLog = (p) => p.page.evaluate(() =>
  [...document.querySelectorAll("#log-entries p")].map((e) => e.textContent).filter((t) => t.includes("netplay")));
const toasts = (p) => p.page.evaluate(() =>
  [...document.querySelectorAll("#toast .toast-item")].map((e) => e.textContent));
const cardShown = (p) => p.page.evaluate(() => !document.getElementById("net-away").hidden);

test("a friend's background tab shows the away card and the link outlives the idle window",
     { skip, timeout: 180000 }, async () => {
  web ??= await serveWeb();
  if (!signal) await startSignal();
  browser ??= await playwright.chromium.launch({ headless: true,
    args: ["--disable-features=WebRtcHideLocalIpsWithMdns", "--mute-audio"] });
  const a = await player(), b = await player();
  await connect(a, "AWAYE2E");
  await until(() => a.page.evaluate(() => net?.ws?.readyState === 1), "A at the server", 10000);
  await sleep(500);
  await connect(b, "AWAYE2E");
  await until(async () => (await linked(a)) && (await linked(b)), "both linked", 60000);
  await busyCable(a);
  await busyCable(b);
  await until(() => a.page.evaluate(() => rbLinkWasActive), "A's cable in real use", 10000);

  // B goes to the background: says so, then its game loop stops.
  await setHidden(b, true);

  await until(() => cardShown(a), "A's away card", 5000);
  assert.ok(await a.page.evaluate(() => document.body.classList.contains("peer-away")));
  assert.ok(await a.page.evaluate(() => rbStallSince > 0), "A is stalled on B");
  assert.ok(await a.page.evaluate(() => document.getElementById("net-stall").hidden),
            "the card, not the badge, explains the wait");
  await sleep(AWAY_MS);
  assert.ok(await linked(a), "A kept the session past the idle window: " + (await netLog(a)).join(" | "));
  const clock = await a.page.evaluate(() => document.getElementById("net-away-time").textContent);
  assert.match(clock, /^Away 0:2\d$/);

  // B comes back.
  await setHidden(b, false);
  await until(async () => (await toasts(b)).some((t) => t.startsWith("Your game was paused for")),
    async () => "B's welcome-back toast: " + (await toasts(b)).join(" | "), 5000);
  await until(async () => !(await cardShown(a)), "A's card gone", 5000);
  assert.ok((await netLog(a)).some((t) => t.includes("friend back after")));
  await until(() => a.page.evaluate(() => rbStallSince === 0), "A running again", 5000);
  assert.ok((await linked(a)) && (await linked(b)), "both still linked");
  await a.ctx.close(); await b.ctx.close();
});
