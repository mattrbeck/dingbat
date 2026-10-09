# DS games: the app features that were off, and cheap wins

Status (2026-10-08, branch `nds-features`): **rewind, run-ahead and cheats
(Action Replay DS, unencrypted CodeBreaker DS) work for DS games in the web
app**. Clips, the rewind scrubber, the link cable and the library-pictures
batch are still off. The iOS app still gates all of them for DS games.

## Where each one stands

| Feature | Before | Why it was off | Now / what it would take |
|---|---|---|---|
| Save states, slots, resume | on | -- | (docs/nds/savestate.md) |
| Fast-forward, 2x, slow motion, frame step | on | -- | unchanged. Fast-forward runs 12 ms of frames a tick (~3-4x on SoulSilver). Skipping the drawing of frames nobody sees would roughly double it, but display capture writes drawn frames into VRAM, so a skipped frame changes the machine unless capture is off: 1-2 agent-days, careful. |
| **Rewind** (hold) | off | not wired: the core had the hooks (`state_payload` / `load_state_payload`) but no ring in either front end | **on** (web). The GB/GBA ring (`common/rewind.nim`) fed every 10 frames; the Rewind switch, the button and the backquote key reach it. iOS: the same ring is gated for `ekNDS` in `dingbat_ios.nim`; about half a day to lift. |
| Rewind scrubber, Report a Bug's timeline | off | needs thumbnails in the ring and the scrub exports | still off. ~1 agent-day (thumbnails of both screens at push time, the `*_scrub_*` exports, the JS side already exists). |
| **Run-ahead** | off | not wired; a DS snapshot was assumed too dear (it is not: under a millisecond each way) | **on** (web, opt-in as for GB/GBA). Run-ahead n costs n + 1 frames: see "Cost". iOS: gated in `dingbat_ios.nim` `runahead_tick`; ~half a day. |
| **Cheats** | off | no DS engine (the GB/GBA engines are the other cores') | **on** (web): `nds/cheats.nim`. iOS: the cheat list UI is shared; wiring the DS engine is ~half a day. |
| Encrypted CodeBreaker DS | -- | needs the game's *encrypted* secure area (the core has the KEY1 code to make it) | ~1 agent-day on top of the engine (GBATEK gives the whole cipher). |
| Record (video) | off | gated with Clip that!; the DS sound does not reach the clip tap (its worklet plays into the master gain) | ~half a day: the picture already works (`nativeFrameCanvas` draws both screens); route the DS worklet into the tap too. |
| Clip that! (retroactive) | off | replays the GB/GBA core's input log from anchor states | 2-3 agent-days: an input log of buttons, stylus *and* microphone per frame, anchors from the rewind ring or states, the encoder fed both screens. |
| Link cable / wireless | off | DS wireless is the core's `Air` (two machines in one process, docs/nds/wifi.md); nothing crosses browsers | Two games in one tab: memory (a 128 MB ROM leaves a 272 MB heap each). Across browsers: the Air's frames over WebRTC with a timing model: 10+ agent-days. |
| Library pictures batch | off | boots games on the GB/GBA core | ~1 agent-day (boot on the DS core headless, take the top screen at a frame). |
| Drive sync | off (decision) | main has no DS core (docs/nds/web.md) | blocked on DS reaching main. |

## What the prototype does

**Rewind.** `src/dingbat_nds_wasm.nim`: `nds_rewind_enable(on, cap)`,
`nds_rewind_pop()`, `nds_rewind_depth()`, `nds_rewind_bytes()`. After each
frame (`step_frame`) the ring takes a payload when one is due (every 10
frames, as GB/GBA). No keyframes (each would be a 2 MB zlib of the whole
payload, a visible stall every 10 seconds; they only speed up scrubber
seeks, and there is no DS scrubber) and no thumbnails. A pop applies the
snapshot with `load_own_payload` (below). The ring starts empty at every
boot, reboot and state load. Cap: 64 MB, 16 MB on iOS (as GB/GBA).
`index.js`: `ndsApplyRewind` follows the Rewind switch, `ndsRewindStep`
pops ~30 snapshots a second while rewind is held (5x speed backwards, as
GB/GBA), `body.nds-rewind` shows the button.

**Run-ahead.** `nds_runahead(n)`: after the frame the page will show (its
sound already taken), snapshot, run `n` frames (cheats applied as in a
real frame), copy both screens out, go back. `nds_fb555_top/bottom` point
at the copies until the next frame runs, so the presenter needs no change.
`load_own_payload(as_new = false)` keeps the save chips' dirty flags (a
state load sets them, which would store the save every 5 seconds); the
firmware's dirty flag is kept too (the firmware is not in a state: a
flash write during the lookahead stays written and is written again,
identically, by the real frame). `index.js` runs it once a tick, after the
last frame of the tick, at normal speed only.

