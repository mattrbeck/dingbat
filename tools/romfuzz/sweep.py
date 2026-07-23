#!/usr/bin/env python3
"""Cross-emulator ROM sweep: run each title through mGBA, NanoBoyAdvance and
dingbat (HLE + real BIOS), screenshot at checkpoints, diff perceptually,
verify divergences against reference bursts to cancel frame skew.

Usage: sweep.py <workdir> [--jobs N] [--titles substr]
  workdir needs: selected_roms.json (title -> rom basename), roms/<basename>
Outputs: <workdir>/runs/<slug>/..., <workdir>/results.json
"""
import concurrent.futures as cf
import json, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import imgdiff

BIOS = os.path.expanduser('~/code/dingbat/tests/roms/gba_bios.bin')
RUNNERS = {
    'mgba':  [os.path.join(HERE, 'mgba_runner')],
    'nba':   [os.path.join(HERE, 'nba_runner')],
    'dhle':  [os.path.join(HERE, 'dingbat_nav')],
    'dreal': [os.path.join(HERE, 'dingbat_nav')],
}
SCRIPT = '300:START,500:START,820:START,1220:A,1620:A'
SHOTS = [800, 1200, 1600, 2000]
BURST = list(range(-45, 50, 5))  # verification window around a checkpoint

def slugify(title):
    return re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')

def run_one(emu, rom, outprefix, script, shots, state=False):
    shots_arg = ','.join(str(s) for s in shots)
    cmd = list(RUNNERS[emu])
    if emu == 'mgba' or emu == 'nba':
        cmd += [rom, BIOS, outprefix, script, shots_arg]
    elif emu == 'dhle':
        cmd += [rom, 'hle', outprefix, script, shots_arg]
    else:
        cmd += [rom, BIOS, outprefix, script, shots_arg]
    if state:
        cmd.append('--state')
    r = subprocess.run(cmd, capture_output=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError(f'{emu} failed: {r.stderr.decode()[-300:]}')

def sweep_title(workdir, title, rom_base):
    slug = slugify(title)
    rundir = os.path.join(workdir, 'runs', slug)
    os.makedirs(rundir, exist_ok=True)
    # isolate save files: each emulator variant gets its own copy of the ROM
    result = {'title': title, 'rom': rom_base, 'slug': slug, 'shots': {}, 'error': None}
    try:
        # A reference emulator crashing on a ROM (NBA segfaults on Pokemon
        # Pinball R&S) shouldn't fail the title — fall back to the other
        # reference and record the crash.
        ref_crashed = None
        for emu in RUNNERS:
            emudir = os.path.join(rundir, emu)
            os.makedirs(emudir, exist_ok=True)
            romcopy = os.path.join(emudir, 'rom.gba')
            if not os.path.exists(romcopy):
                shutil.copy(os.path.join(workdir, 'roms', rom_base), romcopy)
            try:
                run_one(emu, romcopy, os.path.join(emudir, emu), SCRIPT, SHOTS,
                        state=(emu == 'dhle'))
            except Exception:
                if emu == 'nba':
                    ref_crashed = 'nba'
                else:
                    raise
        if ref_crashed:
            result['ref_crashed'] = ref_crashed
        MARK = {'verdict': 'REF-CRASH', 'exact': 0, 'mae': 0,
                'phash_hamming': 0, 'ncc': 0}
        for f in SHOTS:
            shot = {}
            paths = {e: os.path.join(rundir, e, f'{e}.f{f:04}.ppm') for e in RUNNERS}
            have_nba = ref_crashed != 'nba'
            shot['ref_control'] = imgdiff.metrics(paths['mgba'], paths['nba']) if have_nba else dict(MARK)
            shot['dhle_vs_mgba'] = imgdiff.metrics(paths['mgba'], paths['dhle'])
            shot['dhle_vs_nba'] = imgdiff.metrics(paths['nba'], paths['dhle']) if have_nba else dict(MARK)
            shot['dreal_vs_mgba'] = imgdiff.metrics(paths['mgba'], paths['dreal'])
            result['shots'][f] = shot
        # Final verdict: dingbat passes a checkpoint if it matches EITHER
        # reference. When both direct comparisons fail, re-check against
        # reference bursts around the checkpoint to cancel lag-frame skew
        # (emulators accumulate different lag, so inputs can land on
        # different screens — mGBA and NBA regularly diverge from each
        # other this way too).
        OK = ('IDENTICAL', 'MINOR')
        RANK = ['IDENTICAL', 'MINOR', 'DIFFERENT', 'MAJOR']
        for f in SHOTS:
            shot = result['shots'][f]
            direct = min((v for v in (shot['dhle_vs_mgba']['verdict'],
                                      shot['dhle_vs_nba']['verdict']) if v in RANK),
                         key=RANK.index)
            if direct in OK:
                shot['final'] = direct
                continue
            dshot = os.path.join(rundir, 'dhle', f'dhle.f{f:04}.ppm')
            burst_frames = sorted(set(max(1, f + d) for d in BURST))
            best_overall = direct
            for ref in ('mgba', 'nba'):
                if ref == ref_crashed:
                    continue
                emudir = os.path.join(rundir, ref)
                run_one(ref, os.path.join(emudir, 'rom.gba'),
                        os.path.join(emudir, f'burst{f}'), SCRIPT, burst_frames)
                best = None
                for bf in burst_frames:
                    m = imgdiff.metrics(
                        os.path.join(emudir, f'burst{f}.f{bf:04}.ppm'), dshot)
                    key = (m['verdict'] in OK, m['ncc'])
                    if best is None or key > best[0]:
                        best = (key, bf, m)
                shot[f'skew_{ref}'] = {'best_frame': best[1], **best[2]}
                best_overall = min((best_overall, best[2]['verdict']), key=RANK.index)
            shot['final'] = best_overall
    except Exception as e:
        result['error'] = str(e)[-500:]
    return result

def main():
    workdir = sys.argv[1]
    jobs = 6
    title_filter = None
    selected = 'selected_roms.json'
    out = 'results.json'
    args = sys.argv[2:]
    while args:
        a = args.pop(0)
        if a == '--jobs': jobs = int(args.pop(0))
        elif a == '--titles': title_filter = args.pop(0).lower()
        elif a == '--selected': selected = args.pop(0)
        elif a == '--out': out = args.pop(0)
    sel = json.load(open(os.path.join(workdir, selected)))
    if title_filter:
        sel = {t: r for t, r in sel.items() if title_filter in t.lower()}
    results = []
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(sweep_title, workdir, t, r): t for t, r in sorted(sel.items())}
        for fut in cf.as_completed(futs):
            res = fut.result()
            results.append(res)
            worst = 'ERROR' if res['error'] else max(
                (s['final'] for s in res['shots'].values()),
                key=['IDENTICAL', 'MINOR', 'DIFFERENT', 'MAJOR'].index, default='?')
            print(f"[{len(results)}/{len(futs)}] {res['title']}: {worst}", flush=True)
    results.sort(key=lambda r: r['title'])
    json.dump(results, open(os.path.join(workdir, out), 'w'), indent=1)
    print('wrote', os.path.join(workdir, out))

if __name__ == '__main__':
    main()
