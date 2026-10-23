// Online link play: a reliable+ordered WebRTC DataChannel between two
// browsers. The room-code signaling server (web/signaling/server.js) relays
// only SDP + ICE; game traffic is peer-to-peer. Loaded after index.js and
// shares its top-level bindings; the index.js RAF loop calls netStep /
// netAfterTick while netMode is set.

// ?signal=ws://... overrides the signaling server; ?linkdelay=N adds N ms of
// latency to every outgoing message. Loopback, RFC 1918 and .local origins
// use a same-host server on :8790 (plain ws); everything else the production
// endpoint (GitHub Pages cannot proxy WebSockets). An https dev serve needs
// ?signal=, since ws: from https: is mixed content.
const NET_PARAMS = new URLSearchParams(location.search);
const NET_LOCAL_HOST =
  location.hostname === "localhost" ||
  location.hostname === "[::1]" ||
  location.hostname.endsWith(".local") ||
  /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(location.hostname) ||
  /^10\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(location.hostname) ||
  /^192\.168\.\d{1,3}\.\d{1,3}$/.test(location.hostname) ||
  /^172\.(1[6-9]|2[0-9]|3[01])\.\d{1,3}\.\d{1,3}$/.test(location.hostname);
const NET_SIGNAL_URL =
  NET_PARAMS.get("signal") ||
  (NET_LOCAL_HOST
    ? "ws://" + location.hostname + ":8790"
    : "wss://signal.dingbat.gg/signal");
const NET_LINK_DELAY = parseInt(NET_PARAMS.get("linkdelay") || "0", 10) || 0;
// SIO-word speculation is off: when the master's outgoing word depends on the
// received word (any real trade) a misprediction ships bytes the guest has
// already consumed (tests/roms/speclinkdep.gba raises "link error").
const NET_SPECULATIVE = false;
// Input rollback: both cores run locally, only per-frame inputs cross the
// network. `?rollback=0` falls back to the RTT-bound SIO path.
const NET_ROLLBACK = NET_PARAMS.get("rollback") !== "0";
// STUN only; symmetric NAT / strict CGNAT pairs fail with a clear error.
const NET_ICE_SERVERS = [{ urls: "stun:stun.l.google.com:19302" }];
const NET_BUF_CAP = 16384; // wasm-side shuttle buffer (frames are tiny)

var netMode = false; // read by the index.js RAF loop, like linkMode
let net = null;      // active session (from modal open to shutdown)
// A rollback session owns the core from rollback_init (rbTryInit), before it
// has started (rollbackMode): the solo core is gone, and its teardown puts the
// session's core back and persists it under currentOriginalName. index.js
// ends such a session before it names or boots another game.
const netHoldsCore = () => !!net?.rb?.inited;

const netModal = document.getElementById("net-modal");
const netTitle = document.getElementById("net-title");
const netStatusDiv = document.getElementById("net-status");
const netCodeInput = /** @type {HTMLInputElement} */ (document.getElementById("net-code-input"));
const netJoinGo = /** @type {HTMLButtonElement} */ (document.getElementById("net-join-go"));
const netStallBadge = document.getElementById("net-stall");
const netSpinner = document.getElementById("net-spinner");
const netTransfer = document.getElementById("net-transfer");

const netModalOpen = () => netModal.classList.contains("open");

const netSetConnecting = (on) => {
  if (netSpinner) netSpinner.hidden = !on;
  netCodeInput.readOnly = on;
  netJoinGo.textContent = on ? "Cancel" : "Connect";
};

// The link screen (two bats either end of the cable) is up while the games
// cross: from the first progress line until the session starts, fails or
// the modal closes. Every status passes through here, so this is the switch.
const NET_TRANSFER_STATUS = /^(Transferring games|Ready — waiting for your friend)/;

const netSetStatus = (msg, isError) => {
  netStatusDiv.textContent = msg;
  netStatusDiv.classList.toggle("net-error", !!isError);
  const transferring = !isError && NET_TRANSFER_STATUS.test(msg);
  if (netTransfer) netTransfer.hidden = !transferring;
  // Connected: the code entry has done its job, the scene and the line stay.
  netModal.classList.toggle("net-transferring", transferring);
  if (isError) netSetConnecting(false);
  // The post-connect pipeline reports here, but this element is in the
  // shared-code view: mirror into the manual view when that is up.
  if (netManualView && !netManualView.hidden && typeof manualSetStatus === "function") {
    manualSetStatus(msg, isError);
  }
};

// A fresh pending session. `attach` = bind to the already-running core with
// no reboot (the only path today).
const makeSession = (attach) => ({
  attach,
  isHost: null,         // decided by the "paired" role (arrival order)
  ws: null,
  pc: null,
  bc: null,             // same-browser BroadcastChannel (no server, no WebRTC)
  localChan: null,      // LocalChannel wrapping bc, once the local path pairs
  abortLocal: null,     // tears down the local path if WebRTC wins the race
  manualChan: null,     // manual-exchange DataChannel (wired only if we end up host)
  manualCode: null,     // our encoded offer, held invisibly for Share/Copy
  codeShared: false,    // Share/Copy happened: pin the code (no auto re-mint)
  code: null,           // normalized shared code (kept so a redial can re-rendezvous)
  redials: 0,           // reconnect dials since the server last answered
  redialTimer: 0,       // pending reconnect after the server socket dropped mid-wait
  rtcDeadline: 0,       // backstop for a pairing whose DataChannel never opens
  dc: null,
  ptr: 0,
  started: false,       // wasm core linked, game ticking
  rtcConnected: false,  // DataChannel open
  sdpIn: false,         // the friend's description arrived for this pairing
  strikes: 0,           // pairings whose descriptions crossed and still never opened
  rewaited: false,      // a pairing ended and we went back to waiting on the code
  helloDone: false,     // wire handshake validated (first successful tick)
  rxQueue: [],
  stallSince: 0,
});
let netAttach = true;   // attach mode of the current/last pending session (for retry)
// Switches the modal to the manual code exchange when the server has not
// answered in time: the dial gets the liveness probe's budget, then the
// rendezvous its own 2 s from the socket opening (a cold cellular TLS dial can
// eat most of 2 s by itself). Disarmed by any server reply (a lone peer on
// "waiting" is healthy).
let manualFallbackTimer = 0;
const MANUAL_FALLBACK_DELAY = 2000;
const SIG_DIAL_TIMEOUT = 4000;
// Sent with every rendezvous, the same across redials: the server drops this
// page's stale seat (a socket that died without it hearing, e.g. iOS suspended
// the tab) instead of pairing us with it or calling the code in use.
const NET_PAGE_ID = (() => {
  const a = new Uint32Array(4);
  crypto.getRandomValues(a);
  return Array.from(a, (x) => x.toString(16).padStart(8, "0")).join("");
})();
// Redial schedule for a server socket that drops after answering at least
// once; then give up into the manual exchange. Any server reply refills it.
const SIG_REDIAL_DELAYS = [1000, 2000, 4000];
// "paired" to DataChannel-open backstop: ICE starved of the far side's
// candidates sits in checking forever without reaching 'failed'. Generous,
// since a slow STUN round can legitimately take 10s+.
const RTC_CONNECT_DEADLINE = 20000;

const closeNetModal = () => {
  netModal.classList.remove("open");
  if (netTransfer) netTransfer.hidden = true;
  netModal.classList.remove("net-transferring");
  netSetConnecting(false);
  releaseWakeLock();
  clearTimeout(manualFallbackTimer);
  if (typeof manualReset === "function") manualReset();
  releaseFocus(netModal);
};

// Liveness probe (page load, tab visible, modal open) so the link modal can
// open straight onto the manual exchange when the server was last seen down.
// Real dials also feed the flag.
let sigServerUp = null; // null = never probed; otherwise last known liveness
let sigProbeAt = 0;
const SIG_PROBE_MIN_INTERVAL = 30000;
const SIG_PROBE_TIMEOUT = 4000; // a silent host is "down", same as an error

const probeSignalServer = () => {
  const now = Date.now();
  if (now - sigProbeAt < SIG_PROBE_MIN_INTERVAL) return;
  sigProbeAt = now;
  // Every outcome is logged with timing: this decides which flow the modal
  // offers, and must be diagnosable from the device.
  const t0 = performance.now();
  const ms = () => Math.round(performance.now() - t0) + "ms";
  let ws;
  try {
    ws = new WebSocket(NET_SIGNAL_URL);
  } catch (e) {
    sigServerUp = false;
    log("netplay: probe " + NET_SIGNAL_URL + " failed to construct: " + (e?.message || e), "warn");
    return;
  }
  // First outcome wins: iOS Safari fires a late error event on a socket
  // closed right after it opens, which would overwrite an "up" verdict.
  let settled = false;
  const timer = setTimeout(() => {
    settled = true;
    sigServerUp = false;
    log("netplay: probe " + NET_SIGNAL_URL + " timed out after " + ms(), "warn");
    try { ws.close(); } catch {}
  }, SIG_PROBE_TIMEOUT);
  ws.onopen = () => {
    if (settled) return;
    settled = true;
    sigServerUp = true;
    clearTimeout(timer);
    log("netplay: probe " + NET_SIGNAL_URL + " ok in " + ms());
    ws.onerror = null; // our own close below must not read as a failure
    try { ws.close(); } catch {}
  };
  ws.onerror = () => {
    if (settled) return;
    settled = true;
    sigServerUp = false;
    clearTimeout(timer);
    log("netplay: probe " + NET_SIGNAL_URL + " errored after " + ms(), "warn");
  };
};
probeSignalServer();
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") probeSignalServer();
});

// True while the connect modal froze the running game (so cancel can thaw it).
let netFrozeGame = false;

// Both players type the same code; the server makes the first arrival host.

const openNetConnect = async (attach) => {
  if (netMode || net) await netShutdown();
  if (linkMode) await exitLinkMode();
  netAttach = attach;
  net = makeSession(attach);
  netTitle.textContent = "Connect link cable";
  netCodeInput.value = "";
  netJoinGo.disabled = false;
  netSetStatus("");
  netSetConnecting(false);
  if (typeof manualReset === "function") manualReset();
  netModal.classList.add("open");
  trapFocus(netModal);
  acquireWakeLock(); // keep the screen (and our sockets/mappings) alive while waiting
  // Server last seen down: open straight onto the manual exchange, re-probing
  // so a recovered server puts the next open back on the normal path.
  if (sigServerUp === false && navigator.onLine) {
    log("netplay: last probe saw the server down — opening onto the manual exchange", "warn");
    probeSignalServer();
    manualEnter();
  }
  // Freeze the game for the whole of code entry, pairing and transfer: left
  // running, its own link handshake times out before the peer connects.
  // Thawed by netShutdown or when the session starts.
  // The player's choice, not a flight's hold (takePlayerPause, index.js).
  netFrozeGame = !!currentRomName && !takePlayerPause();
  if (netFrozeGame) {
    paused = true;
    document.body.classList.add("paused");
    pauseButton.classList.add("paused", "active");
  }
  setTimeout(() => {
    (netManualView && !netManualView.hidden ? manualIn : netCodeInput)?.focus();
  }, 0);
};

const netConnectLabel = document.querySelector("#net-connect span");
window.setNetConnectLabel = (connected) => {
  if (netConnectLabel) netConnectLabel.textContent = connected ? "Disconnect" : "Link Cable";
};

document.getElementById("net-connect").addEventListener("click", () => {
  menuDropdown.hidden = true;
  // Already linked: two-step disconnect (a mis-tap ends the session for both).
  if (net?.started || net?.rb?.inited) {
    menuDisconnectArm.fire();
    return;
  }
  const oext = extOf(currentOriginalName || "");
  if (!ROM_EXTS.includes(oext) || oext === ".nds") { // the DS core has no link yet
    showToast("Link cable needs a GB, GBC, or GBA game");
    return;
  }
  openNetConnect(true);
});

const sigSend = (obj) => {
  if (net?.ws?.readyState === WebSocket.OPEN) net.ws.send(JSON.stringify(obj));
};

const netFail = (msg) => {
  // Setup-phase failure; once the game has started it is a peer-gone case.
  if (net?.started) {
    netPeerGone(msg);
    return;
  }
  log("netplay: " + msg, "warn");
  netSetStatus(msg, true);
  netShutdown({ keepModal: true });
  // Modal still up: re-arm so Connect works again without reopening.
  if (netModalOpen()) {
    net = makeSession(netAttach);
    netJoinGo.disabled = false;
  }
};

// `redial`: a failed dial lands back in the redial ladder (via onclose)
// rather than ending the session.
const sigConnect = (redial = false) =>
  new Promise((resolve) => {
    let ws;
    try {
      ws = new WebSocket(NET_SIGNAL_URL);
    } catch (e) {
      netFail("Couldn't reach the signaling server");
      return resolve(false);
    }
    net.ws = ws;
    // A dead server is only fatal when no other path can carry the session
    // (the same-browser path runs in parallel and may have already won).
    const hasAltPath = () => !!(net && (net.bc || net.dc || net.rtcConnected || net.started));
    let opened = false;
    ws.onopen = () => {
      opened = true;
      sigServerUp = true; // a real dial is as good as a probe
      resolve(true);
    };
    ws.onerror = () => {
      if (opened) return; // an established socket's failure is onclose's to handle
      sigServerUp = false;
      log("netplay: dial " + NET_SIGNAL_URL + " errored before opening", "warn");
      if (hasAltPath() || redial) {
        if (net.bc && !net.dc) {
          netSetStatus("Server unavailable — a second tab of this browser can still link");
        }
        resolve(false);
        return;
      }
      netFail("Couldn't reach the signaling server at " + NET_SIGNAL_URL);
      resolve(false);
    };
    ws.onclose = () => {
      // Our own teardowns null `net` or `net.ws` before closing; a linked
      // session no longer needs the server; a pairing in flight is the RTC
      // deadline's to resolve. What remains is a drop while dialing or
      // waiting: redial with backoff.
      if (!net || net.ws !== ws) return;
      if (net.rtcConnected || net.started) return;
      if (net.pc) return;
      sigRedial();
    };
    ws.onmessage = (e) => {
      let msg;
      try {
        msg = JSON.parse(e.data);
      } catch {
        return;
      }
      onSigMessage(msg);
    };
  });

