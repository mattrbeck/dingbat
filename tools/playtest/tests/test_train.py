"""train.py's comparison and attribution on synthetic suite data, plus the
pipeline's reference replay.

  python3 -m unittest discover tools/playtest/tests
"""
import copy
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import train  # noqa: E402

CONFIGS = train.DINGBAT


def results(passed=True, cps=None, audio='au0', save='sv0', load_hash='ld0', windows=True, configs=CONFIGS):
    """A results.json-shaped dict: the same outcome in every configuration
    unless a value is a dict {config: value}."""
    def pick(v, c):
        return v.get(c, v.get('*')) if isinstance(v, dict) and ('*' in v or c in v) else v
    cps = cps or {'title': 'h-title', 'menu': 'h-menu'}
    r = {'emulators': list(configs) + ['mgba', 'nba'], 'verdicts': {}, 'new': {}, 'saves': {}, 'load': {}}
    for c in configs:
        p = pick(passed, c)
        r['verdicts'][c] = {'pass': p, 'play': 'IDENTICAL' if p else 'DIFFERENT',
                            'problems': [] if p else ['checkpoint menu: DIFFERENT']}
        r['new'][c] = {'ok': True, 'error': None, 'frame': 1000, 'audio_sha1': pick(audio, c),
                       'checkpoints': {name: {'frame': 100 + i, 'hash': pick(h, c)}
                                       for i, (name, h) in enumerate(cps.items())}}
        r['saves'][c] = {'exists': True, 'size': 8192, 'sha1': pick(save, c)}
        r['load'][f'{c}-in-mgba'] = {'ok': True, 'save_unchanged': True,
                                     'checkpoints': {'continue': {'frame': 50, 'hash': pick(load_hash, c)}}}
        r['load'][f'mgba-in-{c}'] = {'ok': True, 'save_unchanged': True,
                                     'checkpoints': {'continue': {'frame': 50, 'hash': 'ref-read'}}}
    return r


def dump(data, p):
    with open(p, 'w') as f:
        json.dump(data, f)


def fp(status='PASS', **kw):
    win = kw.pop('win', None)
    res = results(**kw)
    windows = {c: {cp: [win or 'w', d['hash']] for cp, d in res['new'][c]['checkpoints'].items()} for c in CONFIGS}
    return train.fingerprint({'status': status, 'outdir': '/runs/x'}, res, windows)


class Fingerprint(unittest.TestCase):
    def test_identical_runs_do_not_differ(self):
        self.assertEqual(train.diff_fp(fp(), fp()), {})

    def test_one_pixel_change_in_one_config_is_neutral(self):
        after = fp(cps={'title': 'h-title', 'menu': {'*': 'h-menu', 'dingbat-bios': 'h-menu2'}})
        d = train.diff_fp(fp(), after)
        self.assertEqual(list(d), ['dingbat-bios'])
        self.assertIn('cp:menu', d['dingbat-bios'])
        self.assertIn('win:menu', d['dingbat-bios'])
        self.assertEqual(train.classify(fp(), after), {'kind': 'neutral', 'configs': {'dingbat-bios': 'neutral'}})

    def test_window_only_change_is_caught(self):
        # the checkpoint frame matches but a neighbouring frame differs
        d = train.diff_fp(fp(), fp(win='w2'))
        self.assertEqual(sorted(d['dingbat']), ['win:menu', 'win:title'])

    def test_fixed_and_regressed(self):
        self.assertEqual(train.classify(fp(passed=False), fp())['kind'], 'fixed')
        self.assertEqual(train.classify(fp(), fp(passed=False))['kind'], 'regressed')
        mixed = fp(passed={'*': True, 'dingbat': False}, status='FAIL')
        self.assertEqual(train.classify(fp(passed={'*': False, 'dingbat': True}, status='FAIL'), mixed)['kind'],
                         'mixed')

    def test_audio_save_and_load_hashes(self):
        for kw, key in (({'audio': 'au1'}, 'audio'), ({'save': 'sv1'}, 'save'),
                        ({'load_hash': 'ld1'}, 'load:dingbat-in-mgba')):
            d = train.diff_fp(fp(), fp(**kw))
            self.assertEqual(set(d), set(CONFIGS), kw)
            self.assertIn(key, d['dingbat'])

    def test_missing_audio_or_windows_is_unknown_not_different(self):
        old = train.fingerprint({'status': 'PASS'}, results(audio=None), None)
        self.assertEqual(train.diff_fp(old, fp()), {})

    def test_error_paths_do_not_count(self):
        a, b = results(), results()
        a['new']['dingbat']['error'] = 'DriverError: /runs/a/new/dingbat/env exited'
        b['new']['dingbat']['error'] = 'DriverError: /runs/b/new/dingbat/env exited'
        fa = train.fingerprint({'status': 'FAIL', 'outdir': '/runs/a'}, a)
        fb = train.fingerprint({'status': 'FAIL', 'outdir': '/runs/b'}, b)
        self.assertEqual(train.diff_fp(fa, fb), {})

    def test_game_that_stops_running_is_regressed(self):
        dead = train.fingerprint({'status': 'ERROR'})
        self.assertEqual(train.classify(fp(), dead)['kind'], 'regressed')
        self.assertEqual(train.classify(dead, fp())['kind'], 'fixed')

    def test_diff_suites(self):
        changed, added, removed = train.diff_suites({'a': fp(), 'b': fp(), 'c': fp()},
                                                    {'a': fp(), 'b': fp(audio='x'), 'd': fp()})
        self.assertEqual(list(changed), ['b'])
        self.assertEqual((added, removed), (['d'], ['c']))


