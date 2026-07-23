# HLE BIOS Shortcomings

## Remaining known gaps (2026-07-23)

The halted-register protocol and copy-SWI interruptibility landed 2026-07-22
(Bubble Bobble Old & New, Card E-Reader): user IRQ handlers now see
r12 = 0x04000000 while the CPU waits inside Halt/Stop/IntrWait (the devkitARM
crt0 convention for the IntrWait mirror ack), the caller's r12 is restored via
the real dispatcher's SVC-stack slot, IntrWait returns the real r0/r1/r3
protocol, and CpuSet/CpuFastSet are preempted mid-loop by deliverable IRQs
with time charged in step with the real routine.

2026-07-23 additions: decompression SWIs and RegisterRamReset are
IRQ-preemptible (Muppets On With The Show, Robot Wars - Advanced
Destruction), the Div/DivArm cost model counts the real alignment loop
exactly, executing the reset vector (a game jump to 0x00000000) re-runs an
HLE boot with the measured real-BIOS duration and post-boot state (Earthworm
Jim 2), SoftReset enters the target at its first instruction (previously
off by one instruction), and SoundGetJumpList (SWI 0x2A) + the SoundDriverMain
(SWI 0x1C) lock/callback dispatch are implemented for games that drive the
BIOS-resident MP2K engine (Cyberdrive Zoids boots). Still deliberately
unmodeled:

- **The BIOS-resident MP2K sound driver body**: SoundGetJumpList returns the
  real BIOS's 36 pointers and the stub BIOS backs them with code, but only
  entry 35 (channel clear) is functional — the rest return immediately. SWI
  0x1C runs the real SoundMain's ident-magic lock and calls the two
  game-registered callbacks ([info+32]([info+36]) and [info+40](info)) in
  SVC mode, then unlocks; the PCM/CGB mixer that follows in the real routine
  is not modeled, so no BIOS-driver audio is produced, the SoundInfo mixer
  bookkeeping the real routine performs (e.g. pcmDmaCounter) never updates,
  and the MPlay score-command handlers reached through the jump list are
  inert. Games that sequence music through the BIOS engine still wedge where
  they block on that state: Cyberdrive Zoids reaches its boot logos
  (f400 exact) but stalls at its music-synced title (~frame 410); Saibara
  Rieko no Dendou Mahjong runs its frame loop but blocks on mixer
  bookkeeping. Fixing them means implementing the score interpreter
  (~26 jump-list routines) and the mixer's SoundInfo protocol.
- **Interrupted-copy register remnants**: when an IRQ preempts CpuSet /
  CpuFastSet, the continuation state lives in r0/r1/r2 (PC rewound onto the
  SWI). On the interrupted path only, the halfword forms' r0/r1 advance
  (the real routine leaves them untouched) and r2's count field counts down;
  each preemption also re-pays the SWI dispatch (~50 cycles).
- **Interrupted decompression sees finished output**: LZ77/Huffman/RL are
  preempted by deliverable IRQs at faithful cycle positions (the un-charged
  remainder rides the halt-resume mechanism and is paid when execution
  returns to the instruction after the SWI), but the destination bytes are
  all written up front — a handler that inspects the destination mid-call
  sees the completed output where the real BIOS would show a partial one.
  The Diff/BitUnPack filters stay atomic.
- **Interrupted RegisterRamReset**: phases run in the real order ("other"
  I/O, SIO, sound, EWRAM, VRAM, OAM, palette, IWRAM last) with the RAM
  clears advancing in step with the charged time, and a preemption rewinds
  the PC onto the SWI with the continuation encoded in r0 (bit 31 marker +
  remaining phase charge in bits 8-29 + pending flag bits). A caller that
  passed a flags argument with bit 31 set and garbage mid bits could be
  misread as a continuation; compilers emit clean flag bytes, so this is
  theoretical.
