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
the same frame).

## What matches the web

| Web | iOS |
|---|---|
| Home: brand, hero (paused / closed, Resume · Play · Close · ⋯), library grid with pictures and cartridge labels, search / system chips / sort from 9 games, tile menu (Rename, Reset save data, Delete), Add a game (a ROM or a .zip with box art) | `HomeView`, `HeroView`, `LibraryGrid`, `Cartridge`, `TileMenu` |
| Sessions: the `stateauto` snapshot on leaving a game and every minute of play, valid only while the save it carries is the stored one; "Opening a game from the library" (Resume / From save) and the "Last session saved … Resume" offer | `GameSession.persistSession`, `RomLibrary.resumableSession`, `AppModel.launch` |
| In-game top bar: menu, reset (Undo), rewind (hold; double tap opens the scrubber), pause, frame step while paused, 2x, fast-forward, tilt recenter, camera, fps when unusual / SLEEPING, muted-channels pill, enhanced-music note, volume | `PlayView.swift` (`TopBar`) |
| Phone landscape: see-through pads (Outline / Bold / Solid), chevron d-pad, Select/Start pills inboard, a tap on the picture shows and hides the bar | `PlayLayout`, `TouchControls`, `GameStage` |
| Portrait, tablet rails, Large controls, joystick (fixed / floating), Game Boy games without L/R; controls fixed-size, the picture yields | `PlayLayout`, `TouchControls` |
| Menu: Quick Save / Quick Load / Rewind to a Moment / Slow Motion, Main Menu, Save States, Manage Saves, Capture (Screenshot, Record, Clip that!, Printed Photos), Link Cable, Cheats, Settings, Report a Bug | `GameMenu` and the sheets |
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
  the web asks first. The web's flick (jolt) channel is not ported.
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
- **Small layout choices.** The paused hero's ⋯ is a native menu; the tile
  menu is a sheet on iPad too; in a game the toasts sit under the top bar,
  clear of the controls.

## Left off, and why

- **The link's same-browser BroadcastChannel path** (two tabs of one
  browser): there is no second tab in an app. **Local 2P** (two games on
  one screen, the 2P tile) is not ported either.
- **"Add pictures"** (picturing every game in one batch).
- **Web-only plumbing**: the service worker's update button and Force
  update, Fullscreen, the diagnostic log, drag and drop, the "File Check
  Failed" header warning, picture flights between the hero and the game.

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
