#!/usr/bin/env python3
"""Cross-emulator playtest harness: play a game from a recorded script in
dingbat and the reference emulators, compare screens at checkpoints, save in
each, compare the battery files, then cross-load every save into every
emulator. See README.md.

  playtest.py run ROM|SHA1 [--emus dingbat,mgba,nba] [--out DIR]
  playtest.py serve NAME --rom ROM [--emus ...] [--save FILE]
  playtest.py do NAME STEP...
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
    p.add_argument('--emus', default='dingbat,mgba,nba')
    p.add_argument('--save')
    p.add_argument('--rtc', type=int, default=DEFAULT_RTC)

    p = sub.add_parser('do')
    p.add_argument('name')
    p.add_argument('steps', nargs='+')
    p.add_argument('--json', action='store_true')

    p = sub.add_parser('sha1')
    p.add_argument('rom')

    p = sub.add_parser('record', help='play a game in the desktop app with input recording, then convert')
    p.add_argument('rom', help='ROM path, or the sha1 of a ROM in the library')
    p.add_argument('--section', default='new', choices=['new', 'load'])
    p.add_argument('--save', help='[load]: battery file to start from (default: the latest [new] recording\'s)')
    p.add_argument('--app', default=os.environ.get('DINGBAT_APP', os.path.join(HERE, '..', '..', 'dingbat')),
                   help='desktop dingbat binary built from this tree (default: repo-root ./dingbat)')

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
        else:
            p.add_argument('only', nargs='*', help='sha1 prefixes or title substrings (default: every script)')
            p.add_argument('--script', default=None, help=argparse.SUPPRESS)
        p.add_argument('--emus', default='dingbat,mgba,nba')
        p.add_argument('--rtc', type=int, default=DEFAULT_RTC)
        p.add_argument('--no-cross', action='store_true', help='skip the cross-load matrix')

    args = ap.parse_args()
    if args.cmd == 'serve':
        session.serve(args.name, args.rom, args.emus.split(','), args.out, save=args.save, rtc=args.rtc)
    elif args.cmd == 'do':
        replies = session.send(args.name, args.steps, args.out)
        if args.json:
            print(json.dumps(replies, indent=1))
        else:
            for line, r in zip(args.steps, replies):
                print(render_reply(line, r))
    elif args.cmd == 'sha1':
        print(sha1_of(args.rom))
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
        sys.exit(pipeline.run(args))
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
    """Run every script (or a filtered subset); one summary table."""
    import pipeline
    import script
    rows = []
    for fn in sorted(os.listdir(os.path.join(HERE, 'scripts'))):
        if not fn.endswith('.play'):
            continue
        sha1 = fn[:-5]
        try:
            meta = script.parse(open(os.path.join(HERE, 'scripts', fn)).read())['meta']
        except script.ScriptError as e:
            if not args.only or any(sha1.startswith(o) for o in args.only):
                rows.append((fn, 'ERROR', str(e)))
            continue
        title = meta.get('title', sha1)
        if args.only and not any(sha1.startswith(o) or o.lower() in title.lower() for o in args.only):
            continue
        if meta.get('status', 'ready') != 'ready':
            rows.append((title, 'SKIPPED', meta['status']))
            continue
        args.rom = resolve(args.out, sha1)
        rc = pipeline.run(args)
        report = json.load(open(os.path.join(pipeline.last_outdir, 'results.json')))
        for s, v in report['verdicts'].items():
            rows.append((title, 'PASS' if v['pass'] else 'FAIL',
                         f"{s} play={v['play']} " + '; '.join(v['problems'][:3])))
    print('\n== suite')
    for title, status, detail in rows:
        print(f'{status:8} {title[:48]:48} {detail}')
    return 0 if all(r[1] != 'FAIL' for r in rows) else 1


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
