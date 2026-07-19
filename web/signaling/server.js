// Signaling server for dingbat online link play (multiplayer phase 3b).
//
// Tiny room-code rendezvous: a host creates a room and gets a short code;
// a guest joins with the code; the server then relays opaque messages (SDP
// offer/answer + ICE candidates) between exactly those two sockets until
// both have a WebRTC DataChannel and hang up. Game traffic NEVER touches
// this server, and it holds no state beyond live rooms.
//
// Zero dependencies (the WebSocket handshake + framing are implemented
// inline on node's http server) so `node server.js` works anywhere —
// development, CI, or a tiny VM. Options:
//
//   node server.js [port]        # default 8790
//
// Wire protocol (JSON text messages):
//   client -> server: {"t":"rendezvous","code":"PIKA"} both peers send the same
//                                                    code they agreed on
//   server -> client: {"t":"waiting"}                first arrival with a code;
//                                                    hold for the peer
//                     {"t":"paired"}                 both present (whoever
//                                                    arrived first gets
//                                                    role:"host", the other
//                                                    role:"guest"); start
//                                                    WebRTC now
//                     {"t":"peer-closed"}            the other side is gone
//                     {"t":"error","msg":"..."}      then the socket closes
//   after "paired", ONLY {"t":"sdp",...} and {"t":"ice",...} envelopes are
//   relayed (their payloads are never inspected). Anything else — any other
//   type, non-JSON, or exceeding the per-room relay byte budget — closes the
//   room: this server connects peers and is structurally incapable of
//   carrying game/save/ROM bytes.
//
// Like a physical link cable, players don't designate a host: both type the
// same code and the FIRST to reach the server hosts (becomes the WebRTC
// offerer / SIO multi-mode parent). A code is a rendezvous point for exactly
// two peers; a third using the same code is rejected. Codes are normalized to
// uppercase alphanumerics and an unclaimed room expires after 10 minutes.
//
// Abuse hardening (all mirrored in server.nim — keep the twins in sync):
//   - Per-IP limits (rendezvous rate, concurrent sockets, waiting rooms) are
//     keyed on the direct peer address, EXCEPT when the direct peer is
//     localhost (the reverse-proxy case): then the LAST entry of
//     X-Forwarded-For — the one appended by our trusted local proxy — is used.
//     Earlier entries are client-supplied and forgeable, so they are ignored.
//   - SIGNAL_ALLOWED_ORIGINS (comma-separated) rejects WebSocket upgrades whose
//     Origin header is not listed. Unset = allow all (LAN/dev). A MISSING
//     Origin is always allowed: non-browser clients don't send one and the
//     header is trivially forgeable outside a browser anyway — this check is
//     CSWSH protection for browsers, nothing more.
//   - The health line is static; SIGNAL_STATS=1 restores the live room count
//     (used by the test harness; don't set it on a public deployment).

'use strict';

const http = require('http');
const crypto = require('crypto');

const PORT = parseInt(process.argv[2], 10) || parseInt(process.env.PORT, 10) || 8790;
const ROOM_TTL_MS = 10 * 60 * 1000;
const MAX_MSG_BYTES = 64 * 1024; // SDP + ICE are a few KB; anything bigger is abuse
const MIN_CODE_LEN = 3; // user-chosen; short enough to say aloud, long enough to not collide by accident

// Post-pair relay policy. The server's ONLY job after pairing is to carry the
// WebRTC handshake; it must be structurally incapable of relaying game, save,
// or ROM bytes (those belong on the peers' DataChannel). Two layers:
//   1. Envelope allowlist: only {"t":"sdp"} / {"t":"ice"} messages are relayed.
//      netplay.js sends nothing else post-pair ("rendezvous" is pre-pair
//      only). Payloads are never inspected — the gate is the envelope type,
//      so the server stays oblivious to what SDP/ICE mean.
//   2. A cumulative per-room relayed-byte budget (both directions, lifetime).
//      A real handshake is tiny: one SDP offer + answer (a few KB each) plus
//      up to dozens of trickled ICE candidates (~200 B each) — well under
//      32 KB in practice. 256 KB is ~10x headroom for pathological SDP yet
//      makes sustained data tunneling through allowlisted envelopes useless.
// Violating either closes the room in the standard error style (error to the
// sender, peer-closed to the peer): a peer sending non-signaling traffic is
// either a bug or abuse, never something to relay.
const RELAY_TYPES = new Set(['sdp', 'ice']);
const MAX_RELAY_BYTES_PER_ROOM = 256 * 1024;

