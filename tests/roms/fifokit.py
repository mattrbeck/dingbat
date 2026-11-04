"""fifokit.py -- alyosha fifo_6's sequence at its own waits (WS0 3/1), from a
flash cart, in one ROM that sends its answers down the link cable.

    python3 tests/roms/fifokit.py build OUTDIR    # OUTDIR/fifokit.gba + predictions
    python3 tests/roms/fifokit.py listen OUTDIR   # wait for the cart's report, score it

The link rig settled fifo_6's path at WAITCNT 0x4000 with the slot empty: an
ARM sled there reads 0xFFFFxxxx, NV no-ops (payloads/nvcond.s, f6slot.s,
f6q.s; docs/playtest-bugs.md). The empty slot does not answer reliably at
3/1, which is fifo_6's setting, and the one rule that made fifo_6 pass
(PF_WAIT_UNDER_BURST) breaks fifo_2..4 there. A cartridge whose sled region
holds 0xFFFFFFFF runs the same NV sled at any waits, so this is
payloads/f6q3.s (f6q.s plus a 3/1 bit) in payloadrun.s's wrapper, every cell
once, the answers streamed by linkreport (LRPT) when the run is done and the
screen green. The 4/2 cells are controls: they must read what the empty slot
read (tools/hwlink/r0-agb.json, f6q).

Boot it with the GB-Link cable plugged in; `listen` saves the block and
scores it against the predictions written at build time (base, the two
knobs landed, and PF_WAIT_UNDER_BURST on).
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, 'tools', 'hwlink'))
sys.path.insert(0, HERE)
import payloadcmp  # noqa: E402

PAYLOAD = os.path.join(HERE, 'payloads', 'f6q3.s')
# f6q3's SLED is 0x08010000. Every cell takes its interrupt within ~200
# cycles, but a sled that ran to TM3's 262144-cycle watchdog would cover
# 256 KiB at 3/1, and a flash cart may answer anything past the image.
SLED_END = 0x60000
RESULTS = 0x02000000
W31, W42, PF, IW = 0x2000, 0x0000, 0x4000, 0x10000000
NOIRQ = 0x20000000            # DMA1's interrupt off: TM3 at Q is the one taken


def cells():
    """(arg, label). P = 39 (fifo_6's period) unless said."""
    out = []
    p39 = 39 << 16
    for w, wn in ((W31 | PF, '3/1 pf on'), (W31, '3/1 pf off')):
        for d in range(12):              # the DMA-end interrupt, fifo_6's own
            out.append((w | p39 | d << 24, f'{wn} dma-irq d={d}'))
        for p in range(34, 48):
            out.append((w | p << 16, f'{wn} dma-irq P={p}'))
        for d in range(6):               # TM3 at Q, the burst running
            for q in range(66, 96):
                out.append((NOIRQ | w | p39 | d << 24 | q, f'{wn} tm3 d={d} Q={q}'))
        for q in range(60, 72):          # TM3 at Q, no DMA at all
            out.append((w | q, f'{wn} tm3 no-dma Q={q}'))
    for d in range(6):                   # controls: the empty slot's answers
        out.append((PF | p39 | d << 24, f'4/2 pf on dma-irq d={d}'))
        out.append((NOIRQ | PF | p39 | d << 24 | 80, f'4/2 pf on tm3 d={d} Q=80'))
    out.append((IW | p39, 'iwram dma-irq'))
    return out


WRAPPER = r'''
    .arm
    .text
    .global _start
_start:
    b   main
    .space 0x9C
    .space 0x20
main:
    ldr sp, =0x03007F00
    ldr r0, =payload
    ldr r1, =0x03000000
    ldr r2, =payload_end
    mov r3, r0
    sub r2, r2, r3
1:  ldr r4, [r0], #4
    str r4, [r1], #4
    subs r2, r2, #4
    bgt 1b
    ldr r7, =0x02000000
    ldr r8, =arg_table
    ldr r9, =arg_count
    ldr r9, [r9]
2:  ldr r0, [r8], #4
    ldr r10, =0x03000000
    mov lr, pc
    bx  r10
    str r0, [r7], #4
    subs r9, r9, #1
    bgt 2b
    @ done: a green screen, then the block down the link forever
    mov r0, #0x04000000
    mov r1, #0
    strh r1, [r0]
    ldr r0, =0x05000000
    ldr r1, =0x03E0
    strh r1, [r0]
    ldr r0, =0x02000000
    ldr r1, =arg_count
    ldr r1, [r1]
    bl  link_report_init
3:  bl  link_report_poll
    b   3b
    .ltorg
    .equ lr_state, 0x0203FF00
    .include "linkreport_ram.inc"
    .align 2
arg_count:
    .word {count}
arg_table:
{table}
    .align 2
payload:
    .incbin "payload.bin"
    .align 2
payload_end:
'''


def build(outdir):
    os.makedirs(outdir, exist_ok=True)
    work = os.path.join(outdir, 'build')
    os.makedirs(work, exist_ok=True)
    import romfix
    run = lambda c: subprocess.run(c, check=True)
    src_dir = os.path.dirname(PAYLOAD)
    run(['arm-none-eabi-as', '-mcpu=arm7tdmi', '-I', src_dir, '-o', f'{work}/payload.o', PAYLOAD])
    run(['arm-none-eabi-ld', '-Ttext=0x3000000', '-o', f'{work}/payload.elf', f'{work}/payload.o'])
    run(['arm-none-eabi-objcopy', '-O', 'binary', f'{work}/payload.elf', f'{work}/payload.bin'])
    # linkreport.inc keeps its state inline; a cartridge needs it in RAM
    lr = open(os.path.join(HERE, 'linkreport.inc')).read()
    lr = lr[:lr.index('    .align 2\nlr_state:')]
    open(f'{work}/linkreport_ram.inc', 'w').write(lr)
    cs = cells()
    table = '\n'.join(f'    .word {a:#x}' for a, _ in cs)
    open(f'{work}/kit.s', 'w').write(WRAPPER.replace('{count}', str(len(cs))).replace('{table}', table))
    run(['arm-none-eabi-as', '-mcpu=arm7tdmi', '-I', work, '-o', f'{work}/kit.o', f'{work}/kit.s'])
    run(['arm-none-eabi-ld', '-Ttext=0x08000000', '-o', f'{work}/kit.elf', f'{work}/kit.o'])
    rom = os.path.join(outdir, 'fifokit.gba')
    run(['arm-none-eabi-objcopy', '-O', 'binary', f'{work}/kit.elf', rom])
    data = bytearray(open(rom, 'rb').read())
    assert len(data) < 0x10000, 'the wrapper reaches the sled'
    data += b'\xFF' * (SLED_END - len(data))
    open(rom, 'wb').write(bytes(data))
    romfix.gba_logo(rom)
    print(f'{rom}: {len(cs)} cells, {os.path.getsize(rom)} bytes')
    return rom, cs


VARIANTS = {
    'base': [],
    'landed': [],   # the tree as built: the two landed knobs on (defaults)
    'pfwait': ['-d:PF_WAIT_UNDER_BURST=true'],
}


def predict(outdir, rom, cs):
    """dingbat's answer per cell, each variant, real BIOS."""
    out = {}
    for name, defs in VARIANTS.items():
        if name == 'base':
            defs = ['-d:FIFO_IRQ_CREDIT=0', '-d:IRQ_FETCH_STOPPED_BUFFER=false']
        drv = os.path.join(outdir, 'build', f'drv_{name}')
        subprocess.run(['nim', 'c', '-d:test_harness', '-d:release', '--path:src',
                        '--hints:off', '--warnings:off', *defs,
                        f'--nimcache:{outdir}/build/nc_{name}', f'-o:{drv}',
                        'tools/playtest/drivers/dingbat_driver.nim'], check=True, cwd=REPO)
        os.environ['PLAYTEST_DINGBAT_DRIVER'] = drv
        got = payloadcmp.in_emulators(rom, len(cs), names=('dingbat-bios',),
                                      frames=8 + len(cs) // 8)['dingbat-bios']
        out[name] = got
    del os.environ['PLAYTEST_DINGBAT_DRIVER']
    with open(os.path.join(outdir, 'predictions.txt'), 'w') as f:
        f.write('# low 16 bits = TM1 at the handler\'s read; IF in the top half\n')
        f.write(f'{"arg":>10}  ' + ''.join(f'{n:>10}' for n in VARIANTS) + '   cell\n')
        for i, (a, label) in enumerate(cs):
            f.write(f'{a:#010x}  ' + ''.join(f'{out[n][i] & 0xFFFF:>10}' for n in VARIANTS)
                    + f'   {label}\n')
    json.dump({'cells': cs, 'pred': out}, open(os.path.join(outdir, 'predictions.json'), 'w'))
    print('predictions written')


def listen(outdir, hours=12):
    import gblink
    pred = json.load(open(os.path.join(outdir, 'predictions.json')))
    n = len(pred['cells'])
    deadline = time.time() + hours * 3600
    while time.time() < deadline:
        try:
            with gblink.GBLink() as link:
                link.open_link()
                words, msg = gblink.read_report(link)
        except Exception as e:           # no adapter, console off: keep waiting
            words, msg = None, repr(e)
        if words and len(words) == n:
            json.dump(words, open(os.path.join(outdir, 'console.json'), 'w'))
            score(outdir, words, pred)
            return 0
        time.sleep(5)
    return 1


def score(outdir, words, pred):
    lines = []
    for name, got in pred['pred'].items():
        ok = sum(1 for w, g in zip(words, got) if w == g)
        lines.append(f'{name}: {ok}/{len(words)} cells')
    lines.append('')
    for i, ((a, label), w) in enumerate(zip(pred['cells'], words)):
        row = ' '.join(f'{pred["pred"][n][i] & 0xFFFF:>4}' for n in pred['pred'])
        mark = '' if all(pred['pred'][n][i] == w for n in pred['pred']) else '  <<<'
        lines.append(f'{a:#010x} console {w & 0xFFFF:>4} (IF {w >> 16:#06x})  '
                     f'base/landed/pfwait {row}   {label}{mark}')
    open(os.path.join(outdir, 'score.txt'), 'w').write('\n'.join(lines) + '\n')
    print('\n'.join(lines[:3]))


if __name__ == '__main__':
    cmd, outdir = sys.argv[1], os.path.abspath(sys.argv[2])
    if cmd == 'build':
        rom, cs = build(outdir)
        predict(outdir, rom, cs)
    elif cmd == 'listen':
        sys.exit(listen(outdir))