// Response deadline for a dial or a just-sent rendezvous; any server reply
// disarms it.
const armManualFallback = (session, ms = MANUAL_FALLBACK_DELAY) => {
  clearTimeout(manualFallbackTimer);
  manualFallbackTimer = setTimeout(() => {
    if (net === session && !net.dc && !net.rtcConnected && !net.started) {
      sigServerUp = false;
      manualEnter(true);
    }
  }, ms);
};

const sigRendezvous = (session) => {
  sigSend({ t: "rendezvous", code: session.code, id: NET_PAGE_ID });
  armManualFallback(session);
};

// A dial after the first (a redial, or back to waiting): rendezvous again on
// the same code once it opens.
const sigDialAgain = async (session) => {
  armManualFallback(session, SIG_DIAL_TIMEOUT);
  if (await sigConnect(true)) {
    if (net !== session || session.dc) return;
    sigRendezvous(session);
  }
  // else: that dial's onclose lands back in sigRedial
};

// This pairing is over before linking, but the friend may still come: they
// left the server or were suspended (a phone in the background) before the
// descriptions crossed, or the channel never opened. Drop the peer connection
// and the socket and rendezvous again on the same code, as if Connect had just
// been pressed (formal/WebState/LinkPairing.lean, `rewait`).
const sigRewait = (why) => {
  const session = net;
  if (!session || !session.code || session.rtcConnected || session.started) return;
  log("netplay: " + why + " — back to waiting on the code", "warn");
  clearTimeout(session.rtcDeadline);
  clearTimeout(session.redialTimer);
  try { session.pc?.close(); } catch {}
  session.pc = null;
  session.dc = null; // a host's channel belonged to that pc
  session.isHost = null;
  session.sdpIn = false;
  session.rewaited = true;
  const ws = session.ws;
  session.ws = null;
  if (ws) {
    try { ws.onopen = ws.onclose = ws.onerror = ws.onmessage = null; ws.close(); } catch {}
  }
  // The dial counts against the redial ladder: a server that dies under it
  // gets the ladder's remaining steps, then the manual exchange.
  if (session.redials++ >= SIG_REDIAL_DELAYS.length) {
    sigServerUp = false;
    manualEnter(true);
    return;
  }
  netSetStatus("Waiting for your friend…");
  sigDialAgain(session);
};

// The pairing deadline, or ICE giving up: a pairing whose descriptions crossed
// and still never opened is a strike, and two in a row are the NAT verdict;
// otherwise the friend stopped answering, so wait for them again.
const rtcGaveUp = (session, pc, why) => {
  if (net !== session || session.pc !== pc || session.rtcConnected || session.started) return;
  if (session.sdpIn && ++session.strikes >= 2) {
    netFail("Could not connect peer-to-peer (a strict NAT on one side may be blocking it)");
    return;
  }
  sigRewait(why);
};

// The server socket died mid-wait; the room died with it, so reconnect and
// re-rendezvous with the same code (both peers do, so a restart re-pairs).
const sigRedial = () => {
  const session = net;
  if (!session || !session.code) return;
  if (!navigator.onLine) {
    manualEnter(true);
    return;
  }
  clearTimeout(manualFallbackTimer);
  const attempt = session.redials++;
  if (attempt >= SIG_REDIAL_DELAYS.length) {
    sigServerUp = false;
    manualEnter(true);
    return;
  }
  netSetStatus("Reconnecting to the linking server…");
  log("netplay: signaling socket dropped — redial " + (attempt + 1) + "/" +
      SIG_REDIAL_DELAYS.length + " in " + SIG_REDIAL_DELAYS[attempt] + "ms", "warn");
  session.redialTimer = setTimeout(() => {
    if (net !== session || session.dc || session.rtcConnected || session.started) return;
    sigDialAgain(session);
  }, SIG_REDIAL_DELAYS[attempt]);
};

const onSigMessage = async (msg) => {
  if (!net) return;
  const session = net;
  // Any reply is proof of life: disarm the fallback, refill the redial budget.
  clearTimeout(manualFallbackTimer);
  session.redials = 0;
  sigServerUp = true;
  if (msg.t !== "sdp" && msg.t !== "ice") {
    log("netplay: server: " + msg.t + (msg.role ? " " + msg.role : "") +
        (msg.msg ? " " + msg.msg : ""));
  }
  // The pc this message is about: an await can outlive it (back to waiting
  // closes it), and its errors are then nobody's business.
  const pc = session.pc;
  try {
    switch (msg.t) {
      case "waiting":
        netSetStatus(session.rewaited ? "Waiting for your friend…" : "");
        break;
      case "paired":
        // host = WebRTC offerer = unit 0.
        session.isHost = msg.role === "host";
        netSetStatus("Friend found — connecting…");
        await startRtc(session.isHost);
        break;
      case "sdp":
        if (!pc) return;
        session.sdpIn = true; // the friend is alive and paired with us
        await pc.setRemoteDescription(msg.d);
        if (msg.d.type === "offer") {
          const answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          if (net !== session || session.pc !== pc) return;
          sigSend({ t: "sdp", d: pc.localDescription });
        }
        break;
      case "ice":
        if (pc && msg.c) await pc.addIceCandidate(msg.c).catch(() => {});
        break;
      case "peer-closed":
        if (session.rtcConnected) break;
        // The friend left the server. With the descriptions crossed it has
        // most likely linked and released the room a round trip before our
        // channel opens: leave it to our channel, or the deadline. Otherwise
        // it left before pairing: wait for it again.
        if (session.sdpIn) {
          log("netplay: friend left the server mid-pairing — waiting on the channel");
          break;
        }
        sigRewait("friend left before pairing");
        break;
      case "error":
        netFail(msg.msg || "Connection error");
        break;
    }
  } catch (e) {
    if (net !== session || (pc && session.pc !== pc)) return; // superseded
    netFail("Connection setup failed: " + e.message);
  }
};

const startRtc = async (isOfferer) => {
  const session = net;
  const pc = new RTCPeerConnection({ iceServers: NET_ICE_SERVERS });
  session.pc = pc;
  session.sdpIn = false;
  // A checking phase that never starts never reaches 'failed' on its own.
  clearTimeout(session.rtcDeadline);
  session.rtcDeadline = setTimeout(
    () => rtcGaveUp(session, pc, "no link " + RTC_CONNECT_DEADLINE / 1000 + " s after pairing"),
    RTC_CONNECT_DEADLINE
  );
  pc.onicecandidate = (e) => {
    if (e.candidate && net === session && session.pc === pc) sigSend({ t: "ice", c: e.candidate });
  };
  pc.onconnectionstatechange = () => {
    if (!net || net.pc !== pc) return;
    const st = pc.connectionState;
    if (net.started && rbCanResume()) rbWatchDisconnected(pc, st);
    if (st === "failed") {
      if (net.started) rbDropped("connection failed", "Peer connection lost");
      else if (net.rtcConnected) netFail("Peer connection lost");
      else rtcGaveUp(session, pc, "ICE failed");
    } else if (st === "disconnected" && net.started && rbCanResume()) {
      // It may recover; "failed" redials.
      log("netplay: connection disconnected — waiting");
    } else if (st === "disconnected" && net.started && rbPeerAwaySince) {
      // A friend who said they're away may be suspended (an iPhone app
      // past its background time, iPhone Safari): they stop answering, and
      // "disconnected" recovers if they wake before the browser's "failed"
      // (about 10 s on), which still ends it above.
      log("netplay: connection disconnected while the friend is away — waiting");
    } else if (st === "connected" && net.started && rbPeerAwaySince) {
      log("netplay: connection back while the friend is away");
    } else if ((st === "disconnected" || st === "closed") && net.started) {
      rbDropped("connection " + st, "Peer connection lost");
    }
  };
  if (isOfferer) {
    wireChannel(pc.createDataChannel("link", { ordered: true }));
    try {
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
    } catch (e) {
      if (net !== session || session.pc !== pc) return; // back to waiting meanwhile
      throw e;
    }
    if (net !== session || session.pc !== pc) return;
    sigSend({ t: "sdp", d: pc.localDescription });
  } else {
    pc.ondatachannel = (e) => {
      if (net === session && session.pc === pc) wireChannel(e.channel);
    };
  }
};

const wireChannel = (dc) => {
  // Local BroadcastChannel and server+WebRTC race; the loser is torn down here.
  if (net.dc) {
    try {
      dc.close?.(true); // silent: don't signal "bye"
    } catch {}
    return;
  }
  net.dc = dc;
  if (net.abortLocal && dc !== net.localChan) net.abortLocal();
  net.abortLocal = null;
  dc.binaryType = "arraybuffer";
  dc.onopen = () => {
    net.rtcConnected = true;
    clearTimeout(net.rtcDeadline);
    // Linked: closing the socket also releases our room on the server at
    // once instead of after the TTL (pinned by web/signaling/server.test.mjs).
    try {
      net.ws?.close();
    } catch {}
    net.ws = null;
    netSetStatus("Connected — linking…");
    if (NET_ROLLBACK) {
      rbConnect().catch((e) => netFail("Couldn't start the session: " + e.message));
    } else {
      launchNetRom().catch((e) => netFail("Couldn't start the game: " + e.message));
    }
  };
  dc.onmessage = (e) => {
    if (net?.dc !== dc) return; // let go of (a redial adopted another)
    NET_ROLLBACK ? rbMessage(e.data) : netReceive(new Uint8Array(e.data));
  };
  dc.onclose = () => {
    if (!net || net.dc !== dc || net.ending) return;
    if (net.started) rbDropped("channel closed", "Peer disconnected");
    // Dropped mid-handshake: surface it rather than leave the game frozen.
    else if (net.rb && !net.rb.inited) netFail("Connection lost during setup");
  };
};

// Same-browser path: two tabs of one browser profile rendezvous on a
// BroadcastChannel keyed by the code and carry the same wire traffic a
// DataChannel would. LocalChannel mimics only the RTCDataChannel surface
// wireChannel()/rbSend*()/rbDrain() touch.

const LOCAL_PREFIX = "dingbat-link-"; // BroadcastChannel name = prefix + code

const netRandId = () => {
  const a = new Uint32Array(1);
  crypto.getRandomValues(a);
  return a[0] || 1; // 0 is reserved as "unset"
};

// bufferedAmount is faked so rbSendRom's backpressure loop yields between
// bursts (BroadcastChannel has no send buffer; a multi-MB synchronous flood
// would block the main thread).
class LocalChannel {
  constructor(bc) {
    this.bc = bc;
    this.readyState = "open";
    this.binaryType = "arraybuffer";
    this.bufferedAmount = 0;
    this.bufferedAmountLowThreshold = 0;
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this._low = new Set();
    this._flushing = false;
    this._onBc = (e) => {
      const m = e.data;
      if (!m || m.ch !== "link") return;
      if (m.t === "data") this.onmessage?.({ data: m.buf });
      else if (m.t === "bye") this.close(true);
    };
    bc.addEventListener("message", this._onBc);
  }
  addEventListener(type, fn) {
    if (type === "bufferedamountlow") this._low.add(fn);
  }
  removeEventListener(type, fn) {
    if (type === "bufferedamountlow") this._low.delete(fn);
  }
  send(buf) {
    if (this.readyState !== "open") return;
    // The caller reuses its buffer: postMessage gets a standalone copy.
    const ab =
      buf instanceof ArrayBuffer
        ? buf.slice(0)
        : buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
    this.bc.postMessage({ ch: "link", t: "data", buf: ab });
    this.bufferedAmount += ab.byteLength;
    if (!this._flushing) {
      this._flushing = true;
      setTimeout(() => {
        this.bufferedAmount = 0;
        this._flushing = false;
        this._low.forEach((fn) => fn());
      }, 0);
    }
  }
  close(fromPeer) {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    try {
      if (!fromPeer) this.bc.postMessage({ ch: "link", t: "bye" });
    } catch {}
    try {
      this.bc.removeEventListener("message", this._onBc);
    } catch {}
    try {
      this.bc.close();
    } catch {}
    this.onclose?.();
  }
}

// Listens for another tab on `code` until a peer appears, WebRTC wins, or
// the user cancels, so the two players need not hit Connect at once.
const startLocalLink = (code) => {
  const session = net;
  let bc;
  try {
    bc = new BroadcastChannel(LOCAL_PREFIX + code);
  } catch {
    return; // no BroadcastChannel support
  }
  session.bc = bc;
  const myId = netRandId();

  const onMsg = (e) => {
    if (net !== session || net.dc) return;
    const m = e.data;
    if (!m || m.ch !== "hello") return;
    if (m.t === "hi") {
      // Answer so the peer learns us: it may have opened after our own
      // announce (BroadcastChannel keeps no history).
      try {
        bc.postMessage({ ch: "hello", t: "yo", id: myId, to: m.id });
      } catch {}
      pair(m.id);
    } else if (m.t === "yo" && m.to === myId) {
      pair(m.id);
    }
  };

  // Higher nonce = host; both tabs compute the same winner.
  const pair = (peerId) => {
    if (net !== session || net.dc || peerId === myId) return;
    bc.removeEventListener("message", onMsg);
    session.isHost = myId > peerId;
    const chan = new LocalChannel(bc);
    session.localChan = chan; // marks the local path as the winner in wireChannel
    wireChannel(chan);
    chan.onopen?.();
  };

  session.abortLocal = () => {
    try {
      bc.removeEventListener("message", onMsg);
      bc.close();
    } catch {}
    if (net === session) session.bc = null;
  };

  bc.addEventListener("message", onMsg);
  try {
    bc.postMessage({ ch: "hello", t: "hi", id: myId });
  } catch {}
};

