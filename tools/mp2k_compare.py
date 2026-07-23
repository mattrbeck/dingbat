#!/usr/bin/env python3
"""Compare two MP2K sweep runs (before/after fixes): engage-rate movement,
foreign-latch population, and per-ROM |ratio-1| improvements/regressions.

Usage: mp2k_compare.py <before.jsonl> <after.jsonl> [--rms-floor 3.0]
"""
import argparse, json

def load(p):
    out = {}
    with open(p) as f:
        for line in f:
            try:
                r = json.loads(line)
                out[r["rom"]] = r
            except Exception:
                pass
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("before"); ap.add_argument("after")
    ap.add_argument("--rms-floor", type=float, default=3.0)
    args = ap.parse_args()
    A = load(args.before); B = load(args.after)
    both = sorted(set(A) & set(B))

    for name, S in (("BEFORE", A), ("AFTER", B)):
        ok = [r for r in S.values() if r.get("status") in ("ok", "timeout")]
        m4a = [r for r in ok if r.get("m4a_seen")]
        eng = [r for r in m4a if r.get("engaged_ever")]
        foreign = [r for r in ok if r.get("foreign")]
        playing = [r for r in ok if r.get("engaged_ever")
                   and not r.get("foreign")
                   and r.get("real_rms", 0) >= args.rms_floor]
        good = [r for r in playing if abs(r.get("ratio", 0) - 1) <= 0.2]
        print(f"{name}: ok={len(ok)} m4a={len(m4a)} engaged={len(eng)} "
              f"({100*len(eng)/max(1,len(m4a)):.1f}%) foreign={len(foreign)} "
              f"playing={len(playing)} within20%={len(good)} "
              f"({100*len(good)/max(1,len(playing)):.1f}%)")

    deltas = []
    for rom in both:
        a, b = A[rom], B[rom]
        if not (a.get("engaged_ever") and b.get("engaged_ever")):
            continue
        if b.get("foreign") or a.get("real_rms", 0) < args.rms_floor:
            continue
        da = abs(a.get("ratio", 0) - 1)
        db = abs(b.get("ratio", 0) - 1)
        deltas.append((db - da, a.get("ratio"), b.get("ratio"), rom))
    deltas.sort()
    print(f"\nbiggest improvements (|ratio-1| change):")
    for d, ra, rb, rom in deltas[:20]:
        print(f"  {ra:.3f} -> {rb:.3f}  ({d:+.3f})  {rom[:60]}")
    print(f"\nbiggest regressions:")
    for d, ra, rb, rom in deltas[-20:]:
        print(f"  {ra:.3f} -> {rb:.3f}  ({d:+.3f})  {rom[:60]}")
    imp = sum(1 for d, *_ in deltas if d < -0.02)
    reg = sum(1 for d, *_ in deltas if d > 0.02)
    print(f"\nimproved(>0.02): {imp}  regressed(>0.02): {reg}  "
          f"unchanged: {len(deltas)-imp-reg}")
    newly_foreign = [r for r in both
                     if B[r].get("foreign") and not A[r].get("foreign")]
    print(f"\nnewly foreign-latched: {len(newly_foreign)}")
    for r in newly_foreign[:40]:
        print(f"  real={A[r].get('real_rms',0):5.1f} oldratio={A[r].get('ratio',0):.3f} {r[:60]}")

main()
