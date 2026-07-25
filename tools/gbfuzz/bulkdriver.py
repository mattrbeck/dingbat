#!/usr/bin/env python3
"""Sweep the whole GB/GBC library in batches, resumably.

Enumerates every distinct title across the four sources in pick_roms.SOURCES,
takes the most canonical dump of each, and walks them in batches: fetch ->
sweep -> log -> prune. Ordering puts pick_roms.POPULAR first (so the titles that
matter are done first and a stop anywhere leaves the most useful coverage), then
the rest alphabetically.

Clean titles have their run artifacts and ROM deleted as soon as they pass, so
disk stays bounded no matter how long this runs; flagged titles keep everything
for the report. Progress goes to <workdir>/bulk_progress.log and completed
titles to <workdir>/bulk_done.json, which is what makes a re-run resume rather
than restart.

Usage: bulkdriver.py <workdir> [--batch-size 50] [--jobs 8] [--limit N]
"""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pick_roms as P

RANK = ['IDENTICAL', 'MINOR', 'DIFFERENT', 'MAJOR', 'REF-CRASH', 'ERROR']
OK = ('IDENTICAL', 'MINOR')


def log(workdir, msg):
    line = f'[{time.strftime("%H:%M:%S")}] {msg}'.rstrip()
    with open(os.path.join(workdir, 'bulk_progress.log'), 'a') as f:
        f.write(line + '\n')
    print(line, flush=True)


def worst_of(r):
    if r.get('error'):
        return 'ERROR'
    return max((s['final'] for s in r['shots'].values()), key=RANK.index,
               default='?')


def enumerate_titles(workdir):
    """Every distinct title -> (source, zipname) for its most canonical dump."""
    by_title = {}
    for sysname, (listfile, _) in P.SOURCES.items():
        path = os.path.join(workdir, listfile)
        if not os.path.exists(path):
            continue
        for line in open(path):
            z = line.strip()
            if not z:
                continue
            sc = P.score(z)
            if sc is None:           # beta / proto / hack / pirate
                continue
            key = P.norm(P.base_title(z))
            if not key:
                continue
            prev = by_title.get(key)
            if prev is None or sc > prev[0]:
                by_title[key] = (sc, sysname, z, P.base_title(z))
    # POPULAR first, in its own order, then everything else alphabetically.
    order, seen = [], set()
    for t in P.POPULAR:
        k = P.norm(t)
        if k in by_title and k not in seen:
            seen.add(k)
            order.append(k)
    for k in sorted(by_title, key=lambda k: by_title[k][3].lower()):
        if k not in seen:
            seen.add(k)
            order.append(k)
    return [(by_title[k][3], by_title[k][1], by_title[k][2]) for k in order]


def main():
    workdir = sys.argv[1]
    batch_size, jobs, limit = 50, 8, None
    args = sys.argv[2:]
    while args:
        a = args.pop(0)
        if a == '--batch-size': batch_size = int(args.pop(0))
        elif a == '--jobs': jobs = int(args.pop(0))
        elif a == '--limit': limit = int(args.pop(0))

    done_path = os.path.join(workdir, 'bulk_done.json')
    done = set(json.load(open(done_path))) if os.path.exists(done_path) else set()
    # Titles already covered by the hand-curated batches don't need redoing.
    for fn in os.listdir(workdir):
        if fn.startswith('results_') and fn.endswith('.json') \
                and not fn.startswith('results_bulk'):
            try:
                for r in json.load(open(os.path.join(workdir, fn))):
                    done.add(r['title'])
            except Exception:
                pass

    titles = enumerate_titles(workdir)
    todo = [t for t in titles if t[0] not in done]
    if limit:
        todo = todo[:limit]
    log(workdir, f'BULK START: {len(todo)} of {len(titles)} titles left '
                 f'({len(done)} already done)')

    batch_no = 0
    while todo:
        batch_no += 1
        batch, todo = todo[:batch_size], todo[batch_size:]
        sel, fetchfail = {}, 0
        for title, sysname, zipname in batch:
            try:
                sel[title] = P.extract(workdir, sysname, zipname)
            except Exception as e:
                fetchfail += 1
                log(workdir, f'  FETCHFAIL {zipname}: {str(e)[:90]}')
                done.add(title)      # don't retry a title the source can't give us
        if not sel:
            log(workdir, f'BATCH {batch_no}: nothing fetched '
                         f'({fetchfail} fetch failures)')
            json.dump(sorted(done), open(done_path, 'w'))
            continue
        sel_name = f'selected_bulk{batch_no:03d}.json'
        json.dump(sel, open(os.path.join(workdir, sel_name), 'w'), indent=1)
        out = f'results_bulk{batch_no:03d}.json'
        r = subprocess.run(
            [sys.executable, os.path.join(HERE, 'sweep.py'), workdir,
             '--jobs', str(jobs), '--selected', sel_name, '--out', out,
             '--auto-noinput', '--prune-clean'],
            capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(os.path.join(workdir, out)):
            log(workdir, f'BATCH {batch_no}: SWEEP FAILED rc={r.returncode} '
                         f'{r.stderr[-250:]}')
            continue
        res = json.load(open(os.path.join(workdir, out)))
        tally, flagged = {}, []
        for t in res:
            w = worst_of(t)
            tally[w] = tally.get(w, 0) + 1
            if w not in OK:
                flagged.append(f'{t["title"]}[{w}]')
            done.add(t['title'])
        json.dump(sorted(done), open(done_path, 'w'))
        # Free the ROMs of titles that passed; a flagged one is kept so the
        # divergence can be re-run and screenshotted.
        for t in res:
            if worst_of(t) in OK:
                p = os.path.join(workdir, 'roms', t['rom'])
                if os.path.exists(p):
                    os.remove(p)
        clean = sum(tally.get(k, 0) for k in OK)
        log(workdir, f'BATCH {batch_no}: {clean}/{len(res)} clean {tally} '
                     f'fetchfail={fetchfail} remaining={len(todo)}'
                     + (f' FLAGGED: {"; ".join(flagged)}' if flagged else ''))
    log(workdir, 'BULK DONE')


if __name__ == '__main__':
    main()
