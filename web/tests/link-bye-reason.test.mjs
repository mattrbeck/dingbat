// Three ways an ending reaches the friend as what it was:
// - the connection's BYE says why ([14][why]: 0 left, 1 gave up), so a
//   give-up just after the new channel opened reads "Couldn't reconnect"
//   on the friend's side too, not "Peer disconnected"
//   (formal/WebState/LinkResume.lean bye_reason_heard);
// - a link that dropped while the friend was away (hidden tab, app in the
//   background) shows "Friend switched away" and "Waiting for", not
//   "Reconnecting…": it waits on the friend, not the network;
// - a page killed mid-session (it runs nothing) leaves its goodbye at the
//   next load of that tab, from the retry code kept in sessionStorage
//   (LinkResume.lean Event.relaunch, regress_kill_heard_on_relaunch).
// sdputil.js + netplay.js are evaluated in the helpers.mjs vm context.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp } from "./helpers.mjs";

const NET_SOURCE =
  readFileSync(new URL("../sdputil.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../netplay.js", import.meta.url), "utf8");

const CODE = "RSABCDEFGHJKLMNP";
const LIVE_KEY = "dingbat-link-live";
const OLD_ID = "0123456789abcdef0123456789abcdef";

const setup = async ({ live = null, owner = false, storage = true } = {}) => {
  const app = await loadApp();
  const { sandbox } = app;
  sandbox.WebSocket = class {
    static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; }
    send(t) { this.sent.push(t); }
    close() { this.readyState = 3; }
  };
  sandbox.RTCPeerConnection = class { close() {} addEventListener() {} };
  // One bus per channel name; delivery to every other instance, at once.
  const bus = new Map();
  class BC {
    constructor(name) {
      this.name = name;
      this.listeners = [];
      if (!bus.has(name)) bus.set(name, new Set());
      bus.get(name).add(this);
    }
    postMessage(m) {
      for (const o of bus.get(this.name)) if (o !== this) for (const f of o.listeners) f({ data: m });
    }
    addEventListener(t, f) { if (t === "message") this.listeners.push(f); }
    removeEventListener() {}
    close() { bus.get(this.name).delete(this); }
  }
  sandbox.BroadcastChannel = BC;
  // Another tab still running the session (Duplicate Tab copied our storage).
  if (owner) {
    const o = new BC("dingbat-link-owner");
    o.addEventListener("message", (e) => {
      if (e.data?.t === "own?") o.postMessage({ t: "mine", code: e.data.code, id: e.data.id });
    });
  }
  const store = new Map(live ? [[LIVE_KEY, JSON.stringify(live)]] : []);
  if (storage) {
    sandbox.sessionStorage = {
      getItem: (k) => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => store.set(k, String(v)),
      removeItem: (k) => store.delete(k),
    };
  }
  sandbox.navigator.onLine = true;
  sandbox.location.hostname = "localhost";
  sandbox.crypto = { getRandomValues: (a) => a };
  const beacons = [];
  sandbox.navigator.sendBeacon = (url, body) => { beacons.push({ url, body: JSON.parse(body) }); return true; };
  sandbox.fetch = () => Promise.resolve({ ok: true });
  for (const id of ["net-stall", "net-away"]) app.document.getElementById(id).hidden = true;
  // A manual clock for timers and performance.now; the load's probe is
  // scheduled during the eval, so before it.
  let now = 1000;
  let timers = [];
  let nextId = 1;
  sandbox.performance = { now: () => now };
  sandbox.setTimeout = (fn, ms = 0) => { const id = nextId++; timers.push({ id, at: now + ms, fn }); return id; };
  sandbox.setInterval = (fn, ms) => { const id = nextId++; timers.push({ id, at: now + ms, fn, every: ms }); return id; };
  sandbox.clearTimeout = sandbox.clearInterval = (id) => { timers = timers.filter((t) => t.id !== id); };
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
  vm.runInContext(NET_SOURCE, app.context, { filename: "web/netplay.js" });
  const chan = [];
  sandbox.__chan = chan;
  // A started session; `resume` false: before the retry code is dealt.
  const session = ({ resume = true } = {}) => app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    rollbackMode = true;
    net = { ...makeSession(true), started: true,
            dc: { readyState: "open", send: (b) => __chan.push([...b]), close() {} },
            rb: { inited: false, resume: ${resume ? `{ sid: 1, code: "${CODE}" }` : "null"},
                  resumeOk: ${resume}, byeIn: false, noteLeft: false, lastRx: -1,
                  sentFrames: new Int32Array(128), sentBits: new Uint16Array(128), sentCount: 0,
                  reconnecting: false, reconnectAt: Date.now(), rsEarly: [], rsFlags: 0,
                  pauseReg: { on: false, n: 0, host: true }, speedReg: { on: false, n: 0, host: true } } };
    0`);
  const toasts = () => JSON.parse(app.runIn("JSON.stringify(toastItems.map((t) => t.msg))"));
  const receive = (bytes) => app.runIn(`rbMessage(new Uint8Array(${JSON.stringify(bytes)}).buffer)`);
  const liveEntry = () => (store.has(LIVE_KEY) ? JSON.parse(store.get(LIVE_KEY)) : null);
  const text = (id) => app.document.getElementById(id).textContent;
  return { app, beacons, chan, session, toasts, receive, advance, liveEntry, store, text };
};

// ---- The BYE's reason

test("BYE says why: 0 for the player's own end, 1 for a give-up", async () => {
  const a = await setup();
  a.session();
  await a.app.runIn("netShutdown()");
  assert.equal(JSON.stringify(a.chan), "[[14,0]]");
  const b = await setup();
  b.session();
  b.app.runIn(`netPeerGone("Couldn't reconnect")`);
  assert.equal(JSON.stringify(b.chan), "[[14,1]]");
});

for (const [bytes, toast] of [[[14, 1], "Couldn't reconnect"], [[14, 0], "Peer disconnected"],
  [[14], "Peer disconnected"]]) {
  test(`the friend's BYE ${JSON.stringify(bytes)} ends with "${toast}"`, async () => {
    const { app, session, receive, toasts, chan } = await setup();
    session();
    receive(bytes);
    assert.equal(app.runIn("net"), null);
    assert.ok(toasts().some((m) => m.startsWith(toast + " —")), toasts().join(" | "));
    assert.equal(chan.length, 0, "no BYE back");
  });
}

