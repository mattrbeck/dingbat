// Sync checks on a live link with the real core (netplay.js "Sync checks",
// rollback.nim syncEvery): two players in one browser link over the
// same-browser path, play scripted buttons, and their fingerprints cross
// every 120 frames and agree. Then one side's copy of the friend's game is
// set back to an earlier moment (a divergence no input explains): the next
// fingerprints differ, both stop at one frame, swap their own games, start
// over from them, and from then on agree; at a stop every core on both
// sides is byte-identical. Prints what the checks cost here (wasm).
//
//   node --test e2e/link-sync.e2e.mjs        # from web/, after the wasm build
//   DINGBAT_SYNC_ROM=/path/game.gba node --test e2e/link-sync.e2e.mjs
//                                           # the cost with a real game too
//
// Chromium only.

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, sleep, WEB } from "./devices.mjs";
import { synctestRom, SYNCTEST_NAME } from "./synctest-rom.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;
let web = null, signal = null, browser = null, signalPort = 0;
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

const player = async (ctx, game) => {
  const page = await ctx.newPage();
  await page.goto(web.url + "?signal=ws://127.0.0.1:" + signalPort);
  await page.waitForFunction(() => typeof Module !== "undefined" && runtimeReady &&
    typeof db !== "undefined" && !!db, null, { timeout: 60000 });
  await page.evaluate(() => dbPut(THUMBS_OFFER_KEY, Date.now()));
  await sleep(500);
  const [chooser] = await Promise.all([page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
  await chooser.setFiles({ name: game.name, mimeType: "application/octet-stream", buffer: game.bytes });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused,
    null, { timeout: 30000 });
  // Every message sent, by kind, from the first: bytes and count.
  await page.evaluate(() => {
    window.__tx = {};
    window.__toasts = [];
    new MutationObserver((ms) => {
      for (const m of ms) for (const n of m.addedNodes) if (n.textContent) window.__toasts.push(n.textContent);
    }).observe(document.getElementById("toast"), { childList: true });
  });
  return { page };
};

let codes = 0;
const pair = async (game) => {
  web ??= await serveWeb();
  if (!signal) {
    signalPort = 20000 + Math.floor(Math.random() * 20000);
    signal = spawn(process.execPath, [join(WEB, "signaling/server.js"), String(signalPort)], { stdio: "ignore" });
    for (let i = 0; ; i++) {
      try { await fetch(`http://127.0.0.1:${signalPort}/`); break; } catch {}
      if (i > 100) throw new Error("signaling server never came up");
      await sleep(50);
    }
  }
  browser ??= await playwright.chromium.launch({ headless: true, args: ["--mute-audio"] });
  // One context: the two tabs share a BroadcastChannel and link through it.
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 } });
  const a = await player(ctx, game), b = await player(ctx, game);
  const code = "SYNCE2E" + ++codes;
  for (const p of [a, b]) {
    await p.page.evaluate(() => document.getElementById("net-connect").click());
    await p.page.locator("#net-code-input").fill(code);
    await p.page.locator("#net-join-go").click();
  }
  const linked = (p) => p.page.evaluate(() => !!net?.started && rollbackMode);
  await until(async () => (await linked(a)) && (await linked(b)), "both linked", 60000);
  for (const p of [a, b]) {
    await p.page.evaluate(() => {
      const dc = net.dc;
      const send = dc.send.bind(dc);
      dc.send = (b) => {
        const u = b instanceof ArrayBuffer ? new Uint8Array(b) : new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
        const k = u[0];
        const e = (window.__tx[k] ??= { n: 0, bytes: 0 });
        e.n++; e.bytes += u.length;
        return send(b);
      };
    });
  }
  return { a, b, done: () => ctx.close() };
};

// Scripted buttons by frame, a stop at `stop`, and the time of every tick.
const script = ({ page }, stop, every) => page.evaluate(([stop, every]) => {
  const tick = Module._rollback_tick;
  window.__ticks = [];
  window.__stop = stop;
  Module._rollback_tick = () => {
    const h = Module._rollback_head();
    if (h >= window.__stop) return -1;
    localButtons = ((h / every) | 0) % 2 ? 1 << 4 : 0;
    const t = performance.now();
    const f = tick(localButtons);
    if (f >= 0) window.__ticks.push([f, performance.now() - t]);
    return f;
  };
}, [stop, every]);

