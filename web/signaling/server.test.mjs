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
const HOST = '127.0.0.1';

// ---------------- minimal WebSocket client ----------------
// Client frames must be masked (RFC 6455); the server replies unmasked.

function wsConnect(port) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, HOST, () => {
      const key = crypto.randomBytes(16).toString('base64');
      socket.write(
        'GET / HTTP/1.1\r\n' +
        `Host: ${HOST}:${port}\r\n` +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Key: ${key}\r\n` +
        'Sec-WebSocket-Version: 13\r\n\r\n');
    });
    socket.on('error', reject);

    let handshakeDone = false;
    let buf = Buffer.alloc(0);
    const queue = [];   // received JSON messages not yet awaited
    const waiters = []; // pending next() resolvers

    const client = {
      isClosed: false,
      onclose: null,
      send(obj) {
        const payload = Buffer.from(JSON.stringify(obj), 'utf8');
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
  const server = spawn(bin, [...preArgs, String(PORT)], { stdio: 'ignore' });
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

  if (failures) { console.error(`\n${failures} assertion(s) failed`); process.exit(1); }
  console.log('\nall signaling room-lifecycle tests passed');
}

run().catch((e) => { console.error(e); process.exit(1); });
