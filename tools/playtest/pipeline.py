"""`playtest.py run`: replay a game's script in every emulator, compare
screens, compare battery files, cross-load every save everywhere, report.

Layout of one run (out/runs/<slug>-<sha1 prefix>/<timestamp>/):
  new/<emu>/            env (ROM symlink + battery file) and checkpoint shots
  saves/<emu>.sav       each emulator's battery file after [new] + quit
  load/<writer>-in-<reader>/   [load] with <writer>'s save seeded into <reader>
  cmp/*.png             side-by-side composites per checkpoint
  results.json, report.html
"""
import concurrent.futures as cf
import datetime
import hashlib
import html
import json
import os
import re
import shutil
import time
import traceback

import classify
import emu as emulib
import img
import runner
import saves
import screen
import script

HERE = os.path.dirname(os.path.abspath(__file__))
SUBJECT_PREFIX = 'dingbat'
last_outdir = None
OK_LOAD = ('IDENTICAL', 'SLIP', 'MINOR')


def sha1_of(path):
    h = hashlib.sha1()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def run_phase(name, rom, steps, workdir, rtc, save_in=None, log=print):
    """One emulator, one section. Never raises: failures are data."""
    t0 = time.time()
    res = {'emu': name, 'ok': False, 'checkpoints': {}, 'error': None}
    reader = screen.ScreenReader()
    e = None
    try:
        e = emulib.Emulator(name, rom, os.path.join(workdir, 'env'), rtc_epoch=rtc, save_in=save_in)
        ex = runner.Executor(e, os.path.join(workdir, 'shots'), reader, log=log)
        try:
            for step in steps:
                ex.do(step)
            res['ok'] = True
        except runner.StepFailed as f:
            res['error'] = f"line {f.step.get('line')}: {script.format_step(f.step)}: {f}"
            fail = os.path.join(workdir, 'shots', 'FAILED.ppm')
            e.shot(fail)
            img.write_png(fail[:-4] + '.png', img.read_ppm(fail))
            res['failed_text'] = reader.read(fail)['text']
        res['checkpoints'] = ex.checkpoints
        res['frame'] = e.frame
        e.quit()
        res['save'] = e.save_path if os.path.exists(e.save_path) else None
    except Exception as exc:  # driver crash, bad ROM, ...
        res['error'] = f'{type(exc).__name__}: {exc}'
        res['trace'] = traceback.format_exc()[-1500:]
        if e:
            e.kill()
    finally:
        reader.close()
    res['seconds'] = round(time.time() - t0, 1)
    log(f"{name}: {'ok' if res['ok'] else 'FAILED'} in {res['seconds']}s" + (f" ({res['error']})" if res['error'] else ''))
    return res


