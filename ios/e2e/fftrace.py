"""Summarise an iOS -ff-trace log (Documents/fftrace.txt; GameSession's
FFTrace has the line format).

usage: python3 ios/e2e/fftrace.py fftrace.txt [--speed ff|1x] [--presses]

Per display tick: callback gaps, how late the callback ran, how close the
present came to the vsync it was meant for, main-thread time outside the
tick; per press of A: which tick first ran with it held, whether that
tick's picture was presented, when it reached the glass (the drawable's
presentedTime on a device; the GPU's end in the simulator, which has no
presented handler), and how many refreshes the picture before it stayed.

On a device: Xcode › Product › Scheme › Edit Scheme › Run › Arguments, add
`-ff-trace` (Debug build), run, play (fast-forward, tap A through text),
then Files › On My iPhone › dingbat › fftrace.txt (AirDrop it over).
Simulator:
the press driver (`-ff-drive 60 -ff-grid-target`, see FFTrace.swift).
"""
import statistics, sys
from collections import defaultdict


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else float("nan")


def stats(v):
    if not v:
        return "n=0"
    return "n=%d p50 %.2f p90 %.2f p99 %.2f max %.2f" % (len(v), pct(v, .5), pct(v, .9), pct(v, .99), max(v))


def main():
    path = sys.argv[1]
    want = None
    if "--speed" in sys.argv:
        want = sys.argv[sys.argv.index("--speed") + 1]
    ticks, glass, gpu, inputs, marks, planned = [], {}, {}, [], [], {}
    # When the press driver ran, only its tapping phase counts (the boot and
    # the intro's presses run at fast-forward too).
    driven = any(l.startswith("M tapping") for l in open(path))
    tapping = not driven
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "M" and len(p) > 1 and p[1] == "tapping":
            tapping = True
        if not tapping and p[0] in ("T", "I"):
            continue
        if p[0] == "T" and len(p) >= 14:
            ticks.append(dict(seq=int(p[1]), ts=float(p[2]), target=float(p[3]), entry=float(p[4]),
                              work=float(p[5]), pend=None if p[6] == "-" else float(p[6]), ran=int(p[7]),
                              mask=int(p[8], 16), presented=p[9] == "1", hash=p[10], speed=p[11],
                              outside=float(p[12]), wait=float(p[13]),
                              budget=float(p[14]) if len(p) > 14 else 0.0,
                              aim=float(p[15]) if len(p) > 15 and float(p[15]) > 0 else float(p[3])))
        elif p[0] == "D":
            glass[int(p[1])] = float(p[2])
        elif p[0] == "G":
            gpu[int(p[1])] = (float(p[2]), float(p[3]))
        elif p[0] == "I":
            inputs.append((float(p[1]), int(p[2]), p[3] == "1", p[4]))
        elif p[0] == "X":
            planned[int(p[1])] = float(p[2])
        elif p[0] == "M":
            marks.append(" ".join(p[1:]))
    by = {t["seq"]: t for t in ticks}
    if want:
        ticks = [t for t in ticks if t["speed"] == want]
    if not ticks:
        print("no ticks")
        return
    press_id = int(sys.argv[sys.argv.index("--press-id") + 1]) if "--press-id" in sys.argv else 4
    presses = [i for i in inputs if i[1] == press_id and i[2]]
    t_first = ticks[0]["entry"]
    presses = [p for p in presses if p[0] > t_first]

    # The refresh period from consecutive ticks' refreshes (a CAMetalDisplayLink
    # tick's target is its work deadline, not the next refresh).
    P = statistics.median(b["ts"] - a["ts"] for a, b in zip(ticks, ticks[1:])
                          if b["seq"] == a["seq"] + 1 and b["ts"] > a["ts"])
    real_glass = bool(glass)
    print("ticks %d (%s) period %.2f ms; glass = %s" % (len(ticks), want or "all", P,
          "drawable presentedTime" if real_glass else "GPU end (no presented handler)"))
    print("frames per tick:", stats([t["ran"] for t in ticks]))

    near = set()  # ticks that ran with a press or release arriving just before
    for (tp, _id, _d, _s) in inputs:
        nxt = [t for t in ticks if t["entry"] > tp][:2]
        for t in nxt:
            near.add(t["seq"])

    gaps, gaps_near = [], 0
    for a, b in zip(ticks, ticks[1:]):
        if b["seq"] != a["seq"] + 1:
            continue
        g = (b["ts"] - a["ts"]) / P
        gaps.append(g)
        if g > 1.5 and b["seq"] in near:
            gaps_near += 1
    big = [g for g in gaps if g > 1.5]
    missed = sum(round(g) - 1 for g in big)
    print("callback gaps > 1.5 periods: %d of %d (%d next to an input edge), %d refreshes missed in all;"
          " worst %.2f periods" % (len(big), len(gaps), gaps_near, missed, max(gaps) if gaps else 0))
    print("callback lateness entry-ts ms:", stats([t["entry"] - t["ts"] for t in ticks]))
    print("tick work entry->workEnd ms:", stats([t["work"] - t["entry"] for t in ticks]))
    pres = [t for t in ticks if t["presented"]]
    print("present cost workEnd->presentEnd ms:", stats([t["pend"] - t["work"] for t in pres]))
    print("  of it waiting for a drawable ms:", stats([t["wait"] for t in pres]))
    slack = [t["aim"] - t["pend"] for t in pres]
    print("present end before the vsync aimed at ms (neg = after it):", stats(slack))
    print("  presents after it: %d of %d" % (sum(1 for s in slack if s < 0), len(slack)))
    bud = [t for t in ticks if t["budget"] > 0]
    if bud:
        print("FF budget ms:", stats([t["budget"] for t in bud]))
        print("FF overshoot past the budget ms:", stats([(t["work"] - t["entry"]) - t["budget"] for t in bud]))
    out_near = [t["outside"] for t in ticks if t["seq"] in near]
    out_far = [t["outside"] for t in ticks if t["seq"] not in near]
    print("main thread outside the tick ms, quiet ticks:", stats(out_far))
    print("main thread outside the tick ms, next to an input:", stats(out_near))
    print("presented %d of %d ticks; changed-but-unpresented %d" % (
        len(pres), len(ticks), sum(1 for t in ticks if t["mask"] and not t["presented"])))

    def on_glass(seq):
        # A device's presentedTime of 0 is a picture never shown: no time,
        # not the GPU's (the simulator has no presented handler at all).
        if real_glass:
            return glass[seq] if glass.get(seq, 0) > 0 else None
        if seq in gpu:
            return gpu[seq][1]
        return None

    if real_glass:
        never = [t for t in pres if glass.get(t["seq"]) == 0]
        print("presented but never shown (presentedTime 0): %d of %d" % (len(never), len(pres)))
    lat =[on_glass(t["seq"]) - t["aim"] for t in pres if on_glass(t["seq"]) is not None]
    print("glass - vsync aimed at ms:", stats(lat))
    # Comparable across pacing modes: how old the picture is when it shows.
    print("present end -> glass ms:", stats([on_glass(t["seq"]) - t["pend"] for t in pres
                                              if on_glass(t["seq"]) is not None]))
    print("tick entry -> glass ms:", stats([on_glass(t["seq"]) - t["entry"] for t in pres
                                             if on_glass(t["seq"]) is not None]))
    if planned:
        print("CAMetalDisplayLink: glass - planned presentation ms:",
              stats([on_glass(t["seq"]) - planned[t["seq"]] for t in pres
                     if t["seq"] in planned and on_glass(t["seq"]) is not None]))
        print("  planned presentation - tick entry ms:",
              stats([planned[t["seq"]] - t["entry"] for t in ticks if t["seq"] in planned]))
    holds = []
    prev = None
    for t in pres:
        g = on_glass(t["seq"])
        if g is None:
            continue
        if prev is not None:
            holds.append((g - prev) / P)
        prev = g
    print("glass-to-glass between presented pictures (periods):", stats(holds))
    hist = defaultdict(int)
    for h in holds:
        hist[round(h)] += 1
    print("  rounded:", dict(sorted(hist.items())))

    if "--presses" in sys.argv or presses:
        rows = []
        for (tp, _id, _d, src) in presses:
            after = [t for t in ticks if t["entry"] > tp]
            if not after:
                continue
            t1 = after[0]
            t1p = next((t for t in after if t["presented"]), None)
            before = [t for t in ticks if t["entry"] < tp and t["presented"]]
            t0 = before[-1] if before else None
            g1 = on_glass(t1p["seq"]) if t1p else None
            g0 = on_glass(t0["seq"]) if t0 else None
            rows.append(dict(
                wait=(t1["entry"] - tp), first_ran=t1["ran"], t1_presented=t1["presented"],
                ticks_to_present=(t1p["seq"] - t1["seq"]) if t1p else None,
                lat=(g1 - tp) if g1 else None,
                hold=((g1 - g0) / P) if (g1 and g0) else None,
                gap=((t1["ts"] - by[t1["seq"] - 1]["ts"]) / P) if (t1["seq"] - 1) in by else None,
                outside=t1["outside"]))
        print("\npresses %d" % len(rows))
        print("  press -> next tick entry ms:", stats([r["wait"] for r in rows]))
        print("  that tick presented: %d of %d; ticks until a present: %s" % (
            sum(r["t1_presented"] for r in rows), len(rows),
            dict(sorted(defaultdict(int, {k: sum(1 for r in rows if r["ticks_to_present"] == k)
                                          for k in set(r["ticks_to_present"] for r in rows)}).items(),
                        key=lambda kv: (kv[0] is None, kv[0])))))
        print("  press -> glass ms:", stats([r["lat"] for r in rows if r["lat"] is not None]))
        print("  the picture before it held (periods):", stats([r["hold"] for r in rows if r["hold"] is not None]))
        print("  callback gap into that tick (periods):", stats([r["gap"] for r in rows if r["gap"] is not None]))
        print("  main thread outside the tick before it ms:", stats([r["outside"] for r in rows]))


if __name__ == "__main__":
    main()
