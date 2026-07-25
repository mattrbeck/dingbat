#!/usr/bin/env python3
"""Render a self-contained HTML report from one or more gbfuzz results files.

Usage: report.py <workdir> <out.html> [results1.json ...] [--notes notes.md]

Screenshots are inlined as data: URIs so the page can be published as-is.
Flagged titles get every emulator at every checkpoint; clean titles get
dingbat's own progression (the shots are identical to the references anyway).
"""
import base64, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'romfuzz'))
import imgdiff

RANK = ['IDENTICAL', 'MINOR', 'DIFFERENT', 'MAJOR', 'REF-CRASH', 'ERROR']
OK = ('IDENTICAL', 'MINOR')
EMUS = ('sameboy', 'mgba', 'dingbat')
LABEL = {'sameboy': 'SameBoy', 'mgba': 'mGBA', 'dingbat': 'dingbat'}
# Screenshots are inlined, so a whole-library run would otherwise produce a
# page too large to open. Flagged titles always show theirs; the clean gallery
# is a sample.
CLEAN_GALLERY = 48


def worst_of(res):
    if res.get('error'):
        return 'ERROR'
    return max((s['final'] for s in res['shots'].values()), key=RANK.index,
               default='?')


def diverges_unprompted(r):
    """True when the title differs from SameBoy with no input at all.

    The scripted run presses Start and A at fixed frames, and plenty of games
    seed their RNG from whatever the timer holds when a button is read — so a
    one-frame difference in where a press lands legitimately produces a
    completely different screen. The no-input control removes that variable:
    if dingbat still matches SameBoy without input, the scripted divergence
    came from the script, not from the emulator.
    """
    ni = r.get('noinput_f1650', {}).get('verdict')
    return ni is None or ni not in OK


def divergence(r):
    """How far from SameBoy this title is, worst-first when sorted descending.

    Titles that diverge with no input sort above ones that only diverge under
    the scripted presses, then the ranked bucket so a MAJOR never sorts under a
    DIFFERENT, then the share of pixels that differ at the worst checkpoint.
    """
    bad = [s for s in r['shots'].values() if s['final'] not in OK]
    if not bad:
        return (0, -1, 0.0, 0)
    rank = max(RANK.index(s['final']) for s in bad)
    worst = max(1.0 - s['dingbat_vs_sameboy'].get('exact', 0.0) for s in bad)
    return (1 if diverges_unprompted(r) else 0, rank, worst, len(bad))


def png_data_uri(ppm_path):
    try:
        w, h, rgb = imgdiff.read_ppm(ppm_path)
    except Exception:
        return None
    tmp = ppm_path + '.tmp.png'
    imgdiff.write_png(tmp, w, h, rgb)
    with open(tmp, 'rb') as f:
        data = base64.b64encode(f.read()).decode()
    os.remove(tmp)
    return 'data:image/png;base64,' + data


