// --- Compact SDP codec for the manual code exchange (serverless WebRTC) ---
// The normal online path (netplay.js) trickles ICE candidates through the
// signaling server one at a time, so a full SDP never has to fit anywhere small.
// The manual fallback (server unreachable) has NO server: the whole description
// travels as a copy-pasted string. A raw WebRTC data-channel SDP is ~600–900
// bytes of mostly-boilerplate — too big and unwieldy to trade by hand.
//
// This codec throws away everything that is CONSTANT for this app's single fixed
// configuration (one ordered DataChannel, DTLS/SCTP, no media) and keeps only the
// parts that actually differ between peers:
//   - the DTLS setup role (actpass / active / passive)
//   - the SHA-256 certificate fingerprint (32 bytes)
//   - the ICE ufrag + pwd (the shared-secret credentials)
//   - the udp ICE candidates (host mDNS + server-reflexive), each as
//     type + priority + port + address
// decode() rebuilds a VALID SDP from a fixed template plus those fields. The
// reconstruction is not byte-identical to the original (foundations, the o= line
// session id, and the m=/c= placeholder ports are regenerated) but it is
// SEMANTICALLY equivalent: same fingerprint, same credentials, same candidates —
// which is all WebRTC needs to establish the connection.
//
// Wire format (then base64url-encoded, no padding):
//   u8   version (1)
//   u8   flags:  bits0-1 setup role (0 actpass, 1 active, 2 passive)
//                bit2    kind (0 offer, 1 answer) — informational
//   u8   ufrag length, then ufrag bytes (ASCII)
//   u8   pwd   length, then pwd   bytes (ASCII)
//   32B  sha-256 fingerprint (raw bytes)
//   u8   candidate count
//   per candidate:
//     u8    bits0-1 addr kind (0 IPv4, 1 IPv6, 2 mDNS-UUID, 3 hostname)
//           bits2-3 cand type (0 host, 1 srflx, 2 prflx, 3 relay)
//     u32BE priority
//     u16BE port
//     addr: IPv4 = 4 bytes, IPv6 = 16 bytes, mDNS = 16-byte UUID,
//           hostname = u8 length + UTF-8 bytes
//
// Loads as a plain classic script in the browser (sets window.SDPCodec) and as a
// CommonJS module under Node for the unit tests (module.exports = SDPCodec).

