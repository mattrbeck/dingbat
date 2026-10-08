# The iOS app

`ios/` is a native SwiftUI app around the core (`libdingbat.a`, built from
`src/dingbat_ios.nim`). It follows the web front-end (`web/`): the same
screens, labels, settings and defaults, so a player moving between
dingbat.gg and the app finds the same thing. This page says what the app
has, where it differs from the web, and what it leaves off.

Build: `ios/build-core.sh` and `ios/build-webrtc.sh` (both slices; the
second fetches libdatachannel and mbedTLS at pinned tags into `ios/deps`
and needs CMake and Ninja), then `cd ios && xcodegen generate` and build
the `Dingbat` scheme. The presenter's Metal shader is compiled at launch
(`PresentShader.swift`), so the build needs no Metal toolchain. The C API
is tested on the desktop by `tests/ios_api_test.nim` (`nimble
test_iosapi`, in CI on Linux).

Tests against the real web build, on a headless simulator (both muted):
`node ios/e2e/drive-sync.mjs <Dingbat.app>` (one Drive library across the
app and a browser, through a fake Drive) and `node ios/e2e/link.mjs
<Dingbat.app>` (an online link between the app and Chromium through a local
signaling server; both must hold byte-identical states for both players at
the same frame). `ios/e2e/trade.mjs` plays a whole Pokémon trade, FireRed
in Chromium against LeafGreen in the app from save states at the Cable Club
counter, over a relay that delays, jitters and drops the WebRTC packets
(`ios/e2e/netem.mjs`, no root needed); it needs the real games, so it is
not in CI (usage in the file).

## What matches the web

