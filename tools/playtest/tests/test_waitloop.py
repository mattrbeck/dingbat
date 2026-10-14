"""pipeline.waitloop_diffs: a configuration against its -nowl twin must
match in every recorded aspect; and the verdict fails the skipping side."""
import copy
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import pipeline  # noqa: E402


def report():
    run = {'ok': True, 'frame': 900, 'audio_sha1': 'au',
           'checkpoints': {'title': {'hash': 'h1', 'frame': 100}, 'menu': {'hash': 'h2', 'frame': 400}}}
    cell = {'ok': True, 'checkpoints': {'continue': {'hash': 'c1', 'frame': 50}}}
    names = ['dingbat', 'dingbat-nowl', 'mgba']
    return {'new': {n: copy.deepcopy(run) for n in names},
            'saves': {n: {'sha1': 'sv'} for n in names},
            'load': {f'{w}-in-{r}': copy.deepcopy(cell) for w in names for r in names}}


class WaitloopDiffs(unittest.TestCase):
    def test_identical_twins(self):
        self.assertEqual(pipeline.waitloop_diffs(report(), 'dingbat', 'dingbat-nowl'), [])

    def test_each_aspect_is_caught(self):
        cases = [
            (lambda r: r['new']['dingbat-nowl']['checkpoints']['menu'].update(hash='hX'), 'checkpoints menu'),
            (lambda r: r['new']['dingbat']['checkpoints']['title'].update(frame=101), 'checkpoints title'),
            (lambda r: r['new']['dingbat'].update(audio_sha1='au2'), 'audio'),
            (lambda r: r['saves']['dingbat'].update(sha1='sv2'), 'battery file'),
            (lambda r: r['new']['dingbat-nowl'].update(ok=False), '[new] outcome'),
            (lambda r: r['load']['mgba-in-dingbat']['checkpoints']['continue'].update(hash='cX'),
             'load mgba-in-dingbat'),
            # dingbat reading its own save against dingbat-nowl reading its own
            (lambda r: r['load']['dingbat-in-dingbat'].update(ok=False), 'load dingbat-in-dingbat'),
        ]
        for change, what in cases:
            r = report()
            change(r)
            self.assertEqual(pipeline.waitloop_diffs(r, 'dingbat', 'dingbat-nowl'), [what], what)


if __name__ == '__main__':
    unittest.main()
