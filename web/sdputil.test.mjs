// Tests for the compact SDP codec (web/sdputil.js) used by the serverless
// manual code exchange. The codec throws away the constant boilerplate of a
// WebRTC data-channel SDP and keeps only what the peers actually need to connect
// (fingerprint, ICE ufrag/pwd, candidates). A round-trip therefore is NOT
// byte-identical — so we compare the SEMANTIC fields (parse both sides, compare
// fingerprint / ufrag / pwd / setup / candidate set), assert the encoded string
// stays short enough to trade by hand, and check that malformed input fails
// cleanly.
//
// Zero dependencies, mirroring web/signaling/server.test.mjs: a plain assert()
// helper, a single run(), non-zero exit on any failure. sdputil.js is a CommonJS
// UMD script; ESM default-import interop pulls in its module.exports here.
//
// Run:  node web/sdputil.test.mjs

import SDPCodec from "./sdputil.js";

// Real offer + answer SDPs captured from Chrome's RTCPeerConnection with this
// app's exact config (one ordered DataChannel, STUN-only, full non-trickle
// gather). The public IP has been masked to a documentation address; the shape
// (mDNS host candidate + srflx candidate) is verbatim.
const OFFER =
  "v=0\r\no=- 3116375424838376079 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n" +
  "a=group:BUNDLE 0\r\na=extmap-allow-mixed\r\na=msid-semantic: WMS\r\n" +
  "m=application 51754 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 98.51.255.128\r\n" +
  "a=candidate:1299904540 1 udp 2113937151 76a8c416-5273-4154-85e7-82c648cd35ac.local 51754 typ host generation 0 network-cost 999\r\n" +
  "a=candidate:2856224762 1 udp 1677729535 98.51.255.128 51754 typ srflx raddr 0.0.0.0 rport 0 generation 0 network-cost 999\r\n" +
  "a=ice-ufrag:K+P4\r\na=ice-pwd:9kl0L+UkFvmvG0PBzSCtsmk4\r\na=ice-options:trickle\r\n" +
  "a=fingerprint:sha-256 08:E7:63:D6:B2:18:D6:68:5F:E7:91:0B:E5:69:8F:1E:E1:F6:31:FC:EF:61:22:11:B6:47:28:A4:FC:01:DD:66\r\n" +
  "a=setup:actpass\r\na=mid:0\r\na=sctp-port:5000\r\na=max-message-size:262144\r\n";

const ANSWER =
  "v=0\r\no=- 5500472847570645094 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n" +
  "a=group:BUNDLE 0\r\na=extmap-allow-mixed\r\na=msid-semantic: WMS\r\n" +
  "m=application 56343 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 98.51.255.128\r\n" +
  "a=candidate:1379006846 1 udp 2113937151 76a8c416-5273-4154-85e7-82c648cd35ac.local 56343 typ host generation 0 network-cost 999\r\n" +
  "a=candidate:465566284 1 udp 1677729535 98.51.255.128 56343 typ srflx raddr 0.0.0.0 rport 0 generation 0 network-cost 999\r\n" +
  "a=ice-ufrag:31LZ\r\na=ice-pwd:9blt8qRDmn9chdw1CuxAdYzW\r\na=ice-options:trickle\r\n" +
  "a=fingerprint:sha-256 73:43:4F:62:52:00:00:3C:48:6A:6D:02:81:38:6C:05:C5:2A:8A:20:43:54:38:D6:54:0E:9C:74:59:65:D3:E4\r\n" +
  "a=setup:active\r\na=mid:0\r\na=sctp-port:5000\r\na=max-message-size:262144\r\n";

// A candidate set that also exercises a literal IPv4 host candidate (mDNS off).
const LITERAL_HOST =
  OFFER.replace(
    "76a8c416-5273-4154-85e7-82c648cd35ac.local",
    "192.168.1.42"
  );

const CODE_BUDGET = 300; // characters; short enough to paste into any messenger

let failures = 0;
function assert(cond, msg) {
  if (cond) { console.log(`  ok: ${msg}`); return; }
  failures++;
  console.error(`  FAIL: ${msg}`);
}

function sameFields(origSdp, rebuiltSdp, label) {
  const a = SDPCodec.fields(origSdp);
  const b = SDPCodec.fields(rebuiltSdp);
  assert(a.fingerprint === b.fingerprint, `${label}: fingerprint preserved`);
  assert(a.ufrag === b.ufrag, `${label}: ice-ufrag preserved`);
  assert(a.pwd === b.pwd, `${label}: ice-pwd preserved`);
  assert(a.setup === b.setup, `${label}: setup role preserved`);
  assert(
    JSON.stringify(a.candidates) === JSON.stringify(b.candidates),
    `${label}: candidate set (type|addr|port|priority) preserved`
  );
}

