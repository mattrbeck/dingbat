# Features

The full feature list for both front-ends and both emulated systems. The
[README](../README.md) covers only the highlights.

## Web front-end

The browser build at [dingbat.gg](https://dingbat.gg) is the default way to play.

- Installable as an offline-capable PWA, with a home screen library grid
- Touch controls, with layouts for phones and tablets in both orientations
- Gamepad support
- Save states: nine per-ROM slots with thumbnails, plus Quick Save / Quick Load
- Auto-save on exit with a "Resume last session" offer, and Undo for both state
  loads and Reset
- Rewind, fast forward, 2x, slow motion and frame step. Holding the fast-forward
  key restores whatever speed was latched before it, rather than dropping to 1x
- Rewind scrubber: a film-strip modal (menu, or double-tap the rewind button) for
  travelling further back than a hold. Committing discards the future, says so,
  warns separately when it would also roll back an in-game save, and offers Undo
- Run-ahead (opt-in, 1-2 frames) to cut input latency, disabled automatically
  while linked
- "Clip that!": retroactive clip capture over the last minute of play, replayed
  deterministically from state anchors plus a per-frame input log rather than
  recorded video. Opens the same film-strip scrubber the rewind modal uses, with
  an in and an out point, pre-set to the last 10 seconds
- Cheats (Game Genie, GameShark, Action Replay / CodeBreaker)
- Per-ROM save files kept in IndexedDB, with a "Manage ROMs and Saves" modal for
  resetting save data or deleting a game outright
- Online link play with room codes
- Google Drive cross-device sync, with Sign in offered from the home screen — see below
- Report a Bug: attach a save state from any point in the rewind timeline, downloaded
  as a self-contained report file. Nothing is transmitted.
- Desktop keyboard shortcuts: pause, fast forward, rewind, save states, screenshot,
  fullscreen, mute
- MBC5 rumble — gamepad vibration where supported, screen shake everywhere
- Sensor carts: MBC7 and GBA tilt and the WarioWare Twisted gyro, driven by the
  device's motion sensor, a gamepad stick, or the D-pad. Motion is expressed in
  screen space and re-baselined when the device rotates, so landscape play and
  recentring behave the same as portrait
- Game Boy Camera: uses a real webcam, with front/back switching where more than
  one camera exists. When no camera is available the emulated viewfinder says why
  (blocked by the browser, none present, not yet enabled) instead of showing the
  cart's synthetic test pattern
- Game Boy Printer: always connected, with hardware-matched print timing. Finished
  prints land in a Printed Photos gallery and save as PNGs
- Toasts stack rather than replacing one another, wrap on narrow screens, and are
  individually dismissible
- Tabbed settings panel: key rebinding, GB renderer choice, GBA BIOS/HLE modes, color
  correction, integer scaling, scanlines, LCD response (panel ghosting), and an
  ambient glow backdrop
- Per-panel color correction: mGBA's AGB model for GBA, the hardware-measured
  "GBC-Color" model for GB/GBC
- Game Boy shade palette: keep the hardware shades, derive a palette from the app
  theme, or pick all four colours yourself. Applied in the presenter's shader, so
  it cannot touch emulation, save states or netplay determinism, and colour (GBC)
  titles are unaffected

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
- A refused save state says why (wrong ROM, written by a newer build, corrupt)
  rather than failing silently
- LCD color correction, per panel: AGB and GBC models
- Scanlines, LCD response (a per-pixel panel-ghosting model, selectable per panel:
  DMG / CGB / AGB-001 / AGS-101), and hq4x / xBR upscaling
- MBC5 rumble (controller rumble + screen shake)
- Link cable window for network play
- Debug windows for the PPU, IO registers, and scheduler

## Game Boy / Game Boy Color

- Accurate sound emulation, through an output-stage DC blocker modelling the
  coupling capacitor between the mixer and the jack. Without it the mix carries a
  large DC offset that steps whenever a channel is switched on or off, and every
  one of those steps is an audible click
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
  The renderer's rules and their derivations are documented at the constants in
  `src/dingbat/gb/gb.nim` and `fifo_ppu.nim`.
- Save files are compatible with other emulators like BGB
- Cartridge mappers — every mapper the library uses:
  - MBC1, including MBC1M multicarts
  - MBC2, fully supported
  - MBC3, fully supported, including the real-time clock
  - MBC5, including the rumble motor
  - MBC6, MBC7 (tilt sensor and EEPROM), MMM01, HuC1, HuC3, TAMA5
  - Pocket Camera, wired to a real webcam in the browser
- Serial port and link cable — two cores in one process, and online in the browser via
  input-rollback netplay
- Game Boy Color support, including HDMA, double-speed mode, and palettes
- Game Boy Printer, with hardware-matched print timing

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
  - [jsmolka/gba-tests](https://github.com/jsmolka/gba-tests) — all 13 ROMs
    (ARM, THUMB, memory mirrors, BIOS reads, SRAM/Flash, the `unsafe` pair,
    and the four render-only ROMs)
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
- Sensor cartridges: the tilt sensor (Yoshi's Universal Gravitation, Koro Koro
  Puzzle) and the WarioWare Twisted gyro
- Save states
- Browser / WebAssembly build

## Test results

Regenerated by CI on every run and published as build artifacts.

| Suite | Result |
|---|---|
| mGBA test suite | 6910 / 7008 |
| jsmolka gba-tests | 13 / 13 |
| Combined suite (`tests/results.md`) | 150 / 182 |

The remaining mGBA failures cluster in timing (46), timer count-up (43), and misc. edge
cases (9). Per-area analyses live in `research_timer_irq.md`,
`research_sram_unaligned.md`, `research_dma_bios_rom.md`, `research_sio_timing.md`, and
`research_failing_rows_breakdown.md`. Mealybug Tearoom rows are scored as
percent-of-pixels-matching rather than pass/fail.

## Remaining work

**Web front-end**

- Audio dropouts under main-thread hitches: diagnosed and measured, fix
  deferred because the obvious one costs ~18 ms of added audio latency. See
  [research_web_audio_gaps.md](research_web_audio_gaps.md) — it also records
  that WebKit shows the fault far more readily than Chrome, so audio pacing
  should be measured there.

**Game Boy / Game Boy Color**

- Other hardware bugs tested in blargg's test suite

**Game Boy Advance**

- Timing: prefetch occupancy-model rewrite (scoped, see [prefetch-model-rewrite.md](prefetch-model-rewrite.md))
- Storage: game database for odd cases (Classic NES, ROMs that misreport their save type)
- Solar sensor (Boktai)

**Tooling**

- Debugger with breakpoints and stepping
