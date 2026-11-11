#!/usr/bin/env python3
"""Every difference a playtest suite found, qualified for triage.

    divergences.py SUITE_DIR [--prev SUITE_DIR] [-o divergences.json] [--subject dingbat]

Reads a suite's index.json and each game's results.json and lists, per game,
every place where the subject (dingbat) and the two references part:

  frame       a [new] checkpoint (the script's own play-through)
  load        a [load] checkpoint: the same writer's save, read by each emulator
  save        the battery file each emulator wrote at the end of [new]
  crossload   the harness's own cross-load problems (a save not read, a reader
              showing it differently from the references reading it)
  harness     any other problem the harness failed the subject on (waitloop
              skipping changing the run, audio, a script that did not play)

Each item gets a quick qualifier: who stands alone, how big the difference
is (a frame slip, a palette drift, the same layout with other details, a
different screen, a checkpoint never reached), whether the subject comes back
into agreement later in the run or the difference reaches the save, and
whether a script's @known entry already covers it. From that, a tier:

  S1  act      the subject fails, or its saves do not round-trip, or it shows
               another screen than two agreeing references and stays apart
  S2  chase    the subject alone against agreeing references with a different
               screen, or a slip that never recovers, or a save body far from
               two identical references' saves
  S3  watch    the subject alone but transient (a slip or detail it recovers
               from), or saves whose bytes differ but load the same everywhere
  S4  noted    covered by @known, or no consensus (all three differ) with the
               subject between the references
  R   reference  one reference alone; the subject agrees with the other

--prev SUITE_DIR adds `since`: new, or how the item looked in that suite.
"""
import argparse, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pipeline  # noqa: E402  (cell_ok, blank_state)

REFS = ('mgba', 'nba')
LABEL = {'mgba': 'mgba', 'nba': 'ref2'}
SAME = ('IDENTICAL', 'MINOR')
# how far apart two pictures are, least to most
RANK = {'IDENTICAL': 0, 'MINOR': 1, 'SLIP': 2, 'DIFFERENT': 3, 'MAJOR': 4, 'FAILED': 5, None: 0}


def same(v):
    return bool(v) and v.get('verdict') in SAME


def pattern(ds, dr, mr):
    """Who is odd one out, from the three pair verdicts (subject~mgba,
    subject~ref2, mgba~ref2)."""
    if None in (ds, dr, mr) or None in (ds.get('verdict'), dr.get('verdict'), mr.get('verdict')):
        return 'incomplete'
    s = (same(ds), same(dr), same(mr))
    return {(True, True, True): 'agree', (True, False, False): 'ref2 alone',
            (False, True, False): 'mgba alone', (False, False, True): 'dingbat alone',
            (False, False, False): 'all differ'}.get(s, 'inconsistent')


def size(v):
    """A pair verdict as one word plus a number for sorting."""
    if not v:
        return ('?', 0)
    k = v.get('verdict')
    if k == 'SLIP':
        if v.get('field_phase'):
            return (f"fields {v['field_phase']:+d}", 2)
        return (f"slip {v.get('offset', 0):+d}", 2 + min(abs(v.get('offset', 0)), 30) / 100)
    if k == 'MINOR':
        return ('drift', 1)
    if k in ('DIFFERENT', 'MAJOR'):
        box = v.get('diff_box') or [0, 0, 240, 160]
        area = max(0, box[2] - box[0]) * max(0, box[3] - box[1]) / (240 * 160)
        word = 'details' if k == 'DIFFERENT' else 'screen'
        if v.get('why') == 'one screen is blank':
            word, area = 'blank', 1.0
        elif v.get('why', '').startswith('compared by on-screen text'):
            word, area = 'text', 1.0
        # DIFFERENT (same layout, other details) 2.5-3.5, MAJOR (another
        # screen) 3.5-4.5, each by the share of the screen that changed
        return (f"{word} {round(area * 100)}%", (2.5 if k == 'DIFFERENT' else 3.5) + area)
    if k == 'FAILED':
        return ('not reached', 5)
    return (k.lower() if k else '?', RANK.get(k, 0))


