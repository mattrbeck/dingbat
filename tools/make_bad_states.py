#!/usr/bin/env python3
"""Deliberately corrupted save states, one per refusal cause.

Makes one file per StateRejectKind from a known-good .state, so every
refusal message the UI can show is reachable by hand.

    nimble statefuzz_build
    ./statefuzz web/goodboy-demo-en.gba dump /tmp/good.state 600
    python3 tools/make_bad_states.py /tmp/good.state /tmp/bad
    for f in /tmp/bad/*.state; do
        ./statefuzz web/goodboy-demo-en.gba reject "$f"
    done

`wildbus` and `wildsched` re-seal the FNV payload hash (an integrity check,
not a security control) so they get past the header and reach the field
readers' range guards.
"""
import os
import struct
import sys

HEADER = 32


def fnv1a(data: bytes) -> int:
    h = 0x811C9DC5
    for b in data:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def reseal(buf: bytearray) -> bytes:
    """Recompute payload_len and payload_hash so the header still validates."""
    buf[24:28] = struct.pack("<I", len(buf) - HEADER)
    buf[28:32] = struct.pack("<I", fnv1a(bytes(buf[HEADER:])))
    return bytes(buf)


def variants(src: bytes):
    """(name, bytes, which StateRejectKind it should produce)."""
    def edit(fn):
        b = bytearray(src)
        fn(b)
        return bytes(b)

    yield ("notastate", b"PK\x03\x04not a save state at all", "srkNotAState")
    yield ("wrongcore", edit(lambda b: b.__setitem__(12, 1 - b[12])), "srkWrongCore")
    yield ("wrongrom", edit(lambda b: b.__setitem__(16, b[16] ^ 0xFF)), "srkWrongRom")
    yield ("toonew", edit(lambda b: b.__setitem__(8, 99)), "srkTooNew")
    yield ("truncated", src[: len(src) // 2], "srkTruncated")
    yield ("corrupt",
           edit(lambda b: b.__setitem__(HEADER + 100, b[HEADER + 100] ^ 0xFF)),
           "srkCorrupt (payload hash)")

    # Resealed, so they reach the per-field readers. GBA offsets.
    b = bytearray(src)
    b[HEADER + 298] = 0xFF                       # bus.cycles, high byte
    yield ("wildbus", reseal(b), "srkCorrupt (bus.cycles out of range)")

    b = bytearray(src)
    for off in (295239, 295240, 295241):         # scheduler.cycles, high bytes
        b[HEADER + off] = 0xFF
    yield ("wildsched", reseal(b), "srkCorrupt (event deadline implausible)")


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src = open(sys.argv[1], "rb").read()
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    if len(src) < 300000:
        print("note: the wildsched offsets are GBA-specific; this looks like a "
              "GB state, so that one will land somewhere harmless")
    for name, data, expect in variants(src):
        path = os.path.join(out, name + ".state")
        open(path, "wb").write(data)
        print(f"  {name:12s} {len(data):8d} B   expect {expect}")
    print(f"\nwrote {out}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