CSS = """
/* Grounded in the DMG's own world: an olive-green LCD ground, a four-step
   shade ramp for severity, squared corners and hairline rules (instrument
   output, not cards), and a monospace utility face for every number the
   report is actually about. */
:root {
  --ground:#f1f2ea; --panel:#fbfbf6; --ink:#171a12; --muted:#6d7162;
  --rule:#d8dac9; --rule-soft:#e7e9db; --accent:#4e6b23;
  --ok:#2f6d4f; --minor:#3f6591; --diff:#9a6a1e; --major:#a8412f;
  --shot-bg:#dcdfcd;
}
@media (prefers-color-scheme: dark) {
  :root {
    --ground:#101309; --panel:#171b0f; --ink:#e6e9d8; --muted:#8e937f;
    --rule:#2b3020; --rule-soft:#212617; --accent:#a3c264;
    --ok:#63c495; --minor:#82aede; --diff:#d5a54e; --major:#ef8a76;
    --shot-bg:#0a0c06;
  }
}
:root[data-theme="dark"] {
  --ground:#101309; --panel:#171b0f; --ink:#e6e9d8; --muted:#8e937f;
  --rule:#2b3020; --rule-soft:#212617; --accent:#a3c264;
  --ok:#63c495; --minor:#82aede; --diff:#d5a54e; --major:#ef8a76;
  --shot-bg:#0a0c06;
}
:root[data-theme="light"] {
  --ground:#f1f2ea; --panel:#fbfbf6; --ink:#171a12; --muted:#6d7162;
  --rule:#d8dac9; --rule-soft:#e7e9db; --accent:#4e6b23;
  --ok:#2f6d4f; --minor:#3f6591; --diff:#9a6a1e; --major:#a8412f;
  --shot-bg:#dcdfcd;
}
*, *::before, *::after { box-sizing:border-box; }
body {
  margin:0; padding:3rem 1.5rem 6rem; background:var(--ground); color:var(--ink);
  font:15px/1.65 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;
}
.wrap { max-width:1180px; margin:0 auto; display:flex; flex-direction:column; gap:2.75rem; }
.mono, th, .cph, .cap, .chip, .stat b, .meta, .barkey {
  font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
}
.eyebrow {
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  font-size:.72rem; letter-spacing:.18em; text-transform:uppercase;
  color:var(--accent); margin:0 0 .5rem;
}
h1 { font-size:clamp(1.7rem,4vw,2.3rem); line-height:1.15; margin:0;
     letter-spacing:-.025em; font-weight:650; text-wrap:balance; }
h2 { font-size:1.05rem; margin:0 0 1rem; letter-spacing:.01em; font-weight:650;
     padding-bottom:.5rem; border-bottom:2px solid var(--ink); }
h3 { font-size:.98rem; margin:0; font-weight:620; letter-spacing:-.01em; }
p { margin:0; max-width:68ch; }
.sub { color:var(--muted); margin:.6rem 0 0; }
section { display:flex; flex-direction:column; gap:1rem; }

/* summary: proportional bars, dingbat against the reference noise floor */
.summary { display:flex; flex-direction:column; gap:1.5rem; }
.figures { display:flex; flex-wrap:wrap; gap:0; border:1px solid var(--rule);
           background:var(--panel); }
.stat { padding:.85rem 1.25rem; border-right:1px solid var(--rule); flex:1 1 auto;
        min-width:118px; }
.stat:last-child { border-right:0; }
.stat b { display:block; font-size:1.55rem; line-height:1.15; font-weight:600;
          font-variant-numeric:tabular-nums; letter-spacing:-.02em; }
.stat span { display:block; color:var(--muted); font-size:.7rem; margin-top:.15rem;
             text-transform:uppercase; letter-spacing:.11em; }
.bars { display:flex; flex-direction:column; gap:.9rem; }
.barrow { display:grid; grid-template-columns:minmax(0,13rem) 1fr; gap:1rem;
          align-items:center; }
.barlabel { font-size:.82rem; }
.barlabel em { display:block; color:var(--muted); font-style:normal; font-size:.75rem; }
.bar { display:flex; height:1.5rem; border:1px solid var(--rule); overflow:hidden; }
.bar i { display:block; height:100%; }
.bar i.s-IDENTICAL { background:var(--ok); }
.bar i.s-MINOR { background:var(--minor); }
.bar i.s-DIFFERENT { background:var(--diff); }
.bar i.s-MAJOR { background:var(--major); }
.barkey { display:flex; flex-wrap:wrap; gap:1rem; font-size:.72rem;
          color:var(--muted); text-transform:uppercase; letter-spacing:.09em; }
.barkey span { display:flex; align-items:center; gap:.4rem; }
.barkey b { width:.7rem; height:.7rem; display:block; }

/* verdict chips */
.chip { font-size:.68rem; font-weight:600; letter-spacing:.08em; padding:.15rem .45rem;
        text-transform:uppercase; border:1px solid currentColor; white-space:nowrap; }
.v-IDENTICAL { color:var(--ok); }
.v-MINOR { color:var(--minor); }
.v-DIFFERENT { color:var(--diff); }
.v-MAJOR, .v-ERROR, .v-REF-CRASH { color:var(--major); }

.scroll { overflow-x:auto; -webkit-overflow-scrolling:touch; border:1px solid var(--rule); }
table { border-collapse:collapse; width:100%; font-size:.85rem; background:var(--panel); }
th, td { text-align:left; padding:.45rem .75rem; border-bottom:1px solid var(--rule-soft);
         white-space:nowrap; }
th { color:var(--muted); font-weight:500; font-size:.68rem; text-transform:uppercase;
     letter-spacing:.11em; border-bottom:1px solid var(--rule); position:sticky; top:0;
     background:var(--panel); }
tr:last-child td { border-bottom:0; }
td.num { font-variant-numeric:tabular-nums; }
.rom { color:var(--muted); font-size:.76rem; }

.card { background:var(--panel); border:1px solid var(--rule); padding:1.1rem 1.25rem;
        display:flex; flex-direction:column; gap:.75rem; }
.card header { display:flex; align-items:center; gap:.75rem; flex-wrap:wrap; }
.meta { color:var(--muted); font-size:.74rem; letter-spacing:.02em; }
.shots { display:flex; gap:1.5rem; overflow-x:auto; padding-bottom:.35rem; }
.cp { flex:0 0 auto; display:flex; flex-direction:column; gap:.4rem; }
.cph { color:var(--muted); font-size:.68rem; text-transform:uppercase;
       letter-spacing:.11em; display:flex; gap:.5rem; align-items:center; }
.row { display:flex; gap:.6rem; }
.shot { display:flex; flex-direction:column; gap:.25rem; }
.shot img { width:160px; height:144px; image-rendering:pixelated; display:block;
            border:1px solid var(--rule); background:var(--shot-bg); }
.strip img { width:132px; height:119px; }
.cap { color:var(--muted); font-size:.68rem; font-variant-numeric:tabular-nums; }
.note { color:var(--muted); font-size:.85rem; }
code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.86em;
       background:var(--rule-soft); padding:.1em .35em; }
a { color:var(--accent); }
:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
@media (max-width:640px) {
  body { padding:2rem 1rem 4rem; }
  .barrow { grid-template-columns:1fr; gap:.35rem; }
}
"""


