#!/usr/bin/env python3
"""Structural locator/patcher for the MP2K ("Sappy" / M4A) song table in a GBA ROM.

Nothing here is derived from a game's source, a decompilation, or another
emulator: the scanner only knows the *shape* of the structures and reads the
bytes of whatever ROM it is handed.  Background reference:

    loveemu, "Summary of GBA Standard Sound Driver MusicPlayer2000"
    https://loveemu.github.io/vgmdocs/Summary_of_GBA_Standard_Sound_Driver_MusicPlayer2000.html

from which we take the sequence-command byte ranges (0x80..0xB0 wait,
0xB1..0xCE control, 0xD0..0xFF note) used only for the human-readable dump,
and GBATEK for the cartridge address space (ROM is mirrored at 0x08000000).

Structures the scanner assumes (interface facts, not copied code):

    song table entry (8 bytes, 4-byte aligned, contiguous run):
        u32 songHeader    ROM pointer, 0x08000000-based, 4-byte aligned
        u16 playerIndex   small
        u16 playerIndex   small (usually equal to the first)

    SongHeader:
        u8  trackCount    0..16   (0 == empty / "stop" song)
        u8  blockCount
        u8  priority
        u8  reverb
        u32 voicegroup    ROM pointer, 4-byte aligned
        u32 track[trackCount]   ROM pointers into byte-code streams

The table is found by looking for the longest contiguous run of entries whose
headers all pass that plausibility test.
"""

from __future__ import annotations

import argparse
import re
import struct
import sys
from typing import Dict, List, Optional, Tuple

ROM_BASE = 0x08000000
ENTRY_SIZE = 8
HEADER_FIXED = 8          # trackCount/blockCount/priority/reverb + voicegroup
MAX_TRACKS = 16
MAX_PLAYER = 256          # player indices are small: Minish Cap reaches 31

# A seed is any byte position where two consecutive 8-byte entries have the
# right *silhouette*: a pointer whose high byte is 0x08 or 0x09 (GBATEK: the
# cartridge window is 0x08000000..0x09FFFFFF, so a ROM past 16 MB carries 0x09
# pointers too), and two u16 player indices below 256 (so bytes +5 and +7 of
# each entry are zero).  The lookahead is zero-width so re.finditer steps one
# byte at a time and cannot swallow a later, better aligned match.  This is the
# only pass that touches all 32 MB, and it runs at C speed.
_SEED_ENTRY = rb"...[\x08\x09].\x00.\x00"
_SEED_RE = re.compile(rb"(?=(?:" + _SEED_ENTRY + rb"){2})", re.DOTALL)


# --------------------------------------------------------------------------
# low-level helpers
# --------------------------------------------------------------------------

def _u32(rom: bytes, off: int) -> int:
    return struct.unpack_from("<I", rom, off)[0]


def _u16(rom: bytes, off: int) -> int:
    return struct.unpack_from("<H", rom, off)[0]


def rom_offset(rom_len: int, addr: int, align: int = 4) -> Optional[int]:
    """ROM address -> file offset, or None if it is not a usable ROM pointer."""
    if addr < ROM_BASE or addr >= ROM_BASE + rom_len:
        return None
    if align and (addr % align):
        return None
    return addr - ROM_BASE


class Entry:
    """One validated (or rejected) song-table entry."""

    __slots__ = ("offset", "header_addr", "player", "player2", "track_count",
                 "block_count", "priority", "reverb", "voicegroup", "tracks",
                 "ok", "empty")

    def __init__(self, offset: int) -> None:
        self.offset = offset
        self.header_addr = 0
        self.player = self.player2 = 0
        self.track_count = self.block_count = self.priority = self.reverb = 0
        self.voicegroup = 0
        self.tracks: List[int] = []
        self.ok = False
        self.empty = False


def parse_entry(rom: bytes, off: int) -> Entry:
    """Validate the entry at file offset `off`.  Never raises."""
    e = Entry(off)
    n = len(rom)
    if off < 0 or off + ENTRY_SIZE > n or (off & 3):
        return e

    e.header_addr = _u32(rom, off)
    e.player = _u16(rom, off + 4)
    e.player2 = _u16(rom, off + 6)
    if e.player >= MAX_PLAYER or e.player2 >= MAX_PLAYER:
        return e

    h = rom_offset(n, e.header_addr, align=4)
    if h is None or h + HEADER_FIXED > n:
        return e

    e.track_count = rom[h]
    e.block_count = rom[h + 1]
    e.priority = rom[h + 2]
    e.reverb = rom[h + 3]
    e.voicegroup = _u32(rom, h + 4)
    if e.track_count > MAX_TRACKS:
        return e

    if e.track_count == 0:
        # An empty / "stop" song: no tracks, so nothing else in the header is
        # ever dereferenced and its voicegroup word may be anything at all
        # (observed: 0, and a non-ROM constant in Kirby).  Many entries of a
        # real table share one such header, so the entry is accepted on the
        # strength of the pointer plus the two small player indices alone;
        # `scan` still insists a candidate run contain real songs.
        e.ok = True
        e.empty = True
        return e

    if rom_offset(n, e.voicegroup, align=4) is None:
        return e
    if h + HEADER_FIXED + 4 * e.track_count > n:
        return e
    for i in range(e.track_count):
        t = _u32(rom, h + HEADER_FIXED + 4 * i)
        # track streams are byte-aligned, so only the range is checked
        if rom_offset(n, t, align=1) is None:
            return e
        e.tracks.append(t)
    e.ok = True
    return e


