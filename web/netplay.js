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

const netModal = document.getElementById("net-modal");
const netTitle = document.getElementById("net-title");
const netStatusDiv = document.getElementById("net-status");
const netCodeInput = /** @type {HTMLInputElement} */ (document.getElementById("net-code-input"));
const netJoinGo = /** @type {HTMLButtonElement} */ (document.getElementById("net-join-go"));
const netStallBadge = document.getElementById("net-stall");
const netSpinner = document.getElementById("net-spinner");

const netModalOpen = () => netModal.classList.contains("open");

const netSetConnecting = (on) => {
  if (netSpinner) netSpinner.hidden = !on;
  netCodeInput.readOnly = on;
  netJoinGo.textContent = on ? "Cancel" : "Connect";
};

const netSetStatus = (msg, isError) => {
  netStatusDiv.textContent = msg;
  netStatusDiv.classList.toggle("net-error", !!isError);
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
  helloDone: false,     // wire handshake validated (first successful tick)
  rxQueue: [],
  stallSince: 0,
});
let netAttach = true;   // attach mode of the current/last pending session (for retry)
// Switches the modal to the manual code exchange when the server has not
// answered a rendezvous in time; disarmed by any server reply (a lone peer
// on "waiting" is healthy).
let manualFallbackTimer = 0;
const MANUAL_FALLBACK_DELAY = 2000;
// Redial schedule for a server socket that drops after answering at least
// once; then give up into the manual exchange. Any server reply refills it.
const SIG_REDIAL_DELAYS = [1000, 2000, 4000];
// "paired" to DataChannel-open backstop: ICE starved of the far side's
// candidates sits in checking forever without reaching 'failed'. Generous,
// since a slow STUN round can legitimately take 10s+.
const RTC_CONNECT_DEADLINE = 20000;

