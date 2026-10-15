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
    def test_two_field_screen_reports_the_nearest_field(self):
        # A B A B ... on both sides, one field apart: the gap is one frame,
        # not the window's edge (Phantasy Star Collection, §62)
        a = side(['A' if k % 2 == 0 else 'B' for k in range(61)])
        b = side(['B' if k % 2 == 0 else 'A' for k in range(61)])
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


if __name__ == '__main__':
    unittest.main()
