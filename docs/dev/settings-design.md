# Settings design (iOS first, web next)

The design for the native-style Settings rework and the Supporter unlock. The boards live on the
design canvas (https://claude.ai/artifact/1MGcSNnpoSG3hDs1jxJpC4, page "Settings system"); this
file is the part code needs. Status: proposal. iOS on branch `worktree-supporter-unlock` still has
the older look.

## One schema, two renderers

Every pane is data: a list of sections, each with an optional header and footer and a list of
typed rows. SwiftUI and the web each have ONE renderer for these; a pane never lays out rows by
hand. Adding a setting is one entry per platform, and the platforms stay in step because the
entries match.

```
Pane     { id, title, back?, sections: [Section] }
Section  { header?, footer?, rows: [Row] }
Row      = nav      { label, value?, tile?, image?, badge?, locked?, to }
         | toggle   { label, binding, badge?, disabled?, locked? }
         | segmented{ label, options: [label], binding }          // 2-4 short options
         | menu     { label, options: [{label, locked?}], binding } // 5+, or long names
         | check    { label, sub?, swatch?, selected, locked? }     // one of a list, with descriptions
         | file     { label, value }                               // menu: Choose File…, Remove
         | button   { label, role: normal | destructive }
         | info     { label, value, keycap? }
         | banner | themeGallery | colorWells                      // the three one-offs
```

`locked` rows render the Supporter lock and open the Supporter sheet on that item's card instead
of acting. A row's visibility (`when`) is part of its entry, e.g. Joystick behavior only while
Direction is Joystick.

## Rules

- Words: a row is a label plus at most one short line. Prefer a name that explains itself
  ("Reproduce motion blur", "Separate light-mode theme", "DS support") over a footer; a footer only
  when no name can carry it, one short sentence. Empty file slots read "None", which already says
  optional.
- A check row always reserves its trailing slot (check, lock or empty) so swatches and values line
  up down the list.
- Choices: 2-4 short options → segmented; 5+ or long names → menu showing the value; options that
  need a description → check list.
- Paid things are shown in place, locked: the lock takes the place of the switch or the arrow. Never hidden, never a banner inside a pane. The only
  upsell surfaces are the banner at the top of Settings and the locked item itself.
- Free baseline: Night theme and the Night Flyer icon. Advanced features (Save webhook, DS
  support) are Supporter too: locked rows in General, and the Nintendo DS row appears only once
  DS support is on. No light theme or appearance matching for
  free users.
- Switches and checks use the theme accent. Icon tiles have fixed hues on every theme.
- Navigation: Settings has a large title and Close; panes an inline title and Back. From 700 pt
  wide (iPad, web desktop) it is a sidebar plus detail. The up/down section stepper goes; a
  controller steps sections with LB/RB.
- Controller: a 2 pt accent ring on the focused row; A acts, B goes back.
- Destructive actions use the system confirmation (action sheet / dialog), not arm-then-tap.
- A row that only matters for one choice appears with it; a row whose dependency is directly above
  it stays visible but disabled.
- One warning badge: "Highly experimental" (amber) on General › DS support, "Experimental" on the
  Nintendo DS row. Nothing else carries a badge. The pink Supporter pill only on the banner and in
  the sheet.

## Decided (2026-11-19)

- No grandfathering: paid extras lock on the update (one user today).
- The web is fully free: no locks, no banner, and no Support link until it has a destination.
- Holiday icons default off.
- Prices $2.99 / $4.99 / $9.99, all three non-consumable and unlocking the same thing, $4.99
  preselected.

## The web

Same schema, map and words; the renderer takes a platform and swaps the skin, not the structure:

- Density: 44 px rows, 15 px body, 12.5 px footers, 12 px radius groups with a hairline border,
  sentence-case section headers, 24 px icon tiles.
- Desktop: a dialog (about 940 × 640) with a sidebar of sections; Esc closes; each pane has a URL
  (`#settings/audio`) so Back and links work.
- Phone browsers: one pane at a time under a plain page header ("‹ Settings"), no glass buttons.
- Real controls: `<button>`, `<select>` for menus, `role="switch"` checkboxes, radio groups for
  segmented; hover states and `:focus-visible` rings; the controller ring stays for gamepads.
- Tokens: the same roles, mapped onto the web's existing `:root[data-theme]` custom properties.

## Map

| Pane | Sections → rows |
|---|---|
| Settings | Supporter banner · Display & Appearance, Controls, Audio · Play, Game Boy, Game Boy Advance, Nintendo DS (DS Beta) · Google Drive, General · version |
| Display & Appearance | Theme: gallery, (Supporter: Separate light-mode theme, Light-mode theme), App Icon · Game screen: Color correction, Filter (menu; hq4x/xBR locked), Integer scaling, Reproduce motion blur, Ambient glow, (Duo: Picture held upright) |
| Controls | Touch: Large controls, Direction (seg), Joystick behavior (seg, when Joystick), Buttons in landscape (seg, phone), Hide with a controller · Feedback: Rumble, Haptic feedback, Show inputs on screen · Controller and keyboard: Controller buttons ›, Keyboard › (while connected) |
| Controller buttons | info rows with keycaps: game buttons, while playing, in menus |
| Audio | Playback: Pitch-correct fast-forward, Play in Silent Mode · GBA sound: Interpolation, Analog filter, Enhanced music synthesis · Channels › |
| Channels | Tone: Square 1, Square 2, Wave, Noise · Samples: Sample A, Sample B · Turn All Channels On |
| Play | Opening a game: Resume / From save (check) · Rewind · Response: Run-ahead (seg Off 1 2 3) |
| Game Boy | Palette: Default / App theme / Custom (check with swatches; Custom locked) + color wells when Custom · Super Game Boy: mode, Show border · Boot ROM: file |
| Game Boy Advance | BIOS: file, Play BIOS intro · BIOS calls: HLE / Real BIOS / Real boot, HLE calls (check) |
| Nintendo DS | Screens: Layout (menu), Bottom screen first, Gap (menu), Turn (menu), Hide the top bar (phone) · 3D: Resolution (seg), Drawn by (menu) · BIOS and firmware: three files |
| Google Drive | account (email, last sync), Sync Now · Sign Out, Sign Out Everywhere (destructive) |
| General | Advanced (Supporter): Save webhook ›, DS support (Highly experimental) · About: Version, Acknowledgements, Privacy · Reset All Settings (destructive) |

## Tokens

Rows name roles, never colors. Each theme supplies: `bg, group, separator, pressed, label,
secondary, value, chevron, accent, accentInk, trackOn, trackOff, destructive, segTrack, segOn,
glass, glassEdge, lockGlyph, badgeBg`. iOS: fields on `Palette` (Theme.swift); web: `--settings-*`
custom properties per `:root[data-theme]`.

| Measure | Value |
|---|---|
| Row min height | 52 (grows with Dynamic Type) |
| Row padding | 16 each side |
| Group radius | 26 |
| Page margin | 16 |
| Icon tile | 30, radius 8, white glyph |
| Separator inset | 16, or 60 past a tile/image |
| Header→group, group→footer | 7 |
| Between sections | 26 (22 without a header) |
| Switch | 51 × 31 |
| Segmented | 34 high, capsule |
| Touch target | ≥ 44 |

Type: Large title 34 bold, Headline 17 semibold, Body 17, Subhead 15, Footnote 13, Caption 12;
the system font (Dynamic Type styles on iOS, `system-ui` on the web).
