// Tests for the self-contained QR encoder (web/qr.js). Since the repo carries no
// QR *decoder*, correctness is pinned two ways:
//   1) A golden matrix: QR.encode("HELLO", mask=2) must reproduce, cell for cell,
//      the output of the reference MIT encoder `qrcode-generator` for the same
//      input/version/mask (captured once, embedded here). A single wrong module
//      in data placement, Reed-Solomon EC, masking, or format info shifts this.
//   2) Structural invariants (finder patterns, timing, size, version selection)
//      and clean failure when data exceeds a version-40 symbol.
// The encoder was additionally cross-checked in-browser: its output decodes back
// to the original string through the native BarcodeDetector and through jsQR
// (both confirmed during development on real base64url SDP payloads).
//
// Zero dependencies, mirroring web/signaling/server.test.mjs. Run:
//   node web/qr.test.mjs

import QR from "./qr.js";

// Golden: qrcode-generator@1.4.4 encode of "HELLO", level M, mask 2, version 1.
// Rows top-to-bottom, '1' = dark module.
const GOLDEN_HELLO_MASK2 = [
  "111111100001001111111", "100000100010101000001", "101110101100001011101",
  "101110101010101011101", "101110101100101011101", "100000101111001000001",
  "111111101010101111111", "000000001100000000000", "101111100011001111100",
  "011011010111111001100", "001111101000101101110", "011010000111111001100",
  "010111111000100100101", "000000001010100101000", "111111100111010010110",
  "100000101010000111110", "101110101101010010110", "101110101101111101000",
  "101110101100101100100", "100000100111111011100", "111111101100100010110",
];

let failures = 0;
function assert(cond, msg) {
  if (cond) { console.log(`  ok: ${msg}`); return; }
  failures++;
  console.error(`  FAIL: ${msg}`);
}

function matrixToRows(q) {
  return q.modules.map((row) => row.map((v) => (v ? "1" : "0")).join(""));
}

async function run() {
  console.log("golden matrix (matches reference qrcode-generator, mask 2):");
  {
    const q = QR.encode("HELLO", 2);
    assert(q.size === 21 && q.version === 1, "HELLO -> version 1, 21x21");
    const rows = matrixToRows(q);
    let diffs = 0;
    for (let y = 0; y < 21; y++) if (rows[y] !== GOLDEN_HELLO_MASK2[y]) diffs++;
    assert(diffs === 0, `every module matches the golden (${diffs} row diffs)`);
  }

  console.log("finder / timing / dark structure:");
  {
    const q = QR.encode("hello world", 0);
    const m = q.modules, n = q.size;
    const finderOK = (ox, oy) => m[oy][ox] && m[oy][ox + 6] && m[oy + 6][ox] &&
      m[oy + 2][ox + 2] && m[oy + 3][ox + 3] && m[oy + 4][ox + 4] && !m[oy + 1][ox + 1];
    assert(finderOK(0, 0), "top-left finder well-formed");
    assert(finderOK(n - 7, 0), "top-right finder well-formed");
    assert(finderOK(0, n - 7), "bottom-left finder well-formed");
    // Timing pattern alternates on row/col 6.
    let timingOK = true;
    for (let i = 8; i < n - 8; i++) if (m[6][i] !== (i % 2 === 0)) timingOK = false;
    assert(timingOK, "horizontal timing pattern alternates");
    assert(m[n - 8][8] === true, "fixed dark module present");
  }

  console.log("version auto-selection scales with data length:");
  {
    assert(QR.encode("x".repeat(10)).version === 1, "10 bytes fits version 1");
    assert(QR.encode("x".repeat(20)).version === 2, "20 bytes needs version 2");
    const big = QR.encode("x".repeat(132));
    assert(big.version >= 6 && big.version <= 10, `132-byte payload picks a mid version (got ${big.version})`);
    assert(big.size === big.version * 4 + 17, "size = version*4+17");
  }

  console.log("mask selection stays in range and matrix is square/boolean:");
  {
    const q = QR.encode("a compact pairing string like the SDP codec emits");
    assert(q.mask >= 0 && q.mask < 8, `auto mask in [0,8) (got ${q.mask})`);
    assert(q.modules.length === q.size && q.modules.every((r) => r.length === q.size), "matrix is square");
    assert(q.modules.every((r) => r.every((v) => typeof v === "boolean")), "all modules boolean");
  }

  console.log("oversized data fails cleanly:");
  {
    let threw = false;
    try { QR.encode("z".repeat(3000)); } catch { threw = true; }
    assert(threw, "data too large throws (does not silently truncate)");
  }

  if (failures) { console.error(`\n${failures} assertion(s) failed`); process.exit(1); }
  console.log("\nall QR encoder tests passed");
}

run().catch((e) => { console.error(e); process.exit(1); });
