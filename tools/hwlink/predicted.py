"""Answers written down before the console gave them, and how they fared.

    python3 r0table.py --score [row ...]   # hit rate against r0-agb.json
    python3 r0table.py --drift [row ...]   # the emulators today against theirs

A probe's predictions are the point of designing it first: an emulator's
answer, or a named hypothesis's, set down in docs/playtest-bugs.md or the
payload's header before any console run. Once the row is recorded (`r0table.py
--record`), `--score` counts, per row and over all of them, how many of each
one's cells the console answered as predicted, and lists the cells still
unrecorded. Nothing here is ever filled from a console answer: a prediction
is added with the probe, dated, or not at all.

PREDICTIONS maps a row (an r0table.TABLE name) to
    'where'  the passage the predictions are copied from
    'date'   the day they were written, before the row's first console run
    'cart'   for a NEEDS_CART row, the carts the passage names
    'who'    {name: what it is}; an emulator name (EMULATOR_NAMES) is that
             emulator's answer as the passage gives it, not as it runs today
             (`--drift` compares the two); any other name is a hypothesis
    'cells'  {argument label (r0-agb.json's, f'{arg:#x}'): {who: pattern}}

A pattern is one or more alternatives separated by '|', each eight hex
digits where 'x' is any digit ('BEE3xxxx'), or MASK&VALUE (the answer AND
MASK is VALUE: '00040000&00000000'). A leading '!' turns it around: any
answer but those. A cell the console answered several ways ('A | B', rig.py)
is a hit only when every one of its answers fits.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))

EMULATOR_NAMES = ('dingbat', 'dingbat-bios', 'mgba', 'ref2')


def label(arg):
    return f'{arg:#x}'


def word(n):
    return f'{n:08X}'


# ---- the predictions, row by row ------------------------------------------

def _timergeo():
    args = [0x46701, 0x56701, 0x66701, 0x76701, 0x86701, 0x366401, 0x376401]
    dingbat = ['001204BD', '001204BE', '001204BF', '001304C0', '001304C1', '001304EF', '001404F0']
    mgba = ['001304BD', '001304BE', '001304BF', '001304C0', '001304C1', '001304EF', '001304F0']
    return {
        'where': 'docs/playtest-bugs.md §79 item 3', 'date': '2026-10-14',
        'who': {'dingbat': "the ÷64 edge at e = 7 on line 103, 16 cycles a line earlier",
                'mgba': 'mGBA'},
        'cells': {label(a): {'dingbat': d, 'mgba': m} for a, d, m in zip(args, dingbat, mgba)},
    }


def _wakehb():
    dingbat = {0x80: '017003EF', 0x90: '000003EB', 0xA0: '041903EC',
               0xA8: '03A803EC', 0xE0: '0B3603EC', 0xA2: '03EC0000'}
    mgba = {0x80: '01B403F3', 0x90: '000003F3', 0xA0: '042003F3',
            0xA8: '03B003F3', 0xE0: '0B3403F3', 0xA2: '03F40000'}
    cells = {label(a): {'dingbat': w, 'dingbat-bios': w, 'mgba': mgba[a]} for a, w in dingbat.items()}
    cells[label(0xA0)]['early15'] = '040A03DD'
    cells[label(0xA8)]['early15'] = '039903DD'
    cells[label(0x28)] = {'wakeirq+4': '095Bxxxx'}
    cells[label(0x60)] = {'wakeirq+4': '0AFExxxx'}
    return {
        'where': 'docs/playtest-bugs.md §79 item 2; tests/roms/payloads/wakehb.s', 'date': '2026-10-14',
        'who': {'dingbat': 'the H-blank interrupt rising with the flag at 1007 through the 4-cycle sync',
                'dingbat-bios': 'the same',
                'mgba': 'mGBA',
                'early15': "the running rows 15 cycles early (IRQDECOMP's irqlat-hblank residual as a law)",
                'wakeirq+4': "the V-count controls: wakeirq's recorded cells with the 4 added cycles"},
        'cells': cells,
    }


def _obusdma16():
    h1 = {0: 'BEE3BEE3', 4: '33333333', 8: 'BEE3BEE3', 12: '33333333',
          32: 'BEE3BEE3', 36: 'BEE3BEE3', 40: 'BEE3BEE3'}
    h2 = {0: 'BEE33333', 4: '22223333', 8: 'BEE3xxxx', 12: 'xxxx3333',
          32: 'BEE33333', 36: 'BEE33333', 40: 'BEE33333'}
    h3 = {0: 'BEE33333', 4: '33332222', 8: 'xxxxBEE3', 12: 'xxxx3333',
          32: '3333BEE3', 36: '3333BEE3', 40: 'BEE33333'}
    for h in (h1, h2, h3):                     # the EWRAM rows: "the same"
        for o in (0, 4, 8, 12):
            h[o + 16] = h[o]
        h[44] = 'DEADBEE3'                     # the 32-bit control, in every one
    ewram = (16, 20, 24, 28, 36)
    h4 = {o: (h1 if o in ewram else h2)[o] for o in h1}
    cells = {label(o): {'dingbat': h1[o], 'dingbat-bios': h1[o], 'mgba': h1[o],
                        'H1': h1[o], 'H2': h2[o], 'H3': h3[o], 'H4': h4[o]} for o in sorted(h1)}
    return {
        'where': 'tests/roms/payloads/obusdma16.s; docs/playtest-bugs.md §79 item 5', 'date': '2026-10-14',
        'who': {'dingbat': 'H1', 'dingbat-bios': 'H1', 'mgba': 'H1',
                'H1': 'a halfword on both lanes (dma.nim)',
                'H2': "each read drives its source address's lane",
                'H3': "each write drives its destination address's lane",
                'H4': 'the bus width decides: IWRAM rows as H2, EWRAM rows as H1'},
        'cells': cells,
    }


def fifolog_samples(path=None):
    """{(who, k, w, n): [the ten TM1 samples]} from fifolog-predicted.txt:
    sample 0 is s0, each next one the last plus its gap."""
    path = path or os.path.join(HERE, '..', '..', 'tests', 'roms', 'payloads', 'fifolog-predicted.txt')
    out, who = {}, None
    for line in open(path):
        t = line.split()
        if line.startswith('== '):
            who = t[1]
            continue
        if t and t[0] in ('toy', 'k3data'):
            who, t = t[0], t[1:]
        if not t or not t[0].startswith('k=') or 'gaps' not in t:
            continue
        # k=1 w=0 n= 0  s0= 32 extra0= 26  gaps ...
        text = ' '.join(t).replace('= ', '=')
        f = text.split()
        k, w, n, s0 = (int(f[i].split('=')[1]) for i in range(4))
        gaps = [int(g) for g in f[f.index('gaps') + 1:]]
        samples = [s0]
        for g in gaps:
            samples.append(samples[-1] + g)
        out[(who, k, w, n)] = samples
    return out


def fifolog_arg(k, w, n, i):
    return i << 24 | k << 16 | w << 8 | n


def _fifolog():
    # the file gives TM1 alone: bit 31 (the V-blank guard ran) is not predicted
    cells = {}
    for (who, k, w, n), samples in fifolog_samples().items():
        for i, s in enumerate(samples):
            cells.setdefault(label(fifolog_arg(k, w, n, i)), {})[who] = '7FFFFFFF&' + word(s & 0xFFFF)
    return {
        'where': 'tests/roms/payloads/fifolog-predicted.txt; docs/playtest-bugs.md §79 item 6',
        'date': '2026-10-14',
        'who': {'dingbat': 'dingbat on 2026-10-14',
                'mgba': 'mGBA',
                'toy': "the four-rule model fitting fifoffff's k = 1, 2, 4 cells",
                'k3data': "k = 3 as fifoffff's recorded timeline gives it (k = 3, w = 0 only)"},
        'cells': cells,
    }


S0AGE_H0 = '1 0 L F 7 7 7 3 3 3 L 3 3 3 1 1'.split()
S0AGE_C2 = '1 3 1 1 1 3 1 1 1 3 1 1 1 3 1 1'.split()


def _s0age_word(d):
    return 'FFFF00FF' if d == 'L' else f'xxxx000{d}'


def _s0age():
    cells = {}
    for m in (0, 2, 5, 7):
        for b in (0, 0x100, 0x200, 0x300):
            for k in range(16):
                h0 = _s0age_word(S0AGE_H0[k])
                # H1: past m = 0 the row is C2, or C3 (one L in four phases,
                # 3 at the other three; which phase is not said)
                h1 = h0 if m == 0 else '|'.join(dict.fromkeys(
                    [_s0age_word(S0AGE_C2[k]), _s0age_word('3'), _s0age_word('L')]))
                h2 = '!' + h0 if b & 0x100 and m >= 4 else h0
                h3 = '!' + h0 if b & 0x200 else h0
                cells[label(b | m << 4 | k)] = {
                    'dingbat': h0, 'dingbat-bios': h0, 'mgba': 'FFFF00FF',
                    'H0': h0, 'H1': h1, 'H2': h2, 'H3': h3}
    return {
        'where': 'tests/roms/payloads/s0age.s; docs/playtest-bugs.md §79 item 7', 'date': '2026-10-14',
        'who': {'dingbat': 'H0', 'dingbat-bios': 'H0', 'mgba': 'L everywhere (no shift-0 check)',
                'H0': 'the slow timing holds: every row 1 0 L F 7 7 7 3 3 3 L 3 3 3 1 1',
                'H1': 'it runs out by itself: m > 0 rows turn C2 or C3',
                'H2': "a note ending by length ends it: bit-8 rows with m >= 4 leave H0",
                'H3': 'an NR10 write ends it: bit-9 rows leave H0 at every m'},
        'cells': cells,
    }


def _psgrace():
    # "+12 (after ch2's note): lives ... dingbat over 256 phases 0/256"
    return {
        'where': 'docs/playtest-bugs.md §79 item 7 (the psgrace sweep)', 'date': '2026-10-14',
        'who': {'dingbat': '+12 (bit 18) never alive, at any of the 256 phases'},
        'cells': {label(c << 8 | d): {'dingbat': '00040000&00000000'}
                  for c in range(0, 128, 8) for d in range(16)},
    }


HDMARACE = {0: 'E150 E3A0 1AFF E1C6 002E E150', 1: 'E1D4 002B E150 E3A0 1AFF E1C6',
            2: 'E1C6 002B E150 E3A0 1AFF E1C6', 3: 'E3A0 1AFF E1C6 002D E150 E3A0',
            4: '002A E150 E3A0 1AFF E1C6 002F', 5: '002A E150 E3A0 1AFF E1C6 002F',
            6: '1AFF E1C6 002C E150 E3A0 1AFF'}


def _hdmarace():
    table = {d: row.split() for d, row in HDMARACE.items()}
    cells = {}
    for d, row in table.items():
        for k, hw in zip(range(2, 8), row):
            column = sorted({table[e][k - 2] for e in table})
            cells[label(d << 12 | 0x100 | k)] = {
                'dingbat': '0008' + hw, 'dingbat-bios': '0008' + hw,
                'mgba': 'xxxx0000|xxxx0001|xxxxFFFC',
                'same-wake': '0008' + hw,
                'rotated': '|'.join('0008' + c for c in column)}
    return {
        'where': 'tests/roms/payloads/hdmarace.s; docs/playtest-bugs.md §79 item 1', 'date': '2026-10-14',
        'who': {'dingbat': "dingbat's d x k table", 'dingbat-bios': 'the same', 'mgba': 'mGBA',
                'same-wake': 'the console wakes on the core\'s cycle: unanimous cells, the table',
                'rotated': "the wake c cycles off: the table's rows rotated (a word of the cell's column)"},
        'cells': cells,
    }


def _hdmaobus():
    # docs/playtest-bugs.md, "a DMA burst that follows another reads the bus
    # the first one left" (ee23537d, 2026-10-02 10:47; recorded 13:59)
    x = {k: f'A5{0x11 * k:02X}' for k in range(8)}
    cells = {}
    for k in range(8):                               # writer first, sled
        cells[label(k)] = {'dingbat': 'xxxx' + x[k], 'dingbat-bios': 'xxxx' + x[k],
                           'mgba': 'xxxx' + x[k], 'predicted': 'xxxx' + x[k],
                           'before': 'xxxx46C0' if k < 2 else 'xxxx1AFF|xxxxE1C6'}
    for k in range(6):                               # writer first, halted
        cells[label(0x200 | k)] = {'dingbat': 'xxxx' + x[k], 'dingbat-bios': 'xxxx' + x[k],
                                   'mgba': 'xxxx' + x[k], 'predicted': 'xxxx' + x[k],
                                   'before': 'xxxx0000|xxxx0300'}
    for k in range(2):                               # reader first, sled
        cells[label(0x100 | k)] = {n: 'xxxx46C0' for n in
                                   ('dingbat', 'dingbat-bios', 'mgba', 'predicted', 'before')}
    for k in range(1, 6):                            # reader first, halted: "open"
        cells[label(0x300 | k)] = {'dingbat': 'xxxx0000', 'dingbat-bios': 'xxxx0300',
                                   'mgba': 'xxxx7F00', 'before': 'xxxx0000|xxxx0300',
                                   'previous-line': 'xxxx' + x[k - 1]}
    return {
        'where': 'docs/playtest-bugs.md, the hdmaobus probe table ("predicted for the SP")',
        'date': '2026-10-02',
        'who': {'dingbat': 'dingbat after DMA_BUS_BACK_TO_BACK (HLE)',
                'dingbat-bios': 'the same, under the BIOS',
                'mgba': 'mGBA',
                'predicted': 'the "predicted for the SP" column',
                'before': 'dingbat before the change',
                'previous-line': "the halted reader finds the writer's word from the line before"},
        'cells': cells,
    }


def _fiforeset():
    survive = [2, 5, 4, 3, 2, 5, 4, 3, 2]

    def ab(v):
        return f'xxxx{v:02X}{v:02X}'
    cells = {}
    for k in range(9):
        cells[label(k)] = {'dingbat': ab(2), 'dingbat-bios': ab(2), 'mgba': ab(survive[k]),
                           'ref2': ab(survive[k]), 'keeps-word': ab(survive[k])}
        cells[label(0x100 | k)] = {'dingbat': ab(2), 'dingbat-bios': ab(2), 'mgba': ab(18 - k),
                                   'ref2': ab(survive[k]), 'keeps-word': ab(2), 'fifomap': ab(2)}
    return {
        'where': 'tests/roms/payloads/fiforeset.s PROVENANCE; docs/playtest-bugs.md, '
                 '"Status before the console" (f8d9b730, 2026-10-02 11:26; recorded 13:59)',
        'date': '2026-10-02',
        'who': {'dingbat': 'the word dropped (as shipped)', 'dingbat-bios': 'the same',
                'mgba': 'the word kept for v = 0; v = 1 never empties the FIFO (18 - k)',
                'ref2': 'the word kept, both ways',
                'keeps-word': 'dingbat with FIFO_RESET_KEEPS_WORD',
                'fifomap': "v = 1: fifomap's master enable empties it, word and all"},
        'cells': cells,
    }


def _sramloop():
    args = [1, 2, 0x10, 0x40, 0x110, 0x140, 0x210, 0x240, 0x310, 0x340, 0x440]
    dingbat = [0x26, 0x42, 0x1CA, 0x70A, 0x262, 0x952, 0x16A, 0x58A, 0x202, 0x7D2, 0]
    held = [0x29, 0x46, 0x1DC, 0x74C] + dingbat[4:]
    mgba = [0x28, 0x47, 0x1F9, 0x7C9, 0x262, 0x952, 0x149, 0x509, 0x202, 0x7D2, 0]
    emptying = [0x2E, 0x50, 0x22C, 0x88C]
    cells = {}
    for i, a in enumerate(args):
        c = {'dingbat': word(dingbat[i]), 'dingbat-bios': word(dingbat[i]),
             'held': word(held[i]), 'mgba': word(mgba[i])}
        if i < len(emptying):
            c['emptying'] = word(emptying[i])
        cells[label(a)] = c
    return {
        'where': 'docs/playtest-bugs.md §84', 'date': '2026-10-14',
        'cart': 'Hamtaro - Rainbow Rescue (A84P)',
        'who': {'dingbat': 'the prefetcher reads through SRAM (28 a byte)', 'dingbat-bios': 'the same',
                'held': 'SRAM_HOLDS_GAMEPAK_BUS, the buffer kept (29 a byte)',
                'mgba': 'mGBA (31 a byte)',
                'emptying': 'the access also empties the buffer (34 a byte)'},
        'cells': cells,
    }


def _eesettle():
    # cell 3 is the cart's own last block (FFFFFFFF only when blank): no
    # prediction
    cells = {label(2): {'dingbat': '00000350', 'dingbat-bios': '00000350', 'mgba': '00000351',
                        'ref2': '00000350'}}
    for a in (0, 1):
        cells[label(a)] = {'dingbat': word(108362), 'dingbat-bios': word(108362),
                           'mgba': word(38), 'ref2': word(101392)}
    return {
        'where': 'docs/playtest-bugs.md §36, §68, §87, §89', 'date': '2026-10-02 (§36) to 10-14',
        'cart': 'a 64 Kbit EEPROM cart: Super Mario Advance 3, Car Battler Joe, '
                "The Sims - Bustin' Out, Mario Party Advance (each answers for its own chip)",
        'who': {'dingbat': "GBATEK's ca. 108368", 'dingbat-bios': 'the same', 'mgba': 'mGBA',
                'ref2': 'the second reference (§87)'},
        'cells': cells,
    }


def _eesettle4k():
    cells = {label(0x102): {'dingbat': '00000300', 'dingbat-bios': '00000300', 'mgba': '00000301'}}
    for a in (0x100, 0x101):
        cells[label(a)] = {'dingbat': word(108362), 'dingbat-bios': word(108362), 'mgba': word(114992)}
    return {
        'where': 'docs/playtest-bugs.md §40, §67, §69', 'date': '2026-10-02 (§40) to 10-14',
        'cart': 'a 4 Kbit EEPROM cart: Klonoa - Empire of Dreams (§40), Super Mario Advance '
                '(AMZE, §67), Starsky & Hutch (§69)',
        'who': {'dingbat': "GBATEK's ca. 108368", 'dingbat-bios': 'the same', 'mgba': 'mGBA'},
        'cells': cells,
    }


def _flashprog():
    # §64's table, in cycles; mGBA's busy times "after an erase" are given as
    # the alternative they are
    d = {0: 0x1B32, 4: 34, 0x104: 30, 1: 51, 0x101: 43, 0x201: 147, 0x301: 139,
         2: 51, 0x102: 43, 3: 45, 0x103: 37}
    mgba = {0: [0x1B32], 4: [34], 0x104: [30], 1: [51, 678], 0x101: [43, 673],
            0x201: [147, 679], 0x301: [139, 679], 2: [51], 0x102: [673], 3: [30046], 0x103: [30037]}
    cells = {}
    for a, v in d.items():
        cells[label(a)] = {'dingbat': word(v), 'mgba': '|'.join(word(m) for m in mgba[a]),
                           'ref2': word(0xD4BF if a == 0 else v)}
    return {
        'where': 'docs/playtest-bugs.md §64, §90', 'date': '2026-10-14',
        'cart': 'a FLASH cart: Mario vs. Donkey Kong (§64), The Urbz (§90); '
                'cells 2, 0x102, 3, 0x103 only with sector 15 blank',
        'who': {'dingbat': 'no busy state (storage/flash.nim)', 'mgba': 'mGBA',
                'ref2': 'the second reference (its SST routine)'},
        'cells': cells,
    }


PREDICTIONS = {name: build() for name, build in (
    ('timergeo', _timergeo), ('wakehb', _wakehb), ('obusdma16', _obusdma16),
    ('fifolog', _fifolog), ('s0age', _s0age), ('psgrace', _psgrace),
    ('hdmarace', _hdmarace), ('hdmaobus', _hdmaobus), ('fiforeset', _fiforeset),
    ('sramloop', _sramloop), ('eesettle', _eesettle), ('eesettle4k', _eesettle4k),
    ('flashprog', _flashprog))}


# ---- matching and scoring ---------------------------------------------------

def _fits_one(alt, w):
    if '&' in alt:
        mask, value = (int(p, 16) for p in alt.split('&'))
        return w & mask == value
    text = word(w)
    return len(alt) == 8 and all(a in ('x', 'X', t) for a, t in zip(alt.upper(), text))


def fits(pattern, w):
    """Does the word w fit the pattern?"""
    negate = pattern.startswith('!')
    hit = any(_fits_one(alt.strip(), w) for alt in pattern.lstrip('!').split('|'))
    return hit != negate


def valid(pattern):
    for alt in pattern.lstrip('!').split('|'):
        alt = alt.strip()
        if '&' in alt:
            parts = alt.split('&')
            if len(parts) != 2 or not all(len(p) == 8 for p in parts):
                return False
            try:
                [int(p, 16) for p in parts]
            except ValueError:
                return False
        elif len(alt) != 8 or any(c not in '0123456789ABCDEFabcdefxX' for c in alt):
            return False
    return True


def console_words(text):
    """r0-agb.json's cell text -> its words ('A | B' when it raced)."""
    return [int(t, 16) for t in text.split(' | ')]


