#!/usr/bin/env python3
"""Render web/og-image.png, the 1200 x 630 card link previews show (Messages,
chat apps, GitHub), from the logo and the wordmark, with headless Chrome.

Usage: og.py [--chrome PATH]

The card is flat Night (#0e0a16) with the bat at 8x; the text is the system
UI face, which is why this renders through a browser rather than writing
pixels like flap.py. index.html points og:image / twitter:image at it.
"""
import base64
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bat  # noqa: E402
import imgio  # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'


def page():
    still = bat.still()
    logo = base64.b64encode(imgio.svg(still, bat.PURPLE).encode()).decode()
    w, h = len(still[0]) * 8, len(still) * 8
    chips = ''.join(f'<span class="chip">{t}</span>' for t in ('GB', 'GBC', 'GBA', 'in your browser'))
    return f'''<!doctype html><html><head><meta charset="utf-8"><style>
html, body {{ margin: 0; width: 1200px; height: 630px; overflow: hidden; background: {bat.NIGHT_BG}; }}
body {{ display: flex; align-items: center; gap: 56px; padding: 0 80px; box-sizing: border-box;
       font-family: -apple-system, "SF Pro Display", system-ui, "Segoe UI", Roboto, sans-serif; }}
.art {{ width: 400px; display: flex; justify-content: center; }}
img {{ image-rendering: pixelated; display: block; }}
.word {{ font-size: 112px; font-weight: 800; letter-spacing: -2px; color: #efeaf8; }}
.tag {{ font-size: 30px; color: #a89cc4; margin-top: 14px; }}
.chips {{ display: flex; gap: 10px; margin-top: 24px; }}
.chip {{ font-size: 18px; font-weight: 700; padding: 6px 14px; border-radius: 999px;
         border: 2px solid #b79cff; color: #b79cff; }}
</style></head><body>
<div class="art"><img src="data:image/svg+xml;base64,{logo}" width="{w}" height="{h}" alt=""></div>
<div><div class="word">dingbat</div><div class="tag">a game boy &amp; game boy advance emulator</div>
<div class="chips">{chips}</div></div>
</body></html>
'''


def main():
    chrome = sys.argv[sys.argv.index('--chrome') + 1] if '--chrome' in sys.argv else CHROME
    out = os.path.join(ROOT, 'web', 'og-image.png')
    with tempfile.TemporaryDirectory() as d:
        html = os.path.join(d, 'og.html')
        open(html, 'w').write(page())
        subprocess.run([chrome, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
                        f'--user-data-dir={d}/profile', '--window-size=1200,630', f'--screenshot={out}', 'file://' + html],
                       check=True, capture_output=True)
    print('wrote', out)


if __name__ == '__main__':
    main()
