# mGBA Test Suite - Detailed Results

*Generated: 2026-08-03 11:39:29*

## Memory tests

All tests passed.

## I/O read tests

All tests passed.

## Timing tests (1988/2020 passed)

1988/2020 tests passed, 32 failed:

| Test | Actual | Expected |
|------|--------|----------|
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

## Timer count-up tests (935/936 passed)

935/936 tests passed, 1 failed:

| Test | Actual | Expected |
|------|--------|----------|
| 0b, 0x000C 1xv 1d 4i | FFFE | FFFF |

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

## Misc. edge case tests (4/12 passed)

4/12 tests passed, 8 failed:

| Test | Actual | Expected |
|------|--------|----------|
| DMA Prefetch Break | 0x10002A94 | 0x10002478 |
| H-blank bit start Hblank | 0x000004D0 | 0x000004D3 |
| H-blank bit start Flip 1 | 0x00000087 | 0x00000092 |
| H-blank bit start Flip 2 | 0x000003EC | 0x000003DD |
| H-blank bit start Flip 3 | 0x000000E5 | 0x000000E4 |
| H-blank bit start Flip 4 | 0x000003EB | 0x000003EC |
| H-blank bit start Flip 5 | 0x000000E3 | 0x000000F4 |
| H-blank bit start Flip 6 | 0x000003F3 | 0x000003E0 |

## Summary

- **Total:** 6998
- **Pass:** 6957
- **Fail:** 41