// ---- The card when the friend was away

test("a drop while the friend was away waits on them, not the network", async () => {
  const { app, session, advance, text } = await setup();
  session();
  app.runIn("rbPeerAway(true)");
  app.runIn(`rbDropped("channel closed", "Peer disconnected")`);
  assert.equal(app.runIn("net.rb.reconnecting"), true);
  assert.equal(app.document.getElementById("net-away").hidden, false);
  assert.equal(text("net-away-title"), "Friend switched away");
  assert.match(text("net-away-text"), /^The link dropped while they were away\. If they come back within 3 minutes/);
  advance(5000);
  assert.equal(text("net-away-time"), "Waiting for 0:05");
});

test("a drop with the friend here is still \"Reconnecting…\"", async () => {
  const { app, session, advance, text } = await setup();
  session();
  app.runIn(`rbDropped("channel closed", "Peer disconnected")`);
  assert.equal(text("net-away-title"), "Reconnecting…");
  assert.match(text("net-away-text"), /^The connection dropped\./);
  advance(5000);
  assert.equal(text("net-away-time"), "Trying for 0:05");
});

test("the resume clears it: a later drop with the friend here reads as one", async () => {
  const { app, session, text } = await setup();
  session();
  app.runIn("rbPeerAway(true)");
  app.runIn(`rbDropped("channel closed", "Peer disconnected")`);
  assert.equal(app.runIn("net.rb.peerAwayAtDrop"), true);
  // The friend's RESUME on the new channel: back, not away (flags 0).
  app.runIn("net.rb.rsDcOpen = true");
  app.runIn("rsResumeIn(net.rb, new DataView(new Uint8Array([13, 0, 0, 0, 1, 255, 255, 255, 255, 0]).buffer))");
  assert.equal(app.runIn("net.rb.reconnecting"), false);
  assert.equal(app.runIn("net.rb.peerAwayAtDrop"), false);
  app.runIn(`rbDropped("channel closed", "Peer disconnected")`);
  assert.equal(text("net-away-title"), "Reconnecting…");
});

