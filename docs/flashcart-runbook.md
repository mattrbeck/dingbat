# flashcart-runbook: the GB hardware session

**Date:** 2026-08-17. Run `tools/make-flashcart-kit.sh` (needs the
game-boy-test-roms cache; any suite run populates it) and copy
`flashcart-kit/` to the SD card. This runbook is ordered by payoff and
keyed to the available consoles: **GBC (board -04), GBP (MGB), GBA,
GBA SP** — the GB flashcart works in the GBA/SP's GB slot (CGB-compat
mode on AGB silicon; gbedge's MODEL line reads `11 01` there). **The GB
Micro has no GB slot** — it only helps if a GBA-slot flashcart shows up,
in which case `tests/roms/gbaedge.gba` is its job (new AGB-revision data).
No DMG and no SGB in the set: the MGB covers the mono side (its boot
seeds differ from DMG's — that's data, not a problem); SGB-only rows stay
open.

**Two caveats before starting.**
- *Menu pollution:* if the flashcart boots a menu and soft-launches ROMs,
  every boot-handoff capture (gbedge p00 IDENT, p01 DIVPHASE) reads the
  menu's exit state, not the boot ROM's. If the cart has a
  "power-cycle into last game" or hard-reset-to-game mode, use it for
  those two pages; otherwise still photograph them (cross-console deltas
  survive a constant menu) but mark them menu-tainted.
- *No mapper tests:* the flashcart's FPGA answers MBC questions, not
  Nintendo silicon — MBC5 $1A-enable, MBC3 latch, MBC30 banking are NOT
  testable this way (docs/hwprobe-questions.md tier 4 says the same for
  $FEA0). Those need real carts.

## 1. gbedge.gb — the bulk of the session (folder 1)

Protocol in docs/hwprobe.md ("Hardware protocol"): page with LEFT/RIGHT,
photograph; one photo of any page fingerprints the run via `ALL`.
Order: **GBC first, then GBA (or SP), then GBP.** On the GBA and SP,
photograph page 00 on both — if `ALL` matches, one full set covers both
(an earlier AGS session exists under `tests/roms/expected/agb-sp-1/`, so
the SP may already be half-covered; the current 27-page build re-covers
everything).

Priority pages if the session gets cut short (per hwprobe-questions):
**00, 02, 03, 15, 16, 17, 18, 12, 1A** —

| page | settles |
|---|---|
| 00 IDENT | post-boot P1/SC three-way split (Pan Docs $C7·$CF/$7F vs dingbat/DocBoy $FF/$7C vs SameBoy $7E — pandocs-upstream §2), SVBK/RP/OPRI/FF72-77 readback, boot register fingerprint, which CGB revision the "-04" board actually carries |
| 02 TIMAGLITCH | **the CGB TAC-disable tick** (audit A5): Pan Docs says CGB skips it, no emulator models that — the GBC photo vs the GBP photo IS the answer |
| 03 TIMARELOAD | the glitch-overflow window interior (A6): position/width of the TIMA=$00 window + write-in-window rules |
| 15 M1STAT | hwprobe row 3 (~42 rows) |
| 16 HALTPHASE | rows 2 + 5 (~21 rows + two parked knobs) |
| 17 WYLATCH | row 4 — the DMG-vs-CGB WY sample split (~26 rows) |
| 18 CGBWRAM | row 1 — the $D000 SVBK alias vs banking (64 rows) |
| 12 PCMPSG | CGB revision discrimination (C vs E) — read this before trusting any per-revision conclusion from the -04 board |
| 1A SWEEP | row 17 — is the second sweep overflow check AGB-only? Compare the GBC page against the GBA page directly |

## 2. windesync — the window insertion glitch (folder 2; hwprobe row 19)

nitro2k01's ROM (SameBoy issue #278; D-pad menu, hold A + direction to
change values). Run on **GBP and GBC** — the SGB traces are the only
existing captures, so both consoles are new device axes. Three questions:

