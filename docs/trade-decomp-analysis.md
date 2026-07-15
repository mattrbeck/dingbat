# Cross-game trade "Communication error" — pret decomp analysis

Source-only analysis of the Emerald↔FireRed cable-trade failure, mapping every observed
dingbat address back to `pret/pokefirered` + `pret/pokeemerald` and pinning the exact
game-code branch that tears down the link.

## Method / confidence

**Gold path used — byte-perfect builds.** I built both decomps with `agbcc` (bootstrapped
`agbcc` from source; substituted a `clang -E` shim for the missing `arm-none-eabi-cpp`).
Both ROMs match the official SHA-1, so every ROM (`.text`) address and every embedded
RAM pointer is authoritative:

| ROM | built SHA-1 | matches |
|---|---|---|
| FireRed **rev0** (BPRE 1.0) | `41cb23d8…e2fdc` | `firered.sha1` ✔ |
| FireRed **rev1** (BPRE 1.1) | `dd5945db…bf417` | `firered_rev1.sha1` ✔ |
| Emerald (BPEE) | `f3ae0881…1d07b7` | `pokeemerald.gba.sha1` ✔ |

Confidence: **high** for all address→symbol maps (nm on the sha-verified ELFs) and for
the source control flow (cited file:line). The only judgement call is *which* LINK_STAT
error bit fires (LAG_MASTER vs checksum) — I argue LAG_MASTER below and give dingbat the
exact addresses to confirm it.

---

## 0. TWO CORRECTIONS THAT REFRAME THE WHOLE INVESTIGATION

### (a) dingbat runs FireRed **rev1 (BPRE 1.1)**, not rev0
All three "observed" FireRed ROM addresses land on *exact function entries* only in rev1:

| addr | rev0 | **rev1 (what dingbat runs)** |
|---|---|---|
| `0x08056A28` | mid-`VBlankCB_Field` (+20) | **`VBlankCB_Field`** (+0) |
| `0x080097A0` | `InitLink` | **`VBlankCB_LinkError`** |
| `0x0800B2B0` | mid-`DisableSerial` (+20) | **`DisableSerial`** (+0) |
| `0x0800B2C6` (write PC) | — | `DisableSerial`+22 (the SIOCNT store) |

So the "SetMainCallback2(0x080097A0=InitLink)" reading was a rev0 mis-map; in rev1
`0x080097A0` is `VBlankCB_LinkError`.

### (b) The prior "FireRed RAM symbols" are mis-identified — they are `gMain` fields
`gMain` lives at `0x030030F0` (both revs). The addresses the earlier work called link
globals are actually offsets into `struct Main` (`include/main.h`):

| dingbat label | address | **what it really is** | offset |
|---|---|---|---|
| "gLinkCallback" | `0x030030FC` | **`gMain.vblankCallback`** | gMain+0x0C |
| "gLinkStatus" | `0x0300310C` | **`gMain.intrCheck`** (vu16) | gMain+0x1C |
| "gLink base" | `0x030030EC` | ≈ `gLinkTransferringData` region | — |
| "serialIntrCounter" | `0x0300312C` | inside `gMain.oamBuffer` | gMain+0x3C |

This invalidates the pivotal earlier conclusion *"gLinkStatus never sets an error bit, so
it is a game code-path branch, not an error."* That read `gMain.intrCheck`, whose high 16
bits are structurally always zero — it was **never looking at `gLinkStatus` at all.**

**The real FireRed rev1 addresses (from the sha-verified ELF) that dingbat should watch:**

| symbol | address | notes |
|---|---|---|
| `gLinkStatus` (u32) | **`0x03003F20`** | LINK_STAT_ERROR_LAG_MASTER = bit 16 = `0x00010000` |
| `gLinkCallback` (u32) | **`0x03003F80`** | real link callback (0 = idle) |
| `gLink` (struct) | **`0x03003FB0`** | |
| `gLink.state` (u8) | `0x03003FB1` | LINK_STATE_CONN_ESTABLISHED = 4 |
| `gLink.serialIntrCounter` (s8) | **`0x03003FBD`** | gLink+13; transfers done this frame |
| `gLink.lag` (u8) | **`0x03003FC3`** | gLink+19; LAG_NONE=0, LAG_MASTER=1, LAG_SLAVE=2 |
| `gLink.hardwareError` (u8) | `0x03003FC0` | gLink+16 |
| `gReadyToExitStandby[4]` | `0x03003F2C` | |
| `sNumVBlanksWithoutSerialIntr` | `0x03000E64` | slave-side lag counter |

(Offsets verified against the rev1 `LinkVSync` disassembly: `gLink` literal `0x03003FB0`,
`strb [r3,#13]`=serialIntrCounter, `strb [r3,#19]`=lag.)

