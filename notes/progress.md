# Progress — current state

Dated work logs live in git history. This is where each subsystem stands.

## Game Boy Advance

| Subsystem | State |
|---|---|
| CPU (ARM/THUMB) | Complete; jsmolka gba-tests 13/13, FuzzARM 5/5, armwrestler |
| Bus | Cycle-counted waitstates, prefetch, open bus; mGBA suite tallies in `tests/results_mgba_suite.md` |
| PPU | Modes 0–5, sprites, windows, blending, mosaic; compositing per window span |
| APU | PSG 1–4 lazily caught up in closed form (observation points listed above `apu_catchup_all` in `gba/apu.nim`); Direct Sound FIFO with true-phase cubic reconstruction (`fifo_interp`), bit-true DAC mode available |
| DMA | Four channels, priority preemption, video capture |
| Timers | Scheduler-driven, cascade, overflow IRQ |
| Serial | Multi, Normal 8/16/32; in-process link, TCP, WebRTC; input-rollback netplay |
| Storage | SRAM, Flash, EEPROM; RTC with per-minute IRQ; GPIO rumble, tilt, gyro |
| HLE BIOS | Full SWI table except MultiBoot and the sound-driver SWIs (`notes/todo.md`) |
| Sound-driver HLE | MP2K/M4A shadow mixer (opt-in); Golden Sun "Bon" mixer behind `-d:gsbon` |
| Waitloop detection | Idle-loop fast-forward bounded by `apu_next_step()` (`DINGBAT_NO_WAITLOOP=1` disables) |

## Game Boy / Game Boy Color

| Subsystem | State |
|---|---|
| CPU | SM83, all 512 opcodes |
| PPU | Scanline and FIFO renderers; CGB palettes, HDMA, compat mode, SGB; revision axis (`docs/gb-hardware-revisions.md`) |
| APU | Channels 1–4 with closed-form lazy catch-up; DC-blocked output; SameSuite APU 70/70, blargg dmg_sound 12/12, cgb_sound 12/12 (`notes/samesuite-apu.md`) |
| Timer / serial / joypad | Complete; closed-form TIMA between events |
| MBC | ROM, MBC1/1M, MBC2, MBC3+RTC, MBC5+rumble, MBC6, MBC7, MMM01, HuC1, HuC3, TAMA5, Camera; flat-ROM window devirtualised (`-d:mbc_map_check` verifies) |
| Link | In-process, printer, online via rollback |

## Invariants worth knowing

- Save-state and rollback snapshots round-trip the lazy APU deadlines through the
  `etAPUChannel<N>` event slots, so the payload format did not change when the per-period
  events were removed. Event enum ordinals are save-state format; never reorder.
- `-d:psgverify` shadows every closed-form APU catch-up with the per-period loop it
  replaced and asserts they agree.
- Scheduler tie-break: when a waveform step lands on an observer's cycle, the more
  recently armed (shorter `arm_delay`) event wins. `gb_steps_due` in
  `gb/apu/abstract_channels.nim` reproduces it.
- Two places read `scheduler.next_event` to decide how far to skip the clock
  (`cpu.tick`'s idle-loop path, `dma.nim`'s mid-burst drain). Both must also consult
  `apu_next_step()`, or the skip length becomes the PSG's observation resolution.
- GB mode 3 cannot be made lazy: the end of mode 3 is CPU-observable (mode-0 STAT IRQ,
  HBlank DMA, VRAM unlock) and its dot is unknown without running the pipeline.
- Nim `defer` is block-scoped, not proc-scoped.
- `uint32 shl 32` is undefined in C; the ARM shifter handles 0, <32, 32, >32 explicitly.

## Measurement rules

- Compare retired instructions (`DINGBAT_BENCH_COUNTERS=1`, `/usr/bin/time -l`), not wall
  clock; wall clock lies below ~1.3%.
- Byte-identical framebuffer hashes (`DINGBAT_BENCH_HASH=1`) and PCM dumps
  (`DINGBAT_GB_AUDIO_DUMP` / `DINGBAT_GBA_AUDIO_DUMP` + `tools/pcmdiff.py`) are the
  regression gates for perf work. With the dump unset under `-d:test_harness` the GB mixer
  is dead-code-eliminated, so set it on both sides of an A/B.
- RTC carts (Pokemon Emerald/Ruby/Crystal) are not run-to-run reproducible across time;
  `ROMFUZZ_RTC_EPOCH` freezes the clock in `tools/romfuzz/dingbat_nav`.
- Headless Chrome halves browser numbers; bench in a visible window (`web/bench/README.md`).