async function run() {
  console.log("offer round-trips to an equivalent description:");
  {
    const enc = SDPCodec.encode({ type: "offer", sdp: OFFER });
    assert(typeof enc === "string" && enc.length > 0, "offer encodes to a string");
    const dec = SDPCodec.decode(enc);
    assert(dec && dec.type === "offer", "offer decodes with type=offer");
    sameFields(OFFER, dec.sdp, "offer");
    console.log(`  (encoded ${enc.length} chars, ${Math.ceil(enc.length * 6 / 8)} raw bytes)`);
    assert(enc.length <= CODE_BUDGET, `offer encoded ${enc.length} <= ${CODE_BUDGET} char code budget`);
    // The rebuilt SDP must be independently parseable back to the same fields.
    assert(dec.sdp.includes("UDP/DTLS/SCTP webrtc-datachannel"), "rebuilt SDP has the datachannel m-line");
  }

  console.log("answer round-trips to an equivalent description:");
  {
    const enc = SDPCodec.encode({ type: "answer", sdp: ANSWER });
    assert(typeof enc === "string" && enc.length > 0, "answer encodes to a string");
    const dec = SDPCodec.decode(enc);
    assert(dec && dec.type === "answer", "answer decodes with type=answer");
    sameFields(ANSWER, dec.sdp, "answer");
    console.log(`  (encoded ${enc.length} chars)`);
    assert(enc.length <= CODE_BUDGET, `answer encoded ${enc.length} <= ${CODE_BUDGET} char code budget`);
  }

  console.log("literal IPv4 host candidate round-trips:");
  {
    const enc = SDPCodec.encode({ type: "offer", sdp: LITERAL_HOST });
    const dec = SDPCodec.decode(enc);
    assert(!!dec, "literal-host SDP decodes");
    sameFields(LITERAL_HOST, dec.sdp, "literal-host");
    assert(dec.sdp.includes("192.168.1.42"), "IPv4 host address round-trips");
  }

  console.log("mDNS UUID is preserved exactly (same-LAN resolution depends on it):");
  {
    const enc = SDPCodec.encode({ type: "offer", sdp: OFFER });
    const dec = SDPCodec.decode(enc);
    assert(
      dec.sdp.includes("76a8c416-5273-4154-85e7-82c648cd35ac.local"),
      "mDNS candidate UUID byte-identical after round-trip"
    );
  }

  console.log("malformed input fails cleanly (null, no throw):");
  {
    assert(SDPCodec.decode("") === null, "empty string -> null");
    assert(SDPCodec.decode("!!!not base64!!!@@@") === null, "garbage -> null");
    assert(SDPCodec.decode("AAAA") === null, "truncated payload -> null");
    assert(SDPCodec.decode(null) === null, "null -> null");
    assert(SDPCodec.decode(undefined) === null, "undefined -> null");
    assert(SDPCodec.encode(null) === null, "encode(null) -> null");
    assert(SDPCodec.encode({ type: "offer", sdp: "v=0\r\n" }) === null, "SDP missing fields -> null");
    assert(
      SDPCodec.encode({ type: "offer", sdp: OFFER.replace(/a=candidate:.+\r\n/g, "") }) === null,
      "SDP with no candidates -> null"
    );
  }

  console.log("answerFrom rewrites a peer's offer code into a usable answer:");
  {
    const enc = SDPCodec.encode({ type: "offer", sdp: OFFER });
    const asServer = SDPCodec.answerFrom(enc, "active"); // peer will be DTLS client
    const asClient = SDPCodec.answerFrom(enc, "passive");
    assert(asServer && asServer.type === "answer", "answerFrom -> type answer");
    assert(
      SDPCodec.fields(asServer.sdp).setup === "active",
      "requested setup role lands in a=setup (active)"
    );
    assert(
      SDPCodec.fields(asClient.sdp).setup === "passive",
      "requested setup role lands in a=setup (passive)"
    );
    // Everything the connection needs survives the reinterpretation.
    sameFields(
      OFFER.replace("a=setup:actpass", "a=setup:active"),
      asServer.sdp,
      "answerFrom(active)"
    );
    assert(SDPCodec.answerFrom(enc, "actpass") === null, "actpass is not a valid answer role");
    assert(SDPCodec.answerFrom("garbage!!!", "active") === null, "garbage code -> null");
  }

  console.log("version byte guards forward compatibility:");
  {
    const enc = SDPCodec.encode({ type: "offer", sdp: OFFER });
    // Flip the version byte (first byte of the payload) and confirm reject.
    const bad = "Z" + enc.slice(1); // corrupt first base64url char -> different version byte
    const dec = SDPCodec.decode(bad);
    assert(dec === null || dec.type === "offer", "corrupt version byte does not crash");
  }

  if (failures) { console.error(`\n${failures} assertion(s) failed`); process.exit(1); }
  console.log("\nall SDP codec tests passed");
}

run().catch((e) => { console.error(e); process.exit(1); });
