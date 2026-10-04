# The web home screen

What the home screen shows in each state, what its buttons do, and the
records behind them. Code: `web/index.js` (search the section names below),
`web/styles.css`, tests in `web/tests/home-current.test.mjs`,
`home-brand.test.mjs`, `game-switch.test.mjs` and `home-signin.test.mjs`.

## Two rules

**A fresh visit opens on the brand**: the big logo and slogan, with the
whole library under it (the last game played is first in the grid, which
is sorted by play). Scrolling hands the brand to the bar.

**Once a game is played in this visit, it heads the page, paused or not**
(the *hero*, `#hero`; `playedThisVisit`). Every other game is in the grid
below it. The hero's game is shown once: its tile stands down from the
grid (`.is-current`) except while a search or filter is running, and a
library of only that game folds the grid away (`body.home-solo`). Closing
a game changes the hero in place; nothing in the grid moves. The next
fresh visit opens on the brand again.

## The states

| Library | A fresh visit | A game played this visit, now paused (Main Menu) | … then closed |
|---|---|---|---|
| empty | Logo, slogan, the drop box with **Add a game**, and *Already playing on another device?* with Google's button | — | — |
| one game | Logo, slogan, the game's tile | The hero alone, paused, with an **Add a game** pill under it | The hero alone, Last played |
| a few | Logo, slogan, the games | The hero, then the other games | the same, Last played |
| more than 8 | Logo, slogan, then search, chips and sort above the grid | The hero, then search, chips and sort above the grid | the same, Last played |

Search and filters appear only above 8 games (`LIB_BAR_MIN = 9`); a running
filter keeps them so it can always be cleared. Phones use the full-width
hero in every state.

## The hero's buttons

`data-mode` on `#hero` is `paused` or `closed`.

| Mode | Buttons | Resume does | The second button does |
|---|---|---|---|
| paused | **Resume** · Close · ⋯ | Goes back to the game still in memory | Close: flushes the save, keeps the session, turns the hero to closed |
| closed, with a session | **Resume** · Play · ⋯ | Boots the game and puts the session back in during the boot | Play: boots from the in-game save |
| closed, no session | **Play** · ⋯ | Boots from the in-game save | — |

A **session** is the `stateauto:<game>` snapshot, taken when the game is
left (Main Menu, a switch, a close, the tab hidden or closed) and only when
it has moved since the last one (`sessionMoved`). It counts only while the
stored save is the one it was taken with (`saveSig`, `resumeSessionFor`): a
game that has saved since boots from that save, so a snapshot can never
roll a save back. The page reloaded, the hero is closed.

While the game runs, the session is also taken every minute of play
(`CHECKPOINT_PLAY_MS`, a **checkpoint**), so a browser that crashes or is
killed with the game on screen - no hide, no close, nothing to take it on -
resumes about a minute back rather than wherever the game was last left.
See *A game that keeps stopping* below.

## A game that keeps stopping

