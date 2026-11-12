"""The `gyro` and `tilt` steps: parsing, the frozen form, the executor, and
what each driver is sent.

  python3 -m unittest discover tools/playtest/tests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import emu as emulib  # noqa: E402
import runner  # noqa: E402
import script  # noqa: E402


class Steps(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(script.parse_step('gyro 0.5'), {'op': 'gyro', 'rate': 0.5})
        self.assertEqual(script.parse_step('tilt -0.25 1'), {'op': 'tilt', 'x': -0.25, 'y': 1.0})

    def test_round_trip(self):
        for line in ('gyro 0.5', 'gyro -1', 'gyro 0', 'tilt 0.25 -0.75', 'tilt 0 0'):
            self.assertEqual(script.format_step(script.parse_step(line)), line)

    def test_range(self):
        for line in ('gyro 1.5', 'gyro -2', 'tilt 0 1.01'):
            with self.assertRaises(script.ScriptError):
                script.parse_step(line)

    def test_in_a_script(self):
        play = script.parse('[new]\nwait 10\ngyro 0.5\nwait 30\ngyro 0\n[load]\ntilt 0.1 0\n')
        self.assertEqual([s['op'] for s in play['new']], ['wait', 'gyro', 'wait', 'gyro'])
        self.assertEqual(play['load'][0]['op'], 'tilt')


class FakeEmu:
    def __init__(self, binary):
        self.sent = []
        self.binary = binary
        self.motion = (0.0, 0.0, 0.0)
        self.motion_ignored = False
        self.frame = 0
        self.held = 0

    def cmd(self, line):
        self.sent.append(line)
        return ''

    set_motion = emulib.Emulator.set_motion


class Drivers(unittest.TestCase):
    def test_held_and_combined(self):
        e = FakeEmu('dingbat_driver')
        ex = runner.Executor(e, '/tmp/dingbat-test-motion', reader=None)
        ex.do(script.parse_step('gyro 0.5'))
        ex.do(script.parse_step('tilt -0.25 0.75'))
        ex.do(script.parse_step('gyro 0.5'))      # unchanged: nothing sent
        ex.do(script.parse_step('gyro 0'))
        self.assertEqual(e.sent, ['motion 0.5000 0.0000 0.0000', 'motion 0.5000 -0.2500 0.7500',
                                  'motion 0.0000 -0.2500 0.7500'])
        self.assertFalse(e.motion_ignored)

    def test_no_motion_input(self):
        e = FakeEmu('nba_driver')
        ex = runner.Executor(e, '/tmp/dingbat-test-motion', reader=None)
        ex.do(script.parse_step('gyro 0.5'))
        self.assertEqual(e.sent, [])
        self.assertTrue(e.motion_ignored)

    def test_rest_is_not_ignored(self):
        e = FakeEmu('nba_driver')
        ex = runner.Executor(e, '/tmp/dingbat-test-motion', reader=None)
        ex.do(script.parse_step('gyro 0'))      # already at rest: nothing to take
        self.assertFalse(e.motion_ignored)


if __name__ == '__main__':
    unittest.main()
