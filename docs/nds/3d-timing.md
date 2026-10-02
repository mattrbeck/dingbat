# DS 3D engine timing, limits and the display FIFO

Status of the geometry engine's timing, the render budget, SWAP_BUFFERS,
the main-memory display FIFO (DMA mode 4) and display capture edge cases.
Hardware facts are GBATEK unless marked; values settled or contradicted by
black-box reference runs are in docs/oracles.md ("NDS 3D engine"); the rest
is marked Assumed. Cycles are 33.51 MHz bus cycles (the scheduler counts
master cycles, 2 per bus cycle).

## What dingbat had before

- Every geometry command ran the moment it reached the FIFO, so GXSTAT
  never showed a busy engine except behind a pending SWAP_BUFFERS, and
  writes behind a pending swap were queued without limit (no CPU stall).
- DMA mode 7 (GX FIFO) was only started by DMA register writes and at
  V-blank; the GXFIFO IRQ was only re-evaluated on FIFO writes.
- RDLINES_COUNT read a constant 46; DISP3DCNT.12 never set.
- DISP_MMEM_FIFO was a whole-frame buffer written round-robin by each word
  (a stub): DMA mode 4 pushed 128 words per line at line start, wherever
  the frame's data happened to be.
- Display capture cleared its busy bit after its last captured line, and a
  transparent 3D dot captured as 0000h.

## Geometry engine (gpu3d.nim)

| | Hardware (GBATEK) | dingbat now |
|---|---|---|
| Command time | cycle column of "DS 3D Geometry Commands"; NORMAL 9..12 by lights; MTX_MULT/TRANS +30 in mode 2; SWAP_BUFFERS = until V-blank + 392 | the same table (`CMD_CYCLES`, `cmd_cycles`); NORMAL 9, 9, 10, 11, 12 for 0..4 lights (reference runs); MTX_SCALE pays no mode-2 extra |
| When a command starts | after the previous one, once its parameters are in | `max(engine free, last parameter's arrival)` |
| When its effect shows | not stated | at its start (Assumed; the reference runs show the new stack level while GXSTAT.14 is still set: 3d_timing_cmds MID) |
| GXSTAT.0 / .14 / .27 | test busy / push-pop busy / anything executing or queued | from the running command and the queue; .14 for MTX_PUSH/POP only (MTX_STORE/RESTORE not, as the reference runs) |
| FIFO / PIPE | 256 + 4 entries; GXSTAT counts the FIFO only | unchanged rule: entries beyond the first 4 count (3d_status) |
| Full FIFO | the writing STR freezes; the bus is held (DMA, IRQs, ARM7 too) | `push` sets `stall_until` = when the next command starts (behind a pending swap: V-blank + 392); bus9 moves the ARM9 and ARM7 clocks there |
| DMA mode 7 | 112 words whenever the FIFO is less than half full | unchanged burst; evGxFifo is booked for the time the queue next drops below half (`wake_at`), so a long list streams at the engine's pace |
| GXFIFO IRQ | level-triggered on < half / empty | the same, now also re-raised at the booked wake-up |
| SWAP_BUFFERS | engine halted until line 192, then 392 cycles; bits apply to later commands | the swap happens at `on_vblank` if it started before line 192, then the engine is busy 392 cycles |
| A frame not finished in time | the swap waits for the next V-blank; the renderer redraws the old buffer | falls out of the timing: 3d_timing_fifo SLOW shows the swap landing a V-blank later (3D at 30 fps) |

