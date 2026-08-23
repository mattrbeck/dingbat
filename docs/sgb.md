# Super Game Boy: borders and palettes

Module: `src/dingbat/gb/sgb.nim`. Test: `nimble test_sgb` (`tests/sgb_test.nim`
against `tests/roms/sgbtest.gb`, built by `tests/roms/sgbtest.py`). Spec:
[Pan Docs, SGB Functions](https://gbdev.io/pandocs/SGB_Functions.html) and its
sub-pages (Command Packet, VRAM Transfer, Color Palettes, Unlocking).

## Detection and mode

1. The cart header must carry **both** `$0146 = $03` and `$014B = $33`
   (Pan Docs, "SGB Unlocking"); a cart with only one gets nothing.
2. A cart that is also CGB-capable (`$0143` bit 7) runs as a **CGB**, never as
   an SGB — the two are mutually exclusive on hardware and the CGB path is what
   a Game Boy Color does with such a cart. `force_dmg` may fall through to SGB.
3. The adapter is opt-in: `gb.sgb_enable` (native config), `sgbEnable` (web
   `"system"` record), `GB.sgb_requested` for harnesses. Default off everywhere.
   A missing key keeps the default; nobody silently gains an adapter.

Attaching promotes `boot_model` `bmDmgABC → bmSgb`, so the boot seeds
`C = $14` (Pan Docs, "SGB Unlocking": the register-based detection) and the
SGB DIV phase apply. Whether a machine *has* an SGB is decided by header plus
opt-in, never by a save state, so toggling the mode is a ROM reload, not a live
setting. The border toggle is live.

## Transport: the P1 pulse stream

Packets arrive as pulses on P1 bits 4/5 (Pan Docs, "SGB Command Packet"): both
low = reset / start of packet; P14 low = `0`, P15 low = `1`; both high = the
space between; 16 bytes LSB-first per packet then a stop bit; byte 0 of the
first packet is `command shl 3 or length` (1..7 packets per group). The
encoding is self-clocking, so the receiver is a pure state machine over P1
writes — Pan Docs' 5/15 M-cycle pulse/space convention is a margin for real
silicon, not something an emulator enforces.

Details Pan Docs leaves open, pinned by `cpp/sgb-ext-test` (CasualPokePlayer;
passes byte-exact):

* **A bit is sampled at the release edge**, reading whichever line is low at
  that moment (`SendPacket20To10` reads a 1, its mirror a 0).
* A release only carries a bit if the line went low *from both-high*: a pulse
  entered straight from the reset is dropped (`SendPacketShortStart`).
* A `$00` mid-pulse abandons the bit in flight; a stream that never returns to
  both-high is received as nothing (`SendPacketAvoid30`).
* The stop bit's value is ignored (`SendPacketCorruptStop`).
* The "previous lines" latch must start at both-high, or a game's very first
  reset pulse is not an edge and its first packet (often `MASK_EN` or
  `CHR_TRN`) is lost — which presents as a transparent border, not a decode bug.

## VRAM transfers are read out of the display

`*_TRN` commands make the SNES read 4 KiB out of the Game Boy's video signal
(Pan Docs, "SGB VRAM Transfer"). Pan Docs says the data is "normally" at
`$8000-$8FFF`; the mechanism is the precondition list above that sentence
(characters `$00-$FF` on screen, display on, no scroll, `BGP = $E4`). Pokemon
Blue runs its transfers with `LCDC = $E3` (LCDC.4 clear, so character `$00`
lives at `$9000`), where a flat `$8000` read returns zeroes. `sgb_read_transfer`
therefore walks the display — per character the BG map cell (honouring
SCX/SCY and LCDC.3) and the tile through LCDC.4's addressing — which equals
the flat read whenever the preconditions hold.

The read happens at packet completion, not a frame later: Pan Docs requires
the data in VRAM before the packet is sent, and a deferred read breaks the
"two `CHR_TRN`s around one VRAM rewrite" pattern. Objects are ignored during a
transfer (Pan Docs requires they not overlap the background there).

## Commands

| Cmd | Name | Modelled |
|---|---|---|
| `$00-$03` | `PAL01/PAL23/PAL03/PAL12` | yes — colour 0 is one shared backdrop across all four palettes, set by whichever command last assigned it |
| `$04-$07` | `ATTR_BLK/ATTR_LIN/ATTR_DIV/ATTR_CHR` | yes, incl. multi-packet `ATTR_CHR` and `ATTR_BLK`'s inside-only line rule |
| `$0A/$0B` | `PAL_SET/PAL_TRN` | yes — 512-entry system palette RAM, Apply-ATF flag |
| `$11` | `MLT_REQ` | yes — joypad IDs on P1 (below) |
| `$13/$14` | `CHR_TRN/PCT_TRN` | yes — 128 4bpp tiles per call, 32x28 map + border palettes 4-6 |
| `$15/$16` | `ATTR_TRN/ATTR_SET` | yes — 45 attribute files, cancel-mask bit |
| `$17` | `MASK_EN` | yes, all four modes; mode 1 freezes the frame the emulator last presented (Pan Docs: hardware needs "one or two frames") |
| `SOUND/SOU_TRN/OBJ_TRN/DATA_SND/DATA_TRN/JUMP/ATRC_EN/TEST_EN/ICON_EN/PAL_PRI` | | accepted and dropped; none feeds anything back to the GB. `PAL_PRI` is a no-op by construction (no SGB menu to prioritise over) |

The attribute map does not scroll and objects take the palette of the screen
cell they land on — the SNES colourises the composited 2-bit signal (Pan Docs,
"SGB Color Palettes"). Palettes without `ATTR_*` paint the whole screen in
palette 0; do not ship one without the other.

### `MLT_REQ` joypad IDs

Pinned by `same-suite/sgb/command_mlt_req` and `command_mlt_req_1_incrementing`
(both byte-exact). The counter is not "reset to player 1 and advance per poll":

* it **free-runs on every P15 rising edge**, including the pulses a command
  packet is made of (`$89 $01` advances it five times, `$89 $03` six — one
  reset pulse plus one P15 pulse per `1` bit); `MLT_REQ` only ANDs it with the
  new player mask;
* request 2 is not a documented mode (Pan Docs lists 0, 1, 3); hardware
  behaves as mask 2, which sticks the ID (`(n+1) and 2` never moves from 0 or
  2), and request 2 advances the counter once as it lands where 0/1/3 do not.

In one-player mode the mask is 0, so P1 reads the same `$F` a handheld does.

## Rendering

**Colour is applied in the pixel emit, not a post-pass.** `GbPpu.sgb_pal` /
`sgb_attr` are nil on every non-SGB machine and tested once per pixel
(3 sites in `scanline_ppu.nim`, 1 in `fifo_ppu.nim`; the substitution sits in
`fifo_mix`, so `fifo_recompose_last` recolours too). Cost is +0.23 % retired
instructions (`DINGBAT_BENCH_COUNTERS=1`), the price of not carrying a second
framebuffer: a post-pass reverse-mapping `DMG_COLORS` is ambiguous once the
framebuffer holds SGB colours (LCD off, `MASK_EN` freeze).

**The border is a second surface.** The core keeps emitting 160x144 and
exposes `gb.sgb.border`, 256x224 BGR555 with bit 15 = opaque (SNES colour 0
transparent, so borders that cover the window — Mario's Picross, WildSnake —
work). Thumbnails, rewind, netplay, printer, camera and every 160x144 literal
stay untouched and byte-identical with the border off. Re-uploaded only when
`SgbState.border_gen` moves.

Both frontends composite in one pass with two samplers: opaque border wins,
else the GB window with its filters, else the SGB backdrop. Border art takes
neither colour correction nor upscale filters (native SNES output; the filters
are tuned for 2bpp art). The scanline pitch is its own uniform
(`u_scan_height` = 224 with a border). `output_size()` / `_wasm_out_w/h` are
authoritative for the picture size; `gameRes()` consumers (thumbnails, glow,
paused card, bug report) keep the console framebuffer. The web DMG shade
palette is disabled with an explanation while an adapter is active — its
shader substitution keys on the four `DMG_COLORS` words, which an SGB frame
does not contain.

Native letterboxes under `preserve_aspect` (default on) and resizes the window
once on the edge where a border appears or disappears. The desktop vertex
shader's negative V means the border texture must use `GL_REPEAT`, not
`CLAMP_TO_EDGE` (which pins the border to row 0 and renders stripes), and the
GB window rectangle is computed un-flipped and flipped back.

The ambient glow (web) samples the **composited picture before presentation
effects** — border (no panel model), GB window through the colour LUT, shade
palette, backdrop — via `wasm_glow_sample`; upscale filters, scanlines and
letterbox bars are deliberately excluded. `toDataURL()` on the game canvas
returns black (no `preserveDrawingBuffer`); take an element screenshot.

## Save states

Section `GB_SEC_SGB = $BB`, `GB_PAYLOAD_VERSION` 5, written only when
`gb.sgb != nil`: palettes, attribute map, system palette RAM, attribute files,
border tiles/map/palettes, `MASK_EN` + frozen frame, and the packet-decode
state machine (a state taken mid-packet resumes mid-packet). Derived, not
serialized: the decoded border image (re-rendered inline in the loader so the
window does not blink 256→160→256) and the two PPU hook pointers.

The reader **peeks the tag**: a state saved with SGB on loads with SGB off
(section read into a throwaway) and vice versa, decided by the payload, not
this machine's configuration. Pinned both directions in `tests/sgb_test.nim`.
A rev-5 state for an SGB cart is refused by pre-SGB builds; states for other
carts are byte-identical. See `docs/savestate_compat.md`.

## Settings

* Native: Settings ▸ Video, "Super Game Boy mode" (applies on next ROM load —
  an always-visible note says so), "Show SGB border" (live, disabled while the
  mode is off), "Preserve aspect ratio". Config keys `gb: sgb_enable`,
  `gb: sgb_border`, `preserve_aspect`.
* Web: Settings ▸ Game Boy, "Super Game Boy mode" (next load; toast if a game
  is running) and "Show border" (live). Persisted in the `"system"` IndexedDB
  record; covered by "Reset all settings".

## Deliberately not modelled

* SNES APU, SNES sprites, `DATA_SND`/`JUMP` 65816 code (Space Invaders'
  arcade mode), SNES-side UI commands.
* The SGB1's 2.4 % fast clock (SGB2 does not have it): it would move
  `GB_CLOCK_SPEED`, which every GB save state's scheduler deadlines are
  denominated in.
* A built-in border for non-SGB mono carts (Nintendo's art).
* The 29th border row the S-PPU shows when the SGB forgets to force-blank
  (Pan Docs, "SGB Command Border").
* A VRAM transfer spread over the five frames hardware takes; a cart that
  rewrites VRAM in the frame it sends the packet would break.

## Coverage

Real-cart proof is Pokemon Blue only (packet receiver, both transfers,
`PAL_TRN/PAL_SET`, `ATTR_BLK`, `MASK_EN 1`, `MLT_REQ`; palettes match
Bulbapedia's Gen I SGB palette table to the bit). `ATTR_CHR/ATTR_LIN/ATTR_TRN`,
multi-packet groups, `MASK_EN` 2/3, overlapping borders and two-`CHR_TRN`
borders are covered only by the synthetic cart. `tools/gbfuzz` cannot be an
SGB oracle as built: both reference runners pin SGB off and compare 160x144.
