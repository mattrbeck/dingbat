// A browser and the desktop app's online link (src/dingbat/frontend/
// online_link.nim, through its headless player tests/online_peer.nim) link
// online: each side runs both players' cores, the wasm core in the page and
// the native one in the peer, so both pages of state must come out
// byte-identical at the same frame, whichever side hosts. A Game Boy pair
// and a cross-game pair (each ROM crosses) too. Every pair also runs the
// sync checks (docs/dev/multiplayer.md): the wasm and native fingerprints
// must agree at every check, and a copy set back on either side must be
// caught and re-synced, the two sides identical after.
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
import { synctestRom, SYNCTEST_NAME } from "./synctest-rom.mjs";

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

const page_player = async (game, drift = 0, bios = null, stop = STOP, random = false) => {
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
  await page.evaluate(([stop, drift, random]) => {
    const tick = Module._rollback_tick;
    Module._rollback_tick = () => {
      const h = Module._rollback_head();
      // The page's copy of the friend's game, saved at drift - 150 and
      // loaded back at drift with every input in (a rollback before it
      // would undo it): it goes back in time, as no input could take it.
      if (drift && !window.__drifted && net?.rb) {
        const remote = 1 - net.rb.localPlayer;
        if (!window.__old && h >= drift - 150) {
          const n = Module._rollback_dump_size(remote);
          window.__old = new Uint8Array(Module.memory.buffer, Module._rollback_dump_data(), n).slice();
        }
        if (window.__old && h >= drift) {
          if (Module._rollback_confirmed() !== h - 1) return -1; // hold for the friend's inputs
          window.__drifted = true;
          const p = Module._malloc(window.__old.length);
          new Uint8Array(Module.memory.buffer, p, window.__old.length).set(window.__old);
          Module._rollback_load_state(remote, p, window.__old.length);
          Module._free(p);
        }
      }
      if (h >= stop) return -1;
      if (random) {
        // A new set every 8 frames, never the soft-reset chord.
        if (h % 8 === 0) {
          window.__r = (Math.imul(window.__r ?? 0x5eed, 1664525) + 1013904223) >>> 0;
          const x = window.__r;
          window.__held = (x & 3) === 0 ? 0 : (x >>> 8) & 0x3ff;
          if ((window.__held & 0xf) === 0xf) window.__held &= ~0x8;
        }
        localButtons = window.__held ?? 0;
      } else {
        localButtons = ((h / 29) | 0) % 2 ? 1 << 4 : ((h / 41) | 0) % 2 ? 1 << 7 : 0;
      }
      return tick(localButtons);
    };
  }, [stop, drift, random]);
  // A real GBA BIOS on this side only, the real-BIOS mode: the session's
  // cores must still run what the friend's do (HLE, rbBiosHle).
  if (bios) {
    await page.evaluate(([b, fallback]) => {
      writeToFS("bios.bin", new Uint8Array(b));
      Module._wasm_set_gba_bios_mode(1);
      if (!fallback) Module._rollback_set_bios_hle = () => {}; // the control: no agreement
    }, [[...bios.bytes], bios.fallback]);
  }
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

const run_peer = (rom, code, extra = [], stop = STOP) => {
  const p = spawn(PEER, [rom, code, `--signal=ws://127.0.0.1:${SIGNAL_PORT}`, `--frames=${stop}`,
    "--warmup=20", `--timeout=${120 + Math.ceil(stop / 50)}`, ...extra], { stdio: ["ignore", "pipe", "pipe"] });
  let out = "";
  p.stdout.on("data", (d) => { out += d; });
  p.stderr.on("data", (d) => { out += d; });
  const done = new Promise((res) => p.on("exit", (rc) => res(rc)));
  return { p, log: () => out, done };
};

const SYNC_RE = /ONLINE SYNC checks=(\d+) mismatches=(\d+) resyncs=(\d+)/g;
const peer_sync = (log) => {
  const all = [...log.matchAll(SYNC_RE)];
  const m = all[all.length - 1];
  return m ? { checks: +m[1], mismatches: +m[2], resyncs: +m[3] } : { checks: 0, mismatches: 0, resyncs: 0 };
};
const page_sync = (page) => page.evaluate(() => ({
  checks: net.rb.syncChecks, mismatches: net.rb.syncMismatches, resyncs: net.rb.resyncs, ms: net.rb.resyncMs }));
// Fingerprints at 120, 240 ... STOP: each side compares every one.
const CHECKS = STOP / 120;

// The page and the native peer on `code`; `peer_first` picks who hosts.
// `opts.peerArgs` go to the peer; `opts.pageDrift` sets the page's copy back.
const link = async (page_game, peer_rom, code, peer_first, opts = {}) => {
  await setup();
  const stop = opts.stop ?? STOP;
  const pl = await page_player(page_game, opts.pageDrift ?? 0, opts.pageBios ?? null, stop, !!opts.random);
  let peer = null;
  const extra = opts.peerArgs ?? [];
  if (peer_first) { peer = run_peer(peer_rom, code, extra, stop); await sleep(1500); }
  await pl.page.evaluate(() => document.getElementById("net-connect").click());
  await pl.page.locator("#net-code-input").fill(code);
  await pl.page.locator("#net-join-go").click();
  if (!peer_first) { await sleep(1500); peer = run_peer(peer_rom, code, extra, stop); }
  if (opts.until) {
    // Only until the page's sync checks say what was wanted, then end.
    await until(async () => (await pl.page.evaluate(() => !!net?.started)) && opts.until(await page_sync(pl.page)),
      async () => "page sync " + JSON.stringify(await page_sync(pl.page).catch(() => null)), 60000);
    const sync = { page: await page_sync(pl.page), hle: await pl.page.evaluate(() => rbBiosHle(net.rb)) };
    peer.p.kill("SIGKILL");
    await pl.ctx.close();
    return { sync };
  }
  const done = () => pl.page.evaluate((stop) => {
    if (!net?.started || Module._rollback_head() < stop) return false;
    if (Module._rollback_confirmed() < stop - 1) Module._rollback_feed(stop + 60, 0);
    return Module._rollback_confirmed() === stop - 1;
  }, stop);
  await until(async () => {
    if (opts.onWait) await opts.onWait(pl.page, peer.log());
    return (await done()) && /ONLINE DUMP/.test(peer.log());
  }, async () => "both at the stop | page: " +
      (await pl.page.evaluate(() => document.getElementById("net-status")?.textContent)) +
      " | peer: " + peer.log().slice(-600), 120000 + stop * 40);
  const page_dump = await dump(pl.page);
  const peer_dump = peer.log().match(/ONLINE DUMP (.*)/)[1].trim();
  const host = await pl.page.evaluate(() => net.isHost);
  // The last fingerprint (frame STOP) crosses just after both stop.
  const checks = Math.floor(stop / 120);
  await until(async () => (await page_sync(pl.page)).checks >= checks && peer_sync(peer.log()).checks >= checks,
    async () => "every sync check: page " + JSON.stringify(await page_sync(pl.page)) +
      " | peer " + JSON.stringify(peer_sync(peer.log())), 20000);
  const sync = { page: await page_sync(pl.page), peer: peer_sync(peer.log()),
                 hle: await pl.page.evaluate(() => rbBiosHle(net.rb)) };
  // The page's Disconnect (two taps): the peer hears the BYE and exits.
  await pl.page.evaluate(() => document.getElementById("rb-disconnect").click());
  await pl.page.evaluate(() => document.getElementById("rb-disconnect").click());
  const rc = await Promise.race([peer.done, sleep(15000).then(() => "timeout")]);
  if (rc === "timeout") peer.p.kill("SIGKILL");
  await pl.ctx.close();
  return { page_dump, peer_dump, host, rc, sync, log: peer.log() };
};

// wasm and native fingerprints the same at every check: no re-sync.
const in_step = (r) => {
  console.log("    sync: page", JSON.stringify(r.sync.page), "peer", JSON.stringify(r.sync.peer));
  for (const side of ["page", "peer"]) {
    assert.equal(r.sync[side].checks, CHECKS, side + " compared every fingerprint");
    assert.equal(r.sync[side].mismatches, 0, side + ": wasm and native fingerprints agree");
    assert.equal(r.sync[side].resyncs, 0, side + ": no re-sync");
  }
};

// One side's copy set back: both see it once, re-sync once, and carry on in
// step (the session restarts at frame 0, so STOP frames more after it).
const resynced = (r) => {
  console.log("    sync: page", JSON.stringify(r.sync.page), "peer", JSON.stringify(r.sync.peer));
  for (const side of ["page", "peer"]) {
    assert.equal(r.sync[side].mismatches, 1, side + " caught it once; the peer said:\n" +
      r.log.split("\n").filter((l) => !l.startsWith("ONLINE SYNC")).slice(-25).join("\n"));
    assert.equal(r.sync[side].resyncs, 1, side + " re-synced once");
    assert.ok(r.sync[side].checks >= CHECKS, side + " checks carried on after, and agreed");
  }
  assert.match(r.log, /peer: re-synced/, "the native side built its fresh cores");
  assert.equal(r.page_dump, r.peer_dump, "every core identical on both sides after the re-sync");
};

const GBA = { name: "attachtest.gba", bytes: readFileSync(join(ROMS, "attachtest.gba")) };
const GB = { name: "gblinktest.gb", bytes: readFileSync(join(ROMS, "gblinktest.gb")) };

test("browser hosts a native player: both sides' cores identical", { skip, timeout: 240000 }, async () => {
  const r = await link(GBA, join(ROMS, "attachtest.gba"), "NATA" + process.pid, false);
  assert.equal(r.host, true, "the page arrived first and hosts");
  assert.equal(r.page_dump, r.peer_dump, "page and native peer agree");
  in_step(r);
  assert.match(r.log, /linktest mark 0xCAFE[\s\S]*linktest mark 0xCAFE/, "link rounds done on both cores");
  assert.equal(r.rc, 0, "the peer heard the page's Disconnect and ended cleanly");
});

test("native player hosts the browser: both sides' cores identical", { skip, timeout: 240000 }, async () => {
  const r = await link(GBA, join(ROMS, "attachtest.gba"), "NATB" + process.pid, true);
  assert.equal(r.host, false, "the peer arrived first and hosts");
  assert.equal(r.page_dump, r.peer_dump, "page and native peer agree");
  in_step(r);
});

test("Game Boy: browser and native agree", { skip, timeout: 240000 }, async () => {
  const r = await link(GB, join(ROMS, "gblinktest.gb"), "NATGB" + process.pid, false);
  assert.equal(r.page_dump, r.peer_dump, "GB page and native peer agree");
  in_step(r);
});

test("cross-game: each side's ROM crosses and both agree", { skip, timeout: 240000 }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "dingbat-native-"));
  const other = join(dir, "attachtest-b.gba");
  writeFileSync(other, Buffer.concat([GBA.bytes, Buffer.from([0xff, 0xff, 0xff, 0xff])]));
  const r = await link(GBA, other, "NATX" + process.pid, false);
  assert.equal(r.page_dump, r.peer_dump, "cross-game page and native peer agree");
  in_step(r);
});