(function (root) {
  "use strict";

  const VERSION = 1;
  const SETUP = { actpass: 0, active: 1, passive: 2 };
  const SETUP_NAME = ["actpass", "active", "passive"];
  const CTYPE = { host: 0, srflx: 1, prflx: 2, relay: 3 };
  const CTYPE_NAME = ["host", "srflx", "prflx", "relay"];
  const A_V4 = 0, A_V6 = 1, A_MDNS = 2, A_HOST = 3;

  // ---- tiny growable byte writer / reader -------------------------------
  class Writer {
    constructor() { this.b = []; }
    u8(v) { this.b.push(v & 0xff); }
    u16(v) { this.b.push((v >>> 8) & 0xff, v & 0xff); }
    u32(v) { this.b.push((v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff); }
    bytes(arr) { for (let i = 0; i < arr.length; i++) this.b.push(arr[i] & 0xff); }
    str(s) { const e = strBytes(s); this.u8(e.length); this.bytes(e); }
    out() { return Uint8Array.from(this.b); }
  }
  class Reader {
    constructor(u8) { this.d = u8; this.i = 0; }
    left() { return this.d.length - this.i; }
    u8() { if (this.i >= this.d.length) throw new Error("eof"); return this.d[this.i++]; }
    u16() { return (this.u8() << 8) | this.u8(); }
    u32() { return ((this.u8() << 24) | (this.u8() << 16) | (this.u8() << 8) | this.u8()) >>> 0; }
    bytes(n) { if (this.i + n > this.d.length) throw new Error("eof"); const s = this.d.subarray(this.i, this.i + n); this.i += n; return s; }
    str() { const n = this.u8(); return bytesStr(this.bytes(n)); }
  }

  const strBytes = (s) => {
    if (typeof TextEncoder !== "undefined") return new TextEncoder().encode(s);
    const out = []; for (let i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 0xff); return Uint8Array.from(out);
  };
  const bytesStr = (u8) => {
    if (typeof TextDecoder !== "undefined") return new TextDecoder().decode(u8);
    let s = ""; for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]); return s;
  };

  // ---- base64url (no padding) -------------------------------------------
  const b64urlEncode = (u8) => {
    let bin = "";
    for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
    let b64;
    if (typeof btoa !== "undefined") b64 = btoa(bin);
    else b64 = Buffer.from(u8).toString("base64");
    return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };
  const b64urlDecode = (s) => {
    const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
    let bin;
    if (typeof atob !== "undefined") {
      // atob tolerates missing padding in practice, but pad to be safe.
      const pad = b64.length % 4 ? "=".repeat(4 - (b64.length % 4)) : "";
      bin = atob(b64 + pad);
    } else {
      return new Uint8Array(Buffer.from(b64, "base64"));
    }
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  };

  // ---- SDP field extraction ---------------------------------------------
  const firstMatch = (sdp, re) => { const m = sdp.match(re); return m ? m[1] : null; };

  // Parse "AB:CD:..:66" hex-colon fingerprint into raw bytes.
  const fpToBytes = (hex) => {
    const parts = hex.trim().split(":");
    const out = new Uint8Array(parts.length);
    for (let i = 0; i < parts.length; i++) {
      const v = parseInt(parts[i], 16);
      if (Number.isNaN(v)) throw new Error("bad fingerprint");
      out[i] = v;
    }
    return out;
  };
  const bytesToFp = (u8) => {
    const out = [];
    for (let i = 0; i < u8.length; i++) out.push(u8[i].toString(16).toUpperCase().padStart(2, "0"));
    return out.join(":");
  };

  const isMdns = (host) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.local$/i.test(host);
  const isV4 = (h) => /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.test(h);
  const isV6 = (h) => h.includes(":");

  const uuidToBytes = (host) => {
    const hex = host.split(".")[0].replace(/-/g, "");
    const out = new Uint8Array(16);
    for (let i = 0; i < 16; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
    return out;
  };
  const bytesToUuid = (u8) => {
    const h = [];
    for (let i = 0; i < 16; i++) h.push(u8[i].toString(16).padStart(2, "0"));
    const s = h.join("");
    return `${s.substr(0, 8)}-${s.substr(8, 4)}-${s.substr(12, 4)}-${s.substr(16, 4)}-${s.substr(20, 12)}.local`;
  };
  const v4ToBytes = (h) => Uint8Array.from(h.split(".").map((x) => parseInt(x, 10) & 0xff));
  const bytesToV4 = (u8) => `${u8[0]}.${u8[1]}.${u8[2]}.${u8[3]}`;
  const v6ToBytes = (h) => {
    // Expand :: and per-group into 16 bytes.
    let head, tail;
    if (h.includes("::")) {
      const [a, b] = h.split("::");
      head = a ? a.split(":") : [];
      tail = b ? b.split(":") : [];
    } else { head = h.split(":"); tail = []; }
    const mid = new Array(8 - head.length - tail.length).fill("0");
    const groups = head.concat(mid, tail).map((g) => parseInt(g || "0", 16));
    const out = new Uint8Array(16);
    for (let i = 0; i < 8; i++) { out[i * 2] = (groups[i] >>> 8) & 0xff; out[i * 2 + 1] = groups[i] & 0xff; }
    return out;
  };
  const bytesToV6 = (u8) => {
    const groups = [];
    for (let i = 0; i < 8; i++) groups.push(((u8[i * 2] << 8) | u8[i * 2 + 1]).toString(16));
    return groups.join(":"); // uncompressed but valid
  };

  // Parse a single "a=candidate:..." line body (everything after "candidate:").
  // Returns null for candidates we don't carry (non-udp, or unparseable).
  const parseCandidate = (body) => {
    // foundation component transport priority address port typ TYPE ...
    const t = body.trim().split(/\s+/);
    if (t.length < 8) return null;
    const transport = t[2].toLowerCase();
    if (transport !== "udp") return null; // same-LAN pairing only needs udp
    const priority = parseInt(t[3], 10) >>> 0;
    const address = t[4];
    const port = parseInt(t[5], 10) & 0xffff;
    if (t[6] !== "typ") return null;
    const type = t[7];
    if (!(type in CTYPE)) return null;
    return { type, priority, address, port };
  };

  // ------------------------------ encode ---------------------------------
  // desc: an RTCSessionDescription-like { type, sdp }. Returns a base64url
  // string, or null if the SDP lacks the fields WebRTC needs.
  function encode(desc) {
    try {
      if (!desc || !desc.sdp) return null;
      const sdp = desc.sdp;
      const ufrag = firstMatch(sdp, /a=ice-ufrag:(\S+)/);
      const pwd = firstMatch(sdp, /a=ice-pwd:(\S+)/);
      const fp = firstMatch(sdp, /a=fingerprint:sha-256 ([0-9A-Fa-f:]+)/);
      const setup = firstMatch(sdp, /a=setup:(\S+)/) || "actpass";
      if (!ufrag || !pwd || !fp) return null;
      if (ufrag.length > 255 || pwd.length > 255) return null;

      const cands = [];
      const re = /a=candidate:(.+)/g;
      let m;
      while ((m = re.exec(sdp))) {
        const c = parseCandidate(m[1]);
        if (c) cands.push(c);
      }
      if (cands.length === 0) return null; // nothing to connect with
      if (cands.length > 255) cands.length = 255;

      const kind = (desc.type === "answer") ? 1 : 0;
      const setupCode = SETUP[setup] != null ? SETUP[setup] : 0;

      const w = new Writer();
      w.u8(VERSION);
      w.u8((setupCode & 0x03) | (kind << 2));
      w.str(ufrag);
      w.str(pwd);
      w.bytes(fpToBytes(fp)); // 32 bytes for sha-256
      w.u8(cands.length);
      for (const c of cands) {
        let addrKind, addrBytes = null, hostStr = null;
        if (isMdns(c.address)) { addrKind = A_MDNS; addrBytes = uuidToBytes(c.address); }
        else if (isV4(c.address)) { addrKind = A_V4; addrBytes = v4ToBytes(c.address); }
        else if (isV6(c.address)) { addrKind = A_V6; addrBytes = v6ToBytes(c.address); }
        else { addrKind = A_HOST; hostStr = c.address; }
        w.u8((addrKind & 0x03) | ((CTYPE[c.type] & 0x03) << 2));
        w.u32(c.priority);
        w.u16(c.port);
        if (addrKind === A_HOST) w.str(hostStr);
        else w.bytes(addrBytes);
      }
      return b64urlEncode(w.out());
    } catch {
      return null;
    }
  }

  // ------------------------------ decode ---------------------------------
  // str: a base64url string from encode(). Returns { type, sdp } or null.
  function decode(str) {
    try {
      if (typeof str !== "string" || str.length === 0) return null;
      const r = new Reader(b64urlDecode(str.trim()));
      const ver = r.u8();
      if (ver !== VERSION) return null;
      const flags = r.u8();
      const setup = SETUP_NAME[flags & 0x03] || "actpass";
      const kind = (flags >> 2) & 0x01 ? "answer" : "offer";
      const ufrag = r.str();
      const pwd = r.str();
      const fp = bytesToFp(r.bytes(32));
      const nc = r.u8();
      const candLines = [];
      for (let i = 0; i < nc; i++) {
        const cb = r.u8();
        const addrKind = cb & 0x03;
        const ctype = CTYPE_NAME[(cb >> 2) & 0x03];
        const priority = r.u32();
        const port = r.u16();
        let addr;
        if (addrKind === A_V4) addr = bytesToV4(r.bytes(4));
        else if (addrKind === A_V6) addr = bytesToV6(r.bytes(16));
        else if (addrKind === A_MDNS) addr = bytesToUuid(r.bytes(16));
        else addr = r.str();
        // Foundation is regenerated (the remote never needs it to match); use a
        // stable per-index value. srflx/relay carry a template raddr/rport.
        const rel = (ctype === "srflx" || ctype === "relay") ? " raddr 0.0.0.0 rport 0" : "";
        candLines.push(
          `a=candidate:${i + 1} 1 udp ${priority} ${addr} ${port} typ ${ctype}${rel} generation 0`
        );
      }
      if (!ufrag || !pwd || candLines.length === 0) return null;

      // Fixed session id: constant is fine, the remote doesn't correlate it.
      const sdp =
        "v=0\r\n" +
        "o=- 4611686018427387904 2 IN IP4 127.0.0.1\r\n" +
        "s=-\r\n" +
        "t=0 0\r\n" +
        "a=group:BUNDLE 0\r\n" +
        "a=extmap-allow-mixed\r\n" +
        "a=msid-semantic: WMS\r\n" +
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" +
        "c=IN IP4 0.0.0.0\r\n" +
        candLines.map((l) => l + "\r\n").join("") +
        "a=ice-ufrag:" + ufrag + "\r\n" +
        "a=ice-pwd:" + pwd + "\r\n" +
        "a=ice-options:trickle\r\n" +
        "a=fingerprint:sha-256 " + fp + "\r\n" +
        "a=setup:" + setup + "\r\n" +
        "a=mid:0\r\n" +
        "a=sctp-port:5000\r\n" +
        "a=max-message-size:262144\r\n";
      return { type: kind, sdp };
    } catch {
      return null;
    }
  }

  // Reinterpret a peer's encoded OFFER as the ANSWER to our own local offer.
  //
  // The manual code exchange is SYMMETRIC: both sides independently create an
  // offer, encode it, and hand the string to the other side (no server, no
  // second round trip). Standard WebRTC can't take two offers — so each side
  // locally rewrites the peer's blob into a valid answer: same fingerprint,
  // same ICE credentials, same candidates (which is everything the connection
  // actually needs), but type "answer" and a concrete DTLS role in a=setup.
  // The roles must complement each other, so the caller picks `setup` from a
  // deterministic comparison both sides can compute (e.g. of the two code
  // strings): the side that will be the DTLS server passes "active" (the PEER
  // acts as client), the other passes "passive". Both peers having created
  // data channels and both ICE agents starting out "controlling" is fine: ICE
  // role conflicts resolve via the RFC 8445 tie-breaker, and DCEP stream ids
  // are role-partitioned (client even / server odd) so the channels can't
  // collide. Verified end-to-end in web/manualpair.test.mjs.
  function answerFrom(code, setup) {
    if (setup !== "active" && setup !== "passive") return null;
    const d = decode(code);
    if (!d) return null;
    return { type: "answer", sdp: d.sdp.replace(/a=setup:\S+/, "a=setup:" + setup) };
  }

  // Parse the semantic fields back out of an SDP, for tests / comparison.
  function fields(sdp) {
    const cands = [];
    const re = /a=candidate:(.+)/g;
    let m;
    while ((m = re.exec(sdp))) { const c = parseCandidate(m[1]); if (c) cands.push(c); }
    return {
      ufrag: firstMatch(sdp, /a=ice-ufrag:(\S+)/),
      pwd: firstMatch(sdp, /a=ice-pwd:(\S+)/),
      fingerprint: firstMatch(sdp, /a=fingerprint:sha-256 ([0-9A-Fa-f:]+)/),
      setup: firstMatch(sdp, /a=setup:(\S+)/),
      candidates: cands
        .map((c) => `${c.type}|${c.address}|${c.port}|${c.priority}`)
        .sort(),
    };
  }

  const SDPCodec = { encode, decode, answerFrom, fields, VERSION };
  root.SDPCodec = SDPCodec;
  if (typeof module !== "undefined" && module.exports) module.exports = SDPCodec;
})(typeof window !== "undefined" ? window : globalThis);
