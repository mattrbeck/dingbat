# Web UI redesign — implementation units

**Read this instead of `ui-redesign-spec.md` if you are implementing.** The
older file is prose and left decisions unmade; four separate rounds of device
testing found gaps in it. This file is the same design expressed as **20
independent units**, each small enough to implement and verify in one sitting.

## How to use this

- Do **one unit at a time**. Each has *Scope*, *Exact values*, *Every state*,
  *Acceptance*, and *Do not break*.
- **If a unit does not say what to do in some case, stop and ask.** Do not
  infer. Every gap found so far came from an agent reasonably filling a silence
  I left.
- `§0` of `ui-redesign-spec.md` (the Do-not-break table) still governs
  everything. Re-read it before each unit that touches its surfaces.
- Never edit a test to make a change pass. A test here is the record of a
  decision.
- Never push. Never edit `web/em.js`, `web/em.wasm`, `web/types/em.d.ts`.

## Vocabulary used below

| term | meaning |
|---|---|
| **phone** | `pointer: coarse` **and** `max-width: 759px` |
| **desktop** | everything else |
| **home** | `#home` visible — no game running, or a game paused and returned to |
| **in game** | `body.running` and `#home` not visible |
| **n** | number of games in the library |
| ladder | 32 dense · 36 default · 44 touch/primary · 50 mobile CTA |
| radii | 8 controls · 12 cards · 18 sheets · 999 pills |

---

# A. Foundations — no visual identity change

## Unit 1 — the focus ring

**Scope.** `web/styles.css` only.

**Exact.** Add `--ring-gap` to `:root`, default `var(--surface-1)`. One rule:

```css
:where(button, [role="button"], a, input, select, summary):focus-visible {
  outline: none;
  box-shadow: 0 0 0 2px var(--ring-gap), 0 0 0 4px var(--accent);
}
```

Override `--ring-gap` per surface: `#stage`/`#home` → `var(--bg)`; inside
`.modal`, `.psheet` → `var(--surface-1)`; inside a `.card`/tile →
`var(--surface-2)`.

**Every state.** Delete the seven existing ring rules
(`.toast-action`, `.toast-close`, `.state-slot`, `.dual-range-knob`,
`.vol-range`, `.report-slider`, `.settings-tab` and its group).
**Keep** `#canvas:focus { outline: none }` — it is a script-focus parking spot.
**Keep** the switch's own ring (its `<input>` is 0×0) and the dual-range knobs'
(both inputs share one 44px box) — these two cannot use the shared rule.

**Acceptance.** Tab through: top bar, library bar, a tile, hero buttons, menu
rows, settings rows, modal buttons. Every one shows the same two-tone ring, and
the inner gap matches the surface behind it. `chrome-focus.test.mjs` passes.

**Do not break.** `#canvas:focus`.

---

## Unit 2 — the type ramp

**Scope.** `web/styles.css`.

**Exact.** Six tokens, and **every** `font-size` in the file becomes one of them:

```css
--fs-caps: 12px;    /* + font-family: var(--font-mono); letter-spacing: .1em;
                       text-transform: uppercase */
--fs-meta: 13px;
--fs-body: 14px;
--fs-title: 16px;
--fs-section: 20px;  /* font-weight: 650; letter-spacing: -.01em */
--fs-display: 28px;  /* font-weight: 700; letter-spacing: -.02em */
```

`--font-ui` leads with `system-ui`, then `-apple-system`, `"Segoe UI"`, …

Add `font-variant-numeric: tabular-nums` to: `#fps`, `#storage-info`,
`.lib-count`, `.states-meta`, `.cheats-meta`, `#clip-estimate`, and every
`.mono` readout.

**Every state.** There is **no** exception below 12px, including the system
chip (was 9px) and `SELECT`/`START` (was 11px). Half-pixel sizes (11.5, 12.5,
13.5) are deleted, not rounded — pick the nearest token.

