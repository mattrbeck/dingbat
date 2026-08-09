// Signaling-resilience tests for web/netplay.js — the connect flow's contract
// with the linking server. On top of helpers.mjs (which evaluates the real
// index.js), this evaluates sdputil.js + netplay.js in the same vm context,
// mirroring index.html's script order, with a test-scripted WebSocket and a
// manual fake clock so the 2s fallback / 1-2-4s redial ladder / 20s RTC
// deadline run instantly and deterministically.
//
// Pinned behavior (regression: the server's "waiting" reply used to be
// mistaken for an unresponsive server, yanking the first peer to the manual
// code exchange — and releasing its room — after 2s):
//   - any server reply disarms the "didn't respond" fallback; a solo peer
//     waits indefinitely and can still be paired much later
//   - a rendezvous the server never answers still falls back at ~2s
//   - a socket that drops mid-wait is redialed and re-registers the same
//     code; a server reply refills the redial budget
//   - a server that stays dead gets exactly three spaced redials, then the
//     manual code exchange — and is never dialed again
//   - cancelling while waiting closes the socket without redialing
//   - a mid-handshake socket drop does NOT redial; a pairing whose
//     DataChannel never opens fails at the 20s deadline instead of hanging

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp } from "./helpers.mjs";

const NET_SOURCE =
  readFileSync(new URL("../sdputil.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../netplay.js", import.meta.url), "utf8");

const NO_RESPONSE = "Couldn't connect — the linking server didn't respond";

const setup = async () => {
  const app = await loadApp();
  const { sandbox } = app;

  // Scripted WebSocket: the test plays the server's side of every socket.
  const sockets = [];
  class FakeWebSocket {
    static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
    constructor(url) {
      this.url = String(url);
      this.readyState = 0;
      this.sent = [];
      sockets.push(this);
    }
    send(data) { this.sent.push(JSON.parse(data)); }
    close() { if (this.readyState === 3) return; this.readyState = 3; this.onclose?.(); }
    // Test-side controls:
    open() { this.readyState = 1; this.onopen?.(); }              // dial succeeded
    refuse() { this.onerror?.(); this.readyState = 3; this.onclose?.(); } // dial failed
    serverDrop() { this.readyState = 3; this.onclose?.(); }       // live socket dies
    reply(obj) { this.onmessage?.({ data: JSON.stringify(obj) }); }
  }

  // Inert RTCPeerConnection: enough surface for startRtc and manualPrepare;
  // it never gathers ICE and its channel never opens (that's the point of the
  // deadline tests).
  const pcs = [];
  class FakeRTCPeerConnection {
    constructor() { this.iceGatheringState = "gathering"; pcs.push(this); }
    createDataChannel() { return { readyState: "connecting", close() {} }; }
    async createOffer() { return { type: "offer", sdp: "v=0" }; }
    async createAnswer() { return { type: "answer", sdp: "v=0" }; }
    async setLocalDescription(d) { this.localDescription = d; }
    async setRemoteDescription() {}
    async addIceCandidate() {}
    addEventListener() {}
    close() {}
  }

  // Inert BroadcastChannel: the same-browser local path stays present but
  // quiet, as in every current browser — its presence keeps a failed redial
  // on sigConnect's resolve(false) path (status note) instead of netFail.
  class FakeBroadcastChannel {
    postMessage() {}
    addEventListener() {}
    removeEventListener() {}
    close() {}
  }

  // Manual clock. netplay.js resolves setTimeout/clearTimeout through the vm
  // global at call time, so swapping the sandbox's is enough; index.js timers
  // already scheduled during loadApp stay on the host clock and never fire
  // into these tests.
  let now = 0, seq = 0;
  const timers = new Map();
  sandbox.setTimeout = (fn, ms = 0) => { const id = ++seq; timers.set(id, { at: now + ms, fn }); return id; };
  sandbox.clearTimeout = (id) => { timers.delete(id); };
  const flush = () => new Promise((r) => setImmediate(r));
  const advance = async (ms) => {
    const end = now + ms;
    for (;;) {
      let next = null;
      for (const [id, t] of timers)
        if (t.at <= end && (next === null || t.at < timers.get(next).at)) next = id;
      if (next === null) break;
      const t = timers.get(next);
      timers.delete(next);
      now = Math.max(now, t.at);
      t.fn();
      await flush(); // settle promises the timer callback awaited
    }
    now = end;
  };

  sandbox.WebSocket = FakeWebSocket;
  sandbox.RTCPeerConnection = FakeRTCPeerConnection;
  sandbox.BroadcastChannel = FakeBroadcastChannel;
  sandbox.navigator.onLine = true;
  sandbox.location.hostname = "localhost"; // read at netplay.js module scope
  sandbox.crypto = { getRandomValues: (a) => { a[0] = 0x1234; return a; } };

  vm.runInContext(NET_SOURCE, app.context, { filename: "web/netplay.js" });

  // netplay.js probes server liveness at module scope; complete it as "up" so
  // opening the modal takes the normal shared-code path.
  assert.equal(sockets.length, 1, "module-scope liveness probe dialed once");
  sockets[0].open();

  const el = (id) => app.document.getElementById(id);
  const api = vm.runInContext(`({ openNetConnect, get net() { return net; } })`, app.context);

  // Open the modal and start a connect attempt. Returns the click-handler
  // promise, pending until the test settles the dial (open/refuse); the
  // rendezvous dial socket exists as soon as this settles a flush.
  const connect = async (code) => {
    await api.openNetConnect(true);
    el("net-code-input").value = code;
    return el("net-join-go").click();
  };

  return { app, el, api, sockets, pcs, connect, advance, flush,
           lastWS: () => sockets[sockets.length - 1] };
};