const closeNetModal = () => {
  netModal.classList.remove("open");
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
  netFrozeGame = !!currentRomName && !paused;
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
  if (oext !== ".gba" && oext !== ".gb" && oext !== ".gbc") {
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

const sigConnect = () =>
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
      if (hasAltPath()) {
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

// Response deadline for a just-sent rendezvous; any server reply disarms it.
const armManualFallback = (session) => {
  clearTimeout(manualFallbackTimer);
  manualFallbackTimer = setTimeout(() => {
    if (net === session && !net.dc && !net.rtcConnected && !net.started) {
      sigServerUp = false;
      manualEnter(true);
    }
  }, MANUAL_FALLBACK_DELAY);
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
  session.redialTimer = setTimeout(async () => {
    if (net !== session || session.dc || session.rtcConnected || session.started) return;
    if (await sigConnect()) {
      if (net !== session || session.dc) return;
      sigSend({ t: "rendezvous", code: session.code });
      armManualFallback(session);
    }
    // else: that dial's onclose lands back in sigRedial
  }, SIG_REDIAL_DELAYS[attempt]);
};

const onSigMessage = async (msg) => {
  if (!net) return;
  // Any reply is proof of life: disarm the fallback, refill the redial budget.
  clearTimeout(manualFallbackTimer);
  net.redials = 0;
  sigServerUp = true;
  try {
    switch (msg.t) {
      case "waiting":
        netSetStatus("");
        break;
      case "paired":
        // host = WebRTC offerer = unit 0.
        net.isHost = msg.role === "host";
        netSetStatus("Friend found — connecting…");
        await startRtc(net.isHost);
        break;
      case "sdp":
        if (!net.pc) return;
        await net.pc.setRemoteDescription(msg.d);
        if (msg.d.type === "offer") {
          const answer = await net.pc.createAnswer();
          await net.pc.setLocalDescription(answer);
          sigSend({ t: "sdp", d: net.pc.localDescription });
        }
        break;
      case "ice":
        if (net.pc && msg.c) await net.pc.addIceCandidate(msg.c).catch(() => {});
        break;
      case "peer-closed":
        if (!net.rtcConnected) netFail("The other side left");
        break;
      case "error":
        netFail(msg.msg || "Connection error");
        break;
    }
  } catch (e) {
    netFail("Connection setup failed: " + e.message);
  }
};

const startRtc = async (isOfferer) => {
  const session = net;
  const pc = new RTCPeerConnection({ iceServers: NET_ICE_SERVERS });
  session.pc = pc;
  // A checking phase that never starts never reaches 'failed' on its own.
  clearTimeout(session.rtcDeadline);
  session.rtcDeadline = setTimeout(() => {
    if (net === session && !net.rtcConnected && !net.started) {
      netFail("Could not connect peer-to-peer (a strict NAT on one side may be blocking it)");
    }
  }, RTC_CONNECT_DEADLINE);
  pc.onicecandidate = (e) => {
    if (e.candidate) sigSend({ t: "ice", c: e.candidate });
  };
  pc.onconnectionstatechange = () => {
    if (!net || net.pc !== pc) return;
    const st = pc.connectionState;
    if (st === "failed") {
      netFail(
        net.rtcConnected
          ? "Peer connection lost"
          : "Could not connect peer-to-peer (a strict NAT on one side may be blocking it)"
      );
    } else if ((st === "disconnected" || st === "closed") && net.started) {
      netPeerGone("Peer connection lost");
    }
  };
  if (isOfferer) {
    wireChannel(pc.createDataChannel("link", { ordered: true }));
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    sigSend({ t: "sdp", d: pc.localDescription });
  } else {
    pc.ondatachannel = (e) => wireChannel(e.channel);
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
  dc.onmessage = (e) =>
    NET_ROLLBACK ? rbMessage(e.data) : netReceive(new Uint8Array(e.data));
  dc.onclose = () => {
    if (!net) return;
    if (net.started) netPeerGone("Peer disconnected");
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
    screenLock = (await navigator.wakeLock?.request("screen")) || null;
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
// Stop propagation so the SDL key handlers never see the field; that also
// hides Escape from the document handler, so dismiss here directly.
manualIn && ["keydown", "keypress", "keyup"].forEach((t) =>
  manualIn.addEventListener(t, (/** @type {KeyboardEvent} */ e) => {
    if (t === "keydown" && e.key === "Enter" && !manualConfirm.disabled) manualConfirmGo();
    if (t === "keydown" && e.key === "Escape") netDismissModal();
    e.stopPropagation();
  })
);

// Input-rollback wire protocol over the DataChannel (first byte = kind):
//   0 hello        : [0][epoch u32][romHash u32]  (host's epoch is the shared clock)
//   1 input        : [1][frame i32][bits u16]      (this peer's buttons for a frame)
//   2 state-begin  : [2][len u32]                  (full save-state, chunked)
//   3 state-chunk  : [3][bytes…]
//   4 rom-begin    : [4][len u32]                  (this peer's ROM, chunked)
//   5 rom-chunk    : [5][bytes…]
//   6 ready        : [6]                           (cores built + states loaded)
//   7 speed        : [7][on u8]                     (2x fast-forward toggle — both cores)
//   8 pause        : [8][on u8]
// Both peers run both cores (core 0 = host's game, core 1 = guest's): each
// side's save-state is exchanged and loaded into the matching core, then only
// inputs cross the network. When the hello hashes differ (cross-game trade)
// each peer also streams its ROM so both hold the same {host, guest} pair.
// The "ready" barrier keeps either peer from ticking until both have booted.

const RB_HELLO = 0, RB_INPUT = 1, RB_STATE_BEGIN = 2, RB_STATE_CHUNK = 3;
const RB_ROM_BEGIN = 4, RB_ROM_CHUNK = 5, RB_READY = 6, RB_SPEED = 7;
const RB_PAUSE = 8;
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

const rbSend = (buf) => {
  if (!net?.dc || net.dc.readyState !== "open") return;
  try {
    net.dc.send(buf);
  } catch {}
};

const rbSendInput = (frame, bits) => {
  const buf = new ArrayBuffer(7);
  const v = new DataView(buf);
  v.setUint8(0, RB_INPUT);
  v.setInt32(1, frame);
  v.setUint16(5, bits);
  if (NET_LINK_DELAY > 0) setTimeout(() => rbSend(buf), NET_LINK_DELAY);
  else rbSend(buf);
};

// 2x drives both peers: a one-sided 2x just stalls at the prediction window.
const rbSendSpeed = (on) => {
  const buf = new ArrayBuffer(2);
  const v = new DataView(buf);
  v.setUint8(0, RB_SPEED);
  v.setUint8(1, on ? 1 : 0);
  rbSend(buf);
};

// Pause drives both peers too, so the freeze shows rather than reads as a stall.
const rbSendPause = (on) => {
  const buf = new ArrayBuffer(2);
  const v = new DataView(buf);
  v.setUint8(0, RB_PAUSE);
  v.setUint8(1, on ? 1 : 0);
  rbSend(buf);
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
  if (oext !== ".gba" && oext !== ".gb" && oext !== ".gbc")
    throw new Error("link cable needs a GB/GBC/GBA game");
  rbExt = oext === ".gba" ? ".gba" : oext;
  linkIsGb = rbExt !== ".gba";
  const localState = rbCaptureState();
  // Freeze at the snapshot so the game cannot run past it; enterRollbackMode
  // unfreezes into the session.
  paused = true;
  const romBytes = FS.readFile(currentRomName);
  net.rb = {
    localPlayer: net.isHost ? 0 : 1,
    epoch: net.isHost ? Math.floor(Date.now() / 1000) : 0,
    romHash: rbHash(romBytes),
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
  };
  netSetStatus("Syncing…");
  const h = new ArrayBuffer(9);
  const hv = new DataView(h);
  hv.setUint8(0, RB_HELLO);
  hv.setUint32(1, net.rb.epoch);
  hv.setUint32(5, net.rb.romHash);
  rbSend(h);
  rbSendState(localState);
};

const rbMessage = (data) => {
  const rb = net?.rb;
  if (!rb) return;
  const v = new DataView(data);
  const kind = v.getUint8(0);
  if (kind === RB_INPUT) {
    if (rb.inited && Module._rollback_feed)
      Module._rollback_feed(v.getInt32(1), v.getUint16(5));
    return;
  }
  if (kind === RB_READY) {
    rb.remoteReady = true;
    rbStartIfReady();
    return;
  }
  if (kind === RB_SPEED) {
    // Match without echoing back.
    window.applyRemoteSpeed2x?.(v.getUint8(1) === 1);
    return;
  }
  if (kind === RB_PAUSE) {
    // Mirror without echoing back.
    window.applyRemotePause?.(v.getUint8(1) === 1);
    return;
  }
  if (kind === RB_HELLO) {
    rb.remoteRomHash = v.getUint32(5);
    if (!net.isHost) rb.epoch = v.getUint32(1); // guest adopts the host's clock
    rb.remoteHello = true;
    if (rb.remoteRomHash !== rb.romHash) {
      rb.needRom = true;
      rbShowXferProgress();
      rbSendOurRom();
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
      if (rbHash(rb.romBuf) !== rb.remoteRomHash) {
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
  armManualFallback(session);
  // Same-browser BroadcastChannel and signaling server race; the first to
  // connect wins (wireChannel tears the loser down).
  startLocalLink(code);
  if (await sigConnect()) {
    if (net !== session || net.dc) return; // paired locally or cancelled
    sigSend({ t: "rendezvous", code });
  } else if (net === session && !net.dc && !net.rtcConnected) {
    clearTimeout(manualFallbackTimer);
    manualEnter(true);
  }
});

// Stop propagation at the field so SDL's window-level handlers (which
// preventDefault keypress) never see it; Escape is then dismissed here.
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
    if (currentRomName && currentOriginalName) {
      await persistSave(currentRomName, currentOriginalName);
    }
    const romFile = "rom" + extOf(rom.name);
    writeToFS(romFile, rom.data);
    currentRomName = romFile;
    currentOriginalName = rom.name;
    await restoreSave(romFile, rom.name);
    const ok = Module.ccall(
      "netlink_init",
      "number",
      ["string", "number", "number"],
      [romFile, net.isHost ? 1 : 0, 1]
    );
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
  netShutdown();
  if (started) {
    showToast(msg + " — your game keeps running");
  } else {
    netSetStatus(msg, true);
  }
};

// The local game keeps running unlinked once netMode is false.
const netShutdown = async (opts) => {
  netStallBadge.hidden = true;
  clearTimeout(manualFallbackTimer);
  const s = net;
  net = null;
  if (s) {
    clearTimeout(s.redialTimer);
    clearTimeout(s.rtcDeadline);
  }
  // Thaw the game frozen at modal open, even if rb was never created.
  if (netFrozeGame) {
    netFrozeGame = false;
    paused = false;
    document.body.classList.remove("paused");
    pauseButton.classList.remove("paused", "active");
    pauseButton.title = "Pause";
  }
  if (s?.rb) {
    paused = false;
    document.body.classList.remove("paused");
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
    netShutdown();
    showToast("Disconnected");
  }
);
rbDisconnectBtn.addEventListener("click", () => {
  if (net?.started || net?.rb?.inited) rbDisconnectArm.fire();
});

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
