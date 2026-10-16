"""Checkpoint classification: how different are two emulators' screens at
the same script checkpoint, and does the difference matter?

Verdicts, least to most severe:
  IDENTICAL   same 15-bit framebuffer
  SLIP        the same frame appears within a few frames of the checkpoint
              on the other side (hash window match); offset reported
  MINOR       nearly the same picture (>=98% pixels, or tiny mean error):
              a palette-fade step, a blinking cursor, one animated sprite
  DIFFERENT   same screen layout (block structure + on-screen text agree)
              but visible content differs: worth a look
  MAJOR       a different screen: blank vs content, other text, crash
  FAILED      the script could not reach this checkpoint at all

A screen drawn as fields that take turns every frame (A B A B: a line-drop
table, sprite flicker) is judged by its fields, not by the one that lands on
the checkpoint frame: see field_run and _judge_fields.
"""
import difflib
import math

import img
import screen

ORDER = ['IDENTICAL', 'SLIP', 'MINOR', 'DIFFERENT', 'MAJOR', 'FAILED']

# A window that repeats every n <= MAX_FIELDS frames, for FIELD_CYCLES whole
# cycles on each side of the checkpoint frame, is a screen of n fields
MAX_FIELDS = 4
FIELD_CYCLES = 3


def worst(verdicts):
    return max(verdicts, key=ORDER.index) if verdicts else 'IDENTICAL'


def _words(text):
    return {w for w in screen.normalize(text).replace('|', ' ').split() if len(w) >= 3}


def field_run(hashes, center):
    """(n, lo, hi) for the smallest n <= MAX_FIELDS such that the frames
    lo..hi of the window (inclusive, around `center`) repeat every n frames,
    with FIELD_CYCLES whole cycles on each side of the centre; None when the
    window does not settle like that. n = 1 is a still screen."""
    if not hashes or not 0 <= center < len(hashes):
        return None
    for n in range(1, MAX_FIELDS + 1):
        lo = center
        while lo > 0 and lo - 1 + n < len(hashes) and hashes[lo - 1] == hashes[lo - 1 + n]:
            lo -= 1
        hi = center            # hashes[k] == hashes[k + n] for lo <= k < hi
        while hi + n < len(hashes) and hashes[hi] == hashes[hi + n]:
            hi += 1
        if hi > center and center - lo >= FIELD_CYCLES * n and hi + n - 1 - center >= FIELD_CYCLES * n:
            return n, lo, hi + n - 1
    return None


def _field_picture(c, h):
    """The shot of field `h` of checkpoint `c`: the checkpoint's own, or one
    the runner kept of the frames after it (runner.Executor.checkpoint)."""
    if h == c['hash']:
        return c.get('ppm')
    return (c.get('fields') or {}).get(h)


