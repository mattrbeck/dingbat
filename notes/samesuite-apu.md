# SameSuite APU: what its sources assert, and how the GB APU models it

Status: SameSuite APU 70/70, blargg dmg_sound 12/12, cgb_sound 12/12 (`tests/results.md`).
Rows whose filename names a revision (`-cgb0B`, `-cgbDE`, `-A`, …) are scored on that
revision via `--model`; the rest on CGB E, the revision the suite's README says passes
everything (`tests/README.md`, device axis; `docs/gb-hardware-revisions.md`).

```
./dingbat_test <rom> --mode=mooneye --color --model=cgbE --timeout=3000
./dingbat_test_runner --apu        # the whole sub-suite plus both blargg sound suites
```

SameSuite uses the mooneye convention (`LD B,B`, then B=3 C=5 D=8 E=13 H=21 L=34). ROMs
ship in the test-ROM bundle under `same-suite/apu/`.

## Method: read the source, not the pixels

Every SameSuite APU test carries a comment at the top of its `.asm` stating the hardware
behaviour it measures, in cycles, and a `CorrectResults` `db` table. The model below is
derived from those sentences and tables; nothing was fitted to a reference image. Two
caveats learnt the hard way:

- The prose can be right about the observable and wrong about the rule.
  `channel_4_delay` says "sample length + 3 M-cycles"; the rule that produces its whole
  table is `period/2 + 2`, and the two agree only at the one sample length the author
  measured. Solve the table, then check the rule against a test it was not derived from.