**`load_own_payload`** (`nds/savestate.nim`): a payload this machine took
itself, applied without the backup walk `load_state_payload` takes first
for a refusal it can never meet (half the cost).

**Cheats.** `src/dingbat/nds/cheats.nim`, from GBATEK "DS Cart Cheat
Action Replay DS" and "DS Cart Cheat Codebreaker DS":

- Action Replay DS: 0/1/2 writes, 3-A conditions (nested), B, C0 loops with
  D1/D2, C5 counter, C6, D0, D3-DC (offset and data registers), E
  parameter copies, F memory copies; the v1.54 rules (address 0 in a
  condition reads [offset]; DB leaves the offset alone). C4 (the offset
  becomes the code's own address in the device's code list, which is not
  in the DS here) is refused. Hook lines (`00000000 XXXXXXXX`) are writes to
  address 0, which ignores stores.
- CodeBreaker DS, when the first line is the unencrypted header `8000CR16
  GAMECODE` (checked against the ROM header): writes, add, OR/AND/XOR,
  fill, copy, pointer write (and its conditional form with the line skip
  GBATEK calls a bug), D conditions. Encrypted lists, BEEFC0DE and the
  hooks are refused with a reason.
- Each cheat is its own list: registers fresh every frame, the C5 counter
  its own and kept. A cheat stops after 2^18 steps a frame.
- Run once a frame at the start of V-blank (after `run_frame`), through
  `nds.nim` `cheat_read` / `cheat_write`: no cycles charged, no I/O side
  effects. Reads give what the game sees (main RAM through the ARM9's
  data cache); a store goes to memory's side as an ARM7 store does
  (instruction-cache copies kept) **and** to the ARM9's cached copy, so a
  value poked into a line the data cache holds is not lost when the line
  is evicted clean. Decision: a real device runs its list on the ARM7 and
  sees memory's side only (GBATEK notes the cache problem); the coherent
  poke makes codes take on games that keep hot variables in a cached line.
  Of the I/O ports only KEYINPUT and EXTKEYIN read (the button
  activators); the TCMs, VRAM and the rest of I/O read 0 and ignore stores.
- The list lives in the wasm module, not the core: a reset keeps it.
  `nds_load_cheats` takes the app's `.cht` text (the same list, the same
  `cheats:<game>` record, the same modal), and returns "name: why" for
  each refused cheat. The format hint names the DS formats.

With no cheat on, rewind off and run-ahead 0, `step_frame` is
`run_frame`: nothing new runs. The rewind ring is on by default (as on
GB/GBA); taking a payload has no side effect on the machine (below).

## Evidence

- `tests/nds_cheats_test.nim` (`nimble test_ndscheats`): every code type
  above against a flat memory -- writes, the four word and four masked
  conditions, nesting, B/D3-DC, loops with D1 and D2's flush, C5 every
  fourth frame, E/F, a 2^32-pass loop that returns, CodeBreaker's codes,
  and every refusal.
- `web/e2e/nds.e2e.mjs`, three tests (headless Chromium, muted):
  - rewind: 100 frames of `built/Double_Buffer` with the ring, three pops
    go back 20+ frames, the screens are that frame's, and the next 15
    frames replay exactly (screens and sound); holding the real #rewind
    button half a second runs the frame counter back; Rewind off in
    Settings drops the ring and hides the button.
  - run-ahead: from a state, 90 frames plain and with run-ahead 2: every
    frame's screens and sound identical; each shown frame is the frame two
    on; `snd_tone` with run-ahead 3: the same sound every frame.
  - cheats on `cheat_probe` (ours: `tests/nds/src/cheat_probe`, built by
    `tests/nds/tools/build_fb.sh`; its top screen is the halfword at
    0x02100000): C4 and malformed codes refused in the modal; AR word write
    (blue), a KEYINPUT condition (green while A is held), a C0/D1 loop
    summing the data register then D3/D7 (white), a CodeBreaker list with
    the ROM's header (yellow); unticking one; the list back after a
    reload.
- Commercial games (local only: `DINGBAT_NDS_BENCH=<rom> node --test
  e2e/nds.e2e.mjs`, "leave DINGBAT_NDS_BENCH's frames as they were"): from
  frame 1500 of Pokemon SoulSilver, Golden Sun: Dark Dawn and Mystery
  Dungeon: Explorers of Darkness, 300 frames plain, with run-ahead 1, and
  with run-ahead 3 plus the rewind ring: **zero frames differ** (screens
  and sound; 166 / 187 / 67 distinct screens, sound every frame); the
  run-ahead frame shown is always the next frame; after 5 pops the next
  40 frames replay identically.

