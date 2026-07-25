# Features

The full feature list for both front-ends and both emulated systems. The
[README](../README.md) covers only the highlights.

## Web front-end

The browser build at [dingbat.gg](https://dingbat.gg) is the default way to play.

- Installable as an offline-capable PWA, with a home screen library grid
- Touch controls, with layouts for phones and tablets in both orientations
- Gamepad support
- Save states: nine per-ROM slots with thumbnails, plus Quick Save / Quick Load
- Rewind and fast forward
- Cheats (Game Genie, GameShark, Action Replay / CodeBreaker)
- Per-ROM save files kept in IndexedDB, with a "Manage ROMs and Saves" modal for
  resetting save data or deleting a game outright
- Online link play with room codes
- Google Drive cross-device sync — see below
- Report a Bug: attach a save state from any point in the rewind timeline, downloaded
  as a self-contained report file. Nothing is transmitted.
- Desktop keyboard shortcuts: pause, fast forward, rewind, save states, screenshot,
  fullscreen, mute
- MBC5 rumble — gamepad vibration where supported, screen shake everywhere
- Tabbed settings panel: key rebinding, GB renderer choice, GBA BIOS/HLE modes, color
  correction, integer scaling, scanlines, motion blur (interframe blending), and an
  ambient glow backdrop
- Per-panel color correction: mGBA's AGB model for GBA, the hardware-measured
  "GBC-Color" model for GB/GBC

### Google Drive sync

Signing in *is* turning sync on; signed out, none of it runs and the app behaves exactly
as it did before.

- One "library" file on Drive holds the merged recents plus tombstones, so the home grid
  is your library on every device. ROMs are never bulk-downloaded — a game you only have
  on another device shows as a dashed tile and fetches on tap.
- Saves, save states, and ROMs upload from a persisted dirty queue, flushed 2s after the
  last change and at most 10s after the first. Uploads skip files whose signature hasn't
  changed, and a queue that outlives a reload is not lost.
- Pulls happen on sign-in, app start, refocus, regained connectivity, a 3-minute poll,
  and manual "Sync now".
- Deleting a game writes a tombstone so other devices drop it too, but only after asking
  — the "removed on another device" modal offers Continue (drop local) or Restore (keep
  and re-upload, clearing the tombstone).
- The top bar's status indicator reports sync state.

Scope is `drive.appdata`, so dingbat can only see its own hidden app folder — never the
rest of your Drive. The OAuth client ID ships in source, which is safe for the GIS
implicit flow: there is no client secret, and access is gated by the Authorized
JavaScript origins allowlist. Two rules bite when adding an origin for a new deployment
or dev port: https is required off localhost, and Google rejects raw IP addresses, so an
`http://192.168.x.x` LAN origin can never be registered. Setting `gdrive_client_id` in
`localStorage` overrides the shipped ID to point a build at a different client.

## Native front-end

- Open ROMs; select a BIOS file
- Rebind keys; controller support
- Save states: nine per-ROM slots with thumbnails, plus Quick Save / Quick Load
- Cheats (Game Genie, GameShark, Action Replay / CodeBreaker)
- Rewind
- Fast forward and 2x speed (pitch-preserving via WSOLA, opt-in)
- Pause and frame advance
- Screenshots
- Volume and per-channel audio controls
- LCD color correction, per panel: AGB and GBC models
- Scanlines, interframe blending (LCD ghosting), and hq4x / xBR upscaling
- MBC5 rumble (controller rumble + screen shake)
- Link cable window for network play
- Debug windows for the PPU, IO registers, and scheduler

## Game Boy / Game Boy Color

- Accurate sound emulation
- Passing blargg's [cpu_instrs](https://github.com/retrio/gb-test-roms/tree/master/cpu_instrs),
  [instr_timing](https://github.com/retrio/gb-test-roms/tree/master/instr_timing), and
  [mem_timing](https://github.com/retrio/gb-test-roms/tree/master/mem_timing) ROMs
- Passing [blargg's Game Boy Color sound tests](https://github.com/retrio/gb-test-roms/tree/master/cgb_sound)
- Passing [mooneye-gb timer tests](https://github.com/Gekkio/mooneye-gb/tree/master/tests/acceptance/timer)
- Passing dmg-acid2 and cgb-acid2
- PPU draws background, window, and sprites
- Two PPU implementations: a cycle-accurate FIFO renderer (the default) and a faster
  scanline renderer, selectable in settings. The FIFO renderer handles games like
  Prehistorik Man that depend on cycle-accurate PPU behavior.
  See [fifo_ppu_changes.md](fifo_ppu_changes.md) and [fifo_ppu_edge_cases.md](fifo_ppu_edge_cases.md).
- Save files are compatible with other emulators like BGB
- Cartridge mappers:
  - MBC1, including MBC1M multicarts
  - MBC2, fully supported
  - MBC3, fully supported, including the real-time clock
  - MBC5, including the rumble motor
- Serial port and link cable — two cores in one process, and online in the browser via
  input-rollback netplay
- Game Boy Color support, including HDMA, double-speed mode, and palettes

## Game Boy Advance

- Accurate sound emulation, both Direct Sound and PSGs
- Optional "Improve audio quality" mode (experimental): games built on Nintendo's
  standard MP2K/M4A sound engine are detected at runtime and their music is re-rendered
  per note above the FIFO's native mix rate
- HLE BIOS, so no BIOS file is required.
  See [hle-bios-shortcomings.md](hle-bios-shortcomings.md) for the deliberate gaps.
- PPU: modes 0–5, affine backgrounds and sprites, alpha blending, windowing, mosaic
- CPU core, passing:
  - [armwrestler](https://github.com/destoer/armwrestler-gba-fixed)
  - [FuzzARM](https://github.com/DenSinH/FuzzARM)
  - [gba-suite](https://github.com/jsmolka/gba-suite)
- Timing:
  - Cycle-counted bus with waitstates and prefetch
  - DMA channel priority and preemption
  - Passing the AGS aging cartridge
  - Timers run on the scheduler
  - Idle-loop detection to skip busy-waits
- Storage: Flash, SRAM, EEPROM
- Link cable support, both locally and online
- Real-time clock support
- GPIO rumble
- Save states
- Browser / WebAssembly build

## Test results

Regenerated by CI on every run and published as build artifacts.

| Suite | Result |
|---|---|
| mGBA test suite | 6910 / 7008 |
| Combined GB suite (`tests/results.md`) | 137 / 169 |

The remaining mGBA failures cluster in timing (46), timer count-up (43), and misc. edge
cases (9). Per-area analyses live in `research_timer_irq.md`,
`research_sram_unaligned.md`, `research_dma_bios_rom.md`, `research_sio_timing.md`, and
`research_failing_rows_breakdown.md`. Mealybug Tearoom rows are scored as
percent-of-pixels-matching rather than pass/fail.

## Remaining work

**Game Boy / Game Boy Color**

- Other hardware bugs tested in blargg's test suite

**Game Boy Advance**

- Timing: prefetch occupancy-model rewrite (scoped, see [prefetch-model-rewrite.md](prefetch-model-rewrite.md))
- Storage: game database for odd cases (Classic NES, ROMs that misreport their save type)
- Sensor cartridges (tilt, gyro, solar)

**Tooling**

- Debugger with breakpoints and stepping
