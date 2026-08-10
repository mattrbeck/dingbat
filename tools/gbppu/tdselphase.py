#!/usr/bin/env python3
"""What an LCDC.4 change does at every OFFSET from a background bitplane read.

    nim c -d:test_harness -d:release -d:gb_px_trace -d:gb_m3_trace \
      -d:GB_TRACE_LY=-1 --path:src -o:dt_px tests/dingbat_test.nim
    python3 tools/gbppu/tdselphase.py ./dt_px [workdir]

`tdselcells.py` scores the cells where a change lands ON a read (`glitch != 0`
in the trace) and asks WHICH BYTE hardware substituted. This asks the prior
question: for a change `d` dots away from a read, does hardware disturb that
read at all -- and if so with what. It exists because `CGB_HALT_PPU_LEAD`
moves `cgb-acid-hell`'s write burst against the fetch cycle by 4 dots, i.e.
onto the tile-MAP slot, where the shipping rules fire on nothing; the question
"what does a change in the map slot do" then has to be answered from the four
mealybug references, which sweep exactly that offset.

Every background bitplane read whose eight bits the reference pins is a row
here, bucketed by `(delta, direction)` where `delta = read dot - the dot the
last LCDC.4 change went live` (`chg` in the FDATA trace) and direction is the
value the bit changed TO. Per bucket it prints how many reads hardware agrees
with dingbat on, and how many are explained instead by the tile index, the
address latch, or the other addressing mode's byte.

The row count per bucket is the honest part: a bucket with no rows says the
corpus is silent about that offset, which is the whole finding for some of
them.

What it answered on 2026-08-14, in one line: of 6352 mealybug reads with an
LCDC.4 change on their own line, hardware disturbs the 408 at `delta = 0` and
none of the other 5944 -- so at `CGB_HALT_PPU_LEAD=1`, where `cgb-acid-hell`'s
changes sit 4 dots off its reads, no rule fires and none can be written. The
last table it prints (`detail`) is the bucket that decides it, split by the
change BEFORE the last one, which is where the two-sided bracket lives.

One caveat on its `cgb-acid-hell` rows: 16 of that frame's 304 pinned reads
(lines 136..143, one tile column, `mapoff = none`) report a mismatch on a frame
that is pixel-exact, because their push is attributed to the wrong pixels. They
are nowhere near the mechanism and identical in every build; the four mealybug
frames reconstruct 23680/23680 reads with no mismatch at all, which is what
says the reconstruction itself is sound.
"""
import collections, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tdselcells import ROMS, KV, hx, palette_inverse
from mbscore import read_png_rgb, read_ppm_rgb

NO_CHG = -1 << 30
# tdselcells.run_trace drops FTILE; the fetch cycle's own origin is exactly
# what this tool buckets by, so it keeps them.
KINDS = ("FTILE ", "FDATA ", "PUSH ", "SPR ", "PX ")


def run_trace(binary, rom, ppm, txt):
    argv = [binary, rom, "--mode=screenshot", "--timeout=120",
            "--screenshot=" + ppm, "--nosave", "--cgb", "--color"]
    with open(txt + ".raw", "w") as f:
        subprocess.run(argv, stdout=f, stderr=subprocess.DEVNULL)
    keep = []
    with open(txt + ".raw") as f:
        for ln in f:
            if ln.startswith("LATCH ly=0 "):
                keep = []
            elif ln.startswith(KINDS):
                keep.append(ln)
    os.remove(txt + ".raw")
    return [dict(KV.findall(ln), k=ln.split(" ", 1)[0]) for ln in keep]


