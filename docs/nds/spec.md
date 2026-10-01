# DS support: spec and prototype map

Status: **prototype**. The DS core lives beside the GB and GBA cores
(`src/dingbat/nds/`), boots homebrew by direct boot, and renders both screens
on a dev page (`web/nds.html`). Hardware reference: `docs/nds/gbatek-notes.md`
(GBATEK distilled into shared / changed / new against the GBA).

## What the DS is, against what dingbat already has

| Piece | DS | Relation to the GBA core |
|---|---|---|
| ARM7 | ARM7TDMI @ 33.51 MHz | same ISA as the GBA CPU |
| ARM9 | ARM946E-S @ 67.03 MHz, ARMv5TE, CP15, ITCM 32K / DTCM 16K, caches | new |
| Memory | 4 MB main RAM, 32K shared WRAM (WRAMCNT), 64K ARM7 WRAM, 656K VRAM in 9 banks | new map |
| 2D | two engines (A, B) | the GBA PPU plus extended BG modes, ext palettes, master brightness, capture, VRAM/FIFO display |
| 3D | geometry engine + rasteriser, output as engine A BG0 | new |
| Sound | 16-channel ARM7 SPU | new (no PSG/FIFO) |
| IRQ / timers / DMA / keypad | per CPU | GBA-shaped; IE/IF 32-bit, DMA modes and counts changed |
| IPC, maths unit, SPI (firmware, touch, power), RTC, card | | new |

## Reuse decisions

- **CPU: new generic interpreter, not the GBA's.** `gba/arm`, `gba/thumb` and
  `gba/cpu.nim` reach through `cpu.gba.bus` into the AGB prefetcher, waitloop
  detector, LDM^ glitch and cycle-exact IRQ entry -- every one an AGB SP
  measurement. `nds/arm/cpu.nim` is `ArmCpu[B]`, generic over its bus, with
  `armv5(B)` selecting ARMv5TE behaviour; the ARM9 and ARM7 are two
  instantiations. If the DS interpreter matures, the GBA could move onto it,
  never the other way round.
- **Scheduler: local.** `common/scheduler.nim`'s `EventType` ordinals are
  GB/GBA save-state format and its `CycleCount` is 32-bit on wasm.
  `nds/sched.nim` keeps its own small event set on a 64-bit master clock
  (the ARM9 clock, 2x the bus clock).
- **2D rendering: port, don't share.** The GBA PPU's text/affine/OBJ/window/
  blend logic carries over, but it indexes flat VRAM; DS engines read
  through the VRAM bank page tables (`mem/vram.nim`). Port the algorithms
  into `gpu/engine2d.nim`.
- **Shared as is:** `bitfield.nim`, `common/util.nim`, `common/resampler.nim`
  (sound output, later), `common/serialize.nim` (save states, later), the
  frontends' plumbing.
- **BIOS:** real dumps are used when present (`--bios DIR` /
  `$DINGBAT_NDS_BIOS`: `bios9.bin`, `bios7.bin`, `firmware.bin`); firmware is
  synthesized when missing. HLE BIOS is a subsystem below.

## Timeline and timing

One master clock = ARM9 cycles (67.027964 MHz). A line is 355 dots x 6 bus
cycles = 4260 master cycles, H-blank at 3212, 263 lines, 59.8261 Hz.
`NDS.run_until` runs the ARM9 then the ARM7 up to the same slice end (at most
64 master cycles, or the next event), then dispatches due events.

Placeholder timing: 2 master cycles per ARM9 instruction, 4 per ARM7
instruction, no memory wait states (`access_cycles` mixin returns 0). Real
timing (GBATEK section 3: N32+3 ARM9 fetches outside TCM/cache, main-RAM
waits, cache hits) is its own subsystem.

## Layout

