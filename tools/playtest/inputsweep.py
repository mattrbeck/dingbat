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
              some, a different chip size, far fewer bytes written)

`--pattern deep` (with `--frames 12000`) plays longer and harder: the same
START/A beat for half a minute, then ten-second blocks of held directions
with A and B, button mashing, START/A beats, and save attempts (START, a few
DOWNs, A to confirm, B to back out), the blocks chosen per game by a seeded
generator so every emulator gets the same timeline. It adds:

    reset     the boot's fade frames (the first 300, before any input) come
              back later in a run: the game started over
    freeze    the screen stops changing for half a minute mid-run and the
              reference never does
    frozen-audio  ... while the sound plays on
    garbage   the screenshots are noise (many distinct 8x8 tiles, most
              neighbouring pixels different) where the reference's are not

Timing slips are expected (the emulators accumulate lag frames differently,
docs/playtest-bugs.md section 29), so the same key press can land on a
different frame in each and a game's path can fork. Nothing here compares
frames one to one; every check is a gross property of the whole run, and a
flag is only a lead until the screenshots (written per game beside the
result) say otherwise.

    inputsweep.py pool [--list pool.json]   # the candidate list: one dump per
                                    # title, no hacks or demos, no title a
                                    # playtest script or games.json covers
    inputsweep.py run <rom-or-sha1> [...] [--emus dingbat,mgba]
    inputsweep.py sweep --list pool.json [--jobs 6] [--tag NAME]
                    [--pattern deep --frames 12000]
    inputsweep.py recheck --tag NAME [--emus dingbat-bios,nba]
                                    # flagged games again in more emulators
    inputsweep.py report --tag NAME

