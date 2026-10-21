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
const pair = async ({ before } = {}) => {
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
  if (before) await before(a);
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

  // And again, from the other side, on the redialed connection.
  await sleep(1500);
  await a.page.evaluate(() => net.pc.close());
  await until(async () => (await netLog(a)).filter((t) => t.includes("resumed after")).length >= 2 &&
                          (await netLog(b)).filter((t) => t.includes("resumed after")).length >= 2,
    "both resumed a second time", 60000);

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
  await b.page.evaluate(() => { net.dc.send = () => {}; net.pc.close(); });
  await b.ctx.close();
  await until(async () => (await cardTitle(a)) === "Reconnecting…", "A's reconnecting card", 15000);
  assert.ok(await linked(a), "A keeps the session while redialing");
  await done();
});

test("a redialed channel that dies before the friend's RESUME dials again (no dead end)",
     { skip, timeout: 180000 }, async () => {
  const { a, b, done } = await pair();
  const stop = (await a.page.evaluate(() => Module._rollback_head())) + 900;
  await script(a, stop, 23);
  await script(b, stop, 37);
  await sleep(1500);
  // B's first redialed channel dies the moment it would say RESUME.
  await b.page.evaluate(() => {
    const send = RTCDataChannel.prototype.send;
    let killed = false;
    RTCDataChannel.prototype.send = function (buf) {
      const kind = buf instanceof ArrayBuffer ? new Uint8Array(buf)[0] : buf?.[0];
      if (kind === 13 && !killed) { killed = true; this.close(); return; }
      return send.call(this, buf);
    };
  });
  await b.page.evaluate(() => net.pc.close());
  await until(async () => (await netLog(a)).some((t) => t.includes("resumed after")) &&
                          (await netLog(b)).some((t) => t.includes("resumed after")),
    async () => "both resumed: A " + (await netLog(a)).slice(-6).join(" | ") + " // B " + (await netLog(b)).slice(-6).join(" | "),
    90000);
  const dials = (await netLog(a)).filter((t) => t.includes("redial: paired")).length;
  assert.ok(dials >= 2, "A paired twice (the first channel died): " + dials);
  for (const p of [a, b]) {
    await until(() => p.page.evaluate((s) => Module._rollback_head() >= s && Module._rollback_confirmed() === s - 1, stop),
      "at the stop", 60000);
  }
  assert.equal(await dumps(a), await dumps(b), "both players' cores identical on both sides");
  await done();
});

test("Disconnect while reconnecting: this side plays on solo, the friend gives up and does too",
     { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await b.page.evaluate(() => { rbResumeGiveUpMs = 8000; });
  // B's redials can't get through to the server.
  await b.page.evaluate(() => { window.WebSocket = class { constructor() { throw new Error("offline"); } }; });
  await a.page.evaluate(() => net.pc.close());
  await until(async () => (await cardTitle(a)) === "Reconnecting…", "A reconnecting", 15000);
  await a.page.click("#net-away-disconnect");
  await a.page.click("#net-away-disconnect");
  await until(async () => !(await linked(a)), "A ended it", 5000);
  assert.ok((await toasts(a)).includes("Disconnected"));
  assert.ok(!(await a.page.evaluate(() => rollbackMode || paused)), "A plays on solo");
  await until(async () => !(await linked(b)), "B gave up", 20000);
  assert.ok((await toasts(b)).some((t) => t.startsWith("Couldn't reconnect")), (await toasts(b)).join(" | "));
  assert.ok(!(await b.page.evaluate(() => rollbackMode)), "B plays on solo");
  await done();
});

// The goodbye note (POST /bye on the retry code): a side that ends while
// the link is down tells a redialing friend through the server, instead of
// leaving it on "Reconnecting…" until its 180 s give-up. A's redials can't
// reach the server here, so B is left waiting on the code.
const strandA = async (a) => {
  await a.page.evaluate(() => { window.WebSocket = class { constructor() { throw new Error("offline"); } }; });
  await a.page.evaluate(() => net.pc.close());
};
const waitingOnCode = (p) => netLog(p).then((l) => l.some((t) => t.includes("redial: waiting for the friend")));

