# mGBA Test Suite - Detailed Results

*Generated: 2026-07-11 05:45:30*

## Memory tests (1544/1552 passed)

1544/1552 tests passed, 8 failed:

| Test | Actual | Expected |
|------|--------|----------|
| BIOS out-of-bounds load U8 | 0x00000004 | 0x00000001 |
| BIOS out-of-bounds load S8 | 0x00000004 | 0x00000002 |
| BIOS out-of-bounds load U16 | 0x00002004 | 0x00002003 |
| BIOS out-of-bounds load S16 | 0x00002004 | 0x00002005 |
| BIOS out-of-bounds load 32 | 0xE3A02004 | 0xE3A02007 |
| BIOS out-of-bounds load 32 (unaligned 1) | 0x04E3A020 | 0x08E3A020 |
| BIOS out-of-bounds load 32 (unaligned 2) | 0x2004E3A0 | 0x2009E3A0 |
| BIOS out-of-bounds load 32 (unaligned 3) | 0xA02004E3 | 0x9F000CE5 |

## I/O read tests

All tests passed.

## Timing tests (1938/2020 passed)

1938/2020 tests passed, 82 failed:

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
| Trivial DMA (16/ROM) ARM/ROM P.. | 12 | 14 |
| Trivial DMA (16/ROM) ARM/ROM PN. | 12 | 13 |
| Trivial DMA (16/ROM) ARM/ROM P.S | 12 | 13 |
| Trivial DMA (16/ROM) ARM/ROM PNS | 11 | 12 |
| Trivial DMA (16/ROM) Thumb/ROM ... | 12 | 14 |
| Trivial DMA (16/ROM) Thumb/ROM ..S | 11 | 14 |
| Trivial DMA (16/to ROM) ARM/ROM P.. | 14 | 15 |
| Trivial DMA (16/to ROM) ARM/ROM PN. | 13 | 14 |
| Trivial DMA (16/to ROM) ARM/ROM .NS | 12 | 14 |
| Trivial DMA (16/to ROM) Thumb/ROM P.. | 11 | 12 |
| Trivial DMA (16/to ROM) Thumb/ROM PN. | 10 | 11 |
| Trivial DMA (16/ROM to ROM) ARM/ROM P.. | 14 | 16 |
| Trivial DMA (16/ROM to ROM) ARM/ROM PN. | 14 | 15 |
| Trivial DMA (16/ROM to ROM) ARM/ROM P.S | 13 | 14 |
| Trivial DMA (16/ROM to ROM) ARM/ROM PNS | 12 | 13 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM ... | 14 | 16 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM ..S | 12 | 15 |
| Trivial DMA (32/from ROM) ARM/ROM P.. | 15 | 17 |
| Trivial DMA (32/from ROM) ARM/ROM PN. | 15 | 16 |
| Trivial DMA (32/from ROM) ARM/ROM P.S | 14 | 15 |
| Trivial DMA (32/from ROM) ARM/ROM PNS | 13 | 14 |
| Trivial DMA (32/from ROM) Thumb/ROM ... | 15 | 17 |
| Trivial DMA (32/from ROM) Thumb/ROM ..S | 13 | 16 |
| Trivial DMA (32/to ROM) ARM/ROM P.. | 17 | 18 |
| Trivial DMA (32/to ROM) ARM/ROM PN. | 16 | 17 |
| Trivial DMA (32/to ROM) ARM/ROM .NS | 14 | 16 |
| Trivial DMA (32/to ROM) Thumb/ROM P.. | 14 | 15 |
| Trivial DMA (32/to ROM) Thumb/ROM PN. | 13 | 14 |
| Trivial DMA (32/ROM to ROM) ARM/ROM P.. | 20 | 22 |
| Trivial DMA (32/ROM to ROM) ARM/ROM PN. | 20 | 21 |
| Trivial DMA (32/ROM to ROM) ARM/ROM P.S | 17 | 18 |
| Trivial DMA (32/ROM to ROM) ARM/ROM PNS | 16 | 17 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM ... | 20 | 22 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM ..S | 16 | 19 |
| Short DMA (16/from ROM) ARM/ROM P.. | 72 | 74 |
| Short DMA (16/from ROM) ARM/ROM PN. | 72 | 73 |
| Short DMA (16/from ROM) ARM/ROM P.S | 57 | 58 |
| Short DMA (16/from ROM) ARM/ROM PNS | 56 | 57 |
| Short DMA (16/from ROM) Thumb/ROM ... | 72 | 74 |
| Short DMA (16/from ROM) Thumb/ROM ..S | 56 | 59 |
| Short DMA (16/to ROM) ARM/ROM P.. | 74 | 75 |
| Short DMA (16/to ROM) ARM/ROM PN. | 73 | 74 |
| Short DMA (16/to ROM) ARM/ROM .NS | 57 | 59 |
| Short DMA (16/to ROM) Thumb/ROM P.. | 71 | 72 |
| Short DMA (16/to ROM) Thumb/ROM PN. | 70 | 71 |
| Short DMA (16/ROM to ROM) ARM/ROM P.. | 104 | 106 |
| Short DMA (16/ROM to ROM) ARM/ROM PN. | 104 | 105 |
| Short DMA (16/ROM to ROM) ARM/ROM P.S | 73 | 74 |
| Short DMA (16/ROM to ROM) ARM/ROM PNS | 72 | 73 |
| Short DMA (16/ROM to ROM) Thumb/ROM ... | 104 | 106 |
| Short DMA (16/ROM to ROM) Thumb/ROM ..S | 72 | 75 |
| Short DMA (32/from ROM) ARM/ROM P.. | 120 | 122 |
| Short DMA (32/from ROM) ARM/ROM PN. | 120 | 121 |
| Short DMA (32/from ROM) ARM/ROM P.S | 89 | 90 |
| Short DMA (32/from ROM) ARM/ROM PNS | 88 | 89 |
| Short DMA (32/from ROM) Thumb/ROM ... | 120 | 122 |
| Short DMA (32/from ROM) Thumb/ROM ..S | 88 | 91 |
| Short DMA (32/to ROM) ARM/ROM P.. | 122 | 123 |
| Short DMA (32/to ROM) ARM/ROM PN. | 121 | 122 |
| Short DMA (32/to ROM) ARM/ROM .NS | 89 | 91 |
| Short DMA (32/to ROM) Thumb/ROM P.. | 119 | 120 |
| Short DMA (32/to ROM) Thumb/ROM PN. | 118 | 119 |
| Short DMA (32/ROM to ROM) ARM/ROM P.. | 200 | 202 |
| Short DMA (32/ROM to ROM) ARM/ROM PN. | 200 | 201 |
| Short DMA (32/ROM to ROM) ARM/ROM P.S | 137 | 138 |
| Short DMA (32/ROM to ROM) ARM/ROM PNS | 136 | 137 |
| Short DMA (32/ROM to ROM) Thumb/ROM ... | 200 | 202 |
| Short DMA (32/ROM to ROM) Thumb/ROM ..S | 136 | 139 |

