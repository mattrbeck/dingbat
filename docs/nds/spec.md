# DS support: spec and prototype map

Status: **prototype**. The DS core lives beside the GB and GBA cores
(`src/dingbat/nds/`), boots homebrew by direct boot, and renders both screens
on a dev page (`web/nds.html`) and in the main web app (`docs/nds/web.md`). Hardware reference: `docs/nds/gbatek-notes.md`
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
  synthesized when missing (every GBATEK section but code, the wifi
  calibration included: docs/nds/saves.md), and a missing BIOS gets the HLE
  BIOS (below).
  `DINGBAT_NDS_HLE=1` (or `new_nds(..., force_hle = true)`) forces the HLE
  BIOS with dumps present, to compare the two on one ROM.
- **Boot:** direct boot by default (the card's binaries loaded, the
  post-BIOS state written; encrypted, decrypted and ID-overwritten secure
  areas all handled). `--boot firmware` / `new_nds(..., boot = nbFirmware)`
  runs the real BIOSes and firmware from power-on through the card's KEY1/
  KEY2 handshake and the DS menu (all three dumps needed; no ROM = empty
  slot). docs/nds/boot.md.

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
the selected baud rate. GBA-slot accesses take their times from the
accessing CPU's own EXMEMCNT bits 0-4 (the table's rows are the default
setting). With these, SoulSilver runs frame-locked with the reference core
(docs/oracles.md, "NDS core").

The geometry engine takes GBATEK's cycles per command, a full GX FIFO holds
the writing CPU (and the ARM7), SWAP_BUFFERS waits for V-blank + 392, DMA
mode 7 and the GXFIFO IRQ follow the FIFO level through an `evGxFifo`
booking, and DMA mode 4 feeds the main-memory display FIFO 4 words per
request as the display reads it. The renderer's line budget gives
RDLINES_COUNT and the underflow flag. docs/nds/3d-timing.md has the model
and its evidence.
the selected baud rate (the ARM7 bus delivers its reply and IRQ at the end:
docs/nds/peripherals.md). With these, SoulSilver runs frame-locked with the
reference core (docs/oracles.md, "NDS core").

The ARM9's protection unit refuses accesses outside every region or
against a region's AP bits with a data abort (lr = opcode + 8) or prefetch
abort (lr = opcode + 4), as libnds's exception handler expects. For speed,
fetches are checked on branches and page crossings and data accesses to
main RAM and DTCM are not checked at all (`bus9.nim` pu_check9). Direct
boot leaves the regions as the firmware does, with the unit off
(`boot.nim`; docs/oracles.md).

## Layout

