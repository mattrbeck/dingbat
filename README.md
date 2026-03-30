<p align="center"><img src="README/dingbat_large.png"></p>

Dingbat is a Game Boy, Game Boy Color, and Game Boy Advance emulator written in Nim. Game Boy and Game Boy Color emulation are very accurate, while Game Boy Advance is considered playable in many games.

The Game Boy and Game Boy Color work would not be possible without the [Pan Docs](https://gbdev.io/pandocs), [izik's opcode table](https://izik1.github.io/gbops), the [gbz80 opcode reference](https://rednex.github.io/rgbds/gbz80.7.html), [The Cycle-Accurate Game Boy Docs](https://github.com/AntonioND/giibiiadvance/blob/master/docs/TCAGBD.pdf), or gekkio's [Game Boy: Complete Technical Reference](https://gekkio.fi/files/gb-docs/gbctr.pdf). The Game Boy Advance work would not be possible without [GBATEK](http://problemkaputt.de/gbatek.htm), [Tonc](https://www.coranac.com/tonc), [mGBA](https://mgba.io/), or the wonderful emudev community.

<p align="center"><img width="800" src="README/GoldenSun.gif"></p>

## Building

[SDL2](https://www.libsdl.org/) and [Dear ImGui](https://github.com/ocornut/imgui) (via [imguin](https://github.com/dinau/imguin)) are required. SDL2 is available on every major package manager.

After cloning the repository, run `nimble build -d:release` to build the emulator in release mode. This will place the binary at `./dingbat`.

### WASM / Browser Build

To build for the browser using Emscripten, run `nimble wasm`. This configures various flags that are required for the web build.

Serve the `web/` directory with `python3 web/serve.py` (required for SharedArrayBuffer support).

## Usage

Running the emulator is as simple as running the `dingbat` executable. If you'd rather launch a specific ROM directly, you can pass it as a command-line argument: `./dingbat /path/to/rom`.

A GBA BIOS is required for GBA emulation. You can select it through the UI or place it at `~/.config/dingbat/bios.bin`.

### Pixel-Accurate GB / GBC Rendering

To enable the experimental FIFO renderer (as opposed to the scanline renderer), toggle it in the config editor. The FIFO implementation handles games like Prehistorik Man more accurately since that game relies on a cycle-accurate PPU implementation.

## Features and Remaining Work

### Features

- Frontend
  - Open ROMs
  - Select BIOS
  - Rebind keys
  - Toggle syncing
- GB / GBC
  - Accurate sound emulation
  - Controller support
  - Passing [blargg's CPU tests](https://github.com/retrio/gb-test-roms/tree/master/cpu_instrs)
  - Passing [blargg's instruction timing tests](https://github.com/retrio/gb-test-roms/tree/master/instr_timing)
  - Passing [blargg's memory timing tests](https://github.com/retrio/gb-test-roms/tree/master/mem_timing)
  - Passing [blargg's Game Boy Color sound tests](https://github.com/retrio/gb-test-roms/tree/master/cgb_sound)
  - Passing [mooneye-gb timer tests](https://github.com/Gekkio/mooneye-gb/tree/master/tests/acceptance/timer)
  - PPU draws background, window, and sprites
  - PPU offers both scanline and FIFO rendering modes
  - Save files work as intended, and are compatible with other emulators like BGB
  - MBC1 cartridges are supported (except for multicarts)
  - MBC2 cartridges are fully supported
  - MBC3 cartridges are supported (except timers)
  - MBC5 cartridges are supported
  - Game Boy Color support, including HDMA, double-speed mode, and palettes
- GBA
  - Accurate sound emulation (both Direct Sound and PSGs)
  - Controller support
  - PPU features
    - Modes 0-5 are mostly implemented
    - Affine backgrounds and sprites
    - Alpha blending
    - Windowing
  - CPU core
    - Passing [armwrestler](https://github.com/destoer/armwrestler-gba-fixed)
    - Passing [FuzzARM](https://github.com/DenSinH/FuzzARM)
    - Passing [gba-suite](https://github.com/jsmolka/gba-suite)
  - Storage
    - Flash
    - SRAM
    - EEPROM
  - Timers run efficiently on the scheduler
  - Real-time clock support
  - Browser/WASM build

### Remaining Work

- GB / GBC
  - Pixel FIFO: sprites on column 0 of the LCD not yet rendered
  - MBC5 rumble
  - RTC
  - Other hardware bugs tested in blargg's test suite
- GBA
  - PPU: Mosaic
  - Storage: Game database for odd cases (Classic NES, ROMs that misreport things)
  - Timing: cycle counting, DMA timing, prefetch
- Debugger for both GB and GBA

## Special Thanks

A special thanks goes out to those in the emudev community who are always helpful, both with insightful feedback and targeted test ROMs.

- https://github.com/ladystarbreeze
- https://github.com/DenSinH
- https://github.com/fleroviux
- https://github.com/destoer
- https://github.com/GhostRain0

## Contributors

- [Matthew Beck](https://github.com/mattrbeck) - creator and maintainer