# --------------------------------------------------------------------------
# scanning
# --------------------------------------------------------------------------

def _extend(rom: bytes, seed: int, max_gap: int,
            cache: Dict[int, Entry]) -> Tuple[int, List[Entry]]:
    """Grow a run of entries out of `seed` in both directions."""

    def get(o: int) -> Entry:
        e = cache.get(o)
        if e is None:
            e = parse_entry(rom, o)
            cache[o] = e
        return e

    if not get(seed).ok:
        return seed, []

    # backwards
    start = seed
    gap = 0
    o = seed - ENTRY_SIZE
    while o >= 0:
        if get(o).ok:
            start = o
            gap = 0
        else:
            gap += 1
            if gap > max_gap:
                break
        o -= ENTRY_SIZE

    # forwards, then trim any trailing rejects the gap tolerance let through
    entries: List[Entry] = []
    o = start
    gap = 0
    while o + ENTRY_SIZE <= len(rom):
        e = get(o)
        if e.ok:
            gap = 0
        else:
            gap += 1
            if gap > max_gap:
                break
        entries.append(e)
        o += ENTRY_SIZE
    while entries and not entries[-1].ok:
        entries.pop()
    return start, entries


def scan(rom_bytes: bytes, min_count: int = 8, max_gap: int = 1,
         min_songs: int = 4) -> List[dict]:
    """Find candidate song tables.  Returns dicts sorted best-first.

    Each candidate: offset, addr, count, valid, empty, strong, bad,
    voicegroups (distinct voicegroup addresses among its entries),
    top_voicegroup (address, share) and `entries`.
    """
    rom = rom_bytes
    cache: Dict[int, Entry] = {}
    seen_runs: Dict[int, dict] = {}
    covered_until = -1

    for m in _SEED_RE.finditer(rom):
        off = m.start()
        if off & 3:
            continue
        if off < covered_until:
            continue
        start, entries = _extend(rom, off, max_gap, cache)
        if len(entries) < min_count:
            continue
        end = start + ENTRY_SIZE * len(entries)
        covered_until = max(covered_until, end)
        if start in seen_runs:
            continue

        good = [e for e in entries if e.ok]
        strong = [e for e in good if not e.empty]
        if len(strong) < min_songs:
            # A run of nothing but empty songs is not a song table.
            continue
        vgs: Dict[int, int] = {}
        for e in strong:
            vgs[e.voicegroup] = vgs.get(e.voicegroup, 0) + 1
        top = max(vgs.items(), key=lambda kv: kv[1]) if vgs else (0, 0)
        seen_runs[start] = {
            "offset": start,
            "addr": ROM_BASE + start,
            "count": len(entries),
            "valid": len(good),
            "strong": len(strong),
            "empty": len(good) - len(strong),
            "bad": len(entries) - len(good),
            "voicegroups": len(vgs),
            "top_voicegroup": top[0],
            "top_voicegroup_share": (top[1] / len(strong)) if strong else 0.0,
            "entries": entries,
        }

    cands = list(seen_runs.values())
    # Tie-break: most entries, then most non-empty entries, then lowest offset.
    cands.sort(key=lambda c: (-c["count"], -c["strong"], c["offset"]))
    return cands


# --------------------------------------------------------------------------
# patching
# --------------------------------------------------------------------------

def patch(rom_bytes: bytes, table_offset: int, count: int,
          new_header_addr: int) -> bytes:
    """Point every entry of the table at `new_header_addr` (ROM address)."""
    out = bytearray(rom_bytes)
    end = table_offset + ENTRY_SIZE * count
    if table_offset < 0 or end > len(out):
        raise ValueError("table (%d entries at 0x%X) runs past the ROM end"
                         % (count, table_offset))
    if new_header_addr < ROM_BASE or new_header_addr % 4:
        raise ValueError("header address 0x%08X is not a 4-aligned ROM address"
                         % new_header_addr)
    packed = struct.pack("<I", new_header_addr)
    for i in range(count):
        o = table_offset + ENTRY_SIZE * i
        out[o:o + 4] = packed          # player indices at +4..+7 are kept
    return bytes(out)


def extend_rom(rom_bytes: bytes, mbytes: float) -> bytes:
    """Pad a ROM copy with 0xFF up to `mbytes` MiB (unmapped cart reads as
    open bus; 0xFF is the conventional blank-flash filler)."""
    target = int(mbytes * 1024 * 1024)
    if target <= len(rom_bytes):
        return bytes(rom_bytes)
    return bytes(rom_bytes) + b"\xFF" * (target - len(rom_bytes))


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

