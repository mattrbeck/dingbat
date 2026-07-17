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
const NET_PARAMS = new URLSearchParams(location.search);
const NET_SIGNAL_URL =
  NET_PARAMS.get("signal") ||
  (location.protocol === "https:"
    ? "wss://" + location.host + "/signal"
    : "ws://" + location.hostname + ":8790");
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
const netCodeInput = document.getElementById("net-code-input");
const netJoinGo = document.getElementById("net-join-go");
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
  dc: null,
  ptr: 0,
  started: false,       // wasm core linked, game ticking
  rtcConnected: false,  // DataChannel open
  helloDone: false,     // wire handshake validated (first successful tick)
  rxQueue: [],
  stallSince: 0,
});
let netAttach = true;   // attach mode of the current/last pending session (for retry)

const closeNetModal = () => {
  netModal.classList.remove("open");
  netSetConnecting(false);
  releaseFocus(netModal);
};

// Open the single shared-code entry modal and stage a pending session. Both
// players type the SAME code; the signaling server makes whoever arrives first
// the host. No Host/Join choice — just like plugging in a link cable.
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
  netModal.classList.add("open");
  trapFocus(netModal);
  // Drop the cursor straight in the field so the code can be typed immediately.
  setTimeout(() => netCodeInput.focus(), 0);
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
    ws.onopen = () => resolve(true);
    ws.onerror = () => {
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
      // Normal after WebRTC connects (we close it); anything earlier is a
      // failure unless the local path is still live or already carried us.
      if (net && !hasAltPath()) {
        netFail("Lost the signaling connection");
      }
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

const onSigMessage = async (msg) => {
  if (!net) return;
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
  const pc = new RTCPeerConnection({ iceServers: NET_ICE_SERVERS });
  net.pc = pc;
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
  netSetConnecting(true);
  netSetStatus("Connecting…");
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
  }
});

// Keep the emulator from swallowing what's typed here. Emscripten's SDL layer
// registers key handlers on `window` (bubble phase) and calls preventDefault()
// on keypress, which otherwise blocks text entry into every input on the page.
// Stopping propagation at the field keeps those keystrokes from ever reaching
// it. keydown also submits on Enter.
["keydown", "keypress", "keyup"].forEach((type) =>
  netCodeInput.addEventListener(type, (e) => {
    if (type === "keydown" && e.key === "Enter") netJoinGo.click();
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
  const s = net;
  net = null;
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

document.getElementById("net-close").addEventListener("click", netDismissModal);
netModal.addEventListener("click", (e) => {
  if (e.target === netModal) netDismissModal();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && netModalOpen()) netDismissModal();
});
