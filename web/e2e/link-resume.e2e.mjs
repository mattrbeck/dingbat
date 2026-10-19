// A dropped connection resumes: two players link through the real signaling
// server and real WebRTC, then one side's peer connection dies with no BYE
// (as a crash, a suspended phone or a network hop look to the other side).
// Both show "Reconnecting…", rendezvous on the retry code the host dealt at
// the start, open a new connection, swap RESUME and play on. Both press
// scripted buttons (the test ROM counts frames with A held, so any input
// lost or doubled in the resend changes the game) and stop at the same
// frame: every core on both sides must then be byte-identical.
// A deliberate end (Disconnect) sends BYE: no redial, the friend is told.
//
//   node --test e2e/link-resume.e2e.mjs      # from web/, after the wasm build
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
// A server per test: every page here shares one address, and the server's
// per-address rendezvous rate (10 a minute) counts the redials too.
let signalPort = 0;

let web = null, signal = null, browser = null;
after(async () => {
  await browser?.close();
  signal?.kill();
  web?.close();
});

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
  await page.goto(web.url + "?signal=ws://127.0.0.1:" + signalPort);
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
  await page.evaluate(() => {
    window.__toasts = [];
    new MutationObserver((ms) => {
      for (const m of ms) for (const n of m.addedNodes) if (n.textContent) window.__toasts.push(n.textContent);
    }).observe(document.getElementById("toast"), { childList: true });
  });
  return { ctx, page };
};

const connect = async ({ page }, code) => {
  await page.evaluate(() => document.getElementById("net-connect").click());
  await page.locator("#net-code-input").fill(code);
  await page.locator("#net-join-go").click();
};

let codes = 0;
const pair = async () => {
  web ??= await serveWeb();
  signal?.kill();
  signalPort = 20000 + Math.floor(Math.random() * 20000);
  signal = spawn(process.execPath, [join(WEB, "signaling/server.js"), String(signalPort)], { stdio: "ignore" });
  for (let i = 0; ; i++) {
    try { await fetch(`http://127.0.0.1:${signalPort}/`); break; } catch {}
    if (i > 100) throw new Error("signaling server never came up");
    await sleep(50);
  }
  browser ??= await playwright.chromium.launch({ headless: true,
    args: ["--disable-features=WebRtcHideLocalIpsWithMdns", "--mute-audio"] });
  const code = "RESUMEE2E" + ++codes;
  const a = await player(), b = await player();
  await connect(a, code);
  await until(() => a.page.evaluate(() => net?.ws?.readyState === 1), "A at the server", 10000);
  await sleep(500);
  await connect(b, code);
  await until(async () => (await linked(a)) && (await linked(b)), "both linked", 60000);
  await until(async () => (await a.page.evaluate(() => net.rb.resumeOk)) &&
                          (await b.page.evaluate(() => net.rb.resumeOk)), "both know the retry code", 5000);
  return { a, b, done: async () => { await a.ctx.close(); await b.ctx.close(); } };
};

const linked = (p) => p.page.evaluate(() => !!net?.started && rollbackMode);
const netLog = (p) => p.page.evaluate(() =>
  [...document.querySelectorAll("#log-entries p")].map((e) => e.textContent).filter((t) => t.includes("netplay")));
const toasts = (p) => p.page.evaluate(() => window.__toasts);
const cardTitle = (p) => p.page.evaluate(() =>
  document.getElementById("net-away").hidden ? "" : document.getElementById("net-away-title").textContent);

// Scripted buttons by frame (A on a per-side rhythm) and a stop at `stop`.
const script = ({ page }, stop, every) => page.evaluate(([stop, every]) => {
  const tick = Module._rollback_tick;
  Module._rollback_tick = () => {
    const h = Module._rollback_head();
    if (h >= stop) return -1;
    localButtons = ((h / every) | 0) % 2 ? 1 << 4 : 0;
    return tick(localButtons);
  };
}, [stop, every]);

const dumps = ({ page }) => page.evaluate(() => {
  const fnv = (b) => { let h = 0x811c9dc5 >>> 0; for (const x of b) h = Math.imul(h ^ x, 0x01000193) >>> 0; return h.toString(16); };
  const out = [];
  for (let p = 0; p < 2; p++) {
    const n = Module._rollback_dump_size(p);
    out.push(n + ":" + fnv(new Uint8Array(Module.memory.buffer, Module._rollback_dump_data(), n)));
  }
  return `head=${Module._rollback_head()} confirmed=${Module._rollback_confirmed()} p0=${out[0]} p1=${out[1]}`;
});

