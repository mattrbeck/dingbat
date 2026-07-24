#!/usr/bin/env python3
"""Cross-emulator GB/GBC ROM sweep: run each title through SameBoy, mGBA and
dingbat, screenshot at checkpoints, diff perceptually, verify divergences
against reference bursts to cancel frame skew.

Usage: sweep.py <workdir> [--jobs N] [--titles substr] [--selected f] [--out f]
  workdir needs: selected_roms.json (title -> rom basename), roms/<basename>,
                 boot/{dmg,cgb}_boot.bin
Outputs: <workdir>/runs/<slug>/..., <workdir>/<out>

ROMs never live in the repo — <workdir> is expected to be outside it.
"""
import concurrent.futures as cf
import json, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'romfuzz'))
import imgdiff

RUNNERS = {
    'sameboy': [os.path.join(HERE, 'sameboy_runner')],
    'mgba':    [os.path.join(HERE, 'mgba_gb_runner')],
    'dingbat': [os.path.join(HERE, 'dingbat_gb_nav')],
}
REFS = ('sameboy', 'mgba')
# Start, then A repeatedly: the generic "get through the title screen and the
# first menus" pattern. Checkpoints sit between input bursts so each shot lands
# on a different stage of the game. Frame 0 is power-on and every runner plays
# the boot ROM, so the first input waits out the CGB boot animation (~200
# frames; the DMG one is ~60).
SCRIPT = '260:START,420:A,600:START,800:A,1000:A,1250:START,1500:A'
SHOTS = [350, 700, 1150, 1650]
# Verification window around a checkpoint. Wide on purpose: a cutscene that
# one emulator lets run a second longer than another puts the scripted A press
# on a different screen, and the resulting offset is far larger than the
# frame-or-two of lag skew a narrow window cancels.
BURST = list(range(-150, 151, 10))
AUTO_NOINPUT = False   # for flagged titles, also compare a no-input run
PRUNE_CLEAN = False    # delete run artifacts for clean titles (bulk mode)
TIMEOUT = 600

OK = ('IDENTICAL', 'MINOR')
RANK = ['IDENTICAL', 'MINOR', 'DIFFERENT', 'MAJOR']


def slugify(title):
    return re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')


def run_one(workdir, emu, rom, outprefix, script, shots, state=False):
    shots_arg = ','.join(str(s) for s in shots)
    cmd = list(RUNNERS[emu]) + [rom, os.path.join(workdir, 'boot'), outprefix,
                                script, shots_arg]
    if state:
        cmd.append('--state')
    r = subprocess.run(cmd, capture_output=True, timeout=TIMEOUT)
    if r.returncode != 0:
        raise RuntimeError(f'{emu} rc={r.returncode}: {r.stderr.decode()[-300:]}')


