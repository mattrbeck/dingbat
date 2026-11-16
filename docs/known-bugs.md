# Known bugs, not yet fixed

Found and understood, not fixed. Each entry says what goes wrong, when, and
the fix it wants. Remove an entry in the commit that fixes it.

## GBA

### A dispatch outside the slow tick reads a stale `tick_left`

`Scheduler.tick_left` (common/scheduler.nim) is what remains of the quota
`tick_slow` was advancing when it dispatched the current event; 0 means the
event is due at an instruction boundary. Only `tick_slow` writes it, but the
GBA reads it in every dispatch: `gba.nim` (etDMA `at_boundary`) and `dma.nim`
(`dma_bus_tail`). Events dispatched by `fast_forward` /
`fast_forward_bounded` (a HALT) or by the idle-loop skip's `call_current`
(gba/cpu.nim) see the last slow tick's leftover instead of 0, so a DMA
granted there can take the wrong boundary timing. This happens in an
uninterrupted run; a load sets it to 0 (a new scheduler's value), so a
loaded core can differ from the run it came from at that point.

Fix: set `tick_left = 0` in `fast_forward`, `fast_forward_bounded` and before
the idle-loop skip's dispatches (0 is the true value there). It moves GBA
timing: check the mGBA suite, dbsuite and alyosha rows and run the playtest
train before landing.

### The tilt latch is not in the payload

`Bus.tilt_x` / `tilt_y` / `tilt_armed` are not serialized; a load resets them
to a new core's values, so a frame boundary that falls between a game's
latch and its read returns 0 after a load where the uninterrupted run returns
the sample. The games latch before each read, so this needs a boundary inside
that sequence. Fix at the next payload revision: carry the three fields.

### Idle-loop detector: RAM-loop accepts leave `last_waitloop` stale

In `waitloop.nim` the RAM-loop accept paths set `last_waitloop_first_load`
without `last_waitloop`, so the `key == last_waitloop` fast path can reuse a
first-load address from another loop when it computes `fresh`. A RAM address
against a ROM loop makes `fresh` false (no skip: safe); only a load-free RAM
loop (`WL_NO_LOAD`) could widen the window wrongly. Fix: set `last_waitloop`
with `last_waitloop_first_load` on those paths.

## GB

### A STOP taken in mode 3 ends a frame in mode 3

In STOP the PPU is frozen but `mem_tick_stopped` still raises `ppu.frame` from
the panel clock, and `step_frame`'s settle loop is skipped while the CPU is
stopped. A STOP executed during mode 3 therefore ends a frame with the PPU in
mode 3, and `load_ppu_state` refuses a mode-3 state, so a rewind, a rollback
or a slot taken there fails to load. Every boundary until the key press is
such a state: daid `stop_instr_gbc_mode3` (CGB), DocBoy
`cgb/ppu/visual/stop_during_pixel_transfer{,_alt}`, `*stop_read_tima*` and
`mbc3_rtc_gb_stopped_recover` reproduce it; no licensed game uses STOP outside
the speed switch (Pan Docs), which never sets `stopped`.

An in-process load (`apply_state_payload`: rewind, scrub commit, run-ahead)
has no rollback, and the PPU section comes after the CPU, memory and scheduler
ones. A refused rewind therefore leaves the live core half-applied: CPU back
in the snapshot's STOP, PPU and APU still at the present frame. The slot and
file paths (`gb_apply_checked`) restore the machine.

Fix: carry what a mode-3 state needs (the per-line renderer scratch, which
also closes the HBlank repaint entry below); the boundary cannot wait for the
STOP's end, which only a key press brings. Separately, make the in-process
load all-or-nothing.

### A boundary just past mode 3 loses an HBlank palette repaint

After a speed switch's stall the frame can end a few dots into mode 0.
`reset_render_scratch` (fifo_ppu.nim) clears `lx`, `tail_dot0` and the mixer
on load, so a palette write in that line's early HBlank repaints nothing
(MIXER_TAIL_HBLANK) where the running core repaints the line's tail. Both a
loaded and a new core reset these, so the state-hygiene test cannot see it.
Fix: settle the boundary past the repaint window, or keep the tail fields
across a load when the PPU is in mode 0 of a drawn line.

### `hdma_block_due` can be left set at a halted V-blank boundary

With the CPU halted, a mode-0 edge can owe an HBlank block (`hdma_block_due`,
deadline far off) at the frame's end, and the load does not reset it. It
mostly cancels itself (a wake outside mode 0 drops it). Fix: carry it with
the edge detector's mode in the machine section, or clear it on load when
the CPU is not halted under an armed transfer.

## Tests

### The signaling room-lifecycle test can hang after passing

`node web/signaling/server.test.mjs` once printed "all signaling
room-lifecycle and token-broker tests passed" and then did not exit (3 h
44 min, local run, 2026-11-14); a rerun exited normally. Something (a timer,
a socket, the spawned server) keeps the process alive after the last check.
Fix: close every handle at the end, or exit explicitly once the summary is
printed.