// Abuse / resource caps. On a tiny VPS an unbounded server is a liability:
// a peer that opens sockets and never speaks, or spams unique codes, could
// pin unbounded RAM. Legitimate use is a handful of concurrent pairs, so these
// ceilings are far above real demand yet bound the worst case hard.
const MAX_CONNS = 2000;              // total live sockets; reject the upgrade past this
const MAX_ROOMS = 1000;              // total live rooms; reject new-room rendezvous past this
const HANDSHAKE_TIMEOUT_MS = 30 * 1000; // a socket that never sends `rendezvous` is dropped
// Keepalive: WebRTC normally makes both peers close their signaling socket, so
// paired rooms are short-lived. But a peer that vanishes without a TCP FIN
// (laptop asleep, NAT drop) would otherwise pin its socket + room forever —
// paired rooms carry no TTL. A periodic ping + silence deadline reaps them.
const PING_INTERVAL_MS = 30 * 1000;
const IDLE_TIMEOUT_MS = 90 * 1000;   // no frame (incl. pong) for this long -> dead, close

// Per-IP quotas: one address must not be able to sweep the code space (codes
// are user-chosen and short, so pairing is first-come) or eat the global caps.
const MAX_CONNS_PER_IP = 8;          // concurrent live sockets per client IP
const MAX_WAITING_PER_IP = 4;        // unclaimed waiting rooms held per client IP
const RENDEZVOUS_WINDOW_MS = 60 * 1000; // rendezvous rate-limit window (fixed window)
const MAX_RENDEZVOUS_PER_WINDOW = 10;   // rendezvous attempts per IP per window

const STATS_ENABLED = process.env.SIGNAL_STATS === '1';
const ALLOWED_ORIGINS = new Set(
  (process.env.SIGNAL_ALLOWED_ORIGINS || '')
    .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean));

// ---------------- per-IP bookkeeping ----------------

const ipConns = new Map();   // ip -> live post-handshake sockets
const ipWaiting = new Map(); // ip -> unclaimed waiting rooms hosted
const rzWindows = new Map(); // ip -> { start, count } rendezvous attempts

const bumpIp = (m, ip) => m.set(ip, (m.get(ip) || 0) + 1);
const dropIp = (m, ip) => {
  const n = (m.get(ip) || 0) - 1;
  if (n <= 0) m.delete(ip); else m.set(ip, n);
};

const isLocalPeer = (ip) =>
  ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';

// The address per-IP limits key on. Behind the production reverse proxy every
// direct peer is localhost, so honor X-Forwarded-For then — but ONLY then, and
// only its LAST entry (the one appended by our trusted proxy; earlier entries
// are client-supplied and would let an attacker dodge the limits).
function effectiveIp(direct, xff) {
  if (!direct) return '?';
  if (isLocalPeer(direct) && xff) {
    const last = String(xff).split(',').pop().trim();
    if (last) return last;
  }
  return direct;
}

// Fold a user-typed code to the canonical form both peers must match on.
const normalizeCode = (raw) =>
  String(raw || '').toUpperCase().replace(/[^A-Z0-9]/g, '');

// ---------------- minimal WebSocket implementation ----------------

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// Every live socket, so the reaper can sweep for dead/half-open ones.
const conns = new Set();

