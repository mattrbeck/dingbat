// Load / relay benchmark for the signaling server. Spawns the target server,
// drives a configurable number of concurrent room pairs through the full flow
// (rendezvous -> paired -> SDP + ICE relayed BOTH directions -> disconnect),
// verifies every relayed payload arrives intact, samples the server's RSS at
// idle and under peak load, and times relay round-trips.
//
//   node bench.mjs                       # benchmarks node server.js
//   SIGNAL_CMD=./signalsrv node bench.mjs   # benchmarks the compiled Nim server
//   PAIRS=100 node bench.mjs             # override the pair count (default 100)
//
// Zero dependencies: a tiny masked-frame WebSocket client is inlined, same as
// server.test.mjs.

import net from 'node:net';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SERVER = join(HERE, 'server.js');
const PORT = 8793;
const HOST = '127.0.0.1';
const PAIRS = parseInt(process.env.PAIRS || '100', 10);
const RELAY_MSGS = parseInt(process.env.RELAY_MSGS || '2000', 10);

function wsConnect(port) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, HOST, () => {
      const key = crypto.randomBytes(16).toString('base64');
      socket.write(
        'GET / HTTP/1.1\r\n' + `Host: ${HOST}\r\n` +
        'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
        `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`);
    });
    socket.on('error', reject);
    socket.setNoDelay(true);
    let handshakeDone = false;
    let buf = Buffer.alloc(0);
    const queue = [], waiters = [];
    const client = {
      isClosed: false,
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
      next(ms = 4000) {
        if (queue.length) return Promise.resolve(queue.shift());
        return new Promise((res, rej) => {
          const t = setTimeout(() => rej(new Error('timeout')), ms);
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
    socket.on('data', (d) => {
      buf = Buffer.concat([buf, d]);
      if (!handshakeDone) {
        const idx = buf.indexOf('\r\n\r\n');
        if (idx === -1) return;
        if (!/ 101 /.test(buf.subarray(0, idx).toString())) { reject(new Error('handshake failed')); return; }
        handshakeDone = true;
        buf = buf.subarray(idx + 4);
        resolve(client);
      }
      while (handshakeDone && buf.length >= 2) {
        const opcode = buf[0] & 0x0f;
        let len = buf[1] & 0x7f, off = 2;
        if (len === 126) { if (buf.length < 4) break; len = buf.readUInt16BE(2); off = 4; }
        else if (len === 127) { if (buf.length < 10) break; len = Number(buf.readBigUInt64BE(2)); off = 10; }
        if (buf.length < off + len) break;
        const payload = buf.subarray(off, off + len);
        buf = buf.subarray(off + len);
        if (opcode === 0x8) { socket.end(); break; }
        if (opcode === 0x1) {
          const m = JSON.parse(payload.toString('utf8'));
          if (waiters.length) waiters.shift()(m); else queue.push(m);
        }
      }
    });
  });
}

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

async function liveRooms(port) {
  const m = (await httpGet(port)).match(/(\d+) live room/);
  return m ? parseInt(m[1], 10) : -1;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Sample RSS (KB) of the server process tree — the server PID plus any child
// (node prints one process; a compiled binary is one process too).
function rssKB(pid) {
  return new Promise((resolve) => {
    const p = spawn('ps', ['-o', 'rss=', '-p', String(pid)]);
    let out = '';
    p.stdout.on('data', (d) => (out += d));
    p.on('close', () => resolve(parseInt(out.trim().split(/\s+/)[0] || '0', 10)));
  });
}

async function run() {
  const [bin, ...pre] = process.env.SIGNAL_CMD
    ? process.env.SIGNAL_CMD.split(' ') : [process.execPath, SERVER];
  const label = process.env.SIGNAL_CMD || 'node server.js';
  const server = spawn(bin, [...pre, String(PORT)], { stdio: 'ignore' });
  server.on('error', (e) => { console.error('spawn error', e); process.exit(1); });

  for (let i = 0; ; i++) {
    try { if ((await liveRooms(PORT)) >= 0) break; } catch {}
    if (i > 100) { console.error('server never came up'); process.exit(1); }
    await sleep(50);
  }
  await sleep(300);
  const idleRss = await rssKB(server.pid);

  // ---- Load: PAIRS concurrent rooms, each relaying SDP + ICE both ways ----
  let relayErrors = 0;
  const hosts = [], guests = [];
  const t0 = Date.now();
  for (let i = 0; i < PAIRS; i++) {
    const code = 'BENCH' + i.toString(36).toUpperCase();
    const a = await wsConnect(PORT);
    a.send({ t: 'rendezvous', code });
    if ((await a.next()).t !== 'waiting') relayErrors++;
    const b = await wsConnect(PORT);
    b.send({ t: 'rendezvous', code });
    const ap = await a.next(), bp = await b.next();
    if (ap.t !== 'paired' || ap.role !== 'host') relayErrors++;
    if (bp.t !== 'paired' || bp.role !== 'guest') relayErrors++;
    // SDP host->guest, ICE guest->host: verify verbatim relay both directions.
    const sdp = { t: 'sdp', d: { type: 'offer', sdp: 'v=0 room ' + code + ' '.repeat(20) } };
    a.send(sdp);
    const gotSdp = await b.next();
    if (gotSdp.t !== 'sdp' || gotSdp.d.sdp !== sdp.d.sdp) relayErrors++;
    const ice = { t: 'ice', c: { candidate: 'candidate:' + code, sdpMLineIndex: 0 } };
    b.send(ice);
    const gotIce = await a.next();
    if (gotIce.t !== 'ice' || gotIce.c.candidate !== ice.c.candidate) relayErrors++;
    hosts.push(a); guests.push(b);
  }
  const loadMs = Date.now() - t0;
  await sleep(200);
  const peakRss = await rssKB(server.pid);
  const roomsAtPeak = await liveRooms(PORT);

  // ---- Relay throughput: hammer one pair with RELAY_MSGS round-trips ----
  const h = hosts[0], g = guests[0];
  const payload = 'x'.repeat(400);
  const tR = Date.now();
  for (let i = 0; i < RELAY_MSGS; i++) {
    h.send({ t: 'sdp', d: { n: i, p: payload } });
    const m = await g.next();
    if (m.d.n !== i) relayErrors++;
  }
  const relayMs = Date.now() - tR;

  // ---- Churn: drop everyone, confirm rooms are freed ----
  for (const c of hosts) c.close();
  for (const c of guests) c.close();
  let freed = -1;
  for (let i = 0; i < 80; i++) { freed = await liveRooms(PORT); if (freed === 0) break; await sleep(25); }
  await sleep(300);
  const afterRss = await rssKB(server.pid);

  server.kill();

  console.log(`\n=== ${label} ===`);
  console.log(`pairs (rooms) driven         : ${PAIRS}  (=${PAIRS * 2} sockets)`);
  console.log(`relay correctness errors     : ${relayErrors}`);
  console.log(`rooms live at peak           : ${roomsAtPeak} (want ${PAIRS})`);
  console.log(`rooms after disconnect churn : ${freed} (want 0)`);
  console.log(`setup+relay of all pairs     : ${loadMs} ms`);
  console.log(`relay ${RELAY_MSGS} round-trips (1 pair): ${relayMs} ms  ` +
              `=> ${(RELAY_MSGS / (relayMs / 1000)).toFixed(0)} msg/s, ` +
              `${(relayMs / RELAY_MSGS).toFixed(3)} ms/round-trip`);
  console.log(`RSS idle                     : ${idleRss} KB (${(idleRss / 1024).toFixed(1)} MB)`);
  console.log(`RSS at peak (${PAIRS * 2} sockets)   : ${peakRss} KB (${(peakRss / 1024).toFixed(1)} MB)`);
  console.log(`RSS after churn              : ${afterRss} KB (${(afterRss / 1024).toFixed(1)} MB)`);
  console.log(`RSS per connection (approx)  : ${((peakRss - idleRss) / (PAIRS * 2)).toFixed(1)} KB`);
  if (relayErrors || roomsAtPeak !== PAIRS || freed !== 0) {
    console.error('\nBENCH FAILED (correctness)');
    process.exit(1);
  }
}
run().catch((e) => { console.error(e); process.exit(1); });
