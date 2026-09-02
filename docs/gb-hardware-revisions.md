# Game Boy hardware revisions in dingbat

How a silicon revision is selected, how behaviour hangs off it, what each flag
is pinned by, and which parked clusters a revision cannot reach. The table
itself is `gb_quirks_for` in `src/dingbat/gb/gb.nim`; each flag's evidence is
at its declaration in `GbQuirks`.

## 1. The axis

- **`GbRevision`** is the selector: `grDmg0, grDmgABC, grMgb, grSgb, grSgb2,
  grCgb0, grCgbAB, grCgbC, grCgbD, grCgbE, grAgb`. One orderable token, named
  the way the suites name things (mooneye `boot_regs-cgb0`, AGE
  `ei-halt-dmgC-cgbBCE`, SameSuite `-cgb0B`).
- **`GbQuirks`** is the implementation: a plain object of flags on the `GB`,
  filled once by `gb_quirks_for(rev)`. Emulation code reads flags, never the
  revision: a flag names the behaviour at the site, two revisions that share
  a behaviour share a flag instead of a set literal that breaks when a
  revision is inserted, and a flag is a load where a range check in a hot
  path can move clang's inline decision (`docs/gb_oam_dma_cost.md`).
- **`GbBootModel` is derived**, not parallel: it selects a boot-handoff
  register table, and mooneye's filenames show that table is coarser than
  the silicon (one `boot_regs-dmgABC`, one `boot_regs-cgbABCDE`).
  `gb_boot_model_for(rev)` is many-to-one; `gb_set_revision(gb, rev)` is the
  only way to change the machine's identity and sets all three fields
  together.
- A revision that names no flag behaves like the default machine, so filling
  the enum ahead of evidence costs nothing; a flag without a ROM behind it is
  unverifiable code and is not added.

### Selection

`--model=<token>` in the test harness, parsed by `gb_revision_from_name`,
accepts the suites' own tokens (`dmg0`, `mgb`, `S`, `A`, `cgb0`, `dmgC`,
`cgbBCE`, `cgb0B`, `cgbDE`, `cgb0BC`, …). A range token resolves to its
**highest** member: the newest silicon that still shows the behaviour is the
strongest claim the ROM makes, and it keeps SameSuite's `-cgb0` / `-cgbB` CH3
pair on two different revisions. `--cgb-rev=<0|A|B|C|D|E>` is sugar over
`--model` for the CGB axis. The runner picks the revision from the filename
for mooneye (`mooneye_model_for`), AGE (`age_device_tokens`) and SameSuite
(`samesuite_model_for`); unsuffixed ROMs run on the default.

There is no `Config` field and no GUI selector, and there must not be one
before `revision` is serialized (§3): a state carries no revision byte, and
two of the flags below are game-visible.

### Default: `grCgbC` on CGB hardware, `grDmgABC` on DMG

The default is the revision the references are captured from:

- mealybug's scored CGB set is `_cgb_c`; the `_cgb_d` set beside it differs
  (`m3_scy_change` by 6217 px, `m3_bgp_change` by 864 px);
- `CGB_MIXER_LATENCY = 1` is pixel-exact on `m3_bgp_change_cgb_c.png` and
  864 px out on `_cgb_d`;
- `cgb-acid-hell`'s reference is a C-class capture and the ROM picks its tile
  data off a `$FEA0` readback only a CGB C answers that way;
- mooneye `boot_regs-dmgABC`, `boot_div-dmgABCmgb` and
  `stat_irq_blocking` ("pass: DMG ABC, MGB, CGB, AGB, AGS / fail: DMG 0").

SameSuite `apu/README.md`'s "CPU-CGB-E – passes all tests" does not make E
the default: its per-revision ROMs carry their own `--model=` token and never
ran on the default, and the pixel references above are C.

### Cost

Resolution happens once at construction. The flag reads sit in register-write
paths (NRx2, NRx4, PCM reads, LY/STAT edges), none per dot. Measured at the
retired-instruction floor (`docs/gb_oam_dma_cost.md` method).