test("Disconnect while reconnecting is heard: the friend's redial gets the goodbye",
     { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await strandA(a);
  await until(async () => (await cardTitle(a)) === "Reconnecting…", "A reconnecting", 15000);
  await until(() => waitingOnCode(b), "B waiting on the retry code", 20000);
  const t0 = Date.now();
  await a.page.click("#net-away-disconnect");
  await a.page.click("#net-away-disconnect");
  await until(async () => !(await linked(b)), "B told", 10000);
  assert.ok(Date.now() - t0 < 10000, "well inside B's 180 s give-up");
  assert.ok((await toasts(b)).some((t) => t.startsWith("Peer disconnected")), (await toasts(b)).join(" | "));
  assert.ok((await netLog(b)).some((t) => t.includes("redial: the friend left")), (await netLog(b)).join(" | "));
  assert.ok((await netLog(a)).some((t) => t.includes("goodbye note on the retry code (left)")));
  assert.ok(!(await b.page.evaluate(() => rollbackMode)), "B plays on solo");
  await done();
});

test("closing the tab while reconnecting is heard too (the note is a beacon)",
     { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await strandA(a);
  await until(async () => (await cardTitle(a)) === "Reconnecting…", "A reconnecting", 15000);
  await until(() => waitingOnCode(b), "B waiting on the retry code", 20000);
  await a.page.close({ runBeforeUnload: true });
  await until(async () => !(await linked(b)), "B told", 10000);
  assert.ok((await toasts(b)).some((t) => t.startsWith("Peer disconnected")), (await toasts(b)).join(" | "));
  await done();
});

test("a friend's give-up is heard: \"Couldn't reconnect\" at once, not 3 minutes later",
     { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await a.page.evaluate(() => { rbResumeGiveUpMs = 6000; });
  await strandA(a);
  await until(() => waitingOnCode(b), "B waiting on the retry code", 20000);
  await until(async () => !(await linked(a)), "A gave up", 15000);
  await until(async () => !(await linked(b)), "B told", 10000);
  assert.ok((await toasts(b)).some((t) => t.startsWith("Couldn't reconnect")), (await toasts(b)).join(" | "));
  assert.ok((await netLog(b)).some((t) => t.includes("redial: the friend gave up")), (await netLog(b)).join(" | "));
  await done();
});

// A give-up just after the new channel opened says BYE on it; the BYE says
// why, so the friend that just resumed reads "Couldn't reconnect" too, not
// "Peer disconnected" (formal/WebState/LinkResume.lean
// give_up_reads_as_disconnect, bye_reason_heard). A never takes B's RESUME
// here, so it stays redialing with the channel open until its give-up.
test("a give-up after the new channel opened reads as one on the friend's side",
     { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await a.page.evaluate(() => {
    rbResumeGiveUpMs = 8000;
    const d = Object.getOwnPropertyDescriptor(RTCDataChannel.prototype, "onmessage");
    Object.defineProperty(RTCDataChannel.prototype, "onmessage", {
      configurable: true, get: d.get,
      set(fn) {
        d.set.call(this, fn && ((e) => {
          if (e.data instanceof ArrayBuffer && new Uint8Array(e.data)[0] === 13) return;
          return fn(e);
        }));
      },
    });
  });
  await a.page.evaluate(() => net.pc.close());
  await until(async () => (await netLog(b)).some((t) => t.includes("resumed after")), "B resumed on A's RESUME", 20000);
  await until(async () => !(await linked(a)), "A gave up", 15000);
  await until(async () => !(await linked(b)), "B told", 5000);
  assert.ok((await toasts(b)).some((t) => t.startsWith("Couldn't reconnect")), (await toasts(b)).join(" | "));
  assert.ok(!(await toasts(b)).some((t) => t.startsWith("Peer disconnected")), (await toasts(b)).join(" | "));
  assert.ok(!(await netLog(b)).some((t) => t.includes("redial: the friend gave up")), "by the BYE, not the note");
  await done();
});