For **Emerald** the earlier `gLinkCallback = 0x03003140` **is correct** (real
`gLinkCallback`; gMain there is `0x030022C0`). Emerald's `gLinkStatus` is
`0x030030E0`, not the `0x03003260` that was quoted.

---

## 1. Address → function map

### FireRed rev1 (the teardown)
- **`0x08056A28` = `VBlankCB_Field`** (`src/field_screen_effect`/overworld field VBlank).
  This is the *value* of `gMain.vblankCallback` while sitting in the overworld — i.e. the
  cable-club link handshake runs as tasks on top of the field, before any trade-menu scene
  switch. Its being the field callback tells us the failure happens during the **cable-club
  link-up phase**, not inside a dedicated trade scene.
- **`0x080097A0` = `VBlankCB_LinkError`** (`src/link.c:359`). Installed by `CB2_LinkError`
  (`src/link.c:1452`, `SetVBlankCallback(VBlankCB_LinkError)`). So
  `gMain.vblankCallback: VBlankCB_Field → VBlankCB_LinkError` = **FireRed entered
  `CB2_LinkError`** (the "Communication error" screen).
- **`0x0800B2B0` = `DisableSerial`** (`src/link.c`), **not** `CloseLink`. `CloseLink`
  itself is `0x080098CC` (rev1) and calls `DisableSerial`. `DisableSerial` body:
  ```c
  DisableInterrupts(INTR_FLAG_TIMER3 | INTR_FLAG_SERIAL);
  REG_SIOCNT = SIO_MULTI_MODE;   // = 0x2000  ← the observed SIOCNT write, PC 0x0800B2C6
  REG_TM3CNT_H = 0;
  REG_IF = INTR_FLAG_TIMER3 | INTR_FLAG_SERIAL;
  REG_SIOMLT_SEND = 0; REG_SIOMLT_RECV = 0;
  CpuFill32(0, &gLink, sizeof(gLink));
  ```
  This is exactly the observed "SIOCNT=0x2000, IRQ off": the master stops clocking the cable.

### `struct Link` layout (`include/link.h`) — the field that "counts 0→4"
The earlier "0x312E byte incrementing 0→4" was inside `gMain.oamBuffer` (a mis-map) and is
noise. The real per-frame transfer counter is `gLink.serialIntrCounter` (offset 13,
addr `0x03003FBD`); it counts to 9 each frame and is reset to 0 at VBlank.
`gLink.sendCmdIndex`/`recvCmdIndex` are offsets 22/23. `gReadyToExitStandby[]` is a
separate array (`0x03003F2C`), **not** a gLink field.

### Emerald (the two installed callbacks — all exact hits)
- **`0x0800AE30` = `LinkCB_Standby`**  (`src/link.c`)
- **`0x0800AE5C` = `LinkCB_StandbyForAll`**
- caller **`0x0800AE1A` = `SetLinkStandbyCallback`+34** → `gLinkCallback = LinkCB_Standby`
- caller **`0x0800AE48` = `LinkCB_Standby`+24** → `gLinkCallback = LinkCB_StandbyForAll`

So Emerald at f2070/f2071 is running the **normal SetLinkStandbyCallback barrier**: install
`LinkCB_Standby`, send its `0x2FFE` once, advance to `LinkCB_StandbyForAll` and wait.

---

## 2. The standby-barrier state machine (`src/link.c`, identical in both games)

```c
void SetLinkStandbyCallback(void) {              // cable path
    if (gLinkCallback == NULL) gLinkCallback = LinkCB_Standby;
    gLinkDummy1 = FALSE;
}
static void LinkCB_Standby(void) {
    if (gLastRecvQueueCount == 0) {              // wait until my send queue drained
        BuildSendCmd(LINKCMD_READY_EXIT_STANDBY); // queue one 0x2FFE  (link.c:664)
        gLinkCallback = LinkCB_StandbyForAll;
    }
}
static void LinkCB_StandbyForAll(void) {
    for (i = 0; i < GetLinkPlayerCount(); i++)
        if (!gReadyToExitStandby[i]) break;      // all peers' 0x2FFE arrived?
    if (i == linkPlayerCount) {                  // yes → barrier done
        for (...) gReadyToExitStandby[i] = FALSE;
        gLinkCallback = NULL;                     // exit: scene may advance
    }
}
```
Receiving a peer's `0x2FFE` sets `gReadyToExitStandby[i] = TRUE`
(`ProcessRecvCmds`, `src/link.c:640-641`).

