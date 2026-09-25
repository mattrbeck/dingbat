#!/usr/bin/env python3
"""Builds dbsuite: dbsuite.gba (cartridge) and dbsuite.mb.gba (multiboot).

    python3 tests/roms/dbsuite/build.py

Needs arm-none-eabi-{as,ld,objcopy,nm} and gbafix (romfix.gba_logo), like
the other ROMs in tests/roms.  Nothing else: the logo PNG is decoded here
with zlib.

Steps:
  1. every link-rig payload a case carries is assembled for IWRAM
     0x03000000 (the address the rig's monitor runs it at), so the ROM and
     the console run identical bytes at the identical address;
  2. the 6x8 font, the logo (web/favicon.svg's embedded 48x29 PNG) and the
     cases generated from the recorded console tables
     (tools/hwlink/r0-agb.json, breakram-agb.json) are written as includes;
  3. dbsuite.s is assembled twice: MB=0 linked at 0x08000000 behind a
     cartridge header, MB=1 linked at MB_HOME and wrapped by mbstub.s;
  4. cases.json lists every case (index, suite, name, check) as built, for
     harnesses that read the results block out of a memory dump.
"""
import base64
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROMS = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(ROMS))
HWLINK = os.path.join(REPO, 'tools', 'hwlink')
sys.path.insert(0, ROMS)
import romfix  # noqa: E402

MB_HOME = 0x02024000
MB_BODY_MAX = 0x02040000 - MB_HOME
PAYLOAD_HOME = 0x03000000

# payload name -> source.  tests/roms/payloads/ are the link rig's own,
# carried byte for byte; dbsuite/payloads/ are copies of the session
# payloads that were run on the console (their headers say what changed).
PAYLOADS = {
    'irqstorm': os.path.join(ROMS, 'payloads', 'irqstorm.s'),
    'dmaphase': os.path.join(ROMS, 'payloads', 'dmaphase.s'),
    'kitdemo': os.path.join(ROMS, 'payloads', 'kitdemo.s'),
    'wakeirq': os.path.join(ROMS, 'payloads', 'wakeirq.s'),
    'tmrw': os.path.join(ROMS, 'payloads', 'tmrw.s'),
    'lycwrite': os.path.join(ROMS, 'payloads', 'lycwrite.s'),
    'breakram': os.path.join(ROMS, 'payloads', 'breakram.s'),
    'swiedge': os.path.join(ROMS, 'payloads', 'swiedge.s'),
    'thumbmul': os.path.join(ROMS, 'payloads', 'thumbmul.s'),
    'waitcnt': os.path.join(ROMS, 'payloads', 'waitcnt.s'),
    'dmasteal': os.path.join(ROMS, 'payloads', 'dmasteal.s'),
    'obusprobe': os.path.join(ROMS, 'payloads', 'obusprobe.s'),
    'obusbus': os.path.join(ROMS, 'payloads', 'obusbus.s'),
    'obuswin': os.path.join(ROMS, 'payloads', 'obuswin.s'),
    'obuswint': os.path.join(ROMS, 'payloads', 'obuswint.s'),
    'ldmglitch1': os.path.join(HERE, 'payloads', 'ldmglitch1.s'),
    'ldmglitch2': os.path.join(HERE, 'payloads', 'ldmglitch2.s'),
    'ldmglitch3': os.path.join(HERE, 'payloads', 'ldmglitch3.s'),
    'ldmglitch4': os.path.join(HERE, 'payloads', 'ldmglitch4.s'),
    'dmaobus': os.path.join(HERE, 'payloads', 'dmaobus.s'),
    'dmaobus2': os.path.join(HERE, 'payloads', 'dmaobus2.s'),
    'dmatime': os.path.join(HERE, 'payloads', 'dmatime.s'),
    'tmrdma': os.path.join(ROMS, 'payloads', 'tmrdma.s'),
    'dmastart': os.path.join(ROMS, 'payloads', 'dmastart.s'),
    'dmadur': os.path.join(ROMS, 'payloads', 'dmadur.s'),
    'dmamulirq': os.path.join(ROMS, 'payloads', 'dmamulirq.s'),
    'dmairq': os.path.join(ROMS, 'payloads', 'dmairq.s'),
    'irqwait': os.path.join(ROMS, 'payloads', 'irqwait.s'),
    # sp-agb.json's families (record.py): the rig's payloads dbsuite had not
    # carried, and this suite's own
    'switime': os.path.join(HERE, 'payloads', 'switime.s'),
    'sweeptrig': os.path.join(HERE, 'payloads', 'sweeptrig.s'),
    'fifodma': os.path.join(HERE, 'payloads', 'fifodma.s'),
    'timergeo': os.path.join(ROMS, 'payloads', 'timergeo.s'),
    'halthb': os.path.join(ROMS, 'payloads', 'halthb.s'),
    'vdmageo': os.path.join(ROMS, 'payloads', 'vdmageo.s'),
    'haltprobe': os.path.join(ROMS, 'payloads', 'haltprobe.s'),
    'vbwait': os.path.join(ROMS, 'payloads', 'vbwait.s'),
    'psgfirst': os.path.join(ROMS, 'payloads', 'psgfirst.s'),
}


def run(cmd, cwd=None):
    subprocess.run(cmd, check=True, cwd=cwd)


