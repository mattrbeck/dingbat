#!/usr/bin/env python3
"""Write every logo asset in the repo from bat.py: the Night Flyer still, its
flap, the favicons and the app icons.

Usage: flap.py [--preview DIR]

  web/logo.svg                      the bar and home logo (42 x 19; 1x and 2x)
  web/favicon.svg, favicon.ico      browser tabs: the 32 x 32 drawing; .ico adds 16 and 48
  web/favicon-96x96.png             the logo at 2x, transparent
  web/apple-touch-icon*.png         iOS home screen: the bat on the moon, on Night
  web/web-app-manifest-*.png        Android (maskable): the same, bat 3x / 9x inside the safe circle
  web/flap.png                      31 frames of 52 x 28: a full beat (0-15), then a
                                    settling beat at 45% swing (16-30)
  web/flap-dusk.png, FlapDusk       the dusk bat's beat (16 frames): the link screen's friend
  ios/.../AppIcon.icon               the iOS app icon (Icon Composer): bat on the cratered moon by day,
                                    on the moon disc at night, the bat alone in Clear and Tinted
  ios/.../Logo, LaunchLogo          the in-app logo and launch logo
  ios/.../Flap                      the opening's flap: the same 31-frame strip as web/flap.png
  docker/windows-cross/dingbat.ico  the Windows build's icon
  README/dingbat.png, dingbat_large.png, dingbat_flap.gif

Everything is pixel art at whole-number scales on flat colours. check.py
verifies the flap's frames.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bat  # noqa: E402
import imgio  # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
P, BG = bat.PURPLE, bat.NIGHT_BG
RES = os.path.join(ROOT, 'ios', 'Dingbat', 'Resources')
XC = os.path.join(RES, 'Assets.xcassets')


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


def moon_tile(n, k):
    """An n x n Night tile: the bat at k x over the moon. Web and Windows icons get one look
    whatever the system's appearance, so they take the dark icon's."""
    b, _, moon = bat.moon_layers(n, k)
    return bat.over(b, moon)


def in_safe_circle(rows):
    """A maskable icon's art must sit inside the centre circle of 40% radius."""
    n = len(rows)
    return all((x + 0.5 - n / 2) ** 2 + (y + 0.5 - n / 2) ** 2 <= (0.4 * n) ** 2
               for y, r in enumerate(rows) for x, c in enumerate(r) if c not in '.g')


def moon_maskable(n, k):
    b, _, moon = bat.moon_layers(n, k)
    assert in_safe_circle(b) and in_safe_circle(moon), (n, k)
    return bat.over(b, moon)


# iOS 26 lights each layer group as raised glass; its specular rim traces every pixel step in
# white, so it is off by day and night. The bat keeps it in Clear and Tinted, where the moon
# is hidden and the glass bat needs its edge.
APP_ICON = {
    "fill-specializations": [
        {"value": {"solid": "srgb:0.95294,0.89020,0.65098,1.00000"}},
        {"appearance": "dark", "value": {"solid": "srgb:0.05490,0.03922,0.08627,1.00000"}}],
    "groups": [
        {"layers": [{"image-name": "bat.png", "name": "bat"}],
         "shadow": {"kind": "neutral", "opacity": 0.5},
         "translucency": {"enabled": False, "value": 0.5},
         "specular-specializations": [{"value": False}, {"appearance": "tinted", "value": True}]},
        {"layers": [{"image-name-specializations": [{"value": "ground_light.png"},
                                                    {"appearance": "dark", "value": "ground_dark.png"}],
                     "name": "moon",
                     "hidden-specializations": [{"appearance": "tinted", "value": True}]}],
         "shadow": {"kind": "none", "opacity": 0},
         "translucency": {"enabled": False, "value": 0.5},
         "specular": False}],
    "supported-platforms": {"squares": "shared"}}


def app_icon(dst):
    """The Icon Composer document: the bat over one full-bleed ground per appearance."""
    os.makedirs(os.path.join(dst, 'Assets'), exist_ok=True)
    b, field, moon = bat.moon_layers(1024, 22)
    imgio.png(os.path.join(dst, 'Assets', 'bat.png'), b, bat.MOON_PAL)
    imgio.png(os.path.join(dst, 'Assets', 'ground_light.png'), field, bat.MOON_PAL)
    imgio.png(os.path.join(dst, 'Assets', 'ground_dark.png'), moon, bat.MOON_PAL)
    with open(os.path.join(dst, 'icon.json'), 'w') as f:
        json.dump(APP_ICON, f, indent=2)
        f.write('\n')


def main():
    still = bat.still()
    fav32, fav16 = bat.favicon32(), bat.FAVICON16

    # ---- web
    open(path('web', 'logo.svg'), 'w').write(imgio.svg(still, P))
    open(path('web', 'favicon.svg'), 'w').write(imgio.svg(fav32, P))
    imgio.ico(path('web', 'favicon.ico'), [imgio.png_bytes(fav16, P), imgio.png_bytes(fav32, P),
                                           imgio.png_bytes(bat.pad(still, 48, 48), P)])
    imgio.png(path('web', 'favicon-96x96.png'), bat.pad(bat.scale(still, 2), 96, 96), P)
    MP = bat.MOON_PAL
    imgio.png(path('web', 'apple-touch-icon.png'), moon_tile(180, 4), MP)
    imgio.png(path('web', 'apple-touch-icon-precomposed.png'), moon_tile(160, 3), MP)
    imgio.png(path('web', 'web-app-manifest-192x192.png'), moon_maskable(192, 3), MP)
    imgio.png(path('web', 'web-app-manifest-512x512.png'), moon_maskable(512, 9), MP)
    frames31 = flap31()
    imgio.png(path('web', 'flap.png'), strip(frames31), P)
    # the link screen's other player: the dusk bat, one wingbeat
    imgio.png(path('web', 'flap-dusk.png'), strip(frames31[:16]), bat.DUSK)

    # ---- iOS
    app_icon(os.path.join(RES, 'AppIcon.icon'))
    # one 1x image: the views scale it by whole numbers with .interpolation(.none)
    imgio.png(os.path.join(XC, 'Logo.imageset', 'logo.png'), still, P)
    # 3 points per art pixel at @3x (LaunchIntro.launchScale)
    imgio.png(os.path.join(XC, 'LaunchLogo.imageset', 'launch-logo@3x.png'), bat.scale(still, 9), P)
    imgio.png(os.path.join(XC, 'Flap.imageset', 'flap.png'), strip(frames31), P)
    os.makedirs(os.path.join(XC, 'FlapDusk.imageset'), exist_ok=True)
    imgio.png(os.path.join(XC, 'FlapDusk.imageset', 'flap-dusk.png'), strip(frames31[:16]), bat.DUSK)

    # ---- Windows: 16 / 32 / 48 pixel art and a 256 moon tile with rounded corners
    t256 = rounded(moon_tile(256, 5), 40)
    imgio.ico(path('docker', 'windows-cross', 'dingbat.ico'),
              [imgio.png_bytes(fav16, P), imgio.png_bytes(fav32, P), imgio.png_bytes(bat.pad(still, 48, 48), P),
               imgio.png_bytes(t256, MP)])

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
