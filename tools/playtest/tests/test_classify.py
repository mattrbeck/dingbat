"""Checkpoint classification: the SLIP offset a frame window reports.

  python3 -m unittest discover tools/playtest/tests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import classify  # noqa: E402

CENTER = 30


def side(hashes):
    return {'hash': hashes[CENTER], 'hashes': hashes, 'center': CENTER}


class SlipOffset(unittest.TestCase):
    def test_two_field_screen_that_starts_at_another_frame_reports_the_nearest_field(self):
        # A B A B ... on both sides, one field apart, but the fields begin
        # at different frames: not a phase alone, so the window match
        # judges it, and the gap is one frame, not the window's edge
        # (Phantasy Star Collection, §62)
        a = side(['X'] * 10 + ['A' if k % 2 == 0 else 'B' for k in range(51)])
        b = side(['X'] * 11 + ['A' if k % 2 == 0 else 'B' for k in range(50)])
        r = classify.classify(a, b)
        self.assertEqual(r['verdict'], 'SLIP')
        self.assertEqual(abs(r['offset']), 1)

    def test_a_plain_slip_keeps_its_sign(self):
        frames = [f'f{k}' for k in range(100)]
        a = side(frames[10:71])
        b = side(frames[12:73])     # b runs two frames ahead of a
        self.assertEqual(classify.classify(a, b), {'verdict': 'SLIP', 'offset': -2})
        self.assertEqual(classify.classify(b, a), {'verdict': 'SLIP', 'offset': 2})

    def test_a_shared_frame_off_centre_keeps_the_same_sign(self):
        # neither centre is in the other's window (each side's frames are
        # unique to it near the centre), but the windows share frames: the
        # offset must read as the centre match would, b ahead -> negative
        frames = [f'f{k}' for k in range(100)]
        a = side(frames[10:71])
        b = side(frames[11:72])     # b runs one frame ahead of a
        a['hashes'] = a['hashes'][:]
        b['hashes'] = b['hashes'][:]
        # blank out what would let either centre match directly
        a['hashes'][CENTER + 1] = 'a-only'
        b['hashes'][CENTER - 1] = 'b-only'
        a['hash'], b['hash'] = 'a-centre', 'b-centre'
        r = classify.classify(a, b)
        self.assertEqual(r['verdict'], 'SLIP')
        self.assertIn('windows share a frame', r.get('why', ''))
        self.assertEqual(r['offset'], -1)
        self.assertEqual(classify.classify(b, a)['offset'], 1)

    def test_a_text_judged_screen_one_frame_behind_is_a_slip(self):
        # OCR of a scrolling screen differs frame to frame, but the same
        # picture one frame apart is a slip (The Sims' language, §87)
        frames = [f'f{k}' for k in range(100)]
        a = dict(side(frames[10:71]), compare='text', text='ENGLISH | FRANCAIS')
        b = dict(side(frames[11:72]), compare='text', text='qx | zz')
        self.assertEqual(classify.classify(a, b), {'verdict': 'SLIP', 'offset': -1})

    def test_a_text_judged_screen_sharing_only_other_frames_reads_its_text(self):
        # the centres differ at the same moment (a blend step), the windows
        # share their unblended frames: not a slip (Aria of Sorrow, §72)
        a = dict(side([f'f{k}' for k in range(30)] + ['a-centre'] + [f'g{k}' for k in range(30)]),
                 compare='text', text='ENGLISH | FRANCAIS')
        b = dict(side([f'f{k}' for k in range(30)] + ['b-centre'] + [f'g{k}' for k in range(30)]),
                 compare='text', text='qx | zz')
        self.assertEqual(classify.classify(a, b)['verdict'], 'MAJOR')

    def test_a_text_judged_screen_one_rounding_step_apart_is_minor(self):
        # a blend one 5-bit step lower everywhere it differs: OCR reads the
        # faded letters differently, the pixels say rounding (§73, §89)
        import tempfile
        import numpy as np
        import img
        d = tempfile.mkdtemp()
        base = np.zeros((img.H, img.W, 3), np.uint8)
        base[::2, :, :] = 0x80
        lower = base.copy()
        lower[:40, :, 0] = np.where(base[:40, :, 0] == 0x80, 0x78, base[:40, :, 0])
        pa, pb = os.path.join(d, 'a.ppm'), os.path.join(d, 'b.ppm')
        for path, rgb in ((pa, lower), (pb, base)):
            with open(path, 'wb') as f:
                f.write(b'P6\n%d %d\n255\n' % (img.W, img.H) + rgb.tobytes())
        a = dict(side([f'a{k}' for k in range(61)]), compare='text', text='PUSH START', ppm=pa)
        b = dict(side([f'b{k}' for k in range(61)]), compare='text', text='PU5H 5TAPT', ppm=pb)
        r = classify.classify(a, b)
        self.assertEqual(r['verdict'], 'MINOR')
        self.assertIn('rounding', r['why'])

    def test_a_text_judged_screen_with_no_shared_frame_reads_its_text(self):
        a = dict(side([f'a{k}' for k in range(61)]), compare='text', text='ENGLISH | FRANCAIS')
        b = dict(side([f'b{k}' for k in range(61)]), compare='text', text='ENGLISH | FRANCAIS')
        self.assertEqual(classify.classify(a, b)['verdict'], 'MINOR')


def ppm(d, name, rgb):
    import img
    path = os.path.join(d, name + '.ppm')
    with open(path, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (img.W, img.H) + rgb.tobytes())
    return path


def picture(seed):
    """A busy picture of its own for every seed; seed + 0.5 is the same
    picture with one corner a 5-bit step dimmer (MINOR against it)."""
    import numpy as np
    import img
    rng = np.random.default_rng(int(seed))
    rgb = (rng.integers(0, 32, (img.H, img.W, 3)) * 8).astype(np.uint8)
    if seed != int(seed):
        rgb[:8, :8] = np.where(rgb[:8, :8] >= 8, rgb[:8, :8] - 8, rgb[:8, :8])
    return rgb


def alternating(fields, n=61, start=0):
    return [fields[(k + start) % len(fields)] for k in range(n)]


class FieldScreens(unittest.TestCase):
    """Screens drawn as fields that take turns every frame (§62)."""

    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()

    def with_pictures(self, c, pictures, tag):
        """The centre shot and the other fields' shots, as the runner keeps
        them; pictures: {hash: picture seed}."""
        c = dict(c)
        c['ppm'] = ppm(self.dir, f'{tag}-{c["hash"]}', picture(pictures[c['hash']]))
        c['fields'] = {h: ppm(self.dir, f'{tag}-{h}', picture(s)) for h, s in pictures.items() if h != c['hash']}
        c['text'] = ''
        return c

    def test_field_run(self):
        self.assertEqual(classify.field_run(['A'] * 61, CENTER), (1, 0, 60))
        self.assertEqual(classify.field_run(alternating('AB'), CENTER), (2, 0, 60))
        self.assertEqual(classify.field_run(alternating('ABC'), CENTER), (3, 0, 60))
        self.assertIsNone(classify.field_run([f'f{k}' for k in range(61)], CENTER))
        # a field cycle that only settles just before the centre is not one
        self.assertIsNone(classify.field_run(['X'] * 28 + alternating('AB', 33), CENTER))
        self.assertIsNone(classify.field_run(['A'], 0))

    def test_two_fields_out_of_phase_agree(self):
        # the same two pictures, the other one on the checkpoint frame: the
        # screen agrees; the phase is a note, not a slip
        r = classify.classify(side(alternating('AB')), side(alternating('BA')))
        self.assertEqual(r['verdict'], 'IDENTICAL')
        self.assertEqual(r['fields'], 2)
        self.assertEqual(abs(r['field_phase']), 1)

    def test_three_fields_out_of_phase_agree(self):
        r = classify.classify(side(alternating('ABC')), side(alternating('ABC', start=1)))
        self.assertEqual(r['verdict'], 'IDENTICAL')
        self.assertEqual((r['fields'], r['field_phase']), (3, -1))
        self.assertEqual(classify.classify(side(alternating('ABC')), side(alternating('ABC')))['field_phase'], 0)

    def test_fields_in_another_order_are_not_a_phase(self):
        # A B C against A C B: the same pictures, but no rotation lines them
        # up; with no pictures of the fields the centre frames are judged
        r = classify.classify(side(alternating('ABC')), side(alternating('ACB')))
        self.assertNotIn('field_phase', r)

    def test_a_phase_inside_the_same_change_of_screen_agrees(self):
        # the field cycle changes from A/B to C/D at the same frame on both
        # sides, out of phase throughout: a phase, not a slip (Boktai 2)
        a = side(alternating('AB', 4) + alternating('CD', 48) + alternating('AB', 9))
        b = side(alternating('BA', 4) + alternating('DC', 48) + alternating('BA', 9))
        r = classify.classify(a, b)
        self.assertEqual((r['verdict'], abs(r['field_phase'])), ('IDENTICAL', 1))

    def test_a_field_the_centres_hide_is_judged(self):
        # the checkpoint frames are the same picture, the other fields are
        # different screens: before field judging this read IDENTICAL
        a = self.with_pictures(side(alternating('AB')), {'A': 1, 'B': 2}, 'a')
        b = self.with_pictures(side(alternating('AC')), {'A': 1, 'C': 3}, 'b')
        r = classify.classify(a, b)
        self.assertEqual(r['verdict'], 'MAJOR')
        self.assertEqual(r['fields'], 2)
        self.assertEqual(sorted(r['field_verdicts']), ['IDENTICAL', 'MAJOR'])

    def test_a_field_one_rounding_step_off_is_minor(self):
        a = self.with_pictures(side(alternating('AB')), {'A': 1, 'B': 2}, 'a')
        b = self.with_pictures(side(alternating('CA')), {'A': 1, 'C': 2.5}, 'b')
        r = classify.classify(a, b)
        self.assertEqual(r['verdict'], 'MINOR')
        self.assertEqual(abs(r['field_phase']), 1)

    def test_fields_are_paired_by_rotation_not_by_the_checkpoint_frame(self):
        # a shows A on the checkpoint frame, b its own copy of the other
        # field: comparing the centres would pair different screens
        a = self.with_pictures(side(alternating('AB')), {'A': 1, 'B': 2}, 'a')
        b = self.with_pictures(side(alternating('DC')), {'C': 1.5, 'D': 2.5}, 'b')
        r = classify.classify(a, b)
        self.assertEqual(r['verdict'], 'MINOR')
        self.assertEqual(abs(r['field_phase']), 1)

    def test_a_missing_flicker_is_judged(self):
        # one side alternates A/B, the other holds A: the B field is judged
        # against A, a different screen
        a = self.with_pictures(side(['A'] * 61), {'A': 1}, 'a')
        b = self.with_pictures(side(alternating('BA')), {'A': 1, 'B': 2}, 'b')
        self.assertEqual(classify.classify(a, b)['verdict'], 'MAJOR')

    def test_a_field_without_a_picture_falls_back_to_the_centres(self):
        # a run that kept no shots of its fields (recorded before the runner
        # did): the fields cannot be judged, the centre frames are, and the
        # verdict says so
        r = classify.classify(side(alternating('AB')), side(alternating('AC')))
        self.assertEqual(r['verdict'], 'IDENTICAL')
        self.assertTrue(r['fields_unjudged'])
        self.assertIn('no picture', r['why'])
        self.assertNotIn('field_phase', r)


if __name__ == '__main__':
    unittest.main()
