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
  (sound output, later), `common/serialize.nim` (the state container,
  docs/nds/savestate.md), the
  frontends' plumbing.
- **BIOS:** real dumps are used when present (`--bios DIR` /
  `$DINGBAT_NDS_BIOS`: `bios9.bin`, `bios7.bin`, `firmware.bin`); firmware is
  synthesized when missing, and a missing BIOS gets the HLE BIOS (below).
  `DINGBAT_NDS_HLE=1` (or `new_nds(..., force_hle = true)`) forces the HLE
  BIOS with dumps present, to compare the two on one ROM.

## Timeline and timing

One master clock = ARM9 cycles (67.027964 MHz). A line is 355 dots x 6 bus
cycles = 4260 master cycles, H-blank at 3212, 263 lines, 59.8261 Hz.
`NDS.run_until` runs the ARM9 then the ARM7 up to the same slice end (at most
64 master cycles, or the next event), then dispatches due events.

CPU timing (`timing.nim`, hooked in by bus9/bus7): every code fetch and
data access is charged from GBATEK's "DS Memory Timings" tables (per region,
N/S, 16/32-bit; ARM9 opcode fetches always N32, a Thumb pair sharing one);
the ARM9's 8 KB I / 4 KB D caches are modelled as tags only, cachability from
the protection unit; instructions add their internal cycles. An ARM9 cycle is
one master cycle, an ARM7 cycle two. The few unpublished values are marked
Assumed in `timing.nim`. The card (`cart.nim`) times ROM words by its CLK,
gap1 and gap2, and both SPI buses keep their busy flags for the byte's time at
the selected baud rate. With these, SoulSilver runs frame-locked with the
reference core (docs/oracles.md, "NDS core").

## Layout

```
src/dingbat/nds/
  nds.nim          NDS object, construction, event dispatch, frame loop
  bus9.nim         ARM9 map + I/O dispatch     (included by nds.nim)
  bus7.nim         ARM7 map + I/O dispatch     (included by nds.nim)
  boot.nim         direct boot, synthesized firmware, CRC16
  hle_bios.nim     HLE BIOS: synthesized images + SWIs answered in Nim
  hle_bios.s       its guest code (vectors, IRQ/SWI dispatch, IntrWait,
                   callback decompressors); tools/nds_hle_bios.sh assembles
                   it into hle_bios_image.nim
  sched.nim        event scheduler, timing constants
  timing.nim       CPU memory timing: access tables, ARM9 cache tags
  arm/cpu.nim      ArmCpu[B]: ARM + Thumb, ARMv4T/v5TE
  arm/cp15.nim     CP15 registers, TCM regions
  mem/vram.nim     VRAM banks A-I, VRAMCNT page tables
  gpu/gpu.nim      display timing, DISPSTAT, POWCNT1, screen routing
  gpu/engine2d.nim 2D engine A/B registers + line renderer
  gpu3d/gpu3d.nim  3D engine: GXFIFO/ports, GXSTAT, registers, BG0 line output
  gpu3d/geometry.nim matrices, lighting, polygon assembly, clipping, tests
  gpu3d/render.nim  whole-frame rasteriser: textures, depth, blending, fog, edges
  io/irq.nim       IME/IE/IF per CPU
  io/timers.nim    4 timers per CPU
  io/dma.nim       4 channels per CPU (+ ARM9 fill regs)
  io/ipc.nim       IPCSYNC + FIFOs
  io/divsqrt.nim   ARM9 maths unit
  io/input.nim     KEYINPUT/KEYCNT/EXTKEYIN, touch, lid
  io/spi.nim       ARM7 SPI: power manager, firmware flash, touchscreen
  io/cart.nim      card slot (ROMCTRL, B7 reads, AUXSPI)
  io/backup.nim    save chip: EEPROM/FRAM/FLASH, IR-cart front-end
  io/spu.nim       ARM7 sound: 16 channels, capture, stereo out at 32728.5 Hz
  io/rtc.nim       ARM7 RTC (host clock, or emulated time from a date)
  io/wifi.nim      wifi MAC/BB/RF without a radio (nothing is received)
  savestate.nim    save states: the machine walked field by field
                   (docs/nds/savestate.md)
src/dingbat_nds_wasm.nim(+.nims)  wasm exports for web/nds.html
tools/ndsrun.nim                   headless runner: ROM -> PNG of both screens
web/nds.html, web/nds/             dev page (two canvases, keys, touch)
tests/nds/                         ROM sources, build tools, README
tests/nds_3d_test.nim              3D engine driven through write_reg -> checks + PNGs
tests/nds_hle_bios_test.nim        every HLE SWI against the real BIOS
tests/nds_savestate_test.nim       save states: round trips at awkward moments, refusals
```