def sweep_title(workdir, title, rom_base):
    slug = slugify(title)
    rundir = os.path.join(workdir, 'runs', slug)
    os.makedirs(rundir, exist_ok=True)
    ext = os.path.splitext(rom_base)[1] or '.gb'
    result = {'title': title, 'rom': rom_base, 'slug': slug, 'shots': {},
              'error': None}
    try:
        # Each emulator gets its own copy of the ROM so battery saves written
        # by one run cannot leak into another's boot path.
        ref_crashed = None
        for emu in RUNNERS:
            emudir = os.path.join(rundir, emu)
            os.makedirs(emudir, exist_ok=True)
            romcopy = os.path.join(emudir, 'rom' + ext)
            if not os.path.exists(romcopy):
                shutil.copy(os.path.join(workdir, 'roms', rom_base), romcopy)
            try:
                run_one(workdir, emu, romcopy, os.path.join(emudir, emu),
                        SCRIPT, SHOTS, state=(emu == 'dingbat'))
            except Exception as e:
                # A reference crashing on a ROM shouldn't fail the title — fall
                # back to the other reference and record the crash. Only one
                # reference may drop out; losing both leaves nothing to compare.
                if emu in REFS and ref_crashed is None:
                    ref_crashed = emu
                    result['ref_crash_msg'] = str(e)[-200:]
                else:
                    raise
        if ref_crashed:
            result['ref_crashed'] = ref_crashed
        MARK = {'verdict': 'REF-CRASH', 'exact': 0, 'mae': 0,
                'phash_hamming': 0, 'ncc': 0}
        live_refs = [r for r in REFS if r != ref_crashed]
        for f in SHOTS:
            shot = {}
            paths = {e: os.path.join(rundir, e, f'{e}.f{f:04}.ppm') for e in RUNNERS}
            shot['ref_control'] = (imgdiff.metrics(paths['sameboy'], paths['mgba'])
                                   if not ref_crashed else dict(MARK))
            for ref in REFS:
                shot[f'dingbat_vs_{ref}'] = (
                    imgdiff.metrics(paths[ref], paths['dingbat'])
                    if ref in live_refs else dict(MARK))
            result['shots'][f] = shot
        # Final verdict: dingbat passes a checkpoint if it matches EITHER
        # reference. When both direct comparisons fail, re-check against
        # reference bursts around the checkpoint to cancel lag-frame skew
        # (emulators accumulate different lag, so inputs can land on different
        # screens — the two references diverge from each other this way too).
        for f in SHOTS:
            shot = result['shots'][f]
            direct = min((shot[f'dingbat_vs_{r}']['verdict'] for r in REFS
                          if shot[f'dingbat_vs_{r}']['verdict'] in RANK),
                         key=RANK.index, default='MAJOR')
            if direct in OK:
                shot['final'] = direct
                continue
            dshot = os.path.join(rundir, 'dingbat', f'dingbat.f{f:04}.ppm')
            burst_frames = sorted(set(max(1, f + d) for d in BURST))
            best_overall = direct
            for ref in live_refs:
                emudir = os.path.join(rundir, ref)
                run_one(workdir, ref, os.path.join(emudir, 'rom' + ext),
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
        worst = max((s['final'] for s in result['shots'].values()),
                    key=RANK.index, default='IDENTICAL')
        # Auto-triage: a flagged title gets a no-input control run — screens
        # converge on static screens, so a clean no-input comparison means the
        # scripted divergence was input-landing skew, not a real bug.
        if AUTO_NOINPUT and worst not in OK:
            try:
                for emu in ('dingbat', 'sameboy'):
                    run_one(workdir, emu, os.path.join(rundir, emu, 'rom' + ext),
                            os.path.join(rundir, emu, 'noinput'), '', [1650])
                result['noinput_f1650'] = imgdiff.metrics(
                    os.path.join(rundir, 'sameboy', 'noinput.f1650.ppm'),
                    os.path.join(rundir, 'dingbat', 'noinput.f1650.ppm'))
            except Exception as e:
                result['noinput_f1650'] = {'verdict': 'ERROR', 'err': str(e)[-100:]}
        if PRUNE_CLEAN:
            ni = result.get('noinput_f1650', {}).get('verdict')
            if worst in OK or ni in OK:
                shutil.rmtree(rundir, ignore_errors=True)
    except Exception as e:
        result['error'] = str(e)[-500:]
    return result


def worst_of(res):
    if res['error']:
        return 'ERROR'
    return max((s['final'] for s in res['shots'].values()), key=RANK.index,
               default='?')


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
        elif a == '--auto-noinput':
            global AUTO_NOINPUT; AUTO_NOINPUT = True
        elif a == '--prune-clean':
            global PRUNE_CLEAN; PRUNE_CLEAN = True
    sel = json.load(open(os.path.join(workdir, selected)))
    if title_filter:
        sel = {t: r for t, r in sel.items() if title_filter in t.lower()}
    results = []
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(sweep_title, workdir, t, r): t for t, r in sorted(sel.items())}
        for fut in cf.as_completed(futs):
            res = fut.result()
            results.append(res)
            print(f"[{len(results)}/{len(futs)}] {res['title']}: {worst_of(res)}",
                  flush=True)
    results.sort(key=lambda r: r['title'])
    json.dump(results, open(os.path.join(workdir, out), 'w'), indent=1)
    print('wrote', os.path.join(workdir, out))


if __name__ == '__main__':
    main()
