#!/usr/bin/env python3
"""Cross-emulator playtest harness: play a game from a recorded script in
dingbat and the reference emulators, compare screens at checkpoints, save in
each, compare the battery files, then cross-load every save into every
emulator. See README.md.

  playtest.py run ROM|SHA1 [--emus dingbat,...,mgba,nba] [--out DIR]
  playtest.py suite [FILTER...] [--jobs N]
  playtest.py serve NAME --rom ROM [--emus ...] [--save FILE | --save-dir DIR]
  playtest.py do NAME STEP...
  playtest.py freeze SHA1|SCRIPT [--rom ROM] [--write]
  playtest.py sha1 ROM
"""
import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import emu as emulib  # noqa: E402
import session  # noqa: E402

DEFAULT_OUT = os.environ.get('PLAYTEST_OUT', os.path.join(HERE, 'out'))
DEFAULT_RTC = 1136073600   # 2006-01-01 00:00:00 UTC, frozen in every emulator that allows it


def sha1_of(path):
    h = hashlib.sha1()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=DEFAULT_OUT)
    sub = ap.add_subparsers(dest='cmd', required=True)

    p = sub.add_parser('serve')
    p.add_argument('name')
    p.add_argument('--rom', required=True)
    p.add_argument('--emus', default=','.join(session.AUTHORING))
    p.add_argument('--save', help='one battery file seeded into every emulator')
    p.add_argument('--save-dir', help='<emu>.sav per emulator (a stopped session\'s saves/ directory)')
    p.add_argument('--rtc', type=int, default=DEFAULT_RTC)
    p.add_argument('--no-lockstep', action='store_true',
                   help='record until/mash as conditions instead of frozen input frames')

    p = sub.add_parser('freeze', help='condition script -> frozen input timeline (lockstep on the authoring emulators)')
    p.add_argument('script', help='script path, or the sha1 of scripts/<sha1>.play')
    p.add_argument('--rom')
    p.add_argument('--rtc', type=int, default=DEFAULT_RTC)
    p.add_argument('--write', action='store_true',
                   help='move the condition script to scripts/source/ and write the frozen one in its place')

    p = sub.add_parser('do')
    p.add_argument('name')
    p.add_argument('steps', nargs='+')
    p.add_argument('--json', action='store_true')

    p = sub.add_parser('sha1')
    p.add_argument('rom')

    p = sub.add_parser('saveinfo', help='size, blankness and hash of battery files')
    p.add_argument('files', nargs='+')

    p = sub.add_parser('record', help='play a game in the desktop app with input recording')
    p.add_argument('rom', help='ROM path, or the sha1 of a ROM in the library')
    p.add_argument('--section', default='new', choices=['new', 'load'])
    p.add_argument('--save', help='[load]: battery file to start from (default: the latest [new] recording\'s)')
    p.add_argument('--app', default=os.environ.get('DINGBAT_APP', os.path.join(HERE, '..', '..', 'dingbat')),
                   help='desktop dingbat binary built from this tree (default: repo-root ./dingbat)')
    p.add_argument('--convert', action='store_true',
                   help='convert once the app quits')

    p = sub.add_parser('convert', help='turn a DINGBAT_INPUT_LOG recording into a script section')
    p.add_argument('log')
    p.add_argument('--rom', required=True)
    p.add_argument('--section', default='new', choices=['new', 'load'])
    p.add_argument('--save', help='battery file the [load] recording was made with')
    p.add_argument('--rtc', type=int, default=DEFAULT_RTC)

    for name in ('run', 'suite'):
        p = sub.add_parser(name)
        if name == 'run':
            p.add_argument('rom', help='ROM path, or the sha1 of a scripted ROM in the library')
            p.add_argument('--script', help='default: scripts/<sha1>.play')
            p.add_argument('--outdir-file', help=argparse.SUPPRESS)
        else:
            p.add_argument('only', nargs='*', help='sha1 prefixes or title substrings (default: every script)')
            p.add_argument('--script', default=None, help=argparse.SUPPRESS)
        p.add_argument('--emus', default=','.join(emulib.ALL))
        p.add_argument('--rtc', type=int, default=DEFAULT_RTC)
        p.add_argument('--no-cross', action='store_true', help='skip the cross-load matrix')
        p.add_argument('--no-audio', action='store_true', help='skip audio capture and comparison')
        if name == 'suite':
            p.add_argument('--jobs', type=int, default=1, help='games run in parallel')
            p.add_argument('--tag', default=None, help='suite output directory name (default: a timestamp)')

    args = ap.parse_args()
    if args.cmd == 'serve':
        save = args.save
        if args.save_dir:
            save = {n: os.path.join(args.save_dir, n + '.sav') for n in args.emus.split(',')
                    if os.path.exists(os.path.join(args.save_dir, n + '.sav'))}
        session.serve(args.name, args.rom, args.emus.split(','), args.out, save=save, rtc=args.rtc,
                      lockstep=not args.no_lockstep)
    elif args.cmd == 'freeze':
        sys.exit(freeze_cmd(args))
    elif args.cmd == 'do':
        replies = session.send(args.name, args.steps, args.out)
        if args.json:
            print(json.dumps(replies, indent=1))
        else:
            for line, r in zip(args.steps, replies):
                print(render_reply(line, r))
    elif args.cmd == 'sha1':
        print(sha1_of(args.rom))
    elif args.cmd == 'saveinfo':
        for f in args.files:
            data = open(f, 'rb').read() if os.path.exists(f) else None
            if data is None:
                print(f'{f}: missing')
                continue
            used = sum(1 for b in data if b not in (0x00, 0xFF))
            print(f'{f}: {len(data)} bytes, {used} bytes not 00/FF'
                  f"{' (BLANK)' if not used else ''}, sha1 {hashlib.sha1(data).hexdigest()[:12]}")
    elif args.cmd == 'record':
        sys.exit(record(args))
    elif args.cmd == 'convert':
        import convert
        print(convert.convert(args.log, args.rom, args.section, os.path.join(args.out, 'convert'),
                              save=args.save, rtc=args.rtc), end='')
    elif args.cmd == 'run':
        import pipeline
        if not os.path.exists(args.rom) and re.fullmatch(r'[0-9a-f]{40}', args.rom):
            args.rom = resolve(args.out, args.rom)
        rc = pipeline.run(args)
        if args.outdir_file and pipeline.last_outdir:
            open(args.outdir_file, 'w').write(pipeline.last_outdir)
        sys.exit(rc)
    elif args.cmd == 'suite':
        sys.exit(suite(args))