```
src/dingbat/nds/
  nds.nim          NDS object, construction, event dispatch, frame loop
  bus9.nim         ARM9 map + I/O dispatch     (included by nds.nim)
  bus7.nim         ARM7 map + I/O dispatch     (included by nds.nim)
  boot.nim         direct boot, firmware boot (power-on), synthesized
                   firmware, CRC16
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
  gpu/engine2d.nim 2D engine A/B registers + line renderer, main-memory display FIFO
  gpu3d/gpu3d.nim  3D engine: GXFIFO/ports, command timing, GXSTAT, registers, BG0 line output
  gpu3d/geometry.nim matrices, lighting, polygon assembly, clipping, tests
  gpu3d/render.nim  whole-frame rasteriser: textures, depth, blending, fog, edges,
                   line budget (RDLINES)
  io/irq.nim       IME/IE/IF per CPU
  io/timers.nim    4 timers per CPU
  io/dma.nim       4 channels per CPU (+ ARM9 fill regs)
  io/ipc.nim       IPCSYNC + FIFOs
  io/divsqrt.nim   ARM9 maths unit
  io/input.nim     KEYINPUT/KEYCNT/EXTKEYIN, touch, lid (IF.22)
  io/spi.nim       ARM7 SPI: power manager, firmware flash, touchscreen
                   (docs/nds/peripherals.md)
  io/mic.nim       microphone sample queue, read by the TSC's AUX channel
  io/cart.nim      card slot (ROMCTRL, raw/KEY1/KEY2 protocol, seeds, AUXSPI)
  io/cartcrypt.nim KEY1 (BIOS7 table at run time), KEY2, secure-area forms
  io/backup.nim    save chip: EEPROM/FRAM/FLASH, detection, .sav fitting,
                   IR-cart front-end (docs/nds/saves.md)
  io/slot2.nim     GBA slot: open bus, GBA cart (ROM, SRAM/FLASH/EEPROM via
                   gba/storage_chip.nim, GPIO), Rumble Pak, Expansion Pak
                   (docs/nds/slot2.md)
  io/spu.nim       ARM7 sound: 16 channels, capture, stereo out at 32728.5 Hz
  io/rtc.nim       ARM7 RTC (host clock, or emulated time from a date),
                   INT1/INT2 interrupts to SIO SI, RCNT
  io/wifi.nim      wifi MAC/BB/RF, transmitter, receiver, the Air between
                   consoles (docs/nds/wifi.md)
  air.nim          several machines in lockstep on one Air (local wireless)
  savestate.nim    save states: the machine walked field by field
                   (docs/nds/savestate.md)
src/dingbat_nds_wasm.nim(+.nims)  wasm exports (createNdsCore) for the app and web/nds.html
tools/ndsrun.nim                   headless runner: ROM -> PNG of both screens
tools/ndsair.nim                   the same for N machines on one Air
web/nds.html, web/nds/             dev page (two canvases, keys, touch); ndsutil.js,
                                   ndsaudio.js for the main app (docs/nds/web.md)
tools/ndssweep.nim                 compatibility sweep against tools/ndsref (docs/nds/compat.md)
tests/nds/                         ROM sources, build tools, README
tests/nds_3d_test.nim              3D engine driven through write_reg -> checks + PNGs,
                                   command timing, the 3d_* ROM hashes
tests/nds_hle_bios_test.nim        every HLE SWI against the real BIOS
tests/nds_slot2_test.nim           GBA-slot devices + the slot2_probe ROM
tests/nds_boot_test.nim            KEY1/KEY2, card handshake, secure area, direct boot
tests/nds_wifi_test.nim            wifi blocks on an Air; wifi_link on two machines
tests/nds_periph_test.nim          RTC interrupts, SPI, power manager, TSC, mic, sleep/lid
tests/nds_savestate_test.nim       save states: round trips at awkward moments, refusals
tests/nds_compat_test.nim          checks for the homebrew sweep's fixes
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

# the main app on the LAN over HTTPS (builds both cores; docs/nds/web.md)
tools/serve_nds_dev.sh
```

Third-party test ROMs: `~/.cache/dingbat-nds/roms/` (tests/nds/README.md).

## Subsystems and milestones

| Subsystem | First milestone |
|---|---|
| CPU (ARM9 + ARM7) | armwrestler and arm7wrestler all-pass; libnds crt0 reaches `main` |
| Memory / boot / BIOS | libnds `hello_world` and `template_combined` boot through both CPUs' crt0 + IPC handshake; HLE BIOS so no dump is required |
| 2D engines | libnds console (`hello_world`, `ansi_console`), `16bit_color_bmp`, `256_color_bmp`, `simple` sprites, window tests |
| IRQ / timers / DMA / IPC / maths | gbeplus irq/math/dma, rockwrestler system tests, `pxi`, `timercallback` |
| Input / touch / SPI / RTC | `touch_test` tracks the mouse; periph_suite (RTC interrupts, SPI timing, power manager, TSC channels, mic, sleep/lid: docs/nds/peripherals.md) |
| 3D | `Simple_Tri`, `Simple_Quad` |
| Sound | maxmod examples and Pokemon SoulSilver play (tests/nds_spu_test.nim, `snd_suite.nds` against the reference cores: docs/oracles.md NDS core) |
| GBA slot | `slot2_probe` under each device; SoulSilver's MIGRATE FROM <GBA game> with a Generation 3 cart (docs/nds/slot2.md) |
| Card + backup | a commercial ROM's B7 reads + save detection; the KEY1/KEY2 boot handshake (docs/nds/boot.md) |
| Wireless | two machines on one Air: wifi_link's beacon scan, data frames and multiplay rounds (tests/nds_wifi_test.nim); network play is a plan (docs/nds/wifi.md) |
| Timing | wait states, cache model, frame-rate-stable commercial boot |
| Frontend | desktop SDL target with both screens; main web UI integration (first cut: docs/nds/web.md) |

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
differs, a 2D alpha fade is one step off in places. It also boots through
the real BIOS, firmware and DS menu (`--boot firmware --press A@300,A@460`)
from any of its dump forms, frame for frame with the reference core's
firmware boot after the menu (docs/nds/boot.md).
