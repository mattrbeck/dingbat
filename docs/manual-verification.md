# Manual verification list

Things that shipped with unit-test coverage but still need a hands-on check
against the real world (live Google account, deployed https build, multiple
devices) that the harnesses can't provide. Check an item off — or just delete
it — once it's been seen working; add a dated entry whenever something lands
that needs the same treatment.

## "Clip that!" — range-based clip export (2026-08-14)

Retroactive clip capture grew from a hardcoded trailing 10 s to a picked range
over a ~60 s rolling window, on the rewind scrubber's film strip with two
markers. The replay's determinism has a real gate
(`tests/clip_replay_test.nim`, three ROMs, whole-machine-state hashes) and the
range arithmetic has one (`web/tests/clip-range.test.mjs`), but neither
harness has a MediaRecorder, a canvas, or a GPU — so everything about the
FILE is unproven, and so is the strip as a touch control.

- [ ] **The file is the range.** Pick a range with a recognisable event in it
      (a level transition works well), save, and play the .webm back. Expect
      the clip to start on the frame the in marker sat on and end on the out
      marker's — no leading frames of the live moment (`drawGame()` before
      `captureStream` is what prevents that), no tail running on to "now".
- [ ] **Audio is in it, and in sync.** Same clip: sound present from the first
      frame, still lined up at the end of a 60 s export.
- [ ] **A full minute exports.** "Everything" on a GBA game after a minute or
      more of play. Expect a ~60 s file, the banner counting to 100%, controls
      inert throughout, and the game resuming exactly where it was left.
- [ ] **On a phone (LAN https).** Drag each marker; they must not swap, the
      film must not carry momentum after the finger lifts, and tapping the
      strip must move the NEARER marker. Check portrait and landscape, and
      rotate with the picker open (the strip re-rasterises on resize).
- [ ] **Safari.** The recorder there produces .mp4 rather than .webm; confirm
      the file plays and the audio track is present.
- [ ] **Rewind OFF.** Turn rewind off in Settings (and/or turn speed mode on,
      which suspends it) and confirm the clip picker still shows a full strip.
      This is the case the clip ring's own thumbnails exist for.
- [ ] **iOS memory.** Play for several minutes on the phone with the 6 MB clip
      cap and confirm no tab reload / JIT demotion, and that the picker's
      oldest frame is still roughly a minute back on a GB game.
- [ ] **The rewind scrubber still behaves.** It was refactored onto the shared
      film-strip component; re-check the drag, the tap, the two-stage confirm
      and the save-loss warning.
## Input display overlay (2026-08-14)

Settings → Controls → "Show inputs on screen" (or the `I` key): a DOM
controller pinned to the bottom-left of the stage that lights each button
while it is held. Every input path is unit-tested at the chokepoint
(`web/tests/input-display.test.mjs`, 16 tests) and the layout was screenshot
in headless Chromium across three themes plus a touch viewport; what no
harness can answer is how it looks and feels on real hardware and in a real
capture.

- [ ] **iPhone LAN test** (the standing rule for any mobile/PWA UI change).
      Serve the worktree's `web/` over the LAN and load it on the phone.
      Portrait and landscape, with the touch controls up: the overlay must be
      completely absent — no reserved space, no seam, and the touch buttons
      unchanged in size and spacing. Then pair a Bluetooth controller (which
      hides the touch controls) and confirm the overlay appears bottom-left,
      inside the safe area, and does not sit under the notch/home indicator.
- [ ] **OBS capture.** Add the browser tab as a Window Capture / Browser
      Source and confirm the overlay is in the captured image (it should be),
      then record a clip from the app's own Record Clip and confirm the
      overlay is NOT in the clip (canvas.captureStream — deliberate).
- [ ] **Legibility at stream size.** At 1080p downscaled to a typical stream
      view, check the SELECT/START lettering is still readable and the lit
      state is obvious at a glance over both a bright and a dark game.
- [ ] **Device themes.** The overlay borrows the `--pad-*` / `--btn-ab-*` /
      `--pill-*` tokens, so device themes (Famicom, atomic purple, daiei…)
      recolour it for free — spot-check two of the loudest ones for a pressed
      state that still reads.
- [ ] **A real GBA vs GB game.** L/R must be present for a `.gba` title and
      gone for GB/GBC (`body.gb-mode`), with the overlay getting shorter
      rather than leaving a gap.

## Now playing: page title + Media Session (2026-08-14)