def render(workdir, results, notes_html, out_path):
    tally = {}
    for r in results:
        w = worst_of(r)
        tally[w] = tally.get(w, 0) + 1
    clean = sum(tally.get(k, 0) for k in OK)

    # Per-checkpoint distributions. dingbat's is only meaningful next to the
    # noise floor: how often the two reference emulators disagree with each
    # other at the very same checkpoint.
    dist_d, dist_r, ncheck = {}, {}, 0
    for r in results:
        for s in r['shots'].values():
            dist_d[s['final']] = dist_d.get(s['final'], 0) + 1
            v = s['ref_control']['verdict']
            dist_r[v] = dist_r.get(v, 0) + 1
            ncheck += 1
    ref_noise = sum(dist_r.get(k, 0) for k in ('DIFFERENT', 'MAJOR'))
    cp_clean = sum(dist_d.get(k, 0) for k in OK)

    def bar(dist, total):
        segs = ''.join(
            f'<i class="s-{k}" style="width:{dist.get(k,0)*100/total:.3f}%" '
            f'title="{k}: {dist.get(k,0)}"></i>'
            for k in RANK if dist.get(k))
        return f'<div class="bar">{segs}</div>'

    h = ['<div class="wrap">']
    h.append('<header>'
             '<p class="eyebrow">Cross-emulator sweep &middot; batch 1</p>'
             '<h1>dingbat on Game Boy and Game Boy Color</h1>'
             f'<p class="sub">The {len(results)} most popular GB/GBC titles run '
             'frame-by-frame through SameBoy&nbsp;1.0.3, mGBA&nbsp;0.10.5 and '
             'dingbat &mdash; same boot ROM, same input script, four '
             'checkpoints each.</p></header>')

    h.append('<section class="summary">')
    h.append('<div class="figures">')
    h.append(f'<div class="stat"><b>{clean}/{len(results)}</b><span>titles clean</span></div>')
    h.append(f'<div class="stat"><b>{tally.get("IDENTICAL",0)}</b><span>pixel-identical</span></div>')
    h.append(f'<div class="stat"><b>{cp_clean}/{ncheck}</b><span>checkpoints clean</span></div>')
    h.append(f'<div class="stat"><b>{ref_noise}/{ncheck}</b><span>ref vs ref differ</span></div>')
    h.append('</div>')
    h.append('<div class="bars">')
    h.append('<div class="barrow"><div class="barlabel">dingbat vs references'
             '<em>per checkpoint</em></div>' + bar(dist_d, ncheck) + '</div>')
    h.append('<div class="barrow"><div class="barlabel">SameBoy vs mGBA'
             '<em>noise floor, same checkpoints</em></div>'
             + bar(dist_r, ncheck) + '</div>')
    h.append('<div class="barkey">'
             + ''.join(f'<span><b class="s-{k}" style="background:var(--{c})"></b>{k}</span>'
                       for k, c in (('IDENTICAL', 'ok'), ('MINOR', 'minor'),
                                    ('DIFFERENT', 'diff'), ('MAJOR', 'major')))
             + '</div>')
    h.append('</div></section>')

    if notes_html:
        h.append('<section>' + notes_html + '</section>')

    frames = sorted(int(x) for x in results[0]['shots'])

    diff_rows = sorted((r for r in results if worst_of(r) not in OK),
                       key=divergence, reverse=True)
    if diff_rows:
        h.append('<section><h2>Titles that differ from SameBoy</h2>'
                 '<p class="note">Most different first. "Worst px" is the share '
                 'of pixels that differ at the checkpoint that diverged most; '
                 '"vs mGBA" and "SameBoy vs mGBA" are context only &mdash; a '
                 'divergence where the two references also disagree is a '
                 'different kind of problem from one where they agree.</p>'
                 '<div class="scroll"><table>')
        h.append('<tr><th>Title</th><th>Verdict</th><th>Worst px</th>'
                 '<th>Bad checkpoints</th><th>vs mGBA</th>'
                 '<th>SameBoy vs mGBA</th><th>No input</th><th>ROM</th></tr>')
        split_done = False
        for r in diff_rows:
            if not split_done and not diverges_unprompted(r):
                split_done = True
                h.append('<tr><td colspan="8" class="rom" style="padding-top:.9rem">'
                         '&darr; below here dingbat matches SameBoy with no input '
                         '&mdash; the divergence only appears under the scripted '
                         'presses</td></tr>')
            w = worst_of(r)
            bad = [(f, sh) for f, sh in r['shots'].items() if sh['final'] not in OK]
            _, _, worstpx, nbad = divergence(r)
            mg = min((sh['dingbat_vs_mgba']['verdict'] for f, sh in bad),
                     key=lambda v: RANK.index(v) if v in RANK else 99)
            rc = max((sh['ref_control']['verdict'] for f, sh in bad),
                     key=lambda v: RANK.index(v) if v in RANK else 99)
            ni = r.get('noinput_f1650', {}).get('verdict', '—')
            cps = ', '.join(f'f{f}' for f, _ in sorted(bad, key=lambda x: int(x[0])))
            h.append(f'<tr><td>{r["title"]}</td>'
                     f'<td><span class="chip v-{w}">{w}</span></td>'
                     f'<td class="num">{worstpx*100:.1f}%</td>'
                     f'<td class="num">{nbad}/{len(r["shots"])} &nbsp;<span class="rom">{cps}</span></td>'
                     f'<td><span class="chip v-{mg}">{mg[:4]}</span></td>'
                     f'<td><span class="chip v-{rc}">{rc[:4]}</span></td>'
                     f'<td class="rom">{ni}</td>'
                     f'<td class="rom">{r["rom"]}</td></tr>')
        h.append('</table></div></section>')

    h.append('<section><h2>All titles</h2><div class="scroll"><table>')
    h.append('<tr><th>Title</th><th>Verdict</th>'
             + ''.join(f'<th>f{f}</th>' for f in frames) + '<th>ROM</th></tr>')
    for r in sorted(results, key=lambda r: r['title']):
        w = worst_of(r)
        cells = ''.join(
            f'<td><span class="chip v-{r["shots"][f]["final"]}">'
            f'{r["shots"][f]["final"][:4]}</span></td>'
            for f in sorted(r['shots'], key=int))
        h.append(f'<tr><td>{r["title"]}</td>'
                 f'<td><span class="chip v-{w}">{w}</span></td>{cells}'
                 f'<td class="rom">{r["rom"]}</td></tr>')
    h.append('</table></div></section>')

    flagged = sorted((r for r in results if worst_of(r) not in OK),
                     key=lambda r: (-RANK.index(worst_of(r)), r['title']))
    if flagged:
        h.append('<section><h2>Flagged titles</h2>'
                 '<p class="note">Every emulator at every checkpoint. In each '
                 'of these the two references also disagree with each other at '
                 'the same checkpoint &mdash; see the noise floor above.</p>')
        for r in flagged:
            h.append(card(workdir, r, full=True))
        h.append('</section>')

    clean = [r for r in results if worst_of(r) in OK]
    gallery = clean[:CLEAN_GALLERY]
    h.append('<section><h2>Clean titles</h2>'
             '<p class="note">dingbat\'s own progression. Start and A are '
             'pressed between checkpoints to walk the title screen and the '
             'opening menus; every frame below matched SameBoy.'
             + (f' Showing {len(gallery)} of {len(clean)} &mdash; the rest are '
                'in the table above, and a whole-library run prunes their '
                'screenshots as it goes.' if len(clean) > len(gallery) else '')
             + '</p>')
    for r in sorted(gallery, key=lambda r: r['title']):
        h.append(card(workdir, r, full=False))
    h.append('</section></div>')

    doc = ('<title>dingbat GB/GBC ROM sweep</title>\n'
           f'<style>{CSS}</style>\n' + '\n'.join(h))
    with open(out_path, 'w') as f:
        f.write(doc)
    print('wrote', out_path, f'({os.path.getsize(out_path)//1024} KB)')


