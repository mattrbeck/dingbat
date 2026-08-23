# GB test-suite failures: the open buckets

Every Game Boy row the runner scores red, grouped by the hardware mechanism
the row measures. For each bucket: the rows, the behaviour under test and the
evidence for it, what dingbat models today (the knob and its shipping value),
and what would close it. Scores live in `tests/results.md` (per suite) and
`tests/results_gambatte.md` (per row); this file explains them and is updated
when they move. Closed buckets are one line each at the end.

Conventions: a knob is a `{.intdefine.}` in `src/dingbat/gb/` and its own
comment carries the derivation; `[dmg]`/`[cgb]` is the device a gambatte row
is scored on; `_ds_` is double speed; `@cgbc` etc. is the revision arm of a
row whose ROM names several machines.

## Scoreboard

| suite | pass | of | open buckets |
|---|---|---|---|
| Blargg (+ dmg_sound, cgb_sound) | 52 | 52 | — |
| Mooneye | 152 | 152 | — |
| Mooneye (wilbertpol) | 178 | 180 | G |
| Acid2, MagenTests, Screenshot suites, Shootout ROMs | 35 | 35 | — |
| Mealybug Tearoom | 74 | 74 | — |
| GBMicrotest | 480 | 480 | — |
| SameSuite, SameSuite APU | 78 | 78 | — |
| AGE | 57 | 89 | A1, B1, C2, C8, E1 |
| gambatte (rows) | 4619 | 4996 | everything below |

The gbdev shootout scores 261/261 (`tests/README.md`, "The gbdev shootout's
own ROMs"). It runs CGB-E; the local runner's default CGB is CGB-C, and both
are at their measured maximum — see "The device axis" in `tests/README.md`.

## Rows that are deliberately not scored

The runner's `NotScored` list (`tests/dingbat_test_runner.nim`) is the
ledger and is printed at the bottom of `tests/results.md`. The GB entries:

* GBMicrotest: 31 ROMs that never write the `$FF82` verdict byte, and two
  whose expected byte is unreachable (`halt_op_dupe_delay`,
  `stat_write_glitch_l154_d`; `docs/gb-test-suite-sources.md` §8.6, §8.6b).
  Denominator 480.
* gambatte: the 220 `_outaudio*` rows, the AGB column, and nine
  `oamdma_src{FE00,FF00}_*read*` DMG rows whose verdict is uninitialised WRAM.
* wilbertpol: `acceptance/gpu/ly_lyc{,_0,_144,_153}-C@cgbc` — see G.
* AGE `ncm*` (CGB in non-CGB mode), mooneye `ags` arms (fold into `agb`),
  `daid/ppu_scanline_bgp (GBC)` on the local runner's CGB-C (its reference is
  a CGB-D-or-later palette dot; the shootout arm at CGB-E is green).

## Reading the instruments

* **gambatte families.** `name_1`, `name_2`, … are one ROM with one write
  moved one CPU M-cycle per member, so the member the expected value flips on
  is the measurement. The filename carries the expected value per device
  (`_dmg08_out2_cgb04c_out3`); one value means both devices agree.
  `lcdoffset{1,2,3}` members run 2/4/2 speed switches in their preamble to
  offset the PPU dot grid from the CPU's M-cycle grid — the suite's only
  sub-M-cycle ruler (B1). `tools/gbppu/gamall.sh` writes the 4996-row verdict
  file; `tools/gbppu/famflip.py` reads flip points off it (check a family with
  `cmp -l` first: it merges non-contiguous ladders).
* **AGE.** Each ROM draws its own expected-vs-got table; a cell is the index
  of the first mismatching sample in a run of them, and the sample is named in
  the ROM's `EXPECTED_*` table. `tools/gbppu/agetable.py`, `agecells.py`,
  `agediff.py` read it back (render with `--mode=screenshot --timeout=600`,
  not `--bb-breakpoint`, which stops the ROM before it draws). Source:
  `github.com/c-sp/age-test-roms`, with the silicon each table was taken on in
  the ROM header.
* **wilbertpol `acceptance/gpu`.** `tools/gbppu/wilbergpu.py` prints the raw
  samples (`--patch`); `lycwsled.py` slides a store through its NOP field.
* **PNG rows.** `tools/gbppu/pngdiff.py` (per-scanline diff);
  `tools/gbphoto/` reads mealybug's hardware photographs.
* **Traces** (`-d:`, tools only): `gb_m3_trace`, `gb_px_trace`, `gb_m3_len`,
  `gb_dma_trace`, `gb_stat_read_trace`, `gb_stat_src_trace`, `gb_halt_trace`,
  `gb_lcdc2_trace`, `gb_lyread_probe`.
* **Sweeps.** `tools/gbppu/sssweep.sh` (one build per define set, sharded),
  `daidswitch.sh` (the five pixel gates for any halt/speed-switch change),
  `revsweep.py` (every failing self-checking row on all eleven revisions).
* **Perf.** `tools/gbppu/counters.sh`; retired instructions with
  `DINGBAT_BENCH_COUNTERS=1`, `cycles=` equal between arms. Wall clock lies
  below ~1.3% (`docs/gb_oam_dma_cost.md`).
* **Environment.** `TMPDIR`, `DINGBAT_ROM_CACHE` and the nimcache are shared
  across worktrees; use private ones. `tests/results*.md` are committed
  baselines every runner pass rewrites.

---

## A. STAT and interrupt timing

### A1. The mode-0 dispatch grid at double speed

**Rows (7).** AGE `stat-interrupt/stat-int-dmgC-cgbBCE@{cgbab,cgbc,cgbe}`
(double-speed half: every odd SCX, no even one); gambatte
`m2int_m0irq/m2int_m0irq_scx5_ds_1`, `m0int_m0stat/m0int_m0stat_scx5_ds_2`,
`enable_display/ly0_m0irq_scx{0,1}_ds_1`.

**Behaviour.** The mode-0 STAT interrupt's dispatch relative to the line's
mode 0 -> 2 edge, read at 2-dot resolution. AGE `stat-int` takes the mode-0
interrupt on line 3 and reads STAT back at two delays one M-cycle apart for
SCX 0..9; its expected table (CGB B/C/E, per the header) is a staircase that
dingbat's double-speed arm reproduces only on even SCX, dispatching a whole
M-cycle early on odd SCX — the signature of a one-dot source lead on a 2-dot
M-cycle grid.

**Modelled.** `STAT_M0_LEAD_T = 2` (ppu.nim): the mode-0 source leads the
mode 3 -> 0 flag by 2 T-cycles of the CPU clock, single speed exact;
`STAT_M0_LEAD_DS = 1` is the double-speed value. `CGB_M0_HALT_BLIND_DS_DOTS
= 1`.

**To close.** `-d:STAT_M0_LEAD_DS=0 -d:CGB_M0_HALT_BLIND_DS_DOTS=0` takes the
AGE arms and five gambatte rows but loses
`irq_precedence/late_m0irq_retrigger_scx1_ds_2` and
`m2int_m0irq/m2int_m0irq_scx3_ifw_ds_2`, and a single implementation is known
to pass all ten, so the lead is not the quantity that is wrong (pinned only
by comparison; see the note at `STAT_M0_LEAD_DS`). Rounding the source to an
odd dot reproduces the staircase and keeps the edge, which points at the
CPU-to-PPU dispatch phase in double speed (`mem_tick_ppu_latched`,
`CGB_LATENCY_CAP`) rather than at the source.