const synctest_rom = () => {
  const dir = mkdtempSync(join(tmpdir(), "dingbat-native-sync-"));
  const path = join(dir, SYNCTEST_NAME);
  writeFileSync(path, Buffer.from(synctestRom()));
  return { game: { name: SYNCTEST_NAME, bytes: readFileSync(path) }, path };
};

test("native copy set back: caught, re-synced, both agree after", { skip, timeout: 240000 }, async () => {
  const { game, path } = synctest_rom();
  const r = await link(game, path, "NATS" + process.pid, false, { peerArgs: ["--drift=300"] });
  assert.match(r.log, /copy of the friend's game set back at frame \d+: true/);
  resynced(r);
});

test("browser copy set back, native hosts: caught, re-synced, both agree after", { skip, timeout: 240000 }, async () => {
  const { game, path } = synctest_rom();
  const r = await link(game, path, "NATT" + process.pid, true, { pageDrift: 300 });
  assert.equal(r.host, false, "the peer hosts");
  resynced(r);
});

// A player with the real GBA BIOS (real-BIOS mode) and one without: before
// the HELLO named it, the two copies of each game ran different code on
// every BIOS call. DINGBAT_GBA_BIOS=a gba_bios.bin, DINGBAT_BIOS_GAME=a game
// that sits inside a BIOS call at a frame's end (Golden Sun, in Halt; its
// no-image state loaded under the image runs apart at once; attachtest.gba
// doesn't); neither is in the repo.
const biosPath = process.env.DINGBAT_GBA_BIOS, biosGame = process.env.DINGBAT_BIOS_GAME;
const biosSkip = skip || ((!biosPath || !biosGame) && "DINGBAT_GBA_BIOS / DINGBAT_BIOS_GAME not set");
const biosRom = () => ({ name: "biosgame.gba", bytes: readFileSync(biosGame) });
test("a real BIOS on the browser, none on the native side: both run HLE and stay in step", { skip: biosSkip, timeout: 240000 }, async () => {
  const bios = { bytes: readFileSync(biosPath), fallback: true };
  const r = await link(biosRom(), biosGame, "NATBIOS" + process.pid, false, { pageBios: bios });
  assert.equal(r.sync.hle, true, "the page saw the BIOSes differ");
  assert.equal(r.page_dump, r.peer_dump, "page and native peer agree");
  in_step(r);
});

test("control: the same pair without the agreement drifts at once", { skip: biosSkip, timeout: 240000 }, async () => {
  const bios = { bytes: readFileSync(biosPath), fallback: false };
  const r = await link(biosRom(), biosGame, "NATBIOC" + process.pid, false,
    { pageBios: bios, until: (st) => st.mismatches >= 1 });
  console.log("    control:", JSON.stringify(r.sync));
  assert.ok(r.sync.page.mismatches >= 1, "the real BIOS and HLE drift apart");
});

// A real game for a while against the native core, random buttons on both
// sides: every fingerprint agrees. DINGBAT_SOAK_ROM=path, DINGBAT_SOAK_MIN (15).
const soakRom = process.env.DINGBAT_SOAK_ROM;
const soakMin = Number(process.env.DINGBAT_SOAK_MIN || 15);
test(`soak: a real game for ${soakMin} min, browser and native, random buttons`,
     { skip: skip || (!soakRom && "DINGBAT_SOAK_ROM not set"), timeout: (soakMin * 60 * 2 + 600) * 1000 }, async () => {
  const game = { name: "soak.gba", bytes: readFileSync(soakRom) };
  const stop = soakMin * 3600;
  let last = 0;
  const r = await link(game, soakRom, "NATSOAK" + process.pid, false, {
    stop, random: true,
    onWait: async (page, log) => {
      if (Date.now() - last < 60000) return;
      last = Date.now();
      const st = await page_sync(page).catch(() => null);
      console.log("    page", JSON.stringify(st), "peer", JSON.stringify(peer_sync(log)));
      assert.equal((st?.mismatches ?? 0) + peer_sync(log).mismatches, 0, "a mismatch");
    },
  });
  console.log("    end: page", JSON.stringify(r.sync.page), "peer", JSON.stringify(r.sync.peer));
  for (const side of ["page", "peer"]) {
    assert.equal(r.sync[side].mismatches, 0, side + ": every fingerprint agreed");
    assert.equal(r.sync[side].resyncs, 0);
    assert.ok(r.sync[side].checks >= Math.floor(stop / 120), side + " compared them all");
  }
  assert.equal(r.page_dump, r.peer_dump, "page and native peer identical at the end");
});