def hit(pattern, text):
    return all(fits(pattern, w) for w in console_words(text))


def tally(table, only=None, predictions=None):
    """{row: {'recorded': [labels], 'unrecorded': [labels],
              'who': {name: (hits, scored, [missed labels])}}}"""
    predictions = predictions or PREDICTIONS
    out = {}
    for row, p in predictions.items():
        if only and row not in only:
            continue
        console = table.get(row, {})
        rec = [c for c in p['cells'] if c in console]
        who = {}
        for name in p['who']:
            scored = [c for c in rec if name in p['cells'][c]]
            missed = [c for c in scored if not hit(p['cells'][c][name], console[c])]
            who[name] = (len(scored) - len(missed), len(scored), missed)
        out[row] = {'recorded': rec, 'unrecorded': [c for c in p['cells'] if c not in console],
                    'who': who}
    return out


def _rate(h, n):
    return f'{h}/{n}' + (f' ({100 * h / n:.0f}%)' if n else '')


def _list(labels, limit=12):
    shown = ' '.join(labels[:limit])
    return shown + (f' ... ({len(labels) - limit} more)' if len(labels) > limit else '')


def score(table, only=None, predictions=None):
    """Print each row's hit rates and the cells not yet recorded, then each
    emulator's over every row (a hypothesis belongs to its row)."""
    predictions = predictions or PREDICTIONS
    t = tally(table, only, predictions)
    overall = {}
    for row, r in t.items():
        p = predictions[row]
        cart = f'; cart: {p["cart"]}' if 'cart' in p else ''
        print(f'{row}: {len(r["recorded"])}/{len(p["cells"])} cells recorded '
              f'(predicted {p["date"]}, {p["where"]}{cart})')
        if not r['recorded']:
            print('  predicted by: ' + ', '.join(
                n if n in EMULATOR_NAMES else f'{n} (hypothesis)' for n in r['who']))
        for name, (h, n, missed) in r['who'].items():
            if not r['recorded']:
                overall.setdefault(name if name in EMULATOR_NAMES else f'{row}:{name}', [0, 0])
                continue
            kind = '' if name in EMULATOR_NAMES else '  hypothesis'
            print(f'  {name:<14}{_rate(h, n):<16}{kind}'
                  + (f'  missed: {_list(missed, 8)}' if missed else ''))
            key = name if name in EMULATOR_NAMES else f'{row}:{name}'
            a = overall.setdefault(key, [0, 0])
            a[0] += h
            a[1] += n
        if r['unrecorded']:
            print(f'  unrecorded: {_list(r["unrecorded"])}')
    print('overall (scored cells only)')
    for key in sorted(overall, key=lambda k: (k not in EMULATOR_NAMES, k)):
        h, n = overall[key]
        if n or key in EMULATOR_NAMES:
            print(f'  {key:<24}{_rate(h, n)}')
    pending = sum(len(r['unrecorded']) for r in t.values())
    print(f'  {pending} predicted cells await the console')
    return t


def drift(only=None, predictions=None):
    """Run each predicted row in the emulators the predictions name and print
    where an emulator today answers other than its pre-registered word. The
    row runs whole, in TABLE order, as it is recorded (flashprog's erase
    carries from cell to cell). Returns 1 on any drift."""
    import r0table
    predictions = predictions or PREDICTIONS
    moved = 0
    for row, p in predictions.items():
        if only and row not in only:
            continue
        names = [n for n in p['who'] if n in EMULATOR_NAMES]
        args = r0table.TABLE[row]
        got = r0table.in_emulators(row, args, names=names)
        for n in names:
            cells = [(label(a), w) for a, w in zip(args, got[n]) if n in p['cells'].get(label(a), {})]
            off = [(c, w) for c, w in cells if not fits(p['cells'][c][n], int(w, 16))]
            print(f'{row:<11}{n:<14}{len(cells) - len(off)}/{len(cells)} as predicted')
            for c, w in off[:12]:
                print(f'    {c:<12} {w}  (predicted {p["cells"][c][n]})')
            if len(off) > 12:
                print(f'    ... {len(off) - 12} more')
            moved += len(off)
    return 1 if moved else 0
