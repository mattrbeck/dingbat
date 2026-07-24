# Cross-game Pokémon trade — "Communication error" investigation

> **Status update (2026-07-23): believed resolved.** Emerald↔FireRed trades have since
> been run successfully end to end, so the failure described below no longer reproduces.
> The fix was not isolated to a single commit — the timing work landed after 2026-07-14
> most likely closed the ~1-frame drift. The analysis below is kept for its method and
> for the link-timing detail it documents, but its conclusions describe a state the
> emulator is no longer in. Re-verify before acting on any of it.

Status (at time of writing, 2026-07-14): **root cause identified, not yet fixed.**
Handoff for a future session.

Over-the-internet (and local 2P) trading works for **same-game** pairs (Emerald↔Emerald)
but every **cross-game** pair (Emerald↔Ruby, Emerald↔FireRed) fails with the in-game
`"Communication error… Please check all connections, then turn the power OFF and ON."`
right after the characters enter the trade room, **before the trade room renders**.

mGBA trades the exact same ROMs successfully, so this is a dingbat bug, not a game
incompatibility. National Pokédex is present on both saves (386 caught), so it is not
the FRLG↔RSE cross-family gating.

---

## TL;DR — the root cause

**It is a timing bug, not a data bug — proven, not inferred.**

At the post-block **standby barrier** (Gen-3 `LINKCMD_READY_EXIT_STANDBY = 0x2FFE`),
dingbat's FireRed takes a *different game code-path branch* than mGBA's FireRed:
it tears the link down (`CloseLink`) instead of continuing into the trade. But
FireRed's link-state **memory is byte-for-byte identical to mGBA's** at that moment
(verified by a full 2 KB IWRAM diff, and by *forcing every divergent byte to mGBA's
value every frame — still fails*). So the branch is decided by **timing**, not state:
*when* the peer's second `0x2FFE` arrives relative to FireRed's flow.

Measured: dingbat's inter-game **drift is ~1 frame larger** than mGBA's over the
~250-frame trade setup (dingbat: FireRed `0x2FFE` at f2026, Emerald at f2073 = 47-frame
gap; mGBA: 2097→2143 = 46-frame gap). That one frame tips FireRed onto the wrong side
of the decision. Both emulators run frame-locked at 60 fps and land frame boundaries at
the same cycle count, so this is a **diffuse sub-0.5%/frame CPU/DMA cycle-accuracy
difference** accumulating to one frame — not a single patchable value.

A tolerance/keepalive tweak will **not** fix this: the failure is FireRed's own game
logic branching early, not the slave's lag timeout (an earlier, wrong hypothesis).

---

## The two harnesses (left in place — do not delete)

### 1. dingbat reproduction — `tests/trade_repro.nim`
Loads two real ROMs (+ their `.sav`), links them via the in-process lockstep
(`gba/link.nim`), drives per-core inputs from a script, and dumps SIO / IWRAM / PC traces.
Deterministic — same result every run.

```
nim c -d:test_harness -d:release --path:src -o:trade_repro tests/trade_repro.nim
# ALWAYS restore fresh saves first — the games overwrite .sav on in-game save:
cp ~/Downloads/PokemonFireRed.sav        scratch-repro/roms/fr.sav
cp ~/Downloads/PokemonEmeraldShiny1.sav  scratch-repro/roms/em.sav
./trade_repro scratch-repro/roms/fr.gba scratch-repro/roms/em.gba \
              scratch-repro/combined.txt 4500 scratch-repro/shots 4500
# screenshots are PPM; view with: sips -s format png <f>.ppm --out <f>.png
```
- ROMs/saves: `~/Downloads/PokemonFireRed.{gba,sav}` (stock BPRE), `~/Downloads/PokemonEmeraldShiny1.{gba,sav}`.
  Also `~/Documents/emu/gba/Pokemon{Ruby,FireRed,Emerald}.{gba,sav}` (NOT positioned for the trade).
- Navigation script `scratch-repro/combined.txt` (format `<frame> <core> <buttons>`): FireRed
  (core 0 = master; save faces the Cable Club attendant) mashes A+START; Emerald (core 1 = slave)
  skips its long intro with START, CONTINUE with A, walks UP to the counter, then mashes A.
- Env-var probes built into the harness: `FORCE0` / `FORCECD` / `FORCEALL` force the divergent
  bytes to mGBA's values (all still fail — that's the proof it's timing). `scratch-repro/montage.py`
  tiles PPMs (no PIL needed). zsh does NOT word-split unquoted vars — use globs.

