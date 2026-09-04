# gbedge APU pages (2026-09): what to photograph and what it settles

Six pages appended to `gbedge.gb` (`tests/roms/gbedge.py`), pages **1B-20**,
all aimed at APU constants that dingbat currently carries with a
"**Assumed; no ROM pins this**" comment or that a Pan Docs audit row lists as
unresolved. Nothing before page 1B was touched: the 27 pre-existing pages are
byte-identical before and after, on `--dmg` and on `--cgb` alike.

Build:

```
python3 tests/roms/gbedge.py     # -> gbedge.gb (LEFT/RIGHT paging)
                                 #    gbedge-auto.gb (page++ every 64 frames)
```

The probes take about **273 frames (4.5 s)** to run before the viewer appears
— the sweep and length pages are literally waiting for frame-sequencer events,
and consecutive sweep steps are 8192 M-cycles apart. A blank screen for four
and a half seconds after power-on is normal, not a hang; `$FF80` holds the
running probe index if it ever really is one. Of those 273 frames **214 belong
to the 27 pre-2026-09 pages** and 59 to the six here; the poll caps and row
counts below are chosen against that budget, because
`tests/clip_replay_test.nim` runs this ROM for 420 frames and needs the viewer
up and taking input inside them.

dingbat's own answers for every page are in
`tests/roms/expected/predicted-gb-2026-09/` (`pages.txt` = CGB-C,
`pages-cgbE.txt` = CGB-E/AGB, `pages-dmg.txt` = DMG). **Those are predictions,
not measurements.**

## The measurement convention

The value of these pages is entirely in their cycle counts, so all six are
built from the same four moves (see the helper block above `@test("CH2PHASE")`
in `gbedge.py`):

* **APU power cycle** — `NR52 = $00` then `$80`. Zeroes NR10-NR51, parks every
  frequency timer, puts both squares' duty position and CH3's wave pointer
  back to 0, restarts the APU's 1 MHz tick grid and sets the frame-sequencer
  stage to 0. Wave RAM survives it. Every row of every page starts with one,
  so no row can inherit anything from the row before it.
* **DIV anchor** — `xor a / ldh ($04),a`. **Cycle 0** of every count on these
  pages is the M-cycle that write lands on. The internal divider restarts
  there, so the DIV-APU tap (internal bit 12, 8192 T) falls 2048 M later and
  every 2048 M after that. With the sequencer stage zeroed just before:

  | event | cycle | stage | what runs |
  |---|---|---|---|
  | #1 | 2048 | 0 | length |
  | #3 | 6144 | 2 | length + **sweep** |
  | #5 | 10240 | 4 | length |
  | #7 | 14336 | 6 | length + **sweep** |
  | #8 | 16384 | 7 | **envelope** |

  so length steps are 2048 then every 4096 M, sweep steps 6144 then every
  8192 M, envelope steps 16384 then every 16384 M.
* **A write named for a cycle** is the third M-cycle of `ldh (n),a` — the bus
  write itself. **A read named for a cycle** is the third M-cycle of
  `ldh a,(n)`. Where a page sweeps `k` it is sweeping that one cycle by one
  M-cycle per row.
* **Poll counts.** Two loops read NR52 bit 0 until it clears: a fine one of
  **15 M** per poll storing a 16-bit count (lo, hi), and a coarse one of
  **317 M** per poll storing one saturating byte (`$00` = the channel was
  already off on the first poll). One sweep step is 8192 M ≈ **26 coarse
  polls**; one length step is 4096 M ≈ **273 fine polls**. Each loop's cap is
  set per page and is *also* that page's cost, since a row that never dies
  runs to the cap: `$08` on SWPPHASE's restart rows (which only have to answer
  "did it die at all"), 40 on its control row, 200 on NR10PACE, `$0400` on
  NOISEWAVE and `$0200` on SEQRESET. A byte or word equal to the page's cap
  means "still playing", not a measurement.

---

## Page 1B `CH2PHASE` — channel 2's trigger phase (CGB/AGB only)

`apu/channel2.nim` says of `ch2_pcm_edge_zero` and `ch2_reload_is_now`: *"no
channel_2 build of the ROM measures it. Assumed"* — they are channel 1's
constants copied across. This page is that build. PCM12 (`$FF76`) carries CH1
in the low nibble and CH2 in the high one; a power cycle leaves CH1's DAC off,
so every byte reads `x0` and `x` **is** channel 2's 4-bit output.

