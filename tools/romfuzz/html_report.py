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
    'super-mario-advance': ([800], 'f800 — references at the Choose a Game menu; dingbat reports corrupt save data on a fresh boot.'),
    'super-mario-advance-3-yoshi-s-island': ([2000], 'f2000 — same storybook scene, but dingbat’s colors are badly wrong (blend/brightness).'),
    'tony-hawk-s-pro-skater-2': ([2000], 'f2000 — dingbat matches the references except the skater portrait, which renders as noise tiles.'),
    'doom': ([1200], 'f1200 (pre-fix) — timing, not rendering: references (identical to each other) still on the title; dingbat-HLE booted ~75 frames faster and already caught the scripted START press. Fixed by HLE BIOS cost calibration (a9ca2a9): HLE title arrival now f875, pixel-identical to real BIOS.'),
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
    extra = os.path.join(workdir, 'results2_merged.json')
    if os.path.exists(extra):
        results += json.load(open(extra))
    notes = json.load(open(os.path.join(workdir, 'notes.json')))
    for r in results:
        r['overall'] = 'ERROR' if r['error'] else max(
            (s['final'] for s in r['shots'].values()), key=RANK.index, default='?')
    order = {'ERROR': 0, 'MAJOR': 1, 'DIFFERENT': 2, 'MINOR': 3, 'IDENTICAL': 4}
    results.sort(key=lambda r: (order.get(r['overall'], 9), r['title']))
    counts = {}
    for r in results:
        counts[r['overall']] = counts.get(r['overall'], 0) + 1

    fixed = [
        ('SpongeBob SquarePants — Volume 1 (GBA Video)', 'spongebob-squarepants-volume-1',
         'Phantom keypad IRQ — fixed, commit c92de8c',
         'The “Not compatible with Game Boy Player” screen is a normal boot phase of GBA Video carts; dingbat boot-looped on it forever. A byte-decomposed 16-bit KEYCNT store let the keypad-IRQ check observe a transient (0xC00F→0x0000 passes through 0xC000 = AND-mode empty mask, vacuously true), latching a phantom IRQ that fired the cart’s soft-reset handler every boot. KEYCNT stores now commit atomically; KEYINPUT bits 10-15 read 0. Post-fix: pixel-identical to both references at 3 of 4 checkpoints; f1200 is a mid-video playback-sync offset that resyncs by f1600.'),
        ('Golden Sun — The Lost Age', 'golden-sun-the-lost-age',
         'SMC-vs-pipeline-refill + ARMv4T UND exception — fixed, commit c92de8c',
         'Crashed in the first frames on THUMB 0xE92D: the game DMAs an ARM trampoline onto the stack at a just-branched-to address, and dingbat’s self-modifying-code pipeline capture pre-filled stale bytes in the branch-to-refill window. Fixed with a refill-pending guard, plus a hardware-accurate undefined-instruction exception so junk execution can never crash the process again. Post-fix: clean to f2000, MINOR vs both references. mGBA suite unchanged at baseline (HLE 6910/7008, LLE 6909/7008).'),
        ('Tony Hawk’s Pro Skater 2', 'tony-hawk-s-pro-skater-2',
         '8bpp OBJ tile indexing in 1D mapping — fixed, commit e901913',
         'The skater portrait (an odd-indexed 256-color sprite in 1D mapping) rendered as noise: the OBJ renderer force-cleared the tile index’s low bit unconditionally, but hardware only forces it in 2D mapping — in 1D mapping an odd name starts 32 bytes into a tile pair, so every fetch landed half a tile early. Post-fix the portrait is pixel-identical to mGBA; a second skater verified too.'),
        ('Super Mario Advance', 'super-mario-advance',
         'EEPROM size autodetect + write-settle window — fixed, commit 38927b5',
         'The size-autodetect rule was unsatisfiable (compared the DMA transfer count against ≤6, but real counts are 9/73 for 4Kbit vs 17/81 for 64Kbit), so every 4Kbit cart parsed 14 address bits instead of 6 and desynced the serial protocol — SMA’s save checksum failed every boot and it reformatted. Writes also completed instantly where real EEPROMs read busy ~6.5 ms (added mGBA’s 115000-cycle settle window). Post-fix: boots clean with a correct 512-byte save that persists; SMA2/SMA3 (64Kbit) unaffected.'),
        ('Super Mario Advance 3 — Yoshi’s Island', 'super-mario-advance-3-yoshi-s-island',
         'HLE LZ77 cost + frame counting — fixed, commits a9ca2a9 + fa36c81',
         'Not a PPU bug: blend registers, PRAM and VRAM were byte-identical to mGBA — the whole cinematic ran 7 frames ahead, and the “wrong colors” are the same scene earlier in its 128-frame cloud-drift cycle. The lead came from HLE LZ77UnCompVram undercharging (six back-to-back ~70KB decompressions behind the boot fade) plus ppu.frame being a bool that collapsed frames elapsing inside a multi-frame atomic SWI. Post-fix: pixel-identical to mGBA at every checkpoint; Kirby (also decompression-heavy) went exact too.'),
    ]
    bugs = []

    def bug_article(i, title, slug, cls, desc, fixed_cls=''):
        parts = [f'<article class="bug{fixed_cls}"><h3><span class="bugno{fixed_cls}">{i}</span>{html.escape(title)}</h3>'
                 f'<p class="bugclass">{html.escape(cls)}</p><p>{html.escape(desc)}</p>']
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

    def fixed_section():
        parts = []
        before = os.path.join(workdir, 'spongebob-before-fix.png')
        for i, (title, slug, cls, desc) in enumerate(fixed, 1):
            extra = ''
            if slug == 'spongebob-squarepants-volume-1' and os.path.exists(before):
                extra = (f'<figure><div class="shotwrap"><img src="{img_uri(before)}" alt="before fix"></div>'
                         f'<figcaption>Before the fix (f1600): references (left, middle) both black during video playback; '
                         f'dingbat (right) stuck forever on the boot notice.</figcaption></figure>')
            art = bug_article(i, title, slug, cls, desc, fixed_cls=' fixedbug')
            parts.append(art.replace('</article>', extra + '</article>'))
        return '\n'.join(parts)

    def bug_section():
        return '\n'.join(bug_article(i, *b) for i, b in enumerate(bugs, 1))

    def timing_section():
        frames, cap = EMBED['doom']
        p = os.path.join(workdir, 'report', 'img', f'doom.f{frames[0]:04}.png')
        if not os.path.exists(p):
            return ''
        return (f'<figure><div class="shotwrap"><img src="{img_uri(p)}" alt="Doom"></div>'
                f'<figcaption><strong>Doom</strong>: {html.escape(cap)}</figcaption></figure>')

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
.bugno.fixedbug{color:var(--ok);border-color:var(--ok)}
h2 .chip{vertical-align:middle;margin-left:8px}
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
<p class="sub">{len(results)} popular GBA titles (two 50-title popularity batches) ran headless
for 2000 frames in all three emulators with an identical input script,
screenshots at four checkpoints, and perceptual diffing (exact pixels +
downscaled correlation + average hash). A checkpoint passes when dingbat
matches either reference, directly or within a &plusmn;45-frame skew window.</p>
<div class="tiles">{tiles}</div>