def assemble(src, out_bin, base, build, defs=()):
    obj = os.path.join(build, os.path.basename(out_bin) + '.o')
    elf = os.path.join(build, os.path.basename(out_bin) + '.elf')
    cmd = ['arm-none-eabi-as', '-mcpu=arm7tdmi', '-I', build, '-I', HERE,
           '-I', os.path.dirname(src)]
    for d in defs:
        cmd += ['--defsym', d]
    run(cmd + ['-o', obj, src])
    run(['arm-none-eabi-ld', f'-Ttext={base:#x}', '-o', elf, obj])
    run(['arm-none-eabi-objcopy', '-O', 'binary', elf, out_bin])
    return elf


# ─────────────────────────────── PNG → logo ────────────────────────────────
def decode_png(data):
    """A minimal PNG decoder: 8-bit depth, any colour type, no interlace."""
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    pos, idat, plte, trns = 8, b'', None, None
    while pos < len(data):
        n, = struct.unpack('>I', data[pos:pos + 4])
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b'IHDR':
            w, h, depth, ctype, _, _, inter = struct.unpack('>IIBBBBB', body)
        elif kind == b'PLTE':
            plte = body
        elif kind == b'tRNS':
            trns = body
        elif kind == b'IDAT':
            idat += body
    assert depth == 8 and inter == 0, 'only 8-bit, non-interlaced PNGs'
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * ch
    prev = bytearray(stride)
    p = 0
    px = []
    for _ in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        row = []
        for x in range(w):
            if ctype == 6:
                row.append(tuple(line[x * 4:x * 4 + 4]))
            elif ctype == 2:
                row.append(tuple(line[x * 3:x * 3 + 3]) + (255,))
            elif ctype == 0:
                row.append((line[x],) * 3 + (255,))
            elif ctype == 4:
                row.append((line[x * 2],) * 3 + (line[x * 2 + 1],))
            else:
                i = line[x]
                alpha = trns[i] if trns and i < len(trns) else 255
                row.append(tuple(plte[i * 3:i * 3 + 3]) + (alpha,))
        px.append(row)
        prev = line
    return w, h, px


def gen_logo(build):
    svg = open(os.path.join(REPO, 'web', 'favicon.svg'), 'rb').read()
    png = base64.b64decode(re.search(rb'base64,([A-Za-z0-9+/=]+)', svg).group(1))
    w, h, px = decode_png(png)
    out = [f'@ generated by build.py from web/favicon.svg ({w}x{h}); BGR555,',
           '@ 0x8000 = transparent', f'.equ LOGO_W, {w}', f'.equ LOGO_H, {h}',
           'logo_data:']
    for row in px:
        vals = []
        for r, g, b, a in row:
            if a < 128:
                vals.append(0x8000)
            else:
                vals.append((r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10))
        out.append('    .hword ' + ','.join(f'0x{v:04X}' for v in vals))
    out.append('    .align 2')
    open(os.path.join(build, 'logo_gen.inc'), 'w').write('\n'.join(out) + '\n')


# ──────────────────────────────── the font ─────────────────────────────────
# 5x7 glyphs in an 8x8 cell (columns 1-5 of 8: the renderer draws 6 columns,
# the first blank).  Lower case is drawn as upper case.  The digits and
# capitals are hwverified's font_gen.inc glyphs.
GLYPHS = {
    ' ': [], '!': ['..#..', '..#..', '..#..', '..#..', '..#..', '.....', '..#..'],
    '"': ['.#.#.', '.#.#.'], '#': ['.#.#.', '#####', '.#.#.', '.#.#.', '#####', '.#.#.'],
    '$': ['..#..', '.####', '#.#..', '.###.', '..#.#', '####.', '..#..'],
    '%': ['##...', '##..#', '...#.', '..#..', '.#...', '#..##', '...##'],
    '&': ['.#...', '#.#..', '#.#..', '.#...', '#.#.#', '#..#.', '.##.#'],
    "'": ['..#..', '..#..'], '(': ['...#.', '..#..', '.#...', '.#...', '.#...', '..#..', '...#.'],
    ')': ['.#...', '..#..', '...#.', '...#.', '...#.', '..#..', '.#...'],
    '*': ['.....', '#.#.#', '.###.', '#####', '.###.', '#.#.#'],
    '+': ['.....', '..#..', '..#..', '#####', '..#..', '..#..'],
    ',': ['.....', '.....', '.....', '.....', '.....', '..#..', '.#...'],
    '-': ['.....', '.....', '.....', '.###.'], '.': ['.....'] * 5 + ['.##..', '.##..'],
    '/': ['....#', '...#.', '...#.', '..#..', '.#...', '.#...', '#....'],
    ':': ['.....', '.##..', '.##..', '.....', '.##..', '.##..'],
    ';': ['.....', '.##..', '.##..', '.....', '.##..', '..#..', '.#...'],
    '<': ['...#.', '..#..', '.#...', '#....', '.#...', '..#..', '...#.'],
    '=': ['.....', '.....', '#####', '.....', '#####'],
    '>': ['.#...', '..#..', '...#.', '....#', '...#.', '..#..', '.#...'],
    '?': ['.###.', '#...#', '....#', '...#.', '..#..', '.....', '..#..'],
    '@': ['.###.', '#...#', '#.###', '#.#.#', '#.###', '#....', '.###.'],
    '[': ['.###.', '.#...', '.#...', '.#...', '.#...', '.#...', '.###.'],
    '\\': ['#....', '.#...', '.#...', '..#..', '...#.', '...#.', '....#'],
    ']': ['.###.', '...#.', '...#.', '...#.', '...#.', '...#.', '.###.'],
    '^': ['..#..', '.#.#.', '#...#'], '_': ['.....'] * 6 + ['#####'],
    '`': ['.#...', '..#..'], '{': ['...#.', '..#..', '..#..', '.#...', '..#..', '..#..', '...#.'],
    '|': ['..#..'] * 7, '}': ['.#...', '..#..', '..#..', '...#.', '..#..', '..#..', '.#...'],
    '~': ['.....', '.....', '.#...', '#.#.#', '...#.'],
}
HWV_ORDER = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-/."