def _cmd_kind(b: int) -> str:
    """Classify a sequence byte per the loveemu summary's ranges."""
    if b < 0x80:
        return "arg"
    if b <= 0xB0:
        return "wait"
    if b <= 0xCE:
        return "ctrl"
    if b == 0xCF:
        return "tie"
    return "note"


def describe(rom_bytes: bytes, table_offset: int, count: int,
             limit: int = 8, out=sys.stdout) -> None:
    """Print the first `limit` entries for eyeballing."""
    rom = rom_bytes
    n = min(count, limit)
    print("  idx  entry@       header      trk blk pri rev  voicegroup   "
          "track0 bytes", file=out)
    for i in range(n):
        off = table_offset + ENTRY_SIZE * i
        e = parse_entry(rom, off)
        if not e.ok:
            print("  %3d  0x%06X   <rejected: 0x%08X>" % (i, off, _u32(rom, off)),
                  file=out)
            continue
        if e.track_count == 0:
            print("  %3d  0x%06X   0x%08X   0   -  %3d %3d  0x%08X   (empty song)"
                  % (i, off, e.header_addr, e.priority, e.reverb, e.voicegroup),
                  file=out)
            continue
        t0 = rom_offset(len(rom), e.tracks[0], align=1)
        raw = rom[t0:t0 + 8]
        kinds = " ".join("%02X(%s)" % (b, _cmd_kind(b)) for b in raw[:4])
        print("  %3d  0x%06X   0x%08X  %2d %3d  %3d %3d  0x%08X   0x%08X: %s"
              % (i, off, e.header_addr, e.track_count, e.block_count,
                 e.priority, e.reverb, e.voicegroup, e.tracks[0], kinds),
              file=out)


def _report(cand: dict, out=sys.stdout) -> None:
    print("  offset 0x%06X  addr 0x%08X  entries %d "
          "(non-empty %d, empty %d, rejected %d)"
          % (cand["offset"], cand["addr"], cand["count"], cand["strong"],
             cand["empty"], cand["bad"]), file=out)
    print("  distinct voicegroups %d; most common 0x%08X used by %.0f%% of songs"
          % (cand["voicegroups"], cand["top_voicegroup"],
             100.0 * cand["top_voicegroup_share"]), file=out)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description="Locate (and optionally repoint) the MP2K song table of a "
                    "GBA ROM by structural scanning.")
    ap.add_argument("rom")
    ap.add_argument("--patch", metavar="HEADER_ADDR",
                    help="repoint every entry at this ROM address (hex, "
                         "e.g. 0x09000000); requires --out")
    ap.add_argument("--out", metavar="PATH", help="where to write the ROM copy")
    ap.add_argument("--extend", metavar="MBYTES", type=float,
                    help="pad the ROM copy with 0xFF up to this many MiB")
    ap.add_argument("--table", metavar="OFF",
                    help="override the table file offset (hex)")
    ap.add_argument("--count", type=int, help="override the entry count")
    ap.add_argument("--limit", type=int, default=8,
                    help="entries to describe (default 8)")
    ap.add_argument("--all", action="store_true",
                    help="list every candidate run, not just the best")
    ap.add_argument("--min-count", type=int, default=8,
                    help="shortest run to consider a candidate (default 8)")
    args = ap.parse_args(argv)
    if (args.patch or args.extend) and not args.out:
        ap.error("--patch/--extend need --out")

    with open(args.rom, "rb") as f:
        rom = f.read()
    print("%s  (%d bytes, %.1f MiB)" % (args.rom, len(rom), len(rom) / 1048576.0))

    if args.table is not None:
        table_off = int(args.table, 16)
        count = args.count
        if count is None:
            _, entries = _extend(rom, table_off, 1, {})
            count = len(entries)
    else:
        cands = scan(rom, min_count=args.min_count)
        if not cands:
            print("no song table found", file=sys.stderr)
            return 2
        if args.all or len(cands) > 1:
            print("candidate runs (best first):")
            for c in cands[: (None if args.all else 5)]:
                _report(c)
            print("tie-break: longest run, then most non-empty songs, "
                  "then lowest offset")
        cand = cands[0]
        table_off = cand["offset"]
        count = args.count if args.count is not None else cand["count"]
        print("song table: offset 0x%06X  addr 0x%08X  %d entries"
              % (table_off, ROM_BASE + table_off, count))
        _report(cand)

    describe(rom, table_off, count, args.limit)

    if args.patch:
        hdr = int(args.patch, 16)
        out = patch(rom, table_off, count, hdr)
        if args.extend:
            out = extend_rom(out, args.extend)
        with open(args.out, "wb") as f:
            f.write(out)
        print("wrote %s: %d entries repointed at 0x%08X, %d bytes"
              % (args.out, count, hdr, len(out)))
    elif args.extend:
        out = extend_rom(rom, args.extend)
        with open(args.out, "wb") as f:
            f.write(out)
        print("wrote %s: %d bytes" % (args.out, len(out)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
