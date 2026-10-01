#!/usr/bin/env python3
"""Cross-emulator differences from a suite run, as findings.

  report.py SUITE_DIR [--judgements FILE] [--html OUT_DIR]

Reads SUITE_DIR/index.json (playtest.py suite) and every game's
results.json, and writes SUITE_DIR/findings.json: one finding per distinct
disagreement, each naming who stands alone.

  video     at a checkpoint the emulators fall into groups that render the
            same screen (single linkage over IDENTICAL/SLIP/MINOR); a finding
            is a grouping, reported at the first checkpoint it appears and
            counted while it persists
  audio     a dingbat configuration differs from both references where they
            agree, or one reference differs where dingbat agrees with the other
  save      dingbat's battery file or cross-load problems; references that
            fail to read a save
  run       an emulator that did not complete the script (crash, hang)

`suspect` is who the evidence points at: `dingbat` (every configuration),
`dingbat:hle-bios` / `dingbat:official-bios` / `dingbat:waitloop` /
`dingbat:no-waitloop` / `dingbat:<names>` (only some configurations),
`mgba`, `nba`, or `unclear`. With --html, a page plus the images it needs.
--judgements merges an evaluator's verdicts ({finding id: {...}}).
"""
import argparse
import html
import json
import os
import shutil

DINGBAT = ['dingbat', 'dingbat-nowl', 'dingbat-bios', 'dingbat-bios-nowl']
REFS = ['mgba', 'nba']
CONFIG_LABEL = {
    'dingbat': 'HLE BIOS, waitloop on (shipped default)',
    'dingbat-nowl': 'HLE BIOS, waitloop off',
    'dingbat-bios': 'official BIOS, waitloop on',
    'dingbat-bios-nowl': 'official BIOS, waitloop off',
    'mgba': 'mGBA 0.10.5, official BIOS',
    'nba': 'second reference, official BIOS',
}


def suspect_of(odd):
    """Who a group that stands alone implicates."""
    s = set(odd)
    if s == set(DINGBAT):
        return 'dingbat'
    if s <= set(DINGBAT):
        if s == {'dingbat', 'dingbat-nowl'}:
            return 'dingbat:hle-bios'
        if s == {'dingbat-bios', 'dingbat-bios-nowl'}:
            return 'dingbat:official-bios'
        if s == {'dingbat', 'dingbat-bios'}:
            return 'dingbat:waitloop'
        if s == {'dingbat-nowl', 'dingbat-bios-nowl'}:
            return 'dingbat:no-waitloop'
        return 'dingbat:' + '+'.join(sorted(s, key=DINGBAT.index))
    if s == {'mgba'}:
        return 'mgba'
    if s == {'nba'}:
        return 'nba'
    return 'unclear'


def odd_group(clusters):
    """The group standing alone, or None when it is not one group against
    the rest (three-way splits)."""
    if len(clusters) < 2:
        return None
    if len(clusters) == 2:
        a, b = clusters
        # the side holding both references is the majority view
        if set(REFS) <= set(a):
            return b
        if set(REFS) <= set(b):
            return a
        # references split: the lone reference stands alone if every dingbat
        # configuration sided with the other one
        for r in REFS:
            for g, h in ((a, b), (b, a)):
                if g == [r] and set(DINGBAT) <= set(h):
                    return g
        return None
    # three or more groups: one reference alone and everything else together
    # but split only among dingbat configurations -> still unclear
    return None


