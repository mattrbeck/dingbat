"""Play many games a little, with a dumb input pattern, and flag the ones
where dingbat fails grossly and a reference does not.

bootsweep.py presses nothing and asks whether dingbat ever draws a frame the
references never draw; that sees logos, title screens and attract demos. This
one presses START and A on a fixed beat after a quiet boot, which gets most
games past their title screen into a menu, an intro or the first level, and
it asks coarser questions -- the ones a player would notice:

    crash     the driver died or refused a command
    wild-pc   the CPU executed where no code lives (unused space above the
              BIOS, I/O, the save chip): needs the trace driver
              (PLAYTEST_DINGBAT_DRIVER=bin/dingbat_driver_trace, pcwatch)
    hang      the screen stops changing for good while the reference keeps
              drawing new frames
    blank     the late screenshots are one colour while the reference's are not
    few       dingbat draws far fewer distinct frames than the reference
    silent    no sound where the reference plays some
    save      the battery file's size or content disagrees in kind (none vs
              some, a different chip size)

Timing slips are expected (the emulators accumulate lag frames differently,
docs/playtest-bugs.md section 29), so the same key press can land on a
different frame in each and a game's path can fork. Nothing here compares
frames one to one; every check is a gross property of the whole run, and a
flag is only a lead until the screenshots (written per game beside the
result) say otherwise.

    inputsweep.py run <rom-or-sha1> [...] [--emus dingbat,mgba]
    inputsweep.py sweep --list pool.json [--jobs 6] [--tag NAME]
    inputsweep.py recheck --tag NAME [--emus dingbat-bios,nba]
                                    # flagged games again in more emulators
    inputsweep.py report --tag NAME

ROMs are only ever symlinked into private environment directories (emu.py),
so no battery file lands in the library.
"""
import argparse
import json
import os
import signal
import sys
import time

import numpy as np

import emu
import img
import library

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out', 'inputsweep')
CACHE = os.path.join(HERE, 'out', '.library.json')
RTC = 1750000000            # 2025-06-15 15:06 UTC: a fixed clock in every emulator
QUIET = 300                 # frames with no input after power-on
BEAT = 60                   # one press per second after that
HOLD = 6
SHOTS = (600, 1200, 1800, 2400, 3000)
AUDIO_RATE = 32768
FPS = 16777216 / 280896
# Each emulator's output level for the same signal, against mGBA's: dingbat's
# dump runs about 1/48 of it (median over 311 games both play sound in).
GAIN = {'mgba': 1.0, 'nba': 0.7}
DINGBAT_GAIN = 48.0


def gain(name):
    return DINGBAT_GAIN if name.startswith('dingbat') else GAIN.get(name, 1.0)


def schedule(frames):
    """(frame, key mask) changes: START and A alternately, held HOLD frames,
    one every BEAT frames after QUIET. START first so a title screen goes;
    then A for 'new game', dialogue and menus."""
    out = [(0, 0)]
    k = 0
    for f in range(QUIET, frames, BEAT):
        key = 'START' if k % 2 == 0 else 'A'
        out += [(f, emu.key_mask([key])), (f + HOLD, 0)]
        k += 1
    return out


def play(name, rom, envdir, frames, shots=SHOTS):
    """One emulator's run: every frame's hash, screenshots, audio, save."""
    audio = os.path.join(envdir + '-audio.raw')
    r = {'emu': name}
    started = time.time()
    e = None
    hashes = []
    try:
        e = emu.Emulator(name, rom, envdir, rtc_epoch=RTC, audio=audio)
        r['ready'] = e.ready
        watching = False
        if name.startswith('dingbat'):
            try:                        # only the -d:biosdrvtrace build has it
                e.cmd('pcwatch on')
                watching = True
            except emu.DriverError:
                pass
        marks = sorted(x for x in set([f for f, _ in schedule(frames)] + list(shots) + [frames]) if x <= frames)
        keys = dict(schedule(frames))
        held = 0
        for a, b in zip(marks, marks[1:]):
            if a in keys and keys[a] != held:
                e.set_keys(keys[a])
                held = keys[a]
            if b > a:
                hashes += e.runhash(b - a)
            if b in shots:
                e.shot(os.path.join(envdir, f'f{b}.ppm'))
        if watching:
            n, pc, at = e.cmd('pcwatch').split()
            r['wild_pc'] = {'count': int(n), 'first': pc, 'frame': int(at)} if int(n) else None
        try:
            p = os.path.join(envdir, 'save.bin')
            e.cmd(f'savedata {p}')
            data = open(p, 'rb').read() if os.path.exists(p) else b''
            r['save_size'] = len(data)
            # erased chips read 0xFF; mGBA fills a 4 Kbit EEPROM it later
            # widens to 64 Kbit with zeros, so neither byte counts as written
            r['save_used'] = len(data) - data.count(b'\xff') - data.count(b'\x00') > 0
        except emu.DriverError as x:
            r['save_error'] = str(x)[:120]
    except Exception as x:              # noqa: BLE001 -- a driver dying is a result
        r['crash'] = str(x)[:300]
    finally:
        if e:
            e.kill()
    r['frames_run'] = len(hashes)
    r['seconds'] = round(time.time() - started, 1)
    r.update(hash_stats(hashes, frames))
    r.update(audio_stats(audio, len(hashes), gain(name)))
    if os.path.exists(audio):
        os.remove(audio)
    r['shots'] = {}
    for f in shots:
        p = os.path.join(envdir, f'f{f}.ppm')
        if os.path.exists(p):
            px = img.read_ppm(p)
            q = img.to555(px).reshape(-1, 3)
            r['shots'][str(f)] = {'colours': int(len(np.unique(q[:, 0] * 1024 + q[:, 1] * 32 + q[:, 2]))),
                             'blank': img.is_blank(px)}
    with open(os.path.join(envdir, 'hashes.txt'), 'w') as fh:
        fh.write(' '.join(hashes))
    return r


