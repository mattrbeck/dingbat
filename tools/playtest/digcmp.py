#!/usr/bin/env python3
"""Replay one script's [new] timeline under the HLE and the official BIOS
with the driver's `rundigest` (the -d:biosdrvtrace driver) and report the
first frame where the game's own code ran other instructions or ran them on
other cycles -- earlier than hlecmp.py's frame hashes, which only part when
the picture does.

    digcmp.py <sha1-prefix|title> [--frames N]
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

OUT = os.path.join(HERE, 'out', 'digcmp')


def digests(name, rom, tl, frames):
    os.environ['PLAYTEST_DINGBAT_DRIVER'] = os.path.join(HERE, 'bin', 'dingbat_driver_trace')
    e = emulib.Emulator(name, rom, os.path.join(OUT, 'env-' + name), rtc_epoch=hlecmp.RTC)
    out = []
    try:
        for keys, n in tl:
            if len(out) >= frames:
                break
            e.set_keys(keys)
            while n > 0 and len(out) < frames:
                k = min(n, 300, frames - len(out))
                r = e.cmd(f'rundigest {k}')
                out += r.split()[1:]
                n -= k
    finally:
        e.kill()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('only')
    ap.add_argument('--frames', type=int, default=10 ** 9)
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
        a = digests('dingbat', rom, tl, args.frames)
        b = digests('dingbat-bios', rom, tl, args.frames)
        print(f'{title}: {len(a)} / {len(b)} frames')
        kinds = ['picture', 'instruction count', 'instruction order', 'instruction timing']
        first = {}
        for i, (x, y) in enumerate(zip(a, b)):
            for k, (p, q) in enumerate(zip(x.split(':'), y.split(':'))):
                if p != q and k not in first:
                    first[k] = i
        for k in range(4):
            print(f'  {kinds[k]:20s}: ' + (f'first differs at f{first[k]}' if k in first else 'equal'))
        return


if __name__ == '__main__':
    main()
