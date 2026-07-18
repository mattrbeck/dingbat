# mGBA Test Suite - Detailed Results

*Generated: 2026-07-18 16:25:15*

## Memory tests

All tests passed.

## I/O read tests

All tests passed.

## Timing tests (1974/2020 passed)

1974/2020 tests passed, 46 failed:

| Test | Actual | Expected |
|------|--------|----------|
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM P.S | 16 | 17 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM PNS | 14 | 15 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM P.S | 28 | 29 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM PNS | 26 | 27 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM P.S | 26 | 27 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM PNS | 24 | 25 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM P.. | 31 | 32 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM PN. | 29 | 30 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM P.. | 28 | 29 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM PN. | 26 | 27 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM P.S | 22 | 23 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM PNS | 20 | 21 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM P.S | 20 | 21 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM PNS | 18 | 19 |
| Trivial DMA (16/ROM) ARM/ROM P.S | 12 | 13 |
| Trivial DMA (16/ROM) ARM/ROM PNS | 11 | 12 |
| Trivial DMA (16/to ROM) ARM/ROM P.. | 14 | 15 |
| Trivial DMA (16/to ROM) ARM/ROM PN. | 13 | 14 |
| Trivial DMA (16/to ROM) Thumb/ROM P.. | 11 | 12 |
| Trivial DMA (16/to ROM) Thumb/ROM PN. | 10 | 11 |
| Trivial DMA (16/ROM to ROM) ARM/ROM P.S | 13 | 14 |
| Trivial DMA (16/ROM to ROM) ARM/ROM PNS | 12 | 13 |
| Trivial DMA (32/from ROM) ARM/ROM P.S | 14 | 15 |
| Trivial DMA (32/from ROM) ARM/ROM PNS | 13 | 14 |
| Trivial DMA (32/to ROM) ARM/ROM P.. | 17 | 18 |
| Trivial DMA (32/to ROM) ARM/ROM PN. | 16 | 17 |
| Trivial DMA (32/to ROM) Thumb/ROM P.. | 14 | 15 |
| Trivial DMA (32/to ROM) Thumb/ROM PN. | 13 | 14 |
| Trivial DMA (32/ROM to ROM) ARM/ROM P.S | 17 | 18 |
| Trivial DMA (32/ROM to ROM) ARM/ROM PNS | 16 | 17 |
| Short DMA (16/from ROM) ARM/ROM P.S | 57 | 58 |
| Short DMA (16/from ROM) ARM/ROM PNS | 56 | 57 |
| Short DMA (16/to ROM) ARM/ROM P.. | 74 | 75 |
| Short DMA (16/to ROM) ARM/ROM PN. | 73 | 74 |
| Short DMA (16/to ROM) Thumb/ROM P.. | 71 | 72 |
| Short DMA (16/to ROM) Thumb/ROM PN. | 70 | 71 |
| Short DMA (16/ROM to ROM) ARM/ROM P.S | 73 | 74 |
| Short DMA (16/ROM to ROM) ARM/ROM PNS | 72 | 73 |
| Short DMA (32/from ROM) ARM/ROM P.S | 89 | 90 |
| Short DMA (32/from ROM) ARM/ROM PNS | 88 | 89 |
| Short DMA (32/to ROM) ARM/ROM P.. | 122 | 123 |
| Short DMA (32/to ROM) ARM/ROM PN. | 121 | 122 |
| Short DMA (32/to ROM) Thumb/ROM P.. | 119 | 120 |
| Short DMA (32/to ROM) Thumb/ROM PN. | 118 | 119 |
| Short DMA (32/ROM to ROM) ARM/ROM P.S | 137 | 138 |
| Short DMA (32/ROM to ROM) ARM/ROM PNS | 136 | 137 |

## Timer count-up tests (893/936 passed)

893/936 tests passed, 43 failed:

