#!/usr/bin/env python3
"""Write every logo asset in the repo from bat.py: the Night Flyer still, its
flap, the favicons and the app icons.

Usage: flap.py [--preview DIR]

  web/logo.svg                      the bar and home logo (42 x 19; 1x and 2x)
  web/favicon.svg, favicon.ico      browser tabs: the 32 x 32 drawing; .ico adds 16 and 48
  web/favicon-96x96.png             the logo at 2x, transparent
  web/apple-touch-icon*.png         iOS home screen: flat Night tile, bat 3x
  web/web-app-manifest-*.png        Android (maskable): bat 3x / 8x inside the safe circle
  web/flap.png                      31 frames of 52 x 28: a full beat (0-15), then a
                                    settling beat at 45% swing (16-30)
  web/flap-dusk.png, FlapDusk       the dusk bat's beat (16 frames): the link screen's friend
  ios/.../AppIcon, Logo, LaunchLogo the iOS app icon, in-app logo and launch logo
  ios/.../Flap                      the opening's flap: the same 31-frame strip as web/flap.png
  docker/windows-cross/dingbat.ico  the Windows build's icon
  README/dingbat.png, dingbat_large.png, dingbat_flap.gif

Everything is pixel art at whole-number scales on flat colours. check.py
verifies the flap's frames.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bat  # noqa: E402
import imgio  # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
P, BG = bat.PURPLE, bat.NIGHT_BG
XC = os.path.join(ROOT, 'ios', 'Dingbat', 'Resources', 'Assets.xcassets')


def path(*p):
    return os.path.join(ROOT, *p)


def strip(frames):
    return [''.join(f[y] for f in frames) for y in range(len(frames[0]))]


def flap31():
    """A full wingbeat, then a settling beat at 45% swing that comes to rest."""
    full = bat.flap_frames(16)
    saved = dict(bat.TUNE)
    for k in ('amp', 'fwd', 'cup', 'bend_down', 'bend_up'):
        bat.TUNE[k] = saved[k] * 0.45
    try:
        settle = bat.flap_frames(16)[1:]
    finally:
        bat.TUNE.update(saved)
    return full + settle


def rounded(rows, r):
    """Clear the corners of a square tile to a radius-r quarter circle."""
    n = len(rows)
    g = [list(row) for row in rows]
    for y in range(n):
        for x in range(n):
            cx = r - 0.5 if x < r else (n - r - 0.5 if x >= n - r else None)
            cy = r - 0.5 if y < r else (n - r - 0.5 if y >= n - r else None)
            if cx is not None and cy is not None and (x - cx) ** 2 + (y - cy) ** 2 > (r - 0.5) ** 2:
                g[y][x] = ' '
    return [''.join(row) for row in g]


def tile_rows(n, k):
    """An n x n Night tile with the logo at k x: '.' becomes the ground ('g')."""
    art = bat.pad(bat.scale(bat.still(), k), n, n)
    return [r.replace('.', 'g') for r in art]


def main():
    still = bat.still()
    fav32, fav16 = bat.favicon32(), bat.FAVICON16
    TP = dict(P, g=BG)

    # ---- web
    open(path('web', 'logo.svg'), 'w').write(imgio.svg(still, P))
    open(path('web', 'favicon.svg'), 'w').write(imgio.svg(fav32, P))
    imgio.ico(path('web', 'favicon.ico'), [imgio.png_bytes(fav16, P), imgio.png_bytes(fav32, P),
                                           imgio.png_bytes(bat.pad(still, 48, 48), P)])
    imgio.png(path('web', 'favicon-96x96.png'), bat.pad(bat.scale(still, 2), 96, 96), P)
    imgio.png(path('web', 'apple-touch-icon.png'), tile_rows(180, 3), TP)
    imgio.png(path('web', 'apple-touch-icon-precomposed.png'), tile_rows(160, 3), TP)
    imgio.png(path('web', 'web-app-manifest-192x192.png'), tile_rows(192, 3), TP)
    imgio.png(path('web', 'web-app-manifest-512x512.png'), tile_rows(512, 8), TP)
    frames31 = flap31()
    imgio.png(path('web', 'flap.png'), strip(frames31), P)
    # the link screen's other player: the dusk bat, one wingbeat
    imgio.png(path('web', 'flap-dusk.png'), strip(frames31[:16]), bat.DUSK)

    # ---- iOS
    imgio.png(os.path.join(XC, 'AppIcon.appiconset', 'icon-1024.png'), tile_rows(1024, 18), TP)
    # one 1x image: the views scale it by whole numbers with .interpolation(.none)
    imgio.png(os.path.join(XC, 'Logo.imageset', 'logo.png'), still, P)
    # 3 points per art pixel at @3x (LaunchIntro.launchScale)
    imgio.png(os.path.join(XC, 'LaunchLogo.imageset', 'launch-logo@3x.png'), bat.scale(still, 9), P)
    imgio.png(os.path.join(XC, 'Flap.imageset', 'flap.png'), strip(frames31), P)
    os.makedirs(os.path.join(XC, 'FlapDusk.imageset'), exist_ok=True)
    imgio.png(os.path.join(XC, 'FlapDusk.imageset', 'flap-dusk.png'), strip(frames31[:16]), bat.DUSK)

    # ---- Windows: 16 / 32 / 48 pixel art and a 256 Night tile with rounded corners
    t256 = rounded(tile_rows(256, 5), 40)
    imgio.ico(path('docker', 'windows-cross', 'dingbat.ico'),
              [imgio.png_bytes(fav16, P), imgio.png_bytes(fav32, P), imgio.png_bytes(bat.pad(still, 48, 48), P),
               imgio.png_bytes(t256, TP)])

    # ---- README
    imgio.png(path('README', 'dingbat.png'), still, P)
    imgio.png(path('README', 'dingbat_large.png'), bat.scale(still, 4), P)
    imgio.gif(path('README', 'dingbat_flap.gif'), [bat.scale(f, 4) for f in frames31[:16]], P, delay_cs=4)

    if '--preview' in sys.argv:
        out = sys.argv[sys.argv.index('--preview') + 1]
        os.makedirs(out, exist_ok=True)
        for i, f in enumerate(frames31):
            imgio.png(os.path.join(out, f'frame_{i:02d}.png'), bat.scale(f, 4), P, bg=BG)
    print('wrote the logo assets; still', len(still[0]), 'x', len(still), '; flap', len(frames31), 'frames')


if __name__ == '__main__':
    main()