// Manual code exchange (server unreachable): each side shows one compact
// code (SDPCodec) and pastes the friend's; the post-connect flow is then the
// server path's. Differences: ICE gathering runs to completion and one
// bundled description is encoded (nothing to trickle over); the exchange is
// symmetric, both sides offer and each rewrites the peer's blob into the
// answer to its own offer (SDPCodec.answerFrom) with DTLS roles from a code
// string comparison (pinned by web/manualpair.test.mjs). Same-LAN pairing
// rides on the mDNS host candidate, which Chrome and Safari both resolve.

const MANUAL_GATHER_TIMEOUT = 3500; // ms cap on ICE gathering once a public address is in hand
// Without a srflx candidate a code can only pair on its own LAN, so wait
// longer when STUN is merely slow (cellular CGNAT).
const MANUAL_GATHER_EXTENDED = 8000;

const netConnectView = document.getElementById("net-connect-view");
const netManualView = document.getElementById("net-manual-view");
const manualIn = /** @type {HTMLInputElement} */ (document.getElementById("net-manual-in"));
const manualCopyBtn = /** @type {HTMLButtonElement} */ (document.getElementById("net-manual-copy"));
const manualConfirm = /** @type {HTMLButtonElement} */ (document.getElementById("net-manual-confirm"));
const manualStatusDiv = document.getElementById("net-manual-status");

const manualSetStatus = (msg, isError) => {
  if (!manualStatusDiv) return;
  manualStatusDiv.textContent = msg || "";
  manualStatusDiv.classList.toggle("net-error", !!isError);
};

// Resolves on gathering 'complete' (or the null-candidate sentinel), with
// timeouts so a stuck STUN server cannot hang the flow.
const manualGather = (pc) =>
  new Promise((resolve) => {
    if (pc.iceGatheringState === "complete") return resolve();
    let done = false;
    let sawSrflx = false;
    const finish = () => { if (done) return; done = true; resolve(); };
    pc.addEventListener("icegatheringstatechange", () => {
      if (pc.iceGatheringState === "complete") finish();
    });
    pc.addEventListener("icecandidate", (e) => {
      if (!e.candidate) return finish();
      if (e.candidate.candidate && e.candidate.candidate.includes(" srflx ")) sawSrflx = true;
    });
    setTimeout(() => { if (sawSrflx) finish(); }, MANUAL_GATHER_TIMEOUT);
    setTimeout(finish, MANUAL_GATHER_EXTENDED);
  });

// Candidate-pair dump for a dead pairing: sent>0 got=0 means our checks
// vanish into a NAT; no pairs means nothing could be built from the remote list.
const logIcePairs = async (pc) => {
  try {
    const stats = await pc.getStats();
    const cand = {};
    stats.forEach((r) => {
      if (r.type === "local-candidate" || r.type === "remote-candidate")
        cand[r.id] = r.candidateType || "?";
    });
    stats.forEach((r) => {
      if (r.type === "candidate-pair")
        log("netplay: pair " + (cand[r.localCandidateId] || "?") + "→" +
            (cand[r.remoteCandidateId] || "?") + " " + r.state +
            " sent=" + (r.requestsSent ?? 0) + " got=" + (r.responsesReceived ?? 0), "warn");
    });
  } catch {}
};

const manualConnState = (pc) => () => {
  if (!net || net.pc !== pc) return;
  const st = pc.connectionState;
  log("netplay: manual pc " + st + " ice=" + pc.iceConnectionState);
  if (st === "failed") {
    logIcePairs(pc); // best-effort: the teardown below races it
    if (net.rtcConnected) {
      netFail("Peer connection lost");
      return;
    }
    // The traded codes are spent with the PC; both sides fail together, so
    // both regenerate together.
    netFail("Couldn't connect with those codes");
    if (netModalOpen() && netManualView && !netManualView.hidden) {
      manualSetStatus("Couldn't connect — trade these fresh codes and try again", true);
      manualPrepare();
    }
  } else if ((st === "disconnected" || st === "closed") && net.started) {
    netPeerGone("Peer connection lost");
  }
};

// The DataChannel must exist before the offer (its m-line), but which side
// wires it is unknown until the friend's code arrives, so it waits unwired in
// net.manualChan. NAT mappings behind a code decay in under a minute idle, so
// an unshared code is re-minted on a timer and on return to the foreground
// (minting at the tap is too slow: iOS voids the user activation before
// navigator.share may run). A shared code is pinned, since the friend holds it.
const MANUAL_CODE_MAX_AGE = 45000;
let manualFreshTimer = 0;

// Candidate mix of an SDP ("srflx/v4 host/mdns"), for the log.
const candKinds = (sdp) =>
  SDPCodec.fields(sdp).candidates.map((c) => {
    const [type, addr] = c.split("|");
    return type + (addr.includes(":") ? "/v6" : addr.endsWith(".local") ? "/mdns" : "/v4");
  });

const manualButtonsEnabled = (on) => {
  if (manualCopyBtn) manualCopyBtn.disabled = !on;
  if (manualShareBtn) manualShareBtn.disabled = !on;
};

const manualPrepare = async (opts) => {
  if (!net) net = makeSession(netAttach);
  const session = net;
  session.manualCode = null;
  session.codeShared = false;
  clearTimeout(manualFreshTimer);
  manualButtonsEnabled(false);
  try { session.pc?.close(); } catch {}
  if (!opts?.keepFriendBox) {
    if (manualIn) { manualIn.value = ""; manualIn.readOnly = false; }
    if (manualConfirm) manualConfirm.disabled = true;
  }
  const mintT0 = performance.now();
  try {
    const pc = new RTCPeerConnection({ iceServers: NET_ICE_SERVERS });
    session.pc = pc;
    pc.onconnectionstatechange = manualConnState(pc);
    // STUN/TURN failures surface here and nowhere else.
    pc.addEventListener("icecandidateerror", (/** @type {*} */ e) => {
      log("netplay: ICE candidate error " + (e.errorCode || "?") + " " +
          (e.errorText || "") + (e.url ? " via " + e.url : ""), "warn");
    });
    session.manualChan = pc.createDataChannel("link", { ordered: true });
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await manualGather(pc);
    if (net !== session || session.pc !== pc) return;
    const enc = SDPCodec.encode(pc.localDescription);
    if (!enc) throw new Error("couldn't encode the offer");
    session.manualCode = enc;
    manualButtonsEnabled(true);
    // srflx = internet-capable; mDNS-host only = this LAN only.
    const kinds = candKinds(pc.localDescription.sdp);
    log("netplay: manual code minted in " + Math.round(performance.now() - mintT0) +
        "ms: " + (kinds.join(" ") || "no candidates"));
    if (!kinds.some((k) => k.startsWith("srflx"))) {
      log("netplay: manual code has no public address — it can only pair on this network", "warn");
    }
    manualArmFresh(session);
  } catch (e) {
    if (net === session) {
      manualSetStatus("Couldn't prepare a code: " + (e.message || e), true);
    }
  }
};

const manualArmFresh = (session) => {
  clearTimeout(manualFreshTimer);
  manualFreshTimer = setTimeout(() => {
    if (net !== session || session.codeShared || session.rtcConnected) return;
    if (!netManualView || netManualView.hidden) return;
    if (manualIn?.value || manualIn?.readOnly) return;
    manualPrepare({ keepFriendBox: true });
  }, MANUAL_CODE_MAX_AGE);
};

// Switch to the manual exchange. `attemptFailed`: a live attempt found the
// server unreachable, so say so. Cancels the server/local attempts (a
// distinct rendezvous) but keeps the session.
const manualEnter = (attemptFailed) => {
  if (!netModalOpen() || !net) return;
  if (netManualView && !netManualView.hidden) return;
  if (!navigator.onLine) {
    netSetStatus("No network connection — join the same Wi-Fi as your friend and retry", true);
    return;
  }
  clearTimeout(manualFallbackTimer);
  clearTimeout(net.redialTimer);
  clearTimeout(net.rtcDeadline);
  if (attemptFailed) {
    log("netplay: server attempt failed — switching to the manual code exchange", "warn");
  }
  // Detach the socket handlers before closing, else ws.onclose fires netFail
  // and destroys the session being kept.
  const ws = net.ws;
  if (ws) {
    try { ws.onopen = ws.onclose = ws.onerror = ws.onmessage = null; ws.close(); } catch {}
  }
  net.ws = null;
  if (net.abortLocal) { try { net.abortLocal(); } catch {} net.abortLocal = null; }
  net.bc = null;
  netSetConnecting(false);
  netSetStatus("");
  manualSetStatus(
    attemptFailed ? "Couldn't connect — the linking server didn't respond" : "",
    true
  );
  if (netConnectView) netConnectView.hidden = true;
  if (netManualView) netManualView.hidden = false;
  manualPrepare();
};

// Back to the shared-code view; the prepared offer is abandoned.
const manualBack = () => {
  if (!net || net.dc || net.rtcConnected || net.started) return;
  try { net.pc?.close(); } catch {}
  net = makeSession(netAttach);
  manualReset();
  netSetConnecting(false);
  netSetStatus("");
  netJoinGo.disabled = false;
  setTimeout(() => netCodeInput?.focus(), 0);
};

const manualReset = () => {
  if (netManualView) netManualView.hidden = true;
  if (netConnectView) netConnectView.hidden = false;
  clearTimeout(manualFreshTimer);
  manualButtonsEnabled(false);
  if (manualIn) { manualIn.value = ""; manualIn.readOnly = false; }
  if (manualConfirm) manualConfirm.disabled = true;
  manualSetStatus("");
};

// Confirm: the friend's code becomes the answer to our offer (both sides do
// this; the code comparison assigns DTLS roles and the host seat).
const manualConfirmGo = async () => {
  const session = net;
  if (!session?.pc || !session.manualCode) return;
  const friendCode = (manualIn?.value || "").trim().replace(/\s+/g, "");
  if (!friendCode) return;
  if (friendCode === session.manualCode) {
    manualSetStatus("That's your own code — paste your friend's", true);
    return;
  }
  // Log the friend's candidate mix and code age (a cross-network pairing
  // lives on their srflx being fresh).
  try {
    const fd = SDPCodec.decode(friendCode);
    if (fd) {
      const age = fd.mintedAt
        ? Math.max(0, Math.round(Date.now() / 1000 - fd.mintedAt)) + "s old"
        : "age unknown";
      log("netplay: friend's code: " + candKinds(fd.sdp).join(" ") + " — " + age);
    }
  } catch {}
  const isHost = session.manualCode > friendCode;
  // The peer takes the opposite DTLS role.
  const remote = SDPCodec.answerFrom(friendCode, isHost ? "active" : "passive");
  if (!remote) {
    manualSetStatus("That code didn't read cleanly — recopy it and try again", true);
    return;
  }
  session.isHost = isHost;
  if (isHost) {
    wireChannel(session.manualChan);
  } else {
    session.pc.ondatachannel = (e) => wireChannel(e.channel);
  }
  try {
    await session.pc.setRemoteDescription(remote);
  } catch (e) {
    manualSetStatus("Pairing failed: " + (e.message || e), true);
    return;
  }
  if (manualIn) manualIn.readOnly = true;
  if (manualConfirm) manualConfirm.disabled = true;
  manualSetStatus("Connecting…");
  // Pairing heartbeat for the log; self-clears on success or teardown.
  const progress = setInterval(async () => {
    if (net !== session || session.rtcConnected || session.started || !session.pc) {
      clearInterval(progress);
      return;
    }
    let pairs = 0, sent = 0, got = 0;
    try {
      const stats = await session.pc.getStats();
      stats.forEach((r) => {
        if (r.type === "candidate-pair") {
          pairs++;
          sent += r.requestsSent ?? 0;
          got += r.responsesReceived ?? 0;
        }
      });
    } catch {}
    log("netplay: pairing… ice=" + session.pc.iceConnectionState +
        " pairs=" + pairs + " sent=" + sent + " got=" + got);
  }, 5000);
  // A remote list with no routable candidate leaves ICE in checking forever;
  // bound it like the server path, with the same fresh-codes recovery.
  clearTimeout(session.rtcDeadline);
  session.rtcDeadline = setTimeout(async () => {
    if (net !== session || session.rtcConnected || session.started) return;
    log("netplay: manual pairing deadline — no connection in " +
        RTC_CONNECT_DEADLINE + "ms (ice=" + session.pc?.iceConnectionState + ")", "warn");
    if (session.pc) await logIcePairs(session.pc);
    if (net !== session || session.rtcConnected || session.started) return;
    netFail("Couldn't connect with those codes");
    if (netModalOpen() && netManualView && !netManualView.hidden) {
      manualSetStatus("Couldn't connect — trade these fresh codes and try again", true);
      manualPrepare();
    }
  }, RTC_CONNECT_DEADLINE);
};

manualConfirm?.addEventListener("click", manualConfirmGo);
manualIn?.addEventListener("input", () => {
  manualConfirm.disabled = manualIn.readOnly || manualIn.value.trim().length === 0;
});
manualCopyBtn?.addEventListener("click", async () => {
  const code = net?.manualCode;
  if (!code) return;
  if (net) net.codeShared = true;
  clearTimeout(manualFreshTimer);
  try {
    await navigator.clipboard.writeText(code);
  } catch {
    // Clipboard API needs a secure context (and can be denied).
    const ta = document.createElement("textarea");
    ta.value = code;
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); } catch {}
    ta.remove();
  }
  showToast("Code copied");
});

