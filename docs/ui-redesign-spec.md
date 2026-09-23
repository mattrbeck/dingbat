# Web UI redesign — implementation spec

Companion to the design canvas. Every value here is either lifted from
`web/styles.css` / `web/index.html` as it stands, or is a proposed change
stated against the value it replaces. Where a number is proposed, the
current number is given so the diff is checkable.

**Read `##0 Do not break` before touching anything.** It lists behaviour
that exists only in JS and test files and is invisible from the markup.

---

## 0. Do not break

These are load-bearing behaviours with no visual trace. Each has a test or
a long comment explaining why. Preserve them exactly.

| Behaviour | Where | Rule |
|---|---|---|
| Printed-photos row is conditional | `index.js` `refreshPrintsMenuItem` | `printsItem.hidden = printerPhotos.length === 0`. The row appears on the first print and disappears when the last photo is deleted. |
| New-photo dot trail | `index.js` "New-photo indicator", `tests/print-indicator.test.mjs` | Three dots: `#menu-btn`, `#capture-toggle`, `#open-prints`. Each clears **only** when its own element is used. |
| Toast "View" is conditional | same | If `everOpenedFromMenu` is false, View shows the photo and clears **nothing**. If true, it clears all three. |
| Only the menu row sets the flag | same | Not the toast, and **not** the new Settings route (§6.4). |
| Dots + flag survive reload | same | Persisted; a half-walked trail stays half-walked. |
| GB/GBC drops the shoulder row | `styles.css` `body.gb-mode #lr` | Row **and** its grid track (`grid-template-rows: 1fr auto`). Do not reintroduce a 0px track. |
| Capture folds on every menu open | `index.js` `menuBtn` click → `collapseCaptureSub()` | A fresh open always starts collapsed. |
| `aria-expanded` mirrors the dropdown | `index.js` MutationObserver on `#menu-dropdown[hidden]` | Set wherever the menu is closed, not just by the button. |
| Menu scroll hint | `updateMenuScrollHint` → `.can-scroll-down` | Re-checked on open, scroll and resize. `scrollHeight` reads 0 while hidden. |
| Rewind double-tap | `index.js` `RW_TAP_MAX_MS 250`, `RW_DBLTAP_MS 300`, `RW_DBLTAP_SLOP 28` | Pointer events only — `dblclick` is dead code here on every engine. |
| Undo toasts | `showActionToast` | Four: State loaded→Undo (6s), Rewound→Undo (8s), Game reset→Undo, Last session saved→Resume. |
| Cart buttons | `#tilt-recenter`, `#cam-flip` | Conditional top-bar controls with two states each (`needs-enable` / on) and a label. **They must fit at 320px.** |
| Persist prompt asks once | `requestPersistentStorage` | At most once per session, tied to a data-entrusting moment. |
| Canvas focus draws no ring | `#canvas:focus { outline: none }` | It is a script-focus parking spot, never navigated to. |
| Drive "paused" is not signed out | `SYNC_DESCS.paused` | Out of token keeps the account, library and queue. Never revert the UI to "Sign in". |
| "Synced" is momentary | `setSyncStatus` | Times out. Never a permanent badge. |

---

## 1. Theme tokens — `:root`

Replaces the amber/indigo default. The other ten themes override `:root`
wholesale and **do not change**. Keep every `*-rgb` triplet in step with
the solid it mirrors — the file's own rule.

