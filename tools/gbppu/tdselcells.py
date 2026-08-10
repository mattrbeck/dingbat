#!/usr/bin/env python3
"""The CGB TILE_SEL arbitration corpus, rebuilt from the emulator's own trace.

    nim c -d:test_harness -d:release -d:gb_px_trace -d:gb_m3_trace \
      -d:GB_TRACE_LY=-1 --path:src -o:dt_px tests/dingbat_test.nim
    python3 tools/gbppu/tdselcells.py ./dt_px [workdir]

Every glitched background bitplane read of the four CGB `m3_lcdc_tile_sel*`
references and of `cgb-acid-hell` is one CELL, and the reference PNG says which
byte HARDWARE returned for it. That turns "which substitution source does the
silicon use" into an offline score with no rebuild between hypotheses, which is
what `CGB_TDSEL_GLITCH` and `CGB_TDSEL_IDX_DOTS` in `gb/gb.nim` are derived
from. A whole-frame percentage cannot do this job: a cell under an object, or
in a palette whose four entries are the same colour, is invisible in the
picture and still votes here.

How a cell gets its hardware byte, with no VRAM dump and no palette table:

  * `-d:gb_px_trace` prints `FDATA` per bitplane read (with every candidate
    substitution source next to it), `PUSH` per eight pixels entering the BG
    FIFO (with the `lx` they show at and the tile attribute), and `PX` per
    emitted pixel (with the BG colour, its palette, and whether an object won).
  * The `PX` lines plus dingbat's OWN framebuffer give, per palette, the RGB of
    each of the four colours -- so the reference PNG can be inverted back to
    colour indices without knowing anything about CGB colour correction. A
    palette that shows one RGB for two colours simply leaves those bits
    unpinned, which is the honest answer.
  * A pixel is only used where no object covered it and its palette is the
    pushed tile's, so what is left is the BG bitplane pair, bit for bit.

The self-check is the point of trusting any of it: for every plane whose eight
bits the reference pins, dingbat's own byte must equal the reconstructed one
wherever the frame is pixel-exact. All five frames report 0 mismatches on a
passing tree; a nonzero count on the four mealybug frames means the parser
drifted, not that hardware disagrees.

Cell census depends on the pinning convention and there is no canonical one:
this tool counts a cell whenever at least ONE bit is pinned (415 cells, 223 SET
and 192 RESET) and also reports the strict all-eight-bits subset (335, 151 and
184). Scoring is per pinned bit either way, so the inclusive census is the
harder gate and the one the tables in `gb.nim` quote.
"""
import collections, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mbscore import read_png_rgb, read_ppm_rgb

CACHE = os.environ.get("DINGBAT_ROM_CACHE", "/tmp/dingbat-test-roms")
MB = os.environ.get("MBROOT",
                    CACHE + "/game-boy-test-roms/mealybug-tearoom-tests/ppu")
HELL = CACHE + "/game-boy-test-roms/cgb-acid-hell"

ROMS = [
    ("m3_lcdc_tile_sel_change",      MB + "/m3_lcdc_tile_sel_change.gb",
                                     MB + "/m3_lcdc_tile_sel_change_cgb_c.png"),
    ("m3_lcdc_tile_sel_change2",     MB + "/m3_lcdc_tile_sel_change2.gb",
                                     MB + "/m3_lcdc_tile_sel_change2_cgb_c.png"),
    ("m3_lcdc_tile_sel_win_change",  MB + "/m3_lcdc_tile_sel_win_change.gb",
                                     MB + "/m3_lcdc_tile_sel_win_change_cgb_c.png"),
    ("m3_lcdc_tile_sel_win_change2", MB + "/m3_lcdc_tile_sel_win_change2.gb",
                                     MB + "/m3_lcdc_tile_sel_win_change2_cgb_c.png"),
    ("cgb-acid-hell",                HELL + "/cgb-acid-hell.gbc",
                                     HELL + "/cgb-acid-hell.png"),
]

KV = re.compile(r"(\w+)=([^\s]+)")
KINDS = ("FDATA ", "PUSH ", "SPR ", "PX ")


def hx(s):
    return int(s, 16)


