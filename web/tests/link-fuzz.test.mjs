// What a link friend sends, turned hostile: web/netplay.js's rbMessage fed
// seeded random messages (every kind, short, long, and with announced sizes
// past the caps) on a session set up as rbConnect sets one up, before the
// link starts. Nothing it is sent may throw out of the handler, hold more
// than the caps allow (RB_STATE_MAX, RB_ROM_MAX), or start the game.
// tests/link_hostile_test.nim does the same for the cores' side; the state
// a friend sends is fuzzed there (tests/fuzz).

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp } from "./helpers.mjs";

const NET_SOURCE =
  readFileSync(new URL("../sdputil.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../netplay.js", import.meta.url), "utf8");

// A page with a game loaded and a link session opened on it (rbConnect),
// its channel open and what it sends dropped.
const linkedPage = async (host) => {
  const app = await loadApp();
  const { sandbox } = app;
  sandbox.WebSocket = class { constructor() { this.readyState = 0; } send() {} close() {} };
  sandbox.RTCPeerConnection = class { close() {} addEventListener() {} };
  sandbox.BroadcastChannel = class {
    postMessage() {} addEventListener() {} removeEventListener() {} close() {}
  };
  sandbox.navigator.onLine = true;
  sandbox.location.hostname = "localhost";
  sandbox.crypto = { getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = (i * 2654435761) >>> 0; return a; } };
  for (const id of ["net-stall", "net-away", "net-mismatch"]) app.document.getElementById(id).hidden = true;
  vm.runInContext(NET_SOURCE, app.context, { filename: "web/netplay.js" });
  await app.runIn(`(async () => {
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    FS.readFile = () => { const r = new Uint8Array(4096); for (let i = 0; i < r.length; i++) r[i] = i * 7; return r; };
    window.enterRollbackMode = () => { window.__started = true; };
    net = { ...makeSession(true), isHost: ${host}, started: false,
            dc: { readyState: "open", send() {}, close() {}, bufferedAmount: 0 } };
    await rbConnect();
  })()`);
  return app;
};

// A seeded generator (xorshift32), so a failure replays.
const rng = (seed) => () => {
  seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
  return (seed >>> 0) / 4294967296;
};

const KINDS = 24; // the 21 kinds there are, and some there are not
const BIG = [0, 1, 0x7FFFFFFF, 0xFFFFFFFF, 8 * 1024 * 1024 + 1, 48 * 1024 * 1024 + 1, 16];

const message = (r) => {
  const kind = Math.floor(r() * KINDS);
  const len = r() < 0.2 ? 1 : r() < 0.9 ? 1 + Math.floor(r() * 48) : 1 + Math.floor(r() * 20000);
  const b = new Uint8Array(len);
  b[0] = kind;
  for (let i = 1; i < len; i++) b[i] = Math.floor(r() * 256);
  // A size field (bytes 1..4 of the BEGIN messages) from the edges often.
  if (len >= 5 && r() < 0.5) {
    const v = BIG[Math.floor(r() * BIG.length)];
    b[1] = v >>> 24; b[2] = (v >>> 16) & 255; b[3] = (v >>> 8) & 255; b[4] = v & 255;
  }
  return b;
};

for (const host of [true, false]) {
  test(`hostile messages before the link starts (${host ? "host" : "guest"}): no throw, no hoard, no start`, async () => {
    const app = await linkedPage(host);
    const r = rng(host ? 0x51A7E : 0xD1C3);
    const caps = app.runIn("({ state: RB_STATE_MAX, rom: RB_ROM_MAX })");
    let fresh = 0;
    for (let i = 0; i < 20000; i++) {
      // A session ended by a message (a bad size fails it) is opened again.
      if (!app.runIn("!!(net && net.rb && !net.ending)")) {
        await app.runIn(`(async () => {
          net = { ...makeSession(true), isHost: ${host}, started: false,
                  dc: { readyState: "open", send() {}, close() {}, bufferedAmount: 0 } };
          await rbConnect();
        })()`);
        fresh++;
      }
      const m = message(r);
      app.sandbox.__msg = m;
      try {
        app.runIn("rbMessage(new Uint8Array(__msg).buffer)");
      } catch (e) {
        assert.fail(`message ${i} (kind ${m[0]}, ${m.length} bytes) threw: ${e.message}`);
      }
      const held = app.runIn(`({ state: net?.rb?.stateBuf?.length || 0, rom: net?.rb?.romBuf?.length || 0 })`);
      assert.ok(held.state <= caps.state && held.rom <= caps.rom,
        `message ${i} (kind ${m[0]}) left ${JSON.stringify(held)} held`);
    }
    assert.equal(app.runIn("!!window.__started"), false, "nothing a stranger sends starts the game");
    assert.ok(fresh > 0, "some messages ended the session, as bad sizes should");
  });
}

// The same once the link runs: the inputs, presses, sync checks, re-syncs
// and resume messages a running link reads. The core is as a running link
// finds it, every call answering 0, and a re-sync's state load refused (the
// state is the cores' to check: tests/fuzz gbstate/gbastate).
const running = async (app, host) => {
  await app.runIn(`(async () => {
    net = { ...makeSession(true), isHost: ${host}, started: false,
            dc: { readyState: "open", send() {}, close() {}, bufferedAmount: 0 } };
    await rbConnect();
    if (!net?.rb) throw new Error("the link did not open: " + document.getElementById("net-status").textContent);
    for (const f of ["_rollback_feed", "_rollback_head", "_rollback_confirmed", "_rollback_sync_poll",
                     "_rollback_exit", "_rollback_exit_to_single", "_rollback_set_bios_hle",
                     "_rollback_bios_identity", "_core_id", "_free"]) Module[f] = () => 0;
    Module._rollback_load_state = () => 0;
    Module._malloc = () => 16;
    Module.memory = { buffer: new ArrayBuffer(1 << 16) };
    Module.HEAPU8 = new Uint8Array(Module.memory.buffer);
    net.started = true;
    net.rb.inited = true;
    net.rb.resync = { gen: 1, mineT: 0, target: 0, inLen: 0, inBuf: null, inGot: 0 };
  })()`);
};

for (const host of [true, false]) {
  test(`hostile messages on a running link (${host ? "host" : "guest"}): no throw, no hoard`, async () => {
    const app = await linkedPage(host);
    await running(app, host);
    const r = rng(host ? 0xBEEF : 0xF00D);
    const cap = app.runIn("RB_STATE_MAX");
    let ended = 0;
    for (let i = 0; i < 20000; i++) {
      // A goodbye or a bad size ends a link, as it should: open another.
      if (!app.runIn("!!(net && net.rb && !net.ending)")) {
        // Its teardown runs on (netShutdown) and clears net when done.
        for (let t = 0; t < 20; t++) await new Promise((r) => setImmediate(r));
        await running(app, host);
        ended++;
      }
      const m = message(r);
      app.sandbox.__msg = m;
      try {
        app.runIn("rbMessage(new Uint8Array(__msg).buffer)");
      } catch (e) {
        assert.fail(`message ${i} (kind ${m[0]}, ${m.length} bytes) threw: ${e.message}`);
      }
      const held = app.runIn("net?.rb?.resync?.inBuf?.length || 0");
      assert.ok(held <= cap, `message ${i} (kind ${m[0]}) left ${held} bytes held`);
    }
    assert.ok(ended < 20000 / 4, `${ended} of 20000 messages ended the link`);
  });
}
