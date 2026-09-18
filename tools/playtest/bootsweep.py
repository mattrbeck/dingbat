"""Boot a game in all three emulators, press nothing, and ask one question:
does dingbat ever draw a frame that neither reference draws?

The playtest suite needs a recorded script per game, so it covers 52 titles.
This covers as many as there are ROMs, at the cost of only seeing what a game
shows on its own: logos, the title screen, and -- on most GBA games -- an
attract-mode demo, which is real gameplay with real input, just not ours.

The metric is deliberately not a frame-by-frame comparison. Two emulators a
few frames apart on an animating screen disagree on almost every frame while
being equally correct, which is why the suite has a SLIP verdict. Here, each
emulator's whole run is reduced to the *set* of frames it drew, and what is
counted is set difference: a frame hash that one emulator produced and another
never produced at any point in the run. Timing slips cancel out; drawing
something nobody else ever draws does not.

An odd-frame count on its own means little -- a game resets its RNG from an
uninitialised value and all three diverge. What matters is the shape:

    dingbat 0     mgba 0     nba 0        all three agree, nothing to see
    dingbat 850   mgba 12    nba 9        dingbat is the odd one out  <-- look
    dingbat 900   mgba 880   nba 890      the game is nondeterministic

so every emulator is scored the same way against the other two, and a game is
only reported when dingbat's score stands out against both.

    bootsweep.py run <rom-or-sha1> [...]     # named ROMs
    bootsweep.py sweep [--limit N] [--seconds N] [--shuffle]
    bootsweep.py show <title>                # screenshots at the first odd frame
"""
import argparse
import json
import os
import random
import signal
import sys
import time

import emu
import library

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out', 'bootsweep')
CACHE = os.path.join(HERE, 'out', '.library.json')
REFERENCES = ['mgba', 'nba']
CHUNK = 600


def frame_hashes(name, rom, envdir, frames, bios=None):
    """Every frame's screen hash from a cold boot, no buttons pressed."""
    kw = {'bios': bios} if bios else {}
    e = emu.Emulator(name, rom, envdir, **kw)
    try:
        out = []
        while len(out) < frames:
            out += e.runhash(min(CHUNK, frames - len(out)))
        return out
    finally:
        e.kill()


def odd_frames(hashes):
    """For each emulator, the frames it drew that no other emulator ever drew,
    as (count, first frame index)."""
    seen = {name: set(h) for name, h in hashes.items()}
    out = {}
    for name, h in hashes.items():
        others = set().union(*(s for n, s in seen.items() if n != name))
        odd = [k for k, x in enumerate(h) if x not in others]
        out[name] = (len(odd), odd[0] if odd else None)
    return out


def sweep_one(rom, frames, keep=None):
    title = os.path.splitext(os.path.basename(rom))[0]
    # per-process, so several sweeps can run at once without sharing a game.sav
    envroot = keep or os.path.join(OUT, f'env-{os.getpid()}')
    hashes = {}
    started = time.time()
    for name in ['dingbat'] + REFERENCES:
        hashes[name] = frame_hashes(name, rom, os.path.join(envroot, name), frames)
    counts = odd_frames(hashes)
    ding, first = counts['dingbat']
    refs = [counts[r][0] for r in REFERENCES]
    # dingbat alone: it draws frames nobody else does, and the references do
    # not do the same thing to each other. The floor keeps a handful of frames
    # of fade timing from being news.
    alone = ding > 8 and ding > 4 * max(refs + [1])
    return {'title': title, 'rom': rom, 'frames': frames,
            'odd': {n: counts[n][0] for n in counts},
            'first_odd': first, 'alone': alone,
            'seconds': round(time.time() - started, 1)}


def _one(job):
    rom, frames, deadline = job
    # a ROM that wedges a driver would otherwise stall the whole sweep: the
    # driver blocks in read() with nothing coming back
    signal.signal(signal.SIGALRM, lambda *a: (_ for _ in ()).throw(
        TimeoutError(f'no answer within {deadline}s')))
    signal.alarm(deadline)
    try:
        return sweep_one(rom, frames)
    except Exception as e:                           # a driver refusing a ROM
        return {'title': os.path.basename(rom), 'rom': rom, 'error': str(e)[:200],
                'odd': {}, 'alone': False, 'first_odd': None}
    finally:
        signal.alarm(0)