### A2. The dispatch's IF clear against a source rising inside it

**Rows (16).** The `_2` arm of every `*_late_retrigger` family, both
devices: `ly0/lycint152_lyc0irq_late_retrigger_2`,
`ly0/lycint152_lyc153irq_late_retrigger_2`,
`lyc153int_m2irq/lyc153int_m2irq_late_retrigger_2`,
`m1/lycint143_m1irq_late_retrigger_2`,
`m1/lycint_vblankirq_late_retrigger_2`,
`irq_precedence/late_m0irq_retrigger_2`, and
`tima/tc00_irq_late_retrigger_{2,3,ds_2}`.

**Behaviour.** Each ROM's handler re-requests its own interrupt with an
`LDH ($0F),A` that moves one M-cycle per member, `EI`s, and reads IF inside
the second dispatch; the member the value flips on is where the dispatch
clears the taken IF bit. Pan Docs, "Interrupt Handling": the dispatch is five
M-cycles, the fifth setting PC. gambatte `m2int_m2irq_late_retrigger_{1,2}`
pins the clear at the start of that fifth M-cycle (T = 16) and every other
`*_late_retrigger` family — five STAT sources and the timer — agrees on its
`_1` arm.

**Modelled.** `IRQ_SAMPLE_T = 16`, `IRQ_SAMPLE_T_DS = 16` (cpu.nim). The
`_2` arms want the clear at T = 20 in single speed; `20 / 16` takes them and
costs `m2int_m2irq_late_retrigger_1`, `irq_precedence/late_m0irq_retrigger_
scx1_1` and `serial/start_wait_trigger_int8_read_if_2 [dmg]`.

**To close.** Seven sources agreeing against `m2int_m2irq` about the same
instant says the difference is in when each SOURCE rises relative to the
dispatch, not in the clear. Settle the per-source rise dots (A3, A4) before
moving this constant.

### A3. A STAT source enabled, disabled or handed over across a line edge

**Rows (108).** `lycEnable` 33, `m2enable` 20, `m1` 23, `m0enable` 18,
`miscmstatirq` 7, `m2int_m0irq/m2int_m0irq_scx3_ifw_{2,4}` (4),
`ly0/lycint152_lyc{0,153}flag_ds_3`, `lycint_lycflag/lycint_lycflag_ds_3`.
Heavily CGB, and a third of them `lcdoffset1` or `_ds_` members.

**Behaviour.** The STAT interrupt line is a level OR of four sources into
one edge detector, so an interrupt fires only when the OR rises from zero
(Pan Docs, "LCD Status Register", STAT blocking; mooneye
`acceptance/gpu/stat_irq_blocking` is green). These families write STAT or
LYC one M-cycle per member across a line boundary and ask whether the
enable, the disable or the hand-over from one source to another produced an
edge. Sub-shapes, each a separate rule:

* `m0enable/lycdisable_ff4{1,5}_*` (14): LYC source disabled by a STAT or
  LYC write while the mode-0 source is coming up; hardware takes the
  interrupt (`out2`), dingbat does not.
* `m2enable/late_enable_*`, `lyc1_m2irq_late_lyc*`, `m2_late_m0disable`
  (20): the OAM source enabled one M-cycle across the line boundary it rises
  on. `STAT_M2_LEAD = 1` puts the rise one CPU M-cycle before the boundary;
  these say the enable window around it is still a cycle out, mostly on CGB.
* `m1/m1irq_m2enable_lyc_*`, `m2m1irq_ifw_*`, `m1irq_m2disable_lycdisable_*`,
  `ly143_late_m{0,2}enable_*`, `m1irq_late_enable_*` (23): the mode-1 /
  mode-2 / LYC hand-over at the top of line 144, where hardware refuses an
  edge a level-OR gives. `LY_BLIND_SCOPE = 2` (the comparator is blind while
  LY changes, including the mode 0 -> 1 entry) took the rest of `m1`; these
  are what it does not reach.
* `lycEnable/lyc153_late_*`, `lyc0_m1disable_*`, `lcdoff_lycirqen_*` (15):
  the LYC = 153 and LYC = 0 sources around the LY 153 -> 0 snapback
  (`LYC_SRC_RELATCH_LEAD = 1`, `LYC_SETTLE_DOTS`), and LYC armed while the
  LCD is off.
* `lycEnable/ff45_enable_weirdpoint_*`, `late_ff45_enable_*`,
  `late_ff41_enable_*` (14, all CGB but two): a CGB takes an LYC write one
  M-cycle later than a DMG (`CGB_LYC_WRITE_DEFER`, wilbertpol
  `ly_lyc*_write-C` vs `-GS`); the `lcdoffset1` members ask whether that is
  4 dots or 2, which a boundary spelling cannot answer.
* `miscmstatirq/*wirq_trigger*` (7): a STAT write's enable bits reaching the
  line (`STAT_ENABLE_LATENCY = 0`, `CGB_STAT_ENABLE_LATENCY = 2`, bracketed by
  `m0enable/disable*_2 [cgb]` against `m0enable/disable_scx*_1`).

**Modelled.** The level-OR edge detector; `LY_BLIND_SCOPE = 2`; `STAT_M2_LEAD
= 1` (DMG and CGB alike — GBMicrotest `oam_int_if_edge_{a..d}` put the CGB
exact and the DMG a cycle late); `STAT_M2_PULSE = 3` and the line-144 OAM
pulse (`M2_144_PULSE`); `lyc_compare_hold` (CGB D+ hold the comparison the
blind window is leaving); the CGB enable latency above.

**To close.** Read each sub-shape at cell resolution with `famflip.py` and
`-d:gb_stat_src_trace` (which names the source on every rising edge) against
one statement of when each source's level rises and falls relative to the
line boundary. No Pan Docs sentence gives these dots; the evidence is the
families themselves.

### A4. Mode-0 STAT interrupt against a timer interrupt

**Rows (8).** `irq_precedence/late_m0irq_vs_tima_scx{2,3}{,_halt}_1`, both
devices: hardware takes the timer (`out4`), dingbat the STAT (`out2`).

**Behaviour.** Priority is by IF bit order when both are pending at the
dispatch (Pan Docs, "Interrupt Handling"); the row therefore measures which
source rose first, at SCX 2 and 3 only — the mode-0 edge's position inside
the M-cycle. `TIMER_IRQ_RUN_LEAD = 1` (gb.nim) puts a TIMA overflow at a
running CPU's dispatch one M-cycle ahead of its IF bit; `STAT_M0_LEAD_T = 2`
is the mode-0 side. The SCX dependence says it is the same sub-M-cycle
mode-0 residual as A1/A5, seen through the priority resolver.

### A5. Halt-woken readers of the mode-0 edge

**Rows (11).** `halt/late_m0int_halt_m0stat_scx{2,3}_{2b,3a,3b}` (7, mixed
direction inside one family: `scx2_3a` wants the read earlier, `scx3_2b`
later), `halt/noime_m2irq_m0stat_1 [cgb]`,
`oamdma/oamdma_late_halt_stat_2` (both), `oamdma_late_speedchange_stat_2`.

