"""Ask the console the same question more than once, and say so when the
answers differ.

    from rig import ask
    cells = ask(code, [0, 1, 2], runs=3)          # one Cell per argument
    cells[0].text      '048303D5'  or  '048303D5 | 048403D5'
    cells[0].counts    {'048303D5': 3}

A number off the console is only as good as the link that carried it. The
monitor already reads back everything it sends (monitor.run_payload); this is
the other half: every cell is asked `runs` times in interleaved passes (so a
drift over minutes shows as disagreement, not as a trend down the table), and
a cell with more than one answer is kept as such -- it can never match an
emulator, which is the point. The one two-valued cell this rig ever produced
was the rig's own fault, and it was the counts that gave it away: ten runs,
one outlier, and the outlier was the neighbouring cell's answer.

`settle=N` keeps asking a disagreeing cell, up to N more times, so that the
counts say whether it is a rare glitch (9:1) or a real two-valued cell (5:5).
"""
import sys
import time


class Cell:
    def __init__(self):
        self.counts = {}

    def add(self, answer):
        self.counts[answer] = self.counts.get(answer, 0) + 1

    @property
    def stable(self):
        return len(self.counts) == 1

    @property
    def text(self):
        return ' | '.join(sorted(self.counts))

    def tally(self):
        return ', '.join(f'{a} x{n}' for a, n in sorted(self.counts.items()))


def _once(code, arg, tries=3):
    from monitor import Monitor
    for attempt in range(tries):           # the adapter drops a word now and then
        try:
            with Monitor() as m:
                m.ping()
                return m.run_payload(code, arg)
        except Exception:
            if attempt == tries - 1:
                raise
            time.sleep(1.5)


def ask(code, args, runs=3, show=None, settle=6, log=sys.stderr):
    """Run `code` once per argument, `runs` passes over the whole list.
    `show` turns the returned word into the cell's text (default: 8 hex
    digits)."""
    show = show or (lambda v: f'{v:08X}')
    cells = [Cell() for _ in args]
    for _ in range(runs):
        for cell, a in zip(cells, args):
            cell.add(show(_once(code, a)))
    for cell, a in zip(cells, args):
        extra = 0
        while not cell.stable and extra < settle:
            cell.add(show(_once(code, a)))
            extra += 1
        if not cell.stable and log:
            print(f'  rig: arg {a:#x} answered {cell.tally()}', file=log, flush=True)
    return cells