## 2. The flags

| flag | revisions | pinned by |
|---|---|---|
| `length_clock_any_nrx4` | CGB 0, A/B | SameSuite `channel_{1,2,4}_extra_length_clocking-cgb0B`, `channel_3_extra_length_clocking-cgb0` (§2.1) |
| `mixer_write_immediate` | CGB D, E | mealybug `m3_bgp_change` `_cgb_c` vs `_cgb_d` (one pixel per write edge = the `CGB_MIXER_LATENCY` dot); LCDC keeps the dot on every revision because the LCDC ROMs' two captures are byte-identical |
| `scy_fetch_latch` | CGB D, E | mealybug `m3_scy_change`: live-per-read is pixel-exact on `_cgb_c` and 6217 px wrong on `_cgb_d`; a per-fetch latch at the map read is the exact inverse (`docs/gb-mealybug-sources.md` §3.4) |
| `pcm_read_edge_zero` | CGB 0–C | SameSuite `channel_1_freq_change_timing-{A,cgb0BC,cgbDE}`: cells 4 and 15 put a PCM12 read on a rising duty step and read `$0f` only in the `-cgb0BC` table; `apu/README.md` states the scope (§2.3). The one flag true on the default |
| `square_freq_backstep_halftick` | CGB D, E | see declaration |
| `lyc_compare_hold` | CGB D, E, AGB | see declaration |
| `ly_read_edge_late` | CGB D, E, AGB | AGE `ly-*` / STAT rows split at C/D; see declaration |
| `m1_end_no_mode0` | CGB D, E, AGB | the mode-0 M-cycle at the end of mode 1 is present on CGB ≤ C; see declaration |
| `oam_read_open_late` | CGB E | see declaration |
| `spsw_div_mid_taps_slow`, `spsw_irq_leaf_hold_short` | CGB E | speed-switch rows; see declaration |
| `unusable_region` | all | Pan Docs, "Memory Map" → "FEA0–FEFF range": DMG/MGB/SGB `urZero`, CGB 0–C `urRamMasked`, CGB D `urRamPlain`, CGB E/AGB `urNibbleEcho`. Not a bool; its CGB default is the one place the default machine differs from the pre-revision one |

`grAgb` is deliberately absent from `mixer_write_immediate` and
`scy_fetch_latch`: no AGB capture of those ROMs exists, and the AGE `agb`
rows are scored against the current behaviour.

### 2.1 Extra length clocking (CGB ≤ B)

SameSuite's shared header: "Extra length clocking occurs when writing to NRx4
when the frame sequencer's next step is one that doesn't clock the length
counter. In this case, if the length counter was PREVIOUSLY disabled and now
enabled and the length counter is not zero, it is decremented. On revisions
<= CPU CGB B, the length counter only has to have been disabled before; the
current length enable state doesn't matter. This breaks at least one game
(Prehistorik Man), and was fixed on CPU CGB C." The ROMs write NRx4 = $00
(CH3: $03), bit 6 clear, and still expect the counter to move; the flag drops
the `and len_enable` term. A green `-cgb0B` row on the default would mean the
default is wrong.

### 2.2 CH3 on CGB B needs two NRx4 writes — not modelled

`channel_3_extra_length_clocking-cgbB`: "On CPU CGB, CH3 requires ONE write to
disable the channel when the length counter is 1. On CPU CGB B, CH3 requires
TWO writes." Its `CorrectResults` row N is `-cgb0`'s row N−1 throughout. Two
mechanisms fit identically (the counter loading one higher; the first extra
clock after a trigger being swallowed) and they differ in ordinary
length-counter behaviour that no ROM discriminates, so no flag is landed.
`grCgbAB` therefore passes `channel_3_extra_length_clocking-cgb0`, which a
real CGB B would fail.

### 2.3 PCM read glitch (CGB ≤ C)