```
src/dingbat/nds/
  nds.nim          NDS object, construction, event dispatch, frame loop
  bus9.nim         ARM9 map + I/O dispatch     (included by nds.nim)
  bus7.nim         ARM7 map + I/O dispatch     (included by nds.nim)
  boot.nim         direct boot, synthesized firmware, CRC16
  sched.nim        event scheduler, timing constants
  arm/cpu.nim      ArmCpu[B]: ARM + Thumb, ARMv4T/v5TE
  arm/cp15.nim     CP15 registers, TCM regions
  mem/vram.nim     VRAM banks A-I, VRAMCNT page tables
  gpu/gpu.nim      display timing, DISPSTAT, POWCNT1, screen routing
  gpu/engine2d.nim 2D engine A/B registers + line renderer
  gpu3d/gpu3d.nim  3D engine (stub)
  io/irq.nim       IME/IE/IF per CPU
  io/timers.nim    4 timers per CPU
  io/dma.nim       4 channels per CPU (+ ARM9 fill regs)
  io/ipc.nim       IPCSYNC + FIFOs
  io/divsqrt.nim   ARM9 maths unit
  io/input.nim     KEYINPUT/KEYCNT/EXTKEYIN, touch, lid
  io/spi.nim       ARM7 SPI: power manager, firmware flash, touchscreen
  io/cart.nim      card slot (ROMCTRL, B7 reads), backup (stub)
  io/spu.nim       ARM7 sound: 16 channels, capture, stereo out at 32728.5 Hz
  io/rtc.nim       ARM7 RTC (stub)
  io/wifi.nim      wifi registers (stub)
src/dingbat_nds_wasm.nim(+.nims)  wasm exports for web/nds.html
tools/ndsrun.nim                   headless runner: ROM -> PNG of both screens
web/nds.html, web/nds/             dev page (two canvases, keys, touch)
tests/nds/                         ROM sources, build tools, README
```

I/O registers are reached as aligned 32-bit words with a byte mask
(`read_reg(offset)` / `write_reg(offset, value, mask)`), so 8/16/32-bit
accesses share one path per register.

## Building and running

```
# headless: both screens to one PNG
nim c -d:release -d:test_harness --path:src -o:ndsrun tools/ndsrun.nim
./ndsrun tests/nds/roms/fb_both.nds --frames 5 --out /tmp/fb.png \
    --bios "$HOME/Documents/emu/nds/NDS Bios & Firmware"

# web dev page
nim c -d:emscripten src/dingbat_nds_wasm.nim      # -> web/nds/nds.{js,wasm}
python3 -m http.server 8791 -d web                # open /nds.html?rom=nds/demos/fb_both.nds
```

Third-party test ROMs: `~/.cache/dingbat-nds/roms/` (tests/nds/README.md).

## Subsystems and milestones

| Subsystem | First milestone |
|---|---|
| CPU (ARM9 + ARM7) | armwrestler and arm7wrestler all-pass; libnds crt0 reaches `main` |
| Memory / boot / BIOS | libnds `hello_world` and `template_combined` boot through both CPUs' crt0 + IPC handshake; HLE BIOS so no dump is required |
| 2D engines | libnds console (`hello_world`, `ansi_console`), `16bit_color_bmp`, `256_color_bmp`, `simple` sprites, window tests |
| IRQ / timers / DMA / IPC / maths | gbeplus irq/math/dma, rockwrestler system tests, `pxi`, `timercallback` |
| Input / touch / SPI / RTC | `touch_test` tracks the mouse |
| 3D | `Simple_Tri`, `Simple_Quad` |
| Sound | maxmod example plays (so far: tests/nds_spu_test.nim and `snd_tone.nds`) |
| Card + backup | a commercial ROM's B7 reads + save detection |
| Timing | wait states, cache model, frame-rate-stable commercial boot |
| Frontend | desktop SDL target with both screens; main web UI integration |

Milestone 1 (this skeleton): fb_hello / fb_both render on both screens in
`ndsrun` and on `web/nds.html`.