ROMs are only ever symlinked into private environment directories (emu.py),
so no battery file lands in the library.
"""
import argparse
import glob
import json
import os
import random
import re
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


def shots_for(frames, pattern):
    """Screenshot frames: SHOTS for the 3000-frame beat, else every 600
    frames (1500 past 3000) and the last."""
    if pattern == 'beat' and frames == SHOTS[-1]:
        return SHOTS
    step = 600 if frames <= 3000 else 1500
    return tuple(list(range(step, frames, step)) + [frames])


def schedule(frames, pattern='beat', seed=0):
    """(frame, key mask) changes. 'beat': START and A alternately, held HOLD
    frames, one every BEAT frames after QUIET -- START first so a title
    screen goes; then A for 'new game', dialogue and menus. 'deep':
    deep_schedule()."""
    if pattern == 'deep':
        return deep_schedule(frames, seed)
    out = [(0, 0)]
    k = 0
    for f in range(QUIET, frames, BEAT):
        key = 'START' if k % 2 == 0 else 'A'
        out += [(f, emu.key_mask([key])), (f + HOLD, 0)]
        k += 1
    return out


DEEP_BEAT_END = 2100
DEEP_BLOCK = 600
DIRS = ['RIGHT', 'RIGHT', 'LEFT', 'UP', 'DOWN']


def deep_schedule(frames, seed):
    """The quiet boot, the START/A beat up to DEEP_BEAT_END, then 600-frame
    blocks. Buttons are pressed one at a time (with at most one held
    direction), so no soft-reset chord (A+B+START+SELECT) ever forms, and
    SELECT is never pressed. Every third block from the second is a save
    attempt."""
    rng = random.Random(seed)
    btn = [0] * (frames + 1)    # buttons tapped
    dirn = [0] * (frames + 1)   # held direction

    def tap(f, key, hold=HOLD):
        for x in range(f, min(f + hold, frames)):
            btn[x] = emu.key_mask([key])

    def held(a, b, key):
        for x in range(a, min(b, frames)):
            dirn[x] = emu.key_mask([key])

    k = 0
    for f in range(QUIET, min(DEEP_BEAT_END, frames), BEAT):
        tap(f, 'START' if k % 2 == 0 else 'A')
        k += 1
    n = 0
    for b0 in range(DEEP_BEAT_END, frames, DEEP_BLOCK):
        kind = 'save' if n % 3 == 1 else rng.choice(['walk', 'walk', 'mash', 'beat', 'walkmash'])
        n += 1
        if kind == 'save':
            # START opens most games' menu; SAVE is often a few entries down;
            # A, then A again for "yes" / overwrite / the slot; B backs out
            tap(b0, 'START')
            f = b0 + 60
            for _ in range(rng.randrange(0, 6)):
                tap(f, 'DOWN', 4)
                f += 16
            for _ in range(4):
                f += 50
                tap(f, 'A')
            f += 180
            for _ in range(3):
                tap(f, 'B')
                f += 40
            tap(f + 40, 'START')
            for x in range(f + 120, b0 + DEEP_BLOCK - 20, 40):
                tap(x, 'A')
        elif kind in ('walk', 'walkmash'):
            # a held direction (a new one every 150 frames), A to jump,
            # attack or talk every 24 frames (12 when mashing), B every 90
            for s in range(b0, b0 + DEEP_BLOCK, 150):
                held(s, s + 140, rng.choice(DIRS))
            every = 12 if kind == 'walkmash' else 24
            for x in range(b0, b0 + DEEP_BLOCK, every):
                tap(x, 'A', 4)
            for x in range(b0 + 45, b0 + DEEP_BLOCK, 90):
                tap(x, 'B', 4)
        elif kind == 'mash':
            for x in range(b0, b0 + 300, 10):
                tap(x, 'A', 4)
            for x in range(b0 + 300, b0 + 400, 10):
                tap(x, 'B', 4)
            for x in range(b0 + 400, b0 + DEEP_BLOCK, 20):
                tap(x, 'DOWN' if (x // 20) % 3 == 0 else 'A', 4)
        else:
            for i, x in enumerate(range(b0, b0 + DEEP_BLOCK, 40)):
                tap(x, 'START' if i % 4 == 0 else 'A')
    out = []
    prev = None
    for f in range(frames):
        v = btn[f] | dirn[f]
        if v != prev:
            out.append((f, v))
            prev = v
    return out


def play(name, rom, envdir, frames, shots=SHOTS, pattern='beat', seed=0):
    """One emulator's run: every frame's hash, screenshots, audio, save."""
    audio = os.path.join(envdir + '-audio.raw')
    r = {'emu': name}
    started = time.time()
    e = None
    hashes = []
    sched = schedule(frames, pattern, seed)
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
        marks = sorted(x for x in set([f for f, _ in sched] + list(shots) + [frames]) if x <= frames)
        keys = dict(sched)
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
            r['save_bytes'] = len(data) - data.count(b'\xff') - data.count(b'\x00')
            r['save_used'] = r['save_bytes'] > 0
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
            r['shots'][str(f)] = shot_stats(img.read_ppm(p))
    with open(os.path.join(envdir, 'hashes.txt'), 'w') as fh:
        fh.write(' '.join(hashes))
    return r


def shot_stats(px):
    """Colours, blankness, and how noisy the picture is: distinct 8x8 tiles
    (of 600) and the share of horizontally neighbouring pixels that differ.
    Real screens repeat tiles (sky, ground, text background) and run in
    flat spans; garbage -- tiles drawn from the wrong VRAM -- does neither."""
    q = img.to555(px).astype(np.int32)
    c = q[..., 0] * 1024 + q[..., 1] * 32 + q[..., 2]
    tiles = c.reshape(20, 8, 30, 8).transpose(0, 2, 1, 3).reshape(600, 64)
    return {'colours': int(len(np.unique(c))), 'blank': img.is_blank(px),
            'tiles': int(len(np.unique(tiles, axis=0))),
            'noise': round(float(np.mean(c[:, 1:] != c[:, :-1])), 3)}


def hash_stats(h, frames):
    if not h:
        return {'distinct': 0, 'tail_frozen': 0, 'late_distinct': 0}
    run = 1
    for k in range(len(h) - 1, 0, -1):
        if h[k] != h[k - 1]:
            break
        run += 1
    late = h[len(h) * 3 // 5:]
    # the longest stretch of one unchanging frame after the quiet boot
    best, best_at, cur, at = 0, QUIET, 1, QUIET
    for k in range(QUIET + 1, len(h)):
        if h[k] == h[k - 1]:
            cur += 1
        else:
            cur, at = 1, k
        if cur > best:
            best, best_at = cur, at
    return {'distinct': len(set(h[QUIET:])), 'tail_frozen': run,
            'late_distinct': len(set(late)), 'max_frozen': best,
            'max_frozen_at': best_at, 'resets': resets(h)}


def resets(h):
    """Where the boot comes back: hashes the first QUIET frames show only
    briefly (a logo's fade, not a held black or title screen) seen again
    after frame 900, six or more distinct ones inside 180 frames. Returns
    the frame each return starts at."""
    from collections import Counter
    fade = {x for x, n in Counter(h[:QUIET]).items() if n <= 4}
    if len(fade) < 8:
        return []
    out = []
    k = 900
    while k < len(h):
        if h[k] in fade and len({x for x in h[k:k + 180] if x in fade}) >= 6:
            out.append(k)
            k += 600
        else:
            k += 1
    return out


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


def audible_during(r, a, b):
    """Share of the seconds of frames [a, b) with sound (per_sec starts at
    QUIET, one entry per 60 frames)."""
    ps = r.get('per_sec') or []
    span = ps[max(0, (a - QUIET) // 60):max(0, (b - QUIET) // 60)]
    return sum(1 for x in span if x > 30) / len(span) if span else 0.0


def garbage(shot):
    return shot.get('tiles', 0) >= GARBAGE_TILES and shot.get('noise', 0) >= GARBAGE_NOISE


GARBAGE_TILES = 420
GARBAGE_NOISE = 0.55


def verdict(d, ref):
    """Flags where dingbat (`d`) fails grossly against one reference."""
    flags = []
    if d.get('wild_pc'):
        flags.append('wild-pc')
    if d.get('crash') and not ref.get('crash'):
        flags.append('crash')
    if ref.get('crash'):
        return flags
    rl = ref.get('late_distinct', 0)
    if d.get('tail_frozen', 0) > 900 and ref.get('tail_frozen', 0) < 300 and rl > 20:
        flags.append('hang')
    elif d.get('max_frozen', 0) >= 1800 and ref.get('max_frozen', 0) < 600:
        a = d['max_frozen_at']
        flags.append('frozen-audio' if audible_during(d, a, a + d['max_frozen']) >= 0.5
                     else 'freeze')
    shots = sorted(d['shots'], key=int)
    late = shots[len(shots) * 2 // 5:]
    db = sum(1 for f in late if d['shots'].get(f, {}).get('blank'))
    rb = sum(1 for f in late if ref['shots'].get(f, {}).get('blank'))
    if db >= 2 and rb == 0:
        flags.append('blank')
    dg = sum(1 for f in shots if garbage(d['shots'][f]))
    rg = sum(1 for f in shots if garbage(ref['shots'].get(f, {})))
    if dg and not rg:
        flags.append('garbage')
    if ref.get('distinct', 0) > 60 and d.get('distinct', 0) * 4 < ref['distinct']:
        flags.append('few')
    if len(d.get('resets') or []) > len(ref.get('resets') or []):
        flags.append('reset')
    ra, da = ref.get('audible_secs') or 0, d.get('audible_secs') or 0
    if ra >= 10 and da * 4 < ra:
        flags.append('silent')
    if ref.get('save_used') and not d.get('save_used'):
        flags.append('save-unwritten')
    elif ref.get('save_bytes', 0) >= 64 and d.get('save_bytes', 0) * 8 < ref['save_bytes']:
        flags.append('save-short')
    rs, ds = ref.get('save_size'), d.get('save_size')
    if rs and ds is not None and rs != ds and not ({rs, ds} == {512, 8192}) and ref.get('save_used'):
        flags.append(f'save-size {ds}!={rs}')
    return flags


def seed_of(title):
    return sum(ord(c) * (i + 1) for i, c in enumerate(title)) & 0xFFFFFFFF


def sweep_one(rom, frames, outdir, emus, pattern='beat'):
    title = os.path.splitext(os.path.basename(rom))[0]
    gdir = os.path.join(outdir, 'games', img_slug(title))
    shots = shots_for(frames, pattern)
    res = {'title': title, 'rom': rom, 'frames': frames, 'pattern': pattern,
           'shots': list(shots), 'emus': {}}
    for name in emus:
        res['emus'][name] = play(name, rom, os.path.join(gdir, name), frames,
                                 shots, pattern, seed_of(title))
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


def composite(gdir, emus, shots=SHOTS):
    """One PNG per game: every emulator's screenshots, a row each."""
    rows = []
    for name in emus:
        frames = []
        for f in shots:
            p = os.path.join(gdir, name, f'f{f}.ppm')
            frames.append(img.read_ppm(p) if os.path.exists(p)
                          else np.zeros((160, 240, 3), np.uint8))
        rows.append(img.composite(frames, [f'{name} f{f}' for f in shots], scale=1))
    w = max(r.shape[1] for r in rows)
    rows = [np.pad(r, ((0, 0), (0, w - r.shape[1]), (0, 0))) for r in rows]
    img.write_png(os.path.join(gdir, 'compare.png'), np.vstack(rows))


def _one(job):
    rom, frames, outdir, emus, deadline, pattern = job
    signal.signal(signal.SIGALRM, lambda *a: (_ for _ in ()).throw(
        TimeoutError(f'no answer within {deadline}s')))
    signal.alarm(deadline)
    try:
        return sweep_one(rom, frames, outdir, emus, pattern)
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


def run_many(roms, frames, outdir, emus, jobs, deadline, pattern='beat'):
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, 'results.json')
    try:
        results = {r['rom']: r for r in json.load(open(path))}
    except (OSError, ValueError):
        results = {}
    todo = [(r, frames, outdir, emus, deadline, pattern) for r in roms]
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
    """Re-flag every game from its stored measurements (a changed threshold
    needs no rerun), list the flagged ones, and draw their composites."""
    path = os.path.join(outdir, 'results.json')
    results = json.load(open(path))
    for r in results:
        if r.get('emus') and 'error' not in r:
            flag_game(r)
    with open(path, 'w') as f:
        json.dump(results, f, indent=1)
    flagged = [r for r in results if r.get('flags') or 'error' in r]
    print(f'{len(results)} games, {len(flagged)} flagged\n')
    for r in sorted(flagged, key=lambda r: r['title']):
        print(line(r))
        gdir = os.path.join(outdir, 'games', img_slug(r['title']))
        if r.get('emus') and os.path.isdir(gdir):
            composite(gdir, list(r['emus']), r.get('shots') or SHOTS)
    return 0