def closest(a, b):
    """The smaller of two differences (the subject's nearest reference)."""
    return a if size(a)[1] <= size(b)[1] else b


def load_json(p):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def frame_items(game, r, s, kind):
    """Items for [new] checkpoints (kind 'frame') or each writer's [load] row
    (kind 'load'), grouped by (phase, pattern)."""
    rows = []   # (phase, cp, frame, ds, dr, mr, png)
    if kind == 'frame':
        for cp, e in (r.get('new_checkpoints') or {}).items():
            if not isinstance(e, dict) or 'pairs' not in e:
                continue
            p = e['pairs']
            rows.append(('new', cp, (e.get('frames') or {}).get(s), p.get(f'{s}~mgba'), p.get(f'{s}~nba'),
                         p.get('mgba~nba'), e.get('png')))
    else:
        lc = r.get('load_checkpoints') or {}
        for w in (s,) + REFS:
            if f'{w}-in-{s}' not in lc:
                continue
            for cp, c in lc[f'{w}-in-{s}'].items():
                vs = c.get('vs') or {}
                if not c.get('reached'):
                    ds = dr = {'verdict': 'FAILED'}
                else:
                    ds, dr = vs.get('mgba'), vs.get('nba')
                mr = ((lc.get(f'{w}-in-mgba') or {}).get(cp) or {}).get('vs', {}).get('nba')
                cell = (r.get('load') or {}).get(f'{w}-in-{s}') or {}
                rows.append((f'load:{LABEL.get(w, w)} save', cp, (cell.get('checkpoints', {}).get(cp) or {}).get('frame'),
                             ds, dr, mr, None))
    # the order checkpoints happen in, per phase
    out = {}
    order = {}
    for i, (ph, cp, fr, ds, dr, mr, png) in enumerate(rows):
        pat = pattern(ds, dr, mr)
        order.setdefault(ph, []).append((i, cp, pat))
        if pat in ('agree', 'incomplete'):
            continue
        key = (ph, pat)
        it = out.setdefault(key, {'phase': ph, 'pattern': pat, 'cps': []})
        it['cps'].append({'cp': cp, 'frame': fr, 'vs_mgba': size(ds)[0], 'vs_ref2': size(dr)[0],
                          'refs': size(mr)[0], 'd': [v.get('verdict') if v else None for v in (ds, dr, mr)],
                          'png': png, '_ds': ds, '_dr': dr, '_mr': mr, '_i': i})
    for (ph, pat), it in out.items():
        seq = order[ph]
        last_bad = max(c['_i'] for c in it['cps'])
        # does the subject agree with both references again after this?
        later = [p for (i, _, p) in seq if i > last_bad]
        it['recovers'] = 'agree' in later
        it['at_end'] = not later
        it['of'] = len(seq)
    items = list(out.values())
    if kind == 'load':
        # one save, three readers: the same difference shows up for each
        # writer's save; one item per pattern, naming the writers
        merged = {}
        for it in items:
            m = merged.setdefault(it['pattern'], {'phase': 'load', 'pattern': it['pattern'], 'cps': [],
                                                  'writers': [], 'recovers': True, 'at_end': False, 'of': 0})
            w = it['phase'].split(':')[1].split()[0]
            m['writers'].append(w)
            for c in it['cps']:
                c['writer'] = w
            m['cps'] += it['cps']
            m['recovers'] = m['recovers'] and it['recovers']
            m['at_end'] = m['at_end'] or it['at_end']
            m['of'] = max(m['of'], it['of'])
        items = list(merged.values())
    return items


