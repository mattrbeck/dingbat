// Tests for the signaling server's room lifecycle — in particular that a
// connection code is FREED the instant its clients go away. This is the
// contract the same-browser BroadcastChannel fast path relies on: when two tabs
// of one browser pair locally, each closes its signaling socket, and the server
// must release the code immediately (not hold it until the 10-minute TTL) so it
// can be reused right away.
//
// Zero dependencies, mirroring server.js: a tiny masked-frame WebSocket client
// is implemented inline so this runs on any Node version without a global
// WebSocket. Spawns its own server on a throwaway port; exits non-zero on any
// failed assertion.

import net from 'node:net';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SERVER = join(HERE, 'server.js');
const PORT = 8791; // distinct from the default 8790 so a dev server can coexist
const PORT2 = 8792; // scratch servers for the abuse-limit scenarios
const HOST = '127.0.0.1';

// ---------------- minimal WebSocket client ----------------
// Client frames must be masked (RFC 6455); the server replies unmasked.

function wsConnect(port, extraHeaders = '') {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, HOST, () => {
      const key = crypto.randomBytes(16).toString('base64');
      socket.write(
        'GET / HTTP/1.1\r\n' +
        `Host: ${HOST}:${port}\r\n` +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Key: ${key}\r\n` +
        'Sec-WebSocket-Version: 13\r\n' +
        extraHeaders + '\r\n');
    });
    socket.on('error', reject);

    let handshakeDone = false;
    let buf = Buffer.alloc(0);
    const queue = [];   // received JSON messages not yet awaited
    const waiters = []; // pending next() resolvers

    const client = {
      isClosed: false,
      onclose: null,
      send(obj) { client.sendRaw(JSON.stringify(obj)); },
      // Raw text frame (not necessarily JSON) — for the relay-allowlist tests.
      sendRaw(str) {
        const payload = Buffer.from(str, 'utf8');
        const mask = crypto.randomBytes(4);
        const len = payload.length;
        let header;
        if (len < 126) header = Buffer.from([0x81, 0x80 | len]);
        else if (len < 65536) {
          header = Buffer.alloc(4);
          header[0] = 0x81; header[1] = 0x80 | 126; header.writeUInt16BE(len, 2);
        } else {
          header = Buffer.alloc(10);
          header[0] = 0x81; header[1] = 0x80 | 127; header.writeBigUInt64BE(BigInt(len), 2);
        }
        const body = Buffer.from(payload);
        for (let i = 0; i < body.length; i++) body[i] ^= mask[i & 3];
        socket.write(Buffer.concat([header, mask, body]));
      },
      // Resolve with the next server message, or reject after `ms`.
      next(ms = 2000) {
        if (queue.length) return Promise.resolve(queue.shift());
        return new Promise((res, rej) => {
          const t = setTimeout(() => rej(new Error('timeout waiting for a message')), ms);
          waiters.push((m) => { clearTimeout(t); res(m); });
        });
      },
      close() {
        if (client.isClosed) return;
        client.isClosed = true;
        try { socket.write(Buffer.from([0x88, 0x80, 0, 0, 0, 0])); } catch {}
        socket.end();
      },
    };

    const markClosed = () => {
      if (!handshakeDone) reject(new Error('closed before handshake'));
      if (client.isClosed) return;
      client.isClosed = true;
      if (client.onclose) client.onclose();
    };
    socket.on('close', markClosed);
    socket.on('end', markClosed);

    socket.on('data', (d) => {
      buf = Buffer.concat([buf, d]);
      if (!handshakeDone) {
        const idx = buf.indexOf('\r\n\r\n');
        if (idx === -1) return;
        const head = buf.subarray(0, idx).toString('utf8');
        if (!/ 101 /.test(head)) { reject(new Error('handshake failed: ' + head)); return; }
        handshakeDone = true;
        buf = buf.subarray(idx + 4);
        resolve(client);
      }
      while (handshakeDone && buf.length >= 2) {
        const opcode = buf[0] & 0x0f;
        let len = buf[1] & 0x7f;
        let off = 2;
        if (len === 126) { if (buf.length < 4) break; len = buf.readUInt16BE(2); off = 4; }
        else if (len === 127) { if (buf.length < 10) break; len = Number(buf.readBigUInt64BE(2)); off = 10; }
        if (buf.length < off + len) break;
        const payload = buf.subarray(off, off + len);
        buf = buf.subarray(off + len);
        if (opcode === 0x8) { socket.end(); markClosed(); break; } // close
        if (opcode === 0x1) {                                     // text
          const m = JSON.parse(payload.toString('utf8'));
          if (waiters.length) waiters.shift()(m);
          else queue.push(m);
        }
      }
    });
  });
}

// ---------------- helpers ----------------

const httpGet = (port, path = '/') =>
  new Promise((resolve, reject) => {
    const req = net.connect(port, HOST, () => {
      req.write(`GET ${path} HTTP/1.1\r\nHost: ${HOST}\r\nConnection: close\r\n\r\n`);
    });
    let data = '';
    req.on('data', (d) => (data += d));
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });

// The health page reports "... N live room(s). ..." — read N back.
async function liveRooms(port) {
  const body = await httpGet(port);
  const m = body.match(/(\d+) live room/);
  if (!m) throw new Error('could not read room count from: ' + body);
  return parseInt(m[1], 10);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Poll until liveRooms hits `want` (freeing is prompt but not synchronous with
// our socket.end returning) or time out.
async function waitRooms(port, want, ms = 2000) {
  const deadline = Date.now() + ms;
  for (;;) {
    const n = await liveRooms(port);
    if (n === want) return n;
    if (Date.now() > deadline) throw new Error(`rooms stayed at ${n}, wanted ${want}`);
    await sleep(25);
  }
}

let failures = 0;
function assert(cond, msg) {
  if (cond) { console.log(`  ok: ${msg}`); return; }
  failures++;
  console.error(`  FAIL: ${msg}`);
}

// ---------------- scenarios ----------------

async function run() {
  // Default target is the Node server; SIGNAL_CMD lets the same suite exercise
  // an alternative implementation (e.g. the compiled Nim binary):
  //   SIGNAL_CMD=./signalsrv node server.test.mjs
  const [bin, ...preArgs] = process.env.SIGNAL_CMD
    ? process.env.SIGNAL_CMD.split(' ')
    : [process.execPath, SERVER];

  // Spawn a server on `port` with extra env, wait for it to listen, run `fn`,
  // and always kill it. The room-lifecycle scenarios need SIGNAL_STATS=1 so
  // the health page still reports the live-room count they poll.
  async function withServer(port, env, fn) {
    const srv = spawn(bin, [...preArgs, String(port)],
      { stdio: 'ignore', env: { ...process.env, ...env } });
    srv.on('error', (e) => { console.error('server spawn error', e); process.exit(1); });
    for (let i = 0; ; i++) {
      try { await httpGet(port); break; } catch { if (i > 100) throw new Error('server never came up'); await sleep(50); }
    }
    try { await fn(port); } finally { srv.kill(); await sleep(100); }
  }

  const server = spawn(bin, [...preArgs, String(PORT)],
    { stdio: 'ignore', env: { ...process.env, SIGNAL_STATS: '1' } });
  server.on('error', (e) => { console.error('server spawn error', e); process.exit(1); });

  // Wait for the listener.
  for (let i = 0; ; i++) {
    try { await liveRooms(PORT); break; } catch { if (i > 100) throw new Error('server never came up'); await sleep(50); }
  }

  try {
    // 1) A lone host frees its room the moment it disconnects (and the code is
    //    reusable) — this is a same-browser tab that registered while waiting
    //    for its peer, then paired locally and dropped the signaling socket.
    console.log('waiting-room freed on disconnect:');
    {
      const a = await wsConnect(PORT);
      a.send({ t: 'rendezvous', code: 'FREE1' });
      assert((await a.next()).t === 'waiting', 'first arrival gets "waiting"');
      assert((await waitRooms(PORT, 1)) === 1, 'room is held while waiting');
      a.close();
      assert((await waitRooms(PORT, 0)) === 0, 'room freed immediately on disconnect');
      const b = await wsConnect(PORT);
      b.send({ t: 'rendezvous', code: 'FREE1' });
      assert((await b.next()).t === 'waiting', 'same code is reusable right away');
      b.close();
      await waitRooms(PORT, 0);
    }

    // 2) THE case the request is about: two clients rendezvous (the server
    //    pairs them), then BOTH go away because they linked locally instead —
    //    the code must be freed at once and immediately reusable.
    console.log('paired room freed when both clients go local:');
    {
      const a = await wsConnect(PORT);
      const b = await wsConnect(PORT);
      a.send({ t: 'rendezvous', code: 'LOCAL9' });
      assert((await a.next()).t === 'waiting', 'A waits');
      b.send({ t: 'rendezvous', code: 'LOCAL9' });
      const ap = await a.next(), bp = await b.next();
      assert(ap.t === 'paired' && ap.role === 'host', 'A paired as host');
      assert(bp.t === 'paired' && bp.role === 'guest', 'B paired as guest');
      assert((await waitRooms(PORT, 1)) === 1, 'paired code occupies exactly one room');

      // A third party can't hijack the code while it's in use.
      const c = await wsConnect(PORT);
      c.send({ t: 'rendezvous', code: 'LOCAL9' });
      assert((await c.next()).t === 'error', 'a third client on the same code is rejected');
      c.close();

      // Both peers drop their signaling sockets (they're linked over the
      // BroadcastChannel now) — the room must vanish.
      a.close();
      b.close();
      assert((await waitRooms(PORT, 0)) === 0, 'code freed immediately once both go local');

      const d = await wsConnect(PORT);
      d.send({ t: 'rendezvous', code: 'LOCAL9' });
      assert((await d.next()).t === 'waiting', 'freed code is reusable immediately');
      d.close();
      await waitRooms(PORT, 0);
    }

    // 3) If only ONE paired client drops, the survivor is told and the room is
    //    freed (the server never leaves a half-room dangling).
    console.log('paired room freed + peer notified on one-sided disconnect:');
    {
      const a = await wsConnect(PORT);
      const b = await wsConnect(PORT);
      a.send({ t: 'rendezvous', code: 'HALF7' });
      await a.next(); // waiting
      b.send({ t: 'rendezvous', code: 'HALF7' });
      await a.next(); await b.next(); // paired, paired
      a.close();
      assert((await b.next()).t === 'peer-closed', 'survivor gets "peer-closed"');
      assert((await waitRooms(PORT, 0)) === 0, 'room freed on the one-sided drop');
      b.close();
      await waitRooms(PORT, 0);
    }
  } finally {
    server.kill();
  }

  // One connect + rendezvous + first reply, then hang up.
  async function rzAttempt(port, code, headers = '') {
    const c = await wsConnect(port, headers);
    c.send({ t: 'rendezvous', code });
    const m = await c.next();
    c.close();
    return m;
  }

  // 4) Health page is static by default (no live-room count leaked); the
  //    count only appears under SIGNAL_STATS=1 (what the sections above ran).
  console.log('health page static without SIGNAL_STATS:');
  await withServer(PORT2, {}, async (port) => {
    const body = await httpGet(port);
    assert(/Connect via WebSocket/.test(body), 'health page still answers');
    assert(!/live room/.test(body), 'no room count in the default health page');
  });

  // 5) Per-IP rendezvous rate limit: attempts count before validation, so
  //    short-code failures burn the window too; the 11th in a minute is cut.
  console.log('per-IP rendezvous rate limit:');
  await withServer(PORT2, {}, async (port) => {
    let shortRejects = 0;
    for (let i = 0; i < 10; i++) {
      const m = await rzAttempt(port, 'A'); // too short -> error, but counted
      if (m.t === 'error' && /too short/.test(m.msg)) shortRejects++;
    }
    assert(shortRejects === 10, 'first 10 attempts hit normal validation');
    const m = await rzAttempt(port, 'A');
    assert(m.t === 'error' && /too many attempts/.test(m.msg),
      '11th attempt inside the window is rate-limited');
  });

  // 6) Per-IP concurrent-connection cap (8): the 9th socket from one IP is
  //    turned away; a different client IP (via trusted XFF from localhost)
  //    still gets in.
  console.log('per-IP connection cap:');
  await withServer(PORT2, {}, async (port) => {
    const held = [];
    for (let i = 0; i < 8; i++) held.push(await wsConnect(port));
    const ninth = await wsConnect(port);
    const m = await ninth.next();
    assert(m.t === 'error' && /too many connections/.test(m.msg),
      '9th concurrent socket from one IP is rejected');
    const other = await rzAttempt(port, 'XFF1', 'X-Forwarded-For: 203.0.113.9\r\n');
    assert(other.t === 'waiting', 'another IP (trusted XFF via localhost) still connects');
    for (const c of held) c.close();
    await sleep(250); // let the server observe the closes
    const again = await rzAttempt(port, 'AGAIN');
    assert(again.t === 'waiting', 'closing sockets releases the per-IP count');
  });

  // 7) Per-IP waiting-room cap (4): a 5th unclaimed code from one IP is
  //    refused; pairing one of the rooms frees a slot.
  console.log('per-IP waiting-room cap:');
  await withServer(PORT2, {}, async (port) => {
    const hosts = [];
    for (let i = 1; i <= 4; i++) {
      const c = await wsConnect(port);
      c.send({ t: 'rendezvous', code: `WAIT${i}` });
      assert((await c.next()).t === 'waiting', `waiting room ${i} accepted`);
      hosts.push(c);
    }
    const fifth = await rzAttempt(port, 'WAIT5');
    assert(fifth.t === 'error' && /too many open codes/.test(fifth.msg),
      '5th unclaimed code from one IP is refused');
    const guest = await wsConnect(port);
    guest.send({ t: 'rendezvous', code: 'WAIT1' });
    assert((await guest.next()).t === 'paired', 'pairing one room still works');
    const sixth = await wsConnect(port);
    sixth.send({ t: 'rendezvous', code: 'WAIT6' });
    assert((await sixth.next()).t === 'waiting', 'pairing freed a waiting slot');
    sixth.close();
    guest.close();
    for (const c of hosts) c.close();
  });

  // 8) Origin allowlist: only set-and-mismatched Origins are rejected. A
  //    missing Origin is allowed by design (non-browser clients send none;
  //    the check is CSWSH protection for browsers). Unset allowlist = allow
  //    all, which is what every section above already exercised.
  console.log('origin allowlist:');
  await withServer(PORT2, { SIGNAL_ALLOWED_ORIGINS: 'https://dingbat.example' }, async (port) => {
    let rejected = false;
    try { await wsConnect(port, 'Origin: https://evil.example\r\n'); }
    catch { rejected = true; }
    assert(rejected, 'foreign Origin upgrade is rejected');
    const ok = await rzAttempt(port, 'ORIG1', 'Origin: https://dingbat.example\r\n');
    assert(ok.t === 'waiting', 'allowlisted Origin connects');
    const bare = await rzAttempt(port, 'ORIG2');
    assert(bare.t === 'waiting', 'missing Origin (non-browser client) connects');
  });

  // Pair two fresh sockets on `code`. Each pair gets its own client IP (via
  // trusted XFF from localhost) so many pairs in one section don't trip the
  // per-IP rendezvous rate limit these tests aren't about.
  let pairSeq = 0;
  async function pairUp(port, code) {
    pairSeq++;
    const xff = (n) => `X-Forwarded-For: 198.51.100.${pairSeq * 2 + n}\r\n`;
    const a = await wsConnect(port, xff(0));
    a.send({ t: 'rendezvous', code });
    if ((await a.next()).t !== 'waiting') throw new Error('pairUp: no waiting');
    const b = await wsConnect(port, xff(1));
    b.send({ t: 'rendezvous', code });
    if ((await a.next()).t !== 'paired') throw new Error('pairUp: host not paired');
    if ((await b.next()).t !== 'paired') throw new Error('pairUp: guest not paired');
    return [a, b];
  }

  // 9) Post-pair relay allowlist: the server exists to carry the WebRTC
  //    handshake and NOTHING else. Only {"t":"sdp"} / {"t":"ice"} envelopes
  //    cross; any other type, rendezvous-after-pairing, or a non-JSON blob
  //    closes the room (error to the sender, peer-closed to the peer).
  console.log('post-pair relay allowlist (sdp/ice only):');
  await withServer(PORT2, { SIGNAL_STATS: '1' }, async (port) => {
    // (a) sdp and ice relay fine, both directions, byte-for-byte.
    {
      const [a, b] = await pairUp(port, 'RLY1');
      a.send({ t: 'sdp', d: { type: 'offer', sdp: 'v=0\r\no=- 1 1 IN IP4 0.0.0.0' } });
      const sdp = await b.next();
      assert(sdp.t === 'sdp' && sdp.d.sdp === 'v=0\r\no=- 1 1 IN IP4 0.0.0.0',
        'sdp relays host->guest intact');
      b.send({ t: 'ice', c: { candidate: 'candidate:1 1 udp 2122260223 x', sdpMLineIndex: 0 } });
      const ice = await a.next();
      assert(ice.t === 'ice' && ice.c.candidate === 'candidate:1 1 udp 2122260223 x',
        'ice relays guest->host intact');
      a.close(); b.close();
      await waitRooms(port, 0);
    }
    // (b) a non-signaling type from the host closes the room.
    {
      const [a, b] = await pairUp(port, 'RLY2');
      a.send({ t: 'rbinput', data: 'AAAA' });
      const err = await a.next();
      assert(err.t === 'error' && /only sdp\/ice/.test(err.msg),
        'game-shaped type is rejected with an error');
      assert((await b.next()).t === 'peer-closed', 'peer is told the room is gone');
      await waitRooms(port, 0);
    }
    // ...and from the guest, with an arbitrary unknown type.
    {
      const [a, b] = await pairUp(port, 'RLY3');
      b.send({ t: 'x' });
      const err = await b.next();
      assert(err.t === 'error' && /only sdp\/ice/.test(err.msg),
        'unknown type from the guest is rejected');
      assert((await a.next()).t === 'peer-closed', 'host notified of the closed room');
      await waitRooms(port, 0);
    }
    // rendezvous is pre-pair only; post-pair it is not signaling.
    {
      const [a, b] = await pairUp(port, 'RLY4');
      a.send({ t: 'rendezvous', code: 'OTHER' });
      assert((await a.next()).t === 'error', 'rendezvous after pairing is rejected');
      assert((await b.next()).t === 'peer-closed', 'peer notified');
      await waitRooms(port, 0);
    }
    // a raw non-JSON blob (what a data tunnel would look like) closes the room.
    {
      const [a, b] = await pairUp(port, 'RLY5');
      a.sendRaw('GAMEBYTES not json at all');
      const err = await a.next();
      assert(err.t === 'error' && /not JSON/.test(err.msg), 'raw blob is rejected');
      assert((await b.next()).t === 'peer-closed', 'peer notified');
      await waitRooms(port, 0);
    }
  });

  // 10) Per-room relayed-byte budget: a real handshake is a few KB; a room
  //     that relays 256 KB is a data tunnel and gets shut down even when every
  //     envelope is an allowlisted type.
  console.log('per-room relay byte budget:');
  await withServer(PORT2, { SIGNAL_STATS: '1' }, async (port) => {
    // (c) sustained max-size "sdp" spam trips the budget. Each message is
    // ~60 KB (under the 64 KB per-message cap): 4 fit under 256 KB and relay;
    // the 5th crosses the budget and closes the room.
    {
      const [a, b] = await pairUp(port, 'BDG1');
      const big = 'x'.repeat(60 * 1024);
      let intact = 0;
      for (let i = 0; i < 4; i++) {
        a.send({ t: 'sdp', d: big });
        const m = await b.next();
        if (m.t === 'sdp' && m.d.length === big.length) intact++;
      }
      assert(intact === 4, 'first 4 x 60KB messages stay under budget and relay');
      a.send({ t: 'sdp', d: big });
      const err = await a.next();
      assert(err.t === 'error' && /byte budget/.test(err.msg),
        '5th pushes the room past 256KB and is cut off');
      assert((await b.next()).t === 'peer-closed', 'peer notified of the closed room');
      await waitRooms(port, 0);
    }
    // (d) a realistic WebRTC handshake is nowhere near the budget: a chunky
    // SDP offer + answer and 40 trickled ICE candidates all relay fine.
    {
      const [a, b] = await pairUp(port, 'BDG2');
      const sdpBody = 'v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n' +
        'a=fingerprint:sha-256 ' + 'AB:'.repeat(31) + 'CD\r\n' +
        'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'.repeat(20);
      a.send({ t: 'sdp', d: { type: 'offer', sdp: sdpBody } });
      const offer = await b.next();
      assert(offer.t === 'sdp' && offer.d.sdp === sdpBody, 'realistic offer relays');
      b.send({ t: 'sdp', d: { type: 'answer', sdp: sdpBody } });
      assert((await a.next()).t === 'sdp', 'answer relays');
      let iceOk = 0;
      for (let i = 0; i < 40; i++) {
        const cand = {
          t: 'ice',
          c: { candidate: `candidate:${i} 1 udp 2122260223 192.168.1.${i} ${40000 + i} typ srflx raddr 0.0.0.0 rport 9 generation 0 ufrag abcd`, sdpMLineIndex: 0 },
        };
        const [from, to] = i % 2 ? [b, a] : [a, b];
        from.send(cand);
        const m = await to.next();
        if (m.t === 'ice' && m.c.candidate === cand.c.candidate) iceOk++;
      }
      assert(iceOk === 40, '40 trickled ICE candidates relay both ways');
      // The room is still healthy — one more sdp goes through, no error seen.
      a.send({ t: 'sdp', d: { type: 'offer', sdp: 'v=0 renegotiate' } });
      assert((await b.next()).d.sdp === 'v=0 renegotiate',
        'room still open: realistic volume is far under the budget');
      a.close(); b.close();
      await waitRooms(port, 0);
    }
  });

  if (failures) { console.error(`\n${failures} assertion(s) failed`); process.exit(1); }
  console.log('\nall signaling room-lifecycle tests passed');
}

run().catch((e) => { console.error(e); process.exit(1); });
