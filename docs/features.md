# Features

The full feature list for both front-ends and both emulated systems.

## Web front-end ([dingbat.gg](https://dingbat.gg))

- Installable offline-capable PWA with a home-screen library grid
- Touch controls (phone and tablet layouts, both orientations); gamepad support
- Save states: nine per-ROM slots with thumbnails, Quick Save / Quick Load, auto-save on
  exit with "Resume last session", Undo for state loads and Reset
- Rewind, fast forward, 2x, slow motion, frame step; a film-strip rewind scrubber
  (menu, or double-tap the rewind button) that warns before rolling back an in-game save
- Run-ahead (opt-in, 1–2 frames); disabled while linked
- "Clip that!": retroactive capture of the last minute of play, replayed deterministically
  from state anchors plus the input log, trimmed in the same film-strip scrubber
- Cheats: Game Genie, GameShark, Action Replay / CodeBreaker
- Per-ROM saves in IndexedDB; "Manage ROMs and Saves" resets or deletes a game
- Online link play with room codes; local 2P on one machine
- Google Drive cross-device sync (below)
- Report a Bug: a self-contained report file with a save state from any point in the
  rewind timeline. Nothing is transmitted.
- Keyboard shortcuts: pause, fast forward, rewind, save states, screenshot, fullscreen, mute
- MBC5 rumble (gamepad vibration where supported, screen shake everywhere)
- Sensor carts: MBC7 and GBA tilt, WarioWare Twisted gyro — from the device's motion
  sensor, a gamepad stick, or the D-pad; re-baselined when the device rotates
- Game Boy Camera from a real webcam (front/back switching); the viewfinder says why when
  no camera is available
- Game Boy Printer, always connected; prints land in a gallery and save as PNGs
- Settings: key rebinding, GB renderer, GBA BIOS/HLE, color correction, integer scaling,
  filters (scanlines, hq4x, xBR), LCD response (panel ghosting), ambient glow
- Per-panel color correction (AGB / GBC models); Game Boy shade palette from the
  hardware shades, the app theme, or four colours of your own (shader-only, so emulation
  and netplay are unaffected)

### Google Drive sync

Signing in turns sync on; signed out, none of it runs.

- One "library" file on Drive holds the merged recents plus tombstones. ROMs are never
  bulk-downloaded: a game held only on another device fetches on tap.
- Saves, states and ROMs upload from a persisted dirty queue (2 s after the last change,
  at most 10 s after the first); unchanged files are skipped.
- Pulls on sign-in, app start, refocus, regained connectivity, a 3-minute poll, and
  "Sync now".
- Deleting a game writes a tombstone; other devices ask before dropping it (Continue /
  Restore).

Scope is `drive.appdata` (dingbat sees only its own hidden app folder). The OAuth client
ID ships in source (GIS implicit flow, no secret; gated by the Authorized JavaScript
origins allowlist — https required off localhost, raw IPs rejected).
`gdrive_client_id` in `localStorage` overrides it.

## Native front-end

- Open ROMs; select a BIOS file; rebind keys; controller support
- Save states (nine slots with thumbnails, Quick Save / Quick Load); a refused state says
  why (wrong ROM, newer build, corrupt)
- Cheats; rewind; fast forward and 2x (pitch-preserving WSOLA, opt-in); pause and frame
  advance; screenshots; volume and per-channel audio
- LCD color correction per panel; scanlines; LCD response (DMG / CGB / AGB-001 / AGS-101
  ghosting models); hq4x / xBR upscaling
- MBC5 rumble (controller rumble + screen shake)
- Link Cable window for network play
- Debug windows: PPU, IO registers, scheduler

## Game Boy / Game Boy Color

- Sound with an output-stage DC blocker (the coupling capacitor between mixer and jack)
- Two PPU implementations: cycle-accurate FIFO (default) and a faster scanline renderer
  — see [fifo_ppu_changes.md](fifo_ppu_changes.md)
- Mappers: MBC1 (incl. MBC1M multicarts), MBC2, MBC3 with RTC, MBC5 with rumble, MBC6,
  MBC7 (tilt + EEPROM), MMM01, HuC1, HuC3, TAMA5, Pocket Camera
- CGB: HDMA, double speed, palettes; SGB border/palette packets
- Serial port and link cable: two cores in one process, or online via input-rollback
  netplay; Game Boy Printer
- Passes blargg, mooneye, mealybug, SameSuite, GBMicrotest, dmg-acid2 and cgb-acid2;
  per-suite tallies in [tests/results.md](../tests/results.md)

## Game Boy Advance

- Direct Sound and PSG audio; optional "Improve audio quality" mode re-renders MP2K/M4A
  music per note above the FIFO's mix rate
- HLE BIOS — gaps in [hle-bios-shortcomings.md](hle-bios-shortcomings.md)
- PPU modes 0–5, affine backgrounds and sprites, alpha blending, windowing, mosaic
- CPU passes armwrestler, FuzzARM and all 13 jsmolka/gba-tests ROMs
- Cycle-counted bus with waitstates and prefetch; DMA priority and preemption; timers on
  the scheduler; idle-loop detection; passes the AGS aging cartridge
- Flash, SRAM, EEPROM; RTC; GPIO rumble; tilt (Yoshi's Universal Gravitation, Koro Koro
  Puzzle) and the WarioWare Twisted gyro
- Link cable locally and online; save states; browser build

## Test results

Regenerated by CI on every run: [tests/results.md](../tests/results.md) (all suites),
[tests/results_mgba_suite.md](../tests/results_mgba_suite.md) and
[tests/results_gambatte.md](../tests/results_gambatte.md) (per-row detail). Mealybug rows
are scored as percent of pixels matching; open GB rows are triaged in
[gb-failure-triage.md](gb-failure-triage.md).

## Remaining work

- Web audio dropouts under main-thread hitches — diagnosed, fix deferred (~18 ms of added
  latency): [web_audio_pacing.md](web_audio_pacing.md)
- GBA: game database for odd save types (Classic NES, misreported save types); solar
  sensor (Boktai)
- Debugger with breakpoints and stepping