def game_findings(game, rep, base):
    out = []
    title = rep['meta'].get('title', rep['rom_info']['title'])
    gid = rep['sha1'][:8]
    emus = rep['emulators']

    def add(kind, suspect, summary, **kw):
        f = {'id': f'{gid}-{len(out) + 1:02}', 'game': title, 'sha1': rep['sha1'], 'kind': kind,
             'suspect': suspect, 'summary': summary, 'run': base}
        f.update(kw)
        out.append(f)

    # run failures
    failed = [n for n in emus if not rep['new'][n]['ok']]
    if failed and len(failed) < len(emus):
        add('run', suspect_of(failed) if suspect_of(failed) != 'unclear' else 'unclear',
            f"{', '.join(failed)} did not complete [new]",
            details={n: rep['new'][n]['error'] for n in failed},
            images=[os.path.join(base, 'new', n, 'shots', 'FAILED.png') for n in failed
                    if os.path.exists(os.path.join(base, 'new', n, 'shots', 'FAILED.png'))])

    # video: distinct groupings
    seen = {}
    for cp, e in rep['new_checkpoints'].items():
        clusters = e.get('clusters')
        if not clusters or len(clusters) < 2:
            continue
        key = json.dumps(clusters)
        if key in seen:
            seen[key]['persists'].append(cp)
            continue
        odd = odd_group(clusters)
        suspect = suspect_of(odd) if odd else 'unclear'
        frames = e.get('frames', {})
        detail = {k: {kk: vv for kk, vv in p.items() if kk in ('verdict', 'offset', 'similarity', 'diff_pixels',
                                                                  'mae', 'max_channel_delta', 'why')}
                  for k, p in e['pairs'].items() if p['verdict'] not in ('IDENTICAL',)}
        add('video', suspect,
            f"checkpoint {cp}: " + ' | '.join('+'.join(g) for g in clusters),
            checkpoint=cp, frame=next((f for f in frames.values() if f is not None), None),
            clusters=clusters, odd=odd, persists=[], pairs=detail,
            text={n: (t or '')[:160] for n, t in (e.get('text') or {}).items()},
            images=[e['png']] if e.get('png') else [])
        seen[key] = out[-1]

    # audio
    au = rep.get('audio') or {}
    subj = au.get('subjects', {})
    bad = [s for s, r in subj.items() if r.get('status') == 'DIFFERENT']
    if bad:
        first = subj[bad[0]]
        run0 = (first.get('runs') or [{}])[0]
        add('audio', suspect_of(bad),
            f"audio differs from both references ({', '.join(bad)}): {first['flagged_fraction'] * 100:.1f}% of "
            f"the run, longest {first['longest_seconds']}s from f{run0.get('start_frame')} ({run0.get('kind')})",
            audio={s: {k: v for k, v in subj[s].items() if k != 'vs'} for s in bad},
            clips=first.get('clips', {}))
    for r, res in (au.get('refs') or {}).get('odd', {}).items():
        if res.get('status') == 'DIFFERENT':
            run0 = (res.get('runs') or [{}])[0]
            add('audio', r,
                f"{r} audio differs where the other reference and dingbat agree: {res['flagged_fraction'] * 100:.1f}% "
                f"of the run, longest {res['longest_seconds']}s from f{run0.get('start_frame')} ({run0.get('kind')})",
                audio=res, clips=res.get('clips', {}))

    # saves and cross-load: dingbat's problems, grouped by text across configs
    probs = {}
    for s, v in rep['verdicts'].items():
        for p in v['problems']:
            if p.startswith('checkpoint ') or p.startswith('audio ') or p.startswith('[new] did not'):
                continue
            norm = p
            for d in sorted(DINGBAT, key=len, reverse=True):
                norm = norm.replace(d, 'DINGBAT')
            probs.setdefault(norm, []).append((s, p))
    for norm, hits in probs.items():
        who = [s for s, _ in hits]
        add('save', suspect_of(who), hits[0][1], configs=who)
    # references failing to read saves
    for key, cell in (rep.get('load') or {}).items():
        w, r = key.split('-in-')
        if r in REFS and not cell['ok'] and w not in DINGBAT[1:]:
            add('save', r, f'{r} could not complete [load] with the {w} save: {cell["error"]}', cell=key)
    for k, p in rep.get('save_pairs', {}).items():
        a, b = k.split('~')
        if {a, b} == set(REFS) and not p.get('same_size'):
            mine = (rep['saves'].get('dingbat') or {}).get('size')
            odd = b if mine == rep['saves'][a]['size'] else a if mine == rep['saves'][b]['size'] else None
            add('save', odd or 'unclear', f"the references write different save sizes: "
                f"{a} {rep['saves'][a]['size']} bytes, {b} {rep['saves'][b]['size']} bytes, dingbat {mine} "
                f"(chip sizes {rep['rom_info'].get('canonical_sizes')})", pair=k)
    return out


def collect(suite_dir):
    index = json.load(open(os.path.join(suite_dir, 'index.json')))
    findings, games = [], []
    for g in index['games']:
        row = {'title': g['title'], 'sha1': g['sha1'], 'status': g['status']}
        if g.get('outdir') and os.path.exists(os.path.join(g['outdir'], 'results.json')):
            rep = json.load(open(os.path.join(g['outdir'], 'results.json')))
            fs = game_findings(g, rep, g['outdir'])
            findings += fs
            row.update(outdir=g['outdir'], findings=[f['id'] for f in fs],
                       verdicts={s: v['pass'] for s, v in rep['verdicts'].items()},
                       new_ok={n: r['ok'] for n, r in rep['new'].items()},
                       checkpoints=len(rep['new_checkpoints']),
                       save=('skip' if rep.get('save_skipped') else 'none' if rep.get('no_save') else 'yes'),
                       audio_refs=(rep.get('audio') or {}).get('refs', {}).get('differ'))
        games.append(row)
    return {'suite': index.get('tag'), 'emulators': index.get('emus'), 'games': games, 'findings': findings}


