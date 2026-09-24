#!/usr/bin/env python3
"""Run dbsuite and report per case.

    python3 tests/roms/dbsuite/run.py               # dingbat, cartridge image
    python3 tests/roms/dbsuite/run.py --mb          # ... and the multiboot one
    python3 tests/roms/dbsuite/run.py --bios=PATH   # through a real BIOS
    python3 tests/roms/dbsuite/run.py --all         # list passes too
    python3 tests/roms/dbsuite/run.py --sp OUT.json # on the GBA SP over the
                                                    # link rig (see below)

Emulator runs drive `./dingbat_test <rom> --mode=mgba-suite`, which stops at
the ROM's `DBSUITE ALL DONE` line, and read the one `DBSUITE case ...` line
the ROM prints per case through the mGBA debug registers.  Any emulator with
those registers can be scored the same way; one with none can be scored off
the results block (README.md) or the verdict pixel at (239,159).

--sp uploads dbsuite.mb.gba to a console waiting in the multiboot loop (a
resident tools/hwlink monitor is sent BOOT first), follows the ROM's link
beacons (0xDB000000 | case index before each case) while it runs, then reads
the results block it streams ('LRPT', tools/hwlink/gblink.py read_report),
saves the words to OUT.json and decodes them.  A run that stops names the
case it stopped in.  Afterwards it sends BOOT (the ROM answers with the
BIOS's HardReset) and reinstalls the monitor.  Take the rig's lock first.

Exits 0 iff nothing failed, timed out or crashed.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
STATUS = ['NOTRUN', 'PASS', 'FAIL', 'TIMEOUT', 'CRASH', 'SKIP']
RESULTS_WORDS_AT = 0x140 // 4


def cases():
    return json.load(open(os.path.join(HERE, 'cases.json')))['cases']


def in_dingbat(rom, bios=None, frames=20000):
    harness = os.path.join(ROOT, 'dingbat_test')
    if not os.path.exists(harness):
        sys.exit('dingbat_test not found -- run `nimble test_build` first')
    cmd = [harness, os.path.join(HERE, rom), '--mode=mgba-suite', f'--timeout={frames}']
    if bios:
        cmd.append(f'--bios={bios}')
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True).stdout
    got = {}
    for line in out.splitlines():
        line = line.strip()
        if line.startswith('DBSUITE case '):
            words = line.split()
            got[words[2]] = (words[3], ' '.join(words[4:]))
    return got, 'DBSUITE ALL DONE' in out


def report(title, got, finished, show_all):
    bad = 0
    per_suite = {}
    for c in cases():
        key = f"{c['suite']}/{c['name']}"
        status, detail = got.get(key, ('NOT-REACHED', ''))
        s = per_suite.setdefault(c['suite'], [0, 0, 0])
        s[2] += 1
        if status == 'PASS':
            s[0] += 1
        elif status == 'SKIP':
            s[1] += 1
        if status not in ('PASS', 'SKIP'):
            bad += 1
        if show_all or status not in ('PASS', 'SKIP'):
            print(f'  {status:11} {key:52} {detail}')
    print(f'== {title}' + ('' if finished else '  (the run did not finish)'))
    for suite, (p, sk, t) in per_suite.items():
        print(f'  {suite:6} {p}/{t - sk}' + (f'  ({sk} skipped)' if sk else ''))
    return bad


def decode_block(words):
    """{case key: (status, 'got=.. exp=..')} from a results block."""
    got = {}
    for c in cases():
        i = c['index']
        w = words[RESULTS_WORDS_AT + 4 * i: RESULTS_WORDS_AT + 4 * i + 4]
        if len(w) < 4:
            continue
        status = STATUS[w[0] & 0xFF] if (w[0] & 0xFF) < len(STATUS) else '?'
        exp = f'{w[2]:08X}' + (f'..{w[3]:08X}' if w[3] != w[2] else '')
        got[f"{c['suite']}/{c['name']}"] = (status, f'got={w[1]:08X} exp={exp}')
    return got


def on_console(out_path):
    sys.path.insert(0, os.path.join(ROOT, 'tools', 'hwlink'))
    import gblink
    import await_console
    from monitor import Monitor, install
    boot, magic = 0x424F4F54, 0x4C525054

    def log(*a):
        print(time.strftime('%H:%M:%S'), *a, flush=True)

    state = await_console.console_state()
    if state == 'monitor':
        with Monitor() as m:
            m.reboot()
        time.sleep(4.5)
        state = await_console.console_state()
    if state != 'multiboot':
        sys.exit(f'the console is not waiting for an upload (state {state})')
    image = open(os.path.join(HERE, 'dbsuite.mb.gba'), 'rb').read()
    with gblink.GBLink() as link:
        link.set_voltage_3v3()
        time.sleep(0.15)
        ok, msg = gblink.multiboot(link, image, log=lambda *a: None)
    log('upload:', msg)
    if not ok:
        sys.exit(1)
    # follow the beacons until the results stream starts
    last, last_change, words = None, time.time(), None
    with gblink.GBLink() as link:
        link.open_link()
        while time.time() - last_change < 30:
            v = link.transfer32(0)
            if v == magic:
                words, msg = gblink.read_report(link, limit=4096)
                log('results:', msg)
                if words:
                    break
            elif v >> 24 == 0xDB and v != last:
                last, last_change = v, time.time()
                if (v & 0xFFFFFF) % 50 == 0 or v >> 16 == 0xDBFF:
                    log(f'beacon {v:08X}')
            time.sleep(0.002)
    if not words:
        where = f'{last:08X}' if last is not None else 'none'
        n = last & 0xFFFFFF if last is not None and last >> 16 != 0xDBFF else None
        name = next((f"{c['suite']}/{c['name']}" for c in cases() if c['index'] == n), '')
        sys.exit(f'no results: the last beacon was {where} {name} -- the console '
                 'probably needs a power cycle')
    json.dump(words, open(out_path, 'w'))
    log('saved', len(words), 'words to', out_path)
    with gblink.GBLink() as link:
        link.open_link()
        for _ in range(3):
            link.transfer32(boot)
    time.sleep(4.5)
    ok, msg = install(log=lambda *a: None)
    log('monitor reinstall:', msg)
    return decode_block(words)


def main(argv):
    flags = [a for a in argv[1:] if a.startswith('--')]
    bios = next((f.split('=', 1)[1] for f in flags if f.startswith('--bios=')), None)
    show_all = '--all' in flags
    bad = 0
    if '--sp' in flags:
        out = next(a for a in argv[1:] if not a.startswith('--'))
        got = on_console(out)
        return 1 if report('AGB SP, multiboot image', got, True, show_all) else 0
    roms = ['dbsuite.gba'] + (['dbsuite.mb.gba'] if '--mb' in flags else [])
    for rom in roms:
        got, finished = in_dingbat(rom, bios)
        bad += report(f'dingbat, {rom}' + (' (real BIOS)' if bios else ''), got,
                      finished, show_all)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
