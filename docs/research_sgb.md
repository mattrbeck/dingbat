# Super Game Boy: borders and palettes

Investigated 2026-08-06 on branch `agent-sgb`. Nothing here is on `main`.

The question was whether dingbat can grow SGB border and palette support in
both frontends, what it costs, and what it breaks. Short answer: **the core
half is small, well specified, and already works — a prototype on this branch
decodes the real packet protocol and produces a pixel-exact colorized screen
and a 256x224 border. The expensive half is the frontends, and the expense is
almost entirely about the output surface changing shape.**

Spec source is Pan Docs (`SGB_Command_Packet.md`, `SGB_VRAM_Transfer.md`,
`SGB_Color_Palettes.md`, `SGB_Command_{Palettes,Attribute,Border,System,
Multiplayer}.md`, `SGB_Unlocking.md`). No emulator source was read for the
decode.

---

## 1. What the codebase does today

**Almost nothing.** `sgb` appears in five places in `src/`, and every one of
them is about the *boot handoff*, not the adapter:

| Where | What |
|---|---|
| `src/dingbat/gb/gb.nim` `GbBootModel` | `bmSgb` / `bmSgb2` exist as boot-state models |
| `src/dingbat/gb/cpu.nim:20-23` | their register seeds: `bmSgb` gives `BC = 0x0014`, i.e. **C = 0x14, which is exactly the SGB detection Pan Docs documents** |
| `src/dingbat/gb/memory.nim:97` | the SGB/SGB2 APU handoff quirk |
| `src/dingbat/gb/timer.nim:21-33` | the SGB boot duration's effect on the DIV seed |
| `tests/dingbat_test.nim:1852` | `--model=sgb` for the mooneye boot ROMs |

Nothing selects `bmSgb` outside the test harness — a real SGB cart got
`bmDmgABC`, so *even the register-based detection failed* and every SGB game
ran as a plain DMG game.

**Header byte 0x0146 was never read.** `new_gb` (`gb.nim:1920`) reads only
`0x0143` (CGB flag), `0x0148`, `0x0149`, and the title. Neither the SGB flag
(0x0146 = 0x03) nor the old licensee code (0x014B = 0x33) — Pan Docs requires
*both* to unlock SGB functions — was looked at anywhere in the repo.

**P1 is a pure joypad.** `joypad_write` (`joypad.nim:40`) sets the two select
bits and runs the interrupt edge detector. The pulse stream that an SGB game
writes to those same bits was simply discarded.

**Existing palette machinery, precisely:**

* Core: `DMG_COLORS` (`gb.nim:1145`) is a `const` copied into `ppu.pram[0..7]`
  and `ppu.obj_pram[0..15]` at PPU construction (`ppu.nim:162-173`). Both
  renderers then index PRAM directly, so "the DMG palette" is really "whatever
  is in PRAM". There is no palette-override hook.
* Core: `CGB_COMPAT_BG_COLORS` / `CGB_COMPAT_OBJ_COLORS` for a mono cart on
  CGB hardware. The per-title Nintendo boot-ROM palette table is deliberately
  absent (rationale in the comment at `gb.nim:1147`).
* Native frontend: **no palette feature at all.**
* Web frontend: a complete DMG shade-palette feature — `GB_HW_SHADES`,
  `GB_THEME_PALETTES` (11 theme ramps), `gbPaletteMode` ∈
  default/theme/custom, IDB key `"gb-palette"`, UI in the General settings
  pane (`web/index.html:887-912`), and an exact packed-value substitution in
  the shader (`web/glpresent.js:59-70`: `if (packed == 0x6BDFu) return
  u_dmg_pal[0];` …). `web/tests/gb-palette.test.mjs` pins *the decision* (which
  four colours and whether they apply, plus contrast/ΔE rules on the ramps),
  not pixels.

**The web palette feature is the first thing SGB collides with.** Its shader
substitution keys on the four literal `DMG_COLORS` words. An SGB-colorized
frame contains arbitrary colours, so the substitution silently stops matching
— which is the *right* outcome, but it has to be made explicit (see §5).

---

## 2. What SGB support actually requires

### 2.1 The transport

