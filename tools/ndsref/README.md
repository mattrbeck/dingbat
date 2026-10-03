# ndsref: headless DS reference runs through a libretro core

`ndsref` loads a libretro core (a prebuilt shared library), runs a DS ROM for
N frames with no window and no audio device, and writes frames as 256x384
PNGs in `tools/ndsrun.nim`'s layout (top screen above bottom) plus the run's
audio as a WAV. It is the black-box half of a comparison: the core is only
ever *run* (docs/oracles.md: running another emulator is allowed and
recorded; reading its implementation is not). Only the public libretro API
header (`libretro.h`, MIT, vendored here) is used.

| File | What |
|---|---|
| `ndsref.c`, `build.sh` | the frontend (C, needs only a compiler and zlib) |
| `ndsdiff` | compare two same-size PNGs per screen, write a diff PNG |
| `ndscompare` | run one ROM through `ndsrun` and `ndsref` at the same frames and diff them |
| `ndsreloc` | copy a ROM with its ARM9 binary moved out of the cart secure area |

## Build

    sh tools/ndsref/build.sh            # -> tools/ndsref/ndsref
    nimble ndsref_build                 # the same, plus tools/ndsref/ndsrun

## ndsref

    tools/ndsref/ndsref --core CORE ROM [--frames N] [--out PREFIX]
        [--shots F1,F2,..] [--press KEY@F[+D|-L],..] [--touch X:Y@F[+D|-L],..]
        [--wav OUT.wav] [--bios DIR] [--sysfile NAME=PATH]
        [--opt KEY=VALUE].. [--opts-file FILE].. [--no-core-opts]
        [--list-opts] [--layout auto|tb|bt|lr|rl] [--depth5]
        [--workdir DIR] [--no-final] [--slot2 GBA[,SAVE]] [--rumble-log]
        [--ram-peek A1,..] [--ram-shots F1,..] [--sram FILE] [--sram-out FILE] [-v|-vv]

- `--core` takes a path to a libretro core, or a short NAME looked up as
  `NAME`, `NAME_libretro.dylib/.so/.dll` in `$NDSREF_CORES`, then
  `~/.cache/dingbat-nds/cores`. Core names and their settings live there,
  not in the repo.
- `--frames N` runs N frames (`retro_run` calls; default 60). `--shots`
  writes `PREFIX_<F>.png` after frame F, and `PREFIX.png` is the last frame
  (`--no-final` skips it). A trailing `.png` on `--out` is dropped, so
  `--out x.png` names files the way `ndsrun --out x.png` does.
- `--press` / `--touch` use `ndsrun`'s syntax: held from frame F (0-based,
  applied before that frame runs) for D frames (default 2), or until frame L.
  Keys: `A B X Y L R START SELECT UP DOWN LEFT RIGHT`; `TOUCH:x:y` inside
  `--press` is the same as `--touch x:y`. Touch is sent as a libretro pointer
  aimed at the centre of that bottom-screen pixel, so the core's touch mode
  must be its pointer/touch setting (see `--list-opts`).
- `--wav` writes every sample the core produced, 16-bit stereo, at the
  core's reported rate rounded to an integer in the header; the exact rate
  is printed (`audio: N frames at R Hz`).
- `--bios DIR` copies `bios7.bin`, `bios9.bin`, `firmware.bin` from DIR into
  the core's system directory; without it the directory is empty and the
  core uses whatever it does without dumps (HLE BIOS, built-in firmware).
  `--sysfile NAME=PATH` places any other file a core wants (`-v` shows the
  paths a core tries).
- Options: on start the core declares its options through the libretro
  options environment calls; `--list-opts` prints each key, its value (the
  default unless set) and the allowed values, then exits. Some cores declare
  options only when content loads, so give a ROM with `--list-opts`. Values
  are layered: `CORE.opts` beside the core file (e.g.
  `~/.cache/dingbat-nds/cores/NAME_libretro.opts`; `KEY=VALUE` lines, `#`
  comments) unless `--no-core-opts`, then each `--opts-file`, then each
  `--opt`; later wins. A key the core never declares, or a value outside its
  list, is warned about.
- The core's frame may be any of its own layouts. `--layout auto` (default)
  reads a frame at least 2:3 tall (256x384 and taller) as top/bottom, with
  the bottom screen anchored to the frame's bottom edge so a gap is skipped,
  and one at least 8:3 wide (512x192 and wider) as left/right; integer upscales are sampled back to 256x192. `tb`,
  `bt`, `lr`, `rl` force one. Hybrid/large-screen layouts are refused: pick
  a plain one with `--opt`. Pixel formats 0RGB1555, RGB565 and XRGB8888 are
  handled, with any pitch.
