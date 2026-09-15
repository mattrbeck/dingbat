#!/usr/bin/env python3
"""Reports over MP2K sweep results (tools/mp2k_sweep.py output, one JSON line
per ROM from tests/mp2k_sweep.nim). See tools/mp2ksweep/README.md.

Usage:
  runs.py summary      <before.jsonl> <after.jsonl>
  runs.py regressions  <before.jsonl> <after.jsonl> [--threshold 0.02] [--list-out FILE]
  runs.py byrate       <before.jsonl> <after.jsonl>
  runs.py triage       <results.jsonl>
  runs.py engagement   <old.jsonl> <new.jsonl>
  runs.py census       <census.jsonl>   (a -d:mp2kwcensus sweep: the pass-ordering invariants)
  runs.py starts       <results.jsonl>  (note-ons carrying a count: honoured or ignored)

A "music" title is one that ran, is engaged at the end, and whose real
stream is audible (real_rms >= 3). xcorr0 is the lag-0 waveform correlation
against the game's own FIFO stream; it is only meaningful between runs whose
harness clears both captures after arming the HLE (2026-09-15).
"""
import argparse, collections, json, re, statistics, sys


def load(p):
    out = {}
    with open(p) as f:
        for line in f:
            line = line.strip()
            if line.startswith('{'):
                r = json.loads(line)
                out[r['rom']] = r
    return out


def music(r):
    return 'crash' not in r and r.get('engaged') and r.get('real_rms', 0) >= 3


