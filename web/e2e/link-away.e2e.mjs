// A linked friend whose tab goes to the background. Two players link through
// the real signaling server and real WebRTC; then one hides
// (visibilitychange) and its rAF stops, as a background tab's does. The
// other stalls at the prediction limit, shows the "Friend switched away"
// card and keeps the session past the 20 s idle window that used to end it.
// The edge cases: a quick alt-tab, a cable that really goes quiet (the idle
// window must still end that), a Disconnect or a closed page while away, a
// stall with no away message (an older build), both players away at once,
// away during a shared pause, and a shared pause past the idle window.
//
// The test ROM never touches the serial port, so each page counts nine
// transfers per simulated frame, as a GBA link game clocks its cable: the
// idle windows see a busy link that goes quiet only when told to, or when
// the core stalls.
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

// Nine serial transfers per frame the core actually simulates, until
// window.__cableQuiet (the games stop talking).
const busyCable = ({ page }) => page.evaluate(() => {
  const tick = Module._rollback_tick;
  let n = 0;
  Module._rollback_tick = (b) => { const f = tick(b); if (f >= 0 && !window.__cableQuiet) n += 9; return f; };
  Module._rollback_transfers = () => n;
});

const linked = (p) => p.page.evaluate(() => !!net?.started);

// Two players linked on a fresh code, the cable in real use on both.
let codes = 0;
const pair = async () => {
  web ??= await serveWeb();
  if (!signal) await startSignal();
  browser ??= await playwright.chromium.launch({ headless: true,
    args: ["--disable-features=WebRtcHideLocalIpsWithMdns", "--mute-audio"] });
  const code = "AWAYE2E" + ++codes;
  const a = await player(), b = await player();
  await connect(a, code);
  await until(() => a.page.evaluate(() => net?.ws?.readyState === 1), "A at the server", 10000);
  await sleep(500);
  await connect(b, code);
  await until(async () => (await linked(a)) && (await linked(b)), "both linked", 60000);
  await busyCable(a);
  await busyCable(b);
  await until(async () => (await a.page.evaluate(() => rbLinkWasActive)) &&
                          (await b.page.evaluate(() => rbLinkWasActive)), "both cables in real use", 10000);
  return { a, b, done: async () => { await a.ctx.close(); await b.ctx.close(); } };
};

// A background tab: rAF stops (its callbacks are held and run on return)
// and, unless `announce` is false, document.hidden flips and
// visibilitychange fires (false: a friend whose page froze without saying
// so, or an older build). Headless Chromium never hides a page, and won't
// freeze one it thinks is visible.
const setHidden = ({ page }, hidden, announce = true) => page.evaluate(([h, ann]) => {
  if (h) {
    window.__raf = window.requestAnimationFrame;
    window.__rafHeld = [];
    window.requestAnimationFrame = (cb) => { window.__rafHeld.push(cb); return 0; };
  } else {
    window.requestAnimationFrame = window.__raf;
    for (const cb of window.__rafHeld) window.__raf(cb);
  }
  if (!ann) return;
  Object.defineProperty(document, "hidden", { configurable: true, get: () => h });
  Object.defineProperty(document, "visibilityState", { configurable: true, get: () => (h ? "hidden" : "visible") });
  document.dispatchEvent(new Event("visibilitychange"));
}, [hidden, announce]);

const netLog = (p) => p.page.evaluate(() =>
  [...document.querySelectorAll("#log-entries p")].map((e) => e.textContent).filter((t) => t.includes("netplay")));
// Every toast mounted since the page loaded (a toast lasts 2.2 s).
const watchToasts = ({ page }) => page.evaluate(() => {
  window.__toasts = [];
  new MutationObserver((ms) => {
    for (const m of ms) for (const n of m.addedNodes) if (n.textContent) window.__toasts.push(n.textContent);
  }).observe(document.getElementById("toast"), { childList: true });
});
const toastsSeen = (p) => p.page.evaluate(() => window.__toasts || []);
const cardShown = (p) => p.page.evaluate(() => !document.getElementById("net-away").hidden);
const badgeShown = (p) => p.page.evaluate(() => !document.getElementById("net-stall").hidden);
const stalled = (p) => p.page.evaluate(() => rbStallSince > 0);

