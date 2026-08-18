#!/usr/bin/env python3
"""Compare two probe (f) staircases modulo one uniform column offset.

Argv is two whitespace-separated column lists, oracle first. Prints the offset
that lines them up over the bands both readings share, and whether every band
agrees at that offset. The reader loses a band at either end depending on where
the staircase falls off the screen, so only the overlap is scored.
"""
import sys


def parse(s):
    return [int(t) for t in s.split()]


def score(want, got):
    """Best (badcount, offset, deltas, nbands) over the shared bands."""
    n = min(len(want), len(got))
    deltas = [g - w for w, g in zip(want[:n], got[:n])]
    off = max(set(deltas), key=deltas.count)
    return (sum(1 for d in deltas if d != off), off, deltas, n)


def main():
    want, got = parse(sys.argv[1]), parse(sys.argv[2])
    if min(len(want), len(got)) < 4:
        print("shape ?  (too few bands: %d/%d)" % (len(want), len(got)))
        return
    # The reader drops a band at either end depending on where the staircase
    # falls off the screen, and it does not always drop the same one from both
    # frames -- so a lost leading band must not be read as a shape error. Try
    # the three plausible band alignments and keep the best.
    cands = [(score(want, got), 0),
             (score(want[1:], got), -1),
             (score(want, got[1:]), +1)]
    (bad, off, deltas, n), skew = min(cands, key=lambda c: (c[0][0], abs(c[1])))
    tag = "" if skew == 0 else "  [band skew %+d]" % skew
    if bad == 0:
        print("offset %+d  shape ok   (%d bands)%s" % (off, n, tag))
    else:
        print("offset %+d  shape BAD  %d/%d bands off  deltas %s" %
              (off, bad, n, " ".join("%+d" % d for d in deltas)))


main()
