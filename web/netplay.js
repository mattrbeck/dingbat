// --- Online link play (multiplayer phase 3b) ---
// Two browsers, one emulated link cable: a WebRTC DataChannel
// (reliable+ordered) carries the linkproto wire frames between this page's
// wasm core (netlink_* exports) and the peer's. Peers find each other
// through the room-code signaling server (web/signaling/server.js), which
// only relays the SDP offer/answer + ICE candidates — game traffic is
// always peer-to-peer.
//
// Loaded after index.js (shares its top-level bindings: Module, writeToFS,
// showToast, currentRomName, ...). The RAF loop in index.js calls netStep/
// netAfterTick while netMode is set, exactly like the linkMode branch.

// ?signal=ws://... overrides the signaling server (dev/self-hosted);
// ?linkdelay=50 adds N ms of artificial latency to every outgoing message
// (internet simulation, mirrors the native --netlink-delay-ms knob).
// Loopback, RFC 1918 LAN, and mDNS .local origins are dev serves: they talk
// to a signaling server on the same host (:8790, plain ws). Everything else
// defaults to the production endpoint (the static site is on GitHub Pages,
// which can't proxy WebSockets, so a same-origin /signal path can never work
// there). An https dev serve needs ?signal= — ws: from https: is blocked as
// mixed content.
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
// SIO-word speculation is DISABLED — it is unsafe for a real trade. It predicts
// the peer's reply and puts the *next* transfer (built from that prediction) on
// the wire; when the master's outgoing word depends on the received word (true
// in any real trade) a misprediction ships wrong bytes the guest already
// consumed and can't be recalled → the guest's game raises "link error". Proven
// with tests/roms/speclinkdep.gba. Superseded by input-level rollback (run both
// cores locally, network only keypresses). `?speculative=1` is now a no-op.
const NET_SPECULATIVE = false;
// Input-rollback online play (the fast path): both cores run locally, only
// per-frame inputs cross the network, prediction+rollback hides latency. This
// is the default; `?rollback=0` falls back to the (slow, RTT-bound) SIO path.
const NET_ROLLBACK = NET_PARAMS.get("rollback") !== "0";
// STUN-only for v1: most home NATs connect; symmetric NAT/strict CGNAT
// pairs fail with a clear error (a TURN relay is a future option).
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

// Reflect the "connecting" state on the entry form: lock the code field with
// the amber spinner pinned inside its right edge, and turn Connect into Cancel.
// This is the whole waiting indicator now — no separate status line/spinner.
const netSetConnecting = (on) => {
  if (netSpinner) netSpinner.hidden = !on;
  netCodeInput.readOnly = on;
  netJoinGo.textContent = on ? "Cancel" : "Connect";
};

const netSetStatus = (msg, isError) => {
  netStatusDiv.textContent = msg;
  netStatusDiv.classList.toggle("net-error", !!isError);
  // An error ends the waiting state; unlock the form so the code can be fixed.
  if (isError) netSetConnecting(false);
};