def compare_checkpoints(results, names, subject, cmpdir, tag):
    """Per checkpoint name: composite + subject-vs-reference verdicts."""
    out = {}
    all_cps = []
    for n in names:
        for cp in results[n]['checkpoints']:
            if cp not in all_cps:
                all_cps.append(cp)
    refs = [n for n in names if not n.startswith(SUBJECT_PREFIX)]
    subjects = [n for n in names if n.startswith(SUBJECT_PREFIX)]
    for cp in all_cps:
        entry = {'frames': {n: results[n]['checkpoints'].get(cp, {}).get('frame') for n in names},
                 'text': {n: results[n]['checkpoints'].get(cp, {}).get('text') for n in names},
                 'pairs': {}}
        frames, labels = [], []
        for n in names:
            c = results[n]['checkpoints'].get(cp)
            if c:
                frames.append(img.read_ppm(c['ppm']))
                labels.append(f"{n} f{c['frame']}")
        if frames:
            png = os.path.join(cmpdir, f'{tag}-{cp}.png')
            img.write_png(png, img.composite(frames, labels, scale=1))
            entry['png'] = png
        for s in subjects:
            for r in refs:
                entry['pairs'][f'{s}~{r}'] = classify.classify(results[s]['checkpoints'].get(cp),
                                                               results[r]['checkpoints'].get(cp))
        for i, r1 in enumerate(refs):
            for r2 in refs[i + 1:]:
                entry['pairs'][f'{r1}~{r2}'] = classify.classify(results[r1]['checkpoints'].get(cp),
                                                                 results[r2]['checkpoints'].get(cp))
        # a subject passes a checkpoint by matching ANY reference: the
        # references themselves disagree on animation phase and lag frames
        entry['verdict'] = {s: min((entry['pairs'][f'{s}~{r}']['verdict'] for r in refs),
                                   key=classify.ORDER.index) if refs else 'IDENTICAL'
                            for s in subjects}
        # animation the references disagree on too, plus one-step rounding
        # elsewhere, is not a difference
        for sub in subjects:
            if entry['verdict'][sub] not in ('DIFFERENT', 'MAJOR') or len(refs) < 2:
                continue
            for r in refs:
                o = next(x for x in refs if x != r)
                if classify.within_reference_spread(results[sub]['checkpoints'].get(cp),
                                                    results[r]['checkpoints'].get(cp),
                                                    results[o]['checkpoints'].get(cp)):
                    pair = entry['pairs'][f'{sub}~{r}']
                    pair['verdict'] = 'MINOR'
                    pair['why'] = f'beyond one 5-bit step only where {r} and {o} differ (animation)'
                    entry['verdict'][sub] = 'MINOR'
                    break
        # reference noise: when the references differ from each other at
        # least as much as the subject differs from its closest reference,
        # this checkpoint cannot tell a bug from animation phase
        ref_pairs = [p['verdict'] for k, p in entry['pairs'].items()
                     if not k.startswith(SUBJECT_PREFIX)]
        entry['ref_disagreement'] = classify.worst(ref_pairs) if ref_pairs else None
        entry['noise'] = {s: bool(ref_pairs) and v not in ('IDENTICAL', 'FAILED')
                          and classify.ORDER.index(v) <= classify.ORDER.index(entry['ref_disagreement'])
                          for s, v in entry['verdict'].items()}
        out[cp] = entry
    return out


