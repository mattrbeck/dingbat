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
// STUN-only for v1: most home NATs connect; symmetric NAT/strict CGNAT
// pairs fail with a clear error (a TURN relay is a future option).
const NET_ICE_SERVERS = [{ urls: "stun:stun.l.google.com:19302" }];
const NET_BUF_CAP = 16384; // wasm-side shuttle buffer (frames are tiny)

var netMode = false; // read by the index.js RAF loop, like linkMode
let net = null;      // active session (from modal open to shutdown)

const netModal = document.getElementById("net-modal");
const netTitle = document.getElementById("net-title");
const netHostView = document.getElementById("net-host-view");
const netJoinView = document.getElementById("net-join-view");
const netCodeDiv = document.getElementById("net-code");
const netStatusDiv = document.getElementById("net-status");
const netCodeInput = document.getElementById("net-code-input");
const netJoinGo = document.getElementById("net-join-go");
const netStallBadge = document.getElementById("net-stall");

const netSetStatus = (msg, isError) => {
  netStatusDiv.textContent = msg;
  netStatusDiv.classList.toggle("net-error", !!isError);
};

// Group "KJ4Q7N" as "KJ4-Q7N" for reading aloud; input accepts either.
const netFormatCode = (code) => code.slice(0, 3) + "-" + code.slice(3);

const openNetModal = (isHost) => {
  netTitle.textContent = isHost ? "Host online game" : "Join online game";
  netHostView.hidden = !isHost;
  netJoinView.hidden = isHost;
  netCodeDiv.textContent = "";
  netCodeInput.value = "";
  netJoinGo.disabled = false;
  netSetStatus("");
  netModal.classList.add("open");
  trapFocus(netModal);
};

const closeNetModal = () => {
  netModal.classList.remove("open");
  releaseFocus(netModal);
};

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
    ws.onopen = () => resolve(true);
    ws.onerror = () => {
      netFail("Couldn't reach the signaling server at " + NET_SIGNAL_URL);
      resolve(false);
    };
    ws.onclose = () => {
      // Normal after WebRTC connects (we close it); anything earlier is a
      // failure unless one was already reported.
      if (net && !net.rtcConnected && !net.started) {
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
      case "room":
        netCodeDiv.textContent = netFormatCode(msg.code);
        netSetStatus("Waiting for your friend to join…");
        break;
      case "paired":
        netSetStatus("Peer found — connecting…");
        await startRtc(msg.role === "host");
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
        netFail(
          msg.msg === "no such room"
            ? "No room with that code — check it and try again"
            : "Server: " + msg.msg
        );
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
  net.dc = dc;
  dc.binaryType = "arraybuffer";
  dc.onopen = () => {
    net.rtcConnected = true;
    // Peer-to-peer is up: the signaling server's job is done.
    try {
      net.ws?.close();
    } catch {}
    net.ws = null;
    netSetStatus("Connected — linking…");
    launchNetRom().catch((e) => netFail("Couldn't start the game: " + e.message));
  };
  dc.onmessage = (e) => netReceive(new Uint8Array(e.data));
  dc.onclose = () => {
    if (net && net.started) netPeerGone("Peer disconnected");
  };
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
  // A REPLY the peer is stalled on should go out now, not next frame
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

const netHost = async (rom) => {
  await startNet(rom, true);
  if (!net) return;
  netSetStatus("Contacting server…");
  if (await sigConnect()) sigSend({ t: "create" });
};

const netJoin = async (rom) => {
  await startNet(rom, false);
  // Wait for the user to type the code; netJoinGo's handler continues.
};

const startNet = async (rom, isHost) => {
  if (netMode || net) await netShutdown();
  if (linkMode) await exitLinkMode();
  net = {
    rom,
    isHost,
    ws: null,
    pc: null,
    dc: null,
    ptr: 0,
    started: false,       // wasm core initialized, game ticking
    rtcConnected: false,  // DataChannel open
    helloDone: false,     // wire handshake validated (first successful tick)
    rxQueue: [],
    stallSince: 0,
  };
  openNetModal(isHost);
};

netJoinGo.addEventListener("click", async () => {
  if (!net || net.ws) return;
  const code = netCodeInput.value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (code.length !== 6) {
    netSetStatus("Room codes are 6 letters/digits", true);
    return;
  }
  netJoinGo.disabled = true;
  netSetStatus("Contacting server…");
  if (await sigConnect()) sigSend({ t: "join", code });
});

netCodeInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") netJoinGo.click();
  e.stopPropagation(); // keep bound game keys usable in the field
});

// Start the local core against the open DataChannel. Mirrors loadRom's
// bookkeeping: the ROM runs from the standard single-core FS path with the
// player's OWN battery save — trading from your real save is the point.
const launchNetRom = async () => {
  const rom = net.rom;
  if (currentRomName && currentOriginalName) {
    await persistSave(currentRomName, currentOriginalName);
  }
  const romFile = "rom" + extOf(rom.name);
  writeToFS(romFile, rom.data);
  currentRomName = romFile;
  currentOriginalName = rom.name;
  await restoreSave(romFile, rom.name);
  setFastForward(false);
  setSpeed2x(false);
  setRewindHeld(false);
  paused = false;
  document.body.classList.remove("paused");
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  const ok = Module.ccall(
    "netlink_init",
    "number",
    ["string", "number", "number"],
    [romFile, net.isHost ? 1 : 0, 1] // relaxed CRC: games negotiate compatibility
  );
  if (ok !== 1) throw new Error("core init failed");
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
document.getElementById("net-close").addEventListener("click", () => {
  if (net && !net.started) netShutdown();
  else closeNetModal();
});
netModal.addEventListener("click", (e) => {
  if (e.target === netModal) {
    if (net && !net.started) netShutdown();
    else closeNetModal();
  }
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && netModal.classList.contains("open")) {
    if (net && !net.started) netShutdown();
    else closeNetModal();
  }
});