// A fresh pending session. `attach` = bind to the already-running core with no
// reboot (the only path today; the game is up and we plug the cable in).
// isHost is unknown until the signaling server pairs us and names a role.
const makeSession = (attach) => ({
  attach,
  isHost: null,         // decided by the "paired" role (arrival order)
  ws: null,
  pc: null,
  bc: null,             // same-browser BroadcastChannel (no server, no WebRTC)
  localChan: null,      // LocalChannel wrapping bc, once the local path pairs
  abortLocal: null,     // tears down the local path if WebRTC wins the race
  manualChan: null,     // manual-exchange DataChannel (wired only if we end up host)
  manualCode: null,     // our encoded offer, as shown in "Your code"
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
// Timer that switches the modal to the manual code exchange when the signaling
// server hasn't answered a rendezvous within ~2s (armed each time one is sent;
// disarmed by ANY server reply — a peer waiting alone on "waiting" is a healthy
// state, not an unresponsive server).
let manualFallbackTimer = 0;
const MANUAL_FALLBACK_DELAY = 2000;
// Reconnect pacing for a server socket that drops after the server answered at
// least once (deploy restart, proxy idling the connection out, network blip):
// a few spaced dials, then give up into the manual exchange. Any server reply
// refills the budget, so an arbitrarily long wait survives repeated drops while
// never dialing faster than this schedule.
const SIG_REDIAL_DELAYS = [1000, 2000, 4000];
// Backstop from "paired" to the DataChannel opening. Signaling lost mid-relay
// can leave ICE without the far side's candidates — a state browsers sit in
// forever without reaching 'failed'. Generous: real cross-network ICE with a
// slow STUN round can legitimately take 10s+.
const RTC_CONNECT_DEADLINE = 20000;

const closeNetModal = () => {
  netModal.classList.remove("open");
  netSetConnecting(false);
  clearTimeout(manualFallbackTimer);
  if (typeof manualReset === "function") manualReset();
  releaseFocus(netModal);
};

// ---------------- signaling server liveness probe ----------------
// Dialed on the same cadence as index.js's update check (page load + the tab
// becoming visible, plus every modal open), so the link modal can skip the
// doomed shared-code attempt and open STRAIGHT to the manual code exchange
// when the server was last seen down. Real connect attempts also feed the
// flag, so it stays current without extra dials. Unlike the update check's
// 24h stamp, liveness goes stale in minutes — the throttle only smooths
// rapid tab-switch flapping.
let sigServerUp = null; // null = never probed; otherwise last known liveness
let sigProbeAt = 0;
const SIG_PROBE_MIN_INTERVAL = 30000;
const SIG_PROBE_TIMEOUT = 4000; // a silent host is "down", same as an error

const probeSignalServer = () => {
  const now = Date.now();
  if (now - sigProbeAt < SIG_PROBE_MIN_INTERVAL) return;
  sigProbeAt = now;
  // Every outcome is logged with its timing: this probe decides whether the
  // link modal even offers the shared-code flow, and it used to fail silently
  // — "the modal opens straight to code trading and the log says nothing" was
  // undiagnosable from the device.
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
  // First outcome wins. iOS Safari fires a LATE error event on a socket we
  // close right after it opens — without the latch, every successful probe
  // immediately overwrote its own verdict with "down" on WebKit (seen on an
  // iPhone as "probe ok in 537ms" followed by "errored after 667ms"), and the
  // link modal opened onto the manual exchange on a perfectly healthy server.
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

// Open the single shared-code entry modal and stage a pending session. Both
// players type the SAME code; the signaling server makes whoever arrives first
// the host. No Host/Join choice — just like plugging in a link cable.
// True while the connect modal froze the running game (so cancel can thaw it).
let netFrozeGame = false;

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
  // Server known-down from the last probe: no point walking into the shared-code
  // flow — open straight onto the manual exchange (re-probing in the background
  // so a recovered server puts the next open back on the normal path).
  if (sigServerUp === false && navigator.onLine) {
    log("netplay: last probe saw the server down — opening onto the manual exchange", "warn");
    probeSignalServer();
    manualEnter();
  }
  // Freeze the running game the moment this modal opens and keep it frozen
  // through code entry, pairing, and the ROM/state transfer. The modal covers
  // the emulation frame anyway, and letting the game keep running lets its OWN
  // single-player link handshake ("Please wait", "Your friend is not ready")
  // time out before the peer connects. Thawed on cancel (netShutdown) or when
  // the session starts (launchNetRom / enterRollbackMode via rbStartIfReady).
  netFrozeGame = !!currentRomName && !paused;
  if (netFrozeGame) {
    paused = true;
    document.body.classList.add("paused");
    pauseButton.classList.add("paused", "active");
  }
  // Drop the cursor straight in the field so the code can be typed immediately
  // (the friend's-code field when we opened onto the manual exchange).
  setTimeout(() => {
    (netManualView && !netManualView.hidden ? manualIn : netCodeInput)?.focus();
  }, 0);
};

// --- "Link Cable" menu button ---
// Opens the connect modal bound to the already-running game (attach mode).
// Online link is GBA-only, so guard other cores.
const netConnectLabel = document.querySelector("#net-connect span");
// Reflect connection state on the menu item: connect vs disconnect.
window.setNetConnectLabel = (connected) => {
  if (netConnectLabel) netConnectLabel.textContent = connected ? "Disconnect" : "Link Cable";
};

document.getElementById("net-connect").addEventListener("click", () => {
  menuDropdown.hidden = true;
  // Already linked → this is the disconnect action.
  if (net?.started || net?.rb?.inited) {
    netShutdown();
    showToast("Disconnected");
    return;
  }
  const oext = extOf(currentOriginalName || "");
  if (oext !== ".gba" && oext !== ".gb" && oext !== ".gbc") {
    showToast("Link cable needs a GB, GBC, or GBA game");
    return;
  }
  // GBA and GB/GBC both use the online (two-browser) input-rollback link now.
  openNetConnect(true);
});

// ---------------- signaling ----------------

const sigSend = (obj) => {
  if (net?.ws?.readyState === WebSocket.OPEN) net.ws.send(JSON.stringify(obj));
};

const netFail = (msg) => {
  // Setup-phase failure: report in the modal (if open) and toast, then tear
  // down. If the game already started this is a peer-gone case instead.
  if (net?.started) {
    netPeerGone(msg);
    return;
  }
  log("netplay: " + msg, "warn");
  netSetStatus(msg, true);
  netShutdown({ keepModal: true });
  // Setup failed but the modal is still up: re-arm a pending session so the
  // player can fix the code and hit Connect again without reopening.
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
    // A dead/closing server is only fatal when nothing else can carry the
    // session: no same-browser peer listening (bc), not already linked locally
    // (dc), and not already running (rtcConnected/started). The same-browser
    // path runs in parallel for every connect, so a down server must never tear
    // a session down while that path is still live or has already won.
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
        // Only note it while we're still waiting on the local peer; once linked
        // (dc set) the server is simply irrelevant.
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
      // Fires for every socket end, so sort them: our own teardowns null `net`
      // (netShutdown) or `net.ws` (wireChannel, manualEnter) before closing and
      // fail the first guard; a linked session no longer needs the server; a
      // pairing already in flight is the RTC deadline's to resolve (the room
      // died with the socket, so redialing mid-handshake helps nobody). What
      // remains is the server — or the path to it — dropping us while we dial
      // or wait for a friend: reconnect and re-rendezvous, with backoff.
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

// Arm (or re-arm) the response deadline for a just-sent rendezvous: if the
// signaling server hasn't answered within ~2s, treat it as unreachable and
// flip the modal to the manual code exchange (its base text becomes "Trade
// codes with your friend"). Racing a slow-but-alive server any longer isn't
// worth it: the exchange also works same-LAN with no internet. Any server
// reply disarms this (onSigMessage) — waiting for a friend is not a timeout.
const armManualFallback = (session) => {
  clearTimeout(manualFallbackTimer);
  manualFallbackTimer = setTimeout(() => {
    if (net === session && !net.dc && !net.rtcConnected && !net.started) {
      sigServerUp = false;
      manualEnter(true);
    }
  }, MANUAL_FALLBACK_DELAY);
};

// The server answered at least once and its socket then died mid-wait. The
// room died with it on the server, so reconnect and re-rendezvous with the
// same code — both peers ride this same path, so a server restart re-pairs
// them as each side re-registers. A handful of spaced dials, then the same
// give-up as a server that never answered. The budget refills only when the
// server actually replies (onSigMessage), so a flapping server is retried at
// this schedule's pace at worst, never hammered.
const sigRedial = () => {
  const session = net;
  if (!session || !session.code) return;
  if (!navigator.onLine) {
    manualEnter(true); // no interface at all — redialing can't help; say so now
    return;
  }
  clearTimeout(manualFallbackTimer); // the redial chain owns the give-up now
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
      armManualFallback(session); // a fresh socket must earn a reply too
    }
    // else: that dial's onclose lands back in sigRedial for the next attempt
  }, SIG_REDIAL_DELAYS[attempt]);
};