def _judge_fields(a, b):
    """A verdict for two checkpoints on a screen of fields, or None when
    either side is not one. {'verdict': None, 'fields': n} when the fields
    cannot all be judged: classify then judges the checkpoint frames as
    before and says so.

    Which field lands on the checkpoint frame is a phase that can hang on a
    few hundred cycles anywhere before it (Phantasy Star Collection's field
    flag starts a V-blank later after a VRAM fill under contention,
    docs/playtest-bugs.md §62), so the sides are compared by their whole
    field cycles, lined up at every rotation:

      - every field the same picture at some rotation: IDENTICAL, with the
        rotation as `field_phase` (b shows a's centre field that many frames
        later), a note and not a slip;
      - otherwise each field pair that differs is judged by its pixels, and
        the rotation whose worst pair is mildest is the verdict. A pair with
        no picture of one of its fields (a run that kept none) cannot be
        judged, nor can a rotation that needs it.

    The cycles must begin and end at the same moment on both sides: a
    stretch of fields that starts at another frame is the screen changing
    at another time, a slip the window match measures."""
    ha, hb = a.get('hashes'), b.get('hashes')
    ra = field_run(ha, a.get('center', -1))
    rb = field_run(hb, b.get('center', -1))
    if not (ra and rb) or max(ra[0], rb[0]) < 2:
        return None

    def bounds(h, c, r):
        return (None if r[1] == 0 else r[1] - c, None if r[2] == len(h) - 1 else r[2] - c)
    if bounds(ha, a['center'], ra) != bounds(hb, b['center'], rb):
        return None
    fa = [ha[a['center'] + i] for i in range(ra[0])]
    fb = [hb[b['center'] + i] for i in range(rb[0])]
    n = ra[0] * rb[0] // math.gcd(ra[0], rb[0])
    text = a.get('compare') == 'text' or b.get('compare') == 'text'
    judged = {}

    def judge(x, y):
        if x == y:
            return {'verdict': 'IDENTICAL'}
        if (x, y) not in judged:
            pa, pb = _field_picture(a, x), _field_picture(b, y)
            # A text-judged screen is read by OCR, and only its checkpoint
            # frame is read. A field pair judged by pixels takes the
            # checkpoint frames' text: the fields are one screen's
            judged[(x, y)] = None if text or not (pa and pb) else \
                _judge_pixels(img.read_ppm(pa), img.read_ppm(pb), a.get('text', ''), b.get('text', ''))
        return judged[(x, y)]
    best = None
    for r in range(n):
        pairs = [judge(fa[i % len(fa)], fb[(i + r) % len(fb)]) for i in range(n)]
        if None in pairs:
            continue
        phase = r if r <= n // 2 else r - n
        rank = (max(ORDER.index(p['verdict']) for p in pairs),
                -sum(p['verdict'] == 'IDENTICAL' for p in pairs), abs(phase))
        if best is None or rank < best[0]:
            best = (rank, phase, pairs)
    if best is None:
        return {'verdict': None, 'fields': n, 'unjudged': 'read as text' if text else 'one with no picture'}
    _, phase, pairs = best
    out = dict(max(pairs, key=lambda p: ORDER.index(p['verdict'])))
    out['fields'] = n
    out['field_phase'] = phase
    if out['verdict'] == 'IDENTICAL':
        out['why'] = (f'{n} fields, the same pictures' +
                      (f', {abs(phase)} field{"s" if abs(phase) > 1 else ""} out of phase' if phase else ''))
    else:
        out['why'] = f"{n} fields judged field by field" + (f" ({out['why']})" if out.get('why') else '')
        out['field_verdicts'] = [p['verdict'] for p in pairs]
    return out


def _judge_pixels(fa, fb, text_a, text_b):
    """The pixel verdict for two pictures of the same moment."""
    m = img.compare(fa, fb)
    wa, wb = _words(text_a), _words(text_b)
    text_sim = len(wa & wb) / len(wa | wb) if (wa or wb) else 1.0
    m['text_similarity'] = round(text_sim, 2)
    if img.is_blank(fa) != img.is_blank(fb):
        m['verdict'] = 'MAJOR'
        m['why'] = 'one screen is blank'
    elif m['exact'] >= 0.98 or m['mae'] <= 0.1:
        m['verdict'] = 'MINOR'
    elif m['palette_only'] and m['mae'] <= 0.5:
        m['verdict'] = 'MINOR'
        m['why'] = 'palette step only'
    elif m['max_channel_delta'] <= 1:
        # Every differing pixel is one 5-bit step off: colour-effect rounding.
        # The reference emulators blend at finer than 5-bit precision, so they
        # cannot judge it; tests/roms/blendprobe.gba on hardware does, and
        # tests/ppucomposite_test.nim pins dingbat to that.
        m['verdict'] = 'MINOR'
        m['why'] = 'one 5-bit step (colour-effect rounding)'
    elif m['ncc'] >= 0.85 and text_sim >= 0.6:
        m['verdict'] = 'DIFFERENT'
    elif (m['ncc'] >= 0.98 and m['mae'] < 0.5) or (m['ncc'] >= 0.995 and m['mae'] < 1.0):
        # the layout matches almost exactly: OCR words churning over small
        # differences (tinted windows, a moving sprite) must not make it MAJOR
        m['verdict'] = 'DIFFERENT'
        m['why'] = 'same layout, OCR text differs'
    else:
        m['verdict'] = 'MAJOR'
    return m


def classify(a, b):
    """a, b: checkpoint dicts from runner.Executor.checkpoint (or None when
    the run never got there)."""
    if a is None or b is None:
        return {'verdict': 'FAILED'}
    if a.get('compare') == 'none' or b.get('compare') == 'none':
        if a['hash'] == b['hash']:
            return {'verdict': 'IDENTICAL'}
        return {'verdict': 'IDENTICAL', 'why': 'recorded, not judged'}
    # Before the centre frames: on a screen of fields the same centre frame
    # can hide another field that differs
    fields = _judge_fields(a, b)
    if fields and fields['verdict']:
        return fields
    m = _classify_frames(a, b)
    if fields:
        m = dict(m, fields=fields['fields'], fields_unjudged=True)
        m['why'] = (m['why'] + '; ' if m.get('why') else '') + \
            f"{fields['fields']} fields that differ, {fields['unjudged']}: judged on the checkpoint frame"
    return m