1. **Arming.** With the window never enabled at all (don't touch the
   enable toggle), park WX=$07/WY=$00 over the test pattern: any glitch
   column? (Emulators say no — Pokemon Blue is the field evidence; Pan
   Docs' enable-free Y condition says yes.) Then enable-once-and-disable
   via the LYC toggles and confirm the glitch appears.
2. **Insert vs replace.** With the glitch active over the `%01000111`
   pattern: does everything right of the glitch pixel shift one pixel
   right (insert — SameBoy/DocBoy), or does the pattern stay aligned with
   only the one pixel recolored (replace — dingbat, from the mealybug
   readback)? Photograph close-up.
3. **Device axis.** Same setup on the GBC: SameBoy says CGB doesn't do
   this at all; DocBoy says it does mid-window-fetch only.

Cross-check with folder 3's `m3_lcdc_win_en_change_multiple_wx.gb` on the
GBP — the two white pixels at t=8/t=32, background alignment either side
of them, close-up photo. And `m2_win_en_toggle.gb` on the **GBC**: Pan
Docs' CGB note says clearing LCDC.5 resets the frame's Y condition (no
emulator models it) — if true, the CGB rendering of this ROM differs
from its DMG reference in exactly the lower toggled bands.

## 3. strikethrough.gb (folder 3; hwprobe row 18 — biggest single payoff)

Run on GBC **and** GBP. Photograph the whole frame, then close-up of
**LY 68, screen x 71..78** (the OAM-entry-39 box). The bundled reference
draws the sprite there even though an OAM DMA covers that line's mode 2;
three built-and-refused dingbat mechanisms (57-75 gambatte rows) die on
whether silicon really draws it. Also arbitrates the reverted A13
phase-swap family indirectly.

## 4. rapid_toggle.gb (folder 4)

Mooneye prints its verdict on-screen. Run on GBP (expect the DMG-family
result) and on **GBC** — together with gbedge p02 this pins A5. Note
mooneye tests encode DMG-family expectations; a CGB "fail" screen is
still data — photograph the register dump.

## 5. CRAM lock edges (folder 5 — GBC only)

Every ROM displays a raw value; the filename's `_outXX` is what the
gambatte reference hardware (a CGB-C class unit, "cgb04c") showed. Two
uses:
- The 11 rows dingbat still fails (`cgbpal_m3end_{1,3}*`,
  `*_ds_*`, `*_lcdoffset*`, `cgbpal_m3start_ds_1`,
  `cgbpal_read/write_m3start_ds_1`, `..._lcdoffset1_1`): photograph the
  displayed value — that is the dot-level edge data the shipped
  `cpu_cram_open` model (CRAM_LOCK_R=3) is missing.
- If the -04 board turns out to be CGB-D (page 12), any row whose value
  differs from its `_out` suffix is a **revision split** nobody has
  recorded — photograph everything that disagrees.
The 8 `ly0_late_cgbp*` rows re-check the line-0 exemption on real
silicon.

## 6. oamdma phase family (folder 6 — GBC only)

The A13 arbiter. dingbat + the cgb04c references currently agree that
`*_ds_2`-phase rows show the sprite value and `_ds_1` don't; modeling
Pan Docs/SameBoy's CGB obj-fetch-while-disabled rule swapped every
sibling pair. Run each ROM, note which phase shows which value. If the
hardware values match the filenames, the reference stands and the
SameBoy-shaped model needs a one-fast-M-cycle phase term before it can
ship; if any differ, that's a revision split worth every photo.

## 7. APU (folder 7)

- `channel_3_restart_stop_delay.gb` on GBC: dingbat clears the CH3
  sample buffer on NR30 DAC-off citing this ROM; SameBoy and DocBoy
  preserve the buffer. Photograph the result screen — someone's coverage
  is thin.
- `channel_1_sweep_restart{,_2}.gb` on GBC **and** GBA: the GB-slot
  side of the AGB sweep question (pairs with gbedge p1A).
- The HPF-charge question (Pan Docs' per-model constants) is analog:
  if a line-out/headphone recording rig is around, a note that decays to
  silence recorded on GBP vs GBC vs GBA is enough to fit the two
  constants. Otherwise skip.

## Session 1 results — 2026-08-17, GBP (MGB) + GBA SP, gbedge.gb complete

All 27 pages photographed on both consoles; transcribed to
`tests/roms/expected/gb-mgb-1.txt` / `gb-agbsp-1.txt`, every page verified
against its on-screen CRC-16/CCITT (init $FFFF) — zero read errors. gbedge
is a CGB-flagged cart, so the SP ran CGB-NATIVE mode (MODEL 11 01, ALL
052C); the MGB ran DMG-family (MODEL FF 00, ALL 3FE7). No menu pollution:
both P00 pages carry clean boot-handoff values.

**MGB vs dingbat (`--model mgb`): 22 of 26 content pages byte-identical.**
The four mismatches, all small and coherent:
- **P06 SERIAL** bytes 00/02/03 (hw 64/63/46 vs 5D/64/40) — the parked
  serial start-phase cluster's raw counts (gb.nim `start_wait_*`).
- **P0F UNUSED** bytes 1C/1D read 50, dingbat 51 — one LSB.
- **P15 M1STAT** byte 08 reads mode 0 (hw E0, dingbat E3) and byte 1B mode
  2 (hw E2, dingbat E3) — the 42-row m1 bucket's exact signal, and the SP
  shows the IDENTICAL bytes (F5C8 both consoles): one model truth.
- **P19 DIVTAPS** bytes 08/09 (hw 88 00, dingbat 00 20) — also identical
  across both consoles.
Two worries in the known-divergences list above DISSOLVED: P03 TIMARELOAD
and P05 IEPUSH match hardware byte-for-byte on both consoles.

**AGB-native new data (no dingbat reference yet — the gbedge viewer white-
screens under `--model cgb/agb`, a dingbat bug to fix first):**
- **P00 IDENT**: P1 = $CF (dingbat's AGB table hands off $FF — fix),
  SC = $7C (dingbat/DocBoy right; Pan Docs $7F and SameBoy $7E wrong),
  SVBK = $F8 (the 45a2d0f raw-readback fix is what silicon does),
  RP = $3E on an SP with no IR window (dingbat leaves it unmapped → $FF),
  VBK $FE / KEY1 $7E / FF75 $8F / OPRI $FE / DIV $1F / LY $91 / STAT $81.
- **P18 CGBWRAM**: byte 0A = **5C — the $D000 window really BANKS** on
  AGB (banks 2-7 all distinct, SVBK 0→1 alias only). hwprobe row 1's
  64-row alias assumption is refuted on this silicon; the CGB arm still
  wants the GBC run.
- **P1A SWEEP**: byte-identical to the MGB page — **no second overflow
  check in the GB-slot APU on AGS hardware**; row 17 closes (the reverted
  GB port stays reverted, the GBA-mode check is GBA-native-only).
- Model splits, one page each, for later decode: P02 TIMAGLITCH (bytes
  10-13 — the A5 TAC-disable family), P06 SERIAL (bytes 02/05/06),
  P0B STATWBUG (DMG-only glitch absent, as documented), P0D OAMDMA (CGB
  bus conflicts), P0F (FEA0 echo pattern AA..FF), P10 VRAMLOCK,
  P13 DSTAT / P14 SPEED (double-speed pages ran for real), P16 HALTPHASE,
  P17 WYLATCH (row 4's CGB-samples-WY data).

## Session 2 results — 2026-08-17, GBA SP: the 261st row's arbitration

Photos IMG_3803-3808 (acid-hell, probe_c ×3, daid, probe_b), all on the SP.

**cgb-acid-hell (IMG_3803): THE REFERENCE IS HARDWARE-CORRECT ON AGS, and
dingbat's 2 pixels are a genuine model defect on this silicon.** The
ROM's pass state is the near-blank screen with the yellow smiley; the two
disputed pixels are the smiley's mouth — reference draws a "∨" (dark at
(79,68),(81,68),(80,69)), dingbat a flat bar (dark at (79-81,68)). A
grid-fit of the photo (controls: both eyes DARK, cheek YELLOW, fit
validated) reads the verdict cell (80,68) as YELLOW and (80,69) as
dark — the reference's values, not dingbat's. The "reference question"
escape hatch is CLOSED for AGS-class silicon: 261/261 requires the model
world the SCX campaign named (acid-hell's grid alignment restored while
daid's emission term stays — the P-bracket co-derivation in
docs/gb-failure-triage.md). Verified en route: dingbat's shipped world
reproduces exactly 2 wrong pixels against the reference at rev C AND rev
E (the runner passes `--color`; without it the capture is the compat-grey
view and the smiley reads grey).

**probe_c ×3 / probe_b / daid photos (IMG_3804-3806, 3807, 3808):**
captured and archived, not yet machine-read. tools/gbprobe/photowarp.py
(experimental, this session) finds the SP's letterbox panel quad but its
registration is a few pixels too coarse for the 4-dot phase reading; the
fix is adapting gbphoto/photogrid.py's NCC refinement to the letterbox
geometry. These photos hold the quantitative version of what acid-hell
already answered qualitatively, so read them when the tool is finished —
before the GBC session at the latest (same tool reads those photos).

## Getting results back

Photograph everything into one folder per console. For gbedge pages,
`tests/roms/hwprobe_ocr.py` reads dingbat screenshots of the same build
for the diff side; hardware photos are compared by eye against those.
File deltas as rows in docs/hwprobe-questions.md / pandocs-upstream.md §2
— each entry there names the knob or model the answer moves.

## 9. g1 — the halt-wake PPU phase (folder 9; hwprobe v8, HIGHEST VALUE NOW)

Two fixed builds of probe (e), `g1_scx0.gb` and `g1_scx4.gb`. Boot each on the
**GBA SP**, check the header reads `00 FF` / `04 FF`, photograph, done — no
d-pad, no timing. Folder 9's README has the full story and the predicted
screens rendered at 3x.

It arbitrates `CGB_HALT_PPU_LEAD`, which is **shipping on main** (it is what
took `cgb-acid-hell` to 0 px and the shootout to 261/261) and which two of our
own instruments disagree about: `cgb-acid-hell` and daid's `ppu_scanline_bgp`
want it, probe (e) scored against SameBoy does not. Three candidate readings,
8 px apart:

| SCX | lead 0 | lead 1 (ships) | SameBoy |
|---|---|---|---|
| 0 | `32 40 40 48 …` | `40 40 48 48 …` | `24 32 32 40 …` |
| 4 | `28 36 36 44 …` | `36 36 44 44 …` | `20 28 28 36 …` |

Neither dingbat build matches SameBoy even at lead 0 — that gap is probe (e)'s
own unexplained 2-3 M baseline offset, so this shot tests the instrument as
well as the constant. Read with `tools/gbprobe/read_probe_e.py <photo.jpg>`.

## Session 3 results — 2026-08-18, GBA SP: g1, the halt-wake phase

Two photos (`flashcart-kit/9-halt-lead/IMG_g1_scx0.jpg`, `IMG_g1_scx4.jpg`),
read with the new `tools/gbprobe/read_g1.sh`.

**Hardware reads the SameBoy column on both.** SCX 0 gives
`24 32 32 40 40 48 48 56 56 64 64 71 71 79` against SameBoy's
`24 32 32 40 40 48 48 56 56 64 64 72 72 80`; SCX 4 gives
`20 28 28 36 36 45 45 53 53 61 61 69 69 77` against `20 28 28 36 36 44 44 52
52 60 60 68 68 76`. dingbat is 8 px (2 M) out with `CGB_HALT_PPU_LEAD=0` and
16 px (4 M) out with it on.

So **probe (e)'s long-standing 2-3 M offset from the oracle is a real defect in
dingbat**, now with silicon behind it — and the shipped lead makes this
particular instrument worse while remaining the only thing that makes
`cgb-acid-hell` and daid's `ppu_scanline_bgp` exact. Full reasoning and what to
chase next in docs/hwprobe-questions.md, g1 RESULT.

Tooling note: photowarp's own detector still cannot find the panel in these SP
shots. `tools/gbprobe/find_panel.py` (new) locates it as the largest connected
bright region and fits a quad from the diagonal extremes, choosing the
threshold by how close the result is to 160:144. The SCX 4 shot's LCD moire
also defeats read_probe_e's global threshold; a per-row median read of the same
warped frame recovers it.
