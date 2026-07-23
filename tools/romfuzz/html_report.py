#!/usr/bin/env python3
"""Build the self-contained HTML sweep report (images inlined as data URIs).

Usage: html_report.py <workdir> <out.html>
Embeds composites for titles listed in EMBED; all other titles appear in the
summary table only. Expects report.py to have run (report/img/*.png).
"""
import base64, html, json, os, sys

RANK = ['IDENTICAL', 'MINOR', 'DIFFERENT', 'MAJOR']

# slug -> (frames to embed, caption)
EMBED = {
    'spongebob-squarepants-volume-1': ([1600], 'f1600 — references (left, middle) both black during video playback; dingbat (right) shows the ROM’s Game Boy Player lockout screen.'),
    'super-mario-advance': ([800], 'f800 — references at the Choose a Game menu; dingbat reports corrupt save data on a fresh boot.'),
    'super-mario-advance-3-yoshi-s-island': ([2000], 'f2000 — same storybook scene, but dingbat’s colors are badly wrong (blend/brightness).'),
    'tony-hawk-s-pro-skater-2': ([2000], 'f2000 — dingbat matches NBA except the skater portrait, which renders as noise tiles.'),
    'doom': ([1200], 'f1200 — timing skew, not a bug: references still on the title; dingbat already caught the scripted START press. With no input all three are pixel-identical.'),
    'castlevania-aria-of-sorrow': ([2000], 'f2000 — the common benign pattern: dingbat (right) matches NBA (middle) exactly; only mGBA (left) is a menu behind.'),
}

def img_uri(path):
    return 'data:image/png;base64,' + base64.b64encode(open(path, 'rb').read()).decode()

def chip(v):
    cls = {'IDENTICAL': 'ok', 'MINOR': 'ok2', 'DIFFERENT': 'warn', 'MAJOR': 'bad',
           'ERROR': 'err'}.get(v, 'na')
    return f'<span class="chip {cls}">{v}</span>'