const stats = ({ page }) => page.evaluate(() => ({
  checks: net.rb.syncChecks, mismatches: net.rb.syncMismatches, resyncs: net.rb.resyncs,
  resyncMs: net.rb.resyncMs, peerSync: net.rb.peerSync, head: Module._rollback_head(),
  confirmed: Module._rollback_confirmed(), resync: !!net.rb.resync,
}));

const dumps = ({ page }) => page.evaluate(() => {
  const fnv = (b) => { let h = 0x811c9dc5 >>> 0; for (const x of b) h = Math.imul(h ^ x, 0x01000193) >>> 0; return h.toString(16); };
  const out = [];
  for (let p = 0; p < 2; p++) {
    const n = Module._rollback_dump_size(p);
    out.push(n + ":" + fnv(new Uint8Array(Module.memory.buffer, Module._rollback_dump_data(), n)));
  }
  return `head=${Module._rollback_head()} confirmed=${Module._rollback_confirmed()} p0=${out[0]} p1=${out[1]}`;
});

const atStop = async (p, stop) =>
  until(() => p.page.evaluate((s) => Module._rollback_head() >= s && Module._rollback_confirmed() === s - 1, stop),
    async () => "at the stop " + stop + ": " + JSON.stringify(await stats(p)) + " fps " +
      (await p.page.evaluate(() => window.__ticks.length)), 240000);

// What the checks cost, measured in the page.
const cost = async ({ page }, label) => {
  const r = await page.evaluate(() => {
    const p = Module._malloc(8);
    const reps = 40;
    const t0 = performance.now();
    for (let i = 0; i < reps; i++) Module._rollback_fingerprint_live(p);
    const fp = (performance.now() - t0) / reps;
    Module._free(p);
    const ticks = window.__ticks.map((x) => x[1]);
    const all = [...ticks].sort((x, y) => x - y);
    const q = (xs, f) => xs.length ? xs[Math.min(xs.length - 1, Math.floor(xs.length * f))] : 0;
    const packed = Module._rollback_dump_packed(net.rb.localPlayer);
    // A fingerprint runs inside whichever tick or input makes its frame final.
    return { fp, med: q(all, 0.5), p99: q(all, 0.99), max: all.length ? all[all.length - 1] : 0, n: ticks.length,
             packedKB: packed / 1024, tx: window.__tx };
  });
  const kb = (k) => r.tx[k] ? `${r.tx[k].n} msgs, ${(r.tx[k].bytes / 1024).toFixed(1)} KB` : "0";
  console.log(`  ${label}: fingerprint ${r.fp.toFixed(2)} ms in wasm; tick median ${r.med.toFixed(2)} ms, ` +
    `p99 ${r.p99.toFixed(2)} ms, slowest ${r.max.toFixed(2)} ms (${r.n} ticks); ` +
    `re-sync state ${r.packedKB.toFixed(1)} KB packed`);
  console.log(`    sent: inputs ${kb(1)}; sync ${kb(16)}; resync ${kb(17)} + state ${kb(18)}/${kb(19)}`);
  return r;
};

const synctest = { name: SYNCTEST_NAME, bytes: Buffer.from(synctestRom()) };

test("in step: fingerprints cross and agree, nothing more is sent, at a cost measured here",
     { skip, timeout: 240000 }, async () => {
  const { a, b, done } = await pair(synctest);
  const stop = (await a.page.evaluate(() => Module._rollback_head())) + 1200;
  await script(a, stop, 23);
  await script(b, stop, 37);
  await atStop(a, stop);
  await atStop(b, stop);
  const sa = await stats(a), sb = await stats(b);
  console.log("  A", JSON.stringify(sa), "\n  B", JSON.stringify(sb));
  assert.ok(sa.peerSync && sb.peerSync, "both HELLOs say they check");
  assert.ok(sa.checks >= 8 && sb.checks >= 8, "compared every 120 frames");
  assert.equal(sa.mismatches + sb.mismatches, 0);
  assert.equal(await dumps(a), await dumps(b), "every core identical on both sides");
  const r = await cost(a, "synctest.gb (GB)");
  assert.equal(r.tx[17], undefined, "no re-sync");
  await done();
});

