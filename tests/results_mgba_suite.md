# mGBA Test Suite - Detailed Results

*Generated: 2026-09-15 14:33:24*

## Memory tests

All tests passed.

## I/O read tests

All tests passed.

## Timing tests

All tests passed.

## Timer count-up tests

All tests passed.

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

## Misc. edge case tests (5/12 passed)

5/12 tests passed, 7 failed:

| Test | Actual | Expected |
|------|--------|----------|
| DMA Prefetch Break | 0x10002944 | 0x10002A94 |
| H-blank bit start Hblank | 0x000004D3 | 0x000004D0 |
| H-blank bit start Flip 1 | 0x00000080 | 0x00000087 |
| H-blank bit start Flip 2 | 0x000003ED | 0x000003EC |
| H-blank bit start Flip 3 | 0x000000E3 | 0x000000E5 |
| H-blank bit start Flip 4 | 0x000003F3 | 0x000003EB |
| H-blank bit start Flip 6 | 0x000003E9 | 0x000003F3 |

## Summary

- **Total:** 6998
- **Pass:** 6991
- **Fail:** 7
