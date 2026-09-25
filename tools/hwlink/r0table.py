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

EMULATORS = ('dingbat', 'dingbat-bios', 'mgba')
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
    # an H-blank DMA whose bursts outlast the line (configuration << 8 | word):
    # bursts, last start and last unit from the first, burst 1's gap; one
    # channel of 0.5 to 3.5 lines, near the V-blank edge, about a line, and
    # with nothing else armed; the V-blank arming's first start; two
    # channels' burst counts. Not the configurations 23-30, whose second
    # channel starts two cycles late here (the payload's header)
    'hdmalag': ([c << 8 | w for c in list(range(0, 12)) + [15, 16, 17, 18, 19, 20, 31, 32, 33, 34]
                 for w in (1, 10, 11, 14)]
                + [8 << 8 | 2, 22 << 8 | 1, 22 << 8 | 11]
                + [c << 8 | w for c in (12, 13, 14) for w in (1, 6)]),
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