class Attribution(unittest.TestCase):
    def test_each_game_to_its_candidate(self):
        base = {'g1': fp(passed=False, status='FAIL'), 'g2': fp()}
        comb = {'g1': fp(), 'g2': fp(cps={'title': 'new', 'menu': 'h-menu'})}
        cands = {'A': {'g1': fp(), 'g2': fp()}, 'B': {'g1': fp(passed=False, status='FAIL'), 'g2': comb['g2']}}
        att = train.attribute(base, comb, cands)
        self.assertEqual(att['interactions'], [])
        self.assertEqual(list(att['effects']['A']), ['g1'])
        self.assertEqual(att['effects']['A']['g1']['kind'], 'fixed')
        self.assertEqual(list(att['effects']['B']), ['g2'])
        self.assertEqual(att['effects']['B']['g2']['kind'], 'neutral')

    def test_two_candidates_split_one_game(self):
        # A changes the pixels, B fixes the save: together both, alone one each
        base = {'g': fp(passed=False, status='FAIL', load_hash='ld0')}
        comb = {'g': fp(cps={'title': 'px', 'menu': 'h-menu'}, load_hash='ld1')}
        cands = {'A': {'g': fp(passed=False, status='FAIL', cps={'title': 'px', 'menu': 'h-menu'})},
                 'B': {'g': fp(load_hash='ld1')}}
        att = train.attribute(base, comb, cands)
        self.assertEqual(att['interactions'], [])
        self.assertEqual(att['effects']['A']['g']['kind'], 'neutral')
        self.assertEqual(att['effects']['B']['g']['kind'], 'fixed')

    def test_change_nobody_makes_alone_is_an_interaction(self):
        base = {'g': fp()}
        comb = {'g': fp(passed=False, status='FAIL')}
        att = train.attribute(base, comb, {'A': {'g': fp()}, 'B': {'g': fp()}})
        self.assertEqual(len(att['interactions']), 1)
        i = att['interactions'][0]
        self.assertEqual(i['involved'], ['A', 'B'])
        self.assertTrue(any('pass' in u for u in i['unexplained']))

    def test_changes_that_overlap_are_an_interaction(self):
        base = {'g': fp()}
        comb = {'g': fp(audio='both')}
        att = train.attribute(base, comb, {'A': {'g': fp(audio='a')}, 'B': {'g': fp(audio='both')}})
        self.assertEqual(len(att['interactions']), 1)
        self.assertTrue(att['interactions'][0]['overlapping'][0].startswith('A:'))
        self.assertEqual(att['interactions'][0]['involved'], ['A', 'B'])

    def test_same_change_from_two_candidates_is_shared(self):
        base = {'g': fp(passed=False, status='FAIL')}
        comb = {'g': fp()}
        att = train.attribute(base, comb, {'A': {'g': fp()}, 'B': {'g': fp()}})
        self.assertEqual(att['interactions'], [])
        self.assertEqual(att['shared'], {'g': ['A', 'B']})
        self.assertEqual(att['effects']['A']['g']['kind'], 'fixed')
        self.assertEqual(att['effects']['B']['g']['kind'], 'fixed')

    def test_change_masked_in_the_batch_is_flagged(self):
        # A moves g alone, but the combined build shows g unchanged: only an
        # interaction can hide it (g is in the changed set through B)
        base = {'g': fp()}
        comb = {'g': fp(save='sv9')}
        cands = {'A': {'g': fp(audio='a')}, 'B': {'g': fp(save='sv9')}}
        att = train.attribute(base, comb, cands)
        self.assertEqual(len(att['interactions']), 1)
        self.assertEqual(att['effects']['B']['g']['kind'], 'neutral')

    def test_describe(self):
        d = train.diff_fp(fp(passed=False, status='FAIL'), fp(audio='x', load_hash='ld9'))
        text = train.describe({'dingbat': d['dingbat']})
        self.assertIn('FAIL->PASS', text)
        self.assertIn('audio', text)
        self.assertIn('load self-in-mgba', text)
        # every configuration changing the same way is one entry
        self.assertIn(' | all four: FAIL->PASS', train.describe(d))