def hwv_font():
    """hwverified's glyphs, keyed by character."""
    text = open(os.path.join(ROMS, 'hwverified', 'font_gen.inc')).read()
    rows = re.findall(r'\.byte ((?:0x[0-9A-F]{2},?){8})', text)
    return {c: [int(v, 16) for v in r.split(',')] for c, r in zip(HWV_ORDER, rows)}


def gen_font(build):
    base = hwv_font()
    out = ['@ generated by build.py: ASCII 0x20-0x7F, 8 bytes a glyph (bit 7 left)',
           'font_data:']
    for code in range(0x20, 0x80):
        c = chr(code)
        if c in base:
            rows = base[c]
        elif c.upper() in base:
            rows = base[c.upper()]
        else:
            pat = GLYPHS.get(c, GLYPHS['?'])
            rows = []
            for r in range(8):
                s = pat[r] if r < len(pat) else '.....'
                v = 0
                for i, ch in enumerate(s):
                    if ch == '#':
                        v |= 0x40 >> i
                rows.append(v)
        out.append('    .byte ' + ','.join(f'0x{v:02X}' for v in rows))
    open(os.path.join(build, 'font_gen.inc'), 'w').write('\n'.join(out) + '\n')


# ─────────────────────── cases from the recorded tables ────────────────────
def breakram_check(text, kind):
    """(mask, lo, hi, kind) for one recorded breakram cell."""
    if text == 'WD':
        return 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    if kind == 'edge':
        bits, v = text.split()
        n = int(v[1:])
        val = (n << 8) | int(bits, 2)
        return 0xFFFFFF07, val, val, 0
    if kind == 'stamp':
        t, reads = text.split()
        t = int(t[2:])
        if reads == '-':
            return 0xFFFFFFFF, (t << 16) | 0x4000, (t << 16) | 0xFFFF, 0
        v = (t << 16) | int(reads)
        return 0xFFFFFFFF, v, v, 0
    if text == '-':                      # never caught: reads >= 0x4000
        return 0xFFFFFF00, 0x00400000, 0xFFFFFE00, 0
    reads, line = text.split('@')
    v = (int(reads) << 8) | int(line)
    return 0xFFFFFFFF, v, v, 0


BREAKRAM_ROWS = {
    '': 'loop-iwram', '--stale=1': 'loop-stale', '--ewram': 'loop-ewram',
    '--stamp': 'stamp', '--stamp --vcount=160': 'stamp-v160',
    '--stamp --vcount=30': 'stamp-v30', '--stamp --dma0 --vcount=30': 'stamp-dma0-v30',
    '--stamp --vdma --vcount=159': 'stamp-vdma-v159',
    '--stamp --hblank --vcount=30': 'stamp-hblank-v30',
    '--vcount=30 --edge=200': 'edge200-v30',
    '--running --vcount=30 --edge=212': 'edge212-running-v30',
    '--vcount=30 --edge=255': 'edge255-v30', '--vcount=159 --edge=255': 'edge255-v159',
    '--nodma --hblank --vcount=30 --edge=12': 'edge12-nodma-hblank-v30',
    '--hblank --vcount=30 --edge=12': 'edge12-hblank-v30',
}

