// The goodbye note: a session ending while the friend may be redialing
// leaves a goodbye on the retry code (POST /bye, a beacon), and a redial
// that finds one ends with the friend's goodbye instead of "Reconnecting…"
// until the give-up (server.js leaveNote; formal/WebState/LinkRedial.lean
// regress_quit_heard, LinkResume.lean regress_quit_while_redialing).
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

const RB_BYE = 14;
const CODE = "RSABCDEFGHJKLMNP";

const setup = async ({ beacon = true } = {}) => {
  const app = await loadApp();
  const { sandbox } = app;
  const sockets = [];
  sandbox.WebSocket = class {
    static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; sockets.push(this); }
    send(t) { this.sent.push(t); }
    close() { this.readyState = 3; }
  };
  sandbox.RTCPeerConnection = class { close() {} addEventListener() {} };
  sandbox.BroadcastChannel = class {
    postMessage() {} addEventListener() {} removeEventListener() {} close() {}
  };
  sandbox.navigator.onLine = true;
  sandbox.location.hostname = "localhost";
  sandbox.crypto = { getRandomValues: (a) => a };
  const beacons = [];
  const fetches = [];
  if (beacon) sandbox.navigator.sendBeacon = (url, body) => { beacons.push({ url, body: JSON.parse(body) }); return true; };
  else delete sandbox.navigator.sendBeacon;
  sandbox.fetch = (url, opts) => { fetches.push({ url, opts }); return Promise.resolve({ ok: true }); };
  for (const id of ["net-stall", "net-away"]) app.document.getElementById(id).hidden = true;
  vm.runInContext(NET_SOURCE, app.context, { filename: "web/netplay.js" });
  const chan = [];
  sandbox.__chan = chan;
  // A started session that can resume; `reconnecting` while redialing (no
  // channel), else live on an open channel.
  const session = ({ reconnecting = false, resume = true, byeIn = false } = {}) => app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    rollbackMode = true;
    net = { ...makeSession(true), started: true,
            dc: ${reconnecting ? "null" : `{ readyState: "open", send: (b) => __chan.push([...b]), close() {} }`},
            rb: { inited: false, resume: ${resume ? `{ sid: 1, code: "${CODE}" }` : "null"},
                  resumeOk: ${resume}, byeIn: ${byeIn}, noteLeft: false, lastRx: -1,
                  sentFrames: new Int32Array(128), sentBits: new Uint16Array(128), sentCount: 0,
                  reconnecting: ${reconnecting}, reconnectAt: Date.now(), rsEarly: [] } };
    0`);
  const toasts = () => app.runIn("JSON.stringify(toastItems.map((t) => t.msg))");
  return { app, sockets, beacons, fetches, chan, session, toasts };
};

test("Disconnect while redialing leaves a goodbye on the retry code", async () => {
  const { app, beacons, session } = await setup();
  session({ reconnecting: true });
  await app.runIn("netShutdown()");
  assert.equal(app.runIn("net"), null);
  assert.equal(beacons.length, 1);
  assert.equal(beacons[0].url, "http://localhost:8790/bye");
  assert.equal(beacons[0].body.code, CODE);
  assert.equal(beacons[0].body.why, "left");
  assert.equal(beacons[0].body.id, app.runIn("NET_PAGE_ID"));
});

test("Disconnect on a live link says BYE on the channel and leaves the note too", async () => {
  const { app, beacons, chan, session } = await setup();
  session();
  await app.runIn("netShutdown()");
  assert.equal(JSON.stringify(chan), JSON.stringify([[RB_BYE]]));
  assert.equal(beacons.length, 1, "for a friend the BYE can't reach (its link already down)");
  assert.equal(beacons[0].body.why, "left");
});

test("giving up leaves a \"gave-up\" goodbye, once", async () => {
  const { app, beacons, session } = await setup();
  session({ reconnecting: true });
  app.runIn(`netPeerGone("Couldn't reconnect")`);
  await app.runIn("netShutdown()");
  assert.equal(beacons.length, 1);
  assert.equal(beacons[0].body.why, "gave-up");
});

test("no note after the friend's own goodbye, or without a retry code", async () => {
  const a = await setup();
  a.session({ byeIn: true });
  await a.app.runIn("netShutdown()");
  assert.equal(a.beacons.length, 0, "the friend said BYE: it has gone");
  const b = await setup();
  b.session({ resume: false });
  await b.app.runIn("netShutdown()");
  assert.equal(b.beacons.length, 0, "a manual or same-browser session has no retry code");
});

test("without sendBeacon the note goes by a keepalive fetch", async () => {
  const { app, beacons, fetches, session } = await setup({ beacon: false });
  session({ reconnecting: true });
  await app.runIn("netShutdown()");
  assert.equal(beacons.length, 0);
  assert.equal(fetches.length, 1);
  assert.equal(fetches[0].url, "http://localhost:8790/bye");
  assert.equal(fetches[0].opts.keepalive, true);
  assert.equal(JSON.parse(fetches[0].opts.body).code, CODE);
});

// The friend's side: a redial whose rendezvous finds the goodbye.
for (const [why, toast] of [["left", "Peer disconnected"], ["gave-up", "Couldn't reconnect"]]) {
  test(`a redial told "bye" (${why}) ends with "${toast}" and leaves no note of its own`, async () => {
    const { app, sockets, beacons, session, toasts } = await setup();
    session();
    const before = sockets.length;
    app.runIn(`rbDropped("channel closed", "Peer disconnected")`);
    assert.equal(app.runIn("net.rb.reconnecting"), true, "redialing");
    assert.equal(sockets.length, before + 1, "on the retry code");
    const ws = sockets[before];
    ws.onopen();
    assert.equal(JSON.parse(ws.sent[0]).code, CODE);
    await ws.onmessage({ data: JSON.stringify({ t: "bye", why }) });
    assert.equal(app.runIn("net"), null, "the session ended");
    assert.ok(JSON.parse(toasts()).some((m) => m.startsWith(toast)), toasts());
    assert.equal(beacons.length, 0);
    assert.equal(sockets.length, before + 1, "no redial after it");
  });
}