// Share sheet: only where the Web Share API exists and the primary pointer
// is a finger.
const manualShareBtn = /** @type {HTMLButtonElement} */ (document.getElementById("net-manual-share"));
if (manualShareBtn && navigator.share && matchMedia("(pointer: coarse)").matches) {
  manualShareBtn.hidden = false;
}
manualShareBtn?.addEventListener("click", async () => {
  const code = net?.manualCode;
  if (!code) return;
  if (net) net.codeShared = true;
  clearTimeout(manualFreshTimer);
  try {
    // Bare code, no prose: whatever the friend pastes back must decode.
    await navigator.share({ text: code });
  } catch {
    // A dismissed sheet rejects with AbortError.
  }
});

// Screen wake lock while the modal is up: iOS auto-lock suspends Safari and
// kills the NAT mappings and signaling socket behind the wait. The OS drops
// the lock on backgrounding, so it re-arms on return.
let screenLock = null;
const acquireWakeLock = async () => {
  try {
    const lock = (await navigator.wakeLock?.request("screen")) || null;
    // Hold one lock, and only while the modal is up: the session can start
    // (closeNetModal) while the request is out, and every return to the tab
    // re-arms, so two requests can be out at once.
    releaseWakeLock();
    if (netModalOpen()) screenLock = lock;
    else lock?.release();
  } catch {} // denied (low power mode etc.)
};
const releaseWakeLock = () => {
  try { screenLock?.release(); } catch {}
  screenLock = null;
};

let modalHiddenAt = Date.now();
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") {
    modalHiddenAt = Date.now();
    return;
  }
  if (!netModalOpen()) return;
  acquireWakeLock();
  // An unshared code re-mints silently; a shared one only after being away
  // long enough for its NAT mappings to have died, and says so.
  if (!net || !netManualView || netManualView.hidden) return;
  if (net.rtcConnected || net.started || manualIn?.readOnly) return;
  if (!net.manualCode) return;
  if (!net.codeShared) {
    manualPrepare({ keepFriendBox: true });
  } else if (Date.now() - modalHiddenAt > MANUAL_CODE_MAX_AGE) {
    manualPrepare({ keepFriendBox: true });
    manualSetStatus("Away a while — your code was refreshed, share the new one");
  }
});
// Stop propagation so the page's key handlers never see the field; that
// also hides Escape from the document handler, so dismiss here directly.
manualIn && ["keydown", "keypress", "keyup"].forEach((t) =>
  manualIn.addEventListener(t, (/** @type {KeyboardEvent} */ e) => {
    if (t === "keydown" && e.key === "Enter" && !manualConfirm.disabled) manualConfirmGo();
    if (t === "keydown" && e.key === "Escape") netDismissModal();
    e.stopPropagation();
  })
);

// Input-rollback wire protocol over the DataChannel (first byte = kind):
//   0 hello        : [0][epoch u32][romHash u32][len u32][crc32 u32][fnv u32]
//                    (host's epoch is the shared clock; romHash covers the
//                    first 1 MB, the rest identify the whole ROM; builds
//                    before the whole-ROM fields send the first 9 bytes)
//   1 input        : [1][frame i32][bits u16]      (this peer's buttons for a frame)
//   2 state-begin  : [2][len u32]                  (full save-state, chunked)
//   3 state-chunk  : [3][bytes…]
//   4 rom-begin    : [4][len u32]                  (this peer's ROM, chunked)
//   5 rom-chunk    : [5][bytes…]
//   6 ready        : [6]                           (cores built + states loaded)
//   7 speed        : [7][on u8][n u32]              (2x fast-forward toggle — both cores)
//   8 pause        : [8][on u8][n u32]              (n numbers the press: see rbPress;
//                                                    builds before it send [kind][on u8])
//   9 have-rom     : [9]                           (your ROM is in my library: don't send it)
//  10 need-rom     : [10]                          (send me your ROM)
//  11 away         : [11][on u8]                    (my tab is hidden: my game is paused)
//  12 resume-info  : [12][sid u32][retry code]     (host deals it at start; the guest echoes it)
//  13 resume       : [13][sid u32][last frame u32][flags u8] (first on a redialed channel)
//  14 bye          : [14][why u8]                  (a deliberate end: don't redial; why 0 =
//                                                    left, 1 = gave up; builds before it send [14])
// Both peers run both cores (core 0 = host's game, core 1 = guest's): each
// side's save-state is exchanged and loaded into the matching core, then only
// inputs cross the network. When the hello hashes differ (cross-game trade)
// each peer also streams its ROM so both hold the same {host, guest} pair,
// unless the friend already has it: a peer whose hello names the whole ROM
// looks the friend's up in its library and answers have-rom or need-rom, and
// a ROM goes over the wire only on need-rom (to an older build, which never
// answers, it goes at once, as before).
// The "ready" barrier keeps either peer from ticking until both have booted.

const RB_HELLO = 0, RB_INPUT = 1, RB_STATE_BEGIN = 2, RB_STATE_CHUNK = 3;
const RB_ROM_BEGIN = 4, RB_ROM_CHUNK = 5, RB_READY = 6, RB_SPEED = 7;
const RB_PAUSE = 8, RB_HAVE_ROM = 9, RB_NEED_ROM = 10, RB_AWAY = 11;
const RB_RESUME_INFO = 12, RB_RESUME = 13, RB_BYE = 14, RB_PING = 15;
// A started link says something this often even when nothing else flows
// (both paused, a stall): a drop after a long pause is judged by how long
// the friend has been silent, and a quiet link mustn't read as one given up.
const RB_PING_MS = 20000;
const RB_HELLO_LEN = 21; // with the whole-ROM identity
const RB_CHUNK = 16384; // DataChannel-safe chunk size for state + ROM frames
// Send-buffer high water while streaming a ROM; well under Chrome's ~16 MB
// cap, past which send() throws and the dropped chunk corrupts the ROM.
const RB_SEND_HIGH_WATER = 4 * 1024 * 1024;
const RB_ROM_MAX = 48 * 1024 * 1024; // sanity cap on an announced ROM length
// FS extension of the session's ROMs; rollback_init dispatches GB/GBA on it.
let rbExt = ".gba";

const rbHash = (bytes) => {
  // FNV-1a over the first 1 MB: enough to tell ROM versions apart.
  let h = 0x811c9dc5 >>> 0;
  const n = Math.min(bytes.length, 1 << 20);
  for (let i = 0; i < n; i++) h = Math.imul(h ^ bytes[i], 0x01000193) >>> 0;
  return h >>> 0;
};

// The whole ROM's identity: its length, CRC-32 and FNV-1a over every byte.
// What a library copy must match exactly before it stands in for the
// friend's (no crypto.subtle: it is missing on plain-http LAN pages).
let rbCrcTable = null;
const rbRomId = (bytes) => {
  if (!rbCrcTable) {
    rbCrcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      rbCrcTable[n] = c >>> 0;
    }
  }
  let crc = 0xffffffff, h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    crc = rbCrcTable[(crc ^ b) & 0xff] ^ (crc >>> 8);
    h = Math.imul(h ^ b, 0x01000193);
  }
  return { len: bytes.length, crc: (crc ^ 0xffffffff) >>> 0, fnv: h >>> 0 };
};
const rbSameRom = (a, b) => !!a && !!b && a.len === b.len && a.crc === b.crc && a.fnv === b.fnv;

// Library games' identities, so a later link reads only the likely match.
// A hint, never trusted: the bytes are measured again before use.
const RB_ROM_IDS_KEY = "linkromids";

// A library game whose bytes are exactly the ROM `want` names, or null.
const rbFindLocalRom = async (want) => {
  await loadRomSizes();
  const ids = (await dbGet(RB_ROM_IDS_KEY)) || {};
  const names = (await getRecentMeta()).map((r) => r?.name).filter(Boolean);
  // Games already known to be it first, then any of that size (or of no
  // recorded size) not measured yet.
  const known = names.filter((n) => rbSameRom(ids[n], want));
  const fresh = names.filter((n) => !known.includes(n) &&
    (!ids[n] || ids[n].len !== romSizeOf(n)) && [0, want.len].includes(romSizeOf(n)));
  // Measuring a big library the first time is cut off after a few seconds
  // (the friend is waiting on the answer); what was measured is kept, so a
  // later link goes further.
  const until = Date.now() + 4000;
  let changed = false, found = null;
  for (const n of [...known, ...fresh]) {
    if (!known.includes(n) && Date.now() > until) break;
    const bytes = await getRomBytes(n);
    if (!bytes) continue;
    ids[n] = rbRomId(bytes);
    changed = true;
    if (rbSameRom(ids[n], want)) { found = bytes; break; }
  }
  if (changed) await dbPut(RB_ROM_IDS_KEY, ids).catch(() => {});
  return found;
};

// The friend named its whole ROM: answer whether it needs to come over.
const rbAnswerRom = async (rb, want) => {
  let bytes = null;
  try { bytes = await rbFindLocalRom(want); } catch {}
  if (net?.rb !== rb) return;
  if (bytes) {
    rb.remoteRom = bytes;
    rb.remoteRomLen = rb.remoteRomGot = bytes.length;
    rb.romFromLibrary = true;
    log("netplay: your friend's game is in the library — not transferred");
    rbSend(new Uint8Array([RB_HAVE_ROM]));
  } else {
    rbSend(new Uint8Array([RB_NEED_ROM]));
  }
  rbShowXferProgress();
  rbTryInit();
};

const rbSend = (buf) => {
  if (!net?.dc || net.dc.readyState !== "open") return;
  try {
    net.dc.send(buf);
  } catch {}
};

const rbSendInput = (frame, bits) => {
  const rb = net?.rb;
  if (rb) {
    rbLogSent(rb, frame, bits);
    if (rb.reconnecting) return; // resent once the friend says what it has
  }
  rbSendInputWire(frame, bits);
};

const rbSendInputWire = (frame, bits) => {
  const buf = new ArrayBuffer(7);
  const v = new DataView(buf);
  v.setUint8(0, RB_INPUT);
  v.setInt32(1, frame);
  v.setUint16(5, bits);
  if (NET_LINK_DELAY > 0) {
    const dc = net?.dc;
    setTimeout(() => { if (net?.dc === dc) rbSend(buf); }, NET_LINK_DELAY);
  } else {
    rbSend(buf);
  }
};

// Pause and 2x are one value shared by both sides, and either player can
// change it, so two presses can cross on the wire. Each press is numbered
// one past the highest this side has seen; both sides keep the highest
// press, the host's on a tie, so once neither press is in flight they hold
// the same one, whatever order they arrived in (a "now" state message, the
// last to arrive wins, split them: each side's last was the other's).
// formal/WebState/LinkResume.lean `presses_agree`.
const rbNewReg = (on) => ({ on, n: 0, host: true });
const rbBeats = (a, b) => a.n > b.n || (a.n === b.n && a.host && !b.host);

const rbPress = (kind, reg, on) => {
  reg.on = on;
  reg.n++;
  reg.host = !!net.isHost;
  const buf = new ArrayBuffer(6);
  const v = new DataView(buf);
  v.setUint8(0, kind);
  v.setUint8(1, on ? 1 : 0);
  v.setUint32(2, reg.n);
  rbSend(buf);
};

// The friend's press: taken only if it beats the one we hold.
const rbPressIn = (reg, v) => {
  const on = v.getUint8(1) === 1;
  // A build before the numbering: as it was, the last to arrive wins.
  if (v.byteLength < 6) {
    reg.on = on;
    return true;
  }
  const cand = { on, n: v.getUint32(2), host: !net.isHost };
  if (!rbBeats(cand, reg)) return false;
  Object.assign(reg, cand);
  return true;
};

// 2x drives both peers: a one-sided 2x just stalls at the prediction window.
const rbSendSpeed = (on) => {
  const rb = net?.rb;
  if (!rb || rb.reconnecting) return;
  rbPress(RB_SPEED, rb.speedReg, on);
};

// Pause drives both peers too, so the freeze shows rather than reads as a stall.
const rbSendPause = (on) => {
  const rb = net?.rb;
  if (!rb || rb.reconnecting) return;
  rbPress(RB_PAUSE, rb.pauseReg, on);
};

// Our tab hid or came back. Not a pause: nothing here stops the friend's
// clock (ours stopping does that); it only lets them say why.
const rbSendAway = (on) => {
  rbSend(new Uint8Array([RB_AWAY, on ? 1 : 0]));
};

// Same bytes as a .state file.
const rbCaptureState = () => {
  if (!Module._wasm_state_size) return new Uint8Array(0);
  const size = Module._wasm_state_size();
  if (size <= 0) return new Uint8Array(0);
  const ptr = Module._wasm_state_data();
  return new Uint8Array(Module.memory.buffer, ptr, size).slice();
};

const rbSendState = (bytes) => {
  const hdr = new ArrayBuffer(5);
  new DataView(hdr).setUint8(0, RB_STATE_BEGIN);
  new DataView(hdr).setUint32(1, bytes.length);
  rbSend(hdr);
  for (let off = 0; off < bytes.length; off += RB_CHUNK) {
    const slice = bytes.subarray(off, Math.min(off + RB_CHUNK, bytes.length));
    const frame = new Uint8Array(1 + slice.length);
    frame[0] = RB_STATE_CHUNK;
    frame.set(slice, 1);
    rbSend(frame);
  }
};

// Checks synchronously too: bufferedamountlow only fires on a fresh crossing.
const rbDrain = (dc) =>
  new Promise((resolve) => {
    const check = () => {
      if (dc.bufferedAmount <= dc.bufferedAmountLowThreshold) {
        dc.removeEventListener("bufferedamountlow", check);
        resolve();
      }
    };
    dc.addEventListener("bufferedamountlow", check);
    check();
  });