R0_NAMES = {
    'dmaphase': lambda a: ('hdma-' + ('nodma-' if a & 0x80 else '')
                           + ['mul', 'ewram', 'iwram', 'nop'][(a >> 4) & 3] + f'-k{a & 15}'),
    'kitdemo': lambda a: ('kit-hdma-' + ('nodma-' if a & 0x80 else '')
                          + ['mul', 'ewram', 'iwram', 'nop'][(a >> 4) & 3] + f'-k{a & 15}'),
    'wakeirq': lambda a: f'wakeirq-{a:02x}',
    'tmrw': lambda a: f'timer-read-vs-stop-{a:02x}',
    'lycwrite': lambda a: 'lyc-write-edge',
    'tmrdma': lambda a: ('tmrdma-dma1-only' if a == 0x10 else 'tmrdma-dma0-only'
                         if a == 0x20 else f'tmrdma-k{a}'),
    'dmastart': lambda a: ('dmastart-' + ('thumb-' if a & 0x10 else 'arm-')
                           + ['none', 'ldr-ewram-dest', 'ldr-iwram', 'nop-ldr-ewram',
                              'nop-nop-ldr-ewram', 'mul-ldr-ewram', 'str-ewram',
                              'ldm-iwram-2', 'ldrh-io', 'ldrh-ewram-dest'][a & 15]),
    'dmadur': lambda a: ('dmadur-' + ['cpu-starts-tm1', 'dma32-starts-tm1',
                                      'dma16-starts-tm1', 'iw-iw-32', 'iw-ew-32',
                                      'ew-iw-32', 'iw-iw-16', 'io-iw-32'][a & 7]
                         + f'-n{[0, 1, 2, 3, 4, 6, 8, 12][(a >> 4) & 7]}'),
    'dmamulirq': lambda a: ('dmamulirq-' + ['mul', 'ewram-ldr', 'no-dma'][a >> 16]
                            + f'-k{0x10000 - (a & 0xFFFF)}'),
    'dmairq': lambda a: ('dmairq-' + ['poll-iwram', 'poll-ewram', 'nop-sled'][a >> 8]
                         + f'-n{a & 0xFF}'),
    'irqwait': lambda a: ('irqwait-' + ('ewram-' if a & 0x100 else 'iwram-')
                          + ('thumb' if a & 0x200 else 'arm') + f'-k{a & 0xFF}'),
}
# Families carried in part (the multiboot image's 112 KiB): the cells kept.
# tests/roms/cyclelaws holds every recorded cell for CI.
R0_CASES = {
    # every phase of one EWRAM fetch period, ARM (6) and Thumb (3), and the
    # IWRAM controls at both ends
    'irqwait': ({16, 24} | {0x100 | k for k in range(17, 23)}
                | {0x300 | k for k in range(17, 20)} | {0x200 | k for k in (16, 24)}),
}
# Families left out of the ROM: tests/roms/cyclelaws holds them for CI.
R0_SKIP = {
    # its stamp buffers are 0x02010000-0x0203FFFF, over this ROM's results
    # block, runtime and multiboot body
    'hdmalag',
    # the multiboot image is full; the cpu suite's THUMBPC3 port carries
    # its row (a), and cyclelaws both cells
    'thumbpc3c',
    'dmairqf',
    # recorded after the multiboot body filled up (114648/114688 bytes); held
    # by tests/roms/cyclelaws until the image makes room
    'c2code', 'c2seq', 'contmap', 'vramexec', 'fifodma', 'fifomap',
    'hadesdsd', 'hdmaoam', 'hpreempt', 'memcnt', 'tmrffff', 'tmrffirq',
}
R0_SUITE = {'dmaphase': 'dma', 'kitdemo': 'dma', 'wakeirq': 'irq', 'tmrw': 'timer',
            'lycwrite': 'irq', 'tmrdma': 'dma', 'dmastart': 'dma', 'dmadur': 'dma',
            'dmamulirq': 'irq', 'dmairq': 'irq', 'irqwait': 'irq'}
R0_WHAT = {
    'dmaphase': 'an H-blank DMA against every phase of one kind of instruction: '
                'T << 16 | D (T = TM0 after the run, D = TM1 frozen by the DMA)',
    'kitdemo': "dmaphase's multiply and NOP runs rebuilt from probe.inc",
    'wakeirq': 'a halted CPU woken by an interrupt it takes: TM1 on handler entry '
               'and the BIOS return address the dispatcher pushed',
    'tmrw': 'a timer read against a timer stop in straight-line IWRAM code',
    'lycwrite': 'the V-count match interrupt is the compare\'s rising edge; a '
                'write of the current line raises it',
    'tmrdma': 'two immediate DMAs racing on a timer (alyosha timer/timer_reset): '
              'DMA1 writes TM0CNT, DMA0 armed k NOPs later reads it -- DMA1 runs '
              'first, DMA0 follows on the next cycle reading the old count under '
              'the new control, and a DMA-written TMCNT starts the timer where the '
              'write lands (see the payload header for the answer\'s fields)',
    'dmastart': 'when an immediate DMA takes the bus from the instruction after '
                'its enable: it requests at W+2, an access already begun finishes '
                'first (EWRAM word +5, halfword +2, one-cycle access +0), internal '
                'cycles run under the burst; ARM and Thumb alike',
    'dmadur': 'how long a one-unit immediate DMA holds the bus, and where a timer '
              'a DMA starts begins counting (where the write lands, not where the '
              'burst began)',
    'dmamulirq': 'a timer interrupt raised as an immediate DMA takes the bus: the '
                 'synchroniser keeps counting through the internal cycles the CPU '
                 'runs under the burst; one due after them waits for the burst\'s '
                 'end (TM1 at entry | entries << 16 | interrupted address bits 2-9 '
                 '<< 24)',
    'irqwait': 'a timer interrupt against a NOP sled in IWRAM or EWRAM, ARM or '
               'Thumb, k cycles to the overflow: from EWRAM it is taken one NOP '
               'later than the cycle count says (a recognition inside a fetch\'s '
               'wait states waits for the next instruction) and the entry pays '
               'for the in-flight fetch (TM1 at entry | NOPs done << 16 | '
               'entries << 24)',
    'dmairq': 'a DMA\'s end-of-transfer interrupt taken by a running CPU: N words '
              'EWRAM to EWRAM, the CPU polling a flag in IWRAM or EWRAM or running '
              'a NOP sled; the interrupt\'s synchroniser counts from where the '
              'burst let go of the bus (TM1 at entry | entries << 16 | interrupted '
              'address bits 2-9 << 24)',
}