**Acceptance.** `grep -oE 'font-size: *[0-9.]+px' web/styles.css | sort -u`
returns nothing outside the six token values. No `11.5`, `12.5`, `13.5` anywhere.

---

## Unit 3 — forced colors

**Scope.** `web/styles.css`, one new `@media` block at the end. No other file.

**Exact.** See `ui-redesign-spec.md` §3 "Forced colors" for the block verbatim.

**Acceptance.** In Chromium DevTools → Rendering → *Emulate forced-colors:
active*, every button still has a visible boundary, the active/selected state is
distinguishable, and the focus ring is `Highlight`.

---

## Unit 4 — the control ladder

**Scope.** `web/styles.css`.

**Exact.** Four tokens — `--ctl-dense: 32px`, `--ctl: 36px`, `--ctl-touch: 44px`,
`--ctl-cta: 50px`. Every control sets `height`, never vertical padding.

Map: `.button` → `--ctl`; `.button-sm` → `--ctl-dense`; `.icon-btn` → `--ctl`;
`.choice-chip` → `--ctl-dense` (desktop) / `--ctl` (coarse);
`.button-primary` → `--ctl-touch`; the one full-width mobile CTA → `--ctl-cta`.

**Gradient is reserved** for `.button-primary` and `.pad-btn`. Every other
control becomes a flat `rgba(255,255,255,.045)` fill with a transparent border,
hover `.09`, active `.14`.

**Acceptance.** No control's height comes from padding. `modals.test.mjs`,
`cart-enable.test.mjs` pass.

---

## Unit 5 — touch targets

**Scope.** `web/styles.css`.

**Exact.**

```css
.pad-pill { position: relative; }
.pad-pill::before {
  content: ""; position: absolute; left: 0; right: 0;
  top: calc((100% - 44px) / 2); bottom: calc((100% - 44px) / 2);
}
```

The `calc` form (not `-6px`) so the reach is 44 at **all three** painted
heights: 34 default, 28 short-portrait, 24 if unit 14 lands.

Same treatment for any action-bearing text link that survives.

**Acceptance.** In DevTools, the pill's hit box measures ≥44px tall at 390 and
at 320. **The painted pill does not change size**, and the stage loses no pixels.

---

# B. Chrome

## Unit 6 — the top bar

**Scope.** `web/index.html` bar markup, `web/styles.css`, the JS that toggles
bar children.

**Exact.** `--bar-h` is `52px` desktop, `44px` phone. Keep
`height: calc(var(--bar-h) + var(--safe-t))` and `padding-top: var(--safe-t)`.

**Every state.** This table is complete. Anything not listed is not in the bar.

| control | desktop home | desktop in game | phone home | phone in game |
|---|---|---|---|---|
| `#menu-btn` (game menu) | — | yes | — | yes |
| logo mark + wordmark | yes, **centred** | yes, **centred** | yes, left | — |
| `#playback-controls` | — | yes | — | yes, fused |
| cart (`#tilt-recenter`, `#cam-flip`) | — | if cart loaded | — | if cart loaded |
| `#rb-disconnect` | — | if linked | — | if linked |
| `#fps` | yes | yes | — | — |
| `#update-btn` | if update | if update | dot only | dot only |
| `#hle-indicator` | if HLE | if HLE | if HLE | **≥390 only** |
| `#volume-control` | yes | yes | yes | yes |
| account control | **yes** | — | — | — |
| settings | yes | yes | **yes** | **yes** |
| fullscreen | yes | yes | **—** | **—** |

Three decisions that were previously wrong, stated plainly:

1. **Settings is in the bar on every screen.** It is the only route on the home
   screen — the hamburger is the *game* menu and does not exist there. It also
   stays a row in the game menu, as today. Two entry points is normal; zero is
   what shipped.
2. **Fullscreen is removed from phones**, both platforms. iOS Safari has no
   fullscreen for non-video; on Android it duplicates the browser's own
   chrome-hiding. Its 36px is what pays for Settings.