/** Wrap an upgraded socket with frame encode/decode + callbacks. */
class WebSock {
  constructor(socket) {
    this.socket = socket;
    this.buf = Buffer.alloc(0);
    this.fragments = null; // in-progress fragmented message
    this.closed = false;
    this.lastRecv = Date.now(); // any inbound frame (incl. pong) proves liveness
    this.ip = '?';         // effective client IP (set right after the upgrade)
    this.ipCounted = false; // true once counted in ipConns
    this.onmessage = null; // (string) => void
    this.onclose = null;   // () => void
    conns.add(this);
    socket.on('data', (d) => this._ingest(d));
    const bye = () => this._dead();
    socket.on('close', bye);
    socket.on('error', bye);
    socket.on('end', bye);
  }

  _dead() {
    if (this.closed) return;
    this.closed = true;
    conns.delete(this);
    // Every disconnect path funnels through here exactly once (the guard
    // above), so this is the single place the per-IP socket count is released.
    if (this.ipCounted) {
      this.ipCounted = false;
      dropIp(ipConns, this.ip);
    }
    this.socket.destroy();
    if (this.onclose) this.onclose();
  }

  _ingest(data) {
    this.lastRecv = Date.now();
    this.buf = Buffer.concat([this.buf, data]);
    while (true) {
      const frame = this._parseFrame();
      if (!frame) return;
      const { fin, opcode, payload } = frame;
      if (opcode === 0x8) { // close
        this.close();
        return;
      } else if (opcode === 0x9) { // ping -> pong
        this._send(0xA, payload);
      } else if (opcode === 0xA) { // pong: ignore
      } else if (opcode === 0x1 || opcode === 0x2 || opcode === 0x0) {
        // text/binary/continuation; we only ever speak JSON text but
        // reassemble whatever arrives
        if (opcode !== 0x0) this.fragments = [];
        if (this.fragments === null) { this.close(); return; } // stray continuation
        this.fragments.push(payload);
        const total = this.fragments.reduce((n, p) => n + p.length, 0);
        if (total > MAX_MSG_BYTES) { this.close(); return; }
        if (fin) {
          const msg = Buffer.concat(this.fragments).toString('utf8');
          this.fragments = null;
          if (this.onmessage) this.onmessage(msg);
        }
      } else {
        this.close(); // unknown opcode
        return;
      }
      if (this.closed) return;
    }
  }

  _parseFrame() {
    const b = this.buf;
    if (b.length < 2) return null;
    const fin = (b[0] & 0x80) !== 0;
    const opcode = b[0] & 0x0F;
    const masked = (b[1] & 0x80) !== 0;
    let len = b[1] & 0x7F;
    let off = 2;
    if (len === 126) {
      if (b.length < off + 2) return null;
      len = b.readUInt16BE(off);
      off += 2;
    } else if (len === 127) {
      if (b.length < off + 8) return null;
      const big = b.readBigUInt64BE(off);
      if (big > BigInt(MAX_MSG_BYTES)) { this.close(); return null; }
      len = Number(big);
      off += 8;
    }
    if (len > MAX_MSG_BYTES) { this.close(); return null; }
    let mask = null;
    if (masked) {
      if (b.length < off + 4) return null;
      mask = b.subarray(off, off + 4);
      off += 4;
    }
    if (b.length < off + len) return null;
    const payload = Buffer.from(b.subarray(off, off + len));
    if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
    this.buf = b.subarray(off + len);
    return { fin, opcode, payload };
  }

  _send(opcode, payload) {
    if (this.closed) return;
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.from([0x80 | opcode, len]);
    } else if (len < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | opcode;
      header[1] = 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | opcode;
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(len), 2);
    }
    this.socket.write(Buffer.concat([header, payload]));
  }

  sendText(s) {
    this._send(0x1, Buffer.from(s, 'utf8'));
  }

  ping() {
    this._send(0x9, Buffer.alloc(0)); // browsers auto-pong; a pong bumps lastRecv
  }

  close() {
    if (this.closed) return;
    this._send(0x8, Buffer.alloc(0));
    this._dead();
  }
}

// ---------------- rooms ----------------

const rooms = new Map(); // code -> { host: WebSock, guest: WebSock|null, timer }

function send(ws, obj) {
  ws.sendText(JSON.stringify(obj));
}

function fail(ws, msg) {
  send(ws, { t: 'error', msg });
  ws.close();
}

