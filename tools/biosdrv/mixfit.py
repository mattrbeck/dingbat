#!/usr/bin/env python3
"""Per-output mixer timing against the resampler's events, from a traced
real-BIOS run of a mix_*.gba probe (run.py <rom> real N --trace): for every
channel-0 output, the cycles since the previous output (from the pcmBuffer
store stamps) tabulated by (fixed, advances since the previous output, loop
wraps among them). Also each pass's channel-0 setup time (status read to
first store) and tail (last store to the next channel's status read).
  mixfit.py <name> [...]"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import load_marks, regions_of  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def s8(x):
    return x - 256 if x > 127 else x


def analyse(name):
    rom = os.path.join(HERE, "mix_%s.gba" % name)
    prefix = "/tmp/bd/mix_%s.real" % name
    marks = load_marks(prefix, regions_of(rom))
    global AREA
    AREA = regions_of(rom)[0][0]
    wins = []
    for i, (m, f, c, s) in enumerate(marks):
        if m == 0xF1 and i > 0 and marks[i - 1][0] == 0xF0:
            wins.append((marks[i - 1][2], c, i))
    stores = []
    for line in open(prefix + ".mem.txt"):
        p = line.split()
        a = int(p[3].split(":")[0], 16)
        if AREA + 0x350 <= a < AREA + 0xFB0:
            stores.append((int(p[1]), a))
    # every BIOS access with its width, for the access census of a span
    acc_ev = []
    for path in (".mem.txt", ".memread.txt"):
        for line in open(prefix + path):
            p = line.split()
            a, rest = p[3].split(":")
            a = int(a, 16)
            w = int(rest.split("=")[0])
            if a >= 0x02000000 and not (0x03007E00 <= a < 0x03008000):
                acc_ev.append((int(p[1]), a, w))
    acc_ev.sort()

    def census(t0, t1):
        # area words/bytes, source (other) words/bytes in [t0, t1)
        aw = ab = sw = sb = 0
        for t, a, w in acc_ev:
            if t < t0:
                continue
            if t >= t1:
                break
            if AREA <= a < AREA + 0xFB0:
                if w == 4: aw += 1
                else: ab += 1
            else:
                if w == 4: sw += 1
                else: sb += 1
        return (aw, ab, sw, sb)

    visits = []
    for line in open(prefix + ".memread.txt"):
        p = line.split()
        if p[2] == "pc=1EB8" and int(p[3].split(":")[0], 16) >= 0x02000000:
            visits.append((int(p[1]), int(p[3].split(":")[0], 16)))
    table = collections.Counter()
    setup = collections.Counter()
    tails = collections.Counter()
    # snapshots: the 0x20 mark after each pass (same order as the 1C calls)
    snaps = [x for x in marks if x[0] == 0x20]
    for w, (t0, t1, mi) in enumerate(wins[2:]):     # skip Init and Mode
        if w >= len(snaps) or w == 0:
            continue
        a = snaps[w][3][0]
        pa = snaps[w - 1][3][0]
        cn = int(os.environ.get("CH", "0"))
        ch, pch = a[0x50 + 64 * cn:0x90 + 64 * cn], pa[0x50 + 64 * cn:0x90 + 64 * cn]
        if (ch[0] & 0xC7) == 0 and (pch[0] & 0xC7) == 0:
            continue
        spv = struct.unpack_from("<I", a, 0x10)[0]
        P = struct.unpack_from("<I", a, 0x14)[0]
        fixed = ch[1] & 8
        freq = struct.unpack_from("<I", ch, 0x20)[0]
        wav = struct.unpack_from("<I", ch, 0x24)[0]
        # pass start state: after the previous pass, unless the note began
        started = ((pch[0] & 0xC7) == 0) or struct.unpack_from("<I", pch, 0x24)[0] != wav or \
            struct.unpack_from("<I", pch, 0x20)[0] != freq or (ch[0] & 0x10) != (pch[0] & 0x10)
        # ROM wave header via the probe ROM (or its EWRAM copy: same bytes)
        rb = open(rom, "rb").read()
        base = rb.find(b"\x00\x00")  # unused
        del base
        # use the channel's own fields for the loop geometry
        if started:
            acc, count = 0, None
        else:
            acc = struct.unpack_from("<I", pch, 0x1C)[0]
            count = struct.unpack_from("<I", pch, 0x18)[0]
        vis = [v for v in visits if t0 <= v[0] <= t1]
        if os.environ.get("DBG"):
            print("dbg", w, t0, t1, len(vis), hex(ch[0]), hex(pch[0]))
        if not vis:
            continue
        vis = [v for v in vis if v[1] >= AREA + 0x50 + 64 * cn]
        if not vis:
            continue
        v0 = vis[0][0]
        v1 = vis[1][0] if len(vis) > 1 else t1
        st = [s for s in stores if v0 <= s[0] < v1]
        outs = [s[0] for s in st[1::2]]
        if not outs:
            continue
        pre = None
        tails[(len(outs) == spv, v1 - st[-1][0], census(st[-1][0] + 1, v1 + 1))] += 1
        # advances before each output (resampled); fixed: one per output
        size = loop = None
        prev = outs[0]
        acc_i = acc
        adv_list = []
        acc_list = []
        wrap_list = []
        rb = open(rom, "rb").read()
        # the wave's loop geometry (from its header in the ROM image: the
        # probe ROMs keep one wave, or the channel's first)
        ls = sz = None
        hoff = wav - 0x08000000 if wav >= 0x08000000 else None
        if hoff is not None:
            ls, sz = struct.unpack_from("<II", rb, hoff + 8)
        cnt_i = count if count is not None else sz
        for i in range(spv):
            n = 0
            wraps = []
            acc_list.append(acc_i)
            if not fixed:
                while acc_i >= P:
                    acc_i -= P
                    n += 1
                    if cnt_i is not None:
                        cnt_i -= 1
                        if cnt_i == 0:
                            wraps.append(n)
                            cnt_i = sz - ls
                acc_i += freq
            else:
                if cnt_i is not None and i > 0:
                    cnt_i -= 1
                    if cnt_i == 0:
                        wraps.append(1)
                        cnt_i = sz - ls
            adv_list.append(n)
            wrap_list.append(tuple(wraps))
        # setup: status read to the first output's A store, less that
        # output's own cost; keyed by start/cont, kind, envelope phase before
        # the pass, first output's advances
        # envelope path: the status before the pass (START taken as such)
        # and after it
        env = "%02X>%02X" % (0x80 if started else pch[0], ch[0])
        setup[("fix" if fixed else "res", env, adv_list[0], outs[0] - v0,
               census(v0, outs[0] + 1))] += 1
        for i in range(1, len(outs)):
            g = outs[i] - outs[i - 1]
            key = ("fix", 1) if fixed else ("res", adv_list[i])
            if os.environ.get("WRAP"):
                key = key + (wrap_list[i],)
            if os.environ.get("ACC"):
                # the accumulator after this output's advances, in bands
                a_after = acc_list[i] - adv_list[i] * P
                key = key + (min(a_after // int(os.environ["ACC"]), 9),)
            if os.environ.get("PARITY"):
                key = key + ("odd" if i % 2 else "even",)
            if os.environ.get("BYFREQ"):
                key = key + (freq,)
            table[key + (g,)] += 1
    return table, setup, tails


for name in sys.argv[1:]:
    t, s, tl = analyse(name)
    print("==", name)
    byk = collections.defaultdict(list)
    for k, n in t.items():
        byk[k[:-1]].append((n, k[-1]))
    for k in sorted(byk):
        print("  ", k, sorted(byk[k], reverse=True)[:6])
    print("   setup", sorted(s.items()))
    print("   tails", sorted(tl.items()))
