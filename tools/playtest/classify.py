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
"""
import difflib

import img
import screen

ORDER = ['IDENTICAL', 'SLIP', 'MINOR', 'DIFFERENT', 'MAJOR', 'FAILED']


def worst(verdicts):
    return max(verdicts, key=ORDER.index) if verdicts else 'IDENTICAL'


def _words(text):
    return {w for w in screen.normalize(text).replace('|', ' ').split() if len(w) >= 3}


def classify(a, b):
    """a, b: checkpoint dicts from runner.Executor.checkpoint (or None when
    the run never got there)."""
    if a is None or b is None:
        return {'verdict': 'FAILED'}
    if a['hash'] == b['hash']:
        return {'verdict': 'IDENTICAL'}
    if a.get('compare') == 'none' or b.get('compare') == 'none':
        return {'verdict': 'IDENTICAL', 'why': 'recorded, not judged'}
    if a.get('compare') == 'text' or b.get('compare') == 'text':
        # OCR reads the same screen with small errors and in varying line
        # order: fuzzy-match the sorted lines
        la = sorted(screen.normalize(t) for t in a['text'].split(' | '))
        lb = sorted(screen.normalize(t) for t in b['text'].split(' | '))
        sim = difflib.SequenceMatcher(None, '\n'.join(la), '\n'.join(lb)).ratio()
        ok = sim >= 0.8
        return {'verdict': 'MINOR' if ok else 'MAJOR', 'text_similarity': round(sim, 2),
                'why': 'compared by on-screen text only', 'palette_only': ok}
    for k, h in enumerate(b['hashes']):
        if h == a['hash']:
            return {'verdict': 'SLIP', 'offset': k - b['center']}
    for k, h in enumerate(a['hashes']):
        if h == b['hash']:
            return {'verdict': 'SLIP', 'offset': a['center'] - k}
    # Neither centre frame appears in the other's window, but the two windows
    # may still overlap: on a screen that animates every frame, both sides can
    # be rendering the same sequence a few frames apart without either centre
    # landing in the other's window. Rendering the same frame at all is a slip,
    # so compare the windows against each other and report the smallest shift.
    elsewhere = {h: k for k, h in enumerate(b['hashes'])}
    offsets = [(k - a['center']) - (elsewhere[h] - b['center'])
               for k, h in enumerate(a['hashes']) if h in elsewhere]
    if offsets:
        return {'verdict': 'SLIP', 'offset': min(offsets, key=abs),
                'why': 'the windows share a frame; neither centre does'}
    fa, fb = img.read_ppm(a['ppm']), img.read_ppm(b['ppm'])
    m = img.compare(fa, fb)
    wa, wb = _words(a['text']), _words(b['text'])
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