The SGB protocol is a self-clocking pulse stream on P1 bits 4 and 5:

* both low = **reset**, start of a packet;
* P14 low = a `0` bit, P15 low = a `1` bit, both high = the space between;
* 16 bytes LSB-first per packet, then a `0` stop bit;
* byte 0 of the first packet is `command << 3 | length`, where length is the
  **number of packets** (1..7) in the group. Up to 111 data bytes.

Because bits are taken on falling edges, **no timing model is needed** — the
receiver is a pure state machine over P1 writes. Pan Docs' 5-M-cycle pulse /
15-M-cycle space convention is a reliability margin on real silicon, not
something an emulator has to enforce. (One real trap, found the hard way in
the prototype: the "previous lines" latch must start at *both high*, or the
very first reset pulse a game sends is not an edge and its first packet — very
often `MASK_EN` or `CHR_TRN` — is silently dropped.)

The second transport is the **VRAM transfer**: `*_TRN` commands make the SNES
read 4 KiB out of the Game Boy's video signal, reproducing the byte order the
data has at 0x8000-0x8FFF. An emulator has the VRAM, so this is a `copyMem`
from `ppu.vram[0]`. Pan Docs requires the data to be in VRAM *before* the
packet is sent, which means reading at packet completion is both simpler and
safer than reading a frame later: the "two `CHR_TRN`s around one VRAM rewrite"
pattern (a game defining all 256 border tiles) breaks under a deferred read.

### 2.2 Commands that matter, ranked

**Tier 1 — palettes (the visible payoff).**

| Cmd | Name | Why |
|---|---|---|
| 0x00-0x03 | `PAL01` / `PAL23` / `PAL03` / `PAL12` | the four screen palettes, three custom colours each |
| 0x04-0x07 | `ATTR_BLK` / `ATTR_LIN` / `ATTR_DIV` / `ATTR_CHR` | **which 8x8 screen cell uses which palette** |
| 0x0A / 0x0B | `PAL_SET` / `PAL_TRN` | 512-palette system RAM + indirect select |
| 0x15 / 0x16 | `ATTR_TRN` / `ATTR_SET` | 45 pre-baked 20x18 attribute files |

The colour-0 rule is load-bearing and easy to miss: colour 0 of all palettes
is one shared backdrop, set by whichever command most recently assigned a
colour 0. Getting this wrong makes title screens look like they have four
different background colours.

**Tier 2 — border.**

| Cmd | Name |
|---|---|
| 0x13 | `CHR_TRN` — 128 SNES 4bpp tiles per call, two calls for all 256 |
| 0x14 | `PCT_TRN` — 32x28 tilemap (16-bit entries) + border palettes 4-6 |
| 0x17 | `MASK_EN` — freeze/blank the GB window while a transfer garbles VRAM |

`MASK_EN` is not optional cosmetics: without it the player sees the raw
transfer pattern on screen for several frames on every border load.

**Tier 3 — feedback.** `MLT_REQ` (0x11) is the only command that talks *back*
to the Game Boy, via rotating joypad IDs on P1. Modern games detect SGB with
the C-register check instead, but older ones use `MLT_REQ` and will not enable
their SGB features without it.

**Never.** `SOUND`/`SOU_TRN` (SNES APU), `OBJ_TRN` (SNES sprites),
`DATA_SND`/`DATA_TRN`/`JUMP` (running 65816 code — this is what Space
Invaders' arcade mode needs), `ATRC_EN`/`TEST_EN`/`ICON_EN`/`PAL_PRI` (SNES-
side UI). All are safely accepted and dropped: none feeds anything back to the
GB.

### 2.3 The honest accuracy ceiling

* **Palettes without `ATTR_*` look actively wrong.** A game that sends
  `PAL01` and then an `ATTR_BLK` expects the status bar and the play field to
  be different palettes; applying only the global palette paints the whole
  screen in palette 0. Do not ship one without the other.
* **The attribute map does not scroll.** That is hardware, not a shortcut, and
  it is why SGB colour is mostly title screens and status bars.