def run(args):
    rom = os.path.abspath(args.rom)
    sha1 = sha1_of(rom)
    script_path = args.script or os.path.join(HERE, 'scripts', sha1 + '.play')
    if not os.path.exists(script_path):
        print(f'no script for {sha1} ({script_path}); record one with `playtest.py serve`')
        return 2
    play = script.parse(open(script_path).read())
    names = args.emus.split(',')
    info = saves.rom_info(rom)
    slug = re.sub(r'[^a-z0-9]+', '-', play['meta'].get('title', info['title']).lower()).strip('-')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    outdir = os.path.join(args.out, 'runs', f'{slug}-{sha1[:8]}', stamp)
    cmpdir = os.path.join(outdir, 'cmp')
    os.makedirs(cmpdir)
    shutil.copyfile(script_path, os.path.join(outdir, 'script.play'))
    rtc = int(play['meta'].get('rtc', args.rtc))
    print(f"== {play['meta'].get('title', info['title'])} [{info['game_code']}] sha1={sha1} chip={info['chip']} rtc={info['rtc']}")
    print(f'   out: {outdir}')

    report = {'sha1': sha1, 'rom': os.path.basename(rom), 'meta': play['meta'], 'rom_info': info,
              'emulators': names, 'started': stamp}

    # ---------------------------------------------------------- [new]
    with cf.ThreadPoolExecutor(len(names)) as pool:
        futs = {n: pool.submit(run_phase, n, rom, play['new'], os.path.join(outdir, 'new', n), rtc)
                for n in names}
        new = {n: f.result() for n, f in futs.items()}
    report['new'] = {n: _strip(r) for n, r in new.items()}
    report['new_checkpoints'] = compare_checkpoints(new, names, SUBJECT_PREFIX, cmpdir, 'new')

    # ---------------------------------------------------------- saves
    savedir = os.path.join(outdir, 'saves')
    os.makedirs(savedir)
    # `@save none`: the game has no battery save (passwords, or nothing);
    # the check is then that dingbat writes no data, and there is no matrix
    no_save = play['meta'].get('save', '').strip() == 'none'
    report['no_save'] = no_save
    copies, written = {}, {}
    for n in names:
        if new[n].get('save') and new[n]['ok']:
            copies[n] = os.path.join(savedir, n + '.sav')
            shutil.copyfile(new[n]['save'], copies[n])
            if os.path.getsize(copies[n]) > 0 and not no_save:
                written[n] = copies[n]
    report['saves'] = {n: saves.describe(copies.get(n), info) for n in names}
    report['save_pairs'] = {}
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if a in written and b in written:
                report['save_pairs'][f'{a}~{b}'] = saves.compare(written[a], written[b], info)

    # ---------------------------------------------------------- [load] matrix
    load = {}
    if play['load'] and not args.no_cross:
        jobs = {}
        with cf.ThreadPoolExecutor(min(8, len(names) * len(written) or 1)) as pool:
            for w, path in written.items():
                for r in names:
                    wd = os.path.join(outdir, 'load', f'{w}-in-{r}')
                    jobs[(w, r)] = pool.submit(run_phase, r, rom, play['load'], wd, rtc, save_in=path)
            for key, f in jobs.items():
                load[key] = f.result()
        report['load'] = {}
        for (w, r), res in load.items():
            cell = _strip(res)
            seeded = open(written[w], 'rb').read()
            after = open(res['save'], 'rb').read() if res.get('save') else None
            # booting and loading must leave the battery file as it was: the
            # [load] section never saves
            cell['save_unchanged'] = after == seeded
            if after is not None and after != seeded:
                cell['save_after'] = {'size': len(after), 'size_before': len(seeded),
                                      'diff': saves.diff_ranges(seeded[:len(after)], after[:len(seeded)])}
            report['load'][f'{w}-in-{r}'] = cell
        # One save must look the same whichever emulator reads it, so each
        # cell is compared with the other readers of the SAME writer's save.
        # (Different writers' saves legitimately differ: RNG-seeded starters,
        # play time.) load_checkpoints[w-in-r][cp][x] = verdict vs w-in-x.
        report['load_checkpoints'] = {}
        for (w, r), res in load.items():
            cps = {}
            cp_names_row = []
            for x in names:
                for cp in load.get((w, x), {}).get('checkpoints', {}):
                    if cp not in cp_names_row:
                        cp_names_row.append(cp)
            for cp in cp_names_row:
                mine = res['checkpoints'].get(cp)
                cps[cp] = {'reached': mine is not None, 'vs': {}}
                for x in names:
                    if x == r or (w, x) not in load:
                        continue
                    other = load[(w, x)]['checkpoints'].get(cp)
                    if mine is not None and other is not None:
                        cps[cp]['vs'][x] = classify.classify(mine, other)
            report['load_checkpoints'][f'{w}-in-{r}'] = cps
        # composites: one image per checkpoint, every cell
        cp_names = []
        for res in load.values():
            for cp in res['checkpoints']:
                if cp not in cp_names:
                    cp_names.append(cp)
        for cp in cp_names:
            # rows = writer, columns = reader; a cell that never reached the
            # checkpoint is a grey placeholder so the grid keeps its shape
            frames, labels = [], []
            for w in names:
                for r in names:
                    if (w, r) not in load:
                        continue
                    c = load[(w, r)]['checkpoints'].get(cp)
                    if c:
                        frames.append(img.read_ppm(c['ppm']))
                        labels.append(f'{w} sav in {r}')
                    else:
                        frames.append(img.np.full((img.H, img.W, 3), 96, dtype=img.np.uint8))
                        labels.append(f'{w} sav in {r} failed')
            if frames:
                img.write_png(os.path.join(cmpdir, f'load-{cp}.png'), _grid(frames, labels, len(names)))

    report['verdicts'] = verdicts(report, names)
    with open(os.path.join(outdir, 'results.json'), 'w') as f:
        json.dump(report, f, indent=1, default=str)
    write_html(report, outdir)
    print_summary(report)
    latest = os.path.join(args.out, 'runs', f'{slug}-{sha1[:8]}', 'latest')
    if os.path.islink(latest):
        os.unlink(latest)
    os.symlink(stamp, latest)
    global last_outdir
    last_outdir = outdir
    return 0 if all(v['pass'] for v in report['verdicts'].values()) else 1


