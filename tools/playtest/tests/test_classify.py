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


if __name__ == '__main__':
    unittest.main()