def qualify_frames(it, known, game_status):
    """Severity for one group of checkpoints (one phase, one pattern)."""
    pat = it['pattern']
    if pat == 'dingbat alone':
        worst = max(it['cps'], key=lambda c: size(closest(c['_ds'], c['_dr']))[1])
        mag = size(closest(worst['_ds'], worst['_dr']))
    elif pat == 'all differ':
        worst = max(it['cps'], key=lambda c: size(closest(c['_ds'], c['_dr']))[1])
        mag = size(closest(worst['_ds'], worst['_dr']))
    else:
        worst = max(it['cps'], key=lambda c: size(c['_mr'])[1])
        mag = size(worst['_mr'])
    it['worst'] = {'cp': worst['cp'], 'size': mag[0], 'png': worst.get('png')}
    n = len({c['cp'] for c in it['cps']})
    # lasting: no later checkpoint agrees again, and there is evidence it
    # carries on (more than one checkpoint, or later ones that still differ);
    # one difference at the script's last checkpoint has nothing after it
    lasting = not it['recovers'] and (n > 1 or not it['at_end'])
    tail = ('and never agrees again' if lasting else
            'at the last checkpoint (nothing after it to tell)' if it['at_end'] and not it['recovers'] else
            'then agrees again')
    if pat in ('mgba alone', 'ref2 alone'):
        it['sev'] = 'R'
        it['why'] = f"{pat.split()[0]} is the odd one out ({mag[0]}); dingbat agrees with the other reference"
    elif pat == 'inconsistent':
        it['sev'] = 'S4'
        it['why'] = 'non-transitive (each pair judged alone); no reading'
    elif pat == 'all differ':
        # between the references: each of the subject's pairs no worse than theirs
        between = all(max(size(c["_ds"])[1], size(c["_dr"])[1]) <= size(c["_mr"])[1] + 0.05 for c in it['cps'])
        if between:
            it['sev'] = 'S4'
            it['why'] = f'no consensus: the references are as far apart as dingbat is from either ({mag[0]} nearest)'
        else:
            it['sev'] = 'S3' if mag[1] < 3 or not lasting else 'S2'
            it['why'] = f'no consensus, but dingbat is furthest out ({mag[0]} from its nearest reference), {tail}'
    else:   # dingbat alone
        if mag[1] >= 5:
            it['sev'] = 'S1'
            it['why'] = f'dingbat never reaches the checkpoint the references reach'
        elif mag[1] >= 4 and lasting:
            it['sev'] = 'S1'
            it['why'] = f'another screen than two agreeing references ({mag[0]}), {tail}'
        elif mag[1] >= 3 or (mag[1] >= 2 and lasting):
            it['sev'] = 'S2'
            it['why'] = f'dingbat alone ({mag[0]} from its nearest reference), {tail}'
        else:
            it['sev'] = 'S3'
            it['why'] = f'dingbat alone, {mag[0]}, {tail}'
    if known and it['sev'] in ('S1', 'S2', 'S3'):
        it['sev'] = 'S4' if game_status == 'KNOWN' else it['sev']
        it['why'] += '; @known covers the game'
    for c in it['cps']:
        for k in ('_ds', '_dr', '_mr', '_i'):
            c.pop(k, None)
    return it


