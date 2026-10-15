"""Plays a game's [new] section on a dingbat driver, with no OCR, for
refresh.sh: the instrumented driver records which code the corpus runs.

  pgo/play.py DRIVER CONFIG SHA1
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import emu  # noqa: E402
import library  # noqa: E402
import runner  # noqa: E402
import script  # noqa: E402


class NoOCR:
    def ocr(self, *a, **k):
        return []

    def read(self, *a, **k):
        return {'lines': [], 'text': '', 'selected': None}


def main():
    driver, config, sha1 = sys.argv[1:4]
    play = script.parse(open(os.path.join(HERE, '..', 'scripts', sha1 + '.play')).read())
    rom = library.Library(os.path.join(HERE, '..', 'out', 'rom-index.json')).find(sha1, play['meta'].get('file'))
    if not rom:
        sys.exit(f'{sha1}: ROM not in the library')
    os.environ['PLAYTEST_DINGBAT_DRIVER'] = driver
    with tempfile.TemporaryDirectory() as d:
        e = emu.Emulator(config, rom, os.path.join(d, 'env'), rtc_epoch=int(play['meta'].get('rtc', 1136073600)))
        ex = runner.Executor(e, os.path.join(d, 'shots'), NoOCR())
        for st in play['new']:
            ex.do(st)
        e.quit()


if __name__ == '__main__':
    main()