| Web | iOS |
|---|---|
| Home: brand, hero (paused / closed, Resume · Play · Close · ⋯), library grid with pictures and cartridge labels, search / system chips / sort from 9 games, tile menu (Rename, Reset save data, Delete), Add a game (a ROM or a .zip with box art) | `HomeView`, `HeroView`, `LibraryGrid`, `Cartridge`, `TileMenu` |
| Sessions: the `stateauto` snapshot on leaving a game and every minute of play, valid only while the save it carries is the stored one; "Opening a game from the library" (Resume / From save) and the "Last session saved … Resume" offer | `GameSession.persistSession`, `RomLibrary.resumableSession`, `AppModel.launch` |
| In-game top bar: menu, reset (Undo), rewind (hold; double tap opens the scrubber), pause, frame step while paused, 2x, fast-forward, tilt recenter, camera, fps when unusual / SLEEPING, muted-channels pill, enhanced-music note, volume | `PlayView.swift` (`TopBar`) |
| Phone landscape: see-through pads (Outline / Bold / Solid), chevron d-pad, Select/Start pills inboard, a tap on the picture shows and hides the bar | `PlayLayout`, `TouchControls`, `GameStage` |
| Portrait, tablet rails, Large controls, joystick (fixed / floating), Game Boy games without L/R; controls fixed-size, the picture yields | `PlayLayout`, `TouchControls` |
| Menu: Quick Save / Quick Load / Rewind to a Moment / Slow Motion, Main Menu, Save States, Manage Saves, Capture (Screenshot, Record, Clip that!, Printed Photos), Link Cable, Cheats, Settings, Report a Bug | `GameMenu` and the sheets |
| Local 2P (the web's debug rig behind `?2p`; here the `-2p` launch argument shows each tile's 2P): two cores of one game on the emulated cable, both screens at once; touch drives the screen tapped last, a controller player 2; player 1's battery is the game's save, player 2's its own (`save:<name>-p2`, a copy of player 1's the first time); rewind, states, cheats, speed and capture stand down | `TwoPlayer`, `dingbat_link_*` |
| Add pictures: every game with no picture booted in the core without becoming the loaded game (its session put back, or its boot run toward a title, bounded), the screen kept as its library picture; offered once, then from the library head while any game lacks one; signed in, Drive-only games too, fetched and not kept | `AddPictures` |
| Crash recovery: the session taken every minute of play, kept as checkpoints too (nine, spread over play time, the ones from before a crash frozen); runs that end unseen counted per game, and after two in a row a tap on the game opens "… stopped unexpectedly" (Resume an earlier moment, or Start from in-game save); the tile menu's Resume from earlier. A moment from before the last in-game save takes its battery back, the newer save kept for Restore old save | `Checkpoints`, `CrashWatch`, `MomentsView` |
| Google Drive: sign in through the browser (the web's broker flow), one library with dingbat.gg (saves, states, sessions, pictures, the library file, renames, deletions with the "removed on another device" sheet), Drive-only tiles that download on tap, hand-off between devices, kept saves, the sync indicator and Sync now | `DriveAuth`, `DriveClient`, `DriveSync`, `DriveViews` |
| Record and "Clip that!": the last minute replayed frame-exact from the clip ring into an MP4 (H.264 at 4x, AAC), with the "Save a Clip" range picker and progress; Record captures play as it happens. The file goes to the share sheet | `ClipExporter`, `ClipViews`, `dingbat_clip_*` |
| Link Cable online: the same code on both sides pairs through the web's signaling server, then a WebRTC data channel carries the web's input-rollback protocol, so an iPhone links with a browser or another iPhone. Cross-game trades send each side's ROM first; pause and 2x drive both sides; Disconnect (two taps, menu or the bar's pill); idle auto-disconnect; the game plays on when the friend leaves. With no server (or by choice) the manual code exchange: Share code / Copy code, the friend's code, Confirm; codes re-minted while unshared, the fallback when the server does not answer | `NetLink`, `RTCPeer` (libdatachannel), `LinkSignaling`, `SDPCodec` (the web's byte format), `LinkCableView`, `dingbat_rollback_*` |
| Save States (9 slots, slot 1 is Quick, thumbnails), Manage Saves (export / import .sav incl. SharkPort and GameShark SP, reset; export / import .state), the rewind scrubber with its staged commit and Undo, Cheats, Printed Photos, Report a Bug (JSON with a state from any moment) | `SaveStatesView`, `ManageSavesView` + `SaveImport`, `RewindScrubberView`, `CheatsView`, `PrintsView`, `ReportBugView` |
| Settings, all six sections with the web's rows, keys and defaults, the eleven app themes | `SettingsView`, `Settings`, `Theme` |
| Presenter: colour correction per panel, None / LCD grid / RGB subpixels / hq4x / xBR, Game Boy shade palettes, the Super Game Boy border, integer scaling, LCD response, ambient glow, pinch zoom | `PresentShader` (the web shader in Metal), `GameRenderer`, `GameStage` |
| Speeds and audio: 2x, unbounded fast-forward, slow motion, rewind, run-ahead, pitch-correct fast-forward, enhanced music, audio interpolation, the 12 kHz analog filter, channel mutes, Play in Silent Mode | `GameSession`, `AudioOutput`, `dingbat_ios_audio.c` |
| Controllers (web mapping; RT holds fast-forward, LT rewind, R3 or Select+Start held opens the menu paused; hide touch controls), rumble, tilt carts, the Game Boy Camera, the Game Boy Printer, the save webhook | `Controllers`, `Peripherals`, `GameSession` |
| A controller alone, outside the game: the d-pad and stick move focus spatially over the home screen, the in-game menu and every sheet, A presses, B goes back (a Settings section, then the sheet or menu; at home, the top), Y opens a game's options, LB/RB step the system filter, LT/RT the sort, Start resumes the hero's game; buttons held across a switch are not presses on arrival. No bar icon, toasts or readouts, as on the web | `PadNav` (iOS has no controller focus engine outside tvOS), `Controllers` |
| A hardware keyboard: the ten bindings with the Default and Home-row presets (Settings › Controls › Keyboard, shown while one is connected: tap a key, press its replacement), the web's shortcuts (Space, Tab, Shift+Tab, \`, Shift+\`, ., M, I, F5, F8, F9) and Escape for the menu; outside the game the arrows, Return and Escape drive the UI as the pad does | `Keyboard` (GCKeyboard; bindings in the web's SDL keycodes) |

