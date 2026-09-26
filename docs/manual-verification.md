# Manual verification list

Things that shipped with unit-test coverage but still need a hands-on check
the harnesses cannot provide (live Google account, deployed https build,
real devices). Delete an item once it has been seen working; add one
whenever something lands that needs the same treatment.

## "Clip that!" — range-based clip export

Gated: replay determinism (`tests/clip_replay_test.nim`), range arithmetic
(`web/tests/clip-range.test.mjs`). Not gated: the FILE, the strip as touch.

- [ ] **The file is the range.** Pick a range around a level transition;
      the .webm starts on the in marker's frame and ends on the out marker's,
      no leading live frames, no tail to "now".
- [ ] **Audio in sync** through a 60 s export; **a full minute exports**
      (banner to 100 %, controls inert, game resumes where it was).
- [ ] **Phone (LAN https).** Markers never swap, no momentum after lift, a
      tap moves the NEARER marker; portrait, landscape, rotate with the
      picker open.
- [ ] **Safari** produces .mp4; confirm it plays with audio.
- [ ] **Rewind off** (or speed mode on): the picker still shows a full strip.
- [ ] **iOS memory**: several minutes with the 6 MB clip cap, no reload or
      JIT demotion; oldest frame still ~a minute back on a GB game.
- [ ] **Rewind scrubber** (shared film-strip component): drag, tap,
      two-stage confirm, save-loss warning.

## Input display overlay

Settings → Controls → "Show inputs on screen" (`I` key);
`web/tests/input-display.test.mjs`.

- [ ] **iPhone LAN test.** With touch controls up the overlay is absent — no
      reserved space, touch buttons unchanged. Pair a Bluetooth controller:
      overlay bottom-left inside the safe area.
- [ ] **OBS capture** shows the overlay; the app's own Record Clip does not
      (canvas.captureStream — deliberate).
- [ ] **Legible at stream size**; **device themes** (`--pad-*` /
      `--btn-ab-*` / `--pill-*` tokens) spot-checked on two loud ones.
- [ ] **L/R present for .gba, gone for GB/GBC** with no gap.

## Library tiles and their menu

Gated: which items appear per game state and why each is blocked
(`web/tests/tile-menu.test.mjs`), the grid and its filters
(`web/tests/library-filter.test.mjs`). Not gated: touch, and anything that
needs a second real device.

- [ ] **The long press** on a phone: about half a second opens the sheet,
      the finger lifting afterwards does not launch the game, and a press
      that turns into a scroll opens nothing. iOS shows no text callout or
      selection under the finger.
- [ ] **Right-click** on desktop opens the menu at the pointer and the
      browser's own menu never appears. Near the bottom edge the popover
      flips above the glyph rather than off-screen.
- [ ] **The size is real.** A tile's menu shows the cartridge size, and it
      is right for a 4 MB and a 32 MB game. A game that has never been on
      this device shows no size until it is downloaded.
- [ ] **Remove closes the game.** With a game paused, Remove asks "Close and
      remove?", closes it, frees the space, and the save survives the close.
- [ ] **An online link holds everything.** Mid-session, every item is
      greyed with "Exit the online session first" — no item accepts a
      confirming tap and then refuses.
- [ ] **Add pictures** appears above the library only while a game lacks
      one, and is gone once the run finishes.
- [ ] **An empty library** shows the hero alone: Load a game beside Sign
      in, and no library section at all. The first game loaded brings the
      section in and takes Sign in away.
- [ ] **A small library does not strand its head.** With one, two and three
      games on a wide desktop window, the head, the search bar and the tiles
      are one centred block, not a rule across the screen with a tile in the
      corner. With two games and every filter chip showing, the chips take
      their own row rather than scrolling sideways.
- [ ] **A search does not move the bar.** Typing into the search field with
      a dozen games leaves the field and the chips exactly where they were,
      whatever the result count.
- [ ] **A game past the byte budget keeps everything but its file.** The
      budget is half of what the browser says this origin may hold, and the
      library head only shows a figure once the device is nearly full, so
      read the allowance from the console (`navigator.storage.estimate()`)
      and halve it, then load GBA games past it. The oldest
      tile is still there, still showing its picture, dashed like a
      Drive-only tile, and its menu offers Find the file rather than
      Download. Twenty small GB games evict nothing at all.
- [ ] **The allowance is not the same everywhere.** Check
      `navigator.storage.estimate()` on the phone, on the desktop and in a
      private window: the three differ, and the budget moves with them. A
      device reporting no figure at all falls back to 2 GB.
- [ ] **The storage line climbs in three steps.** With room to spare the
      library head shows no figure at all, only Sign in / Sync / Add
      pictures. Past 80% the figure appears in the head's own grey; past 90%
      the same words turn red; past 95% the figures give way to the reason,
      which must say that saves are kept. Freeing space
      walks back down. On a phone the 95% line takes two rows and pushes the
      links below it — check that reads as deliberate rather than broken.
