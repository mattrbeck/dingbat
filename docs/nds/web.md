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
| Screens | One composite frame through the WebGL presenter (`glpresent.js` takes `opts.frame`: BGR555 parts placed in one texture; no per-frame conversion). Stacked (256 x 392) or side by side (520 x 192), 8 composite pixels apart; `#nds-hinge` paints the gap the stage's colour so the screens read as two. **Automatic** picks whichever shows the screens bigger in the stage; Settings > Nintendo DS and the screens button in the top bar (DS games only) pick Stacked or Side by side. Integer scaling and the filters/screen looks apply; colour correction and the GB palette do not (the DS's own LCDs). The backing store is `glScale()`, or less when the picture is shown small and no screen look needs whole pixels (`ndsBackingScale`). |
| Stylus | Pointer events on the canvas (mouse, pen, finger): a touch starts only on the bottom screen and then follows the pointer, clamped to its edges, until it lifts (`NdsUtil.touchPoint`: client point to 256x192, exact at any scale and layout). |
| Buttons | The app's input ids grow X (10) and Y (11). Keys: default preset X = D, Y = C; home-row preset X = I, Y = U; rebindable in Settings > Controls as "X (DS)"/"Y (DS)". They count only while a DS game runs (`boundInput`), so elsewhere I stays the input-display shortcut. A saved 10-key profile gains the defaults (or none, where its keys already hold them). Gamepad (standard mapping), by label: 0 A, 1 B, 2 X, 3 Y; shoulders and triggers L/R; Back/Start; d-pad and left stick. Touch: A/B/X/Y become a diamond of the same buttons (X top, Y left, A right, B bottom, 0.75 of a button from the centre: clear of each other and narrow enough beside the d-pad at every control size); L/R stay. Phone held sideways: the screens fit between the d-pad and the face buttons (`ndsAvail`), and Select/Start (the small circles) move from the bottom middle, where the touch screen is, to just under R. |
| Audio | `web/nds/ndsaudio.js` (shared with the dev page): ring + windowed-sinc resampler in an AudioWorklet (ScriptProcessor without one), attached to the app's AudioContext at the master gain, so volume, mute and the clip tap apply. Emulation is paced by the ring's fill, as on the dev page: frames run while less than the target is buffered, so the audio clock sets the speed; the adaptive target (4 to 8 frames) grows on underruns. Before audio is unlocked, wall-clock pacing. A pause or a hidden tab drops what is queued silently. |
| Speed | Fast-forward (12 ms of frames a tick, sound only while the ring wants it), 2x (every other sample) and slow motion (each sample twice) through the same pacing; frame step; screenshot. |
| Saves | The cart backup (`n.cart.backup`, exports `nds_save_size/ptr/dirty/clean`) is stored under the usual `save:<name>` key whenever the chip's dirty flag says the game wrote it, on the usual triggers (5 s interval, hide, page close, game switch, Main Menu, close). The stored save goes into the core at boot (docs/nds/saves.md: an EEPROM/FRAM size names the chip, other sizes are fitted to the chip the game addresses and stored back exact). Import `.sav`/`.dsv` (stored whole, no GBA container sniffing; the core strips a .dsv footer) and export as for GB/GBA; Manage Saves' reset works. |
| BIOS / firmware | HLE BIOS and a synthesized firmware by default: nothing to supply. Settings > Nintendo DS takes `bios9.bin` (4 KB), `bios7.bin` (16 KB) and `firmware.bin` (128/256/512 KB), stored like the GBA BIOS (IndexedDB `bios:nds9`, `bios:nds7`, `bios:ndsfw`), used from the next DS game started from the library (a reset reboots on the BIOS the game started with). |
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
| Lid close | Not in the UI yet (the core has `input.lid_closed`). |

None of the GB/GBA core's per-cart work runs for a DS game (tilt, camera,
rumble, printer, SGB, palette, the HLE audio indicator, the glow): that core
still holds the last GB/GBA game, so each of those checks the DS mode first.

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
  detection, layout and stylus maths, the button map, the audio ring,
  battery saves through a stand-in core (stored when written, booted next
  time, reboot on import), X/Y bindings and old profiles, Drive exclusion,
  the save-state hook. `web/tests/helpers.mjs` prepends `nds/ndsutil.js` and
  `nds/ndsaudio.js` as index.html loads them.
- `web/e2e/nds.e2e.mjs` (Playwright, headless Chromium): both screens read
  back off the canvas in both layouts, the pointer's touch matching a direct
  touch at the same pixel (`built/touch_test`), `snd_tone`'s two channels,
  realtime pacing, a save the game wrote (`save_write`, our boot-counter
  ROM: `tests/nds/tools/build_save.sh`) surviving a reload, and a .dsv
  imported through Manage Saves. Skips without the builds or ROMs.
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

- Portrait phones: the controls keep their size, so the screens get what is
  left (side by side, ~375 x 140 on an iPhone 13 mini). A DS-only portrait
  arrangement (screens over a smaller strip, or controls over the top
  screen) is a decision for Matt.
- Rewind and run-ahead on the DS (`state_payload` / `load_state_payload`
  are the core's hooks; docs/nds/savestate.md has the sizes and costs).
- Lid close, microphone, the GBA slot, wireless.
- Drive sync of DS saves once main plays DS games.