## Timer count-up tests (785/936 passed)

785/936 tests passed, 151 failed:

| Test | Actual | Expected |
|------|--------|----------|
| 0b, 0x0005 1xv 1d 2i | FFFC | FFFB |
| 0b, 0x0005 16xv 1d 2i | FFFF | FFFE |
| 0b, 0x0005 1xv 2d 2i | FFFC | FFFB |
| 0b, 0x0005 16xv 2d 2i | FFFF | FFFE |
| 0b, 0x0005 1xv 4d 2i | FFFC | FFFB |
| 0b, 0x0005 16xv 4d 2i | FFFF | FFFE |
| 0b, 0x0005 1xv 1d 4i | FFFB | FFFD |
| 0b, 0x0005 16xv 1d 4i | FFFE | FFFB |
| 0b, 0x0005 1xv 2d 4i | FFFB | FFFD |
| 0b, 0x0005 16xv 2d 4i | FFFE | FFFB |
| 0b, 0x0005 1xv 4d 4i | FFFB | FFFD |
| 0b, 0x0005 16xv 4d 4i | FFFE | FFFB |
| 0b, 0x000C 1xv 1d 2i | FFFE | FFFD |
| 0b, 0x000C 16xv 1d 2i | FFF4 | FFFF |
| 0b, 0x000C 1xv 2d 2i | FFFE | FFFD |
| 0b, 0x000C 16xv 2d 2i | FFF4 | FFFF |
| 0b, 0x000C 1xv 4d 2i | FFFE | FFFD |
| 0b, 0x000C 16xv 4d 2i | FFF4 | FFFF |
| 0b, 0x000C 1xv 1d 4i | FFF6 | FFFF |
| 0b, 0x000C 16xv 1d 4i | FFF8 | FFF5 |
| 0b, 0x000C 1xv 2d 4i | FFF6 | FFFF |
| 0b, 0x000C 16xv 2d 4i | FFF8 | FFF5 |
| 0b, 0x000C 1xv 4d 4i | FFF6 | FFFF |
| 0b, 0x000C 16xv 4d 4i | FFF8 | FFF5 |
| 0b, 0x000D 1xv 1d 2i | FFFB | FFFA |
| 0b, 0x000D 16xv 1d 2i | FFFA | FFF9 |
| 0b, 0x000D 1xv 2d 2i | FFFB | FFFA |
| 0b, 0x000D 16xv 2d 2i | FFFA | FFF9 |
| 0b, 0x000D 1xv 4d 2i | FFFB | FFFA |
| 0b, 0x000D 16xv 4d 2i | FFFA | FFF9 |
| 0b, 0x000D 1xv 1d 4i | FFF8 | FFF5 |
| 0b, 0x000D 16xv 1d 4i | FFF7 | FFF4 |
| 0b, 0x000D 1xv 2d 4i | FFF8 | FFF5 |
| 0b, 0x000D 16xv 2d 4i | FFF7 | FFF4 |
| 0b, 0x000D 1xv 4d 4i | FFF8 | FFF5 |
| 0b, 0x000D 16xv 4d 4i | FFF7 | FFF4 |
| 0b, 0x0010 1xv 1d 2i | FFF6 | FFF5 |
| 0b, 0x0010 16xv 1d 2i | FFF8 | FFF7 |
| 0b, 0x0010 1xv 2d 2i | FFF6 | FFF5 |
| 0b, 0x0010 16xv 2d 2i | FFF8 | FFF7 |
| 0b, 0x0010 1xv 4d 2i | FFF6 | FFF5 |
| 0b, 0x0010 16xv 4d 2i | FFF8 | FFF7 |
| 0b, 0x0010 1xv 1d 4i | FFFA | FFF7 |
| 0b, 0x0010 16xv 1d 4i | FFFC | FFF9 |
| 0b, 0x0010 1xv 2d 4i | FFFA | FFF7 |
| 0b, 0x0010 16xv 2d 4i | FFFC | FFF9 |
| 0b, 0x0010 1xv 4d 4i | FFFA | FFF7 |
| 0b, 0x0010 16xv 4d 4i | FFFC | FFF9 |
| 0b, 0x0014 1xv 1d 2i | FFFA | FFF9 |
| 0b, 0x0014 16xv 1d 2i | FFFA | FFF9 |
| 0b, 0x0014 1xv 2d 2i | FFFA | FFF9 |
| 0b, 0x0014 16xv 2d 2i | FFFA | FFF9 |
| 0b, 0x0014 1xv 4d 2i | FFFA | FFF9 |
| 0b, 0x0014 16xv 4d 2i | FFFA | FFF9 |
| 0b, 0x0014 1xv 1d 4i | FFFE | FFFB |
| 0b, 0x0014 16xv 1d 4i | FFFE | FFFB |
| 0b, 0x0014 1xv 2d 4i | FFFE | FFFB |
| 0b, 0x0014 16xv 2d 4i | FFFE | FFFB |
| 0b, 0x0014 1xv 4d 4i | FFFE | FFFB |
| 0b, 0x0014 16xv 4d 4i | FFFE | FFFB |
| 0b, 0x0015 1xv 1d 2i | FFF1 | FFF0 |
| 0b, 0x0015 16xv 1d 2i | FFEF | FFEE |
| 0b, 0x0015 1xv 2d 2i | FFF1 | FFF0 |
| 0b, 0x0015 16xv 2d 2i | FFEF | FFEE |
| 0b, 0x0015 1xv 4d 2i | FFF1 | FFF0 |
| 0b, 0x0015 16xv 4d 2i | FFEF | FFEE |
| 0b, 0x0015 1xv 1d 4i | FFFE | FFFB |
| 0b, 0x0015 16xv 1d 4i | FFFC | FFF9 |
| 0b, 0x0015 1xv 2d 4i | FFFE | FFFB |
| 0b, 0x0015 16xv 2d 4i | FFFC | FFF9 |
| 0b, 0x0015 1xv 4d 4i | FFFE | FFFB |
| 0b, 0x0015 16xv 4d 4i | FFFC | FFF9 |
| 0b, 0x0020 1xv 1d 2i | FFF6 | FFF5 |
| 0b, 0x0020 16xv 1d 2i | FFF6 | FFF5 |
| 0b, 0x0020 1xv 2d 2i | FFF6 | FFF5 |
| 0b, 0x0020 16xv 2d 2i | FFF6 | FFF5 |
| 0b, 0x0020 1xv 4d 2i | FFF6 | FFF5 |
| 0b, 0x0020 16xv 4d 2i | FFF6 | FFF5 |
| 0b, 0x0020 1xv 1d 4i | FFEA | FFE7 |
| 0b, 0x0020 16xv 1d 4i | FFEA | FFE7 |
| 0b, 0x0020 1xv 2d 4i | FFEA | FFE7 |
| 0b, 0x0020 16xv 2d 4i | FFEA | FFE7 |
| 0b, 0x0020 1xv 4d 4i | FFEA | FFE7 |
| 0b, 0x0020 16xv 4d 4i | FFEA | FFE7 |
| 0b, 0x0024 1xv 1d 2i | FFFE | FFFD |
| 0b, 0x0024 16xv 1d 2i | FFFF | FFFE |
| 0b, 0x0024 1xv 2d 2i | FFFE | FFFD |
| 0b, 0x0024 16xv 2d 2i | FFFF | FFFE |
| 0b, 0x0024 1xv 4d 2i | FFFE | FFFD |
| 0b, 0x0024 16xv 4d 2i | FFFF | FFFE |
| 0b, 0x0024 1xv 1d 4i | FFF6 | FFF3 |
| 0b, 0x0024 16xv 1d 4i | FFF7 | FFF4 |
| 0b, 0x0024 1xv 2d 4i | FFF6 | FFF3 |
| 0b, 0x0024 16xv 2d 4i | FFF7 | FFF4 |
| 0b, 0x0024 1xv 4d 4i | FFF6 | FFF3 |
| 0b, 0x0024 16xv 4d 4i | FFF7 | FFF4 |
| 0b, 0x0025 1xv 1d 2i | FFFA | FFF9 |
| 0b, 0x0025 16xv 1d 2i | FFF8 | FFF7 |
| 0b, 0x0025 1xv 2d 2i | FFFA | FFF9 |
| 0b, 0x0025 16xv 2d 2i | FFF8 | FFF7 |
| 0b, 0x0025 1xv 4d 2i | FFFA | FFF9 |
| 0b, 0x0025 16xv 4d 2i | FFF8 | FFF7 |
| 0b, 0x0025 1xv 1d 4i | FFEB | FFE8 |
| 0b, 0x0025 16xv 1d 4i | FFE9 | FFE6 |
| 0b, 0x0025 1xv 2d 4i | FFEB | FFE8 |
| 0b, 0x0025 16xv 2d 4i | FFE9 | FFE6 |
| 0b, 0x0025 1xv 4d 4i | FFEB | FFE8 |
| 0b, 0x0025 16xv 4d 4i | FFE9 | FFE6 |
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