class Noise(unittest.TestCase):
    BASE = 'b' * 40

    def rerun(self, fps):
        """A rerun callback returning `fps` and recording what it was asked."""
        self.asked = None

        def f(subset):
            self.asked = list(subset)
            return {s: fps[s] for s in subset if s in fps}
        return f

    def test_no_rerun_when_nothing_changed(self):
        C, changed, noise, reran = train.denoise({'g': fp()}, {'g': fp()}, self.BASE, {}, self.rerun({}))
        self.assertIsNone(self.asked)
        self.assertEqual((changed, noise, reran), ({}, {}, []))

    def test_noisy_cell_excluded_real_change_kept(self):
        # the second reference reading dingbat's save plays live: its cell
        # moves on base too; the audio change is the candidate's
        base = {'g': fp(), 'h': fp()}
        comb = {'g': fp(audio='au1', load_hash={'*': 'ld0', 'dingbat': 'ld5'}), 'h': fp()}
        again = {'g': fp(load_hash={'*': 'ld0', 'dingbat': 'ld6'})}
        C, changed, noise, reran = train.denoise(base, comb, self.BASE, {}, self.rerun(again))
        self.assertEqual(self.asked, ['g'])     # only the changed game is replayed
        self.assertEqual(list(noise['g']), ['dingbat'])
        self.assertEqual(list(noise['g']['dingbat']), ['load:dingbat-in-mgba'])
        self.assertEqual(noise['g']['dingbat']['load:dingbat-in-mgba']['how'], 'rerun')
        self.assertEqual(set(changed['g']), set(CONFIGS))
        self.assertNotIn('load:dingbat-in-mgba', changed['g']['dingbat'])
        self.assertIn('audio', changed['g']['dingbat'])
        self.assertEqual(train.classify(base['g'], C['g'])['kind'], 'neutral')

    def test_change_that_is_only_noise_drops_out(self):
        comb = {'g': fp(load_hash='ld9')}
        C, changed, noise, reran = train.denoise({'g': fp()}, comb, self.BASE, {}, self.rerun({'g': fp(load_hash='ld7')}))
        self.assertEqual(changed, {})
        self.assertEqual(set(noise['g']), set(CONFIGS))
        # nothing left for the candidates: attribution sees no change
        cells = {cfg: list(d) for cfg, d in noise['g'].items()}
        att = train.attribute({'g': fp()}, C, {'A': {'g': train.mask(comb['g'], fp(), cells)}})
        self.assertEqual(att['effects']['A'], {})

    def test_ocr_only_flip_reproduced_by_base_is_noise(self):
        # the baseline's OCR came back empty: FAIL with every hash the same
        flaky = fp(passed={'*': True, 'dingbat-bios': False}, status='FAIL')
        C, changed, noise, reran = train.denoise({'g': flaky}, {'g': fp()}, self.BASE, {}, self.rerun({'g': fp()}))
        self.assertEqual(changed, {})
        self.assertEqual(sorted(noise['g']), ['*', 'dingbat-bios'])
        self.assertEqual(train.ocr_only(noise['g']), ['dingbat-bios'])
        text = train.describe_noise(noise['g'])
        self.assertIn('FAIL->PASS', text)

    def test_ocr_only_flip_not_reproduced_is_kept(self):
        flaky = fp(passed={'*': True, 'dingbat-bios': False}, status='FAIL')
        C, changed, noise, reran = train.denoise({'g': fp()}, {'g': flaky}, self.BASE, {}, self.rerun({'g': fp()}))
        self.assertEqual(noise, {})
        self.assertEqual(train.classify(fp(), C['g'])['kind'], 'regressed')

    def test_rerun_that_did_not_play_teaches_nothing(self):
        dead = train.fingerprint({'status': 'ERROR'})
        C, changed, noise, reran = train.denoise({'g': fp()}, {'g': fp(audio='x')}, self.BASE, {},
                                                 self.rerun({'g': dead}))
        self.assertEqual(noise, {})
        self.assertIn('g', changed)

    def test_ledger_written_read_and_accepted_on_the_same_base(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, 'noise.json')
            base, comb = {'g': fp()}, {'g': fp(load_hash='ld9')}
            _, _, noise, _ = train.denoise(base, comb, self.BASE, {}, self.rerun({'g': fp(load_hash='ld9')}))
            fresh = {}      # what the train reads from a missing noise.json
            train.update_ledger(fresh, noise, self.BASE, {'g': 'Game'}, now='t1')
            train.write_json(p, fresh)
            ledger = train.read_json(p)
            cell = ledger['cells']['g dingbat load:dingbat-in-mgba']
            self.assertEqual((cell['seen'], cell['title'], cell['last_seen']), (1, 'Game', 't1'))
            self.assertEqual(len(cell['examples']), 2)
            self.assertEqual(len(train.chronic(ledger)), 4)
            # the next train on the same base: the combined value base already
            # produced is unchanged without a rerun
            C, changed, noise2, reran = train.denoise(base, comb, self.BASE, ledger, self.rerun({}))
            self.assertIsNone(self.asked)
            self.assertEqual(changed, {})
            self.assertEqual({e['how'] for e in noise2['g'].values() for e in e.values()}, {'known'})
            ledger = train.update_ledger(ledger, noise2, self.BASE, {'g': 'Game'}, now='t2')
            self.assertEqual(ledger['cells']['g dingbat load:dingbat-in-mgba']['seen'], 2)
            # on another base the value is only informative: rerun, and a
            # surviving change is flagged as a known noisy cell
            C, changed, noise3, reran = train.denoise(base, comb, 'c' * 40, ledger, self.rerun({'g': fp()}))
            self.assertEqual(self.asked, ['g'])
            self.assertIn('g', changed)
            self.assertIn('dingbat load:dingbat-in-mgba (noise seen 2x)', train.known_noisy(ledger, 'g', changed['g']))


    def test_report_lists_noise(self):
        flaky = fp(passed={'*': True, 'dingbat-bios': False}, status='FAIL')
        _, _, noise, _ = train.denoise({'g': flaky}, {'g': fp()}, self.BASE, {}, self.rerun({'g': fp()}))
        g = {'sha1': 'g' * 40, 'title': 'Kart', 'what': train.describe_noise(noise['g']), 'how': ['rerun'],
             'ocr_only': train.ocr_only(noise['g'])}
        car = [{'id': 'x', 'name': 'cand', 'sha': 'a' * 40}]
        run = {'id': 'r', 'base': self.BASE, 'verdicts': {'x': {'status': 'clean', 'noise': [g]}}}
        with tempfile.TemporaryDirectory() as d:
            home, train.HOME = train.HOME, d
            try:
                text = train.render_report(run, car)
            finally:
                train.HOME = home
        self.assertIn('## Noise (not attributed)', text)
        self.assertIn('Kart', text)
        self.assertIn('differs between two runs of the base (OCR only in dingbat-bios', text)


