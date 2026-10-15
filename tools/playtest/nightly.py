#!/usr/bin/env python3
"""The nightly suite's summary (nightly.sh): what needs a look, first line
first.

  nightly.py SUITE_DIR [SUITES_ROOT]

Lists every waitloop exactness failure (a configuration differing from its
-nowl twin: the reason dingbat-bios-nowl plays nightly), the games that fail
or stopped running, and, against the newest earlier nightly in SUITES_ROOT,
the games whose status changed. Exit 2 when something needs a look (an
exactness failure, or a game newly FAIL or ERROR), else 0.
"""
import json
import os
import re
import sys

WAITLOOP = 'waitloop skipping changes the run'


def rows(sdir):
    with open(os.path.join(sdir, 'index.json')) as f:
        return {r['sha1']: r for r in json.load(f)['games']}


def problems(row):
    """{config: [problem, ...]} from the game's results.json (empty when it did not run)."""
    try:
        with open(os.path.join(row['outdir'], 'results.json')) as f:
            res = json.load(f)
    except (OSError, KeyError, TypeError, ValueError):
        return {}
    return {c: v.get('problems', []) for c, v in res.get('verdicts', {}).items()}


def previous(sdir, root):
    """The newest earlier full nightly suite (tag YYYY-MM-DD) under root."""
    if not root or not os.path.isdir(root):
        return None
    me = os.path.basename(os.path.normpath(sdir))
    tags = sorted(t for t in os.listdir(root) if re.fullmatch(r'\d{4}-\d{2}-\d{2}', t) and t < me
                  and os.path.exists(os.path.join(root, t, 'index.json')))
    return os.path.join(root, tags[-1]) if tags else None


def main():
    sdir = sys.argv[1]
    now = rows(sdir)
    counts = {}
    for r in now.values():
        counts[r['status']] = counts.get(r['status'], 0) + 1
    exact, failing = [], []
    for r in sorted(now.values(), key=lambda r: r['title']):
        ps = problems(r)
        for c, plist in sorted(ps.items()):
            exact += [f"  {r['title']} [{c}]: {p}" for p in plist if p.startswith(WAITLOOP)]
        if r['status'] in ('FAIL', 'ERROR'):
            first = next((f'{c}: {p[0]}' for c, p in sorted(ps.items()) if p), r.get('detail', ''))
            failing.append(f"  {r['status']:5} {r['title']}: {first}")
    prev = previous(sdir, sys.argv[2] if len(sys.argv) > 2 else None)
    moved, newly_bad = [], 0
    if prev:
        before = rows(prev)
        for s, r in sorted(now.items(), key=lambda kv: kv[1]['title']):
            b = before.get(s, {}).get('status')
            if b and b != r['status']:
                moved.append(f"  {r['title']}: {b} -> {r['status']}")
                newly_bad += r['status'] in ('FAIL', 'ERROR') and b not in ('FAIL', 'ERROR')
    tally = ', '.join(f'{n} {k}' for k, n in sorted(counts.items()))
    if exact:
        head = f'waitloop skipping changed {len(exact)} run(s); {tally}'
    elif newly_bad:
        head = f'{newly_bad} game(s) newly failing; {tally}'
    else:
        head = f'nothing new; {tally}'
    print(head)
    print(f'suite: {sdir}' + (f' (compared with {prev})' if prev else ' (no earlier nightly to compare with)'))
    for title, lines in (('waitloop exactness (a configuration against its -nowl twin)', exact),
                         ('status changed since the last nightly', moved),
                         ('failing (FAIL / ERROR)', failing)):
        print(f'\n{title}: {len(lines) or "none"}')
        print('\n'.join(lines)) if lines else None
    return 2 if exact or newly_bad else 0


if __name__ == '__main__':
    sys.exit(main())
