#!/usr/bin/env python3
"""Bulk archive driver: process remaining ROM zips 50 at a time.

For each batch: download -> extract .gba -> pick canonical dump -> sweep
(with auto no-input triage + clean-title pruning) -> log summary.
Zips are deleted after extraction; extracted ROMs are kept for the final
regression pass. Resilient: per-zip and per-batch failures are logged and
skipped. Progress lines go to <workdir>/batch_progress.log.

Usage: batchdriver.py <workdir> <download_base_url> [--batch-size 50]
  workdir needs zip_list.txt and picked_roms*.txt (already-processed zips).
"""
import json, os, re, shutil, subprocess, sys, unicodedata, urllib.parse, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
RANK = ['IDENTICAL', 'MINOR', 'DIFFERENT', 'MAJOR']

def log(workdir, msg):
    line = msg.rstrip()
    with open(os.path.join(workdir, 'batch_progress.log'), 'a') as f:
        f.write(line + '\n')
    print(line, flush=True)

def score(name):
    s = 0; low = name.lower()
    if re.search(r'hack|\[t[+-]|\[b\d|\[f\d|\[h\d|\[t\d|\[p\d|beta|\(save', low):
        return -100
    if '[a' in low: s -= 5
    if '[!]' in name: s += 50
    if '(u)' in low or '(usa' in low: s += 40
    elif '(ue)' in low: s += 30
    elif '(e)' in low or '(europe' in low: s += 20
    elif '(j)' in low: s += 5
    s -= len(name) * 0.01
    return s

def main():
    workdir = sys.argv[1]
    base = sys.argv[2]
    batch_size = 50
    args = sys.argv[3:]
    while args:
        a = args.pop(0)
        if a == '--batch-size': batch_size = int(args.pop(0))

    zips = [l.strip() for l in open(os.path.join(workdir, 'zip_list.txt')) if l.strip()]
    done = set()
    for fn in os.listdir(workdir):
        if fn.startswith('picked_roms') and fn.endswith('.txt'):
            done |= {l.strip() for l in open(os.path.join(workdir, fn)) if l.strip()}
    proc_path = os.path.join(workdir, 'processed_zips.txt')
    if os.path.exists(proc_path):
        done |= {l.strip() for l in open(proc_path) if l.strip()}
    remaining = [z for z in zips if z not in done]
    log(workdir, f'DRIVER START: {len(remaining)} zips remaining of {len(zips)}')

    sel_all_path = os.path.join(workdir, 'selected_all.json')
    sel_all = json.load(open(sel_all_path)) if os.path.exists(sel_all_path) else {}
    seen_roms = set(sel_all.values())
    # roms already covered by batches 1-3
    for fn in ('selected_roms.json', 'selected_roms2.json', 'selected_roms3.json'):
        p = os.path.join(workdir, fn)
        if os.path.exists(p):
            seen_roms |= set(json.load(open(p)).values())

    batch_no = 0
    while remaining:
        batch_no += 1
        batch, remaining = remaining[:batch_size], remaining[batch_size:]
        sel = {}
        dupes = failures = 0
        for z in batch:
            zp = os.path.join(workdir, 'zips', z)
            try:
                if not os.path.exists(zp):
                    url = base + '/' + urllib.parse.quote(z)
                    r = subprocess.run(['curl', '-sL', '--retry', '3', '--fail',
                                        '-o', zp, url], timeout=600)
                    if r.returncode != 0:
                        raise RuntimeError('download failed')
                names = [n for n in zipfile.ZipFile(zp).namelist()
                         if n.lower().endswith('.gba')]
                with zipfile.ZipFile(zp) as zf:
                    for n in names:
                        target = os.path.join(workdir, 'roms', os.path.basename(n))
                        if not os.path.exists(target):
                            with zf.open(n) as src, open(target, 'wb') as dst:
                                shutil.copyfileobj(src, dst)
                cands = [os.path.basename(n) for n in names]
                cands = [c for c in cands
                         if os.path.exists(os.path.join(workdir, 'roms', c))]
                if not cands:
                    raise RuntimeError('no .gba in zip')
                best = max(cands, key=score)
                title = re.sub(r'\.zip$', '', z)
                if best in seen_roms:
                    dupes += 1
                else:
                    seen_roms.add(best)
                    sel[title] = best
                    sel_all[title] = best
                os.remove(zp)
            except Exception as e:
                failures += 1
                log(workdir, f'  ZIPFAIL {z}: {str(e)[:80]}')
            with open(proc_path, 'a') as f:
                f.write(z + '\n')
        json.dump(sel_all, open(sel_all_path, 'w'), indent=1)
        if not sel:
            log(workdir, f'BATCH {batch_no}: nothing new ({dupes} dupes, {failures} failures)')
            continue
        sel_path = os.path.join(workdir, f'selected_bulk{batch_no:02d}.json')
        json.dump(sel, open(sel_path, 'w'), indent=1)
        out = f'results_bulk{batch_no:02d}.json'
        r = subprocess.run([sys.executable, os.path.join(HERE, 'sweep.py'),
                            workdir, '--jobs', '6',
                            '--selected', os.path.basename(sel_path),
                            '--out', out, '--auto-noinput', '--prune-clean'],
                           capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(os.path.join(workdir, out)):
            log(workdir, f'BATCH {batch_no}: SWEEP FAILED rc={r.returncode} '
                         f'{r.stderr[-200:]}')
            continue
        res = json.load(open(os.path.join(workdir, out)))
        tally = {}
        flagged = []
        for t in res:
            o = 'ERROR' if t['error'] else max(
                (s['final'] for s in t['shots'].values()), key=RANK.index,
                default='?')
            ni = t.get('noinput_f2000', {}).get('verdict', '')
            if o not in ('IDENTICAL', 'MINOR') and ni not in ('IDENTICAL', 'MINOR'):
                flagged.append(f"{t['title']}[{o}/ni={ni or 'n/a'}]")
            tally[o] = tally.get(o, 0) + 1
        log(workdir, f'BATCH {batch_no}: {len(res)} titles {tally} '
                     f'dupes={dupes} zipfails={failures}'
                     + (f' NEEDS-REVIEW: {"; ".join(flagged)}' if flagged else ''))
    log(workdir, 'DRIVER DONE')

if __name__ == '__main__':
    main()