**Key properties:** each unit sends `0x2FFE` exactly once, then waits purely on
`gReadyToExitStandby[]`. There is **no timeout and no dependence on frame count or on the
*value* of any other received word** — a peer that is many frames behind is fine. Exit is
`gLinkCallback = NULL`. So the ~46-frame gap between the two barriers is *by design* and is
**not** itself the bug (mGBA shows the same two-barrier / ~46-frame structure). The barrier
cannot, on its own, produce a `CloseLink`.

---

## 3. THE BRANCH — it is the LAG_MASTER error path, not a game-logic `if`

There is **no** `if` in the trade/standby code that says "continue vs CloseLink" based on a
received command. FireRed's teardown comes from the **generic link error check**, driven by
a hardware-timing flag. The full chain, every step cited:

1. **`LinkVSync` (`src/link.c:1949`)** runs in FireRed's VBlank IRQ. FireRed is the SIO
   **master**. In `LINK_STATE_CONN_ESTABLISHED`:
   ```c
   if (gLink.serialIntrCounter < 9) {           // <9 SIO transfers completed this frame
       if (gLink.hardwareError != TRUE) gLink.lag = LAG_MASTER;   // ← THE flag
       else StartTransfer();
   } else if (gLink.lag != LAG_MASTER) {
       gLink.serialIntrCounter = 0; StartTransfer();
   }
   ```
2. **`LinkMain1` (`src/link.c:1849`)** turns that into a status bit:
   `if (gLink.lag == LAG_MASTER) retVal |= LINK_STAT_ERROR_LAG_MASTER;` (`0x00010000`).
   `gLinkStatus = LinkMain1(...)` in `HandleLinkConnection` (`src/link.c:1645`).
3. **`CheckErrorStatus` (`src/link.c:1397`)**, called every frame from `LinkMain2`
   (`src/link.c:524`) right after step 2:
   ```c
   if (sLinkOpen && EXTRACT_LINK_ERRORS(gLinkStatus)) {
       if (!gSuppressLinkErrorMessage) SetMainCallback2(CB2_LinkError);
       gLinkErrorOccurred = TRUE;
       CloseLink();                              // → DisableSerial → SIOCNT=0x2000
   }
   ```
4. Next frame `CB2_LinkError` runs → `SetVBlankCallback(VBlankCB_LinkError)` →
   `gMain.vblankCallback` (`0x030030FC`) flips `VBlankCB_Field (0x08056A29)` →
   `VBlankCB_LinkError (0x080097A1)`. **This is the exact observed transition.**

Both observed writes (SIOCNT=0x2000 *and* vblankCallback→VBlankCB_LinkError) are produced by
this single `CheckErrorStatus` branch, which is the tell that this — not a timeout or a
magic-string mismatch — is the route taken.

### Why LAG_MASTER specifically
The master runs **exactly one 9-transfer command per frame** (CMD_LENGTH=8 data words +
1 checksum, `include/link.h:8`), paced by Timer3:
`LinkVSync` kicks transfer 1 at VBlank → each `SerialCB` (`src/link.c:1996`) does
`serialIntrCounter++` and `SendRecvDone` re-arms Timer3 (`REG_TM3CNT_L = -197`, 64-clk
prescale ⇒ ~12608 cyc/transfer) → `Timer3Intr` → `StartTransfer`, until the 9th
(`recvCmdIndex == CMD_LENGTH`) when the timer is *not* re-armed. At the next VBlank
`serialIntrCounter` must read **9**; if it reads **≤8**, `LAG_MASTER`.

The other error bits are ruled out by the established facts: block data is byte-correct
(no `LINK_STAT_ERROR_CHECKSUM`, `DoRecv` `src/link.c:2086`), the queues are idle during
standby (no `QUEUE_FULL`), and `hardwareError` comes from a real SIO error flag that mGBA
never raises here. That leaves `serialIntrCounter < 9`.

**The decisive, timing-dependent input is therefore: how many SIO-multi transfer
completions (serial IRQs) land on the FireRed *master* between two consecutive VBlanks.**
It must be ≥9. dingbat produces one frame in the standby window (the barrier-2 frame,
~f2073) where it is ≤8, which is fabricated LAG_MASTER. mGBA holds 9/frame throughout (its
own trace: 2676 frames at 9 transfers/frame, longest zero run = 2), so it never lags and
keeps SIOCNT=`0x608B`.

---

## 4. Emerald's side — it is the victim, running the barrier correctly