def write_html(data, outdir, judgements=None):
    """A self-contained page plus images/ and audio/ beside it."""
    os.makedirs(os.path.join(outdir, 'img'), exist_ok=True)
    os.makedirs(os.path.join(outdir, 'audio'), exist_ok=True)
    e = html.escape
    judgements = judgements or {}

    def asset(path, sub):
        if not path or not os.path.exists(path):
            return None
        name = f"{abs(hash(path)) % 10**10:010d}-{os.path.basename(path)}"
        shutil.copyfile(path, os.path.join(outdir, sub, name))
        return f'{sub}/{name}'

    order = ['dingbat', 'dingbat:hle-bios', 'dingbat:official-bios', 'dingbat:waitloop', 'dingbat:no-waitloop']
    groups = {}
    for f in data['findings']:
        groups.setdefault(f['suspect'], []).append(f)
    keys = [k for k in order if k in groups] + sorted(k for k in groups if k.startswith('dingbat:') and k not in order) \
        + [k for k in ('mgba', 'nba', 'unclear') if k in groups]
    label = {'dingbat': 'dingbat, every configuration', 'dingbat:hle-bios': 'dingbat with the HLE BIOS only',
             'dingbat:official-bios': 'dingbat with the official BIOS only',
             'dingbat:waitloop': 'dingbat with waitloop skipping only',
             'dingbat:no-waitloop': 'dingbat with waitloop skipping off only',
             'mgba': 'mGBA alone', 'nba': 'the second reference alone', 'unclear': 'no single odd one out'}
    parts = []
    parts.append('<h2>Games</h2><table class=games><tr><th>game</th><th>save</th><th>checkpoints</th>'
                 + ''.join(f'<th>{e(n)}</th>' for n in DINGBAT) + '<th>findings</th></tr>')
    for g in data['games']:
        cells = ''.join(f"<td class={'ok' if g.get('verdicts', {}).get(n) else 'bad'}>"
                        f"{'pass' if g.get('verdicts', {}).get(n) else 'FAIL' if 'verdicts' in g else '-'}</td>"
                        for n in DINGBAT)
        parts.append(f"<tr><td>{e(g['title'])}</td><td>{e(g.get('save', '-'))}</td><td>{g.get('checkpoints', '-')}</td>"
                     f"{cells}<td>{' '.join(f'<a href=#{i}>{i[-2:]}</a>' for i in g.get('findings', []))}</td></tr>")
    parts.append('</table>')
    for k in keys:
        parts.append(f'<h2 id="s-{e(k)}">{e(label.get(k, k))} <span class=n>{len(groups[k])}</span></h2>')
        for f in groups[k]:
            j = judgements.get(f['id'])
            parts.append(f"<div class=card id={f['id']}><div class=h><b>{e(f['game'])}</b> "
                         f"<span class=k>{f['kind']}</span> <span class=id>{f['id']}</span></div>"
                         f"<p>{e(f['summary'])}</p>")
            if f.get('persists'):
                parts.append(f"<p class=m>same grouping at {len(f['persists'])} later checkpoint(s): "
                             f"{e(', '.join(f['persists']))}</p>")
            if f.get('details'):
                parts.append('<pre>' + e(json.dumps(f['details'], indent=1)[:1500]) + '</pre>')
            for im in f.get('images', []):
                a = asset(im, 'img')
                if a:
                    parts.append(f"<img loading=lazy src='{a}' alt='{e(f['summary'])}'>")
            for n, clip in (f.get('clips') or {}).items():
                a = asset(clip, 'audio')
                if a:
                    parts.append(f"<div class=clip>{e(n)} <audio controls preload=none src='{a}'></audio></div>")
            if j:
                parts.append(f"<div class=judge><b>Evaluator:</b> likely wrong: <b>{e(str(j.get('likely_wrong')))}</b> "
                             f"({e(str(j.get('confidence')))}) &mdash; {e(j.get('reasoning', ''))}"
                             + (f"<br><b>Report upstream:</b> {e(j['report'])}" if j.get('report') else '') + '</div>')
            parts.append('</div>')
    return parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('suite_dir')
    ap.add_argument('--judgements')
    ap.add_argument('--html')
    args = ap.parse_args()
    data = collect(args.suite_dir)
    json.dump(data, open(os.path.join(args.suite_dir, 'findings.json'), 'w'), indent=1)
    by = {}
    for f in data['findings']:
        by[f['suspect']] = by.get(f['suspect'], 0) + 1
    print(f"{len(data['games'])} games, {len(data['findings'])} findings: {by}")
    if args.html:
        j = json.load(open(args.judgements)) if args.judgements else None
        parts = write_html(data, args.html, j)
        open(os.path.join(args.html, 'body.html'), 'w').write('\n'.join(parts))
        print(f'html fragments in {args.html}')


if __name__ == '__main__':
    main()