**Checkpoints.** Every minute of play (`maybeCheckpoint`, from the end of a
tick that has room: under `CKPT_SLACK_MS` spent, or `CKPT_WAIT_MS` overdue)
the session is taken again and a copy kept as an earlier moment. The
frame's thread only copies out the plain state image
(`wasm_state_plain_size`), the screen and the battery file, ~1 ms (~4 ms at
4x CPU throttling); `ckptworker.js` deflates the state into the stored
format (`pack_state`'s: header flagged, body zlib, via `CompressionStream`),
signs the battery and encodes the picture. Packing on the page cost
2.3 ms / 9.9 ms in game (FireRed), a dropped frame on a phone. Without a
worker (iOS 15) the page does it all, as before. A result that lands after
a newer snapshot (Main Menu, a switch) or a delete of the session is
dropped (`sessionSnapTs`, `sessionEpoch`). Drive gets a checkpoint's session
at most every `SESSION_UPLOAD_MS` (5 min); leaving the game sends the newest
at once (`sessionUnsent`).

Checkpoints are kept on this device only (`ckpts:<game>` index,
`ckpt<slot>:<game>` records, nine slots), spread over *play* time, which the
index carries (`play`), so a week away does not lump them into one bucket:
the newest, and the oldest within each of 3 min, 10 min, 30 min, 2 h, 8 h
and beyond behind it (`keepCheckpoints`). Older than 30 days, one goes.
They go with a reset, a delete and Remove from this device; a rename moves
them. Other games' checkpoints are freed before any ROM when storage runs
out (`dbPutRoomy`).

**Crashes.** While its game runs in view a page records itself in the
`playing` IndexedDB record, and takes itself out when the game pauses, the
page is hidden or closed, or the game is left (`markPlaying`,
`clearPlaying`). A mark found at boot whose page holds no Web Lock
(`dingbat-page:<page>`) is a run that ended without any of those - a crash
(`noteCrashedRuns`) - and counts in `crashes` (per game: `{ streak, since }`;
`seen` keeps a mark from counting twice). IndexedDB, because Chrome writes
localStorage to disk seconds late: a SIGKILL soon after a relaunch lost the
count and brought back the mark it had counted. A core trap keeps its mark.
A run counts toward the row only while it is short: once it has played
`CLEAN_RUN_MS` (1 min, `long` in its mark) a crash starts a new row at one,
and a normal end clears the count.

A quitting browser runs the close handlers but lands none of their
IndexedDB writes (Chrome; WebKit lands the first small one), measured with
Playwright closes: so the end of a run is also written to localStorage
synchronously (`dingbat_clean:<page>`; a mark with it is no crash), and the
close handlers leave the session, with a battery not yet stored, in
`dingbat_lastgasp`, which the next boot takes in when it is newer than the
stored session (`takeLastGasp`; `lastgasp` in IndexedDB is the newest taken
in, so one that comes back is not taken twice). Chrome closed mid-game then
resumes exactly; WebKit, whose localStorage writes there do not land
either, resumes at the last checkpoint. The close handlers clear the mark
first, then store the battery and the session.

The battery is stored once its file has stopped changing for
`SAVE_SETTLE_MS` (0.5 s; `FS.stat` mtime), not only at the 5 s autosave: a
crash 1.5 s after an in-game save kept it (it was lost before).

Checkpoint and session pictures are Blobs, which WebKit's private browsing
will not store: there they are skipped and the moment is kept without one.

After a crash, the checkpoints taken before it are frozen until the count
clears: what later runs take shares two places (`CKPT_CRASH_ROOM`), so a
checkpoint that crashes the game can be reopened any number of times and
the moments before it are still there.

**What the player sees.** Normally nothing: one crash and the next tap
resumes the newest checkpoint, the case this is for. Two in a row
(`CRASH_ASK_STREAK`) and a tap on the game (tile or hero) opens the sheet
instead of resuming (`crashGate`): *“Game” stopped unexpectedly* - it
closed without warning the last two times; if the moment it resumes from is
the cause, pick an earlier one. The sheet is the Save States grid: *Latest*
(the session) then each kept checkpoint, labelled by play time back (*4 min
earlier*, *2 h earlier*) and the clock time, *Latest* chosen; **Resume**,
and **Start from in-game save**. The same sheet, without the crash wording
or the save button, is **Resume from earlier** on the game's menu whenever
it has checkpoints.

A moment from before the last in-game save carries that older battery: the
cell says *Before your last save*, the note under the grid says what
happens, and choosing it keeps the newer save aside first (`keepOldSave`,
*The save you replaced*) so **Restore old save** switches back
(`resumeMoment`; loadRom's `resume.force` applies it despite the save).

The kicker over the name says where the game stands:

| Hero | Kicker |
|---|---|
| paused, signed out | Paused |
| paused, signed in | Paused · Syncing… → Paused · Synced (Not synced yet when Drive cannot be reached) |
| closed | Last played |
| closed, its session left on another device | On your iPhone · 5m ago (*your other Mac* when both are Macs) |

It is one line; a long one is cut short, never wrapped.

## Picking a game up on another device

The session is a Drive file (`stateauto:<game>`, its picture inside it:
`sessionBundle`), so it is the hand-off. **Main Menu** stores the session
of that moment and the save it was taken with at once, not at the next 5 s
autosave, and queues both; the kicker says *Synced* once they are up. On
the other device a pull brings them down, and its hero (or tile) resumes at
that moment. *Sync now* stores the loaded game's save and session before it
sends anything.

A game left paused on a device while another played on is a stale copy.
When a pull finds another device's newer save or session for the game in
memory (`handoffNews`):

- **On the home screen, everything of it already sent** (`heldGameIsSent`:
  no move since its session, its save stored and sent): the copy in memory
  is let go, nothing of it written (`takeHandoff`), and the newer files
  land. The hero turns closed, shows the other device's picture, says
  where it was, and Resume goes there. A toast: *“Game” was played on your
  iPhone since — Resume picks up there.*
- **Being played, or with work here not yet sent:** nothing is yanked. A
  toast offers *Switch* (*“Game” was played on your iPhone since you opened
  it here*), once per newer copy. Switch drops the copy here and lands the
  bytes the pull already downloaded (`handoffStash`), then sends them up
  again so they are Drive's copy too.

A session another device wrote since this one last saw Drive's copy is not
written over unseen: the flush holds it back and the pull after it decides.
Once the offer has been made the other session counts as seen, so a player
who keeps the copy here sends theirs, the later moment, at the next flush.
Saves keep the older rule: the last device to send one wins.

## Opening a game from a tile

Settings → Controls → *Opening a game from the library* (`library-open`):

- **Resume** (default): as the hero's Resume, where a session still counts.
- **From save**: boots from the in-game save, then offers the session in a
  toast (*Last session saved … Resume*).

Either way, the top bar's reset, or closing the game and choosing Play,
boots from the save. A file dropped on the page always boots from the save
and offers the session.

### A game that is only on Drive

Its tile is dashed, its picture and name dimmed, with ↓ in the corner. The
dimming is on the picture and the name, not the tile, and the hover that
lifts it is mouse-only: on touch the hover stuck after the tap and the tile
looked ready while it was still coming down. While it comes down
(`fetchTileGame`, painted by `paintTileLoad`), the tile says so over the
picture:

| | Over the picture | Bar | Corner |
|---|---|---|---|
| Tapped, not signed in | *Signing in…* / Google Drive | — | spinner |
| Tapped | *Opening* / 3.1 of 8.0 MB, amber ring | bytes | spinner |
| Downloaded, player coming | *Starting…* | full | spinner |
| ↓ or the menu's Download | *Downloading* / bytes, no ring | bytes | spinner |
| ↓ finished | nothing; a check for 2 s | — | ✓ |
| Failed | *Couldn't download* / Tap to try again, until the next tap | red | ↓ |

The total is the Drive listing's sizes of the files it fetches, so the bytes
are real from the first one. A tap elsewhere while one is opening is the
later tap and wins (`loadGen`): the first tile turns back into *Downloading*
and gets its check instead of opening. A tap on the picture during a ↓
download joins it and opens it when it lands; nothing is fetched twice.
The hero's game has its tile stood down, so when the hero shows a
Drive-only game its button says it instead: *Signing in…*, *Opening · 38%*,
*Starting…*, *Try again*.

## Pictures

- `frame:<game>` is the library's picture: the last screen stored (a slow
  tick while running, every pause, close and switch). Mirrored on Drive, so
  it may be another device's.
- `sessionpic:<game>` = `{ ts, blob }` is the session's own picture, written
  after the snapshot and stamped with its `ts`. It counts only while its
  `ts` is the snapshot's. In the session group of `perGameKeys`, so it
  moves and goes with the snapshot, and it reaches Drive inside the
  session's file rather than as one of its own.

The closed hero shows the session's picture where there is one, else the
library's, else the box art, else the game's cartridge (`buildCart`, two
initials from the tidied title, `cartLabelFor`).

## Flights

Going home, the screen shrinks into the hero's frame while the page rises
in under it. Opening a game, the picture flies from the hero or the tile
onto the screen, and the game is held (`body.home-flying`, `paused`) until
it lands. A picture lands intact only when it is the frame the game will
show: the paused game, or a session going back in whose picture is known
(a tile's picture turns into the session's on the way). Otherwise it goes
dark on the way and the screen powers on from black. Touch controls slide
up as the game opens. Nothing animates under reduced motion.

Web Animations here never fill forwards: every element made for a flight
is removed when it lands, and every animation is tagged (`home-flight`,
`hero-swap`). A CSS entrance animation is never switched off with `none`
and back: putting the name back restarts it (the arrival sets
`#home-inner`'s duration to 0 instead).

## The first picture

The library is read from IndexedDB a few frames after the page first
paints. So that a returning player does not see the empty state's drop box
under the brand first, the page keeps a hint in localStorage
(`dingbat_library`: `games` or `empty`, written on every library render).
Where it says `games`, a script in `index.html`'s head adds
`html.home-pending`: the brand paints at once, and what goes under it is
hidden until the first render has its tiles' pictures (at most 400 ms
more), then fades in. No hint, or `empty`, and nothing waits. `libraryEmpty` is `null` until the
first read, so nothing before it (the boot sync refresh) decides either way.

## Account

The bar's account slot (`#account-slot`, home screen only, not in the empty
state). Signed out: a dim outline of a person; it opens a menu holding
Google's own button (`google-signin-dark.svg` / `-light.svg`, from Google's
sign-in assets, unaltered). Signed in: the email's initial with a sync
badge (a tick, a turning ring, an amber mark); its menu has the sync status,
Sync now, Sign out, and Sign out everywhere (two taps; it signs every
device out).
