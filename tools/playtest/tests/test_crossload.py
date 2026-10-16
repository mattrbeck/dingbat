"""The [load] matrix's judgement: which readers count as having read a save,
with the references' blank-cart runs of the same timeline as the control.

  python3 -m unittest discover tools/playtest/tests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import pipeline  # noqa: E402

REFS = ['mgba', 'nba']


def verdict(a, b):
    return {'verdict': 'IDENTICAL' if a == b else 'MAJOR'}


def report(cells, blank=None, blank_saves=()):
    """cells: {'w-in-r': {checkpoint: screen}}, a screen being any label
    (equal labels are the same picture; None: never reached). blank:
    {reference: {checkpoint: screen}}, its [load] with no battery file."""
    names = sorted({n for k in cells for n in k.split('-in-')}, key=lambda n: (n in REFS, n))
    rep = {'emulators': names,
           'saves': {n: {'exists': True, 'blank': n in blank_saves} for n in names},
           'load': {k: {'ok': True, 'save_unchanged': True, 'error': None} for k in cells},
           'load_checkpoints': {}}
    for key, screens in cells.items():
        w, r = key.split('-in-')
        out = {}
        for cp, mine in screens.items():
            out[cp] = {'reached': mine is not None, 'vs': {}}
            for x in names:
                other = cells.get(f'{w}-in-{x}', {}).get(cp)
                if x != r and f'{w}-in-{x}' in cells and mine is not None and other is not None:
                    out[cp]['vs'][x] = verdict(mine, other)
        rep['load_checkpoints'][key] = out
    if blank is not None:
        rep['load_blank_checkpoints'] = {
            key: {cp: {x: verdict(mine, b[cp]) for x, b in blank.items() if b.get(cp) is not None}
                  for cp, mine in screens.items() if mine is not None}
            for key, screens in cells.items()}
    return rep


def judge(rep, s='dingbat'):
    problems = []
    notes = pipeline.cross_load_verdict(rep, s, REFS, problems)
    return problems, notes


def matrix(**cells):
    """dingbat_in_mgba='x' -> {'dingbat-in-mgba': {'cp': 'x'}}"""
    return {k.replace('_in_', '-in-'): {'cp': v} for k, v in cells.items()}


BLANK = {'mgba': {'cp': 'blank'}, 'nba': {'cp': 'blank'}}


class BlankCart(unittest.TestCase):
    # Columns Crown (docs/playtest-bugs.md §95): mgba reads every save that
    # holds data, the second reference and dingbat read none of them
    COLUMNS = matrix(dingbat_in_dingbat='blank', dingbat_in_mgba='blank', dingbat_in_nba='blank',
                     mgba_in_dingbat='blank', mgba_in_mgba='loaded', mgba_in_nba='blank',
                     nba_in_dingbat='blank', nba_in_mgba='loaded', nba_in_nba='blank')

    def test_columns_crown_passed_without_the_control(self):
        problems, _ = judge(report(self.COLUMNS))
        self.assertEqual(problems, [])

    def test_columns_crown_fails_with_it(self):
        # the second reference's save is not reported: dingbat shows it as
        # its writer reads it back (lost), and the second reference losing
        # its own save leaves dingbat's open
        problems, _ = judge(report(self.COLUMNS, BLANK))
        self.assertEqual(problems, ["mgba save in dingbat: shows a blank cart's screens, as nba does, "
                                    "where mgba reads the save: cp (mgba=MAJOR)"])

    def test_showing_a_save_as_its_writer_does_is_not_a_blank_cart(self):
        # Classic NES Series: mgba's 8 KB file loads a title a step from the
        # blank cart's in mgba and dingbat, the second reference shows
        # GAME PAK ERROR (not the blank cart: it "reads" the save)
        cells = matrix(dingbat_in_dingbat='loaded', dingbat_in_mgba='loaded', dingbat_in_nba='loaded',
                       mgba_in_dingbat='blank', mgba_in_mgba='blank', mgba_in_nba='error',
                       nba_in_dingbat='loaded', nba_in_mgba='loaded', nba_in_nba='loaded')
        problems, _ = judge(report(cells, BLANK))
        self.assertEqual(problems, [])

    def test_a_save_that_loads_nowhere_while_both_references_load_their_own(self):
        cells = matrix(dingbat_in_dingbat='blank', dingbat_in_mgba='blank', dingbat_in_nba='blank',
                       mgba_in_mgba='loaded', nba_in_nba='loaded')
        problems, _ = judge(report(cells, BLANK))
        self.assertEqual(problems, ["dingbat save: shows a blank cart's screens in dingbat/mgba/nba where "
                                    "mgba/nba read their own save: cp"])

    def test_a_save_that_loads_nowhere_while_one_reference_loses_its_own_too(self):
        # Mario & Luigi: dingbat's and mgba's [new] reach no save (the same
        # bytes, the blank cart's screens everywhere); the second
        # reference's own save loads. Nothing says dingbat is wrong
        cells = matrix(dingbat_in_dingbat='blank', dingbat_in_mgba='blank', dingbat_in_nba='blank',
                       mgba_in_mgba='blank', nba_in_nba='loaded')
        self.assertEqual(judge(report(cells, BLANK))[0], [])

    def test_a_reference_that_cannot_read_is_no_witness_but_not_a_failure(self):
        # the second reference before §94: it loses every 4 Kbit save, its
        # own included; dingbat reads them all as mgba does
        cells = matrix(dingbat_in_dingbat='loaded', dingbat_in_mgba='loaded', dingbat_in_nba='blank',
                       mgba_in_dingbat='loaded', mgba_in_mgba='loaded', mgba_in_nba='blank',
                       nba_in_dingbat='loaded', nba_in_mgba='loaded', nba_in_nba='blank')
        problems, notes = judge(report(cells, BLANK))
        self.assertEqual(problems, [])
        self.assertTrue(any('not diagnostic' in n for n in notes))

    def test_a_game_that_ignores_the_save_at_these_checkpoints(self):
        cells = matrix(dingbat_in_dingbat='blank', dingbat_in_mgba='blank', dingbat_in_nba='blank',
                       mgba_in_dingbat='blank', mgba_in_mgba='blank', mgba_in_nba='blank',
                       nba_in_dingbat='blank', nba_in_mgba='blank', nba_in_nba='blank')
        self.assertEqual(judge(report(cells, BLANK)), ([], []))

    def test_both_references_read_and_dingbat_does_not(self):
        cells = matrix(dingbat_in_dingbat='loaded', dingbat_in_mgba='loaded', dingbat_in_nba='loaded',
                       mgba_in_dingbat='blank', mgba_in_mgba='loaded', mgba_in_nba='loaded',
                       nba_in_dingbat='loaded', nba_in_mgba='loaded', nba_in_nba='loaded')
        problems, _ = judge(report(cells, BLANK))
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("mgba save in dingbat: shows a blank cart's screens where mgba/nba "
                                               "reads the save"), problems[0])

    def test_references_reading_a_save_differently_stays_not_diagnostic(self):
        # both read it (neither shows the blank cart), they disagree, and
        # dingbat sides with one: nothing says which is right
        cells = matrix(dingbat_in_dingbat='a', dingbat_in_mgba='a', dingbat_in_nba='a',
                       mgba_in_dingbat='a', mgba_in_mgba='a', mgba_in_nba='b',
                       nba_in_dingbat='a', nba_in_mgba='a', nba_in_nba='a')
        problems, _ = judge(report(cells, BLANK))
        self.assertEqual(problems, [])

    def test_dingbat_reading_something_else_is_not_a_blank_cart(self):
        # dingbat shows neither the save nor the blank cart: the existing
        # rule (references disagree: not diagnostic) still decides
        cells = matrix(dingbat_in_dingbat='loaded', dingbat_in_mgba='loaded', dingbat_in_nba='loaded',
                       mgba_in_dingbat='garbled', mgba_in_mgba='loaded', mgba_in_nba='blank',
                       nba_in_dingbat='loaded', nba_in_mgba='loaded', nba_in_nba='loaded')
        problems, notes = judge(report(cells, BLANK))
        self.assertEqual(problems, [])
        self.assertTrue(any('mgba save, checkpoint cp: the references show it differently too' in n for n in notes))

    def test_a_blank_save_is_meant_to_look_blank(self):
        # a writer whose file holds no data: showing the blank cart is right
        problems, _ = judge(report(self.COLUMNS, BLANK, blank_saves=('mgba', 'nba', 'dingbat')))
        self.assertEqual(problems, [])

    def test_a_save_nobody_can_read_with_no_reference_reading_its_own(self):
        # every reader shows the blank cart for dingbat's save, but no
        # reference loads its own save here either: no evidence
        cells = matrix(dingbat_in_dingbat='blank', dingbat_in_mgba='blank', dingbat_in_nba='blank',
                       mgba_in_mgba='blank', nba_in_nba='blank')
        self.assertEqual(judge(report(cells, BLANK))[0], [])

    def test_dingbat_not_reading_its_own_save_that_the_references_read(self):
        # both references show dingbat's save loaded, dingbat the blank
        # cart: without the control that is only a note (the references
        # agree with each other against dingbat's own reading)
        cells = matrix(dingbat_in_dingbat='blank', dingbat_in_mgba='loaded', dingbat_in_nba='loaded',
                       mgba_in_mgba='loaded', nba_in_nba='loaded')
        problems, notes = judge(report(cells))
        self.assertEqual(problems, [])
        self.assertEqual(len(notes), 2)
        problems, _ = judge(report(cells, BLANK))
        self.assertEqual(problems, ["dingbat save in dingbat: shows a blank cart's screens where mgba/nba read "
                                    "the same save: cp"])

    def test_no_blank_run_reaching_the_checkpoint_says_nothing(self):
        blank = {'mgba': {'cp': None}, 'nba': {'cp': None}}
        problems, _ = judge(report(self.COLUMNS, blank))
        self.assertEqual(problems, [])

    def test_blank_state(self):
        rep = report(self.COLUMNS, BLANK)
        self.assertTrue(pipeline.blank_state(rep, 'mgba-in-nba', 'cp'))
        self.assertIs(pipeline.blank_state(rep, 'mgba-in-mgba', 'cp'), False)
        self.assertIsNone(pipeline.blank_state(rep, 'mgba-in-mgba', 'other'))
        self.assertIsNone(pipeline.blank_state(report(self.COLUMNS), 'mgba-in-mgba', 'cp'))


if __name__ == '__main__':
    unittest.main()