def _classify_frames(a, b):
    """The checkpoint frames and their windows."""
    if a['hash'] == b['hash']:
        return {'verdict': 'IDENTICAL'}
    # The match nearest the centre, not the first in the window: a screen
    # drawn as two alternating fields (A B A B: Phantasy Star Collection's
    # Master System line drop) matches at every other frame, and the first
    # match is the window's edge -- a one-field gap read as SLIP(-29)
    # (docs/playtest-bugs.md §62).
    offsets = [k - b['center'] for k, h in enumerate(b['hashes']) if h == a['hash']]
    if not offsets:
        offsets = [a['center'] - k for k, h in enumerate(a['hashes']) if h == b['hash']]
    if offsets:
        return {'verdict': 'SLIP', 'offset': min(offsets, key=abs)}
    text = a.get('compare') == 'text' or b.get('compare') == 'text'
    # Neither centre frame appears in the other's window, but the two windows
    # may still overlap: on a screen that animates every frame, both sides can
    # be rendering the same sequence a few frames apart without either centre
    # landing in the other's window. Rendering the same frame at all is a slip,
    # so compare the windows against each other and report the smallest shift.
    # The sign is the centre match's: negative when a shows a picture b
    # showed earlier (a behind). It was inverted here until 2026-10-14, so
    # a one-frame lag read +1 on this path and -1 on the one above
    # (docs/playtest-bugs.md §80, Gradius Galaxies).
    elsewhere = {h: k for k, h in enumerate(b['hashes'])}
    offsets = [(elsewhere[h] - b['center']) - (k - a['center'])
               for k, h in enumerate(a['hashes']) if h in elsewhere]
    if offsets and not text:
        return {'verdict': 'SLIP', 'offset': min(offsets, key=abs),
                'why': 'the windows share a frame; neither centre does'}
    # A text-judged screen is read by OCR unless one side's checkpoint
    # picture is in the other's window: the same picture frames apart is a
    # slip whatever OCR makes of it (The Sims' language screen, a scrolling
    # flag one frame behind, read MAJOR: docs/playtest-bugs.md §87). Windows
    # that merely share some other frame do not count here: a screen whose
    # blend differs at the centre shares its unblended frames (Aria of
    # Sorrow's Select Data, §72)
    if text:
        # Pictures no more than one 5-bit step apart are the colour-effect
        # rounding the pixel path calls MINOR below; OCR reads those steps
        # as other letters (Koro Koro Puzzle's title, §73; Gunstar's panels,
        # §89)
        if a.get('ppm') and b.get('ppm'):
            fa, fb = img.read_ppm(a['ppm']), img.read_ppm(b['ppm'])
            m = img.compare(fa, fb)
            if img.is_blank(fa) == img.is_blank(fb) and m['max_channel_delta'] <= 1:
                m['verdict'] = 'MINOR'
                m['why'] = 'one 5-bit step (colour-effect rounding)'
                return m
        # OCR reads the same screen with small errors and in varying line
        # order: fuzzy-match the sorted lines
        la = sorted(screen.normalize(t) for t in a['text'].split(' | '))
        lb = sorted(screen.normalize(t) for t in b['text'].split(' | '))
        sim = difflib.SequenceMatcher(None, '\n'.join(la), '\n'.join(lb)).ratio()
        ok = sim >= 0.8
        return {'verdict': 'MINOR' if ok else 'MAJOR', 'text_similarity': round(sim, 2),
                'why': 'compared by on-screen text only', 'palette_only': ok}
    return _judge_pixels(img.read_ppm(a['ppm']), img.read_ppm(b['ppm']), a['text'], b['text'])


def within_reference_spread(subject, ref, other):
    """True when every pixel where `subject` is more than one 5-bit step from
    `ref` is also a pixel where the two references disagree by more than a
    step (animation phase, scrolling), and that spread covers under half the
    screen: the rest is at most colour-effect rounding."""
    import numpy as np
    if not (subject and ref and other):
        return False
    qs, qr, qo = (img.to555(img.read_ppm(c['ppm'])) for c in (subject, ref, other))
    far = np.abs(qs - qr).max(axis=2) > 1
    spread = np.abs(qr - qo).max(axis=2) > 1
    # a moving sprite's edge lands a pixel apart between frames
    grown = spread.copy()
    grown[1:] |= spread[:-1]
    grown[:-1] |= spread[1:]
    grown[:, 1:] |= grown[:, :-1].copy()
    grown[:, :-1] |= grown[:, 1:].copy()
    return bool(far.any()) and not (far & ~grown).any() and spread.mean() < 0.5