test("a copy set back to an earlier moment is caught, re-synced, and both agree after",
     { skip, timeout: 240000 }, async () => {
  const { a, b, done } = await pair(synctest);
  const start = await a.page.evaluate(() => Module._rollback_head());
  const stop = start + 1500;
  await script(a, stop, 23);
  await script(b, stop, 37);
  // A's copy of B's game, saved now and loaded back later: it goes back in time.
  await sleep(1500);
  await a.page.evaluate(() => {
    const remote = 1 - net.rb.localPlayer;
    const n = Module._rollback_dump_size(remote);
    window.__old = new Uint8Array(Module.memory.buffer, Module._rollback_dump_data(), n).slice();
  });
  await sleep(2500);
  await a.page.evaluate(() => {
    const remote = 1 - net.rb.localPlayer;
    const p = Module._malloc(window.__old.length);
    new Uint8Array(Module.memory.buffer, p, window.__old.length).set(window.__old);
    Module._rollback_load_state(remote, p, window.__old.length);
    Module._free(p);
  });
  await until(async () => (await stats(a)).resyncs >= 1 && (await stats(b)).resyncs >= 1,
    async () => "a re-sync: " + JSON.stringify(await stats(a)) + " / " + JSON.stringify(await stats(b)), 60000);
  // The engine restarted at frame 0: a stop well past the new frames.
  for (const p of [a, b]) await p.page.evaluate(() => { window.__stop = Module._rollback_head() + 600; });
  const s2 = Math.max(await a.page.evaluate(() => window.__stop), await b.page.evaluate(() => window.__stop));
  for (const p of [a, b]) await p.page.evaluate((s) => { window.__stop = s; }, s2);
  await atStop(a, s2);
  await atStop(b, s2);
  const sa = await stats(a), sb = await stats(b);
  console.log("  A", JSON.stringify(sa), "\n  B", JSON.stringify(sb));
  assert.equal(sa.mismatches, 1, "A saw it once");
  assert.equal(sb.mismatches, 1, "B saw it once");
  assert.equal(sa.resyncs, 1);
  assert.ok(sa.checks >= 2, "checks carried on after, and agreed");
  assert.equal(await dumps(a), await dumps(b), "every core identical on both sides after the re-sync");
  const r = await cost(a, "synctest.gb after a re-sync");
  console.log(`    re-sync took ${sa.resyncMs[0]} ms on A, ${sb.resyncMs[0]} ms on B (proposal to restart)`);
  assert.ok(r.tx[18] && r.tx[19], "A sent its game");
  await done();
});

const romPath = process.env.DINGBAT_SYNC_ROM;
test("the cost with a real game", { skip: skip || (!romPath && "DINGBAT_SYNC_ROM not set"), timeout: 300000 }, async () => {
  const game = { name: basename(romPath), bytes: readFileSync(romPath) };
  const { a, b, done } = await pair(game);
  const stop = (await a.page.evaluate(() => Module._rollback_head())) + 1800;
  await script(a, stop, 23);
  await script(b, stop, 37);
  await atStop(a, stop);
  await atStop(b, stop);
  const sa = await stats(a);
  assert.equal(sa.mismatches, 0);
  assert.equal(await dumps(a), await dumps(b));
  await cost(a, game.name);
  // The same stretch again with the checks off, for the difference.
  await a.page.evaluate(() => Module._rollback_set_sync_every(0));
  await b.page.evaluate(() => Module._rollback_set_sync_every(0));
  const stop2 = stop + 1800;
  await a.page.evaluate((s) => { window.__ticks = []; window.__stop = s; }, stop2);
  await b.page.evaluate((s) => { window.__stop = s; }, stop2);
  await atStop(a, stop2);
  await atStop(b, stop2);
  await cost(a, game.name + " with the checks off");
  await done();
});
