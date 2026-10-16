"""Pre-registered predictions: the pattern grammar, the scoring, and that
every prediction names a cell its row records.

  python3 -m unittest discover tools/hwlink/tests
"""
import io
import os
import sys
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import predicted  # noqa: E402
import r0table  # noqa: E402


class Patterns(unittest.TestCase):
    def test_word_and_wildcard(self):
        self.assertTrue(predicted.fits('BEE33333', 0xBEE33333))
        self.assertTrue(predicted.fits('bee3xxxx', 0xBEE31234))
        self.assertFalse(predicted.fits('BEE3xxxx', 0x3333BEE3))

    def test_alternatives_and_negation(self):
        self.assertTrue(predicted.fits('00000033|000002A6', 0x2A6))
        self.assertFalse(predicted.fits('!xxxx0001|FFFF00FF', 0xFFFF00FF))
        self.assertTrue(predicted.fits('!xxxx0001', 0x3))

    def test_mask(self):
        self.assertTrue(predicted.fits('00040000&00000000', 0x003B0001))
        self.assertFalse(predicted.fits('00040000&00000000', 0x00040000))

    def test_a_raced_cell_hits_only_when_every_answer_fits(self):
        self.assertTrue(predicted.hit('0008xxxx', '0008E150 | 00081AFF'))
        self.assertFalse(predicted.hit('0008E150', '0008E150 | 00081AFF'))

    def test_every_pattern_parses(self):
        for row, p in predicted.PREDICTIONS.items():
            for cell, by in p['cells'].items():
                for who, pattern in by.items():
                    self.assertTrue(predicted.valid(pattern), (row, cell, who, pattern))


class Registry(unittest.TestCase):
    def test_every_predicted_cell_is_recorded_by_its_row(self):
        for row, p in predicted.PREDICTIONS.items():
            labels = {predicted.label(a) for a in r0table.TABLE[row]}
            self.assertLessEqual(set(p['cells']), labels, row)

    def test_every_predictor_is_described(self):
        for row, p in predicted.PREDICTIONS.items():
            self.assertIn('date', p, row)
            used = {who for by in p['cells'].values() for who in by}
            self.assertEqual(used, set(p['who']), row)

    def test_the_probe_rows_stay_out_of_the_frozen_gate(self):
        for row in ('timergeo', 'wakehb', 'obusdma16', 'fifolog', 's0age', 'psgrace', 'hdmarace'):
            self.assertIn(row, r0table.TABLE)
            self.assertIn(row, r0table.OPEN_ROWS)
            self.assertNotIn(row, r0table.NEEDS_CART)

    def test_fifolog_samples_add_up(self):
        s = predicted.fifolog_samples()
        self.assertEqual(s[('toy', 1, 0, 0)][:5], [32, 35, 38, 41, 62])
        self.assertEqual(s[('k3data', 3, 0, 0)][:2], [17, 27])
        self.assertEqual(len(s), 56 * 3 + 7)


class Score(unittest.TestCase):
    PRED = {'probe': {
        'where': 'here', 'date': '2026-10-15',
        'who': {'dingbat': '', 'mgba': '', 'H1': ''},
        'cells': {'0x0': {'dingbat': '00000001', 'mgba': '00000002', 'H1': '0000000x'},
                  '0x1': {'dingbat': '00000001', 'H1': '!00000001'},
                  '0x2': {'dingbat': '00000005'}}}}

    def test_hits_misses_and_unrecorded(self):
        table = {'probe': {'0x0': '00000001', '0x1': '00000003'}}
        with redirect_stdout(io.StringIO()) as out:
            t = predicted.score(table, predictions=self.PRED)
        r = t['probe']
        self.assertEqual(r['unrecorded'], ['0x2'])
        self.assertEqual(r['who']['dingbat'], (1, 2, ['0x1']))
        self.assertEqual(r['who']['mgba'], (0, 1, ['0x0']))
        self.assertEqual(r['who']['H1'], (2, 2, []))
        self.assertIn('probe:H1', out.getvalue())

    def test_each_cart_is_scored_on_its_own(self):
        table = {'probe@ASIE': {'0x0': '00000001'}, 'probe@B8ME': {'0x0': '00000002'}}
        with redirect_stdout(io.StringIO()):
            t = predicted.score(table, predictions=self.PRED)
        self.assertNotIn('probe', t)
        self.assertEqual(t['probe@ASIE']['who']['dingbat'], (1, 1, []))
        self.assertEqual(t['probe@B8ME']['who']['mgba'], (1, 1, []))

    def test_nothing_recorded_scores_nothing(self):
        with redirect_stdout(io.StringIO()):
            t = predicted.score({}, predictions=self.PRED)
        self.assertEqual(t['probe']['who']['dingbat'], (0, 0, []))
        self.assertEqual(len(t['probe']['unrecorded']), 3)


if __name__ == '__main__':
    unittest.main()