const onSigMessage = async (msg) => {
  if (!net) return;
  // Any reply is proof of life: a solo peer parked on "waiting" is a healthy
  // server, not an unresponsive one. Disarm the manual-exchange fallback and
  // refill the redial budget, so an arbitrarily long wait survives any number
  // of well-spaced socket drops.
  clearTimeout(manualFallbackTimer);
  net.redials = 0;
  sigServerUp = true;
  try {
    switch (msg.t) {
      case "waiting":
        // The in-field spinner + "Cancel" button convey the wait; no text line.
        netSetStatus("");
        break;
      case "paired":
        // Arrival order picked our role: host = WebRTC offerer = unit 0.
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
        // The server's messages ("that code is already in use…", "code too
        // short") are already player-friendly; show them as-is.
        netFail(msg.msg || "Connection error");
        break;
    }
  } catch (e) {
    netFail("Connection setup failed: " + e.message);
  }
};

// ---------------- WebRTC ----------------

const startRtc = async (isOfferer) => {
  const session = net;
  const pc = new RTCPeerConnection({ iceServers: NET_ICE_SERVERS });
  session.pc = pc;
  // Paired, but the DataChannel never opens: signaling dying mid-relay starves
  // ICE of the far side's candidates, and a checking phase that never starts
  // won't reach 'failed' on its own — without a deadline the modal would show
  // "Friend found — connecting…" forever.
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
    // The host offers; it is also unit 0 (the multi-mode parent).
    wireChannel(pc.createDataChannel("link", { ordered: true }));
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    sigSend({ t: "sdp", d: pc.localDescription });
  } else {
    pc.ondatachannel = (e) => wireChannel(e.channel);
  }
};

const wireChannel = (dc) => {
  // Two connect paths race (local BroadcastChannel vs. server+WebRTC); the first
  // to hand us a channel wins and the loser is torn down here.
  if (net.dc) {
    try {
      dc.close?.(true); // silent: discarding the losing channel, don't signal "bye"
    } catch {}
    return;
  }
  net.dc = dc;
  if (net.abortLocal && dc !== net.localChan) net.abortLocal(); // WebRTC won → drop BC
  net.abortLocal = null;
  dc.binaryType = "arraybuffer";
  dc.onopen = () => {
    net.rtcConnected = true;
    clearTimeout(net.rtcDeadline);
    // Linked (WebRTC peer, or a same-browser BroadcastChannel): the signaling
    // server's job is done. Closing the socket also RELEASES our room on the
    // server at once — so when two same-browser tabs pair locally, whichever had
    // registered a code frees it immediately instead of holding it for the TTL.
    // (web/signaling/server.test.mjs pins this room-freeing contract.)
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
    // Dropped mid-handshake (the ROM/state exchange can take seconds): don't
    // leave this peer frozen behind the modal — surface it and re-arm.
    else if (net.rb && !net.rb.inited) netFail("Connection lost during setup");
  };
};

// ---------------- same-browser fast path (no signaling, no WebRTC) ----------------
// Two tabs/windows of the SAME browser can link with zero infrastructure: no
// signaling server and no WebRTC at all. They rendezvous on a BroadcastChannel
// keyed by the shared code and then carry the exact same wire traffic a
// DataChannel would. LocalChannel below mimics just the RTCDataChannel surface
// wireChannel()/rbSend*()/rbDrain() touch, so everything downstream is unchanged.
//
// Scope: BroadcastChannel only reaches same-origin contexts in the SAME browser
// profile. Different browsers (Chrome↔Safari) or different devices are sandboxed
// from each other and still take the signaling + WebRTC path.

const LOCAL_PREFIX = "dingbat-link-"; // BroadcastChannel name = prefix + code

const netRandId = () => {
  const a = new Uint32Array(1);
  crypto.getRandomValues(a);
  return a[0] || 1; // 0 is reserved as "unset"; re-roll to any nonzero
};

// A BroadcastChannel-backed stand-in for an RTCDataChannel. Exposes only what
// the transport actually uses: send(), onmessage (e.data = ArrayBuffer, matching
// binaryType="arraybuffer"), readyState, close/onclose, and a faked bufferedAmount
// so rbSendRom's backpressure loop yields between bursts instead of blocking the
// main thread on a multi-MB synchronous flood (BroadcastChannel has no send buffer).
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
    // The caller reuses/frees its buffer, so hand postMessage a standalone copy.
    const ab =
      buf instanceof ArrayBuffer
        ? buf.slice(0)
        : buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
    this.bc.postMessage({ ch: "link", t: "data", buf: ab });
    // Fake enough backpressure that rbSendRom's loop awaits rbDrain and yields.
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