def record(args):
    """Isolated recording directory out/recordings/<sha1>/<section>-<time>/:
    game.gba (symlink), game.sav (the app's battery file), input.log, and
    <section>.play once the app quits."""
    import datetime
    import glob
    import shutil
    import subprocess
    import convert
    rom = args.rom
    if not os.path.exists(rom) and re.fullmatch(r'[0-9a-f]{40}', rom):
        rom = resolve(args.out, rom)
    rom = os.path.abspath(rom)
    sha1 = sha1_of(rom)
    app = os.path.abspath(args.app)
    if not os.access(app, os.X_OK):
        sys.exit(f'no desktop build at {app}: run `nimble build -d:release` in this tree '
                 f'(the input recorder is new), or pass --app')
    base = os.path.join(args.out, 'recordings', sha1)
    d = os.path.join(base, f"{args.section}-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    os.makedirs(d)
    os.symlink(rom, os.path.join(d, 'game.gba'))
    save = args.save
    if args.section == 'load' and not save:
        news = sorted(glob.glob(os.path.join(base, 'new-*', 'game.sav')))
        if not news:
            sys.exit('no [new] recording with a save yet; record --section new first or pass --save')
        save = news[-1]
    if save:
        shutil.copyfile(save, os.path.join(d, 'game.sav'))
        shutil.copyfile(save, os.path.join(d, 'seed.sav'))
    log = os.path.join(d, 'input.log')
    print(f'recording {os.path.basename(rom)} [{args.section}] into {d}')
    print('  play normally; F9 marks a screen worth checking; do not load states or rewind;')
    print('  for [new], quit the app once the game has confirmed the save.')
    subprocess.run([app, os.path.join(d, 'game.gba')], env=dict(os.environ, DINGBAT_INPUT_LOG=log))
    if not os.path.exists(log):
        sys.exit('the app wrote no input log (is it a build with the recorder?)')
    if not args.convert:
        cmd = f'playtest.py convert {log} --rom {rom!r} --section {args.section}'
        if save:
            cmd += f" --save {os.path.join(d, 'seed.sav')}"
        print(f'recorded; convert later with:\n  {cmd}')
        return 0
    text = convert.convert(log, rom, args.section, os.path.join(d, 'convert'),
                           save=os.path.join(d, 'seed.sav') if save else None, rtc=DEFAULT_RTC)
    out = os.path.join(d, f'{args.section}.play')
    open(out, 'w').write(text)
    print(text)
    print(f'script section written to {out}')
    return 0


def resolve(outroot, sha1):
    import library
    import script
    path = os.path.join(HERE, 'scripts', sha1 + '.play')
    meta = script.parse(open(path).read())['meta'] if os.path.exists(path) else {}
    rom = library.Library(os.path.join(outroot, 'rom-index.json')).find(sha1, meta.get('file'))
    if not rom:
        sys.exit(f'no ROM with sha1 {sha1} in the library ({meta.get("file", "no @file")})')
    return rom


def suite(args):
    """Run every script (or a filtered subset), `--jobs` games at a time,
    each in its own process with its log in the suite directory
    (out/suites/<tag>/): index.json maps every game to its run directory."""
    import concurrent.futures as cf
    import datetime
    import subprocess
    import script
    tag = args.tag or datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    sdir = os.path.join(args.out, 'suites', tag)
    os.makedirs(os.path.join(sdir, 'logs'), exist_ok=True)
    rows, todo = [], []
    for fn in sorted(os.listdir(os.path.join(HERE, 'scripts'))):
        if not fn.endswith('.play'):
            continue
        sha1 = fn[:-5]
        try:
            meta = script.parse(open(os.path.join(HERE, 'scripts', fn)).read())['meta']
        except script.ScriptError as e:
            if not args.only or any(sha1.startswith(o) for o in args.only):
                rows.append({'sha1': sha1, 'title': fn, 'status': 'ERROR', 'detail': str(e)})
            continue
        title = meta.get('title', sha1)
        if args.only and not any(sha1.startswith(o) or o.lower() in title.lower() for o in args.only):
            continue
        if meta.get('status', 'ready') != 'ready':
            rows.append({'sha1': sha1, 'title': title, 'status': 'SKIPPED', 'detail': meta['status']})
            continue
        todo.append((sha1, title))

    def one(item):
        sha1, title = item
        log = os.path.join(sdir, 'logs', f'{sha1[:12]}.log')
        link = os.path.join(sdir, 'logs', f'{sha1[:12]}.outdir')
        cmd = [sys.executable, os.path.join(HERE, 'playtest.py'), '--out', args.out, 'run', sha1,
               '--emus', args.emus, '--rtc', str(args.rtc), '--outdir-file', link]
        cmd += ['--no-cross'] if args.no_cross else []
        cmd += ['--no-audio'] if args.no_audio else []
        with open(log, 'w') as fh:
            rc = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT).returncode
        row = {'sha1': sha1, 'title': title, 'rc': rc, 'log': log}
        if os.path.exists(link):
            row['outdir'] = open(link).read().strip()
            report = json.load(open(os.path.join(row['outdir'], 'results.json')))
            row['status'] = 'PASS' if all(v['pass'] for v in report['verdicts'].values()) else 'FAIL'
            row['detail'] = {s: {'pass': v['pass'], 'play': v['play'], 'problems': v['problems'][:4]}
                             for s, v in report['verdicts'].items()}
        else:
            row['status'] = 'ERROR'
            row['detail'] = open(log).read()[-600:]
        print(f"{row['status']:8} {title[:56]}", flush=True)
        return row

    # an existing suite of the same tag is extended: its games stay unless
    # this run replaces them
    index_path = os.path.join(sdir, 'index.json')
    if os.path.exists(index_path):
        mine = {sha1 for sha1, _ in todo} | {r['sha1'] for r in rows}
        rows = [r for r in json.load(open(index_path))['games'] if r['sha1'] not in mine] + rows
    print(f'== suite {tag}: {len(todo)} games, {args.jobs} at a time -> {sdir}', flush=True)
    with cf.ThreadPoolExecutor(max(1, args.jobs)) as pool:
        for row in pool.map(one, todo):
            rows.append(row)
            json.dump({'tag': tag, 'emus': args.emus.split(','), 'games': rows},
                      open(os.path.join(sdir, 'index.json'), 'w'), indent=1)
    print(f'\n== suite {tag}')
    for r in rows:
        print(f"{r['status']:8} {r['title'][:56]}")
    return 0 if all(r['status'] != 'FAIL' for r in rows) else 1


