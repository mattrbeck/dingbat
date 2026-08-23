// Signaling resilience for web/netplay.js: sdputil.js + netplay.js are
// evaluated in the helpers.mjs vm context in index.html's script order, with
// a scripted WebSocket and a manual clock so the fallback / redial ladder /
// RTC deadline run deterministically. Pins: the server's "waiting" reply is
// not an unresponsive server.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp } from "./helpers.mjs";

const NET_SOURCE =
  readFileSync(new URL("../sdputil.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../netplay.js", import.meta.url), "utf8");

const NO_RESPONSE = "Couldn't connect — the linking server didn't respond";

const setup = async (opts = {}) => {
  const app = await loadApp();
  const { sandbox } = app;

  // Share ships hidden in index.html; fake-DOM elements default to hidden=false.
  app.document.getElementById("net-manual-share").hidden = true;
  const shares = []; // every payload handed to navigator.share
  if (opts.mobileShare) {
    app.state.mediaMatches["(pointer: coarse)"] = true;
    sandbox.navigator.share = (data) => { shares.push(data); return Promise.resolve(); };
  }
  const wakeLocks = { acquired: 0, released: 0 };
  sandbox.navigator.wakeLock = {
    request: async () => { wakeLocks.acquired++; return { release: async () => { wakeLocks.released++; } }; },
  };

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
    open() { this.readyState = 1; this.onopen?.(); }              // dial succeeded
    refuse() { this.onerror?.(); this.readyState = 3; this.onclose?.(); } // dial failed
    serverDrop() { this.readyState = 3; this.onclose?.(); }       // live socket dies
    reply(obj) { this.onmessage?.({ data: JSON.stringify(obj) }); }
  }

  // Inert RTCPeerConnection: never gathers ICE, channel never opens (the
  // deadline tests). The offer SDP is enough for SDPCodec.encode to mint a code.
  const FAKE_SDP = [
    "v=0",
    "a=ice-ufrag:testUFRG",
    "a=ice-pwd:testpwd0123456789012345",
    "a=fingerprint:sha-256 " + Array(32).fill("AB").join(":"),
    "a=setup:actpass",
    "a=candidate:842163049 1 udp 1677729535 203.0.113.7 4242 typ srflx raddr 0.0.0.0 rport 0",
    "",
  ].join("\r\n");
  const pcs = [];
  class FakeRTCPeerConnection {
    constructor() { this.iceGatheringState = "gathering"; pcs.push(this); this.closed = false; }
    createDataChannel() { return { readyState: "connecting", close() {} }; }
    async createOffer() { return { type: "offer", sdp: FAKE_SDP }; }
    async createAnswer() { return { type: "answer", sdp: FAKE_SDP }; }
    async setLocalDescription(d) { this.localDescription = d; }
    async setRemoteDescription() {}
    async addIceCandidate() {}
    addEventListener() {}
    close() { this.closed = true; }
  }

  // Inert BroadcastChannel: its presence keeps a failed redial on
  // sigConnect's resolve(false) path instead of netFail.
  class FakeBroadcastChannel {
    postMessage() {}
    addEventListener() {}
    removeEventListener() {}
    close() {}
  }

  // Manual clock: netplay.js resolves setTimeout through the vm global at
  // call time; index.js timers already scheduled stay on the host clock.
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

  // Complete the module-scope liveness probe as "up".
  assert.equal(sockets.length, 1, "module-scope liveness probe dialed once");
  sockets[0].open();

  const el = (id) => app.document.getElementById(id);
  const api = vm.runInContext(`({ openNetConnect, get net() { return net; } })`, app.context);

  // Returns the click-handler promise, pending until the test settles the dial.
  const connect = async (code) => {
    await api.openNetConnect(true);
    el("net-code-input").value = code;
    return el("net-join-go").click();
  };

  return { app, el, api, sockets, pcs, shares, wakeLocks, connect, advance, flush,
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

test("a late WebKit error after a successful probe doesn't mark the server down", async () => {
  // iOS Safari fires `error` on a socket closed right after it opens; the
  // probe's verdict must latch on the first outcome.
  const { el, api, sockets } = await setup();
  const probe = sockets[0]; // opened during setup
  probe.onerror?.(); // the late error Safari delivers after our own close
  await api.openNetConnect(true);
  assert.equal(el("net-manual-view").hidden, true, "modal opens on the shared-code view");
  assert.equal(el("net-connect-view").hidden, false);
});

test("the footer links toggle between the shared-code and manual views", async () => {
  const { el, api } = await setup();
  await api.openNetConnect(true);
  assert.equal(el("net-manual-view").hidden, true);

  await el("net-to-manual").click();
  assert.equal(el("net-manual-view").hidden, false, "manual exchange shown");
  assert.equal(el("net-connect-view").hidden, true);

  await el("net-to-code").click();
  assert.equal(el("net-manual-view").hidden, true, "back on the shared-code view");
  assert.equal(el("net-connect-view").hidden, false);
  assert.ok(api.net, "a fresh session is armed");
  assert.equal(el("net-join-go").disabled, false, "Connect is usable again");
});

test("Share appears on touch devices, waits for the mint, and shares the bare code", async () => {
  const { el, api, shares, advance, flush } = await setup({ mobileShare: true });
  assert.equal(el("net-manual-share").hidden, false, "revealed at load");
  await api.openNetConnect(true);
  await el("net-to-manual").click();
  assert.equal(el("net-manual-share").disabled, true, "disabled while the code is minting");
  await advance(8000); // gather cap (no srflx event from the fake pc)
  await flush();
  const code = api.net.manualCode;
  assert.ok(code, "a code was minted from the offer");
  assert.equal(el("net-manual-share").disabled, false);
  await el("net-manual-share").click();
  assert.equal(shares.length, 1);
  assert.equal(shares[0].text, code, "bare code, no prose — it must paste back cleanly");
  assert.equal(api.net.codeShared, true, "shared codes are pinned");
});

test("an unshared code re-mints on a timer; a shared one is pinned", async () => {
  const { el, api, pcs, advance, flush } = await setup({ mobileShare: true });
  await api.openNetConnect(true);
  await el("net-to-manual").click();
  await advance(8000);
  await flush();
  assert.ok(api.net.manualCode);
  const minted = pcs.length;
  await advance(46000 + 8000); // freshness interval + the re-mint's own gather
  await flush();
  assert.ok(pcs.length > minted, "unshared code re-minted with a fresh pc");
  await el("net-manual-share").click(); // pin it
  const pinned = pcs.length;
  await advance(10 * 60 * 1000);
  assert.equal(pcs.length, pinned, "no re-mint once the friend holds the code");
});

test("pipeline statuses mirror into the manual view while it's up", async () => {
  const { el, api, app } = await setup();
  await api.openNetConnect(true);
  app.runIn(`netSetStatus("Transferring games… 40%")`);
  assert.equal(el("net-manual-status").textContent, "",
    "hidden manual view: no mirror");
  await el("net-to-manual").click();
  app.runIn(`netSetStatus("Transferring games… 60%")`);
  assert.equal(el("net-manual-status").textContent, "Transferring games… 60%",
    "visible manual view sees the post-connect pipeline");
});

test("disconnecting a live link is a two-step armed confirm, not a one-tap", async () => {
  const { el, api, advance, flush } = await setup();
  await api.openNetConnect(true);
  api.net.started = true; // simulate a running linked session
  await el("rb-disconnect").click();
  await flush();
  assert.ok(el("rb-disconnect").classList.contains("armed"), "first tap arms");
  assert.ok(api.net, "armed but not disconnected");
  await advance(4000); // the arm window expires
  assert.ok(!el("rb-disconnect").classList.contains("armed"), "auto-disarmed");
  await el("rb-disconnect").click(); // re-arm…
  await el("rb-disconnect").click(); // …and confirm within the window
  await flush();
  assert.equal(api.net, null, "second tap while armed disconnects");
});

test("the link modal holds a screen wake lock while open", async () => {
  const { el, api, wakeLocks, flush } = await setup();
  await api.openNetConnect(true);
  await flush();
  assert.ok(wakeLocks.acquired >= 1, "acquired on open");
  await el("net-close").click();
  await flush();
  assert.ok(wakeLocks.released >= 1, "released on close");
});

test("Share stays hidden without the Web Share API", async () => {
  const { el } = await setup();
  assert.equal(el("net-manual-share").hidden, true);
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
