# HLE BIOS Shortcomings

Comparison of three BIOS modes against the mGBA test suite (2026-03-23).

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