def report(r):
    marks = ' '.join(f'{n}={r["odd"][n]}' for n in ['dingbat'] + REFERENCES)
    flag = '  <<< dingbat alone' if r['alone'] else ''
    first = f'  first@{r["first_odd"]}' if r['first_odd'] is not None else ''
    print(f'{r["title"][:52]:<54}{marks}{first}{flag}', flush=True)


def candidates(limit, shuffle, skip_known=True):
    """ROMs to sweep: the library, minus what the scripted suite already
    covers, minus the obvious non-games."""
    known = set()
    if skip_known:
        games = json.load(open(os.path.join(HERE, 'games.json')))
        known = {g['file'] for g in games}
    roms, titles = [], set()
    for d in library.DEFAULT_DIRS:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            low = name.lower()
            if not low.endswith('.gba') or name in known:
                continue
            # bad, hacked, translated or overdumped dumps: a difference in one
            # of those says nothing about the emulator
            if any(t in low for t in ('[b', '[f', '[t', '[a', '[o', '[h', '[p')):
                continue
            if any(t in low for t in ('(demo', '-in-1', 'test', 'bios', '(beta')):
                continue
            # one release per game: the European and Japanese cuts of the same
            # title would otherwise crowd out other games
            title = low.split('(')[0].strip()
            if title in titles:
                continue
            titles.add(title)
            roms.append(os.path.join(d, name))
    if shuffle:
        random.Random(20260917).shuffle(roms)
    return roms[:limit] if limit else roms


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('verb', choices=['run', 'sweep', 'show'])
    ap.add_argument('names', nargs='*')
    ap.add_argument('--seconds', type=float, default=40.0)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--shuffle', action='store_true')
    ap.add_argument('--jobs', type=int, default=1)
    ap.add_argument('--deadline', type=int, default=240,
                    help='seconds before a wedged driver is given up on')
    ap.add_argument('--out', default=os.path.join(OUT, 'results.json'))
    args = ap.parse_args(argv[1:])
    frames = int(args.seconds * 60)
    os.makedirs(OUT, exist_ok=True)

    if args.verb == 'run':
        lib = library.Library(CACHE)
        roms = [n if os.path.exists(n) else lib.find(n) for n in args.names]
    elif args.verb == 'sweep':
        roms = candidates(args.limit, args.shuffle)
    else:
        return show(args.names[0], frames)

    roms = [r for r in roms if r]
    results = []
    if args.jobs > 1:
        import multiprocessing
        with multiprocessing.Pool(args.jobs) as pool:
            stream = pool.imap_unordered(_one, [(r, frames, args.deadline) for r in roms])
            for r in stream:
                report(r) if 'error' not in r else print(
                    f'{r["title"][:52]:<54}error: {r["error"][:60]}', flush=True)
                results.append(r)
                with open(args.out, 'w') as f:
                    json.dump(results, f, indent=1)
    else:
        for rom in roms:
            r = _one((rom, frames, args.deadline))
            report(r) if 'error' not in r else print(
                f'{r["title"][:52]:<54}error: {r["error"][:60]}', flush=True)
            results.append(r)
            with open(args.out, 'w') as f:
                json.dump(results, f, indent=1)
    flagged = [r for r in results if r.get('alone')]
    print(f'\n{len(results)} swept, {len(flagged)} where dingbat stands alone')
    for r in flagged:
        print(f'  {r["title"]}  (first odd frame {r["first_odd"]})')
    return 0


def show(name, frames):
    """Screenshots from every emulator at the first frame dingbat drew alone."""
    results = json.load(open(os.path.join(OUT, 'results.json')))
    hit = next((r for r in results if name.lower() in r['title'].lower()), None)
    if not hit or hit.get('first_odd') is None:
        print('no such swept game, or nothing odd in it')
        return 1
    at = hit['first_odd']
    shots = os.path.join(OUT, 'shots', hit['title'])
    os.makedirs(shots, exist_ok=True)
    for emu_name in ['dingbat'] + REFERENCES:
        e = emu.Emulator(emu_name, hit['rom'], os.path.join(OUT, 'env', emu_name))
        e.run(at + 1)
        e.shot(os.path.join(shots, f'{emu_name}.png'))
        e.kill()
    print(f'frame {at}: {shots}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