// Start listening for another tab of this browser on `code`. Runs CONCURRENTLY
// with the signaling + WebRTC path (see the connect handler): whichever pairs
// first wins and wireChannel() tears the other down. Unlike a one-shot probe,
// this keeps listening until a peer appears, WebRTC wins, or the user cancels —
// so the two players don't have to hit Connect at the same instant. When no
// server is reachable at all, this is the only path, and same-browser still links.
const startLocalLink = (code) => {
  const session = net;
  let bc;
  try {
    bc = new BroadcastChannel(LOCAL_PREFIX + code);
  } catch {
    return; // no BroadcastChannel support → WebRTC path carries on alone
  }
  session.bc = bc; // reachable for Cancel/shutdown
  const myId = netRandId();

  const onMsg = (e) => {
    if (net !== session || net.dc) return; // torn down, or the other path won
    const m = e.data;
    if (!m || m.ch !== "hello") return;
    if (m.t === "hi") {
      // A peer announced. Answer so it learns us — it may have opened after our
      // own announce, which it never saw (BroadcastChannel keeps no history).
      try {
        bc.postMessage({ ch: "hello", t: "yo", id: myId, to: m.id });
      } catch {}
      pair(m.id);
    } else if (m.t === "yo" && m.to === myId) {
      pair(m.id);
    }
  };

  // Higher nonce = host (unit 0 / the multi-mode parent, the WebRTC offerer).
  // Both tabs compute the same winner, so roles never collide.
  const pair = (peerId) => {
    if (net !== session || net.dc || peerId === myId) return; // won elsewhere, or a tie
    bc.removeEventListener("message", onMsg); // hello handshake done
    session.isHost = myId > peerId;
    const chan = new LocalChannel(bc);
    session.localChan = chan; // marks the local path as the winner in wireChannel
    wireChannel(chan);
    // No async "channel open": the cable is live the instant both tabs agree.
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

// ---------------- Manual code exchange (server unreachable) ----------------
// Fallback when the network is up but the signaling server isn't: the modal's
// text flips to "Trade codes with your friend." and each side shows ONE compact
// code (SDPCodec, sdputil.js) to send over any messenger, pastes the friend's,
// and confirms. This reuses the exact same post-connect flow — wireChannel() →
// rbConnect() — so once the DataChannel opens it is identical to the server
// path.
//
// Why it differs from the server path:
//  1. NON-TRICKLE gathering — the server path trickles ICE candidates one by one
//     as they arrive; here there is no channel to trickle over, so we wait for
//     ICE gathering to COMPLETE and bundle one full localDescription.
//  2. COMPRESSION — a raw data-channel SDP is ~600–900 bytes of boilerplate.
//     SDPCodec strips it to ~130 bytes (fingerprint + ufrag/pwd + candidates).
//  3. SYMMETRIC one-shot exchange — no host/guest choice and no second round
//     trip. BOTH sides encode an offer; each side locally rewrites the peer's
//     blob into the answer to its own offer (SDPCodec.answerFrom), with
//     complementary DTLS roles picked by comparing the two code strings. The
//     comparison winner ("host", also unit 0) wires its own pre-created
//     DataChannel; the other side takes ondatachannel. Pinned end-to-end
//     against real browser PCs in web/manualpair.test.mjs.
//
// Same-LAN reachability (Wi-Fi without internet) rides on the mDNS host
// candidate (uuid.local): both Chrome and Safari resolve a peer's .local
// candidate over the local network, so two phones connect even with no STUN
// reflexive path between them.

const MANUAL_GATHER_TIMEOUT = 3500; // ms cap on ICE gathering once a public address is in hand
// A code minted without a server-reflexive (STUN/public) candidate can only
// pair on its own LAN — across the internet the peer sees nothing but an
// unresolvable mDNS name and sits in "Connecting…" forever. When STUN is
// merely slow (cellular CGNAT), wait longer before settling for a LAN-only
// code; gathering completion still resolves early on fast networks.
const MANUAL_GATHER_EXTENDED = 8000;

const netConnectView = document.getElementById("net-connect-view");
const netManualView = document.getElementById("net-manual-view");
const manualOut = /** @type {HTMLInputElement} */ (document.getElementById("net-manual-out"));
const manualIn = /** @type {HTMLInputElement} */ (document.getElementById("net-manual-in"));
const manualCopyBtn = document.getElementById("net-manual-copy");
const manualConfirm = /** @type {HTMLButtonElement} */ (document.getElementById("net-manual-confirm"));
const manualStatusDiv = document.getElementById("net-manual-status");

const manualSetStatus = (msg, isError) => {
  if (!manualStatusDiv) return;
  manualStatusDiv.textContent = msg || "";
  manualStatusDiv.classList.toggle("net-error", !!isError);
};

// Wait for full ICE gathering so ONE bundled description carries every candidate.
// Resolves on the 'complete' state (or the null-candidate sentinel), with a
// timeout so a stuck STUN server can't hang the flow — the host mDNS candidate
// is usually already present and is what carries a same-LAN link anyway.
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

// Connection-state handler (mirrors startRtc's). A pre-start failure means the
// traded codes are spent (the PC is dead), so put a FRESH code up along with
// the error — both sides fail together, so both regenerate together.
// Compact ICE candidate-pair dump for a dead manual pairing: which pairs
// formed, and whether checks went unanswered (sent>0 got=0 = our packets
// vanish into a NAT) or never went out at all.
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
    logIcePairs(pc); // best-effort: the teardown below races the snapshot
    if (net.rtcConnected) {
      netFail("Peer connection lost");
      return;
    }
    netFail("Couldn't connect with those codes");
    if (netModalOpen() && netManualView && !netManualView.hidden) {
      manualSetStatus("Couldn't connect — trade these fresh codes and try again", true);
      manualPrepare();
    }
  } else if ((st === "disconnected" || st === "closed") && net.started) {
    netPeerGone("Peer connection lost");
  }
};