test("a friend's background tab shows the away card and the link outlives the idle window",
     { skip, timeout: 180000 }, async () => {
  const { a, b, done } = await pair();
  await watchToasts(a); await watchToasts(b);
  await setHidden(b, true);
  await until(() => cardShown(a), "A's away card", 5000);
  assert.ok(await a.page.evaluate(() => document.body.classList.contains("peer-away")));
  assert.ok(await stalled(a), "A is stalled on B");
  assert.ok(!(await badgeShown(a)), "the card, not the badge, explains the wait");
  await sleep(AWAY_MS);
  assert.ok(await linked(a), "A kept the session past the idle window: " + (await netLog(a)).join(" | "));
  assert.match(await a.page.evaluate(() => document.getElementById("net-away-time").textContent), /^Away 0:2\d$/);
  await setHidden(b, false);
  await until(async () => (await toastsSeen(b)).some((t) => t.startsWith("Your game was paused for 0:2")),
    async () => "B's welcome-back toast: " + (await toastsSeen(b)).join(" | "), 5000);
  await until(async () => !(await cardShown(a)), "A's card gone", 5000);
  await until(async () => (await toastsSeen(a)).includes("Friend's back — link resumed"), "A's back toast", 5000);
  await until(async () => !(await stalled(a)), "A running again", 5000);
  assert.ok((await linked(a)) && (await linked(b)), "both still linked");
  await done();
});

test("a quick alt-tab flashes no card and toasts nothing", { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await watchToasts(a); await watchToasts(b);
  await setHidden(b, true);
  let flashed = false;
  for (let i = 0; i < 6; i++) { flashed ||= await cardShown(a); await sleep(100); }
  await setHidden(b, false);
  for (let i = 0; i < 15; i++) { flashed ||= await cardShown(a); await sleep(100); }
  assert.ok(!flashed, "no card for a 0.6 s switch");
  assert.deepEqual([...(await toastsSeen(a)), ...(await toastsSeen(b))], []);
  assert.ok((await linked(a)) && (await linked(b)));
  await done();
});

test("a cable that really goes quiet still ends the link at the idle window", { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await watchToasts(a);
  await a.page.evaluate(() => { window.__cableQuiet = true; });
  await b.page.evaluate(() => { window.__cableQuiet = true; });
  const t0 = Date.now();
  await until(async () => !(await linked(a)), "A's idle disconnect", 30000);
  const after = (Date.now() - t0) / 1000;
  assert.ok(after > 18 && after < 25, `idled out after ${after.toFixed(1)} s`);
  assert.ok((await netLog(a)).some((t) => t.includes("link idle 20 s")));
  assert.ok((await toastsSeen(a)).includes("Link idle — disconnected"));
  await until(async () => !(await linked(b)), "B told", 10000);
  await done();
});

test("Disconnect from the card while the friend is away: they hear it on return",
     { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await watchToasts(a); await watchToasts(b);
  await setHidden(b, true);
  await until(() => cardShown(a), "A's away card", 5000);
  const btn = a.page.locator("#net-away-disconnect");
  await btn.click();
  assert.equal(await btn.textContent(), "Are you sure?");
  assert.ok(await linked(a), "one tap only arms it");
  await btn.click();
  await until(async () => !(await linked(a)), "A disconnected", 5000);
  assert.ok(!(await cardShown(a)), "the card goes with the session");
  assert.ok(!(await a.page.evaluate(() => document.body.classList.contains("peer-away"))), "screen undimmed");
  assert.ok(!(await a.page.evaluate(() => rollbackMode || paused)), "A plays on solo");
  await until(async () => !(await linked(b)), "B's session ended while away", 10000);
  await setHidden(b, false);
  await until(async () => (await toastsSeen(b)).some((t) => t.startsWith("Peer disconnected while you were away")),
    async () => "B's toast: " + (await toastsSeen(b)).join(" | "), 5000);
  assert.ok(!(await toastsSeen(b)).some((t) => t.startsWith("Your game was paused")), "no 'friend waited' on a dead link");
  assert.ok(!(await b.page.evaluate(() => rollbackMode || paused)), "B plays on solo");
  await done();
});

