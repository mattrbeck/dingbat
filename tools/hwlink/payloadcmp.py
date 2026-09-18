"""Run one payload on the real console and in the emulators, side by side.

    python3 payloadcmp.py ../../tests/roms/payloads/thumbmul.s
    python3 payloadcmp.py <payload.s> 0 4 0x14      # with arguments

A payload is ARM code entered with r0 = the argument, returning its answer in
r0 (see tools/hwlink/monitor.py). The console runs it through the resident
monitor; the emulators run the identical bytes through tests/roms/payloadrun.s,
a cartridge wrapper that copies the payload to the same address in IWRAM and
calls it the same way. So all three numbers come from the same code in the
same place, which is what makes a disagreement mean something.

Emulators only, when the console is busy or absent:

    python3 payloadcmp.py --emulators-only <payload.s>
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ROMS = os.path.join(REPO, 'tests', 'roms')
SCRATCH = os.path.join(HERE, '.payloadcmp')
RESULTS = 0x02000000
PAYLOAD_ADDRESS = 0x03000000


def _run(cmd):
    subprocess.run(cmd, check=True)


def build_wrapper(payload_source, args):
    """A cartridge ROM that runs the payload once per argument."""
    os.makedirs(SCRATCH, exist_ok=True)
    sys.path.insert(0, ROMS)
    import romfix
    blob = os.path.join(SCRATCH, 'payload.bin')
    _run(['arm-none-eabi-as', '-mcpu=arm7tdmi', '-o', f'{SCRATCH}/payload.o',
          payload_source])
    _run(['arm-none-eabi-ld', f'-Ttext={PAYLOAD_ADDRESS:#x}', '-o',
          f'{SCRATCH}/payload.elf', f'{SCRATCH}/payload.o'])
    _run(['arm-none-eabi-objcopy', '-O', 'binary', f'{SCRATCH}/payload.elf', blob])

    # the wrapper reads its argument list out of its own source, so write one
    source = open(os.path.join(ROMS, 'payloadrun.s')).read()
    table = '\n'.join(f'    .word {a:#x}' for a in args)
    source = source[:source.index('arg_count:')] + (
        f'arg_count:\n    .word {len(args)}\narg_table:\n{table}\n\n'
        f'    .align 2\npayload:\n    .incbin "payload.bin"\n'
        f'    .align 2\npayload_end:\n')
    open(f'{SCRATCH}/payloadrun.s', 'w').write(source)
    _run(['arm-none-eabi-as', '-mcpu=arm7tdmi', '-I', SCRATCH, '-o',
          f'{SCRATCH}/wrapper.o', f'{SCRATCH}/payloadrun.s'])
    _run(['arm-none-eabi-ld', '-Ttext=0x08000000', '-o', f'{SCRATCH}/wrapper.elf',
          f'{SCRATCH}/wrapper.o'])
    rom = os.path.join(SCRATCH, 'payloadrun.gba')
    _run(['arm-none-eabi-objcopy', '-O', 'binary', f'{SCRATCH}/wrapper.elf', rom])
    data = bytearray(open(rom, 'rb').read())
    while len(data) % 16:
        data.append(0)
    open(rom, 'wb').write(bytes(data))
    romfix.gba_logo(rom)
    return rom


def in_emulators(rom, count, names=('dingbat', 'mgba'), block=None, frames=8):
    sys.path.insert(0, os.path.join(REPO, 'tools', 'playtest'))
    import emu as emulib
    address, count = block if block else (RESULTS, count)
    out = {}
    for name in names:
        e = emulib.Emulator(name, rom, os.path.join(SCRATCH, 'run', name))
        e.run(frames)
        raw = e.cmd(f'peek {address:08X} {count * 4}').strip()
        out[name] = [int.from_bytes(bytes.fromhex(raw[i * 8:i * 8 + 8]), 'little')
                     for i in range(count)]
        e.kill()
    return out


def on_hardware(payload_source, args, block=None):
    sys.path.insert(0, HERE)
    from monitor import Monitor, assemble
    code = assemble(payload_source, out_dir=SCRATCH)
    with Monitor() as m:
        m.ping()
        answers = [m.run_payload(code, a) for a in args]
        # a payload that answers with a block of memory rather than one word
        return [int(w, 16) for w in m.read_mem(*block)] if block else answers


def main(argv):
    emulators_only = '--emulators-only' in argv
    argv = [a for a in argv if a != '--emulators-only']
    block, frames = None, 8
    for a in list(argv):
        if a.startswith('--frames='):          # a long payload needs more
            frames = int(a.split('=')[1], 0)
            argv.remove(a)
    for a in list(argv):
        if a.startswith('--block='):           # --block=0x02008000:8, in words
            address, _, count = a.split('=')[1].partition(':')
            block = (int(address, 0), int(count or 1, 0))
            argv.remove(a)
    source = argv[1]
    args = [int(a, 0) for a in argv[2:]] or [0]

    rom = build_wrapper(source, args)
    results = in_emulators(rom, len(args), block=block, frames=frames)
    if not emulators_only:
        try:
            results['hardware'] = on_hardware(source, args, block=block)
        except Exception as e:
            print(f'(no hardware reading: {e})')

    names = [n for n in ('hardware', 'dingbat', 'mgba') if n in results]
    if block:
        return show_block(results, names, block)
    print(f'{"argument":>12}' + ''.join(f'{n:>12}' for n in names) + '   disagree')
    for i, a in enumerate(args):
        row = [results[n][i] for n in names]
        mark = '  <<<' if len(set(row)) > 1 else ''
        print(f'{a:#12x}' + ''.join(f'{v:12}' for v in row) + mark)
    return 0


def show_block(results, names, block):
    """A probe page's block of memory, one row of bytes per emulator, and
    which byte offsets disagree -- the rows are what the probe documents."""
    address, count = block
    data = {n: b''.join(w.to_bytes(4, 'little') for w in results[n]) for n in names}
    for n in names:
        print(f'{n:>10}  ' + ' '.join(f'{b:02X}' for b in data[n]))
    if len(names) > 1:
        odd = [k for k in range(count * 4)
               if len({data[n][k] for n in names}) > 1]
        print(f'{"disagree":>10}  ' + ' '.join(
            ' ^' if k in odd else '  ' for k in range(count * 4)))
        print(f'\n{len(odd)} of {count * 4} bytes disagree'
              + (f': offsets {odd}' if odd else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