## DMA tests (1232/1256 passed)

1232/1256 tests passed, 24 failed:

| Test | Actual | Expected |
|------|--------|----------|
| 0 Imm W -SRAM/=IWRAM 3 | A5B6C7D8 | 00000000 |
| 1 Imm W -SRAM/=IWRAM 3 | 00000000 | 47474747 |
| 2 Imm W -SRAM/=IWRAM 3 | 00000000 | 47474747 |
| 3 Imm W -SRAM/=IWRAM 3 | 00000000 | 47474747 |
| 0 Imm W -SRAM/=EWRAM 3 | A5B6C7D8 | 00000000 |
| 1 Imm W -SRAM/=EWRAM 3 | 00000000 | 47474747 |
| 2 Imm W -SRAM/=EWRAM 3 | 00000000 | 47474747 |
| 3 Imm W -SRAM/=EWRAM 3 | 00000000 | 47474747 |
| 0 HBl W -SRAM/=IWRAM 3 | A5B6C7D8 | 00000000 |
| 1 HBl W -SRAM/=IWRAM 3 | 00000000 | 47474747 |
| 2 HBl W -SRAM/=IWRAM 3 | 00000000 | 47474747 |
| 3 HBl W -SRAM/=IWRAM 3 | 00000000 | 47474747 |
| 0 HBl W -SRAM/=EWRAM 3 | A5B6C7D8 | 00000000 |
| 1 HBl W -SRAM/=EWRAM 3 | 00000000 | 47474747 |
| 2 HBl W -SRAM/=EWRAM 3 | 00000000 | 47474747 |
| 3 HBl W -SRAM/=EWRAM 3 | 00000000 | 47474747 |
| 0 Imm W R+0x10/+IWRAM 3 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+IWRAM 4 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+IWRAM 5 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+IWRAM 6 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+EWRAM 3 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+EWRAM 4 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+EWRAM 5 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+EWRAM 6 | A5B6C7D8 | 00000000 |

## SIO register R/W tests

All tests passed.

## SIO timing tests

All tests passed.

## Misc. edge case tests (1/10 passed)

1/10 tests passed, 9 failed:

| Test | Actual | Expected |
|------|--------|----------|
| DMA Prefetch Break | 0x10002A64 | 0x10000004 |
| DMA Prefetch Read | 0xDEAD0000 | 0xE3A02004 |
| H-blank bit start Hblank | 0x000004D1 | 0x000004D0 |
| H-blank bit start Flip 1 | 0x00000085 | 0x000000C8 |
| H-blank bit start Flip 2 | 0x000003EC | 0x00000400 |
| H-blank bit start Flip 3 | 0x000000E4 | 0x000000E1 |
| H-blank bit start Flip 4 | 0x000003EC | 0x000003E0 |
| H-blank bit start Flip 5 | 0x000000E4 | 0x000000E0 |
| H-blank bit start Flip 6 | 0x000003F5 | 0x00000420 |

## Summary

- **Total:** 7008
- **Pass:** 6734
- **Fail:** 274