def freeze_cmd(args):
    import freeze
    path = args.script
    if not os.path.exists(path) and re.fullmatch(r'[0-9a-f]{40}', path):
        path = os.path.join(HERE, 'scripts', path + '.play')
    text = open(path).read()
    if freeze.is_frozen(text):
        print(f'{path} is already frozen')
        return 0
    sha1 = os.path.basename(path)[:-5]
    rom = args.rom or resolve(args.out, sha1)
    try:
        frozen = freeze.freeze(path, rom, args.out, args.rtc)
    except freeze.FreezeFailed as e:
        print(f'FREEZE FAILED: {e}')
        return 1
    if args.write:
        src = os.path.join(HERE, 'scripts', 'source')
        os.makedirs(src, exist_ok=True)
        os.replace(path, os.path.join(src, os.path.basename(path)))
        open(path, 'w').write(frozen)
        print(f'frozen: {path} (condition script kept in scripts/source/)')
    else:
        print(frozen)
    return 0


def render_reply(line, r):
    if 'error' in r:
        return f'!! {line}: {r["error"]}'
    if 'png' in r:
        out = [f'look: {r["png"]}  identical={r["identical"]}']
        for n, v in r['emus'].items():
            out.append(f'  {n} f{v["frame"]} {v["hash"][:8]} selected={v["selected"]!r}')
            out.append('    ' + ' | '.join(t for t, _ in v['lines']))
        return '\n'.join(out)
    if 'results' in r and 'step' in r:
        parts = []
        for n, (status, msg, frame) in r['results'].items():
            parts.append(f'{n}=f{frame}' + ('' if status == 'ok' else f' FAIL({msg})'))
        s = f'{"ok" if r["recorded"] else "!!"} {r["step"]}: ' + ', '.join(parts)
        if 'failed_look' in r:
            s += f'\n   (rolled back; failure screen: {r["failed_look"]})'
        if 'rollback_failed' in r:
            s += f'\n   !! ROLLBACK FAILED, emulators out of sync: {r["rollback_failed"]} -- restart the session'
        return s
    if 'script' in r:
        return r['script']
    return f'{line}: {json.dumps(r)}'


if __name__ == '__main__':
    main()