LIBRARY = os.path.expanduser('~/Documents/emu/gba/archive/roms')
SKIP_WORDS = ('(demo', '-in-1', 'in 1 ', 'bios', '(beta', '(prototype', '(proto', 'gba video',
              'classic nes', 'famicom mini', 'e-reader', '(sample', '(kiosk', 'games in 1',
              'pack', 'hack', 'mb2gba', 'trainer', 'for nds')
BAD_DUMP = re.compile(r'\[(b|f|h|t|a|o|p|T)[^\]]*\]', re.I)
REGION_RANK = {'U': 0, 'UE': 0, 'EU': 1, 'JU': 1, 'E': 2, 'J': 3}


def norm_title(name):
    t = re.sub(r'\(.*?\)|\[.*?\]', '', name[:-4] if name.endswith('.gba') else name)
    t = t.lower().replace("'", '').replace(',', '')
    t = re.sub(r'[^a-z0-9]+', ' ', t).strip()
    return re.sub(r'^the ', '', t)


def build_pool(lib=LIBRARY):
    """One file per title from the archive: good dumps only (no [b] [f] [h]
    [t] [a] [o] [p] [T] tags), no demos, betas, compilations, video carts or
    hacks, the first of USA > Europe > Japan with [!] preferred, and no title
    a playtest script or games.json already covers."""
    covered = set()
    for p in glob.glob(os.path.join(HERE, 'scripts', '*.play')):
        for ln in open(p):
            if ln.startswith('@file') or ln.startswith('@title'):
                covered.add(norm_title(ln.split(None, 1)[1].strip()))
    for g in json.load(open(os.path.join(HERE, 'games.json'))):
        covered.add(norm_title(g['file']))
        covered.add(norm_title(g['title']))
    best = {}
    for n in os.listdir(lib):
        low = n.lower()
        if not low.endswith('.gba') or BAD_DUMP.search(n) or any(w in low for w in SKIP_WORDS):
            continue
        regs = [x for x in re.findall(r'\(([^)]*)\)', n) if x in REGION_RANK]
        if not regs:
            continue
        rank = REGION_RANK[regs[0]] * 2 + (0 if '[!]' in n else 1)
        t = norm_title(n)
        if t not in covered and (t not in best or rank < best[t][0]):
            best[t] = (rank, n)
    return [v[1] for v in sorted(best.values())]


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('verb', choices=['pool', 'run', 'sweep', 'recheck', 'report'])
    ap.add_argument('names', nargs='*')
    ap.add_argument('--list', help='JSON list of ROM file names or paths')
    ap.add_argument('--tag', default='default')
    ap.add_argument('--frames', type=int, default=3000)
    ap.add_argument('--pattern', choices=['beat', 'deep'], default='beat')
    ap.add_argument('--jobs', type=int, default=1)
    ap.add_argument('--emus', default='dingbat,mgba')
    ap.add_argument('--deadline', type=int, default=300)
    args = ap.parse_args(argv[1:])
    outdir = os.path.join(OUT, args.tag)
    emus = args.emus.split(',')
    if args.verb == 'pool':
        pool = build_pool()
        path = args.list or os.path.join(OUT, 'pool.json')
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, 'w') as f:
            json.dump(pool, f, indent=0)
        print(f'{len(pool)} titles -> {path}')
        return 0
    if args.verb == 'report':
        return report(outdir)
    frames, pattern = args.frames, args.pattern
    if args.verb == 'recheck':
        results = json.load(open(os.path.join(outdir, 'results.json')))
        flagged = [r for r in results if r.get('flags') or 'error' in r]
        roms = [r['rom'] for r in flagged]
        if flagged:                     # the timeline the sweep played
            frames = flagged[0].get('frames', frames)
            pattern = flagged[0].get('pattern', pattern)
    elif args.verb == 'run':
        lib = library.Library(CACHE)
        roms = []
        for n in args.names:
            hit = [os.path.join(d, n) for d in library.DEFAULT_DIRS
                   if os.path.exists(os.path.join(d, n))]
            roms.append(n if os.path.exists(n) else hit[0] if hit else lib.find(n))
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
    run_many(roms, frames, outdir, emus, args.jobs, args.deadline, pattern)
    return report(outdir) if args.verb != 'run' else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
