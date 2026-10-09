# DS games in the web app

On this branch (not main) the main app (`web/index.html` + `web/index.js`)
plays `.nds` games on the DS core. The standalone dev page (`web/nds.html`)
stays as it was, on the same core build.

## Trying it on a phone or another Mac

    source ~/code/emsdk/emsdk_env.sh     # emcc on PATH
    tools/serve_nds_dev.sh               # builds both cores, serves https://<LAN IP>:8443/

The script builds `web/em.{js,wasm}` (GB/GBA, `src/dingbat_wasm.nim`) and
`web/nds/nds.{js,wasm}` (DS, `src/dingbat_nds_wasm.nim`), makes a
self-signed certificate for the current address of `en0` (`IFACE=` for
another interface; kept in `~/.cache/dingbat-dev-certs`, remade when the
address moves) and runs `web/serve.py --dev --https` on port 8443 (`PORT=`).
`--no-build` serves what is built.

- HTTPS because iOS runs plain-http LAN pages without the JIT, and the DS
  audio needs a secure context (AudioWorklet). Accept the certificate once
  per device (Safari: Show Details, visit this website).
- `--dev` serves every file `no-store`, stamps `em.js`/`em.wasm` with
  `em.wasm`'s mtime and publishes the DS core's stamp (`window.DINGBAT_ASSET_V`,
  which `index.js` adds to `nds/nds.js` and `nds.wasm`), so a page never
  pairs a fresh script with a stale wasm. Its `sw.js` clears every cache and
  unregisters itself: a service worker from an earlier visit cannot serve
  old files. With an untrusted certificate the browser refuses any worker
  (a harmless "Failed to register a ServiceWorker" in the log).
- A home-screen web app keeps what it was installed with: delete and add it
  again after changing the manifest or icons.
- Then: Add a game, pick a `.nds`. A DS game's tile has a DS chip.

`python3 web/serve.py` alone is the old plain server on :8765.

## What works

