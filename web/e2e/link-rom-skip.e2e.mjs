// Two different games linked online (each side runs both): a ROM crosses the
// wire only when the friend does not already have it. A side whose library
// holds the friend's exact ROM answers have-rom and boots from its own copy;
// the other still sends its game across. Against a build from before the
// answer (simulated by cutting the hello back to 9 bytes and dropping the
// answers), both ROMs go over as they always did. In every case both pages
// must then hold byte-identical states for both players at the same frame.
//
//   node --test e2e/link-rom-skip.e2e.mjs     # from web/, after the wasm build
//
// Chromium with mDNS off, as link-pairing.e2e.mjs, for the same reason.

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, sleep, WEB } from "./devices.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;
const SIGNAL_PORT = 8795;
const ROMS = join(WEB, "../tests/roms");
const X = { name: "linktest.gba", bytes: readFileSync(join(ROMS, "linktest.gba")) };
const Y = { name: "gbaedge.gba", bytes: readFileSync(join(ROMS, "gbaedge.gba")) };
const STOP = 240;

let web = null, signal = null, browser = null;
after(async () => {
  await browser?.close();
  signal?.kill("SIGKILL");
  web?.close();
});

const setup = async () => {
  web ??= await serveWeb();
  if (!signal) {
    signal = spawn(process.execPath, [join(WEB, "signaling/server.js"), String(SIGNAL_PORT)], { stdio: "ignore" });
    for (let i = 0; ; i++) {
      try { await fetch(`http://127.0.0.1:${SIGNAL_PORT}/`); break; } catch {}
      if (i > 100) throw new Error("signaling server never came up");
      await sleep(50);
    }
  }
  browser ??= await playwright.chromium.launch({ headless: true,
    args: ["--disable-features=WebRtcHideLocalIpsWithMdns"] });
};

const until = async (cond, what, ms) => {
  const end = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > end) assert.fail("timed out waiting for " + (typeof what === "function" ? await what() : what));
    await sleep(100);
  }
};

// A build from before the answer: its hello is the first 9 bytes, it never
// sends have/need, and it reads a friend's hello as 9 bytes too.
const OLD_BUILD = () => {
  const cut = (d) => {
    const u = d instanceof ArrayBuffer ? new Uint8Array(d) : ArrayBuffer.isView(d) ? new Uint8Array(d.buffer, d.byteOffset, d.byteLength) : null;
    if (!u || !u.length) return d;
    if (u[0] === 9 || u[0] === 10) return null;
    if (u[0] === 0 && u.length > 9) return u.slice(0, 9).buffer;
    return d;
  };
  const send = RTCDataChannel.prototype.send;
  RTCDataChannel.prototype.send = function (d) { const c = cut(d); if (c !== null) send.call(this, c); };
  const desc = Object.getOwnPropertyDescriptor(RTCDataChannel.prototype, "onmessage");
  Object.defineProperty(RTCDataChannel.prototype, "onmessage", {
    configurable: true,
    get() { return desc.get.call(this); },
    set(h) {
      desc.set.call(this, h && ((e) => {
        const c = cut(e.data);
        if (c !== null) h.call(this, c === e.data ? e : new MessageEvent("message", { data: c }));
      }));
    },
  });
};

const addGame = async (page, game) => {
  const [chooser] = await Promise.all([page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
  await chooser.setFiles({ name: game.name, mimeType: "application/octet-stream", buffer: game.bytes });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused, null, { timeout: 30000 });
};

// One player: its own context, `library` added in turn (the last one left
// running), and the session ticking to STOP under scripted buttons.
const player = async (library, initScript) => {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 } });
  const page = await ctx.newPage();
  if (initScript) await page.addInitScript(initScript);
  await page.goto(web.url + "?signal=ws://127.0.0.1:" + SIGNAL_PORT);
  await page.waitForFunction(() => typeof Module !== "undefined" && runtimeReady &&
    typeof db !== "undefined" && !!db, null, { timeout: 60000 });
  await page.evaluate(() => dbPut(THUMBS_OFFER_KEY, Date.now()));
  await sleep(500);
  for (const [i, game] of library.entries()) {
    if (i > 0) {
      await page.evaluate(() => document.getElementById("main-menu").click());
      await page.waitForFunction(() => !document.body.classList.contains("running"), null, { timeout: 10000 });
    }
    await addGame(page, game);
  }
  await page.evaluate((stop) => {
    const tick = Module._rollback_tick;
    Module._rollback_tick = () => {
      const h = Module._rollback_head();
      if (h >= stop) return -1;
      localButtons = ((h / 29) | 0) % 2 ? 1 << 4 : ((h / 41) | 0) % 2 ? 1 << 7 : 0;
      return tick(localButtons);
    };
  }, STOP);
  return { ctx, page };
};

const connect = async ({ page }, code) => {
  await page.evaluate(() => document.getElementById("net-connect").click());
  await page.locator("#net-code-input").fill(code);
  await page.locator("#net-join-go").click();
};

