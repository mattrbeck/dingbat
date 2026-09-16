"""Screen reading: OCR text (macOS Vision via bin/screenread) plus a guess at
which menu entry is selected.

Selection is inferred from pixels around each OCR line, two ways:
  - cursor: ink (non-background pixels) in a strip just left of the line
    that no other line in the same menu column has -- an arrow or hand;
  - highlight: the line's background colour differs from its column
    siblings' -- a highlighted box or inverted row.
Both are heuristics; `selected` is None when neither singles out one line.
"""
import json
import os
import subprocess
import threading
from collections import Counter

import numpy as np

import img

HERE = os.path.dirname(os.path.abspath(__file__))


class ScreenReader:
    def __init__(self):
        self.proc = None
        self.lock = threading.Lock()
        self.cache = {}

    def _start(self):
        self.proc = subprocess.Popen([os.path.join(HERE, 'bin', 'screenread'), '--serve'],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)

    def ocr(self, ppm_path, key=None):
        """OCR lines for a PPM. `key` (e.g. the frame hash) enables caching."""
        if key is not None and key in self.cache:
            return self.cache[key]
        with self.lock:
            if self.proc is None or self.proc.poll() is not None:
                self._start()
            self.proc.stdin.write(os.path.abspath(ppm_path) + '\n')
            self.proc.stdin.flush()
            out = json.loads(self.proc.stdout.readline())
        lines = out.get('lines', [])
        if key is not None:
            self.cache[key] = lines
        return lines

    def read(self, ppm_path, key=None):
        """{'lines': [...], 'text': joined, 'selected': text or None}"""
        lines = [dict(l) for l in self.ocr(ppm_path, key)]
        rgb = img.read_ppm(ppm_path)
        sel = guess_selected(rgb, lines)
        for i, l in enumerate(lines):
            l['selected'] = (i == sel)
        return {'lines': lines, 'text': ' | '.join(l['text'] for l in lines),
                'selected': lines[sel]['text'] if sel is not None else None}

    def close(self):
        if self.proc and self.proc.poll() is None:
            self.proc.stdin.close()
            self.proc.wait()


def normalize(s):
    return ' '.join(s.upper().replace('É', 'E').split())


def contains_text(lines, needle):
    n = normalize(needle)
    joined = normalize(' '.join(l['text'] for l in lines))
    return n in joined or any(n in normalize(l['text']) for l in lines)


def _bg_color(q, box):
    x, y, w, h = box
    region = q[max(0, y):y + h, max(0, x):x + w].reshape(-1, 3)
    if len(region) == 0:
        return None
    return Counter(map(tuple, region)).most_common(1)[0][0]


CURSOR_GLYPHS = '•▶►▸>›»→*'


def guess_selected(rgb, lines):
    # a cursor glyph OCR read as part of exactly one line
    glyphed = [i for i, l in enumerate(lines) if l['text'][:1] in CURSOR_GLYPHS and len(l['text']) > 1]
    if len(glyphed) == 1:
        return glyphed[0]
    if len(lines) < 2:
        return None
    q = img.to555(rgb)
    H, W = q.shape[:2]
    # group lines into menu columns by left edge
    columns = {}
    for i, l in enumerate(lines):
        x = l['box'][0]
        key = next((k for k in columns if abs(k - x) <= 12), x)
        columns.setdefault(key, []).append(i)
    candidates = []
    for members in columns.values():
        if len(members) < 2:
            continue
        # highlight: one member's background colour is the odd one out
        bgs = [_bg_color(q, lines[i]['box']) for i in members]
        counts = Counter(bgs)
        if len(counts) == 2 and None not in counts:
            odd = [i for i, b in zip(members, bgs) if counts[b] == 1]
            if len(odd) == 1:
                candidates.append(('highlight', odd[0]))
            elif len(members) == 2:
                # two entries, two backgrounds: no odd one out, so take the
                # brighter box (menus light the selected entry far more often
                # than they dim it)
                lum = [sum(b) for b in bgs]
                if lum[0] != lum[1]:
                    candidates.append(('highlight', members[lum.index(max(lum))]))
        # cursor: ink left of exactly one member
        inked = []
        for i, bg in zip(members, bgs):
            x, y, w, h = lines[i]['box']
            x0, x1 = max(0, x - 14), max(0, x - 1)
            y0, y1 = max(0, y), min(H, y + h)
            if x1 <= x0 or y1 <= y0 or bg is None:
                continue
            strip = q[y0:y1, x0:x1].reshape(-1, 3)
            ink = int(np.any(strip != np.array(bg, dtype=np.int16), axis=1).sum())
            inked.append((ink, i))
        hits = [i for ink, i in inked if ink >= 6]
        if len(hits) == 1 and len(inked) >= 2:
            candidates.append(('cursor', hits[0]))
    if len(candidates) == 1:
        return candidates[0][1]
    # prefer a cursor over a highlight when both fire in different columns
    cursors = [i for kind, i in candidates if kind == 'cursor']
    return cursors[0] if len(cursors) == 1 else None