function closeRoom(code) {
  const room = rooms.get(code);
  if (!room) return;
  clearTimeout(room.timer);
  // A room closed while still guestless was counted in ipWaiting.
  if (!room.guest) dropIp(ipWaiting, room.host.ip);
  rooms.delete(code);
}

// Post-pair relay: forward only allowlisted signaling envelopes, within the
// room's lifetime byte budget (see RELAY_TYPES above). fail() closes the
// offender's socket, whose onclose tears the room down and peer-closes the
// other side — the same funnel every other room-death path uses.
function relayFrom(room, from, to) {
  return (text) => {
    room.relayed += Buffer.byteLength(text, 'utf8');
    if (room.relayed > MAX_RELAY_BYTES_PER_ROOM) {
      return fail(from, 'signaling byte budget exceeded');
    }
    let msg;
    try { msg = JSON.parse(text); } catch { return fail(from, 'not JSON'); }
    const t = msg && typeof msg === 'object' ? msg.t : null;
    if (typeof t !== 'string' || !RELAY_TYPES.has(t)) {
      return fail(from, 'only sdp/ice signaling is relayed');
    }
    to.sendText(text);
  };
}

function attach(ws) {
  // Each socket is in exactly one of three states: fresh (no message yet),
  // waiting (first with a code, holding a room), or paired. Pairing swaps
  // BOTH sockets' onmessage to the enforcing relay (relayFrom), so this
  // setup handler never sees a paired socket again.
  let code = null;      // room this socket belongs to (as host or guest)

  // A socket that connects and never rendezvouses is either a stalled client or
  // a resource-holding probe; drop it so it can't accumulate.
  let hsTimer = setTimeout(() => fail(ws, 'no rendezvous'), HANDSHAKE_TIMEOUT_MS);
  const clearHandshakeTimer = () => { if (hsTimer) { clearTimeout(hsTimer); hsTimer = null; } };

  ws.onmessage = (text) => {
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return fail(ws, 'not JSON');
    }
    if (msg.t === 'rendezvous') {
      // Per-IP rendezvous rate limit (counted before any validation): codes
      // are short and user-chosen, so an attacker sweeping the code space —
      // or racing a legitimate guest for the peer slot — needs many quick
      // attempts, while real use is ~one per session.
      const now = Date.now();
      let w = rzWindows.get(ws.ip);
      if (!w || now - w.start >= RENDEZVOUS_WINDOW_MS) w = { start: now, count: 0 };
      w.count++;
      rzWindows.set(ws.ip, w);
      if (w.count > MAX_RENDEZVOUS_PER_WINDOW) {
        return fail(ws, 'too many attempts — wait a minute and try again');
      }
      if (code) return fail(ws, 'already in a room');
      const c = normalizeCode(msg.code);
      if (c.length < MIN_CODE_LEN) return fail(ws, 'code too short');
      const room = rooms.get(c);
      if (!room) {
        if (rooms.size >= MAX_ROOMS) return fail(ws, 'server busy — try again shortly');
        if ((ipWaiting.get(ws.ip) || 0) >= MAX_WAITING_PER_IP) {
          return fail(ws, 'too many open codes from your address — try again shortly');
        }
        // First to arrive with this code: host it and wait for the peer.
        clearHandshakeTimer();
        code = c;
        rooms.set(c, {
          host: ws,
          guest: null,
          relayed: 0, // lifetime bytes relayed post-pair, both directions
          timer: setTimeout(() => {
            const r = rooms.get(c);
            closeRoom(c);
            if (r) fail(r.host, 'nobody joined — try again');
          }, ROOM_TTL_MS),
        });
        bumpIp(ipWaiting, ws.ip);
        send(ws, { t: 'waiting' });
      } else if (!room.guest) {
        // Second arrival: pair as guest. Two peers per code, no more.
        clearHandshakeTimer();
        room.guest = ws;
        dropIp(ipWaiting, room.host.ip); // no longer an unclaimed waiting room
        clearTimeout(room.timer);
        room.timer = null;
        code = c;
        // Both sides start WebRTC now. The host (first arrival) is the offerer
        // and unit 0 / multi-mode parent in the game.
        const host = room.host;
        // Both sides swap to the enforcing relay: only sdp/ice envelopes cross,
        // within the room's byte budget. Payload contents are never inspected.
        host.onmessage = relayFrom(room, host, ws);
        ws.onmessage = relayFrom(room, ws, host);
        host.onclose = () => {
          closeRoom(c);
          send(ws, { t: 'peer-closed' });
          ws.close();
        };
        send(host, { t: 'paired', role: 'host' });
        send(ws, { t: 'paired', role: 'guest' });
      } else {
        return fail(ws, 'that code is already in use — pick another');
      }
    } else {
      fail(ws, 'expected rendezvous');
    }
  };

  ws.onclose = () => {
    clearHandshakeTimer();
    if (!code) return;
    const room = rooms.get(code);
    if (!room) return;
    // Unpaired host leaving, or either side of a pair: tear the room down
    // and let the survivor know.
    const other = room.host === ws ? room.guest : room.host;
    closeRoom(code);
    if (other && !other.closed) {
      send(other, { t: 'peer-closed' });
      other.close();
    }
  };
}