def run_trace(binary, rom, ppm, txt):
    """One screenshot run, keeping only the LAST frame's pipeline events.

    The trace is ~7M lines for 120 frames and all but the last frame is noise,
    so the filtering happens here rather than in memory: the last `LATCH ly=0`
    opens the frame the screenshot shows.
    """
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


def palette_inverse(ev, own_rgb):
    """pal -> {rgb: colour}, read off dingbat's own frame.

    Only object-free pixels are used, so the RGB shown IS the BG palette entry.
    An RGB two colours of one palette share is dropped: those bits are not
    pinned by any reference.
    """
    fwd = collections.defaultdict(lambda: collections.defaultdict(set))
    for e in ev:
        if e["k"] != "PX" or e["hs"] != "false":
            continue
        if e["sp"].split("/")[0] != "0":
            continue
        colour, pal, _ = e["bg"].split("/")
        i = (int(e["ly"]) * 160 + int(e["lx"])) * 3
        fwd[int(pal)][int(colour)].add(tuple(own_rgb[i:i+3]))
    inv = {}
    for pal, m in fwd.items():
        seen = collections.Counter(r for rgbs in m.values() for r in rgbs)
        inv[pal] = {r: c for c, rgbs in m.items() for r in rgbs if seen[r] == 1}
    return inv


def build(name, ref_png, ev, ppm):
    own = read_ppm_rgb(ppm)
    ref = read_png_rgb(ref_png)
    inv = palette_inverse(ev, own)
    px = {(int(e["ly"]), int(e["lx"])): e for e in ev if e["k"] == "PX"}

    cells, pending, reads = [], [], []
    stats = collections.Counter()
    for e in ev:
        if e["k"] == "SPR":
            reads.append(e)
            continue
        if e["k"] == "FDATA":
            reads.append(e)
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
        for plane, mine in ((0, hx(e["lo"])), (1, hx(e["hi"]))):
            if pinned[plane] == 0xFF:
                stats["pinned"] += 1
                stats["mismatch"] += hw[plane] != mine
        for r in pending:
            plane = int(r["plane"])
            r["_hw"], r["_pinned"] = hw[plane], pinned[plane]
            if int(r["glitch"]) != 0 and pinned[plane] != 0:
                cells.append(r)
        pending = []
    return cells, stats, reads


def annotate(reads):
    """Replay the latch rules over the read stream, so each read carries where
    its latch came from and how long ago the last RESET glitch was."""
    src = last_rst = None
    n = 0
    for r in reads:
        if r["k"] == "SPR":
            src = {"kind": "obj", "i": n, "dot": int(r["dot"]),
                   "ly": int(r["ly"])}
            continue
        n += 1
        r["_n"], r["_src"], r["_rst"] = n, src, last_rst
        g = int(r["glitch"])
        if g < 0:
            last_rst = {"kind": "rst", "i": n, "dot": int(r["dot"]),
                        "ly": int(r["ly"])}
        if g < 0 or (g == 0 and (hx(r["lcdc"]) >> 4) & 1):
            src = {"kind": "rst" if g < 0 else "uns", "i": n,
                   "dot": int(r["dot"]), "ly": int(r["ly"])}


def age(r, key):
    s = r.get(key)
    if s is None:
        return None, None, None, None
    same = s["ly"] == int(r["ly"])
    return (r["_n"] - s["i"], (int(r["dot"]) - s["dot"]) if same else None,
            same, s["kind"])


def collect(binary, work):
    corpus = []
    for name, rom, png in ROMS:
        ppm = os.path.join(work, "tdsel_%s.ppm" % name)
        ev = run_trace(binary, rom, ppm, os.path.join(work, "tdsel_%s" % name))
        cells, stats, reads = build(name, png, ev, ppm)
        os.remove(ppm)
        annotate(reads)
        for c in cells:
            ar, ad, asame, akind = age(c, "_src")
            rr, rd, rsame, _ = age(c, "_rst")
            corpus.append({
                "rom": name, "ly": int(c["ly"]), "dot": int(c["dot"]),
                "plane": int(c["plane"]), "glitch": int(c["glitch"]),
                "hw": c["_hw"], "pinned": c["_pinned"], "mine": hx(c["byte"]),
                "num": hx(c["num"]), "latch": hx(c["latch"]),
                "uns": hx(c["uns"]), "sgn": hx(c["sgn"]),
                "prevd": hx(c["prevd"]), "prevu": hx(c["prevu"]),
                "src": akind, "age_reads": ar, "age_dots": ad,
                "same_line": asame,
                "rst_reads": rr, "rst_dots": rd, "rst_same_line": rsame,
            })
        print("%-30s %3d SET %3d RESET cells   self-check %d/%d planes wrong"
              % (name, sum(1 for c in cells if int(c["glitch"]) > 0),
                 sum(1 for c in cells if int(c["glitch"]) < 0),
                 stats["mismatch"], stats["pinned"]))
    return corpus