def cross_load_verdict(report, s, refs, problems):
    """Row-wise judgement of the save matrix for subject `s`; appends
    problems, returns notes."""
    notes = []
    cells, cps = report['load'], report['load_checkpoints']

    def agree(key, cp, x):
        c = cps.get(key, {}).get(cp)
        return bool(c and x in c['vs'] and cell_ok(c['vs'][x]))

    def healthy(r):
        """Reader r shows its own save the way at least one other emulator does."""
        row = cps.get(f'{r}-in-{r}', {})
        return bool(row) and all(c['reached'] and (not c['vs'] or any(cell_ok(vv) for vv in c['vs'].values()))
                                 for c in row.values())

    for key, cell in cells.items():
        w, r = key.split('-in-')
        if s not in (w, r):
            continue
        # booting must not rewrite the file -- unless the references rewrite
        # the same save the same way (the game's own boot bookkeeping)
        if not cell['save_unchanged']:
            after = cell.get('save_after') or {}
            padded = after.get('diff', {}).get('bytes') == 0 and after.get('size', 0) > after.get('size_before', 0)
            refs_keep = [x for x in refs if f'{w}-in-{x}' in cells and cells[f'{w}-in-{x}']['save_unchanged']]
            if r == s and refs_keep:
                problems.append(f'{w} save in {r}: battery file changed by booting, {"/".join(refs_keep)} left it '
                                f'unchanged: {after}')
            elif padded:
                notes.append(f'{r} extends a {after["size_before"]}-byte save to {after["size"]} bytes on boot (data unchanged)')
            else:
                notes.append(f'{w} save in {r}: the game rewrites part of the save at boot (references too)')

    # s reading reference saves: agree with at least one reference reader
    for w in refs:
        key = f'{w}-in-{s}'
        if key not in cells:
            continue
        for cp, c in cps[key].items():
            ref_readers = [x for x in refs if cps.get(f'{w}-in-{x}', {}).get(cp, {}).get('reached')]
            if not ref_readers:
                continue
            if not c['reached']:
                problems.append(f'{w} save in {s}: never reached {cp} ({cells[key]["error"]}); '
                                f'{"/".join(ref_readers)} did')
            elif not any(agree(key, cp, x) for x in ref_readers):
                if len(ref_readers) > 1 and not agree(f'{w}-in-{ref_readers[0]}', cp, ref_readers[1]):
                    notes.append(f'{w} save, checkpoint {cp}: the references show it differently too: not diagnostic')
                else:
                    detail = ', '.join(f"{x}={c['vs'][x]['verdict']}" for x in ref_readers if x in c['vs'])
                    problems.append(f'{w} save in {s}: checkpoint {cp} differs from the references reading the same save ({detail})')

    # references reading s's save: each should show it as s shows it, unless
    # that reference cannot even show its own save consistently
    for r in refs:
        key = f'{s}-in-{r}'
        if key not in cells:
            continue
        for cp, c in cps[key].items():
            own = cps.get(f'{s}-in-{s}', {}).get(cp)
            if not own or not own['reached']:
                continue
            ok = c['reached'] and agree(key, cp, s)
            if ok:
                continue
            # the reader shows another writer's save differently from that
            # writer too: the difference is the reader's (animation phase,
            # wandering characters), not this save's
            others = [w for w in refs if w not in (r, s) and f'{w}-in-{r}' in cps
                      and cps.get(f'{w}-in-{w}', {}).get(cp, {}).get('reached')]
            reader_quirk = any(not agree(f'{w}-in-{r}', cp, w) for w in others)
            if not healthy(r):
                notes.append(f'{s} save in {r}: checkpoint {cp} differs, but {r} does not show its own save '
                             f'like the others either: not diagnostic')
            elif reader_quirk:
                notes.append(f'{s} save in {r}: checkpoint {cp} differs, but {r} shows the other saves '
                             f'differently from their writers too: not diagnostic')
            elif any(agree(key, cp, x) for x in refs if x != r):
                notes.append(f'{s} save in {r}: checkpoint {cp} differs from {s}, but matches another reference')
            else:
                what = 'never reached' if not c['reached'] else c['vs'][s]['verdict']
                problems.append(f'{s} save in {r}: checkpoint {cp}: {what} compared with {s} reading its own save')

    # reference-only cells, for the record
    for key, cell in cells.items():
        w, r = key.split('-in-')
        if s in (w, r):
            continue
        if not cell['ok']:
            notes.append(f'references: {w} save in {r}: [load] failed: {cell["error"]}')
    return notes