```css
:root {
  /* ---- Base surfaces ---- */
  --bg: #120a17;
  --stage: #0a0510;
  --surface-1: #1c1226;
  --surface-2: #261932;
  --surface-3: #32223f;
  --surface-hover: #3c2a4a;

  /* ---- RGB triplets for rgba() compositing ---- */
  --hi-rgb: 255, 255, 255;
  --accent-rgb: 168, 180, 106;      /* == --accent */
  --accent-hi-rgb: 201, 209, 155;   /* == --accent-hi */
  --danger-rgb: 255, 107, 107;
  --text-rgb: 239, 233, 243;
  --stage-rgb: 10, 5, 16;
  --surface-1-rgb: 28, 18, 38;

  /* ---- Hairlines ---- */
  --border:   rgba(var(--hi-rgb), 0.09);
  --border-2: rgba(var(--hi-rgb), 0.16);
  --inset-hi: rgba(var(--hi-rgb), 0.09);
  --inset-lo: rgba(0, 0, 0, 0.45);

  /* ---- Text ---- */
  --text:       #efe9f3;
  --text-dim:   #aca2b9;
  --text-faint: #8d8399;

  /* ---- Accent: the logo's green, toned ---- */
  --accent:     #a8b46a;   /* logo wing is #bbc943 — accent sits below it */
  --accent-2:   #bcc684;
  --accent-hi:  #c9d19b;
  --accent-ink: #13160c;
  --accent-glow: rgba(var(--accent-rgb), 0.32);

  /* ---- Status. Deliberately NOT the accent. ---- */
  --warn:   #e0a33f;   /* sync "paused" only */
  --danger: #ff6b6b;
  /* --live is retired: success is momentary and needs no colour. */

  /* ---- Chrome gradients ---- */
  --topbar-top: #211534;
  --topbar-bottom: #170e21;
  --surface-2-lo: #21152c;
  --stage-top: #100819;
  --control-strip-top: #150c1d;

  /* ---- Amber-tinted → accent-tinted fills ---- */
  --accent-tint-top: #242a12;
  --btn-active-bottom: #181c0a;
  --pad-pressed-bottom: #141806;

  /* ---- System badges: cool hues, clear of a yellow-green accent ---- */
  --badge-gb-fg:  #6fc8c0;  --badge-gb-bg:  rgba(111, 200, 192, 0.15);
  --badge-gbc-fg: #7fb2f0;  --badge-gbc-bg: rgba(127, 178, 240, 0.15);
  --badge-gba-fg: #c09bea;  --badge-gba-bg: rgba(192, 155, 234, 0.15);

  /* ---- Radii: three plus the pill. No literals anywhere else. ---- */
  --radius-sm: 8px;    /* controls */
  --radius:    12px;   /* cards */
  --radius-lg: 18px;   /* sheets, modals */
  /* 999px for pills */

  /* ---- Focus ring ---- */
  --ring-gap: var(--surface-1);   /* set per surface; see §3 */
}
```