| | |
|---|---|
| Opening | `.nds` in the file picker, drag and drop, inside a `.zip`, the library (tile, hero, Resume). The header check is GBATEK's: header CRC16 at 15Eh, or the logo CRC CF56h at 15Ch (`NdsUtil.looksLikeNdsRom`); a failed check asks, as for GB/GBA. |
| Core loading | `nds/nds.js` + `nds.wasm` (~16 KB + ~220 KB) are fetched the first time a DS game starts (`loadNdsCore`); GB/GBA sessions never load them. The build is MODULARIZE'd (`createNdsCore`) so it never meets `em.js`'s global `Module`. The service worker caches them on that first fetch (not precached), so DS games play offline after one online start. |
| ROM in memory | `nds_rom_alloc` hands out the ROM's buffer inside the core and the page writes it once; `new_nds`/`new_cart` take it as a `sink`. SoulSilver (128 MB) leaves a 272 MB wasm heap. Reset, a save import and a save reset reboot in place (`nds_reboot`: same ROM, same BIOS) instead of reading the ROM from IndexedDB again. Loading a GB/GBA game drops the DS core (`nds_unload`). |
| Screens | Stacked, side by side, Focus (one large, one small), one screen; swap, gap, a quarter turn for book games; the top bar hides on phones held upright. "Screens" below. Integer scaling and the filters/screen looks apply; colour correction and the GB palette do not (the DS's own LCDs). |
| Stylus | Pointer events on the canvas (mouse, pen, finger): a touch starts only on the bottom screen and then follows the pointer, clamped to its edges, until it lifts (`NdsUtil.touchPoint`: client point to 256x192, exact at any scale, arrangement and turn). |
| Lid, microphone | Close/open the lid, a live microphone, and Blow (noise, held) for a device without one. "Lid and microphone" below. |
| Buttons | The app's input ids grow X (10) and Y (11). Keys: default preset X = D, Y = C; home-row preset X = I, Y = U; rebindable in Settings > Controls as "X (DS)"/"Y (DS)". They count only while a DS game runs (`boundInput`), so elsewhere I stays the input-display shortcut. A saved 10-key profile gains the defaults (or none, where its keys already hold them). Gamepad (standard mapping), by label: 0 A, 1 B, 2 X, 3 Y; shoulders and triggers L/R; Back/Start; d-pad and left stick. Touch: A/B/X/Y become a diamond of the same buttons (X top, Y left, A right, B bottom, 0.75 of a button from the centre: clear of each other and narrow enough beside the d-pad at every control size); L/R stay. Phone held sideways: the screens fit between the d-pad and the face buttons (`ndsAvail`), and Select/Start are small labelled circles in the right rail under R (inboard pills, as Game Boy and GBA games have, would leave the screens 303 px tall of 393). |
| Audio | `web/nds/ndsaudio.js` (shared with the dev page): ring + windowed-sinc resampler in an AudioWorklet (ScriptProcessor without one), attached to the app's AudioContext at the master gain, so volume, mute and the clip tap apply. Emulation is paced by the ring's fill, as on the dev page: frames run while less than the target is buffered, so the audio clock sets the speed; the adaptive target (4 to 8 frames) grows on underruns. Before audio is unlocked, wall-clock pacing. A pause or a hidden tab drops what is queued silently. |
| Speed | Fast-forward (12 ms of frames a tick, sound only while the ring wants it), 2x (every other sample) and slow motion (each sample twice) through the same pacing; frame step; screenshot. |
| Saves | The cart backup (`n.cart.backup`, exports `nds_save_size/ptr/dirty/clean`) is stored under the usual `save:<name>` key whenever the chip's dirty flag says the game wrote it, on the usual triggers (5 s interval, hide, page close, game switch, Main Menu, close). The stored save goes into the core at boot (docs/nds/saves.md: an EEPROM/FRAM size names the chip, other sizes are fitted to the chip the game addresses and stored back exact). Import `.sav`/`.dsv` (stored whole, no GBA container sniffing; the core strips a .dsv footer) and export as for GB/GBA; Manage Saves' reset works. |
| BIOS / firmware | HLE BIOS and a synthesized firmware by default: nothing to supply. Settings > Nintendo DS takes `bios9.bin` (4 KB), `bios7.bin` (16 KB) and `firmware.bin` (128/256/512 KB), stored like the GBA BIOS (IndexedDB `bios:nds9`, `bios:nds7`, `bios:ndsfw`), used from the next DS game started from the library (a reset reboots on the BIOS the game started with). |
| Firmware settings | What a game or the DS menu writes to the firmware flash (the user's name, birthday, language, Nintendo WFC connections) is kept, one per device like a real DS's flash, shared by every DS game. "Firmware settings" below. |
| Power-off | A program that shuts the DS down (power manager register 0 bit 6) leaves a switched-off console: no frames, no sound, a "The game turned the DS off" layer with Restart and Library. "Power-off" below. |
| Library | System "DS" (chip, filter chip, sort, a small grey card with a corner cut for unpictured games), the paused hero and the tile picture are the top screen. The per-game menu says "this device only" while signed in to Drive. |

## Gated off (body.nds-mode)

| Feature | Why |
|---|---|
| Save states: Quick save/load, slots, Save States, resume snapshots and the hand-off | The core exports `nds_state_size`/`nds_state_data`/`nds_state_load` (+ `nds_state_error_kind`/`nds_state_error`; docs/nds/savestate.md). `ndsCaptureState`/`ndsApplyState` in index.js "Nintendo DS" call them, so `captureStateBytes`/`applyStateBytes` work, `body.nds-states` brings back quick save/load and Save States, the library offers the session, and a refused state's toast reads the DS core's reason. Rewind and run-ahead need more than that and stay off. |
| Rewind, the rewind scrubber, Report a Bug's timeline | No rewind ring on the DS core (Report a Bug attaches the moment, when states exist). |
| Clip that! and Record | Clip that! replays the GB/GBA core's history; Record is kept with it as in every other mode (it would likely work: canvas + audio tap). |
| Link cable, 2P link | No DS wireless/link. |
| Cheats | The cheat engines are the GB/GBA cores'. |
| Library pictures batch | It boots games on the GB/GBA core; DS games get their picture by being played. |

None of the GB/GBA core's per-cart work runs for a DS game (tilt, camera,
rumble, printer, SGB, palette, the HLE audio indicator, the glow): that core
still holds the last GB/GBA game, so each of those checks the DS mode first.

## Screens

The choices live in two places with the same chips and toggles: the
**Screens panel** (the screens button in the top bar, DS games only) and
Settings > Nintendo DS. A **swap** button sits beside the screens button.
They are stored per device like other settings: `nds-layout` (the
arrangement) and `nds-display` (`{ swap, gap, rot, barHide }`); a damaged
record falls back field by field; Reset all settings clears both.

| Choice | What it does |
|---|---|
| Automatic | Stacked or side by side, whichever shows the screens bigger in the room there is (a tie stacks). The default. |
| Stacked / Side by side | As named. |
| Focus | One screen whole and the other at a third of its size, below it or beside it, whichever lets the whole one be bigger. On a 375 px-wide phone the large screen is the full width (1.46x, against 0.72x side by side). |
| One screen | Only one. |
| Swap (B) | The bottom screen first: above / left, or the large (only) one in Focus and One screen. **A tap on the top screen swaps** in Focus and One screen (lifted within 500 ms and 12 px): nothing is touched there, so the small top screen comes up large with one tap, and the large top screen goes small. |
| Gap | None, Hinge (8 px, the default and what it was), or Like the console (90 px; Focus keeps at most the hinge's 8). The console's figure is an estimate, Assumed: a DS Lite's half is 73.9 mm deep closed, its 62 x 46 mm screens are 0.24 mm a pixel, about 14 mm from the top screen to the hinge and 8 mm on to the bottom one, 22 mm or ~90 px. Worth a ruler on a real console. |
| Turn (O) | Upright, Book left (the picture a quarter turn anticlockwise: top screen left, touch screen right, the right-handed way book games are held) and Book right (clockwise). The whole arrangement turns, and Automatic weighs the turned shapes. |
| Hide the top bar (phones) | On by default: on a phone held upright (coarse pointer, under 700 px wide) the bar slides off the top during a DS game, as it already does on a phone held sideways, and a tap on the picture brings it back over the top screen (and takes it away): the top screen, or the stage round the screens, never the touch screen (the stylus's) nor, in Focus and One screen, the top screen (its tap swaps). With the bar folded the top screen goes up to the notch or the Dynamic Island ("Phone held upright" below). |
| V | Next arrangement (with a toast). |

### Phone held upright

A DS game on a phone held upright (coarse pointer, portrait, under 700 px
wide) has its own controls strip; Game Boy and GBA games keep theirs.

| | |
|---|---|
| Top screen | With the bar folded, as high as the phone allows: `--nds-top` is where the notch or Dynamic Island ends (`--nds-cut`, from `NdsUtil.cutoutBottom` by screen size and status-bar inset, table below). A phone the table doesn't know gets the estimate: the inset less 14 px on a notched phone, 11 px on an island one (an inset of 54 px or more). A plain 20 px status bar, or a browser tab (no inset), keeps the whole inset. Room the screens do not fill goes below them. |
| L, R | 120 x 28 at the strip's top corners (were the full-width 46 px row), hit 6 px above and below. |
| Select, Start | 28 px circles labelled underneath, at the bottom between the d-pad and B (were a 150 x 34 row of pills under the clusters). Each is hit 8 px past its circle and on its label. |
| D-pad, face buttons | Their size as before; the row they sit in is exactly the d-pad's height, on the strip's bottom padding `--nds-pad-b`: the home indicator's inset less 12 px (at least 10), plus a 16 px lift (`--nds-lift`) on a phone that has the indicator. The lift comes out of the screens: 383.5 -> 373 px wide on a 402 x 874. |

On a 402 x 874 iPhone 17 (62 / 34 insets) the stacked screens are 373 px
wide (267 before the DS layout). The first iPhone SE is not a target for DS
games (too slow).

Where the cut-outs end (CSS px = points), measured per model on its
simulator: for the islands, the system's own exclusion area (the iOS app's
`-probe-cutout`); for the notches, the simulator's screen mask, which draws
the notch up to 1.7 px deeper than iOS's exclusion area says.

| Screen @ inset | Phones | Cut-out ends |
|---|---|---|
| 375 x 812 @ 44, 414 x 896 @ 44 | X, XS, XS Max, 11 Pro, 11 Pro Max | 30 |
| 414 x 896 @ 48 | XR, 11 | 33 |
| 375 x 812 @ 50 | 12 mini (34.33), 13 mini | 37.5 |
| 390 x 844 @ 47, 428 x 926 @ 47 | 12 series (32); 13, 13 Pro, 13 Pro Max, 14, 14 Plus, 16e, 17e | 33.67 |
| 393 x 852 @ 59, 430 x 932 @ 59 | 14 Pro, 14 Pro Max, 15, 15 Plus, 15 Pro, 15 Pro Max, 16, 16 Plus (island 11.33 to 48) | 48 |
| 402 x 874 @ 62, 440 x 956 @ 62 | 16 Pro, 16 Pro Max, 17, 17 Pro, 17 Pro Max, 18 Pro, 18 Pro Max (island 14 to 50.67; 18 Pro's 94.67 wide, the others 125) | 50.67 |
| 420 x 912 @ 68 | Air (island 20 to 56.67) | 56.67 |

Where one key covers two models the deeper cut-out is used. The old
estimate was exact on the 59-inset islands, a third of a pixel low on the
62 and 68 ones, and 0.67 px (13 / 14) or 1.5 px (13 mini) under the notch.

The touch controls never change: only the stage gives or takes room (the
e2e checks every control's box is identical in every mode, with the bar
shown and hidden, upright and sideways). Sideways, every arrangement fits
between the d-pad and the face buttons (`ndsAvail`), as before.

Integer scaling: whole multiples where 1x fits the stage, and the plain
fit where it does not (it never draws a picture bigger than the stage,
which the old `max(1, floor)` did on small phones). In Focus the large
screen is the whole multiple; the small one is a third of it.

How it is drawn: `NdsUtil.layout` gives the arrangement (each screen's rect
in an upright composite, the picture's turned size, the scale); the
presenter (`glpresent.js`, `frame.out`) draws the core's two BGR555 buffers
(one 256 x 384 texture, no conversion) view by view: each screen into its
own rect of the canvas, at its size, turned, over the stage's colour. The
filters clamp to the view's own texels and the grid / RGB-subpixel looks
follow the screen's pixels, so a turned screen turns its subpixel stripes
as the real panel would. The GB/GBA path draws exactly what it did (same
canvas bytes under every filter, old against new). `#nds-hinge` is gone:
the presenter paints gaps and Focus's empty corner. The stylus maps a
client point back through the same rects and turn (`touchPoint`,
`screenAt`; `clientPoint` is the inverse, for tests).

Screenshots of every mode at 375x812, 390x844, 844x390, a 820x1180 tablet
and a 1280x800 desktop are made by a Playwright script outside the repo
(any `.nds`, e.g. a homebrew); see the branch's report.

## Lid and microphone

- **Lid** (Screens panel or N): `nds_set_lid` (EXTKEYIN bit 7; opening
  raises the lid IRQ, docs/nds/peripherals.md "Sleep and the lid"). Closed,
  the screens dim under a "Lid closed · tap to open" layer over the stage
  (a closed console has no touch screen to reach), and a tap anywhere opens
  it. Every boot starts open, and after a state load the core is told the
  lid as the page has it. Not closed automatically when the page hides
  (considered): a hidden page runs no frames, so the game would never see
  the lid shut, and pausing already stops the game.
- **Microphone** (the panel's Microphone button, a toggle): permission is
  asked only then (`getUserMedia`, echo cancellation / noise suppression /
  gain control off). The stream goes through an AudioWorklet (a
  ScriptProcessor where there is none) in the app's AudioContext, pulled
  through a silent gain straight to the destination (never the master gain:
  no echo, nothing in a clip), and each 1024-sample chunk is pushed as int16
  at the context's rate (`nds_push_mic`; the core plays its queue out
  against emulated time and keeps at most 250 ms). Nothing is pushed while
  paused. The button's fill shows the live level. Not stored: the page must
  not open the microphone on its own next time. On iOS the audio session is
  switched to play-and-record while it records (playback after); not yet
  tried on a phone.
- **Blow** (the panel's button, held; or H held): one emulated frame of
  white noise at ~60% of full scale (`NdsUtil.blowNoise`, Assumed: a blow
  test listens for a loud level) pushed before each frame, at 16 kHz (the
  microphone's own rate while it is on). For a device without a
  microphone, or a quiet room.

## Firmware settings

The core's flash (`spi.firmware`, wasm `nds_firmware_len/_ptr/_dirty/_clean`)
changes when a game or the DS menu programs it (docs/nds/accuracy.md 6).

| | |
|---|---|
| Where | IndexedDB `bios:ndsflash`, beside the dumps: `{ data, base, ts, by }`. One per device, shared by every DS game (one console's flash). Never synced: DS stays local, and the record is not a per-game key. |
| When | On the battery's triggers (`persistSave`: the 5 s autosave, hide, close, game switch, Main Menu, power-off) while `nds_firmware_dirty`. The bytes are taken synchronously with the battery's (the core may be dropped right after); a put that fails is kept for the next flush. |
| The user's firmware.bin | Stays as given (`bios:ndsfw`). The written image is its own record with `base` = the dump's signature; the next boot gets it whole. A different dump (or none) has another base, so it starts from its own settings; the record is ignored until a write on that base replaces it. (Decision: a real DS writes its own flash, but the dump is the user's file, so it stays untouched and Reset goes back to it.) |
| The built-in firmware | `base` "built-in". Only the user area (the three Wi-Fi connection slots and both user-settings copies, `[020h]*8 - 400h` to `+ 200h`) is laid over this build's `synth_firmware` (`nds_synth_firmware`), so a later fix to the built-in header or wifi calibration (docs/nds/saves.md) still reaches a device whose settings changed. |
| Reset in place | `nds_reboot` now keeps the running core's flash (and its dirty flag) instead of the image the game booted with: a power cycle keeps what was written. Restart after a power-off and the app's Reset therefore see the game's own writes. |
| Settings > Nintendo DS, Console settings | Name, birthday, language and favourite colour (its number 0-15: GBATEK names only 0 grey and 1 brown) of the firmware the next boot gets, read with the core's rules (current copy: CRC-valid, update counter one more; `NdsUtil.fwReadUser`). Edit changes name (10 UTF-16 units), birthday and language as the menu does (`NdsUtil.fwWithUser`): the current copy edited, written over the older one with the counter + 1 (mod 80h) and its CRC16 (FFFFh, 000h..06Fh) at 072h; extended settings (074h, iQue/DSi) get the language too when their own CRC at 0FEh holds. A running game's flash takes the edit as well (it reads its settings at boot, so it sees it at the next start). Reset deletes the record. The built-in firmware's rows load the DS core (cached) when the section is shown. |

Checked against the core: an image `fwWithUser` wrote boots with the
edited name, birthday and language in RAM at 27FFC80h (ndsrun --peek9), and
copies the core's flash code wrote read back CRC-valid in `fwReadUser`.

## Power-off

`nds_powered_off()` (the core stops both CPUs and blanks the screens:
docs/nds/accuracy.md 1) is checked after every tick that ran frames, a
frame step, a boot and a state load (`ndsSyncPower`). On the change to off:

- No frames (`ndsTick` and frame step return), the audio ring dropped
  silently, the stylus and Blow released, the wake lock let go.
- The battery and firmware stored at once (`persistSave`).
- The session ends: its resume snapshot and picture (`stateauto:`,
  `sessionpic:`) are deleted, `persistAutoState` takes none of an off
  console, the library picture stays the last one played (`storeLastFrame`
  skips), and no state can be saved of it (`ndsCaptureState` is null; a
  slot save says "restart it first"). A tile then starts the game afresh,
  which is what switching on again is.
- `#nds-off` over the black screens: "The game turned the DS off" with
  **Restart** (focused; `loadRom` in place, as the Reset button: `nds_reboot`
  on the stored save) and **Library** (closes the game, as the hero's Close).
- A state taken while off loads off and shows the layer; loading a running
  state over an off console switches it back on.

Pause, fast-forward and the menu work as before; the layer stays until
Restart, Library or another game.

## Google Drive: DS games stay local (decision)

Nothing of a DS game goes to Drive: not its ROM, save, picture, session or
library entry (`driveExcluded`, `driveLibraryOf`). The account's other
devices run the production app (main), which has no DS core and would list
a synced `.nds` as a Game Boy game; a synced save would also make a
"save only" library entry there. Saves are small enough that syncing them
later is easy once main can play them. A toast says so once a session when
a DS game starts while signed in; the per-game menu says "this device only".

## Performance

Headless Chromium on this Mac (M-series, `--use-angle=metal`), the app's own
build (`-O3`, `danger`):

| Game | Unpaced | |
|---|---|---|
| Pokemon SoulSilver, intro (frame ~1500) | 5.0-5.5 ms/frame (~200 fps) | `DINGBAT_NDS_BENCH=... node --test e2e/nds.e2e.mjs`; plays at 59.8 fps paced, 272 MB heap |
| libnds examples (they halt in V-blank) | well under a ms | `built/simple.nds` paced at 59.6 fps, 0 underruns |
| Bare-metal test ROMs that spin both CPUs (`snd_tone`, `fb_*`) | ~22 ms/frame | no halt to skip: ~45 fps in wasm. A core matter, not the page |

Software WebGL (headless Chromium without a GPU, CI's Linux) draws the DS
frame at a few frames a second: judge speed with a GPU.

## Tests

- `web/tests/nds.test.mjs` (node:vm, with the real index.js): header
  detection, layout and stylus maths (every arrangement x swap x gap x turn
  round-trips a pixel through `clientPoint` and `touchPoint`; Focus's
  shapes; turned views), the button map, the audio ring, battery saves
  through a stand-in core (stored when written, booted next time, reboot on
  import), X/Y bindings and old profiles, Drive exclusion, the save-state
  hook, the display choices stored and read back (and a damaged record
  falling back), tap-to-swap in Focus, the stylus through a turned picture,
  the V/B/O/N/H keys, the lid at boot and after a state load, mic int16 and
  Blow's noise; firmware user settings (read, edit over the older copy,
  counter wrap, a damaged copy, extended language, the built-in overlay),
  a written flash stored once and never queued for Drive, the next boot on
  it (built-in: overlaid; a dump: whole; another dump: its own), Console
  settings shown / edited / reset (the running core's flash following),
  and power-off (frames stop, battery stored, session deleted, no
  snapshot or state, Restart reboots; a state loaded off; Library
  closes). `web/tests/helpers.mjs` prepends `nds/ndsutil.js` and
  `nds/ndsaudio.js` as index.html loads them.
- `web/e2e/nds.e2e.mjs` (Playwright, headless Chromium): both screens read
  back off the canvas in both layouts, the pointer's touch matching a direct
  touch at the same pixel (`built/touch_test`), `snd_tone`'s two channels,
  realtime pacing, a save the game wrote (`save_write`, our boot-counter
  ROM: `tests/nds/tools/build_save.sh`) surviving a reload, and a .dsv
  imported through Manage Saves. `fw_power` (our ROM:
  `tests/nds/tools/build_fw_power.sh`): START switches it off, the layer
  shows over black screens, no frames run, the resume snapshot goes,
  Restart boots it again (with the flash its first boot wrote), Library
  closes it; the firmware it wrote ("FWTEST1") boots after a reload (it
  then writes "FWTEST2"), Settings shows it, an edit in Settings reaches
  the game at Reset. `DINGBAT_E2E_SHOTS=<dir>` saves screenshots of the
  layer and the Console settings. Display modes
  (27 of them: four arrangements x swap x three turns, plus gaps and
  Automatic): each shown screen's corners read off the canvas where and
  which way up the layout says (`fb_both`: blue top left, red top right,
  magenta bottom; xBR turned in Focus too), the console gap in the stage's
  colour; real mouse presses landing on the bottom-screen pixel under them
  in every mode; on 375x812 and 390x844 phones the bar going and coming
  back with the handle, the screens growing, every control's box unchanged
  in every mode; sideways, every mode between the rails; the lid, Blow, and
  Chromium's fake microphone reaching `nds_push_mic`. Skips without the
  builds or ROMs.
- `web/e2e/nds-soulsilver.e2e.mjs` (local only, needs the commercial ROM
  and a save: env vars in its header): import, CONTINUE, save in game,
  reload, CONTINUE (docs/nds/saves.md).

      NODE_PATH=../../web/node_modules node --test web/tests/*.test.mjs     # worktree: the main checkout's node_modules
      cd web && node --test e2e/nds.e2e.mjs

## Files

`web/nds/ndsutil.js` (pure helpers, `NdsUtil`), `web/nds/ndsaudio.js`
(`NdsAudioRing`, `createNdsAudio`), index.js "Nintendo DS" (the session) plus
small DS branches where the app touches the GB/GBA core (`loadRom`,
`persistSave`, `drawGame`, `nativeRes`, `updateCanvasScaling`, the tick,
input routing), `web/types/nds.d.ts` (the core module's type, by hand: keep
it in step with the `.nims` export list), `styles.css` "Nintendo DS",
`web/serve.py`, `tools/serve_nds_dev.sh`.

## Left to do

- On a real phone: the hidden bar in standalone mode (safe areas), the
  microphone's audio session on iOS, and how Focus's tap-to-swap feels.
  Headless Chromium has no safe areas and no iOS audio session.
- One screen showing the bottom has no gesture back to the top (the
  screen is the stylus's): the swap button, the panel or B.
- Hiding the bar for GB/GBA too (portrait GB/GBA is width-bound, so it
  would only add letterbox); the size of Focus's small screen (a third) as
  a choice.
- Rewind and run-ahead on the DS (`state_payload` / `load_state_payload`
  are the core's hooks; docs/nds/savestate.md has the sizes and costs).
- The GBA slot, wireless.
- Drive sync of DS saves once main plays DS games (the firmware record
  stays local even then: it is one device's console).
- The favourite colour as a swatch (no colour table in GBATEK) and an
  editor for it and the message; the DS menu itself in the app (firmware
  boot from the web app: boot.md "Wasm").
