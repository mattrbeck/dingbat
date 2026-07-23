#!/usr/bin/env python3
"""Triage the MP2K sweep results JSONL (tools/mp2k_sweep.py output).

Usage: mp2k_triage.py <results.jsonl> [--rms-floor 3.0] [--ratio-band 0.2]
"""
import argparse, json, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--rms-floor", type=float, default=3.0)
    ap.add_argument("--ratio-band", type=float, default=0.2)
    ap.add_argument("--list", default="",
                    help="dump full rom lists for a bucket: "
                         "crash|churn|miss|outlier|slow|noreal")
    args = ap.parse_args()

    rows = []
    with open(args.results) as f:
        for line in f:
            try: rows.append(json.loads(line))
            except Exception: pass

    by_status = {}
    for r in rows:
        by_status.setdefault(r.get("status", "?"), []).append(r)
    print(f"total {len(rows)}")
    for s, rs in sorted(by_status.items()):
        print(f"  {s}: {len(rs)}")

    ok = [r for r in rows if r.get("status") in ("ok", "timeout")]
    magic_rt = [r for r in ok if r.get("m4a_seen")]
    magic_rom = [r for r in ok if r.get("rom_magic")]
    engaged = [r for r in ok if r.get("engaged_ever")]
    eng_of_rt = [r for r in magic_rt if r.get("engaged_ever")]
    print(f"\nok+timeout {len(ok)}")
    print(f"  rom_magic (ID_NUMBER in image): {len(magic_rom)}")
    print(f"  m4a_seen (runtime ident):       {len(magic_rt)}")
    print(f"  engaged_ever:                   {len(engaged)}")
    if magic_rt:
        print(f"  engage rate among m4a_seen:     "
              f"{100.0 * len(eng_of_rt) / len(magic_rt):.2f}%")
    ghosts = [r for r in ok if r.get("engaged_ever") and not r.get("m4a_seen")]
    print(f"  engaged WITHOUT runtime magic (should be 0): {len(ghosts)}")
    for r in ghosts[:20]:
        print(f"    {r['rom']}")

    misses = [r for r in magic_rt if not r.get("engaged_ever")]
    print(f"\nDETECTION MISSES (m4a_seen but never engaged): {len(misses)}")
    for r in misses[:40]:
        print(f"  m4a@{r.get('m4a_frame'):>4} ident={r.get('ident_last')} "
              f"pf={r.get('probe_fails')} {r['rom'][:70]}")

    churn = [r for r in ok if r.get("probe_fails", 0) > 0]
    print(f"\nCHURN (probe_fails > 0): {len(churn)}")
    for r in sorted(churn, key=lambda r: -r.get("probe_fails", 0))[:40]:
        print(f"  pf={r['probe_fails']:>2} engaged={r.get('engaged')} "
              f"hook={r.get('hook')} {r['rom'][:65]}")

    crashes = by_status.get("crash", []) + by_status.get("hard-timeout", []) \
              + by_status.get("driver-error", [])
    print(f"\nCRASHES/HANGS: {len(crashes)}")
    for r in crashes[:40]:
        msg = r.get("crash", r.get("stderr", ""))[:80]
        print(f"  [{r.get('status')}] exit={r.get('exit')} {r['rom'][:55]} :: {msg}")

    # audio-quality outliers among engaged with real music playing
    playing = [r for r in ok if r.get("engaged_ever")
               and r.get("real_rms", 0) >= args.rms_floor]
    out = [r for r in playing
           if abs(r.get("ratio", 0) - 1.0) > args.ratio_band]
    print(f"\nAUDIO: engaged with real_rms >= {args.rms_floor}: {len(playing)}")
    print(f"  within ±{args.ratio_band*100:.0f}%: {len(playing) - len(out)} "
          f"({100.0*(len(playing)-len(out))/max(1,len(playing)):.1f}%)")
    print(f"  OUTLIERS (|ratio-1| > {args.ratio_band}): {len(out)}")
    for r in sorted(out, key=lambda r: abs(r.get("ratio", 0) - 1.0),
                    reverse=True)[:60]:
        print(f"  ratio={r['ratio']:.3f} hle={r['hle_rms']:.1f} "
              f"real={r['real_rms']:.1f} mono={r.get('mono')} rev={r.get('reverb')} "
              f"retrig={r.get('retrig')} {r['rom'][:52]}")

    silent_hle = [r for r in playing if r.get("hle_rms", 0) < 0.5]
    print(f"\n  engaged, real playing, HLE ~SILENT (<0.5): {len(silent_hle)}")
    for r in silent_hle[:30]:
        print(f"    real={r['real_rms']:.1f} {r['rom'][:65]}")

    slow = sorted(ok, key=lambda r: -r.get("wall_s", 0))[:20]
    print(f"\nSLOWEST (perf outlier screen):")
    for r in slow:
        print(f"  {r['wall_s']:>7.1f}s engaged={r.get('engaged')} {r['rom'][:60]}")

    if args.list:
        sel = {"crash": crashes, "churn": churn, "miss": misses,
               "outlier": out, "slow": slow,
               "noreal": [r for r in ok if r.get("engaged_ever")
                          and r.get("real_rms", 1) < args.rms_floor]}[args.list]
        print(f"\n--- full list: {args.list} ({len(sel)}) ---")
        for r in sel:
            print(r["rom"])

main()