Row settings: NR21 duty 3 (`$C0` — low only on the position a power cycle
leaves behind, so the first duty step is the first non-zero byte), NR22 `$F0`,
NR23 `$F8` (freq $7F8 → a duty step every 8 M), NR24 `$87`.

| bytes | meaning |
|---|---|
| 00-0F | `k` = 0..15: PCM12 read `k+3` M-cycles after the NR24 trigger, channel starting from **off** |
| 10-1D | `k` = 0..13 counted from a **second** NR24 trigger written 68 M after the first (a restart of a running channel) |
| 1E | NR52 after the last row (`$x2`) |
| 1F | `EE` = not CGB/AGB |

**What it pins.** The k of the first `F0` is `gb_trigger_deadline`'s start-up
delay at 1 M resolution: `period + extra_ticks` with **2** extra ticks from
off and **1** on a restart (`apu/abstract_channels.nim`), plus the 1 M the
write takes to reach the APU's 1 MHz grid (`gb_apu_edge`). The *difference*
between the two rows' edges is that extra tick on its own, independent of
every other constant. A byte reading `00` where both neighbours read `F0` is
the CGB 0/A/B/C PCM read glitch on the channel-2 side —
`GbQuirks.pcm_read_edge_zero` through `ch2_pcm_edge_zero`, the assumption this
page exists for.

**dingbat.** CGB-C: `00`×8 then `F0`×8, and `00`×7 then `F0`×7 — the read that
lands exactly on the step is zeroed by the glitch. CGB-E: one k earlier in
both rows (`00`×7 / `00`×6), because the glitch is off from CGB D. **So the
C-vs-E difference is one byte of shift per row: photograph this page on a
CGB-C and a CGB-E (or AGS) and the pair settles `ch2_pcm_edge_zero`
outright.** If neither console shows the shift, the glitch is a channel-1-only
effect and `ch2_pcm_edge_zero` should go.

## Page 1C `SWPPHASE` — sweep restart phase and the sweep-delay split