// ---- The goodbye on relaunch

test("the session's retry code is kept while it can resume, freshened, and cleared at its end", async () => {
  const host = await setup();
  host.session({ resume: false });
  host.app.runIn("rbOfferResume()");
  const e = host.liveEntry();
  assert.equal(e.code, host.app.runIn("net.rb.resume.code"));
  assert.equal(e.id, host.app.runIn("NET_PAGE_ID"));
  assert.ok(Date.now() - e.at < 5000);
  // Freshened at a drop (a long session killed in the background stays recent).
  host.store.set(LIVE_KEY, JSON.stringify({ ...e, at: 0 }));
  host.app.runIn("net.rb.resumeOk = true"); // the guest's echo
  host.app.runIn(`rbDropped("channel closed", "Peer disconnected")`);
  assert.ok(host.liveEntry().at > 0);
  await host.app.runIn("netShutdown()");
  assert.equal(host.liveEntry(), null, "ended here: nothing for a relaunch to say");

  const guest = await setup();
  guest.session({ resume: false });
  guest.app.runIn(`(() => {
    const code = new TextEncoder().encode("${CODE}");
    const b = new Uint8Array(5 + code.length);
    b[0] = 12; new DataView(b.buffer).setUint32(1, 7); b.set(code, 5);
    rbResumeInfoIn(net.rb, new DataView(b.buffer), b.buffer);
  })()`);
  assert.equal(guest.liveEntry().code, CODE);
});

test("going hidden freshens it", async () => {
  const { app, session, liveEntry, store } = await setup();
  session();
  app.runIn("rbMarkLive(net.rb)");
  store.set(LIVE_KEY, JSON.stringify({ ...liveEntry(), at: 0 }));
  app.document.hidden = true;
  app.document.visibilityState = "hidden";
  await app.dispatchDoc("visibilitychange");
  assert.ok(liveEntry().at > 0);
});

test("a load that finds a session that never ended leaves its goodbye", async () => {
  const { beacons, advance, liveEntry } = await setup({
    live: { code: CODE, id: OLD_ID, at: Date.now() - 60000 } });
  assert.equal(liveEntry(), null, "taken at once");
  assert.equal(beacons.length, 0, "not before the other tabs could say it's theirs");
  advance(300);
  assert.equal(beacons.length, 1);
  assert.equal(beacons[0].url, "http://localhost:8790/bye");
  assert.deepEqual(beacons[0].body, { code: CODE, id: OLD_ID, why: "left" });
});

test("not for one older than the server keeps a goodbye (10 minutes)", async () => {
  const { beacons, advance, liveEntry } = await setup({
    live: { code: CODE, id: OLD_ID, at: Date.now() - 11 * 60000 } });
  advance(1000);
  assert.equal(beacons.length, 0);
  assert.equal(liveEntry(), null);
});

test("not when another tab still runs that session (Duplicate Tab)", async () => {
  const { beacons, advance } = await setup({
    live: { code: CODE, id: OLD_ID, at: Date.now() - 1000 }, owner: true });
  advance(1000);
  assert.equal(beacons.length, 0);
});

test("a live tab answers for its own session only", async () => {
  const { app, session } = await setup();
  session();
  const heard = [];
  const probe = app.runIn(`new BroadcastChannel("dingbat-link-owner")`);
  probe.addEventListener("message", (e) => heard.push(e.data));
  probe.postMessage({ t: "own?", code: CODE, id: "someone-else" });
  assert.equal(heard.length, 0, "the friend's tab, in the same browser, has another id");
  probe.postMessage({ t: "own?", code: CODE, id: app.runIn("NET_PAGE_ID") });
  assert.equal(heard.length, 1);
  assert.equal(heard[0].t, "mine");
});

test("without sessionStorage nothing breaks", async () => {
  const { app, session, beacons, advance } = await setup({ storage: false });
  session({ resume: false });
  app.runIn("rbOfferResume()");
  await app.runIn("netShutdown()");
  advance(1000);
  assert.equal(beacons.length, 1, "only the session's own goodbye");
});