// A page killed outright runs nothing (no BYE, no note). The tab kept the
// session's retry code in sessionStorage, and its next load leaves the
// goodbye the killed page couldn't (LinkResume.lean regress_kill_heard_on_relaunch).
// The kill: the session is detached, so A's unload handlers find nothing to
// end (Chrome runs them whatever a capture listener does), then the tab reloads.
test("a page killed mid-session leaves its goodbye at the tab's next load",
     { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  const live = await a.page.evaluate(() => JSON.parse(sessionStorage.getItem("dingbat-link-live")));
  assert.equal(live.code, await a.page.evaluate(() => net.rb.resume.code));
  await a.page.evaluate(() => { window.__killed = net; net = null; });
  const t0 = Date.now();
  await a.page.reload();
  await until(async () => !(await linked(b)), "B told", 30000);
  console.log(`  told in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  assert.ok((await toasts(b)).some((t) => t.startsWith("Peer disconnected")), (await toasts(b)).join(" | "));
  assert.ok((await netLog(b)).some((t) => t.includes("redial: the friend left")),
    "by the goodbye note, while redialing: " + (await netLog(b)).slice(-4).join(" | "));
  assert.ok(await a.page.evaluate(() => [...document.querySelectorAll("#log-entries p")]
    .some((e) => e.textContent.includes("the last session here never ended"))), "A's new page left the goodbye");
  assert.equal(await a.page.evaluate(() => sessionStorage.getItem("dingbat-link-live")), null);
  await done();
});

// While redialing the game is held: Pause and 2x are off and the game's
// buttons go nowhere (a press there used to be undone by the reconnect,
// LinkResume.lean pause_in_drop_undone); both come back once resumed.
test("while reconnecting the game holds: Pause and 2x are off, then back", { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  // A's server is out of reach for a few seconds, so the redial is visible.
  await a.page.evaluate(() => {
    const WS = window.WebSocket;
    window.WebSocket = class { constructor() { throw new Error("offline"); } };
    setTimeout(() => { window.WebSocket = WS; }, 6000);
    net.pc.close();
  });
  await until(async () => (await cardTitle(a)) === "Reconnecting…", "A reconnecting", 15000);
  assert.deepEqual(await a.page.evaluate(() => [pauseButton.disabled, speed2xButton.disabled]), [true, true]);
  const head0 = await a.page.evaluate(() => Module._rollback_head());
  await a.page.keyboard.press("Space");
  await a.page.keyboard.press("Shift+Tab");
  await a.page.evaluate(() => pauseButton.click());
  await sleep(1000);
  assert.deepEqual(await a.page.evaluate(() => [paused, speed2x]), [false, false], "nothing pressed");
  assert.equal(await a.page.evaluate(() => Module._rollback_head()), head0, "the game held");
  await until(async () => (await netLog(a)).some((t) => t.includes("resumed after")), "A resumed", 30000);
  assert.deepEqual(await a.page.evaluate(() => [pauseButton.disabled, speed2xButton.disabled]), [false, false]);
  await a.page.evaluate(() => pauseButton.click());
  await until(() => b.page.evaluate(() => paused), "A's Pause reaches B again", 5000);
  await done();
});

// Parity with the iOS app: the home screen freezes the friend's game too
// (it used to leave the friend stalled on "waiting for friend"), and a
// session starts at normal speed (a 2x left on before Connect ran one side
// alone at it).
test("the home screen pauses the friend too, and Resume runs both", { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await a.page.evaluate(() => showMainMenu());
  await until(() => b.page.evaluate(() => paused), "B paused with A's home screen", 5000);
  await a.page.evaluate(() => resumeGame());
  await until(() => b.page.evaluate(() => !paused), "B running again", 5000);
  await done();
});

test("a 2x left on before Connect is off when the session starts", { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair({ before: (p) => p.page.evaluate(() => setSpeed2x(true)) });
  assert.deepEqual(await a.page.evaluate(() => [speed2x, speed2xButton.classList.contains("active")]),
    [false, false]);
  assert.equal(await b.page.evaluate(() => speed2x), false);
  await done();
});

test("a shared pause held across a drop stays shared", { skip, timeout: 120000 }, async () => {
  const { a, b, done } = await pair();
  await a.page.evaluate(() => document.getElementById("pause").click());
  await until(() => b.page.evaluate(() => paused), "the pause reached B", 5000);
  await b.page.evaluate(() => net.pc.close());
  await until(async () => (await netLog(a)).some((t) => t.includes("resumed after")) &&
                          (await netLog(b)).some((t) => t.includes("resumed after")), "both resumed", 60000);
  await sleep(500);
  assert.ok((await a.page.evaluate(() => paused)) && (await b.page.evaluate(() => paused)), "still paused on both");
  await a.page.evaluate(() => document.getElementById("pause").click());
  await until(async () => !(await b.page.evaluate(() => paused)), "resumed on B", 5000);
  const h = await a.page.evaluate(() => Module._rollback_head());
  await until(() => a.page.evaluate((h) => Module._rollback_head() > h + 60, h), "playing again", 10000);
  assert.ok((await linked(a)) && (await linked(b)));
  await done();
});
