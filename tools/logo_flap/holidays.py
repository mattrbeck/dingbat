#!/usr/bin/env python3
"""Holiday Night Flyers: the logo's flap (bat.py) in a seasonal palette, with
pixel props riding the body's bob. Ideas for later, not used by the app yet.

Usage: holidays.py OUTDIR

  OUTDIR/<name>.gif    the wingbeat at 4x on the holiday's ground, 40 ms a frame
  OUTDIR/<name>.png    the still (frame 0) at 4x on the same ground

Props are ASCII stamps in flap-box coordinates (frame 0); 'over' props draw on
top of everything, 'under' ones over the wings but not the body (a collar
behind the head). The box gains PAD rows of headroom for hats.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bat  # noqa: E402
import imgio  # noqa: E402

PAD = 6
BODY_X = (19, 32)   # the body's columns in the flap box: 'under' props never cover it


def lines(s):
    return s.strip('\n').split('\n')


def stamp(fr, art, x0, y0, mode='over'):
    g = [list(r) for r in fr]
    for dy, r in enumerate(art):
        for dx, c in enumerate(r):
            x, y = x0 + dx, y0 + dy
            if c == '.' or not (0 <= y < len(g) and 0 <= x < len(g[0])):
                continue
            if mode == 'under' and BODY_X[0] <= x <= BODY_X[1] and g[y][x] not in '.WwHabcdefgh':
                continue
            g[y][x] = c
    return [''.join(r) for r in g]


def mirror_stamp(art):
    return [r[::-1] for r in art]


WITCH = lines('''
.........KK...
........KPK...
.......KPPK...
......KPPPK...
.....KPPPPK...
....KPPPPPPK..
....KOOOOOOK..
..KKPPPPPPPPKK
.KPPPPPPPPPPPPK
..KKKKKKKKKKKK.
''')
SANTA = lines('''
....KKKKK.....
...KRRRRRK.KK.
..KRRRRRRRKTTK
.KRRRRRRRRKTTK
.KTTTTTTTTTKK.
KTTTTTTTTTTK..
.KKKKKKKKKK...
''')
PARTY = lines('''
...KK...
..KYYK..
...KK...
..KPK...
..KTPK..
.KPTPK..
.KTPTPK.
KPTPTPTK
KKKKKKKK
''')
BEANIE = lines('''
....KKK.....
...KTTTK....
..KKKTKKK...
.KPPPPPPPK..
KPPPPPPPPPK.
KTPTPTPTPTK.
KKKKKKKKKKK.
''')
HEART = lines('''
.KK.KK.
KRRKRRK
KRTRRRK
KRRRRRK
.KRRRK.
..KRK..
...K...
''')
COIN = lines('''
.KKKKK.
KGGGGGK
KGYGYGK
KGGKGGK
KGYGYGK
KGGGGGK
.KKKKK.
''')
COLLAR_L = lines('''
K.....
KK....
KRK...
KRRK..
KRRRK.
KRRRRK
.KRRRK
..KRRK
...KKK
''')
SCARF = lines('''
KKKKKKKKKKKKKK
KPPPPPPPPPPPPK
KTTTTTTTTTTTTK
.KKKKKKKKPPK..
........KTTK..
........KPPK..
........KKKK..
''')

# name: (wing stripes, ground, palette, props [(art, x, y, mode)])
HOLIDAYS = {
    'witch': (0, '#2a1840', dict(K='#140b1e', B='#f28c28', W='#4b2a6b', w='#3a2052', H='#ffb35c', E='#ffe14d', C='#ffcf8a', F='#ffffff',
                                     P='#2b1a3d', O='#7fd35b'),
              [(WITCH, 19, -3, 'over')]),
    'vampire': (0, '#3a0d1a', dict(K='#07050a', B='#3a3446', W='#221d2b', w='#19151f', H='#5f566f', E='#ff3b4a', C='#7a3444', F='#ffffff',
                                       R='#c3122d'),
                [(COLLAR_L, 14, 7, 'under'), (mirror_stamp(COLLAR_L), 32, 7, 'under')]),
    'santa': (0, '#0f3b2a', dict(K='#1b1028', B='#7a4fc4', W='#4d2f8a', w='#3a2270', H='#a98ae6', E='#ffffff', C='#ff8fb1', F='#f1eee8',
                                     R='#e0253a', T='#ffffff'),
              [(SANTA, 20, 0, 'over')]),
    'lunar': (0, '#5a0f14', dict(K='#1f0608', B='#d7263d', W='#8c1424', w='#6a0f1b', H='#f2c14e', E='#fff3d6', C='#ffb3ba', F='#ffffff',
                                     G='#f2c14e', Y='#ffe9a8'),
              [(COIN, 22, 20, 'over')]),
    'valentine': (0, '#fff3f8', dict(K='#3a0f2a', B='#ff8fc8', W='#d1508f', w='#a83d72', H='#ffd1ea', E='#ffffff', C='#ff5c8a', F='#ffffff',
                                         R='#ff2d55', T='#ffc2d1'),
                  [(HEART, 22, -3, 'over')]),
    'pride': (6, '#17121f', dict(K='#120c1a', B='#7a4fc4', H='#2b1d3a', E='#ffffff', C='#ff8fb1', F='#f1eee8',
                                     a='#e40303', b='#ff8c00', c='#ffed00', d='#008026', e='#004dff', f='#750787'),
              []),
    'party': (0, '#f6efe2', dict(K='#0f2b2a', B='#3aa59b', W='#23766f', w='#1b5f59', H='#7fd3c8', E='#ffffff', C='#f2a0b4', F='#ffffff',
                                     P='#ff5c8a', T='#ffd23f', Y='#ffd23f'),
              [(PARTY, 22, -4, 'over')]),
    'snowy': (0, '#dfeefa', dict(K='#10243d', B='#7fb8e6', W='#3f7fbf', w='#336aa3', H='#d4ecff', E='#ffffff', C='#ff9fb8', F='#ffffff',
                                     P='#e0253a', T='#ffffff'),
              [(BEANIE, 20, 1, 'over'), (SCARF, 19, 16, 'over')]),
}


def frames(name):
    """The holiday's 16 frames as rows, PAD rows taller than the flap box."""
    stripes, _, _, props = HOLIDAYS[name]
    fr = bat.flap_frames(16, stripes)
    tops = [min(y for y, r in enumerate(f) if r[20:32].strip('.')) for f in fr]
    out = []
    for f, top in zip(fr, tops):
        f = ['.' * len(f[0])] * PAD + f
        for art, x, y, mode in props:
            f = stamp(f, art, x, y + PAD + top - tops[0], mode)
        out.append(f)
    return out


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, (_, ground, pal, _) in HOLIDAYS.items():
        fr = [[r.replace('.', 'g') for r in bat.scale(f, 4)] for f in frames(name)]
        pal = dict(pal, g=ground)
        imgio.gif(os.path.join(out, name + '.gif'), fr, pal, delay_cs=4)
        imgio.png(os.path.join(out, name + '.png'), fr[0], pal)
    print('wrote', len(HOLIDAYS), 'holiday bats to', out)


if __name__ == '__main__':
    main()
