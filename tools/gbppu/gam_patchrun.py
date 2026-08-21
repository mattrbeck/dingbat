#!/usr/bin/env python3
"""Build a gambatte-format probe ROM, run it through BOTH dingbat and SameBoy.

The gambatte suite's ROMs all end in `jp $7000`, and everything from $0150 to
$6FFF of them is NOP padding with a `wait until LY == B` helper parked at
$7400 and the hex printer at $7000.  That makes any one of them a blank
program the harness already knows how to read a byte out of: overwrite the
body, jump to $7000 with the answer in A, and `--mode=gambatte` (dingbat) and
`tools/gbfuzz/sameboy_gambatte` (SameBoy) both decode it off the screen.

That is what turns a question this suite cannot ask -- "at exactly which CPU
M-cycle after an LCD enable does the mode-0 STAT source rise, and does a HALTED
CPU see it on the same one?" -- into one SameBoy can answer.  GBMicrotest asks
it, but its answers live in `$FF80` and no SameBoy runner here reads that.

Used by gam_sled.py, gam_dispatch.py and gam_haltwake.py; see the write-up at
`M0_HALT_BLIND_DOTS` in src/dingbat/gb/ppu.nim for what they measured.

Environment:
  DINGBAT_ROOT     repo/worktree root (default: two levels up from this file)
  GB_TEST_ROMS     game-boy-test-roms checkout
                   (default /tmp/dingbat-test-roms/game-boy-test-roms)
  SAMEBOY_GAMBATTE path to the built oracle (default <root>/tools/gbfuzz/...)
  SAMEBOY_BOOT     directory holding dmg_boot.bin / cgb_boot.bin
"""
import os
import subprocess

WT = os.environ.get(
    'DINGBAT_ROOT',
    os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
ROOT = os.environ.get('GB_TEST_ROMS',
                      '/tmp/dingbat-test-roms/game-boy-test-roms')
SAMEBOY = os.environ.get('SAMEBOY_GAMBATTE',
                         os.path.join(WT, 'tools/gbfuzz/sameboy_gambatte'))
BOOT = os.environ.get('SAMEBOY_BOOT', os.path.join(WT, '.work', 'boot'))
OUT = os.path.join(WT, '.work', 'roms')


def hdrfix(b):
    """Re-checksum $014D. The global checksum at $014E-F is not verified by
    hardware or by any emulator here, so it is left alone."""
    b = bytearray(b)
    s = 0
    for i in range(0x134, 0x14D):
        s = (s - b[i] - 1) & 0xFF
    b[0x14D] = s
    return bytes(b)


def make(src, patches, name):
    """patches: [(addr, [bytes]), ...] applied in order. Writes <OUT>/<name>."""
    os.makedirs(OUT, exist_ok=True)
    b = bytearray(open(src, 'rb').read())
    for addr, data in patches:
        b[addr:addr + len(data)] = bytes(data)
    p = os.path.join(OUT, name)
    open(p, 'wb').write(hdrfix(b))
    return p


def _tsv(rows, name):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with open(path, 'w') as f:
        for dev, rom in rows:
            # The expected column is a dummy: both runners print what they got.
            f.write('%s\thex\t00\t%s\n' % (dev, rom))
    return path


def run_dingbat(rows):
    """rows: [(dmg|cgb, rompath)]. Returns the harness's GAM lines."""
    tsv = _tsv(rows, 'list.tsv')
    outp = os.path.join(OUT, 'out.txt')
    if os.path.exists(outp):
        os.remove(outp)
    env = dict(os.environ)
    env.setdefault('TMPDIR', os.path.join(WT, '.tmp'))
    os.makedirs(env['TMPDIR'], exist_ok=True)
    r = subprocess.run([os.path.join(WT, 'dingbat_test'), '--mode=gambatte',
                        '--list=' + tsv, '--out=' + outp],
                       capture_output=True, text=True, env=env, cwd=WT)
    lines = []
    if os.path.exists(outp):
        lines = [l for l in open(outp).read().splitlines()
                 if l.startswith('GAM ')]
    return lines, r.stdout, r.stderr


def dingbat_values(rows):
    """{row index: the two hex digits the ROM printed}."""
    lines, _, _ = run_dingbat(rows)
    d = {}
    for l in lines:
        parts = l.split()
        d[int(parts[1])] = (parts[3] if parts[2] == 'PASS'
                            else l.split('got ')[1].split(',')[0])
    return d


def run_sameboy(rows, frames=15):
    tsv = _tsv(rows, 'sblist.tsv')
    r = subprocess.run([SAMEBOY, BOOT, tsv, str(frames)],
                       capture_output=True, text=True, cwd=WT)
    return r.stdout, r.stderr


def sameboy_values(rows, frames=15):
    out, _ = run_sameboy(rows, frames)
    d = {}
    for l in out.splitlines():
        parts = l.split()
        if parts and parts[0] == 'GAM':
            d[int(parts[1])] = parts[2][:2]
    return d
