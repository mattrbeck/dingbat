// Web parity with the iOS app on a live rollback link:
// - the home screen and Report a Bug freeze the friend's game too, and
//   giving the game back runs both (iOS showMainMenu / openSheet relay the
//   pause; the web froze only this side, and the friend stalled at the
//   prediction window with "waiting for friend");
// - a session starts at normal speed (iOS linkWillStart): a 2x left on from
//   before Connect ran this side alone at it.
// sdputil.js + netplay.js are evaluated in the helpers.mjs vm context, in
// index.html's script order.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp } from "./helpers.mjs";

const NET_SOURCE =
  readFileSync(new URL("../sdputil.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../netplay.js", import.meta.url), "utf8");

const RB_PAUSE = 8, RB_SPEED = 7;

const setup = async () => {
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
  const raw = [];
  sandbox.__sent = raw;
  // A started session, live on an open channel, as rbStartIfReady leaves it.
  app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    rollbackMode = true;
    net = { ...makeSession(true), started: true,
            dc: { readyState: "open", send: (b) => __sent.push(b), close() {} },
            rb: { inited: false, resume: null, resumeOk: false, byeIn: false, lastRx: -1,
                  sentFrames: new Int32Array(128), sentBits: new Uint16Array(128), sentCount: 0,
                  reconnecting: false, rsEarly: [] } };
    window.rbSendPause = rbSendPause;
    window.rbSendSpeed = rbSendSpeed;
    paused = false;
    0`);
  const sent = () => raw.map((b) => [...(ArrayBuffer.isView(b) ? b : new Uint8Array(b))]);
  const pauses = () => sent().filter((b) => b[0] === RB_PAUSE).map((b) => b[1]);
  return { app, sent, pauses };
};

test("the home screen pauses the friend too, and Resume runs both", async () => {
  const { app, pauses } = await setup();
  app.runIn("showMainMenu()");
  assert.equal(app.runIn("paused"), true);
  assert.deepEqual(pauses(), [1], "the friend is told");
  app.runIn("resumeGame()");
  assert.equal(app.runIn("paused"), false);
  assert.deepEqual(pauses(), [1, 0], "and told again on Resume");
});

test("going home already paused tells the friend nothing new", async () => {
  const { app, pauses } = await setup();
  app.runIn("togglePause()");
  assert.deepEqual(pauses(), [1]);
  app.runIn("showMainMenu()");
  assert.deepEqual(pauses(), [1], "the friend was already paused");
});

test("Report a Bug pauses the friend too; closing runs both, unless it was paused", async () => {
  const a = await setup();
  a.app.runIn("openReportModal()");
  assert.deepEqual(a.pauses(), [1]);
  a.app.runIn("closeReportModal()");
  assert.equal(a.app.runIn("paused"), false);
  assert.deepEqual(a.pauses(), [1, 0]);
  const b = await setup();
  b.app.runIn("togglePause()");
  b.app.runIn("openReportModal()");
  b.app.runIn("closeReportModal()");
  assert.equal(b.app.runIn("paused"), true, "the player's own pause is given back");
  assert.deepEqual(b.pauses(), [1], "nothing more to tell");
});

test("a session starts at normal speed, without telling the friend", async () => {
  const { app, sent } = await setup();
  app.runIn("rollbackMode = false; setSpeed2x(true)");
  assert.equal(app.runIn("speed2x"), true, "2x on before Connect");
  app.runIn("window.enterRollbackMode()");
  assert.equal(app.runIn("speed2x"), false);
  assert.equal(app.runIn("speed2xButton.classList.contains('active')"), false);
  assert.ok(!sent().some((b) => b[0] === RB_SPEED), "the friend starts at normal speed on its own");
});