def ok(c, pred):
    return (pred & c["pinned"]) == (c["hw"] & c["pinned"])


def score(corpus):
    S = [c for c in corpus if c["glitch"] > 0]
    R = [c for c in corpus if c["glitch"] < 0]
    print("\ncorpus: %d cells -- %d SET, %d RESET  (all eight bits pinned: "
          "%d, %d)" % (len(corpus), len(S), len(R),
                       sum(1 for c in S if c["pinned"] == 255),
                       sum(1 for c in R if c["pinned"] == 255)))

    print("\nRESET branch")
    for nm, f in (("tile index", "num"), ("latched byte", "latch"),
                  ("unsigned byte", "uns"),
                  ("previous bitplane byte", "prevd")):
        print("  %-28s %3d / %d"
              % (nm, sum(1 for c in R if ok(c, c[f])), len(R)))

    print("\nSET branch, unconditional")
    for nm, f in (("latched byte", "latch"), ("tile index", "num"),
                  ("previous $8000 byte", "prevu"),
                  ("previous bitplane byte", "prevd")):
        print("  %-28s %3d / %d"
              % (nm, sum(1 for c in S if ok(c, c[f])), len(S)))

    def within(c, key, n):
        return c[key] is not None and c[key] <= n

    def recent_rst(c, n):
        return bool(c["rst_same_line"]) and within(c, "rst_dots", n)

    print("\nSET branch, triggers for 'deliver the index instead'")
    trig = [
        ("never (the address latch alone)", lambda c: False),
        ("always", lambda c: True),
        ("the latch was written by a RESET glitch, any age",
         lambda c: c["src"] == "rst"),
        ("the immediately preceding read was RESET-glitched",
         lambda c: c["rst_reads"] == 1),
        ("the latch is <= 8 dots old, whatever wrote it",
         lambda c: bool(c["same_line"]) and within(c, "age_dots", 8)),
        ("the latch is <= 8 dots old AND a RESET glitch wrote it [SHIPPING]",
         lambda c: bool(c["same_line"]) and within(c, "age_dots", 8)
                   and c["src"] == "rst"),
        ("a RESET glitch landed <= 8 dots ago (latch ownership ignored)",
         lambda c: recent_rst(c, 8)),
        ("a RESET glitch landed <= 2 reads ago",
         lambda c: within(c, "rst_reads", 2)),
    ]
    for nm, pred in trig:
        n = sum(1 for c in S if ok(c, c["num"] if pred(c) else c["latch"]))
        miss = collections.Counter(
            c["rom"] for c in S
            if not ok(c, c["num"] if pred(c) else c["latch"]))
        print("  %-52s %3d / %d  misses %s"
              % (nm, n, len(S), dict(miss) or "-"))

    print("\nwindow sweep -- 'a RESET glitch landed <= N dots ago'")
    for n in range(0, 20):
        k = sum(1 for c in S
                if ok(c, c["num"] if recent_rst(c, n) else c["latch"]))
        fires = collections.Counter(c["rom"] for c in S if recent_rst(c, n))
        print("  N=%-3d %3d / %d   fires on %s"
              % (n, k, len(S), dict(fires) or "-"))


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else "./dt_px"
    work = sys.argv[2] if len(sys.argv) > 2 else tempfile.gettempdir()
    corpus = collect(binary, work)
    out = os.path.join(work, "tdsel_corpus.json")
    json.dump(corpus, open(out, "w"))
    score(corpus)
    print("\ncorpus written to %s" % out)


if __name__ == "__main__":
    main()
