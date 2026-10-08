#!/usr/bin/env python3
"""Freeze every ready condition script (scripts/*.play without @frozen) in
place (`--jobs` at a time); the originals move to scripts/source/. Prints one line
per script and leaves a failed one unchanged.

  freeze_all.py [--jobs N] [FILTER...]
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import freeze  # noqa: E402
import script  # noqa: E402


def main():
    args = sys.argv[1:]
    jobs = 1
    if args[:1] == ['--jobs']:
        jobs, args = int(args[1]), args[2:]
    only = args
    todo = []
    for fn in sorted(os.listdir(os.path.join(HERE, 'scripts'))):
        if not fn.endswith('.play'):
            continue
        text = open(os.path.join(HERE, 'scripts', fn)).read()
        meta = script.parse(text)['meta']
        if freeze.is_frozen(text) or meta.get('status', 'ready') != 'ready':
            continue
        if only and not any(fn.startswith(o) or o.lower() in meta.get('title', '').lower() for o in only):
            continue
        todo.append((fn[:-5], meta.get('title', fn)))
    print(f'{len(todo)} scripts to freeze, {jobs} at a time', flush=True)
    import concurrent.futures as cf
    with cf.ThreadPoolExecutor(jobs) as pool:
        list(pool.map(lambda t: one(*t), todo))


def one(sha1, title):
    t0 = time.time()
    r = subprocess.run([sys.executable, os.path.join(HERE, 'playtest.py'), 'freeze', sha1, '--write'],
                       capture_output=True, text=True)
    tail = (r.stdout + r.stderr).strip().splitlines()
    status = 'OK' if r.returncode == 0 and any(l.startswith('frozen:') for l in tail) else 'FAILED'
    print(f'{status:6} {time.time() - t0:5.0f}s {title}', flush=True)
    if status != 'OK':
        print('       ' + '\n       '.join(tail[-6:]), flush=True)


if __name__ == '__main__':
    main()
