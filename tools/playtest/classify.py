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
    if a.get('compare') == 'text' or b.get('compare') == 'text':
        wa, wb = _words(a['text']), _words(b['text'])
        sim = len(wa & wb) / len(wa | wb) if (wa or wb) else 1.0
        return {'verdict': 'MINOR' if sim >= 0.9 else 'MAJOR', 'text_similarity': round(sim, 2),
                'why': 'compared by on-screen text only', 'palette_only': sim >= 0.9}
    for k, h in enumerate(b['hashes']):
        if h == a['hash']:
            return {'verdict': 'SLIP', 'offset': k - b['center']}
    for k, h in enumerate(a['hashes']):
        if h == b['hash']:
            return {'verdict': 'SLIP', 'offset': a['center'] - k}
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
