# Cross-game Pokémon trade: the "Communication error", and the decomp analysis of it

**Status: resolved.** Emerald↔FireRed trades run end to end. The fix was not one
commit — the link/SIO timing work that landed after 2026-07-14 closed the ~1-frame
drift (see memory `trade-regression-hle-charge`: a decompression charge starving SIO).
This doc is kept for the decomp method, the verified addresses, and the harnesses,
all of which are reusable. It supersedes the separate
`cross-game-trade-investigation.md` and `trade-decomp-analysis.md`.

## What the failure was

Same-game pairs traded fine; every cross-game pair (Emerald↔Ruby, Emerald↔FireRed)
hit `"Communication error…"` right after entering the trade room. mGBA traded the
same ROMs successfully, so it was a dingbat bug.

The standby uses **two `0x2FFE` barriers ~46 frames apart**. Barrier 1: FireRed
leads, Emerald echoes. Barrier 2: Emerald leads, FireRed echoes. dingbat's FireRed
did barrier 1 but never sent its barrier-2 echo — it ran `CloseLink`
(`SIOCNT 0x600B→0x2000`) instead.

## The mechanism, from the decomp

Built both decomps with `agbcc` (bootstrapped from source, with a `clang -E` shim for
the missing `arm-none-eabi-cpp`); both ROMs match the official SHA-1, so every ROM
address and embedded RAM pointer below is authoritative rather than inferred.

**dingbat runs FireRed rev1 (BPRE 1.1), not rev0.** The three observed addresses land
on exact function entries only in rev1: `0x08056A28` = `VBlankCB_Field`,
`0x080097A0` = `VBlankCB_LinkError` (not `InitLink`, which was a rev0 mis-map),
`0x0800B2B0` = `DisableSerial`.

The route is `CheckErrorStatus` → `gLinkErrorOccurred = TRUE` → `CloseLink()` →
`DisableSerial` (SIOCNT=0x2000), then next frame `CB2_LinkError` sets
`VBlankCB_LinkError`. Both observed writes come from that single branch, which is the
tell that it is neither a timeout nor a magic-string mismatch.

**Why LAG_MASTER specifically.** The master runs exactly one 9-transfer command per
frame (8 data words + 1 checksum), paced by Timer3: `LinkVSync` kicks transfer 1 at
VBlank, each `SerialCB` bumps `serialIntrCounter` and re-arms Timer3
(`REG_TM3CNT_L = -197`, 64-clk prescale ⇒ ~12608 cyc/transfer) until the 9th. At the
next VBlank `serialIntrCounter` must read 9; ≤8 means `LAG_MASTER`. The other error
bits are ruled out — block data is byte-correct (no checksum error), the queues are
idle during standby, and `hardwareError` needs a real SIO error flag mGBA never
raises. dingbat produced one frame in the standby window with ≤8: a fabricated
LAG_MASTER. mGBA holds 9/frame throughout (2676 frames, longest zero run = 2).

So the bug reduced to one quantity: **FireRed-master `serialIntrCounter` must be ≥9 at
every VBlank in `CONN_ESTABLISHED`.** The most likely cause, and the one the timing
work addressed, is SIO-multi completion being gated on the peer core: if a master
transfer only completes once the Emerald core has staged `SIOMLT_SEND`, a frame where
Emerald is busy withholds one of FireRed's 9 completions. Hardware never does this —
a not-yet-staged slave just contributes `0xFFFF` and the transfer happens on schedule.

## Verified addresses (from the sha-verified ELFs)

FireRed rev1:

| symbol | address | notes |
|---|---|---|
| `gLinkStatus` (u32) | `0x03003F20` | LAG_MASTER = bit 16 = `0x00010000` |
| `gLinkCallback` (u32) | `0x03003F80` | 0 = idle |
| `gLink` (struct) | `0x03003FB0` | |
| `gLink.state` (u8) | `0x03003FB1` | CONN_ESTABLISHED = 4 |
| `gLink.serialIntrCounter` (s8) | `0x03003FBD` | gLink+13 |
| `gLink.lag` (u8) | `0x03003FC3` | gLink+19; NONE=0, MASTER=1, SLAVE=2 |
| `gLink.hardwareError` (u8) | `0x03003FC0` | gLink+16 |
| `gReadyToExitStandby[4]` | `0x03003F2C` | |
| `sNumVBlanksWithoutSerialIntr` | `0x03000E64` | slave-side lag counter |

Emerald: `gLinkCallback = 0x03003140`, `gLinkStatus = 0x030030E0`,
`gMain = 0x030022C0`.