- `--depth5` keeps the top 5 bits of each channel and widens them as
  `ndsrun` does (`(c << 3) | (c >> 2)`). Cores that output RGB565 or 6-bit
  widened XRGB8888 differ from `ndsrun` by 2-4 per channel without it.
- `--ram-peek A1,..` prints those 32-bit words of the core's system RAM
  (`RETRO_MEMORY_SYSTEM_RAM`, main RAM for the DS cores) after every frame
  as `peek F A=V ..`, the format of `ndsrun --ram-peek`; `--ram-shots
  F1,..` writes the whole of it to `PREFIX_ram_<F>.bin` after frame F
  (`ndsrun --ram-shots` writes ours). With them a game's own counters and
  random-number state can be followed in both runs (docs/nds/commercial.md).
  `--sram-out FILE` writes the cart's save memory after the run.
- `--slot2 GBA[,SAVE]` loads the ROM with a GBA ROM (and its save) in the
  GBA slot through the core's first subsystem that takes two or more files
  (`-v` lists the subsystems; melonDS DS calls it `gba`, "Slot 1 & 2
  Boot"). `--rumble-log` takes the core's rumble interface and prints each
  strength change with its frame (`rumble frame=F strong=S`).
- Nothing is written outside `--out`, `--wav` and the scratch directory:
  system/ and save/ go under `--workdir DIR` or a fresh `$TMPDIR/ndsref.*`
  that is removed at exit. The core's stdout/stderr are silenced unless
  `-v`; `-vv` also logs every option read and every refused environment
  call. Hardware rendering is refused, so cores render in software.
- Exit status: 0, 1 when a frame could not be written, 2 on a usage or load
  error.

## ndsdiff

    tools/ndsref/ndsdiff A.png B.png [--out DIFF.png] [--tol N] [--quiet]

Per screen (a 256x384 image is split into top and bottom): mismatched pixel
count and percentage, the largest per-channel error, and the first mismatch.
A pixel mismatches when any channel differs by more than `--tol` (default 0).
The diff PNG shows matches as a dim grey copy of A and mismatches in red.
Exit 0 when identical within `--tol`, 1 otherwise.

## ndscompare

    tools/ndsref/ndscompare ROM --core CORE --shots 2,10,60
        [--frames N] [--ref-offset K] [--press ..] [--touch ..]
        [--bios DIR] [--opt KEY=VALUE].. [--relocate] [--tol N]
        [--out DIR] [--ndsrun PATH]

Runs `ndsrun` (built into `tools/ndsref/ndsrun` when missing, or `$NDSRUN`)
and `ndsref --depth5` with the same frames and inputs, then `ndsdiff` on each
shot: `DIR/ours_<F>.png`, `DIR/ref_<F+K>.png`, `DIR/diff_<F>.png`. `--ref-offset
K` compares our frame F with the core's F+K (input frames shift with it).
`--bios` goes to both runners. Exit 0 when every shot matches.

`--relocate` gives the core an `ndsreloc` copy of the ROM. A cart's ROM
4000h-7FFFh is the secure area (GBATEK, DS Cartridge Secure Area); the ROMs
in `~/.cache/dingbat-nds/roms` (and some old homebrew) put plain ARM9 code there, which
a core that checks the secure area on direct boot rejects as an all-white
frame. Relocating changes no code, only where it sits in the file.

## Alignment

- Use the core's direct-boot option. A firmware boot stops at the
  health-and-safety screen until touched and then reaches the menu, which
  does not list homebrew carts, so it is not comparable.
- Under direct boot the frame count lines up: libnds `hello_world` shows the
  same `Frame = N` counter as `ndsrun` at the same frame. A static scene is
  comparable from frame 2-10 depending on the core: what lags is how fast
  the ROM's own CPU-drawn setup finishes, i.e. CPU timing, not boot
  alignment. Compare settled scenes at frame 10+ (60 to be safe), or treat
  early-frame mismatches as a timing lead, not a misalignment.
- Run twice and compare: with the shipped core option files every core
  tested gave byte-identical PNGs and WAVs across runs. Watch for cores that
  read the host clock for the RTC (a ROM that shows the date/time will
  differ run to run) and for JIT / threaded-renderer options; set them off.

Per-core settings and findings are recorded in docs/oracles.md (DS reference
cores).