// Streams a ROM with backpressure. Returns false if the channel dies.
const rbSendRom = async (bytes, onProgress) => {
  const dc = net?.dc;
  if (!dc || dc.readyState !== "open") return false;
  dc.bufferedAmountLowThreshold = RB_SEND_HIGH_WATER;
  const hdr = new ArrayBuffer(5);
  new DataView(hdr).setUint8(0, RB_ROM_BEGIN);
  new DataView(hdr).setUint32(1, bytes.length);
  rbSend(hdr);
  for (let off = 0; off < bytes.length; off += RB_CHUNK) {
    if (!net?.dc || net.dc.readyState !== "open") return false;
    if (dc.bufferedAmount > RB_SEND_HIGH_WATER) await rbDrain(dc);
    const end = Math.min(off + RB_CHUNK, bytes.length);
    const frame = new Uint8Array(1 + (end - off));
    frame[0] = RB_ROM_CHUNK;
    frame.set(bytes.subarray(off, end), 1);
    rbSend(frame);
    if (onProgress) onProgress(end);
  }
  return true;
};

// Joint progress over both directions; both must finish before either boots.
const rbShowXferProgress = () => {
  const rb = net?.rb;
  if (!rb || !rb.needRom) return;
  // Estimate the peer's ROM at our own size until its rom-begin lands.
  const total = (rb.romLen || 0) + (rb.remoteRomLen || rb.romLen || 0);
  if (total <= 0) return;
  const done = (rb.romSent || 0) + (rb.remoteRomGot || 0);
  const pct = Math.min(100, Math.floor((done / total) * 100));
  netSetStatus("Transferring games… " + pct + "%");
};

const rbSendOurRom = () => {
  const rb = net?.rb;
  if (!rb || rb.romSendStarted) return;
  rb.romSendStarted = true;
  rbSendRom(rb.romBytes, (sent) => {
    rb.romSent = sent;
    rbShowXferProgress();
  }).catch(() => {});
};

const rbConnect = async () => {
  const oext = extOf(currentOriginalName || "");
  if (!ROM_EXTS.includes(oext))
    throw new Error("link cable needs a GB/GBC/GBA game");
  rbExt = oext === ".gba" ? ".gba" : oext;
  linkIsGb = rbExt !== ".gba";
  const localState = rbCaptureState();
  // Freeze at the snapshot so the game cannot run past it; enterRollbackMode
  // unfreezes into the session.
  paused = true;
  const romBytes = FS.readFile(currentRomName);
  const romId = rbRomId(romBytes);
  net.rb = {
    localPlayer: net.isHost ? 0 : 1,
    epoch: net.isHost ? Math.floor(Date.now() / 1000) : 0,
    romHash: rbHash(romBytes),
    romId,
    remoteRomId: null,
    romFromLibrary: false,
    friendHasRom: false,
    romBytes,
    romLen: romBytes.length,
    localState,
    remoteState: null,
    stateBuf: null,
    stateGot: 0,
    remoteHello: false,
    // Cross-game ROM transfer (when the peer's hello hash differs).
    needRom: false,
    remoteRomHash: 0,
    remoteRomLen: 0,
    remoteRom: null,
    romBuf: null,
    romGot: 0,
    romSent: 0,
    remoteRomGot: 0,
    romSendStarted: false,
    localReady: false,
    remoteReady: false,
    inited: false,
    // Resume (see "Resume" below).
    resume: null,       // { sid, code } dealt by the host
    resumeOk: false,    // both sides know it: a drop redials instead of ending
    byeIn: false,       // the friend ended it on purpose
    noteLeft: false,    // our goodbye note is posted (rbLeaveNote)
    lastRx: -1,         // last input frame received from the friend
    sentFrames: new Int32Array(RB_SENT_LOG), // the input log (a ring), for the friend's gap
    sentBits: new Uint16Array(RB_SENT_LOG),
    sentCount: 0,
    reconnecting: false,
    reconnectSince: 0,
    giveUpTimer: 0,
    rsRetry: 0,
    rsPairTimer: 0,
    rsWs: null,         // the redial's server socket
    rsPc: null,         // the redial's peer connection, until adopted
    rsDcOpen: false,
    rsSdpIn: false,
    rsEarly: [],        // the friend's messages before our open (replayed on it)
    rsFlags: 0,         // the flags our last RESUME carried (pause/2x are decided from both)
    pauseReg: rbNewReg(false), // the winning pause press (rbPress)
    speedReg: rbNewReg(false), // the winning 2x press
    rsAttempt: 0,
    rsAnswerTimer: 0,
    rsRewait: 0,
    discTimer: 0,
    lastMsgAt: 0,       // wall clock of the friend's last message
    reconnectAt: 0,     // wall clock when redialing began
  };
  netSetStatus("Syncing…");
  const h = new ArrayBuffer(RB_HELLO_LEN);
  const hv = new DataView(h);
  hv.setUint8(0, RB_HELLO);
  hv.setUint32(1, net.rb.epoch);
  hv.setUint32(5, net.rb.romHash);
  hv.setUint32(9, romId.len);
  hv.setUint32(13, romId.crc);
  hv.setUint32(17, romId.fnv);
  rbSend(h);
  rbSendState(localState);
};

const rbMessage = (data) => {
  const rb = net?.rb;
  if (!rb || net.ending) return;
  const v = new DataView(data);
  const kind = v.getUint8(0);
  rb.lastMsgAt = Date.now();
  if (kind === RB_PING) return;
  if (kind === RB_INPUT) {
    const frame = v.getInt32(1);
    if (frame > rb.lastRx) rb.lastRx = frame;
    if (rb.inited && Module._rollback_feed)
      Module._rollback_feed(frame, v.getUint16(5));
    return;
  }
  if (kind === RB_RESUME_INFO) {
    rbResumeInfoIn(rb, v, data);
    return;
  }
  if (kind === RB_RESUME) {
    rsResumeIn(rb, v);
    return;
  }
  if (kind === RB_BYE) {
    // Why the friend ended: its own Disconnect, or a failure there (its
    // give-up just after the new channel opened). formal/WebState/
    // LinkResume.lean bye_reason_heard.
    rb.byeIn = true;
    if (net.started) netPeerGone(v.byteLength >= 2 && v.getUint8(1) === 1 ? "Couldn't reconnect" : "Peer disconnected");
    return;
  }
  if (kind === RB_READY) {
    rb.remoteReady = true;
    rbStartIfReady();
    return;
  }
  if (kind === RB_SPEED) {
    // Match without echoing back; a press that lost a crossing is dropped.
    if (rbPressIn(rb.speedReg, v)) window.applyRemoteSpeed2x?.(rb.speedReg.on);
    return;
  }
  if (kind === RB_PAUSE) {
    // Mirror without echoing back, as 2x.
    if (rbPressIn(rb.pauseReg, v)) window.applyRemotePause?.(rb.pauseReg.on);
    return;
  }
  if (kind === RB_AWAY) {
    rbPeerAway(v.getUint8(1) === 1);
    return;
  }
  if (kind === RB_HAVE_ROM) {
    // Our ROM is already on the friend's side.
    rb.friendHasRom = true;
    rb.romSendStarted = true;
    rb.romSent = rb.romLen;
    rbShowXferProgress();
    return;
  }
  if (kind === RB_NEED_ROM) {
    rbSendOurRom();
    return;
  }
  if (kind === RB_HELLO) {
    rb.remoteRomHash = v.getUint32(5);
    if (!net.isHost) rb.epoch = v.getUint32(1); // guest adopts the host's clock
    rb.remoteHello = true;
    // A friend that names its whole ROM also answers for ours; both sides
    // then compare whole ROMs, an older build only the first 1 MB.
    const answers = data.byteLength >= RB_HELLO_LEN;
    if (answers) rb.remoteRomId = { len: v.getUint32(9), crc: v.getUint32(13), fnv: v.getUint32(17) };
    if (answers ? !rbSameRom(rb.remoteRomId, rb.romId) : rb.remoteRomHash !== rb.romHash) {
      rb.needRom = true;
      rbShowXferProgress();
      if (answers) rbAnswerRom(rb, rb.remoteRomId);
      else rbSendOurRom();
    }
  } else if (kind === RB_STATE_BEGIN) {
    rb.stateBuf = new Uint8Array(v.getUint32(1));
    rb.stateGot = 0;
  } else if (kind === RB_STATE_CHUNK) {
    if (!rb.stateBuf) return;
    rb.stateBuf.set(new Uint8Array(data, 1), rb.stateGot);
    rb.stateGot += data.byteLength - 1;
    if (rb.stateGot >= rb.stateBuf.length) rb.remoteState = rb.stateBuf;
  } else if (kind === RB_ROM_BEGIN) {
    const len = v.getUint32(1);
    if (len <= 0 || len > RB_ROM_MAX) {
      netFail("Your friend's game looks invalid — try again");
      return;
    }
    rb.remoteRomLen = len;
    rb.romBuf = new Uint8Array(len);
    rb.romGot = 0;
    rbShowXferProgress();
  } else if (kind === RB_ROM_CHUNK) {
    if (!rb.romBuf) return;
    rb.romBuf.set(new Uint8Array(data, 1), rb.romGot);
    rb.romGot += data.byteLength - 1;
    rb.remoteRomGot = rb.romGot;
    rbShowXferProgress();
    if (rb.romGot >= rb.romBuf.length) {
      // The channel is reliable+ordered, so this only guards a real mismatch.
      if (rbHash(rb.romBuf) !== rb.remoteRomHash ||
          (rb.remoteRomId && !rbSameRom(rbRomId(rb.romBuf), rb.remoteRomId))) {
        netFail("Game transfer was corrupted — try again");
        return;
      }
      rb.remoteRom = rb.romBuf;
      rb.romBuf = null;
    }
  }
  rbTryInit();
};

const rbLoadState = (player, bytes) => {
  const p = Module._malloc(bytes.length);
  if (!p) return false;
  new Uint8Array(Module.memory.buffer, p, bytes.length).set(bytes);
  const ok = Module._rollback_load_state(player, p, bytes.length);
  Module._free(p);
  return ok === 1;
};

// With the peer's hello, state and (cross-game) ROM in hand: boot both
// cores, load each player's snapshot, announce readiness.
const rbTryInit = () => {
  const rb = net.rb;
  if (!rb || rb.inited || !rb.remoteHello || !rb.remoteState) return;
  if (rb.needRom && !rb.remoteRom) return;
  rb.inited = true;
  // Both peers write the same {host, guest} pair.
  const localRom = rb.romBytes;
  const remoteRom = rb.needRom ? rb.remoteRom : rb.romBytes;
  const hostRom = net.isHost ? localRom : remoteRom;
  const guestRom = net.isHost ? remoteRom : localRom;
  const rom0 = "rbrom0" + rbExt, rom1 = "rbrom1" + rbExt;
  writeToFS(rom0, hostRom);
  writeToFS(rom1, guestRom);
  const ok = Module.ccall(
    "rollback_init",
    "number",
    ["string", "string", "number", "number"],
    [rom0, rom1, rb.localPlayer, rb.epoch]
  );
  if (ok !== 1) {
    netFail("Couldn't start the rollback session");
    return;
  }
  const hostState = net.isHost ? rb.localState : rb.remoteState;
  const guestState = net.isHost ? rb.remoteState : rb.localState;
  if (!rbLoadState(0, hostState) || !rbLoadState(1, guestState)) {
    netFail("Couldn't sync game state — are you both on the same emulator build?");
    return;
  }
  rb.localReady = true;
  rbSend(new Uint8Array([RB_READY]));
  netSetStatus(rb.needRom ? "Ready — waiting for your friend…" : "");
  rbStartIfReady();
};

const rbStartIfReady = () => {
  const rb = net?.rb;
  if (!rb || !rb.inited || !rb.localReady || !rb.remoteReady || net.started) return;
  net.started = true;
  netFrozeGame = false; // the session unfreezes below
  netMode = false; // rollback drives its own RAF branch, not the SIO netStep path
  closeNetModal();
  window.rbSendInput = rbSendInput;
  window.rbSendSpeed = rbSendSpeed;
  window.rbSendPause = rbSendPause;
  window.enterRollbackMode(); // unfreezes into the session
  showToast(net.isHost ? "Player 2 connected — full speed" : "Connected — full speed");
  if (net.isHost) rbOfferResume();
  const rbNow = net.rb;
  rbNow.pingTimer = setInterval(() => {
    if (net?.rb === rbNow && !rbNow.reconnecting) rbSend(new Uint8Array([RB_PING]));
  }, RB_PING_MS);
  // The ROMs + states now live in MEMFS; drop the JS copies (up to ~32 MB).
  rb.romBytes = null;
  rb.remoteRom = null;
  rb.romBuf = null;
  rb.localState = null;
  rb.remoteState = null;
  rb.stateBuf = null;
};

// Leave the session but keep playing: promote our core to the single-player
// core and repoint currentRomName at it so battery saves persist to our slot.
const rbTeardown = async () => {
  if (!net?.rb?.inited) return;
  window.rbSendInput = null;
  window.rbSendSpeed = null;
  window.rbSendPause = null;
  const kept =
    Module._rollback_exit_to_single && Module._rollback_exit_to_single() === 1;
  if (kept) {
    // The solo core now lives at rbrom<player><ext>; the display name stays.
    currentRomName = "rbrom" + net.rb.localPlayer + rbExt;
  } else if (Module._rollback_exit) {
    Module._rollback_exit();
  }
  if (typeof window.leaveRollbackMode === "function") window.leaveRollbackMode();
  if (kept && currentRomName && currentOriginalName) {
    try {
      await persistSave(currentRomName, currentOriginalName);
    } catch {}
  }
};

const netReceive = (bytes) => {
  if (!net) return;
  if (!net.started) {
    // The peer's HELLO can arrive before our core exists.
    net.rxQueue.push(bytes);
    return;
  }
  netFeedNow(bytes);
};

