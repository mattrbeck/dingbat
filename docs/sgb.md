# Super Game Boy: borders and palettes

Investigated and built 2026-08-06/07 on branch `agent-sgb`. Not on `main`.

**Status: shipped end to end on this branch.** The core decodes the real
command-packet protocol, colourises the screen per attribute cell and decodes
the 256x224 border; both frontends composite it; both have settings toggles;
save states carry it. Verified on Pokemon Blue (a real SGB-enhanced cart) in
the native GL path and in headless Chromium, and on Zelda: Link's Awakening DX
(SGB flag *and* CGB flag) for the mode-priority case.

Spec source is Pan Docs (`SGB_Command_Packet.md`, `SGB_VRAM_Transfer.md`,
`SGB_Color_Palettes.md`, `SGB_Command_{Palettes,Attribute,Border,System,
Multiplayer}.md`, `SGB_Unlocking.md`). No emulator source was read.

## 0. The three things that were not obvious

Everything else in this document is bookkeeping. These three cost the time.

**A VRAM transfer is read out of the display, not out of 0x8000.** Pan Docs
says the data is "normally" at 0x8000-0x8FFF and that the SNES "will
automatically re-produce the same ordering of bits and bytes". That sentence
describes the common case, not the mechanism. The mechanism is the
precondition list right above it -- characters $00-$FF on screen, $00..$13 on
the first line, display enabled, no scroll, BGP = $E4 -- which is what makes
the picture equal to those bytes. All three of Pokemon Blue's transfers run
with LCDC = 0xE3, i.e. LCDC.4 clear, so character $00 lives at 0x9000 and a
flat 0x8000 read returns mostly zeroes: empty tilemap, black palettes, no
border, while the packet decode itself is already perfect. `sgb_read_transfer`
walks the display instead -- per character, the screen cell it occupies, the
BG map there (honouring SCX/SCY and LCDC.3), the tile through LCDC.4's
addressing mode. Identical to the flat read when the preconditions hold.

**The idle level of the P1 select lines is load-bearing.** The receiver takes
bits on falling edges, so the "previous lines" latch has to start at both-high
or a game's very first reset pulse is not an edge and its first packet is
dropped. For a border game that packet is `CHR_TRN`, so the palettes come out
perfect and the border comes out entirely transparent -- which reads as a
tile-decode bug and is not one.

**The desktop vertex shader emits a negative V.** `VERT_SRC` flips the image
with `/ vec2(2.0, -2.0)`, so `tex_coord.y` runs 0 -> -1 and every texture
fetch is out of range, brought back only by the default `GL_REPEAT` wrap. The
border texture was given `CLAMP_TO_EDGE` -- which is what "sampled at exactly
the quad's extent" argues for -- and that pinned the whole border to row 0.
It renders as vertical stripes. The same flip is why the Game Boy window
rectangle has to be computed in un-flipped space and flipped back.

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

Because the encoding is self-clocking, **no timing model is needed** — the
receiver is a pure state machine over P1 writes. Pan Docs' 5-M-cycle pulse /
15-M-cycle space convention is a reliability margin on real silicon, not
something an emulator has to enforce. (One real trap, found the hard way in
the prototype: the "previous lines" latch must start at *both high*, or the
very first reset pulse a game sends is not an edge and its first packet — very
often `MASK_EN` or `CHR_TRN` — is silently dropped.)

**Which edge carries the bit.** A pulse is two edges — a line falls, then both
lines are released — and Pan Docs does not say which one the ICD2 samples. It
is the **release**, and it reads whichever line is low at that moment. The
prototype guessed the fall, which is indistinguishable for every well-formed
transfer and wrong for a malformed one. `cpp/sgb-ext-test` is built entirely
out of malformed ones and settles it three ways:

* `SendPacket20To10` drives `$20` (P14 low) → `$10` (P15 low) → `$30` for one
  bit. Hardware reads a **1**: the P15 state at the release wins, not the P14
  fall that came first. Its `MLT_REQ 4` and `MLT_REQ 2` packets, whose affected
  bit is already 1, survive intact; its `MLT_REQ 1` packet, whose bit is 0, is
  received as `MLT_REQ 2`. `SendPacket10To20` is the mirror and reads a **0**.
* `SendPacketShortStart` omits the `$30` that ends the reset pulse, so the
  first bit's low pulse is entered *from the reset* rather than from both-high.
  Hardware drops that bit — the packet shifts by one and its command byte stops
  being `MLT_REQ`. So a release only carries a bit if the line went low from
  both-high; the receiver needs that one extra "pulse in flight" bit of state.
* `SendPacketAvoid30` never returns to both-high at all, and hardware receives
  nothing. `SendPacket10To00` / `SendPacket20To00` drop a `$00` in the middle
  of a bit's pulse, and the reset wins: the bit in flight is abandoned.

The stop bit's *value* is ignored — `SendPacketCorruptStop` sends a 1 there and
the packet is still accepted.

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

The joypad-ID counter is not the "reset to player 1 and advance between polls"
device the obvious reading of Pan Docs suggests. SameSuite's two `sgb/` ROMs
pin it exactly, and both halves are counter-intuitive:

* It **free-runs on every P15 rising edge**, including the ones a command
  packet is made of. `command_mlt_req` is built on that: it uses `MLT_REQ`
  packets purely as a known number of steps, and says so — "Each of these
  increments the player 5 times before it gets ANDed" beside an `MLT_REQ 1`
  packet, "6 times" beside `MLT_REQ 3`. A packet is one reset pulse plus one
  P15 pulse per `1` bit, and `$89 $01` has four 1 bits (five) against `$89 $03`
  with five (six), so those numbers *are* the rule. `MLT_REQ` itself does not
  clear the counter; it only ANDs it with the new player mask.
