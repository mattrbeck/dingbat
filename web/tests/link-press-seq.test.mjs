// Pause and 2x presses crossing on a live link. Each press is numbered one
// past the highest its side has seen, and both sides keep the highest (the
// host's on a tie), so they agree once nothing is in flight; a "now" state
// message, the last to arrive wins, left one side paused and the other
// stalled at "waiting for friend" (formal/WebState/LinkResume.lean
// pause_presses_cross; the fix is proved by presses_agree there).
// Two pages, A the host and B the guest, each a helpers.mjs vm context with
// sdputil.js + netplay.js evaluated in index.html's script order; what one
// sends is handed to the other by hand, so a test chooses what crosses.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp } from "./helpers.mjs";

const NET_SOURCE =
  readFileSync(new URL("../sdputil.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../netplay.js", import.meta.url), "utf8");

const RB_PAUSE = 8, RB_SPEED = 7, RB_RESUME = 13;
const SID = 0x01020304;

// One side, live on an open channel as rbStartIfReady leaves it (or, with
// `redialing`, its new channel open and our RESUME sent with flags 0).
const side = async (host, { redialing = false } = {}) => {
  const app = await loadApp();
  const { sandbox } = app;
  sandbox.WebSocket = class { constructor() { this.readyState = 0; } send() {} close() {} };
  sandbox.RTCPeerConnection = class { close() {} addEventListener() {} };
  sandbox.BroadcastChannel = class {
    postMessage() {} addEventListener() {} removeEventListener() {} close() {}
  };
  sandbox.navigator.onLine = true;
  sandbox.location.hostname = "localhost";
  sandbox.crypto = { getRandomValues: (a) => a };
  for (const id of ["net-stall", "net-away"]) app.document.getElementById(id).hidden = true;
  vm.runInContext(NET_SOURCE, app.context, { filename: "web/netplay.js" });
  const out = [];
  sandbox.__sent = out;
  app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    window.enterRollbackMode = () => {};
    rollbackMode = true;
    net = { ...makeSession(true), isHost: ${host}, started: true,
            dc: { readyState: "open", send: (b) => __sent.push(b), close() {} },
            rb: { inited: false, resume: { sid: ${SID}, code: "RSABCDEFGHJKLMNP" }, resumeOk: true,
                  byeIn: false, lastRx: -1, sentFrames: new Int32Array(128),
                  sentBits: new Uint16Array(128), sentCount: 0, reconnecting: ${redialing},
                  reconnectSince: 0, rsDcOpen: true, rsFlags: 0, rsEarly: [],
                  pauseReg: { on: false, n: 0, host: true },
                  speedReg: { on: false, n: 0, host: true } } };
    window.rbSendPause = rbSendPause;
    window.rbSendSpeed = rbSendSpeed;
    paused = false;
    speed2x = false;
    0`);
  // rbSend gets Uint8Arrays and ArrayBuffers (from the vm's realm).
  const take = () => out.splice(0).map((b) => [...(ArrayBuffer.isView(b) ? b : new Uint8Array(b))]);
  const recv = (bytes) => app.runIn(`rbMessage(new Uint8Array([${bytes}]).buffer)`);
  return { app, take, recv, paused: () => app.runIn("paused"), speed: () => app.runIn("speed2x") };
};

const pair = async () => [await side(true), await side(false)];

// Hand each side everything the other sent (both batches taken first, so
// they cross).
const cross = (a, b) => {
  const toB = a.take(), toA = b.take();
  for (const m of toB) b.recv(m);
  for (const m of toA) a.recv(m);
};

const press = (kind, on, n) => [kind, on ? 1 : 0, n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];

test("a double tap crossing a single tap: both sides agree", async () => {
  const [a, b] = await pair();
  a.app.runIn("togglePause()"); // Pause
  a.app.runIn("togglePause()"); // Resume
  b.app.runIn("togglePause()"); // Pause, before A's arrive
  cross(a, b);
  assert.equal(a.paused(), b.paused(), "one pause state on both sides");
  assert.equal(a.paused(), false, "A's Resume, the newest press, wins");
  assert.deepEqual([...a.take(), ...b.take()], [], "settled: nothing more to send");
});

test("presses made at once with the same number: the host's wins on both sides", async () => {
  const [a, b] = await pair();
  a.app.runIn("togglePause()");
  b.app.runIn("togglePause()");
  a.app.runIn("togglePause()"); // A: Resume, number 2
  b.app.runIn("togglePause()"); // B: Resume, number 2
  b.app.runIn("togglePause()"); // B: Pause, number 3
  cross(a, b);
  assert.equal(a.paused(), true, "B's third press is the highest");
  assert.equal(b.paused(), true);
  const [c, d] = await pair();
  c.app.runIn("togglePause()"); // A: Pause, 1
  d.app.runIn("togglePause()"); // B: Pause, 1
  d.app.runIn("togglePause()"); // B: Resume, 2
  c.app.runIn("togglePause()"); // A: Resume, 2
  c.recv(press(RB_PAUSE, true, 2)); // a tie, made up: B's pause at A's number
  assert.equal(c.paused(), false, "the host keeps its own press on a tie");
  d.take();
  c.take();
  d.recv(press(RB_PAUSE, true, 2)); // the host's at B's number: B takes it
  assert.equal(d.paused(), true, "the guest gives way to the host on a tie");
});

test("2x crossing: both sides agree", async () => {
  const [a, b] = await pair();
  b.app.runIn("setSpeed2x(true)");
  b.app.runIn("setSpeed2x(false)");
  a.app.runIn("setSpeed2x(true)");
  cross(a, b);
  assert.equal(a.speed(), b.speed());
  assert.equal(a.speed(), false, "B's second press is the newest");
});

test("a press older than the one held is dropped", async () => {
  const [a] = await pair();
  a.app.runIn("togglePause()"); // 1
  a.app.runIn("togglePause()"); // 2
  a.app.runIn("togglePause()"); // 3: paused
  a.recv(press(RB_PAUSE, false, 2));
  assert.equal(a.paused(), true, "the friend's resume at 2 lost to our pause at 3");
  a.recv(press(RB_PAUSE, false, 4));
  assert.equal(a.paused(), false, "a newer one is taken");
});

test("a press after seeing the friend's beats it", async () => {
  const [a, b] = await pair();
  b.app.runIn("togglePause()"); // B: Pause, 1
  cross(a, b);
  assert.equal(a.paused(), true);
  b.app.runIn("togglePause()"); // B: Resume, 2
  a.app.runIn("togglePause()"); // A: Resume, 2 too, at once
  cross(a, b);
  assert.equal(a.paused(), false);
  assert.equal(b.paused(), false);
  b.app.runIn("togglePause()"); // B: Pause, 3: beats the host's 2
  cross(a, b);
  assert.equal(a.paused(), true, "the guest's later press holds against the host");
  assert.equal(b.paused(), true);
});

test("a build before the numbering: its 2-byte message is taken as it was", async () => {
  const [a] = await pair();
  a.app.runIn("togglePause()");
  a.app.runIn("togglePause()");
  a.recv([RB_PAUSE, 1]);
  assert.equal(a.paused(), true);
  a.recv([RB_SPEED, 1]);
  assert.equal(a.speed(), true);
  const sent = a.take().filter((m) => m[0] === RB_PAUSE);
  assert.deepEqual(sent.at(-1), press(RB_PAUSE, false, 2), "ours carry the number");
});

test("the resume starts the count again: a press after it is taken", async () => {
  const a = await side(true, { redialing: true });
  const b = await side(false, { redialing: true });
  // Before the drop B had pressed far ahead of A.
  b.app.runIn("net.rb.pauseReg = { on: false, n: 40, host: false }; 0");
  a.recv([RB_RESUME, 1, 2, 3, 4, 255, 255, 255, 255, 0]);
  b.recv([RB_RESUME, 1, 2, 3, 4, 255, 255, 255, 255, 0]);
  assert.equal(a.app.runIn("net.rb.reconnecting"), false);
  assert.deepEqual(JSON.parse(b.app.runIn("JSON.stringify(net.rb.pauseReg)")),
    { on: false, n: 0, host: true }, "the decision, as the host's press 0");
  a.take();
  b.take();
  a.app.runIn("togglePause()");
  assert.deepEqual(a.take(), [press(RB_PAUSE, true, 1)]);
  b.recv(press(RB_PAUSE, true, 1));
  assert.equal(b.paused(), true, "press 1 beats the decision");
});