- **Reset-vector boot shows no logo and plays no jingle**: the warm re-boot
  waits out the real duration (270 vblanks + the tail to scanline 126,
  measured against dingbat's real-BIOS execution) with the display
  force-blanked, and hands over the measured post-boot register/IO state —
  but VRAM/palette keep the pre-jump contents instead of the Nintendo logo
  frames, and the boot jingle is silent. A jump landing exactly on a vblank
  start counts that vblank (the real boot's setup would wait for the next).
- **IntrWait(discard=0) returns without halting when a masked flag is already
  set** (mGBA behavior). The real routine always halts at least once, and its
  first halt uses the caller's stale r12 for the HALTCNT store (hardware
  quirk).
- **Handler-visible r2/r4/lr/r11 during the wait** keep their caller values
  (real: mirror value / 1 / BIOS return address / spsr scratch). No known
  convention reads them; mGBA's HLE BIOS deviates the same way.
- **Nested IntrWait** (an IRQ handler itself calling IntrWait/Halt while one
  is active) overwrites the single set of resume fields; the real BIOS necks
  through the stack. The parked decompression/RamReset remainder shares the
  halt-resume fields the same way.

## Comparison of three BIOS modes against the mGBA test suite (2026-03-23)

The tables below are stale (pre-2026-07): Div/Sqrt/ArcTan/CpuSet and the
rest of the jump table have long since been implemented and calibrated —
current scores are HLE 6910/7008, official-BIOS LLE 6909/7008.

## Test Suite Results by BIOS Mode

| Suite | Embedded | Official | HLE | Notes |
|-------|----------|----------|-----|-------|
| Memory | 1376/1552 | **1396/1552** | 1129/1552 | |
| I/O read | 130/130 | 130/130 | 130/130 | All pass |
| Timing | 177/2020 | 177/2020 | 177/2020 | Same failures across all |
| Timer count-up | 336/936 | 336/936 | 336/936 | Same failures across all |
| Timer IRQ | 0/90 | 0/90 | 0/90 | Same failures across all |
| Shifter | 140/140 | 140/140 | 140/140 | All pass |
| Carry | 93/93 | 93/93 | 93/93 | All pass |
| Multiply long | 52/72 | 52/72 | 52/72 | Same failures across all |
| **BIOS math** | 603/615 | **615/615** | 287/615 | Biggest HLE gap |
| DMA | **1056/1256** | 1044/1256 | 1044/1256 | |
| SIO R/W | 90/90 | 90/90 | 90/90 | All pass |
| SIO timing | 0/4 | 0/4 | 0/4 | Same failures across all |
| Misc edge | 1/10 | 1/10 | 1/10 | Same failures across all |

## HLE Shortcomings vs Official BIOS

| Category | Tests Lost | Root Cause |
|----------|-----------|------------|
| **Div (SWI 0x06)** | ~6 | HLE maps SWI 0x06 to Halt instead of division — this is a bug |
| **Sqrt (SWI 0x08)** | ~6 | Unimplemented, returns as no-op |
| **ArcTan (SWI 0x09)** | 66 | Unimplemented, returns as no-op |
| **ArcTan2 (SWI 0x0A)** | 242 | Unimplemented, returns as no-op |
| **CpuSet (SWI 0x0B)** | 171 | Unimplemented — memory fill/copy |
| **CpuFastSet (SWI 0x0C)** | 122 | Unimplemented — fast memory fill/copy |
| **Memory BIOS access** | 247 | CpuSet/CpuFastSet tests that read from BIOS region |

Total: HLE loses ~328 tests vs official in BIOS math, ~247 in memory.

The HLE currently only implements Halt (SWI 0x02), IntrWait (SWI 0x04), and VBlankIntrWait (SWI 0x05).

## Embedded BIOS Shortcomings vs Official BIOS

| Category | Tests Lost | Root Cause |
|----------|-----------|------------|
| **ArcTan2 r1 preservation** | 6 | When first arg is 0, embedded BIOS doesn't preserve r1 correctly |
| **Div by zero edge cases** | 6 | Division by zero returns different results than official |
| **CpuSet/CpuFastSet BIOS load** | -20 | Embedded can't pass "BIOS load swi B/C" tests (BIOS memory access protection differs) |

The embedded BIOS gains +12 in DMA over official due to open bus value differences when reading from BIOS region, so net it's quite close (4054 vs 4060 total).

## Priority for HLE Improvement

1. **Fix SWI 0x06 bug** — it's mapped to Halt but should be Div (easy fix)
2. **Implement Div/Mod (SWI 0x06/0x07)** — heavily used by games
3. **Implement CpuSet/CpuFastSet (SWI 0x0B/0x0C)** — used for memory init, VRAM clears
4. **Implement Sqrt (SWI 0x08)** — simple integer square root
5. **Implement ArcTan/ArcTan2 (SWI 0x09/0x0A)** — used for rotation/angle math in games