* Request **2 is not a real mode** — Pan Docs lists 0, 1 and 3 — and the SGB
  behaves as 3 players, i.e. mask 2. That mask makes the ID stick: `0 →
  (0+1)&2 = 0` and `2 → (2+1)&2 = 2`, so it never moves again, which is what
  the ROM's last three groups check. Request 2 also advances the counter once
  as it lands, which requests 0/1/3 do not. That asymmetry is forced by the
  data, not chosen: entering an `MLT_REQ 2` from four-player mode with the four
  possible counters, hardware answers players 2, 2, 0, 0 — `((n+1) & 2)` — while
  the same four entering an `MLT_REQ 1` answer 1, 0, 1, 0 — `(n & 1)`, with no
  advance. The two packets carry the same number of 1 bits, so no AND-only or
  advance-always rule fits both.

In one-player mode the mask is 0, so the free-running counter is pinned at 0
and P1 reads the same `0xF` a handheld does — the multiplayer path is inert
rather than special-cased.

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

### 3.2 The border: the frontend composites, the core does not

The border is 256x224; the Game Boy screen is 160x144 centred at (48, 40).
The core keeps emitting 160x144 and exposes the border as a **second surface**:
`gb.sgb.border`, 256x224 BGR555 with bit 15 (unused by the colour format)
meaning "opaque". SNES colour index 0 stays transparent, which is exactly how
borders that *cover* the Game Boy window (Mario's Picross, WildSnake) work.

Why not have the core emit a bigger frame: thumbnails, the rewind ring, the
netplay frame transport, the printer, the Pocket Camera, the link/rollback
blit paths and every 160x144 literal in both frontends would all have had to
move, and the picture would only be 256x224 for part of a session anyway. As a
second surface, **all of those are byte-identical when the border is off** --
measured, see §6.

Why not decode SGB in the frontends: the protocol would exist twice, in Nim
and in JS, and the state would not be in save states.

Both frontends composite in **one pass with two samplers**: opaque border wins,
else the Game Boy window with every filter it already gets, else the SGB
backdrop (colour 0). Border art is native SNES output, so it takes neither the
LCD colour-correction curve nor the upscale filters -- those are tuned for 2bpp
pixel art and smear 4bpp tiles.

The scanline pitch had to become its own uniform (`scan_height` /
`u_scan_height`). With a border the picture is 224 native rows and both layers
live in it, so a single `fract(uv.y * 224)` is correct for the composite;
feeding the sampled texture's height (144) instead puts Game Boy scanlines
over SNES art.

The border image is re-uploaded only when a generation counter
(`SgbState.border_gen`) moves. It changes a handful of times in a session and
is 112 KiB.

### 3.3 Aspect ratio and letterboxing (native)

dingbat stretched the game quad across the whole window. That is invisible
while the window keeps the size `load_rom` gave it and obviously wrong the
moment it does not -- fullscreen on a 16:9 panel stretched a 10:9 Game Boy
picture by 1.6x horizontally. A border makes it worse, because the picture
changes from 10:9 to 8:7 part way into a session.

So `game_viewport()` now letterboxes, under a new `preserve_aspect` setting
(default on), and the window resizes once on the edge where a border appears
or disappears -- the way a console changes video mode. The letterbox bars are
black behind a game; the brand purple stays the empty-app backdrop.

### 3.4 Everything the bigger surface touched, and what happened to it

**Native** (`src/dingbat.nim` is the whole frontend):

| Site | Resolution |
|---|---|
| `GB_W/GB_H/GBA_W/GBA_H` consts | joined by `output_size()`, which returns 256x224 while a border is on screen |
| texture allocation | second `GL_RGB5_A1` texture on unit 1; `1_5_5_5_REV` puts BGR555 in RGB and the opaque bit in A with no conversion |
| `apply_panel_uniforms` | also binds the two samplers to units 0 and 1 — without that the border sampler defaults to unit 0 and samples the game as its own border |
| `FRAG_SRC` main | two samplers, a UV remap, and `scan_height` split out of `tex_height` |
| window sizing (3 sites) | all go through `resize_to_output()` |
| viewport | `game_viewport()` letterboxes; the rumble jitter offsets that rect instead of the window |
| `save_screenshot` | composites the border the same way the shader does, or screenshots would silently lose it |

**Web**:

| Site | Resolution |
|---|---|
| `nativeRes()` (was derived from the **ROM filename**) | new `_wasm_out_w` / `_wasm_out_h` are authoritative; the filename check survives only as the bootstrap answer for the frame before the core exists, and for GBA |
| the four `_wasm_fb_ptr` consumers (thumbnails, ambient glow, paused card, bug-report preview) | new `gameRes()` — they want the console framebuffer, and a 256x224 heap view over a 160x144 buffer would walk off the end. They also look better without the border |
| `updateCanvasScaling` | unchanged; it already derives everything from `nativeRes()`. `drawGame` watches for the size changing and re-runs it |
| `--game-ar` | follows automatically: 8:7 = 1.1428 with a border, verified live |
| `glpresent.js` | second `usampler2D` on unit 1, `u_sgb_border`, `u_sgb_backdrop`, `u_scan_height` |
| `web/embed.js` | same authoritative `nativeRes()` |
| touch layout | no change needed. A border makes the frame shorter and wider, so portrait gets *more* room; verified at 390x844 and 844x390 |
| DMG shade palette | see below |

**The shade-palette collision, handled rather than deferred.** The web's
`u_dmg_remap` works by substituting the four exact `DMG_COLORS` words in the
shader. An SGB-colourised framebuffer contains none of them, so the feature
silently stops doing anything. `drawGame` now stops passing the palette once
the adapter is active, and the control is **disabled with a sentence saying
why** ("This game is running as a Super Game Boy and is drawing its own
colors...") instead of being left live and inert.

## 4. Save states

`docs/research_savestate_compat.md` §6 is the governing document: `STATE_VERSION`
(container, currently 7) is header-only; each core has its own payload
revision, and the loader migrates rather than refusing.

SGB adds real state: 4x4 palettes, the 20x18 attribute map, 512x4 system
palettes (4 KiB), 45 attribute files (4050 B), 256 border tiles (8 KiB), the
32x28 tilemap (1792 B), three border palettes, `MASK_EN` + the frozen frame,
and the packet-decode state machine (which genuinely must be saved — a state
taken mid-packet has to resume mid-packet).

**What shipped:**

* new section tag `GB_SEC_SGB = 0xBB`, written **only when `gb.sgb != nil`**;
* `GB_PAYLOAD_VERSION` 4 → 5, **`STATE_VERSION` untouched at 7** — so no GBA
  state is invalidated, which is the entire point of the v7 split;
* loader guard `if gb.sgb != nil and rev >= 5`. A pre-SGB state loads into an
  SGB machine with a fresh `SgbState`, which an SGB game re-establishes within
  a few frames anyway (games re-send palette/attribute commands on every
  screen change);
* derived, not serialized: the decoded 256x224 `border` image and the two
  `GbPpu` hook pointers (re-attached by `sgb_attach`). The border is
  re-rendered **inline in the loader**, not flagged dirty for the next frame:
  both frontends size the window from `border_valid`, so a deferred render
  would make a state load blink 256x224 → 160x144 → 256x224.

`tests/savestate_compat_test.nim` passes unchanged: the committed corpus of
GB rev 1/2/3 states still loads.

**A state must cross the setting.** Super Game Boy is a frontend toggle, so
saving with it on and loading with it off is an ordinary thing for a user to
do — and the obvious reader condition, `if gb.sgb != nil and rev >= 5`, gets
it wrong in both directions: it decides from *this machine's* configuration
when the only thing that can decide is what is in the payload. The section
bytes are then left in the stream, the next `expect_tag` reads 0xBB where it
wants `GB_SEC_END`, and a perfectly good state is refused with "section marker
mismatch". The reader **peeks the tag** instead (`peek_tag`), and with no
adapter reads the section into a throwaway and drops it — the state loads and
simply plays in black and white, which is what turning the setting off means.
Pinned in `tests/sgb_test.nim` in both directions.

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
3. **A user toggle**, default **off**. It is off in four places that all have
   to agree: `GB.sgb_requested` (so the test harnesses, the benchmark and the
   ROM sweeps keep stock behaviour without knowing SGB exists), `new_config()`,
   `var sgbEnable` in `web/index.js`, and `var sgbRequested` in
   `dingbat_wasm.nim` (which is what an *embed* gets, since embed.js never
   calls `applySystemSettings`).

   **Migration is by omission and that is deliberate.** Neither
   `parse_config`'s `gb.sgb` lookup nor `loadSystemSettings`'s `s.sgbEnable`
   lookup invents a value when the key is absent, so a config or a `"system"`
   record written before this feature existed keeps the new default. Nobody
   silently gains an adapter.

So: **opt-in, then auto-detected.** The switch is off out of the box — a fresh
install plays a monochrome cart as a Game Boy, which is what it looks like
everywhere else — and once it is on, whether any given cart gets an adapter is
decided by the header alone, never by a per-game prompt. Verified on
Zelda LADX, which carries both flags and runs as a Game Boy Color in both
frontends.

Attaching the adapter also promotes `boot_model` `bmDmgABC` → `bmSgb`, so the
`C = 0x14` detection Pan Docs documents works. That changes the boot register
seeds and the DIV phase for SGB carts, and it is gated by the same opt-in —
which is why Pokemon Blue with SGB *off* still hashes identically to `main`.

### Native (ImGui)

**Settings ▸ Video**, in a "Super Game Boy:" group under the FIFO/scanline
renderer radio (the existing GB group; the frontend has no per-system video
section and inventing one for two checkboxes would have been worse):

* `[ ] Super Game Boy mode` — **off by default**, with an always-visible
  `Applies on the next ROM load or reset.` under it. Not behind the `(?)`
  marker: the adapter is chosen when the cartridge is inserted, so ticking the
  box cannot affect the game already running, and a user who ticks it and sees
  nothing happen would reasonably conclude it is broken.
* `[x] Show SGB border` — on, but disabled while the mode is off (the same
  "disabled while suspended" pattern the scanlines-under-filter checkbox
  uses). This one *is* live: it only hides a layer the core already has.
* `[x] Preserve aspect ratio` — new, and not SGB-specific (§3.3).

Config: `sgb_enable` / `sgb_border` in the nested `gb:` block of
`dingbat.yml`, `preserve_aspect` at the top level. All three are wired in all
four places a setting has to appear — `new_config`, `parse_config`,
`save_config`, and `config_editor.do_factory_reset` — plus `video_widget`'s
`reset`/`apply`.

The "Frame size 1x..8x" submenu now sizes from `output_size()`.

### Web

**Settings ▸ Game Boy**, above the Boot ROM row. That pane, not Video: these
are system settings, not presentation settings.

* "Super Game Boy mode" — **off by default**; applies on next load, with a
  toast saying so when a game is already running. The pane's existing
  `settings-note` now reads "Renderer, Super Game Boy mode and boot ROM
  changes apply the next time a game is loaded. Showing or hiding the border
  takes effect immediately."
* "Show border" — on, and **live**; it only hides a layer the core already
  has, and the canvas changes shape immediately. Greys out with the mode.

Persisted in the existing grouped `"system"` IndexedDB record, so
`SETTINGS_KEYS` is unchanged and "Reset all settings" already covers them; the
in-memory half of that reset restores both and re-pushes them into the core.

## 6. What was built, and what proves it

### Files

| File | What |
|---|---|
| `src/dingbat/gb/sgb.nim` (new, ~430 lines) | `SgbState`, the P1 pulse receiver, PAL01/23/03/12, PAL_SET, PAL_TRN, ATTR_BLK/LIN/DIV/CHR, ATTR_TRN, ATTR_SET, MASK_EN, CHR_TRN, PCT_TRN, MLT_REQ (count *and* joypad-ID rotation), the display-walking VRAM transfer, the 256x224 border decode |
| `src/dingbat/gb/gb.nim` | `SgbState` type, `GB.sgb` / `GB.sgb_requested`, `GbPpu.sgb_pal` / `.sgb_attr`, header unlock + adapter attach in `post_init`, `sgb_frame_end` in `step_frame` |
| `src/dingbat/gb/joypad.nim` | run the receiver alongside the joypad; SGB joypad IDs on a both-deselected read |
| `src/dingbat/gb/{fifo,scanline}_ppu.nim` | the per-pixel colorization hook (1 + 3 sites) |
| `src/dingbat/gb/savestate.nim`, `common/serialize.nim` | `GB_SEC_SGB`, payload rev 4 → 5, migration |
| `src/dingbat.nim` | border texture + compositing shader, `output_size`, `game_viewport` letterbox, screenshot composite, `--capture` |
| `src/dingbat/frontend/{video_widget,config_editor}.nim`, `common/config.nim` | the three settings |
| `src/dingbat_wasm.nim(s)` | nine new exports (`_wasm_sgb_*`, `_wasm_out_w/h`) |
| `web/glpresent.js`, `web/index.js`, `web/index.html`, `web/embed.js`, `web/styles.css`, `web/types/em.d.ts` | the web half |
| `tests/roms/sgbtest.py` (new) | a mini SM83 assembler emitting `sgbtest.gb` — a real 32 KiB cart with the Nintendo logo, SGB flag 0x03, licensee 0x33, an identity BG map so its transfers meet the documented preconditions, and a program that pulses two VRAM transfers and four colour packets down P1 |
| `tests/sgb_test.nim` (new) | the acceptance test; `nimble test_sgb` |

### Automated proof — `nimble test_sgb`

From the synthetic cart, driven through the real receiver:

* the adapter attaches for an SGB-flagged cart, `boot_model` becomes `bmSgb`;
* all 16 palette entries, **including the shared colour 0** across all four;
* all 360 attribute cells (ATTR_DIV + ATTR_BLK, including ATTR_BLK's
  "inside only ⇒ the surrounding line follows" rule);
* **all 23,040 screen pixels** = `pal[attr(cell)][shade]`;
* **all 57,344 border pixels** of the 4bpp tile decode, and the 20x18 window
  hole fully transparent (0 opaque pixels);
* FIFO and scanline renderers **identical**;
* a cart without the header bits gets `sgb == nil` and `ppu.sgb_attr == nil`;
* palettes, attribute map and border tiles survive a state round trip after
  the live state is deliberately scribbled over.

By injecting packet groups directly down P1 (the same receiver, no shortcut),
for the shapes a 16-byte packet cannot reach and Pokemon Blue does not use:

* **multi-packet ATTR_CHR** — 40 data sets across two packets, and nothing
  written past the count;
* ATTR_LIN horizontal and vertical;
* **PAL_TRN + PAL_SET** — four palettes pulled from system palette RAM, the
  shared colour 0, and the Apply-ATF flag;
* ATTR_SET including its cancel-mask bit;
* **all four MASK_EN modes** — freeze, black, backdrop, release;
* MLT_REQ joypad IDs alternating 0xF/0xE in two-player mode and pinned at 0xF
  in one-player mode.

Each of these was confirmed to actually bite: inverting ATTR_CHR's bit-pair
shift fails 40/40 cells.

### Proof against a real cart (Pokemon Blue)

* Core, headless: the full command log is decoded — MLT_REQ ×2, MASK_EN,
  eight DATA_SND, CHR_TRN, PCT_TRN, PAL_TRN, MASK_EN, PAL_SET, ATTR_BLK ×2 —
  and the border, per-region palettes, intro and title screen all render.
* Native GL path, via `--capture`: the composited 768x672 back buffer is
  correct.
* Web, headless Chromium driving the real app: `_wasm_out_w/h` = 256x224,
  canvas backing 1024x896, `--game-ar` 8:7, border and palettes correct;
  phone portrait (390x844) and landscape (844x390) both lay out correctly.

### Proof that SGB off changes nothing

Frame hashes (FNV-1a over every frame's framebuffer) from this branch with
SGB disabled, against a build of `main`'s `src/`:

| ROM | frames | result |
|---|---|---|
| `gbhdmatest.gbc` | 400 | identical |
| `gblinktest.gb` | 400 | identical |
| Zelda LADX (CGB) | 600 | identical |
| **Pokemon Blue** | 900 | identical |

With SGB on, Blue's hash differs — which is the point. Zelda LADX carries SGB
flag 0x03 *and* CGB flag 0x80 and selects **CGB** in both frontends, which is
what happens when you put one in a Game Boy Color.

The existing suites also still pass: `test_savestate_compat` (the committed
corpus of GB rev 1/2/3 states still loads), `test_rewind`, `test_printer`,
`test_cheats`, `test_timestretch`, all of `web/tests/*`, `web/uv.test.mjs`
and `web/render.test.mjs` (which compiles the *real* shaders in headless
Chromium).

### Performance

The per-pixel hook costs **+0.228% of retired instructions**
(`DINGBAT_BENCH_COUNTERS=1`, `gbhdmatest.gbc`, 600 frames: 5,672,669,709
against 5,659,770,263 with the branch compiled out). That is a predictable nil
check replacing an existing indexed load, and it is inside the noise wall
`docs/performance.md` puts wall-clock A/B at.

### Deliberately not implemented

* **SOUND / SOU_TRN** (the SNES APU), **OBJ_TRN** (SNES sprites),
  **DATA_SND / DATA_TRN / JUMP** (running 65816 code — this is what Space
  Invaders' arcade mode needs), **ATRC_EN / TEST_EN / ICON_EN**. All are
  accepted and dropped, which is what a Game Boy program sees anyway: none of
  them feeds anything back to the GB. Pokemon Blue sends eight `DATA_SND`
  packets and does not care that they go nowhere.
* **PAL_PRI**. It prioritises the game's palette set over one the *player*
  chose in the SGB's own menus. dingbat has no SGB menu, so there is nothing
  to prioritise over and the command is a no-op by construction.
* **The SGB1's 2.4% fast clock.** Real SGB1 hardware chains the Game Boy clock
  to the SNES master clock; SGB2 does not. Modelling it would move
  `GB_CLOCK_SPEED`, which every scheduler deadline in every existing GB save
  state is denominated in. Not worth it for a pitch shift.
* **A built-in border for non-SGB monochrome carts.** The real SGB shows one
  for any mono game. Shipping it would mean shipping Nintendo's art.
* **The 29th border row.** Pan Docs documents that the S-PPU shows part of a
  29th tile row when the SGB forgets to force-blank. Not modelled.
* **The scanline renderer is covered but not the shipping default**; the FIFO
  renderer is, and the test pins them identical.

## 7. Validation (2026-08-07)

### What was available

**There is no Game Boy library on this machine.** `~/Documents/emu/gba/archive/`
holds 7,899 `.gba` files and no Game Boy ROMs at all, and SGB is a Game Boy
feature. The eleven GB/GBC ROMs that exist locally are the whole corpus:

| header (0143/0146/014B) | carts | what they test |
|---|---|---|
| `00/03/33` | Pokemon Blue | the only pure SGB-enhanced cart — everything below rests on it |
| `80/03/33` | Zelda LADX (x2 variants), Pokemon Silver | SGB flag **and** CGB flag: the priority path |
| `00/00/01`, `00/00/60` | Zelda LADX (mono, x2), pocket.gb, Prehistorik Man | no SGB flag: must be untouched |
| `c0/00/33` | Kirby Tilt 'n' Tumble, Pokemon Crystal, Shantae | CGB-only |

So this is one cart deep-verified plus ten negative controls, not a sweep.
§7.4 says plainly what that does and does not buy.

### 7.1 The palettes are numerically right, not just plausible

Blue was driven from power-on through the intro, the title screen, the naming
keyboard, the bedroom, Pallet Town, the party menu, Route 1 and a wild battle,
and the live SGB palette registers were read out at each. Against Bulbapedia's
table of the Generation I SGB palettes (`List of color palettes by index number
in Generation I`), converted from 24-bit RGB to BGR555:

| scene | dingbat's live palette | reference | |
|---|---|---|---|
| Pallet Town | `6F99` `7F54` | Pallet 0x01 `#CEE7DE` `#A5D6FF` → `6F99` `7F54` | exact |
| Route 1 | `2F95` `7F54` | Route 0x00 `#ADE75A` `#A5D6FF` → `2F95` `7F54` | exact |
| battle, palette 2 | `2A9F` `195A` | RedMon 0x12 `#FFA552` `#D65231` → `2A9F` `195A` | exact |
| battle, palette 3 | `3E9C` `25D5` | BrownMon 0x15 `#E7A57B` `#AD734A` → `3E9C` `25D5` | exact |
| battle, palette 1 | `029A` | YellowMon 0x18 `#D6A500` → `029A` | exact |
| title screen | `47DE`, `1015` | logo `#F7F78C`, `#AD0021` → `47DE`, `1015` | exact |

Every value matches to the bit. And the **assignment** is right, not just the
values: the player's Charmander gets the Red-Pokemon palette and the wild
Pidgey gets the Brown-Pokemon palette, in the same battle, at the same time.
That is `PAL_TRN` + `PAL_SET` selecting from the 512-entry system palette RAM
by species — the single hardest thing in this feature to get right by accident.

### 7.2 The attribute map is doing real work

The `ATTR_*` region count per scene, straight out of the live attribute map
(cells per palette 0/1/2/3):

| scene | attr | reading |
|---|---|---|
| intro battle | 200 / 160 / 0 / 0 | two regions: the animation band and the frame |
| title, main menu | 160 / 40 / 160 / 0 | three: logo, subtitle, background |
| Oak's intro, dialogue | 360 / 0 / 0 / 0 | one palette, two shades — the text box is shade work, not attribute work |
| party menu | 61 / 299 / 0 / 0 | the Pokemon's row is its own region |
| overworld (Pallet, Route 1) | 360 / 0 / 0 / 0 | one palette per map, which is what Gen I does |
| **wild battle** | 65 / 40 / 192 / 63 | **all four** — enemy box, HP bar, field, player box |

The overworld being a single region is correct behaviour, not a gap: Gen I
changes the whole-screen palette per map rather than dividing the screen up.
The place it divides the screen is menus and battles, and it does.

### 7.3 Robustness, since breadth was not available

`sweep.sh` — byte identity, **1500 frames x 11 ROMs x {SGB off, SGB on} x two
baselines** (this branch's merge-base with `main`, and `main`'s tip; the GB
core is untouched between them, and the two agree everywhere). Two channels
per run: a fold of every frame's framebuffer, and a fold of the whole
save-state payload every 64 frames.

> With SGB **off**, every one of the eleven is identical to the baseline.
> With SGB **on**, every one is identical *except* Pokemon Blue.

Two traps this sweep walked into first, both worth remembering: the emulator
writes a cart's `.sav` next to the ROM, so a save left by one run is loaded by
the next and two runs of the same binary silently differ (ROMs are reached
through symlinks in a scratch dir now, and saves are cleared between runs);
and MBC3+RTC carts seed from wall-clock time, so Silver's and Crystal's state
payload is legitimately different on every run and the state channel is
skipped for them.

`stress.nim` — nine sections, all passing:

1. all three CGB+SGB carts (`80/03/33`) select **CGB**, with the adapter absent
   and the renderer hook nil;
2. **900 consecutive save+restore round trips**, one per frame straight through
   the transfer window, compared against an uninterrupted reference run;
3. the **rewind** shape — snapshot every frame, jump six back, replay forward;
4. the **run-ahead** shape — save, run a speculative frame, roll back, every
   frame;
5. reset at every 20th frame of the transfer window leaves the next run clean;
6. a state crossing the SGB setting, **in both directions, at every phase**;
7. border validity is monotone and the border is re-rendered a bounded number
   of times (it settles at generation 2 and never moves again);
8. every non-SGB cart gets no adapter even when one is requested;
9. `MASK_EN` is genuinely exercised (modes 0 and 1), the longest mask is 69
   frames, and the screen is never left masked.

The first three shapes are now also in `tests/sgb_test.nim` against the
synthetic cart, so they run in CI without needing a commercial ROM.

**`tools/gbfuzz` cannot be used as an SGB oracle as it stands.** Both reference
runners deliberately refuse SGB — `mgba_gb_runner.c` pins `sgb.model` /
`cgb.sgbModel` to follow the cartridge's CGB flag "never SGB", and
`sameboy_runner.c` says the same, both because an SGB frame is 256x224 and the
harness compares 160x144. Turning it into an SGB differential harness means
enabling SGB in both runners and teaching the comparison about the larger
frame. That is the highest-value next step and it is not small.

### 7.4 Residual risk — read this before shipping

**Validated:**

* one SGB-enhanced cart, deeply: eight distinct scenes, palettes checked
  numerically against a published reference, attribute regions checked per
  scene, border stable across every scene change;
* that cart's `MLT_REQ` detection handshake — Blue opens with two `MLT_REQ`
  packets and only continues sending if it believes an SGB answered, and it
  does continue;
* the mode-priority rule against all three CGB+SGB carts present;
* non-interference against ten carts and two baselines, off and on;
* every save/restore shape the emulator has, driven through the transfer window.

**Not validated:**

* **any cart other than Pokemon Blue.** Nothing here says anything about how
  the other ~500 SGB-enhanced titles behave. The commands Blue never sends —
  `ATTR_LIN`, `ATTR_CHR`, `ATTR_TRN`/`ATTR_SET`, `ATTR_DIV`, `PAL01`–`PAL12`
  as direct sends, `OBJ_TRN`, `PAL_PRI` — are unit-covered only, against a
  synthetic cart whose expectations I wrote. A cart that uses them differently
  from how I read Pan Docs would not be caught.
* **borders that overlap the Game Boy window** (Mario's Picross, WildSnake).
  The compositor handles it by construction and the synthetic ROM has a
  transparent centre; no cart here proves it.
* **two `CHR_TRN`s for a 256-tile border.** Blue sends one. The immediate-read
  ordering was chosen specifically to make that case work, and it is untested
  against a real cart.
* **`MASK_EN` modes 2 and 3.** Blue only uses mode 1.
* **anything SGB-multiplayer past the joypad IDs.** The counter and mask are
  now pinned to hardware by three test ROMs (below), but no second controller
  is wired to anything.
* **cross-emulator agreement.** No SGB oracle was run at all — see gbfuzz above.

**Since validated by test ROMs** (all three pass byte-exactly against their
reference images, and the two SameSuite ones run in the local suite as
`same-suite/sgb/*`):

* `samesuite/sgb/command_mlt_req` and `.../command_mlt_req_1_incrementing` —
  the joypad-ID counter, its free run over packet pulses, the per-request mask
  and the glitched request 2. See §2.2, Tier 3.
* `cpp/sgb-ext-test` (CasualPokePlayer) — the packet transport against nine
  deliberately malformed transfers: which edge carries a bit, what a truncated
  reset does, what a mid-bit reset does, and that the stop bit's value is
  ignored. See §2.1. This is the only coverage the transport has that is not
  a well-formed packet.

**Honest summary:** the *mechanism* is well tested and the *one cart that
exercises it* is right to the bit. The breadth is missing, and only a library
can supply it.

---

### Re-verified against today's main (2026-08-07, after the merge)

The byte-identity claim above was first made against the `main` this branch was
cut from. `main` has since taken GB core work (the `fifo_mix` refactor that
this branch's SGB hook now sits inside), a rewind delta codec, save-state
loader hardening and web changes — so that claim had expired, and the only
version of it worth anything is the one against the `main` that exists now.

Re-run at `0aafb51` — which is `main` after it took this branch's earlier
SGB work, so the comparison is now "did the merge and the glow change disturb
anything" rather than "is the feature inert" — 400 frames per cart, both channels (a fold of every
frame's framebuffer, and a fold of the whole save-state payload every 64
frames, so state that has not reached the screen yet is still compared):

| header | carts | SGB off | SGB on |
|---|---|---|---|
| `00/03/33` | Pokemon Blue | identical | **differs** — the intended unlock |
| `80/03/33` | Zelda LADX, LADX DX, Pokemon Silver | identical | identical |
| `c0/00/33` | Kirby Tilt 'n' Tumble, Pokemon Crystal, Shantae | identical | identical |
| `00/00/01`, `00/00/60` | Zelda LADX mono (x2), pocket.gb, Prehistorik Man | identical | identical |

Eleven carts, both switch positions, zero unexpected differences. **With the
SGB switch off the adapter is not there**, byte for byte, against the `main` of
today rather than the one this branch was cut from. The two RTC carts
(Crystal, Silver) skip the state channel only: their payload seeds from
wall-clock time and legitimately differs run to run.

The merge also *fixed* something rather than merely surviving. `main` split the
shifter's colour decision out into `fifo_mix`, which is what
`fifo_recompose_last` calls as well — so moving the SGB substitution in there
means a register write that re-colours the previous dot now gets the SGB
palette too. The original placement, in the shifter alone, missed that path.

## 8. The ambient glow samples the composite, not the framebuffer

Added 2026-08-07, after the border landed.

The glow is a 24x16 halo blurred behind the screen. It sampled
`_wasm_fb_ptr` — the **game** framebuffer — which stopped being the right
picture the moment an SGB border existed: under a border the Game Boy screen
occupies the middle 160x144 of a 256x224 picture, so the halo was a blur of
edges the user cannot see. Pokemon Blue bleeds overworld greens out from
behind a Poke Ball border that is almost entirely blue.

Matt's generalisation is the right frame: this is one question, not two. If
the glow samples the wrong stage it will mismatch for colour correction and
for any future filter too. So the question is **what stage should it sample**,
and the answer is: **the composited picture, before presentation effects.**

### What that means concretely

Sampled:

* the SGB border layer, where it is opaque — unpacked 5-to-8 bit with **no**
  panel model, because border art is native SNES output and the shader does
  not correct it either;
* the Game Boy window — through the colour LUT, so the halo follows the
  correction toggle and any curve added later, because the LUT is the one
  place the curve lives;
* the DMG shade palette substitution, which is display-space and bypasses the
  panel model exactly as it does in the shader;
* the SGB backdrop, where neither layer covers.

Deliberately **not** sampled, with the reasoning written at the code:

| excluded | why |
|---|---|
| upscale filters (hq4x / xBR) | at one sample per ~100 output pixels the filter cannot change the answer, and running it would cost real work for a difference nobody can see |
| scanlines | they darken every other row by 28%; a point sample lands on a dark row about half the time, so the halo would flicker as an artefact of *where the grid fell* rather than of the picture |
| integer-scale letterbox bars | the bars are black and are not part of the picture; sampling them would wash the glow toward black in exactly the configuration where the screen is smallest and the glow matters most |

"The composited surface" is therefore **not** "the final framebuffer". Reading
back the presented canvas would have swept in all three, *and* forced a
GPU→CPU sync every 100 ms that the current path does not have. It was
rejected on both counts.

### Where it lives, and whether one point serves both frontends

**One frontend, not two: the native frontend has no ambient glow.** The
feature is web-only, so there is one sampling point to place.

It went into wasm (`wasm_glow_sample`) rather than JS, because that is where
the colour LUT and the border already are. A second copy of the panel model in
JS would drift the first time a correction curve is added on one side only —
which is precisely the failure the selectable-curves workstream would
otherwise walk into. The shade palette is passed **in** as an argument rather
than stored, so it still never reaches emulated state (which is what keeps
save states, rewind and netplay byte-identical).

### Cost: it got cheaper, on both profiles

Matt asked for confirmation that this is not a performance hit, and the answer
is that it is a performance *win* — for a structural reason, not a lucky one.
The old path converted the **whole** frame through the colour LUT (23,040
pixels for a Game Boy, 38,400 for a GBA) and then point-sampled 384 of them.
The new one composites and converts only the 384 cells asked for.

**Measurement conditions, stated because they matter.** These were taken on a
machine under heavy concurrent load (load average 14–23; five sibling agents
building Nim and driving headless browsers). Two things make the result
survive that:

1. **The arms are interleaved, not sequential.** Both run in the same page on
   alternating glow ticks — OLD, NEW, OLD, NEW at ~10 Hz. Load drifts over
   minutes, not between two ticks 100 ms apart, so the paired difference is not
   at the mercy of what else started halfway through.
2. **Each timing window batches 25 repetitions.** `performance.now()` is
   coarsened to 100 us in a page that is not cross-origin-isolated, and a
   single call of either arm is well under that — it quantises to 0.0 or 0.1
   and any median of single samples is pure clock artefact. Batching resolves
   it. Both arms pay the same batching, so the ratio is unaffected; the batch
   loop does warm the caches, which is why these absolute figures sit below the
   unbatched ones in the second table.

Medians with the interquartile range as spread, 40 s per profile:

| | OLD per-call | NEW per-call | ratio |
|---|---|---|---|
| desktop, no border | 0.0400 ms [0.0360, 0.0480] | 0.0080 ms [0.0080, 0.0120] | **0.20** |
| desktop, SGB border | 0.0440 ms [0.0440, 0.0480] | 0.0120 ms [0.0080, 0.0120] | **0.27** |
| phone, no border | 0.1400 ms [0.1320, 0.1480] | 0.0320 ms [0.0160, 0.0360] | **0.23** |
| phone, SGB border | 0.1480 ms [0.1320, 0.1520] | 0.0300 ms [0.0200, 0.0360] | **0.20** |

**The interquartile ranges do not overlap in any of the four rows** — the
spread is nowhere near the difference, so this is a point estimate rather than
a bound. Phone is 390x844 @ dpr 3 with CPU throttled 4x, the profile the
original figure used.

And per **frame**, which is the budget question, since the glow works on one
rAF in six. Measured the unbatched way, so it is directly comparable to the
0.0122 ms/frame desktop and 0.045 ms/frame phone figures already on record for
the whole feature:

| | before | after |
|---|---|---|
| desktop, no border | 0.0153 ms | **0.0080 ms** |
| desktop, SGB border | 0.0131 ms | **0.0099 ms** |
| phone, no border | 0.0560 ms | **0.0288 ms** |
| phone, SGB border | 0.0506 ms | **0.0439 ms** |

The point sample stays a point sample. An area average over the same grid was
measured at 0.0070 -> 0.1386 ms per sample for a quality gain invisible behind
a 28-pixel blur, and moving the sampling point does not revive it.

### The ordinary case is provably unchanged

The risk in moving a sampling point is that you fix the case you were looking
at and quietly change every other one. So: with no SGB and no border, where the
"composite" is just the game window and there is nothing to composite, the new
sampler is compared against the old sampling of the same frame.

**Zero of 1152 channels differ** (24x16 cells, three channels), and all 384
cells are non-black. The change is a strict superset — identical where there is
nothing to composite, correct where there is.

### What it looks like

`web_15_glow_sampling_compare.png` is the whole argument in one image: the
screen on the left (a blue Poke Ball border framing a cream battle box), the
old glow surface in the middle — uniformly cream with a green smear, no blue
anywhere — and the new one on the right, a blue frame around a cream centre.
Both are shown as sampled and as the user sees them, blurred.

A trap for whoever regenerates these: `toDataURL()` on the game canvas returns
**black**. The WebGL context has no `preserveDrawingBuffer`, so the drawing
buffer is already gone by the time a readback asks for it. Take an element
screenshot instead.

## 9. Known rough edges

1. **The window resizes mid-session** (native) when a border first appears,
   because the picture genuinely changes size. It is one resize, on the edge,
   and it is what a console does.
2. **`MASK_EN 1` freezes the frame the emulator last presented**, not the one
   the SNES last stored. Pan Docs notes hardware needs "one or two frames"
   before a freeze is reliable. No cart has been seen to care.
3. **A VRAM transfer is read at packet completion**, not spread over the five
   frames hardware takes. Pokemon Blue's display is byte-stable across all
   five frames after each of its three transfers, and reading early is the
   only order that survives the two-`CHR_TRN` pattern — but a cart that starts
   rewriting VRAM in the same frame it sends the packet would break.
4. **Objects are ignored during a transfer.** Pan Docs requires that they not
   overlap the background there; a cart that violates it would corrupt its own
   border on hardware too.
5. **One real cart is one real cart.** Blue exercises the packet receiver,
   both VRAM transfers, PAL_TRN/PAL_SET, ATTR_BLK, MASK_EN and MLT_REQ.
   ATTR_CHR/ATTR_LIN/ATTR_TRN and multi-packet groups are unit-covered only.
   A wider sweep (`tools/gbfuzz` already knows how to walk a library) is the
   obvious next step.
6. **The window resize is now much less of a surprise** than it was when this
   defaulted on: it only happens to someone who went and turned Super Game Boy
   on, reloaded the game, and is watching for it.
7. **Turning the mode on or off needs a ROM reload.** The adapter is chosen
   when the cartridge is inserted. Both frontends say so — an always-visible
   line under the native checkbox, a toast plus the pane's `settings-note` on
   the web. The *border* toggle is live.
8. **A pre-existing config that already has `gb: sgb: true`** — which only
   exists if someone ran a build of this branch from before the default was
   flipped — keeps it on. That is correct (it is an explicit stored value);
   flip the toggle or delete the two lines to get the new default.
9. **The save-state downgrade is one-way**: a state written by this build for
   an SGB cart is refused by an older build (`rev 5 > 4`). States for every
   other cart are byte-identical. Same class as the sub-1 MiB GBA identity fix.