At f2070 Emerald's own trade state machine reaches a `SetLinkStandbyCallback`
(`0x0800AE1A`) → `gLinkCallback = LinkCB_Standby` (`0x0800AE30`); f2071 it sends its single
`0x2FFE` and advances to `LinkCB_StandbyForAll` (`0x0800AE5C`), where it waits for
`gReadyToExitStandby[all]`. Emerald "leads" barrier-2 only because its state machine hit the
call ~1 frame before FireRed hit the matching point (the normal 46/47-frame inter-barrier
drift). Emerald then **freezes in `LinkCB_StandbyForAll`** — not because Emerald is buggy,
but because FireRed LAG_MASTER-aborts and stops clocking the cable, so Emerald (the slave)
never receives FireRed's echo and, after `sNumVBlanksWithoutSerialIntr > 10`
(`src/link.c:1976`), would itself go `LAG_SLAVE`. Emerald's `LinkCB_Standby`/
`LinkCB_StandbyForAll` are byte-identical to FireRed's, and its master-lag check
(`serialIntrCounter < 9 → LAG_MASTER`) is identical too — the protocol is symmetric across
the two games. **No cross-game code divergence is involved; the trigger is purely the
FireRed master's per-frame transfer count.**

---

## 5. Fix hypotheses (grounded in the branch)

The bug reduces to a single quantity: **FireRed-master `serialIntrCounter` must be ≥9 at
every VBlank in `CONN_ESTABLISHED`.** On hardware/mGBA the master's 9 transfers are driven
by its *own* Timer3 clock and always complete within a frame regardless of what the slave is
doing (a not-yet-staged slave just contributes `0xFFFF`); the transfer — and thus the
master's serial IRQ — happens on schedule. Candidate dingbat inaccuracies that would drop
the master below 9 on the barrier-completion frame:

1. **SIO-multi completion gated on the peer core (most likely).** If dingbat only "completes"
   a master transfer (and fires the master's serial IRQ / bumps `serialIntrCounter`) after
   run-to-ing the Emerald core so it has staged `SIOMLT_SEND`, then a frame where Emerald is
   momentarily busy (its own barrier-2 scene/logic work at f2070-2073) withholds one or more
   of FireRed's 9 completions → `serialIntrCounter ≤ 8` → LAG_MASTER. Hardware never does
   this. **Test:** make the master's transfer complete on its Timer3 schedule with the peer
   contributing stale/`0xFFFF` if not staged, independent of the peer's advancement.
2. **Timer3 period / serial-transfer latency slightly too long,** so the 9th transfer's serial
   IRQ lands *after* VBlank on the one frame where the transfer chain starts latest (extra CPU
   at barrier completion shifts phase). Nominal budget is huge (9 × ~12608 ≈ 114k cyc vs
   280896 cyc/frame), so this only bites at a phase edge. **Test:** log the cycle timestamps
   of the 9 Timer3/serial IRQs vs the VBlank IRQ on the failing frame; the Timer3 reload
   interval should be ~12608 cycles.
3. **VBlank-vs-serial IRQ ordering at the frame boundary** — if dingbat evaluates `LinkVSync`
   (VBlank) an instruction before delivering the in-flight 9th serial IRQ, it reads 8.

**Concrete next step for dingbat:** re-instrument with the *correct* addresses —
`gLinkStatus @0x03003F20` (watch bit16), `gLink.lag @0x03003FC3`, and
`gLink.serialIntrCounter @0x03003FBD` — and dump them every frame across f2060–2078. Expect
to catch the exact frame where `serialIntrCounter` reads ≤8 and `gLinkStatus` bit16 sets, one
frame before the `CloseLink`. Then compare that frame's count and Timer3/serial IRQ cadence
to mGBA (should be 9). The prior "force all divergent bytes to mGBA values" test was
inconclusive because it forced `gMain`/OAM bytes, never the real `gLink`/`gLinkStatus`.

---

## Appendix — key file:line references
- Standby machine: `pokefirered/src/link.c:1353` (SetLinkStandbyCallback), `:1368`
  (LinkCB_Standby), `:1377` (LinkCB_StandbyForAll), `:640` (recv 0x2FFE → gReadyToExitStandby).
- Error branch: `:1397` (CheckErrorStatus), `:524` (called from LinkMain2), `:1849`
  (LAG_MASTER→status bit), `:1956` (serialIntrCounter<9→LAG_MASTER in LinkVSync).
- Transfer engine: `:1996` (SerialCB, serialIntrCounter++), `:2159` (SendRecvDone, one
  command/frame), `:1990` (Timer3Intr), `:2028` (StartTransfer).
- Teardown: `CloseLink`=rev1 `0x080098CC` → `DisableSerial` `0x0800B2B0` (`REG_SIOCNT =
  SIO_MULTI_MODE` = 0x2000); `CB2_LinkError` `0x0800ACE8` → `SetVBlankCallback(
  VBlankCB_LinkError 0x080097A0)`.
- Emerald mirror: `pokeemerald/src/link.c` LinkCB_Standby `0x0800AE30`, LinkCB_StandbyForAll
  `0x0800AE5C`, SetLinkStandbyCallback `0x0800ADF8`, master lag `src/link.c:2097`.