def build(name, ref_png, ev, ppm):
    """Every bitplane read of the frame, carrying hardware's byte for it.

    Same reconstruction as tdselcells.build -- a PUSH's eight pixels invert
    through the palette into the two bitplane bytes hardware used -- but it
    keeps EVERY read rather than only the glitched ones.
    """
    own = read_ppm_rgb(ppm)
    ref = read_png_rgb(ref_png)
    inv = palette_inverse(ev, own)
    px = {(int(e["ly"]), int(e["lx"])): e for e in ev if e["k"] == "PX"}

    rows, pending = [], []
    stats = collections.Counter()
    map_dot = None
    # The trace carries only the LATEST LCDC.4 change (`chg`), which is all the
    # fetcher keeps. The change BEFORE it is recovered here: `chg` is sampled
    # at every read, so the distinct values it takes down a line are that
    # line's change dots in order, and the direction of each is the direction
    # the read that still saw it reported.
    prev_chg, prev_dir, cur_chg, cur_dir = None, None, None, None
    prev2_chg = None
    line = None
    for e in ev:
        if e["k"] == "FTILE":
            map_dot = int(e["dot"])
            continue
        if e["k"] == "FDATA":
            if int(e["ly"]) != line:
                line, prev_chg, prev_dir = int(e["ly"]), None, None
                cur_chg, cur_dir, prev2_chg = None, None, None
            chg = int(e["chg"])
            if chg > NO_CHG // 2 and chg != cur_chg:
                prev2_chg = prev_chg
                prev_chg, prev_dir = cur_chg, cur_dir
                cur_chg = chg
            cur_dir = 1 if (hx(e["lcdc"]) >> 4) & 1 else -1
            e["_map"] = map_dot
            e["_prevchg"], e["_prevdir"] = prev_chg, prev_dir
            e["_prev2chg"] = prev2_chg
            pending.append(e)
            continue
        if e["k"] != "PUSH":
            continue
        ly, lx0 = int(e["ly"]), int(e["lx"])
        attr = hx(e["attr"])
        pal, flip = attr & 7, (attr & 0x20) != 0
        hw, pinned = [0, 0], [0, 0]
        for col in range(8):
            x = lx0 + col
            p = px.get((ly, x))
            if p is None or p["hs"] != "false":
                continue
            if p["sp"].split("/")[0] != "0":
                continue
            colour, ppal, _ = p["bg"].split("/")
            if int(ppal) != pal:
                continue
            i = (ly * 160 + x) * 3
            c = inv.get(pal, {}).get(tuple(ref[i:i+3]))
            if c is None:
                continue
            shift = col if flip else 7 - col
            hw[0] |= (c & 1) << shift
            hw[1] |= ((c >> 1) & 1) << shift
            pinned[0] |= 1 << shift
            pinned[1] |= 1 << shift
        for r in pending:
            plane = int(r["plane"])
            if pinned[plane] == 0:
                continue
            stats["rows"] += 1
            chg = int(r["chg"])
            dot = int(r["dot"])
            rows.append({
                "rom": name, "ly": int(r["ly"]), "dot": dot,
                "plane": plane, "glitch": int(r["glitch"]),
                "delta": (dot - chg) if chg > NO_CHG // 2 else None,
                # Where the change fell inside THIS fetch cycle, counted from
                # the tile-map read. 0 is the map slot itself; 2 and 4 are the
                # two bitplane slots when the fetcher runs at pitch, and they
                # are not assumed -- an object or a stalled FIFO moves them.
                "mapoff": ((chg - r["_map"]) if (chg > NO_CHG // 2 and
                                                 r["_map"] is not None)
                           else None),
                "readoff": (dot - r["_map"]) if r["_map"] is not None else None,
                # The change BEFORE the one above, in the same frame of
                # reference: which fetch cycle it fell in and which way it went.
                "prevoff": ((r["_prevchg"] - r["_map"])
                            if (r["_prevchg"] is not None and
                                r["_map"] is not None) else None),
                "prevdir": r["_prevdir"],
                "prev2off": ((r["_prev2chg"] - r["_map"])
                             if (r["_prev2chg"] is not None and
                                 r["_map"] is not None) else None),
                # The bit's value AFTER the change is the bit the read sees,
                # except on the change's own dot, where `glitch` names it.
                "dir": 1 if (hx(r["lcdc"]) >> 4) & 1 else -1,
                "hw": hw[plane], "pinned": pinned[plane], "mine": hx(r["byte"]),
                "num": hx(r["num"]), "latch": hx(r["latch"]),
                "uns": hx(r["uns"]), "sgn": hx(r["sgn"]),
                "prevd": hx(r["prevd"]), "prevu": hx(r["prevu"]),
            })
        pending = []
    return rows, stats


