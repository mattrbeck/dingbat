"""alyfifo2.py OUTDIR -- the second flashcart round for alyosha fifo_dma: the
FIFO_CART_CHAIN_LATE rule's neighbours, and fifo_6's handler arrival swept.

Every variant prints the low byte of one TM1 read as "Failed test NNN", like
alyfifo.py's (tests/roms/alyfifo.py; same cached upload, --rom/--rom6 for
other copies). dingbat's answer for each is printed when it is written: the
console's answers are scored against those, recorded before the run.

fifo_k<K>_t2a / _t2b   fifo.gba's test 2 (both reads) with TM0 at period K
    instead of 32 (the word at 0x23C). K = 30, 31, 33, 34. The round-1 reads
    (K = 32: 104, 139) put the second overflow's request on the cycle after
    the first burst; one period shorter puts it on the hand-back itself (the
    plain FIFO_HANDBACK_CHAIN case), longer ones after it.

fifo6_w<WAITCNT>_p<P>  fifo_6.gba with its verdict branch made unconditional
    (0x240: `b f001a`), WAITCNT (0x17C) and TM0's period (0x24C) changed.
    w4014 = the ROM's own (prefetcher on, 3/1): P = 39..46, one cycle a step,
    two turns of the prefetcher's 4-cycle word. w4014_p39 is fifo_6 itself:
    the console read 123 (it passed). w0014 = the same waits, prefetcher off:
    P = 48..55 (its handler is slower, so the next refill, two periods on,
    must come later; from P = 56 the first overflow leaves the NOP sled for
    the `ldr r0, [r6]` after it, which then times the burst at every P).
    dingbat's handler read is 3 cycles late at P = 39; a constant 3 across
    the sweep puts the cost on a fixed part of the path (the BIOS
    dispatch, the refill into the handler), a step that moves with P on the
    prefetcher's state when the interrupt is taken.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import alyfifo  # noqa: E402

ROM6 = os.path.join(os.path.dirname(alyfifo.ROM), 'fifo_6.gba')

# fifo.gba: test 2's TM0 control word (reload 0xFFE0 = period 32, enable)
T2_TMR = 0x23C
# fifo_6.gba
F6_WAIT, F6_TMR, F6_BNE = 0x17C, 0x24C, 0x240
F6_EXPECT = {F6_WAIT: 0x00004014, F6_TMR: 0x00C0FFD9, F6_BNE: 0x1A000004}


def tmr(ctrl, period):
    return ctrl << 16 | (0x10000 - period)


def variants():
    out = []
    for k in (30, 31, 33, 34):
        for t in ('t2a', 't2b'):
            out.append((alyfifo.ROM, f'fifo_k{k}_{t}',
                        {**alyfifo.VARIANTS['fifo_' + t], T2_TMR: tmr(0x0080, k)},
                        {**alyfifo.EXPECT, T2_TMR: 0x0080FFE0}))
    sweeps = [(0x4014, range(39, 47)), (0x0014, range(48, 56))]
    for wait, periods in sweeps:
        for p in periods:
            out.append((ROM6, f'fifo6_w{wait:04x}_p{p}',
                        {F6_BNE: 0xEA000004, F6_WAIT: wait, F6_TMR: tmr(0x00C0, p)},
                        F6_EXPECT))
    return out


def build(outdir, rom=None, rom6=None):
    os.makedirs(outdir, exist_ok=True)
    cache = {}
    paths = []
    for src, name, patch, expect in variants():
        if rom and src == alyfifo.ROM:
            src = rom
        if rom6 and src == ROM6:
            src = rom6
        if src not in cache:
            cache[src] = open(src, 'rb').read()
        data = cache[src]
        for off, want in expect.items():
            if alyfifo.word(data, off) != want:
                sys.exit(f'{src}: word at {off:#x} is {alyfifo.word(data, off):#010x}, '
                         f'not {want:#010x}')
        d = bytearray(data)
        for off, w in patch.items():
            d[off:off + 4] = w.to_bytes(4, 'little')
        path = os.path.join(outdir, name + '.gba')
        open(path, 'wb').write(bytes(d))
        paths.append(path)
    return paths


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    opt = dict(a[2:].split('=', 1) for a in sys.argv[1:] if a.startswith('--') and '=' in a)
    if not args:
        sys.exit(__doc__)
    for p in build(args[0], opt.get('rom'), opt.get('rom6')):
        print(f'{os.path.basename(p)}: dingbat {alyfifo.predict(p)}')