// Build this side's offer and put its code in the "Your code" box. The
// DataChannel must exist before the offer (its m-line), but which side WIRES
// its channel isn't known until the friend's code arrives, so it waits unwired
// in net.manualChan.
const manualPrepare = async () => {
  if (!net) net = makeSession(netAttach);
  const session = net;
  session.manualCode = null;
  if (manualOut) manualOut.value = "";
  if (manualIn) { manualIn.value = ""; manualIn.readOnly = false; }
  if (manualConfirm) manualConfirm.disabled = true;
  try {
    const pc = new RTCPeerConnection({ iceServers: NET_ICE_SERVERS });
    session.pc = pc;
    pc.onconnectionstatechange = manualConnState(pc);
    session.manualChan = pc.createDataChannel("link", { ordered: true });
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await manualGather(pc);
    if (net !== session || session.pc !== pc) return; // torn down while gathering
    const enc = SDPCodec.encode(pc.localDescription);
    if (!enc) throw new Error("couldn't encode the offer");
    session.manualCode = enc;
    if (manualOut) manualOut.value = enc;
    // What the code carries decides where it can pair: srflx = internet-capable
    // (NAT permitting), mDNS-host only = this LAN only. Logged so a cross-
    // network "stuck at Connecting…" is diagnosable from the device.
    const kinds = SDPCodec.fields(pc.localDescription.sdp).candidates.map((c) => {
      const [type, addr] = c.split("|");
      return type + (addr.includes(":") ? "/v6" : addr.endsWith(".local") ? "/mdns" : "/v4");
    });
    log("netplay: manual code candidates: " + (kinds.join(" ") || "none"));
    if (!kinds.some((k) => k.startsWith("srflx"))) {
      log("netplay: manual code has no public address — it can only pair on this network", "warn");
    }
  } catch (e) {
    if (net === session) {
      manualSetStatus("Couldn't prepare a code: " + (e.message || e), true);
    }
  }
};

// Switch the modal from the shared-code view to the manual exchange. Two ways
// in: openNetConnect() jumps here straight away when the last liveness probe
// saw the server down, and the connect flow lands here when a live shared-code
// attempt finds the server unreachable (outright error, silent for ~2s, or
// gone mid-wait and still dead after the redial budget) —
// `attemptFailed` distinguishes the latter so the player is told their attempt
// failed rather than the view just silently changing shape. Cancels the
// in-progress server/local attempts (this is a distinct rendezvous) but keeps
// the session.
const manualEnter = (attemptFailed) => {
  if (!netModalOpen() || !net) return;
  if (netManualView && !netManualView.hidden) return; // already trading codes
  if (!navigator.onLine) {
    // No network interface at all — trading codes can't help; WebRTC has
    // nothing to connect over either.
    netSetStatus("No network connection — join the same Wi-Fi as your friend and retry", true);
    return;
  }
  clearTimeout(manualFallbackTimer);
  clearTimeout(net.redialTimer);
  clearTimeout(net.rtcDeadline);
  if (attemptFailed) {
    log("netplay: server attempt failed — switching to the manual code exchange", "warn");
  }
  // Drop any in-progress server attempt WITHOUT tripping its teardown: detach
  // the socket handlers first, else ws.onclose fires netFail (no alt path yet)
  // and destroys the session we're keeping for the manual rendezvous.
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

// Return from the manual exchange to the shared-code view (the footer link).
// The prepared offer is abandoned — codes are cheap to regenerate — and a
// fresh pending session re-arms so Connect works immediately.
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

// Restore the shared-code view (called from modal open / close / shutdown).
const manualReset = () => {
  if (netManualView) netManualView.hidden = true;
  if (netConnectView) netConnectView.hidden = false;
  if (manualOut) manualOut.value = "";
  if (manualIn) { manualIn.value = ""; manualIn.readOnly = false; }
  if (manualConfirm) manualConfirm.disabled = true;
  manualSetStatus("");
};

// Confirm: interpret the friend's code as the answer to our offer (see the
// section comment — both sides do this; the code-string comparison assigns the
// complementary DTLS roles and the host/unit-0 seat).
const manualConfirmGo = async () => {
  const session = net;
  if (!session?.pc || !session.manualCode) return;
  const friendCode = (manualIn?.value || "").trim().replace(/\s+/g, "");
  if (!friendCode) return;
  if (friendCode === session.manualCode) {
    manualSetStatus("That's your own code — paste your friend's", true);
    return;
  }
  const isHost = session.manualCode > friendCode;
  // Our peer takes the opposite DTLS role: if we're the server ("host"), their
  // synthesized answer must say active, and vice versa.
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
  // A remote list with no routable candidate (mDNS-only, or a stale NAT
  // mapping) leaves ICE in checking forever without ever reaching 'failed' —
  // "Connecting…" for eternity. Bound it like the server path's pairing
  // deadline, with the same fresh-codes recovery as a hard ICE failure.
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
// Confirm goes live only once there's something in the friend's-code box.
manualIn?.addEventListener("input", () => {
  manualConfirm.disabled = manualIn.readOnly || manualIn.value.trim().length === 0;
});
manualCopyBtn?.addEventListener("click", async () => {
  const code = manualOut?.value;
  if (!code) return;
  try {
    await navigator.clipboard.writeText(code);
  } catch {
    // Clipboard API needs a secure context (and can be denied); fall back to a
    // selectable temp element + execCommand. The code box itself is disabled,
    // so it can't be selected directly.
    const ta = document.createElement("textarea");
    ta.value = code;
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); } catch {}
    ta.remove();
  }
  showToast("Code copied");
});

// Native share sheet for the code — the natural mobile flow, where the code
// is headed to a messenger anyway. Revealed only where the Web Share API
// exists and the primary pointer is a finger; desktop keeps just Copy.
const manualShareBtn = /** @type {HTMLButtonElement} */ (document.getElementById("net-manual-share"));
if (manualShareBtn && navigator.share && matchMedia("(pointer: coarse)").matches) {
  manualShareBtn.hidden = false;
}
manualShareBtn?.addEventListener("click", async () => {
  const code = manualOut?.value;
  if (!code) return;
  try {
    // The bare code, no prose: whatever the friend pastes back must decode.
    await navigator.share({ text: code });
  } catch {
    // A dismissed share sheet rejects with AbortError; nothing to report.
  }
});
// Keep the emulator's key handlers from swallowing input; Enter confirms.
// Escape must still dismiss the modal: stopping propagation here means the
// document-level Escape handler below never sees it while this field has
// focus (which it always does — the modal focuses it on open).
manualIn && ["keydown", "keypress", "keyup"].forEach((t) =>
  manualIn.addEventListener(t, (/** @type {KeyboardEvent} */ e) => {
    if (t === "keydown" && e.key === "Enter" && !manualConfirm.disabled) manualConfirmGo();
    if (t === "keydown" && e.key === "Escape") netDismissModal();
    e.stopPropagation();
  })
);