* **Objects share the background's cell palette.** The SNES colorizes the
  *composited* 2-bit video signal, so a sprite takes whatever palette its
  screen cell has. This is the single most important architectural fact and it
  makes the implementation much simpler than "colour the sprites separately".
* **No SNES sprites, no SNES sound.** A handful of games lose an effect.
* **Clock speed.** A real SGB1 runs the GB 2.4% fast (SGB2 does not). dingbat
  runs at handheld speed. Nobody will notice, and matching it would desync
  every existing GB save state's scheduler deadlines. Not worth it.
* **The 29th border row.** Pan Docs documents that the S-PPU shows part of a
  29th tile row when the SGB forgets to force-blank. Deliberately not modelled.

---

## 3. Rendering / architecture

### 3.1 The screen colorization: in the emit, not a post-pass

`ppu.framebuffer` is `seq[uint16]` BGR555 and both renderers write it by
indexing PRAM. SGB colour is `pal[attr(cell)][shade]`, where `shade` is the
2-bit value *after* BGP/OBP and `cell` is the **screen** cell `(x>>3, y>>3)`.

Two designs were considered:

1. **Frame-end post-pass**, reverse-mapping the four `DMG_COLORS` words back
   to shades. Zero hot-path cost, and exact — but only for one frame. The
   moment the PPU does not redraw (LCD off, `MASK_EN` freeze) the framebuffer
   already holds SGB colours and the reverse map is ambiguous. It also needs a
   second 160x144 buffer to stay correct, which is the thing it was trying to
   avoid.
2. **Two pointers on `GbPpu`** (`sgb_pal`, `sgb_attr`), nil on every non-SGB
   machine, tested once per emitted pixel. Chosen.

Measured cost of (2), `DINGBAT_BENCH_COUNTERS=1` on `gbhdmatest.gbc`,
600 frames, against the same build with the branch compiled out:

```
with branch:  instructions = 5,672,669,709
branch gone:  instructions = 5,659,770,263      +0.228%
```

0.23% of retired instructions for a predictable nil check that replaces an
existing indexed load. That is inside the noise the repo's own perf notes call
unmeasurable by wall clock, and it is the price of not having a second
framebuffer. (`docs/performance.md`'s method applies: wall-clock A/B lies
below ~1.3%, counters do not.)

Both renderers need the hook (3 edit sites in `scanline_ppu.nim`, 1 in
`fifo_ppu.nim`). The prototype does both and the test asserts they agree
pixel-for-pixel.

### 3.2 The border: **the frontend composites, the core does not**

The border is 256x224; the GB screen is 160x144 centred at (48, 40). Three
options:

| | Core emits 256x224 | Core hands over a second surface | Frontend decodes SGB itself |
|---|---|---|---|
| blast radius | every 160/144 constant, thumbnails, netplay, rewind, touch layout, screenshots | one new export per frontend | duplicate protocol in Nim and JS |
| filters | scanlines/hq4x/xBR/colour-correction hit the border too | frontend chooses per layer | — |
| GB paths when border is off | changed | **byte-identical** | — |