def save_items(r, s):
    saves = r.get('saves') or {}
    if r.get('no_save') or r.get('save_skipped') or s not in saves:
        return []
    groups = r.get('save_groups') or []
    gof = {n: i for i, g in enumerate(groups) for n in g}
    if all(gof.get(x) == gof.get(s) for x in REFS if x in gof):
        return []
    pairs = r.get('save_pairs') or {}

    def pair(a, b):
        return pairs.get(f'{a}~{b}') or pairs.get(f'{b}~{a}') or {}
    m_r = gof.get('mgba') is not None and gof.get('mgba') == gof.get('nba')
    with_ = [x for x in REFS if gof.get(x) == gof.get(s)]
    if m_r:
        pat = 'dingbat alone'
    elif with_:
        pat = f"{LABEL[[x for x in REFS if x not in with_][0]]} alone"
    else:
        pat = 'all differ'
    sv = saves[s]
    diffs = {}
    for x in REFS:
        p = pair(s, x)
        if not p:
            continue
        diffs[LABEL[x]] = {'same_size': p.get('same_size'), 'sizes': p.get('sizes'),
                           'body_same': p.get('chip_body_identical'),
                           'bytes': (p.get('diff') or {}).get('bytes'), 'ranges': (p.get('diff') or {}).get('count'),
                           'decoded_same': p.get('decoded_equivalent')}
    # does the save load the same everywhere? the subject's save in each
    # reference against the subject reading it, and each reference's save in
    # the subject against that reference reading it
    lc = r.get('load_checkpoints') or {}
    read_ok, read_bad = [], []
    for x in REFS:
        for key, other in ((f'{s}-in-{x}', s), (f'{x}-in-{s}', x)):
            for cp, c in (lc.get(key) or {}).items():
                v = (c.get('vs') or {}).get(other)
                if not c.get('reached') or (v and not pipeline.cell_ok(v)):
                    read_bad.append(f'{key.replace("nba", "ref2")}:{cp}')
                elif v:
                    read_ok.append(key)
    it = {'phase': 'save', 'pattern': pat, 'size': sv.get('size'), 'vs': diffs,
          'loads_same': not read_bad, 'load_misses': read_bad[:6]}
    def dist(d):
        if d.get('body_same'):
            return 0
        # bytes apart in the chip data (a trailer, an RTC block, on one side
        # only is the container's, not the data's)
        return d['bytes'] if d.get('bytes') is not None else 1 << 30
    near = min(diffs.values(), key=dist, default=None)
    nb = dist(near) if near else 0
    tot = sv.get('size') or 1
    rng = (near or {}).get('ranges')
    it['nearest_bytes'] = None if nb == 1 << 30 else nb
    if pat.endswith('alone') and not pat.startswith('dingbat'):
        it['sev'] = 'R'
        it['why'] = f"{pat.split()[0]} wrote another file; dingbat's matches the other reference"
    elif near and near.get('body_same'):
        it['sev'] = 'S4'
        it['why'] = 'the chip data is the same as a reference\'s; only the file around it (size, trailer) differs'
    elif near and near.get('decoded_same'):
        it['sev'] = 'S4'
        it['why'] = 'bytes differ, the decoded save is the same'
    elif nb == 1 << 30:
        it['sev'] = 'S1' if pat == 'dingbat alone' else 'S2'
        it['why'] = f"a {sv.get('size')}-byte file whose chip data matches no reference's ({near['sizes'][1]} bytes)"
    elif pat == 'dingbat alone':
        big = nb > max(256, tot // 8)
        it['sev'] = 'S2' if big or read_bad else 'S3'
        it['why'] = (f'{nb} of {tot} bytes in {rng} ranges differ from two identical reference saves'
                     + (f'; {len(read_bad)} cross-load cells show it differently (the harness calls them not diagnostic)'
                        if read_bad else '; every cross-load shows the same screens'))
    else:   # all differ
        it['sev'] = ('S2' if nb > 256 and read_bad else 'S3' if read_bad and nb > 32 else 'S4')
        it['why'] = (f'no consensus: {nb} bytes in {rng} ranges from the nearest reference'
                     + ('' if nb > 32 else ' (counter- or seed-sized)')
                     + (f'; {len(read_bad)} cross-load cells differ' if read_bad else '; loads the same'))
    return [it]


def harness_items(r, s, known):
    """The harness's own failures, for every configuration of the subject
    (dingbat, dingbat-nowl, dingbat-bios, ...); @known entries once."""
    out = []
    seen = set()
    for cfg, v in sorted((r.get('verdicts') or {}).items(), key=lambda kv: (kv[0] != s, kv[0])):
        if not cfg.startswith(s):
            continue
        for p in v.get('problems') or []:
            if p in seen:
                continue
            seen.add(p)
            kind = 'crossload' if ' save in ' in p or ' save:' in p else 'harness'
            out.append({'phase': kind, 'pattern': f'{cfg} fails', 'sev': 'S1', 'config': cfg,
                        'why': p.replace('nba', 'ref2')[:400]})
    for p in ((r.get('verdicts') or {}).get(s) or {}).get('known') or []:
        out.append({'phase': 'known', 'pattern': '@known', 'sev': 'S4', 'why': p.replace('nba', 'ref2')[:400]})
    return out


def game_items(g, s):
    if not g.get('outdir'):
        return [{'phase': 'harness', 'pattern': 'did not run', 'sev': 'S1', 'why': g.get('detail') or 'no output'}]
    r = load_json(os.path.join(g['outdir'], 'results.json'))
    if not r:
        return [{'phase': 'harness', 'pattern': 'did not run', 'sev': 'S1', 'why': 'no results.json'}]
    known = bool((r.get('verdicts') or {}).get(s, {}).get('known'))
    st = g.get('status')
    items = [qualify_frames(it, known, st) for it in frame_items(g, r, s, 'frame')]
    items += [qualify_frames(it, known, st) for it in frame_items(g, r, s, 'load')]
    items += save_items(r, s)
    items += harness_items(r, s, known)
    if st == 'KNOWN':
        for i in items:
            if i['phase'] == 'save' and i['sev'] in ('S1', 'S2', 'S3'):
                i['sev'] = 'S4'
                i['why'] += '; @known covers the game'
    # a frame difference that ends in a different save is lasting
    if any(i['phase'] == 'save' and i['pattern'] == 'dingbat alone' for i in items):
        for i in items:
            if i['phase'] == 'new' and i['pattern'] == 'dingbat alone' and i['sev'] == 'S3':
                i['sev'] = 'S2'
                i['why'] += '; the save differs from both references too'
    return items


def run(suite, s):
    idx = load_json(os.path.join(suite, 'index.json'))
    games = []
    for g in sorted(idx['games'], key=lambda g: g['title']):
        # SKIPPED: a script with no [new] play-through (nothing to compare)
        items = [] if g.get('status') == 'SKIPPED' else game_items(g, s)
        for i in items:
            i['id'] = f"{g['sha1'][:8]}/{i['phase']}/{i['pattern']}"
        games.append({'title': g['title'], 'sha1': g['sha1'], 'status': g.get('status'),
                      'report': os.path.join(g['outdir'], 'report.html') if g.get('outdir') else None,
                      'items': items})
    return games


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('suite')
    ap.add_argument('--prev')
    ap.add_argument('--subject', default='dingbat')
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    games = run(a.suite, a.subject)
    if a.prev:
        prev = {g['sha1']: {i['id']: i for i in g['items']} for g in run(a.prev, a.subject)}
        prev_title = {g['title']: g['sha1'] for g in run(a.prev, a.subject)}
        for g in games:
            p = prev.get(g['sha1'])
            if p is None and g['title'] in prev_title:
                p = prev[prev_title[g['title']]]
            for i in g['items']:
                key = i['id'].split('/', 1)[1]
                o = next((x for k, x in (p or {}).items() if k.split('/', 1)[1] == key), None)
                i['since'] = 'new game' if p is None else (o['sev'] if o else 'new')
            if p:
                now = {i['id'].split('/', 1)[1] for i in g['items']}
                g['gone'] = [dict(x, since='gone') for k, x in p.items() if k.split('/', 1)[1] not in now]
    out = {'suite': os.path.abspath(a.suite), 'prev': a.prev and os.path.abspath(a.prev), 'games': games}
    txt = json.dumps(out, indent=1)
    if a.out:
        with open(a.out, 'w') as f:
            f.write(txt)
    tally = {}
    for g in games:
        for i in g['items']:
            tally[(i['sev'], i['phase'].split(':')[0])] = tally.get((i['sev'], i['phase'].split(':')[0]), 0) + 1
    for k in sorted(tally):
        print(f'{k[0]:3} {k[1]:10} {tally[k]}')
    if not a.out:
        print(txt)


if __name__ == '__main__':
    main()
