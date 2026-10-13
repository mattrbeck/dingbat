"""@known entries: parsing, and what they do to a configuration's verdict.

  python3 -m unittest discover tools/playtest/tests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import pipeline  # noqa: E402
import script  # noqa: E402

TEXT = """@title Game
@known * checkpoint title: -- §33: the references load early
@known dingbat,dingbat-nowl ~load_file differs -- §32: the load screen
[new]
wait 10
checkpoint title
"""


class Known(unittest.TestCase):
    def test_parse_keeps_every_entry(self):
        k = script.parse(TEXT)['meta']['known']
        self.assertEqual(len(k), 2)
        self.assertEqual(k[0], {'configs': ['*'], 'problem': 'checkpoint title:', 'why': '§33: the references load early'})
        self.assertEqual(k[1]['configs'], ['dingbat', 'dingbat-nowl'])

    def test_entry_without_reason_is_refused(self):
        with self.assertRaises(script.ScriptError):
            script.parse('@known * checkpoint title:\n[new]\nwait 1\n')

    def test_matching(self):
        k = script.parse(TEXT)['meta']['known']
        self.assertTrue(script.known_match(k[0], 'dingbat-bios', 'checkpoint title: DIFFERENT'))
        self.assertFalse(script.known_match(k[0], 'dingbat', 'checkpoint menu: DIFFERENT'))
        self.assertTrue(script.known_match(k[1], 'dingbat', 'mgba save in dingbat: checkpoint load_file differs from'))
        self.assertFalse(script.known_match(k[1], 'dingbat-bios', 'mgba save in dingbat-bios: checkpoint load_file differs'))

    def test_known_problem_no_longer_fails_and_others_still_do(self):
        k = script.parse(TEXT)['meta']['known']
        v = {'problems': ['checkpoint title: MAJOR'], 'notes': []}
        pipeline.apply_known(v, 'dingbat-bios', k)
        self.assertEqual(v['problems'], [])
        self.assertEqual(v['known'], ['checkpoint title: MAJOR [§33: the references load early]'])
        v = {'problems': ['checkpoint title: MAJOR', 'checkpoint menu: DIFFERENT'], 'notes': []}
        pipeline.apply_known(v, 'dingbat', k)
        self.assertEqual(v['problems'], ['checkpoint menu: DIFFERENT'])

    def test_entry_that_matched_nothing_is_a_note(self):
        k = script.parse(TEXT)['meta']['known']
        v = {'problems': [], 'notes': []}
        pipeline.apply_known(v, 'dingbat', k)
        self.assertEqual(len([n for n in v['notes'] if n.startswith('@known')]), 2)
        v = {'problems': [], 'notes': []}
        pipeline.apply_known(v, 'dingbat-bios', k)      # the second entry is not for it
        self.assertEqual(len(v['notes']), 1)


if __name__ == '__main__':
    unittest.main()