## Native differences

- **Haptics.** A light tick on every touch-control press (Settings ›
  Controls › Haptic feedback, on by default); rumble drives Core Haptics on
  the phone and controller. The web can only vibrate on Android.
- **Files.** ROMs, saves and states are plain files in the app's Documents
  folder, visible in the Files app (layout in `RomLibrary.swift`). Exports
  go through the share sheet. There is no storage budget or eviction.
- **Tilt** starts when a tilt cart loads (Core Motion needs no permission);
  the web asks first. A flick rides on top of the tilt as on the web (the
  jolt channel, from Core Motion's user acceleration).
- **A state from a newer dingbat** says to update the app; the web
  downloads its newer build and offers the load again.
- **Pausing** for the background, the app switcher or a call takes the
  session and flushes the save, as the web does on a hidden tab.
- **Sign-in** opens Google's consent page in the system browser sheet;
  the web's `oauth-callback.html` hands an app sign-in on to
  `dingbat://oauth`, so that page must be deployed for the app to sign in.
- **Pacing.** Frames follow the display clock, as the web's follow
  requestAnimationFrame; on a 60 Hz screen the game runs at exactly 60
  frames a second (0.46% above the hardware's 59.73) so every refresh shows
  one new frame, and the audio reader resamples by a hair (at most 1.5%) to
  hold its buffer at ~25 ms (~55 ms in slow motion) instead of running dry.
  The web steps at 59.73 and drops a frame every few seconds. Measured in
  the simulator (`-latency-test 40` on tonc's m7_demo): press to the changed
  frame presented, p50 12.9 / max 15.1 ms; audio ring ~27 ms on top of a
  ~5 ms output buffer. Audio depth does not delay input or video.
- **A controller in menus** steps a pick-list to its next option with A
  (a native menu cannot be opened from a pad), and skips text fields
  (search, codes) and the paused hero's ⋯ menu; Y on a tile and the touch
  screen reach those.
- **"Open in dingbat"** from Files or another app takes ROMs, zips, saves
  (.sav .srm .sps .xps .gsv) and .state files; a save or state goes into
  the running game through Manage Saves (the web's drag and drop).
- **The build** in Settings is the commit a build phase stamps into
  Info.plist (the web reads version.txt).
- **Picture flights** follow the web's (460 ms, the same curve; a picture
  that is not the frame about to show darkens and the screen powers on).
  A game frame flies at its own shape on black, so a Game Boy picture in a
  3:2 tile grows into its 10:9 screen instead of stretching. Reduce Motion
  turns them off.
- **The opening.** The launch screen is the logo on the home screen's
  colour; the app's first frame is an exact copy of it, and the bat then
  flies up to its place above the library, flapping one full beat and a
  smaller settling one (the logo-flap strip, 24 fps), as the colour lifts
  and the page rises in under it. The web has no launch screen. Reduce
  Motion skips it; so do scripted launches (`-autoplay`, `-sheet`, ...).
- **Export…** writes the file into the app's Exports folder (Files ›
  dingbat › Exports) where the web downloads it; Share… on the done screen
  sends it on. The rows, files, names, zip and info.json are the web's,
  byte for byte (`node ios/e2e/export-core.mjs` checks the zip writer,
  camera photos, info.json and adding an export back as a game against the
  web's own functions).
- **Small layout choices.** The paused hero's ⋯ is a native menu; the tile
  menu is a sheet on iPad too; in a game the toasts sit under the top bar,
  clear of the controls.

## Nintendo DS (core and C API)

`libdingbat.a` carries the DS core (`src/dingbat/nds/`) behind
the same C API as the GB/GBA cores, mirroring the web's DS front end
(`src/dingbat_nds_wasm.nim`, index.js "Nintendo DS", docs/nds/web.md).
`ios/include/dingbat.h` is the contract; in short:

| | |
|---|---|
| Loading | `dingbat_load_rom` / `_bytes` take a `.nds` (or any file whose header passes the DS checks) and boot the DS core; a GB/GBA load drops it and the reverse. `dingbat_is_nds`. The battery is `<rom minus extension>.sav`, fitted to the card's chip by the DS rules (docs/nds/saves.md) and written back exact. |
| BIOS, firmware | `dingbat_set_nds_bios(bios9, bios7, firmware)`: dump paths or NULL for the HLE BIOS / synthesized firmware, read at the next DS load (a reset keeps the BIOS the game started with). |
| Firmware flash | `dingbat_set_nds_flash_path`: one file per device, as the web's `bios:ndsflash` record: written on flush when a game wrote the flash, booted only on the firmware it was written on (a dump: whole; built-in: the user area over this build's synthesized image). |
| Picture | One 256x384 BGR555 buffer, top screen over bottom (`dingbat_game_fb`, `fb_width/height` 256x384), no colour correction or LCD response (the DS's panels); `dingbat_nds_top_rgba` for the library picture; the glow samples the composite. |
| Input | ids 10 X, 11 Y; `dingbat_nds_touch` (bottom-screen pixels), `dingbat_nds_set_lid` (each boot open; a state load keeps the app's lid), `dingbat_nds_push_mic`. |
| Sound | The SPU's stereo into the same ring at 32728 Hz (`dingbat_audio_sample_rate` moves with the core: re-read it after a load). The pacing contract (`dingbat_audio_ahead`) is the GB APU's in frames; a sleeping or switched-off DS queues a frame of silence a frame, so pacing holds. Volume, mute, 2x (decimated or WSOLA), slow motion and fast-forward work; channel mutes do not apply. |
| States | `dingbat_state_size/data`, `dingbat_load_state` in the DS format (thumbnail 128x192, both screens); error kind 8 = incompatible (another DS layout or BIOS). None of a switched-off console. |
| Power | `dingbat_nds_powered_off`; `dingbat_reset` reboots in place (same ROM and BIOS, the flash kept) and switches it back on, as the web's Restart. |
| Not on the DS | Rewind and its scrubber, clips, run-ahead (a plain frame), cheats, link (refused before anything is touched), SGB, tilt, camera, printer, rumble, MP2K: no-ops, zeros or refusals that never reach the last GB/GBA game. |

Tests: `tests/ios_api_test.nim` drives all of it on the homebrew DS test
ROMs (`~/.cache/dingbat-nds/roms`, skipped where absent, so not in CI):
both screens, the stylus, X/Y, the lid, the battery coming back, the flash
kept across a reset and a reload and kept apart on another firmware,
power-off, states, the ring's rate and 2x, DS to GBA to DS, the real BIOS
when dumped, and the frame time of SoulSilver when it is at hand.

Performance (this Mac, M-series, -d:release as the iOS build, HLE BIOS,
measured on a busy machine): Pokemon SoulSilver's intro, frames 600-1500,
0.86-0.96 ms a frame (~1100 fps) in the Mac test when it ran unhindered,
2.1-2.4 ms (420-475 fps) when the machine was loaded, and 2.4 ms in the
simulator slice of `libdingbat.a` driven through the C API from a small C
program (`simctl spawn`), which also checked the picture and the ring's
32728 Hz there. No device measurement yet. The DS core adds ~2.8 MB to
each slice (2.07 MB to 4.86 MB).

## Nintendo DS in the app

The Swift side plays DS games as the web app does (docs/nds/web.md is the
reference; this follows it piece by piece). Everything is gated on the
running game being a DS game (`GameSession.isNDS`, the web's
body.nds-mode): Game Boy and GBA games keep every layout, control and
menu exactly as before.

| Web | iOS |
|---|---|
| `.nds` in the file picker, a `.zip`, the library; the header check (`NdsUtil.looksLikeNdsRom`) | `RomLibrary.romExtensions`, the `com.mattrb.dingbat.nds` imported type (project.yml / Info.plist, Open in), `ZipReader`, `NdsUtil.looksLikeNdsRom` (Swift port) |
| System "DS": its chip, filter and sort (after GB), the small grey card with a corner cut, the library and hero picture = the top screen | `RomEntry.system`/`isNDS`, `Palette.badgeDs*`/`cartDs*`, `CartridgeView` / `CartShape(ds:)`, `GameSession.currentImage` (`dingbat_nds_top_rgba`; the state-slot thumbnails too) |
| BIOS / firmware dumps optional (HLE + synthesized firmware), the console's flash one per device | Settings › Nintendo DS (ARM9 BIOS 4 KB, ARM7 BIOS 16 KB, firmware 128/256/512 KB, sizes checked), stored beside the GBA BIOS; `NdsState.prepareLoad` sets them and the flash (`Application Support/dingbat/bios/nds_flash.bin`) before each DS load |
| DS games stay local (`driveExcluded`, `driveLibraryOf`); "this device only" in the game's menu; the once-a-session toast | `driveExcluded` / `DriveLibrary.forDrive` in `DriveSync` (uploads, deletes, full sync, the library file), `TileMenu`, `AppModel.launch` |
| The screens: `NdsUtil.layout/compose/views` (Automatic, Stacked, Side by side, Focus, One screen; swap; gap none / hinge 8 / console 90; turn upright / book left / book right), integer scaling, the filters and looks; no colour correction, palette, LCD response or glow | `NdsUtil.swift` (the math line for line), `GameStage.ndsLayout`, `GameRenderer.drawNds` + `nds_vertex` in `PresentShader` (each screen a quad of the 256x384 texture, turned, its own texels and grid / subpixel pitch, the gaps in the stage's colour) |
| The stylus: a touch that starts on the bottom screen, clamped while it drags, lifted with the finger, one at a time; in Focus / One screen a tap on the top screen (< 500 ms, < 12 px) swaps | `NdsStylus` / `NdsStylusView` over the picture (`NdsUtil.touchPoint`, `screenAt`); touches elsewhere fall through to the stage and the touch controls keep theirs |
| X/Y: the diamond (X top, Y left, A right, B bottom, 0.75 of a button from the centre); controller X/Y by label; keys X = D, Y = C (home row I, U), only while a DS game runs; V / B / O / N / H | `PlayGeometry.placeDiamond`, `Controllers`, `Keyboard` (12 bindings; a saved 10-key profile gains them), Settings › Controls › Keyboard |
| Phone held upright (docs/nds/web.md "Phone held upright"): the bar folded off the top ("Hide the top bar", on), a tap on the picture away from the touch screen brings it down over the top screen; the top screen up to the notch / Dynamic Island (safe top less 14, or 11 at 54 and over); L/R 120x28 at the strip's corners (hit 6 above and below); Select/Start 28 pt circles labelled underneath, between the d-pad and B (hit 8 past and on the label); the clusters' row the d-pad's height on max(10, safe bottom - 12); room left over below the screens | `PlayGeometry.ndsPortrait`, `PlayLayout.barLayer` (the fold), `GameStage.toggleBar` + `NdsState.tapTaken`, `CirclePillKey`, `ShoulderKey(short:)`. The status bar is hidden in play (as for every game), the island / notch keeps the same offset |
| Phone held sideways: Select/Start the same circles under R (18 below it, 22 apart); the screens fit between the d-pad and the face buttons (`ndsAvail`), full height | `PlayGeometry.phoneLandscape` (`ndsMaxWidth`) |
| Tablets: the GBA layout plus X/Y | `PlayGeometry.portrait` / `tabletLandscape` with the diamond |
| The Screens panel (screens button in the bar, beside the swap button): arrangement, gap, turn, Swap, Close the lid, Microphone, Blow (held), Hide the top bar; it does not pause | `NdsBarButtons`, `NdsPanel` (an overlay under the bar, a tap outside closes it), Settings › Nintendo DS for the same choices (UserDefaults `nds-layout`, `nds-display` as the web's records; Reset all settings clears both) |
| The lid: dims the screens, "Lid closed · tap to open", every boot open, a state load keeps the app's lid | `NdsState.setLid`, `NdsStageLayers` |
| Blow: one frame of ~60% white noise at 16 kHz before each frame while held; the microphone: asked for only when turned on, pushed at its own rate, nothing while paused or blowing, never stored | `NdsState.blowFrame`, `NdsMic` (an `AVAudioEngine` input tap; the session is play-and-record while it listens; `NSMicrophoneUsageDescription`) |
| Sound at 32728 Hz; pacing by the display clock as for GB/GBA (the reader's rate control absorbs 59.83 vs 60) | `AudioOutput.syncRate` rebuilds the source node when a load changes `dingbat_audio_sample_rate()`; `GameSession.framesOwed` |
| Save states, slots, sessions / Resume, checkpoints, Quick Save/Load; error kind 8's wording | the same paths (`dingbat_state_*`); `GameSession.rejectCopy` |
| Power-off: "The game turned the DS off" with Restart and Library; the battery stored, the resume snapshot deleted, no picture of the black screens, no state of an off console | `NdsState.syncPower`, `GameSession.ndsPoweredOff` / `ndsRestart`, `NdsStageLayers` |
| Gated off: rewind (button, scrubber, Rewind to a Moment, Report a Bug's timeline), Clip that! and Record, Link Cable and 2P, Cheats, run-ahead, the batch of library pictures, tilt / camera / printer / rumble / SGB / enhanced-music UI (their calls are 0 for a DS game) | `PlaybackCluster`, `GameMenu`, `ReportBugView`, `LibraryGrid` (2P), `AddPictures`, `GameSession.setRewinding` / run-ahead |
| Save import: `.sav` / `.dsv` stored whole (no GBA container sniffing) | `ManageSavesView.importSave`, `.dsv` in the save type and Open in |

Dev hooks (DEBUG, `DingbatApp.autoplay`): `-nds-layout auto|stack|side|focus|single`,
`-nds-swap`, `-nds-gap none|hinge|console`, `-nds-rot 0|1|3`, `-topbar-open`
(the folded bar brought down), `-nds-panel`, `-nds-lid`, and `-nds-touch
X,Y[,seconds]` with `-nds-touch-after S`: the stylus on the bottom
screen's pixel (X, Y), aimed by `NdsUtil.clientPoint` through the current
layout and sent through the same mapping a finger takes (logged to
tmp/ndstouch.txt).

Checked on headless simulators (iPhone 17, iPhone 17 Pro Max, iOS 26.2),
muted: SoulSilver from a save state upright (bar folded and brought down),
sideways, in Focus, and on the Pro Max; Golden Sun: Dark Dawn to its title
upright and sideways; the library with a DS tile and a DS card; a homebrew
touch test with the stylus self-test; Kirby (GBA) upright, unchanged from
main. SoulSilver ran at 60 fps paced in the simulator; Golden Sun's 3D
intro ran at 38-46 fps there on a heavily loaded Mac (load average 400-700
from other jobs), then 60 at its title and name entry: judge speed on a
device.

Left off on the DS: the firmware's Console settings editor (name,
birthday, language: the web's Settings rows; the flash a game writes is
kept, only the editor is missing), the input display's X/Y, and Drive sync
of DS saves (as on the web). Not verified on a device: touch routing and
the stylus feel, the microphone's audio session, the folded bar's tap, and
performance.

## Left off, and why

- **The link's same-browser BroadcastChannel path** (two tabs of one
  browser): there is no second tab in an app.
- **Web-only plumbing**: the service worker's update button and Force
  update, Fullscreen, the diagnostic log, drag and drop (Open in stands
  in for it).

## Not verified on a device

Everything above was built for the simulator and the device and checked in
headless simulator screenshots; the C API is covered by
`tests/ios_api_test.nim`, Drive and the link by the `ios/e2e` tests
against the web build. Taps could not be driven there, so these need a
pass on a real iPhone and iPad: touch routing, every sheet's buttons,
import/export through the share sheet and Files, the rewind scrubber's
commit, controllers, rumble, tilt, the camera, audio (Play in Silent Mode,
interruptions) and performance; real Google sign-in (needs the deployed
callback page); and an online link across two networks (the tests pair on
one machine, so NAT traversal over STUN is unproven from the app).