// ---------------- HTTP + upgrade plumbing ----------------

const server = http.createServer((req, res) => {
  // Health check / friendly hint for anyone poking the port with a browser.
  // The body is static — a live room count is a (mild) recon gift, so it is
  // only reported when SIGNAL_STATS=1 (test harness / private ops).
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(STATS_ENABLED
    ? `dingbat signaling server: ${rooms.size} live room(s). Connect via WebSocket.\n`
    : 'dingbat signaling server. Connect via WebSocket.\n');
});

server.on('upgrade', (req, socket, head) => {
  const key = req.headers['sec-websocket-key'];
  if (req.headers.upgrade?.toLowerCase() !== 'websocket' || !key) {
    socket.destroy();
    return;
  }
  // Optional CSWSH guard: when an allowlist is configured, reject browser
  // upgrades from foreign origins. A missing Origin is deliberately allowed
  // (non-browser clients; see the header comment).
  const origin = req.headers.origin;
  if (ALLOWED_ORIGINS.size && origin &&
      !ALLOWED_ORIGINS.has(String(origin).toLowerCase())) {
    socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
    return;
  }
  if (conns.size >= MAX_CONNS) {
    // Shed load rather than let socket count grow without bound.
    socket.destroy();
    return;
  }
  const accept = crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n` +
    '\r\n');
  socket.setNoDelay(true);
  const ws = new WebSock(socket);
  // Per-IP concurrent-socket cap, released in _dead(), once, on every path.
  ws.ip = effectiveIp(socket.remoteAddress, req.headers['x-forwarded-for']);
  if ((ipConns.get(ws.ip) || 0) >= MAX_CONNS_PER_IP) {
    fail(ws, 'too many connections from your address — try again shortly');
    return;
  }
  bumpIp(ipConns, ws.ip);
  ws.ipCounted = true;
  if (head && head.length) ws._ingest(head);
  attach(ws);
});

// ---------------- liveness reaper ----------------
// Reap sockets that have gone silent (a half-open TCP the OS hasn't noticed),
// and nudge quiet-but-live ones with a ping so their pong resets the clock.
// This is what stops a vanished paired peer from pinning its room forever.
const reaper = setInterval(() => {
  const now = Date.now();
  for (const ws of conns) {
    const idle = now - ws.lastRecv;
    if (idle > IDLE_TIMEOUT_MS) ws.close();
    else if (idle > PING_INTERVAL_MS) ws.ping();
  }
  // Rate-limit windows older than the window length are dead weight; prune
  // them here so the map can't grow without bound under an IP-hopping scan.
  for (const [ip, w] of rzWindows) {
    if (now - w.start >= RENDEZVOUS_WINDOW_MS) rzWindows.delete(ip);
  }
}, PING_INTERVAL_MS);
reaper.unref(); // never keep the process alive just for the sweep

server.listen(PORT, () => {
  console.log(`dingbat signaling server listening on ws://localhost:${PORT}`);
});