3. **The wordmark is centred on desktop**, absolutely positioned against the
   bar so the transport appearing cannot shift it. On phones it is left-aligned
   on home and **absent in game**.

**Budget — phone in game at 320, everything present.** Reproduce this
arithmetic in a comment and check it in DevTools:

```
 12  padding 6 + 6
 34  menu
144  transport 5×28 + 4 borders
 34  cart
 68  mute 34 + settings 34
 20  gaps 5×4
───
312  against 320  →  8px spare
```

**Acceptance.** At 320 and 390, in game, with a tilt cart loaded and an update
pending: nothing overflows, `#topbar.scrollWidth === clientWidth`. On desktop,
the wordmark's centre is within 1px of the bar's centre with and without the
transport.

**Do not break.** The `max-width: 480px` fused-segment block. `#topbar-handle`.
`aria-expanded` on `#menu-btn`.

---

## Unit 7 — `[hidden]` guards

**Scope.** `web/styles.css`.

**Exact.** For **every** element the JS toggles via `.hidden`, if its selector
sets `display`, it needs `[hidden] { display: none }`. Enumerate with
`grep -n '\.hidden = ' web/index.js`, then check each element's rules.

**Acceptance.** On a cold home screen with no game, none of `#clip-banner`,
`#net-stall`, `#update-btn`, `#hle-indicator`, `#sync-indicator`, `#open-prints`
is visible.

---

# C. Home

## Unit 8 — home becomes an overlay

**Scope.** `web/styles.css`, `web/index.js`.

**Exact.** `#home` keeps `position: absolute; inset: 0; z-index: 2` and a solid
`background: var(--bg)`. **Keep `body.running #home { display: none }`** — the
previous attempt to delete it painted the grid over the running game. Home is
shown by pausing to it, exactly as today.

`#home-inner` `max-width` 480px → **1200px**. Padding `26px 32px 0`.

**Every state.**

| | brand block | hero card | library region |
|---|---|---|---|
| n = 0, no game | yes, full size | — | empty card (unit 9) |
| n ≥ 1, no game paused | — | — | bar + grid |
| a game is paused | — | yes | bar + grid |

The brand block (logo 76 + wordmark `--fs-display` + tagline) renders **only**
when n = 0. The bar carries identity otherwise.

**Acceptance.** With a game paused, home shows: hero card, then library. No
duplicated wordmark anywhere. `#boot-progress` still appears above the grid
while the wasm loads.

---

## Unit 9 — the library region

**Scope.** `web/index.html`, `web/styles.css`, `web/index.js`.

**This unit is where two rounds of notes landed. It is fully enumerated.**

**Every state, by n:**

| n | the library region contains |
|---|---|
| **0** | **No bar at all.** The dashed `.home-empty` card: brand block, one sentence, one **Load a game** button (`--ctl-touch`, accent). Nothing else — no sign-in, no search. |
| **1–4** | `Library` label · count · *spacer* · **Manage** · **Add game**. **No chips, no search, no sort.** |
| **5+** | the above **plus** search, sort, and one chip per **system actually present**. |

- The count is `"12 files · 141 MB"` — **storage size lives inside the count**,
  not as a separate `#storage-info` element beside it. That stray element is
  what produced the odd box next to "11.7 MB used".
- Chips: `All` is always first and always present. Render a system chip **only
  if that system has ≥1 file** — never a GBC chip for a library with no GBC files.
- **The account control is not in this bar at any size.** It is in the top bar
  (unit 6).

**Desktop layout.** One row, `display: flex; align-items: center; gap: 11px`,
inside the 1200px column, `margin-bottom: 14px`.

**Phone layout — a column, never a row:**

```
row 1   Library · count · [spacer] · sort · Manage · Add
row 2   search, full width, 40px
row 3   chips
```

`position: sticky; top: calc(var(--bar-h) + var(--safe-t))` once the grid
scrolls under it.

**Chips must never wrap and never overflow:**