test("the friend closes the page while away: the card goes and the game plays on",
     { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await watchToasts(a);
  await setHidden(b, true);
  await until(() => cardShown(a), "A's away card", 5000);
  await b.page.close({ runBeforeUnload: true });
  await until(async () => !(await linked(a)), "A's session ended", 15000);
  assert.ok(!(await cardShown(a)));
  assert.ok((await toastsSeen(a)).some((t) => t.startsWith("Peer disconnected")), (await toastsSeen(a)).join(" | "));
  assert.ok((await netLog(a)).some((t) => t.includes("netplay: Peer disconnected")));
  await done();
});

test("a stall with no away message shows the badge and still outlives the idle window",
     { skip, timeout: 180000 }, async () => {
  const { a, b, done } = await pair();
  await setHidden(b, true, false);
  await until(() => badgeShown(a), "A's badge", 5000);
  assert.ok(!(await cardShown(a)), "no card without the message");
  await sleep(AWAY_MS);
  assert.ok(await linked(a), "A kept the session: " + (await netLog(a)).join(" | "));
  assert.match(await a.page.evaluate(() => document.getElementById("net-stall-text").textContent),
               /^waiting for friend · 0:2\d$/);
  await setHidden(b, false, false);
  await until(async () => !(await badgeShown(a)), "A's badge gone", 5000);
  assert.ok((await linked(a)) && (await linked(b)));
  await done();
});

test("both players away at once, back in turn", { skip, timeout: 180000 }, async () => {
  const { a, b, done } = await pair();
  await watchToasts(a); await watchToasts(b);
  await setHidden(a, true);
  await setHidden(b, true);
  await sleep(AWAY_MS);
  assert.ok((await linked(a)) && (await linked(b)), "neither ended it");
  await setHidden(b, false);
  await until(() => cardShown(b), "B sees A is still away", 5000);
  await sleep(3000);
  assert.ok(await linked(b), "B waits on A without idling out");
  await setHidden(a, false);
  await until(async () => !(await cardShown(b)), "B's card gone", 5000);
  assert.ok(!(await cardShown(a)), "A has no card: B came back first");
  await until(async () => !(await stalled(a)) && !(await stalled(b)), "both running", 5000);
  assert.ok((await linked(a)) && (await linked(b)));
  await done();
});

test("away during a shared pause, then resumed", { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await a.page.evaluate(() => document.getElementById("pause").click());
  await until(() => b.page.evaluate(() => paused), "the pause reached B", 5000);
  await setHidden(b, true);
  await until(() => cardShown(a), "A's card over the paused game", 5000);
  await sleep(AWAY_MS);
  assert.ok(await linked(a));
  await setHidden(b, false);
  await until(async () => !(await cardShown(a)), "card gone", 5000);
  const pausedNow = [await a.page.evaluate(() => paused), await b.page.evaluate(() => paused)];
  assert.deepEqual(pausedNow, [true, true], "still paused on both (A, B): " +
    (await netLog(a)).join(" | ") + " // " + (await netLog(b)).join(" | "));
  await a.page.evaluate(() => document.getElementById("pause").click());
  await until(async () => !(await b.page.evaluate(() => paused)), "resumed on B", 5000);
  await until(async () => !(await stalled(a)) && (await a.page.evaluate(() => Module._rollback_transfers() > 0)), "running", 5000);
  assert.ok((await linked(a)) && (await linked(b)));
  await done();
});

test("a shared pause longer than the idle window resumes without ending the link",
     { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await watchToasts(a); await watchToasts(b);
  await a.page.evaluate(() => document.getElementById("pause").click());
  await until(() => b.page.evaluate(() => paused), "the pause reached B", 5000);
  await sleep(AWAY_MS);
  // B resumes: the first ticks after a pause run no frames, which must not
  // read as 26 s of quiet cable.
  await b.page.evaluate(() => document.getElementById("pause").click());
  await until(async () => !(await a.page.evaluate(() => paused)), "resumed on A", 5000);
  await sleep(3000);
  assert.ok((await linked(a)) && (await linked(b)),
            "still linked: " + (await netLog(a)).join(" | ") + " // " + (await netLog(b)).join(" | "));
  assert.ok(![...(await toastsSeen(a)), ...(await toastsSeen(b))].includes("Link idle — disconnected"));
  await done();
});
