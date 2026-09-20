"""Time single opcodes fetched from an EMPTY cartridge slot, three ways.

    python3 slotexec.py [--emulators-only] [--runs=N] [payload.s] [WAITCNT ...]

tests/roms/payloads/slotexec.s explains the trick: an empty slot answers a
nonsequential halfword read with addr >> 1 and a sequential one with 0xFFFF,
which is the Thumb BL suffix, so one chosen opcode can be executed from the
gamepak region and the float itself branches home. The console needs nothing
but the resident monitor. The emulators have no "empty slot", so this builds
them a cartridge image that reads the same way: payloadcmp's wrapper, padded
to 128 KiB with 0xFFFF, with A >> 1 planted at every address the payload's
table names. The generated image is scratch and is never committed.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import payloadcmp

DEFAULT = os.path.join(payloadcmp.ROMS, 'payloads', 'slotexec.s')
RESULTS = 0x02008000
ROM_SIZE = 0x20000


def table_of(source):
    """(address, comment) for every row of the payload's trial table."""
    rows = []
    for line in open(source).read().split('table:')[1].splitlines():
        m = re.match(r'\s*\.word\s+(0x0[89A-D][0-9A-Fa-f]{6}),.*?@\s*(.*)', line)
        if m:
            rows.append((int(m.group(1), 16), m.group(2).strip()))
    return rows


def plant(rom, rows):
    data = bytearray(open(rom, 'rb').read())
    wrapper = len(data)
    # --hang: fill with `b .` instead, so every trial hangs and the payload's
    # watchdog has to bring each one home -- the only way to test it safely
    fill = b'\xFE\xE7' if '--hang' in sys.argv else b'\xFF\xFF'
    data += fill * ((ROM_SIZE - len(data)) // 2)
    for address, _ in rows:
        off = address - 0x08000000
        assert wrapper <= off < ROM_SIZE - 8, hex(address)
        data[off:off + 2] = ((address >> 1) & 0xFFFF).to_bytes(2, 'little')
    open(rom, 'wb').write(bytes(data))


def halfwords(words, n):
    """(time, sled count, lr) per trial."""
    raw = b''.join(w.to_bytes(4, 'little') for w in words)
    return [tuple(int.from_bytes(raw[i * 8 + a:i * 8 + b], 'little')
                  for a, b in ((0, 2), (2, 4), (4, 8))) for i in range(n)]


def main(argv):
    emulators_only = '--emulators-only' in argv
    runs = 3
    rest = []
    for a in argv[1:]:
        if a.startswith('--runs='):
            runs = int(a.split('=')[1])
        elif not a.startswith('--'):
            rest.append(a)
    source = rest.pop(0) if rest and rest[0].endswith('.s') else DEFAULT
    waitcnts = [int(a, 0) for a in rest] or [0x0000]
    rows = table_of(source)
    n = len(rows) * 2
    words = n * 2

    for waitcnt in waitcnts:
        rom = payloadcmp.build_wrapper(source, [waitcnt])
        plant(rom, rows)
        got = {k: halfwords(v, n) for k, v in payloadcmp.in_emulators(
            rom, 0, block=(RESULTS, words), frames=20).items()}
        if not emulators_only:
            from monitor import Monitor, assemble
            code = assemble(source, out_dir=payloadcmp.SCRATCH)
            seen = []
            for _ in range(runs):
                with Monitor() as m:
                    m.ping()
                    m.run_payload(code, waitcnt)
                    seen.append(halfwords(m.read_mem(RESULTS, words), n))
            got['hardware'] = seen[0]
            stable = all(s == seen[0] for s in seen)
        names = [k for k in ('hardware', 'dingbat', 'mgba') if k in got]
        print(f'\nWAITCNT {waitcnt:#06x}' + ('' if emulators_only else
              f'   hardware: {runs} runs, ' + ('identical' if stable else 'VARYING')))
        print(f'{"":>3} ' + ''.join(f'{k:>14}' for k in names) + '   trial')
        for i, (address, note) in enumerate(rows):
            def plain(v):
                # a row that left by some other door is not a timing: show
                # how far short it landed and which slot held the suffix
                t, short, lr = v
                at = ((lr & ~1) - 4 - address) & 0xFFFFFFFF
                ok = short == 0 and at in (0, 0x102)   # 0x102: the taken branch
                return f'{t}' if ok else f'{t}/-{short}/+{at:X}'
            vals = [plain(got[k][i]) for k in names]
            twice = all(got[k][i] == got[k][i + len(rows)] for k in names)
            mark = ' <<<' if len(set(vals)) > 1 else ''
            if not emulators_only and not stable:
                spread = sorted({plain(r[j]) for r in seen for j in (i, i + len(rows))})
                if len(spread) > 1:
                    mark += f'  hardware saw {spread}'
            print(f'{i:>3} ' + ''.join(f'{v:>14}' for v in vals) + f'   {note}'
                  + mark + ('' if twice else '  (second pass differs)'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