### 2. mGBA reference — `~/code/mgba-ref-src` + `scratch-repro/harness.c`
mGBA 0.10.5 (node-based lockstep, `mLockstepPhase`), core static lib only, each GBA in its
own `mCoreThread` (the Qt `MultiplayerController` lockstep ported verbatim — a single-threaded
cooperative scheduler does NOT reproduce mGBA's lockstep and starves the slave). Instrumented
`src/gba/sio/lockstep.c` with per-transfer hooks.
```
bash scratch-repro/build.sh && codesign -s - -f scratch-repro/harness && bash scratch-repro/run.sh 4500 combined.txt out
```
Traces: `scratch-repro/out_full2/` (clean trade), `out_exit/` (teardown on room-exit),
`out_link/linkdump_c0.log` (per-frame IWRAM 0x3000-0x37FF, u32/word).

**Frame alignment between the two:** `mframe = dingbat_f + 72` (anchor: FireRed barrier-1
`0x2FFE` at dingbat f2026 ↔ mframe 2098; FireRed CloseLink at f2073 ↔ mframe ~2145).

---

## Key facts established

**Timeline (dingbat frames):** handshake ~f1550 · LinkPlayer block exchange ~f1761–1782 ·
standby barrier-1 (FireRed `0x2FFE`) f2026 · **FireRed CloseLink f2073** · comm-error screen ~f2120.

**The standby uses TWO `0x2FFE` barriers ~46 frames apart** (confirmed on mGBA):
- Barrier 1: FireRed leads (mframe 2097), Emerald echoes (2098).
- Barrier 2: Emerald leads (2143), **FireRed echoes (2144)** → both continue, link stays open.
- mGBA's master holds `SIOCNT=0x608B` (serial-IRQ enabled) continuously frames 1619→4500;
  9 transfers/frame during commands; slave never misses >2 VBlanks. It only writes
  `SIOCNT=0x2000` (CloseLink) when you *walk out* of the trade room.

**dingbat diverges at barrier 2:** FireRed does barrier 1 (f2026) but does NOT send its
barrier-2 `0x2FFE`; when Emerald's barrier-2 `0x2FFE` arrives at f2073, FireRed instead
runs `CloseLink` (`SIOCNT 0x600B→0x2000`, IRQ disabled) and switches scene callback.

**The branch:** `gLinkCallback`/`gMain.vblankCallback` (`0x030030FC`) flips
`0x08056A29` (link/trade-scene callback) → `0x080097A1` at f2073. `0x080097A1` is set via
`SetMainCallback2(0x080097A0)` — ROM literal pools at `0x080096E8` and `0x0800AE0C`; the
scene's sibling code calls `CloseLink` at ROM `0x0800B2B0` (`SIOCNT=0x2000`, ack `IF=0xC0`,
zero link state). `gLinkStatus` (`0x0300310C`) high-16 error bits are **never set** on either
emulator — so it is NOT `LAG_MASTER`/`LAG_SLAVE`/checksum/magic; it is a clean but early branch.

**FireRed (stock BPRE 1.0) game-side link addresses** (same on any emulator; read IWRAM in
dingbat via `bus.wram_chip[addr and 0x7FFF]`):
`gLinkStatus 0x0300310C` (u32) · `gLinkCallback 0x030030FC` (u32) ·
`gLink.serialIntrCounter 0x0300312C` (u8) · gLink base ≈ `0x030030EC`.
Emerald (BPEE): `gLinkStatus 0x03003260`, `gLinkCallback 0x03003140`.

