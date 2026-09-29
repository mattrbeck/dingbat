# The web home screen

What the home screen shows in each state, what its buttons do, and the
records behind them. Code: `web/index.js` (search the section names below),
`web/styles.css`, tests in `web/tests/home-current.test.mjs`,
`game-switch.test.mjs` and `home-signin.test.mjs`.

## One rule

**The last game played heads the page, paused or not** (the *hero*,
`#home-paused`). Every other game is in the grid below it. The hero's game
is shown once: its tile stands down from the grid (`.is-current`) except
while a search or filter is running, and a library of only that game folds
the grid away (`body.home-solo`). Closing a game changes the hero in place;
nothing in the grid moves.

## The states

| Library | Nothing loaded | A game paused (Main Menu) |
|---|---|---|
| empty | Logo, slogan, the drop box with **Add a game**, and *Already playing on another device?* with Google's button | — |
| one game | The hero alone, with an **Add a game** pill under it | The hero alone, paused |
| a few | The hero, then the other games | the same |
| more than 8 | The hero, then search, chips and sort above the grid | the same |

Search and filters appear only above 8 games (`LIB_BAR_MIN = 9`); a running
filter keeps them so it can always be cleared. Phones use the full-width
hero in every state.

## The hero's buttons

`data-mode` on `#home-paused` is `paused` or `closed`.

| Mode | Buttons | Resume does | The second button does |
|---|---|---|---|
| paused | **Resume** · Close · ⋯ | Goes back to the game still in memory | Close: flushes the save, keeps the session, turns the hero to closed |
| closed, with a session | **Resume** · Play · ⋯ | Boots the game and puts the session back in during the boot | Play: boots from the in-game save |
| closed, no session | **Play** · ⋯ | Boots from the in-game save | — |

A **session** is the `stateauto:<game>` snapshot, taken when the game is
left (Main Menu, a switch, a close, the tab hidden or closed). It counts
only while the stored save is the one it was taken with (`saveSig`,
`resumeSessionFor`): a game that has saved since boots from that save, so a
snapshot can never roll a save back. The page reloaded, the hero is closed.

## Opening a game from a tile

Settings → Controls → *Opening a game from the library* (`library-open`):

- **Resume** (default): as the hero's Resume, where a session still counts.
- **From save**: boots from the in-game save, then offers the session in a
  toast (*Last session saved … Resume*).

Either way, the top bar's reset, or closing the game and choosing Play,
boots from the save. A file dropped on the page always boots from the save
and offers the session.

## Pictures

- `frame:<game>` is the library's picture: the last screen stored (a slow
  tick while running, every pause, close and switch). Mirrored on Drive, so
  it may be another device's.
- `sessionpic:<game>` = `{ ts, blob }` is the session's own picture, written
  after the snapshot and stamped with its `ts`. It counts only while its
  `ts` is the snapshot's. Local only, in the session group of
  `perGameKeys`, so it moves and goes with the snapshot.

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

## Account

The bar's account slot (`#account-slot`, home screen only, not in the empty
state). Signed out: a dim outline of a person; it opens a menu holding
Google's own button (`google-signin-dark.svg` / `-light.svg`, from Google's
sign-in assets, unaltered). Signed in: the email's initial with a sync
badge (a tick, a turning ring, an amber mark); its menu has the sync status,
Sync now, Drive settings and Sign out.