class Relevance(unittest.TestCase):
    def test_paths(self):
        self.assertTrue(train.relevant(['src/dingbat/gba/ppu.nim']))
        self.assertTrue(train.relevant(['tools/playtest/scripts/abc.play']))
        self.assertTrue(train.relevant(['docs/x.md', 'nim.cfg']))
        self.assertFalse(train.relevant(['docs/playtest-bugs.md', 'web/index.html', 'tools/romdiff.py']))
        self.assertFalse(train.relevant(['tools/playtest/README.md', 'tools/playtest/tests/test_train.py']))


class Suites(unittest.TestCase):
    def test_load_suite_reads_windows_from_phase_results(self):
        with tempfile.TemporaryDirectory() as d:
            od = os.path.join(d, 'run')
            res = results()
            os.makedirs(os.path.join(od, 'new', 'dingbat'))
            dump(res, os.path.join(od, 'results.json'))
            side = copy.deepcopy(res['new']['dingbat'])
            side['checkpoints']['title']['hashes'] = ['a', 'b', 'c']
            dump(side, os.path.join(od, 'new', 'dingbat', 'result.json'))
            dump({'games': [{'sha1': 'g', 'title': 'G', 'status': 'PASS', 'outdir': od},
                  {'sha1': 'h', 'title': 'H', 'status': 'ERROR', 'detail': 'boom'}]},
                 os.path.join(d, 'index.json'))
            got = train.load_suite(d)
            self.assertEqual(sorted(got), ['g', 'h'])
            self.assertIsNotNone(got['g'][1]['dingbat']['win:title'])
            self.assertIsNone(got['g'][1]['dingbat']['win:menu'])
            self.assertIsNone(got['g'][1]['dingbat-nowl']['win:title'])
            self.assertEqual(got['h'][1], {'*': {'status': 'ERROR'}})