test("a dropped connection redials on the retry code, resumes, and both games stay identical",
     { skip, timeout: 180000 }, async () => {
  const { a, b, done } = await pair();
  const stop = (await a.page.evaluate(() => Module._rollback_head())) + 900;
  await script(a, stop, 23);
  await script(b, stop, 37);
  await sleep(2000);

  // B's connection dies, no BYE.
  await b.page.evaluate(() => net.pc.close());
  await until(async () => (await cardTitle(a)) === "Reconnecting…", "A's reconnecting card", 15000);
  await until(async () => (await netLog(a)).some((t) => t.includes("resumed after")) &&
                          (await netLog(b)).some((t) => t.includes("resumed after")),
    async () => "both resumed: A " + (await netLog(a)).slice(-4).join(" | ") + " // B " + (await netLog(b)).slice(-4).join(" | "),
    60000);
  assert.ok((await toasts(a)).includes("Reconnected — link resumed"));
  assert.equal(await cardTitle(a), "", "A's card gone");
  assert.equal(await cardTitle(b), "", "B's card gone");

  // Both play on to the stop with every input in; the cores must match.
  for (const p of [a, b]) {
    await until(() => p.page.evaluate((s) => Module._rollback_head() >= s && Module._rollback_confirmed() === s - 1, stop),
      "at the stop", 60000);
  }
  const da = await dumps(a), db = await dumps(b);
  console.log("  A " + da + "\n  B " + db);
  assert.equal(da, db, "both players' cores identical on both sides");
  assert.ok((await linked(a)) && (await linked(b)));
  await done();
});

test("inputs lost in flight when the connection died are resent on resume",
     { skip, timeout: 180000 }, async () => {
  const { a, b, done } = await pair();
  const stop = (await a.page.evaluate(() => Module._rollback_head())) + 900;
  await script(a, stop, 23);
  await script(b, stop, 37);
  await sleep(2000);
  // B's last inputs never reach A (lost with the dying connection), then it dies.
  await b.page.evaluate(() => {
    const dc = net.dc, send = dc.send.bind(dc);
    dc.send = (buf) => { if (new Uint8Array(buf)[0] !== 1) send(buf); };
  });
  await sleep(500);
  await b.page.evaluate(() => net.pc.close());
  await until(async () => (await netLog(a)).some((t) => t.includes("resumed after")) &&
                          (await netLog(b)).some((t) => t.includes("resumed after")), "both resumed", 60000);
  const resent = (await netLog(b)).find((t) => t.includes("resumed after"));
  console.log("  B: " + resent);
  assert.match(resent, /resent [1-9]\d* inputs/, "B resent the inputs A never got");
  for (const p of [a, b]) {
    await until(() => p.page.evaluate((s) => Module._rollback_head() >= s && Module._rollback_confirmed() === s - 1, stop),
      "at the stop", 60000);
  }
  const da = await dumps(a), db = await dumps(b);
  console.log("  A " + da + "\n  B " + db);
  assert.equal(da, db, "both players' cores identical on both sides");
  await done();
});

test("a deliberate Disconnect sends BYE: the friend is told, no redial", { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await a.page.evaluate(() => document.getElementById("rb-disconnect").click());
  await a.page.evaluate(() => document.getElementById("rb-disconnect").click());
  await until(async () => !(await linked(b)), "B's session ended", 10000);
  assert.ok((await toasts(b)).some((t) => t.startsWith("Peer disconnected")), (await toasts(b)).join(" | "));
  assert.ok(!(await netLog(b)).some((t) => t.includes("redialing")), "B didn't redial");
  await done();
});

test("a friend that never comes back: the session waits, redialing", { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  // B vanishes for good (its page closes without a BYE: a crash).
  await b.page.evaluate(() => { net.dc.send = () => {}; net.pc.close(); window.onpagehide = null; });
  await b.ctx.close();
  await until(async () => (await cardTitle(a)) === "Reconnecting…", "A's reconnecting card", 15000);
  assert.ok(await linked(a), "A keeps the session while redialing");
  await done();
});