- Headers are copied between channels (`channel_4_align.asm` says "channel 1";
  `channel_1_stop_div.asm`'s text appears in the channel_2 copy). Strong evidence, not proof.

Sources: `github.com/LIJI32/SameSuite` at `f15645fb049a47ea235f6d2c9a033e72d8087901`
(`apu/<channel>/<test>.asm`; `include/common.inc` has the `nops` macro, a `call` into a
nop slide exact to the M-cycle). gambatte's ROM sources are in
`github.com/pokemon-speedrunning/gambatte-core`, `test/hwtests/`; their `.text@<addr>`
directives land a write on an exact cycle, which is the only way to know what a
`_1a`/`_1b` pair brackets.

To read a failure as data, dump WRAM from `RESULTS_START` (`$c000` in most tests, `$c006`
in `channel_4_lfsr_restart`) after running the ROM headless and diff it against
`CorrectResults`. `tools/gbapu/ssdump` does this.

## Two things easy to get wrong

- **FF76/FF77 must catch the channels up before reading.** The PSG channels advance
  lazily; PCM12/PCM34 are observation points. Reading them without syncing returns the
  phase from whenever the channel was last touched.
- **Do not reset `frame_sequencer_stage` on APU power-off.** Pan Docs ("Power Control")
  resets the sequencer on power-on; adding it to power-off costs
  `blargg/cgb_sound/08-len ctr during power`.

## Double speed

Most tests run in double speed (`ld a,1 / ldh [rKEY1],a / stop`); `channel_1_delay`,
`channel_1_restart`, `channel_1_duty_delay`, `channel_4_delay`,
`channel_4_frequency_alignment` and the `div` family do not, which makes them the
cross-checks. One `nop` = 4 CPU cycles = half an APU tick in double speed, a whole one in
single; `nops N` is exactly N M-cycles. M-cycle stepping is sufficient resolution for
every test here.

## Catalogue

### Pulse channels (`channel_1`, `channel_2`)

| source | assertion | model |
|---|---|---|
| `channel_1_align_cpu` | channel 1 is aligned to the APU's **enable** time, not the CPU's start | `GbApu.tick_phase` is set by NR52 power-on; `gb_trigger_deadline` rounds a trigger up to that grid |
| `channel_1_align` | ticks at 1 MHz | `gb_apu_tick` |
| `channel_1_delay` | (sample length + 2) ticks from enable until PCM12 changes; the read itself takes 2 cycles | `gb_trigger_deadline(..., 2)`. Also pins the duty table: Pan Docs' `01111110` for duty 3, indexed from position 0 |
| `channel_1_restart` | a restart's start delay is 1 tick shorter; the new pulse's first sample is the next the old would have played | `extra_ticks = 1` when already on; position untouched |
| `channel_1_duty` | duty patterns listed rotated left by one from Pan Docs | same machine, different zero. `channel_1_delay` refuses both rotating the table and seeding the position at 1 |
| `channel_1_duty_delay` | a duty change takes effect after the current sample | `sample_bit` latches the duty bit once per step |
| `channel_1_freq_change` | a frequency change takes effect after the current sample | `next_step` is absolute. Exception: a write on the reload cycle (below) |
| `channel_1_stop_restart` | stopping keeps the phase; only NR52 off resets it | `ch1_catchup_at` parks `next_step` while disabled |
| `channel_1_volume_div` | envelope ticks after 8 × (NR12 & 7) DIV-APU ticks | matches |
| `channel_1_nrx2_speed_change` | envelope speed changes apply after the next tick; enabling the envelope triggers an extra envelope tick on the next **even** DIV-APU tick | `env_extra_tick`. Hardware's "even" is dingbat's odd `frame_sequencer_stage` (the counter increments before the step); the other parity passes tests 3/4/5 and fails 6/7 |
| `channel_1_nrx2_glitch`, `channel_1_volume`, `channel_1_restart_nrx2_glitch` | the NRx2 write ("zombie mode") glitch | the three-column table below |
| `channel_1_stop_div` | like channel 3 with a smaller length range | follows from the DIV-APU work |
| `channel_1_sweep`, `_sweep_restart`, `_sweep_restart_2` | sweep overflow timing, restarts during sweep | below |
| `channel_1_extra_length_clocking-cgb0B` | on CGB ≤ B the extra length clock needs only a previously-disabled counter; fixed on CGB C | `GbQuirks.length_clock_any_nrx4`, on `--model=cgb0B` only |
| `channel_1_freq_change_timing-A/-cgb0BC/-cgbDE` | (no header) three per-revision builds | write-vs-reload rule below; the per-revision cells are `GbQuirks.pcm_read_edge_zero` (CGB 0–C) and `GbQuirks.square_freq_backstep_halftick` (CGB D/E) |

**The sweep's second overflow check is 8 M-cycles late and re-reads NR10.** Pan Docs
("Frequency sweep") describes one indivisible step: compute, disable on overflow, else
write back and compute again. `channel_1_sweep` annotates the block where its channel
goes quiet, 8 nops past the sweep tick, "8 cycles after trigger, the APU checks if the
NEXT trigger overflows the frequency"; `channel_1_sweep_restart` rounds 3–5 each open
with "the channel should stop after 8 cycles, but we <change NR10> before then", and
zeroing NR10 cancels the stop (round 3) while changing only the shift does not (4, 5).
So the gate is the shift read 8 M-cycles later, not the period — which it must be, since
a trigger arms the check with period 0 (blargg cgb_sound `06-overflow on trigger`). The
first calculation is not delayed (`channel_1_sweep_restart_2`, shift 0, stops with no
grace). A trigger's own immediate check gets the delay plus one APU tick: the write is
latched on a tick edge and the countdown starts on the next (`channel_1_sweep_restart`
round 2: nine M-cycles, not eight). Code: `GB_SWEEP_CHECK_DELAY`, `ch1_sweep_check_due`,
the arm in `ch1_write`.

Trap: a lazily-evaluated check that can clear `enabled` must run on every reader of
`enabled`. blargg's `sync_sweep` polls NR52 for the overflow disable
(`cgb_sound/07-len sweep period sync`), so an NR52 read runs the pending check.

**A register write and a timer reload on the same cycle: the write wins.**
`channel_1_freq_change_timing` triggers CH1 at `$7fc`, writes NR14 = 0 after N nops to
stretch the period, and reports the sample right after the write and the one it settles
on. Its single-speed row falls out of one rule: when an NR13/NR14 write lands on the exact
cycle the frequency timer reloads, the reload takes the value being written — the duty
position still advances, but the sample that was about to play never does. One M-cycle
later the pending sample is left alone (`channel_1_freq_change`). Detecting the tie needs
`last_step_at`: a trigger's start delay is `period + 2 ticks`, so a write two M-cycles
after a trigger leaves `next_step` exactly one period out and would look like a reload
(`channel_1_freq_change` row 2). Mirrored onto CH2 by symmetry (no channel_2 build
exists), and onto the sweep unit, which writes the same register pair from the one path
outside `ch1_write`: `channel_1_sweep_restart` round 1 runs at `$7ff` (one M-cycle per
step) so its sweep tick always lands on a reload, and without the rule every step after
it sits one M-cycle early. `ch1_reload_is_now` is the discriminator.

**Zombie mode.** The Pan Docs rule (+1 when the old period was 0 and the envelope still
updating, else +2 when the old direction was decrease) is one column of a three-column
table selected by the value being **written**. Solved from `channel_1_volume`'s 128-byte
table and cross-checked on `channel_1_nrx2_glitch` (write 1024 M-cycles after trigger,
old periods 2 and 7):

|  | new dec, per 0 | new dec, per ≠ 0 | new inc |
|---|---|---|---|
| old per 0, dec | 0 | −1 | +1 |
| old per ≠ 0, dec | 0 | 0 | +2 |
| old per 0, inc | 0 | +1 | +1 |
| old per ≠ 0, inc | 0 | 0 | 0 |

The table is at `write_NRx2`. It is not revision-dependent on CGB E, which is what the
suite's README documents.

### Channel 3

| source | assertion | model |
|---|---|---|
| `channel_3_delay` | (wavelength/32) + 3 ticks from enable until PCM34 changes | the `+6` T-cycles at trigger |
| `channel_3_first_sample` | skips the first wave sample; a one-tick delay plus one "phantom" sample | trigger sets `wave_ram_position = 0`; the first step advances to 1 (low nibble of byte 0) |
| `channel_3_restart_delay` | a mid-sample restart uses the same delay; the previous sample keeps playing through the phantom | a plain trigger does NOT clear the sample buffer |
| `channel_3_restart_stop_delay` | stop then start behaves like a fresh start | with the row above: turning the DAC off (NR30) is what clears the sample buffer |
| `channel_3_freq_change_delay` | a wavelength change applies to the next sample | matches |
| `channel_3_shift_delay`, `_shift_skip_delay` | the shift applies at once (≤ 2 ticks) and cannot shorten the delay | shift applied at read time |
| `channel_3_stop_delay` | NR30 stop affects PCM34 instantly | matches |
| `channel_3_stop_div` | the stop timer is DIV-APU driven; length is ((255 − NR31) × 2 + 1) ticks | DIV-APU work below |
| `channel_3_wave_ram_locked_write` | written at the offset CH3 is reading; ignored on AGB | CGB case modelled; AGB case not, no row asks |
| `channel_3_wave_ram_sync`, `_wave_ram_dac_on_rw` | PCM34 and wave RAM agree; RW while DAC on and channel off | match |
| `channel_3_and_glitch` | CH3 is not affected by the PCM34 AND glitch | dingbat has no AND glitch; this row fails silently if one is added |
| `channel_3_extra_length_clocking-cgb0/-cgbB` | CGB 0 needs ONE write to disable at length 1, CGB B TWO | per `--model`; see `docs/gb-hardware-revisions.md` §3.2 |

Pan Docs, "Power Control": a power-on resets the frame sequencer, the duty units, and
the wave channel's sample buffer to 0. Without the last, every CH3 subtest after the first
reads the previous subtest's wave byte through the whole startup delay.

### Channel 4

| source | assertion | model |
|---|---|---|
| `channel_4_lfsr`, `_lfsr15`, `_lfsr_15_7`, `_lfsr_7_15` | LFSR algorithm and width switching | `lfsr = 0x7FFF` at trigger with `output = not bit0` is the bit-complement of the `lfsr = 0` convention; setting it to 0 "on restart" per `channel_4_lfsr_restart` would break three passing rows |
| `channel_4_volume_div` | as the pulse version | matches |
| `channel_4_align` | ticks at 1 MHz | trigger goes through `gb_trigger_deadline` like the squares |
| `channel_4_delay` | "sample length + 3 M-cycles, maybe ±1" | `period/2 + 2` — a trigger's first period is half-length (a divide-by-two flip-flop the trigger clears); a restart leaves it alone and waits a full period, which is the one-step offset between `channel_4_lfsr`'s table and `_lfsr_restart`'s |
| `channel_4_frequency_alignment` | nine NR43 encodings, with and without an extra nop, annotated affected / not | the split is `divisor_code == 0`: code 0 starts on the 1 MHz tick, code 1 rounds UP to the 512 kHz grid, code ≥ 2 rounds DOWN. The grid sits on the odd 1 MHz ticks from APU power-on (`GbApu.noise_phase`), which is why every subtest power-cycles the APU. Codes 5–7 are unexercised and follow the ≥ 2 case |
| `channel_4_equivalent_frequencies` | equivalent encodings produce the same output bar a start-delay off-by-one | one encoding per rounding case, 512 nops deep; the cross-check for the noise model |
| `channel_4_lfsr_restart`, `_restart_fast` | LFSR cleared on restart | the tables are `channel_4_lfsr`'s shifted by one step: a restart's first sample takes a full period |
| `channel_4_freq_change` | NR43 changed mid-flight; "the logic is still unclear" | two-counter model below |

**The noise timer is two counters.** `channel_4_freq_change` plays periods of 4 and 16
M-cycles through four NR43 encodings each, switches encoding mid-note at two trigger
phases, and walks PCM34 an M-cycle at a time; one counter with one deadline gives the same
answer for all four, its 64 bytes want eight. The circuit: a divisor stage incrementing a
counter every 4 T-cycles for code 0 and every `8 × code` otherwise (half the documented
divisor), and a free-running counter whose bit `clock_shift` clocks the LFSR on its rising
edge (every `2^(shift+1)` increments). They multiply to the documented period, and the
halving is the code-0 carve-out `channel_4_frequency_alignment` derived independently. An
NR43 write re-interprets both stages: the shift picks a different bit of the count already
reached, and the divisor countdown keeps running, reloading with the new divisor only when
it expires — except a write on the exact increment cycle, where the reload is the new
divisor rounded up onto the 512 kHz grid. Code: `GbChannel4.div_counter` / `div_next`,
`ch4_steps_to_rise`, the NR43 arm of `ch4_write`; `gb_noise_deadline` stays the trigger's
single source of truth. The divisor stage is advanced lazily (`ch4_advance_divisor`) —
eagerly it cost measurable instructions for state nothing reads between writes.

### DIV-APU (`div` family)

| source | assertion | model |
|---|---|---|
| `div_write_trigger` | writing DIV while bit 4 is set triggers a DIV-APU event | the event already existed (`timer.nim`); a power-on must also settle `first_half_of_length_period`, or every NRx4 write after power-on does an extra length clock |
| `div_write_trigger_10` | starting the APU with DIV bit 4 set skips the first DIV-APU event | `GbApu.div_skip` |
| `div_write_trigger_volume`, `_volume_10`, `div_trigger_volume_10` | (no headers) | pin the skip's shape |

"Skip the first event" means: the event performs nothing, the sequencer does not advance,
AND the extra-length-clocking gate reads "the next step does not clock length" while the
skip is pending. Not "start at step 1" (puts the envelope's first tick on the seventh
event; two tests want the ninth) and not "run but do nothing" alone (fails
`div_write_trigger_10`'s length column). `first_half_of_length_period` is a property of
the divider, not of `frame_sequencer_stage`, and a skip is the state where they disagree.

## blargg dmg_sound: the DMG axis

- **Wave RAM access (09, 12).** Pan Docs, "Wave RAM": on DMG, wave RAM is accessible only
  on the cycle CH3 reads it; otherwise reads return `$FF` and writes are ignored.
  `ch3_wave_open` is the two T-cycles after a completed fetch; `wave_fetched` exists
  because a trigger reloads with `period + 6` and no byte is read during that window.
- **Restart corruption (10).** Pan Docs: restarting CH3 while it reads wave RAM corrupts
  the first four bytes. The window is the other half of the same sample cycle — the two
  T-cycles ending at the fetch; a single shared window passes 09/12 or 10, never both.
- **Power (08, 11).** Pan Docs, "Power Control": a power-off clears the length counters
  on CGB and leaves them untouched on DMG, where NRx1 stays writable while off.

## Unserialized state

These fields are not in the save state; each is refreshed within one duty period, one
power cycle or one 512 Hz step, is CPU-visible only through PCM12/PCM34, and is written
only by a register write or a power-on, so a rollback snapshot that replays the write
reconstructs it. Serialising them costs a GB payload revision bump; if one happens for any
reason, add all of them:

`GbApu.tick_phase`, `GbApu.div_skip`, `GbApu.noise_phase`, `GbChannel1/2.sample_bit`,
`GbChannel1/2.last_step_at` (cleared by `apu_rebase`), `GbChannel1.sweep_check_at`
(cleared on CH1 state load so a stale deadline cannot fire against loaded registers),
`GbChannel3.wave_fetched`, `GbVolumeEnvChannel.env_extra_tick`, `GbChannel4.div_counter` /
`div_next` (re-derived from the restored `next_step` by `ch4_resync_divisor`),
`GB.revision`, and `GbMemory.unusable` (the 96 bytes of `$FEA0-$FEFF` a CGB 0–D answers
reads from; plain RAM, the weakest member on principle, but only test ROMs are known to
seed it). See `docs/gb-hardware-revisions.md` §2.5.