// ---------------------------------------------------------------------------

test("a solo peer parked on 'waiting' outlives the 2s fallback and still pairs", async () => {
  const { el, api, connect, advance, flush, lastWS, sockets } = await setup();
  const clicked = connect("TESTX");
  await flush();
  const ws = lastWS();
  ws.open();
  await clicked;
  assert.deepEqual(ws.sent, [{ t: "rendezvous", code: "TESTX" }]);

  ws.reply({ t: "waiting" });
  await flush();
  await advance(10 * 60 * 1000); // ten minutes alone

  assert.equal(el("net-manual-view").hidden, true, "never fell back to manual exchange");
  assert.equal(ws.readyState, 1, "the waiting socket is still up");
  assert.equal(el("net-join-go").textContent, "Cancel", "still in the connecting state");
  const dials = sockets.length;

  // The friend finally arrives: pairing proceeds normally on the same socket.
  ws.reply({ t: "paired", role: "host" });
  await flush();
  assert.equal(el("net-status").textContent, "Friend found — connecting…");
  assert.ok(ws.sent.some((m) => m.t === "sdp"), "host sent its offer");
  assert.equal(sockets.length, dials, "no extra dials while waiting");
});

test("a rendezvous the server never answers falls back to manual at ~2s", async () => {
  const { el, connect, advance, flush, lastWS } = await setup();
  const clicked = connect("TESTX");
  await flush();
  lastWS().open(); // socket opens, but the server never replies
  await clicked;

  await advance(2000);
  assert.equal(el("net-manual-view").hidden, false);
  assert.equal(el("net-manual-status").textContent, NO_RESPONSE);
});

test("a socket that drops mid-wait redials, re-registers the code, and keeps waiting", async () => {
  const { el, api, connect, advance, flush, lastWS, sockets } = await setup();
  const clicked = connect("REDIA");
  await flush();
  const ws = lastWS();
  ws.open();
  await clicked;
  ws.reply({ t: "waiting" });
  await flush();

  ws.serverDrop(); // deploy restart / proxy idle kill
  await flush();
  assert.equal(el("net-status").textContent, "Reconnecting to the linking server…");

  await advance(1000); // first redial
  const ws2 = lastWS();
  assert.notEqual(ws2, ws, "a fresh socket was dialed");
  ws2.open();
  await flush();
  assert.deepEqual(ws2.sent, [{ t: "rendezvous", code: "REDIA" }], "same code re-registered");

  ws2.reply({ t: "waiting" });
  await flush();
  assert.equal(api.net.redials, 0, "a server reply refills the redial budget");
  assert.equal(el("net-status").textContent, "", "back to the plain waiting state");

  await advance(10 * 60 * 1000);
  assert.equal(el("net-manual-view").hidden, true, "the recovered wait is again indefinite");
});

test("a server that stays dead gets exactly three spaced redials, then manual — and no more", async () => {
  const { el, connect, advance, flush, lastWS, sockets } = await setup();
  const clicked = connect("DEADX");
  await flush();
  const ws = lastWS();
  ws.open();
  await clicked;
  ws.reply({ t: "waiting" });
  await flush();

  ws.serverDrop();
  await advance(1000);
  lastWS().refuse(); // redial 1
  await advance(2000);
  lastWS().refuse(); // redial 2
  await advance(4000);
  lastWS().refuse(); // redial 3 — budget spent
  await flush();

  assert.equal(el("net-manual-view").hidden, false);
  assert.equal(el("net-manual-status").textContent, NO_RESPONSE);
  assert.equal(sockets.length, 5, "probe + rendezvous + exactly 3 redials");

  await advance(60 * 60 * 1000);
  assert.equal(sockets.length, 5, "gave up for good — a dead server is never spammed");
});

test("cancelling while waiting tears down without redialing", async () => {
  const { el, api, connect, advance, flush, lastWS, sockets } = await setup();
  const clicked = connect("TESTX");
  await flush();
  const ws = lastWS();
  ws.open();
  await clicked;
  ws.reply({ t: "waiting" });
  await flush();

  await el("net-close").click(); // dismiss = abandon the pending session
  await flush();
  assert.equal(ws.readyState, 3, "our own close");
  assert.equal(api.net, null);

  await advance(60 * 1000);
  assert.equal(sockets.length, 2, "an intentional close never redials");
});

test("a mid-handshake drop doesn't redial; an unopened DataChannel fails at the 20s deadline", async () => {
  const { el, api, connect, advance, flush, lastWS, sockets } = await setup();
  const clicked = connect("TESTX");
  await flush();
  const ws = lastWS();
  ws.open();
  await clicked;
  ws.reply({ t: "waiting" });
  ws.reply({ t: "paired", role: "guest" }); // guest: waits for ondatachannel
  await flush();
  assert.equal(el("net-status").textContent, "Friend found — connecting…");

  ws.serverDrop(); // signaling died mid-relay; the room is gone on both sides
  await flush();
  assert.equal(sockets.length, 2, "no redial while a pairing is in flight");

  await advance(20000); // ICE never starts checking — the deadline resolves it
  await flush();
  assert.match(el("net-status").textContent, /peer-to-peer/);
  assert.ok(el("net-status").classList.contains("net-error"));
  assert.ok(api.net, "the session re-armed so the player can retry");
  assert.equal(el("net-join-go").textContent, "Connect");

  await advance(60 * 1000);
  assert.equal(sockets.length, 2, "the failed pairing never dials the server again");
});