**The earlier investigation's FireRed addresses were `gMain` fields, not link
globals** (`gMain = 0x030030F0`): what it called `gLinkCallback` is
`gMain.vblankCallback` (+0x0C), `gLinkStatus` is `gMain.intrCheck` (+0x1C), and
`serialIntrCounter` is inside `gMain.oamBuffer` (+0x3C). That invalidated its pivotal
conclusion — "`gLinkStatus` never sets an error bit, so it is a code-path branch, not
an error" read `gMain.intrCheck`, whose high 16 bits are structurally always zero, so
it was never looking at `gLinkStatus`. Its "force all divergent bytes to mGBA's
values" test was inconclusive for the same reason: it forced `gMain`/OAM bytes and
never the real `gLink`.

## The harnesses (left in place — do not delete)

**dingbat repro — `tests/trade_repro.nim`.** Loads two real ROMs plus their `.sav`,
links them via the in-process lockstep (`gba/link.nim`), drives per-core inputs from a
script, and dumps SIO/IWRAM/PC traces. Deterministic.

```
nim c -d:test_harness -d:release -d:linkTrace --path:src -o:trade_repro tests/trade_repro.nim
# ALWAYS restore fresh saves first — the games overwrite .sav on in-game save:
cp ~/Downloads/PokemonFireRed.sav        scratch-repro/roms/fr.sav
cp ~/Downloads/PokemonEmeraldShiny1.sav  scratch-repro/roms/em.sav
./trade_repro scratch-repro/roms/fr.gba scratch-repro/roms/em.gba \
              scratch-repro/combined.txt 4500 scratch-repro/shots 4500
# screenshots are PPM; view with: sips -s format png <f>.ppm --out <f>.png
```

Navigation script `combined.txt` is `<frame> <core> <buttons>`: FireRed (core 0,
master) mashes A+START; Emerald (core 1, slave) skips its intro with START, CONTINUE
with A, walks UP to the counter, then mashes A. Env probes `FORCE0`/`FORCECD`/
`FORCEALL` force chosen bytes to mGBA's values. `scratch-repro/montage.py` tiles PPMs.

**mGBA reference — `~/code/mgba-ref-src` + `scratch-repro/harness.c`.** mGBA 0.10.5,
core static lib only, each GBA in its own `mCoreThread` with the Qt
`MultiplayerController` lockstep ported verbatim — a single-threaded cooperative
scheduler does NOT reproduce mGBA's lockstep and starves the slave.

```
bash scratch-repro/build.sh && codesign -s - -f scratch-repro/harness
bash scratch-repro/run.sh 4500 combined.txt out
```

Frame alignment between the two: `mframe = dingbat_f + 72`.

**Instrumentation is gated behind `-d:linkTrace`** and compiled out of normal and wasm
builds: `gba/bus.nim` (`onWramChipWrite`, `chipWatch` on the three `wram_chip` write
paths), `gba/serial.nim` (`onSiocntWrite`), `gba/link.nim` (`onMultiRound`). None are
game-specific; the FireRed/Emerald addresses live only in `trade_repro.nim`.

## Related fixes that landed alongside

- **ROM transfer for cross-game trades** (`web/netplay.js`): peers exchange ROMs over
  the DataChannel when hashes differ, with backpressure and an `RB_READY` barrier.
- **`multi_recv` rollback fix** (`gba/link.nim` `LinkSnapshot`): SIOMULTI receive
  latches were lost across an input-rollback restore, causing a communication error in
  *same-game* LAN trades. Regression test: `tests/roms/linkskew.gba` via `--mode=linktest`.
- **Multi-mode completion-time latch** (`start_multi`/`complete_multi`): the outgoing
  `SIOMLT_SEND` word is latched at transfer completion rather than round start, so a
  late-staging peer is not sampled stale.

## Appendix — decomp file:line references

- Standby machine: `pokefirered/src/link.c:1353` (SetLinkStandbyCallback), `:1368`
  (LinkCB_Standby), `:1377` (LinkCB_StandbyForAll), `:640` (recv 0x2FFE).
- Error branch: `:1397` (CheckErrorStatus), `:524` (from LinkMain2), `:1849`
  (LAG_MASTER→status bit), `:1956` (serialIntrCounter<9→LAG_MASTER in LinkVSync).
- Transfer engine: `:1996` (SerialCB), `:2159` (SendRecvDone), `:1990` (Timer3Intr),
  `:2028` (StartTransfer).
- Teardown: `CloseLink` = rev1 `0x080098CC` → `DisableSerial` `0x0800B2B0`;
  `CB2_LinkError` `0x0800ACE8`.
- Emerald mirror: `pokeemerald/src/link.c`, `LinkCB_Standby 0x0800AE30`,
  `LinkCB_StandbyForAll 0x0800AE5C`, master lag `:2097`.
