// Pause and 2x across a resumed link. Both sides decide from the same two
// RESUMEs (rbResumeState) and send nothing more: answering with each one's
// own state, as before, let the two answers cross and swap the sides
// (formal/WebState/LinkResume.lean bug_resume_pause_swap_web/_ios; the fix
// is proved by resume_agrees there). sdputil.js + netplay.js are evaluated
// in the helpers.mjs vm context, in index.html's script order.

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

const setup = async () => {
  const app = await loadApp();
  const { sandbox } = app;
  class InertWebSocket {
    static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
    constructor() { this.readyState = 0; }
    send() {}
    close() { this.readyState = 3; }
  }
  sandbox.WebSocket = InertWebSocket;
  sandbox.RTCPeerConnection = class { close() {} addEventListener() {} };
  sandbox.BroadcastChannel = class {
    postMessage() {} addEventListener() {} removeEventListener() {} close() {}
  };
  sandbox.navigator.onLine = true;
  sandbox.location.hostname = "localhost";
  sandbox.crypto = { getRandomValues: (a) => a };
  for (const id of ["net-stall", "net-away"]) app.document.getElementById(id).hidden = true;
  vm.runInContext(NET_SOURCE, app.context, { filename: "web/netplay.js" });
  const raw = [];
  sandbox.__sent = raw;
  // A started session, redialing, its new channel open and our RESUME sent
  // with `flags`; the friend's RESUME is what each test delivers.
  const redialing = (flags, { pausedNow = false, speedNow = false } = {}) => app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    window.enterRollbackMode = () => {};
    rollbackMode = true;
    net = { ...makeSession(true), started: true,
            dc: { readyState: "open", send: (b) => __sent.push(b), close() {} },
            rb: { inited: false, resume: { sid: ${SID}, code: "RSABCDEFGHJKLMNP" }, resumeOk: true,
                  byeIn: false, lastRx: -1, sentFrames: new Int32Array(128),
                  sentBits: new Uint16Array(128), sentCount: 0, reconnecting: true,
                  reconnectSince: 0, rsDcOpen: true, rsFlags: ${flags}, rsEarly: [] } };
    paused = ${pausedNow};
    speed2x = ${speedNow};
    0`);
  const resumeFrom = (flags) => app.runIn(
    `rbMessage(new Uint8Array([${RB_RESUME}, 1, 2, 3, 4, 255, 255, 255, 255, ${flags}]).buffer)`);
  // rbSend gets Uint8Arrays and ArrayBuffers (from the vm's realm).
  const sent = () => raw.map((b) => [...(ArrayBuffer.isView(b) ? b : new Uint8Array(b))]);
  const sentKinds = () => sent().map((b) => b[0]);
  return { app, redialing, resumeFrom, sentKinds, sent };
};

// Lean's finalPause (pa aa pb ab) = pa ∧ pb ∨ aa ∧ pa ∨ ab ∧ pb.
const finalPause = (mine, theirs) => {
  const p = (f) => (f & 2) !== 0, a = (f) => (f & 1) !== 0;
  return (p(mine) && p(theirs)) || (a(mine) && p(mine)) || (a(theirs) && p(theirs));
};

test("rbResumeState is Lean's finalPause (and slow wins), the same from either side", async () => {
  const { app } = await setup();
  for (let mine = 0; mine < 8; mine++) {
    for (let theirs = 0; theirs < 8; theirs++) {
      const s = app.runIn(`JSON.stringify(rbResumeState(${mine}, ${theirs}))`);
      const r = app.runIn(`JSON.stringify(rbResumeState(${theirs}, ${mine}))`);
      assert.equal(s, r, `symmetric for ${mine}/${theirs}`);
      const { paused, speed2x } = JSON.parse(s);
      assert.equal(paused, finalPause(mine, theirs), `pause for ${mine}/${theirs}`);
      assert.equal(speed2x, (mine & 4) !== 0 && (theirs & 4) !== 0, `2x for ${mine}/${theirs}`);
    }
  }
});

test("both decided alike: nothing more is sent", async () => {
  const { app, redialing, resumeFrom, sentKinds } = await setup();
  redialing(2, { pausedNow: true });
  resumeFrom(0);
  assert.equal(app.runIn("paused"), false, "running wins");
  assert.ok(!sentKinds().includes(RB_PAUSE), "no pause message to cross the friend's");
  assert.ok(!sentKinds().includes(RB_SPEED));
  assert.equal(app.runIn("net.rb.reconnecting"), false);
});

// bug_resume_pause_swap_web: our RESUME said running; Pause was pressed in
// the instant before the friend's RESUME arrived. The friend decides from
// the flags (running); the press is newer, holds, and is relayed.
test("a Pause pressed after our RESUME went out holds and reaches the friend", async () => {
  const { app, redialing, resumeFrom, sent } = await setup();
  redialing(0, { pausedNow: true });
  resumeFrom(0);
  assert.equal(app.runIn("paused"), true);
  assert.deepEqual(sent().filter((b) => b[0] === RB_PAUSE), [[RB_PAUSE, 1]]);
});

// The press agreed with the decision anyway: nothing to tell.
test("a press in that window that matches the decision sends nothing", async () => {
  const { app, redialing, resumeFrom, sentKinds } = await setup();
  redialing(0, { pausedNow: true });
  resumeFrom(3);
  assert.equal(app.runIn("paused"), true);
  assert.ok(!sentKinds().includes(RB_PAUSE));
});

test("a ping keeps the friend's silence clock fresh and does nothing else", async () => {
  const { app, redialing } = await setup();
  redialing(0);
  app.runIn("net.rb.reconnecting = false; net.rb.lastMsgAt = 0; 0");
  app.runIn("rbMessage(new Uint8Array([15]).buffer)");
  assert.ok(app.runIn("net.rb.lastMsgAt") > 0);
  assert.equal(app.runIn("paused"), false);
});

// bug_resume_pause_swap_ios, from the browser's side: the iPhone was paused
// in the background when its channel opened.
test("a friend paused and away keeps both paused", async () => {
  const { app, redialing, resumeFrom, sentKinds } = await setup();
  redialing(0);
  resumeFrom(3);
  assert.equal(app.runIn("paused"), true);
  assert.ok(!sentKinds().includes(RB_PAUSE));
});

test("our own pause with a hidden tab holds against a running friend", async () => {
  const { app, redialing, resumeFrom } = await setup();
  redialing(3, { pausedNow: true });
  resumeFrom(0);
  assert.equal(app.runIn("paused"), true);
});

test("a pause pressed while the link was down is undone by a running friend", async () => {
  const { app, redialing, resumeFrom } = await setup();
  redialing(2, { pausedNow: true });
  resumeFrom(0);
  assert.equal(app.runIn("paused"), false);
});

test("both paused stay paused; 2x only if both were at 2x", async () => {
  const { app, redialing, resumeFrom } = await setup();
  redialing(2 | 4, { pausedNow: true, speedNow: true });
  resumeFrom(2);
  assert.equal(app.runIn("paused"), true);
  assert.equal(app.runIn("speed2x"), false, "slow wins");
});

// Our own Disconnect puts the session back (`net = s`) while rbTeardown
// awaits, with the channel still open. The friend's side closing it in that
// window (or its BYE) used to start a redial: a rendezvous socket on the
// retry code that nothing closed, and "Reconnecting…" over a game that had
// just left the link.
test("the friend's close during our own Disconnect's teardown doesn't redial", async () => {
  const { app } = await setup();
  let sockets = 0;
  app.sandbox.WebSocket = class {
    constructor() { sockets++; this.readyState = 0; }
    send() {}
    close() { this.readyState = 3; }
  };
  app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    rollbackMode = true;
    net = { ...makeSession(true), started: true,
            rb: { inited: true, resume: { sid: 1, code: "RSABCDEFGHJKLMNP" }, resumeOk: true,
                  byeIn: false, lastRx: -1, sentFrames: new Int32Array(128),
                  sentBits: new Uint16Array(128), sentCount: 0, reconnecting: false } };
    globalThis.__dc = { readyState: "open", send() {}, close() {} };
    wireChannel(__dc);
    window.leaveRollbackMode = () => { __dc.readyState = "closed"; __dc.onclose(); };
    0`);
  await app.runIn("netShutdown()");
  assert.equal(app.runIn("net"), null);
  assert.equal(sockets, 0, "no rendezvous on the retry code");
  assert.equal(app.document.getElementById("net-away").hidden, true, "no Reconnecting card");
});
