# NDS test ROMs

Fixtures for the DS core, ordered roughly from "first thing that can work" to
"needs most of the machine".

## Where the ROMs live

Only our own `fb_hello.nds` / `fb_both.nds` / `gx_tri.nds` are committed. The third-party
ROMs below carry no licence (gbe-plus-nds-tests is GPLv2), so they are
gitignored and kept in **`~/.cache/dingbat-nds/roms/`** (same layout as
`roms/`), where every worktree can reach them. Rebuild them with the scripts
under Building if the cache is lost.

## ROMs

| ROM | Source | Needs | Shows |
|---|---|---|---|
| `roms/fb_hello.nds` | `src/fb_hello` (ours) | ARM9 stores only | top screen gradient: TL blue, TR red, BL cyan, BR yellow (exact formula in `arm9.s`) |
| `roms/fb_both.nds` | `src/fb_both` (ours) | + engine B backdrop | fb_hello on top, solid magenta (0x7C1F) bottom |
| `roms/snd_tone.nds` | `src/snd_tone` (ours) | ARM7 I/O stores, SPU | green top, blue bottom; sound: 440 Hz PSG square (ch 8, panned left) + 220 Hz PCM8 saw (ch 0, panned right). `ndsrun --wav` dumps it |
| `roms/gx_tri.nds` | `src/gx_tri` (ours) | + 3D geometry/rendering, engine A BG0 = 3D | top: RGB-shaded triangle (left, command ports) and yellow quad (right, packed GXFIFO) over a dark blue (0x2042) rear plane |
| `roms/armwrestler.nds` | [mic-/armwrestler](https://github.com/mic-/armwrestler), built by `tools/build_wrestlers.sh` | ARM9 ARM/Thumb, LCDC VRAM display, KEYINPUT, DISPSTAT polling | menu of ARM9 instruction tests (ALU, LDR/STR, LDM/STM, Thumb), pass/fail per row |
| `roms/arm7wrestler.nds` | [Arisotura/arm7wrestler](https://github.com/Arisotura/arm7wrestler), same script | both CPUs; ARM7 runs the tests, ARM9 copies its frame | same menu run on the ARM7, including v5 opcodes that must be undefined/no-op there |
| `roms/rockwrestler.nds` | [RockPolish/rockwrestler](https://github.com/RockPolish/rockwrestler) (prebuilt upstream) | both CPUs, IPCSYNC/IPCFIFO, DIV/SQRT, WRAMCNT, VRAMCNT, TCM, CP15 | ARMv4/v5 extras + DS system tests, LCDC display |
| `roms/gbeplus/arm9_{memory,thumb,irq,math,dma}.nds` | [shonumi/gbe-plus-nds-tests](https://github.com/shonumi/gbe-plus-nds-tests) (GPLv2), rebuilt with libnds 2 | libnds runtime (see below) | ARM9 memory/mirrors, Thumb, IRQ, DIV/SQRT, DMA. (Timer test does not assemble upstream: duplicate labels in `common.s`.) |
| `roms/window/window-{basic,hblank,midframe}.nds` | [StrikerX3/nds-tests](https://github.com/StrikerX3/nds-tests), rebuilt with libnds 2 | libnds runtime, 2D windows | window registers, H-blank and mid-frame window changes |
| `roms/built/cardread.nds` | `src/cardread` (ours, libnds) | libnds runtime, slot-1 card | bottom console: PASS/FAIL per card read check (CPU and slot-1 DMA reads, main-mode low-address redirect, chip ID) |
| `roms/built/*.nds` | [devkitPro/nds-examples](https://github.com/devkitPro/nds-examples) | libnds runtime | `hello_world`, `ansi_console` (text console), `template_arm9`, `template_combined`, `16bit_color_bmp`, `256_color_bmp`, `Double_Buffer` (bitmap BGs), `simple` (sprites), `Simple_Tri`, `Simple_Quad` (3D), `pxi` (IPC), `timercallback`, `touch_test` |

Load/entry addresses:

- `fb_*`, `snd_tone`, `arm7wrestler`: ARM9 0x02000000, ARM7 0x037F8000.
- `armwrestler`: ARM9 0x02004000, ARM7 0x03800000. Its crt0 puts the stacks at
  0x00803EC0/0x00803FA0 without touching CP15, so it relies on ITCM being
  mirrored across 0x00000000-0x01FFFFFF as it is after a normal boot.
- `rockwrestler`: ARM9 0x02000100, ARM7 0x03800100.
- every libnds 2 ROM (gbeplus, window, built): ARM9 0x02004000 entry
  0x02004800, ARM7 0x02380000. Unit code 0x02 (DS + DSi header; DS mode can
  ignore the DSi fields). The runtime (calico) handshakes ARM9 and ARM7 over
  IPCSYNC/IPCFIFO before `main`, sets up the MPU/TCMs and reads firmware user
  settings, so these need both CPUs, IPC, IRQs and BIOS SWIs working before
  they show anything.

## Building

### No library (fb_*, snd_tone, wrestlers)

Only GNU binutils for `arm-none-eabi` (Homebrew `arm-none-eabi-binutils`, or
devkitARM) and python3:

    tests/nds/tools/build_fb.sh
    tests/nds/tools/build_wrestlers.sh [workdir]   # fetches the two upstream repos

`tools/mknds.py` writes the cartridge header (CRC16 included, boot logo left
zeroed; `--logo-from` copies one if a firmware boot is ever wanted).

### libnds (nds-examples and the rebuilt third-party ROMs)

This machine has devkitARM r67.1 (gcc 15.2) in `/opt/devkitpro` but only the
GBA packages: no ndstool, calico or libnds. pkg.devkitpro.org refuses
non-pacman downloads, dkp-pacman needs root, and Docker's daemon is not
running here, so `tools/setup_libnds.sh` builds the missing pieces from
devkitPro's GitHub sources into a user prefix (a few minutes, no root):

    tests/nds/tools/setup_libnds.sh ~/.cache/dingbat-dkp
    tests/nds/tools/with_libnds.sh ~/.cache/dingbat-dkp make -C <nds-examples>/hello_world

`src/cardread` builds the same way (`make -C tests/nds/src/cardread`; copy
`cardread.nds` into `roms/built/`).

Output is byte-identical to what produced `roms/built/`. Every nds-examples
project builds except the three dswifi ones, the nitrofs/libfat filesystem
ones, `capture/ScreenShot` and `Printing/print_both_screens` (they need
dswifi / libfilesystem / libfat, not set up here).

With Docker running, the standard image should also work (not tried here):

    docker run --rm -v "$PWD":/src -w /src devkitpro/devkitarm make -C <project>