- [ ] **A full device gives up files, not saves.** Hardest to stage and the
      most worth staging: fill the origin's storage (Safari's allowance is
      the easiest to reach, and a private window's is smaller again), then
      import one more game. A toast says how many games gave up their files,
      those tiles go dashed, every save is still there, and the imported
      game plays. With nothing left to give, the import says there is no
      room and adds no tile — it does not leave one offering to find a file
      you are holding.
- [ ] **Finding the file again reunites it with its save.** Tap that tile,
      pick the same ROM from disk, and the game launches with its save
      intact. Picking a file of a different size asks first; picking one
      with the wrong extension is refused.

## Drive sign-in: staying signed in

Gated: the broker routes on both servers against a fake Google
(`web/signaling/server.test.mjs`, also with `SIGNAL_CMD` on the Nim
binary), and every client path against a fake broker
(`web/tests/driveauth.test.mjs`). Not gated: real Google, the consent
popup's trip back through `oauth-callback.html`, and iOS.

Seen working on 2026-09-25 (laptop + iPhone Safari): fresh sign-in,
the automatic move of an old sign-in, broker down and back, a second
device, Sign out on one device, Sign out everywhere.

- [ ] **A day later, no popup.** Open dingbat on the laptop and the
      iPhone the next day and tap around: no Google window, and a save
      made on one reaches the other.
- [ ] **Home-screen app.** Its first launch shows the consent screen once
      and lands back in the app signed in. If the popup finishes but the
      app never signs in, the callback could not reach it (report it; the
      hourly popup flow still works there).
- [ ] **Declining the consent screen.** Close it instead of accepting:
      no second window follows, the hourly popup carries on, and the
      offer comes back a day later.

## Drive sync: away from the account

Gated: what is queued and how conflicts settle
(`web/tests/offline-queue.test.mjs`, `web/tests/sync-conflicts.test.mjs`),
against a fake Drive. Not gated: a live account, two real devices, and
real clock skew between them.

- [ ] **Signed out, then back in.** Delete a game while signed out; sign
      back in; it goes from Drive and from the other device.
- [ ] **Offline, then back on.** Same again with the network off rather
      than signed out; nothing is lost while the flush keeps failing.
- [ ] **A play beats an older delete.** Delete on A while signed out, play
      the game on B, then sign A back in: the game survives whole — its ROM
      is still downloadable on a third device, not just listed — and A gets
      its tile back.
- [ ] **A play does not beat a rename.** Rename on A while signed out, play
      under the old name on B, then sign A back in: both ends take the new
      name, and B migrates on its next sync rather than pushing the old
      name back for good. Expect it to settle after at most one extra sync.
- [ ] **A fresh import keeps the freed name.** Rename A→B on one device,
      import a different game as A on the other: both exist, and the new A
      is never renamed to B.
- [ ] **Reset reaches Drive.** Wipe a save while signed out; sign back in;
      the other device's copy is wiped too and does not come back.
- [ ] **A newer save beats an older reset.** Reset on A while signed out,
      play on B, then sign A back in: B's save survives.
- [ ] **Two accounts, one browser.** Queue a delete while signed out, sign
      in as a different Google account: that account's library is untouched
      and shows none of the first account's games. Sign back in as the
      first: the toast names the resumed work and the delete lands.
- [ ] **Mixed builds.** While one device is still on the deployed build, a
      sync from it drops the import marks this build writes, so a rename can
      steal a fresh import. Check once both devices run the new build, and
      do not judge the rename cases until they do.

## State-machine fix round (formal/FINDINGS.md)

Driven through the real UI in headless Chromium: the local scenarios, and
Drive on two browser profiles against a fake Google that follows the Drive v3
and GIS documentation (see FINDINGS.md). What only a real Google account can
settle, because the fake assumes it:

- [ ] **Renewal popup**: after the token's hour, the first tap renews silently
      (`prompt: ""` with `login_hint`) and a queued save goes up.
- [ ] **Account switch**: a browser signed in to two Google accounts. Sign out
      of one, sign in as the other: the second account's Drive gets only this
      device's own games, and switching back brings the first account's
      Drive-only tiles back.

## Drive sync: renames

Engine paths unit-tested (`web/tests/sync.test.mjs`, `rename.test.mjs`).

- [ ] **Drive-only rename**: immediate, still downloads after the flush,
      saves intact. **No re-upload**: a large ROM's rename flushes instantly.
- [ ] **Two-device migration**: rename on A; B's next sync toasts "renamed
      on another device", no delete modal, ROM/saves/states/cheats answer to
      the new name.
- [ ] **Rename while playing elsewhere**: B mid-game, A renames; B's next
      sync migrates live — one installed tile, quick save intact, no
      old-name files left on Drive.

## Drive sync: original ship

- [ ] **Two-device delete/tombstone round-trip** against a live account:
      delete on A, B shows "removed on another device", Restore re-uploads.