def cell_ok(v):
    """A load-checkpoint verdict that counts as the save having loaded."""
    if v['verdict'] not in OK_LOAD:
        return False
    # a loaded save that shows different values (a menu setting, a count) is
    # a small pixel change but not the same load
    return not (v['verdict'] == 'MINOR' and v.get('text_similarity', 1.0) < 1.0 and not v.get('palette_only')
                and v.get('max_channel_delta', 99) > 1)


def loads_like(a, b):
    return cell_ok(classify.classify(a, b))


def _strip(res):
    r = {k: v for k, v in res.items() if k != 'checkpoints'}
    r['checkpoints'] = {n: {k: v for k, v in c.items() if k not in ('hashes',)} for n, c in res['checkpoints'].items()}
    return r


def _grid(frames, labels, cols):
    rows = []
    for i in range(0, len(frames), cols):
        fr, lb = frames[i:i + cols], labels[i:i + cols]
        while len(fr) < cols:
            fr.append(fr[0] * 0)
            lb.append('')
        rows.append(img.composite(fr, lb, scale=1))
        rows.append(img.np.full((4, rows[-1].shape[1], 3), 255, dtype=img.np.uint8))
    return img.np.vstack(rows[:-1])


def verdicts(report, names):
    """Per subject emulator: play / save / cross-load pass-fail with reasons."""
    out = {}
    refs = [n for n in names if not n.startswith(SUBJECT_PREFIX)]
    for s in [n for n in names if n.startswith(SUBJECT_PREFIX)]:
        v = {'problems': [], 'notes': []}
        # play
        if not report['new'][s]['ok']:
            v['problems'].append(f"[new] did not complete: {report['new'][s]['error']}")
        for r in refs:
            if not report['new'][r]['ok']:
                v['notes'].append(f"reference {r} did not complete [new]: {report['new'][r]['error']}")
        play = {cp: e['verdict'][s] for cp, e in report['new_checkpoints'].items()}
        noisy = {cp for cp, e in report['new_checkpoints'].items() if e['noise'][s]}
        v['play'] = classify.worst([p for cp, p in play.items() if cp not in noisy])
        for cp, verdict in play.items():
            if cp in noisy:
                v['notes'].append(f"checkpoint {cp}: {verdict}, but the references disagree with each other "
                                  f"({report['new_checkpoints'][cp]['ref_disagreement']}): not diagnostic")
            elif verdict in ('DIFFERENT', 'MAJOR', 'FAILED'):
                v['problems'].append(f'checkpoint {cp}: {verdict}')
            elif verdict in ('SLIP', 'MINOR'):
                pairs = report['new_checkpoints'][cp]['pairs']
                detail = ', '.join(f"{k.split('~')[1]}={p['verdict']}" + (f"({p['offset']:+d})" if 'offset' in p else '')
                                   for k, p in pairs.items() if k.startswith(s + '~'))
                v['notes'].append(f'checkpoint {cp}: {detail}')
        # save format
        sv = report['saves'].get(s, {})
        if report.get('no_save'):
            if sv.get('exists') and not sv.get('blank'):
                v['problems'].append(f"game has no battery save, but dingbat wrote {sv['size']} bytes of data")
            for r in refs:
                rs = report['saves'].get(r, {})
                if rs.get('exists'):
                    v['notes'].append(f"{r} leaves a {rs['size']}-byte {'blank ' if rs.get('blank') else ''}file")
        elif not sv.get('exists'):
            v['problems'].append('no battery file written')
        else:
            if not sv['canonical']:
                v['notes'].append(f"save is {sv['size']} bytes; chip sizes {report['rom_info']['canonical_sizes']}")
            for r in refs:
                pair = report['save_pairs'].get(f'{s}~{r}') or report['save_pairs'].get(f'{r}~{s}')
                if not pair:
                    continue
                if not pair['same_size']:
                    mine, theirs = sv['size'], report['saves'][r]['size']
                    tr = report['saves'][r].get('trailer_bytes')
                    canon = report['rom_info']['canonical_sizes']
                    if sv['canonical'] and tr and theirs - tr == mine:
                        v['notes'].append(f'{r} appends a {tr}-byte trailer after the chip data '
                                          f'({theirs} bytes); cross-load decides compatibility')
                    elif (report['saves'][r].get('canonical') and sv.get('trailer_bytes')
                          and mine - sv['trailer_bytes'] == theirs):
                        v['notes'].append(f"dingbat appends a {sv['trailer_bytes']}-byte trailer "
                                          f"after the chip data{' (RTC)' if report['rom_info'].get('rtc') else ''} "
                                          f'and {r} does not; cross-load decides compatibility')
                    elif mine in canon and theirs in canon:
                        # 4Kbit vs 64Kbit EEPROM: both are chip sizes; which one
                        # the game uses shows in whether the other side loads it
                        v['notes'].append(f'save size differs from {r} ({mine} vs {theirs}), both valid '
                                          f'chip sizes; cross-load decides compatibility')
                    else:
                        v['problems'].append(f"save size differs from {r}: {mine} vs {theirs}")
                if 'decoded' in pair:
                    ds, dr = (pair['decoded'] if report['save_pairs'].get(f'{s}~{r}') else pair['decoded'][::-1])
                    if not ds.get('valid'):
                        v['problems'].append(f"save does not decode: {ds.get('why')}")
                    elif not pair['decoded_equivalent']:
                        v['problems'].append(f"decoded save differs from {r}: {ds.get('summary')} vs {dr.get('summary')}")
                if not pair['chip_body_identical']:
                    v['notes'].append(f"bytes differ from {r} in {pair['diff']['bytes']} bytes / {pair['diff']['count']} ranges")
        # cross-load
        if 'load' in report:
            v['notes'] += cross_load_verdict(report, s, refs, v['problems'])
        v['pass'] = not v['problems']
        out[s] = v
    return out