// ---------------- input-rollback online play ----------------
// Wire protocol over the DataChannel (binary frames, first byte = kind):
//   0 hello        : [0][epoch u32][romHash u32]  (host's epoch is the shared clock)
//   1 input        : [1][frame i32][bits u16]      (this peer's buttons for a frame)
//   2 state-begin  : [2][len u32]                  (full save-state, chunked)
//   3 state-chunk  : [3][bytes…]
//   4 rom-begin    : [4][len u32]                  (this peer's ROM, chunked)
//   5 rom-chunk    : [5][bytes…]
//   6 ready        : [6]                           (cores built + states loaded)
//   7 speed        : [7][on u8]                     (2x fast-forward toggle — both cores)
// Both peers run BOTH cores; core 0 = host's game, core 1 = guest's. To CONTINUE
// from exactly where each player was (no reboot), we exchange each running
// core's full SAVE-STATE and load it into the matching core, then network only
// per-frame inputs (prediction + rollback in the wasm RollbackSession). The
// local game freezes during the brief sync so it doesn't drift past its snapshot.
//
// CROSS-GAME trades (Emerald↔Ruby): each peer only owns ITS game's ROM, but both
// peers must simulate BOTH cores identically. So when the hello hashes differ we
// also stream each peer's ROM to the other (rom-begin/chunk) — after which both
// peers hold the same {host ROM, guest ROM} pair and boot core 0/1 from it. The
// large transfer uses DataChannel backpressure; a final "ready" barrier keeps
// either peer from ticking (and shipping inputs) until BOTH have booted.

const RB_HELLO = 0, RB_INPUT = 1, RB_STATE_BEGIN = 2, RB_STATE_CHUNK = 3;
const RB_ROM_BEGIN = 4, RB_ROM_CHUNK = 5, RB_READY = 6, RB_SPEED = 7;
const RB_CHUNK = 16384; // DataChannel-safe chunk size for state + ROM frames
// Keep at most this much queued in the DataChannel send buffer while streaming a
// ROM; pause until it drains below. Well under Chrome's ~16 MB hard cap (a send()
// over which throws → a dropped chunk → a corrupt ROM), so we never hit it.
const RB_SEND_HIGH_WATER = 4 * 1024 * 1024;
const RB_ROM_MAX = 48 * 1024 * 1024; // sanity cap on an announced ROM length
// FS extension for the session's ROMs (.gba / .gb / .gbc); set at rbConnect and
// used for the FS names so the wasm's rollback_init dispatches to the right core.
let rbExt = ".gba";

const rbHash = (bytes) => {
  // FNV-1a over the first 1 MB — enough to tell ROM versions apart cheaply.
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
  // ?linkdelay=NN simulates internet latency on the input stream, for testing.
  if (NET_LINK_DELAY > 0) setTimeout(() => rbSend(buf), NET_LINK_DELAY);
  else rbSend(buf);
};

// Tell the peer to match our 2x fast-forward. Both cores must run at the same
// rate: a one-sided 2x would race its frame head past the rollback prediction
// window and just stall waiting for the (still-1x) peer's inputs. So the toggle
// drives BOTH — whoever taps 2x fast-forwards the pair together.
const rbSendSpeed = (on) => {
  const buf = new ArrayBuffer(2);
  const v = new DataView(buf);
  v.setUint8(0, RB_SPEED);
  v.setUint8(1, on ? 1 : 0);
  rbSend(buf);
};

// Snapshot the running single core (same bytes as a .state file).
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

// Resolve once the DataChannel's send buffer has drained to/under its low-water
// threshold. Re-checks synchronously in case it already drained before we
// listened (the bufferedamountlow event only fires on a fresh crossing).
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

// Stream a whole ROM to the peer with backpressure so the send buffer never
// overflows (a silently-dropped chunk would corrupt the ROM). `onProgress(sent)`
// tracks bytes acknowledged into the buffer. Returns false if the channel dies.
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

// Combined transfer progress across both directions (upload our ROM + download
// theirs); both must finish before either peer boots, so show the joint percent.
const rbShowXferProgress = () => {
  const rb = net?.rb;
  if (!rb || !rb.needRom) return;
  // Estimate the peer's ROM at our own size until its rom-begin lands (gen-3
  // ROMs match), so the joint bar doesn't lurch when the real length arrives.
  const total = (rb.romLen || 0) + (rb.remoteRomLen || rb.romLen || 0);
  if (total <= 0) return;
  const done = (rb.romSent || 0) + (rb.remoteRomGot || 0);
  const pct = Math.min(100, Math.floor((done / total) * 100));
  netSetStatus("Transferring games… " + pct + "%");
};

// Kick off sending our ROM to the peer once (both peers do this on hello
// mismatch), updating progress as it drains.
const rbSendOurRom = () => {
  const rb = net?.rb;
  if (!rb || rb.romSendStarted) return;
  rb.romSendStarted = true;
  rbSendRom(rb.romBytes, (sent) => {
    rb.romSent = sent;
    rbShowXferProgress();
  }).catch(() => {});
};

