"""alyfifo.py OUTDIR -- cartridge variants of alyosha fifo_dma/fifo.gba that
print the timer reads a console takes, for a flashcart run.

alyosha-tas/gba-tests fifo_dma/fifo.gba (the 2023-09-01 upload; MIT) reads TM1
twice in its tests 2 and 4 and once in test 3 (FIFO A on TM0 at period 32,
DMA1 refilling it from the cartridge at 0x08000150, WAITCNT 0, code in the
cartridge), but draws only "Failed test 002/003" for tests 2 and 3, and test 2's
second compare is broken in the binary (`ldr r7, [r5]` overwrites the read and
the `bne` reuses the first compare's flags). Each variant here forces one
check's failure branch and makes it print the low byte of that read, so the
screen says what the console read: "Failed test NNN", NNN = the byte in
decimal. Nothing else changes: the branches of the earlier tests become NOPs
(an untaken branch and a NOP cost the same), the reads come before any patch.

    fifo_t2a  test 2, first read    ROM expects 0x68 (104)
    fifo_t2b  test 2, second read   upload 0x98 (152), later source 0x8B (139)
    fifo_t3   test 3, its read      0x68 (104)
    fifo_t4a  test 4, first read    0x68 (104)
    fifo_t4b  test 4, second read   0xA5 (165)

dingbat's prediction for each is printed when the variants are written (it
runs them in ./dingbat_test, so that build must be current).

The source the ROM is patched from is the runner's cached download
(tests/dingbat_test_runner.nim AlyoshaRev); pass --rom to use another copy.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CACHE = os.environ.get('DINGBAT_ROM_CACHE', '/tmp/dingbat-test-roms')
ROM = os.path.join(CACHE, 'alyosha-gba-tests-66f5f1d',
                   'gba-tests-66f5f1d60cd7030b600606886c76f5c821ecaf9d',
                   'fifo_dma', 'fifo.gba')

NOP = 0xE1A00000


def branch(at, to):
    """ARM `b to` placed at `at` (ROM offsets)."""
    return 0xEA000000 | (((to - at - 8) >> 2) & 0xFFFFFF)


def and_r12_lowbyte(reg):
    """and r12, <reg>, #0xFF"""
    return 0xE200C0FF | reg << 16


PASS_T2 = {0x220: NOP, 0x230: NOP}                 # test 2's two bne
PASS_T3 = {0x310: NOP}                             # test 3's bne
PRINT_R0_F002A = {0x24C: and_r12_lowbyte(0), 0x250: 0xE3A00000, 0x254: 0xE5830084}
PRINT_R7_F002B = {0x25C: and_r12_lowbyte(7), 0x260: 0xE3A00000, 0x264: 0xE5830084}
PRINT_R0_F003 = {0x328: and_r12_lowbyte(0), 0x32C: 0xE3A00000, 0x330: 0xE5830084}

VARIANTS = {
    'fifo_t2a': {0x220: branch(0x220, 0x24C), **PRINT_R0_F002A},
    'fifo_t2b': {0x220: branch(0x220, 0x25C), **PRINT_R7_F002B},
    'fifo_t3': {**PASS_T2, 0x310: branch(0x310, 0x328), **PRINT_R0_F003},
    'fifo_t4a': {**PASS_T2, **PASS_T3, 0x42C: branch(0x42C, 0x46C)},   # f004a prints r0
    'fifo_t4b': {**PASS_T2, **PASS_T3, 0x42C: NOP,
                 0x440: branch(0x440, 0x488)},                       # f004b prints r7
}

# What each patched word must hold in the upload, so a different binary is
# refused rather than patched blind.
EXPECT = {0x220: 0x1A000009, 0x230: 0x1A000009, 0x310: 0x1A000004,
          0x24C: 0xE3A00000, 0x250: 0xE5830084, 0x254: 0xE3A0C002,
          0x25C: 0xE3A00000, 0x260: 0xE5830084, 0x264: 0xE3A0C002,
          0x328: 0xE3A00000, 0x32C: 0xE5830084, 0x330: 0xE3A0C003,
          0x42C: 0x1A00000E, 0x440: 0x1A000010}


def word(data, off):
    return int.from_bytes(data[off:off + 4], 'little')


def build(rom, outdir):
    data = open(rom, 'rb').read()
    for off, want in EXPECT.items():
        if word(data, off) != want:
            sys.exit(f'{rom}: word at {off:#x} is {word(data, off):#010x}, not {want:#010x}')
    os.makedirs(outdir, exist_ok=True)
    out = []
    for name, patch in VARIANTS.items():
        d = bytearray(data)
        for off, w in patch.items():
            d[off:off + 4] = w.to_bytes(4, 'little')
        path = os.path.join(outdir, name + '.gba')
        open(path, 'wb').write(bytes(d))
        out.append(path)
    return out


def predict(path):
    """What dingbat draws: the r12 the ROM evaluates (dingbat_test's jsmolka
    mode reads it the way the framework prints it)."""
    r = subprocess.run([os.path.join(REPO, 'dingbat_test'), path, '--mode=jsmolka',
                        '--timeout=600'], capture_output=True, text=True)
    lines = r.stdout.strip().splitlines()
    return lines[-1] if lines else r.stderr.strip()


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--rom=')]
    rom = next((a.split('=', 1)[1] for a in sys.argv[1:] if a.startswith('--rom=')), ROM)
    if not args:
        sys.exit(__doc__)
    for p in build(rom, args[0]):
        print(f'{p}: dingbat {predict(p)}')