def summarize(R):
    ok = [r for r in R.values() if 'crash' not in r]
    eng = [r for r in ok if r.get('engaged_ever')]
    mus = [r for r in R.values() if music(r)]
    xs = sorted(r['xcorr0'] for r in mus) or [0]
    return dict(n=len(R), crash=len(R) - len(ok), m4a=sum(1 for r in ok if r.get('m4a_seen')), eng=len(eng),
                mus=len(mus), within=sum(1 for r in mus if abs(r['ratio'] - 1) <= 0.2),
                env9=sum(1 for r in mus if r['env_corr'] >= 0.9),
                med_ratio=round(statistics.median(r['ratio'] for r in mus), 3) if mus else 0,
                med_x=round(xs[len(xs) // 2], 3), x_p25=round(xs[len(xs) // 4], 3),
                x_p75=round(xs[3 * len(xs) // 4], 3), x_gt5=sum(1 for x in xs if x > 0.5))


def cmd_summary(a):
    A, B = load(a.before), load(a.after)
    print("before:", summarize(A))
    print("after :", summarize(B))
    print("\n== newly outside ±20% loudness (music):")
    for k, r in B.items():
        o = A.get(k)
        if o and music(r) and abs(r['ratio'] - 1) > 0.2 and abs(o['ratio'] - 1) <= 0.2:
            print(f"  {o['ratio']:.3f} -> {r['ratio']:.3f} env {o['env_corr']:.2f}->{r['env_corr']:.2f} {k}")
    print("== envelope correlation drops > 0.05:")
    for k, r in B.items():
        o = A.get(k)
        if o and music(r) and o['env_corr'] - r['env_corr'] > 0.05:
            print(f"  env {o['env_corr']:.2f}->{r['env_corr']:.2f} x {o['xcorr0']:.2f}->{r['xcorr0']:.2f} {k}")
    print("== engagement / foreign-stream changes:")
    for k, r in B.items():
        o = A.get(k)
        if o and (o.get('engaged_ever') != r.get('engaged_ever') or o.get('foreign') != r.get('foreign')):
            print(f"  engaged {o.get('engaged_ever')} -> {r.get('engaged_ever')} foreign {o.get('foreign')} -> {r.get('foreign')} {k}")
    print("== crashes:", [k for k, r in B.items() if 'crash' in r])


def cmd_regressions(a):
    A, B = load(a.before), load(a.after)
    d = sorted((B[k]['xcorr0'] - A[k]['xcorr0'], k) for k, r in B.items()
               if music(r) and k in A and 'xcorr0' in A[k])
    worse = [x for x in d if x[0] < -a.threshold]
    better = [x for x in d if x[0] > a.threshold]
    print(f"music titles {len(d)}: better {len(better)}, worse {len(worse)} (|change| > {a.threshold})")
    for x, k in worse:
        print(f"  {x:+.3f} {A[k]['xcorr0']:.3f}->{B[k]['xcorr0']:.3f} {B[k].get('pcm_rate')} Hz rms {B[k].get('real_rms', 0):.0f} {k}")
    if a.list_out:
        with open(a.list_out, 'w') as f:
            for _, k in worse:
                f.write(k + '\n')


def cmd_byrate(a):
    A, B = load(a.before), load(a.after)
    by = collections.defaultdict(list)
    for k, r in B.items():
        o = A.get(k)
        if o and music(r) and music(o):
            by[r['pcm_rate']].append((o['xcorr0'], r['xcorr0']))
    for rate, v in sorted(by.items()):
        print(f"{rate:6d} Hz n {len(v):3d} median {statistics.median(x for x, _ in v):.3f} -> "
              f"{statistics.median(y for _, y in v):.3f} better {sum(1 for x, y in v if y > x + 0.05)} "
              f"worse {sum(1 for x, y in v if y < x - 0.05)} (±0.05)")


def cmd_triage(a):
    rows = list(load(a.results).values())
    m4a = [r for r in rows if r.get('m4a_seen')]
    noeng = [r for r in m4a if not r.get('engaged_ever')]
    print(f"m4a {len(m4a)}, never engaged {len(noeng)}:")
    for r in noeng:
        print(f"  passes {r.get('hook_fires')} ident {r.get('ident_last')} real_rms {r.get('real_rms', 0):.1f} {r['rom']}")
    mus = [r for r in rows if music(r)]
    print(f"\nmusic {len(mus)}; median xcorr0 by rate:")
    by = collections.defaultdict(list)
    for r in mus:
        by[r['pcm_rate']].append(r['xcorr0'])
    for k, v in sorted(by.items()):
        print(f"  {k:6d} Hz n {len(v):3d} median {statistics.median(v):.3f}")
    print("mono vs stereo median:", {m: round(statistics.median([r['xcorr0'] for r in mus if r['mono'] == m]), 3)
                                     for m in sorted(set(r['mono'] for r in mus))})
    print("reverb on vs off median:", {b: round(statistics.median([r['xcorr0'] for r in mus if (r['reverb'] > 0) == b]), 3)
                                       for b in (True, False) if any((r['reverb'] > 0) == b for r in mus)})
    print("\nlowest 25:")
    for r in sorted(mus, key=lambda r: r['xcorr0'])[:25]:
        print(f"  x{r['xcorr0']:+.3f} env{r['env_corr']:.2f} ratio{r['ratio']:.2f} {r['pcm_rate']:5d} Hz "
              f"mono{r['mono']} rev{r['reverb']:3d} steps{r.get('place_steps', '-')} {r['rom']}")


CAMELOT = re.compile(r"Golden Sun|Ougon no Taiyou|Mario Tennis|Mario Golf", re.I)
STOCK = [
    "Pokemon - Emerald Version (U).gba", "Pokemon - Fire Red Version (U) (V1.1).gba",
    "Legend of Zelda, The - The Minish Cap (U).gba", "Castlevania - Circle of the Moon (U) [!].gba",
    "Advance GTA (J) [!].gba", "EZ-Talk 1 (J).gba", "Hudson Best Collection Vol. 3 (J).gba",
    "Megaman Battle Network (U) [!].gba", "Super Dodgeball Advance (U) [!].gba",
    "Beast Shooter Mezase Beast King (J).gba", "Breath of Fire (U) [!].gba",
    "Kirby & The Amazing Mirror (U).gba", "Advance Wars (U) (V1.1) [!].gba",
]


def cmd_engagement(a):
    A, B = load(a.old), load(a.new)
    ok = lambda r: r.get('status', 'ok') == 'ok' and 'crash' not in r
    eng = lambda r: bool(r.get('engaged_ever'))
    common = [k for k in B if k in A]
    print("engaged (old, new):", dict(collections.Counter((eng(A[k]), eng(B[k])) for k in common if ok(A[k]) and ok(B[k]))))
    print("\nno m4a ident literal in the ROM but engaged (must be none):",
          [k for k in common if ok(B[k]) and not B[k].get('rom_magic') and eng(B[k])])
    print("\nCamelot drivers (own mixer; must never engage):")
    for k in sorted(k for k in common if CAMELOT.search(k)):
        print(f"  {'ENGAGED' if eng(B[k]) else 'no':8} old={'ENGAGED' if eng(A[k]) else 'no':8} {k}")
    print("\nstock m4a mixer titles (must engage):")
    for k in STOCK:
        print(f"  {('engaged' if eng(B[k]) else 'NOT ENGAGED') if k in B else '(not in list)':12} {k}")
    print("\nengagement changed:")
    for k in sorted(common):
        if ok(A[k]) and ok(B[k]) and eng(A[k]) != eng(B[k]):
            print(f"  {'old only' if eng(A[k]) else 'new only':9} magic={B[k].get('rom_magic')} passes={B[k].get('hook_fires')} {k}")


def cmd_census(a):
    recs = list(load(a.census).values())
    ok = [r for r in recs if r.get('status') == 'ok' and 'wc' in r]
    print("ROMs", len(recs), "ran ok", len(ok))
    live = [r for r in ok if r['wc']['passes'] > 0]
    print("ROMs whose driver wrote its lock at least once:", len(live))
    tot = collections.Counter()
    for r in live:
        for k in ('passes', 'ring_passes', 'no_ring', 'no_ring_late', 'env_before', 'ring_outside', 'other_buf'):
            tot[k] += r['wc'].get(k, 0)
    print("totals:", dict(tot))
    print("\nenvelope bytes (+0x09..+0x0B) stored before a pass's first ring store (must be none):")
    for r in sorted((r for r in live if r['wc'].get('env_before', 0)), key=lambda r: -r['wc']['env_before']):
        print(f"  {r['wc']['env_before']}/{r['wc']['passes']} pc={r['wc'].get('env_pc')} {r['rom']}")
    print("\nengaged ROMs with locked passes that stored no ring byte after 2 s:")
    for r in sorted((r for r in live if r.get('engaged_ever') and r['wc'].get('no_ring_late', 0) > 1),
                    key=lambda r: -r['wc']['no_ring_late'])[:30]:
        print(f"  no_ring_late={r['wc']['no_ring_late']} ring_passes={r['wc']['ring_passes']} {r['rom']}")
    fc = collections.Counter()
    for r in live:
        for k in r['wc'].get('fields', {}):
            fc[k] += 1
    print("\nSoundInfo / channel fields stored before the first ring store (ROM counts):", fc.most_common(30))


def cmd_starts(a):
    ok = [r for r in load(a.results).values() if 'crash' not in r and r.get('engaged')]
    s = lambda k: sum(r.get(k, 0) for r in ok)
    print(f"titles {len(ok)}: note-ons with a count: honoured {s('start_honoured')}, ignored {s('start_ignored')}, unclear {s('start_unclear')}")
    for r in sorted((r for r in ok if r.get('start_honoured', 0)), key=lambda r: -r['start_honoured'])[:15]:
        print(f"  honoured {r['start_honoured']} ignored {r['start_ignored']} {r['rom']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('summary'); p.add_argument('before'); p.add_argument('after'); p.set_defaults(f=cmd_summary)
    p = sub.add_parser('regressions'); p.add_argument('before'); p.add_argument('after')
    p.add_argument('--threshold', type=float, default=0.02); p.add_argument('--list-out', default='')
    p.set_defaults(f=cmd_regressions)
    p = sub.add_parser('byrate'); p.add_argument('before'); p.add_argument('after'); p.set_defaults(f=cmd_byrate)
    p = sub.add_parser('triage'); p.add_argument('results'); p.set_defaults(f=cmd_triage)
    p = sub.add_parser('engagement'); p.add_argument('old'); p.add_argument('new'); p.set_defaults(f=cmd_engagement)
    p = sub.add_parser('census'); p.add_argument('census'); p.set_defaults(f=cmd_census)
    p = sub.add_parser('starts'); p.add_argument('results'); p.set_defaults(f=cmd_starts)
    a = ap.parse_args()
    a.f(a)


if __name__ == '__main__':
    main()