**Behaviour.** A halted CPU latches the interrupt line at a different point
of its M-cycle from a running one, and the mode-0 source's rise sits
mid-M-cycle at some SCX. GBMicrotest's `int_hblank_{nops,halt}_scx*` pairs
put the halt one M-cycle after the sled for the two sources that do not rise
on a line boundary (OAM, hblank) and level for the two that do (LYC, vblank).

**Modelled.** `HALT_IF_SAMPLE_T = 4` (the running CPU's point; 2 was
measured and ships off — its cost is +4.8% of retired instructions on a
halting main loop, cpu.nim), `M0_HALT_BLIND_DOTS = 2` (DMG: the last 2
T-cycles of a halted M-cycle cannot see the mode-0 rise; wilbertpol
`hblank_ly_scx_timing-GS` vs `-C`), `CGB_HALT_PPU_LEAD = 1` (a halted CGB's
PPU runs one M-cycle behind and gets it back at the wake; gambatte
`halt/lycirq_m2stat_{1,2,3}`, `halt/m1int_ly_{1,2,3}`, `cgb-acid-hell`),
`M2_LEAD_HALT_BLIND` (a halted CPU is blind to `STAT_M2_LEAD`; mooneye
`intr_2_*` vs wilbertpol `*_nops`). `noime_m2irq_m0stat_1 [cgb]` is the one
row `M2_LEAD_HALT_BLIND` costs on its own and is the open question at that
rule: DMG-only, or doubled up with the CGB halt lead.

**To close.** The residual is the SCX-dependent mode-0 edge (A1) read through
a halt, not a halt constant: every scalar here has been swept
(`CGB_HALT_PPU_LEAD_DOTS` 1..4, `CGB_HALT_EXIT_MCYCLES`, `HALT_IF_SAMPLE_T`)
and none separates `scx2_3a` from `scx3_2b`.

---

## B. The line after an LCD enable, and the boot hand-off

### B1. Line 0's mode edges are 2 dots later than the counter says

**Rows (50).** AGE `oam/oam-read-{dmgC-cgbBC@dmgC,@cgbab,@cgbc}`,
`oam-read-cgbE`, `oam/oam-write-{dmgC,cgbBCE@*}`, `vram/vram-read-{dmgC,
cgbBCE@*}` (12 arms); gambatte `enable_display` 15 (`ly0_late_vram{r,w}_*`,
`ly0_late_scx7_m3stat_*`, `frame{0,1}_m{0,2}{irq,stat}_count_*_ds_1`,
`enable_display_ly0_sprites_m0stat_2`, `ly0_oambusy_read_ds_1`),
`lcd_offset` 19 (all CGB), `display_startstate/stat_*_2 [cgb]` 4.

**Behaviour.** After `LCDC.7` goes high the first line starts in mode 0 and
its mode-3 edges sit 2 dots later against the CPU's grid than on any later
line. Four independent brackets in AGE's `oam-read`/`vram-read` pair (the
same ROM with one address changed, so every phase question cancels) agree on
the 2 dots: the mode-3 open and close edges, each on a DMG and a CGB (table
at `LCD_ON_LINE0_LOCK_LEAD`, ppu.nim). mealybug's harness says the same from
the pixel side — `line_0_fix` burns 4 T-cycles fewer on LY 0
(`docs/gb-mealybug-sources.md` §1.2). `lcd_offset`'s `*_count_*` families
are a 1-dot-per-SCX coincidence ruler for the STAT raise dot; read to ±1 dot
only, because `offset1_lyc99int_m0{stat,irq}_count_scx1_ds` — flag and IRQ
of one edge — demand opposite parities. `display_startstate/stat_*_2` read
STAT on the first line after the CGB boot hand-off and want mode 0 where
dingbat reads 3.

**Modelled.** `LCD_ON_HEAD_START = 5` (DMG) / `CGB_BOOT_PHASE = 161` (CGB;
gambatte `display_startstate/stat_*` 159..162) seed the first line.
`LCD_ON_LINE0_LOCK_LEAD = 2` spends the 2 dots in the VRAM and OAM locks
only; `LCD_ON_STAT_READ_LAG = 2` spends them in the STAT read. `LCD_ON_LINE0_
TRIM` and `LCD_ON_LINE1_TRIM` (the geometry fix) ship 0: `=2` moves the
pixel rows, the mode-0 SOURCE rows and mooneye `lcdon_{,write_}timing-GS`
and is far worse whole-runner. `VRAM_READ_M0_OPEN_DOTS = 2` (3 at DS),
`OAM_READ_M0_OPEN_DOTS = 2`, `OAM_READ_M3_CLOSE_DOTS = 5`, and
`oam_read_open_late` (CGB-E's OAM lock reopens a dot later; AGE
`oam-read-cgbE` vs `-dmgC-cgbBC`) are the lock edges themselves.

**To close.** One spelling of line 0's 2 dots that the lock rows, the STAT
rows, the interrupt rows and the pixel rows accept together. The AGE cells
are the instrument (`agediff.py`); `oam-write`'s residue has not been read
at cell resolution and is not known to be the same 2 dots.

### B2. The CGB palette-RAM lock's edges

**Rows (15).** `cgbpal_m3/cgbpal_m3end_{1,3}`, `_ds_{1,3}`, `_scx5_ds_{1,3}`,
`cgbpal_m3start_ds_1`, `cgbpal_{read,write}_m3start_{ds,lcdoffset1}_1`;
`enable_display/ly0_late_cgbp{r,w}{,_ds}_2`.

**Behaviour.** BCPD/OCPD belong to the PPU during mode 3: reads answer
`$FF`, writes are dropped with the auto-increment still taken (Pan Docs,
"Palettes", CGB). gambatte brackets the lock's edges one M-cycle later than
the VRAM lock's on the read side; the `_ds_`/`lcdoffset1` members and the
`m3end_1/_3` pairs ask for the edge in dots, as C1 does for VRAM.

**Modelled.** `CRAM_LOCK_R = 3` (the latched mode plus the LCD-on line-0
exemption), `CRAM_LOCK_W = 0` (the live mode; the knob is inert on every
cgbpal row). No dot-resolution edge.

**To close.** Bracket the open and close edges in dots from the `_1/_3`
pairs at both speeds, the way `VRAM_READ_M0_OPEN_DOTS` was, then the line-0
members follow B1.

---

## C. Mode 3: locks, window, scroll, objects, palettes

### C1. The VRAM and OAM locks at mode 3's two ends

**Rows (27).** `oam_access/{postread_scx{2,3,5}_2, 10spritesprline_postread_2,
postwrite_2_scx3, midwrite_2, prewrite_{2,ds_2,ds_lcdoffset1_2},
preread_{ds,lcdoffset1}_1}`, `vram_m3/{postread_scx{2,3}_2,
10spritesprline_postread_2, preread_lcdoffset2_1, prewrite_lcdoffset2_1}`,
`vramw_m3end/vramw_m3end_scx3_{3,5}`.

**Behaviour.** The CPU's VRAM and OAM access windows open and close on PPU
dots, not on the CPU's M-cycle boundaries (Pan Docs, "Accessing VRAM and
OAM"). The `postread_*_2` rows read one M-cycle after the mode 3 -> 0 edge at
SCX 2/3/5 or with ten objects and want the lock open; `prewrite`/`preread`
ask the close edge at mode 3's start on CGB and in double speed;
`vramw_m3end_scx3_{3,5}` bracket a VRAM WRITE's last admitted M-cycle.