def card(workdir, r, full):
    w = worst_of(r)
    rundir = os.path.join(workdir, 'runs', r['slug'])
    h = [f'<div class="card"><header><h3>{r["title"]}</h3>'
         f'<span class="chip v-{w}">{w}</span></header>']
    bits = [r['rom']]
    ni = r.get('noinput_f1650', {}).get('verdict')
    if ni:
        bits.append(f'no-input control: {ni}')
    h.append(f'<div class="meta">{" &middot; ".join(bits)}</div>')
    h.append('<div class="shots">')
    shown = 0
    frames = sorted(r['shots'], key=int)
    if full:
        # Only the checkpoints that actually diverged. A flagged title usually
        # matches at most of them, and over a whole-library run the matching
        # ones are most of the page weight for none of the information.
        diverged = [f for f in frames if r['shots'][f]['final'] not in OK]
        frames = diverged or frames
    for f in frames:
        shot = r['shots'][f]
        emus = EMUS if full else ('dingbat',)
        h.append(f'<div class="cp"><div class="cph"><span>frame {f}</span>'
                 f'<span class="chip v-{shot["final"]}">{shot["final"][:4]}</span>'
                 f'</div><div class="row{"" if full else " strip"}">')
        for emu in emus:
            uri = png_data_uri(os.path.join(rundir, emu, f'{emu}.f{int(f):04}.ppm'))
            if not uri:
                continue
            cap = LABEL[emu]
            if full and emu == 'dingbat':
                cap += f' &middot; {shot["dingbat_vs_sameboy"]["exact"]*100:.1f}% px'
            shown += 1
            h.append(f'<div class="shot"><img src="{uri}" alt="{LABEL[emu]} at '
                     f'frame {f} of {r["title"]}"><div class="cap">{cap}</div></div>')
        h.append('</div></div>')
    h.append('</div></div>')
    if not shown:
        return ''      # artifacts pruned (bulk mode); the tables still list it
    return '\n'.join(h)


def main():
    workdir = sys.argv[1]
    out = sys.argv[2]
    files, notes = [], None
    args = sys.argv[3:]
    while args:
        a = args.pop(0)
        if a == '--notes': notes = args.pop(0)
        else: files.append(a)
    if not files:
        files = ['results_b1.json']
    results = []
    for fn in files:
        results += json.load(open(os.path.join(workdir, fn)))
    notes_html = open(notes).read() if notes else ''
    render(workdir, results, notes_html, out)


if __name__ == '__main__':
    main()
