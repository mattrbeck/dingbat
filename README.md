<p align="center"><img src="README/dingbat_large.png"></p>

Dingbat is a Game Boy, Game Boy Color, and Game Boy Advance emulator written in Nim. Game Boy and Game Boy Color emulation are very accurate, while Game Boy Advance emulation is accurate enough to play the large majority of games, including link cable games both locally and online in the browser.

The Game Boy and Game Boy Color work would not be possible without the [Pan Docs](https://gbdev.io/pandocs), [izik's opcode table](https://izik1.github.io/gbops), the [gbz80 opcode reference](https://rednex.github.io/rgbds/gbz80.7.html), [The Cycle-Accurate Game Boy Docs](https://github.com/AntonioND/giibiiadvance/blob/master/docs/TCAGBD.pdf), or gekkio's [Game Boy: Complete Technical Reference](https://gekkio.fi/files/gb-docs/gbctr.pdf). The Game Boy Advance work would not be possible without [GBATEK](http://problemkaputt.de/gbatek.htm), [Tonc](https://www.coranac.com/tonc), [mGBA](https://mgba.io/), or the wonderful emudev community.

<p align="center"><img width="800" src="README/GoldenSun.gif"></p>

## Building

[SDL2](https://www.libsdl.org/) and [Dear ImGui](https://github.com/ocornut/imgui) (via [imguin](https://github.com/dinau/imguin)) are required. SDL2 is available on every major package manager.

After cloning the repository, run `nimble build -d:release` to build the emulator in release mode. This will place the binary at `./dingbat`.

### WASM / Browser Build

To build for the browser using Emscripten, run `nimble wasm`. This configures various flags that are required for the web build.

Serve the `web/` directory with `python3 web/serve.py` (required for SharedArrayBuffer support). Online play uses a small signaling server to exchange room codes. Node and zero-dependency Nim implementations are provided in `web/signaling/`.

### Windows Build (cross-compiled)

Windows binaries are cross-compiled with mingw-w64 inside a Docker container — no Windows machine needed:

```sh
docker build --platform linux/amd64 -t dingbat-win-cross docker/windows-cross
docker run --rm --platform linux/amd64 \
  -v "$PWD":/src -v dingbat-nimble:/root/.nimble -w /src \
  dingbat-win-cross ./docker/windows-cross/build.sh
```

This produces a self-contained `dist/windows/dingbat.exe` — SDL2 (zlib-licensed) and the mingw C++ runtime are linked statically, so the single exe is the entire distribution. If an end user ever needs a different SDL2 build (e.g. for a controller fix), SDL's dynamic API override still works: set `SDL_DYNAMIC_API=C:\path\to\SDL2.dll`.

## Usage

Running the emulator is as simple as running the `dingbat` executable. If you'd rather launch a specific ROM directly, you can pass it as a command-line argument (`./dingbat /path/to/rom`) or drag a ROM file onto the window. Zipped ROMs are supported: the first `.gba`/`.gb`/`.gbc` file in the archive is loaded.

No GBA BIOS file is needed. An HLE BIOS is built in and used by default. If you have a real BIOS dump, you can select it through the UI or place it at `~/.config/dingbat/bios.bin` (`%APPDATA%\dingbat\bios.bin` on Windows).

### Link Cable / Multiplayer

The link cable is emulated at three levels: two cores in one process, two dingbat processes over TCP, and online play in the browser using WebRTC with room codes. This covers both GBA link games (Pokémon cross-game trading like Emerald and FireRed, with optional rollback netplay) and GB/GBC link games (Pokémon Gen 1/2 trades). Two tabs in the same browser can even link without a server. See `docs/link-usage.md` for details.

### Pixel-Accurate GB / GBC Rendering

The GB / GBC PPU offers two implementations: a cycle-accurate FIFO renderer (the default) and a faster scanline renderer. The FIFO implementation handles games like Prehistorik Man accurately since that game relies on a cycle-accurate PPU implementation. The renderer can be selected in the settings window, and takes effect on the next ROM load or reset.

## Features and Remaining Work

### Features

- Frontend
  - Open ROMs
  - Select BIOS
  - Rebind keys
  - Controller support
  - Save states
  - Rewind
  - Fast forward and 2x speed
  - Pause and frame advance
  - Screenshots
  - Volume and per-channel audio controls
  - LCD color correction (per-panel: AGB and GBC models)
  - Scanlines and interframe blending (LCD ghosting)
  - MBC5 rumble (controller rumble + screen shake)
  - Link cable window for network play
  - Debug windows for the PPU, IO registers, and scheduler
- Web frontend
  - Touch controls
  - Gamepad support
  - Installable as an offline-capable PWA
  - Save states, rewind, and fast forward
  - Per-ROM save files kept in IndexedDB, with "Manage ROMs & Saves" modals
  - Home screen with a recently-played grid
  - Google Drive save/ROM backup (experimental)
  - Online link play with room codes
  - Tabbed settings panel: key rebinding, GB renderer choice, GBA BIOS/HLE
    modes, color correction, integer scaling, scanlines, motion blur
    (interframe blending), and an ambient glow backdrop
  - Desktop keyboard shortcuts (pause, fast forward, rewind, save states,
    screenshot, fullscreen, mute)
  - MBC5 rumble: gamepad vibration where supported, screen shake everywhere
  - Per-panel color correction: mGBA's AGB model for GBA, the
    hardware-measured "GBC-Color" model for GB/GBC
- GB / GBC
  - Accurate sound emulation
  - Passing 13 of 15 of blargg's [cpu_instrs](https://github.com/retrio/gb-test-roms/tree/master/cpu_instrs), [instr_timing](https://github.com/retrio/gb-test-roms/tree/master/instr_timing), and [memory timing](https://github.com/retrio/gb-test-roms/tree/master/mem_timing) ROMs (06-ld r,r and instr_timing still hang)
  - Passing [blargg's Game Boy Color sound tests](https://github.com/retrio/gb-test-roms/tree/master/cgb_sound)
  - Passing [mooneye-gb timer tests](https://github.com/Gekkio/mooneye-gb/tree/master/tests/acceptance/timer)
  - PPU draws background, window, and sprites
  - PPU offers both scanline and FIFO rendering modes
  - Save files work as intended, and are compatible with other emulators like BGB
  - MBC1 cartridges are supported (except for multicarts)
  - MBC2 cartridges are fully supported
  - MBC3 cartridges are fully supported, including the real-time clock
  - MBC5 cartridges are supported, including the rumble motor
  - Serial port and link cable (two cores in one process, and online in the browser via input-rollback netplay)
  - Game Boy Color support, including HDMA, double-speed mode, and palettes
- GBA
  - Accurate sound emulation (both Direct Sound and PSGs)
  - HLE BIOS, so no BIOS file is required
  - PPU features
    - Modes 0-5
    - Affine backgrounds and sprites
    - Alpha blending
    - Windowing
    - Mosaic
  - CPU core
    - Passing [armwrestler](https://github.com/destoer/armwrestler-gba-fixed)
    - Passing [FuzzARM](https://github.com/DenSinH/FuzzARM)
    - Passing [gba-suite](https://github.com/jsmolka/gba-suite)
  - Timing
    - Cycle-counted bus with waitstates and prefetch
    - DMA channel priority and preemption
    - Passing the AGS aging cartridge (all tests except COM, which requires a second multiboot unit)
    - Timers run efficiently on the scheduler
    - Idle-loop detection to skip busy-waits
  - Storage
    - Flash
    - SRAM
    - EEPROM
  - Link cable support, both locally and online
  - Real-time clock support
  - Save states
  - Browser/WASM build

### Remaining Work

- GB / GBC
  - MBC1 multicarts
  - Other hardware bugs tested in blargg's test suite
- GBA
  - Timing: prefetch occupancy-model rewrite (scoped, see `docs/prefetch-model-rewrite.md`)
  - Storage: Game database for odd cases (Classic NES, ROMs that misreport things)
  - Sensor cartridges (tilt, gyro, solar, rumble)
- Cheats
- Save state slots
- Debugger with breakpoints and stepping

## Special Thanks

A special thanks goes out to those in the emudev community who are always helpful, both with insightful feedback and targeted test ROMs.

- https://github.com/ladystarbreeze
- https://github.com/DenSinH
- https://github.com/fleroviux
- https://github.com/destoer
- https://github.com/GhostRain0

## Contributors

- [Matthew Beck](https://github.com/mattrbeck) - creator and maintainer