| Test | Actual | Expected |
|------|--------|----------|
| 0b, 0x0040 1xv 1d 2i | FFDD | FFDC |
| 0b, 0x0040 1xv 2d 2i | FFDD | FFDC |
| 0b, 0x0040 1xv 4d 2i | FFDD | FFDC |
| 0b, 0x0040 1xs 1d 4i | 0000000C | 0000000D |
| 0b, 0x0040 1xv 1d 4i | FFDD | FFDE |
| 0b, 0x0040 16xv 1d 4i | FFDD | FFDE |
| 0b, 0x0040 1xs 2d 4i | 0000000C | 0000000D |
| 0b, 0x0040 1xv 2d 4i | FFDD | FFDE |
| 0b, 0x0040 16xv 2d 4i | FFDD | FFDE |
| 0b, 0x0040 1xs 4d 4i | 0000000C | 0000000D |
| 0b, 0x0040 1xv 4d 4i | FFDD | FFDE |
| 0b, 0x0040 16xv 4d 4i | FFDD | FFDE |
| 0b, 0x0080 1xv 1d 2i | FFDD | FFDC |
| 0b, 0x0080 1xv 2d 2i | FFDD | FFDC |
| 0b, 0x0080 1xv 4d 2i | FFDD | FFDC |
| 0b, 0x0080 1xs 1d 4i | 00000014 | 00000015 |
| 0b, 0x0080 1xv 1d 4i | FFDD | FFDE |
| 0b, 0x0080 1xs 2d 4i | 00000014 | 00000015 |
| 0b, 0x0080 1xv 2d 4i | FFDD | FFDE |
| 0b, 0x0080 1xs 4d 4i | 00000014 | 00000015 |
| 0b, 0x0080 1xv 4d 4i | FFDD | FFDE |
| 0b, 0x0800 1xv 1d 2i | F85D | F85C |
| 0b, 0x0800 1xv 2d 2i | F85D | F85C |
| 0b, 0x0800 1xv 4d 2i | F85D | F85C |
| 0b, 0x0800 1xs 1d 4i | 000003D4 | 000003D5 |
| 0b, 0x0800 1xv 1d 4i | F85D | F85E |
| 0b, 0x0800 1xs 2d 4i | 000003D4 | 000003D5 |
| 0b, 0x0800 1xv 2d 4i | F85D | F85E |
| 0b, 0x0800 1xs 4d 4i | 000003D4 | 000003D5 |
| 0b, 0x0800 1xv 4d 4i | F85D | F85E |
| 0b, 0x8000 1xv 1d 2i | 805D | 805C |
| 0b, 0x8000 1xv 2d 2i | 805D | 805C |
| 0b, 0x8000 1xv 4d 2i | 805D | 805C |
| 0b, 0x8000 1xs 1d 4i | 00003FD4 | 00003FD5 |
| 0b, 0x8000 1xv 1d 4i | 805D | 805E |
| 0b, 0x8000 1xs 2d 4i | 00003FD4 | 00003FD5 |
| 0b, 0x8000 1xv 2d 4i | 805D | 805E |
| 0b, 0x8000 1xs 4d 4i | 00003FD4 | 00003FD5 |
| 0b, 0x8000 1xv 4d 4i | 805D | 805E |
| 8b, 0x0011 16xs 4d 4i | 00002DD0 | 00002DE0 |
| 8b, 0x0013 16xs 4d 4i | 00003360 | 00003370 |
| 10b, 0x0011 16xs 2d 4i | 0000BBC0 | 0000BBD0 |
| 10b, 0x0012 16xs 1d 1i | 000031B0 | 000031A0 |

## Timer IRQ tests

All tests passed.

## Shifter tests

All tests passed.

## Carry tests

All tests passed.

## Multiply long tests

All tests passed.

## BIOS math tests

All tests passed.

## DMA tests

All tests passed.

## SIO register R/W tests

All tests passed.

## SIO timing tests

All tests passed.

## Misc. edge case tests (1/10 passed)

1/10 tests passed, 9 failed:

| Test | Actual | Expected |
|------|--------|----------|
| DMA Prefetch Break | 0x10002A64 | 0x00000000 |
| DMA Prefetch Read | 0xDEAD0000 | 0x428A428A |
| H-blank bit start Hblank | 0x000004D1 | 0x000004D0 |
| H-blank bit start Flip 1 | 0x00000085 | 0x000000C7 |
| H-blank bit start Flip 2 | 0x000003EC | 0x000003E0 |
| H-blank bit start Flip 3 | 0x000000E4 | 0x000000E1 |
| H-blank bit start Flip 4 | 0x000003EC | 0x00000420 |
| H-blank bit start Flip 5 | 0x000000E4 | 0x000000C0 |
| H-blank bit start Flip 6 | 0x000003F5 | 0x000003E0 |

## Summary

- **Total:** 7008
- **Pass:** 6910
- **Fail:** 98
