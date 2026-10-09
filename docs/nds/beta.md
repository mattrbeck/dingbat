# DS Beta

DS games are on main behind one switch per device, **Settings > General >
Advanced > DS Beta**, off by default, on the web, in the iOS app and on the
desktop. Off, each front end is what it was before the DS core; on, `.nds`
games load and play.

| | Off (default) | On |
|---|---|---|
| Opening a `.nds` (picker, drop, zip, Files / Open in, command line) | refused as any unknown file, with the old message ("Load a .gba, .gb, or .gbc ROM"); the desktop's command line and Recent hand it to the GBA core, as before | loads on the DS core |
| `.dsv` saves | refused as an unknown file | imported (the footer dropped) |
| DS games already in the library | not shown; their files, saves and states stay | shown |
| A DS game running when it goes off | closed, its save flushed | -- |
| Settings | no Nintendo DS section, no X/Y (DS) key rows, no DS shortcut rows | all of them |
| Drive | DS games never sync, either way (docs/nds/web.md) | |

Where it is kept: web `localStorage["ds-beta"]` (`dsBetaOn`, `applyDsBeta`
in `web/index.js`; `body.ds-beta` shows `.ds-beta-only`); iOS
`UserDefaults["dsBeta"]` (`Settings.dsBeta`); desktop the settings file's
`nds:` section (docs/nds/desktop.md). Reset all settings turns it off.

The iOS app no longer registers `.nds` and `.dsv` as document types, so
Files does not offer the app for them whatever the switch (the `.nds` type
stays declared for the in-app picker).

What was checked to be unchanged with the switch off, against main
(dc1b85d0, 2026-10-09):

- The web app, pixel for pixel, at desktop (1280x800), phone upright
  (390x844) and sideways (844x390) and tablet (1024x1366) sizes: home
  (empty, 1-10 games, chips, sort, tile menus), GBA/GB/SGB play under every
  filter and colour correction, the touch controls' and bar buttons' boxes,
  the menu, every Settings section, Rewind to a Moment, Report a Bug. The
  one difference is the DS Beta row at the end of General > Advanced. The
  requests match except two small scripts (`nds/ndsutil.js`,
  `nds/ndsaudio.js`); the DS core is never fetched.
- The iOS app on an iPhone and an iPad, upright and sideways: library,
  GBA/GB play with the menu, Settings, the Rewind and Report a Bug sheets.
  Again only the DS Beta row differs.
- GB/GBC/GBA emulation: 717 ROMs (the committed test ROMs, 14 GB/GBC carts
  and 483 GBA games covering every save chip), 2000 frames under two input
  scripts with the RTC held: frames, state payloads and images, save chips
  and the written `.sav` files identical (179 games wrote saves).
- The desktop settings file byte for byte (defaults, everything changed, a
  main-written file re-saved).
