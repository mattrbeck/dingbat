// The Link Cable's hold on the run state: the modal freezes a running game
// for the whole of code entry and pairing, a session's end hands the game
// back, and the modal's screen wake lock lives exactly as long as the modal.
// Each replays a trace from formal/WebState/RunPause.lean. sdputil.js +
// netplay.js are evaluated in the helpers.mjs vm context, in index.html's
// script order, with inert network stubs (nothing here dials).

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp } from "./helpers.mjs";

const NET_SOURCE =
  readFileSync(new URL("../sdputil.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../netplay.js", import.meta.url), "utf8");

const flush = () => new Promise((r) => setImmediate(r));

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
  sandbox.location.hostname = "localhost"; // read at netplay.js module scope
  sandbox.crypto = { getRandomValues: (a) => { a[0] = 0x1234; return a; } };

  // Screen wake locks the test grants by hand: `grant()` resolves the oldest
  // request still out, as the UA does some time after request().
  const requests = [];
  const locks = [];
  sandbox.navigator.wakeLock = {
    request: () => new Promise((resolve) => requests.push(resolve)),
  };
  const grant = async () => {
    const lock = { released: false, release() { this.released = true; return Promise.resolve(); } };
    locks.push(lock);
    requests.shift()(lock);
    await flush();
  };
  const held = () => locks.filter((l) => !l.released).length;

  vm.runInContext(NET_SOURCE, app.context, { filename: "web/netplay.js" });

  // A game on screen, running, as loadRom leaves it.
  app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    pausePointerTs = -10000;
    0`);
  return { app, grant, held, requests };
};

const paused = (app) => app.runIn("paused");
const icon = (app) =>
  app.runIn('pauseButton.classList.contains("paused")') ? "Resume" : "Pause";
const modalOpen = (app) => app.runIn("netModalOpen()");

test("a setup error keeps the game frozen behind the still-open Link modal " +
     "(bug_link_setup_error_thaws_under_modal)", async () => {
  const { app } = await setup();
  await app.runIn("openNetConnect(true)");
  assert.equal(paused(app), true, "the modal froze the running game");
  app.runIn(`netFail("That code didn't match")`);
  await flush();
  assert.equal(modalOpen(app), true, "the modal stays up for a retry");
  assert.equal(paused(app), true, "the game must not run behind the retry");
  // Dismissing the modal is what hands the game back.
  app.runIn("netDismissModal()");
  await flush();
  assert.equal(modalOpen(app), false);
  assert.equal(paused(app), false);
  assert.equal(icon(app), "Pause");
});

// A started rollback session (no wasm side: rb never inited, so netShutdown
// skips rbTeardown), with the game on screen.
const inSession = (app) => app.runIn(`
  net = { ...makeSession(true), started: true, rb: { inited: false } };
  window.enterRollbackMode = () => {};
  rollbackMode = true;
  0`);

test("a session that ends while the player has it paused keeps the icon honest " +
     "(bug_link_end_keeps_resume_icon)", async () => {
  const { app } = await setup();
  inSession(app);
  await app.document.getElementById("pause").dispatch("click");
  assert.equal(paused(app), true);
  assert.equal(icon(app), "Resume");
  await app.runIn("netShutdown()"); // the peer left
  assert.equal(icon(app) === "Resume", paused(app),
               "the pause button must say what the core does");
  assert.equal(paused(app), true, "the player's own pause outlives the link");
});

test("a session that ends while the game is on the home screen leaves it frozen " +
     "(bug_link_end_on_home_runs)", async () => {
  const { app } = await setup();
  inSession(app);
  app.runIn("showMainMenu()");
  await app.runIn("netShutdown()");
  assert.equal(paused(app), true, "the game must not run behind the library");
});

test("a session that ends with the game running leaves it running", async () => {
  const { app } = await setup();
  inSession(app);
  await app.runIn("netShutdown()");
  assert.equal(paused(app), false);
  assert.equal(icon(app), "Pause");
});

test("a wake lock granted after the Link modal closed is let go " +
     "(bug_link_modal_wake_lock_leak)", async () => {
  const { app, grant, held, requests } = await setup();
  await app.runIn("openNetConnect(true)");
  assert.equal(requests.length, 1, "the modal asked to keep the screen on");
  app.runIn("closeNetModal()"); // the session started before the UA answered
  await grant();
  assert.equal(held(app), 0, "nothing is waiting any more: the screen may sleep");
});

test("two requests in flight (the modal re-arms on every return) hold one lock, " +
     "and closing the modal lets it go", async () => {
  const { app, grant, held, requests } = await setup();
  await app.runIn("openNetConnect(true)");
  await app.dispatchDoc("visibilitychange"); // back to the tab with the modal up
  assert.equal(requests.length, 2);
  await grant();
  await grant();
  assert.equal(held(), 1);
  app.runIn("closeNetModal()");
  assert.equal(held(), 0);
});