def hash_stats(h, frames):
    if not h:
        return {'distinct': 0, 'tail_frozen': 0, 'late_distinct': 0}
    run = 1
    for k in range(len(h) - 1, 0, -1):
        if h[k] != h[k - 1]:
            break
        run += 1
    late = h[len(h) * 3 // 5:]
    return {'distinct': len(set(h[QUIET:])), 'tail_frozen': run,
            'late_distinct': len(set(late))}


def audio_stats(path, frames, g=1.0):
    """RMS of the mid signal per second over the run, after the quiet boot,
    scaled to mGBA's level (`g`)."""
    if not os.path.exists(path) or os.path.getsize(path) < 4 or not frames:
        return {'rms': None}
    a = np.fromfile(path, dtype='<i2').astype(np.float32)
    a = a[: len(a) // 2 * 2].reshape(-1, 2).mean(axis=1)
    per = int(AUDIO_RATE / FPS * 60)
    start = int(AUDIO_RATE / FPS * QUIET)
    secs = [a[i:i + per] for i in range(start, len(a) - per + 1, per)]
    rms = [float(np.sqrt(np.mean(s * s))) * g for s in secs]
    if not rms:
        return {'rms': None}
    return {'rms': round(float(np.median(rms)), 1), 'rms_max': round(max(rms), 1),
            'audible_secs': sum(1 for x in rms if x > 30), 'secs': len(rms),
            'per_sec': [round(x) for x in rms]}


def verdict(d, ref):
    """Flags where dingbat (`d`) fails grossly against one reference."""
    flags = []
    if d.get('wild_pc'):
        flags.append('wild-pc')
    if d.get('crash') and not ref.get('crash'):
        flags.append('crash')
    if ref.get('crash'):
        return flags
    rl, dl = ref.get('late_distinct', 0), d.get('late_distinct', 0)
    if d.get('tail_frozen', 0) > 900 and ref.get('tail_frozen', 0) < 300 and rl > 20:
        flags.append('hang')
    late = [f for f in SHOTS[2:]]
    db = sum(1 for f in late if d['shots'].get(str(f), {}).get('blank'))
    rb = sum(1 for f in late if ref['shots'].get(str(f), {}).get('blank'))
    if db >= 2 and rb == 0:
        flags.append('blank')
    if ref.get('distinct', 0) > 60 and d.get('distinct', 0) * 4 < ref['distinct']:
        flags.append('few')
    ra, da = ref.get('audible_secs') or 0, d.get('audible_secs') or 0
    if ra >= 10 and da * 4 < ra:
        flags.append('silent')
    if ref.get('save_used') and not d.get('save_used'):
        flags.append('save-unwritten')
    rs, ds = ref.get('save_size'), d.get('save_size')
    if rs and ds is not None and rs != ds and not ({rs, ds} == {512, 8192}) and ref.get('save_used'):
        flags.append(f'save-size {ds}!={rs}')
    return flags


def sweep_one(rom, frames, outdir, emus):
    title = os.path.splitext(os.path.basename(rom))[0]
    gdir = os.path.join(outdir, 'games', img_slug(title))
    res = {'title': title, 'rom': rom, 'frames': frames, 'emus': {}}
    for name in emus:
        res['emus'][name] = play(name, rom, os.path.join(gdir, name), frames)
    flag_game(res)
    with open(os.path.join(gdir, 'result.json'), 'w') as f:
        json.dump(res, f, indent=1)
    return res


def flag_game(res):
    e = res['emus']
    res['flags'] = {}
    for d in [n for n in e if n.startswith('dingbat')]:
        for ref in [n for n in e if n in emu.REFERENCES]:
            fl = verdict(e[d], e[ref])
            if fl:
                res['flags'][f'{d}/{ref}'] = fl
    return res


def img_slug(title):
    return ''.join(c if c.isalnum() or c in '-._' else '-' for c in title).strip('-')


def composite(gdir, emus):
    """One PNG per game: every emulator's screenshots, a row each."""
    rows = []
    for name in emus:
        frames = []
        for f in SHOTS:
            p = os.path.join(gdir, name, f'f{f}.ppm')
            frames.append(img.read_ppm(p) if os.path.exists(p)
                          else np.zeros((160, 240, 3), np.uint8))
        rows.append(img.composite(frames, [f'{name} f{f}' for f in SHOTS], scale=1))
    w = max(r.shape[1] for r in rows)
    rows = [np.pad(r, ((0, 0), (0, w - r.shape[1]), (0, 0))) for r in rows]
    img.write_png(os.path.join(gdir, 'compare.png'), np.vstack(rows))


def _one(job):
    rom, frames, outdir, emus, deadline = job
    signal.signal(signal.SIGALRM, lambda *a: (_ for _ in ()).throw(
        TimeoutError(f'no answer within {deadline}s')))
    signal.alarm(deadline)
    try:
        return sweep_one(rom, frames, outdir, emus)
    except Exception as x:              # noqa: BLE001
        return {'title': os.path.basename(rom), 'rom': rom, 'error': str(x)[:200],
                'flags': {}, 'emus': {}}
    finally:
        signal.alarm(0)


def line(r):
    if 'error' in r:
        return f'{r["title"][:56]:<58}error: {r["error"][:70]}'
    fl = '; '.join(f'{k}: {",".join(v)}' for k, v in r['flags'].items())
    d = r['emus'].get('dingbat') or next(iter(r['emus'].values()))
    return f'{r["title"][:56]:<58}{d.get("seconds", 0):5.1f}s  {fl}'


def run_many(roms, frames, outdir, emus, jobs, deadline):
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, 'results.json')
    try:
        results = {r['rom']: r for r in json.load(open(path))}
    except (OSError, ValueError):
        results = {}
    todo = [(r, frames, outdir, emus, deadline) for r in roms]
    if jobs > 1:
        import multiprocessing
        pool = multiprocessing.Pool(jobs)
        stream = pool.imap_unordered(_one, todo)
    else:
        stream = map(_one, todo)
    for r in stream:
        print(line(r), flush=True)
        old = results.get(r['rom'])
        if old and 'emus' in old and 'error' not in r:
            old['emus'].update(r['emus'])
            r['emus'] = old['emus']
            flag_game(r)
        results[r['rom']] = r
        with open(path, 'w') as f:
            json.dump(list(results.values()), f, indent=1)
    return list(results.values())


def report(outdir):
    results = json.load(open(os.path.join(outdir, 'results.json')))
    flagged = [r for r in results if r.get('flags') or 'error' in r]
    print(f'{len(results)} games, {len(flagged)} flagged\n')
    for r in sorted(flagged, key=lambda r: r['title']):
        print(line(r))
        gdir = os.path.join(outdir, 'games', img_slug(r['title']))
        if r.get('emus') and os.path.isdir(gdir):
            composite(gdir, list(r['emus']))
    return 0


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('verb', choices=['run', 'sweep', 'recheck', 'report'])
    ap.add_argument('names', nargs='*')
    ap.add_argument('--list', help='JSON list of ROM file names or paths')
    ap.add_argument('--tag', default='default')
    ap.add_argument('--frames', type=int, default=3000)
    ap.add_argument('--jobs', type=int, default=1)
    ap.add_argument('--emus', default='dingbat,mgba')
    ap.add_argument('--deadline', type=int, default=300)
    args = ap.parse_args(argv[1:])
    outdir = os.path.join(OUT, args.tag)
    emus = args.emus.split(',')
    if args.verb == 'report':
        return report(outdir)
    if args.verb == 'recheck':
        results = json.load(open(os.path.join(outdir, 'results.json')))
        roms = [r['rom'] for r in results if r.get('flags') or 'error' in r]
    elif args.verb == 'run':
        lib = library.Library(CACHE)
        roms = [n if os.path.exists(n) else lib.find(n) for n in args.names]
    else:
        names = json.load(open(args.list))
        roms = []
        for n in names:
            if os.path.exists(n):
                roms.append(n)
            else:
                for d in library.DEFAULT_DIRS:
                    if os.path.exists(os.path.join(d, n)):
                        roms.append(os.path.join(d, n))
                        break
    roms = [r for r in roms if r]
    run_many(roms, args.frames, outdir, emus, args.jobs, args.deadline)
    return report(outdir) if args.verb != 'run' else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