```css
.lib-chips {
  display: flex; flex-wrap: nowrap; gap: 7px;
  overflow-x: auto; scrollbar-width: none;
  -webkit-overflow-scrolling: touch; scroll-snap-type: x proximity;
}
.lib-chips > * { flex: 0 0 auto; scroll-snap-align: start; }
```

with a 34px fade at the right edge. This is note 1 from the last round.

**Grid.** Explicit columns: 6 at ≥1400, 5 at ≥1100, 4 at ≥900, **2 on phones**.
Gap 14px. Tile: `--radius` card, 3:2 thumb on `#000`, footer with filename
(`--fs-caps` mono, ellipsised, `min-width: 0`) and the system chip.

**Acceptance.**
- n = 1, desktop 1280: the bar shows only label, count, Manage, Add. Nothing
  sits far right above a lone tile — this was note 2.
- n = 1, phone 390: one row, nothing off screen.
- n = 12 with four systems, phone 320: chips scroll horizontally; the bar's
  `scrollWidth === clientWidth`; nothing wraps.
- n = 0: no bar renders at all.

**Do not break.** `homegrid.test.mjs`, `recents.test.mjs`,
`game-delete.test.mjs`, `remove-from-device.test.mjs`, `rename.test.mjs`.

---

## Unit 10 — the hero card

**Scope.** `web/index.html`, `web/styles.css`.

**Exact.** Replaces `#home-paused`. `--radius-lg`, `--surface-1`, `--border-2`.
Frame at **400×267** (≥1400), 330×220 (≥1100), 260×173 (<1100), full width on
phone. Contents in order: "Where you left off" (`--fs-caps`, accent), filename
(`--fs-section`, mono), meta line (system · size · last played), then actions.

**Actions — all four on the same rung.** `--ctl-touch` (44px). Resume keeps the
accent gradient; **Save states**, **Close game** and the `···` menu button are
flat neutral. Emphasis is fill and colour, never size — a 44 next to a 36 reads
as an oversight, which is exactly how it read.

The `···` button: `width: var(--ctl-touch); padding: 0`, and
**`.button svg { flex: 0 0 auto }`** — an SVG flex item inside a `<button>`
flex container is shrunk to ~2px by Chromium otherwise, which is why it
rendered empty.

**Acceptance.** All four action controls measure 44px tall. The `···` glyph is
visible and 18px. Clicking it opens the game menu (unit 12).

---

# D. Account and the game menu

## Unit 11 — account and sync

**Scope.** `web/index.html`, `web/index.js`, `web/styles.css`.

**Exact.** Do **not** widen `GDRIVE_SCOPE`. It is
`"…/auth/drive.appdata email"` — email only, no name, no picture.

One control, **in the top bar, on the home screen only** (unit 6). Label is the
word **"Account"**, never an initial derived from the address.

| state | label | indicator |
|---|---|---|
| signed out | "Sign in" + person glyph | — |
| `idle` | "Account" | none |
| `syncing` | "Account" | 13px ring, `--accent` |
| `done` | "Account" | 8px dot `--accent`, **momentary** |
| `offline` | "Account" | 8px dot `--text-faint` |
| `paused` | "Account" | 8px dot **`--warn`** |

`paused` must not use `--accent`: a green "needs you" beside a green "synced"
says nothing.

Strings come from the existing `SYNC_WORDS` / `SYNC_DESCS`. Do not rewrite them.

Panel (popover desktop / sheet phone): `Signed in · <email>` — Sync now (with
"4 min ago") — Games on Drive (count) — Disconnect Drive.

**Do not break.** `home-signin.test.mjs` pins that clicking Sign in calls
`gdriveConnect` **synchronously**, so the signed-out control signs in directly
rather than opening the panel. `sync.test.mjs`, `driveauth.test.mjs`.
"Paused" is not signed out. "Synced" is momentary.

---

## Unit 12 — the game menu