## Cost

The machine was shared with other jobs (load average 140-670), so each
figure is the **fastest of 30-600 runs** (the minimum resists load; the
medians ran 1.5-4x higher), and the frame A/B times the same frame each
way, alternated in one loop. Wasm: headless Chromium on Apple Silicon,
`DINGBAT_NDS_BENCH=<rom> node --test e2e/nds.e2e.mjs` (the "what they
cost" test); native: a scratch program on `load_own_payload`, same
structure, `-d:danger`.

| | SoulSilver (wasm) | Golden Sun: Dark Dawn (wasm) | SoulSilver (native) |
|---|---|---|---|
| raw payload | 6.15 MB | 6.41 MB | 6.15 MB |
| `state_payload` | 0.2-0.5 ms | 0.5 ms | 0.40 ms |
| `load_own_payload` | 0.2-0.5 ms | 0.5 ms | 0.38 ms |
| `load_state_payload` (with the backup walk) | 0.8-1.1 ms (median) | | |
| a packed state (slot, resume) | 40-50 ms (median), 1.6 MB | | |
| the frame measured | 2.7 ms | 21.0 ms | 2.04 ms |
| the same frame right after a restore | 2.8 ms | 22.2 ms | 2.08 ms |
| the same frame + run-ahead 1 | 5.2 ms | 41.3 ms | 3.78 ms |
| a rewind pop | 1.6 ms | 1.8 ms | |
| a frame with a rewind push (every 10th) | about +3.5 ms | about +5 ms | |
| ring after 10 s (incl. the 6 MB newest) | 9.9 MB | 13.1 MB | |

So a DS snapshot is cheap: saving or restoring the payload costs well
under a millisecond, and the frame after a restore costs what it would
anyway. Run-ahead n therefore costs n + 1 frames plus about a millisecond:
1.9x a frame at run-ahead 1. Fine where the game runs at under a third of
the frame budget (SoulSilver on a Mac); not on a phone, nor on Golden Sun's
heavy frames anywhere. Rewind's push is a few milliseconds once every 10
frames (sparse XOR scan of 6 MB + zlib of what changed), affordable
everywhere the game runs. Ring growth was 4-7 MB per 10 s of history in
these scenes, so the 64 MB cap holds roughly 1.5-2.5 minutes and iOS's
16 MB roughly 15-25 s.

## Bigger ideas (not prototyped)

| Idea | Cost | Notes |
|---|---|---|
| DSi mode | 30-60 agent-days | 16 MB RAM, new WRAM banks, NDMA, SD/MMC + NAND, AES, the DSi cameras, TWL BIOS. Needs the user's NAND and BIOS dumps (console-unique keys): no HLE stand-in. Only for DSi-enhanced/-exclusive games and DSiWare. |
| RetroAchievements (rcheevos) | 5-8 days web, +3-4 iOS | rcheevos is a portable C library (MIT): build it into both wasm cores and libdingbat; it reads main RAM through a memory callback (`cheat_read` is the shape) and has a DS ROM hash. Login UI, hardcore mode (no states, rewind, cheats, slow motion). |
| Widescreen hacks | 10+ days, per game | AR-style codes widen a game's projection; the renderer would have to draw 3D wider than 256 and the 2D layers do not widen. Low value. |
| Texture replacement | 10-20 days after an HD renderer | hash texture data at decode time, load packs; depends on an opt-in upscaled 3D renderer (the default must stay bit-identical). |
| GBA-slot accessories | 1-2 days each | the core has the Rumble Pak (and `nds_rumble` is exported but unused by the page), the Expansion Pak and GBA carts (docs/nds/slot2.md). Rumble to `navigator.vibrate` / gamepad rumble: half a day. Guitar Grip (four buttons through slot 2), Motion Pack, Paddle, Piano: core device + mapping each. Pal Park: insert a GBA game from the library: 1-2 days of UI. |
| Firmware settings editor on iOS | ~1 day | the web's Settings > Nintendo DS > Console settings (NdsUtil.fwReadUser / fwWithUser) ported to Swift or exported from Nim. |
| Rewind and run-ahead on iOS | ~1 day | the same hooks; lift the `ekNDS` gates in `dingbat_ios.nim`, cap the ring at 16 MB. |
| Fast-forward frame skip | 1-2 days | above; capture-aware. |