`<meta name="theme-color">` and the boot-hint map in `index.html` both
need `#170e21` (the top bar's foot) for the new default.

**Measured contrast**, default theme, all pass:

| pair | ratio |
|---|---|
| `--text` on `--bg` | 16.3 |
| `--text-dim` on `--surface-1` | 7.4 |
| `--text-faint` on `--surface-2` | 4.6 |
| `--accent` on `--surface-1` | 8.1 |
| `--accent-ink` on `--accent` | 8.2 |
| `--warn` on `--surface-1` | 8.2 |
| badges on `--surface-1` | 7.8–9.2 |

---

## 2. Type ramp

Six steps. Replaces **17** literal sizes (9 → 30px) currently in the file.

| step | size | use |
|---|---|---|
| caps | 12px mono, `letter-spacing: .1em`, uppercase | section labels, readouts, filenames |
| meta | 13px | secondary lines, row descriptions |
| body | 14px | default |
| title | 16px | row titles, modal headings |
| section | 20px, 650, `-.01em` | sheet titles, hero filename |
| display | 28px, 700, `-.02em` | the wordmark on first run |

Rules:
1. **Floor is 12px.** Nothing below it. 24 declarations are currently at or
   under 11.5px, including the 9px system chip and the 11px `SELECT`/`START`.
2. **No half-pixel steps.** Delete 11.5, 12.5, 13.5.
3. Lead the stack with `system-ui`, not `"Segoe UI"` — today Windows gets
   Segoe and macOS falls through to SF, two faces against one set of sizes.
4. `font-variant-numeric: tabular-nums` on every readout (fps, storage,
   timestamps, slot counts) so digits stop jittering.

---

## 3. Control ladder

Four heights, set by `height`, never by padding, so a label change can never
resize a control.

| rung | height | radius | use |
|---|---|---|---|
| dense | 32px | 8px | top bar, toolbars, library bar |
| default | 36px | 8px | icon buttons, menu rows |
| touch | 44px | 12px | anything a thumb touches; every primary action |
| CTA | 50px | 12px | the one full-width mobile primary |

Replaces nine classes at five heights (`.button` 32, `.button-sm` 25,
`.icon-btn` 36, fused segment 34, `.pad-pill` 34, `.choice-chip` 30, and
`.home-manage-link`, which has no box at all).

**Emphasis is fill and colour, never size.** Gradient is reserved for two
things: the primary action, and the physical touch pad. Everything else is
a flat translucent surface over the stage.

### Focus ring — one rule, replaces ten

```css
:where(button, [role="button"], a, input, select, summary):focus-visible {
  outline: none;
  box-shadow: 0 0 0 2px var(--ring-gap), 0 0 0 4px var(--accent);
}
```

Set `--ring-gap` on each surface (`--bg` on the stage, `--surface-1` inside
a modal, `--surface-2` inside a card) so the inner gap is always the colour
underneath. Delete the ten existing `:focus-visible` rules, which use two
different treatments. Keep `#canvas:focus { outline: none }`.

### Touch targets

Two controls sit under 44px painted. **Grow the hit area, not the button**:

```css
.pad-pill { position: relative; }        /* 34px painted (28 short-portrait) */
.pad-pill::before { content: ""; position: absolute; inset: -6px 0; }
```

Costs zero layout height, which matters because §7 has none to give.

### Forced colors — currently zero rules

```css
@media (forced-colors: active) {
  .button, .icon-btn, .menu-item, .choice-chip, .home-tile-launch {
    border: 1px solid ButtonBorder;
    background: ButtonFace;
    color: ButtonText;
  }
  .button-primary, .icon-btn.active, .choice-chip.selected {
    background: Highlight; color: HighlightText; border-color: Highlight;
  }
  :where(button, [role="button"], a, input, select):focus-visible {
    outline: 2px solid Highlight; outline-offset: 2px; box-shadow: none;
  }
}
```

Affordance today lives in `background`, which forced-colors replaces
wholesale — without this the whole control surface flattens into the page.

---

## 4. Top bar

**Rule: identity plus global chrome. Nothing game-scoped, nothing library-scoped.**

Height **44px** (from 52) on `pointer: coarse`; 52px stays on desktop.
`height: calc(var(--bar-h) + var(--safe-t))` and the `padding-top: var(--safe-t)`
are unchanged — that is what makes the bar's background run under the status bar.

Left → right, both platforms:

1. `#menu-btn` — **only while a game is loaded** (`body.has-game`). It is the
   game's menu; with no game its every item is meaningless.
2. Logo mark, 22px, `image-rendering: pixelated`.
3. Wordmark "dingbat", 13.5px/650. **Replaces the "Library" title.** Clickable
   → home on desktop (convention only, not the documented route).
4. `#playback-controls` — unchanged, fused segmented control on `max-width: 480px`.
5. Cart buttons `#tilt-recenter` / `#cam-flip` — unchanged, conditional.
6. `#topbar-spacer`.
7. `#fps` — **desktop only.** Remove from `pointer: coarse`; it is
   `aria-hidden` decoration and its ~24px is what makes (5) fit at 320px.
8. `#volume-control`.
9. **Account control** (new, §6) — replaces `#sync-indicator`, `#home-signin`
   and `#home-sync`.
10. Settings — the app's own gear from `#open-settings`, not a sliders glyph.
11. `#fullscreen-btn`.

Removed from the bar: the "Library" title, and "Load a game" (it is a library
action — §5).

`#update-btn`, `#hle-indicator`, `#clip-banner`, `#net-stall`, `#topbar-handle`
and `#toast` keep their current positions and behaviour.

### `#status` live region

Currently `aria-live="polite"` wrapping an `aria-hidden` `#fps` — announce-capable
and permanently silent. Keep `#fps` hidden; give the region real debounced text
for state changes: "Paused", "Fast forward 2×", "State saved to slot 3",
"Link cable disconnected".

---

## 5. Home screen

`body.running #home { display: none }` **is removed.** Home becomes an overlay
over a flat `--stage`; the paused game gets a hero card instead of a 240×160
thumbnail.

### Layout

- `#home-inner` `max-width: 480px` → **1200px**, still `margin: auto`.
  Padding `26px 32px 0`.
- The brand block (logo 76 + wordmark 30 + tagline) renders **only in the
  empty state**. The bar carries identity everywhere else.
- Order: hero card → library bar → grid.

### Hero card (replaces `#home-paused`)

`--radius-lg`, `--surface-2` → `--surface-1` gradient, `--border-2`.
Contains: the stored last frame at 400×267 (330 at ≤1180, 260 at ≤900),
"Where you left off" in caps, the filename at 21px mono, a meta line
(system · size · last played), then **Resume** (44px CTA), Save states,
Close game, and `···` — the game menu (§8).

### Library bar (new)

One component, **same position on both platforms**, directly above the grid.
Desktop: one row. Phone: three rows, and `position: sticky` under the bar.

`[Library] [count] [chips] — spacer — [search] [sort ▾] [Manage] [+ Add game]`

- Chips carry counts: `All 6 · GB 1 · GBC 1 · GBA 4`. `systemOf()` is a
  three-way branch on the extension, so this is free and exact.
- Search matches **filenames**. Say so in the placeholder.
- **Manage** = the existing "Manage ROMs and Saves" modal minus its Drive
  panel (§6). Needs its own glyph — a cartridge stack — not the settings gear.
- **Add game** replaces `#home-load`; it is the only Load affordance when the
  library is non-empty.
- The whole bar **collapses below 5 files**. A filter row must never be larger
  than the thing it filters.
- Filtering **dims in place** (30% for the transition, then removed) rather
  than reflowing. `prefers-reduced-motion` skips to the filtered grid.

### Grid

`repeat(auto-fill, minmax(210px, 1fr))` → an explicit column count:
6 at ≥1400, 5 at ≥1100, 4 at ≥900, 2 on phones. Gap 14px.

Tile: `--radius` card, 3:2 thumb on `#000`, footer with filename (12px mono,
ellipsised, `min-width: 0`) and the system chip at 12px (from 9px).

### Empty state

The existing dashed `.home-empty` card, doing more work: brand block, one
sentence, and a single **Load a game** CTA. **No sign-in button** — that is
the account control's job, and a Drive prompt on first run is a nag.
`#boot-progress` keeps its position above the grid.

---

## 6. Account and sync

Splits two things that are fused today: you currently sign into Google inside
a modal called "Manage ROMs and Saves".

### 6.1 Scope — do not widen it

`GDRIVE_SCOPE = "https://www.googleapis.com/auth/drive.appdata email"`.

Email **only**. No name, no picture. Do not add `profile`.
The control therefore reads **"Account"** — a word, not a derived initial.
The full email appears once, inside the panel.

### 6.2 The control

One 32px control in the bar, in every state, both platforms.

| state | control | indicator |
|---|---|---|
| signed out | "Sign in" + person glyph | — |
| `idle` | "Account" | none |
| `syncing` | "Account" | 13px ring, `--accent`, spinning |
| `done` | "Account" | 8px dot, `--accent`, **momentary** |
| `offline` | "Account" | 8px dot, `--text-faint` |
| `paused` | "Account" | 8px dot, **`--warn`** |

`paused` must use `--warn`, not `--accent`: with a green accent, a green
"needs you" beside a green "synced" says nothing.

Strings are the existing `SYNC_WORDS` / `SYNC_DESCS`. Do not rewrite them.

### 6.3 The panel

Desktop popover / phone sheet, same rows:
`Signed in · <email>` — Sync now (with "4 min ago") — Games on Drive (count)
— Disconnect Drive. Signed out it is one explanatory paragraph plus the single
**Sign in with Google** button.

### 6.4 Printed photos

Primary route is unchanged: **Capture → Printed Photos** in the game menu,
conditional, with the dot trail (§0).

Add **one** secondary route for the no-game case: a Printed Photos row in
Settings, shown **only when `printerPhotos.length > 0`**, mirroring the same
conditional. It must **not** set `everOpenedFromMenu`.

---

## 7. Mobile

### The budget — check every change against it

iPhone SE 1, 320×568, iOS 15, standalone, GBC (10:9 → needs **288px**):

```
548  viewport less the 20pt status bar
-52  top bar
-207 control strip (L/R already dropped by body.gb-mode)
────
 289  stage   →  +1 against 288. Inside the error bars, not outside them.
```

Proposed, taking only the two free knobs:

```
+8   bar 52 → 44 (fps readout leaves the phone bar)
+4   .pad-pill paint 28 → 24; hit area GROWS to 44 via ::before
────
 301  stage   →  +13. Not a coin flip.
```

Knobs left in reserve, cheapest first: strip `gap` 10→8 (+2), `padding-top`
10→8 (+2), `padding-bottom` 12→10 (+2), d-pad `min(46vw,240px)` → `44vw` (+6,
last resort — it is the thing you hold).

**The d-pad, A/B and the gutters do not change.** Nothing you press gets smaller.

### Portrait in-game

- Bar 44px, transport stays fused **on the bar** — every control keeps its
  current tap count. No floating HUD: it turns one tap into two and covers a
  picture with no pixels to spare.
- Tap the picture to slide the bar away — extend the existing
  `#topbar-handle` mechanism from landscape to portrait.
- No title in the bar. There is no game title to show.

### Safe area

`env(safe-area-inset-top)` is ~47–59px on a notched iPhone **in standalone**,
and **0** on SE-class and in a normal Safari tab in portrait. The band is the
bar's own background; `theme-color` fills it and `index.js` keeps it in step
with the theme. Nothing here changes.

### Settings sheet

Keep the shipped structure — fixed frame, exactly one scroller, the 88dvh /
714px cap, and the ~108px under the last row (the source comment says it is
deliberate; it is).

Change only the row system: 64px rows, 16px titles (from 15), 12.5px
descriptions (from 11.5), grouped into `--radius` cards. Same six sections in
the same order. **No "this game / app" split** — it fences the user out of the
other console's settings for no reason.

Add one group at the end, *About & support*: Printed Photos (conditional,
§6.4) and Report a Bug.

---

## 8. The game menu

One component. The in-game hamburger and the home hero card's `···` open
**the same** menu — desktop popover, phone sheet.

Order, which is the shipped order in `index.html`:

```
┌ Quick Save          Quick Load            ┐  2×2 grid
└ Rewind to a Moment  Slow Motion           ┘
  Library                                       ← was "Main Menu"
  ──────────────────────────────────────────
  Save States                      3 USED
  Manage Saves                          ›
  Capture                               ›       ← Screenshot, Record,
  ──────────────────────────────────────────       Clip that!, Printed Photos
  Link Cable                            ›
  Cheats                            2 ON
  Report a Bug                          ›
  ──────────────────────────────────────────
  Settings                              ›
```

- **Quick actions first** — they are what you reach for without reading, and
  it is what the app already does.
- **No section labels.** Hairline separators only. A label asserts a scope,
  and "App" asserted a false one for Report a Bug: you report a bug in the
  emulation of a specific title, and the modal attaches a save state.
- **Settings alone at the end** — the only genuinely app-level item. That
  reads without needing a word.
- **No ROM name in the desktop popover.** It is 296px over a game you can see.
  The phone sheet keeps it in the header, because there the sheet covers 706
  of 844 pixels.
- Sixteen items do not fit a phone; the sheet scrolls, as the menu already
  does. Library and the quick grid must be reachable without scrolling.
- Use the app's own icons from `index.html` — the film strip for Rewind to a
  Moment, the snail for Slow Motion, the star for Cheats, the link connector,
  the real gear for Settings.

---

## 9. The last frame

Makes the library scannable, gives the paused game a real hero, and turns
"in progress" into a query instead of a guess.

- **Storage.** Reuse the `getRomArt(romName)` pattern — a Blob in its own
  record, so the existing delete and Drive-sync paths already cover it. Add a
  second image kind; do not touch ROM bytes to draw a grid.
- **Capture at** pause, close, save-state (reuse the slot-thumbnail path), and
  a debounced ~60s tick that skips an unchanged frame.
- **Size.** 2× native, JPEG q0.72: ~19 KB per GBA capture, under 1 MB for a
  40-game library. Downscale in CSS; never upscale 240×160 into a 400px hero.
- **Precedence:** user box art → last frame → system chip. A game never opened
  has no frame and must not get an invented one — the chip is a legible state,
  not a failure.

---

## 10. Order of work

Each step is independently shippable and none changes the visual identity
except the last two.

1. **Focus ring.** One token, one `:where()` rule, deletes ten specials.
   Half a day, and the single biggest accessibility gain here.
2. **Type ramp and the 12px floor.** Mechanical; touches every theme once.
3. **`forced-colors` block.** ~30 lines. No visual change for anyone not in
   High Contrast.
4. **Control ladder.** Four heights, height-set not padding-set. This is what
   makes everything else look deliberate.
5. **Touch-target `::before`.** Two selectors, zero layout cost.
6. **Bar 44px on coarse pointers; fps readout off the phone bar.** Unblocks §7.
7. **Last frame capture + storage.** No UI yet — just start collecting.
8. **Library bar** (search, chips, sort, Manage, Add game) and the grid.
9. **Home as an overlay** with the hero card; delete `body.running #home
   { display: none }`.
10. **Account control**; split the Drive panel out of the ROMs modal.
11. **Game menu** re-order and the shared component.
12. **Palette.** One `:root` block. The ten other themes do not move.

Steps 1–6 are invisible-to-identity and can land in any order.