def print_summary(report):
    print()
    print(f"== {report['meta'].get('title', report['rom_info']['title'])}")
    for n, r in report['new'].items():
        print(f"   {n:13} [new] {'ok' if r['ok'] else 'FAILED'} f{r.get('frame')} {r['seconds']}s"
              + (f"  {r['error']}" if r['error'] else ''))
    for cp, e in report['new_checkpoints'].items():
        pairs = ', '.join(f"{k}={p['verdict']}" + (f"({p['offset']:+d})" if 'offset' in p else '') for k, p in e['pairs'].items())
        print(f'   checkpoint {cp:14} {pairs}')
    for n, s in report['saves'].items():
        if s.get('exists'):
            print(f"   save {n:13} {s['size']} bytes canonical={s['canonical']} sha1={s['sha1'][:10]}")
        else:
            print(f'   save {n:13} MISSING')
    for k, p in report['save_pairs'].items():
        extra = ''
        if 'decoded' in p:
            extra = f" decoded_equivalent={p['decoded_equivalent']} " + ' / '.join(
                json.dumps(d.get('summary') or d.get('why')) for d in p['decoded'])
        print(f"   save {k:22} same_size={p['same_size']} identical={p['identical']}"
              + (f" diff_bytes={p['diff']['bytes']}" if 'diff' in p else '') + extra)
    for key, cell in report.get('load', {}).items():
        cps = report['load_checkpoints'].get(key, {})
        s = ', '.join(f"{cp}: " + (' '.join(f"{x}={vv['verdict']}" for x, vv in c['vs'].items()) if c['reached'] else 'NOT REACHED')
                      for cp, c in cps.items())
        print(f"   load {key:22} {'ok' if cell['ok'] else 'FAILED'} unchanged={cell['save_unchanged']} {s}"
              + (f"  {cell['error']}" if cell['error'] else ''))
    for s, v in report['verdicts'].items():
        print(f"   VERDICT {s}: {'PASS' if v['pass'] else 'FAIL'} (play={v['play']})")
        for p in v['problems']:
            print(f'     problem: {p}')
        for n in v['notes']:
            print(f'     note: {n}')