def gen_tables(build):
    """gen_<suite>.inc: one case per console-recorded cell."""
    per_suite = {s: [] for s in ('irq', 'timer', 'dma', 'ppu')}
    r0 = json.load(open(os.path.join(HWLINK, 'r0-agb.json')))
    for name, cells in r0.items():
        if name in R0_SKIP:
            continue
        suite = R0_SUITE[name]
        lines = per_suite[suite]
        lines.append(f'@ {name}: {R0_WHAT[name]}.')
        lines.append(f'@ PROVENANCE: AGB SP (AGS-001) through tools/hwlink, recorded by '
                     f'tools/hwlink/r0table.py --record (3 runs a cell, every cell single-')
        lines.append(f'@ valued) into tools/hwlink/r0-agb.json; payload tests/roms/payloads/'
                     f'{name}.s, byte for byte.')
        for arg, want in cells.items():
            a = int(arg, 0)
            if name in R0_CASES and a not in R0_CASES[name]:
                continue
            answers = [int(w, 16) for w in want.split(' | ')]
            cname = R0_NAMES[name](a)
            if len(answers) == 1:
                lines.append(f'    cpay "{cname}", pl_{name}, {a:#x}, {answers[0]:#010x}')
            else:
                lines.append(f'    cpay2 "{cname}", pl_{name}, {a:#x}, '
                             f'{answers[0]:#010x}, {answers[1]:#010x}')
    sys.path.insert(0, HWLINK)
    import breakram
    b = json.load(open(os.path.join(HWLINK, 'breakram-agb.json')))
    lines = per_suite['ppu']
    lines.append('@ breakram: the mGBA suite\'s "DMA Prefetch Break" sequence run end to')
    lines.append('@ end from RAM (VBlankIntrWait through the BIOS, a table-walking')
    lines.append('@ dispatcher, an H-blank DMA3, a k-NOP entry sled): loop cells are')
    lines.append('@ reads<<8|VCOUNT (reads >= 0x4000 = never caught), stamp cells')
    lines.append('@ TM0<<16|reads, edge cells DISPSTAT&7 | VCOUNT<<8 (see the payload).')
    lines.append('@ PROVENANCE: AGB SP through tools/hwlink, tools/hwlink/breakram.py')
    lines.append('@ --record (2026-09-21, every cell single-valued) -> breakram-agb.json;')
    lines.append('@ payload tests/roms/payloads/breakram.s byte for byte.')
    for flags, cells in b.items():
        mode = breakram.mode_of(flags.split())
        kind = 'edge' if mode >> 24 else 'stamp' if mode & 0x200 else 'loop'
        row = BREAKRAM_ROWS[flags]
        for k, text in cells.items():
            mask, lo, hi, _ = breakram_check(text, kind)
            arg = mode | int(k)
            lines.append(f'    cpaym "breakram-{row}-k{k}", pl_breakram, {arg:#x}, '
                         f'{mask:#010x}, {lo:#010x}, {hi:#010x}   @ {text}')
    for suite, lines in per_suite.items():
        open(os.path.join(build, f'gen_{suite}.inc'), 'w').write(
            '@ generated by build.py from tools/hwlink/*-agb.json\n' + '\n'.join(lines) + '\n')


# ─────────────────────── sp-agb.json (record.py) ───────────────────────────
SP_FILE = os.environ.get('DBSUITE_SP_FILE', os.path.join(HERE, 'sp-agb.json'))
SWITIME_SUBJECTS = [
    'none', 'div-10-3', 'div-7fffffff-3', 'divarm-10-3', 'sqrt-0', 'sqrt-3fffffff',
    'sqrt-ffffffff', 'arctan-2000', 'arctan2-100-100', 'arctan2-neg', 'cpuset-32-halfwords',
    'cpuset-fill-32-words', 'cpufastset-256-words', 'cpufastset-fill-256-words',
    'getbioschecksum', 'bgaffineset-1', 'objaffineset-1', 'bitunpack-4-bytes',
    'lz77uncompwram-16', 'rluncompwram-16', 'diff8bitunfilterwram-16', 'midikey2freq',
    'intrwait-flag-already-set']
REGIONS = ['iwram', 'ewram', 'vram', 'pram', 'oam']


def sweeptrig_name(a):
    f, d = a & 0xFF, a >> 8
    row = ('shift0-' if f & 4 else 'sweep21-') + (('3ff' if f & 0x10 else '400') if f & 8 else
                                                   ('1299' if f & 0x10 else '1300'))
    return (f'sweeptrig-{row}' + ('-length' if f & 0x20 else '')
            + ('' if f & 3 == 1 else '-after-rows') + f'-d{d}')


