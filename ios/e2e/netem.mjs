// A bad network between the two peers of a link test, with no root needed:
// every WebRTC packet goes through a local UDP relay that delays, jitters
// and drops it. The browser page's WebSocket is wrapped so each side only
// ever learns the other's addresses as relay ports: its own candidates go
// out rewritten, the friend's come in rewritten, and anything that cannot be
// relayed (srflx, IPv6, TCP) is pointed at a dead port. Both WebRTC stacks
// then run their real ICE and SCTP over the loss: retransmissions, RTT
// estimates and congestion control included.
//
//   const net = await impair(page, { delay: 40, jitter: 15, loss: 0.02 });
//   ... net.set({ delay: 150 }) ... net.stats() ... net.close();
//
// Chromium must run with --disable-features=WebRtcHideLocalIpsWithMdns so
// its host candidates carry addresses rather than .local names.

import dgram from "node:dgram";

// A small seeded PRNG, so a run's drops can be replayed (NETEM_SEED).
const mulberry32 = (a) => () => {
  a |= 0; a = (a + 0x6d2b79f5) | 0;
  let t = Math.imul(a ^ (a >>> 15), 1 | a);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};

// Rewrites the page's signaling traffic; installed before any page script.
const PAGE_HOOK = () => {
  const Native = window.WebSocket;
  class NetemSocket extends Native {
    constructor(...a) {
      super(...a);
      this._out = Promise.resolve();
      this._in = Promise.resolve();
      this._handler = null;
      super.onmessage = (e) => {
        this._in = this._in.then(async () => {
          const data = typeof e.data === "string" ? await window.__netemRewrite(e.data) : e.data;
          this._handler?.call(this, new MessageEvent("message", { data }));
        });
      };
    }
    set onmessage(h) { this._handler = h; }
    get onmessage() { return this._handler; }
    send(d) {
      this._out = this._out.then(async () => {
        const data = typeof d === "string" ? await window.__netemRewrite(d) : d;
        if (this.readyState === Native.OPEN) super.send(data);
      });
    }
  }
  window.WebSocket = NetemSocket;
};

export const impair = async (page, { delay = 40, jitter = 15, loss = 0.02, seed = 1 } = {}) => {
  const rand = mulberry32(seed);
  const p = { delay, jitter, loss };
  const relays = new Map(); // "ip:port" of a real endpoint -> relay
  const totals = { sent: 0, dropped: 0 };

  // One relay per real endpoint: whatever reaches it from elsewhere goes to
  // the endpoint, and the endpoint's replies go back to the last sender.
  const relayFor = async (ip, port) => {
    const key = ip + ":" + port;
    if (relays.has(key)) return relays.get(key).port;
    const sock = dgram.createSocket("udp4");
    const r = { sock, port: 0, other: null, last: [0, 0] };
    sock.on("message", (msg, from) => {
      const toTarget = !(from.address === ip && from.port === port);
      if (toTarget) r.other = { address: from.address, port: from.port };
      const dst = toTarget ? { address: ip, port } : r.other;
      if (!dst) return;
      totals.sent++;
      if (rand() < p.loss) { totals.dropped++; return; }
      // Jittered but in order, as most real paths deliver.
      const dir = toTarget ? 0 : 1;
      const now = performance.now();
      const at = Math.max(now + Math.max(0, p.delay + p.jitter * (rand() * 2 - 1)), r.last[dir]);
      r.last[dir] = at;
      setTimeout(() => { if (!r.closed) sock.send(msg, dst.port, dst.address); }, at - now);
    });
    await new Promise((res) => sock.bind(0, "0.0.0.0", res));
    r.port = sock.address().port;
    relays.set(key, r);
    return r.port;
  };

  // "candidate:F C udp P <ip> <port> typ host ..." -> the relay's, or dead.
  const rewriteCandidate = async (c) => {
    const p = c.split(" ");
    const i = p.indexOf("typ");
    if (i < 0 || p.length < 6) return c;
    const ip = p[4], port = +p[5];
    const relayable = /udp/i.test(p[2]) && p[i + 1] === "host" && /^\d+\.\d+\.\d+\.\d+$/.test(ip);
    p[4] = "127.0.0.1";
    p[5] = String(relayable ? await relayFor(ip, port) : 9);
    if (!relayable) p[i + 1] = "host";
    return p.slice(0, i + 2).join(" ");
  };

  const rewriteSdp = async (sdp) => {
    const out = [];
    for (const line of sdp.split(/\r\n/)) {
      out.push(line.startsWith("a=candidate:") ? "a=" + await rewriteCandidate(line.slice(2)) : line);
    }
    return out.join("\r\n");
  };

  await page.exposeFunction("__netemRewrite", async (text) => {
    let m;
    try { m = JSON.parse(text); } catch { return text; }
    if (m?.t === "sdp" && m.d?.sdp) m.d.sdp = await rewriteSdp(m.d.sdp);
    else if (m?.t === "ice" && m.c?.candidate) m.c.candidate = await rewriteCandidate(m.c.candidate);
    else return text;
    return JSON.stringify(m);
  });
  await page.addInitScript(PAGE_HOOK);

  return {
    stats: () => ({ ...totals, relays: relays.size }),
    // A new profile from now on (packets already in flight keep theirs).
    set: (q) => Object.assign(p, q),
    close: () => { for (const r of relays.values()) { r.closed = true; r.sock.close(); } },
  };
};
