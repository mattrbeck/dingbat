"""The supporter's crown: a gold stamp that sits on the bat's head between the
ears, on the still (the logo) and on every frame of the flap, riding the
body's bob. flap.py writes the crowned assets from these."""
import bat

CROWN = '''
K...KK...K
YK.KYYK.KY
YYKYYYYKYY
YYYYYYYYYY
YRYYJJYYRY
OOOOOOOOOO
'''.strip('\n').split('\n')

# Gold, its shadow, a ruby and an amethyst; K comes from the bat's palette.
COLORS = dict(Y='#f2c14e', O='#b8862e', R='#ff5c8a', J='#a98ae6')

HEAD_X = 16          # the crown's left column on the still (42 wide): between the ears
PAD = 5              # rows added above every frame for the crown


def stamp(rows, x0, y0):
    g = [list(r) for r in rows]
    for dy, r in enumerate(CROWN):
        for dx, c in enumerate(r):
            y, x = y0 + dy, x0 + dx
            if c != '.' and 0 <= y < len(g) and 0 <= x < len(g[0]):
                g[y][x] = c
    return [''.join(r) for r in g]


def ear_top(rows, x0, x1):
    return min(y for y, r in enumerate(rows) if r[x0:x1].strip('.'))


def still():
    """The logo with the crown, PAD rows taller (the crown's top two rows sit
    above the ears)."""
    s = ['.' * len(bat.still()[0])] * PAD + bat.still()
    return stamp(s, HEAD_X, PAD + ear_top(bat.still(), 14, 28) - 2)


def frames(frs):
    """Flap frames (52 wide) with the crown, each PAD rows taller."""
    off = (len(frs[0][0]) - len(bat.still()[0])) // 2
    out = []
    for f in frs:
        top = ear_top(f, 19, 33)
        out.append(stamp(['.' * len(f[0])] * PAD + f, HEAD_X + off, PAD + top - 2))
    return out


def palette(base):
    return dict(base, **COLORS)
