#!/usr/bin/env python3
"""Compare two steptrace.nim traces (HLE against a BIOS image) call by call:
the steps' cycles, start times and accesses, ignoring the BIOS addresses
(the HLE's steps sit at its own). Reports per call whether every step
agrees, else the first step that does not, with context.

  stepcmp.py <hle.txt> <real.txt> [--ctx=N] [--calls=a-b] [--irqvals] [--nostack]

The values the IRQ vector pushes (r0-r3, r12 and lr of the interrupted
code, at the IRQ stack 0x03007F88-0x03007F9F) are left out of the comparison
unless --irqvals: the HLE's routines keep their own registers there.
--nostack leaves out the values stored to the System stack (0x03007D00-
0x03007EFF): the return addresses a routine pushes are its stub steps'.
"""
import re
import sys


entries = {}
IRQVALS = '--irqvals' in sys.argv
NOSTACK = '--nostack' in sys.argv


def load(path):
    """-> {call: [(kind cycles, start, accesses)]}; `entries` gets each
    call's routine address (the step after the dispatcher's bx) from a
    BIOS-image trace."""
    calls = {}
    cur = None
    prev_pc = 0
    n = -1
    t0 = 0
    for line in open(path):
        line = line.rstrip('\n')
        if line.startswith('CALL '):
            n = int(line.split()[1])
            cur = calls.setdefault(n, [])
            t0 = int(line.split('t=')[1].split()[0])
            continue
        if line.startswith('END '):
            cur.append(('END', str(int(line.split('t=')[1].split()[0]) - t0), ''))
            cur = None
            continue
        if cur is None or line.startswith('IRQREGS'):
            continue
        parts = line.split(' ', 4)
        pc = int(parts[0], 16)
        cyc = parts[2]
        t = str(int(parts[3][2:]) - t0)   # from the call's start
        acc = parts[4] if len(parts) > 4 else ''
        if not IRQVALS:
            acc = re.sub(r'(W4:03007F[89][0-9A-F])=[0-9A-F]{8}', r'\1=*', acc)
        if NOSTACK:
            acc = re.sub(r'(W4:03007[DE][0-9A-F]{2})=[0-9A-F]{8}', r'\1=*', acc)
        where = 'B' if pc < 0x4000 else parts[0]
        cur.append((where + parts[1] + ' ' + cyc, t, acc))
        if prev_pc == 0x16C and n not in entries:
            entries[n] = pc
        prev_pc = pc
    return calls


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    ctx = 4
    rng = None
    for a in sys.argv[1:]:
        if a.startswith('--ctx='):
            ctx = int(a[6:])
        if a.startswith('--calls='):
            lo, hi = a[8:].split('-')
            rng = (int(lo), int(hi))
    h = load(args[0])
    r = load(args[1])
    bad = 0
    for n in sorted(set(h) | set(r)):
        if rng and not (rng[0] <= n <= rng[1]):
            continue
        a, b = h.get(n, []), r.get(n, [])
        first = None
        for i in range(min(len(a), len(b))):
            if a[i] != b[i]:
                first = i
                break
        if first is None and len(a) != len(b):
            first = min(len(a), len(b))
        if first is None:
            print(f"call {n}: {len(a)} steps equal")
            continue
        bad += 1
        ent = f" (routine {entries[n]:04X})" if n in entries else ""
        print(f"call {n}{ent}: differs at step {first} of {len(a)}/{len(b)}")
        for i in range(max(0, first - ctx), min(max(len(a), len(b)), first + ctx + 1)):
            x = a[i] if i < len(a) else ('-', '', '')
            y = b[i] if i < len(b) else ('-', '', '')
            mark = '  ' if x == y else '>>'
            print(f"  {mark} {i:6d} hle  {x[0]:14s} t={x[1]:>10s} {x[2][:90]}")
            if x != y:
                print(f"            real {y[0]:14s} t={y[1]:>10s} {y[2][:90]}")
    print(f"calls differing: {bad}")


if __name__ == '__main__':
    main()