const netFeedNow = (bytes) => {
  const p = Module._malloc(bytes.length);
  if (!p) return;
  new Uint8Array(Module.memory.buffer, p, bytes.length).set(bytes);
  const ok = Module._netlink_feed(p, bytes.length);
  Module._free(p);
  if (ok !== 1) {
    netPeerGone("Link error: " + Module.UTF8ToString(Module._netlink_error_msg()));
    return;
  }
  // Advance the core now and push the reply out: otherwise every link
  // round-trip costs a whole RAF interval.
  if (typeof window.driveNet === "function") window.driveNet();
  netFlush();
};

const netFlush = () => {
  if (!net?.ptr || !net.dc || net.dc.readyState !== "open") return;
  for (;;) {
    const n = Module._netlink_drain(net.ptr, NET_BUF_CAP);
    if (n <= 0) break;
    const chunk = new Uint8Array(Module.memory.buffer, net.ptr, n).slice();
    if (NET_LINK_DELAY > 0) {
      setTimeout(() => {
        try {
          net?.dc?.send(chunk);
        } catch {}
      }, NET_LINK_DELAY);
    } else {
      try {
        net.dc.send(chunk);
      } catch {}
    }
  }
};

netJoinGo.addEventListener("click", async () => {
  // While connecting the same button reads "Cancel".
  if (net?.ws || net?.bc) {
    netDismissModal();
    return;
  }
  if (!net) net = makeSession(netAttach);
  const session = net;
  const code = netCodeInput.value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (code.length < 3) {
    netSetStatus("Pick a code of at least 3 letters/numbers", true);
    return;
  }
  session.code = code;
  netSetConnecting(true);
  netSetStatus("Connecting…");
  armManualFallback(session, SIG_DIAL_TIMEOUT);
  // Same-browser BroadcastChannel and signaling server race; the first to
  // connect wins (wireChannel tears the loser down).
  startLocalLink(code);
  if (await sigConnect()) {
    if (net !== session || net.dc) return; // paired locally or cancelled
    sigRendezvous(session);
  } else if (net === session && !net.dc && !net.rtcConnected) {
    clearTimeout(manualFallbackTimer);
    manualEnter(true);
  }
});

// Stop propagation at the field so the page's window-level handlers (the
// key grab preventDefaults keypress) never see it; Escape is then dismissed
// here.
["keydown", "keypress", "keyup"].forEach((type) =>
  netCodeInput.addEventListener(type, (/** @type {KeyboardEvent} */ e) => {
    if (type === "keydown" && e.key === "Enter") netJoinGo.click();
    if (type === "keydown" && e.key === "Escape") netDismissModal();
    e.stopPropagation();
  })
);

// SIO path: attach binds the cable to the running game; the fresh path boots
// the ROM into a linked session from the player's own battery save.
const launchNetRom = async () => {
  setFastForward(false);
  setSpeed2x(false);
  setRewindHeld(false);
  netFrozeGame = false;
  paused = false;
  document.body.classList.remove("paused");
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";

  if (Module._netlink_set_speculative) {
    Module._netlink_set_speculative(NET_SPECULATIVE ? 1 : 0);
  }

  if (net.attach) {
    const ok = Module.ccall(
      "netlink_attach",
      "number",
      ["number", "number"],
      [net.isHost ? 1 : 0, 1] // relaxed CRC: games negotiate compatibility
    );
    if (ok !== 1) throw new Error("attach failed");
  } else {
    const rom = net.rom;
    nextLoadGen(); // the session owns the core now: a load in flight gives way
    if (currentRomName && currentOriginalName) {
      await persistSave(currentRomName, currentOriginalName);
    }
    const romFile = "rom" + extOf(rom.name);
    const save = await dbGet("save:" + rom.name);
    // As loadRom: the ROM, its battery file and the core in one synchronous
    // run, and only then the name. Named any earlier, a flush in the gap
    // (the 5 s autosave, pagehide) would file the outgoing game's battery,
    // still in rom.sav, under this one.
    writeToFS(romFile, rom.data);
    installSave(romFile, rom.name, save);
    const ok = Module.ccall(
      "netlink_init",
      "number",
      ["string", "number", "number"],
      [romFile, net.isHost ? 1 : 0, 1]
    );
    currentRomName = romFile;
    currentOriginalName = rom.name;
    if (ok !== 1) throw new Error("core init failed");
  }

  net.ptr = Module._malloc(NET_BUF_CAP);
  net.started = true;
  netMode = true;
  document.body.classList.add("has-game", "running", "net-mode");
  netFlush(); // our HELLO
  for (const bytes of net.rxQueue) netFeedNow(bytes);
  net.rxQueue = [];
  netSetStatus("Linked — starting…");
};

// Called from the index.js RAF loop; returns the netlink_tick status.
const netStep = () => {
  if (!netMode || !net?.started) return 4;
  const st = Module._netlink_tick();
  netFlush();
  return st;
};

const netAfterTick = (st) => {
  if (!netMode || !net) return;
  if (!net.helloDone && (st === 1 || st === 2)) {
    net.helloDone = true;
    closeNetModal();
    if (Module._netlink_crc_mismatch()) {
      // Cross-version pairs (Ruby<->Sapphire) are link-compatible, so this
      // is a confirm, not a rejection.
      const stay = confirm(
        "You and your friend are running different ROMs (different bytes, " +
        "e.g. two game versions or regions). Compatible games can still " +
        "trade and battle; incompatible ones will fail their own link " +
        "handshake. Continue?"
      );
      if (!stay) {
        netShutdown();
        showToast("Left the online game");
        return;
      }
    }
    showToast(net.isHost ? "Player 2 connected" : "Connected to host");
  }
  if (st === 3) {
    const msg = Module.UTF8ToString(Module._netlink_error_msg());
    netPeerGone("Link failed: " + msg);
    return;
  }
  if (Module._netlink_peer_done()) {
    netPeerGone("Your friend left the game");
    return;
  }
  // Badge only for sustained stalls, so per-transfer waits don't flicker it.
  if (st === 2) {
    const now = performance.now();
    if (!net.stallSince) net.stallSince = now;
    netStallBadge.hidden = now - net.stallSince < 300;
  } else {
    net.stallSince = 0;
    netStallBadge.hidden = true;
  }
};

// Peer gone: keep the local game running (it sees a yanked cable).
const netPeerGone = (msg) => {
  if (!net) return;
  const started = net.started;
  log("netplay: " + msg);
  netShutdown({ why: "gave-up" });
  if (started) {
    showToast(msg + " — your game keeps running");
    // Toasts last seconds; a player who was away gets it on return.
    if (document.hidden) rbGoneWhileHidden = msg + " while you were away — your game keeps running";
  } else {
    netSetStatus(msg, true);
  }
};

// The local game keeps running unlinked once netMode is false. opts.why is
// the goodbye note's reason: "left" (Disconnect, leaving the page) unless
// the session failed ("gave-up", from netPeerGone).
const netShutdown = async (opts) => {
  if (net?.rb) rsStop(net.rb);
  // A deliberate end: the friend mustn't redial. It says why, so a give-up
  // reads as one on the friend's side too.
  if (net?.started && net.rb && !net.rb.byeIn && net.dc?.readyState === "open") {
    try { net.dc.send(new Uint8Array([RB_BYE, opts?.why === "gave-up" ? 1 : 0])); } catch {}
  }
  // And in case the BYE can't get there (the link is down, or about to be
  // found down), on the retry code too. Here, before any await: at page
  // close only this synchronous part runs.
  if (net?.started && net.rb) rbLeaveNote(net.rb, opts?.why || "left");
  // Ended here, so nothing for a relaunch to say (rbByeOnRelaunch).
  if (net?.rb) rbClearLive();
  netStallBadge.hidden = true;
  netStallText.textContent = "waiting for peer";
  rbHideAwayCard();
  rbHiddenSince = 0;
  clearTimeout(manualFallbackTimer);
  const s = net;
  net = null;
  if (s) {
    // Ending: anything the channel says or does during the teardown below
    // (net is put back for rbTeardown) must not redial or end it again.
    s.ending = true;
    clearTimeout(s.redialTimer);
    clearTimeout(s.rtcDeadline);
    if (s.rb) clearInterval(s.rb.pingTimer);
  }
  // Thaw the game frozen at modal open, even if rb was never created; but not
  // while the modal stays up for a retry (netFail), which the freeze is for.
  if (netFrozeGame && !(opts?.keepModal && netModalOpen())) {
    netFrozeGame = false;
    paused = false;
    document.body.classList.remove("paused");
    pauseButton.classList.remove("paused", "active");
    pauseButton.title = "Pause";
  }
  // A session hands the game back in whatever pause state it is in: every
  // pause still in force has its own undo (Resume, the home screen's Resume,
  // Report a Bug's close; rbConnect's snapshot freeze is the thaw above).
  // Unpausing here ran the game behind the home screen and left the Resume icon up.
  if (s?.rb) {
    if (s.rb.inited) {
      net = s; // rbTeardown reads net.rb / currentOriginalName
      await rbTeardown();
      net = null;
    }
  }
  if (s) {
    try {
      if (netMode && Module._netlink_exit) {
        Module._netlink_exit(); // queues BYE, unbinds the cable, flushes .sav
        if (s.ptr && s.dc?.readyState === "open") {
          // Deliver the BYE so the peer exits cleanly
          for (;;) {
            const n = Module._netlink_drain(s.ptr, NET_BUF_CAP);
            if (n <= 0) break;
            try {
              s.dc.send(new Uint8Array(Module.memory.buffer, s.ptr, n).slice());
            } catch {}
          }
        }
      }
    } catch {}
    try {
      s.dc?.close();
    } catch {}
    try {
      s.pc?.close();
    } catch {}
    try {
      s.ws?.close();
    } catch {}
    try {
      s.bc?.close(); // discovery-phase channel
    } catch {}
    if (s.ptr) Module._free(s.ptr);
  }
  if (netMode) {
    netMode = false;
    document.body.classList.remove("net-mode");
    if (currentRomName && currentOriginalName) {
      await persistSave(currentRomName, currentOriginalName);
    }
  }
  if (!opts?.keepModal) closeNetModal();
};

const netDismissModal = () => {
  if (net && !net.started) netShutdown();
  else closeNetModal();
};

// Two-step confirm on an existing element (index.js makeConfirmButton
// semantics: armed class + label swap + 3.5s auto-disarm).
const armedAction = (el, setLabel, action) => {
  let armed = false;
  let timer = 0;
  const disarm = () => {
    armed = false;
    clearTimeout(timer);
    el?.classList.remove("armed");
    setLabel(false);
  };
  return {
    disarm,
    fire: () => {
      if (!armed) {
        armed = true;
        el?.classList.add("armed");
        setLabel(true);
        timer = setTimeout(disarm, 3500);
        return;
      }
      disarm();
      action();
    },
  };
};

const menuDisconnectArm = armedAction(
  document.getElementById("net-connect"),
  (armed) => {
    if (!netConnectLabel) return;
    if (armed) netConnectLabel.textContent = "Are you sure?";
    // The session may have died remotely while armed.
    else window.setNetConnectLabel(!!(net?.started || net?.rb?.inited));
  },
  () => {
    menuDropdown.hidden = true;
    log("netplay: disconnected by you");
    netShutdown();
    showToast("Disconnected");
  }
);

const rbDisconnectBtn = document.getElementById("rb-disconnect");
// Disarming must restore the responsive suffix markup, not just the text.
const rbDcSpan = rbDisconnectBtn?.querySelector?.("span");
const rbDcHTML = rbDcSpan ? rbDcSpan.innerHTML : "";
const rbDisconnectArm = armedAction(
  rbDisconnectBtn,
  (armed) => {
    if (!rbDcSpan) return;
    if (armed) rbDcSpan.textContent = "Are you sure?";
    else rbDcSpan.innerHTML = rbDcHTML;
  },
  () => {
    log("netplay: disconnected by you");
    netShutdown();
    showToast("Disconnected");
  }
);
rbDisconnectBtn.addEventListener("click", () => {
  if (net?.started || net?.rb?.inited) rbDisconnectArm.fire();
});

// ---- Away. A hidden tab gets no rAF, so that side's game pauses and the
// friend's waits at the prediction limit. The hiding side says so (its
// visibilitychange runs before the page stops) and the friend shows a card
// over the dimmed, frozen screen instead of a silent freeze. Without the
// message (an older build, or a page frozen before the send went out) a
// long enough stall shows the badge instead.
const netAwayCard = document.getElementById("net-away");
const netAwayTime = document.getElementById("net-away-time");
const netAwayTitle = document.getElementById("net-away-title");
const netAwayText = document.getElementById("net-away-text");
const RB_AWAY_TITLE = "Friend switched away";
const RB_AWAY_TEXT = "Their game is paused until they come back. The link stays open — nothing is lost.";
const RB_RECONNECT_TITLE = "Reconnecting…";
const RB_RECONNECT_TEXT = "The connection dropped. Both games are paused and pick up where they left off.";
// The link dropped while the friend was away (their app suspended, or killed:
// nothing says which): waiting on them, not on the network.
const RB_AWAY_DROP_TEXT = "The link dropped while they were away. If they come back within 3 minutes, both games pick up where they left off.";
const netStallText = document.getElementById("net-stall-text");
const RB_AWAY_CARD_MS = 1000;   // a quick alt-tab doesn't flash the card
const RB_AWAY_TOAST_MS = 5000;  // away this long earns a "back" toast
const RB_STALL_BADGE_MS = 2000; // an unexplained stall this long shows the badge
const RB_BACK_TOAST_DELAY_MS = 1500; // back from away: the link proves alive first
let rbPeerAwaySince = 0;    // when the friend's tab hid, or 0
let rbAwayShown = false;    // the away card is up (a second in)
let rbAwayCardTimer = 0;
let rbAwayTick = 0;
let rbHiddenSince = 0;      // when our tab hid during a session, or 0
let rbGoneWhileHidden = ""; // a session end our hidden player didn't see