The web UI names the running game in `document.title` and publishes it to
`navigator.mediaSession` (title, artist "dingbat", artwork), with play/pause
action handlers wired to the emulator's own pause state. Parsing, precedence
and the handlers are unit-tested (`web/tests/nowplaying.test.mjs`,
`tests/romtitle_test.nim`); what no harness can see is whether the OS
actually surfaces any of it. **Plain-http over the LAN is fine for all of
these** — nothing here is a perf measurement.

iPhone Safari is the one that matters and the one most likely to be wrong:
WebKit builds Now Playing from a *media element*, and this emulator's only
output is an AudioContext. The workaround shipped here is the silent looping
`<audio>` element that already existed for iOS ≤16's ringer switch, now also
created on modern iOS (`needsSilentLoop`). If items 3-5 fail, that is the
mechanism to suspect — not the metadata.

- [ ] **Page title.** Desktop or phone: load a game, confirm the tab/window
      says "<Game> — dingbat"; close the game (home → close) and confirm it
      goes back to plain "dingbat". Load a game out of a `.zip`, or one whose
      filename is a serial/hash, and confirm the title falls back to the
      cartridge header name (e.g. "POKEMON EMER") rather than showing the
      archive's inner temp name.
- [ ] **iPhone lock screen.** Start a game (tap something so audio unlocks —
      audio must be audible first), lock the phone. Expect the game's name
      with "dingbat" underneath, and a screen/box-art image. Box art only
      appears for games that have it in the library.
- [ ] **iPhone Control Center.** Swipe down from the top-right during play:
      the audio card should name the game, not "Safari" / the page URL.
- [ ] **Lock-screen pause/resume.** From the lock screen, hit pause: the
      emulator must actually freeze (unlock and check — not just go silent),
      and the widget must show paused. Hit play: it resumes. Then pause with
      the in-app ⏸ button and re-lock — the lock screen must already show
      "paused" (it reconciles within a second).
- [ ] **No audio regression.** The silent element is new on iOS 17+. Play for
      a few minutes with the ringer switch BOTH ways, take a phone call or
      trigger Siri mid-game and come back, and confirm the emulator audio is
      unchanged: no crackle, no drift, no dropout, no stuck silence. This is
      the check that would veto the feature — the pushAudio lead servo is
      tuned and the element must be invisible to it.
- [ ] **Android Chrome / desktop.** No silent element is created there, so
      the notification/media-key surface may simply not appear. Confirm the
      page title still works and nothing is broken; media keys working at all
      is a bonus, not a requirement.
- [ ] **Library, not a phantom.** Close the game and re-lock the phone: the
      Now Playing card must be gone (or at least empty), not stuck on the
      last game.

## Drive sync: renames (2026-08-14, `3f9370a`)

Renames now mirror to Drive as in-place metadata renames, and a `ren` marker
in the shared library migrates other devices. All engine paths are
unit-tested (`web/tests/sync.test.mjs`, `rename.test.mjs`); what's unproven
is the real Drive API + two real devices.

- [ ] **Drive-only rename.** On a device that does NOT hold a game's bytes
      (Drive-only tile), rename it from Manage ROMs. Expect: rename succeeds
      immediately, the tile shows the new name, and after the sync flush the
      game still downloads on tap — under the new name, saves intact.
- [ ] **Two-device migration.** Rename a game on device A that device B holds
      locally (with a battery save). On B's next sync expect: a toast
      ("…renamed on another device"), NO "removed on another device" delete
      modal, and B's ROM/saves/states/cheats all answering to the new name.
- [ ] **No re-upload.** Rename a large downloaded ROM and watch the sync
      indicator: the flush should be near-instant (metadata PATCHes only),
      not a multi-MB upload.
- [ ] **Rename while playing elsewhere** (hardened 2026-08-15 after the first
      field test failed). Rename on A while B is mid-game on the same title,
      then switch back to B's tab. B's very next sync should migrate live:
      the game keeps running and now answers to the new name, the grid shows
      one installed tile, and the quick save survives — never an
      "uninstalled" tile over stranded old-name data.
- [ ] **The failed field flow, re-run.** Install + quick save in browser 1
      (leave the game open), rename from browser 2 where it was never
      downloaded, return to browser 1 and sync/reload. Expect one installed
      game under the new name with the quick save present, and no old-name
      files left on Drive afterwards.

## Drive sync: original ship (2026-07-23, `a023c79`) — still open

- [ ] **Two-device delete/tombstone round-trip** against a live account:
      delete on A, confirm B shows the "removed on another device" modal and
      that Restore really does re-upload. Unit-tested since day one, never
      seen live.