**Scope.** `web/index.html`, `web/index.js`, `web/styles.css`.

**Exact.** One component. The in-game `#menu-btn` and the hero card's `···`
open the same menu — popover on desktop, bottom sheet on phone.

Order (this is the shipped order in `index.html`):

```
┌ Quick Save          Quick Load            ┐  2×2 grid, first
└ Rewind to a Moment  Slow Motion           ┘
  Library                                       ← was "Main Menu"
  ───────────────────────────────────────
  Save States                      3 USED
  Manage Saves                          ›
  Capture                               ›       ← Screenshot, Record,
  ───────────────────────────────────────         Clip that!, Printed Photos
  Link Cable                            ›
  Cheats                            2 ON
  Report a Bug                          ›
  ───────────────────────────────────────
  Settings                              ›
```

- **Quick actions first.** They are what you reach for without reading.
- **No section labels** — hairline separators only. A label asserts a scope, and
  "App" asserted a false one for Report a Bug, which is game-scoped (it attaches
  a save state from the moment things went wrong).
- **No ROM name in the desktop popover.** It is 296px over a game you can see.
  The phone sheet keeps it in the header, because there the sheet covers most
  of the screen.
- Icons come from `index.html` verbatim — the film strip, the snail, the star,
  the link connector, the toothed cog.

**Do not break.** Capture folds on every fresh open. The printed-photos row is
conditional and carries the dot trail — see `§0`.

---

## Unit 13 — one bottom-sheet gesture

**Scope.** `web/index.js`, `web/styles.css`.

**Exact.** Factor the settings sheet's drag/detent/spring-back into
`attachSheetGestures(frame, { isSheet, chrome, scrollers, onClose })` and use it
for **both** the settings sheet and the game-menu sheet. Do not write a second
implementation.

Must support: drag-to-dismiss, spring-back on an abandoned drag, swipe-up to the
second detent, **tap outside to close**, and pointer capture at commit.

Two bugs the original had with a mouse (touch masks them): a release above the
sheet never ended the drag, and a drag that moved still fired a click on the
common ancestor. Both must be fixed in the shared code.

**Acceptance.** With a real mouse in headless Chromium: drag down 40px and
release → springs back; drag down 200px → dismisses; release outside the sheet
→ drag ends; tap the backdrop → closes, and **does not** also slide the top bar.

---

# E. Mobile

## Unit 14 — the phone budget

**Scope.** `web/styles.css`.

**Exact.** Two changes, both free:

1. `--bar-h: 44px` on `pointer: coarse` (from 52). **+8px of stage.**
2. `#fps` removed from the phone bar. It is `aria-hidden` decoration, and its
   ~24px is what makes the cart button fit at 320.

**Optional third**, only if the SE-1 still letterboxes: `.pad-pill` painted
height 28 → 24 in the short-portrait block. The hit area stays 44 via unit 5.

**The budget.** SE 1, 320×568, iOS 15, standalone, GBC needs **288px**:

```
548  viewport less the 20pt status bar
-44  top bar (was 52)
-207 control strip (L/R already dropped by body.gb-mode)
────
297  stage  →  +9 against 288
```

Knobs in reserve, cheapest first: strip `gap` 10→8 (+2), `padding-top` 10→8
(+2), `padding-bottom` 12→10 (+2), d-pad `min(46vw,240px)`→`44vw` (+6, **last
resort** — it is the thing you hold).

**The d-pad, A/B and the gutters do not change.**

**Do not break.** `body.gb-mode` drops the L/R row **and** its grid track.

---

## Unit 15 — portrait bar dismiss

**Scope.** `web/index.js`, `web/styles.css`.

**Exact.** Extend the existing `#topbar-handle` mechanism from landscape to
portrait: tapping the game picture slides the bar off; the handle pulls it back.
Reuse the landscape code path; do not write a second one.

**Acceptance.** Tapping the stage in portrait hides the bar and gains 44px.
Tapping the backdrop of an open sheet closes the sheet and does **not** also
slide the bar.

