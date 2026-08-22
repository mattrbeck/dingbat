#!/usr/bin/env python3
"""Cross wilbertpol's `intr_2_mode0_timing_sprites*` ROMs against dingbat's own
mode-3 lengths, at CELL resolution.

Each of those ROMs is ~129 independent measurements -- an OAM list (1..10
objects at chosen X positions), a fixed SCX, and a nop sled whose length is
tuned so that mode 0 is reached on the FIRST STAT poll with `nopsA` nops and on
the second with `nopsA - 1` -- and the ROM stops at the first failing one and
prints its index in HEX. So a run says "the first cell that disagrees" and
nothing about the other 128.

This reads the whole table out of the ROM (the `ld hl,<params> / ld d,<nopsA> /
ld e,<nopsB> / call <runner>` shape is fixed and greppable) and crosses it
against an M3IN/M3LEN log from a `-d:gb_m3_len` build of the same ROM, keyed on
the object-X list. One `nops` step is 4 dots, so a cell's verdict is a 4-dot
BRACKET on mode 3 -- the offset between the two units is fitted once over the
whole table and then every cell is scored against it.

  nim c -d:test_harness -d:release -d:gb_m3_len --path:src \\
    -o:dt_m3len tests/dingbat_test.nim
  ./dt_m3len <rom> --mode screenshot --frames 140 --screenshot /dev/null \\
    --dmg --nosave 2>&1 | grep -E '^M3(IN|LEN)' > /tmp/m3.log
  python3 tools/gbppu/wpsprites.py <rom> /tmp/m3.log <scx>

Prints the fitted offset, the agreement count and one line per disagreeing cell
with the bracket it missed. This is what found `OBJ_TAIL_WALK_REFUND`: 85 of the
86 reachable cells were exact and the 86th was one dot out.

Note the log only covers the cells the ROM REACHED, so patch the first failing
cell's `nopsA` (or fix the emulator) and re-run to see the rest.
"""
import sys, re, collections

if len(sys.argv) < 4:
    sys.exit(__doc__)
rom = open(sys.argv[1], "rb").read()
log, SCX = sys.argv[2], sys.argv[3]

tests, i = [], 0x150
while i < 0x3F00:
    if (rom[i] == 0x21 and rom[i + 3] == 0x16 and rom[i + 5] == 0x1E and
            rom[i + 7] == 0xCD and rom[i + 10] == 0x18):
        p = rom[i + 1] | (rom[i + 2] << 8)
        cnt = rom[p]
        tests.append((len(tests), list(rom[p + 1:p + 1 + cnt]), rom[i + 4]))
        i += 11
    else:
        i += 1

cur, seen = None, {}
for line in open(log):
    if line.startswith("M3IN"):
        m = re.search(r"scx=(\d+) .*objx=(\S*)", line)
        cur = (m.group(1), m.group(2).rstrip(",")) if m else None
    elif line.startswith("M3LEN") and cur is not None and cur[0] == SCX:
        n = int(re.search(r"len=(\d+)", line).group(1))
        seen.setdefault(cur[1], collections.Counter())[n] += 1

def key(xs): return ",".join(str(x) for x in xs)
def length(xs):
    c = seen.get(key(xs))
    return None if c is None else max(c, key=lambda z: c[z])

best = None
for off in range(-64, 64):
    ok = tot = 0
    for _, xs, nops in tests:
        n = length(xs)
        if n is None: continue
        tot += 1
        if (n + off) // 4 == nops: ok += 1
    if tot and (best is None or ok > best[1]): best = (off, ok, tot)
if best is None: sys.exit("no cells in common -- wrong scx?")
off, ok, tot = best
print("fitted offset %d dots  ---  %d/%d cells agree\n" % (off, ok, tot))
for idx, xs, nops in tests:
    n = length(xs)
    if n is None or (n + off) // 4 == nops: continue
    print("#%-3d($%02X) x=%-46s hw_nops=%d  len=%d (bracket %d..%d)" %
          (idx, idx, key(xs)[:46], nops, n, nops * 4 - off, nops * 4 - off + 3))
