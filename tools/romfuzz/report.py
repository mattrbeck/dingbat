#!/usr/bin/env python3
"""Generate the cross-emulator difference report from sweep results.

Usage: report.py <workdir> <reportdir>
Reads <workdir>/results.json and run artifacts; writes:
  <reportdir>/report.md               summary tables + per-title sections
  <reportdir>/img/<slug>.f<N>.png     side-by-side mgba|nba|dingbat composites
  <reportdir>/states/<slug>.f<N>.state  dingbat save states at each checkpoint
Descriptions can be augmented via <workdir>/notes.json {slug: text}.
"""
import json, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import imgdiff

RANK = ['IDENTICAL', 'MINOR', 'DIFFERENT', 'MAJOR']

def composite(paths, out_png, labels):
    imgs = [imgdiff.read_ppm(p) for p in paths]
    w, h = imgs[0][0], imgs[0][1]
    gap = 6
    W = w * len(imgs) + gap * (len(imgs) - 1)
    H = h + 12
    canvas = bytearray(b'\x20' * (W * H * 3))
    for k, (iw, ih, pix) in enumerate(imgs):
        x0 = k * (w + gap)
        for y in range(ih):
            row = pix[y * iw * 3:(y + 1) * iw * 3]
            off = ((y + 12) * W + x0) * 3
            canvas[off:off + iw * 3] = row
    # label strips: tint the top bar per emulator so columns are identifiable
    tints = [(90, 140, 220), (90, 200, 120), (230, 160, 80)]
    for k in range(len(imgs)):
        x0 = k * (w + gap)
        r, g, b = tints[k % 3]
        for y in range(10):
            for x in range(x0, x0 + w):
                off = (y * W + x) * 3
                canvas[off:off + 3] = bytes((r, g, b))
    imgdiff.write_png(out_png, W, H, bytes(canvas))

def main():
    workdir, reportdir = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.join(reportdir, 'img'), exist_ok=True)
    os.makedirs(os.path.join(reportdir, 'states'), exist_ok=True)
    reg = os.path.join(workdir, 'results_regression.json')
    if os.path.exists(reg):
        results = json.load(open(reg))
    else:
        results = json.load(open(os.path.join(workdir, 'results.json')))
        for extra_name in ('results2_merged.json', 'results3.json'):
            extra = os.path.join(workdir, extra_name)
            if os.path.exists(extra):
                results += json.load(open(extra))
    notes = {}
    npath = os.path.join(workdir, 'notes.json')
    if os.path.exists(npath):
        notes = json.load(open(npath))

    for r in results:
        r['overall'] = 'ERROR' if r['error'] else max(
            (s['final'] for s in r['shots'].values()), key=RANK.index, default='?')
    order = {'ERROR': 0, 'MAJOR': 1, 'DIFFERENT': 2, 'MINOR': 3, 'IDENTICAL': 4, '?': 5}
    results.sort(key=lambda r: (order[r['overall']], r['title']))

    md = ['# dingbat cross-emulator compatibility sweep',
          '']
    fpath = os.path.join(workdir, 'findings.md')
    if os.path.exists(fpath):
        md += [open(fpath).read(), '']
    md += ['## Method',
          '',
          'Each title ran headless for 2000 frames in mGBA 0.10.5, NanoBoyAdvance,',
          'and dingbat (HLE BIOS + real BIOS), with an identical input script',
          '(START/A presses) and screenshots at frames 800/1200/1600/2000.',
          'A checkpoint passes if dingbat matches either reference directly or',
          'within a ±45-frame skew window (emulators accumulate lag frames',
          'differently, so fixed-frame captures drift).',
          '',
          'Composite images are mGBA (blue bar) | NBA (green bar) | dingbat (orange bar).',
          'Save states (dingbat format) for each checkpoint are in states/.',
          '', '## Summary', '',
          '| Title | Verdict | f800 | f1200 | f1600 | f2000 |',
          '|---|---|---|---|---|---|']
    for r in results:
        cells = [r['shots'].get(str(f), {}).get('final', '—') if not r['error'] else 'ERR'
                 for f in [800, 1200, 1600, 2000]]
        md.append(f"| {r['title']} | **{r['overall']}** | " + ' | '.join(cells) + ' |')

    md += ['', '## Titles with differences', '']
    for r in results:
        if r['overall'] in ('IDENTICAL', 'MINOR'):
            continue
        slug = r['slug']
        md.append(f"### {r['title']} — {r['overall']}")
        md.append('')
        if r['error']:
            md.append(f"Runner error: `{r['error']}`")
            md.append('')
            continue
        if slug in notes:
            md.append(notes[slug])
            md.append('')
        rundir = os.path.join(workdir, 'runs', slug)
        for f in [800, 1200, 1600, 2000]:
            s = r['shots'].get(str(f))
            if not s:
                continue
            paths = [os.path.join(rundir, e, f'{e}.f{f:04}.ppm')
                     for e in ('mgba', 'nba', 'dhle')]
            if not all(os.path.exists(p) for p in paths):
                continue
            img = f'img/{slug}.f{f:04}.png'
            composite(paths, os.path.join(reportdir, img), ['mgba', 'nba', 'dingbat'])
            st_src = os.path.join(rundir, 'dhle', f'dhle.f{f:04}.state')
            st = ''
            if os.path.exists(st_src):
                shutil.copy(st_src, os.path.join(reportdir, 'states', f'{slug}.f{f:04}.state'))
                st = f' — state: `states/{slug}.f{f:04}.state`'
            m = s['dhle_vs_mgba']
            md.append(f"**f{f}: {s['final']}** (vs mGBA: ncc={m['ncc']}, "
                      f"exact={m['exact']}, mae={m['mae']}){st}")
            md.append('')
            md.append(f'![{slug} f{f}]({img})')
            md.append('')

    minor = [r for r in results if r['overall'] == 'MINOR']
    if minor:
        md += ['## Minor-only titles', '']
        for r in minor:
            worst = max((s['final'] for s in r['shots'].values()), key=RANK.index)
            md.append(f"- {r['title']}: all checkpoints matched a reference "
                      f"(worst {worst})")
    with open(os.path.join(reportdir, 'report.md'), 'w') as f:
        f.write('\n'.join(md) + '\n')
    print('wrote', os.path.join(reportdir, 'report.md'))

if __name__ == '__main__':
    main()
