"""ffscene.py TRACE [--json]: per speed segment and per speed switch of a
-ff-scene run (FFTrace lines). Times in ms."""
import json, statistics, sys

path = sys.argv[1]
T, D, marks, Z = [], {}, [], set()
tapping = False
for line in open(path):
    p = line.split()
    if not p:
        continue
    if p[0] == "M" and len(p) > 1 and p[1] == "tapping":
        tapping = True
    if p[0] == "M" and len(p) > 3 and p[1] == "speed":
        marks.append((float(p[2]), p[3]))
    if p[0] == "M" and len(p) > 2 and p[1] == "relink":
        marks.append((None, "relink:" + p[2]))
    if not tapping:
        continue
    if p[0] == "T" and len(p) >= 14:
        T.append(dict(seq=int(p[1]), ts=float(p[2]), entry=float(p[4]), work=float(p[5]),
                      pend=None if p[6] == "-" else float(p[6]), ran=int(p[7]),
                      presented=p[9] == "1", speed=p[11]))
    elif p[0] == "D":
        if float(p[2]) > 0:
            D[int(p[1])] = float(p[2])
        else:
            Z.add(int(p[1]))  # presented, never shown
marks = [m for m in marks if m[0] is not None]


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else float("nan")


P = statistics.median(b["ts"] - a["ts"] for a, b in zip(T, T[1:]) if b["seq"] == a["seq"] + 1 and b["ts"] > a["ts"])

# Segments: consecutive ticks at one speed, trimmed 0.5 s from each edge.
segs = []
for t in T:
    if not segs or segs[-1]["speed"] != t["speed"]:
        segs.append(dict(speed=t["speed"], ticks=[]))
    segs[-1]["ticks"].append(t)

out = {"period": P, "segments": [], "switches": []}
agg = {}
for s in segs:
    ts = s["ticks"]
    if len(ts) < 2:
        continue
    t0, t1 = ts[0]["entry"] + 500, ts[-1]["entry"] - 500
    core = [t for t in ts if t0 <= t["entry"] <= t1]
    if len(core) < 30:
        continue
    a = agg.setdefault(s["speed"], dict(ticks=0, missed=0, frames=0, dur=0.0, lat=[], age=[], g2g=[], pres=0, never=0))
    a["ticks"] += len(core)
    for x, y in zip(core, core[1:]):
        g = (y["ts"] - x["ts"]) / P
        if g > 1.5:
            a["missed"] += round(g) - 1
    a["frames"] += sum(t["ran"] for t in core)
    a["dur"] += (core[-1]["entry"] - core[0]["entry"]) / 1000
    prev = None  # (seq, glass) of the last presented tick
    for t in core:
        if not t["presented"]:
            continue
        a["pres"] += 1
        if t["seq"] in Z:
            a["never"] += 1
        g = D.get(t["seq"])
        if g is None:
            continue
        a["lat"].append(g - t["entry"])
        if t["pend"] is not None:
            a["age"].append(g - t["pend"])
        # Pacing: back-to-back refreshes that both brought a new picture
        # should put them on glass one refresh apart.
        if prev is not None and prev[0] == t["seq"] - 1:
            a["g2g"].append(round((g - prev[1]) / P))
        prev = (t["seq"], g)

print("period %.2f ms" % P)
print("%-5s %6s %7s %8s %15s %15s %12s %22s" % ("speed", "ticks", "missed", "fps", "entry->glass", "present->glass", "never shown", "back-to-back pictures (refreshes apart)"))
for sp, a in agg.items():
    hist = {}
    for g in a["g2g"]:
        hist[g] = hist.get(g, 0) + 1
    h = " ".join("%d:%d" % (k, v) for k, v in sorted(hist.items()))
    print("%-5s %6d %7d %8.1f %7.2f/%-7.2f %7.2f/%-7.2f %5d of %-5d %s" % (
        sp, a["ticks"], a["missed"], a["frames"] / a["dur"] if a["dur"] else 0,
        pct(a["lat"], .5), pct(a["lat"], .9), pct(a["age"], .5), pct(a["age"], .9), a["never"], a["pres"], h))
    out["segments"].append(dict(speed=sp, ticks=a["ticks"], missed=a["missed"],
                                fps=a["frames"] / a["dur"] if a["dur"] else 0,
                                lat50=pct(a["lat"], .5), lat90=pct(a["lat"], .9),
                                age50=pct(a["age"], .5), age90=pct(a["age"], .9), up=hist,
                                never=a["never"], pres=a["pres"]))

# Switches: the longest gap between pictures on glass within 0.6 s after each
# speed change, and refreshes the link skipped there.
for (tm, sp) in marks:
    near = [t for t in T if tm - 100 <= t["entry"] <= tm + 600]
    pr = [t for t in near if t["presented"] and t["seq"] in D]
    gaps = [(D[y["seq"]] - D[x["seq"]]) / P for x, y in zip(pr, pr[1:]) if y["seq"] == x["seq"] + 1]
    miss = 0
    for x, y in zip(near, near[1:]):
        g = (y["ts"] - x["ts"]) / P
        if g > 1.5:
            miss += round(g) - 1
    first = [t for t in T if t["entry"] > tm]
    first_glass = None
    for t in first[:30]:
        if t["presented"] and t["seq"] in D:
            first_glass = D[t["seq"]] - tm
            break
    out["switches"].append(dict(to=sp, worst_gap=max(gaps) if gaps else None, missed=miss, first_glass=first_glass))
if out["switches"]:
    print("switches (to: longest picture gap within 0.6 s in refreshes, refreshes skipped, ms to first picture):")
    for s in out["switches"]:
        print("  -> %-4s gap %s  skipped %d  first %s" % (
            s["to"], "%.2f" % s["worst_gap"] if s["worst_gap"] else "-", s["missed"],
            "%.1f" % s["first_glass"] if s["first_glass"] is not None else "-"))
if "--json" in sys.argv:
    json.dump(out, open(path + ".json", "w"), indent=1)
