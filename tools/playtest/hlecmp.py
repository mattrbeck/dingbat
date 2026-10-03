#!/usr/bin/env python3
"""Replay scripts' [new] timelines in two dingbat configurations and compare
every frame's hash: where does the HLE BIOS first draw something the official
BIOS does not?

    hlecmp.py [filter ...] [--pair dingbat,dingbat-bios] [--jobs N]
              [--frames N] [--json OUT]

A filter is a sha1 prefix or a title substring (default: every ready frozen
script). Only frozen steps are replayed (wait, press, tap, hold/release,
checkpoint -> its hash window); a script with `until`/`mash` is skipped. The
result per game: frames compared, frames that differ, the first differing
frame (0-based, the first frame run is 0), or "equal".
"""
import argparse
import json
import multiprocessing
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import emu as emulib  # noqa: E402
import library  # noqa: E402
import script as scriptlib  # noqa: E402

RTC = 1136073600
OUT = os.path.join(HERE, 'out', 'hlecmp')


def timeline(steps):
    """-> [(keymask, frames)] or None when the script is not frozen."""
    out, held = [], 0
    for s in steps:
        op = s['op']
        if op == 'wait':
            out.append((held, s['frames']))
        elif op == 'press':
            out.append((held | emulib.key_mask(s['keys']), s['hold']))
            out.append((held, s['after']))
        elif op == 'hold':
            held = emulib.key_mask(s['keys'])
        elif op == 'tap':
            for _ in range(s['times']):
                out.append((held | emulib.key_mask(s['keys']), s['hold']))
                out.append((held, max(0, s['every'] - s['hold'])))
        elif op == 'checkpoint':
            out.append((held, 2 * s['window']))
        else:
            return None
    return [(k, n) for k, n in out if n > 0]


def hashes(name, rom, envdir, tl, limit):
    e = emulib.Emulator(name, rom, envdir, rtc_epoch=RTC)
    try:
        out = []
        for keys, n in tl:
            if len(out) >= limit:
                break
            e.set_keys(keys)
            while n > 0 and len(out) < limit:
                k = min(n, 600, limit - len(out))
                out += e.runhash(k)
                n -= k
        return out
    finally:
        e.kill()


def compare(job):
    sha1, title, rom, tl, pair, limit = job
    env = os.path.join(OUT, 'env', f'{sha1[:12]}-{os.getpid()}')
    try:
        a = hashes(pair[0], rom, os.path.join(env, 'a'), tl, limit)
        b = hashes(pair[1], rom, os.path.join(env, 'b'), tl, limit)
    except Exception as ex:   # a driver refusing a ROM
        return {'sha1': sha1, 'title': title, 'error': str(ex)[:200]}
    diff = [i for i, (x, y) in enumerate(zip(a, b)) if x != y]
    # frame 0 is the frame the boot skip hands over on: told apart
    late = [i for i in diff if i > 0]
    return {'sha1': sha1, 'title': title, 'frames': min(len(a), len(b)),
            'differ': len(diff), 'f0': bool(diff and diff[0] == 0),
            'first': late[0] if late else None,
            'last': diff[-1] if diff else None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('only', nargs='*')
    ap.add_argument('--pair', default='dingbat,dingbat-bios')
    ap.add_argument('--jobs', type=int, default=1)
    ap.add_argument('--frames', type=int, default=10 ** 9)
    ap.add_argument('--json')
    args = ap.parse_args()
    pair = args.pair.split(',')
    lib = library.Library(os.path.join(HERE, 'out', 'rom-index.json'))
    jobs = []
    sdir = os.path.join(HERE, 'scripts')
    for f in sorted(os.listdir(sdir)):
        if not f.endswith('.play'):
            continue
        sha1 = f[:-5]
        sc = scriptlib.parse(open(os.path.join(sdir, f)).read())
        title = sc['meta'].get('title', sha1)
        if args.only and not any(sha1.startswith(o) or o.lower() in title.lower()
                                 for o in args.only):
            continue
        if not sc['meta'].get('status', 'ready').startswith('ready'):
            continue
        tl = timeline(sc['new'])
        if tl is None:
            print(f'{title[:50]:<52} skipped: not frozen', flush=True)
            continue
        rom = lib.find(sha1, sc['meta'].get('file'))
        if not rom:
            print(f'{title[:50]:<52} skipped: no ROM', flush=True)
            continue
        jobs.append((sha1, title, rom, tl, pair, args.frames))
    results = []

    def show(r):
        if 'error' in r:
            print(f"{r['title'][:50]:<52} error {r['error'][:80]}", flush=True)
        elif r['first'] is None:
            print(f"{r['title'][:50]:<52} equal ({r['frames']} frames)"
                  + (' but f0' if r['f0'] else ''), flush=True)
        else:
            print(f"{r['title'][:50]:<52} first f{r['first']}  {r['differ']}/{r['frames']} differ",
                  flush=True)
    if args.jobs > 1:
        with multiprocessing.Pool(args.jobs) as pool:
            for r in pool.imap_unordered(compare, jobs):
                show(r)
                results.append(r)
    else:
        for j in jobs:
            r = compare(j)
            show(r)
            results.append(r)
    eq = sum(1 for r in results if r.get('first') is None and 'error' not in r)
    print(f'\n{eq}/{len(results)} equal on every frame after f0 ({pair[0]} vs {pair[1]})')
    if args.json:
        with open(args.json, 'w') as f:
            json.dump(sorted(results, key=lambda r: r['title']), f, indent=1)


if __name__ == '__main__':
    main()
