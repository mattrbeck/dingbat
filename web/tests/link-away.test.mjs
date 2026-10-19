// A linked friend's hidden tab. rAF stops in a hidden document, so that
// side's game pauses and ours stalls at the prediction limit: the hiding side
// says so over the DataChannel ([11][on]) and the other shows a card over the
// frozen screen instead of a silent freeze (which used to run out the 20 s
// idle window and end the session mid-trade). sdputil.js + netplay.js are
// evaluated in the helpers.mjs vm context, in index.html's script order.

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
  // Fake elements default to shown; mirror index.html's hidden attributes.
  for (const id of ["net-stall", "net-away"]) app.document.getElementById(id).hidden = true;
  vm.runInContext(NET_SOURCE, app.context, { filename: "web/netplay.js" });

  // A manual clock for netplay's timers and performance.now (both resolved
  // at call time, so swapping them after the eval is enough).
  let now = 1000;
  let timers = [];
  let nextId = 1;
  sandbox.performance = { now: () => now };
  sandbox.setTimeout = (fn, ms = 0) => {
    const id = nextId++;
    timers.push({ id, at: now + ms, fn });
    return id;
  };
  sandbox.setInterval = (fn, ms) => {
    const id = nextId++;
    const t = { id, at: now + ms, fn, every: ms };
    timers.push(t);
    return id;
  };
  sandbox.clearTimeout = sandbox.clearInterval = (id) => {
    timers = timers.filter((t) => t.id !== id);
  };
  const advance = (ms) => {
    const end = now + ms;
    for (;;) {
      timers.sort((a, b) => a.at - b.at);
      const t = timers[0];
      if (!t || t.at > end) break;
      now = t.at;
      if (t.every) t.at += t.every;
      else timers.shift();
      t.fn();
    }
    now = end;
  };

  // A started rollback session (no wasm side), its DataChannel recording.
  const raw = [];
  sandbox.__sent = raw;
  // Host-realm arrays, so deepEqual compares bytes, not prototypes.
  const sent = { at: (i) => [...raw.at(i)], slice: (i) => raw.slice(i).map((b) => [...b]) };
  app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    net = { ...makeSession(true), started: true, rb: { inited: false },
            dc: { readyState: "open", send: (b) => __sent.push(b) } };
    window.enterRollbackMode = () => {};
    rollbackMode = true;
    0`);
  const hide = (h) => {
    app.document.hidden = h;
    app.document.visibilityState = h ? "hidden" : "visible";
    return app.dispatchDoc("visibilitychange");
  };
  const receive = (bytes) => app.runIn(`rbMessage(new Uint8Array(${JSON.stringify(bytes)}).buffer)`);
  return { app, advance, sent, hide, receive };
};

const el = (app, id) => app.document.getElementById(id);

test("the hiding side tells its friend, and on a long absence hears it waited", async () => {
  const { app, advance, sent, hide } = await setup();
  await hide(true);
  assert.deepEqual(sent.at(-1), [11, 1]);
  advance(42000);
  await hide(false);
  assert.deepEqual(sent.at(-1), [11, 0]);
  assert.ok(!app.toasts.some((m) => m.includes("paused for")), "not until the link proves alive");
  advance(1500);
  assert.ok(app.toasts.some((m) => m.includes("Your game was paused for 0:42")), app.toasts.join(" | "));
});

test("back from away to a link that died while suspended: no 'your friend waited'", async () => {
  const { app, advance, hide } = await setup();
  await hide(true);
  advance(60000);
  await hide(false);
  app.runIn('netPeerGone("Peer connection lost")'); // the woken page finds it dead
  await flush();
  advance(1500);
  assert.ok(!app.toasts.some((m) => m.includes("paused for")), app.toasts.join(" | "));
  assert.ok(app.toasts.some((m) => m.startsWith("Peer connection lost")));
});

test("a quick alt-tab sends away/back but toasts nothing", async () => {
  const { app, advance, sent, hide } = await setup();
  await hide(true);
  advance(2000);
  await hide(false);
  assert.deepEqual(sent.slice(-2), [[11, 1], [11, 0]]);
  assert.ok(!app.toasts.some((m) => m.includes("paused for")));
});

test("the friend's away shows the card over a dimmed screen, with a running clock", async () => {
  const { app, advance, receive } = await setup();
  receive([11, 1]);
  assert.equal(el(app, "net-away").hidden, true, "a quick alt-tab doesn't flash the card");
  advance(1000);
  assert.equal(el(app, "net-away").hidden, false);
  assert.ok(app.document.body.classList.contains("peer-away"));
  assert.equal(el(app, "net-away-time").textContent, "Away 0:01");
  advance(64000);
  assert.equal(el(app, "net-away-time").textContent, "Away 1:05");
  // The card explains the stall: no badge on top of it.
  app.runIn("window.rbNoteStall(65000)");
  assert.equal(el(app, "net-stall").hidden, true);
  receive([11, 0]);
  assert.equal(el(app, "net-away").hidden, true);
  assert.ok(!app.document.body.classList.contains("peer-away"));
  assert.ok(app.toasts.includes("Friend's back — link resumed"), app.toasts.join(" | "));
});

test("an unexplained stall (no away message) shows the badge after 2 s", async () => {
  const { app } = await setup();
  app.runIn("window.rbNoteStall(1500)");
  assert.equal(el(app, "net-stall").hidden, true);
  app.runIn("window.rbNoteStall(4200)");
  assert.equal(el(app, "net-stall").hidden, false);
  assert.equal(el(app, "net-stall-text").textContent, "waiting for friend · 0:04");
  app.runIn("window.rbNoteStall(0)");
  assert.equal(el(app, "net-stall").hidden, true);
});

test("the card's Disconnect takes two taps and ends the session", async () => {
  const { app, advance, receive } = await setup();
  receive([11, 1]);
  advance(1000);
  const btn = el(app, "net-away-disconnect");
  await btn.dispatch("click");
  assert.equal(btn.textContent, "Are you sure?");
  assert.equal(app.runIn("!!net"), true, "one tap only arms it");
  await btn.dispatch("click");
  await flush();
  assert.equal(app.runIn("net"), null);
  assert.equal(el(app, "net-away").hidden, true, "the card goes with the session");
});

test("a session that ends while this player is away is told on return", async () => {
  const { app, hide } = await setup();
  await hide(true);
  app.runIn('netPeerGone("Peer disconnected")');
  await flush();
  await hide(false);
  assert.ok(app.toasts.some((m) => m.startsWith("Peer disconnected while you were away")),
            app.toasts.join(" | "));
});