def collect(binary, work):
    corpus = []
    for name, rom, png in ROMS:
        ppm = os.path.join(work, "phase_%s.ppm" % name)
        ev = run_trace(binary, rom, ppm, os.path.join(work, "phase_%s" % name))
        rows, stats = build(name, png, ev, ppm)
        os.remove(ppm)
        corpus += rows
        wrong = sum(1 for r in rows
                    if (r["mine"] & r["pinned"]) != (r["hw"] & r["pinned"]))
        print("%-30s %4d pinned reads, %3d where dingbat differs from hardware"
              % (name, len(rows), wrong))
    return corpus


def ok(r, pred):
    return (pred & r["pinned"]) == (r["hw"] & r["pinned"])


def report(corpus, key, lo=-4, hi=20, title="delta"):
    print("\n%-34s %5s %4s  %5s %5s %5s %5s %5s" %
          ("bucket (%s, dir)" % title, "reads", "mine", "index", "latch",
           "uns", "sgn", "prevd"))
    buckets = collections.defaultdict(list)
    for r in corpus:
        d = r[key]
        buckets[(d if d is not None and lo <= d <= hi else None,
                 r["readoff"] if key == "mapoff" else None,
                 r["dir"])].append(r)
    for k in sorted(buckets, key=lambda k: (k[0] is None, k[0], k[1] is None,
                                            k[1], k[2])):
        rows = buckets[k]
        d, ro, dr = k
        nm = ("%s=%s%s %s" % (title, "none/far" if d is None else d,
                              "" if ro is None else " read+%d" % ro,
                              "SET" if dr > 0 else "RESET"))
        cols = [sum(1 for r in rows if ok(r, r[f]))
                for f in ("mine", "num", "latch", "uns", "sgn", "prevd")]
        roms = collections.Counter(r["rom"][:14] for r in rows)
        print("%-34s %5d %4d  %5d %5d %5d %5d %5d   %s"
              % (nm, len(rows), cols[0], cols[1], cols[2], cols[3], cols[4],
                 cols[5], dict(roms) if len(rows) < 400 else ""))


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else "./dt_px"
    work = sys.argv[2] if len(sys.argv) > 2 else tempfile.gettempdir()
    corpus = collect(binary, work)
    out = os.path.join(work, "tdsel_phase.json")
    json.dump(corpus, open(out, "w"))
    report(corpus, "delta", title="delta")
    report(corpus, "mapoff", title="mapoff")
    detail(corpus)
    print("\nwritten to %s" % out)


def detail(corpus, want=(0,), planes=(4,), dirs=(-1,)):
    """The one bucket the LEAD=1 question lives in, split by prior context.

    If a candidate rule is to fire on `cgb-acid-hell` and on nothing else, some
    column here has to separate its reads from the mealybug ones in the same
    bucket. Empty separating columns are the result, not a failure.
    """
    rows = [r for r in corpus if r["mapoff"] in want
            and r["readoff"] in planes and r["dir"] in dirs]
    print("\nbucket mapoff in %s, read offset in %s, dir %s -- %d reads, split "
          "by the PREVIOUS change" % (want, planes, dirs, len(rows)))
    print("%-14s %-8s %-9s %5s %5s %5s %5s   %s"
          % ("prevoff", "prevdir", "prev2off", "reads", "mine", "index",
             "sgn", "roms"))
    by = collections.defaultdict(list)
    for r in rows:
        by[(r["prevoff"], r["prevdir"], r["prev2off"])].append(r)
    for k in sorted(by, key=lambda k: tuple((x is None, x) for x in k)):
        rs = by[k]
        print("%-14s %-8s %-9s %5d %5d %5d %5d   %s"
              % (k[0], k[1], k[2], len(rs),
                 sum(1 for r in rs if ok(r, r["mine"])),
                 sum(1 for r in rs if ok(r, r["num"])),
                 sum(1 for r in rs if ok(r, r["sgn"])),
                 dict(collections.Counter(r["rom"][:14] for r in rs))))


if __name__ == "__main__":
    main()