Two things: `channel1.nim:242` (*"A pending sweep stop does not survive the
restart (only reachable when the trigger lands on the calculation's cycle).
Assumed"*), and the split of the 8 M-cycles SameSuite `channel_1_sweep*`
measures into `GB_SWEEP_SHADOW_DELAY` (2 M), `GB_SWEEP_CHECK_DELAY` (7 M) and
`GB_SWEEP_STOP_DELAY` (1 M) — the sweep half of hwprobe row 14.

Setup: NR10 `$11` (pace 1, increment, shift 1), duty 2, volume `$F`, freq
**1024** (`$400`), triggered on cycle 40. The trigger's own check computes
1024 + 512 = 1536 and passes; the sweep step on **6144** computes 1536, writes
it back, and its trailing check computes 1536 + 768 = 2304 > `$7FF`, which is
what stops the channel (~cycle 6152). The restart is `NR13 = $00` followed 5 M
later by `NR14 = $80`, so the restarted channel's frequency — and therefore
its shadow — is 0 whichever side of the writeback that pair falls on (1536 =
`$600` also has a zero low byte). A zero shadow computes 0 forever, so nothing
the *restarted* channel does can stop it again.

| bytes | meaning |
|---|---|
| 00-0E | `k` = 0..14: the restart's NR14 write lands on cycle **6139+k** (5 M before the sweep calculation through 9 M after it, past the check at 6151 and the stop at 6152). Coarse poll count from 6 M after the restart, **cap 8** |
| 0F | the same row with **no restart**, polled from cycle 45, cap 40 — the control that says the sweep really does stop this channel |
| 10-1E | (CGB/AGB) `j` = 0..14: PCM12 read on cycle **6136+j**, 1 M apart — the waveform itself at CPU resolution across a sweep writeback. NR10 `$1F` (pace 1, **decrement**, shift 7), freq `$7FE`: a 2 M duty step until the writeback stretches it to 17 M |
| 1F | `EE` = not CGB/AGB (00-0F still ran) |

**What it pins.** In 00-0E, any byte that is not `$FF` is a pending stop a
trigger could not cancel, and its k is the cycle the stop becomes
irrevocable — i.e. where the shadow load, the trailing check and the stop
actually sit inside those 8 M-cycles. In 10-1E, the last edge of the running
2 M waveform and the first frozen sample bracket the cycle the new period
takes effect on: the `reload_now` race in `sweep_step` (`channel1.nim` ~147),
which is the same race `channel1.nim:212` assumes for a frequency write.

**dingbat.** 00-0E: `08` — the cap, i.e. still playing — in all fifteen: a
restart before the check re-arms the check with the zero shadow, one between
check and stop clears the pending stop, one after the stop re-enables the dead
channel. 0F: `14` (20 polls ≈ cycle 6152), so the control fires. 10-1E: `0F 0F` then `00` thirteen times —
the high step ends on 6138 and the writeback on 6144 freezes the position it
lands on, so the high step an unfrozen 2 M waveform would show again on 6146
never arrives. On DMG only 00-0F runs and reads the same.

## Page 1D `NOISEWAVE` — noise divisor codes 5-7, DMG's wave window

The other two thirds of hwprobe row 14.

| bytes | meaning |
|---|---|
| 00-0F | divisor codes 0-7 (lo, hi per code): NR43 = `$40 | code` (shift 4, 15-bit), NR44 `$80`, then a 14 M poll of PCM34 (`$FF77`) until channel 4's **high** nibble goes non-zero, capped `$0400` |
| 10-1F | `k` = 0..15: `$FF30` read `k+3` M-cycles after a CH3 trigger. Wave RAM preloaded with `01 12 23 ... EF 00` (no byte is `$FF`), NR32 `$20`, freq `$7FD` |

**Noise.** A trigger loads the LFSR with `$7FFF` and the output is the
*inverted* bit 0, so the channel starts silent and goes loud on exactly the
15th shift: the count is 14.5 LFSR periods plus the trigger delay, a direct
ruler of the divisor. `ch4_frequency_timer` makes the period `8 T` for code 0
and `16·code T` otherwise; `gb_noise_deadline` says outright *"Codes 5-7 are
not exercised by any test and follow the >= 2 case"*. Codes 1-4 (which
SameSuite does exercise) calibrate the ruler; **5, 6 and 7 must come out at
5:6:7 against them, and their trigger alignment must follow the same 512 kHz
grid rule, or `gb_noise_deadline` needs a case for them.** On DMG `$FF77`
reads `$FF` and every row reads `00 00` — the no-PCM-readback fingerprint, not
a measurement.

**Wave.** `$7FD` steps the wave pointer every **6 T**, deliberately not a whole
M-cycle: the fetch grid and the CPU's coincide only every 12 T, which is what
makes a window tied to the fetch reachable at all (at a 4 T-multiple period it
never is, and every read comes back `$FF` whatever the window). `ch3_wave_open`
(`apu/channel3.nim`, `GB_WAVE_ACCESS_WINDOW = 2 T`) says DMG lets the CPU
through only in the half-cycle after a completed fetch. The pattern's **phase**
is the window's position; how many of each three bytes are readable is its
**width**. Sixteen `$FF` means the window is narrower than 2 T or does not line
up this way; sixteen wave bytes means DMG has no window at all and
`ch3_wave_open`'s DMG branch should go.

**dingbat.** Noise: `0021 0042 0085 00C7 0109 014B 018E 01D0` = 33, 66, 133,
199, 265, 331, 398, 464 — code 0 at half of code 1, then dead linear in the
code, codes 5-7 included. Wave, DMG: `01 FF FF 12 FF FF 23 FF FF 34 FF FF 45
FF FF 56` — every third byte open, the wave byte walking as the pointer moves.
Wave, CGB: `01 01 12 12 12 23 23 23 ...` — the access always resolves, so the
row is just the pointer.

## Page 1E `ENVPHASE` — Pan Docs audit A9 (CGB/AGB only)

*"envelope timer gets +1 when a trigger lands just before an envelope step"*;
dingbat's `init_volume_envelope` sets `timer = period` unconditionally, so an
envelope step one M-cycle after a trigger still counts. Pan Docs' +1 moves the
first volume change a whole envelope period (16384 M) later.

Both rows ask the same question — *did the envelope step on cycle 16384
count?* — with the same encoding, **`02` = yes, `01` = no**, and each reads the
volume **once**, as the OR of eight PCM12 reads 5 M apart. With an 8 M duty
period those eight span five periods, so the OR is the channel's volume
however the duty phase falls.

| bytes | meaning |
|---|---|
| 00-07 | `k` = 0..7, NR12 `$19` (start volume 1, increment, **period 1**): the trigger lands on cycle **16380+k**, 4 M either side of the envelope step, and the volume is read on cycle **16896** |
| 0F | NR52 after the first row (`$F1`) |
| 10-13 | `k` = 0..3, NR12 `$1A` (**period 2**), trigger on **16382+k**, volume read on cycle **33280** — the same question one envelope period further out, where a missed step moves the *first* volume change rather than landing on the next one |
| 1F | `EE` = not CGB/AGB |

**What it pins.** The k at which each row steps from `02` to `01` is the cycle
a trigger stops arming in time for the envelope step it precedes — the arming
boundary at 1 M resolution. A row that is *all* `01` is Pan Docs' +1. Two
different periods disagreeing the same way is what says the **timer** moved and
not the step. Row 2 is four rows rather than eight because at two envelope
periods each of its rows costs twice the boot time.

**dingbat.** 00-07: `02 02 02 02 01 01 01 01`; 10-13: `02 02 01 01`. Both flip
where the trigger lands exactly on cycle 16384, i.e. a trigger on the envelope
step's own cycle does not get that step and one M-cycle earlier does.
Identical on CGB-C and CGB-E.

## Page 1F `NR10PACE` — Pan Docs audit A10 (every model)

*"NR10 pace 0 → nonzero write reloads the sweep timer"*. dingbat's NR10 write
stores fields only, so the timer keeps the count it has been running since the
trigger — with pace 0 that count started at 8 (`channel1.nim`: *"if
sweep_period > 0: sweep_period else: 8"*) and reaches zero on the **eighth**
sweep step whatever the write does. Pan Docs' reload puts the first
calculation `pace` sweep steps after the **write**. The two disagree by up to
seven sweep steps, and — more usefully — they disagree in *shape*.

Setup: NR10 `$01` (pace 0, increment, shift 1), duty 2, volume `$F`, freq 1000
(`$3E8`), triggered on cycle 2560. Sweep steps at 6144 + 8192n. The first
calculation that runs writes back 1500 and its trailing check computes 2250 >
`$7FF`, so the channel dies ~8 M after the sweep step that runs it; the
trigger's own check (1500) is safe. Bytes are coarse poll counts (317 M, cap
200) from 6 M after the NR10 write, or after the trigger in 10-12.

| bytes | meaning |
|---|---|
| 00-02 | `j` = 0, 3, 6: pace `$11` written on cycle **6656 + 8192j** |
| 08-09 | `j` = 0 and 6 again, with pace **7** (`$71`) |
| 10-12 | calibration: pace 1, 2, 4 written *before* the trigger, polled from the trigger — death is then `pace` sweep steps after it |
| 1C | NR52 at the end of the page |

Every row of 00-09 waits for the same death on cycle 63496, 3.6 frames of boot
time each; there are five of them because two `j` values would answer A10 and
three make the staircase a staircase. The rest of the page is zero.

**What it pins.** A **descending staircase** in 00-02 (one death seen from a
start that moves three sweep steps per row) means the timer kept its running
count: dingbat is right and A10's sentence is wrong. A **flat** row means the
write reloaded it. 08-09 decides it a second time and independently of any
absolute count: if those two bytes match 00 and 02 the new pace was ignored;
if they sit seven sweep steps out it was loaded. 10-12 is the ruler that turns
every byte on the page into sweep steps.

**dingbat** (identical on DMG and CGB): 00-02 `B4 66 19` = 180, 102, 25; 08-09
`B4 19` — the same first and last byte as 00-02; 10-12 `0C 26 59` = 12, 38, 89,
so one sweep step ≈ 26 polls; 1C `F0`. Pan Docs' reload would instead give ~24
three times in 00-02 and ~179 twice in 08-09, with 10-12 unchanged.

## Page 20 `SEQRESET` — the frame sequencer across an NR52 off/on (every model)

Does the master power switch reset the DIV-APU sequencer? dingbat zeroes the
sequencer **stage** on power-on but keeps its **timing** on DIV (`apu.nim`),
and sets `first_half_of_length_period = div_skip`, where `div_skip` is
SameSuite `div_write_trigger_10`'s rule: powering the APU up while the DIV-APU
tap bit is already set makes the first event do nothing.

Each row: APU off, DIV anchor, APU on at cycle **128 + 256d**, then
NR51/NR50/NR11/NR12/NR13 and an `NR14 = $C4` trigger (length enabled) 30 M
later, then the 15 M NR52 poll (cap `$2000`). Length steps are at 2048 then
every 4096 M; a skipped first event pushes them to 4096 and every 4096 M.

| bytes | meaning |
|---|---|
| 00-0F | `d` = 0..7 (lo, hi per d), NR11 `$BF` → length counter **1**: the channel dies on the first length step. Fine poll, cap `$0200` |
| 10-1F | the same eight power-on phases with NR11 `$BE` → counter **2**, so a clock at trigger time cannot kill it and the expiry is always measurable |

**What it pins.** A **sawtooth** — 17 polls (256 M) less per row — is the whole
answer to the question: the sequencer's clock is DIV's and the power-on only
moves the stage. A **flat** row would mean the power-on restarts the clock
itself, which nothing in dingbat models. Where row 1 turns to the cap is the
DIV-APU tap bit (M-cycle 1024 = internal bit 12) seen through
`first_half_of_length_period`: with the tap bit already set at power-on the
trigger's own length-enable write clocks the counter from 1 to 0, and the
trigger then reloads the zeroed counter to 64, so the channel outlives the
poll. Row 2 separates "the event was skipped" from "the counter was clocked
early", because there the extra clock only costs one length step.

**dingbat** (identical on DMG and CGB): 00-0F = `007E 006D 005C 004B` (126,
109, 92, 75) for d = 0..3 and `0200` (the cap) for d = 4..7. 10-1F = `018F
017E 016D 015C` (399, 382, 365, 348) for d = 0..3 — dying at 6144, the second
length step — and `00C2 00B1 00A0 008F` (194, 177, 160, 143) for d = 4..7,
dying at 4096 with the first event skipped and one count spent at the trigger.

---

## Reading a photograph against this

1. The `ALL` line changes with these pages (six more slots feed the global
   CRC16), so the `all:` in the older `expected/gb-*.txt` transcriptions is
   stale for the new ROM. Per-page `CRC` lines are not affected.
2. `EE` at `+1F` on 1B, 1C, 1E means the console has no PCM readback (DMG/MGB
   /SGB). Those pages' NR52-only halves still ran.
3. Every count on these pages is a poll count, not a time: multiply by 317 M
   (coarse) or 15 M (fine) to get M-cycles, or by 26 / 273 respectively to get
   sweep / length steps. A count equal to the page's cap (listed above) means
   "still playing", not a measurement.
4. Where hardware and dingbat differ, the *shape* of a row (staircase vs flat,
   the k at which an edge sits) is the finding; the absolute count carries the
   poll loop's own constant with it.

## Not covered

* **`channel1.nim:212`'s own case** — the `square_freq_backstep_halftick`
  duty-position undo — is only reachable at **CGB double speed**, where a
  frequency write can land half an APU tick after a duty step. Page 1C
  measures the sweep writeback's version of that race at single speed, which
  is the same `reload_now` question, but not the D/E half-tick itself; that
  needs a double-speed page of its own (see `DSTAT` for the speed-switch
  machinery it would reuse).
* **`GB_SWEEP_CHECK_DELAY` and `GB_SWEEP_STOP_DELAY` as separate numbers** are
  only bounded by page 1C, not read off it: the coarse poll resolves 317 M, so
  the split shows up as *which k* can still cancel a stop, not as a directly
  printed 7 and 1.
* **NR10PACE's fine row** — a pace write walked over the sweep step's own
  cycle at 1 M resolution, to see whether the step it lands on takes it — was
  cut for boot time: it costs 3.6 frames per row and only means anything if
  hardware says "reload" in the first place. If 00-02 comes back flat, that
  row is the follow-up.
* **The AGB GB-slot column** is not captured separately here: dingbat's AGB GB
  slot runs the CGB core, so `pages-cgbE.txt` is the prediction to diff an
  AGS photograph against (hwprobe row 16 already closed the AGS GB slot as
  byte-identical to MGB for the sweep page).