def band(values, frac=16):
    """A poll count that jitters: the observed spread widened by 1/frac."""
    lo, hi = min(values), max(values)
    return max(0, lo - lo // frac), hi + hi // frac


# family -> (suite, WHAT/WHY/PROVENANCE comment, checks(arg, answers))
# checks yields (case name, slot offset, mask, values seen | (lo, hi) band)
def _r0(name_of):
    return lambda a, alts: [(name_of(a), 0, 0xFFFFFFFF, [w[0] for w in alts])]


def _sweeptrig(a, alts):
    got = [w[0] for w in alts]
    alive = all(g for g in got) and a & 0xFF not in (0x0D, 0x2D)
    if alive and (a & 0x20 or not a & 8):
        return [(sweeptrig_name(a), 0, 0xFFFFFFFF, band(got))]
    return [(sweeptrig_name(a), 0, 0xFFFFFFFF, got)]


def _words(names):
    """A memory family: names[i] = (case name, word index of 0x02008000, mask)."""
    def checks(a, alts):
        return [(n, 0x100 + 4 * i, m, [w[1 + i] & m for w in alts]) for n, i, m in names]
    return checks


def _psgfirst(a, alts):
    out = []
    for name, off in (('ch1-first', 0), ('ch2-first', 2), ('ch3-first', 4), ('ch4-first', 6),
                      ('ch1-nr10-0', 8), ('ch1-nr10-11', 10), ('ch1-after-ch2', 12),
                      ('ch2-before-ch1', 14), ('ch1-second', 16), ('ch1-again', 18),
                      ('ch1-length-off', 24), ('ch2-length-off', 26)):
        vals = []
        for w in alts:
            word = w[1 + off // 4]
            vals.append((word >> (8 * (off & 3))) & 0xFFFF)
        exact = all(v in (0, 0xFFFF) for v in vals)
        out.append((f'ram-psg-{name}', 0x100 + off, 0xFFFF, vals if exact else band(vals)))
    return out


SP_FAMILIES = {
    'switime': ('bios', [
        'switime: TM0 (/1) across one ARM `swi` called from IWRAM -- the',
        'exception, the BIOS dispatch, the function and the return -- plus the',
        'start and the read (subject "none").  WHY: an HLE BIOS gets the answers',
        'right and the time wrong (payloads/switime.s).'],
        _r0(lambda a: f'switime-{SWITIME_SUBJECTS[a]}')),
    'sweeptrig': ('apu', [
        'sweeptrig: channel 1\'s trigger-time overflow check at sweep shift 0',
        '(NR10 = 0): f 0x400 never plays (0x400 + 0x400 overflows), f 0x3FF lives,',
        'length on or off; sweep 0x21 at 1300 alone lives to a tick (banded:',
        'its poll count jitters).  Pan Docs says shift 0 skips the check',
        '(payloads/sweeptrig.s).'],
        _sweeptrig),
    'fifodma': ('dma', [
        'fifodma: the first sound-FIFO DMA after TM0 overflows k cycles in,',
        'against a TM1 read n NOPs on (variant 1: an EWRAM load before the',
        'read).  The burst lands a fixed time after the overflow and a load in',
        'flight holds it off to its end (payloads/fifodma.s).'],
        _r0(lambda a: f'fifodma-{"ewram-load-" if a >> 16 else ""}k{(a >> 8) & 0xFF}-n{a & 0xFF}')),
    'dmasteal': ('dma', [
        'dmasteal: TM0 over a fixed 1200-cycle loop that spans line 100\'s',
        'H-blank, entered by a V-count match halt, with an H-blank DMA of n',
        'units from one region to another (0 = no DMA): the CPU pays 3 + 2n on',
        'IWRAM 16-bit, and each region\'s own access cost',
        '(tests/roms/payloads/dmasteal.s).'],
        _r0(lambda a: ('dmasteal-none' if not a & 0xFF else
                       f'dmasteal-{REGIONS[(a >> 8) & 15]}-to-{REGIONS[(a >> 12) & 15]}-'
                       f'{32 if a >> 16 else 16}bit-n{a & 0xFF}'))),
    'timergeo': ('timer', [
        'timergeo: entered at the top of a line by a V-count match halt, TM1',
        'at prescaler 64 counts a fixed 1200 cycles (TM1 << 16 | TM0): the',
        'prescaler is one free-running divider, so the count depends on where',
        'in its 64 cycles the line began (1232 mod 64 = 16: period 4 lines);',
        'e = extra cycles before the read walks the read across a tick.',
        'Prescalers 256/1024 walk with the frame and are not checked',
        '(tests/roms/payloads/timergeo.s).'],
        _r0(lambda a: (f'timergeo-p{[1, 64, 256, 1024][a & 3]}-line{(a >> 8) & 0xFF}'
                       + (f'-e{a >> 16}' if a >> 16 else '')))),
    'halthb': ('dma', [
        'halthb: halted on an H-blank with the bus idle, W = TM0 when the CPU',
        'wakes, D = TM1 frozen by the H-blank DMA\'s own write; W << 16 | D is',
        'the same for every k-NOP sled before the halt (entry is controlled)',
        '(tests/roms/payloads/halthb.s).'],
        _words([(f'halthb-wake-and-grant-k{k}', k, 0xFFFFFFFF) for k in (0, 4, 9, 13)])),
    'vdmageo': ('dma', [
        'vdmageo: as halthb for the V-blank DMA: the grant\'s floor against a',
        'halted CPU\'s wake (tests/roms/payloads/vdmageo.s).'],
        _words([(f'vdmageo-wake-and-grant-k{k}', k, 0xFFFFFFFF) for k in (0, 4, 9, 13)])),
    'haltprobe': ('irq', [
        'haltprobe: parked on line 100 with a V-count match armed for 104: a',
        'plain strb to HALTCNT from RAM does not halt (TM0 small, still line',
        '100); SWI 2 does (about four lines, line 104).  HALTCNT answers only',
        'to BIOS code (tests/roms/payloads/haltprobe.s).'],
        lambda a, alts: _words([(f'haltprobe-{"swi2" if a else "strb-haltcnt"}-tm0', 0, 0xFFFFFFFF),
                                (f'haltprobe-{"swi2" if a else "strb-haltcnt"}-vcount', 1, 0xFFFF)])(a, alts)),
    'vbwait': ('irq', [
        'vbwait: VBlankIntrWait called from a controlled cycle, through the',
        'BIOS and an IWRAM handler, timed on the way in (H) and out (R) and to',
        'a second V-count wake (T); trials 0..5 (tests/roms/payloads/vbwait.s).'],
        lambda a, alts: _words([(f'vbwait-{"vcount160" if a & 0x100 else "vblank"}-t{i}-{f}', 3 * i + j, 0xFFFFFFFF)
                                for i in (0, 5) for j, f in enumerate('TRH')])(a, alts)),
    'psgfirst': ('apu', [
        'psgfirst run from RAM (gbaedge page 51\'s rows as a link-rig payload):',
        'poll counts until each channel stops after a PSG master-on; a dying',
        'trigger reads 0, a never-expiring one FFFF, the rest are banded',
        '(tests/roms/payloads/psgfirst.s).'],
        _psgfirst),
}


# families recorded more widely than the multiboot image has room to check:
# the cells kept are the ones either side of each step in the answer
SP_CASES = {
    'fifodma': {20 << 8 | n for n in (13, 14, 15, 16, 17, 23, 24, 25)}
               | {1 << 16 | 20 << 8 | n for n in (10, 11, 16, 17, 18, 20, 21)}
               | {33 << 8 | n for n in (29, 30)},
    # the eight lines, and the 64-cycle sweep every 16 cycles
    'timergeo': ({0 | 100 << 8} | {1 | line << 8 for line in range(100, 108)}
                 | {1 | 103 << 8 | e << 16 for e in range(0, 64, 16)}),
}


def gen_sp(build):
    """gen_sp_<suite>.inc: the families in sp-agb.json, one case per check."""
    table = json.load(open(SP_FILE)) if os.path.exists(SP_FILE) else {}
    per_suite = {s: [] for s in ('irq', 'timer', 'dma', 'apu', 'bios')}
    for name, (suite, what, checks) in SP_FAMILIES.items():
        lines = per_suite[suite]
        lines.append(f'    payload_blob pl_{name}, "{name}.bin"')
        cells = table.get(name)
        if not cells:
            continue
        lines += [f'@ {w}' for w in what]
        lines.append('@ PROVENANCE: AGB SP (AGS-001) through tools/hwlink, recorded by '
                     'tests/roms/dbsuite/record.py')
        lines.append('@ (3 runs a cell, interleaved) into tests/roms/dbsuite/sp-agb.json.')
        for arg, text in cells.items():
            a = int(arg, 0)
            if name in SP_CASES and a not in SP_CASES[name]:
                continue
            alts = [[int(w, 16) for w in alt.split()] for alt in text.split(' | ')]
            first = True
            for cname, off, mask, seen in checks(a, alts):
                if isinstance(seen, tuple):
                    lo, hi, kind = seen[0], seen[1], 'K_RANGE'
                else:
                    vals = sorted(set(seen))
                    if len(vals) == 2:
                        lo, hi, kind = vals[0], vals[1], 'K_TWO'
                    else:
                        lo, hi, kind = vals[0], vals[-1], 'K_RANGE'
                if first:
                    lines.append(f'    case "{cname}", run_payload, pl_{name}, {a:#x}, {off:#x}, '
                                 f'{mask:#010x}, {lo:#010x}, {hi:#010x}, {kind}')
                else:
                    lines.append(f'    case "{cname}", RUN_SAME, 0, 0, {off:#x}, '
                                 f'{mask:#010x}, {lo:#010x}, {hi:#010x}, {kind}')
                first = False
    for suite, lines in per_suite.items():
        open(os.path.join(build, f'gen_sp_{suite}.inc'), 'w').write(
            '@ generated by build.py from tests/roms/dbsuite/sp-agb.json\n'
            + '\n'.join(lines) + '\n')


# ─────────────────────────────── the images ────────────────────────────────
def patch_header(rom, title, code):
    rom[0xA0:0xAC] = title.encode().ljust(12, b'\0')[:12]
    rom[0xAC:0xB0] = code.encode()
    rom[0xB0:0xB2] = b'01'
    rom[0xB2] = 0x96
    c = 0
    for i in range(0xA0, 0xBD):
        c = (c - rom[i]) & 0xFF
    rom[0xBD] = (c - 0x19) & 0xFF


def symbols(elf):
    out = subprocess.run(['arm-none-eabi-nm', elf], check=True, capture_output=True,
                         text=True).stdout
    syms = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            syms[parts[2]] = int(parts[0], 16)
    return syms


def case_list(image, base, syms):
    """Read the case and suite tables back out of a built image."""
    def word(addr):
        return struct.unpack_from('<I', image, addr - base)[0]

    def cstr(addr):
        end = image.index(b'\0', addr - base)
        return image[addr - base:end].decode()
    n = syms['N_CASES']
    suites = []
    s = syms['suite_table']
    while word(s):
        suites.append((cstr(word(s)), word(s + 4)))
        s += 8
    cases = []
    for i in range(n):
        d = syms['case_table'] + 32 * i
        info = word(d + 16)
        suite = [nm for nm, first in suites if first <= i][-1]
        cases.append({'index': i, 'suite': suite, 'name': cstr(word(d + 12)),
                      'kind': ['range', 'one-of-two', 'slot'][info & 15],
                      'cartridge_only': bool(info & 0x10),
                      'risky': bool(info & 0x20),
                      'offset': (info >> 16) & 0xFFF, 'mask': f'{word(d + 20):08X}',
                      'lo': f'{word(d + 24):08X}', 'hi': f'{word(d + 28):08X}'})
    return suites, cases


def build_diag(size, out, nostub=False):
    """mbdiag.s as a multiboot image of `size` bytes (see its header)."""
    with tempfile.TemporaryDirectory(prefix='dbsuite-diag-') as build:
        def one(pad):
            if nostub:
                assemble(os.path.join(HERE, 'mbdiag.s'), out, 0x02000000, build,
                         defs=('NOSTUB=1', f'PAD={pad}'))
            else:
                assemble(os.path.join(HERE, 'mbdiag.s'),
                         os.path.join(build, 'body.bin'), MB_HOME, build,
                         defs=('NOSTUB=0', f'PAD={pad}'))
                assemble(os.path.join(HERE, 'mbstub.s'), out, 0x02000000, build)
            return os.path.getsize(out)
        base = one(0)
        if size > base:
            one(size - base)
        img = bytearray(open(out, 'rb').read())
        while len(img) % 16 or len(img) < 0x200:
            img.append(0)
        patch_header(img, 'DBSUITE DIAG', 'ADBE')
        open(out, 'wb').write(img)
        romfix.gba_logo(out)
    print(f'{out}: {len(img)} bytes ({"no stub" if nostub else "stub + body"})')


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--diag':
        build_diag(int(sys.argv[2], 0), sys.argv[3], '--nostub' in sys.argv)
        return
    for tool in ('arm-none-eabi-as', 'arm-none-eabi-ld', 'arm-none-eabi-objcopy'):
        if not shutil.which(tool):
            sys.exit(f'{tool} not found')
    with tempfile.TemporaryDirectory(prefix='dbsuite-') as build:
        for name, src in PAYLOADS.items():
            assemble(src, os.path.join(build, name + '.bin'), PAYLOAD_HOME, build)
        gen_logo(build)
        gen_font(build)
        gen_tables(build)
        gen_sp(build)

        # cartridge
        cart = os.path.join(HERE, 'dbsuite.gba')
        elf = assemble(os.path.join(HERE, 'dbsuite.s'), cart, 0x08000000, build,
                       defs=('MB=0',))
        rom = bytearray(open(cart, 'rb').read())
        while len(rom) % 16:
            rom.append(0)
        patch_header(rom, 'DBSUITE', 'ADBE')
        open(cart, 'wb').write(rom)
        romfix.gba_logo(cart)
        suites, cases = case_list(bytes(rom), 0x08000000, symbols(elf))

        # multiboot: the body runs at MB_HOME; mbstub.s copies it there
        body = os.path.join(build, 'body.bin')
        melf = assemble(os.path.join(HERE, 'dbsuite.s'), body, MB_HOME, build,
                        defs=('MB=1',))
        size = os.path.getsize(body)
        if size > MB_BODY_MAX:
            sys.exit(f'multiboot body is {size} bytes, over {MB_BODY_MAX}')
        mb = os.path.join(HERE, 'dbsuite.mb.gba')
        stub_elf = assemble(os.path.join(HERE, 'mbstub.s'), mb, 0x02000000, build)
        mb_config = symbols(stub_elf)['body'] - 0x02000000 + 4
        img = bytearray(open(mb, 'rb').read())
        while len(img) % 16:
            img.append(0)
        patch_header(img, 'DBSUITE MB', 'ADBE')
        open(mb, 'wb').write(img)
        romfix.gba_logo(mb)
        if len(img) > 0x40000:
            sys.exit(f'multiboot image is {len(img)} bytes, over 256 KB')
        msuites, mcases = case_list(open(body, 'rb').read(), MB_HOME, symbols(melf))
        assert [c['name'] for c in mcases] == [c['name'] for c in cases]

    json.dump({'version': 1, 'results_block': '0x02014000',
               'rom_config_offset': {'cartridge': '0xC4', 'multiboot': f'{mb_config:#x}'},
               'suites':
               [{'name': n, 'first': f} for n, f in suites], 'cases': cases},
              open(os.path.join(HERE, 'cases.json'), 'w'), indent=1)
    print(f'{cart}: {len(rom)} bytes, {len(cases)} cases in {len(suites)} suites')
    print(f'{mb}: {len(img)} bytes (body {size} bytes at {MB_HOME:#x})')


if __name__ == '__main__':
    main()
