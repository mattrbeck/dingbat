#!/usr/bin/env python3
"""Save-state round trip: does saving a state, or saving and loading it,
change what an emulator does next?

  statecheck.py [--emus ...] [--jobs N] [--out FILE] ROM...

Per ROM and emulator, three runs from boot with the same input (START tapped
twice, A tapped, so attract modes and menus move):
  plain   run to frame F, then hash every frame of the next W
  saved   run to F, state_save, then the same W frames
  loaded  run to F, state_save, state_load, then the same W frames
`saved` and `loaded` must hash exactly like `plain`; the first frame that
does not is reported. A live session saves a state before every step (to
undo a failed one), so a difference here makes live play drift away from a
replay of the same inputs.
"""
import argparse
import concurrent.futures as cf
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import emu as emulib  # noqa: E402

F, W = 900, 600
TAPS = [(F + 30, 'START'), (F + 200, 'START'), (F + 380, 'A')]


def one_run(name, rom, workdir, mode):
    e = emulib.Emulator(name, rom, os.path.join(workdir, mode), rtc_epoch=1136073600)
    try:
        e.run(F)
        if mode in ('saved', 'loaded'):
            st = os.path.join(workdir, f'{mode}.state')
            e.state_save(st)
            if mode == 'loaded':
                e.state_load(st)
        hashes = []
        for frame, key in TAPS:
            hashes += e.runhash(frame - e.frame)
            e.set_keys([key])
            hashes += e.runhash(4)
            e.set_keys([])
        hashes += e.runhash(F + W - e.frame)
        return hashes
    finally:
        e.kill()


def check(name, rom):
    workdir = tempfile.mkdtemp(prefix=f'statecheck-{name}-')
    try:
        plain = one_run(name, rom, workdir, 'plain')
        out = {}
        for mode in ('saved', 'loaded'):
            try:
                h = one_run(name, rom, workdir, mode)
            except Exception as exc:  # a state the emulator cannot reload
                out[mode] = f'error: {exc}'
                continue
            bad = next((i for i, (a, b) in enumerate(zip(plain, h)) if a != b), None)
            out[mode] = 'exact' if bad is None else f'diverges at frame {F + 1 + bad}'
        return out
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('roms', nargs='+')
    ap.add_argument('--emus', default=','.join(emulib.ALL))
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--out')
    args = ap.parse_args()
    emus = args.emus.split(',')
    jobs = [(r, n) for r in args.roms for n in emus]
    results = {}
    with cf.ThreadPoolExecutor(args.jobs) as pool:
        for (rom, n), res in zip(jobs, pool.map(lambda j: check(j[1], j[0]), jobs)):
            results.setdefault(os.path.basename(rom), {})[n] = res
            print(f'{os.path.basename(rom)[:50]:50} {n:18} saved={res["saved"]:24} loaded={res["loaded"]}', flush=True)
    if args.out:
        json.dump(results, open(args.out, 'w'), indent=1)


if __name__ == '__main__':
    main()
