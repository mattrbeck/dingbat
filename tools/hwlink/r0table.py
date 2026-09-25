"""Record and check payloads that answer in r0, one word per argument.

    python3 r0table.py --record dmaphase     # console -> r0-agb.json (3 runs a cell)
    python3 r0table.py --check [dmaphase]    # the emulators against that file
    python3 r0table.py dmaphase 0x10 0x11    # ad hoc, console and emulators

A cell the console answers two ways is recorded with both answers and can
never match; that is the point of keeping it.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import payloadcmp

EMULATORS = tuple(os.environ.get('R0_EMULATORS', 'dingbat,dingbat-bios,mgba').split(','))
TABLE_FILE = os.path.join(HERE, 'r0-agb.json')

# payload -> the arguments worth keeping
TABLE = {
    # controls, then a period and more of each run: multiplies, EWRAM loads,
    # IWRAM loads, NOPs
    'dmaphase': ([0x80, 0x85, 0x90, 0xA0, 0xB0]
                 + list(range(0x00, 0x0A)) + list(range(0x10, 0x1C))
                 + list(range(0x20, 0x26)) + [0x30, 0x31, 0x32]),
    # halted wake with and without IME; then the running-CPU controls:
    # V-count and timer sources, R / interrupted NOP / return into the sled,
    # and a timer stopped as the handler's first act
    'wakeirq': [0x00, 0x10, 0x20, 0x28, 0x60, 0x24, 0x2C, 0x64, 0x22, 0x26],
    'tmrw': [0x00, 0x01, 0x02, 0x10, 0x11, 0x20, 0x21, 0x30],
    'lycwrite': [0],
    # tests/roms/payloads/probe.inc held to the console: dmaphase's controls,
    # a multiply period and three NOP phases, rebuilt from the kit
    'kitdemo': [0x80, 0xB0] + list(range(0x00, 0x07)) + [0x30, 0x31, 0x32],
    # alyosha timer_reset's DMA race: k = 0..7 NOPs, DMA1 alone, DMA0 alone
    'tmrdma': list(range(0, 8)) + [0x10, 0x20],
    # the instruction after an immediate DMA's enable, ARM then Thumb
    'dmastart': list(range(0, 10)) + list(range(0x10, 0x1A)),
    # one-unit bursts by n NOPs; not the two cells that read TM1 before the
    # DMA starts it
    'dmadur': [n * 16 + v for n in range(8) for v in range(8)
               if not (n == 0 and v in (1, 2))],
    # a timer interrupt raised k cycles after TM0 starts, across the burst's
    # start one cycle at a time, then across the rest of it
    'dmamulirq': [(v << 16) | (0x10000 - k)
                  for v, ks in ((0, list(range(1, 17)) + list(range(22, 123, 20)) + [106, 110, 114, 118]),
                                (1, list(range(1, 17)) + list(range(22, 123, 20)) + [106, 110, 114, 118]),
                                (2, list(range(2, 123, 20))))
                  for k in ks],
    # a DMA's end-of-transfer interrupt against a running CPU: N = 1..64
    # words, polling from IWRAM / EWRAM, or a NOP sled
    'dmairq': [v << 8 | n for v in (0, 1, 2) for n in (1, 2, 4, 16, 64)],
    # a timer interrupt against a NOP sled: IWRAM (ARM, Thumb) and EWRAM
    # (ARM, Thumb), k = 16..44 cycles to the overflow
    'irqwait': ([k for k in range(16, 25)] + [0x100 | k for k in range(16, 45)] +
                [0x300 | k for k in range(16, 45)] + [0x200 | k for k in range(16, 25)]),
    # Hades-Tests dma-start-delay's two checks as compiled: from IWRAM, then
    # from board WRAM (the request lands in a 6-cycle ARM fetch)
    'hadesdsd': [0, 1, 2, 3],
    # an H-blank DMA landing in a running immediate burst: which gap it takes
    'hpreempt': [0xC0 + k for k in range(8)] + [0x100 + k for k in range(4)],
    # MEMCNT bit 5 clear: board WRAM's region is the chip WRAM (reads, writes,
    # 32K mirror, one-cycle timing); MEMCNT's reset value. Not the swap (bit
    # 0) cells 8-12, which dingbat does not model (payload header)
    'memcnt': [13] + list(range(0, 8)),
    # an H-blank DMA whose bursts outlast the line (configuration << 8 | word):
    # bursts, last start and last unit from the first, burst 1's gap; one
    # channel of 0.5 to 3.5 lines, near the V-blank edge, about a line, and
    # with nothing else armed; the V-blank arming's first start; two
    # channels' burst counts. Not the configurations 23-30, whose second
    # channel starts two cycles late here (the payload's header)
    # fifodma's k = 20 staircase after w = 0, 4, 6, 7, 8 words stored to the
    # FIFO: the eighth word leaves it reading empty (payloads/fifomap.s)
    'fifomap': [w << 26 | 20 << 8 | n for w in (0, 4, 6, 7, 8) for n in (17, 40)],
    'hdmalag': ([c << 8 | w for c in list(range(0, 12)) + [15, 16, 17, 18, 19, 20, 31, 32, 33, 34]
                 for w in (1, 10, 11, 14)]
                + [8 << 8 | 2, 22 << 8 | 1, 22 << 8 | 11]
                + [c << 8 | w for c in (12, 13, 14) for w in (1, 6)]),
    # renderer contention, one access at k (dot k + 37 of this core's line):
    # (scene, access, first k, count) -- text BGs, 8bpp, fine scroll 7 and
    # 5 at the line's end, mode 2's lock-out, mode 1, the bitmap, palette
    # reads (one a pixel, two under alpha, mode 5's backdrop), the OBJ scan
    # (one sprite, entry 127, affine, OAM after a sprite, the budget's end
    # with and without H-blank free, OAM's last read), forced blank with
    # OBJ on, line 159's tail, a word's halves, a store
    'contmap': [0x800 | a << 16 | (s & 15) << 12 | (s >> 4) << 20 | k
                for s, a, k0, n in ((0x00, 1, 23, 16), (0x07, 1, 21, 11),
                                    (0x16, 1, 957, 7), (0x2C, 1, 965, 7),
                                    (0x01, 1, 963, 9), (0x0D, 1, 23, 12),
                                    (0x05, 1, 0, 8), (0x00, 0, 7, 8),
                                    (0x00, 0, 963, 7), (0x19, 0, 7, 8),
                                    (0x14, 0, 645, 9), (0x1C, 2, 63, 11),
                                    (0x1D, 2, 257, 7), (0x1E, 2, 13, 7),
                                    (0x1C, 3, 65, 9), (0x25, 2, 1229, 11),
                                    (0x26, 2, 957, 9), (0x03, 3, 961, 7),
                                    (0x04, 2, 7, 6), (0x40, 2, 0, 5),
                                    (0x00, 5, 11, 5), (0x00, 6, 13, 6))
                for k in range(k0, k0 + n)],
    # gbaedge CONTEND2's sixteen reads from IWRAM at a ten-cycle period, k
    # cycles into line 40: PRAM / VRAM / OAM, modes 0 and 2, H-blank free,
    # no OBJ layer
    # (Two cells are left out: the console once in nine answered them as if
    # nothing were drawn, the value every row reads with the renderer off.)
    'c2seq': [a << 16 | (s & 15) << 12 | (s >> 4) << 20 | k
              for s, a in ((0, 1), (1, 1), (3, 1), (2, 1), (0, 0), (2, 0), (0, 3))
              for k in range(100, 112)
              if (a << 16 | s << 12 | k) not in (0x10068, 0x12067)],
    # its code-in-VRAM rows: the stub in OBJ VRAM under 128 OBJs, under
    # forced blank with OBJ on, with the OBJ layer off, in BG VRAM under
    # four text BGs; and entered late (8, 0, 1, 2 loads)
    'c2code': ([a << 16 | (s & 15) << 12 | k
                for s, a in ((0, 0), (4, 0), (2, 0), (0, 1)) for k in range(100, 112)]
               + [a << 16 | k for a in (3, 4, 5, 6) for k in (100, 101)]),
    # code fetched from PRAM / VRAM / OAM under forced blank against IWRAM
    # and EWRAM, called from IWRAM and from EWRAM
    'vramexec': ([b | w << 4 for b in (0, 1, 3, 6, 7, 9) for w in (0, 2, 3)]
                 + [0x100 | b | w << 4 for b in (0, 1) for w in (0, 2)]
                 + [0x40, 0x50, 0x41, 0x51]),
    # a timer stopped across its overflow one cycle at a time (reload 0xFFF0),
    # then enabled again by a halfword or a word store, or not at all
    # (alyosha timer/timer_disable test 2, irq/BL_IRQ_2 cases c/d)
    'tmrffff': ([0xF000 | k for k in range(8, 13)] + [0x1F009, 0x1F00A, 0x1F00B]
                + [0x2F009, 0x2F00A]),
    # the interrupt an enable-at-0xFFFF raises, against a sled: when the
    # handler runs (TM1) and what it reads (TM0); 0xFFFE controls
    'tmrffirq': [0x00, 0x01, 0x10, 0x30, 0x31, 0x70],
    # an H-blank DMA from EWRAM into OAM running into the next line: 140 and
    # 64 halfwords with sprites on/off, the row's OAM pattern, into IWRAM,
    # and the no-DMA control (alyosha Interactions/Halt_DMA_IRQ_Read_OAM)
    'hdmaoam': [0x808C, 0x008C, 0x108C, 0x308C, 0x408C, 0x0001, 0x1001, 0x3001,
                0x8001, 0x3040, 0x0040],
}


def source(name):
    return os.path.join(payloadcmp.ROMS, 'payloads', name + '.s')


def in_emulators(name, args):
    rom = payloadcmp.build_wrapper(source(name), args)
    got = payloadcmp.in_emulators(rom, len(args), names=EMULATORS, frames=60 + 8 * len(args))
    return {n: [f'{w:08X}' for w in ws] for n, ws in got.items()}


def on_console(name, args, runs):
    from monitor import assemble
    import rig
    code = assemble(source(name), out_dir=payloadcmp.SCRATCH)
    return [c.text for c in rig.ask(code, args, runs=runs)]


def main(argv):
    flags = [a for a in argv[1:] if a.startswith('--')]
    words = [a for a in argv[1:] if not a.startswith('--')]
    runs = next((int(f.split('=')[1]) for f in flags if f.startswith('--runs=')), 3)
    table = json.load(open(TABLE_FILE)) if os.path.exists(TABLE_FILE) else {}

    if '--record' in flags:
        for name in words or list(TABLE):
            args = TABLE[name]
            table[name] = dict(zip((f'{a:#x}' for a in args), on_console(name, args, runs)))
            print(name, table[name], flush=True)
            json.dump(table, open(TABLE_FILE, 'w'), indent=1)
        return 0
    if '--check' in flags:
        import tables
        tables.check(tables.rows(only=words or list(table)))
        return 0

    name, args = words[0], [int(a, 0) for a in words[1:]] or [0]
    got = in_emulators(name, args)
    if '--emulators-only' not in flags:
        got['hardware'] = on_console(name, args, runs)
    names = list(got)
    print(f'{"arg":>6}  ' + ''.join(f'{n:<20}' for n in names))
    for i, a in enumerate(args):
        cells = [got[n][i] for n in names]
        print(f'{a:>#6x}  ' + ''.join(f'{c:<20}' for c in cells) + ('' if len(set(cells)) == 1 else '  <<<'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
