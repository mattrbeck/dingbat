# DS hardware test ROMs beyond the wrestlers

A hunt (2026-10-01, branch `nds-testroms`) for third-party DS test ROMs with
a hardware answer -- a test that prints PASS/FAIL, or ships data recorded on
a console -- that the ROMs already in use (armwrestler, arm7wrestler,
rockwrestler, gbe-plus-nds-tests, StrikerX3's window tests, devkitPro's
nds-examples, our own `tests/nds/src`, the homebrew sweep of
docs/nds/compat.md) do not cover; each run in `ndsrun` and in the reference
core (`tools/ndsref`, black box, melonDS DS 1.4.0), and the failures in our
core fixed where they fall outside 3D edges.

**Where the answer comes from.** Where a test checks itself (polyrastertest's
hardware-recorded spans, gbe-plus PASS rows, the BlocksDS SDK tests' own
checks) its verdict is the hardware answer; the reference is secondary.
Where a ROM has no recorded answer it is a reference comparison, and a
difference is settled with GBATEK or a probe ROM of ours before anything
changes.

## What was found

DS hardware tests are scarce: almost everything public was already in use.
Searched: GitHub (repos and code), Codeberg, the melonDS board on
kuribo64.net, GBAtemp, emudev.org's resource list, the BlocksDS SDK, and the
repositories of DS test and emulator authors (only their test directories
and READMEs were opened; no emulator source was read). New finds:

