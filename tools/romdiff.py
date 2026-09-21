"""Is the test ROM we run the test its expected values were measured with?

    python3 tools/romdiff.py ours.elf ours.gba theirs.gba
    python3 tools/romdiff.py ours.elf ours.gba theirs.gba --show=dmaPrefetch,main

`ours.elf` has the symbols; `theirs.gba` is a binary somebody else published
(upstream's buildbot, a release asset) and has none. Each function in ours is
searched for in theirs, first byte for byte, then with the things a relink
moves wildcarded: branch-and-link targets, and literal-pool words that hold
an address (found from the pc-relative loads that use them, so a changed
CONSTANT still counts as a difference). What comes out is three lists:

  identical            same bytes
  same code, relinked  same instructions; only addresses moved
  NOT in theirs        different code -- read these

The third list is the point. A cycle-exact test times its own compiler
output, so a different toolchain shows up there -- and so does a different
HARNESS: the mGBA suite fork's tests were byte-identical to upstream's and the
row still could not pass, because `main` ran the suites back to back and a
handler one suite registered cost the next 11 cycles a V-blank
(docs/playtest-bugs.md section 23). Identical tests under a different main
are a different test. Do this before touching the emulator
(docs/cycle-hunt-method.md).

Neither ROM is ours to commit; point this at files outside the repo.
"""
import re
import subprocess
import sys

ROM_BASE = 0x08000000


def symbols(elf):
    """[(name, address, size, is_thumb, is_func)] for everything in the ROM."""
    out = subprocess.run(['arm-none-eabi-readelf', '-sW', elf], capture_output=True,
                         text=True, check=True).stdout
    found = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) < 8 or f[3] not in ('FUNC', 'OBJECT'):
            continue
        value, size = int(f[1], 16), int(f[2], 0)
        if size and ROM_BASE <= value < ROM_BASE + 0x02000000:
            found.setdefault((value & ~1, size), (f[7], value & ~1, size, bool(value & 1), f[3] == 'FUNC'))
    return sorted(found.values(), key=lambda s: s[1])


def looks_like_address(w):
    return (w >> 24) in (0x02, 0x03, 0x04, 0x08)


def wildcards(code, address, thumb):
    """Byte offsets in `code` a relink may change."""
    wild = set()
    half = lambda o: int.from_bytes(code[o:o + 2], 'little')
    word = lambda o: int.from_bytes(code[o:o + 4], 'little')
    literals = set()
    if thumb:
        o = 0
        while o + 2 <= len(code):
            h = half(o)
            if h & 0xF800 == 0x4800:                       # ldr rX, [pc, #imm8 * 4]
                literals.add((((address + o + 4) & ~2) + (h & 0xFF) * 4) - address)
            if h & 0xF800 == 0xF000 and o + 4 <= len(code) and half(o + 2) & 0xE800 == 0xE800:
                wild.update(range(o, o + 4))               # bl / blx pair
                o += 2
            o += 2
    else:
        for o in range(0, len(code) - 3, 4):
            w = word(o)
            if w & 0x0F7F0000 == 0x051F0000:               # ldr rX, [pc, #+-imm12]
                imm = w & 0xFFF
                literals.add(o + 8 + (imm if w & 0x00800000 else -imm))
            if w & 0x0E000000 == 0x0A000000:               # b / bl
                wild.update(range(o, o + 3))
    for o in literals:
        if 0 <= o and o + 4 <= len(code) and looks_like_address(word(o)):
            wild.update(range(o, o + 4))
    return wild


def find(code, wild, theirs):
    if not wild:
        at = theirs.find(code)
        return at, 'identical'
    at = theirs.find(code)
    if at >= 0:
        return at, 'identical'
    pattern = b''.join(b'.' if i in wild else re.escape(code[i:i + 1]) for i in range(len(code)))
    m = re.search(pattern, theirs, re.DOTALL)
    return (m.start(), 'relinked') if m else (-1, 'missing')


def nearest(code, wild, theirs):
    """For a function with no match: is most of it there? Anchor on any
    32-byte window of it and count what differs around the anchor."""
    best = None
    for start in range(0, max(1, len(code) - 32), 32):
        window = range(start, min(start + 32, len(code)))
        pattern = b''.join(b'.' if i in wild else re.escape(code[i:i + 1]) for i in window)
        m = re.search(pattern, theirs, re.DOTALL)
        if not m:
            continue
        base = m.start() - start
        if base < 0 or base + len(code) > len(theirs):
            continue
        diff = [i for i in range(len(code)) if i not in wild and code[i] != theirs[base + i]]
        if best is None or len(diff) < len(best[1]):
            best = (base, diff)
    return best


def main(argv):
    show = next((a.split('=')[1].split(',') for a in argv if a.startswith('--show=')), [])
    paths = [a for a in argv[1:] if not a.startswith('--')]
    if len(paths) != 3:
        print(__doc__)
        return 2
    elf, ours_path, theirs_path = paths
    ours, theirs = open(ours_path, 'rb').read(), open(theirs_path, 'rb').read()
    print(f'ours   {len(ours):>8} bytes\ntheirs {len(theirs):>8} bytes'
          + ('   (the same file)' if ours == theirs else ''))

    groups = {'identical': [], 'relinked': [], 'missing': []}
    for name, address, size, thumb, is_func in symbols(elf):
        code = ours[address - ROM_BASE:address - ROM_BASE + size]
        if len(code) < size:
            continue
        wild = wildcards(code, address, thumb) if is_func else set()
        at, verdict = find(code, wild, theirs)
        note = ''
        if verdict == 'missing' and is_func:
            near = nearest(code, wild, theirs)
            note = ('nothing like it there' if not near else
                    f'{len(near[1])} bytes differ, first at +{near[1][0]:#x}')
        groups[verdict].append((name, size, is_func, note))
        if name in show:
            where = f'{ROM_BASE + at:#x}' if at >= 0 else 'nowhere'
            print(f'\n{name}: {size} bytes at {address:#x} here, {where} there -- {verdict}')
            if verdict == 'relinked':
                for o in sorted(w for w in wild if w % 4 == 0 and w + 3 in wild):
                    a = int.from_bytes(code[o:o + 4], 'little')
                    b = int.from_bytes(theirs[at + o:at + o + 4], 'little')
                    if a != b:
                        print(f'    +{o:#06x}  {a:08X} here, {b:08X} there')

    for verdict, title in (('identical', 'identical'), ('relinked', 'same code, relinked'),
                           ('missing', 'NOT in theirs')):
        funcs = [g for g in groups[verdict] if g[2]]
        data = [g for g in groups[verdict] if not g[2]]
        print(f'\n{title}: {len(funcs)} functions, {len(data)} data objects')
        if verdict == 'missing':
            for name, size, is_func, note in sorted(groups[verdict], key=lambda g: -g[1]):
                print(f'    {name:<40} {size:>6} bytes  ' + (note if is_func else '(data)'))
    return 1 if groups['missing'] else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
