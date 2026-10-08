#!/usr/bin/env python3
"""Replay one script's [new] timeline under the HLE and the official BIOS
(the -d:biosdrvtrace driver) with the driver's `swilog` on, and report the
first SWI call whose start or length differs -- where hlecmp.py's frame
hashes part, this says which BIOS call moved first.

    swicmp.py <sha1-prefix|title> [--frames N] [--context K (calls shown)]

Logs are left in out/swicmp/<sha1>.{hle,bios}.txt.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import emu as emulib  # noqa: E402
import hlecmp  # noqa: E402
import library  # noqa: E402
import script as scriptlib  # noqa: E402

OUT = os.path.join(HERE, 'out', 'swicmp')


def run(name, rom, tl, frames, log):
    os.environ['PLAYTEST_DINGBAT_DRIVER'] = os.path.join(HERE, 'bin', 'dingbat_driver_trace')
    e = emulib.Emulator(name, rom, os.path.join(OUT, 'env-' + name), rtc_epoch=hlecmp.RTC)
    try:
        e.cmd(f'swilog {log}')
        done = 0
        for keys, n in tl:
            if done >= frames:
                break
            e.set_keys(keys)
            k = min(n, frames - done)
            e.run(k)
            done += k
        e.cmd('swilog off')
    finally:
        e.kill()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('only')
    ap.add_argument('--frames', type=int, default=10 ** 9)
    ap.add_argument('--context', type=int, default=12)
    args = ap.parse_args()
    lib = library.Library(os.path.join(HERE, 'out', 'rom-index.json'))
    sdir = os.path.join(HERE, 'scripts')
    for f in sorted(os.listdir(sdir)):
        if not f.endswith('.play'):
            continue
        sha1 = f[:-5]
        sc = scriptlib.parse(open(os.path.join(sdir, f)).read())
        title = sc['meta'].get('title', sha1)
        if not (sha1.startswith(args.only) or args.only.lower() in title.lower()):
            continue
        tl = hlecmp.timeline(sc['new'])
        rom = lib.find(sha1, sc['meta'].get('file'))
        os.makedirs(OUT, exist_ok=True)
        logs = []
        for name in ('dingbat', 'dingbat-bios'):
            log = os.path.join(OUT, f'{sha1[:12]}.{name}.txt')
            run(name, rom, tl, args.frames, log)
            logs.append([l.split() for l in open(log)])
        a, b = logs
        print(f'{title}: {len(a)} / {len(b)} calls')
        shown = 0
        for i, (x, y) in enumerate(zip(a, b)):
            if x[1:] != y[1:]:
                print(f'call {i} (frame {x[0]} / {y[0]}): swi {x[1]} at {x[3]} / {y[3]}, '
                      f'{x[4]} / {y[4]} cycles ({int(x[4]) - int(y[4]):+d})'
                      + ('' if x[5:] == y[5:] else '  registers differ'))
                shown += 1
                if shown >= args.context:
                    break
        if not shown:
            print('no call differs')
        return


if __name__ == '__main__':
    main()