| Suite | Source, licence | What it checks | Answer |
|---|---|---|---|
| polyrastertest v1.0.2-b | [Jaklyy/polyrastertest](https://github.com/Jaklyy/polyrastertest), MIT; release zip (source at 550c208e89) | 77 single-polygon scenes: fill rules (normal, swapped, overrides), line polygons, the "swapped vertical left" glitch, trapezoids, edge marking's overlapping-edge rule, vertical right edge shift, AA/edge-mark swapped edges, horizontal line polygons under clipping, second-vertex quirks; each scene captured (DISPCAPCNT, 3D only) and compared span by span and colour by colour | spans and colours recorded on a New 3DS XL in DS mode (TWiLight Menu++), built into the ROM; prints "Tests Passed: n/77" |
| gx_powcnt, gx_clear | melonDS board, "Hardware test ROMs" thread (binaries only, no licence) | POWCNT1 toggles of the geometry/rendering engines and 2D engine A with PAL/OAM write-read counters; 3D clear colour latched per frame | described in the thread (the change "should reflect even though 3D graphics aren't being refreshed") |
| gbe-plus `ARM9/Timer` | [shonumi/gbe-plus-nds-tests](https://github.com/shonumi/gbe-plus-nds-tests) a0df034a, GPLv2 | prescaler counts after 5 frames; count-up, stop, reload-value PASS/FAIL | PASS rows; counts have no recorded answer |
| BlocksDS SDK tests | [blocksds/sdk](https://codeberg.org/blocksds/sdk) 01df02b5 `tests/` (42 built), CC0 | library self-tests on the hardware: cache ops, MPU regions, TCM placement, vector base, IRQ handling, SWI results, IPC FIFO full, hardware sqrt, cothreads waiting on IRQs, ... | each prints its own result; `cache/data_cache_ops`' source lists the hardware's screen |
| BlocksDS SDK examples | same, `examples/` (136 built) | feature demos (2D, 3D, capture, effects, audio, BIOS); 52 hardware-feature ones swept | reference comparison only |
| cached-memory-performance | [asiekierka/nds-misc-tests](https://github.com/asiekierka/nds-misc-tests) 9c78f60c, CC0 | timer ticks to write 16 B..4 KB through cached / uncached main RAM with DC flush-all / flush-range | none (a measurement tool) |
| disp_powcnt (ours) | `tests/nds/src/disp_powcnt` | written for this hunt: what POWCNT1 gates (palette, OAM, each unit's ports, geometry commands, the 3D layer with rendering off) | reference runs + GBATEK + the real firmware |

Looked at and not used: StrikerX3's `nds-3dtst` (a capture-to-SD recorder;
no recorded data in the repo), `nds-aa` (hardware AA coverage datasets for
the edge work, 7z archives of measurements, not a ROM), `nds-interp` and
`nds-attrinterp` (host-side models, not opened beyond their READMEs);
Jakly's `ndsdoc` (documentation); Nintendo's Aging Card NTR (Nintendo's own
test cart: not a public test, not downloaded); GameBrew's hardware
diagnostic tools (Check NDS, Diagnose: report hardware, no expected values).

Every binary lives in `~/.cache/dingbat-nds/roms/` (never in git);
`tests/nds/tools/setup_blocksds.sh` installs BlocksDS into a user prefix
and `tests/nds/tools/build_testroms.sh` fetches and builds all of the above
(pinned commits). SHA-1s of what was run:

| ROM (under roms/) | SHA-1 |
|---|---|
| polyrastertest/polyrastertest.nds | e78569f0ef5fe5571a0ba3c0c4584fa9b162e78a |
| kuribo/gx_powcnt.nds | 0ff943a400c77d242816d80077f2512f8bdc7213 |
| kuribo/gx_clear.nds | 36dc7aee9849a082e33d3d2d005edb927b8ccce2 |
| gbeplus/arm9_timer.nds | be132b2f23271c590400b4f15dbd6599008519db |
| misc/cached_memory_performance.nds | 3153871c00570c8264c5f90e3030ee622f206665 |
| blocksds/{tests,examples}/*.nds | built from sdk 01df02b5 with BlocksDS 1.24.0 / gcc 16.2.0 (`build_testroms.sh` rebuilds them; byte-identical builds are not guaranteed across toolchain updates) |

## Results

| Test | Expected (hardware) | Ours before | Ours now | Reference |
|---|---|---|---|---|
| polyrastertest v1.0.2-b | 77/77 | 50/77 | 50/77 (3D edges: left to the edge work, list below) | 70/77 |
| gx_clear | clear colour follows the register every frame | follows | follows | follows |
| gx_powcnt | PAL/OAM read back 0 with engine A off (GBATEK) | kept counting | 0 | 0 |
| gbe-plus Timer: count-up, stop, reload value | PASS x3 | PASS x3 | PASS x3 | PASS x3 |
| gbe-plus Timer: prescaler counts after 5 frames | (none recorded) | 0000BCF7 / 0AF4 / 02BD / 0AF | same | 0000BD2D / 0AF4 / 02BD / 0AF |
| BlocksDS cache/data_cache_ops | the source's screen: no op 256/0/0, flush range 128/128, invalidate range 128/128, flush all 0/256, invalidate all 256/0 | 0/256/0 in every row (no cache contents) | as the hardware | 0/256/0 in every row |
| disp_powcnt (ours) | GBATEK + the reference + the real firmware | 8 rows wrong (PAL, OAM, BG1CNT of both engines, GEO, PWR) | all rows | (the answer) |
| cached-memory-performance | (none recorded) | flush-all 500..1674 t, flush range 51..1771 t, uncached 61..3428 t | flush-all 504..1842 t (DC_FlushAll now empties the tags), the rest unchanged | 698..1784, 51..1582, 58..3431 |
| BlocksDS `system/swi_calls` | swiIsDebugger() = 1 with the data cache on (GBATEK) | 0 | 1 (real and HLE BIOS) | 0 |
| BlocksDS SDK tests, the other 40 | their own prints | -- | 34 print what the reference prints (MPU regions, TCM placement, vector base, IRQ handling, IPC FIFO full, hardware sqrt results, argv, atexit, sbrk, heap bounds, C++ exceptions, filesystem, textures, ...); 6 differ only in timing printouts or the date | -- |
| BlocksDS examples, 52 hardware-feature ones | (reference comparison) | -- | 2D (21 graphics_2d, 8 video_effects, 2 console), BIOS, compression, interrupts, IPC, maths and timers identical to the reference before the input script's START (exit) except `video_effects/blending` (1-step blend rounding) and counters; `video_capture/*` differ (below) | -- |

How the BlocksDS ROMs were compared: every test 150 frames with no input
(shots 60 and 148, best of the reference's frames within +-2); the
examples 360 frames under the sweep's input script, compared before its
START at frame 120 -- the BlocksDS programs exit on START and power off,
after which our screens keep the last picture and the reference's go black
(the power-off item of docs/nds/compat.md). The differences, each looked at:

- **Timing printouts, no hardware value**: `cothread/coroutines`,
  `preserve_context`, `wait_for_irq` (progress counters a frame apart),
  `filesystem/performance`, `math/hw_sqrtf` (software sqrtf 229 cycles per
  op ours, 191 reference; hardware sqrt 68 vs 75), `ipc/fifo_stress_test`
  and `time/timers` (counters), `audio/capture_audio` (its waveform plot).
- **The RTC**: `ipc/transfer_region` prints the date (ours ran on the host
  clock).
- **`video_effects/blending`**: semi-transparent and bitmap OBJs blended one
  5-bit step apart from the reference in some pixels. Ours follows GBATEK's
  `min(31, (I1*EVA + I2*EVB) / 16)` for semi-transparent OBJs; the weights
  of a bitmap OBJ's alpha (EVA = alpha + 1, EVB = 15 - alpha) are Assumed,
  GBATEK gives none. Open: needs a console.
- **`video_capture/*`**: `render_to_texture` (95 % of the top screen),
  `dual_screen_3d` (84 % of both), `motion_blur` (29-46 %), `bloom` (5 %),
  `two_pass_3d` (2 %), `simple_capture` (1 %) -- the capture/3D timing
  cases docs/nds/compat.md already lists for the capture and 3D work.

### polyrastertest, failing tests (ours)

Numbered as the ROM numbers them (source 550c208e89, `main.h` order; the
names are the source's comments); the
reference fails 26, 38, 39, 43, 62, 63, 64. All are rasteriser edge rules,
so they are listed for the 3D edge work rather than fixed here:

| # | Test | Reference |
|---|---|---|
| 13, 14, 16 | fill rules, swapped polygons: left X-major (top filled, bottom not), left Y-major, right X-major | pass |
| 27, 28, 29 | line-polygon exception: "cursed line polygons" 1-3 (only the line part filled) | pass |
| 30, 31, 32 | swapped vertical left glitch (half-filled slopes; X-major never) | pass |
| 36 | trapezoid rule does not apply when both slopes' bottoms share an x | pass |
| 38, 39, 43 | the curse of edge marking (overlapping edges of the same polygon ID unfilled) | fail too |
| 49, 50, 53 | vertical right edge shift: swapped polygon 1 (and reversed), a 0-wide span shifted left | pass |
| 56 | AA swapped vertical edge glitch, the combined case | pass |
| 59, 60, 61, 66, 70 | horizontal line polygons under clipping: which vertex pair (1-4, 1-2, 2-4) colours the line, "pointer never goes backwards" | pass |
| 62, 63, 64 | the same once vertex 1 is clipped | fail too |
| 73, 74 | edge-marking swapped vertical edge glitch (triangle); second vertex behaving as if swapped | pass |

To list them again: `ndsrun --press A@60,A@100,... --shots <same> --text B0
--text-shots` steps the ROM from failure to failure (A moves on) and prints
"Testing N" / "Tests Passed" at each stop; a stop where the passed count
equals N-1 is a failure of test N. The newer source (6fd29de, 100 tests:
polygon/vertex RAM limits, scanline timing) needs its data file re-recorded
-- both cores fail every test after 37 with it, so only the release is used.

## Fixes

Each in its own commit, each with checks in `tests/nds_testroms_test.nim`
(`nimble test_ndstestroms`).

1. **POWCNT1 gates its units** (`be36c369`; `bus9.nim` pal_oam_on,
   io9_write; `boot.nim`). Found by gx_powcnt: with engine A off its
   PAL/OAM counters kept counting where the reference reads 0. GBATEK
   "DS Power Control": a disabled unit's ports are read-only and its
   palette reads zero. `disp_powcnt` (new, `tests/nds/src/disp_powcnt`)
   then settled the rest against the reference: OAM is gated like the
   palette, both keep their contents, BG registers of a disabled engine
   ignore writes, geometry commands sent with bit 3 clear are dropped.
   Direct boot now leaves POWCNT1 = 820Fh -- what the real firmware leaves
   at the cart's entry (`disp_powcnt` with a boot logo, relocated, booted
   through the dumps with `ndsrun --boot firmware`) and what the
   reference's direct boot leaves; we had 0203h (3D off). SoulSilver
   unchanged.
2. **The ARM9 data cache holds data** (`26284a23`, `5c0d6ed8`, `dde3dd76`; `timing.nim` DcLine,
   `bus9.nim` dc_*, `bus7.nim`). Found by BlocksDS `cache/data_cache_ops`,
   whose source gives the hardware's screen; we (and the reference) showed
   every store reaching memory at once. Now a CPU store to a cached
   write-back line stays in the cache until the line is cleaned or evicted,
   DMA and the ARM7 read memory's side, a store behind the cache (DMA,
   ARM7, an uncached mirror, the cache off) leaves the CPU's copy stale
   until invalidated, and C7 invalidate / clean / clean+invalidate by
   address and by set/index (DC_FlushAll's loop) do what GBATEK says.
   Write-through regions update both sides. Code fetches read memory, and
   so does an access through another mirror of a cached line (a different
   cache line, which misses). Assumed: the whole line is dirty (no per-half
   dirty bits), a RAM line is cached under one mirror at a time (filling
   another writes the first back), and write-backs cost no bus time (the
   cycle model is unchanged).
   With it the real BIOS's IsDebugger returns 1 with the cache on, as
   GBATEK says it does ("Fails on ARM9 when cache is enabled (always
   returns 8MB state)"; BlocksDS `system/swi_calls` prints it; the
   reference prints 0); the HLE BIOS now answers the same when the cache
   covers the probe or its mirror (`hle_bios.nim`, two new cases in
   `tests/nds_hle_bios_test.nim` against the real BIOS). SoulSilver runs its main RAM
   write-back (36 lines apart from memory at frame 600) and renders
   frames 3000/5000/8000 unchanged; host instructions +1.0 % over its first
   3000 frames. Of the 60 homebrew titles and 72 nds-examples run 600
   frames before and after, one changes: nds-examples `fire_and_sprites`
   `dmaCopy`s its fire buffer to VRAM without `DC_FlushRange`, so the rows
   the CPU wrote last are still in the cache and the DMA copies older
   ones into the bottom rows -- what a console does with that code.
3. **Tools.** `ndsrun --text-shots` prints a text BG at every shot (to step
   console tests); `ndssweep` builds again (`0030e61b`) and no longer spins
   on a powered-off DS (`85776d26`: every BlocksDS test that exits to the
   absent loader powers off and used to run into the 300 s timeout).

## Still open

- **polyrastertest's 27 failures** (above): rasteriser edge rules, for the
  3D edge work.
- **The 3D layer with the rendering engine off.** The reference keeps the
  last frame in `disp_powcnt` (render off, then new lists swapped, then
  geometry off too) but shows no 3D in `gx_powcnt` (geometry off first,
  then render, with swaps throughout). We keep rendering the swapped list.
  The hardware renders through a 48-line cache (GBATEK) and so holds no
  frame to keep; what it shows needs a console.
- **Blend rounding of semi-transparent and bitmap OBJs**
  (`video_effects/blending`, above): one 5-bit step from the reference in
  some pixels; the bitmap-OBJ alpha weights are Assumed. Needs a console.
- **Cache maintenance and write-back timing.** cached-memory-performance
  measures DC flush-all at 504-1842 timer ticks in ours against
  698-1784 in the reference (flush range 899 vs 814 at 2 KB, 1771 vs 1582
  at 4 KB; uncached writes agree within 3 %). Neither side has a hardware
  figure; write-backs are free in ours. A console run of the ROM would pin
  both.
- **The instruction cache holds no instructions**: code fetches read
  memory, so code changed behind the instruction cache (DMA'd or written
  overlays without IC_InvalidateRange) runs new where the hardware would
  run stale code.
- **gbe-plus prescaler 0 count**: 0xBCF7 ours, 0xBD2D reference after "5
  frames" of the test's own wait loop (54 cycles of 33 MHz apart, the loop's
  timing, not the timer's); no hardware value.