The engine runs lazily: `catch_up(t)` starts every command whose start time
has come, and is called before anything observes the engine (register
reads, GXSTAT, V-blank, writes to DISP3DCNT / DISP_1DOT_DEPTH, which is not
FIFO'd and so applies to queued polygons, as GBATEK warns). Without a
scheduler (`sched` nil: the unit tests that drive Gpu3d directly) every
command takes no time, as before.

### Readings (3d_timing_cmds, 3d_timing_fifo, 3d_status)

Cost rows are T(144) - T(48) commands = 96 commands' engine time, in hex
bus cycles (the ROM's writer needs ~4 cycles per word, so commands of a
few cycles per word read the CPU instead and are left out here).

| Row | GBATEK x 96 | dingbat | reference run (docs/oracles.md) |
|---|---|---|---|
| MTX_IDENTITY (19) | 0720 | 0725 | 0720 |
| MTX_PUSH + MTX_POP pairs (17 + 36) | 13E0 | 13DE | 13DE |
| MTX_STORE + MTX_RESTORE pairs (17 + 36) | 13E0 | 13DC | 13E0 |
| MTX_SCALE mode 1 / 2 (22) | 0840 / 0840 | 083F / 083F | 0D1D / 0D35 (35) |
| MTX_TRANS mode 1 / 2 (22 / 52) | 0840 / 1380 | 083E / 137E | 0D14 / 185D (35 / 65) |
| MTX_MULT_3x3 mode 2 (58) | 15C0 | 15C0 | 1858 (65) |
| MTX_MULT_4x3 mode 2 (61) | 16E0 | 16DD | 187E (65) |
| MTX_MULT_4x4 mode 2 (65) | 1860 | 185F | 1881 |
| NORMAL 0..4 lights (9..12) | | 035E 035E 03C0 0422 0484 | 0360 035F 03C9 0423 0494 |
| VTX_10 / XY / DIFF (8) | 0300 | 02FB 02FB 02FB | 036F 0360 034A (9) |
| BOX_TEST (103) | 26A0 | 26A4 | 605B (257) |
| VEC_TEST (5) | 01E0 | 01D7 | 01E2 |
| LIGHT_VECTOR (6) | 0240 | 023E | 023B |

| 3d_timing_fifo / 3d_status | dingbat | reference |
|---|---|---|
| SWAP alone: cycles from the first poll seeing line 192 to GXSTAT.27 clear | 0180 | 0150 |
| SWAP + 10 MTX_IDENTITY | 0240 | 01E8 |
| STAL: 300 MTX_IDENTITY behind a swap written at line 100: cycles / VCOUNT / GXSTAT | 301C2 / C0 / 08FB0000 | 30140 / C0 / 08FF0000 |
| 3d_status FIFO: 340 MTX_IDENTITY behind a swap, GXSTAT after the last | 08C30000 | 08B80000 (before: 09000000, no stall) |
| DMA: 400 BOX_TESTs by mode 7: FIFO low / high / time to engine idle | 80 / C8 / A17D (= 400 x 103) | 7E / D2 / 191E3 (= 400 x 257) |
| SLOW: 2000 / 6000 BOX_TESTs then swap: V-blanks during / after | 0, 1 / 1, 1 | 0, 1 / 2, 1 (its BOX_TEST is 2.5x ours) |
| RAMC: RAM_COUNT line 191 / line 192 | 00030001 / 0 | the same |

So the reference follows GBATEK's table for most commands, and differs on
MTX_SCALE/TRANS/MULT_3x3 (35, 65 in mode 2), vertices (9) and BOX_TEST
(257); dingbat keeps GBATEK there. The reference's NORMAL readings pick
GBATEK's "9..12 for 0..4 lights" mapping.

## Limits

- **Polygon/Vertex RAM** (2048 polygons, 6144 vertices; strips share
  vertices): a polygon that does not fit is dropped and DISP3DCNT.13 set;
  later ones that fit still go in. 3d_status OVF (1600 quads: RAM_COUNT
  18000600h; 2100 strip triangles: 2048 polygons) matches the reference
  core. Unchanged by this work.
- **Render budget** (render.nim `line_cost`, `budget`): GBATEK says the
  renderer works line by line into a 48-line cache from line 214, the
  display takes a line at each line start, RDLINES_COUNT is the fewest
  lines buffered in the previous frame minus 2 (46 = never behind), and
  DISP3DCNT.12 flags an underflow. It gives no per-polygon or per-dot
  figures, and the reference cores do not model this (they read a constant
  under any load: 3d_timing_rdlines, docs/oracles.md). The model, all
  Assumed: each polygon crossing a line costs `RENDER_POLY_CYCLES` (8)
  plus its span width / `RENDER_DOTS_PER_CYCLE` (2); line k starts when line k-1 is done
  and line k-48 has been displayed; display line j is taken (49 + j) line
  times after rendering starts. 16 opaque full-screen quads read 42,
  64 underflow (3d_timing_rdlines: S2 = 2A, S3/S4/S8 underflow). The value
  is latched at V-blank for the frame just shown; the underflow does not
  change the picture (what the hardware shows then is unknown).

## Main-memory display FIFO (engine2d.nim, gpu.nim, nds.nim)

GBATEK: DISP_MMEM_FIFO feeds display mode 3 and capture source B; DMA in
main-memory mode with 32-bit units, word count 4, fixed destination;
"The FIFO can receive 4 words (8 pixels) at a time"; "Transfer starts at
next frame".

Model:
- a 16-word FIFO (`MMEM_FIFO_WORDS`, Assumed: four 4-word requests deep);
  CPU or DMA words beyond that are dropped (Assumed);
- for each visible line that display mode 3 or capture source B reads, the
  display takes 8 pixels at a time into `mmem_line`; before each 8, while
  the FIFO has room for 4 words, it asks DMA mode 4 for a block (the
  channel's count: 4 as GBATEK sets it; a larger block overflows and the
  rest is dropped);
- it asks for at most 256x192 pixels per frame (Assumed), so a DMA
  restarted every V-blank lines up with line 0 (disp_mmem phase A: equal
  to the reference pixel for pixel);
- a channel enabled mid-frame waits for the next line 0 ("starts at next
  frame"); one left running continues into the next frame (repeat);
- a dry FIFO repeats the last pixel (Assumed; the reference runs show a
  repeated pixel too).

The reference cores differ among themselves outside phase A (disp_mmem
phases B-G; docs/oracles.md): one stops a never-restarted channel after
one frame (the screen holds the last pixel), another restarts it from its
source, dingbat runs on into the next bitmap; both start a channel enabled
mid-frame at once. None of these is pinned by GBATEK.

## Display capture (gpu.nim)

disp_capture against all three reference cores: busy bit, 128x128 stride,
write-offset wrap at 128K, source B read offset (ignored in VRAM display
mode), capture with the display off, and the clamp at EVA = EVB = 16 all
agree with GBATEK and with dingbat. Changed here:
- DISPCAPCNT.31 now clears at line 192 for every size (GBATEK "regardless
  of the capture size"; disp_capture BUSY: 1 1 1 1 1 0 on all cores);
- a transparent 3D dot (source A = 3D) captures its colour without bit 15
  (GBATEK's Dest_Intensity = SrcA_Intensity; all three cores: 7C00h for a
  blue rear plane at alpha 0), not 0000h;
- blending stays truncating, (A x EVA + B x EVB) / 16 as GBATEK writes it:
  two reference cores agree, one rounds (C010h vs BC0Fh; docs/oracles.md).

## Tests

- `tests/nds/src/3d_timing_cmds`, `3d_timing_fifo`, `3d_timing_rdlines`,
  `disp_mmem`, `disp_capture` (built by `tests/nds/tools/build_3d.sh`);
  `tests/nds/tools/png_text.py SHOT.png` reads their printed rows back
  from an ndsrun or ndsref shot. tm.h has the timer clock and I-cache
  switch they share.
- `tests/nds_3d_test.nim` scene_timing (command cycles, busy bits, NORMAL
  by lights, mode-2 extra, swap + 392, the stall on a full FIFO,
  `wake_at`) and scene_budget (RDLINES / DISP3DCNT.12 for 1, 16, 64
  full-screen quads); `tests/nds_2d_test.nim` the FIFO fed per request,
  the exact frame's worth, the dry FIFO, overflow, and the capture busy bit
  to line 192.
- Every 3d_* ROM hash is unchanged; SoulSilver frames 3000/5000/8000
  (p12 script) are byte-identical to before.

## Left

- Words a DMA burst writes all arrive at one instant (the burst's start);
  the GX FIFO only sees the DMA's time through the stall it charges.
- A command waits for all its parameters before it starts; the hardware
  may begin a multi-parameter command (MTX_LOAD/MULT) as words arrive.
  The FIFO-to-PIPE move (2 entries when the PIPE drops below 3) has no
  latency of its own.
- RAM_COUNT resets at the swap, not "10 cycles after V-blank"; the 3D
  V-blank (lines 191..213) is not modelled; SWAP_BUFFERS after an
  incomplete polygon does not lock up the engine.
- The render budget's constants want a hardware run of 3d_timing_rdlines;
  the underflow's visible effect is not modelled. Render-register writes
  now land per line, 48 lines ahead of the display (docs/nds/accuracy.md,
  3d_render_timing); the budget does not delay when a line samples them.
- The DMA-mode-4 corner cases above (FIFO depth, overflow, a channel left
  running, mid-frame enable) want a hardware run of disp_mmem.
- The ARM9's own I/O access timing makes our polls coarser than the
  reference's (two timer reads: 32h vs 17h cycles; 3d_timing_cmds LAT),
  which shows in the MID/LAT rows but is CPU timing, not this topic.
