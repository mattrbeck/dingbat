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
//   after "paired", every other message is relayed verbatim to the peer
//   (the web UI sends {"t":"sdp",...} and {"t":"ice",...}).
//
// Like a physical link cable, players don't designate a host: both type the
// same code and the FIRST to reach the server hosts (becomes the WebRTC
// offerer / SIO multi-mode parent). A code is a rendezvous point for exactly
// two peers; a third using the same code is rejected. Codes are normalized to
// uppercase alphanumerics and an unclaimed room expires after 10 minutes.

'use strict';

const http = require('http');
const crypto = require('crypto');

const PORT = parseInt(process.argv[2], 10) || parseInt(process.env.PORT, 10) || 8790;
const ROOM_TTL_MS = 10 * 60 * 1000;
const MAX_MSG_BYTES = 64 * 1024; // SDP + ICE are a few KB; anything bigger is abuse
const MIN_CODE_LEN = 3; // user-chosen; short enough to say aloud, long enough to not collide by accident

// Fold a user-typed code to the canonical form both peers must match on.
const normalizeCode = (raw) =>
  String(raw || '').toUpperCase().replace(/[^A-Z0-9]/g, '');

// ---------------- minimal WebSocket implementation ----------------

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** Wrap an upgraded socket with frame encode/decode + callbacks. */
class WebSock {
  constructor(socket) {
    this.socket = socket;
    this.buf = Buffer.alloc(0);
    this.fragments = null; // in-progress fragmented message
    this.closed = false;
    this.onmessage = null; // (string) => void
    this.onclose = null;   // () => void
    socket.on('data', (d) => this._ingest(d));
    const bye = () => this._dead();
    socket.on('close', bye);
    socket.on('error', bye);
    socket.on('end', bye);
  }

  _dead() {
    if (this.closed) return;
    this.closed = true;
    this.socket.destroy();
    if (this.onclose) this.onclose();
  }

  _ingest(data) {
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
  rooms.delete(code);
}

function attach(ws) {
  // Each socket is in exactly one of three states: fresh (no message yet),
  // waiting (first with a code, holding a room), or paired (relaying to `peer`).
  let code = null;      // room this socket belongs to (as host or guest)
  let peer = null;      // set once paired

  ws.onmessage = (text) => {
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return fail(ws, 'not JSON');
    }
    if (peer) {
      // Paired: relay verbatim. The server never inspects SDP/ICE.
      peer.sendText(text);
      return;
    }
    if (msg.t === 'rendezvous') {
      if (code) return fail(ws, 'already in a room');
      const c = normalizeCode(msg.code);
      if (c.length < MIN_CODE_LEN) return fail(ws, 'code too short');
      const room = rooms.get(c);
      if (!room) {
        // First to arrive with this code: host it and wait for the peer.
        code = c;
        rooms.set(c, {
          host: ws,
          guest: null,
          timer: setTimeout(() => {
            const r = rooms.get(c);
            closeRoom(c);
            if (r) fail(r.host, 'nobody joined — try again');
          }, ROOM_TTL_MS),
        });
        send(ws, { t: 'waiting' });
      } else if (!room.guest) {
        // Second arrival: pair as guest. Two peers per code, no more.
        room.guest = ws;
        clearTimeout(room.timer);
        room.timer = null;
        code = c;
        peer = room.host;
        // Both sides start WebRTC now. The host (first arrival) is the offerer
        // and unit 0 / multi-mode parent in the game.
        const host = room.host;
        // Host side: swap from "waiting" to "relaying"
        host.onmessage = (t) => ws.sendText(t);
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
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(`dingbat signaling server: ${rooms.size} live room(s). ` +
          'Connect via WebSocket.\n');
});

server.on('upgrade', (req, socket, head) => {
  const key = req.headers['sec-websocket-key'];
  if (req.headers.upgrade?.toLowerCase() !== 'websocket' || !key) {
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
  if (head && head.length) ws._ingest(head);
  attach(ws);
});

server.listen(PORT, () => {
  console.log(`dingbat signaling server listening on ws://localhost:${PORT}`);
});
