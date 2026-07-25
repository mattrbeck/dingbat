#!/usr/bin/env python3
"""Collect every flagged title from prior result files into one selection.

A long sweep is a discovery pass: fixes land while it runs, so its flags are a
superset of what is still wrong. Re-running just the flagged titles against the
final build settles which of them survive. Clean titles are not re-run — a fix
that broke one of those would show up in the test suite, and re-sweeping 2600
titles to find out costs hours.

Usage: recheck.py <workdir> [--out selected_recheck.json]
Writes the selection, and reports any flagged title whose ROM was pruned.
"""
import glob, json, os, sys

RANK = ['IDENTICAL', 'MINOR', 'DIFFERENT', 'MAJOR', 'REF-CRASH', 'ERROR']
OK = ('IDENTICAL', 'MINOR')


def worst_of(r):
    if r.get('error'):
        return 'ERROR'
    return max((s['final'] for s in r['shots'].values()), key=RANK.index,
               default='?')


def main():
    workdir = sys.argv[1]
    out = 'selected_recheck.json'
    args = sys.argv[2:]
    while args:
        a = args.pop(0)
        if a == '--out': out = args.pop(0)

    sel, missing, seen = {}, [], set()
    for path in sorted(glob.glob(os.path.join(workdir, 'results_*.json'))):
        if os.path.basename(path).startswith('results_recheck'):
            continue
        try:
            results = json.load(open(path))
        except Exception as e:
            print(f'  skipping {os.path.basename(path)}: {e}', file=sys.stderr)
            continue
        for r in results:
            if r['title'] in seen or worst_of(r) in OK:
                continue
            seen.add(r['title'])
            if os.path.exists(os.path.join(workdir, 'roms', r['rom'])):
                sel[r['title']] = r['rom']
            else:
                missing.append(r['title'])
    json.dump(sel, open(os.path.join(workdir, out), 'w'), indent=1)
    print(f'{len(sel)} flagged titles -> {out}')
    if missing:
        print(f'{len(missing)} flagged titles have no ROM left to re-run:',
              '; '.join(missing[:10]))


if __name__ == '__main__':
    main()
