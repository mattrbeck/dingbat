"""divergences.py's qualifier: who stands alone, how big, whether it lasts,
and the tier that follows.

  python3 -m unittest discover tools/playtest/tests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import divergences as dv  # noqa: E402

I = {'verdict': 'IDENTICAL'}


def slip(k):
    return {'verdict': 'SLIP', 'offset': k}


def major(area=1.0):
    return {'verdict': 'MAJOR', 'diff_box': [0, 0, int(240 * area), 160]}


def details(area=1.0):
    return {'verdict': 'DIFFERENT', 'diff_box': [0, 0, int(240 * area), 160]}


def report(rows):
    """rows: [(checkpoint, subject~mgba, subject~ref2, mgba~ref2)]"""
    return {'new_checkpoints': {cp: {'frames': {'dingbat': i * 100},
                                     'pairs': {'dingbat~mgba': a, 'dingbat~nba': b, 'mgba~nba': c}}
                                for i, (cp, a, b, c) in enumerate(rows)}}


def tiers(rows, known=False, status='PASS'):
    r = report(rows)
    out = [dv.qualify_frames(it, known, status) for it in dv.frame_items({}, r, 'dingbat', 'frame')]
    return {it['pattern']: it['sev'] for it in out}


class Patterns(unittest.TestCase):
    def test_who_is_odd(self):
        self.assertEqual(dv.pattern(slip(1), slip(1), I), 'dingbat alone')
        self.assertEqual(dv.pattern(slip(1), I, slip(1)), 'mgba alone')
        self.assertEqual(dv.pattern(I, major(), major()), 'ref2 alone')
        self.assertEqual(dv.pattern(major(), slip(2), slip(3)), 'all differ')
        self.assertEqual(dv.pattern(I, I, I), 'agree')
        self.assertEqual(dv.pattern(I, I, major()), 'inconsistent')

    def test_sizes_order(self):
        self.assertLess(dv.size({'verdict': 'MINOR'})[1], dv.size(slip(1))[1])
        self.assertLess(dv.size(slip(30))[1], dv.size(details(0.0))[1])
        self.assertLess(dv.size(details(1.0))[1], dv.size(major(0.0))[1] + 0.01)
        self.assertLess(dv.size(major(1.0))[1], dv.size({'verdict': 'FAILED'})[1])


class Tiers(unittest.TestCase):
    def test_transient_slip_is_watch(self):
        t = tiers([('a', slip(1), slip(1), I), ('b', I, I, I)])
        self.assertEqual(t['dingbat alone'], 'S3')

    def test_slip_that_never_recovers_is_chase(self):
        t = tiers([('a', slip(1), slip(1), I), ('b', slip(2), slip(2), I)])
        self.assertEqual(t['dingbat alone'], 'S2')

    def test_one_slip_at_the_last_checkpoint_is_not_lasting(self):
        t = tiers([('a', I, I, I), ('b', slip(1), slip(1), I)])
        self.assertEqual(t['dingbat alone'], 'S3')

    def test_another_screen_that_stays_is_act(self):
        t = tiers([('a', major(), major(), I), ('b', major(), major(), I)])
        self.assertEqual(t['dingbat alone'], 'S1')

    def test_known_game_is_noted(self):
        t = tiers([('a', major(), major(), I), ('b', major(), major(), I)], known=True, status='KNOWN')
        self.assertEqual(t['dingbat alone'], 'S4')

    def test_reference_alone_is_reference_side(self):
        t = tiers([('a', major(), I, major())])
        self.assertEqual(t['mgba alone'], 'R')

    def test_no_consensus_between_the_references_is_noted(self):
        t = tiers([('a', slip(1), slip(1), slip(2))])
        self.assertEqual(t['all differ'], 'S4')


class Saves(unittest.TestCase):
    def rep(self, groups, pairs, lc=None):
        return {'saves': {n: {'exists': True, 'size': 512} for n in ('dingbat', 'mgba', 'nba')},
                'save_groups': groups, 'save_pairs': pairs, 'load_checkpoints': lc or {}}

    def test_same_save_is_no_item(self):
        self.assertEqual(dv.save_items(self.rep([['dingbat', 'mgba', 'nba']], {}), 'dingbat'), [])

    def test_counter_sized_alone_is_watch(self):
        p = {'same_size': True, 'sizes': [512, 512], 'chip_body_identical': False, 'diff': {'bytes': 4, 'count': 1}}
        it = dv.save_items(self.rep([['dingbat'], ['mgba', 'nba']], {'dingbat~mgba': p, 'dingbat~nba': p}), 'dingbat')[0]
        self.assertEqual((it['pattern'], it['sev']), ('dingbat alone', 'S3'))

    def test_far_from_two_identical_saves_is_chase(self):
        p = {'same_size': True, 'sizes': [512, 512], 'chip_body_identical': False, 'diff': {'bytes': 300, 'count': 9}}
        it = dv.save_items(self.rep([['dingbat'], ['mgba', 'nba']], {'dingbat~mgba': p, 'dingbat~nba': p}), 'dingbat')[0]
        self.assertEqual(it['sev'], 'S2')

    def test_container_only_is_noted(self):
        p = {'same_size': False, 'sizes': [512, 8192], 'chip_body_identical': True}
        it = dv.save_items(self.rep([['dingbat'], ['mgba', 'nba']], {'dingbat~mgba': p, 'dingbat~nba': p}), 'dingbat')[0]
        self.assertEqual(it['sev'], 'S4')

    def test_reference_alone_is_reference_side(self):
        p = {'same_size': True, 'sizes': [512, 512], 'chip_body_identical': False, 'diff': {'bytes': 4, 'count': 1}}
        it = dv.save_items(self.rep([['dingbat', 'nba'], ['mgba']], {'dingbat~mgba': p}), 'dingbat')[0]
        self.assertEqual((it['pattern'], it['sev']), ('mgba alone', 'R'))


if __name__ == '__main__':
    unittest.main()
