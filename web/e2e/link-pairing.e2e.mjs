// Two players on one code through the real signaling server (server.js) and
// real WebRTC, the real build on both sides: each loads the test ROM, opens
// Link Cable, types the code and presses Connect, and the rollback session
// starts on both. The second case swallows the descriptions A's first socket
// sends, so that pairing never opens: both sides reach the 20 s deadline, go
// back to waiting on the code (sigRewait) and link on the next pairing with
// no further press (formal/WebState/LinkPairing.lean).
//
//   node --test e2e/link-pairing.e2e.mjs      # from web/, after the wasm build
//
// Chromium only, two headless contexts on one machine: it hides host
// candidates behind mDNS names the other context cannot resolve, so mDNS is
// off here. WebKit filters host candidates outright and never pairs two of
// its contexts, which is why CI's WebKit-only e2e shards leave this file out.

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, sleep, WEB } from "./devices.mjs";
import { synctestRom, SYNCTEST_NAME as GAME } from "./synctest-rom.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;
const SIGNAL_PORT = 8794;
const launch = () => playwright.chromium.launch({ headless: true,
  args: ["--disable-features=WebRtcHideLocalIpsWithMdns"] });

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
    if (Date.now() > end) assert.fail("timed out waiting for " + what);
    await sleep(100);
  }
};

// One player: its own context (IndexedDB, BroadcastChannel), the game running.
const player = async (initScript) => {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 } });
  const page = await ctx.newPage();
  if (initScript) await page.addInitScript(initScript);
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

const linked = (p) => p.page.evaluate(() => !!net?.started);
const status = (p) => p.page.evaluate(() => document.getElementById("net-status").textContent);
const log = (p) => p.page.evaluate(() =>
  [...document.querySelectorAll("#log-entries p")].map((e) => e.textContent).filter((t) => t.includes("netplay")));

test("two players on one code link through the server", { skip, timeout: 120000 }, async () => {
  web ??= await serveWeb();
  if (!signal) await startSignal();
  browser ??= await launch();
  const a = await player(), b = await player();
  await connect(a, "PAIRE2E");
  await until(() => a.page.evaluate(() => net?.ws?.readyState === 1), "A at the server", 10000);
  await sleep(500); // its rendezvous answered: A holds the room
  await connect(b, "PAIRE2E");
  await until(async () => (await linked(a)) && (await linked(b)),
    async () => "both linked: A " + (await status(a)) + " / B " + (await status(b)), 60000);
  await a.ctx.close(); await b.ctx.close();
});

test("a pairing that never opens goes back to waiting and links on the next, no press", { skip, timeout: 180000 }, async () => {
  web ??= await serveWeb();
  if (!signal) await startSignal();
  browser ??= await launch();
  // A's first socket to send a description sends none: that pairing can
  // never open (the friend frozen mid-pairing, as far as B can tell).
  const swallow = () => {
    const WS = window.WebSocket;
    window.WebSocket = class extends WS {
      send(d) {
        if (typeof d === "string" && d.includes('"t":"sdp"')) {
          window.__swallowing ??= this;
          if (window.__swallowing === this) return;
        }
        super.send(d);
      }
    };
  };
  const a = await player(swallow), b = await player();
  await connect(a, "REWAITE2E");
  await until(() => a.page.evaluate(() => net?.ws?.readyState === 1), "A at the server", 10000);
  await sleep(500); // its rendezvous answered: A holds the room
  await connect(b, "REWAITE2E");
  await until(async () => (await log(a)).some((t) => t.includes("back to waiting")) ||
                          (await log(b)).some((t) => t.includes("back to waiting")),
    "a side back to waiting after the 20 s deadline", 40000);
  await until(async () => (await linked(a)) && (await linked(b)),
    async () => "both linked: A " + (await status(a)) + " / B " + (await status(b)), 60000);
  const errors = [await status(a), await status(b)].filter((t) => /peer-to-peer|left|in use/.test(t));
  assert.deepEqual(errors, [], "nobody was shown an error");
  await a.ctx.close(); await b.ctx.close();
});