**Modelled.** Open edge: `VRAM_READ_M0_OPEN_DOTS = 2` / `_DS = 3`,
`OAM_READ_M0_OPEN_DOTS = 2` / `_DS = 3` (AGE-bracketed, B1). Close edge:
`VRAM_READ_LIVE_LOCK = 2` (the DMG's read lock asks the live mode, the
CGB's the latched one; gambatte `vram_m3/preread_2_dmg08_out3_cgb04c_out0`),
`OAM_READ_M3_CLOSE_DOTS = 5`. Writes ask the live mode at their commit point
(`OAM_WRITE_M2_TAIL = 1`: the last M-cycle of mode 2 still takes an OAM
write; mooneye `lcdon_write_timing-GS`).

**To close.** The `postread_*_2` rows are single-speed `_dmg08_cgb04c_out0`
rows that `VRAM_READ_M0_OPEN_DOTS = 2` was expected to take and did not; the
AGE-derived 2 dots and gambatte's read M-cycle have not been reconciled on
them (`-d:gb_dma_trace` prints both). The CGB/DS close-edge rows need the
close in dots, as the open now is.

### C2. The window's mode-3 penalty near the right edge

**Rows (23).** AGE `stat-mode-window/stat-mode-window-{cgbBCE@*, dmgC,
ds-cgbBCE@*}` (7 arms; only the WX 165/166 cells are wrong); gambatte
`window/m2int_wxA5_m0irq_2`, `m2int_wxA6_{m0irq,m0irq2,spxA7_m0irq}_2`,
`m2int_wxA6_{m3stat_3, m3stat_ds_2, scx3_m3stat_2, scx5_m3stat_3,
scx5_m3stat_ds_2, firstline_m3stat_3, spxA7_m3stat_{2,4}}`,
`m2int_wxA6_{oambusyread_2, vrambusyread_3}` (16).

**Behaviour.** A window start costs 6 dots of mode 3 (Pan Docs, "Mode 3
Length"; mealybug `m3_window_timing`'s header). AGE sweeps WX 0..9 and
162..167 with `SCX = LY` and its expected table is byte-identical for WX 1
through 166 on both devices — the restart is charged in full however close
to the right edge the trigger lands. dingbat (`-d:gb_m3_len`, per SCX):

    WX        1..163   164        165      166      167
    CGB       178      178/179    179      180      172
    DMG       178      178/179    179      173      172
    hardware  178      178        178      178      172

**Modelled.** `WIN_TAIL_FETCH`, `CGB_WIN_TAIL_LAST = 1` (the CGB's mode 3
ends with the last FETCH and the DMG's with the last PIXEL, so at WX 166
they part: DMG 174, CGB 180 — gambatte `m2int_wxA6_*_m3stat` brackets the
CGB extra to 5..7 dots) and `DMG_WIN_LAST_PX_CARRY = 1` (a DMG WX = 166
match is owed to the next line; 14 `window/on_screen/wxA6_*` frames).
`OBJ_TAIL_WALK_REFUND` covers an object at X = 167 in the same slot.

**To close.** AGE is a third witness saying the flat 178 is right for both
devices; gambatte's `wxA6` families say the CGB is longer and the `on_screen`
frames pin the DMG carry to the pixel. The three have not been read against
each other, and whatever reconciles them has to keep the 14 frames and
`m2int_wxA6_m3stat_1`.

### C3. Mid-line SCX stores

**Rows (10).** `scx_during_m3/scx_0761c0/scx_during_m3_{2,3,4,ds_2..ds_5}`
(the `_3`/`_4`/`_ds_*` members at ~2400 wrong pixels, `_2`/`_ds_2` at 9),
`scx_during_m3_spx2{,_ds}`, `scx_attrib_during_m3_spx2_ds` (8 px each,
CGB, an object case).

**Behaviour.** The BG fetcher's map column is a live sum
`((SCX + 8k - F) shr 3) and 31` — a store that lowers `SCX and 7` below the
line's latched fine scroll borrows one tile (`SCX_FINE_BORROW`; the DMG
borrows one pixel tighter, `SCX_FINE_BORROW_DMG_LEAD`; AGE `m3-bg-scx` ×3
exact). The fine-scroll discard is a slot counter compared each dot against
the live `SCX and 7`; a store landing above the new value but at or below
the old one is matched only after the counter wraps and runs eight more
slots (`SCX_FINE_LATCH_WRAP = 8`; gambatte `scx_m3_extend_{ds_1,ds_2}` write
SCX twelve times on one line and bracket the edge to two dots).

**Not modelled.** Each fetcher stage as two T-cycles with the address latched
in the first and the read in the second, and per-model visibility of an SCX
store inside its own M-cycle — `Assumed; no ROM in the tree pins either`,
and `CGB_SCX_LATENCY = 2` is the one term carried. The `scx_0761c0` residue
is at `F = 7`, where every store lowers the target; `spx2` is an object
fetch under a store.

**To close.** Hardware experiment (b) below measures the extension law
directly. `tools/gbppu/m3len.sh` / `-d:gb_m3_len` give dingbat's side.

### C4. Objects: the X = 167 slot and the CGB's fetch cancel

**Rows (4).** `sprites/10spritesPrLine_10xposA7_m0irq_2` (both devices; ten
objects at OAM X = 167), `sprites/late_disable_ds_1 [cgb]`,
`sprites/enable/late_disable_ds_3 [cgb]`.

**Behaviour.** An object at X = 167 triggers on the line's last pixel and
shares the fetch slot with the tail burst (`OBJ_TAIL_WALK_REFUND`, pinned by
the single-object `xposA7` rows). Clearing LCDC.1 while an object fetch is
in flight cancels it on the DMG (Pan Docs, "Mode 3 Length": the fetch is
abandoned; mealybug `m3_lcdc_obj_en_change_variant` and gambatte
`sprites/sprite_late_*_disable_*` bracket the refund, `OBJ_ABORT_LEAD = 2`,
`OBJ_ABORT_FLAG_HOLD`). `CGB_OBJ_ABORT = 0`: the CGB reference of the same
mealybug ROM wants the full penalty, and the one row cannot separate "no
cancel" from "LCDC.1 reaches the CGB fetcher later"; the two `_ds` rows are
the double-speed members that could.

### C5. Arming the window late through WY

**Rows (30).** `window/arg/late_wy_{FFto0,FFto1,FFto2,10to0}_*`,
`late_wy_{1toFF,2toFF}_*`, `late_scx_late_wy_FFto4_*`,
`late_enable_afterVblank_*`, `window/late_enable_afterVblank_*`,
`window/late_wy_{ds,ds_lcdoffset1,lcdoffset1}_*`.

**Behaviour.** The WY condition is a latch set on the first line where
`LY == WY` while the window is enabled and held for the frame (Pan Docs,
"Window"; `docs/gb-derivations.md`, "the window starts on an equality, and
the WY latch is a level"). On the DMG every failing row is an "arm late"
ROM (WY written to LY in the handler, `FFto*`, `10to*`,
`late_enable_afterVblank`) and every "disarm late" ROM (`1toFF`, `2toFF`)
passes, so the arm deadline is a rule of its own and not a symmetric latch
dot. The CGB's deadline is one M-cycle earlier than the DMG's in 13 of 14
families.

**Modelled.** The level latch; `CGB_WY_LATENCY = 4` (one M-cycle, clipped to
3 dots by `CGB_LATENCY_CAP = 1`), `CGB_WY_LATCH_LATENCY = 0`.

**To close.** A DMG arm deadline separate from the disarm (the families
bracket it to one M-cycle), then the CGB delta on top.

### C6. Window disable and re-enable mid-line on the CGB

**Rows (5).** `window/late_disable_scx5_ds_1`, `late_reenable_scx3_2`,
`late_wx_scx3_2` (CGB), `window/on_screen/wx17_weoff_wxA5_weon [cgb]`
(960 px), `window/on_screen/wxA6_late_we_reenable_3 [dmg]` (916 px).

**Behaviour.** Clearing LCDC.5 mid-mode-3 returns the fetcher to the
background at its next map read (mealybug's PPU notes; `WIN_EN_ABORT = 1`,
DMG and CGB); a CGB window start is revocable for the dots it has run
(`CGB_WIN_REVOKE_LAG = 1`, `CGB_WIN_EN_DEFER = 5`, `DMG_WIN_EN_REVOKE = 1`).
`wxA6_late_we_reenable_3` is the one DMG carry row left: its re-enable at
dot 85 counts one window line too many on the first reactivated line only
(`WIN_CARRY_REACT_LINES = 1` is right on 126 lines and wrong on one).

### C7. The DMG BGP transition pixel

**Rows (8).** `dmgpalette_during_m3/dmgpalette_during_m3_{3,4,5,scx1_4}`,
`lycint_dmgpalette_during_m3_{3,4}`, `scx3/dmgpalette_during_m3_{4,5}` —
144 wrong pixels = one per line, or 1.

**Behaviour.** A DMG BGP write reaches the pixel two dots back as
`old or new` for one pixel (SameBoy issue #65 photographs, mattcurrie 2018;
mealybug `m3_bgp_change` samples BGP once per dot and is exact with it;
daid `ppu_scanline_bgp_1.dmg.png`). It is instance-dependent: daid ships
three accepted DMG references (`_0` old value, `_1` OR, `_2` new value —
GBEmulatorShootout issue #9) and dingbat is pixel-exact on exactly one per
setting. gambatte's references encode the clean edge.

**Modelled.** `MIXER_PALETTE_OR = 1`, `MIXER_PALETTE_BACK = 2` (DMG only; the
CGB's own write dot puts the pixel out of reach). Not a correctness constant
but a DMG-instance choice with no selector; these eight rows are the price
of the mealybug/daid side. Hardware experiment (d) below.

### C8. AGE `m3-bg-bgp-dmgC`, 2 pixels

23038/23040 after `MIXER_PALETTE_OR`; the two pixels are not diagnosed.

---

## D. DMA

### D1. HBlank DMA blocks owed across a halt or a speed switch

**Rows (46).** `dma` 39: `hdma_late_m3halt_m2unhalt_*`,
`hdma_m0halt_late_m3unhalt_scx1_2`, `hdma_transition_{ei_,}halt_*`,
`hdma_transition_halt_m0unhalt_*`, `hdma_late_m0unhalt_{2,ds_2}` (halt);
`hdma_late_m3speedchange_*`, `hdma_m0speedchange_late_m3wakeup_*`,
`hdma_transition_speedchange_*`, `hdma_late_speedchange_inc_*` (speed
switch); `hdma_pc_7ffe`, `late_gdma_pc_7ffe_1` (a transfer while the CPU
fetches at the top of ROM); `hdma_late_enable_{ds_lcdoffset1,lcdoffset3}_2`,
`hdma_disable_display_1`. `irq_precedence/hdma_vs_m0_scx2{,_halt}`,
`late_hdma_vs_{ei,ie}_scx1_2`, `late_hdma_vs_tima_scx{1,2}{,_halt}_1` (7):
a block and an interrupt dispatch contending for the same instant.

**Behaviour.** An HBlank DMA copies one 16-byte block per mode-0 edge while
the CPU is off the bus (Pan Docs, "LCD VRAM DMA Transfers"). The CPU hands
the bus over at three points — its opcode fetch, an instruction boundary,
and halt entry — never on an operand M-cycle (`HDMA_GRANT_FETCH_DOTS`,
`HDMA_GRANT_BOUNDARY_DOTS = 3`; gambatte `dma/hdma_start*` and mealybug
`dma/hdma_timing-C` parameterised by the fetch). A halted CPU's edge
detector holds a CPU-clocked copy of the mode, so a mode-0 edge under a
halt is invisible until the CPU runs again (`HDMA_HALT_M0_BLIND = 1`,
`HDMA_HALT_BLIND_LAG = 2`; `hdma_m3halt_m0unhalt*` vs `hdma_late_m0halt_*`).
A block takes the bus ahead of an interrupt dispatch (`irq_precedence/
hdma_vs_*`, the dispatch's stack push being the DMA's source). Its bytes
land 4 dots after the block (`HDMA_VISIBLE_DOTS`; `hdma_start_ds_1` and
`hdma_start_scx5_2` separate dots from M-cycles).

**Modelled.** All of the above, plus `HDMA_BLOCK_OVERHEAD_BUS = 4`,
`HDMA_WAKE_M0_MARGIN = 8` (fitted: `hdma_late_m0unhalt_{1,2}` wake with 7
and 11 dots of mode 0 left and want no block and a block — neither is room
for a block, so the real rule splits that pair some other way),
`HDMA_SPEEDSWITCH_KILL_W`, `SPEED_SWITCH_FREEZES_OAM_DMA`,
`VDMA_OAM_BUS_CAPTURE`.

**To close.** The halt rows want one statement of which owed block a wake
delivers and when; the speed-switch rows the same across the 2^17-cycle
stall (E1) — today `_1` members pass and `_2`/`_3` members fail, i.e. the
block already owed at the STOP is delivered but its phase is wrong. Trace
with `-d:gb_dma_trace` (FF55 writes, HDMABLOCK, MODE, REGREAD per dot) and
`-d:gb_halt_trace`.

### D2. OAM DMA against the mode-2 scan and the CPU

**Rows (11).** `oamdma/late_sp{00x,00y,01x,01y,39x,39y}_ds_*` (6),
`late_sp39x_4`, `oamdma_src0000_busyint0002` (both devices),
`oamdma_src8000_srcchange0000_busyinc` (both).

**Behaviour.** The mode-2 scan reads OAM entry `n` on dot `2n` and reads
nothing while an OAM DMA owns the OAM bus; the transfer moves one entry per
16 dots (8 in double speed) against the scan's one per 2, so no start
latency can express the rows (Pan Docs, "OAM DMA Transfer"; gambatte
`oamdma/late_sp{00,01,02,39}{x,y}`, sixteen one-M-cycle brackets). A running
transfer is a bus HOLD on the comparator — entries inside the span compare
against the last Y/X latched (`strikethrough` keeps its object 39).

**Modelled.** `OAM_SCAN_DMA_LOCK = 1`, `OAM_SCAN_DMA_HOLD = 1`,
`OBJ_SCAN_DOT_ADJ = 0`, `CGB_OAM_DMA_START_T = 8`, `OAMDMA_HALT_PAUSE = 1`,
`OAMDMA_FREEZE_BUS = 1`, `OAMDMA_WRAM_A12 = 1`, `OBJ_DMA_BUS_LEAD`.

**To close.** The six `_ds` rows read as entry `n` at `2n + 2` in double
speed, which `late_sp02x` refuses at single speed (note at
`OAM_SCAN_DMA_LOCK`). The two `busy*` families are value rows (which byte a
colliding access sees) and are undiagnosed.

---

## E. The KEY1 speed switch

### E1. What the switch does to the divider, the APU tap and interrupts

**Rows (18).** AGE `speed-switch/spsw-tima-{cgbBC@*,cgbE}` (3),
`spsw-ch2-lc-delay-cgbBCE@*` (3), `caution/spsw-interrupts-{cgbBC@*,cgbE}`
(3); gambatte `speedchange/speedchange{,2,5}_ch2_nr52_{1a,2a}{,_ds}` (6),
`sound/ch2_late_reset_nr52_2b{,_ds}` (3).

**Behaviour.** A switch armed by KEY1 and taken by `STOP` resets DIV and
stalls the CPU for 2^17 cycles of the NEW CPU clock while the timer, serial
and OAM DMA keep running — a HALT, not a STOP leaf (Pan Docs, "CGB
Registers", KEY1; gambatte `speedchange_tima00_*` count 128 ticks through
it, `speedchange2_*` twice the real time on the way back). The PPU comes out
8 dots ahead of the CPU clock into double speed and 3 back into single
(`speedchange{,2,3,4,5}_ly44_m3_*`, a ladder in switch count). An interrupt
arriving during the stall ends it; a switch whose HALT is skipped because
one is already pending stops the divider for the oscillator restart
(c-sp's `speed-switch/caution/WARNING.md`). The DIV reset reaches the
divider's slow taps one M-cycle before the fast ones, and CGB-E one tap
lower. After an odd number of switches into double speed the DIV-APU tap
edge arrives one M-cycle late until the APU is powered off.

**Modelled.** `SPEED_SWITCH_STALL_CPU = 131072`,
`SPEED_SWITCH_STALL_RUNS_CPU_CLOCK`, `SPEED_SWITCH_PPU_EXTRA_DOTS = 8` /
`_SINGLE = 3`, `SPEED_SWITCH_STALL_ENDS_ON_IRQ = 1`,
`SPEED_SWITCH_IRQ_LEAF_HOLD_T = 8` (CGB-E half:
`spsw_irq_leaf_hold_short`), `SPEED_SWITCH_DIV_RESET_T = 8` / `_SLOW = 4` /
`SLOW_BIT = 9` (CGB-E: `spsw_div_mid_taps_slow`), `APU_SPSW_TAP_LAG_T = 4`.

**Residue.** Channel 2's length counter expires one M-cycle early in three
of seven switch configurations (`sc`, `sc2_ds`, `sc5`: ends in double
speed, odd switch count) and is exact in the other four, including `sc3`,
which refutes a flat delay; the `speedchange_tima0x` family is internally
unsatisfiable by any stall length (the failures are one tick low, so it is
which cycles the timer sees around the reset). The AGE tables are readable
at cell resolution and have not all been read since the DIV-reset split
landed.

---

## F. Serial and timer

### F1. The eighth shift edge against a CPU access

**Rows (7).** `serial/nopx1_start{,83}_wait_read_if_2`,
`start83_late_div_write_wait_read_if_{1b,2b}` (CGB),
`start_wait_trigger_int8_read_if_{2,ds_2}` (CGB).

**Behaviour.** The shift clock is a falling edge of a divider bit
(Pan Docs, "Serial Data Transfer"); a CPU access meets the shifter before
its own M-cycle's tap edge (`SERIAL_CPU_SAMPLE_T = 0`; gambatte
`serial/start_wait_read_{sb,sc,if}_*`, `nopx1_*`). `SERIAL_TAP_DMG = 4` and
`SERIAL_TAP_CGB = 4`: a 4-T-wide plateau on each SoC, mooneye
`boot_sclk_align-dmgABCmgb` pinning the DMG. Re-seeding the boot divider
instead is refused by GBMicrotest `timer_tima_phase_*` and gambatte `div`.

**Residue.** The CGB's fast-clock arms and the `trigger_int8` ordering; the
whole tap/sample space was swept (24 builds, commit `90accfd5`) and no phase
reaches them, so it is not a phase.

### F2. TIMA reload against a read

**Rows (4).** `tima/tc00_late_tc01_{5,7}` (both devices).

**Behaviour.** Switching TAC's tap reads the newly selected divider bit one
M-cycle before the byte lands and leaves the old tap at the value latched at
the end of the write (`TAC_SELECT_LEAD_T = 4`; `tc00_late_tc01` and
`tc00_tc01_late_tc00_of_2` pin the two halves in opposite directions). `_5`
reads TIMA on the M-cycle dingbat's 4-cycle reload countdown expires and
gets the pre-reload value where hardware has reloaded: the reload window's
interior (Pan Docs, "Timer Obscure Behaviour") is not modelled —
`docs/pandocs-audit.md` A6. Arming the countdown at 5 instead halves the
family.

---

## G. Revision-vocabulary rows, red on purpose

**Rows (2 scored, 4 skipped).** wilbertpol `acceptance/gpu/ly00_mode1_2-C@cgbc`
and `ly_new_frame-C@cgbc` (scored, red); `ly_lyc{,_0,_144,_153}-C@cgbc`
(skipped, in `NotScored`). Their `@agb` arms pass.

**Behaviour.** Three behaviours split at CGB C/D, and AGE ships each as a
ROM pair with per-unit hardware records in the headers: the readable LY 153
-> 0 edge is one M-cycle later on D/E/AGB at single speed
(`ly_read_edge_late`; `ly/ly-dmgC-cgbBC` vs `ly-cgbE`, one byte apart); the
M-cycle of mode 0 between mode 1 ending and line 0's mode 2 exists on every
DMG and CGB <= C and not on D+ (`m1_end_no_mode0`; `stat-mode-dmgC-cgbBC`
vs `stat-mode-cgbE`, the `M1E` byte); CGB D+ hold the LY=LYC comparison the
blind window is leaving (`lyc_compare_hold`). wilbertpol's `-C` is the 2016
fork's hardware GROUP `cgb+agb+ags` with no revision axis, so its four
`ly_lyc*-C` ROMs assert the D+ behaviour for revision C; upstream mooneye
later added the axis and ships no `ly_lyc*` at all (commit `a781e277`).
The C/D placement of `ly_lyc*` is pinned only by comparison; the two
scored rows are the same vocabulary problem and fail for the same reason.

---

## Hardware experiments that would close buckets

The ROMs exist in `tools/gbprobe/` (raw values, no baked expectation,
on-screen hex); what they say in three emulators is in
`docs/gb-probe-oracle-results-2026-08-11.md`, and the catalogue of every
hardware question with its priority is `docs/hwprobe-questions.md`.

* **(a)** Does the STAT mode field report differently to `LD A,(C)` and
  `LDH A,($41)` at the mode 3 -> 0 edge? Settles whether `STAT_M0_FIELD_TAIL`
  (ships 0; gambatte and wilbertpol want a 3-dot field tail that GBMicrotest's
  `LDH` readers refuse, and idiom and suite are perfectly confounded) is
  silicon or an artefact. `probe_a_statidiom.gb`.
* **(b)** How much does a mid-line SCX store lengthen mode 3, as a function
  of where it lands? C3. `probe_b_scxm3.gb`.
* **(c)** `cgb-acid-hell`'s LCDC.4 toggle and daid's BGP band edge on ONE
  frame: does emission separate from the fetch grid by four dots?
  `probe_c_arbitrate*.gb`; the g1 session in `docs/hwprobe-questions.md`
  ("g1 RESULT") read the frame on a GBA SP.
* **(d)** The DMG BGP transition pixel on as many DMGs as can be borrowed,
  with mainboard/CPU markings per unit — C7. The sample size is the
  experiment; no single unit can answer it.

---

## Refuted models (do not re-derive)

Each was built and scored; the refusing ROMs are named so the idea is not
tried again as a knob.

* A uniform STAT-field lag at the mode 3 -> 0 edge (`STAT_MODE0_LAG`): every
  `_2` member of `sprites/*_m3stat` refuses it. At the 2 -> 3 edge
  (`STAT_MODE3_LAG`): `m2int_m2stat/*_ds_2`. A CGB-only 2 -> 3 lead
  (`STAT_MODE3_LAG_CGB = -1`) takes `halt/lycirq_m2stat_2 [cgb]` and is
  refused by five object-free CGB field readers on the same edge.
* Paying the mode-0 field's 3 dots at the EDGE (`M3_END_EARLY`): refused by
  `m0enable` (interrupt, object-free) and GBMicrotest `poweron_stat_*`,
  `win*_a`. Paying them at the field (`STAT_M0_FIELD_TAIL = 3`): refused by
  24 GBMicrotest `win*_b` / `ppu_sprite0_scx*_b` rows. Gating on the read
  idiom (`STAT_M0_TAIL_MAX_MC = 2`) reconciles all three suites and is
  unproven — experiment (a).
* The CGB's mode-0 boundary one M-cycle earlier than the DMG's: 40 gambatte
  families that probe the edge through four instruments are device-equal
  (`vramw_m3end_{1..6}` the sharpest); every family that does flip earlier
  on CGB is a register write racing an edge or a halt.
* A line-0 geometry trim (`LCD_ON_LINE0_TRIM = 2`, `LCD_ON_LINE1_TRIM = -2`):
  refused by mooneye `intr_1_2_timing-GS`, gambatte `m2enable/late_enable_
  ly0_*`, `ly0/lycint152_m2stat_1` and, at cell resolution, by AGE
  `stat-mode-window`, `stat-mode`, `stat-int` and `ly`.
* Line 0's mode-2 STAT interrupt one M-cycle late, or line 0's mode 2 four
  dots short: refused by the same mooneye row and by `m0enable`,
  `vramw_m3end`, `lcd_offset`.
* A readable-LY / comparator split at line 153 (`LY153_SNAP_DOT`,
  `LYC_SETTLE_DOTS` moved apart): every gain reads LY and every loss is a
  LYC = 153 match ending early (`ly_lyc_153-GS`, `line_153_lyc153_stat_
  timing_b`). The CGB snapback relatch at dot 13 for daid: refused by
  `ly0/lycint152_lyc0{flag,irq}_{1,2} [cgb]`, dot 9 bracketed both sides.
* A second M-cycle of OAM-source lead (`STAT_M2_LEAD = 2`): GBMicrotest
  `int_oam_nops`/`int_oam_incs` read one M-cycle under. An LYC-source-only
  lead (`STAT_LYC_LEAD = 1`): six GBMicrotest LYC sleds go one M-cycle early.
* A CGB halt-exit charge (`CGB_HALT_EXIT_MCYCLES = 1`): 42 `tima/*` rows with
  one expected value for both devices refuse any time spent. Sub-M-cycle
  halt leads (`CGB_HALT_PPU_LEAD_DOTS` 1..3): the wake is latched on the
  M-cycle grid, so they are whole M-cycles for a source near a boundary and
  nothing otherwise.
* A CGB-specific OAM DMA start latency (`CGB_OAM_DMA_START_T = 4`): 103
  `oamdma` rows pin 8 T. The `late_sp*` rows as a start latency: unmoved
  from 4 T to 40 T.
* A per-block HDMA delay of one M-cycle (rather than 4 dots of data hold):
  `hdma_late_disable_{2,scx2_2,scx3_2}` and the `hdma_late_m3speedchange_*`
  ladder read the block's bus occupancy where it is.
* The SCX extension as a pipeline stall (`SCX_STORE_STALL_DOTS`): 65 PNG
  rows — a stall displaces pixels from the store's dot, the borrow from the
  next fetch boundary. Counting discard slots without `and 7`: mode 3 runs
  off the end of the line.
* `$D000-$DFFF` aliasing `$C000` as a banking rule: contradicted by the two
  SVBK ROMs; the 64 rows were the DMA driving A12 (`OAMDMA_WRAM_A12`).
* Mode 3's LENGTH as the cause of the `NspritesPrLine` family: the per-object
  cost is exactly Pan Docs' `6 + max(0, 5 - ((X + SCX) mod 8))`
  (`tools/gbppu/objtab.py` 153/153 against GBMicrotest `ppu_spritex_vs_scx`),
  and every double-speed member passes; the family measures the STAT
  readback.
* A frame-level mystery in `window/arg/late_wy_*`: 13 of 14 families have
  different expected values per device, shifted one M-cycle, and the CGB is
  EARLIER — a positive CGB delay moves it the wrong way.
* `m0enable` as a STAT-phase bucket: zero rows move under any STAT
  experiment; it is the write-commit boundary and a DMG/CGB split of zero.
* `mgb_oam_dma_halt_sprites` as a unit-specific corruption pattern: the
  phantom sprite is a BUS value (`OAMDMA_FREEZE_BUS`), the `& $FC` is
  measured by the reference frame, and `OAMDMA_FREEZE_DEST_LEAD` is a
  one-word plateau.
* `rtc3test-1`/`-3` as an RTC defect: the local harness sampled at frame 570
  where the shootout's budget is 925.

---

## Closed buckets

One line each; the knob or commit carries the derivation.

* Line 0's pipeline one M-cycle ahead (125 PNG rows): `LY0_PIPE_MCYCLES`,
  later subsumed by `STAT_M2_LEAD = 1` + `M3_PIPE_AHEAD = 1` (the OAM
  source rises one CPU M-cycle before its line, and the pipeline with it;
  `a554e7fc`, `f95f47f2`).
* `$FEA0-$FEFF` is RAM on CGB 0-D (`addr and not $18` on 0-C), nibble echo
  on E: `GbUnusableRegion`, `d7e34678`; `cgb-acid-hell`'s own readback gate
  pins the mask.
* HDMA source outside cartridge/WRAM moves `$FF`: `a7b6355`,
  `dma_hiram_read_result`.
* The dispatch's IF clear at T = 16: `IRQ_SAMPLE_T` (A2 is what it left).
* The LY=LYC comparator blind while LY changes, at every line edge and the
  vblank entry: `ly_advance_close`, `LY_BLIND_SCOPE = 2` (`60b13d59`,
  `044129ca`).
* A `$FF0F` read's sample point inside its M-cycle: `IF_READ_SAMPLE_T`
  (`36e0bcc1`; now spelled in `irq_read`, interrupts.nim).
* The VRAM read lock's live-mode clause is DMG-only: `VRAM_READ_LIVE_LOCK =
  2` (`689cf7e3`).
* STAT readback samples the mode at `cc - 2` (`cc - 3` in double speed):
  `STAT_READ_SAMPLE`, `STAT_READ_SAMPLE_DS_ADD`; GBMicrotest 404 -> 430 and
  the `NspritesPrLine` family with it.
* The mode-0 STAT source's 2 dots in the retire -> flag hand-off:
  `STAT_M0_LEAD_T = 2` (`12be5e40`); AGE `halt-m0-interrupt` and `stat-int`
  (single speed) with it.
* The OAM scan against an OAM DMA: `OAM_SCAN_DMA_LOCK`, `OAM_SCAN_DMA_HOLD`
  (`f426688b`, then the hold); `strikethrough` kept.
* The speed switch's two clocks and the PPU's 8/3 re-alignment:
  `SPEED_SWITCH_STALL_CPU`, `SPEED_SWITCH_PPU_EXTRA_DOTS{,_SINGLE}`
  (`6668e5e5`, `47b3c223`); landed with `CGB_HALT_PPU_LEAD = 1`
  (`bc9afb1c`), which also closed `cgb-acid-hell` and the shootout's 261st
  row. The DIV reset one M-cycle after the STOP fetch, and its slow-tap
  split: `SPEED_SWITCH_DIV_RESET_T{,_SLOW}` (`c1b05bb6`, `fa813824`).
* The CGB OAM DMA drives the address bus (A12 into WRAM): `OAMDMA_WRAM_A12`
  (`6668e5e5`), the 64 `busypush`/`busypop` rows.
* HBlank DMA bytes land 4 dots late: `HDMA_VISIBLE_DOTS` (`23f9e672`); the
  hand-off at the fetch grant: `HDMA_GRANT_FETCH_DOTS` (`3b6e34e7`), mealybug
  `dma/*` green; a halted CPU's blind mode-0 edge: `HDMA_HALT_M0_BLIND`.
* The LY 153 -> 0 snapback's LYC = 0 edge, blind window and read snap:
  `LYC_SETTLE_DOTS`, `LYC_SRC_RELATCH_LEAD`, `LY153_READ_SNAP` (`8b099948`);
  GBMicrotest 480/480 (`bbf916af`), daid `ppu_scanline_bgp` DMG exact.
* The readable LY edge splits at CGB C/D; `$FF44` on the advance dot reads
  `LY & (LY + 1)`; the mode-0 M-cycle at the end of mode 1 is CGB <= C too:
  `ly_read_edge_late`, `LY_EDGE_AND`, `m1_end_no_mode0` (`351e82ac`,
  `08d34522`). AGE `ly`, `lcd-align-ly`, `stat-mode` green.
* The line-144 OAM STAT source is a pulse; CGB D+ hold the LY=LYC
  comparison; the CGB takes an LYC write one M-cycle later:
  `M2_144_PULSE`, `lyc_compare_hold`, `CGB_LYC_WRITE_DEFER` (`31a683e4`,
  `84ca126c`, `79612ed5`, `731ba498`); wilbertpol `ly_lyc*` cluster.
* A halted OAM DMA drives the OAM bus: `OAMDMA_FREEZE_BUS` (`6766b0be`);
  mooneye 152/152.
* SameSuite APU 70/70: `pcm_read_edge_zero` (CGB <= C), `square_freq_
  backstep_halftick` (CGB D/E), the suite scored on CGB-E as its README
  says (`f0e64749`).
* The mealybug DMG set, every row: `OBJ_BG_RUN = 4` (the object fetch takes
  a tile boundary the object picks), `M3_THROWAWAY_DOTS = 4`,
  `MIXER_PALETTE_OR`, `MIXER_TAIL_HBLANK`, `MIXER_TAIL_DOTS`,
  `MIXER_HEAD_LINGER`, `BG_EN_AT_MIX`, `WIN_LINE_START_WX = 6`,
  `WIN_START_PRE_PIXEL`, `WIN_HEAD_ABSORB`, `WIN_LINE_START_LATCH`,
  `WIN_WX0_PHASE`, `WIN_PRE_PX_PHASE`, `WIN_EN_ABORT`, `WIN_REACT_PHASE`,
  `obj_yields_to_window`, `OBJ_PLANE1_LAG` (LCDC.2 read once per bitplane),
  `fifo_obj_abort`. The CGB set: `CGB_TDSEL_LATENCY`, `CGB_TDSEL_GLITCH`
  (reset = tile index, set = the bus address latch), `CGB_TDSEL_IDX_DOTS`,
  `CGB_MAP_LATENCY = 2` (`a75fb13e`), `CGB_OBJ_SIZE_LATENCY`,
  `CGB_MIXER_LATENCY` / `mixer_write_immediate` (the C/D palette dot).
  Per-test account: `docs/gb-mealybug-sources.md`.
* `scx_during_m3` 49 -> 131: `SCX_FINE_BORROW{,_DMG_LEAD}`,
  `SCX_FINE_LATCH_WRAP` (C3 is the rest).
* The DMG's last-pixel window start owed to the next line:
  `DMG_WIN_LAST_PX_CARRY`, `WIN_CARRY_TILE`, `WIN_CARRY_REACT_LINES`
  (`76009b29`); `window/on_screen` 34/36.
* The OAM scan reads LCDC.2 once per object, two dots apart, and the CGB
  takes a second look one M-cycle earlier: `OBJ_SCAN_DOT_ADJ`,
  `CGB_OBJ_SCAN_LEAD` (`4c7764dc`); all 24 `sprites/late_sizechange*`.
* The arriving TAC tap read a cycle early; `EI; HALT` with `IF & IE`
  arms the halt bug: `TAC_SELECT_LEAD_T`, `ime_set_cycle` (`35751364`).
* A TIMA overflow reaches a running CPU one M-cycle before a halted one:
  `TIMER_IRQ_RUN_LEAD` (`3f4670d8`).
* The serial shift clock is a half-rate toggle the SC write reseeds, and a
  CPU access meets it before its own tap edge: `SERIAL_TAP_*`,
  `SERIAL_CPU_SAMPLE_T` (`e20afbbf`).
* The CGB window start is revocable; the DMG revokes for one dot:
  `CGB_WIN_REVOKE_LAG`, `DMG_WIN_EN_REVOKE` (`ed9fe0f6`, `32854ba7`).
* The OAM X = 167 object charged for the tail walk twice:
  `OBJ_TAIL_WALK_REFUND` (`04c6f808`).
* GBMicrotest's 31 verdict-less ROMs and 2 broken expectations, mooneye
  `utils/`, `bootrom_dumper`: skipped by name, in `NotScored`.
* AGE's DMG arms were running on a CGB (the cart header picked the machine):
  `dmg: not arm_cgb` in `build_age_tests` (`0fe22983`). The same trap cost
  the blargg `oam_bug` rows earlier (`--dmg`).
* `rtc3test-1`/`-3`: the local harness now uses the shootout's own frame
  budget (`93b49768`).
* `mooneye/misc/boot_hwio-C@agb`: the AGB boot table (`8774472a`).
* The CGB revision axis at runtime (`--cgb-rev`, `GbQuirks`): `d7e34678`;
  design in `docs/gb-hardware-revisions.md`.