const fmtAway = (ms) => {
  const s = Math.floor(ms / 1000);
  return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
};

const awayDisconnectBtn = document.getElementById("net-away-disconnect");
const awayDisconnectArm = armedAction(
  awayDisconnectBtn,
  (armed) => {
    awayDisconnectBtn.textContent = armed ? "Are you sure?" : "Disconnect…";
  },
  () => {
    log("netplay: disconnected by you (friend away)");
    netShutdown();
    showToast("Disconnected");
  }
);
awayDisconnectBtn.addEventListener("click", () => {
  if (net?.started || net?.rb?.inited) awayDisconnectArm.fire();
});

// The card over the dimmed screen: redialing a dropped link, or the friend
// away, with a clock either way; hidden otherwise.
const rbRenderCard = () => {
  const rb = net?.rb;
  const reconnecting = !!rb?.reconnecting;
  const show = reconnecting || rbAwayShown;
  // While redialing the game waits on the link (the frame loop doesn't
  // tick), and both sides take pause and 2x from the two RESUMEs: a press
  // now could only be undone then, so there is none to make
  // (formal/WebState/LinkResume.lean regress_no_press_in_drop).
  /** @type {HTMLButtonElement} */ (pauseButton).disabled = reconnecting;
  /** @type {HTMLButtonElement} */ (speed2xButton).disabled = reconnecting;
  if (show) {
    const awayDrop = reconnecting && !!rb.peerAwayAtDrop;
    netAwayTitle.textContent = reconnecting && !awayDrop ? RB_RECONNECT_TITLE : RB_AWAY_TITLE;
    netAwayText.textContent = !reconnecting ? RB_AWAY_TEXT : awayDrop ? RB_AWAY_DROP_TEXT : RB_RECONNECT_TEXT;
    netAwayTime.textContent = reconnecting
      ? (awayDrop ? "Waiting for " : "Trying for ") + fmtAway(performance.now() - rb.reconnectSince)
      : "Away " + fmtAway(performance.now() - rbPeerAwaySince);
    netStallBadge.hidden = true;
    if (!rbAwayTick) rbAwayTick = setInterval(rbRenderCard, 1000);
  } else {
    clearInterval(rbAwayTick);
    rbAwayTick = 0;
    if (!netAwayCard.hidden) awayDisconnectArm.disarm();
  }
  netAwayCard.hidden = !show;
  document.body.classList.toggle("peer-away", show);
};

const rbHideAwayCard = () => {
  clearTimeout(rbAwayCardTimer);
  rbAwayCardTimer = 0;
  rbPeerAwaySince = 0;
  rbAwayShown = false;
  rbRenderCard();
};

const rbPeerAway = (on) => {
  if (on) {
    if (rbPeerAwaySince) return;
    rbPeerAwaySince = performance.now();
    log("netplay: friend switched away");
    rbAwayCardTimer = setTimeout(() => {
      rbAwayShown = true;
      rbRenderCard();
    }, RB_AWAY_CARD_MS);
    return;
  }
  if (!rbPeerAwaySince) return;
  const away = performance.now() - rbPeerAwaySince;
  log("netplay: friend back after " + fmtAway(away));
  rbHideAwayCard();
  if (away >= RB_AWAY_TOAST_MS) showToast("Friend's back — link resumed");
};

// Each rollback tick: how long the clock has been stalled on the friend's
// inputs (0 = running). The away card already explains a hidden friend.
window.rbNoteStall = (ms) => {
  const show = ms >= RB_STALL_BADGE_MS && !rbPeerAwaySince && !!net?.started && !net.rb?.reconnecting;
  if (show) netStallText.textContent = "waiting for friend · " + fmtAway(ms);
  netStallBadge.hidden = !show;
};

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    if (!net?.started || !net.rb) return; // rollback sessions only
    rbHiddenSince = performance.now();
    rbSendAway(true);
    rbMarkLive(net.rb); // a hidden tab is the one a browser kills
    return;
  }
  if (rbGoneWhileHidden) {
    pushToast(rbGoneWhileHidden, 6000, null);
  } else if (rbHiddenSince && net?.started) {
    rbSendAway(false);
    const away = performance.now() - rbHiddenSince;
    // A suspended page learns the link died only once it wakes: say the
    // friend waited only if the session is still up a moment later.
    if (away >= RB_AWAY_TOAST_MS) {
      const s = net;
      setTimeout(() => {
        if (net === s && net.started && !net.rb?.reconnecting) {
          showToast("Your game was paused for " + fmtAway(away) + " — your friend waited");
        }
      }, RB_BACK_TOAST_DELAY_MS);
    }
  }
  rbGoneWhileHidden = "";
  rbHiddenSince = 0;
});

// ---- Resume. A dropped connection (a phone suspended past its background
// time, a network hop) needn't end the session: both games are frozen at
// the prediction limit, so the link picks up where it stopped and the games
// never see the gap. At the start the host deals a retry code (long and
// random, so it never holds a short code someone wants) and a session id,
// and the guest echoes them back; only a session both sides know can
// resume (an older build never echoes, and is ended as before). On a drop
// both rendezvous on the retry code, open a new connection and swap RESUME
// [sid][last input frame received][flags]: each resends the inputs the
// other missed, both take one pause/2x state from the two RESUMEs' flags,
// and they play on (formal/WebState/LinkResume.lean). A deliberate end
// sends BYE first, so the friend doesn't redial, and leaves a goodbye note
// on the retry code (rbLeaveNote) for a friend the BYE can't reach: one
// already redialing is told by the server. Not offered over the
// same-browser path or a manual-code pairing (no server to redial).
let rbResumeGiveUpMs = 180000;       // then the session ends as before (let: e2e shortens it)
const RB_RESUME_PAIR_MS = 20000;     // paired, but no channel: dial again
const RB_RESUME_ANSWER_MS = 10000;   // channel open, but no RESUME from the friend: dial again
const RB_REWAIT_MS = 25000;          // waiting on the code: re-rendezvous (a socket can die unseen)
const RB_DISCONNECTED_MS = 10000;    // "disconnected" this long: redial
const RB_SENT_LOG = 128;             // inputs kept for the friend's gap (it is at most ~2x the window)
const RB_RETRY_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

const rbResumeInfoMsg = (sid, code) => {
  const bytes = new TextEncoder().encode(code);
  const buf = new Uint8Array(5 + bytes.length);
  new DataView(buf.buffer).setUint32(1, sid);
  buf[0] = RB_RESUME_INFO;
  buf.set(bytes, 5);
  return buf;
};

// Host, at the start.
const rbOfferResume = () => {
  const rb = net?.rb;
  if (!rb || (net.localChan && net.dc === net.localChan) || net.manualCode) return;
  const a = new Uint8Array(14);
  crypto.getRandomValues(a);
  const code = "RS" + Array.from(a, (x) => RB_RETRY_ALPHABET[x % 32]).join("");
  rb.resume = { sid: netRandId(), code };
  rbSend(rbResumeInfoMsg(rb.resume.sid, code));
  rbMarkLive(rb);
};

const rbResumeInfoIn = (rb, v, data) => {
  if (data.byteLength < 8) return;
  const sid = v.getUint32(1);
  const code = new TextDecoder().decode(new Uint8Array(data, 5));
  if (!/^[A-Z0-9]{8,32}$/.test(code)) return;
  if (!rb.resume) { // guest: take it and echo it
    rb.resume = { sid, code };
    rb.resumeOk = true;
    rbSend(rbResumeInfoMsg(sid, code));
    rbMarkLive(rb);
  } else if (rb.resume.sid === sid && rb.resume.code === code) {
    rb.resumeOk = true; // host: the guest has it
  }
};

const rbCanResume = () => !!(net?.started && net.rb?.resumeOk && !net.rb.byeIn);

// Redialing on the retry code: the game waits, and Pause and 2x are off.
const rbReconnecting = () => !!net?.rb?.reconnecting;