SameSuite `apu/README.md`: "A quirk in CPU-CGB revisions C and older makes
registers PCM12 and PCM34 report a glitched PCM amplitude for channels 1, 2
and 4 if they're read in the same M-cycle they change." `pcm_read_edge_zero`
models the square-channel rising-edge case the `freq_change_timing` ladder
pins; channel 4 is not pinned by any ROM in the tree.

## 3. Save states

`revision`, `quirks` and `GbMemory.unusable` are not serialized; `boot_model`
never was (all are construction-time properties of the machine a state is
loaded into). A state saved on `--model=cgb0` and loaded by a default process
runs on a CGB C, silently, which costs a pixel (the palette dot) and 96 bytes
of `$FEA0–$FEFF`. Reachable today only from the test
harness, which does not save states. The fix is one byte, `revision`, next to
`cgb_enabled` in `GB_SEC_MEM`, older states reading back the default, going
through `gb_set_revision` on load; it rides the batched GB payload bump listed
in `docs/samesuite-apu.md` "Unserialized state".

## 4. What a revision does not fix

- **NRx2 "zombie mode" is one rule on every revision.** SameSuite
  `channel_1_volume`'s 128-byte `CorrectResults` (trigger, rewrite NRx2 two
  M-cycles later, read PCM12) solves to an increment `d` applied before the
  `16 − volume` flip:

  | old period / direction | new = dec, period 0 | new = dec, period ≠ 0 | new = inc |
  |---|---|---|---|
  | period 0, decrease | 0 | −1 | +1 |
  | period ≠ 0, decrease | 0 | 0 | +2 |
  | period 0, increase | 0 | +1 | +1 |
  | period ≠ 0, increase | 0 | 0 | 0 |

  Pan Docs, "Audio Details" → "Obscure Behavior" (+1 when the old period was
  zero and the envelope still updating, else +2 when the old direction was
  decrease) is exactly the right-hand column; the other two are keyed on the
  value being written. `channel_1_nrx2_glitch` (second write 1024 M-cycles
  later, periods 2 and 7) is the independent check. Only CGB E is tested
  upstream ("Currently, only revision E is tested and documented"); no ROM
  asserts a DMG or CGB ≤ D variant, so none is modelled. Site:
  `apu/abstract_channels.nim`.
- **mealybug's `_dmg_b` captures** (`m3_lcdc_bg_en_change`,
  `m3_lcdc_win_en_change_multiple_wx`, the only two) differ from `_dmg_blob`
  by 228 px and 3 px; dingbat's error on the same rows is 2193 px and
  4215 px. Not a revision problem.
- **GBMicrotest's SCX family** carries two overhead rows (DMG and AGS) in
  its own header while every ROM is built `-DDMG`; the split is not a
  revision axis but the halt-woken versus running reader of one edge —
  `docs/gb-test-suite-sources.md`, "GBMicrotest".
- **`channel_1_freq_change_timing-A` and `-cgbDE`** share one expected table;
  both are red on the default, so that is a default-machine bug, ahead of
  any revision work.
- **Other splits the suites name but no scored ROM reaches:** CGB pre-D vs D+
  LCD-on failure mode (mooneye `lcdon_timing-GS.s`), CH3 wave-RAM locked
  write ignored on AGB (SameSuite `channel_3_wave_ram_locked_write`), SGB
  (a subsystem, not a revision). DMG 0 vs ABC (`stat_irq_blocking`) and the
  CGB-only DI delay (`di_timing-GS.s`) were already keyed on `bmDmgABC` /
  `cgb_enabled`.

## 5. Testing

`TestDef.model` becomes `--model=`. The default run exercises `grDmg0`,
`grMgb`, `grSgb`, `grSgb2`, `grCgb0`, `grCgbAB`, `grCgbC`, `grCgbD`, `grCgbE`
and `grAgb` across mooneye, AGE and SameSuite rows. A ROM that should pass on
several revisions and fail on others is not expressible (each ROM is scored
once, at one revision); the extension when needed is one `TestDef` per named
device, as `build_age_tests` already does for its screenshot rows.