def main():
    workdir, out = sys.argv[1], sys.argv[2]
    results = json.load(open(os.path.join(workdir, 'results.json')))
    notes = json.load(open(os.path.join(workdir, 'notes.json')))
    for r in results:
        r['overall'] = 'ERROR' if r['error'] else max(
            (s['final'] for s in r['shots'].values()), key=RANK.index, default='?')
    order = {'ERROR': 0, 'MAJOR': 1, 'DIFFERENT': 2, 'MINOR': 3, 'IDENTICAL': 4}
    results.sort(key=lambda r: (order.get(r['overall'], 9), r['title']))
    counts = {}
    for r in results:
        counts[r['overall']] = counts.get(r['overall'], 0) + 1

    bugs = [
        ('SpongeBob SquarePants — Volume 1 (GBA Video)', 'spongebob-squarepants-volume-1',
         'Game Boy Player detection false-positive', 'Renders “NOT COMPATIBLE WITH GAME BOY PLAYER”; both references play the video (and are pixel-identical to each other). Same with HLE and real BIOS — expect every GBA Video cart to fail the same way. Fix in progress.'),
        ('Golden Sun — The Lost Age', 'golden-sun-the-lost-age',
         'CPU crash (ARMv4T undefined instruction)',
         'Crashes within the first frames: Unimplemented THUMB instruction 0xE92D (thumb.nim:303). 0xE800–0xEFFF is undefined on ARMv4T; references run the ROM fine. The harness also exits 0 despite the crash. Fix in progress.'),
        ('Super Mario Advance', 'super-mario-advance',
         'EEPROM save emulation',
         '“The saved data is corrupt.” on every boot with zero input; the game formats the save and continues, wiping progress each boot. References boot clean.'),
        ('Super Mario Advance 3 — Yoshi’s Island', 'super-mario-advance-3-yoshi-s-island',
         'PPU blending / brightness',
         'The storybook intro renders saturated purple / murky green where references show pale pastels. Composition and text are correct; earlier checkpoints match NBA — the bug is specific to this scene’s color effects.'),
        ('Tony Hawk’s Pro Skater 2', 'tony-hawk-s-pro-skater-2',
         'Decompression / bitmap-OBJ edge case',
         'Skater-select matches NBA at ~98% — but the portrait photo is persistent garbled noise, with both HLE and real BIOS.'),
    ]

    def bug_section():
        parts = []
        for i, (title, slug, cls, desc) in enumerate(bugs, 1):
            parts.append(f'<article class="bug"><h3><span class="bugno">{i}</span>{html.escape(title)}</h3>'
                         f'<p class="bugclass">{html.escape(cls)}</p><p>{html.escape(desc)}</p>')
            if slug in EMBED:
                frames, cap = EMBED[slug]
                for f in frames:
                    p = os.path.join(workdir, 'report', 'img', f'{slug}.f{f:04}.png')
                    if os.path.exists(p):
                        parts.append(f'<figure><div class="shotwrap"><img src="{img_uri(p)}" alt="{html.escape(title)} frame {f}"></div>'
                                     f'<figcaption>{html.escape(cap)}</figcaption></figure>')
            st = f'states/{slug}.f2000.state'
            if os.path.exists(os.path.join(workdir, 'report', st)):
                parts.append(f'<p class="statenote">Save state: <code>{st}</code> (dingbat format, report bundle)</p>')
            parts.append('</article>')
        return '\n'.join(parts)

    def timing_section():
        out = []
        for slug, label in [('doom', 'Doom'), ('castlevania-aria-of-sorrow', 'Castlevania — Aria of Sorrow')]:
            frames, cap = EMBED[slug]
            p = os.path.join(workdir, 'report', 'img', f'{slug}.f{frames[0]:04}.png')
            out.append(f'<figure><div class="shotwrap"><img src="{img_uri(p)}" alt="{label}"></div>'
                       f'<figcaption><strong>{label}</strong>: {html.escape(cap)}</figcaption></figure>')
        return '\n'.join(out)

    rows = []
    for r in results:
        cells = ''.join(
            f'<td>{chip(r["shots"].get(str(f), {}).get("final", "—")) if not r["error"] else chip("ERROR")}</td>'
            for f in [800, 1200, 1600, 2000])
        note = notes.get(r['slug'], '')
        note_txt = ''
        if note:
            first = note.split('.')[0].replace('**', '').strip()
            note_txt = f'<div class="rownote">{html.escape(first)}.</div>'
        rows.append(f'<tr><td class="t">{html.escape(r["title"])}{note_txt}</td>'
                    f'<td>{chip(r["overall"])}</td>{cells}</tr>')
    table = '\n'.join(rows)

    tiles = ''.join(
        f'<div class="tile {c}"><div class="n">{counts.get(k, 0)}</div><div class="l">{k.title()}</div></div>'
        for k, c in [('IDENTICAL', 'ok'), ('MINOR', 'ok2'), ('DIFFERENT', 'warn'),
                     ('MAJOR', 'bad'), ('ERROR', 'err')])

    css = '''
:root{--bg:#faf6ef;--panel:#f1ebdf;--ink:#241f16;--mut:#6d6353;--line:#ddd3c2;
--accent:#a86f14;--ok:#2c7a4b;--ok2:#5f8a3c;--warn:#a06412;--bad:#b23a2e;--err:#7a2c66;
--chipbg:#e9e1d1;}
:root[data-theme="dark"]{--bg:#161210;--panel:#1f1a15;--ink:#e9e0d0;--mut:#9b8f7b;--line:#352c22;
--accent:#d99c2b;--ok:#5cba82;--ok2:#93b862;--warn:#d9a13c;--bad:#e07566;--err:#c775b4;--chipbg:#2a231b;}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#161210;--panel:#1f1a15;--ink:#e9e0d0;--mut:#9b8f7b;--line:#352c22;
--accent:#d99c2b;--ok:#5cba82;--ok2:#93b862;--warn:#d9a13c;--bad:#e07566;--err:#c775b4;--chipbg:#2a231b;}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif;}
main{max-width:960px;margin:0 auto;padding:40px 20px 80px}
h1{font-size:1.7rem;line-height:1.2;text-wrap:balance;margin:0 0 4px}
h2{font-size:1.2rem;margin:48px 0 12px;padding-top:16px;border-top:1px solid var(--line)}
h3{font-size:1.02rem;margin:0 0 2px;display:flex;align-items:center;gap:10px}
.sub{color:var(--mut);margin:0 0 28px;max-width:64ch}
.eyebrow{font:600 .72rem/1 ui-monospace,Menlo,monospace;letter-spacing:.12em;
text-transform:uppercase;color:var(--accent);margin:0 0 10px}
.tiles{display:flex;gap:10px;flex-wrap:wrap;margin:20px 0 8px}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:6px;
padding:10px 18px;min-width:96px}
.tile .n{font:600 1.5rem/1.2 ui-monospace,Menlo,monospace}
.tile .l{font-size:.75rem;color:var(--mut);letter-spacing:.04em}
.tile.ok .n{color:var(--ok)}.tile.ok2 .n{color:var(--ok2)}
.tile.warn .n{color:var(--warn)}.tile.bad .n{color:var(--bad)}.tile.err .n{color:var(--err)}
.chip{font:600 .68rem/1 ui-monospace,Menlo,monospace;letter-spacing:.05em;
padding:3px 7px;border-radius:4px;background:var(--chipbg);white-space:nowrap}
.chip.ok{color:var(--ok)}.chip.ok2{color:var(--ok2)}.chip.warn{color:var(--warn)}
.chip.bad{color:var(--bad)}.chip.err{color:var(--err)}.chip.na{color:var(--mut)}
.bug{background:var(--panel);border:1px solid var(--line);border-radius:8px;
padding:18px 20px;margin:0 0 18px}
.bugno{font:600 .8rem/1 ui-monospace,Menlo,monospace;color:var(--bad);
border:1px solid var(--bad);border-radius:4px;padding:3px 7px}
.bugclass{font:600 .72rem/1 ui-monospace,Menlo,monospace;letter-spacing:.08em;
text-transform:uppercase;color:var(--accent);margin:6px 0 8px}
.bug p{margin:6px 0;max-width:72ch}
figure{margin:14px 0 4px}
.shotwrap{overflow-x:auto;border:1px solid var(--line);border-radius:6px;background:#000}
.shotwrap img{display:block;image-rendering:pixelated;width:100%;min-width:600px;max-width:900px}
figcaption{font-size:.8rem;color:var(--mut);margin-top:6px;max-width:80ch}
.statenote{font-size:.8rem;color:var(--mut)}
code{font:.85em ui-monospace,Menlo,monospace;background:var(--chipbg);
padding:1px 5px;border-radius:4px}
.tablewrap{overflow-x:auto;border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:.85rem}
th{font:600 .68rem/1.3 ui-monospace,Menlo,monospace;text-transform:uppercase;
letter-spacing:.08em;color:var(--mut);text-align:left;padding:10px 12px;
border-bottom:1px solid var(--line);background:var(--panel)}
td{padding:8px 12px;border-bottom:1px solid var(--line);vertical-align:top}
td.t{min-width:220px}
tr:last-child td{border-bottom:none}
.rownote{font-size:.72rem;color:var(--mut);margin-top:2px;max-width:48ch}
.method{max-width:70ch;color:var(--mut);font-size:.9rem}
.method code{font-size:.82em}
@media (prefers-reduced-motion: no-preference){.bug{transition:border-color .15s}}
.bug:hover{border-color:var(--accent)}
'''
    page = f'''<title>dingbat ROM compatibility sweep</title>
<style>{css}</style>
<main>
<p class="eyebrow">dingbat &middot; cross-emulator fuzz &middot; 2026-07-22</p>
<h1>ROM compatibility sweep: dingbat vs mGBA &amp; NanoBoyAdvance</h1>
<p class="sub">{len(results)} popular GBA titles ran headless for 2000 frames in all three
emulators with an identical input script, screenshots at four checkpoints, and
perceptual diffing (exact pixels + downscaled correlation + average hash). A
checkpoint passes when dingbat matches either reference, directly or within a
&plusmn;45-frame skew window.</p>
<div class="tiles">{tiles}</div>

<h2>Real bugs found</h2>
{bug_section()}

<h2>Timing skew, not incompatibility</h2>
<p class="method">Doom, Star Wars Episode III, Castlevania Harmony of Dissonance and
Mario Party Advance flagged in the scripted run but are pixel-identical (or
blink-phase close) with no input: dingbat runs their boot sequences faster than
both references, so the scripted presses land on different screens. The other
flagged titles all match NanoBoyAdvance exactly — only mGBA, which accumulates
the most lag frames, trails a screen behind.</p>
{timing_section()}

<h2>All titles</h2>
<div class="tablewrap"><table>
<thead><tr><th>Title</th><th>Overall</th><th>f800</th><th>f1200</th><th>f1600</th><th>f2000</th></tr></thead>
<tbody>{table}</tbody>
</table></div>

<h2>Method &amp; artifacts</h2>
<p class="method">Harnesses: <code>tools/romfuzz/</code> — mGBA runner (headless libmgba 0.10.5),
NanoBoyAdvance runner (libnba), dingbat runner (HLE + real BIOS, save states),
perceptual differ <code>imgdiff.py</code>, orchestrator <code>sweep.py</code>. All emulators
skip the BIOS logo so frame 0 is the first game frame; dingbat also ran with the
real BIOS to attribute HLE-BIOS-specific differences (none of the bugs above are
HLE-specific). Full run artifacts — per-title screenshots for every emulator,
composites, and dingbat save states at every checkpoint — are in the report
bundle (<code>report.md</code>, <code>img/</code>, <code>states/</code>).</p>
</main>
'''
    open(out, 'w').write(page)
    print('wrote', out, f'{os.path.getsize(out)//1024}KB')

if __name__ == '__main__':
    main()