I/O registers are reached as aligned 32-bit words with a byte mask
(`read_reg(offset)` / `write_reg(offset, value, mask)`), so 8/16/32-bit
accesses share one path per register.

## Building and running

```
# headless: both screens to one PNG
nim c -d:release -d:test_harness --path:src -o:ndsrun tools/ndsrun.nim
./ndsrun ~/.cache/dingbat-nds/roms/fb_both.nds --frames 5 --out /tmp/fb.png \
    --bios "$HOME/Documents/emu/nds/NDS Bios & Firmware"

# web dev page
nim c -d:emscripten src/dingbat_nds_wasm.nim      # -> web/nds/nds.{js,wasm}
cp ~/.cache/dingbat-nds/roms/fb_both.nds web/nds/demos/   # demos are gitignored
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
| Sound | maxmod examples and Pokemon SoulSilver play (tests/nds_spu_test.nim, `snd_suite.nds` against the reference cores: docs/oracles.md NDS core) |
| Card + backup | a commercial ROM's B7 reads + save detection |
| Timing | wait states, cache model, frame-rate-stable commercial boot |
| Frontend | desktop SDL target with both screens; main web UI integration |

Milestone 1 (this skeleton): fb_hello / fb_both render on both screens in
`ndsrun` and on `web/nds.html`.

## HLE BIOS

Without dumps each CPU gets a synthesized BIOS image (`hle_bios.nim`): real
ARM code assembled from `hle_bios.s`, never bytes from Nintendo's BIOS. The
CPU's `swi_hook` hands every SWI to `hle_swi` first; the pure ones (Div,
Sqrt, CpuSet, CpuFastSet, GetCRC16, IsDebugger, BitUnPack, the ReadNormal
decompressors, Diff filters, SoftReset, Halt/Sleep/CustomHalt/CustomPost,
SoundBias, the ARM7 tables) run in Nim. WaitByLoop, IntrWait,
VBlankIntrWait and the three ReadByCallback decompressors take the SWI
vector into the image's dispatcher (SPSR/r11/r12/lr on the SVC stack,
System mode with the caller's I bit), since they halt with IRQs taken
between checks or call back into the game.

`tests/nds_hle_bios_test.nim` runs each SWI on both BIOSes in the emulator
with the same inputs and compares registers, written memory, IRQ handler
calls and the IntrWait check word (`nimble test_ndshlebios`; without dumps
it checks the HLE against expectations it computes). What it established
beyond GBATEK:

- The decompressors finish the token they are in, so output overruns the
  header size by up to 17 (LZ77) or 129 (RL) bytes; the 16-bit-write
  callback forms never store an odd last byte.
- ARM9 IntrWait sets IME=1 only inside its flag checks. With r0 = 0 it
  halts before the first check, with the caller's IME, then halts and
  checks until a wanted flag turns up: at least one IRQ even when the flag
  was already set, and with IME=0 that first CP15 halt never ends. The
  cases run with IME=1, as a game's IRQ setup leaves it, plus IME=0 ones
  for the hang. r0 = 1 and every ARM7 case behave as documented.
- SoftReset zeroes SPSR_svc/SPSR_irq with an MSR, so they read 0x10 (mode
  bit 4 wired high).
- GetSineTable = round(sin(i * pi/128) * 0x7FFF); GetPitchTable =
  round((2^(i/768) - 1) * 0x10000); GetVolumeTable = 0.1 dB steps from
  -72.3 dB, round(128 * 10^((i-723)/200) * m) with m the largest of 16/4/2
  keeping it below full scale, clamped to 127, except entries 602, 662 and
  722, which read 126.
- Register residues the HLE reproduces: CpuSet (word form) and CpuFastSet
  advance r0/r1, CpuFastSet's r3 shows its "first N bytes" burst bug,
  Sqrt leaves its Newton scratch in r1/r3, GetCRC16/BitUnPack/LZ77/RL/
  Diff advance their pointers, the callback forms return the close pointer
  in r1. BIOS-internal addresses left in r3 (and ARM7 RL's r0) are not
  reproduced.

## Commercial game status

Pokemon SoulSilver (IPGE, the one commercial ROM used in development; never
in the repo) plays from boot through the intro, title, the professor's
introduction, name entry and the 3D bedroom to New Bark Town, saves (512 KB
FLASH behind the IR controller) and continues from that save, with the real
BIOS or the HLE BIOS (identical frames). Driven by `ndsrun --press` scripts
(`TOUCH:x:y` for the touch-screen buttons) with `--rtc 2004-01-01`, the same
script gives the same frames as the reference core at most checkpoints
(`tools/ndsref`, docs/oracles.md). Open: 3D rasterisation differs from the
reference by edge pixels (bedroom, overworld), the title screen's 3D Lugia
differs, a 2D alpha fade is one step off in places.