---

## Unit 16 — the settings sheet

**Scope.** `web/index.html`, `web/styles.css`.

**Exact.** Keep the shipped structure: fixed frame, exactly one scroller
(`.settings-scroll`), the `min(88dvh, 714px)` cap, and the ~108px under the last
row — the source comment says it is deliberate, and it is.

Change only the row system: 64px rows, `--fs-title` titles, `--fs-meta`
descriptions, grouped into `--radius` cards. **Same six sections, same order.**
**No "this game / app" split** — it fences the user out of the other console's
settings for no reason.

Add one group at the end, *About & support*: Printed Photos (**conditional**,
unit 17) and Report a Bug.

---

# F. Content

## Unit 17 — printed photos

**Read `§0` of `ui-redesign-spec.md` first. This unit has been broken once.**

**Scope.** `web/index.js`, `web/styles.css`.

**Exact.** Primary route unchanged: **Capture → Printed Photos** in the game
menu, `hidden` until `printerPhotos.length > 0`, with the three-dot trail on
`#menu-btn`, `#capture-toggle`, `#open-prints`.

Add **one** secondary route: a Printed Photos row in Settings → About & support,
shown **only when `printerPhotos.length > 0`**, which must **not** set
`everOpenedFromMenu`.

**Acceptance.** `print-indicator.test.mjs` passes unchanged — 9 assertions.

---

## Unit 18 — the last frame

**Scope.** `web/index.js`.

**Exact.** Reuse the `getRomArt(romName)` pattern — a Blob in its own record.
Capture at pause, close, save-state (reuse the slot-thumbnail path), and a
debounced ~60s tick that skips an unchanged frame. 2× native, JPEG q0.72
(~19 KB per GBA capture).

**Precedence in the tile:** user box art → last frame → system chip. A game
never opened has no frame and **must not** get an invented one.

**Do not break.** `game-delete.test.mjs` pins the `perGameKeys` inventory
exactly. Either delete the frame record explicitly alongside `art:` in evict,
delete, remove-from-device, both renames and the orphan sweep — or add it to the
inventory **and** update that test in the same commit. Do not add it to the
inventory silently.

---

## Unit 19 — filters

**Scope.** `web/index.js`.

**Exact.** Filter on what the app can answer: system (`systemOf()`, a three-way
branch on the extension), filename substring, size, last played, and whether a
stored frame exists ("in progress"). **Not** title, genre, region or year —
there is no database.

Filtering **dims in place** (30% for the transition, then removed) rather than
reflowing, so the eye tracks what survived. `prefers-reduced-motion` skips
straight to the filtered grid.

Search matches **filenames**; say so in the placeholder. The empty state names
that limit: *"Search looks at filenames. `MinishCap.gba` will not match
'zelda'"* — and offers Rename there.

---

## Unit 20 — the palette

**Do this last.** It is the only unit that changes the identity, and nothing
depends on it.

**Scope.** `web/styles.css` `:root` only, plus the `theme-color` meta and the
boot-hint map in `web/index.html`.

**Exact.** The full token block is in `ui-redesign-spec.md` §1. Key values:
`--bg: #120a17`, `--stage: #0a0510`, `--surface-1: #1c1226`,
`--accent: #a8b46a`, `--accent-ink: #13160c`, `--warn: #e0a33f`,
badges `#6fc8c0` / `#7fb2f0` / `#c09bea`. `theme-color` → `#170e21`.

**Do not break.** The ten `[data-theme]` blocks override `:root` wholesale and
**must not change**. Verify with
`git diff -- web/styles.css | grep -c '^-.*data-theme'` → must be `0`.

**Known follow-up, not part of this unit.** `GB_THEME_PALETTES.amber` — the
"Match app theme" GB palette — is still amber-derived and will mismatch. Fixing
it needs a hardcoded `"#ffb04d"` updated in `gb-palette.test.mjs`, so it is a
separate decision.