// The signaling server over http(s), for the goodbye note.
const NET_SIGNAL_HTTP = (() => {
  const m = /^(wss?):\/\/([^/?#]+)/.exec(NET_SIGNAL_URL);
  return m ? (m[1] === "wss" ? "https://" : "http://") + m[2] : "";
})();

// The session is ending here and the friend may be redialing (or about to
// find the link down and redial): leave a goodbye on the retry code. The
// server tells a friend waiting on it at once, and turns its next
// rendezvous away with the goodbye for the next 10 minutes, so it ends
// with "Peer disconnected" ("Couldn't reconnect" for "gave-up") instead of
// "Reconnecting…" until its own give-up (server.js leaveNote;
// formal/WebState/LinkRedial.lean). A beacon: it survives the page
// closing. Not after the friend's own goodbye: it has gone.
const rbLeaveNote = (rb, why) => {
  if (!rb.resume || rb.byeIn || rb.noteLeft || !NET_SIGNAL_HTTP) return;
  rb.noteLeft = true;
  log("netplay: goodbye note on the retry code (" + why + ")");
  rbPostBye(rb.resume.code, NET_PAGE_ID, why);
};

const rbPostBye = (code, id, why) => {
  const body = JSON.stringify({ code, id, why });
  const url = NET_SIGNAL_HTTP + "/bye";
  try {
    if (navigator.sendBeacon?.(url, body)) return;
  } catch {}
  try {
    fetch(url, { method: "POST", body, keepalive: true, mode: "no-cors" }).catch(() => {});
  } catch {}
};

// A page killed outright (a mobile browser discarding a background tab, a
// crash) runs nothing, so its friend redials for the full 3 minutes. While
// a session that can resume is up, this tab keeps its retry code and page
// id in sessionStorage (per tab; it survives a reload, a discard and a
// crash restore), freshened on going hidden and around a redial, and
// clears it when the session ends here. A load that finds one under 10
// minutes old (the server keeps a goodbye that long) leaves the goodbye the
// killed page couldn't, unless a live tab still holds that session (Duplicate
// Tab copies sessionStorage): it answers on RB_OWNER_CHANNEL.
// formal/WebState/LinkResume.lean Event.relaunch, regress_kill_heard_on_relaunch.
const RB_LIVE_KEY = "dingbat-link-live";
const RB_LIVE_MS = 10 * 60 * 1000;
const RB_OWNER_CHANNEL = "dingbat-link-owner";
const RB_OWNER_PROBE_MS = 300;

const rbMarkLive = (rb) => {
  if (!rb?.resume) return;
  try {
    sessionStorage.setItem(RB_LIVE_KEY, JSON.stringify({ code: rb.resume.code, id: NET_PAGE_ID, at: Date.now() }));
  } catch {}
};

const rbClearLive = () => {
  try { sessionStorage.removeItem(RB_LIVE_KEY); } catch {}
};

// Answer a relaunching tab's "is this session yours?".
try {
  const ch = new BroadcastChannel(RB_OWNER_CHANNEL);
  ch.addEventListener("message", (e) => {
    const m = e.data;
    if (m?.t === "own?" && m.id === NET_PAGE_ID && net?.rb?.resume?.code === m.code) {
      ch.postMessage({ t: "mine", code: m.code, id: m.id });
    }
  });
} catch {}

const rbByeOnRelaunch = () => {
  let live = null;
  try { live = JSON.parse(sessionStorage.getItem(RB_LIVE_KEY) || "null"); } catch {}
  if (!live) return;
  rbClearLive();
  if (typeof live.code !== "string" || typeof live.id !== "string" || !NET_SIGNAL_HTTP) return;
  if (!(Date.now() - live.at < RB_LIVE_MS)) return;
  const post = () => {
    log("netplay: the last session here never ended: goodbye note on its retry code");
    rbPostBye(live.code, live.id, "left");
  };
  let ch;
  try {
    ch = new BroadcastChannel(RB_OWNER_CHANNEL);
  } catch {
    post();
    return;
  }
  let owned = false;
  ch.addEventListener("message", (e) => {
    if (e.data?.t === "mine" && e.data.code === live.code && e.data.id === live.id) owned = true;
  });
  ch.postMessage({ t: "own?", code: live.code, id: live.id });
  setTimeout(() => {
    try { ch.close(); } catch {}
    if (owned) log("netplay: the last session here lives on in another tab");
    else post();
  }, RB_OWNER_PROBE_MS);
};
rbByeOnRelaunch();

// The input log, a ring: every input sent, in frame order.
const rbLogSent = (rb, frame, bits) => {
  const i = rb.sentCount % RB_SENT_LOG;
  rb.sentFrames[i] = frame;
  rb.sentBits[i] = bits;
  rb.sentCount++;
};

// The connection is gone: redial if both sides can, else end as before.
const rbDropped = (why, endMsg) => {
  if (!net || net.ending) return;
  if (rbCanResume()) rbBeginResume(why);
  else netPeerGone(net?.rb?.byeIn ? "Peer disconnected" : endMsg);
};

// "disconnected" may recover; past RB_DISCONNECTED_MS it redials (an engine
// that never reaches "failed" mustn't strand the session).
const rbWatchDisconnected = (pc, st) => {
  const rb = net?.rb;
  if (!rb) return;
  clearTimeout(rb.discTimer);
  if (st !== "disconnected") return;
  rb.discTimer = setTimeout(() => {
    if (net?.rb === rb && net.pc === pc && pc.connectionState !== "connected") {
      rbDropped("disconnected for " + RB_DISCONNECTED_MS / 1000 + " s", "Peer connection lost");
    }
  }, RB_DISCONNECTED_MS);
};

const rbBeginResume = (why) => {
  const rb = net.rb;
  if (rb.reconnecting) {
    // A new channel died before the friend's RESUME: dial again.
    rsRestart(rb, why);
    return;
  }
  // Back from a suspension longer than the friend waits: it has given up.
  if (rb.lastMsgAt && Date.now() - rb.lastMsgAt > rbResumeGiveUpMs) {
    log("netplay: " + why + " after " + Math.round((Date.now() - rb.lastMsgAt) / 1000) + " s of silence — the friend has given up");
    netPeerGone("Peer connection lost");
    return;
  }
  rb.reconnecting = true;
  rb.reconnectSince = performance.now();
  rb.reconnectAt = Date.now();
  rb.rsAttempt = 0;
  // The friend had said it was away: the card says so, not "Reconnecting…".
  rb.peerAwayAtDrop = !!rbPeerAwaySince;
  rbMarkLive(rb);
  log("netplay: " + why + " — redialing on the retry code");
  rsDetach(rb);
  rbRenderCard();
  clearTimeout(rb.giveUpTimer);
  rb.giveUpTimer = setTimeout(() => {
    if (net?.rb !== rb || !rb.reconnecting) return;
    log("netplay: no reconnect in " + rbResumeGiveUpMs / 1000 + " s — giving up", "warn");
    netPeerGone("Couldn't reconnect");
  }, rbResumeGiveUpMs);
  rsDial(rb);
};

// Let go of the dead or half-made connection: the server socket, the
// pairing in flight, an adopted channel, and their timers.
const rsDetach = (rb) => {
  clearTimeout(rb.rsRetry);
  clearTimeout(rb.rsPairTimer);
  clearTimeout(rb.rsAnswerTimer);
  clearTimeout(rb.rsRewait);
  clearTimeout(rb.discTimer);
  const ws = rb.rsWs;
  rb.rsWs = null;
  if (ws) { try { ws.onclose = ws.onmessage = ws.onerror = null; ws.close(); } catch {} }
  const pcs = new Set([rb.rsPc, net?.pc].filter(Boolean));
  const dc = net?.dc;
  rb.rsPc = null;
  rb.rsDcOpen = false;
  rb.rsSdpIn = false;
  rb.rsEarly = [];
  if (net) {
    net.pc = null;
    net.dc = null;
    net.rtcConnected = false;
  }
  try { dc?.close(); } catch {}
  for (const pc of pcs) { try { pc.close(); } catch {} }
};

// This attempt is over: dial again, backing off within the server's
// rendezvous rate (10 a minute per address), until resumed or given up.
const rsRestart = (rb, why, now = false) => {
  if (net?.rb !== rb || !rb.reconnecting) return;
  // The give-up timer may not have run (a suspended page): check the clock.
  if (Date.now() - rb.reconnectAt > rbResumeGiveUpMs) {
    netPeerGone("Couldn't reconnect");
    return;
  }
  log("netplay: redial: " + why);
  rsDetach(rb);
  const delay = now ? 0 : Math.min(2000 * 2 ** rb.rsAttempt++, 15000);
  rb.rsRetry = setTimeout(() => rsDial(rb), delay);
};

// Stop redialing (resumed, or the session is ending). An adopted channel
// stays the session's.
const rsStop = (rb) => {
  rb.reconnecting = false;
  clearTimeout(rb.giveUpTimer);
  clearTimeout(rb.rsRetry);
  clearTimeout(rb.rsPairTimer);
  clearTimeout(rb.rsAnswerTimer);
  clearTimeout(rb.rsRewait);
  const ws = rb.rsWs;
  rb.rsWs = null;
  if (ws) { try { ws.onclose = ws.onmessage = ws.onerror = null; ws.close(); } catch {} }
  if (rb.rsPc && rb.rsPc !== net?.pc) { try { rb.rsPc.close(); } catch {} }
  rb.rsPc = null;
};

// One rendezvous on the retry code.
const rsDial = (rb) => {
  if (net?.rb !== rb || !rb.reconnecting) return;
  let ws;
  try { ws = new WebSocket(NET_SIGNAL_URL); } catch { rsRestart(rb, "no socket"); return; }
  rb.rsWs = ws;
  ws.onopen = () => ws.send(JSON.stringify({ t: "rendezvous", code: rb.resume.code, id: NET_PAGE_ID }));
  ws.onerror = () => {};
  ws.onclose = () => {
    if (rb.rsWs !== ws) return;
    // A pairing under way finishes on its own (or its deadline redials).
    if (rb.rsDcOpen || rb.rsSdpIn) { rb.rsWs = null; return; }
    rsRestart(rb, "server socket closed");
  };
  ws.onmessage = async (e) => {
    let msg;
    try { msg = JSON.parse(e.data); } catch { return; }
    if (rb.rsWs !== ws) return;
    const pc = rb.rsPc;
    try {
      if (msg.t === "waiting") {
        log("netplay: redial: waiting for the friend");
        rb.rsAttempt = 0; // the server answers: no backoff for the next dial
        clearTimeout(rb.rsRewait);
        rb.rsRewait = setTimeout(() => {
          if (rb.rsWs === ws && !rb.rsPc) rsRestart(rb, "still waiting — rendezvous again", true);
        }, RB_REWAIT_MS);
      } else if (msg.t === "paired") {
        log("netplay: redial: paired " + msg.role);
        clearTimeout(rb.rsRewait);
        rsStartRtc(rb, ws, msg.role === "host").catch((err) => {
          if (rb.rsWs === ws) rsRestart(rb, "setup failed: " + err.message);
        });
      } else if (msg.t === "sdp" && pc) {
        rb.rsSdpIn = true;
        await pc.setRemoteDescription(msg.d);
        if (msg.d.type === "offer") {
          await pc.setLocalDescription(await pc.createAnswer());
          if (rb.rsPc === pc) ws.send(JSON.stringify({ t: "sdp", d: pc.localDescription }));
        }
      } else if (msg.t === "ice" && pc && msg.c) {
        await pc.addIceCandidate(msg.c).catch(() => {});
      } else if (msg.t === "peer-closed") {
        // With the descriptions crossed the friend has most likely opened
        // its channel and left the server a round trip before ours opens:
        // leave it to the channel, or the pairing deadline.
        if (!rb.rsDcOpen && !rb.rsSdpIn) rsRestart(rb, "friend left the server");
      } else if (msg.t === "bye") {
        // The friend ended the session while the link was down, and left a
        // goodbye on the code (rbLeaveNote).
        rb.byeIn = true;
        log("netplay: redial: the friend " + (msg.why === "gave-up" ? "gave up" : "left"));
        netPeerGone(msg.why === "gave-up" ? "Couldn't reconnect" : "Peer disconnected");
      } else if (msg.t === "error") {
        rsRestart(rb, "server: " + msg.msg);
      }
    } catch (err) {
      if (rb.rsPc === pc && pc) rsRestart(rb, "setup failed: " + err.message);
    }
  };
};

const rsStartRtc = async (rb, ws, isOfferer) => {
  const pc = new RTCPeerConnection({ iceServers: NET_ICE_SERVERS });
  rb.rsPc = pc;
  rb.rsDcOpen = false;
  rb.rsSdpIn = false;
  clearTimeout(rb.rsPairTimer);
  rb.rsPairTimer = setTimeout(() => {
    if (rb.rsPc === pc && !rb.rsDcOpen) rsRestart(rb, "no channel after pairing");
  }, RB_RESUME_PAIR_MS);
  pc.onicecandidate = (e) => {
    if (e.candidate && rb.rsPc === pc && rb.rsWs === ws) ws.send(JSON.stringify({ t: "ice", c: e.candidate }));
  };
  pc.onconnectionstatechange = () => {
    if (rb.rsPc === pc && !rb.rsDcOpen && pc.connectionState === "failed") rsRestart(rb, "ICE failed");
  };
  const adopt = (dc) => {
    dc.binaryType = "arraybuffer";
    dc.onopen = () => rsAdopt(rb, pc, dc);
    // Wired from the start: the friend opens first and says RESUME at once.
    dc.onmessage = (e) => {
      if (net?.dc === dc) rbMessage(e.data);
      else if (rb.rsPc === pc) rb.rsEarly.push(e.data);
    };
  };
  if (isOfferer) {
    adopt(pc.createDataChannel("link", { ordered: true }));
    await pc.setLocalDescription(await pc.createOffer());
    if (rb.rsPc === pc) ws.send(JSON.stringify({ t: "sdp", d: pc.localDescription }));
  } else {
    pc.ondatachannel = (e) => { if (rb.rsPc === pc) adopt(e.channel); };
  }
};

// The new channel is open: it becomes the session's and says what this
// side has. Inputs, pause and 2x stay held until the friend's RESUME says
// what it has; no RESUME in time dials again.
const rsAdopt = (rb, pc, dc) => {
  if (rb.rsPc === pc && rb.rsDcOpen) return;
  if (net?.rb !== rb || !rb.reconnecting || rb.rsPc !== pc) { try { pc.close(); } catch {} return; }
  rb.rsDcOpen = true;
  clearTimeout(rb.rsPairTimer);
  // The server socket stays until the friend's RESUME: leaving now would
  // close the friend's socket while its channel may still be opening.
  net.pc = pc;
  net.dc = dc;
  net.rtcConnected = true;
  pc.onconnectionstatechange = () => {
    if (!net || net.pc !== pc) return;
    const st = pc.connectionState;
    rbWatchDisconnected(pc, st);
    if (st === "failed" || st === "closed") rbDropped("connection " + st, "Peer connection lost");
    else if (st === "disconnected") log("netplay: connection disconnected — waiting");
  };
  dc.onclose = () => {
    if (!net || net.dc !== dc) return;
    if (net.started) rbDropped("channel closed", "Peer disconnected");
  };
  rb.rsAnswerTimer = setTimeout(() => {
    if (net?.dc === dc && rb.reconnecting) rsRestart(rb, "no RESUME from the friend");
  }, RB_RESUME_ANSWER_MS);
  const buf = new ArrayBuffer(10);
  const v = new DataView(buf);
  v.setUint8(0, RB_RESUME);
  v.setUint32(1, rb.resume.sid);
  v.setInt32(5, rb.lastRx);
  // Kept: the friend decides pause and 2x from these, and so must we.
  rb.rsFlags = (document.hidden ? 1 : 0) | (paused ? 2 : 0) | (speed2x ? 4 : 0);
  v.setUint8(9, rb.rsFlags);
  rbSend(buf);
  log("netplay: redial: channel open, last input from the friend " + rb.lastRx);
  const early = rb.rsEarly;
  rb.rsEarly = [];
  for (const d of early) rbMessage(d);
};

// The friend's RESUME: resend what it missed (from the log, in order), take
// its state, play on.
const rsResumeIn = (rb, v) => {
  if (!rb.reconnecting || !rb.resume || !rb.rsDcOpen) return;
  if (v.getUint32(1) !== rb.resume.sid) {
    netPeerGone("Couldn't resume the link");
    return;
  }
  const theirs = v.getInt32(5);
  const flags = v.getUint8(9);
  const oldest = Math.max(0, rb.sentCount - RB_SENT_LOG);
  const gap = [];
  for (let n = oldest; n < rb.sentCount; n++) {
    const i = n % RB_SENT_LOG;
    if (rb.sentFrames[i] > theirs) gap.push(i);
  }
  if (gap.length && rb.sentFrames[gap[0]] > theirs + 1) {
    log("netplay: the friend's gap is older than the input log", "warn");
    netPeerGone("Couldn't resume the link");
    return;
  }
  rsStop(rb);
  rb.peerAwayAtDrop = false;
  rbMarkLive(rb);
  for (const i of gap) rbSendInputWire(rb.sentFrames[i], rb.sentBits[i]);
  log("netplay: resumed after " + fmtAway(performance.now() - rb.reconnectSince) +
      " (resent " + gap.length + " inputs from frame " + (theirs + 1) + ")");
  rbRenderCard();
  showToast("Reconnected — link resumed");
  if (flags & 1) rbPeerAway(true);
  else rbHideAwayCard(); // back too: one toast, not two
  // Pause and 2x messages from during the drop were lost or held. Both
  // sides decide from the same two RESUMEs, so they agree without another
  // message (answering with each one's own state would cross and swap
  // them): running wins, except that a side that was paused and away (a
  // hidden tab, an app in the background) keeps both paused; slow wins.
  // A Pause press after our RESUME went out is a press of its own, after
  // that decision: it holds, and goes to the friend like any other.
  // Presses count again from the decision, which both sides hold as the
  // host's press 0: nothing from before it can arrive on this channel, and
  // a press after it (1 on) beats it on both sides.
  const want = rbResumeState(rb.rsFlags | 0, flags);
  rb.pauseReg = rbNewReg(want.paused);
  rb.speedReg = rbNewReg(want.speed2x);
  if (paused !== !!(rb.rsFlags & 2)) {
    if (paused !== want.paused) rbSendPause(paused);
  } else if (paused !== want.paused) {
    window.applyRemotePause?.(want.paused);
  }
  if (speed2x !== want.speed2x) window.applyRemoteSpeed2x?.(want.speed2x);
};

// The pause and 2x both sides take after a resume, from the two RESUMEs'
// flags (1 away, 2 paused, 4 2x); symmetric, so both get the same answer.
// formal/WebState/LinkResume.lean `finalPause` proves the two then agree.
const rbResumeState = (mine, theirs) => {
  const pausedAway = (f) => (f & 3) === 3;
  return {
    paused: !!((mine & theirs & 2) || pausedAway(mine) || pausedAway(theirs)),
    speed2x: !!(mine & theirs & 4),
  };
};

document.getElementById("net-to-manual").addEventListener("click", () => {
  manualEnter();
  if (netManualView && !netManualView.hidden) {
    setTimeout(() => manualIn?.focus(), 0);
  }
});
document.getElementById("net-to-code").addEventListener("click", manualBack);

document.getElementById("net-close").addEventListener("click", netDismissModal);
netModal.addEventListener("click", (e) => {
  if (e.target === netModal) netDismissModal();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && netModalOpen()) netDismissModal();
});
