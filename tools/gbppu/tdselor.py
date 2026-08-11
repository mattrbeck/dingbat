#!/usr/bin/env python3
"""Is a glitched TILE_SEL bitplane read ever a COMPOSITE of two sources?

    python3 tools/gbppu/tdselcells.py ./dt_px <work>   # writes tdsel_corpus.json
    python3 tools/gbppu/tdselor.py <work>/tdsel_corpus.json [./dt_px]

Chased from TASVideos submission 9604S, which says a mid-rendering BGP write can
put `old or new` on one pixel.  The question this asks is whether the same shape
of mechanism -- two drivers on one wire, resolving to a bitwise OR (or its
wired-AND dual) -- is what the CGB TILE_SEL glitch does, instead of the clean
single substitution source `CGB_TDSEL_GLITCH` ships.

It answers in two places, and they agree:

  * over the whole 408-cell corpus, by scoring every composite of the shipping
    source with each other candidate byte, in both polarities.  The column that
    matters is not the score but `differs`: a composite that is never
    distinguishable from the clean source has not been tested by the corpus, and
    one that is wrong exactly as often as it differs has been refuted by every
    cell that could see it.
  * on `cgb-acid-hell`'s two disputed planes, which are NOT in the corpus (in
    the shipping world neither read is glitched at all).  Passing the traced
    binary re-reads them off the frame: they demand OPPOSITE polarities of each
    other, which kills any fixed-polarity composite on its own.

See the 2026-08-10 BGP/OR entry in docs/gb-failure-triage.md for the verdict.
"""
import collections, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

FIELDS = ("num", "latch", "uns", "sgn", "prevd", "prevu")
OPS = ((lambda a, b: a | b, "or"), (lambda a, b: a & b, "and"))


def ok(c, pred):
    return (pred & c["pinned"]) == (c["hw"] & c["pinned"])


def score_corpus(path):
    corpus = json.load(open(path))
    S = [c for c in corpus if c["glitch"] > 0]
    R = [c for c in corpus if c["glitch"] < 0]
    print("corpus: %d cells -- %d SET, %d RESET\n" % (len(corpus), len(S), len(R)))

    for name, cells, base in (("RESET", R, "num"), ("SET", S, "latch")):
        print("%s branch -- shipping source is `%s`" % (name, base))
        print("  %-24s %9s %9s %s" % ("source", "score", "differs", "misses"))
        n = sum(1 for c in cells if ok(c, c[base]))
        print("  %-24s %4d/%-4d %9s" % (base + " [SHIPPING]", n, len(cells), "-"))
        for other in FIELDS:
            if other == base:
                continue
            for op, sym in OPS:
                lbl = "%s %s %s" % (base, sym, other)
                n = sum(1 for c in cells if ok(c, op(c[base], c[other])))
                d = sum(1 for c in cells
                        if (op(c[base], c[other]) & c["pinned"])
                        != (c[base] & c["pinned"]))
                miss = collections.Counter(
                    c["rom"] for c in cells if not ok(c, op(c[base], c[other])))
                note = "" if n == len(cells) else (
                    "  <-- every distinguishing cell refuses"
                    if len(cells) - n == d else "")
                print("  %-24s %4d/%-4d %9d  %s%s"
                      % (lbl, n, len(cells), d,
                         dict(miss) or "-", note))
        print()


def acid_hell_planes(binary, work):
    """Re-read acid-hell's two disputed bitplane bytes off the frame."""
    import tdselcells as T
    name, rom, png = [r for r in T.ROMS if r[0] == "cgb-acid-hell"][0]
    ppm = os.path.join(work, "tdselor_hell.ppm")
    ev = T.run_trace(binary, rom, ppm, os.path.join(work, "tdselor_hell"))
    own, ref = T.read_ppm_rgb(ppm), T.read_png_rgb(png)
    inv = T.palette_inverse(ev, own)
    px = {(int(e["ly"]), int(e["lx"])): e for e in ev if e["k"] == "PX"}
    os.remove(ppm)

    print("cgb-acid-hell, the planes where dingbat and hardware disagree")
    pending = []
    for e in ev:
        if e["k"] == "FDATA":
            pending.append(e)
            continue
        if e["k"] != "PUSH":
            continue
        ly, lx0 = int(e["ly"]), int(e["lx"])
        attr = T.hx(e["attr"])
        pal, flip = attr & 7, (attr & 0x20) != 0
        hw, pinned = [0, 0], [0, 0]
        for col in range(8):
            p = px.get((ly, lx0 + col))
            if p is None or p["hs"] != "false" or p["sp"].split("/")[0] != "0":
                continue
            colour, ppal, _ = p["bg"].split("/")
            if int(ppal) != pal:
                continue
            i = (ly * 160 + lx0 + col) * 3
            c = inv.get(pal, {}).get(tuple(ref[i:i+3]))
            if c is None:
                continue
            sh = col if flip else 7 - col
            hw[0] |= (c & 1) << sh
            hw[1] |= ((c >> 1) & 1) << sh
            pinned[0] |= 1 << sh
            pinned[1] |= 1 << sh
        for plane, mine in ((0, T.hx(e["lo"])), (1, T.hx(e["hi"]))):
            if pinned[plane] != 0xFF or hw[plane] == mine:
                continue
            r = [q for q in pending if int(q["plane"]) == plane]
            r = r[-1] if r else {}
            cand = {k: T.hx(r[k]) for k in FIELDS if k in r}
            print("\n  ly=%d lx=%d plane=%d  HW=$%02X  dingbat=$%02X  glitch=%s"
                  % (ly, lx0, plane, hw[plane], mine, r.get("glitch", "?")))
            print("    " + "  ".join("%s=$%02X" % kv for kv in cand.items()))
            for a in cand:
                for b in cand:
                    if a >= b:
                        continue
                    for op, sym in OPS:
                        if op(cand[a], cand[b]) == hw[plane]:
                            print("    matches: %s %s %s = $%02X"
                                  % (a, sym, b, hw[plane]))
        pending = []


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "tdsel_corpus.json"
    score_corpus(path)
    if len(sys.argv) > 2:
        acid_hell_planes(sys.argv[2], os.path.dirname(os.path.abspath(path)))


if __name__ == "__main__":
    main()
