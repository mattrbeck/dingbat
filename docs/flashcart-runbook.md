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

## Getting results back

Photograph everything into one folder per console. For gbedge pages,
`tests/roms/hwprobe_ocr.py` reads dingbat screenshots of the same build
for the diff side; hardware photos are compared by eye against those.
File deltas as rows in docs/hwprobe-questions.md / pandocs-upstream.md §2
— each entry there names the knob or model the answer moves.
