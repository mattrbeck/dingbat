// A browser and the desktop app's online link (src/dingbat/frontend/
// online_link.nim, through its headless player tests/online_peer.nim) link
// online: each side runs both players' cores, the wasm core in the page and
// the native one in the peer, so both pages of state must come out
// byte-identical at the same frame, whichever side hosts. A Game Boy pair
// and a cross-game pair (each ROM crosses) too.
//
//   ONLINE_PEER_BIN=path node --test e2e/link-native.e2e.mjs   # from web/
//
// Build the peer with
//   nim c -d:release -d:test_harness --path:src -o:online_peer tests/online_peer.nim
// Chromium with mDNS off, as link-pairing.e2e.mjs, for the same reason.

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, sleep, WEB } from "./devices.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const PEER = process.env.ONLINE_PEER_BIN;
const skip = !builtWeb() ? "web/em.wasm not built"
  : !PEER ? "ONLINE_PEER_BIN not set (tests/online_peer.nim)" : false;
const SIGNAL_PORT = 8796;
const ROMS = join(WEB, "../tests/roms");
const STOP = 600;

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

const page_player = async (game) => {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 } });
  const page = await ctx.newPage();
  await page.goto(web.url + "?signal=ws://127.0.0.1:" + SIGNAL_PORT);
  await page.waitForFunction(() => typeof Module !== "undefined" && runtimeReady &&
    typeof db !== "undefined" && !!db, null, { timeout: 60000 });
  await page.evaluate(() => dbPut(THUMBS_OFFER_KEY, Date.now()));
  await sleep(500);
  const [chooser] = await Promise.all([page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
  await chooser.setFiles({ name: game.name, mimeType: "application/octet-stream", buffer: game.bytes });
  await page.waitForFunction(() => document.body.classList.contains("running") && !paused, null, { timeout: 30000 });
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

const dump = (page) => page.evaluate(() => {
  const fnv = (b) => { let h = 0x811c9dc5; for (const x of b) h = Math.imul(h ^ x, 0x01000193) >>> 0; return h; };
  const out = [Module._rollback_head(), Module._rollback_confirmed()];
  for (let i = 0; i < 2; i++) {
    const n = Module._rollback_dump_size(i);
    out.push(n + ":" + fnv(new Uint8Array(Module.memory.buffer, Module._rollback_dump_data(), n)).toString(16));
  }
  return out.join(" ");
});

const run_peer = (rom, code) => {
  const p = spawn(PEER, [rom, code, `--signal=ws://127.0.0.1:${SIGNAL_PORT}`, `--frames=${STOP}`,
    "--warmup=20", "--timeout=120"], { stdio: ["ignore", "pipe", "pipe"] });
  let out = "";
  p.stdout.on("data", (d) => { out += d; });
  p.stderr.on("data", (d) => { out += d; });
  const done = new Promise((res) => p.on("exit", (rc) => res(rc)));
  return { p, log: () => out, done };
};

// The page and the native peer on `code`; `peer_first` picks who hosts.
const link = async (page_game, peer_rom, code, peer_first) => {
  await setup();
  const pl = await page_player(page_game);
  let peer = null;
  if (peer_first) { peer = run_peer(peer_rom, code); await sleep(1500); }
  await pl.page.evaluate(() => document.getElementById("net-connect").click());
  await pl.page.locator("#net-code-input").fill(code);
  await pl.page.locator("#net-join-go").click();
  if (!peer_first) { await sleep(1500); peer = run_peer(peer_rom, code); }
  const done = () => pl.page.evaluate((stop) => {
    if (!net?.started || Module._rollback_head() < stop) return false;
    if (Module._rollback_confirmed() < stop - 1) Module._rollback_feed(stop + 60, 0);
    return Module._rollback_confirmed() === stop - 1;
  }, STOP);
  await until(async () => (await done()) && /ONLINE DUMP/.test(peer.log()),
    async () => "both at the stop | page: " +
      (await pl.page.evaluate(() => document.getElementById("net-status")?.textContent)) +
      " | peer: " + peer.log().slice(-600), 120000);
  const page_dump = await dump(pl.page);
  const peer_dump = peer.log().match(/ONLINE DUMP (.*)/)[1].trim();
  const host = await pl.page.evaluate(() => net.isHost);
  // The page's Disconnect (two taps): the peer hears the BYE and exits.
  await pl.page.evaluate(() => document.getElementById("rb-disconnect").click());
  await pl.page.evaluate(() => document.getElementById("rb-disconnect").click());
  const rc = await Promise.race([peer.done, sleep(15000).then(() => "timeout")]);
  if (rc === "timeout") peer.p.kill("SIGKILL");
  await pl.ctx.close();
  return { page_dump, peer_dump, host, rc, log: peer.log() };
};

const GBA = { name: "attachtest.gba", bytes: readFileSync(join(ROMS, "attachtest.gba")) };
const GB = { name: "gblinktest.gb", bytes: readFileSync(join(ROMS, "gblinktest.gb")) };

test("browser hosts a native player: both sides' cores identical", { skip, timeout: 240000 }, async () => {
  const r = await link(GBA, join(ROMS, "attachtest.gba"), "NATA" + process.pid, false);
  assert.equal(r.host, true, "the page arrived first and hosts");
  assert.equal(r.page_dump, r.peer_dump, "page and native peer agree");
  assert.match(r.log, /linktest mark 0xCAFE[\s\S]*linktest mark 0xCAFE/, "link rounds done on both cores");
  assert.equal(r.rc, 0, "the peer heard the page's Disconnect and ended cleanly");
});

test("native player hosts the browser: both sides' cores identical", { skip, timeout: 240000 }, async () => {
  const r = await link(GBA, join(ROMS, "attachtest.gba"), "NATB" + process.pid, true);
  assert.equal(r.host, false, "the peer arrived first and hosts");
  assert.equal(r.page_dump, r.peer_dump, "page and native peer agree");
});

test("Game Boy: browser and native agree", { skip, timeout: 240000 }, async () => {
  const r = await link(GB, join(ROMS, "gblinktest.gb"), "NATGB" + process.pid, false);
  assert.equal(r.page_dump, r.peer_dump, "GB page and native peer agree");
});

test("cross-game: each side's ROM crosses and both agree", { skip, timeout: 240000 }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "dingbat-native-"));
  const other = join(dir, "attachtest-b.gba");
  writeFileSync(other, Buffer.concat([GBA.bytes, Buffer.from([0xff, 0xff, 0xff, 0xff])]));
  const r = await link(GBA, other, "NATX" + process.pid, false);
  assert.equal(r.page_dump, r.peer_dump, "cross-game page and native peer agree");
});