def write_html(report, outdir):
    def rel(p):
        return os.path.relpath(p, outdir)
    e = html.escape
    parts = [f"<title>{e(report['meta'].get('title', report['rom_info']['title']))} playtest</title>",
             '<style>body{font:14px system-ui;margin:16px;background:#fafafa}img{image-rendering:pixelated;max-width:100%}'
             'td,th{padding:2px 8px;text-align:left;vertical-align:top}.FAIL,.MAJOR,.FAILED{color:#b00}.PASS,.IDENTICAL{color:#070}'
             'pre{white-space:pre-wrap}</style>',
             f"<h1>{e(report['meta'].get('title', ''))}</h1><p>sha1 {report['sha1']} &middot; {e(json.dumps(report['rom_info']))}</p>"]
    for s, v in report['verdicts'].items():
        parts.append(f"<h2 class={'PASS' if v['pass'] else 'FAIL'}>{e(s)}: {'PASS' if v['pass'] else 'FAIL'} (play {v['play']})</h2><ul>")
        parts += [f'<li class=FAIL>{e(p)}</li>' for p in v['problems']]
        parts += [f'<li>{e(n)}</li>' for n in v['notes']]
        parts.append('</ul>')
    parts.append('<h2>New game</h2>')
    for cp, en in report['new_checkpoints'].items():
        pairs = ' &middot; '.join(f"{e(k)} <b class={p['verdict']}>{p['verdict']}</b>" + (f" ({p['offset']:+d})" if 'offset' in p else '')
                                  for k, p in en['pairs'].items())
        parts.append(f"<h3>{e(cp)}</h3><p>{pairs}</p>")
        if 'png' in en:
            parts.append(f"<img src='{rel(en['png'])}'>")
    parts.append('<h2>Saves</h2><pre>' + e(json.dumps({'saves': report['saves'], 'pairs': report['save_pairs']}, indent=1)) + '</pre>')
    if 'load' in report:
        parts.append('<h2>Cross-load</h2><table><tr><th>cell</th><th>ok</th><th>save unchanged</th><th>checkpoints (vs the other readers of the same save)</th></tr>')
        for key, cell in report['load'].items():
            cps = report['load_checkpoints'][key]
            s = '; '.join(f"{e(cp)}: " + (' '.join(f"{x}={vv['verdict']}" for x, vv in c['vs'].items()) if c['reached'] else 'NOT REACHED')
                          for cp, c in cps.items())
            parts.append(f"<tr><td>{e(key)}</td><td>{cell['ok']}</td><td>{cell['save_unchanged']}</td><td>{s} {e(cell['error'] or '')}</td></tr>")
        parts.append('</table>')
        for f in sorted(os.listdir(os.path.join(outdir, 'cmp'))):
            if f.startswith('load-'):
                parts.append(f"<h3>{e(f[5:-4])}</h3><img src='cmp/{f}'>")
    with open(os.path.join(outdir, 'report.html'), 'w') as fh:
        fh.write('\n'.join(parts))