const status = (p) => p.page.evaluate(() => document.getElementById("net-status").textContent);
const transfer = (p) => p.page.evaluate(() => ({
  sent: net.rb.friendHasRom ? 0 : net.rb.romSent, got: net.rb.romFromLibrary ? 0 : net.rb.romGot,
  fromLibrary: net.rb.romFromLibrary, friendHas: net.rb.friendHasRom }));
const dump = (p) => p.page.evaluate(() => {
  const fnv = (b) => { let h = 0x811c9dc5; for (const x of b) h = Math.imul(h ^ x, 0x01000193) >>> 0; return h; };
  const out = [Module._rollback_head(), Module._rollback_confirmed()];
  for (let i = 0; i < 2; i++) {
    const n = Module._rollback_dump_size(i);
    out.push(n + ":" + fnv(new Uint8Array(Module.memory.buffer, Module._rollback_dump_data(), n)).toString(16));
  }
  return out.join(" ");
});

// A hosts on `code`, B joins; both run to STOP with every input in.
const link = async (a, b, code) => {
  await connect(a, code);
  await until(() => a.page.evaluate(() => net?.ws?.readyState === 1), "A at the server", 10000);
  await sleep(500);
  await connect(b, code);
  // Stopped at STOP, a side that got the friend's last inputs before its
  // head reached them confirms them only on another arrival (main's tick
  // does not reconcile): an input for a frame never simulated is that
  // arrival, and changes nothing up to STOP.
  const done = (p) => p.page.evaluate((stop) => {
    if (!net?.started || Module._rollback_head() < stop) return false;
    if (Module._rollback_confirmed() < stop - 1) Module._rollback_feed(stop + 60, 0);
    return Module._rollback_confirmed() === stop - 1;
  }, STOP);
  await until(async () => (await done(a)) && (await done(b)),
    async () => "both at the stop: A " + (await status(a)) + " / B " + (await status(b)) +
      " | " + JSON.stringify(await Promise.all([a, b].map((p) => p.page.evaluate(() => {
        const r = net?.rb; if (!r) return null;
        return { needRom: r.needRom, inited: r.inited, localReady: r.localReady, remoteReady: r.remoteReady,
                 started: net.started, romSent: r.romSent, romGot: r.romGot, remoteRom: !!r.remoteRom, head: Module._rollback_head() };
      })))), 90000);
  const [da, db_] = [await dump(a), await dump(b)];
  assert.equal(da, db_, "both players' cores identical on both sides");
};

test("a friend who has your game is not sent it", { skip, timeout: 180000 }, async () => {
  await setup();
  const a = await player([X]);        // A plays X
  const b = await player([X, Y]);     // B has X too, and plays Y
  await link(a, b, "SKIPE2E");
  const [ta, tb] = [await transfer(a), await transfer(b)];
  assert.deepEqual([ta.friendHas, ta.sent], [true, 0], "A sent nothing: B already had X");
  assert.deepEqual([tb.fromLibrary, tb.got], [true, 0], "B booted X from its own library");
  assert.equal(ta.got, Y.bytes.length, "A, without Y, was sent it");
  await a.ctx.close(); await b.ctx.close();
});

test("without the friend's game, both ROMs are sent", { skip, timeout: 180000 }, async () => {
  await setup();
  const a = await player([X]), b = await player([Y]);
  await link(a, b, "BOTHE2E");
  const [ta, tb] = [await transfer(a), await transfer(b)];
  assert.deepEqual([ta.got, tb.got], [Y.bytes.length, X.bytes.length], "each got the other's game");
  assert.ok(!ta.fromLibrary && !tb.fromLibrary && !ta.friendHas && !tb.friendHas);
  await a.ctx.close(); await b.ctx.close();
});

test("when each has the other's game, no ROM crosses at all", { skip, timeout: 180000 }, async () => {
  await setup();
  const a = await player([Y, X]), b = await player([X, Y]);
  await link(a, b, "NONEE2E");
  const [ta, tb] = [await transfer(a), await transfer(b)];
  assert.deepEqual([ta.fromLibrary, ta.friendHas, tb.fromLibrary, tb.friendHas], [true, true, true, true]);
  assert.deepEqual([ta.sent, ta.got, tb.sent, tb.got], [0, 0, 0, 0], "nothing sent either way");
  await a.ctx.close(); await b.ctx.close();
});

test("an older build gets the ROM as before, and sends its own", { skip, timeout: 180000 }, async () => {
  await setup();
  const a = await player([X]);
  const b = await player([X, Y], OLD_BUILD); // has X, but cannot say so
  await link(a, b, "OLDE2E");
  const [ta, tb] = [await transfer(a), await transfer(b)];
  assert.deepEqual([ta.got, tb.got], [Y.bytes.length, X.bytes.length], "both games crossed the wire");
  assert.ok(!ta.friendHas && !tb.fromLibrary);
  await a.ctx.close(); await b.ctx.close();
});