// Capture the running game's state + ROM, freeze it, and start the handshake.
const rbConnect = async () => {
  const oext = extOf(currentOriginalName || "");
  if (oext !== ".gba" && oext !== ".gb" && oext !== ".gbc")
    throw new Error("link cable needs a GB/GBC/GBA game");
  // Both peers must be the same system; the FS ROM extension drives the wasm's
  // GB-vs-GBA dispatch in rollback_init. Also flags the GB canvas dimensions.
  rbExt = oext === ".gba" ? ".gba" : oext;
  linkIsGb = rbExt !== ".gba";
  const localState = rbCaptureState();
  // Freeze the local game AT the snapshot so it doesn't run past it during the
  // exchange (no overlay — the modal shows the sync status). enterRollbackMode
  // unfreezes into the session, so the transition is seamless.
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
    // Cross-game ROM transfer (set when the peer's hello hash differs).
    needRom: false,
    remoteRomHash: 0,
    remoteRomLen: 0,
    remoteRom: null, // assembled peer ROM (or reuse of ours when same-version)
    romBuf: null,
    romGot: 0,
    romSent: 0,
    remoteRomGot: 0,
    romSendStarted: false,
    // Readiness barrier: neither peer ticks/ships inputs until both have booted.
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
    // Peer toggled 2x — match it (without echoing back) so both cores run at
    // the same rate and stay in rollback sync.
    window.applyRemoteSpeed2x?.(v.getUint8(1) === 1);
    return;
  }
  if (kind === RB_HELLO) {
    rb.remoteRomHash = v.getUint32(5);
    if (!net.isHost) rb.epoch = v.getUint32(1); // guest adopts the host's clock
    rb.remoteHello = true;
    // Different game versions → each peer streams its ROM to the other so both
    // can boot the same {host, guest} pair. Same version → keep the fast path.
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
      // Integrity: length + version hash must match what the hello promised
      // (reliable ordered channel, so this only guards a genuine mismatch).
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

// Load a full save-state into a rollback core, so it continues where the player
// was rather than rebooting.
const rbLoadState = (player, bytes) => {
  const p = Module._malloc(bytes.length);
  if (!p) return false;
  new Uint8Array(Module.memory.buffer, p, bytes.length).set(bytes);
  const ok = Module._rollback_load_state(player, p, bytes.length);
  Module._free(p);
  return ok === 1;
};

// Once we have the peer's hello (→ shared epoch), full state, and — for a
// cross-game trade — its ROM, boot both cores, load each player's snapshot, and
// announce readiness. The session doesn't actually START until both peers are
// ready (rbStartIfReady), so no inputs are shipped before either has booted.
const rbTryInit = () => {
  const rb = net.rb;
  if (!rb || rb.inited || !rb.remoteHello || !rb.remoteState) return;
  if (rb.needRom && !rb.remoteRom) return; // still receiving the peer's ROM
  rb.inited = true;
  // core 0 = host's game, core 1 = guest's — both peers write the SAME pair.
  // Same version: our bytes drive both. Cross version: our ROM fills our own
  // slot, the peer's ROM the other, matching the host/guest state assignment.
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
  // Core 0 = host's snapshot, core 1 = guest's; both peers load the same pair,
  // so each game resumes from exactly where its player was.
  const hostState = net.isHost ? rb.localState : rb.remoteState;
  const guestState = net.isHost ? rb.remoteState : rb.localState;
  if (!rbLoadState(0, hostState) || !rbLoadState(1, guestState)) {
    netFail("Couldn't sync game state — are you both on the same emulator build?");
    return;
  }
  // Booted. Tell the peer, and start once they've told us the same.
  rb.localReady = true;
  rbSend(new Uint8Array([RB_READY]));
  netSetStatus(rb.needRom ? "Ready — waiting for your friend…" : "");
  rbStartIfReady();
};

// Both peers have booted their cores → unfreeze into the live session. Gated so
// neither peer ticks (or ships an input the other would drop) before both boot.
const rbStartIfReady = () => {
  const rb = net?.rb;
  if (!rb || !rb.inited || !rb.localReady || !rb.remoteReady || net.started) return;
  net.started = true;
  netFrozeGame = false; // the session unfreezes below; not ours to thaw anymore
  netMode = false; // rollback drives its own RAF branch, not the SIO netStep path
  closeNetModal();
  window.rbSendInput = rbSendInput;
  window.rbSendSpeed = rbSendSpeed;
  window.enterRollbackMode(); // unfreezes into the session
  showToast(net.isHost ? "Player 2 connected — full speed" : "Connected — full speed");
  // The ROMs + states now live in wasm/MEMFS; drop the JS-side copies (up to
  // ~32 MB for a cross-game pair) so they don't linger for the whole session.
  rb.romBytes = null;
  rb.remoteRom = null;
  rb.romBuf = null;
  rb.localState = null;
  rb.remoteState = null;
  rb.stateBuf = null;
};

// Leave the session but keep playing: promote our core to the single-player
// core (continues from the post-trade moment, no reboot), repoint currentRomName
// at it so battery saves persist to our own slot, and persist now.
const rbTeardown = async () => {
  if (!net?.rb?.inited) return;
  window.rbSendInput = null;
  window.rbSendSpeed = null;
  const kept =
    Module._rollback_exit_to_single && Module._rollback_exit_to_single() === 1;
  if (kept) {
    // The running solo core now lives at rbrom<player><ext> / .sav; keep the
    // original display name so its save persists under the real game's slot.
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

// ---------------- wasm byte shuttle ----------------

const netReceive = (bytes) => {
  if (!net) return;
  if (!net.started) {
    // The peer's channel can open (and its HELLO arrive) before our own ROM
    // setup finishes; hold the bytes until the core exists.
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
  // This message may carry the REPLY a stalled transfer is parked on.
  // Advance the core right now (driveNet resolves the stall at network
  // speed) and push whatever we produced back out immediately — without
  // this, every link round-trip would cost a whole 16 ms RAF interval.
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

// ---------------- session lifecycle ----------------

// Connect: normalize the shared code and hand it to the signaling server. Both
// peers send the same code; the server pairs them and hands back a role.
netJoinGo.addEventListener("click", async () => {
  // Once connecting, the same button reads "Cancel" and tears the attempt down.
  if (net?.ws || net?.bc) {
    netDismissModal();
    return;
  }
  if (!net) net = makeSession(netAttach); // re-arm if a prior attempt tore down
  const session = net;
  const code = netCodeInput.value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (code.length < 3) {
    netSetStatus("Pick a code of at least 3 letters/numbers", true);
    return;
  }
  session.code = code; // kept on the session so a redial can re-rendezvous
  netSetConnecting(true);
  netSetStatus("Connecting…");
  armManualFallback(session);
  // Two paths race. Same-browser tabs pair instantly over a BroadcastChannel with
  // no server and no WebRTC; everyone else goes through the signaling server. The
  // first to connect wins (wireChannel tears the loser down). Running both means a
  // second browser tab links even with the server down, while a phone across the
  // network still connects — no Host/Join choice, just a shared code either way.
  startLocalLink(code);
  if (await sigConnect()) {
    // Paired locally (net.dc set) or cancelled (net swapped) while dialing?
    if (net !== session || net.dc) return;
    sigSend({ t: "rendezvous", code });
  } else if (net === session && !net.dc && !net.rtcConnected) {
    // The server was unreachable outright — switch to the fallback immediately.
    clearTimeout(manualFallbackTimer);
    manualEnter(true);
  }
});

// Keep the emulator from swallowing what's typed here. Emscripten's SDL layer
// registers key handlers on `window` (bubble phase) and calls preventDefault()
// on keypress, which otherwise blocks text entry into every input on the page.
// Stopping propagation at the field keeps those keystrokes from ever reaching
// it. keydown also submits on Enter.
["keydown", "keypress", "keyup"].forEach((type) =>
  netCodeInput.addEventListener(type, (/** @type {KeyboardEvent} */ e) => {
    if (type === "keydown" && e.key === "Enter") netJoinGo.click();
    // Same Escape carve-out as the manual-code input: propagation stops here,
    // so dismiss directly instead of relying on the document handler.
    if (type === "keydown" && e.key === "Escape") netDismissModal();
    e.stopPropagation();
  })
);

// The DataChannel is open: bring the local core online. Two paths —
// attach binds the network cable to the already-running game with no
// reboot (from the in-game badge); the fresh path boots the ROM into a
// linked session from the player's OWN battery save (from the tiles).
// Trading from your real save is the point either way.
const launchNetRom = async () => {
  setFastForward(false);
  setSpeed2x(false);
  setRewindHeld(false);
  netFrozeGame = false; // the session takes over the game clock now
  paused = false;
  document.body.classList.remove("paused");
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";

  if (Module._netlink_set_speculative) {
    Module._netlink_set_speculative(NET_SPECULATIVE ? 1 : 0);
  }

  if (net.attach) {
    // The game is already running its own save; just plug the cable in.
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

// One emulated frame attempt; called from the RAF loop in index.js.
// Returns the netlink_tick status (1 = frame ran).
const netStep = () => {
  if (!netMode || !net?.started) return 4;
  const st = Module._netlink_tick();
  netFlush();
  return st;
};

// Post-tick housekeeping: handshake completion (incl. the cross-version ROM
// confirm), the stall badge, peer-departure and error surfacing.
const netAfterTick = (st) => {
  if (!netMode || !net) return;
  if (!net.helloDone && (st === 1 || st === 2)) {
    net.helloDone = true;
    closeNetModal();
    if (Module._netlink_crc_mismatch()) {
      // Different ROM bytes on the two sides. Cross-version pairs
      // (Ruby<->Sapphire) are fully link-compatible and half the point of
      // Pokémon trading, so this is a confirm, not a rejection.
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
  // "Waiting for peer": shown only for sustained stalls so routine
  // per-transfer waits don't flicker the badge.
  if (st === 2) {
    const now = performance.now();
    if (!net.stallSince) net.stallSince = now;
    netStallBadge.hidden = now - net.stallSince < 300;
  } else {
    net.stallSince = 0;
    netStallBadge.hidden = true;
  }
};

// The peer is gone (BYE, channel closed, ICE failure) or the stream broke:
// tell the player and keep the local game running — the game itself sees a
// yanked link cable.
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

// Tear the session down. The local game (if one started) keeps running
// unlinked: index.js's normal single-core RAF branch takes over as soon as
// netMode is false.
const netShutdown = async (opts) => {
  netStallBadge.hidden = true;
  clearTimeout(manualFallbackTimer);
  const s = net;
  net = null;
  if (s) {
    clearTimeout(s.redialTimer);
    clearTimeout(s.rtcDeadline);
  }
  // Cancelling the connect modal (or any teardown) thaws the game we froze when
  // the modal opened — even if the handshake never got as far as creating rb.
  if (netFrozeGame) {
    netFrozeGame = false;
    paused = false;
    document.body.classList.remove("paused");
    pauseButton.classList.remove("paused", "active");
    pauseButton.title = "Pause";
  }
  if (s?.rb) {
    // We froze the local game during the handshake; always unfreeze on teardown
    // (whether the session ran or the handshake failed).
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
          // Deliver the BYE so the peer exits cleanly rather than timing out
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
      s.bc?.close(); // discovery-phase channel (before it became s.dc)
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

// Modal dismissal = abandoning the pending session (or nothing once the
// game is already running — then the modal is long closed anyway).
const netDismissModal = () => {
  if (net && !net.started) netShutdown();
  else closeNetModal();
};

// The prominent in-toolbar disconnect button (shown only in rollback mode).
document.getElementById("rb-disconnect").addEventListener("click", () => {
  if (net?.started || net?.rb?.inited) {
    netShutdown();
    showToast("Disconnected");
  }
});

// Footer links: switch between the shared-code and manual-exchange views.
// Entering the manual exchange cancels any in-progress server attempt
// (manualEnter's normal semantics); going back re-arms a fresh session.
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