class Replay(unittest.TestCase):
    def test_replayed_phase_moves_its_paths(self):
        import pipeline
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, 'old', 'new', 'mgba')
            os.makedirs(os.path.join(src, 'shots'))
            dump('P6', os.path.join(src, 'shots', 'title.ppm'))
            dump({'emu': 'mgba', 'ok': True, 'workdir': src, 'save': os.path.join(src, 'env', 'game.sav'),
                  'checkpoints': {'title': {'ppm': os.path.join(src, 'shots', 'title.ppm'), 'hashes': ['x']}}},
                 os.path.join(src, 'result.json'))
            dst = os.path.join(d, 'now', 'new', 'mgba')
            r = pipeline.replay_phase(src, dst, log=lambda m: None)
            self.assertEqual(r['checkpoints']['title']['ppm'], os.path.join(dst, 'shots', 'title.ppm'))
            self.assertTrue(os.path.exists(r['checkpoints']['title']['ppm']))
            self.assertEqual(r['save'], os.path.join(dst, 'env', 'game.sav'))
            self.assertEqual(r['replayed_from'], src)
            self.assertIsNone(pipeline.replay_phase(os.path.join(d, 'nothing'), dst, log=lambda m: None))

    def test_refs_source_needs_the_same_script(self):
        import pipeline
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, 'script.play'), 'w') as f:
                f.write('@title X\n')
            self.assertEqual(pipeline.refs_source(d, '@title X\n', log=lambda m: None), d)
            self.assertIsNone(pipeline.refs_source(d, '@title Y\n', log=lambda m: None))
            self.assertIsNone(pipeline.refs_source(None, '', log=lambda m: None))


if __name__ == '__main__':
    unittest.main()
