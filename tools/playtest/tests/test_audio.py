"""audio.py's window comparison on synthetic features.

  python3 -m unittest discover tools/playtest/tests
"""
import os
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import audio  # noqa: E402

BANDS = len(audio.EDGES) - 1


def feats(level, n=10):
    return {'rms': np.full(n, float(level)), 'width': np.zeros(n),
            'shape': np.full((n, BANDS), 1.0 / BANDS), 'peak': float(level)}


class Silent(unittest.TestCase):
    def test_a_silent_run_is_inaudible_in_every_window(self):
        self.assertEqual(audio.audible(feats(0)).tolist(), [False] * 10)

    def test_a_reference_silent_throughout_is_compared_not_a_crash(self):
        # Asterix & Obelix XXL: the second reference hangs at boot and plays
        # nothing; window_diff ANDed a 0-length array with a full one
        d, why = audio.window_diff(feats(1), feats(0))
        self.assertEqual(int(why['presence'].sum()), 10)
        out = audio.compare({'dingbat': feats(1), 'mgba': feats(1), 'nba': feats(0)}, ['dingbat'], ['mgba', 'nba'])
        self.assertEqual(out['subjects']['dingbat']['status'], 'SAME')


class Rate(unittest.TestCase):
    def test_a_dump_off_the_nominal_rate_is_named(self):
        # Driv3r: the second reference's capture pulled 547.28 samples a
        # frame, not 548.58, and its windows read audio 25 frames early by
        # the end (docs/playtest-bugs.md, "Driv3r's audio")
        ok, short = feats(1), feats(1)
        ok['per_frame'] = audio.NOMINAL_PER_FRAME
        short['per_frame'] = 547.278
        out = audio.compare({'dingbat': dict(ok), 'mgba': dict(ok), 'nba': short}, ['dingbat'], ['mgba', 'nba'])
        self.assertEqual(list(out['rate_off']), ['nba'])

    def test_features_without_a_rate_are_not_flagged(self):
        out = audio.compare({'dingbat': feats(1), 'mgba': feats(1), 'nba': feats(1)}, ['dingbat'], ['mgba', 'nba'])
        self.assertEqual(out['rate_off'], {})


if __name__ == '__main__':
    unittest.main()