**Full 2 KB IWRAM diff at the failure frame** (dingbat f2072 vs mGBA 2144) — only 7 words
differ, ALL ruled out:
| addr | dingbat | mGBA | verdict |
|---|---|---|---|
| 0x03003114 | 0x0000080B | 0x00000854 | frame counter (differs by ~72 = the alignment offset) |
| 0x03003118 | 0x0000FC00 | 0x00000000 | boot-time byte (set at frame 13, PC in BIOS/DMA); FORCE0 → still fails |
| 0x0300311C | 0x0000FC00 | 0x00000000 | same; still fails |
| 0x03003120 | 0x00260000 | 0x00280000 | a 40-countdown; FORCECD (hold at 40) → still fails |
| 0x0300312C | 0x01019808 | 0x01029808 | ±1 counter jitter (serialIntrCounter neighbor) |
| 0x0300314C | 0xFEFF0C00 | 0xFEFE0C00 | ±1 jitter |
| 0x03003578 | 0x000000D2 | 0x000000D4 | ±2 jitter |
`FORCEALL` (force all of the above to mGBA's values every frame) → **still fails.** ⇒ timing, not data.

**Why mGBA stays aligned:** its lockstep runs each core in its own thread and **blocks the
parent until the slave reaches each transfer barrier** (per-transfer sync). dingbat's
`step_frame` interleaves in `LINK_SLICE`-cycle slices with `run_to` — same frame-boundary
cycle count, but the per-frame *state-machine* progress drifts ~1 frame more over the setup.
Changing `LINK_SLICE` (tested 512→64) does NOT fix it (not a sub-frame interleave artifact).

---

## Fixes SHIPPED this session (in the tree; these are correct, keep them)

These fixed real, distinct bugs found along the way — the cross-game timing bug above is
what remains.
- **ROM transfer for cross-game trades** (`web/netplay.js`): peers exchange ROMs over the
  DataChannel when hashes differ, backpressure + `RB_READY` barrier, per-slot host/guest ROM.
  (wasm already supported two independent ROMs.) See memory `rom-transfer-cross-game`.
- **`multi_recv` rollback fix** (`gba/link.nim` `LinkSnapshot`): SIOMULTI receive latches were
  lost across an input-rollback restore → "communication error" in **same-game** real-latency
  (LAN) trades. Now captured/restored. Regression test = `tests/roms/linkskew.gba` via
  `--mode=linktest`. See memory `rollback-multirecv-desync`.
- **Multi-mode completion-time latch** (`gba/link.nim` `start_multi`/`complete_multi`): the
  outgoing `SIOMLT_SEND` word is now latched at transfer *completion* (like normal mode) rather
  than at round start, so a late-staging peer isn't sampled stale. Verified real (fixes the
  `linkskew` repro) but NOT the deciding cause of the cross-game bug. See `link-multi-latch-timing`.
- Web UI: Link-Cable modal restructure (spinner-in-field, Connect⇄Cancel), stale-server cleanup.

Deployed wasm cache version: `dev-linklatch` (`web/sw.js` + `web/version.txt`).

---

## Debug instrumentation (now gated behind `-d:linkTrace` — compiled out of normal builds)

The SIO/IWRAM hooks the harness reads are wrapped in `when defined(linkTrace)`, so a
normal or production build (native release, wasm — neither defines it) contains none of
them: zero hot-path cost, nothing to strip. Build the harness with the define to use them.
- `gba/bus.nim`: `onWramChipWrite`, `wramWatchOff`, `chipWatch` template on the three
  `wram_chip` write paths (byte/u16/u32) — under `linkTrace`; a no-op `chipWatch` otherwise.
- `gba/serial.nim`: `onSiocntWrite` hook — under `linkTrace`. (The `mlt_send_dirty` field it
  used was a dead-end "stale-word staging" detector; it and its `gba.nim` field are removed.)
- `gba/link.nim`: `onMultiRound` hook — under `linkTrace`; simplified to `(data, multi)`.
- `tests/trade_repro.nim`: `iw32`/`iw8` readers (read `bus.wram_chip` directly — no hook),
  `FORCE0`/`FORCECD`/`FORCEALL` env probes. Build: add `-d:linkTrace` to the nim c line.

None of these are game-specific: they are generic memory/SIO instrumentation points. The
only game-specific knowledge (FireRed/Emerald IWRAM addresses) lives in `trade_repro.nim`,
which is a local investigation harness, not shipped emulator code.

The last deployed wasm (`dev-linklatch`) was built before any of this, so it is clean.

---

## Recommended next step

Before treating it as a diffuse accuracy limit, do a **milestone-timing diff**: log the exact
frame each game reaches each link milestone (handshake start, block-exchange start/end,
barrier-1 send, barrier-2 send) in dingbat vs mGBA (align with `+72`). 
- If Emerald falls behind **uniformly** → diffuse cycle-accuracy (hard; broad audit of DMA
  timing / waitstates / instruction costs).
- If it falls behind at **one specific point** → a concrete, targetable timing bug.

Other angles: (b) port mGBA's per-transfer thread-blocking lockstep model to see if tighter
sync closes the 1-frame gap; (c) if correctness proves infeasible, revisit whether any
emulator-side timing nudge makes the branch align (last resort — a true tolerance tweak does
not apply since the failure is FireRed's own branch).

---

## Memory index (auto-memory, more detail per topic)
`trade-repro-harness` · `link-multi-latch-timing` · `rollback-multirecv-desync` ·
`rom-transfer-cross-game` · `netlink-phase3b` · `speculative-rollback-diagnosis`