<h2>Fixed during this session <span class="chip ok">commit c92de8c on main</span></h2>
{fixed_section()}

{('<h2>Open bugs</h2>' + bug_section()) if bugs else '<h2>Open bugs</h2><p class="method">None — every real difference found by the sweep is fixed on main.</p>'}

<h2>Timing skew, not incompatibility</h2>
<p class="method">Doom — <strong>fixed (commit a9ca2a9)</strong>. A BIOS-parity experiment showed
core timing was fine (full-BIOS runs align across all three emulators;
dingbat-with-real-BIOS matches the references at ~f875) and isolated the gap to
HLE BIOS call costs: Doom's boot makes 69 LZ77UnCompVram calls that were
charged ~41k cycles each vs ~540k for the real BIOS routine. Per-SWI cost
models (CpuSet, LZ77, affine, ArcTan2, RamReset) derived from the BIOS
disassembly and validated cycle-exactly with a calibration ROM close the gap:
HLE title arrival is now f875, pixel-identical to real BIOS, and Emerald /
Aria of Sorrow HLE-vs-real boot parity tightened too. The remaining flagged
titles (Castlevania HoD, DKC 1/2, Kirby, Minish Cap, Mario Party Advance) are
animation/progression phase drift at or below the level the two references
disagree with each other.</p>
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