**Recommendation: the middle column.** The core owns SGB decode and produces
`sgb.border`, a 256x224 `seq[uint16]` where bit 15 (unused by BGR555) means
"opaque"; colour index 0 stays transparent, which is exactly how borders that
*cover* the GB window (Mario's Picross, WildSnake) work. The frontend then:

1. draws the border texture over the whole quad — **nearest, no upscale
   filter**: the border is native SNES art at 1:1, and hq4x/xBR on it looks
   wrong;
2. draws the existing GB texture into the centred 160x144 sub-rect with every
   filter it applies today;
3. draws the border again (or uses the alpha in one pass) so opaque border
   pixels win.

In practice one pass with two samplers is simpler than three draws: sample the
border, and if its bit 15 is clear, sample the GB texture at the remapped UV.

This is the option that keeps `ppu.framebuffer`, save-state thumbnails,
rewind thumbnails, netplay frame transport, the printer, the Pocket Camera and
every 160x144 literal exactly as they are.

### 3.3 Everything the bigger surface touches

**Native** (`src/dingbat.nim` is the whole frontend; the widgets never touch
the game texture):

| Site | Today | With a border |
|---|---|---|
| `:29-32` `GB_W/GB_H/GBA_W/GBA_H` | four consts | a fifth pair, or a runtime `(w, h)` |
| `:524-526` texture alloc | one `GL_RGB5` texture | a second texture for the border |
| `:443-446` `apply_panel_uniforms` | `tex_width`/`tex_height` uniforms | must describe the GB layer, not the quad — **the scanline pitch is `fract(uv.y * tex_height)`, so getting this wrong makes scanlines land on the border at the wrong pitch** |
| `:170-177` `FRAG_SRC` main | one sample | two samplers + a UV remap |
| `:493` / `:502` / `:1007-1008` window sizing | `GB_W*scale` | `256*scale`, and the aspect changes 10:9 → 8:7 |
| `:1320-1325` viewport | full window, quad stretched — **there is no letterboxing at all today** | unchanged, but the stretch is now to a different aspect |
| `:717-747` `save_screenshot` | reads the *core* framebuffer at 160x144, replicates colour correction in CPU float math | must composite the border too, or screenshots silently lose it |
| `:815-826` rumble jitter | offsets the viewport ±1 px | unchanged |
| `frontend/gb_debug.nim:208` | BG-map overlay `160 * MAP_SCALE` | unaffected |

**Web**:

| Site | Note |
|---|---|
| `web/index.js:4828-4830` `nativeRes()` | derived from the **ROM filename extension**, not from wasm. A border needs a real wasm signal — extend `wasm_panel_gbc` to a kind/size export, and add it to the `EXPORTED_FUNCTIONS` list in `src/dingbat_wasm.nims:16` and `web/types/em.d.ts` |
| `web/index.js:4832-4900` `updateCanvasScaling` | backing store `native * GL_SCALE(4)`; publishes `--game-ar` from the live backing store; integer-scale and contain-fit branches both key off it. A 256x224 surface is 8:7 = 1.143 vs 10:9 = 1.111 — small, but it changes the CSS box |
| `web/styles.css:1605-1616` `#canvas` | `aspect-ratio: var(--game-ar, 1.5)` — driven from JS, so it follows automatically |
| `web/styles.css:4215-4222` `body.gb-mode` | hides the shoulder row and gives the vertical space to the stage. A border makes the frame *shorter and wider*, so the portrait touch layout gets slightly more room — no regression, but the short-portrait breakpoint at `:4232` reasons about a 3:2 canvas needing ~213px and should be re-checked |
| `web/styles.css:4791-4815` tablet rails | `#stage` padding is subtracted in JS; unaffected |
| `web/embed.css:19-56` | an integer-multiple ladder that is **GBA-only** — the embed already has no 10:9 tier, so it is already wrong for GB and a border does not make it worse |
| `web/glpresent.js` | contains **zero** hardcoded dimensions (`nativeRes` is injected) — the cleanest file to extend. Needs a second `usampler2D`, a `u_border` flag, and the UV remap |
| `web/glshaders.mjs` | extracts the `VERT`/`FRAG` template literals **as text by regex**. Renaming them or nesting a backtick breaks `uv.test.mjs` and `render.test.mjs` |
| thumbnails (`index.js:3726-3753`), glow (`:4914`), paused card (`:7315`), bug-report preview (`:4013`) | all call `nativeRes()`; all would show the border unless they explicitly ask for the GB layer. **Recommend: thumbnails and the paused card keep 160x144** — a 120px-wide thumbnail of a bordered frame is mostly border |
| `web/index.js:7392-7404` `captureCanvas` | `toBlob` on the backing store, so it gets the border for free |

**The DMG-palette interaction (web).** `glpresent.js:63-74` substitutes the
four `DMG_COLORS` words, and `:136` makes a chosen palette bypass LCD colour
correction. When SGB colour is active the framebuffer no longer contains those
words, so substitution no-ops — correct, but the UI must say so. Gate the
"Shade palette" control on `!sgbActive`, the same way it is already gated on
`gbMonoPanel`.

---

## 4. Save states

`docs/research_savestate_compat.md` §6 is the governing document: `STATE_VERSION`
(container, currently 7) is header-only; each core has its own payload
revision, and the loader migrates rather than refusing.

SGB adds real state: 4x4 palettes, the 20x18 attribute map, 512x4 system
palettes (4 KiB), 45 attribute files (4050 B), 256 border tiles (8 KiB), the
32x28 tilemap (1792 B), three border palettes, `MASK_EN` + the frozen frame,
and the packet-decode state machine (which genuinely must be saved — a state
taken mid-packet has to resume mid-packet).

**Correct handling, implemented in the prototype:**

* new section tag `GB_SEC_SGB = 0xBB`, written **only when `gb.sgb != nil`**;
* `GB_PAYLOAD_VERSION` 4 → 5, **`STATE_VERSION` untouched at 7** — so no GBA
  state is invalidated, which is the entire point of the v7 split;
* loader guard `if gb.sgb != nil and rev >= 5`. A pre-SGB state loads into an
  SGB machine with a fresh `SgbState`, which an SGB game re-establishes within
  a few frames anyway (games re-send palette/attribute commands on every
  screen change);
* derived, not serialized: the decoded 256x224 `border` image (re-rendered
  from `chr`/`map`/`border_pal` on the first frame after a load) and the two
  `GbPpu` hook pointers (re-attached by `sgb_attach`).

`tests/savestate_compat_test.nim` passes unchanged: the committed corpus of
GB rev 1/2/3 states still loads.

**One-way cost, and it is unavoidable:** a state written by an SGB build for
an SGB cart is refused by an older build (`rev 5 > 4`). Same class as the
sub-1 MiB GBA identity fix. States for non-SGB carts are byte-identical.

**Sequencing note.** Whether a machine *has* an SGB is decided by the cart
header plus the frontend opt-in, never by the payload — so the section is
present exactly when both sides agree, and toggling "SGB mode" off in the UI
must be treated as a machine reset, not a live setting.

---

## 5. UI / UX

### Detection and mode exclusivity

Three inputs, in this order:

1. **Cart header** — `0x0146 == 0x03 && 0x014B == 0x33`. Pan Docs is explicit
   that *both* are required; a cart with only one gets nothing.
2. **Not CGB.** `bmSgb` and CGB mode are mutually exclusive on hardware. A
   cart that is both CGB-capable *and* SGB-enhanced (Pokémon Yellow, Zelda
   DX, many 1998-2000 titles) runs as a **CGB** — that is what happens when
   you put one in a Game Boy Color, it is the better-looking mode, and it is
   the behaviour dingbat already produces. `force_dmg` (used by the gambatte
   suite) should then be able to fall through to SGB.
3. **A user toggle**, default on.

So: **auto-detected, with an off switch.** Not a per-game prompt.

The prototype also promotes `boot_model` `bmDmgABC` → `bmSgb` when the adapter
attaches, so `C = 0x14` detection works. That is a behaviour change for SGB
carts (different boot register seeds and DIV phase) and belongs in the same
commit as the adapter, not before it.

### Native (ImGui)

The frontend has four menus — File, Emulation, Audio/Video, Debug — and a
Settings window with tabs Keybindings / Video / Controller / BIOS. There is
**no per-system video section**: `frontend/video_widget.nim` is one flat pane
whose only GB-specific control is the FIFO/scanline renderer radio, and
"LCD Color Correction" lives in the menu bar instead. Match that rather than
inventing:

* **Settings ▸ Video**, directly under the FIFO/scanline radio (the existing
  GB group): `[x] Super Game Boy mode` and `[x] Show SGB border`, the second
  disabled while the first is off — the same "disabled while suspended"
  pattern `video_widget.nim:43-48` already uses for scanlines-under-filter.
* Config: two `bool`s in the existing nested `gb:` block of
  `common/config.nim` (`parse_config` `:350-357`, `save_config` `:443-449`),
  plus `new_config` and `config_editor.do_factory_reset` `:52-74` — **every
  new field must be listed in all four places** or factory reset silently
  drops it.
* Frame size: the "Frame size 1x..8x" submenu (`dingbat.nim:1002-1015`) must
  size from 256x224 when the border is shown.

### Web

Six settings tabs; there is already a **Game Boy** pane
(`web/index.html:716-738`), which is the obvious home — better than Video,
because these are system settings, not presentation settings.

* Two `modal-toggle-row` switches in the Game Boy pane: "Super Game Boy" and
  "SGB border".
* Persist in the existing grouped `"system"` IDB record (not a new key), which
  keeps `SETTINGS_KEYS` unchanged; if a new key is used it **must** be added
  to `SETTINGS_KEYS` (`index.js:5820`) or "Reset all settings" leaves it
  behind — `gb-palette.test.mjs:215` asserts exactly this for the palette.
* The "Shade palette" control in General must show a disabled/explanatory
  state while SGB colour is active (see §3.3).
* Toggling SGB mode requires a core restart, so it should behave like the
  existing renderer/BIOS settings: applies on next load, with the usual toast.

---

## 6. Prototype

**There is no SGB-enhanced ROM in this repository.** `tests/roms/` holds two
GB ROMs (`gblinktest.gb`, `gbhdmatest.gbc`), both self-built; `reference/` does
not exist; `tools/` has no ROMs. Per the brief, no search outside the repo was
made. The proof is therefore synthetic — but it is a *real* proof: the test ROM
speaks the actual wire protocol, not a shortcut.

### What was built

| File | What |
|---|---|
| `src/dingbat/gb/sgb.nim` (new, ~330 lines) | `SgbState`, the P1 pulse receiver, PAL01/23/03/12, PAL_SET, PAL_TRN, ATTR_BLK/LIN/DIV/CHR, ATTR_TRN, ATTR_SET, MASK_EN, CHR_TRN, PCT_TRN, MLT_REQ player count, VRAM transfer, 256x224 border decode |
| `gb.nim` | `SgbState` type, `GB.sgb` / `GB.sgb_requested`, `GbPpu.sgb_pal` / `.sgb_attr`, header unlock + adapter attach in `post_init`, `sgb_frame_end` in `step_frame` |
| `joypad.nim` | one line: run the receiver alongside the joypad, not instead of it |
| `fifo_ppu.nim`, `scanline_ppu.nim` | the per-pixel colorization hook (1 + 3 sites) |
| `savestate.nim`, `serialize.nim` | `GB_SEC_SGB`, payload rev 4 → 5, migration |
| `tests/roms/sgbtest.py` (new) | a mini SM83 assembler that emits `sgbtest.gb`: a real 32 KiB cart with the Nintendo logo, SGB flag 0x03, licensee 0x33, and a program that pulses two VRAM transfers and four colour packets down P1 |
| `tests/sgb_test.nim` (new) | the acceptance test; `nimble test_sgb` |

### What it proves

`nimble test_sgb` → `sgb_test: all checks passed`. The assertions:

* the adapter attaches for an SGB-flagged cart and `boot_model` becomes `bmSgb`;
* all 16 palette entries match, **including the shared colour 0** across all
  four palettes;
* all 360 attribute cells match the expected `ATTR_DIV` + `ATTR_BLK` result,
  including `ATTR_BLK`'s "inside only ⇒ the surrounding line follows" rule;
* **all 23,040 screen pixels** match `pal[attr(cell)][shade]`;
* **all 57,344 border pixels** match the expected 4bpp tile decode, and the
  20x18 window hole is fully transparent (0 opaque pixels);
* the FIFO and scanline renderers produce **identical** SGB output;
* a cart without the header bits gets `sgb == nil` and `ppu.sgb_attr == nil`
  (no behaviour change for every other GB game);
* palettes, attribute map and border tiles survive a save-state round trip
  after the live state is deliberately scribbled over.

With `DINGBAT_SGB_PNG=<dir>` it also writes `screen.png`, `border.png` and
`composite.png` — the last being exactly what §3.2's frontend compositor would
show. It looks right: a 256x224 colour frame around a per-cell-colorized
160x144 screen with a transparent window.

### Bugs the prototype found, worth keeping

* **The idle-level initialisation.** `prev_lines` must start at "both high" or
  the first reset pulse is not an edge and the game's first packet is lost.
  Symptom: everything works except the first command a game sends — which for
  border games is `CHR_TRN`, so the border comes out entirely transparent
  while the palettes are perfect. Easy to misdiagnose as a tile-decode bug.
* **Immediate vs deferred VRAM transfer.** Reading at packet completion rather
  than "next frame" is not just simpler, it is more correct for the two-call
  `CHR_TRN` pattern.

### What is stubbed

* The frontends. Nothing in `src/dingbat.nim` or `web/` was changed — the
  border exists as `gb.sgb.border` and is proven by the test's composite PNG,
  not by a shader. This is deliberate: it is the chunk that needs the design
  decision in §3.2 to be signed off first.
* `MLT_REQ` records the player count but does not rotate joypad IDs on P1, so
  `MLT_REQ`-based SGB detection does not yet succeed. Small, and needed before
  older games light up.
* `PAL_PRI`, sound, SNES objects, SNES CPU commands — accepted and dropped.

---

## 7. Landable chunks

Each is independently shippable and independently useful.

| # | Chunk | Size | Notes |
|---|---|---|---|
| 1 | **Header detection + `bmSgb` boot model.** Read 0x0146/0x014B, promote the boot model, expose `gb.sgb_requested`. No visible change except register-based detection starting to work. | XS (~40 lines) | Already in the prototype. Ships alone. |
| 2 | **Packet receiver + palettes + attributes.** `sgb.nim` minus the border, the two renderer hooks, `MASK_EN`. **This is where the visible payoff is** — colourised title screens and status bars, no frontend change at all. | M (~250 lines + test) | Prototype-complete. Include `MLT_REQ` ID rotation here. |
| 3 | **Save-state section.** Payload rev 5 + migration. | S (~70 lines) | Must land with or before 2, or states taken in SGB mode lose their colour. |
| 4 | **Border decode in the core.** `CHR_TRN`/`PCT_TRN` → `sgb.border`. Still invisible to users. | S (~80 lines) | Prototype-complete. |
| 5 | **Native border compositing.** Second texture, two-sampler shader with a UV remap, window sizing from 256x224, screenshot compositing, the `tex_height` scanline-pitch fix. | M–L | The riskiest chunk; `dingbat.nim` has no aspect handling to build on. |
| 6 | **Web border compositing.** A real dimension export from wasm (retire the filename-derived `nativeRes()`), second sampler in `glpresent.js`, `--game-ar`, thumbnails/glow/paused-card kept at 160x144. | M–L | `glpresent.js` is dimension-clean already, which helps a lot. |
| 7 | **UI toggles + config, both frontends.** | S | Do after 5/6 so there is something to toggle. |
| 8 | **Polish.** `PAL_PRI`, the SGB1 2.4% clock as an opt-in, a built-in default border for non-SGB mono carts. | S each | All optional. |

**Total: roughly a week of focused work**, of which chunks 1-4 (about a day
and a half, and already prototyped) deliver most of the user-visible value.

### Top risks

1. **The frontend surface change is the whole cost.** The native frontend
   stretches a fixed quad to the window with no aspect logic at all, and the
   web frontend derives its resolution from *the ROM filename*. Both need real
   plumbing before a 256x224 output can exist. If the border is descoped,
   chunks 1-4 still ship and the risk goes to zero.
2. **The scanline-pitch uniform.** `fract(uv.y * tex_height)` is shared by both
   frontends. Feed it the quad height instead of the GB layer height and
   scanlines quietly land at the wrong pitch — a subtle, easily-shipped bug.
3. **Palettes without attributes look worse than no SGB at all.** Chunk 2 must
   not be split into "palettes now, attributes later".
4. **The one-way save-state downgrade.** Unavoidable, small, and precedented.
5. **No real test ROM.** The synthetic ROM proves the protocol but not the
   long tail: multi-packet `ATTR_CHR` groups, `PAL_TRN` + `PAL_SET`,
   `MASK_EN` timing around transfers, and borders that overlap the GB window
   are all implemented but only unit-covered. First contact with a real
   SGB-enhanced cart will find something. Budget for it.
6. **Web palette collision.** The DMG shade-palette feature silently no-ops
   under SGB colour. Correct behaviour, but it will read as a bug unless the
   UI says so.
