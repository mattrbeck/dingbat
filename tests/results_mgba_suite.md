# mGBA Test Suite - Detailed Results

*Generated: 2026-07-08 18:37:37*

## Memory tests (1448/1552 passed)

1448/1552 tests passed, 104 failed:

| Test | Actual | Expected |
|------|--------|----------|
| SRAM load DMA1 16 (unaligned) | 0x00006161 | 0x00004747 |
| SRAM load DMA1 32 (unaligned 1) | 0x61616161 | 0x47474747 |
| SRAM load DMA1 32 (unaligned 2) | 0x6D6D6D6D | 0x47474747 |
| SRAM load DMA1 32 (unaligned 3) | 0x65656565 | 0x47474747 |
| SRAM load DMA2 16 (unaligned) | 0x00006161 | 0x00004747 |
| SRAM load DMA2 32 (unaligned 1) | 0x61616161 | 0x47474747 |
| SRAM load DMA2 32 (unaligned 2) | 0x6D6D6D6D | 0x47474747 |
| SRAM load DMA2 32 (unaligned 3) | 0x65656565 | 0x47474747 |
| SRAM load DMA3 16 (unaligned) | 0x00006161 | 0x00004747 |
| SRAM load DMA3 32 (unaligned 1) | 0x61616161 | 0x47474747 |
| SRAM load DMA3 32 (unaligned 2) | 0x6D6D6D6D | 0x47474747 |
| SRAM load DMA3 32 (unaligned 3) | 0x65656565 | 0x47474747 |
| SRAM load swi B 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM load swi B 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM load swi B 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM load swi C 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM load swi C 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM load swi C 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM mirror load DMA1 16 (unaligned) | 0x00006161 | 0x00004747 |
| SRAM mirror load DMA1 32 (unaligned 1) | 0x61616161 | 0x47474747 |
| SRAM mirror load DMA1 32 (unaligned 2) | 0x6D6D6D6D | 0x47474747 |
| SRAM mirror load DMA1 32 (unaligned 3) | 0x65656565 | 0x47474747 |
| SRAM mirror load DMA2 16 (unaligned) | 0x00006161 | 0x00004747 |
| SRAM mirror load DMA2 32 (unaligned 1) | 0x61616161 | 0x47474747 |
| SRAM mirror load DMA2 32 (unaligned 2) | 0x6D6D6D6D | 0x47474747 |
| SRAM mirror load DMA2 32 (unaligned 3) | 0x65656565 | 0x47474747 |
| SRAM mirror load DMA3 16 (unaligned) | 0x00006161 | 0x00004747 |
| SRAM mirror load DMA3 32 (unaligned 1) | 0x61616161 | 0x47474747 |
| SRAM mirror load DMA3 32 (unaligned 2) | 0x6D6D6D6D | 0x47474747 |
| SRAM mirror load DMA3 32 (unaligned 3) | 0x65656565 | 0x47474747 |
| SRAM mirror load swi B 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM mirror load swi B 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM mirror load swi B 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM mirror load swi C 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM mirror load swi C 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM mirror load swi C 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM store DMA3 16 (unaligned) | 0x66666666 | 0xD8D8D8D8 |
| SRAM store DMA3 32 (unaligned 1) | 0x66666666 | 0xD8D8D8D8 |
| SRAM store DMA3 32 (unaligned 2) | 0x66666666 | 0xD8D8D8D8 |
| SRAM store DMA3 32 (unaligned 3) | 0x66666666 | 0xD8D8D8D8 |
| SRAM store swi B 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi B 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi B 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi C 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi C 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi C 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store DMA3 16 (unaligned) | 0x66666666 | 0xD8D8D8D8 |
| SRAM mirror store DMA3 32 (unaligned 1) | 0x66666666 | 0xD8D8D8D8 |
| SRAM mirror store DMA3 32 (unaligned 2) | 0x66666666 | 0xD8D8D8D8 |
| SRAM mirror store DMA3 32 (unaligned 3) | 0x66666666 | 0xD8D8D8D8 |
| SRAM mirror store swi B 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi B 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi B 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi C 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi C 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi C 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| BIOS load U16 | 0x0000F004 | 0x00002004 |
| BIOS load U16 (unaligned) | 0x040000F0 | 0x04000020 |
| BIOS load S16 | 0xFFFFF004 | 0x00002004 |
| BIOS load S16 (unaligned) | 0xFFFFFFF0 | 0x00000020 |
| BIOS load 32 | 0xE25EF004 | 0xE3A02004 |
| BIOS load 32 (unaligned 1) | 0x04E25EF0 | 0x04E3A020 |
| BIOS load 32 (unaligned 2) | 0xF004E25E | 0x2004E3A0 |
| BIOS load 32 (unaligned 3) | 0x5EF004E2 | 0xA02004E3 |
| BIOS load swi B 16 | 0xE25EF004 | 0x00000000 |
| BIOS load swi B 16 (unaligned) | 0x00E200F0 | 0x00000000 |
| BIOS load swi B 32 | 0xE25EF004 | 0x00000000 |
| BIOS load swi B 32 (unaligned 1) | 0xE25EF004 | 0x00000000 |
| BIOS load swi B 32 (unaligned 2) | 0xE25EF004 | 0x00000000 |
| BIOS load swi B 32 (unaligned 3) | 0xE25EF004 | 0x00000000 |
| BIOS load swi C 32 | 0xE25EF004 | 0x00000000 |
| BIOS load swi C 32 (unaligned 1) | 0xE25EF004 | 0x00000000 |
| BIOS load swi C 32 (unaligned 2) | 0xE25EF004 | 0x00000000 |
| BIOS load swi C 32 (unaligned 3) | 0xE25EF004 | 0x00000000 |
| BIOS out-of-bounds load U8 | 0x00000004 | 0x00000001 |
| BIOS out-of-bounds load S8 | 0x00000004 | 0x00000002 |
| BIOS out-of-bounds load U16 | 0x0000F004 | 0x00002003 |
| BIOS out-of-bounds load U16 (unaligned) | 0x040000F0 | 0x04000020 |
| BIOS out-of-bounds load S16 | 0xFFFFF004 | 0x00002005 |
| BIOS out-of-bounds load S16 (unaligned) | 0xFFFFFFF0 | 0x00000020 |
| BIOS out-of-bounds load 32 | 0xE25EF004 | 0xE3A02007 |
| BIOS out-of-bounds load 32 (unaligned 1) | 0x04E25EF0 | 0x08E3A020 |
| BIOS out-of-bounds load 32 (unaligned 2) | 0xF004E25E | 0x2009E3A0 |
| BIOS out-of-bounds load 32 (unaligned 3) | 0x5EF004E2 | 0x9F000CE5 |
| BIOS out-of-bounds load swi B 16 | 0xE25EF004 | 0x00000000 |
| BIOS out-of-bounds load swi B 16 (unaligned) | 0x00E200F0 | 0x00000000 |
| BIOS out-of-bounds load swi B 32 | 0xE25EF004 | 0x00000000 |
| BIOS out-of-bounds load swi B 32 (unaligned 1) | 0xE25EF004 | 0x00000000 |
| BIOS out-of-bounds load swi B 32 (unaligned 2) | 0xE25EF004 | 0x00000000 |
| BIOS out-of-bounds load swi B 32 (unaligned 3) | 0xE25EF004 | 0x00000000 |
| BIOS out-of-bounds load swi C 32 | 0xE25EF004 | 0x00000000 |
| BIOS out-of-bounds load swi C 32 (unaligned 1) | 0xE25EF004 | 0x00000000 |
| BIOS out-of-bounds load swi C 32 (unaligned 2) | 0xE25EF004 | 0x00000000 |
| BIOS out-of-bounds load swi C 32 (unaligned 3) | 0xE25EF004 | 0x00000000 |
| Out-of-bounds load swi B 16 | 0xDF0CDF0C | 0x00000000 |
| Out-of-bounds load swi B 16 (unaligned) | 0x00DF00DF | 0x00000000 |
| Out-of-bounds load swi B 32 | 0xDF0CDF0C | 0x00000000 |
| Out-of-bounds load swi B 32 (unaligned 1) | 0xDF0CDF0C | 0x00000000 |
| Out-of-bounds load swi B 32 (unaligned 2) | 0xDF0CDF0C | 0x00000000 |
| Out-of-bounds load swi B 32 (unaligned 3) | 0xDF0CDF0C | 0x00000000 |
| Out-of-bounds load swi C 32 | 0x4B014B01 | 0x00000000 |
| Out-of-bounds load swi C 32 (unaligned 1) | 0x4B014B01 | 0x00000000 |
| Out-of-bounds load swi C 32 (unaligned 2) | 0x4B014B01 | 0x00000000 |
| Out-of-bounds load swi C 32 (unaligned 3) | 0x4B014B01 | 0x00000000 |

## I/O read tests

All tests passed.

## Timing tests (183/2020 passed)

183/2020 tests passed, 1837 failed:

| Test | Actual | Expected |
|------|--------|----------|
| Calibration ARM/ROM ... | 5 | 7 |
| Calibration ARM/ROM P.. | 5 | 4 |
| Calibration ARM/ROM .N. | 5 | 6 |
| Calibration ARM/ROM PN. | 5 | 4 |
| Calibration ARM/ROM ..S | 5 | 6 |
| Calibration ARM/ROM P.S | 5 | 2 |
| Calibration ARM/ROM PNS | 5 | 2 |
| Calibration ARM/WRAM | 7 | 5 |
| Calibration ARM/IWRAM | 2 | 0 |
| Calibration Thumb/ROM ... | 3 | 4 |
| Calibration Thumb/ROM P.. | 3 | 1 |
| Calibration Thumb/ROM PN. | 3 | 1 |
| Calibration Thumb/ROM ..S | 3 | 4 |
| Calibration Thumb/ROM P.S | 3 | 0 |
| Calibration Thumb/ROM PNS | 3 | 0 |
| Calibration Thumb/WRAM | 4 | 2 |
| Calibration Thumb/IWRAM | 2 | 0 |
| nop ARM/ROM ... | 4 | 6 |
| nop ARM/ROM P.. | 4 | 6 |
| nop ARM/ROM .N. | 4 | 6 |
| nop ARM/ROM PN. | 4 | 6 |
| nop Thumb/ROM ... | 2 | 3 |
| nop Thumb/ROM P.. | 2 | 3 |
| nop Thumb/ROM .N. | 2 | 3 |
| nop Thumb/ROM PN. | 2 | 3 |
| nop / nop ARM/ROM ... | 8 | 12 |
| nop / nop ARM/ROM P.. | 8 | 12 |
| nop / nop ARM/ROM .N. | 8 | 12 |
| nop / nop ARM/ROM PN. | 8 | 12 |
| nop / nop Thumb/ROM ... | 4 | 6 |
| nop / nop Thumb/ROM P.. | 4 | 6 |
| nop / nop Thumb/ROM .N. | 4 | 6 |
| nop / nop Thumb/ROM PN. | 4 | 6 |
| ldrh r2, [sp] ARM/ROM ... | 5 | 10 |
| ldrh r2, [sp] ARM/ROM P.. | 5 | 6 |
| ldrh r2, [sp] ARM/ROM .N. | 5 | 9 |
| ldrh r2, [sp] ARM/ROM PN. | 5 | 6 |
| ldrh r2, [sp] ARM/ROM ..S | 5 | 9 |
| ldrh r2, [sp] ARM/ROM P.S | 5 | 4 |
| ldrh r2, [sp] ARM/ROM .NS | 5 | 8 |
| ldrh r2, [sp] ARM/ROM PNS | 5 | 4 |
| ldrh r2, [sp] ARM/WRAM | 7 | 8 |
| ldrh r2, [sp] ARM/IWRAM | 2 | 3 |
| ldrh r2, [sp] Thumb/ROM ... | 3 | 7 |
| ldrh r2, [sp] Thumb/ROM .N. | 3 | 6 |
| ldrh r2, [sp] Thumb/ROM ..S | 3 | 7 |
| ldrh r2, [sp] Thumb/ROM .NS | 3 | 6 |
| ldrh r2, [sp] Thumb/WRAM | 4 | 5 |
| ldrh r2, [sp] Thumb/IWRAM | 2 | 3 |
| ldrh r2, [sp] / nop ARM/ROM ... | 9 | 16 |
| ldrh r2, [sp] / nop ARM/ROM P.. | 9 | 12 |
| ldrh r2, [sp] / nop ARM/ROM .N. | 9 | 15 |
| ldrh r2, [sp] / nop ARM/ROM PN. | 9 | 12 |
| ldrh r2, [sp] / nop ARM/ROM ..S | 9 | 13 |
| ldrh r2, [sp] / nop ARM/ROM P.S | 9 | 8 |
| ldrh r2, [sp] / nop ARM/ROM .NS | 9 | 12 |
| ldrh r2, [sp] / nop ARM/ROM PNS | 9 | 8 |
| ldrh r2, [sp] / nop ARM/WRAM | 13 | 14 |
| ldrh r2, [sp] / nop ARM/IWRAM | 3 | 4 |
| ldrh r2, [sp] / nop Thumb/ROM ... | 5 | 10 |
| ldrh r2, [sp] / nop Thumb/ROM P.. | 5 | 6 |
| ldrh r2, [sp] / nop Thumb/ROM .N. | 5 | 9 |
| ldrh r2, [sp] / nop Thumb/ROM PN. | 5 | 6 |
| ldrh r2, [sp] / nop Thumb/ROM ..S | 5 | 9 |
| ldrh r2, [sp] / nop Thumb/ROM P.S | 5 | 4 |
| ldrh r2, [sp] / nop Thumb/ROM .NS | 5 | 8 |
| ldrh r2, [sp] / nop Thumb/ROM PNS | 5 | 4 |
| ldrh r2, [sp] / nop Thumb/WRAM | 7 | 8 |
| ldrh r2, [sp] / nop Thumb/IWRAM | 3 | 4 |
| nop / ldrh r2, [sp] ARM/ROM ... | 9 | 16 |
| nop / ldrh r2, [sp] ARM/ROM P.. | 9 | 12 |
| nop / ldrh r2, [sp] ARM/ROM .N. | 9 | 15 |
| nop / ldrh r2, [sp] ARM/ROM PN. | 9 | 12 |
| nop / ldrh r2, [sp] ARM/ROM ..S | 9 | 13 |
| nop / ldrh r2, [sp] ARM/ROM P.S | 9 | 8 |
| nop / ldrh r2, [sp] ARM/ROM .NS | 9 | 12 |
| nop / ldrh r2, [sp] ARM/ROM PNS | 9 | 8 |
| nop / ldrh r2, [sp] ARM/WRAM | 13 | 14 |
| nop / ldrh r2, [sp] ARM/IWRAM | 3 | 4 |
| nop / ldrh r2, [sp] Thumb/ROM ... | 5 | 10 |
| nop / ldrh r2, [sp] Thumb/ROM P.. | 5 | 6 |
| nop / ldrh r2, [sp] Thumb/ROM .N. | 5 | 9 |
| nop / ldrh r2, [sp] Thumb/ROM PN. | 5 | 6 |
| nop / ldrh r2, [sp] Thumb/ROM ..S | 5 | 9 |
| nop / ldrh r2, [sp] Thumb/ROM .NS | 5 | 8 |
| nop / ldrh r2, [sp] Thumb/WRAM | 7 | 8 |
| nop / ldrh r2, [sp] Thumb/IWRAM | 3 | 4 |
| nop / ldrh r2, [sp] / nop ARM/ROM ... | 13 | 22 |
| nop / ldrh r2, [sp] / nop ARM/ROM P.. | 13 | 18 |
| nop / ldrh r2, [sp] / nop ARM/ROM .N. | 13 | 21 |
| nop / ldrh r2, [sp] / nop ARM/ROM PN. | 13 | 18 |
| nop / ldrh r2, [sp] / nop ARM/ROM ..S | 13 | 17 |
| nop / ldrh r2, [sp] / nop ARM/ROM P.S | 13 | 12 |
| nop / ldrh r2, [sp] / nop ARM/ROM .NS | 13 | 16 |
| nop / ldrh r2, [sp] / nop ARM/ROM PNS | 13 | 12 |
| nop / ldrh r2, [sp] / nop ARM/WRAM | 19 | 20 |
| nop / ldrh r2, [sp] / nop ARM/IWRAM | 4 | 5 |
| nop / ldrh r2, [sp] / nop Thumb/ROM ... | 7 | 13 |
| nop / ldrh r2, [sp] / nop Thumb/ROM P.. | 7 | 9 |
| nop / ldrh r2, [sp] / nop Thumb/ROM .N. | 7 | 12 |
| nop / ldrh r2, [sp] / nop Thumb/ROM PN. | 7 | 9 |
| nop / ldrh r2, [sp] / nop Thumb/ROM ..S | 7 | 11 |
| nop / ldrh r2, [sp] / nop Thumb/ROM P.S | 7 | 6 |
| nop / ldrh r2, [sp] / nop Thumb/ROM .NS | 7 | 10 |
| nop / ldrh r2, [sp] / nop Thumb/ROM PNS | 7 | 6 |
| nop / ldrh r2, [sp] / nop Thumb/WRAM | 10 | 11 |
| nop / ldrh r2, [sp] / nop Thumb/IWRAM | 4 | 5 |
| ldrh r2, [#0x08000000] ARM/ROM ... | 6 | 14 |
| ldrh r2, [#0x08000000] ARM/ROM P.. | 6 | 14 |
| ldrh r2, [#0x08000000] ARM/ROM .N. | 6 | 12 |
| ldrh r2, [#0x08000000] ARM/ROM PN. | 6 | 12 |
| ldrh r2, [#0x08000000] ARM/ROM ..S | 6 | 13 |
| ldrh r2, [#0x08000000] ARM/ROM P.S | 6 | 13 |
| ldrh r2, [#0x08000000] ARM/ROM .NS | 6 | 11 |
| ldrh r2, [#0x08000000] ARM/ROM PNS | 6 | 11 |
| ldrh r2, [#0x08000000] ARM/WRAM | 8 | 12 |
| ldrh r2, [#0x08000000] ARM/IWRAM | 3 | 7 |
| ldrh r2, [#0x08000000] Thumb/ROM ... | 4 | 11 |
| ldrh r2, [#0x08000000] Thumb/ROM P.. | 4 | 11 |
| ldrh r2, [#0x08000000] Thumb/ROM .N. | 4 | 9 |
| ldrh r2, [#0x08000000] Thumb/ROM PN. | 4 | 9 |
| ldrh r2, [#0x08000000] Thumb/ROM ..S | 4 | 11 |
| ldrh r2, [#0x08000000] Thumb/ROM P.S | 4 | 11 |
| ldrh r2, [#0x08000000] Thumb/ROM .NS | 4 | 9 |
| ldrh r2, [#0x08000000] Thumb/ROM PNS | 4 | 9 |
| ldrh r2, [#0x08000000] Thumb/WRAM | 5 | 9 |
| ldrh r2, [#0x08000000] Thumb/IWRAM | 3 | 7 |
| ldrh r2, [#0x08000000] / nop ARM/ROM ... | 10 | 20 |
| ldrh r2, [#0x08000000] / nop ARM/ROM P.. | 10 | 20 |
| ldrh r2, [#0x08000000] / nop ARM/ROM .N. | 10 | 18 |
| ldrh r2, [#0x08000000] / nop ARM/ROM PN. | 10 | 18 |
| ldrh r2, [#0x08000000] / nop ARM/ROM ..S | 10 | 17 |
| ldrh r2, [#0x08000000] / nop ARM/ROM P.S | 10 | 17 |
| ldrh r2, [#0x08000000] / nop ARM/ROM .NS | 10 | 15 |
| ldrh r2, [#0x08000000] / nop ARM/ROM PNS | 10 | 15 |
| ldrh r2, [#0x08000000] / nop ARM/WRAM | 14 | 18 |
| ldrh r2, [#0x08000000] / nop ARM/IWRAM | 4 | 8 |
| ldrh r2, [#0x08000000] / nop Thumb/ROM ... | 6 | 14 |
| ldrh r2, [#0x08000000] / nop Thumb/ROM P.. | 6 | 14 |
| ldrh r2, [#0x08000000] / nop Thumb/ROM .N. | 6 | 12 |
| ldrh r2, [#0x08000000] / nop Thumb/ROM PN. | 6 | 12 |
| ldrh r2, [#0x08000000] / nop Thumb/ROM ..S | 6 | 13 |
| ldrh r2, [#0x08000000] / nop Thumb/ROM P.S | 6 | 13 |
| ldrh r2, [#0x08000000] / nop Thumb/ROM .NS | 6 | 11 |
| ldrh r2, [#0x08000000] / nop Thumb/ROM PNS | 6 | 11 |
| ldrh r2, [#0x08000000] / nop Thumb/WRAM | 8 | 12 |
| ldrh r2, [#0x08000000] / nop Thumb/IWRAM | 4 | 8 |
| nop / ldrh r2, [#0x08000000] ARM/ROM ... | 10 | 20 |
| nop / ldrh r2, [#0x08000000] ARM/ROM P.. | 10 | 20 |
| nop / ldrh r2, [#0x08000000] ARM/ROM .N. | 10 | 18 |
| nop / ldrh r2, [#0x08000000] ARM/ROM PN. | 10 | 18 |
| nop / ldrh r2, [#0x08000000] ARM/ROM ..S | 10 | 17 |
| nop / ldrh r2, [#0x08000000] ARM/ROM P.S | 10 | 17 |
| nop / ldrh r2, [#0x08000000] ARM/ROM .NS | 10 | 15 |
| nop / ldrh r2, [#0x08000000] ARM/ROM PNS | 10 | 15 |
| nop / ldrh r2, [#0x08000000] ARM/WRAM | 14 | 18 |
| nop / ldrh r2, [#0x08000000] ARM/IWRAM | 4 | 8 |
| nop / ldrh r2, [#0x08000000] Thumb/ROM ... | 6 | 14 |
| nop / ldrh r2, [#0x08000000] Thumb/ROM P.. | 6 | 14 |
| nop / ldrh r2, [#0x08000000] Thumb/ROM .N. | 6 | 12 |
| nop / ldrh r2, [#0x08000000] Thumb/ROM PN. | 6 | 12 |
| nop / ldrh r2, [#0x08000000] Thumb/ROM ..S | 6 | 13 |
| nop / ldrh r2, [#0x08000000] Thumb/ROM P.S | 6 | 13 |
| nop / ldrh r2, [#0x08000000] Thumb/ROM .NS | 6 | 11 |
| nop / ldrh r2, [#0x08000000] Thumb/ROM PNS | 6 | 11 |
| nop / ldrh r2, [#0x08000000] Thumb/WRAM | 8 | 12 |
| nop / ldrh r2, [#0x08000000] Thumb/IWRAM | 4 | 8 |
| ldr r2, [sp] ARM/ROM ... | 5 | 10 |
| ldr r2, [sp] ARM/ROM P.. | 5 | 6 |
| ldr r2, [sp] ARM/ROM .N. | 5 | 9 |
| ldr r2, [sp] ARM/ROM PN. | 5 | 6 |
| ldr r2, [sp] ARM/ROM ..S | 5 | 9 |
| ldr r2, [sp] ARM/ROM P.S | 5 | 4 |
| ldr r2, [sp] ARM/ROM .NS | 5 | 8 |
| ldr r2, [sp] ARM/ROM PNS | 5 | 4 |
| ldr r2, [sp] ARM/WRAM | 7 | 8 |
| ldr r2, [sp] ARM/IWRAM | 2 | 3 |
| ldr r2, [sp] Thumb/ROM ... | 3 | 7 |
| ldr r2, [sp] Thumb/ROM .N. | 3 | 6 |
| ldr r2, [sp] Thumb/ROM ..S | 3 | 7 |
| ldr r2, [sp] Thumb/ROM .NS | 3 | 6 |
| ldr r2, [sp] Thumb/WRAM | 4 | 5 |
| ldr r2, [sp] Thumb/IWRAM | 2 | 3 |
| ldr r2, [sp] / nop ARM/ROM ... | 9 | 16 |
| ldr r2, [sp] / nop ARM/ROM P.. | 9 | 12 |
| ldr r2, [sp] / nop ARM/ROM .N. | 9 | 15 |
| ldr r2, [sp] / nop ARM/ROM PN. | 9 | 12 |
| ldr r2, [sp] / nop ARM/ROM ..S | 9 | 13 |
| ldr r2, [sp] / nop ARM/ROM P.S | 9 | 8 |
| ldr r2, [sp] / nop ARM/ROM .NS | 9 | 12 |
| ldr r2, [sp] / nop ARM/ROM PNS | 9 | 8 |
| ldr r2, [sp] / nop ARM/WRAM | 13 | 14 |
| ldr r2, [sp] / nop ARM/IWRAM | 3 | 4 |
| ldr r2, [sp] / nop Thumb/ROM ... | 5 | 10 |
| ldr r2, [sp] / nop Thumb/ROM P.. | 5 | 6 |
| ldr r2, [sp] / nop Thumb/ROM .N. | 5 | 9 |
| ldr r2, [sp] / nop Thumb/ROM PN. | 5 | 6 |
| ldr r2, [sp] / nop Thumb/ROM ..S | 5 | 9 |
| ldr r2, [sp] / nop Thumb/ROM P.S | 5 | 4 |
| ldr r2, [sp] / nop Thumb/ROM .NS | 5 | 8 |
| ldr r2, [sp] / nop Thumb/ROM PNS | 5 | 4 |
| ldr r2, [sp] / nop Thumb/WRAM | 7 | 8 |
| ldr r2, [sp] / nop Thumb/IWRAM | 3 | 4 |
| nop / ldr r2, [sp] ARM/ROM ... | 9 | 16 |
| nop / ldr r2, [sp] ARM/ROM P.. | 9 | 12 |
| nop / ldr r2, [sp] ARM/ROM .N. | 9 | 15 |
| nop / ldr r2, [sp] ARM/ROM PN. | 9 | 12 |
| nop / ldr r2, [sp] ARM/ROM ..S | 9 | 13 |
| nop / ldr r2, [sp] ARM/ROM P.S | 9 | 8 |
| nop / ldr r2, [sp] ARM/ROM .NS | 9 | 12 |
| nop / ldr r2, [sp] ARM/ROM PNS | 9 | 8 |
| nop / ldr r2, [sp] ARM/WRAM | 13 | 14 |
| nop / ldr r2, [sp] ARM/IWRAM | 3 | 4 |
| nop / ldr r2, [sp] Thumb/ROM ... | 5 | 10 |
| nop / ldr r2, [sp] Thumb/ROM P.. | 5 | 6 |
| nop / ldr r2, [sp] Thumb/ROM .N. | 5 | 9 |
| nop / ldr r2, [sp] Thumb/ROM PN. | 5 | 6 |
| nop / ldr r2, [sp] Thumb/ROM ..S | 5 | 9 |
| nop / ldr r2, [sp] Thumb/ROM .NS | 5 | 8 |
| nop / ldr r2, [sp] Thumb/WRAM | 7 | 8 |
| nop / ldr r2, [sp] Thumb/IWRAM | 3 | 4 |
| ldr r2, [#0x08000000] ARM/ROM ... | 8 | 17 |
| ldr r2, [#0x08000000] ARM/ROM P.. | 8 | 17 |
| ldr r2, [#0x08000000] ARM/ROM .N. | 8 | 15 |
| ldr r2, [#0x08000000] ARM/ROM PN. | 8 | 15 |
| ldr r2, [#0x08000000] ARM/ROM ..S | 8 | 15 |
| ldr r2, [#0x08000000] ARM/ROM P.S | 8 | 15 |
| ldr r2, [#0x08000000] ARM/ROM .NS | 8 | 13 |
| ldr r2, [#0x08000000] ARM/ROM PNS | 8 | 13 |
| ldr r2, [#0x08000000] ARM/WRAM | 10 | 15 |
| ldr r2, [#0x08000000] ARM/IWRAM | 5 | 10 |
| ldr r2, [#0x08000000] Thumb/ROM ... | 6 | 14 |
| ldr r2, [#0x08000000] Thumb/ROM P.. | 6 | 14 |
| ldr r2, [#0x08000000] Thumb/ROM .N. | 6 | 12 |
| ldr r2, [#0x08000000] Thumb/ROM PN. | 6 | 12 |
| ldr r2, [#0x08000000] Thumb/ROM ..S | 6 | 13 |
| ldr r2, [#0x08000000] Thumb/ROM P.S | 6 | 13 |
| ldr r2, [#0x08000000] Thumb/ROM .NS | 6 | 11 |
| ldr r2, [#0x08000000] Thumb/ROM PNS | 6 | 11 |
| ldr r2, [#0x08000000] Thumb/WRAM | 7 | 12 |
| ldr r2, [#0x08000000] Thumb/IWRAM | 5 | 10 |
| ldr r2, [#0x08000000] / nop ARM/ROM ... | 12 | 23 |
| ldr r2, [#0x08000000] / nop ARM/ROM P.. | 12 | 23 |
| ldr r2, [#0x08000000] / nop ARM/ROM .N. | 12 | 21 |
| ldr r2, [#0x08000000] / nop ARM/ROM PN. | 12 | 21 |
| ldr r2, [#0x08000000] / nop ARM/ROM ..S | 12 | 19 |
| ldr r2, [#0x08000000] / nop ARM/ROM P.S | 12 | 19 |
| ldr r2, [#0x08000000] / nop ARM/ROM .NS | 12 | 17 |
| ldr r2, [#0x08000000] / nop ARM/ROM PNS | 12 | 17 |
| ldr r2, [#0x08000000] / nop ARM/WRAM | 16 | 21 |
| ldr r2, [#0x08000000] / nop ARM/IWRAM | 6 | 11 |
| ldr r2, [#0x08000000] / nop Thumb/ROM ... | 8 | 17 |
| ldr r2, [#0x08000000] / nop Thumb/ROM P.. | 8 | 17 |
| ldr r2, [#0x08000000] / nop Thumb/ROM .N. | 8 | 15 |
| ldr r2, [#0x08000000] / nop Thumb/ROM PN. | 8 | 15 |
| ldr r2, [#0x08000000] / nop Thumb/ROM ..S | 8 | 15 |
| ldr r2, [#0x08000000] / nop Thumb/ROM P.S | 8 | 15 |
| ldr r2, [#0x08000000] / nop Thumb/ROM .NS | 8 | 13 |
| ldr r2, [#0x08000000] / nop Thumb/ROM PNS | 8 | 13 |
| ldr r2, [#0x08000000] / nop Thumb/WRAM | 10 | 15 |
| ldr r2, [#0x08000000] / nop Thumb/IWRAM | 6 | 11 |
| nop / ldr r2, [#0x08000000] ARM/ROM ... | 12 | 23 |
| nop / ldr r2, [#0x08000000] ARM/ROM P.. | 12 | 23 |
| nop / ldr r2, [#0x08000000] ARM/ROM .N. | 12 | 21 |
| nop / ldr r2, [#0x08000000] ARM/ROM PN. | 12 | 21 |
| nop / ldr r2, [#0x08000000] ARM/ROM ..S | 12 | 19 |
| nop / ldr r2, [#0x08000000] ARM/ROM P.S | 12 | 19 |
| nop / ldr r2, [#0x08000000] ARM/ROM .NS | 12 | 17 |
| nop / ldr r2, [#0x08000000] ARM/ROM PNS | 12 | 17 |
| nop / ldr r2, [#0x08000000] ARM/WRAM | 16 | 21 |
| nop / ldr r2, [#0x08000000] ARM/IWRAM | 6 | 11 |
| nop / ldr r2, [#0x08000000] Thumb/ROM ... | 8 | 17 |
| nop / ldr r2, [#0x08000000] Thumb/ROM P.. | 8 | 17 |
| nop / ldr r2, [#0x08000000] Thumb/ROM .N. | 8 | 15 |
| nop / ldr r2, [#0x08000000] Thumb/ROM PN. | 8 | 15 |
| nop / ldr r2, [#0x08000000] Thumb/ROM ..S | 8 | 15 |
| nop / ldr r2, [#0x08000000] Thumb/ROM P.S | 8 | 15 |
| nop / ldr r2, [#0x08000000] Thumb/ROM .NS | 8 | 13 |
| nop / ldr r2, [#0x08000000] Thumb/ROM PNS | 8 | 13 |
| nop / ldr r2, [#0x08000000] Thumb/WRAM | 10 | 15 |
| nop / ldr r2, [#0x08000000] Thumb/IWRAM | 6 | 11 |
| strh r3, [sp] ARM/ROM ... | 5 | 9 |
| strh r3, [sp] ARM/ROM P.. | 5 | 6 |
| strh r3, [sp] ARM/ROM .N. | 5 | 8 |
| strh r3, [sp] ARM/ROM PN. | 5 | 6 |
| strh r3, [sp] ARM/ROM ..S | 5 | 8 |
| strh r3, [sp] ARM/ROM P.S | 5 | 4 |
| strh r3, [sp] ARM/ROM .NS | 5 | 7 |
| strh r3, [sp] ARM/ROM PNS | 5 | 4 |
| strh r3, [sp] Thumb/ROM ... | 3 | 6 |
| strh r3, [sp] Thumb/ROM .N. | 3 | 5 |
| strh r3, [sp] Thumb/ROM ..S | 3 | 6 |
| strh r3, [sp] Thumb/ROM P.S | 3 | 2 |
| strh r3, [sp] Thumb/ROM .NS | 3 | 5 |
| strh r3, [sp] Thumb/ROM PNS | 3 | 2 |
| strh r3, [sp] / nop ARM/ROM ... | 9 | 15 |
| strh r3, [sp] / nop ARM/ROM P.. | 9 | 12 |
| strh r3, [sp] / nop ARM/ROM .N. | 9 | 14 |
| strh r3, [sp] / nop ARM/ROM PN. | 9 | 12 |
| strh r3, [sp] / nop ARM/ROM ..S | 9 | 12 |
| strh r3, [sp] / nop ARM/ROM P.S | 9 | 8 |
| strh r3, [sp] / nop ARM/ROM .NS | 9 | 11 |
| strh r3, [sp] / nop ARM/ROM PNS | 9 | 8 |
| strh r3, [sp] / nop Thumb/ROM ... | 5 | 9 |
| strh r3, [sp] / nop Thumb/ROM P.. | 5 | 6 |
| strh r3, [sp] / nop Thumb/ROM .N. | 5 | 8 |
| strh r3, [sp] / nop Thumb/ROM PN. | 5 | 6 |
| strh r3, [sp] / nop Thumb/ROM ..S | 5 | 8 |
| strh r3, [sp] / nop Thumb/ROM P.S | 5 | 4 |
| strh r3, [sp] / nop Thumb/ROM .NS | 5 | 7 |
| strh r3, [sp] / nop Thumb/ROM PNS | 5 | 4 |
| nop / strh r3, [sp] ARM/ROM ... | 9 | 15 |
| nop / strh r3, [sp] ARM/ROM P.. | 9 | 12 |
| nop / strh r3, [sp] ARM/ROM .N. | 9 | 14 |
| nop / strh r3, [sp] ARM/ROM PN. | 9 | 12 |
| nop / strh r3, [sp] ARM/ROM ..S | 9 | 12 |
| nop / strh r3, [sp] ARM/ROM P.S | 9 | 8 |
| nop / strh r3, [sp] ARM/ROM .NS | 9 | 11 |
| nop / strh r3, [sp] ARM/ROM PNS | 9 | 8 |
| nop / strh r3, [sp] Thumb/ROM ... | 5 | 9 |
| nop / strh r3, [sp] Thumb/ROM P.. | 5 | 6 |
| nop / strh r3, [sp] Thumb/ROM .N. | 5 | 8 |
| nop / strh r3, [sp] Thumb/ROM PN. | 5 | 6 |
| nop / strh r3, [sp] Thumb/ROM ..S | 5 | 8 |
| nop / strh r3, [sp] Thumb/ROM P.S | 5 | 4 |
| nop / strh r3, [sp] Thumb/ROM .NS | 5 | 7 |
| nop / strh r3, [sp] Thumb/ROM PNS | 5 | 4 |
| nop / strh r3, [sp] / nop ARM/ROM ... | 13 | 21 |
| nop / strh r3, [sp] / nop ARM/ROM P.. | 13 | 18 |
| nop / strh r3, [sp] / nop ARM/ROM .N. | 13 | 20 |
| nop / strh r3, [sp] / nop ARM/ROM PN. | 13 | 18 |
| nop / strh r3, [sp] / nop ARM/ROM ..S | 13 | 16 |
| nop / strh r3, [sp] / nop ARM/ROM P.S | 13 | 12 |
| nop / strh r3, [sp] / nop ARM/ROM .NS | 13 | 15 |
| nop / strh r3, [sp] / nop ARM/ROM PNS | 13 | 12 |
| nop / strh r3, [sp] / nop Thumb/ROM ... | 7 | 12 |
| nop / strh r3, [sp] / nop Thumb/ROM P.. | 7 | 9 |
| nop / strh r3, [sp] / nop Thumb/ROM .N. | 7 | 11 |
| nop / strh r3, [sp] / nop Thumb/ROM PN. | 7 | 9 |
| nop / strh r3, [sp] / nop Thumb/ROM ..S | 7 | 10 |
| nop / strh r3, [sp] / nop Thumb/ROM P.S | 7 | 6 |
| nop / strh r3, [sp] / nop Thumb/ROM .NS | 7 | 9 |
| nop / strh r3, [sp] / nop Thumb/ROM PNS | 7 | 6 |
| ldr r2, [sp] x2 ARM/ROM ... | 10 | 20 |
| ldr r2, [sp] x2 ARM/ROM P.. | 10 | 12 |
| ldr r2, [sp] x2 ARM/ROM .N. | 10 | 18 |
| ldr r2, [sp] x2 ARM/ROM PN. | 10 | 12 |
| ldr r2, [sp] x2 ARM/ROM ..S | 10 | 18 |
| ldr r2, [sp] x2 ARM/ROM P.S | 10 | 8 |
| ldr r2, [sp] x2 ARM/ROM .NS | 10 | 16 |
| ldr r2, [sp] x2 ARM/ROM PNS | 10 | 8 |
| ldr r2, [sp] x2 ARM/WRAM | 14 | 16 |
| ldr r2, [sp] x2 ARM/IWRAM | 4 | 6 |
| ldr r2, [sp] x2 Thumb/ROM ... | 6 | 14 |
| ldr r2, [sp] x2 Thumb/ROM .N. | 6 | 12 |
| ldr r2, [sp] x2 Thumb/ROM ..S | 6 | 14 |
| ldr r2, [sp] x2 Thumb/ROM .NS | 6 | 12 |
| ldr r2, [sp] x2 Thumb/WRAM | 8 | 10 |
| ldr r2, [sp] x2 Thumb/IWRAM | 4 | 6 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/ROM ... | 13 | 27 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/ROM P.. | 13 | 23 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/ROM .N. | 13 | 24 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/ROM PN. | 13 | 21 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/ROM ..S | 13 | 24 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/ROM P.S | 13 | 19 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/ROM .NS | 13 | 21 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/ROM PNS | 13 | 17 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/WRAM | 17 | 23 |
| ldr r2, [#0x08000000] / ldr r2, [sp] ARM/IWRAM | 7 | 13 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/ROM ... | 9 | 21 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/ROM P.. | 9 | 17 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/ROM .N. | 9 | 18 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/ROM PN. | 9 | 15 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/ROM ..S | 9 | 20 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/ROM P.S | 9 | 16 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/ROM .NS | 9 | 17 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/ROM PNS | 9 | 14 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/WRAM | 11 | 17 |
| ldr r2, [#0x08000000] / ldr r2, [sp] Thumb/IWRAM | 7 | 13 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/ROM ... | 13 | 27 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/ROM P.. | 13 | 23 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/ROM .N. | 13 | 24 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/ROM PN. | 13 | 21 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/ROM ..S | 13 | 24 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/ROM P.S | 13 | 19 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/ROM .NS | 13 | 21 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/ROM PNS | 13 | 17 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/WRAM | 17 | 23 |
| ldr r2, [sp] / ldr r2, [#0x08000000] ARM/IWRAM | 7 | 13 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM ... | 9 | 21 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM P.. | 9 | 17 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM .N. | 9 | 18 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM PN. | 9 | 15 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM ..S | 9 | 20 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM P.S | 9 | 17 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM .NS | 9 | 17 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/ROM PNS | 9 | 15 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/WRAM | 11 | 17 |
| ldr r2, [sp] / ldr r2, [#0x08000000] Thumb/IWRAM | 7 | 13 |
| ldr r2, [#0x08000000] x2 ARM/ROM ... | 16 | 34 |
| ldr r2, [#0x08000000] x2 ARM/ROM P.. | 16 | 34 |
| ldr r2, [#0x08000000] x2 ARM/ROM .N. | 16 | 30 |
| ldr r2, [#0x08000000] x2 ARM/ROM PN. | 16 | 30 |
| ldr r2, [#0x08000000] x2 ARM/ROM ..S | 16 | 30 |
| ldr r2, [#0x08000000] x2 ARM/ROM P.S | 16 | 30 |
| ldr r2, [#0x08000000] x2 ARM/ROM .NS | 16 | 26 |
| ldr r2, [#0x08000000] x2 ARM/ROM PNS | 16 | 26 |
| ldr r2, [#0x08000000] x2 ARM/WRAM | 20 | 30 |
| ldr r2, [#0x08000000] x2 ARM/IWRAM | 10 | 20 |
| ldr r2, [#0x08000000] x2 Thumb/ROM ... | 12 | 28 |
| ldr r2, [#0x08000000] x2 Thumb/ROM P.. | 12 | 28 |
| ldr r2, [#0x08000000] x2 Thumb/ROM .N. | 12 | 24 |
| ldr r2, [#0x08000000] x2 Thumb/ROM PN. | 12 | 24 |
| ldr r2, [#0x08000000] x2 Thumb/ROM ..S | 12 | 26 |
| ldr r2, [#0x08000000] x2 Thumb/ROM P.S | 12 | 26 |
| ldr r2, [#0x08000000] x2 Thumb/ROM .NS | 12 | 22 |
| ldr r2, [#0x08000000] x2 Thumb/ROM PNS | 12 | 22 |
| ldr r2, [#0x08000000] x2 Thumb/WRAM | 14 | 24 |
| ldr r2, [#0x08000000] x2 Thumb/IWRAM | 10 | 20 |
| str r3, [sp] x2 ARM/ROM ... | 10 | 18 |
| str r3, [sp] x2 ARM/ROM P.. | 10 | 12 |
| str r3, [sp] x2 ARM/ROM .N. | 10 | 16 |
| str r3, [sp] x2 ARM/ROM PN. | 10 | 12 |
| str r3, [sp] x2 ARM/ROM ..S | 10 | 16 |
| str r3, [sp] x2 ARM/ROM P.S | 10 | 8 |
| str r3, [sp] x2 ARM/ROM .NS | 10 | 14 |
| str r3, [sp] x2 ARM/ROM PNS | 10 | 8 |
| str r3, [sp] x2 Thumb/ROM ... | 6 | 12 |
| str r3, [sp] x2 Thumb/ROM .N. | 6 | 10 |
| str r3, [sp] x2 Thumb/ROM ..S | 6 | 12 |
| str r3, [sp] x2 Thumb/ROM P.S | 6 | 4 |
| str r3, [sp] x2 Thumb/ROM .NS | 6 | 10 |
| str r3, [sp] x2 Thumb/ROM PNS | 6 | 4 |
| ldr r2, [sp] / str r2, [sp] ARM/ROM ... | 10 | 19 |
| ldr r2, [sp] / str r2, [sp] ARM/ROM P.. | 10 | 12 |
| ldr r2, [sp] / str r2, [sp] ARM/ROM .N. | 10 | 17 |
| ldr r2, [sp] / str r2, [sp] ARM/ROM PN. | 10 | 12 |
| ldr r2, [sp] / str r2, [sp] ARM/ROM ..S | 10 | 17 |
| ldr r2, [sp] / str r2, [sp] ARM/ROM P.S | 10 | 8 |
| ldr r2, [sp] / str r2, [sp] ARM/ROM .NS | 10 | 15 |
| ldr r2, [sp] / str r2, [sp] ARM/ROM PNS | 10 | 8 |
| ldr r2, [sp] / str r2, [sp] ARM/WRAM | 14 | 15 |
| ldr r2, [sp] / str r2, [sp] ARM/IWRAM | 4 | 5 |
| ldr r2, [sp] / str r2, [sp] Thumb/ROM ... | 6 | 13 |
| ldr r2, [sp] / str r2, [sp] Thumb/ROM .N. | 6 | 11 |
| ldr r2, [sp] / str r2, [sp] Thumb/ROM ..S | 6 | 13 |
| ldr r2, [sp] / str r2, [sp] Thumb/ROM P.S | 6 | 5 |
| ldr r2, [sp] / str r2, [sp] Thumb/ROM .NS | 6 | 11 |
| ldr r2, [sp] / str r2, [sp] Thumb/ROM PNS | 6 | 5 |
| ldr r2, [sp] / str r2, [sp] Thumb/WRAM | 8 | 9 |
| ldr r2, [sp] / str r2, [sp] Thumb/IWRAM | 4 | 5 |
| str r3, [sp] / ldr r3, [sp] ARM/ROM ... | 10 | 19 |
| str r3, [sp] / ldr r3, [sp] ARM/ROM P.. | 10 | 12 |
| str r3, [sp] / ldr r3, [sp] ARM/ROM .N. | 10 | 17 |
| str r3, [sp] / ldr r3, [sp] ARM/ROM PN. | 10 | 12 |
| str r3, [sp] / ldr r3, [sp] ARM/ROM ..S | 10 | 17 |
| str r3, [sp] / ldr r3, [sp] ARM/ROM P.S | 10 | 8 |
| str r3, [sp] / ldr r3, [sp] ARM/ROM .NS | 10 | 15 |
| str r3, [sp] / ldr r3, [sp] ARM/ROM PNS | 10 | 8 |
| str r3, [sp] / ldr r3, [sp] ARM/WRAM | 14 | 15 |
| str r3, [sp] / ldr r3, [sp] ARM/IWRAM | 4 | 5 |
| str r3, [sp] / ldr r3, [sp] Thumb/ROM ... | 6 | 13 |
| str r3, [sp] / ldr r3, [sp] Thumb/ROM .N. | 6 | 11 |
| str r3, [sp] / ldr r3, [sp] Thumb/ROM ..S | 6 | 13 |
| str r3, [sp] / ldr r3, [sp] Thumb/ROM P.S | 6 | 5 |
| str r3, [sp] / ldr r3, [sp] Thumb/ROM .NS | 6 | 11 |
| str r3, [sp] / ldr r3, [sp] Thumb/ROM PNS | 6 | 5 |
| str r3, [sp] / ldr r3, [sp] Thumb/WRAM | 8 | 9 |
| str r3, [sp] / ldr r3, [sp] Thumb/IWRAM | 4 | 5 |
| ldmia sp, {r2} ARM/ROM ... | 5 | 10 |
| ldmia sp, {r2} ARM/ROM P.. | 5 | 6 |
| ldmia sp, {r2} ARM/ROM .N. | 5 | 9 |
| ldmia sp, {r2} ARM/ROM PN. | 5 | 6 |
| ldmia sp, {r2} ARM/ROM ..S | 5 | 9 |
| ldmia sp, {r2} ARM/ROM P.S | 5 | 4 |
| ldmia sp, {r2} ARM/ROM .NS | 5 | 8 |
| ldmia sp, {r2} ARM/ROM PNS | 5 | 4 |
| ldmia sp, {r2} ARM/WRAM | 7 | 8 |
| ldmia sp, {r2} ARM/IWRAM | 2 | 3 |
| ldmia sp, {r2, r3} ARM/ROM ... | 6 | 11 |
| ldmia sp, {r2, r3} ARM/ROM .N. | 6 | 10 |
| ldmia sp, {r2, r3} ARM/ROM ..S | 6 | 10 |
| ldmia sp, {r2, r3} ARM/ROM P.S | 6 | 4 |
| ldmia sp, {r2, r3} ARM/ROM .NS | 6 | 9 |
| ldmia sp, {r2, r3} ARM/ROM PNS | 6 | 4 |
| ldmia sp, {r2, r3} ARM/WRAM | 8 | 9 |
| ldmia sp, {r2, r3} ARM/IWRAM | 3 | 4 |
| ldmia sp, {r2-r7} ARM/ROM ... | 10 | 15 |
| ldmia sp, {r2-r7} ARM/ROM P.. | 10 | 8 |
| ldmia sp, {r2-r7} ARM/ROM .N. | 10 | 14 |
| ldmia sp, {r2-r7} ARM/ROM PN. | 10 | 8 |
| ldmia sp, {r2-r7} ARM/ROM ..S | 10 | 14 |
| ldmia sp, {r2-r7} ARM/ROM P.S | 10 | 8 |
| ldmia sp, {r2-r7} ARM/ROM .NS | 10 | 13 |
| ldmia sp, {r2-r7} ARM/ROM PNS | 10 | 8 |
| ldmia sp, {r2-r7} ARM/WRAM | 12 | 13 |
| ldmia sp, {r2-r7} ARM/IWRAM | 7 | 8 |
| ldmia sp, {r2} x2 ARM/ROM ... | 10 | 20 |
| ldmia sp, {r2} x2 ARM/ROM P.. | 10 | 12 |
| ldmia sp, {r2} x2 ARM/ROM .N. | 10 | 18 |
| ldmia sp, {r2} x2 ARM/ROM PN. | 10 | 12 |
| ldmia sp, {r2} x2 ARM/ROM ..S | 10 | 18 |
| ldmia sp, {r2} x2 ARM/ROM P.S | 10 | 8 |
| ldmia sp, {r2} x2 ARM/ROM .NS | 10 | 16 |
| ldmia sp, {r2} x2 ARM/ROM PNS | 10 | 8 |
| ldmia sp, {r2} x2 ARM/WRAM | 14 | 16 |
| ldmia sp, {r2} x2 ARM/IWRAM | 4 | 6 |
| ldmia sp, {r2, r3} x2 ARM/ROM ... | 12 | 22 |
| ldmia sp, {r2, r3} x2 ARM/ROM .N. | 12 | 20 |
| ldmia sp, {r2, r3} x2 ARM/ROM ..S | 12 | 20 |
| ldmia sp, {r2, r3} x2 ARM/ROM P.S | 12 | 8 |
| ldmia sp, {r2, r3} x2 ARM/ROM .NS | 12 | 18 |
| ldmia sp, {r2, r3} x2 ARM/ROM PNS | 12 | 8 |
| ldmia sp, {r2, r3} x2 ARM/WRAM | 16 | 18 |
| ldmia sp, {r2, r3} x2 ARM/IWRAM | 6 | 8 |
| ldmia sp, {r2-r7} x2 ARM/ROM ... | 20 | 30 |
| ldmia sp, {r2-r7} x2 ARM/ROM P.. | 20 | 16 |
| ldmia sp, {r2-r7} x2 ARM/ROM .N. | 20 | 28 |
| ldmia sp, {r2-r7} x2 ARM/ROM PN. | 20 | 16 |
| ldmia sp, {r2-r7} x2 ARM/ROM ..S | 20 | 28 |
| ldmia sp, {r2-r7} x2 ARM/ROM P.S | 20 | 16 |
| ldmia sp, {r2-r7} x2 ARM/ROM .NS | 20 | 26 |
| ldmia sp, {r2-r7} x2 ARM/ROM PNS | 20 | 16 |
| ldmia sp, {r2-r7} x2 ARM/WRAM | 24 | 26 |
| ldmia sp, {r2-r7} x2 ARM/IWRAM | 14 | 16 |
| stmia sp, {r2} ARM/ROM ... | 5 | 9 |
| stmia sp, {r2} ARM/ROM P.. | 5 | 6 |
| stmia sp, {r2} ARM/ROM .N. | 5 | 8 |
| stmia sp, {r2} ARM/ROM PN. | 5 | 6 |
| stmia sp, {r2} ARM/ROM ..S | 5 | 8 |
| stmia sp, {r2} ARM/ROM P.S | 5 | 4 |
| stmia sp, {r2} ARM/ROM .NS | 5 | 7 |
| stmia sp, {r2} ARM/ROM PNS | 5 | 4 |
| stmia sp, {r2, r3} ARM/ROM ... | 6 | 10 |
| stmia sp, {r2, r3} ARM/ROM .N. | 6 | 9 |
| stmia sp, {r2, r3} ARM/ROM ..S | 6 | 9 |
| stmia sp, {r2, r3} ARM/ROM P.S | 6 | 4 |
| stmia sp, {r2, r3} ARM/ROM .NS | 6 | 8 |
| stmia sp, {r2, r3} ARM/ROM PNS | 6 | 4 |
| stmia sp, {r2-r7} ARM/ROM ... | 10 | 14 |
| stmia sp, {r2-r7} ARM/ROM P.. | 10 | 7 |
| stmia sp, {r2-r7} ARM/ROM .N. | 10 | 13 |
| stmia sp, {r2-r7} ARM/ROM PN. | 10 | 7 |
| stmia sp, {r2-r7} ARM/ROM ..S | 10 | 13 |
| stmia sp, {r2-r7} ARM/ROM P.S | 10 | 7 |
| stmia sp, {r2-r7} ARM/ROM .NS | 10 | 12 |
| stmia sp, {r2-r7} ARM/ROM PNS | 10 | 7 |
| stmia sp, {r2} x2 ARM/ROM ... | 10 | 18 |
| stmia sp, {r2} x2 ARM/ROM P.. | 10 | 12 |
| stmia sp, {r2} x2 ARM/ROM .N. | 10 | 16 |
| stmia sp, {r2} x2 ARM/ROM PN. | 10 | 12 |
| stmia sp, {r2} x2 ARM/ROM ..S | 10 | 16 |
| stmia sp, {r2} x2 ARM/ROM P.S | 10 | 8 |
| stmia sp, {r2} x2 ARM/ROM .NS | 10 | 14 |
| stmia sp, {r2} x2 ARM/ROM PNS | 10 | 8 |
| stmia sp, {r2, r3} x2 ARM/ROM ... | 12 | 20 |
| stmia sp, {r2, r3} x2 ARM/ROM .N. | 12 | 18 |
| stmia sp, {r2, r3} x2 ARM/ROM ..S | 12 | 18 |
| stmia sp, {r2, r3} x2 ARM/ROM P.S | 12 | 8 |
| stmia sp, {r2, r3} x2 ARM/ROM .NS | 12 | 16 |
| stmia sp, {r2, r3} x2 ARM/ROM PNS | 12 | 8 |
| stmia sp, {r2-r7} x2 ARM/ROM ... | 20 | 28 |
| stmia sp, {r2-r7} x2 ARM/ROM P.. | 20 | 14 |
| stmia sp, {r2-r7} x2 ARM/ROM .N. | 20 | 26 |
| stmia sp, {r2-r7} x2 ARM/ROM PN. | 20 | 14 |
| stmia sp, {r2-r7} x2 ARM/ROM ..S | 20 | 26 |
| stmia sp, {r2-r7} x2 ARM/ROM P.S | 20 | 14 |
| stmia sp, {r2-r7} x2 ARM/ROM .NS | 20 | 24 |
| stmia sp, {r2-r7} x2 ARM/ROM PNS | 20 | 14 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM ... | 21 | 36 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM P.. | 21 | 36 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM .N. | 21 | 34 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM PN. | 21 | 34 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM ..S | 21 | 28 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM P.S | 21 | 29 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM .NS | 21 | 26 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/ROM PNS | 21 | 27 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/WRAM | 23 | 34 |
| ldmia [#0x07FFFFFC]!, {r3-r7} ARM/IWRAM | 18 | 29 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM ... | 19 | 33 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM P.. | 19 | 33 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM .N. | 19 | 31 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM PN. | 19 | 31 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM ..S | 19 | 26 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM P.S | 19 | 27 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM .NS | 19 | 24 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/ROM PNS | 19 | 25 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/WRAM | 20 | 31 |
| ldmia [#0x07FFFFFC]!, {r3-r7} Thumb/IWRAM | 18 | 29 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM ... | 18 | 31 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM P.. | 18 | 32 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM .N. | 18 | 29 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM PN. | 18 | 30 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM ..S | 18 | 25 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM P.S | 18 | 25 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM .NS | 18 | 23 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/ROM PNS | 18 | 23 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/WRAM | 20 | 29 |
| ldmia [#0x07FFFFF8]!, {r3-r7} ARM/IWRAM | 15 | 24 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM ... | 16 | 28 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM P.. | 16 | 29 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM .N. | 16 | 26 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM PN. | 16 | 27 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM ..S | 16 | 23 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM P.S | 16 | 23 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM .NS | 16 | 21 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/ROM PNS | 16 | 21 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/WRAM | 17 | 26 |
| ldmia [#0x07FFFFF8]!, {r3-r7} Thumb/IWRAM | 15 | 24 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM ... | 15 | 26 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM P.. | 15 | 26 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM .N. | 15 | 24 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM PN. | 15 | 24 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM ..S | 15 | 22 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM P.S | 15 | 23 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM .NS | 15 | 20 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/ROM PNS | 15 | 21 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/WRAM | 17 | 24 |
| ldmia [#0x07FFFFF4]!, {r3-r7} ARM/IWRAM | 12 | 19 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM ... | 13 | 23 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM P.. | 13 | 23 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM .N. | 13 | 21 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM PN. | 13 | 21 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM ..S | 13 | 20 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM P.S | 13 | 21 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM .NS | 13 | 18 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/ROM PNS | 13 | 19 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/WRAM | 14 | 21 |
| ldmia [#0x07FFFFF4]!, {r3-r7} Thumb/IWRAM | 12 | 19 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/ROM ... | 12 | 21 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/ROM P.. | 12 | 21 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/ROM .N. | 12 | 19 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/ROM PN. | 12 | 19 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/ROM ..S | 12 | 19 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/ROM P.S | 12 | 19 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/ROM .NS | 12 | 17 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/ROM PNS | 12 | 17 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/WRAM | 14 | 19 |
| ldmia [#0x07FFFFF0]!, {r3-r7} ARM/IWRAM | 9 | 14 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/ROM ... | 10 | 18 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/ROM P.. | 10 | 18 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/ROM .N. | 10 | 16 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/ROM PN. | 10 | 16 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/ROM ..S | 10 | 17 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/ROM P.S | 10 | 17 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/ROM .NS | 10 | 15 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/ROM PNS | 10 | 15 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/WRAM | 11 | 16 |
| ldmia [#0x07FFFFF0]!, {r3-r7} Thumb/IWRAM | 9 | 14 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/ROM ... | 9 | 14 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/ROM P.. | 9 | 7 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/ROM .N. | 9 | 13 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/ROM PN. | 9 | 7 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/ROM ..S | 9 | 13 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/ROM P.S | 9 | 7 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/ROM .NS | 9 | 12 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/ROM PNS | 9 | 7 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/WRAM | 11 | 12 |
| ldmia [#0x07FFFFEC]!, {r3-r7} ARM/IWRAM | 6 | 7 |
| ldmia [#0x07FFFFEC]!, {r3-r7} Thumb/ROM ... | 7 | 11 |
| ldmia [#0x07FFFFEC]!, {r3-r7} Thumb/ROM .N. | 7 | 10 |
| ldmia [#0x07FFFFEC]!, {r3-r7} Thumb/ROM ..S | 7 | 11 |
| ldmia [#0x07FFFFEC]!, {r3-r7} Thumb/ROM .NS | 7 | 10 |
| ldmia [#0x07FFFFEC]!, {r3-r7} Thumb/WRAM | 8 | 9 |
| ldmia [#0x07FFFFEC]!, {r3-r7} Thumb/IWRAM | 6 | 7 |
| mul #0x00000000, #0xFF ARM/ROM ... | 4 | 9 |
| mul #0x00000000, #0xFF ARM/ROM P.. | 4 | 6 |
| mul #0x00000000, #0xFF ARM/ROM .N. | 4 | 8 |
| mul #0x00000000, #0xFF ARM/ROM PN. | 4 | 6 |
| mul #0x00000000, #0xFF ARM/ROM ..S | 4 | 8 |
| mul #0x00000000, #0xFF ARM/ROM .NS | 4 | 7 |
| mul #0x00000000, #0xFF ARM/WRAM | 6 | 7 |
| mul #0x00000000, #0xFF ARM/IWRAM | 1 | 2 |
| mul #0x00000000, #0xFF Thumb/ROM ... | 2 | 6 |
| mul #0x00000000, #0xFF Thumb/ROM P.. | 2 | 3 |
| mul #0x00000000, #0xFF Thumb/ROM .N. | 2 | 5 |
| mul #0x00000000, #0xFF Thumb/ROM PN. | 2 | 3 |
| mul #0x00000000, #0xFF Thumb/ROM ..S | 2 | 6 |
| mul #0x00000000, #0xFF Thumb/ROM .NS | 2 | 5 |
| mul #0x00000000, #0xFF Thumb/WRAM | 3 | 4 |
| mul #0x00000000, #0xFF Thumb/IWRAM | 1 | 2 |
| mul #0x00000078, #0xFF ARM/ROM ... | 4 | 9 |
| mul #0x00000078, #0xFF ARM/ROM P.. | 4 | 6 |
| mul #0x00000078, #0xFF ARM/ROM .N. | 4 | 8 |
| mul #0x00000078, #0xFF ARM/ROM PN. | 4 | 6 |
| mul #0x00000078, #0xFF ARM/ROM ..S | 4 | 8 |
| mul #0x00000078, #0xFF ARM/ROM .NS | 4 | 7 |
| mul #0x00000078, #0xFF ARM/WRAM | 6 | 7 |
| mul #0x00000078, #0xFF ARM/IWRAM | 1 | 2 |
| mul #0x00000078, #0xFF Thumb/ROM ... | 2 | 6 |
| mul #0x00000078, #0xFF Thumb/ROM P.. | 2 | 3 |
| mul #0x00000078, #0xFF Thumb/ROM .N. | 2 | 5 |
| mul #0x00000078, #0xFF Thumb/ROM PN. | 2 | 3 |
| mul #0x00000078, #0xFF Thumb/ROM ..S | 2 | 6 |
| mul #0x00000078, #0xFF Thumb/ROM .NS | 2 | 5 |
| mul #0x00000078, #0xFF Thumb/WRAM | 3 | 4 |
| mul #0x00000078, #0xFF Thumb/IWRAM | 1 | 2 |
| mul #0x00005678, #0xFF ARM/ROM ... | 4 | 10 |
| mul #0x00005678, #0xFF ARM/ROM P.. | 4 | 6 |
| mul #0x00005678, #0xFF ARM/ROM .N. | 4 | 9 |
| mul #0x00005678, #0xFF ARM/ROM PN. | 4 | 6 |
| mul #0x00005678, #0xFF ARM/ROM ..S | 4 | 9 |
| mul #0x00005678, #0xFF ARM/ROM .NS | 4 | 8 |
| mul #0x00005678, #0xFF ARM/WRAM | 6 | 8 |
| mul #0x00005678, #0xFF ARM/IWRAM | 1 | 3 |
| mul #0x00005678, #0xFF Thumb/ROM ... | 2 | 7 |
| mul #0x00005678, #0xFF Thumb/ROM P.. | 2 | 3 |
| mul #0x00005678, #0xFF Thumb/ROM .N. | 2 | 6 |
| mul #0x00005678, #0xFF Thumb/ROM PN. | 2 | 3 |
| mul #0x00005678, #0xFF Thumb/ROM ..S | 2 | 7 |
| mul #0x00005678, #0xFF Thumb/ROM P.S | 2 | 3 |
| mul #0x00005678, #0xFF Thumb/ROM .NS | 2 | 6 |
| mul #0x00005678, #0xFF Thumb/ROM PNS | 2 | 3 |
| mul #0x00005678, #0xFF Thumb/WRAM | 3 | 5 |
| mul #0x00005678, #0xFF Thumb/IWRAM | 1 | 3 |
| mul #0x00345678, #0xFF ARM/ROM ... | 4 | 11 |
| mul #0x00345678, #0xFF ARM/ROM P.. | 4 | 6 |
| mul #0x00345678, #0xFF ARM/ROM .N. | 4 | 10 |
| mul #0x00345678, #0xFF ARM/ROM PN. | 4 | 6 |
| mul #0x00345678, #0xFF ARM/ROM ..S | 4 | 10 |
| mul #0x00345678, #0xFF ARM/ROM .NS | 4 | 9 |
| mul #0x00345678, #0xFF ARM/WRAM | 6 | 9 |
| mul #0x00345678, #0xFF ARM/IWRAM | 1 | 4 |
| mul #0x00345678, #0xFF Thumb/ROM ... | 2 | 8 |
| mul #0x00345678, #0xFF Thumb/ROM P.. | 2 | 4 |
| mul #0x00345678, #0xFF Thumb/ROM .N. | 2 | 7 |
| mul #0x00345678, #0xFF Thumb/ROM PN. | 2 | 4 |
| mul #0x00345678, #0xFF Thumb/ROM ..S | 2 | 8 |
| mul #0x00345678, #0xFF Thumb/ROM P.S | 2 | 4 |
| mul #0x00345678, #0xFF Thumb/ROM .NS | 2 | 7 |
| mul #0x00345678, #0xFF Thumb/ROM PNS | 2 | 4 |
| mul #0x00345678, #0xFF Thumb/WRAM | 3 | 6 |
| mul #0x00345678, #0xFF Thumb/IWRAM | 1 | 4 |
| mul #0x12345678, #0xFF ARM/ROM ... | 4 | 12 |
| mul #0x12345678, #0xFF ARM/ROM P.. | 4 | 6 |
| mul #0x12345678, #0xFF ARM/ROM .N. | 4 | 11 |
| mul #0x12345678, #0xFF ARM/ROM PN. | 4 | 6 |
| mul #0x12345678, #0xFF ARM/ROM ..S | 4 | 11 |
| mul #0x12345678, #0xFF ARM/ROM P.S | 4 | 5 |
| mul #0x12345678, #0xFF ARM/ROM .NS | 4 | 10 |
| mul #0x12345678, #0xFF ARM/ROM PNS | 4 | 5 |
| mul #0x12345678, #0xFF ARM/WRAM | 6 | 10 |
| mul #0x12345678, #0xFF ARM/IWRAM | 1 | 5 |
| mul #0x12345678, #0xFF Thumb/ROM ... | 2 | 9 |
| mul #0x12345678, #0xFF Thumb/ROM P.. | 2 | 5 |
| mul #0x12345678, #0xFF Thumb/ROM .N. | 2 | 8 |
| mul #0x12345678, #0xFF Thumb/ROM PN. | 2 | 5 |
| mul #0x12345678, #0xFF Thumb/ROM ..S | 2 | 9 |
| mul #0x12345678, #0xFF Thumb/ROM P.S | 2 | 5 |
| mul #0x12345678, #0xFF Thumb/ROM .NS | 2 | 8 |
| mul #0x12345678, #0xFF Thumb/ROM PNS | 2 | 5 |
| mul #0x12345678, #0xFF Thumb/WRAM | 3 | 7 |
| mul #0x12345678, #0xFF Thumb/IWRAM | 1 | 5 |
| mul #0xFF000000, #0xFF ARM/ROM ... | 4 | 11 |
| mul #0xFF000000, #0xFF ARM/ROM P.. | 4 | 6 |
| mul #0xFF000000, #0xFF ARM/ROM .N. | 4 | 10 |
| mul #0xFF000000, #0xFF ARM/ROM PN. | 4 | 6 |
| mul #0xFF000000, #0xFF ARM/ROM ..S | 4 | 10 |
| mul #0xFF000000, #0xFF ARM/ROM .NS | 4 | 9 |
| mul #0xFF000000, #0xFF ARM/WRAM | 6 | 9 |
| mul #0xFF000000, #0xFF ARM/IWRAM | 1 | 4 |
| mul #0xFF000000, #0xFF Thumb/ROM ... | 2 | 8 |
| mul #0xFF000000, #0xFF Thumb/ROM P.. | 2 | 4 |
| mul #0xFF000000, #0xFF Thumb/ROM .N. | 2 | 7 |
| mul #0xFF000000, #0xFF Thumb/ROM PN. | 2 | 4 |
| mul #0xFF000000, #0xFF Thumb/ROM ..S | 2 | 8 |
| mul #0xFF000000, #0xFF Thumb/ROM P.S | 2 | 4 |
| mul #0xFF000000, #0xFF Thumb/ROM .NS | 2 | 7 |
| mul #0xFF000000, #0xFF Thumb/ROM PNS | 2 | 4 |
| mul #0xFF000000, #0xFF Thumb/WRAM | 3 | 6 |
| mul #0xFF000000, #0xFF Thumb/IWRAM | 1 | 4 |
| mul #0xFFFF0000, #0xFF ARM/ROM ... | 4 | 10 |
| mul #0xFFFF0000, #0xFF ARM/ROM P.. | 4 | 6 |
| mul #0xFFFF0000, #0xFF ARM/ROM .N. | 4 | 9 |
| mul #0xFFFF0000, #0xFF ARM/ROM PN. | 4 | 6 |
| mul #0xFFFF0000, #0xFF ARM/ROM ..S | 4 | 9 |
| mul #0xFFFF0000, #0xFF ARM/ROM .NS | 4 | 8 |
| mul #0xFFFF0000, #0xFF ARM/WRAM | 6 | 8 |
| mul #0xFFFF0000, #0xFF ARM/IWRAM | 1 | 3 |
| mul #0xFFFF0000, #0xFF Thumb/ROM ... | 2 | 7 |
| mul #0xFFFF0000, #0xFF Thumb/ROM P.. | 2 | 3 |
| mul #0xFFFF0000, #0xFF Thumb/ROM .N. | 2 | 6 |
| mul #0xFFFF0000, #0xFF Thumb/ROM PN. | 2 | 3 |
| mul #0xFFFF0000, #0xFF Thumb/ROM ..S | 2 | 7 |
| mul #0xFFFF0000, #0xFF Thumb/ROM P.S | 2 | 3 |
| mul #0xFFFF0000, #0xFF Thumb/ROM .NS | 2 | 6 |
| mul #0xFFFF0000, #0xFF Thumb/ROM PNS | 2 | 3 |
| mul #0xFFFF0000, #0xFF Thumb/WRAM | 3 | 5 |
| mul #0xFFFF0000, #0xFF Thumb/IWRAM | 1 | 3 |
| mul #0xFFFFFF00, #0xFF ARM/ROM ... | 4 | 9 |
| mul #0xFFFFFF00, #0xFF ARM/ROM P.. | 4 | 6 |
| mul #0xFFFFFF00, #0xFF ARM/ROM .N. | 4 | 8 |
| mul #0xFFFFFF00, #0xFF ARM/ROM PN. | 4 | 6 |
| mul #0xFFFFFF00, #0xFF ARM/ROM ..S | 4 | 8 |
| mul #0xFFFFFF00, #0xFF ARM/ROM .NS | 4 | 7 |
| mul #0xFFFFFF00, #0xFF ARM/WRAM | 6 | 7 |
| mul #0xFFFFFF00, #0xFF ARM/IWRAM | 1 | 2 |
| mul #0xFFFFFF00, #0xFF Thumb/ROM ... | 2 | 6 |
| mul #0xFFFFFF00, #0xFF Thumb/ROM P.. | 2 | 3 |
| mul #0xFFFFFF00, #0xFF Thumb/ROM .N. | 2 | 5 |
| mul #0xFFFFFF00, #0xFF Thumb/ROM PN. | 2 | 3 |
| mul #0xFFFFFF00, #0xFF Thumb/ROM ..S | 2 | 6 |
| mul #0xFFFFFF00, #0xFF Thumb/ROM .NS | 2 | 5 |
| mul #0xFFFFFF00, #0xFF Thumb/WRAM | 3 | 4 |
| mul #0xFFFFFF00, #0xFF Thumb/IWRAM | 1 | 2 |
| mul #0xFFFFFFFF, #0xFF ARM/ROM ... | 4 | 9 |
| mul #0xFFFFFFFF, #0xFF ARM/ROM P.. | 4 | 6 |
| mul #0xFFFFFFFF, #0xFF ARM/ROM .N. | 4 | 8 |
| mul #0xFFFFFFFF, #0xFF ARM/ROM PN. | 4 | 6 |
| mul #0xFFFFFFFF, #0xFF ARM/ROM ..S | 4 | 8 |
| mul #0xFFFFFFFF, #0xFF ARM/ROM .NS | 4 | 7 |
| mul #0xFFFFFFFF, #0xFF ARM/WRAM | 6 | 7 |
| mul #0xFFFFFFFF, #0xFF ARM/IWRAM | 1 | 2 |
| mul #0xFFFFFFFF, #0xFF Thumb/ROM ... | 2 | 6 |
| mul #0xFFFFFFFF, #0xFF Thumb/ROM P.. | 2 | 3 |
| mul #0xFFFFFFFF, #0xFF Thumb/ROM .N. | 2 | 5 |
| mul #0xFFFFFFFF, #0xFF Thumb/ROM PN. | 2 | 3 |
| mul #0xFFFFFFFF, #0xFF Thumb/ROM ..S | 2 | 6 |
| mul #0xFFFFFFFF, #0xFF Thumb/ROM .NS | 2 | 5 |
| mul #0xFFFFFFFF, #0xFF Thumb/WRAM | 3 | 4 |
| mul #0xFFFFFFFF, #0xFF Thumb/IWRAM | 1 | 2 |
| mul #0xFFFFFFFF, #0x00 ARM/ROM ... | 4 | 9 |
| mul #0xFFFFFFFF, #0x00 ARM/ROM P.. | 4 | 6 |
| mul #0xFFFFFFFF, #0x00 ARM/ROM .N. | 4 | 8 |
| mul #0xFFFFFFFF, #0x00 ARM/ROM PN. | 4 | 6 |
| mul #0xFFFFFFFF, #0x00 ARM/ROM ..S | 4 | 8 |
| mul #0xFFFFFFFF, #0x00 ARM/ROM .NS | 4 | 7 |
| mul #0xFFFFFFFF, #0x00 ARM/WRAM | 6 | 7 |
| mul #0xFFFFFFFF, #0x00 ARM/IWRAM | 1 | 2 |
| mul #0xFFFFFFFF, #0x00 Thumb/ROM ... | 2 | 6 |
| mul #0xFFFFFFFF, #0x00 Thumb/ROM P.. | 2 | 3 |
| mul #0xFFFFFFFF, #0x00 Thumb/ROM .N. | 2 | 5 |
| mul #0xFFFFFFFF, #0x00 Thumb/ROM PN. | 2 | 3 |
| mul #0xFFFFFFFF, #0x00 Thumb/ROM ..S | 2 | 6 |
| mul #0xFFFFFFFF, #0x00 Thumb/ROM .NS | 2 | 5 |
| mul #0xFFFFFFFF, #0x00 Thumb/WRAM | 3 | 4 |
| mul #0xFFFFFFFF, #0x00 Thumb/IWRAM | 1 | 2 |
| mla #0x00000000, #0xFF ARM/ROM ... | 4 | 10 |
| mla #0x00000000, #0xFF ARM/ROM P.. | 4 | 6 |
| mla #0x00000000, #0xFF ARM/ROM .N. | 4 | 9 |
| mla #0x00000000, #0xFF ARM/ROM PN. | 4 | 6 |
| mla #0x00000000, #0xFF ARM/ROM ..S | 4 | 9 |
| mla #0x00000000, #0xFF ARM/ROM .NS | 4 | 8 |
| mla #0x00000000, #0xFF ARM/WRAM | 6 | 8 |
| mla #0x00000000, #0xFF ARM/IWRAM | 1 | 3 |
| mla #0x00000078, #0xFF ARM/ROM ... | 4 | 10 |
| mla #0x00000078, #0xFF ARM/ROM P.. | 4 | 6 |
| mla #0x00000078, #0xFF ARM/ROM .N. | 4 | 9 |
| mla #0x00000078, #0xFF ARM/ROM PN. | 4 | 6 |
| mla #0x00000078, #0xFF ARM/ROM ..S | 4 | 9 |
| mla #0x00000078, #0xFF ARM/ROM .NS | 4 | 8 |
| mla #0x00000078, #0xFF ARM/WRAM | 6 | 8 |
| mla #0x00000078, #0xFF ARM/IWRAM | 1 | 3 |
| mla #0x00005678, #0xFF ARM/ROM ... | 4 | 10 |
| mla #0x00005678, #0xFF ARM/ROM P.. | 4 | 6 |
| mla #0x00005678, #0xFF ARM/ROM .N. | 4 | 9 |
| mla #0x00005678, #0xFF ARM/ROM PN. | 4 | 6 |
| mla #0x00005678, #0xFF ARM/ROM ..S | 4 | 9 |
| mla #0x00005678, #0xFF ARM/ROM .NS | 4 | 8 |
| mla #0x00005678, #0xFF ARM/WRAM | 6 | 8 |
| mla #0x00005678, #0xFF ARM/IWRAM | 1 | 3 |
| mla #0x00345678, #0xFF ARM/ROM ... | 4 | 10 |
| mla #0x00345678, #0xFF ARM/ROM P.. | 4 | 6 |
| mla #0x00345678, #0xFF ARM/ROM .N. | 4 | 9 |
| mla #0x00345678, #0xFF ARM/ROM PN. | 4 | 6 |
| mla #0x00345678, #0xFF ARM/ROM ..S | 4 | 9 |
| mla #0x00345678, #0xFF ARM/ROM .NS | 4 | 8 |
| mla #0x00345678, #0xFF ARM/WRAM | 6 | 8 |
| mla #0x00345678, #0xFF ARM/IWRAM | 1 | 3 |
| mla #0x12345678, #0xFF ARM/ROM ... | 4 | 10 |
| mla #0x12345678, #0xFF ARM/ROM P.. | 4 | 6 |
| mla #0x12345678, #0xFF ARM/ROM .N. | 4 | 9 |
| mla #0x12345678, #0xFF ARM/ROM PN. | 4 | 6 |
| mla #0x12345678, #0xFF ARM/ROM ..S | 4 | 9 |
| mla #0x12345678, #0xFF ARM/ROM .NS | 4 | 8 |
| mla #0x12345678, #0xFF ARM/WRAM | 6 | 8 |
| mla #0x12345678, #0xFF ARM/IWRAM | 1 | 3 |
| mla #0xFF000000, #0xFF ARM/ROM ... | 4 | 10 |
| mla #0xFF000000, #0xFF ARM/ROM P.. | 4 | 6 |
| mla #0xFF000000, #0xFF ARM/ROM .N. | 4 | 9 |
| mla #0xFF000000, #0xFF ARM/ROM PN. | 4 | 6 |
| mla #0xFF000000, #0xFF ARM/ROM ..S | 4 | 9 |
| mla #0xFF000000, #0xFF ARM/ROM .NS | 4 | 8 |
| mla #0xFF000000, #0xFF ARM/WRAM | 6 | 8 |
| mla #0xFF000000, #0xFF ARM/IWRAM | 1 | 3 |
| mla #0xFFFF0000, #0xFF ARM/ROM ... | 4 | 10 |
| mla #0xFFFF0000, #0xFF ARM/ROM P.. | 4 | 6 |
| mla #0xFFFF0000, #0xFF ARM/ROM .N. | 4 | 9 |
| mla #0xFFFF0000, #0xFF ARM/ROM PN. | 4 | 6 |
| mla #0xFFFF0000, #0xFF ARM/ROM ..S | 4 | 9 |
| mla #0xFFFF0000, #0xFF ARM/ROM .NS | 4 | 8 |
| mla #0xFFFF0000, #0xFF ARM/WRAM | 6 | 8 |
| mla #0xFFFF0000, #0xFF ARM/IWRAM | 1 | 3 |
| mla #0xFFFFFF00, #0xFF ARM/ROM ... | 4 | 10 |
| mla #0xFFFFFF00, #0xFF ARM/ROM P.. | 4 | 6 |
| mla #0xFFFFFF00, #0xFF ARM/ROM .N. | 4 | 9 |
| mla #0xFFFFFF00, #0xFF ARM/ROM PN. | 4 | 6 |
| mla #0xFFFFFF00, #0xFF ARM/ROM ..S | 4 | 9 |
| mla #0xFFFFFF00, #0xFF ARM/ROM .NS | 4 | 8 |
| mla #0xFFFFFF00, #0xFF ARM/WRAM | 6 | 8 |
| mla #0xFFFFFF00, #0xFF ARM/IWRAM | 1 | 3 |
| mla #0xFFFFFFFF, #0xFF ARM/ROM ... | 4 | 10 |
| mla #0xFFFFFFFF, #0xFF ARM/ROM P.. | 4 | 6 |
| mla #0xFFFFFFFF, #0xFF ARM/ROM .N. | 4 | 9 |
| mla #0xFFFFFFFF, #0xFF ARM/ROM PN. | 4 | 6 |
| mla #0xFFFFFFFF, #0xFF ARM/ROM ..S | 4 | 9 |
| mla #0xFFFFFFFF, #0xFF ARM/ROM .NS | 4 | 8 |
| mla #0xFFFFFFFF, #0xFF ARM/WRAM | 6 | 8 |
| mla #0xFFFFFFFF, #0xFF ARM/IWRAM | 1 | 3 |
| mla #0xFFFFFFFF, #0x00 ARM/ROM ... | 4 | 10 |
| mla #0xFFFFFFFF, #0x00 ARM/ROM P.. | 4 | 6 |
| mla #0xFFFFFFFF, #0x00 ARM/ROM .N. | 4 | 9 |
| mla #0xFFFFFFFF, #0x00 ARM/ROM PN. | 4 | 6 |
| mla #0xFFFFFFFF, #0x00 ARM/ROM ..S | 4 | 9 |
| mla #0xFFFFFFFF, #0x00 ARM/ROM .NS | 4 | 8 |
| mla #0xFFFFFFFF, #0x00 ARM/WRAM | 6 | 8 |
| mla #0xFFFFFFFF, #0x00 ARM/IWRAM | 1 | 3 |
| smull #0x00000000, #0xFF ARM/ROM ... | 4 | 10 |
| smull #0x00000000, #0xFF ARM/ROM P.. | 4 | 6 |
| smull #0x00000000, #0xFF ARM/ROM .N. | 4 | 9 |
| smull #0x00000000, #0xFF ARM/ROM PN. | 4 | 6 |
| smull #0x00000000, #0xFF ARM/ROM ..S | 4 | 9 |
| smull #0x00000000, #0xFF ARM/ROM .NS | 4 | 8 |
| smull #0x00000000, #0xFF ARM/WRAM | 6 | 8 |
| smull #0x00000000, #0xFF ARM/IWRAM | 1 | 3 |
| smull #0x00000078, #0xFF ARM/ROM ... | 4 | 10 |
| smull #0x00000078, #0xFF ARM/ROM P.. | 4 | 6 |
| smull #0x00000078, #0xFF ARM/ROM .N. | 4 | 9 |
| smull #0x00000078, #0xFF ARM/ROM PN. | 4 | 6 |
| smull #0x00000078, #0xFF ARM/ROM ..S | 4 | 9 |
| smull #0x00000078, #0xFF ARM/ROM .NS | 4 | 8 |
| smull #0x00000078, #0xFF ARM/WRAM | 6 | 8 |
| smull #0x00000078, #0xFF ARM/IWRAM | 1 | 3 |
| smull #0x00005678, #0xFF ARM/ROM ... | 4 | 11 |
| smull #0x00005678, #0xFF ARM/ROM P.. | 4 | 6 |
| smull #0x00005678, #0xFF ARM/ROM .N. | 4 | 10 |
| smull #0x00005678, #0xFF ARM/ROM PN. | 4 | 6 |
| smull #0x00005678, #0xFF ARM/ROM ..S | 4 | 10 |
| smull #0x00005678, #0xFF ARM/ROM .NS | 4 | 9 |
| smull #0x00005678, #0xFF ARM/WRAM | 6 | 9 |
| smull #0x00005678, #0xFF ARM/IWRAM | 1 | 4 |
| smull #0x00345678, #0xFF ARM/ROM ... | 4 | 12 |
| smull #0x00345678, #0xFF ARM/ROM P.. | 4 | 6 |
| smull #0x00345678, #0xFF ARM/ROM .N. | 4 | 11 |
| smull #0x00345678, #0xFF ARM/ROM PN. | 4 | 6 |
| smull #0x00345678, #0xFF ARM/ROM ..S | 4 | 11 |
| smull #0x00345678, #0xFF ARM/ROM P.S | 4 | 5 |
| smull #0x00345678, #0xFF ARM/ROM .NS | 4 | 10 |
| smull #0x00345678, #0xFF ARM/ROM PNS | 4 | 5 |
| smull #0x00345678, #0xFF ARM/WRAM | 6 | 10 |
| smull #0x00345678, #0xFF ARM/IWRAM | 1 | 5 |
| smull #0x12345678, #0xFF ARM/ROM ... | 4 | 13 |
| smull #0x12345678, #0xFF ARM/ROM P.. | 4 | 6 |
| smull #0x12345678, #0xFF ARM/ROM .N. | 4 | 12 |
| smull #0x12345678, #0xFF ARM/ROM PN. | 4 | 6 |
| smull #0x12345678, #0xFF ARM/ROM ..S | 4 | 12 |
| smull #0x12345678, #0xFF ARM/ROM P.S | 4 | 6 |
| smull #0x12345678, #0xFF ARM/ROM .NS | 4 | 11 |
| smull #0x12345678, #0xFF ARM/ROM PNS | 4 | 6 |
| smull #0x12345678, #0xFF ARM/WRAM | 6 | 11 |
| smull #0x12345678, #0xFF ARM/IWRAM | 1 | 6 |
| smull #0xFF000000, #0xFF ARM/ROM ... | 4 | 12 |
| smull #0xFF000000, #0xFF ARM/ROM P.. | 4 | 6 |
| smull #0xFF000000, #0xFF ARM/ROM .N. | 4 | 11 |
| smull #0xFF000000, #0xFF ARM/ROM PN. | 4 | 6 |
| smull #0xFF000000, #0xFF ARM/ROM ..S | 4 | 11 |
| smull #0xFF000000, #0xFF ARM/ROM P.S | 4 | 5 |
| smull #0xFF000000, #0xFF ARM/ROM .NS | 4 | 10 |
| smull #0xFF000000, #0xFF ARM/ROM PNS | 4 | 5 |
| smull #0xFF000000, #0xFF ARM/WRAM | 6 | 10 |
| smull #0xFF000000, #0xFF ARM/IWRAM | 1 | 5 |
| smull #0xFFFF0000, #0xFF ARM/ROM ... | 4 | 11 |
| smull #0xFFFF0000, #0xFF ARM/ROM P.. | 4 | 6 |
| smull #0xFFFF0000, #0xFF ARM/ROM .N. | 4 | 10 |
| smull #0xFFFF0000, #0xFF ARM/ROM PN. | 4 | 6 |
| smull #0xFFFF0000, #0xFF ARM/ROM ..S | 4 | 10 |
| smull #0xFFFF0000, #0xFF ARM/ROM .NS | 4 | 9 |
| smull #0xFFFF0000, #0xFF ARM/WRAM | 6 | 9 |
| smull #0xFFFF0000, #0xFF ARM/IWRAM | 1 | 4 |
| smull #0xFFFFFF00, #0xFF ARM/ROM ... | 4 | 10 |
| smull #0xFFFFFF00, #0xFF ARM/ROM P.. | 4 | 6 |
| smull #0xFFFFFF00, #0xFF ARM/ROM .N. | 4 | 9 |
| smull #0xFFFFFF00, #0xFF ARM/ROM PN. | 4 | 6 |
| smull #0xFFFFFF00, #0xFF ARM/ROM ..S | 4 | 9 |
| smull #0xFFFFFF00, #0xFF ARM/ROM .NS | 4 | 8 |
| smull #0xFFFFFF00, #0xFF ARM/WRAM | 6 | 8 |
| smull #0xFFFFFF00, #0xFF ARM/IWRAM | 1 | 3 |
| smull #0xFFFFFFFF, #0xFF ARM/ROM ... | 4 | 10 |
| smull #0xFFFFFFFF, #0xFF ARM/ROM P.. | 4 | 6 |
| smull #0xFFFFFFFF, #0xFF ARM/ROM .N. | 4 | 9 |
| smull #0xFFFFFFFF, #0xFF ARM/ROM PN. | 4 | 6 |
| smull #0xFFFFFFFF, #0xFF ARM/ROM ..S | 4 | 9 |
| smull #0xFFFFFFFF, #0xFF ARM/ROM .NS | 4 | 8 |
| smull #0xFFFFFFFF, #0xFF ARM/WRAM | 6 | 8 |
| smull #0xFFFFFFFF, #0xFF ARM/IWRAM | 1 | 3 |
| smull #0xFFFFFFFF, #0x00 ARM/ROM ... | 4 | 10 |
| smull #0xFFFFFFFF, #0x00 ARM/ROM P.. | 4 | 6 |
| smull #0xFFFFFFFF, #0x00 ARM/ROM .N. | 4 | 9 |
| smull #0xFFFFFFFF, #0x00 ARM/ROM PN. | 4 | 6 |
| smull #0xFFFFFFFF, #0x00 ARM/ROM ..S | 4 | 9 |
| smull #0xFFFFFFFF, #0x00 ARM/ROM .NS | 4 | 8 |
| smull #0xFFFFFFFF, #0x00 ARM/WRAM | 6 | 8 |
| smull #0xFFFFFFFF, #0x00 ARM/IWRAM | 1 | 3 |
| smlal #0x00000000, #0xFF ARM/ROM ... | 4 | 11 |
| smlal #0x00000000, #0xFF ARM/ROM P.. | 4 | 6 |
| smlal #0x00000000, #0xFF ARM/ROM .N. | 4 | 10 |
| smlal #0x00000000, #0xFF ARM/ROM PN. | 4 | 6 |
| smlal #0x00000000, #0xFF ARM/ROM ..S | 4 | 10 |
| smlal #0x00000000, #0xFF ARM/ROM .NS | 4 | 9 |
| smlal #0x00000000, #0xFF ARM/WRAM | 6 | 9 |
| smlal #0x00000000, #0xFF ARM/IWRAM | 1 | 4 |
| smlal #0x00000078, #0xFF ARM/ROM ... | 4 | 11 |
| smlal #0x00000078, #0xFF ARM/ROM P.. | 4 | 6 |
| smlal #0x00000078, #0xFF ARM/ROM .N. | 4 | 10 |
| smlal #0x00000078, #0xFF ARM/ROM PN. | 4 | 6 |
| smlal #0x00000078, #0xFF ARM/ROM ..S | 4 | 10 |
| smlal #0x00000078, #0xFF ARM/ROM .NS | 4 | 9 |
| smlal #0x00000078, #0xFF ARM/WRAM | 6 | 9 |
| smlal #0x00000078, #0xFF ARM/IWRAM | 1 | 4 |
| smlal #0x00005678, #0xFF ARM/ROM ... | 4 | 12 |
| smlal #0x00005678, #0xFF ARM/ROM P.. | 4 | 6 |
| smlal #0x00005678, #0xFF ARM/ROM .N. | 4 | 11 |
| smlal #0x00005678, #0xFF ARM/ROM PN. | 4 | 6 |
| smlal #0x00005678, #0xFF ARM/ROM ..S | 4 | 11 |
| smlal #0x00005678, #0xFF ARM/ROM P.S | 4 | 5 |
| smlal #0x00005678, #0xFF ARM/ROM .NS | 4 | 10 |
| smlal #0x00005678, #0xFF ARM/ROM PNS | 4 | 5 |
| smlal #0x00005678, #0xFF ARM/WRAM | 6 | 10 |
| smlal #0x00005678, #0xFF ARM/IWRAM | 1 | 5 |
| smlal #0x00345678, #0xFF ARM/ROM ... | 4 | 13 |
| smlal #0x00345678, #0xFF ARM/ROM P.. | 4 | 6 |
| smlal #0x00345678, #0xFF ARM/ROM .N. | 4 | 12 |
| smlal #0x00345678, #0xFF ARM/ROM PN. | 4 | 6 |
| smlal #0x00345678, #0xFF ARM/ROM ..S | 4 | 12 |
| smlal #0x00345678, #0xFF ARM/ROM P.S | 4 | 6 |
| smlal #0x00345678, #0xFF ARM/ROM .NS | 4 | 11 |
| smlal #0x00345678, #0xFF ARM/ROM PNS | 4 | 6 |
| smlal #0x00345678, #0xFF ARM/WRAM | 6 | 11 |
| smlal #0x00345678, #0xFF ARM/IWRAM | 1 | 6 |
| smlal #0x12345678, #0xFF ARM/ROM ... | 4 | 14 |
| smlal #0x12345678, #0xFF ARM/ROM P.. | 4 | 7 |
| smlal #0x12345678, #0xFF ARM/ROM .N. | 4 | 13 |
| smlal #0x12345678, #0xFF ARM/ROM PN. | 4 | 7 |
| smlal #0x12345678, #0xFF ARM/ROM ..S | 4 | 13 |
| smlal #0x12345678, #0xFF ARM/ROM P.S | 4 | 7 |
| smlal #0x12345678, #0xFF ARM/ROM .NS | 4 | 12 |
| smlal #0x12345678, #0xFF ARM/ROM PNS | 4 | 7 |
| smlal #0x12345678, #0xFF ARM/WRAM | 6 | 12 |
| smlal #0x12345678, #0xFF ARM/IWRAM | 1 | 7 |
| smlal #0xFF000000, #0xFF ARM/ROM ... | 4 | 13 |
| smlal #0xFF000000, #0xFF ARM/ROM P.. | 4 | 6 |
| smlal #0xFF000000, #0xFF ARM/ROM .N. | 4 | 12 |
| smlal #0xFF000000, #0xFF ARM/ROM PN. | 4 | 6 |
| smlal #0xFF000000, #0xFF ARM/ROM ..S | 4 | 12 |
| smlal #0xFF000000, #0xFF ARM/ROM P.S | 4 | 6 |
| smlal #0xFF000000, #0xFF ARM/ROM .NS | 4 | 11 |
| smlal #0xFF000000, #0xFF ARM/ROM PNS | 4 | 6 |
| smlal #0xFF000000, #0xFF ARM/WRAM | 6 | 11 |
| smlal #0xFF000000, #0xFF ARM/IWRAM | 1 | 6 |
| smlal #0xFFFF0000, #0xFF ARM/ROM ... | 4 | 12 |
| smlal #0xFFFF0000, #0xFF ARM/ROM P.. | 4 | 6 |
| smlal #0xFFFF0000, #0xFF ARM/ROM .N. | 4 | 11 |
| smlal #0xFFFF0000, #0xFF ARM/ROM PN. | 4 | 6 |
| smlal #0xFFFF0000, #0xFF ARM/ROM ..S | 4 | 11 |
| smlal #0xFFFF0000, #0xFF ARM/ROM P.S | 4 | 5 |
| smlal #0xFFFF0000, #0xFF ARM/ROM .NS | 4 | 10 |
| smlal #0xFFFF0000, #0xFF ARM/ROM PNS | 4 | 5 |
| smlal #0xFFFF0000, #0xFF ARM/WRAM | 6 | 10 |
| smlal #0xFFFF0000, #0xFF ARM/IWRAM | 1 | 5 |
| smlal #0xFFFFFF00, #0xFF ARM/ROM ... | 4 | 11 |
| smlal #0xFFFFFF00, #0xFF ARM/ROM P.. | 4 | 6 |
| smlal #0xFFFFFF00, #0xFF ARM/ROM .N. | 4 | 10 |
| smlal #0xFFFFFF00, #0xFF ARM/ROM PN. | 4 | 6 |
| smlal #0xFFFFFF00, #0xFF ARM/ROM ..S | 4 | 10 |
| smlal #0xFFFFFF00, #0xFF ARM/ROM .NS | 4 | 9 |
| smlal #0xFFFFFF00, #0xFF ARM/WRAM | 6 | 9 |
| smlal #0xFFFFFF00, #0xFF ARM/IWRAM | 1 | 4 |
| smlal #0xFFFFFFFF, #0xFF ARM/ROM ... | 4 | 11 |
| smlal #0xFFFFFFFF, #0xFF ARM/ROM P.. | 4 | 6 |
| smlal #0xFFFFFFFF, #0xFF ARM/ROM .N. | 4 | 10 |
| smlal #0xFFFFFFFF, #0xFF ARM/ROM PN. | 4 | 6 |
| smlal #0xFFFFFFFF, #0xFF ARM/ROM ..S | 4 | 10 |
| smlal #0xFFFFFFFF, #0xFF ARM/ROM .NS | 4 | 9 |
| smlal #0xFFFFFFFF, #0xFF ARM/WRAM | 6 | 9 |
| smlal #0xFFFFFFFF, #0xFF ARM/IWRAM | 1 | 4 |
| smlal #0xFFFFFFFF, #0x00 ARM/ROM ... | 4 | 11 |
| smlal #0xFFFFFFFF, #0x00 ARM/ROM P.. | 4 | 6 |
| smlal #0xFFFFFFFF, #0x00 ARM/ROM .N. | 4 | 10 |
| smlal #0xFFFFFFFF, #0x00 ARM/ROM PN. | 4 | 6 |
| smlal #0xFFFFFFFF, #0x00 ARM/ROM ..S | 4 | 10 |
| smlal #0xFFFFFFFF, #0x00 ARM/ROM .NS | 4 | 9 |
| smlal #0xFFFFFFFF, #0x00 ARM/WRAM | 6 | 9 |
| smlal #0xFFFFFFFF, #0x00 ARM/IWRAM | 1 | 4 |
| umull #0x00000000, #0xFF ARM/ROM ... | 4 | 10 |
| umull #0x00000000, #0xFF ARM/ROM P.. | 4 | 6 |
| umull #0x00000000, #0xFF ARM/ROM .N. | 4 | 9 |
| umull #0x00000000, #0xFF ARM/ROM PN. | 4 | 6 |
| umull #0x00000000, #0xFF ARM/ROM ..S | 4 | 9 |
| umull #0x00000000, #0xFF ARM/ROM .NS | 4 | 8 |
| umull #0x00000000, #0xFF ARM/WRAM | 6 | 8 |
| umull #0x00000000, #0xFF ARM/IWRAM | 1 | 3 |
| umull #0x00000078, #0xFF ARM/ROM ... | 4 | 10 |
| umull #0x00000078, #0xFF ARM/ROM P.. | 4 | 6 |
| umull #0x00000078, #0xFF ARM/ROM .N. | 4 | 9 |
| umull #0x00000078, #0xFF ARM/ROM PN. | 4 | 6 |
| umull #0x00000078, #0xFF ARM/ROM ..S | 4 | 9 |
| umull #0x00000078, #0xFF ARM/ROM .NS | 4 | 8 |
| umull #0x00000078, #0xFF ARM/WRAM | 6 | 8 |
| umull #0x00000078, #0xFF ARM/IWRAM | 1 | 3 |
| umull #0x00005678, #0xFF ARM/ROM ... | 4 | 11 |
| umull #0x00005678, #0xFF ARM/ROM P.. | 4 | 6 |
| umull #0x00005678, #0xFF ARM/ROM .N. | 4 | 10 |
| umull #0x00005678, #0xFF ARM/ROM PN. | 4 | 6 |
| umull #0x00005678, #0xFF ARM/ROM ..S | 4 | 10 |
| umull #0x00005678, #0xFF ARM/ROM .NS | 4 | 9 |
| umull #0x00005678, #0xFF ARM/WRAM | 6 | 9 |
| umull #0x00005678, #0xFF ARM/IWRAM | 1 | 4 |
| umull #0x00345678, #0xFF ARM/ROM ... | 4 | 12 |
| umull #0x00345678, #0xFF ARM/ROM P.. | 4 | 6 |
| umull #0x00345678, #0xFF ARM/ROM .N. | 4 | 11 |
| umull #0x00345678, #0xFF ARM/ROM PN. | 4 | 6 |
| umull #0x00345678, #0xFF ARM/ROM ..S | 4 | 11 |
| umull #0x00345678, #0xFF ARM/ROM P.S | 4 | 5 |
| umull #0x00345678, #0xFF ARM/ROM .NS | 4 | 10 |
| umull #0x00345678, #0xFF ARM/ROM PNS | 4 | 5 |
| umull #0x00345678, #0xFF ARM/WRAM | 6 | 10 |
| umull #0x00345678, #0xFF ARM/IWRAM | 1 | 5 |
| umull #0x12345678, #0xFF ARM/ROM ... | 4 | 13 |
| umull #0x12345678, #0xFF ARM/ROM P.. | 4 | 6 |
| umull #0x12345678, #0xFF ARM/ROM .N. | 4 | 12 |
| umull #0x12345678, #0xFF ARM/ROM PN. | 4 | 6 |
| umull #0x12345678, #0xFF ARM/ROM ..S | 4 | 12 |
| umull #0x12345678, #0xFF ARM/ROM P.S | 4 | 6 |
| umull #0x12345678, #0xFF ARM/ROM .NS | 4 | 11 |
| umull #0x12345678, #0xFF ARM/ROM PNS | 4 | 6 |
| umull #0x12345678, #0xFF ARM/WRAM | 6 | 11 |
| umull #0x12345678, #0xFF ARM/IWRAM | 1 | 6 |
| umull #0xFF000000, #0xFF ARM/ROM ... | 4 | 13 |
| umull #0xFF000000, #0xFF ARM/ROM P.. | 4 | 6 |
| umull #0xFF000000, #0xFF ARM/ROM .N. | 4 | 12 |
| umull #0xFF000000, #0xFF ARM/ROM PN. | 4 | 6 |
| umull #0xFF000000, #0xFF ARM/ROM ..S | 4 | 12 |
| umull #0xFF000000, #0xFF ARM/ROM P.S | 4 | 6 |
| umull #0xFF000000, #0xFF ARM/ROM .NS | 4 | 11 |
| umull #0xFF000000, #0xFF ARM/ROM PNS | 4 | 6 |
| umull #0xFF000000, #0xFF ARM/WRAM | 6 | 11 |
| umull #0xFF000000, #0xFF ARM/IWRAM | 1 | 6 |
| umull #0xFFFF0000, #0xFF ARM/ROM ... | 4 | 13 |
| umull #0xFFFF0000, #0xFF ARM/ROM P.. | 4 | 6 |
| umull #0xFFFF0000, #0xFF ARM/ROM .N. | 4 | 12 |
| umull #0xFFFF0000, #0xFF ARM/ROM PN. | 4 | 6 |
| umull #0xFFFF0000, #0xFF ARM/ROM ..S | 4 | 12 |
| umull #0xFFFF0000, #0xFF ARM/ROM P.S | 4 | 6 |
| umull #0xFFFF0000, #0xFF ARM/ROM .NS | 4 | 11 |
| umull #0xFFFF0000, #0xFF ARM/ROM PNS | 4 | 6 |
| umull #0xFFFF0000, #0xFF ARM/WRAM | 6 | 11 |
| umull #0xFFFF0000, #0xFF ARM/IWRAM | 1 | 6 |
| umull #0xFFFFFF00, #0xFF ARM/ROM ... | 4 | 13 |
| umull #0xFFFFFF00, #0xFF ARM/ROM P.. | 4 | 6 |
| umull #0xFFFFFF00, #0xFF ARM/ROM .N. | 4 | 12 |
| umull #0xFFFFFF00, #0xFF ARM/ROM PN. | 4 | 6 |
| umull #0xFFFFFF00, #0xFF ARM/ROM ..S | 4 | 12 |
| umull #0xFFFFFF00, #0xFF ARM/ROM P.S | 4 | 6 |
| umull #0xFFFFFF00, #0xFF ARM/ROM .NS | 4 | 11 |
| umull #0xFFFFFF00, #0xFF ARM/ROM PNS | 4 | 6 |
| umull #0xFFFFFF00, #0xFF ARM/WRAM | 6 | 11 |
| umull #0xFFFFFF00, #0xFF ARM/IWRAM | 1 | 6 |
| umull #0xFFFFFFFF, #0xFF ARM/ROM ... | 4 | 13 |
| umull #0xFFFFFFFF, #0xFF ARM/ROM P.. | 4 | 6 |
| umull #0xFFFFFFFF, #0xFF ARM/ROM .N. | 4 | 12 |
| umull #0xFFFFFFFF, #0xFF ARM/ROM PN. | 4 | 6 |
| umull #0xFFFFFFFF, #0xFF ARM/ROM ..S | 4 | 12 |
| umull #0xFFFFFFFF, #0xFF ARM/ROM P.S | 4 | 6 |
| umull #0xFFFFFFFF, #0xFF ARM/ROM .NS | 4 | 11 |
| umull #0xFFFFFFFF, #0xFF ARM/ROM PNS | 4 | 6 |
| umull #0xFFFFFFFF, #0xFF ARM/WRAM | 6 | 11 |
| umull #0xFFFFFFFF, #0xFF ARM/IWRAM | 1 | 6 |
| umull #0xFFFFFFFF, #0x00 ARM/ROM ... | 4 | 13 |
| umull #0xFFFFFFFF, #0x00 ARM/ROM P.. | 4 | 6 |
| umull #0xFFFFFFFF, #0x00 ARM/ROM .N. | 4 | 12 |
| umull #0xFFFFFFFF, #0x00 ARM/ROM PN. | 4 | 6 |
| umull #0xFFFFFFFF, #0x00 ARM/ROM ..S | 4 | 12 |
| umull #0xFFFFFFFF, #0x00 ARM/ROM P.S | 4 | 6 |
| umull #0xFFFFFFFF, #0x00 ARM/ROM .NS | 4 | 11 |
| umull #0xFFFFFFFF, #0x00 ARM/ROM PNS | 4 | 6 |
| umull #0xFFFFFFFF, #0x00 ARM/WRAM | 6 | 11 |
| umull #0xFFFFFFFF, #0x00 ARM/IWRAM | 1 | 6 |
| umlal #0x00000000, #0xFF ARM/ROM ... | 4 | 11 |
| umlal #0x00000000, #0xFF ARM/ROM P.. | 4 | 6 |
| umlal #0x00000000, #0xFF ARM/ROM .N. | 4 | 10 |
| umlal #0x00000000, #0xFF ARM/ROM PN. | 4 | 6 |
| umlal #0x00000000, #0xFF ARM/ROM ..S | 4 | 10 |
| umlal #0x00000000, #0xFF ARM/ROM .NS | 4 | 9 |
| umlal #0x00000000, #0xFF ARM/WRAM | 6 | 9 |
| umlal #0x00000000, #0xFF ARM/IWRAM | 1 | 4 |
| umlal #0x00000078, #0xFF ARM/ROM ... | 4 | 11 |
| umlal #0x00000078, #0xFF ARM/ROM P.. | 4 | 6 |
| umlal #0x00000078, #0xFF ARM/ROM .N. | 4 | 10 |
| umlal #0x00000078, #0xFF ARM/ROM PN. | 4 | 6 |
| umlal #0x00000078, #0xFF ARM/ROM ..S | 4 | 10 |
| umlal #0x00000078, #0xFF ARM/ROM .NS | 4 | 9 |
| umlal #0x00000078, #0xFF ARM/WRAM | 6 | 9 |
| umlal #0x00000078, #0xFF ARM/IWRAM | 1 | 4 |
| umlal #0x00005678, #0xFF ARM/ROM ... | 4 | 12 |
| umlal #0x00005678, #0xFF ARM/ROM P.. | 4 | 6 |
| umlal #0x00005678, #0xFF ARM/ROM .N. | 4 | 11 |
| umlal #0x00005678, #0xFF ARM/ROM PN. | 4 | 6 |
| umlal #0x00005678, #0xFF ARM/ROM ..S | 4 | 11 |
| umlal #0x00005678, #0xFF ARM/ROM P.S | 4 | 5 |
| umlal #0x00005678, #0xFF ARM/ROM .NS | 4 | 10 |
| umlal #0x00005678, #0xFF ARM/ROM PNS | 4 | 5 |
| umlal #0x00005678, #0xFF ARM/WRAM | 6 | 10 |
| umlal #0x00005678, #0xFF ARM/IWRAM | 1 | 5 |
| umlal #0x00345678, #0xFF ARM/ROM ... | 4 | 13 |
| umlal #0x00345678, #0xFF ARM/ROM P.. | 4 | 6 |
| umlal #0x00345678, #0xFF ARM/ROM .N. | 4 | 12 |
| umlal #0x00345678, #0xFF ARM/ROM PN. | 4 | 6 |
| umlal #0x00345678, #0xFF ARM/ROM ..S | 4 | 12 |
| umlal #0x00345678, #0xFF ARM/ROM P.S | 4 | 6 |
| umlal #0x00345678, #0xFF ARM/ROM .NS | 4 | 11 |
| umlal #0x00345678, #0xFF ARM/ROM PNS | 4 | 6 |
| umlal #0x00345678, #0xFF ARM/WRAM | 6 | 11 |
| umlal #0x00345678, #0xFF ARM/IWRAM | 1 | 6 |
| umlal #0x12345678, #0xFF ARM/ROM ... | 4 | 14 |
| umlal #0x12345678, #0xFF ARM/ROM P.. | 4 | 7 |
| umlal #0x12345678, #0xFF ARM/ROM .N. | 4 | 13 |
| umlal #0x12345678, #0xFF ARM/ROM PN. | 4 | 7 |
| umlal #0x12345678, #0xFF ARM/ROM ..S | 4 | 13 |
| umlal #0x12345678, #0xFF ARM/ROM P.S | 4 | 7 |
| umlal #0x12345678, #0xFF ARM/ROM .NS | 4 | 12 |
| umlal #0x12345678, #0xFF ARM/ROM PNS | 4 | 7 |
| umlal #0x12345678, #0xFF ARM/WRAM | 6 | 12 |
| umlal #0x12345678, #0xFF ARM/IWRAM | 1 | 7 |
| umlal #0xFF000000, #0xFF ARM/ROM ... | 4 | 14 |
| umlal #0xFF000000, #0xFF ARM/ROM P.. | 4 | 7 |
| umlal #0xFF000000, #0xFF ARM/ROM .N. | 4 | 13 |
| umlal #0xFF000000, #0xFF ARM/ROM PN. | 4 | 7 |
| umlal #0xFF000000, #0xFF ARM/ROM ..S | 4 | 13 |
| umlal #0xFF000000, #0xFF ARM/ROM P.S | 4 | 7 |
| umlal #0xFF000000, #0xFF ARM/ROM .NS | 4 | 12 |
| umlal #0xFF000000, #0xFF ARM/ROM PNS | 4 | 7 |
| umlal #0xFF000000, #0xFF ARM/WRAM | 6 | 12 |
| umlal #0xFF000000, #0xFF ARM/IWRAM | 1 | 7 |
| umlal #0xFFFF0000, #0xFF ARM/ROM ... | 4 | 14 |
| umlal #0xFFFF0000, #0xFF ARM/ROM P.. | 4 | 7 |
| umlal #0xFFFF0000, #0xFF ARM/ROM .N. | 4 | 13 |
| umlal #0xFFFF0000, #0xFF ARM/ROM PN. | 4 | 7 |
| umlal #0xFFFF0000, #0xFF ARM/ROM ..S | 4 | 13 |
| umlal #0xFFFF0000, #0xFF ARM/ROM P.S | 4 | 7 |
| umlal #0xFFFF0000, #0xFF ARM/ROM .NS | 4 | 12 |
| umlal #0xFFFF0000, #0xFF ARM/ROM PNS | 4 | 7 |
| umlal #0xFFFF0000, #0xFF ARM/WRAM | 6 | 12 |
| umlal #0xFFFF0000, #0xFF ARM/IWRAM | 1 | 7 |
| umlal #0xFFFFFF00, #0xFF ARM/ROM ... | 4 | 14 |
| umlal #0xFFFFFF00, #0xFF ARM/ROM P.. | 4 | 7 |
| umlal #0xFFFFFF00, #0xFF ARM/ROM .N. | 4 | 13 |
| umlal #0xFFFFFF00, #0xFF ARM/ROM PN. | 4 | 7 |
| umlal #0xFFFFFF00, #0xFF ARM/ROM ..S | 4 | 13 |
| umlal #0xFFFFFF00, #0xFF ARM/ROM P.S | 4 | 7 |
| umlal #0xFFFFFF00, #0xFF ARM/ROM .NS | 4 | 12 |
| umlal #0xFFFFFF00, #0xFF ARM/ROM PNS | 4 | 7 |
| umlal #0xFFFFFF00, #0xFF ARM/WRAM | 6 | 12 |
| umlal #0xFFFFFF00, #0xFF ARM/IWRAM | 1 | 7 |
| umlal #0xFFFFFFFF, #0xFF ARM/ROM ... | 4 | 14 |
| umlal #0xFFFFFFFF, #0xFF ARM/ROM P.. | 4 | 7 |
| umlal #0xFFFFFFFF, #0xFF ARM/ROM .N. | 4 | 13 |
| umlal #0xFFFFFFFF, #0xFF ARM/ROM PN. | 4 | 7 |
| umlal #0xFFFFFFFF, #0xFF ARM/ROM ..S | 4 | 13 |
| umlal #0xFFFFFFFF, #0xFF ARM/ROM P.S | 4 | 7 |
| umlal #0xFFFFFFFF, #0xFF ARM/ROM .NS | 4 | 12 |
| umlal #0xFFFFFFFF, #0xFF ARM/ROM PNS | 4 | 7 |
| umlal #0xFFFFFFFF, #0xFF ARM/WRAM | 6 | 12 |
| umlal #0xFFFFFFFF, #0xFF ARM/IWRAM | 1 | 7 |
| umlal #0xFFFFFFFF, #0x00 ARM/ROM ... | 4 | 14 |
| umlal #0xFFFFFFFF, #0x00 ARM/ROM P.. | 4 | 7 |
| umlal #0xFFFFFFFF, #0x00 ARM/ROM .N. | 4 | 13 |
| umlal #0xFFFFFFFF, #0x00 ARM/ROM PN. | 4 | 7 |
| umlal #0xFFFFFFFF, #0x00 ARM/ROM ..S | 4 | 13 |
| umlal #0xFFFFFFFF, #0x00 ARM/ROM P.S | 4 | 7 |
| umlal #0xFFFFFFFF, #0x00 ARM/ROM .NS | 4 | 12 |
| umlal #0xFFFFFFFF, #0x00 ARM/ROM PNS | 4 | 7 |
| umlal #0xFFFFFFFF, #0x00 ARM/WRAM | 6 | 12 |
| umlal #0xFFFFFFFF, #0x00 ARM/IWRAM | 1 | 7 |
| b pc ARM/ROM ... | 10 | 26 |
| b pc ARM/ROM P.. | 10 | 26 |
| b pc ARM/ROM .N. | 10 | 25 |
| b pc ARM/ROM PN. | 10 | 25 |
| b pc ARM/ROM ..S | 10 | 19 |
| b pc ARM/ROM P.S | 10 | 19 |
| b pc ARM/ROM .NS | 10 | 18 |
| b pc ARM/ROM PNS | 10 | 18 |
| b pc ARM/WRAM | 14 | 24 |
| b pc Thumb/ROM ... | 6 | 14 |
| b pc Thumb/ROM P.. | 6 | 14 |
| b pc Thumb/ROM .N. | 6 | 13 |
| b pc Thumb/ROM PN. | 6 | 13 |
| b pc Thumb/ROM ..S | 6 | 11 |
| b pc Thumb/ROM P.S | 6 | 11 |
| b pc Thumb/ROM .NS | 6 | 10 |
| b pc Thumb/ROM PNS | 6 | 10 |
| b pc Thumb/WRAM | 8 | 12 |
| nop ; b pc ARM/ROM ... | 10 | 26 |
| nop ; b pc ARM/ROM P.. | 10 | 26 |
| nop ; b pc ARM/ROM .N. | 10 | 25 |
| nop ; b pc ARM/ROM PN. | 10 | 25 |
| nop ; b pc ARM/ROM ..S | 10 | 19 |
| nop ; b pc ARM/ROM P.S | 10 | 19 |
| nop ; b pc ARM/ROM .NS | 10 | 18 |
| nop ; b pc ARM/ROM PNS | 10 | 18 |
| nop ; b pc ARM/WRAM | 14 | 24 |
| nop ; b pc Thumb/ROM ... | 6 | 14 |
| nop ; b pc Thumb/ROM P.. | 6 | 14 |
| nop ; b pc Thumb/ROM .N. | 6 | 13 |
| nop ; b pc Thumb/ROM PN. | 6 | 13 |
| nop ; b pc Thumb/ROM ..S | 6 | 11 |
| nop ; b pc Thumb/ROM P.S | 6 | 11 |
| nop ; b pc Thumb/ROM .NS | 6 | 10 |
| nop ; b pc Thumb/ROM PNS | 6 | 10 |
| nop ; b pc Thumb/WRAM | 8 | 12 |
| bx ARM/ROM ... | 38 | 78 |
| bx ARM/ROM P.. | 38 | 78 |
| bx ARM/ROM .N. | 38 | 74 |
| bx ARM/ROM PN. | 38 | 74 |
| bx ARM/ROM ..S | 38 | 59 |
| bx ARM/ROM P.S | 38 | 59 |
| bx ARM/ROM .NS | 38 | 55 |
| bx ARM/ROM PNS | 38 | 55 |
| bx ARM/WRAM | 54 | 72 |
| bx ARM/IWRAM | 14 | 22 |
| bx Thumb/ROM ... | 28 | 57 |
| bx Thumb/ROM P.. | 28 | 57 |
| bx Thumb/ROM .N. | 28 | 53 |
| bx Thumb/ROM PN. | 28 | 53 |
| bx Thumb/ROM ..S | 28 | 45 |
| bx Thumb/ROM P.S | 28 | 45 |
| bx Thumb/ROM .NS | 28 | 41 |
| bx Thumb/ROM PNS | 28 | 41 |
| bx Thumb/WRAM | 39 | 51 |
| bx Thumb/IWRAM | 16 | 24 |
| Trivial loop ARM/ROM ... | 230 | 510 |
| Trivial loop ARM/ROM P.. | 230 | 510 |
| Trivial loop ARM/ROM .N. | 230 | 495 |
| Trivial loop ARM/ROM PN. | 230 | 495 |
| Trivial loop ARM/ROM ..S | 230 | 365 |
| Trivial loop ARM/ROM P.S | 230 | 365 |
| Trivial loop ARM/ROM .NS | 230 | 350 |
| Trivial loop ARM/ROM PNS | 230 | 350 |
| Trivial loop ARM/WRAM | 330 | 480 |
| Trivial loop Thumb/ROM ... | 130 | 270 |
| Trivial loop Thumb/ROM P.. | 130 | 270 |
| Trivial loop Thumb/ROM .N. | 130 | 255 |
| Trivial loop Thumb/ROM PN. | 130 | 255 |
| Trivial loop Thumb/ROM ..S | 130 | 205 |
| Trivial loop Thumb/ROM P.S | 130 | 205 |
| Trivial loop Thumb/ROM .NS | 130 | 190 |
| Trivial loop Thumb/ROM PNS | 130 | 190 |
| Trivial loop Thumb/WRAM | 180 | 240 |
| C loop ARM/ROM ... | 173 | 346 |
| C loop ARM/ROM P.. | 173 | 231 |
| C loop ARM/ROM .N. | 173 | 309 |
| C loop ARM/ROM PN. | 173 | 227 |
| C loop ARM/ROM ..S | 173 | 309 |
| C loop ARM/ROM P.S | 173 | 161 |
| C loop ARM/ROM .NS | 173 | 272 |
| C loop ARM/ROM PNS | 173 | 157 |
| C loop ARM/WRAM | 189 | 340 |
| C loop ARM/IWRAM | 149 | 290 |
| C loop Thumb/ROM ... | 163 | 325 |
| C loop Thumb/ROM P.. | 163 | 210 |
| C loop Thumb/ROM .N. | 163 | 288 |
| C loop Thumb/ROM PN. | 163 | 206 |
| C loop Thumb/ROM ..S | 163 | 295 |
| C loop Thumb/ROM P.S | 163 | 147 |
| C loop Thumb/ROM .NS | 163 | 258 |
| C loop Thumb/ROM PNS | 163 | 143 |
| C loop Thumb/WRAM | 174 | 319 |
| C loop Thumb/IWRAM | 151 | 292 |
| BIOS Division ARM/ROM ... | 32 | 398 |
| BIOS Division ARM/ROM P.. | 32 | 398 |
| BIOS Division ARM/ROM .N. | 32 | 394 |
| BIOS Division ARM/ROM PN. | 32 | 394 |
| BIOS Division ARM/ROM ..S | 32 | 381 |
| BIOS Division ARM/ROM P.S | 32 | 381 |
| BIOS Division ARM/ROM .NS | 32 | 377 |
| BIOS Division ARM/ROM PNS | 32 | 377 |
| BIOS Division ARM/WRAM | 48 | 390 |
| BIOS Division ARM/IWRAM | 8 | 338 |
| BIOS Division Thumb/ROM ... | 18 | 371 |
| BIOS Division Thumb/ROM P.. | 18 | 371 |
| BIOS Division Thumb/ROM .N. | 18 | 367 |
| BIOS Division Thumb/ROM PN. | 18 | 367 |
| BIOS Division Thumb/ROM ..S | 18 | 363 |
| BIOS Division Thumb/ROM P.S | 18 | 363 |
| BIOS Division Thumb/ROM .NS | 18 | 359 |
| BIOS Division Thumb/ROM PNS | 18 | 359 |
| BIOS Division Thumb/WRAM | 27 | 363 |
| BIOS Division Thumb/IWRAM | 8 | 338 |
| BIOS Division 2 ARM/ROM ... | 32 | 138 |
| BIOS Division 2 ARM/ROM P.. | 32 | 138 |
| BIOS Division 2 ARM/ROM .N. | 32 | 134 |
| BIOS Division 2 ARM/ROM PN. | 32 | 134 |
| BIOS Division 2 ARM/ROM ..S | 32 | 121 |
| BIOS Division 2 ARM/ROM P.S | 32 | 121 |
| BIOS Division 2 ARM/ROM .NS | 32 | 117 |
| BIOS Division 2 ARM/ROM PNS | 32 | 117 |
| BIOS Division 2 ARM/WRAM | 48 | 130 |
| BIOS Division 2 ARM/IWRAM | 8 | 78 |
| BIOS Division 2 Thumb/ROM ... | 18 | 111 |
| BIOS Division 2 Thumb/ROM P.. | 18 | 111 |
| BIOS Division 2 Thumb/ROM .N. | 18 | 107 |
| BIOS Division 2 Thumb/ROM PN. | 18 | 107 |
| BIOS Division 2 Thumb/ROM ..S | 18 | 103 |
| BIOS Division 2 Thumb/ROM P.S | 18 | 103 |
| BIOS Division 2 Thumb/ROM .NS | 18 | 99 |
| BIOS Division 2 Thumb/ROM PNS | 18 | 99 |
| BIOS Division 2 Thumb/WRAM | 27 | 103 |
| BIOS Division 2 Thumb/IWRAM | 8 | 78 |
| BIOS Sqrt ARM/ROM ... | 24 | 150 |
| BIOS Sqrt ARM/ROM P.. | 24 | 150 |
| BIOS Sqrt ARM/ROM .N. | 24 | 148 |
| BIOS Sqrt ARM/ROM PN. | 24 | 148 |
| BIOS Sqrt ARM/ROM ..S | 24 | 135 |
| BIOS Sqrt ARM/ROM P.S | 24 | 135 |
| BIOS Sqrt ARM/ROM .NS | 24 | 133 |
| BIOS Sqrt ARM/ROM PNS | 24 | 133 |
| BIOS Sqrt ARM/WRAM | 36 | 146 |
| BIOS Sqrt ARM/IWRAM | 6 | 104 |
| BIOS Sqrt Thumb/ROM ... | 12 | 126 |
| BIOS Sqrt Thumb/ROM P.. | 12 | 126 |
| BIOS Sqrt Thumb/ROM .N. | 12 | 124 |
| BIOS Sqrt Thumb/ROM PN. | 12 | 124 |
| BIOS Sqrt Thumb/ROM ..S | 12 | 119 |
| BIOS Sqrt Thumb/ROM P.S | 12 | 119 |
| BIOS Sqrt Thumb/ROM .NS | 12 | 117 |
| BIOS Sqrt Thumb/ROM PNS | 12 | 117 |
| BIOS Sqrt Thumb/WRAM | 18 | 122 |
| BIOS Sqrt Thumb/IWRAM | 6 | 104 |
| BIOS Sqrt 2 ARM/ROM ... | 24 | 265 |
| BIOS Sqrt 2 ARM/ROM P.. | 24 | 265 |
| BIOS Sqrt 2 ARM/ROM .N. | 24 | 263 |
| BIOS Sqrt 2 ARM/ROM PN. | 24 | 263 |
| BIOS Sqrt 2 ARM/ROM ..S | 24 | 250 |
| BIOS Sqrt 2 ARM/ROM P.S | 24 | 250 |
| BIOS Sqrt 2 ARM/ROM .NS | 24 | 248 |
| BIOS Sqrt 2 ARM/ROM PNS | 24 | 248 |
| BIOS Sqrt 2 ARM/WRAM | 36 | 261 |
| BIOS Sqrt 2 ARM/IWRAM | 6 | 219 |
| BIOS Sqrt 2 Thumb/ROM ... | 12 | 241 |
| BIOS Sqrt 2 Thumb/ROM P.. | 12 | 241 |
| BIOS Sqrt 2 Thumb/ROM .N. | 12 | 239 |
| BIOS Sqrt 2 Thumb/ROM PN. | 12 | 239 |
| BIOS Sqrt 2 Thumb/ROM ..S | 12 | 234 |
| BIOS Sqrt 2 Thumb/ROM P.S | 12 | 234 |
| BIOS Sqrt 2 Thumb/ROM .NS | 12 | 232 |
| BIOS Sqrt 2 Thumb/ROM PNS | 12 | 232 |
| BIOS Sqrt 2 Thumb/WRAM | 18 | 237 |
| BIOS Sqrt 2 Thumb/IWRAM | 6 | 219 |
| BIOS Sqrt 3 ARM/ROM ... | 28 | 1192 |
| BIOS Sqrt 3 ARM/ROM P.. | 28 | 1192 |
| BIOS Sqrt 3 ARM/ROM .N. | 28 | 1188 |
| BIOS Sqrt 3 ARM/ROM PN. | 28 | 1188 |
| BIOS Sqrt 3 ARM/ROM ..S | 28 | 1177 |
| BIOS Sqrt 3 ARM/ROM P.S | 28 | 1177 |
| BIOS Sqrt 3 ARM/ROM .NS | 28 | 1173 |
| BIOS Sqrt 3 ARM/ROM PNS | 28 | 1173 |
| BIOS Sqrt 3 ARM/WRAM | 42 | 1184 |
| BIOS Sqrt 3 ARM/IWRAM | 7 | 1137 |
| BIOS Sqrt 3 Thumb/ROM ... | 16 | 1168 |
| BIOS Sqrt 3 Thumb/ROM P.. | 16 | 1168 |
| BIOS Sqrt 3 Thumb/ROM .N. | 16 | 1164 |
| BIOS Sqrt 3 Thumb/ROM PN. | 16 | 1164 |
| BIOS Sqrt 3 Thumb/ROM ..S | 16 | 1161 |
| BIOS Sqrt 3 Thumb/ROM P.S | 16 | 1161 |
| BIOS Sqrt 3 Thumb/ROM .NS | 16 | 1157 |
| BIOS Sqrt 3 Thumb/ROM PNS | 16 | 1157 |
| BIOS Sqrt 3 Thumb/WRAM | 24 | 1160 |
| BIOS Sqrt 3 Thumb/IWRAM | 7 | 1137 |
| BIOS ArcTan ARM/ROM ... | 24 | 150 |
| BIOS ArcTan ARM/ROM P.. | 24 | 150 |
| BIOS ArcTan ARM/ROM .N. | 24 | 148 |
| BIOS ArcTan ARM/ROM PN. | 24 | 148 |
| BIOS ArcTan ARM/ROM ..S | 24 | 135 |
| BIOS ArcTan ARM/ROM P.S | 24 | 135 |
| BIOS ArcTan ARM/ROM .NS | 24 | 133 |
| BIOS ArcTan ARM/ROM PNS | 24 | 133 |
| BIOS ArcTan ARM/WRAM | 36 | 146 |
| BIOS ArcTan ARM/IWRAM | 6 | 104 |
| BIOS ArcTan Thumb/ROM ... | 12 | 126 |
| BIOS ArcTan Thumb/ROM P.. | 12 | 126 |
| BIOS ArcTan Thumb/ROM .N. | 12 | 124 |
| BIOS ArcTan Thumb/ROM PN. | 12 | 124 |
| BIOS ArcTan Thumb/ROM ..S | 12 | 119 |
| BIOS ArcTan Thumb/ROM P.S | 12 | 119 |
| BIOS ArcTan Thumb/ROM .NS | 12 | 117 |
| BIOS ArcTan Thumb/ROM PNS | 12 | 117 |
| BIOS ArcTan Thumb/WRAM | 18 | 122 |
| BIOS ArcTan Thumb/IWRAM | 6 | 104 |
| CpuSet ARM/ROM ... | 3110 | 3453 |
| CpuSet ARM/ROM P.. | 3110 | 3453 |
| CpuSet ARM/ROM .N. | 3110 | 3451 |
| CpuSet ARM/ROM PN. | 3110 | 3451 |
| CpuSet ARM/ROM ..S | 3110 | 3434 |
| CpuSet ARM/ROM P.S | 3110 | 3434 |
| CpuSet ARM/ROM .NS | 3110 | 3432 |
| CpuSet ARM/ROM PNS | 3110 | 3432 |
| CpuSet ARM/WRAM | 3126 | 3449 |
| CpuSet ARM/IWRAM | 3086 | 3397 |
| CpuSet Thumb/ROM ... | 3106 | 3456 |
| CpuSet Thumb/ROM P.. | 3106 | 3456 |
| CpuSet Thumb/ROM .N. | 3106 | 3448 |
| CpuSet Thumb/ROM PN. | 3106 | 3448 |
| CpuSet Thumb/ROM ..S | 3106 | 3447 |
| CpuSet Thumb/ROM P.S | 3106 | 3447 |
| CpuSet Thumb/ROM .NS | 3106 | 3439 |
| CpuSet Thumb/ROM PNS | 3106 | 3439 |
| CpuSet Thumb/WRAM | 3120 | 3440 |
| CpuSet Thumb/IWRAM | 3089 | 3403 |
| Trivial DMA (16) ARM/ROM ... | 7 | 13 |
| Trivial DMA (16) ARM/ROM P.. | 7 | 10 |
| Trivial DMA (16) ARM/ROM .N. | 7 | 12 |
| Trivial DMA (16) ARM/ROM PN. | 7 | 10 |
| Trivial DMA (16) ARM/ROM ..S | 7 | 12 |
| Trivial DMA (16) ARM/ROM P.S | 7 | 8 |
| Trivial DMA (16) ARM/ROM .NS | 7 | 11 |
| Trivial DMA (16) ARM/ROM PNS | 7 | 8 |
| Trivial DMA (16) ARM/WRAM | 9 | 11 |
| Trivial DMA (16) ARM/IWRAM | 4 | 2 |
| Trivial DMA (16) Thumb/ROM ... | 5 | 10 |
| Trivial DMA (16) Thumb/ROM P.. | 5 | 7 |
| Trivial DMA (16) Thumb/ROM .N. | 5 | 9 |
| Trivial DMA (16) Thumb/ROM PN. | 5 | 7 |
| Trivial DMA (16) Thumb/ROM ..S | 5 | 10 |
| Trivial DMA (16) Thumb/ROM P.S | 5 | 2 |
| Trivial DMA (16) Thumb/ROM .NS | 5 | 9 |
| Trivial DMA (16) Thumb/ROM PNS | 5 | 2 |
| Trivial DMA (16) Thumb/WRAM | 6 | 8 |
| Trivial DMA (16) Thumb/IWRAM | 4 | 2 |
| Trivial DMA (16/ROM) ARM/ROM ... | 8 | 17 |
| Trivial DMA (16/ROM) ARM/ROM P.. | 8 | 14 |
| Trivial DMA (16/ROM) ARM/ROM .N. | 8 | 15 |
| Trivial DMA (16/ROM) ARM/ROM PN. | 8 | 13 |
| Trivial DMA (16/ROM) ARM/ROM ..S | 8 | 16 |
| Trivial DMA (16/ROM) ARM/ROM P.S | 8 | 13 |
| Trivial DMA (16/ROM) ARM/ROM .NS | 8 | 14 |
| Trivial DMA (16/ROM) ARM/ROM PNS | 8 | 12 |
| Trivial DMA (16/ROM) ARM/WRAM | 10 | 15 |
| Trivial DMA (16/ROM) ARM/IWRAM | 5 | 2 |
| Trivial DMA (16/ROM) Thumb/ROM ... | 6 | 14 |
| Trivial DMA (16/ROM) Thumb/ROM P.. | 6 | 11 |
| Trivial DMA (16/ROM) Thumb/ROM .N. | 6 | 12 |
| Trivial DMA (16/ROM) Thumb/ROM PN. | 6 | 10 |
| Trivial DMA (16/ROM) Thumb/ROM ..S | 6 | 14 |
| Trivial DMA (16/ROM) Thumb/ROM P.S | 6 | 2 |
| Trivial DMA (16/ROM) Thumb/ROM .NS | 6 | 12 |
| Trivial DMA (16/ROM) Thumb/ROM PNS | 6 | 2 |
| Trivial DMA (16/ROM) Thumb/WRAM | 7 | 12 |
| Trivial DMA (16/ROM) Thumb/IWRAM | 5 | 2 |
| Trivial DMA (16/to ROM) ARM/ROM ... | 8 | 17 |
| Trivial DMA (16/to ROM) ARM/ROM P.. | 8 | 15 |
| Trivial DMA (16/to ROM) ARM/ROM .N. | 8 | 15 |
| Trivial DMA (16/to ROM) ARM/ROM PN. | 8 | 14 |
| Trivial DMA (16/to ROM) ARM/ROM ..S | 8 | 16 |
| Trivial DMA (16/to ROM) ARM/ROM P.S | 8 | 12 |
| Trivial DMA (16/to ROM) ARM/ROM .NS | 8 | 14 |
| Trivial DMA (16/to ROM) ARM/ROM PNS | 8 | 11 |
| Trivial DMA (16/to ROM) ARM/WRAM | 10 | 15 |
| Trivial DMA (16/to ROM) ARM/IWRAM | 5 | 2 |
| Trivial DMA (16/to ROM) Thumb/ROM ... | 6 | 14 |
| Trivial DMA (16/to ROM) Thumb/ROM P.. | 6 | 12 |
| Trivial DMA (16/to ROM) Thumb/ROM .N. | 6 | 12 |
| Trivial DMA (16/to ROM) Thumb/ROM PN. | 6 | 11 |
| Trivial DMA (16/to ROM) Thumb/ROM ..S | 6 | 14 |
| Trivial DMA (16/to ROM) Thumb/ROM P.S | 6 | 2 |
| Trivial DMA (16/to ROM) Thumb/ROM .NS | 6 | 12 |
| Trivial DMA (16/to ROM) Thumb/ROM PNS | 6 | 2 |
| Trivial DMA (16/to ROM) Thumb/WRAM | 7 | 12 |
| Trivial DMA (16/to ROM) Thumb/IWRAM | 5 | 2 |
| Trivial DMA (16/ROM to ROM) ARM/ROM ... | 9 | 19 |
| Trivial DMA (16/ROM to ROM) ARM/ROM P.. | 9 | 16 |
| Trivial DMA (16/ROM to ROM) ARM/ROM .N. | 9 | 17 |
| Trivial DMA (16/ROM to ROM) ARM/ROM PN. | 9 | 15 |
| Trivial DMA (16/ROM to ROM) ARM/ROM ..S | 9 | 17 |
| Trivial DMA (16/ROM to ROM) ARM/ROM P.S | 9 | 14 |
| Trivial DMA (16/ROM to ROM) ARM/ROM .NS | 9 | 15 |
| Trivial DMA (16/ROM to ROM) ARM/ROM PNS | 9 | 13 |
| Trivial DMA (16/ROM to ROM) ARM/WRAM | 11 | 17 |
| Trivial DMA (16/ROM to ROM) ARM/IWRAM | 6 | 2 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM ... | 7 | 16 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM P.. | 7 | 13 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM .N. | 7 | 14 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM PN. | 7 | 12 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM ..S | 7 | 15 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM P.S | 7 | 2 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM .NS | 7 | 13 |
| Trivial DMA (16/ROM to ROM) Thumb/ROM PNS | 7 | 2 |
| Trivial DMA (16/ROM to ROM) Thumb/WRAM | 8 | 14 |
| Trivial DMA (16/ROM to ROM) Thumb/IWRAM | 6 | 2 |
| Trivial DMA (32) ARM/ROM ... | 7 | 13 |
| Trivial DMA (32) ARM/ROM P.. | 7 | 10 |
| Trivial DMA (32) ARM/ROM .N. | 7 | 12 |
| Trivial DMA (32) ARM/ROM PN. | 7 | 10 |
| Trivial DMA (32) ARM/ROM ..S | 7 | 12 |
| Trivial DMA (32) ARM/ROM P.S | 7 | 8 |
| Trivial DMA (32) ARM/ROM .NS | 7 | 11 |
| Trivial DMA (32) ARM/ROM PNS | 7 | 8 |
| Trivial DMA (32) ARM/WRAM | 9 | 11 |
| Trivial DMA (32) ARM/IWRAM | 4 | 2 |
| Trivial DMA (32) Thumb/ROM ... | 5 | 10 |
| Trivial DMA (32) Thumb/ROM P.. | 5 | 7 |
| Trivial DMA (32) Thumb/ROM .N. | 5 | 9 |
| Trivial DMA (32) Thumb/ROM PN. | 5 | 7 |
| Trivial DMA (32) Thumb/ROM ..S | 5 | 10 |
| Trivial DMA (32) Thumb/ROM P.S | 5 | 2 |
| Trivial DMA (32) Thumb/ROM .NS | 5 | 9 |
| Trivial DMA (32) Thumb/ROM PNS | 5 | 2 |
| Trivial DMA (32) Thumb/WRAM | 6 | 8 |
| Trivial DMA (32) Thumb/IWRAM | 4 | 2 |
| Trivial DMA (32/from ROM) ARM/ROM ... | 10 | 20 |
| Trivial DMA (32/from ROM) ARM/ROM P.. | 10 | 17 |
| Trivial DMA (32/from ROM) ARM/ROM .N. | 10 | 18 |
| Trivial DMA (32/from ROM) ARM/ROM PN. | 10 | 16 |
| Trivial DMA (32/from ROM) ARM/ROM ..S | 10 | 18 |
| Trivial DMA (32/from ROM) ARM/ROM P.S | 10 | 15 |
| Trivial DMA (32/from ROM) ARM/ROM .NS | 10 | 16 |
| Trivial DMA (32/from ROM) ARM/ROM PNS | 10 | 14 |
| Trivial DMA (32/from ROM) ARM/WRAM | 12 | 18 |
| Trivial DMA (32/from ROM) ARM/IWRAM | 7 | 2 |
| Trivial DMA (32/from ROM) Thumb/ROM ... | 8 | 17 |
| Trivial DMA (32/from ROM) Thumb/ROM P.. | 8 | 14 |
| Trivial DMA (32/from ROM) Thumb/ROM .N. | 8 | 15 |
| Trivial DMA (32/from ROM) Thumb/ROM PN. | 8 | 13 |
| Trivial DMA (32/from ROM) Thumb/ROM ..S | 8 | 16 |
| Trivial DMA (32/from ROM) Thumb/ROM P.S | 8 | 2 |
| Trivial DMA (32/from ROM) Thumb/ROM .NS | 8 | 14 |
| Trivial DMA (32/from ROM) Thumb/ROM PNS | 8 | 2 |
| Trivial DMA (32/from ROM) Thumb/WRAM | 9 | 15 |
| Trivial DMA (32/from ROM) Thumb/IWRAM | 7 | 2 |
| Trivial DMA (32/to ROM) ARM/ROM ... | 10 | 20 |
| Trivial DMA (32/to ROM) ARM/ROM P.. | 10 | 18 |
| Trivial DMA (32/to ROM) ARM/ROM .N. | 10 | 18 |
| Trivial DMA (32/to ROM) ARM/ROM PN. | 10 | 17 |
| Trivial DMA (32/to ROM) ARM/ROM ..S | 10 | 18 |
| Trivial DMA (32/to ROM) ARM/ROM P.S | 10 | 14 |
| Trivial DMA (32/to ROM) ARM/ROM .NS | 10 | 16 |
| Trivial DMA (32/to ROM) ARM/ROM PNS | 10 | 13 |
| Trivial DMA (32/to ROM) ARM/WRAM | 12 | 18 |
| Trivial DMA (32/to ROM) ARM/IWRAM | 7 | 2 |
| Trivial DMA (32/to ROM) Thumb/ROM ... | 8 | 17 |
| Trivial DMA (32/to ROM) Thumb/ROM P.. | 8 | 15 |
| Trivial DMA (32/to ROM) Thumb/ROM .N. | 8 | 15 |
| Trivial DMA (32/to ROM) Thumb/ROM PN. | 8 | 14 |
| Trivial DMA (32/to ROM) Thumb/ROM ..S | 8 | 16 |
| Trivial DMA (32/to ROM) Thumb/ROM P.S | 8 | 2 |
| Trivial DMA (32/to ROM) Thumb/ROM .NS | 8 | 14 |
| Trivial DMA (32/to ROM) Thumb/ROM PNS | 8 | 2 |
| Trivial DMA (32/to ROM) Thumb/WRAM | 9 | 15 |
| Trivial DMA (32/to ROM) Thumb/IWRAM | 7 | 2 |
| Trivial DMA (32/ROM to ROM) ARM/ROM ... | 13 | 25 |
| Trivial DMA (32/ROM to ROM) ARM/ROM P.. | 13 | 22 |
| Trivial DMA (32/ROM to ROM) ARM/ROM .N. | 13 | 23 |
| Trivial DMA (32/ROM to ROM) ARM/ROM PN. | 13 | 21 |
| Trivial DMA (32/ROM to ROM) ARM/ROM ..S | 13 | 21 |
| Trivial DMA (32/ROM to ROM) ARM/ROM P.S | 13 | 18 |
| Trivial DMA (32/ROM to ROM) ARM/ROM .NS | 13 | 19 |
| Trivial DMA (32/ROM to ROM) ARM/ROM PNS | 13 | 17 |
| Trivial DMA (32/ROM to ROM) ARM/WRAM | 15 | 23 |
| Trivial DMA (32/ROM to ROM) ARM/IWRAM | 10 | 2 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM ... | 11 | 22 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM P.. | 11 | 19 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM .N. | 11 | 20 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM PN. | 11 | 18 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM ..S | 11 | 19 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM P.S | 11 | 2 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM .NS | 11 | 17 |
| Trivial DMA (32/ROM to ROM) Thumb/ROM PNS | 11 | 2 |
| Trivial DMA (32/ROM to ROM) Thumb/WRAM | 12 | 20 |
| Trivial DMA (32/ROM to ROM) Thumb/IWRAM | 10 | 2 |
| Short DMA (16) ARM/ROM ... | 37 | 43 |
| Short DMA (16) ARM/ROM P.. | 37 | 40 |
| Short DMA (16) ARM/ROM .N. | 37 | 42 |
| Short DMA (16) ARM/ROM PN. | 37 | 40 |
| Short DMA (16) ARM/ROM ..S | 37 | 42 |
| Short DMA (16) ARM/ROM P.S | 37 | 38 |
| Short DMA (16) ARM/ROM .NS | 37 | 41 |
| Short DMA (16) ARM/ROM PNS | 37 | 38 |
| Short DMA (16) ARM/WRAM | 39 | 41 |
| Short DMA (16) ARM/IWRAM | 34 | 2 |
| Short DMA (16) Thumb/ROM ... | 35 | 40 |
| Short DMA (16) Thumb/ROM P.. | 35 | 37 |
| Short DMA (16) Thumb/ROM .N. | 35 | 39 |
| Short DMA (16) Thumb/ROM PN. | 35 | 37 |
| Short DMA (16) Thumb/ROM ..S | 35 | 40 |
| Short DMA (16) Thumb/ROM P.S | 35 | 2 |
| Short DMA (16) Thumb/ROM .NS | 35 | 39 |
| Short DMA (16) Thumb/ROM PNS | 35 | 2 |
| Short DMA (16) Thumb/WRAM | 36 | 38 |
| Short DMA (16) Thumb/IWRAM | 34 | 2 |
| Short DMA (16/from ROM) ARM/ROM ... | 53 | 77 |
| Short DMA (16/from ROM) ARM/ROM P.. | 53 | 74 |
| Short DMA (16/from ROM) ARM/ROM .N. | 53 | 75 |
| Short DMA (16/from ROM) ARM/ROM PN. | 53 | 73 |
| Short DMA (16/from ROM) ARM/ROM ..S | 53 | 61 |
| Short DMA (16/from ROM) ARM/ROM P.S | 53 | 58 |
| Short DMA (16/from ROM) ARM/ROM .NS | 53 | 59 |
| Short DMA (16/from ROM) ARM/ROM PNS | 53 | 57 |
| Short DMA (16/from ROM) ARM/WRAM | 55 | 75 |
| Short DMA (16/from ROM) ARM/IWRAM | 50 | 2 |
| Short DMA (16/from ROM) Thumb/ROM ... | 51 | 74 |
| Short DMA (16/from ROM) Thumb/ROM P.. | 51 | 71 |
| Short DMA (16/from ROM) Thumb/ROM .N. | 51 | 72 |
| Short DMA (16/from ROM) Thumb/ROM PN. | 51 | 70 |
| Short DMA (16/from ROM) Thumb/ROM ..S | 51 | 59 |
| Short DMA (16/from ROM) Thumb/ROM P.S | 51 | 2 |
| Short DMA (16/from ROM) Thumb/ROM .NS | 51 | 57 |
| Short DMA (16/from ROM) Thumb/ROM PNS | 51 | 2 |
| Short DMA (16/from ROM) Thumb/WRAM | 52 | 72 |
| Short DMA (16/from ROM) Thumb/IWRAM | 50 | 2 |
| Short DMA (16/to ROM) ARM/ROM ... | 53 | 77 |
| Short DMA (16/to ROM) ARM/ROM P.. | 53 | 75 |
| Short DMA (16/to ROM) ARM/ROM .N. | 53 | 75 |
| Short DMA (16/to ROM) ARM/ROM PN. | 53 | 74 |
| Short DMA (16/to ROM) ARM/ROM ..S | 53 | 61 |
| Short DMA (16/to ROM) ARM/ROM P.S | 53 | 57 |
| Short DMA (16/to ROM) ARM/ROM .NS | 53 | 59 |
| Short DMA (16/to ROM) ARM/ROM PNS | 53 | 56 |
| Short DMA (16/to ROM) ARM/WRAM | 55 | 75 |
| Short DMA (16/to ROM) ARM/IWRAM | 50 | 2 |
| Short DMA (16/to ROM) Thumb/ROM ... | 51 | 74 |
| Short DMA (16/to ROM) Thumb/ROM P.. | 51 | 72 |
| Short DMA (16/to ROM) Thumb/ROM .N. | 51 | 72 |
| Short DMA (16/to ROM) Thumb/ROM PN. | 51 | 71 |
| Short DMA (16/to ROM) Thumb/ROM ..S | 51 | 59 |
| Short DMA (16/to ROM) Thumb/ROM P.S | 51 | 2 |
| Short DMA (16/to ROM) Thumb/ROM .NS | 51 | 57 |
| Short DMA (16/to ROM) Thumb/ROM PNS | 51 | 2 |
| Short DMA (16/to ROM) Thumb/WRAM | 52 | 72 |
| Short DMA (16/to ROM) Thumb/IWRAM | 50 | 2 |
| Short DMA (16/ROM to ROM) ARM/ROM ... | 69 | 109 |
| Short DMA (16/ROM to ROM) ARM/ROM P.. | 69 | 106 |
| Short DMA (16/ROM to ROM) ARM/ROM .N. | 69 | 107 |
| Short DMA (16/ROM to ROM) ARM/ROM PN. | 69 | 105 |
| Short DMA (16/ROM to ROM) ARM/ROM ..S | 69 | 77 |
| Short DMA (16/ROM to ROM) ARM/ROM P.S | 69 | 74 |
| Short DMA (16/ROM to ROM) ARM/ROM .NS | 69 | 75 |
| Short DMA (16/ROM to ROM) ARM/ROM PNS | 69 | 73 |
| Short DMA (16/ROM to ROM) ARM/WRAM | 71 | 107 |
| Short DMA (16/ROM to ROM) ARM/IWRAM | 66 | 2 |
| Short DMA (16/ROM to ROM) Thumb/ROM ... | 67 | 106 |
| Short DMA (16/ROM to ROM) Thumb/ROM P.. | 67 | 103 |
| Short DMA (16/ROM to ROM) Thumb/ROM .N. | 67 | 104 |
| Short DMA (16/ROM to ROM) Thumb/ROM PN. | 67 | 102 |
| Short DMA (16/ROM to ROM) Thumb/ROM ..S | 67 | 75 |
| Short DMA (16/ROM to ROM) Thumb/ROM P.S | 67 | 2 |
| Short DMA (16/ROM to ROM) Thumb/ROM .NS | 67 | 73 |
| Short DMA (16/ROM to ROM) Thumb/ROM PNS | 67 | 2 |
| Short DMA (16/ROM to ROM) Thumb/WRAM | 68 | 104 |
| Short DMA (16/ROM to ROM) Thumb/IWRAM | 66 | 2 |
| Short DMA (32) ARM/ROM ... | 37 | 43 |
| Short DMA (32) ARM/ROM P.. | 37 | 40 |
| Short DMA (32) ARM/ROM .N. | 37 | 42 |
| Short DMA (32) ARM/ROM PN. | 37 | 40 |
| Short DMA (32) ARM/ROM ..S | 37 | 42 |
| Short DMA (32) ARM/ROM P.S | 37 | 38 |
| Short DMA (32) ARM/ROM .NS | 37 | 41 |
| Short DMA (32) ARM/ROM PNS | 37 | 38 |
| Short DMA (32) ARM/WRAM | 39 | 41 |
| Short DMA (32) ARM/IWRAM | 34 | 2 |
| Short DMA (32) Thumb/ROM ... | 35 | 40 |
| Short DMA (32) Thumb/ROM P.. | 35 | 37 |
| Short DMA (32) Thumb/ROM .N. | 35 | 39 |
| Short DMA (32) Thumb/ROM PN. | 35 | 37 |
| Short DMA (32) Thumb/ROM ..S | 35 | 40 |
| Short DMA (32) Thumb/ROM P.S | 35 | 2 |
| Short DMA (32) Thumb/ROM .NS | 35 | 39 |
| Short DMA (32) Thumb/ROM PNS | 35 | 2 |
| Short DMA (32) Thumb/WRAM | 36 | 38 |
| Short DMA (32) Thumb/IWRAM | 34 | 2 |
| Short DMA (32/from ROM) ARM/ROM ... | 85 | 125 |
| Short DMA (32/from ROM) ARM/ROM P.. | 85 | 122 |
| Short DMA (32/from ROM) ARM/ROM .N. | 85 | 123 |
| Short DMA (32/from ROM) ARM/ROM PN. | 85 | 121 |
| Short DMA (32/from ROM) ARM/ROM ..S | 85 | 93 |
| Short DMA (32/from ROM) ARM/ROM P.S | 85 | 90 |
| Short DMA (32/from ROM) ARM/ROM .NS | 85 | 91 |
| Short DMA (32/from ROM) ARM/ROM PNS | 85 | 89 |
| Short DMA (32/from ROM) ARM/WRAM | 87 | 123 |
| Short DMA (32/from ROM) ARM/IWRAM | 82 | 2 |
| Short DMA (32/from ROM) Thumb/ROM ... | 83 | 122 |
| Short DMA (32/from ROM) Thumb/ROM P.. | 83 | 119 |
| Short DMA (32/from ROM) Thumb/ROM .N. | 83 | 120 |
| Short DMA (32/from ROM) Thumb/ROM PN. | 83 | 118 |
| Short DMA (32/from ROM) Thumb/ROM ..S | 83 | 91 |
| Short DMA (32/from ROM) Thumb/ROM P.S | 83 | 2 |
| Short DMA (32/from ROM) Thumb/ROM .NS | 83 | 89 |
| Short DMA (32/from ROM) Thumb/ROM PNS | 83 | 2 |
| Short DMA (32/from ROM) Thumb/WRAM | 84 | 120 |
| Short DMA (32/from ROM) Thumb/IWRAM | 82 | 2 |
| Short DMA (32/to ROM) ARM/ROM ... | 85 | 125 |
| Short DMA (32/to ROM) ARM/ROM P.. | 85 | 123 |
| Short DMA (32/to ROM) ARM/ROM .N. | 85 | 123 |
| Short DMA (32/to ROM) ARM/ROM PN. | 85 | 122 |
| Short DMA (32/to ROM) ARM/ROM ..S | 85 | 93 |
| Short DMA (32/to ROM) ARM/ROM P.S | 85 | 89 |
| Short DMA (32/to ROM) ARM/ROM .NS | 85 | 91 |
| Short DMA (32/to ROM) ARM/ROM PNS | 85 | 88 |
| Short DMA (32/to ROM) ARM/WRAM | 87 | 123 |
| Short DMA (32/to ROM) ARM/IWRAM | 82 | 2 |
| Short DMA (32/to ROM) Thumb/ROM ... | 83 | 122 |
| Short DMA (32/to ROM) Thumb/ROM P.. | 83 | 120 |
| Short DMA (32/to ROM) Thumb/ROM .N. | 83 | 120 |
| Short DMA (32/to ROM) Thumb/ROM PN. | 83 | 119 |
| Short DMA (32/to ROM) Thumb/ROM ..S | 83 | 91 |
| Short DMA (32/to ROM) Thumb/ROM P.S | 83 | 2 |
| Short DMA (32/to ROM) Thumb/ROM .NS | 83 | 89 |
| Short DMA (32/to ROM) Thumb/ROM PNS | 83 | 2 |
| Short DMA (32/to ROM) Thumb/WRAM | 84 | 120 |
| Short DMA (32/to ROM) Thumb/IWRAM | 82 | 2 |
| Short DMA (32/ROM to ROM) ARM/ROM ... | 133 | 205 |
| Short DMA (32/ROM to ROM) ARM/ROM P.. | 133 | 202 |
| Short DMA (32/ROM to ROM) ARM/ROM .N. | 133 | 203 |
| Short DMA (32/ROM to ROM) ARM/ROM PN. | 133 | 201 |
| Short DMA (32/ROM to ROM) ARM/ROM ..S | 133 | 141 |
| Short DMA (32/ROM to ROM) ARM/ROM P.S | 133 | 138 |
| Short DMA (32/ROM to ROM) ARM/ROM .NS | 133 | 139 |
| Short DMA (32/ROM to ROM) ARM/ROM PNS | 133 | 137 |
| Short DMA (32/ROM to ROM) ARM/WRAM | 135 | 203 |
| Short DMA (32/ROM to ROM) ARM/IWRAM | 130 | 2 |
| Short DMA (32/ROM to ROM) Thumb/ROM ... | 131 | 202 |
| Short DMA (32/ROM to ROM) Thumb/ROM P.. | 131 | 199 |
| Short DMA (32/ROM to ROM) Thumb/ROM .N. | 131 | 200 |
| Short DMA (32/ROM to ROM) Thumb/ROM PN. | 131 | 198 |
| Short DMA (32/ROM to ROM) Thumb/ROM ..S | 131 | 139 |
| Short DMA (32/ROM to ROM) Thumb/ROM P.S | 131 | 2 |
| Short DMA (32/ROM to ROM) Thumb/ROM .NS | 131 | 137 |
| Short DMA (32/ROM to ROM) Thumb/ROM PNS | 131 | 2 |
| Short DMA (32/ROM to ROM) Thumb/WRAM | 132 | 200 |
| Short DMA (32/ROM to ROM) Thumb/IWRAM | 130 | 2 |

## Timer count-up tests (339/936 passed)

339/936 tests passed, 597 failed:

| Test | Actual | Expected |
|------|--------|----------|
| 0b, 0x0001 1xs 1d 1i | 00000001 | 00000002 |
| 0b, 0x0001 1xs 2d 1i | 00000001 | 00000002 |
| 0b, 0x0001 1xs 4d 1i | 00000001 | 00000002 |
| 0b, 0x0001 1xs 1d 2i | 00000001 | 00000002 |
| 0b, 0x0001 1xs 2d 2i | 00000001 | 00000002 |
| 0b, 0x0001 1xs 4d 2i | 00000001 | 00000002 |
| 0b, 0x0001 1xs 1d 4i | 00000001 | 00000002 |
| 0b, 0x0001 1xs 2d 4i | 00000001 | 00000002 |
| 0b, 0x0001 1xs 4d 4i | 00000001 | 00000002 |
| 0b, 0x0005 1xs 1d 1i | 00000002 | 00000003 |
| 0b, 0x0005 1xv 1d 1i | FFFD | FFFF |
| 0b, 0x0005 1xs 2d 1i | 00000002 | 00000003 |
| 0b, 0x0005 1xv 2d 1i | FFFD | FFFF |
| 0b, 0x0005 1xs 4d 1i | 00000002 | 00000003 |
| 0b, 0x0005 1xv 4d 1i | FFFD | FFFF |
| 0b, 0x0005 1xs 1d 2i | 00000002 | 00000003 |
| 0b, 0x0005 1xv 1d 2i | FFFD | FFFB |
| 0b, 0x0005 16xv 1d 2i | FFFD | FFFE |
| 0b, 0x0005 1xs 2d 2i | 00000002 | 00000003 |
| 0b, 0x0005 1xv 2d 2i | FFFD | FFFB |
| 0b, 0x0005 16xv 2d 2i | FFFD | FFFE |
| 0b, 0x0005 1xs 4d 2i | 00000002 | 00000003 |
| 0b, 0x0005 1xv 4d 2i | FFFD | FFFB |
| 0b, 0x0005 16xv 4d 2i | FFFD | FFFE |
| 0b, 0x0005 1xs 1d 4i | 00000002 | 00000003 |
| 0b, 0x0005 16xv 1d 4i | FFFD | FFFB |
| 0b, 0x0005 1xs 2d 4i | 00000002 | 00000003 |
| 0b, 0x0005 16xv 2d 4i | FFFD | FFFB |
| 0b, 0x0005 1xs 4d 4i | 00000002 | 00000003 |
| 0b, 0x0005 16xv 4d 4i | FFFD | FFFB |
| 0b, 0x000C 16xs 1d 1i | 00000010 | 00000020 |
| 0b, 0x000C 1xv 1d 1i | FFF4 | FFFC |
| 0b, 0x000C 16xv 1d 1i | FFF4 | FFFE |
| 0b, 0x000C 16xs 2d 1i | 00000010 | 00000020 |
| 0b, 0x000C 1xv 2d 1i | FFF4 | FFFC |
| 0b, 0x000C 16xv 2d 1i | FFF4 | FFFE |
| 0b, 0x000C 16xs 4d 1i | 00000010 | 00000020 |
| 0b, 0x000C 1xv 4d 1i | FFF4 | FFFC |
| 0b, 0x000C 16xv 4d 1i | FFF4 | FFFE |
| 0b, 0x000C 16xs 1d 2i | 00000010 | 00000020 |
| 0b, 0x000C 16xv 1d 2i | FFFD | FFFF |
| 0b, 0x000C 16xs 2d 2i | 00000010 | 00000020 |
| 0b, 0x000C 16xv 2d 2i | FFFD | FFFF |
| 0b, 0x000C 16xs 4d 2i | 00000010 | 00000020 |
| 0b, 0x000C 16xv 4d 2i | FFFD | FFFF |
| 0b, 0x000C 16xs 1d 4i | 00000010 | 00000020 |
| 0b, 0x000C 1xv 1d 4i | FFF7 | FFFF |
| 0b, 0x000C 16xv 1d 4i | FFF7 | FFF5 |
| 0b, 0x000C 16xs 2d 4i | 00000010 | 00000020 |
| 0b, 0x000C 1xv 2d 4i | FFF7 | FFFF |
| 0b, 0x000C 16xv 2d 4i | FFF7 | FFF5 |
| 0b, 0x000C 16xs 4d 4i | 00000010 | 00000020 |
| 0b, 0x000C 1xv 4d 4i | FFF7 | FFFF |
| 0b, 0x000C 16xv 4d 4i | FFF7 | FFF5 |
| 0b, 0x000D 1xs 1d 1i | 00000003 | 00000004 |
| 0b, 0x000D 16xs 1d 1i | 00000010 | 00000020 |
| 0b, 0x000D 1xv 1d 1i | FFFA | FFF6 |
| 0b, 0x000D 16xv 1d 1i | FFFA | FFF5 |
| 0b, 0x000D 1xs 2d 1i | 00000003 | 00000004 |
| 0b, 0x000D 16xs 2d 1i | 00000010 | 00000020 |
| 0b, 0x000D 1xv 2d 1i | FFFA | FFF6 |
| 0b, 0x000D 16xv 2d 1i | FFFA | FFF5 |
| 0b, 0x000D 1xs 4d 1i | 00000003 | 00000004 |
| 0b, 0x000D 16xs 4d 1i | 00000010 | 00000020 |
| 0b, 0x000D 1xv 4d 1i | FFFA | FFF6 |
| 0b, 0x000D 16xv 4d 1i | FFFA | FFF5 |
| 0b, 0x000D 1xs 1d 2i | 00000003 | 00000004 |
| 0b, 0x000D 16xs 1d 2i | 00000010 | 00000020 |
| 0b, 0x000D 1xv 1d 2i | FFFB | FFFA |
| 0b, 0x000D 16xv 1d 2i | FFFB | FFF9 |
| 0b, 0x000D 1xs 2d 2i | 00000003 | 00000004 |
| 0b, 0x000D 16xs 2d 2i | 00000010 | 00000020 |
| 0b, 0x000D 1xv 2d 2i | FFFB | FFFA |
| 0b, 0x000D 16xv 2d 2i | FFFB | FFF9 |
| 0b, 0x000D 1xs 4d 2i | 00000003 | 00000004 |
| 0b, 0x000D 16xs 4d 2i | 00000010 | 00000020 |
| 0b, 0x000D 1xv 4d 2i | FFFB | FFFA |
| 0b, 0x000D 16xv 4d 2i | FFFB | FFF9 |
| 0b, 0x000D 1xs 1d 4i | 00000003 | 00000004 |
| 0b, 0x000D 16xs 1d 4i | 00000010 | 00000020 |
| 0b, 0x000D 1xv 1d 4i | FFFD | FFF5 |
| 0b, 0x000D 16xv 1d 4i | FFFD | FFF4 |
| 0b, 0x000D 1xs 2d 4i | 00000003 | 00000004 |
| 0b, 0x000D 16xs 2d 4i | 00000010 | 00000020 |
| 0b, 0x000D 1xv 2d 4i | FFFD | FFF5 |
| 0b, 0x000D 16xv 2d 4i | FFFD | FFF4 |
| 0b, 0x000D 1xs 4d 4i | 00000003 | 00000004 |
| 0b, 0x000D 16xs 4d 4i | 00000010 | 00000020 |
| 0b, 0x000D 1xv 4d 4i | FFFD | FFF5 |
| 0b, 0x000D 16xv 4d 4i | FFFD | FFF4 |
| 0b, 0x0010 1xs 1d 1i | 00000003 | 00000004 |
| 0b, 0x0010 16xs 1d 1i | 00000010 | 00000020 |
| 0b, 0x0010 1xv 1d 1i | FFF8 | FFFC |
| 0b, 0x0010 16xv 1d 1i | FFF8 | FFFE |
| 0b, 0x0010 1xs 2d 1i | 00000003 | 00000004 |
| 0b, 0x0010 16xs 2d 1i | 00000010 | 00000020 |
| 0b, 0x0010 1xv 2d 1i | FFF8 | FFFC |
| 0b, 0x0010 16xv 2d 1i | FFF8 | FFFE |
| 0b, 0x0010 1xs 4d 1i | 00000003 | 00000004 |
| 0b, 0x0010 16xs 4d 1i | 00000010 | 00000020 |
| 0b, 0x0010 1xv 4d 1i | FFF8 | FFFC |
| 0b, 0x0010 16xv 4d 1i | FFF8 | FFFE |
| 0b, 0x0010 1xs 1d 2i | 00000003 | 00000004 |
| 0b, 0x0010 16xs 1d 2i | 00000010 | 00000020 |
| 0b, 0x0010 1xv 1d 2i | FFF1 | FFF5 |
| 0b, 0x0010 16xv 1d 2i | FFF1 | FFF7 |
| 0b, 0x0010 1xs 2d 2i | 00000003 | 00000004 |
| 0b, 0x0010 16xs 2d 2i | 00000010 | 00000020 |
| 0b, 0x0010 1xv 2d 2i | FFF1 | FFF5 |
| 0b, 0x0010 16xv 2d 2i | FFF1 | FFF7 |
| 0b, 0x0010 1xs 4d 2i | 00000003 | 00000004 |
| 0b, 0x0010 16xs 4d 2i | 00000010 | 00000020 |
| 0b, 0x0010 1xv 4d 2i | FFF1 | FFF5 |
| 0b, 0x0010 16xv 4d 2i | FFF1 | FFF7 |
| 0b, 0x0010 1xs 1d 4i | 00000003 | 00000004 |
| 0b, 0x0010 16xs 1d 4i | 00000010 | 00000020 |
| 0b, 0x0010 1xv 1d 4i | FFF3 | FFF7 |
| 0b, 0x0010 16xv 1d 4i | FFF3 | FFF9 |
| 0b, 0x0010 1xs 2d 4i | 00000003 | 00000004 |
| 0b, 0x0010 16xs 2d 4i | 00000010 | 00000020 |
| 0b, 0x0010 1xv 2d 4i | FFF3 | FFF7 |
| 0b, 0x0010 16xv 2d 4i | FFF3 | FFF9 |
| 0b, 0x0010 1xs 4d 4i | 00000003 | 00000004 |
| 0b, 0x0010 16xs 4d 4i | 00000010 | 00000020 |
| 0b, 0x0010 1xv 4d 4i | FFF3 | FFF7 |
| 0b, 0x0010 16xv 4d 4i | FFF3 | FFF9 |
| 0b, 0x0014 1xv 1d 2i | FFFD | FFF9 |
| 0b, 0x0014 16xv 1d 2i | FFFD | FFF9 |
| 0b, 0x0014 1xv 2d 2i | FFFD | FFF9 |
| 0b, 0x0014 16xv 2d 2i | FFFD | FFF9 |
| 0b, 0x0014 1xv 4d 2i | FFFD | FFF9 |
| 0b, 0x0014 16xv 4d 2i | FFFD | FFF9 |
| 0b, 0x0014 1xv 1d 4i | FFF3 | FFFB |
| 0b, 0x0014 16xv 1d 4i | FFF3 | FFFB |
| 0b, 0x0014 1xv 2d 4i | FFF3 | FFFB |
| 0b, 0x0014 16xv 2d 4i | FFF3 | FFFB |
| 0b, 0x0014 1xv 4d 4i | FFF3 | FFFB |
| 0b, 0x0014 16xv 4d 4i | FFF3 | FFFB |
| 0b, 0x0015 1xs 1d 1i | 00000004 | 00000005 |
| 0b, 0x0015 1xv 1d 1i | FFF6 | FFF5 |
| 0b, 0x0015 16xv 1d 1i | FFF4 | FFF3 |
| 0b, 0x0015 1xs 2d 1i | 00000004 | 00000005 |
| 0b, 0x0015 1xv 2d 1i | FFF6 | FFF5 |
| 0b, 0x0015 16xv 2d 1i | FFF4 | FFF3 |
| 0b, 0x0015 1xs 4d 1i | 00000004 | 00000005 |
| 0b, 0x0015 1xv 4d 1i | FFF6 | FFF5 |
| 0b, 0x0015 16xv 4d 1i | FFF4 | FFF3 |
| 0b, 0x0015 1xs 1d 2i | 00000004 | 00000005 |
| 0b, 0x0015 1xv 1d 2i | FFF6 | FFF0 |
| 0b, 0x0015 16xv 1d 2i | FFF4 | FFEE |
| 0b, 0x0015 1xs 2d 2i | 00000004 | 00000005 |
| 0b, 0x0015 1xv 2d 2i | FFF6 | FFF0 |
| 0b, 0x0015 16xv 2d 2i | FFF4 | FFEE |
| 0b, 0x0015 1xs 4d 2i | 00000004 | 00000005 |
| 0b, 0x0015 1xv 4d 2i | FFF6 | FFF0 |
| 0b, 0x0015 16xv 4d 2i | FFF4 | FFEE |
| 0b, 0x0015 1xs 1d 4i | 00000004 | 00000005 |
| 0b, 0x0015 1xv 1d 4i | FFF6 | FFFB |
| 0b, 0x0015 16xv 1d 4i | FFF4 | FFF9 |
| 0b, 0x0015 1xs 2d 4i | 00000004 | 00000005 |
| 0b, 0x0015 1xv 2d 4i | FFF6 | FFFB |
| 0b, 0x0015 16xv 2d 4i | FFF4 | FFF9 |
| 0b, 0x0015 1xs 4d 4i | 00000004 | 00000005 |
| 0b, 0x0015 1xv 4d 4i | FFF6 | FFFB |
| 0b, 0x0015 16xv 4d 4i | FFF4 | FFF9 |
| 0b, 0x0020 1xv 1d 1i | FFE9 | FFFC |
| 0b, 0x0020 16xv 1d 1i | FFE8 | FFFC |
| 0b, 0x0020 1xv 2d 1i | FFE9 | FFFC |
| 0b, 0x0020 16xv 2d 1i | FFE8 | FFFC |
| 0b, 0x0020 1xv 4d 1i | FFE9 | FFFC |
| 0b, 0x0020 16xv 4d 1i | FFE8 | FFFC |
| 0b, 0x0020 1xv 1d 2i | FFF2 | FFF5 |
| 0b, 0x0020 16xv 1d 2i | FFF1 | FFF5 |
| 0b, 0x0020 1xv 2d 2i | FFF2 | FFF5 |
| 0b, 0x0020 16xv 2d 2i | FFF1 | FFF5 |
| 0b, 0x0020 1xv 4d 2i | FFF2 | FFF5 |
| 0b, 0x0020 16xv 4d 2i | FFF1 | FFF5 |
| 0b, 0x0020 1xv 1d 4i | FFE4 | FFE7 |
| 0b, 0x0020 16xv 1d 4i | FFE3 | FFE7 |
| 0b, 0x0020 1xv 2d 4i | FFE4 | FFE7 |
| 0b, 0x0020 16xv 2d 4i | FFE3 | FFE7 |
| 0b, 0x0020 1xv 4d 4i | FFE4 | FFE7 |
| 0b, 0x0020 16xv 4d 4i | FFE3 | FFE7 |
| 0b, 0x0024 16xs 1d 1i | 00000020 | 00000030 |
| 0b, 0x0024 1xv 1d 1i | FFDD | FFF0 |
| 0b, 0x0024 16xv 1d 1i | FFDC | FFF1 |
| 0b, 0x0024 16xs 2d 1i | 00000020 | 00000030 |
| 0b, 0x0024 1xv 2d 1i | FFDD | FFF0 |
| 0b, 0x0024 16xv 2d 1i | FFDC | FFF1 |
| 0b, 0x0024 16xs 4d 1i | 00000020 | 00000030 |
| 0b, 0x0024 1xv 4d 1i | FFDD | FFF0 |
| 0b, 0x0024 16xv 4d 1i | FFDC | FFF1 |
| 0b, 0x0024 16xs 1d 2i | 00000020 | 00000030 |
| 0b, 0x0024 1xv 1d 2i | FFFE | FFFD |
| 0b, 0x0024 16xv 1d 2i | FFFD | FFFE |
| 0b, 0x0024 16xs 2d 2i | 00000020 | 00000030 |
| 0b, 0x0024 1xv 2d 2i | FFFE | FFFD |
| 0b, 0x0024 16xv 2d 2i | FFFD | FFFE |
| 0b, 0x0024 16xs 4d 2i | 00000020 | 00000030 |
| 0b, 0x0024 1xv 4d 2i | FFFE | FFFD |
| 0b, 0x0024 16xv 4d 2i | FFFD | FFFE |
| 0b, 0x0024 16xs 1d 4i | 00000020 | 00000030 |
| 0b, 0x0024 1xv 1d 4i | FFF8 | FFF3 |
| 0b, 0x0024 16xv 1d 4i | FFF7 | FFF4 |
| 0b, 0x0024 16xs 2d 4i | 00000020 | 00000030 |
| 0b, 0x0024 1xv 2d 4i | FFF8 | FFF3 |
| 0b, 0x0024 16xv 2d 4i | FFF7 | FFF4 |
| 0b, 0x0024 16xs 4d 4i | 00000020 | 00000030 |
| 0b, 0x0024 1xv 4d 4i | FFF8 | FFF3 |
| 0b, 0x0024 16xv 4d 4i | FFF7 | FFF4 |
| 0b, 0x0025 1xs 1d 1i | 00000006 | 00000007 |
| 0b, 0x0025 16xs 1d 1i | 00000020 | 00000030 |
| 0b, 0x0025 1xv 1d 1i | FFFE | FFEF |
| 0b, 0x0025 16xv 1d 1i | FFFE | FFED |
| 0b, 0x0025 1xs 2d 1i | 00000006 | 00000007 |
| 0b, 0x0025 16xs 2d 1i | 00000020 | 00000030 |
| 0b, 0x0025 1xv 2d 1i | FFFE | FFEF |
| 0b, 0x0025 16xv 2d 1i | FFFE | FFED |
| 0b, 0x0025 1xs 4d 1i | 00000006 | 00000007 |
| 0b, 0x0025 16xs 4d 1i | 00000020 | 00000030 |
| 0b, 0x0025 1xv 4d 1i | FFFE | FFEF |
| 0b, 0x0025 16xv 4d 1i | FFFE | FFED |
| 0b, 0x0025 1xs 1d 2i | 00000006 | 00000007 |
| 0b, 0x0025 16xs 1d 2i | 00000020 | 00000030 |
| 0b, 0x0025 1xv 1d 2i | FFF8 | FFF9 |
| 0b, 0x0025 16xv 1d 2i | FFF8 | FFF7 |
| 0b, 0x0025 1xs 2d 2i | 00000006 | 00000007 |
| 0b, 0x0025 16xs 2d 2i | 00000020 | 00000030 |
| 0b, 0x0025 1xv 2d 2i | FFF8 | FFF9 |
| 0b, 0x0025 16xv 2d 2i | FFF8 | FFF7 |
| 0b, 0x0025 1xs 4d 2i | 00000006 | 00000007 |
| 0b, 0x0025 16xs 4d 2i | 00000020 | 00000030 |
| 0b, 0x0025 1xv 4d 2i | FFF8 | FFF9 |
| 0b, 0x0025 16xv 4d 2i | FFF8 | FFF7 |
| 0b, 0x0025 1xs 1d 4i | 00000006 | 00000007 |
| 0b, 0x0025 16xs 1d 4i | 00000020 | 00000030 |
| 0b, 0x0025 1xv 1d 4i | FFEC | FFE8 |
| 0b, 0x0025 16xv 1d 4i | FFEC | FFE6 |
| 0b, 0x0025 1xs 2d 4i | 00000006 | 00000007 |
| 0b, 0x0025 16xs 2d 4i | 00000020 | 00000030 |
| 0b, 0x0025 1xv 2d 4i | FFEC | FFE8 |
| 0b, 0x0025 16xv 2d 4i | FFEC | FFE6 |
| 0b, 0x0025 1xs 4d 4i | 00000006 | 00000007 |
| 0b, 0x0025 16xs 4d 4i | 00000020 | 00000030 |
| 0b, 0x0025 1xv 4d 4i | FFEC | FFE8 |
| 0b, 0x0025 16xv 4d 4i | FFEC | FFE6 |
| 0b, 0x0040 1xv 1d 1i | FFC9 | FFDC |
| 0b, 0x0040 16xv 1d 1i | FFC8 | FFDC |
| 0b, 0x0040 1xv 2d 1i | FFC9 | FFDC |
| 0b, 0x0040 16xv 2d 1i | FFC8 | FFDC |
| 0b, 0x0040 1xv 4d 1i | FFC9 | FFDC |
| 0b, 0x0040 16xv 4d 1i | FFC8 | FFDC |
| 0b, 0x0040 1xs 1d 2i | 0000000A | 0000000B |
| 0b, 0x0040 1xv 1d 2i | FFF2 | FFDC |
| 0b, 0x0040 16xv 1d 2i | FFF1 | FFDC |
| 0b, 0x0040 1xs 2d 2i | 0000000A | 0000000B |
| 0b, 0x0040 1xv 2d 2i | FFF2 | FFDC |
| 0b, 0x0040 16xv 2d 2i | FFF1 | FFDC |
| 0b, 0x0040 1xs 4d 2i | 0000000A | 0000000B |
| 0b, 0x0040 1xv 4d 2i | FFF2 | FFDC |
| 0b, 0x0040 16xv 4d 2i | FFF1 | FFDC |
| 0b, 0x0040 1xs 1d 4i | 0000000B | 0000000D |
| 0b, 0x0040 16xs 1d 4i | 00000040 | 00000050 |
| 0b, 0x0040 1xv 1d 4i | FFC8 | FFDE |
| 0b, 0x0040 16xv 1d 4i | FFC8 | FFDE |
| 0b, 0x0040 1xs 2d 4i | 0000000B | 0000000D |
| 0b, 0x0040 16xs 2d 4i | 00000040 | 00000050 |
| 0b, 0x0040 1xv 2d 4i | FFC8 | FFDE |
| 0b, 0x0040 16xv 2d 4i | FFC8 | FFDE |
| 0b, 0x0040 1xs 4d 4i | 0000000B | 0000000D |
| 0b, 0x0040 16xs 4d 4i | 00000040 | 00000050 |
| 0b, 0x0040 1xv 4d 4i | FFC8 | FFDE |
| 0b, 0x0040 16xv 4d 4i | FFC8 | FFDE |
| 0b, 0x0080 1xs 1d 1i | 00000013 | 00000012 |
| 0b, 0x0080 16xs 1d 1i | 00000060 | 00000070 |
| 0b, 0x0080 1xv 1d 1i | FFC8 | FFDC |
| 0b, 0x0080 16xv 1d 1i | FFC8 | FFDD |
| 0b, 0x0080 1xs 2d 1i | 00000013 | 00000012 |
| 0b, 0x0080 16xs 2d 1i | 00000060 | 00000070 |
| 0b, 0x0080 1xv 2d 1i | FFC8 | FFDC |
| 0b, 0x0080 16xv 2d 1i | FFC8 | FFDD |
| 0b, 0x0080 1xs 4d 1i | 00000013 | 00000012 |
| 0b, 0x0080 16xs 4d 1i | 00000060 | 00000070 |
| 0b, 0x0080 1xv 4d 1i | FFC8 | FFDC |
| 0b, 0x0080 16xv 4d 1i | FFC8 | FFDD |
| 0b, 0x0080 1xs 1d 2i | 00000017 | 00000013 |
| 0b, 0x0080 16xs 1d 2i | 00000080 | 00000070 |
| 0b, 0x0080 1xv 1d 2i | FFC9 | FFDC |
| 0b, 0x0080 16xv 1d 2i | FFC9 | FFDC |
| 0b, 0x0080 1xs 2d 2i | 00000017 | 00000013 |
| 0b, 0x0080 16xs 2d 2i | 00000080 | 00000070 |
| 0b, 0x0080 1xv 2d 2i | FFC9 | FFDC |
| 0b, 0x0080 16xv 2d 2i | FFC9 | FFDC |
| 0b, 0x0080 1xs 4d 2i | 00000017 | 00000013 |
| 0b, 0x0080 16xs 4d 2i | 00000080 | 00000070 |
| 0b, 0x0080 1xv 4d 2i | FFC9 | FFDC |
| 0b, 0x0080 16xv 4d 2i | FFC9 | FFDC |
| 0b, 0x0080 1xs 1d 4i | 0000001D | 00000015 |
| 0b, 0x0080 16xs 1d 4i | 000000A0 | 00000070 |
| 0b, 0x0080 1xv 1d 4i | FFC9 | FFDE |
| 0b, 0x0080 16xv 1d 4i | FFC8 | FFDC |
| 0b, 0x0080 1xs 2d 4i | 0000001D | 00000015 |
| 0b, 0x0080 16xs 2d 4i | 000000A0 | 00000070 |
| 0b, 0x0080 1xv 2d 4i | FFC9 | FFDE |
| 0b, 0x0080 16xv 2d 4i | FFC8 | FFDC |
| 0b, 0x0080 1xs 4d 4i | 0000001D | 00000015 |
| 0b, 0x0080 16xs 4d 4i | 000000A0 | 00000070 |
| 0b, 0x0080 1xv 4d 4i | FFC9 | FFDE |
| 0b, 0x0080 16xv 4d 4i | FFC8 | FFDC |
| 0b, 0x0800 1xs 1d 1i | 00000126 | 00000102 |
| 0b, 0x0800 16xs 1d 1i | 000005E0 | 000005A0 |
| 0b, 0x0800 1xv 1d 1i | F849 | F85C |
| 0b, 0x0800 16xv 1d 1i | F848 | F85C |
| 0b, 0x0800 1xs 2d 1i | 00000126 | 00000102 |
| 0b, 0x0800 16xs 2d 1i | 000005E0 | 000005A0 |
| 0b, 0x0800 1xv 2d 1i | F849 | F85C |
| 0b, 0x0800 16xv 2d 1i | F848 | F85C |
| 0b, 0x0800 1xs 4d 1i | 00000126 | 00000102 |
| 0b, 0x0800 16xs 4d 1i | 000005E0 | 000005A0 |
| 0b, 0x0800 1xv 4d 1i | F849 | F85C |
| 0b, 0x0800 16xv 4d 1i | F848 | F85C |
| 0b, 0x0800 1xs 1d 2i | 0000023B | 000001F3 |
| 0b, 0x0800 16xs 1d 2i | 00000B60 | 00000AE0 |
| 0b, 0x0800 1xv 1d 2i | F849 | F85C |
| 0b, 0x0800 16xv 1d 2i | F848 | F85C |
| 0b, 0x0800 1xs 2d 2i | 0000023B | 000001F3 |
| 0b, 0x0800 16xs 2d 2i | 00000B60 | 00000AE0 |
| 0b, 0x0800 1xv 2d 2i | F849 | F85C |
| 0b, 0x0800 16xv 2d 2i | F848 | F85C |
| 0b, 0x0800 1xs 4d 2i | 0000023B | 000001F3 |
| 0b, 0x0800 16xs 4d 2i | 00000B60 | 00000AE0 |
| 0b, 0x0800 1xv 4d 2i | F849 | F85C |
| 0b, 0x0800 16xv 4d 2i | F848 | F85C |
| 0b, 0x0800 1xs 1d 4i | 00000466 | 000003D5 |
| 0b, 0x0800 16xs 1d 4i | 00001670 | 00001550 |
| 0b, 0x0800 1xv 1d 4i | F848 | F85E |
| 0b, 0x0800 16xv 1d 4i | F849 | F85C |
| 0b, 0x0800 1xs 2d 4i | 00000466 | 000003D5 |
| 0b, 0x0800 16xs 2d 4i | 00001670 | 00001550 |
| 0b, 0x0800 1xv 2d 4i | F848 | F85E |
| 0b, 0x0800 16xv 2d 4i | F849 | F85C |
| 0b, 0x0800 1xs 4d 4i | 00000466 | 000003D5 |
| 0b, 0x0800 16xs 4d 4i | 00001670 | 00001550 |
| 0b, 0x0800 1xv 4d 4i | F848 | F85E |
| 0b, 0x0800 16xv 4d 4i | F849 | F85C |
| 0b, 0x8000 1xs 1d 1i | 0000124A | 00001002 |
| 0b, 0x8000 16xs 1d 1i | 00005D20 | 00005920 |
| 0b, 0x8000 1xv 1d 1i | 8049 | 805C |
| 0b, 0x8000 16xv 1d 1i | 8048 | 805E |
| 0b, 0x8000 1xs 2d 1i | 0000124A | 00001002 |
| 0b, 0x8000 16xs 2d 1i | 00005D20 | 00005920 |
| 0b, 0x8000 1xv 2d 1i | 8049 | 805C |
| 0b, 0x8000 16xv 2d 1i | 8048 | 805E |
| 0b, 0x8000 1xs 4d 1i | 0000124A | 00001002 |
| 0b, 0x8000 16xs 4d 1i | 00005D20 | 00005920 |
| 0b, 0x8000 1xv 4d 1i | 8049 | 805C |
| 0b, 0x8000 16xv 4d 1i | 8048 | 805E |
| 0b, 0x8000 1xs 1d 2i | 00002484 | 00001FF3 |
| 0b, 0x8000 16xs 1d 2i | 0000B9F0 | 0000B1D0 |
| 0b, 0x8000 1xv 1d 2i | 8048 | 805C |
| 0b, 0x8000 16xv 1d 2i | 8048 | 805C |
| 0b, 0x8000 1xs 2d 2i | 00002484 | 00001FF3 |
| 0b, 0x8000 16xs 2d 2i | 0000B9F0 | 0000B1D0 |
| 0b, 0x8000 1xv 2d 2i | 8048 | 805C |
| 0b, 0x8000 16xv 2d 2i | 8048 | 805C |
| 0b, 0x8000 1xs 4d 2i | 00002484 | 00001FF3 |
| 0b, 0x8000 16xs 4d 2i | 0000B9F0 | 0000B1D0 |
| 0b, 0x8000 1xv 4d 2i | 8048 | 805C |
| 0b, 0x8000 16xv 4d 2i | 8048 | 805C |
| 0b, 0x8000 1xs 1d 4i | 000048F9 | 00003FD5 |
| 0b, 0x8000 16xs 1d 4i | 00017380 | 00016340 |
| 0b, 0x8000 1xv 1d 4i | 8049 | 805E |
| 0b, 0x8000 16xv 1d 4i | 8048 | 805C |
| 0b, 0x8000 1xs 2d 4i | 000048F9 | 00003FD5 |
| 0b, 0x8000 16xs 2d 4i | 00017380 | 00016340 |
| 0b, 0x8000 1xv 2d 4i | 8049 | 805E |
| 0b, 0x8000 16xv 2d 4i | 8048 | 805C |
| 0b, 0x8000 1xs 4d 4i | 000048F9 | 00003FD5 |
| 0b, 0x8000 16xs 4d 4i | 00017380 | 00016340 |
| 0b, 0x8000 1xv 4d 4i | 8049 | 805E |
| 0b, 0x8000 16xv 4d 4i | 8048 | 805C |
| 6b, 0x0010 1xs 1d 1i | 00000093 | 0000007B |
| 6b, 0x0010 16xs 1d 1i | 000002F0 | 000002B0 |
| 6b, 0x0010 1xs 2d 1i | 00000093 | 0000007B |
| 6b, 0x0010 16xs 2d 1i | 000002F0 | 000002B0 |
| 6b, 0x0010 1xs 4d 1i | 00000093 | 00000081 |
| 6b, 0x0010 16xs 4d 1i | 000002F0 | 000002D0 |
| 6b, 0x0010 1xs 1d 2i | 00000117 | 000000EC |
| 6b, 0x0010 16xs 1d 2i | 00000590 | 00000520 |
| 6b, 0x0010 1xs 2d 2i | 00000117 | 000000EB |
| 6b, 0x0010 16xs 2d 2i | 00000590 | 00000520 |
| 6b, 0x0010 1xs 4d 2i | 00000117 | 000000F2 |
| 6b, 0x0010 16xs 4d 2i | 00000590 | 00000550 |
| 6b, 0x0010 1xs 1d 4i | 0000021D | 000001CE |
| 6b, 0x0010 16xs 1d 4i | 00000AD0 | 00000A10 |
| 6b, 0x0010 1xs 2d 4i | 0000021D | 000001CD |
| 6b, 0x0010 16xs 2d 4i | 00000AD0 | 00000A10 |
| 6b, 0x0010 1xs 4d 4i | 0000021D | 000001D4 |
| 6b, 0x0010 16xs 4d 4i | 00000AD0 | 00000A30 |
| 6b, 0x0011 1xs 1d 1i | 0000009C | 00000083 |
| 6b, 0x0011 16xs 1d 1i | 00000320 | 000002E0 |
| 6b, 0x0011 1xs 2d 1i | 0000009C | 00000083 |
| 6b, 0x0011 16xs 2d 1i | 00000320 | 000002E0 |
| 6b, 0x0011 1xs 4d 1i | 0000009C | 00000089 |
| 6b, 0x0011 16xs 4d 1i | 00000320 | 00000300 |
| 6b, 0x0011 1xs 1d 2i | 00000129 | 000000FC |
| 6b, 0x0011 16xs 1d 2i | 000005F0 | 00000580 |
| 6b, 0x0011 1xs 2d 2i | 00000129 | 000000FB |
| 6b, 0x0011 16xs 2d 2i | 000005F0 | 00000580 |
| 6b, 0x0011 1xs 4d 2i | 00000129 | 00000102 |
| 6b, 0x0011 16xs 4d 2i | 000005F0 | 000005A0 |
| 6b, 0x0011 1xs 1d 4i | 00000242 | 000001EE |
| 6b, 0x0011 16xs 1d 4i | 00000B80 | 00000AC0 |
| 6b, 0x0011 1xs 2d 4i | 00000242 | 000001ED |
| 6b, 0x0011 16xs 2d 4i | 00000B80 | 00000AC0 |
| 6b, 0x0011 1xs 4d 4i | 00000242 | 000001F4 |
| 6b, 0x0011 16xs 4d 4i | 00000B80 | 00000AE0 |
| 6b, 0x0012 1xs 1d 1i | 000000A6 | 0000008B |
| 6b, 0x0012 16xs 1d 1i | 00000350 | 00000310 |
| 6b, 0x0012 1xs 2d 1i | 000000A6 | 0000008B |
| 6b, 0x0012 16xs 2d 1i | 00000350 | 00000310 |
| 6b, 0x0012 1xs 4d 1i | 000000A6 | 00000091 |
| 6b, 0x0012 16xs 4d 1i | 00000350 | 00000330 |
| 6b, 0x0012 1xs 1d 2i | 0000013B | 0000010C |
| 6b, 0x0012 16xs 1d 2i | 00000650 | 000005E0 |
| 6b, 0x0012 1xs 2d 2i | 0000013B | 0000010B |
| 6b, 0x0012 16xs 2d 2i | 00000650 | 000005D0 |
| 6b, 0x0012 1xs 4d 2i | 0000013B | 00000112 |
| 6b, 0x0012 16xs 4d 2i | 00000650 | 00000600 |
| 6b, 0x0012 1xs 1d 4i | 00000266 | 0000020E |
| 6b, 0x0012 16xs 1d 4i | 00000C40 | 00000B70 |
| 6b, 0x0012 1xs 2d 4i | 00000266 | 0000020D |
| 6b, 0x0012 16xs 2d 4i | 00000C40 | 00000B70 |
| 6b, 0x0012 1xs 4d 4i | 00000266 | 00000214 |
| 6b, 0x0012 16xs 4d 4i | 00000C40 | 00000B90 |
| 6b, 0x0013 1xs 1d 1i | 000000AF | 00000093 |
| 6b, 0x0013 16xs 1d 1i | 00000380 | 00000340 |
| 6b, 0x0013 1xs 2d 1i | 000000AF | 00000093 |
| 6b, 0x0013 16xs 2d 1i | 00000380 | 00000330 |
| 6b, 0x0013 1xs 4d 1i | 000000AF | 00000099 |
| 6b, 0x0013 16xs 4d 1i | 00000380 | 00000360 |
| 6b, 0x0013 1xs 1d 2i | 0000014D | 0000011C |
| 6b, 0x0013 16xs 1d 2i | 000006A0 | 00000630 |
| 6b, 0x0013 1xs 2d 2i | 0000014D | 0000011B |
| 6b, 0x0013 16xs 2d 2i | 000006A0 | 00000630 |
| 6b, 0x0013 1xs 4d 2i | 0000014D | 00000122 |
| 6b, 0x0013 16xs 4d 2i | 000006A0 | 00000650 |
| 6b, 0x0013 1xs 1d 4i | 0000028B | 0000022E |
| 6b, 0x0013 16xs 1d 4i | 00000CF0 | 00000C20 |
| 6b, 0x0013 1xs 2d 4i | 0000028B | 0000022D |
| 6b, 0x0013 16xs 2d 4i | 00000CF0 | 00000C20 |
| 6b, 0x0013 1xs 4d 4i | 0000028B | 00000234 |
| 6b, 0x0013 16xs 4d 4i | 00000CF0 | 00000C40 |
| 8b, 0x0010 1xs 1d 1i | 0000024A | 000001EB |
| 8b, 0x0010 16xs 1d 1i | 00000BB0 | 00000AB0 |
| 8b, 0x0010 1xs 2d 1i | 0000024A | 000001EB |
| 8b, 0x0010 16xs 2d 1i | 00000BB0 | 00000AB0 |
| 8b, 0x0010 1xs 4d 1i | 0000024A | 000001E9 |
| 8b, 0x0010 16xs 4d 1i | 00000BB0 | 00000AB0 |
| 8b, 0x0010 1xs 1d 2i | 00000484 | 000003DC |
| 8b, 0x0010 16xs 1d 2i | 00001700 | 00001580 |
| 8b, 0x0010 1xs 2d 2i | 00000484 | 000003DB |
| 8b, 0x0010 16xs 2d 2i | 00001700 | 00001580 |
| 8b, 0x0010 1xs 4d 2i | 00000484 | 000003DA |
| 8b, 0x0010 16xs 4d 2i | 00001700 | 00001570 |
| 8b, 0x0010 1xs 1d 4i | 000008F9 | 000007BE |
| 8b, 0x0010 16xs 1d 4i | 00002DB0 | 00002B20 |
| 8b, 0x0010 1xs 2d 4i | 000008F9 | 000007BD |
| 8b, 0x0010 16xs 2d 4i | 00002DB0 | 00002B10 |
| 8b, 0x0010 1xs 4d 4i | 000008F9 | 000007BC |
| 8b, 0x0010 16xs 4d 4i | 00002DB0 | 00002B10 |
| 8b, 0x0011 1xs 1d 1i | 0000026F | 0000020B |
| 8b, 0x0011 16xs 1d 1i | 00000C60 | 00000B60 |
| 8b, 0x0011 1xs 2d 1i | 0000026F | 0000020B |
| 8b, 0x0011 16xs 2d 1i | 00000C60 | 00000B60 |
| 8b, 0x0011 1xs 4d 1i | 0000026F | 00000209 |
| 8b, 0x0011 16xs 4d 1i | 00000C60 | 00000B60 |
| 8b, 0x0011 1xs 1d 2i | 000004CD | 0000041C |
| 8b, 0x0011 16xs 1d 2i | 00001880 | 000016E0 |
| 8b, 0x0011 1xs 2d 2i | 000004CD | 0000041B |
| 8b, 0x0011 16xs 2d 2i | 00001880 | 000016E0 |
| 8b, 0x0011 1xs 4d 2i | 000004CD | 0000041A |
| 8b, 0x0011 16xs 4d 2i | 00001880 | 000016E0 |
| 8b, 0x0011 1xs 1d 4i | 0000098B | 0000083E |
| 8b, 0x0011 16xs 1d 4i | 000030A0 | 00002DE0 |
| 8b, 0x0011 1xs 2d 4i | 0000098B | 0000083D |
| 8b, 0x0011 16xs 2d 4i | 000030A0 | 00002DE0 |
| 8b, 0x0011 1xs 4d 4i | 0000098B | 0000083C |
| 8b, 0x0011 16xs 4d 4i | 000030A0 | 00002DE0 |
| 8b, 0x0012 1xs 1d 1i | 00000293 | 0000022B |
| 8b, 0x0012 16xs 1d 1i | 00000D20 | 00000C10 |
| 8b, 0x0012 1xs 2d 1i | 00000293 | 0000022B |
| 8b, 0x0012 16xs 2d 1i | 00000D20 | 00000C10 |
| 8b, 0x0012 1xs 4d 1i | 00000293 | 00000229 |
| 8b, 0x0012 16xs 4d 1i | 00000D20 | 00000C10 |
| 8b, 0x0012 1xs 1d 2i | 00000517 | 0000045C |
| 8b, 0x0012 16xs 1d 2i | 000019F0 | 00001850 |
| 8b, 0x0012 1xs 2d 2i | 00000517 | 0000045B |
| 8b, 0x0012 16xs 2d 2i | 000019F0 | 00001840 |
| 8b, 0x0012 1xs 4d 2i | 00000517 | 0000045A |
| 8b, 0x0012 16xs 4d 2i | 000019F0 | 00001840 |
| 8b, 0x0012 1xs 1d 4i | 00000A1D | 000008BE |
| 8b, 0x0012 16xs 1d 4i | 00003380 | 000030B0 |
| 8b, 0x0012 1xs 2d 4i | 00000A1D | 000008BD |
| 8b, 0x0012 16xs 2d 4i | 00003380 | 000030A0 |
| 8b, 0x0012 1xs 4d 4i | 00000A1D | 000008BC |
| 8b, 0x0012 16xs 4d 4i | 00003380 | 000030A0 |
| 8b, 0x0013 1xs 1d 1i | 000002B8 | 0000024B |
| 8b, 0x0013 16xs 1d 1i | 00000DE0 | 00000CD0 |
| 8b, 0x0013 1xs 2d 1i | 000002B8 | 0000024B |
| 8b, 0x0013 16xs 2d 1i | 00000DE0 | 00000CC0 |
| 8b, 0x0013 1xs 4d 1i | 000002B8 | 00000249 |
| 8b, 0x0013 16xs 4d 1i | 00000DE0 | 00000CC0 |
| 8b, 0x0013 1xs 1d 2i | 00000560 | 0000049C |
| 8b, 0x0013 16xs 1d 2i | 00001B60 | 000019B0 |
| 8b, 0x0013 1xs 2d 2i | 00000560 | 0000049B |
| 8b, 0x0013 16xs 2d 2i | 00001B60 | 000019B0 |
| 8b, 0x0013 1xs 4d 2i | 00000560 | 0000049A |
| 8b, 0x0013 16xs 4d 2i | 00001B60 | 000019A0 |
| 8b, 0x0013 1xs 1d 4i | 00000AAF | 0000093E |
| 8b, 0x0013 16xs 1d 4i | 00003670 | 00003370 |
| 8b, 0x0013 1xs 2d 4i | 00000AAF | 0000093D |
| 8b, 0x0013 16xs 2d 4i | 00003670 | 00003370 |
| 8b, 0x0013 1xs 4d 4i | 00000AAF | 0000093C |
| 8b, 0x0013 16xs 4d 4i | 00003670 | 00003370 |
| 10b, 0x0010 1xs 1d 1i | 00000926 | 000007EB |
| 10b, 0x0010 16xs 1d 1i | 00002E90 | 00002C10 |
| 10b, 0x0010 1xs 2d 1i | 00000926 | 000007EB |
| 10b, 0x0010 16xs 2d 1i | 00002E90 | 00002C10 |
| 10b, 0x0010 1xs 4d 1i | 00000926 | 000007E9 |
| 10b, 0x0010 16xs 4d 1i | 00002E90 | 00002C10 |
| 10b, 0x0010 1xs 1d 2i | 0000123B | 00000FDC |
| 10b, 0x0010 16xs 1d 2i | 00005CD0 | 00005850 |
| 10b, 0x0010 1xs 2d 2i | 0000123B | 00000FDB |
| 10b, 0x0010 16xs 2d 2i | 00005CD0 | 00005840 |
| 10b, 0x0010 1xs 4d 2i | 0000123B | 00000FDA |
| 10b, 0x0010 16xs 4d 2i | 00005CD0 | 00005840 |
| 10b, 0x0010 1xs 1d 4i | 00002466 | 00001FBE |
| 10b, 0x0010 16xs 1d 4i | 0000B950 | 0000B0B0 |
| 10b, 0x0010 1xs 2d 4i | 00002466 | 00001FBD |
| 10b, 0x0010 16xs 2d 4i | 0000B950 | 0000B0A0 |
| 10b, 0x0010 1xs 4d 4i | 00002466 | 00001FBC |
| 10b, 0x0010 16xs 4d 4i | 0000B950 | 0000B0A0 |
| 10b, 0x0011 1xs 1d 1i | 000009B8 | 0000086B |
| 10b, 0x0011 16xs 1d 1i | 00003180 | 00002EE0 |
| 10b, 0x0011 1xs 2d 1i | 000009B8 | 0000086B |
| 10b, 0x0011 16xs 2d 1i | 00003180 | 00002EE0 |
| 10b, 0x0011 1xs 4d 1i | 000009B8 | 00000869 |
| 10b, 0x0011 16xs 4d 1i | 00003180 | 00002ED0 |
| 10b, 0x0011 1xs 1d 2i | 00001360 | 000010DC |
| 10b, 0x0011 16xs 1d 2i | 000062A0 | 00005DE0 |
| 10b, 0x0011 1xs 2d 2i | 00001360 | 000010DB |
| 10b, 0x0011 16xs 2d 2i | 000062A0 | 00005DD0 |
| 10b, 0x0011 1xs 4d 2i | 00001360 | 000010DA |
| 10b, 0x0011 16xs 4d 2i | 000062A0 | 00005DD0 |
| 10b, 0x0011 1xs 1d 4i | 000026AF | 000021BE |
| 10b, 0x0011 16xs 1d 4i | 0000C4F0 | 0000BBD0 |
| 10b, 0x0011 1xs 2d 4i | 000026AF | 000021BD |
| 10b, 0x0011 16xs 2d 4i | 0000C4F0 | 0000BBD0 |
| 10b, 0x0011 1xs 4d 4i | 000026AF | 000021BC |
| 10b, 0x0011 16xs 4d 4i | 0000C4F0 | 0000BBC0 |
| 10b, 0x0012 1xs 1d 1i | 00000A4A | 000008EB |
| 10b, 0x0012 16xs 1d 1i | 00003460 | 000031A0 |
| 10b, 0x0012 1xs 2d 1i | 00000A4A | 000008EB |
| 10b, 0x0012 16xs 2d 1i | 00003460 | 000031A0 |
| 10b, 0x0012 1xs 4d 1i | 00000A4A | 000008E9 |
| 10b, 0x0012 16xs 4d 1i | 00003460 | 000031A0 |
| 10b, 0x0012 1xs 1d 2i | 00001484 | 000011DC |
| 10b, 0x0012 16xs 1d 2i | 00006880 | 00006370 |
| 10b, 0x0012 1xs 2d 2i | 00001484 | 000011DB |
| 10b, 0x0012 16xs 2d 2i | 00006880 | 00006360 |
| 10b, 0x0012 1xs 4d 2i | 00001484 | 000011DA |
| 10b, 0x0012 16xs 4d 2i | 00006880 | 00006360 |
| 10b, 0x0012 1xs 1d 4i | 000028F9 | 000023BE |
| 10b, 0x0012 16xs 1d 4i | 0000D0A0 | 0000C6F0 |
| 10b, 0x0012 1xs 2d 4i | 000028F9 | 000023BD |
| 10b, 0x0012 16xs 2d 4i | 0000D0A0 | 0000C6F0 |
| 10b, 0x0012 1xs 4d 4i | 000028F9 | 000023BC |
| 10b, 0x0012 16xs 4d 4i | 0000D0A0 | 0000C6E0 |
| 10b, 0x0013 1xs 1d 1i | 00000ADC | 0000096B |
| 10b, 0x0013 16xs 1d 1i | 00003750 | 00003470 |
| 10b, 0x0013 1xs 2d 1i | 00000ADC | 0000096B |
| 10b, 0x0013 16xs 2d 1i | 00003750 | 00003470 |
| 10b, 0x0013 1xs 4d 1i | 00000ADC | 00000969 |
| 10b, 0x0013 16xs 4d 1i | 00003750 | 00003460 |
| 10b, 0x0013 1xs 1d 2i | 000015A9 | 000012DC |
| 10b, 0x0013 16xs 1d 2i | 00006E50 | 00006900 |
| 10b, 0x0013 1xs 2d 2i | 000015A9 | 000012DB |
| 10b, 0x0013 16xs 2d 2i | 00006E50 | 000068F0 |
| 10b, 0x0013 1xs 4d 2i | 000015A9 | 000012DA |
| 10b, 0x0013 16xs 4d 2i | 00006E50 | 000068F0 |
| 10b, 0x0013 1xs 1d 4i | 00002B42 | 000025BE |
| 10b, 0x0013 16xs 1d 4i | 0000DC40 | 0000D210 |
| 10b, 0x0013 1xs 2d 4i | 00002B42 | 000025BD |
| 10b, 0x0013 16xs 2d 4i | 0000DC40 | 0000D210 |
| 10b, 0x0013 1xs 4d 4i | 00002B42 | 000025BC |
| 10b, 0x0013 16xs 4d 4i | 0000DC40 | 0000D200 |

## Timer IRQ tests (0/90 passed)

0/90 tests passed, 90 failed:

| Test | Actual | Expected |
|------|--------|----------|
| FFFF 0 nops |  |  |
| FFFF 1 nop |  |  |
| FFFF 2 nops |  |  |
| FFFF 3 nops |  |  |
| FFFF 4 nops |  |  |
| FFFF 5 nops |  |  |
| FFFF 6 nops |  |  |
| FFFF 7 nops |  |  |
| FFFF 8 nops |  |  |
| FFFF 9 nops |  |  |
| FFFE 0 nops |  |  |
| FFFE 1 nop |  |  |
| FFFE 2 nops |  |  |
| FFFE 3 nops |  |  |
| FFFE 4 nops |  |  |
| FFFE 5 nops |  |  |
| FFFE 6 nops |  |  |
| FFFE 7 nops |  |  |
| FFFE 8 nops |  |  |
| FFFE 9 nops |  |  |
| FFFD 0 nops |  |  |
| FFFD 1 nop |  |  |
| FFFD 2 nops |  |  |
| FFFD 3 nops |  |  |
| FFFD 4 nops |  |  |
| FFFD 5 nops |  |  |
| FFFD 6 nops |  |  |
| FFFD 7 nops |  |  |
| FFFD 8 nops |  |  |
| FFFD 9 nops |  |  |
| FFFC 0 nops |  |  |
| FFFC 1 nop |  |  |
| FFFC 2 nops |  |  |
| FFFC 3 nops |  |  |
| FFFC 4 nops |  |  |
| FFFC 5 nops |  |  |
| FFFC 6 nops |  |  |
| FFFC 7 nops |  |  |
| FFFC 8 nops |  |  |
| FFFC 9 nops |  |  |
| FFFB 0 nops |  |  |
| FFFB 1 nop |  |  |
| FFFB 2 nops |  |  |
| FFFB 3 nops |  |  |
| FFFB 4 nops |  |  |
| FFFB 5 nops |  |  |
| FFFB 6 nops |  |  |
| FFFB 7 nops |  |  |
| FFFB 8 nops |  |  |
| FFFB 9 nops |  |  |
| FFFA 0 nops |  |  |
| FFFA 1 nop |  |  |
| FFFA 2 nops |  |  |
| FFFA 3 nops |  |  |
| FFFA 4 nops |  |  |
| FFFA 5 nops |  |  |
| FFFA 6 nops |  |  |
| FFFA 7 nops |  |  |
| FFFA 8 nops |  |  |
| FFFA 9 nops |  |  |
| FFF9 0 nops |  |  |
| FFF9 1 nop |  |  |
| FFF9 2 nops |  |  |
| FFF9 3 nops |  |  |
| FFF9 4 nops |  |  |
| FFF9 5 nops |  |  |
| FFF9 6 nops |  |  |
| FFF9 7 nops |  |  |
| FFF9 8 nops |  |  |
| FFF9 9 nops |  |  |
| FFF8 0 nops |  |  |
| FFF8 1 nop |  |  |
| FFF8 2 nops |  |  |
| FFF8 3 nops |  |  |
| FFF8 4 nops |  |  |
| FFF8 5 nops |  |  |
| FFF8 6 nops |  |  |
| FFF8 7 nops |  |  |
| FFF8 8 nops |  |  |
| FFF8 9 nops |  |  |
| FFF7 0 nops |  |  |
| FFF7 1 nop |  |  |
| FFF7 2 nops |  |  |
| FFF7 3 nops |  |  |
| FFF7 4 nops |  |  |
| FFF7 5 nops |  |  |
| FFF7 6 nops |  |  |
| FFF7 7 nops |  |  |
| FFF7 8 nops |  |  |
| FFF7 9 nops |  |  |

## Shifter tests

All tests passed.

## Carry tests

All tests passed.

## Multiply long tests

All tests passed.

## BIOS math tests

All tests passed.

## DMA tests (1124/1256 passed)

1124/1256 tests passed, 132 failed:

| Test | Actual | Expected |
|------|--------|----------|
| 1 Imm H =ROM/=IWRAM 3 | CB0EBEEF | CB0EDEAD |
| 2 Imm H =ROM/=IWRAM 3 | CB0EBEEF | CB0EDEAD |
| 3 Imm H =ROM/=IWRAM 3 | CB0EBEEF | CB0EDEAD |
| 1 Imm H =ROM/=EWRAM 3 | FEFDBEEF | FEFDDEAD |
| 2 Imm H =ROM/=EWRAM 3 | FEFDBEEF | FEFDDEAD |
| 3 Imm H =ROM/=EWRAM 3 | FEFDBEEF | FEFDDEAD |
| 0 Imm W =ROM/=IWRAM 3 | FEFFBABE | BABEBABE |
| 1 Imm W =ROM/=IWRAM 3 | DEADBEEF | DEADBEF2 |
| 2 Imm W =ROM/=IWRAM 3 | DEADBEEF | DEADBEF2 |
| 3 Imm W =ROM/=IWRAM 3 | DEADBEEF | DEADBEF2 |
| 0 Imm W =ROM/=EWRAM 3 | FEFFBABE | BABEBABE |
| 1 Imm W =ROM/=EWRAM 3 | DEADBEEF | DEADBEF2 |
| 2 Imm W =ROM/=EWRAM 3 | DEADBEEF | DEADBEF2 |
| 3 Imm W =ROM/=EWRAM 3 | DEADBEEF | DEADBEF2 |
| 0 Imm W =BIOS/=IWRAM 3 | FEFFBABE | BABEBABE |
| 1 Imm W =BIOS/=IWRAM 3 | FEBFBABE | BABEBABE |
| 2 Imm W =BIOS/=IWRAM 3 | FEBFBABE | BABEBABE |
| 3 Imm W =BIOS/=IWRAM 3 | FEBFBABE | BABEBABE |
| 0 Imm W =BIOS/=EWRAM 3 | FEFFBABE | BABEBABE |
| 1 Imm W =BIOS/=EWRAM 3 | FEBFBABE | BABEBABE |
| 2 Imm W =BIOS/=EWRAM 3 | FEBFBABE | BABEBABE |
| 3 Imm W =BIOS/=EWRAM 3 | FEBFBABE | BABEBABE |
| 0 Imm W +ROM/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 Imm W +ROM/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 Imm W +BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 Imm W +BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 2 Imm W +BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 3 Imm W +BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 Imm W +BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 Imm W +BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 2 Imm W +BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 3 Imm W +BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 Imm W -ROM/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 Imm W -ROM/=IWRAM 3 | DEADBEEC | DEADBEF2 |
| 2 Imm W -ROM/=IWRAM 3 | DEADBEEC | DEADBEF2 |
| 3 Imm W -ROM/=IWRAM 3 | DEADBEEC | DEADBEF2 |
| 0 Imm W -ROM/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 Imm W -ROM/=EWRAM 3 | DEADBEEC | DEADBEF2 |
| 2 Imm W -ROM/=EWRAM 3 | DEADBEEC | DEADBEF2 |
| 3 Imm W -ROM/=EWRAM 3 | DEADBEEC | DEADBEF2 |
| 0 Imm W -BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 Imm W -BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 2 Imm W -BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 3 Imm W -BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 Imm W -BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 Imm W -BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 2 Imm W -BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 3 Imm W -BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 Imm W -SRAM/=IWRAM 3 | A5B6C7D8 | 00000000 |
| 0 Imm W -SRAM/=EWRAM 3 | A5B6C7D8 | 00000000 |
| 1 HBl H =ROM/=IWRAM 3 | CB0EBEEF | CB0EDEAD |
| 2 HBl H =ROM/=IWRAM 3 | CB0EBEEF | CB0EDEAD |
| 3 HBl H =ROM/=IWRAM 3 | CB0EBEEF | CB0EDEAD |
| 1 HBl H =ROM/=EWRAM 3 | FEFDBEEF | FEFDDEAD |
| 2 HBl H =ROM/=EWRAM 3 | FEFDBEEF | FEFDDEAD |
| 3 HBl H =ROM/=EWRAM 3 | FEFDBEEF | FEFDDEAD |
| 0 HBl W =ROM/=IWRAM 3 | FEFFBABE | BABEBABE |
| 1 HBl W =ROM/=IWRAM 3 | DEADBEEF | DEADBEF2 |
| 2 HBl W =ROM/=IWRAM 3 | DEADBEEF | DEADBEF2 |
| 3 HBl W =ROM/=IWRAM 3 | DEADBEEF | DEADBEF2 |
| 0 HBl W =ROM/=EWRAM 3 | FEFFBABE | BABEBABE |
| 1 HBl W =ROM/=EWRAM 3 | DEADBEEF | DEADBEF2 |
| 2 HBl W =ROM/=EWRAM 3 | DEADBEEF | DEADBEF2 |
| 3 HBl W =ROM/=EWRAM 3 | DEADBEEF | DEADBEF2 |
| 0 HBl W =BIOS/=IWRAM 3 | FEFFBABE | BABEBABE |
| 1 HBl W =BIOS/=IWRAM 3 | FEBFBABE | BABEBABE |
| 2 HBl W =BIOS/=IWRAM 3 | FEBFBABE | BABEBABE |
| 3 HBl W =BIOS/=IWRAM 3 | FEBFBABE | BABEBABE |
| 0 HBl W =BIOS/=EWRAM 3 | FEFFBABE | BABEBABE |
| 1 HBl W =BIOS/=EWRAM 3 | FEBFBABE | BABEBABE |
| 2 HBl W =BIOS/=EWRAM 3 | FEBFBABE | BABEBABE |
| 3 HBl W =BIOS/=EWRAM 3 | FEBFBABE | BABEBABE |
| 0 HBl W +ROM/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 HBl W +ROM/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 HBl W +BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 HBl W +BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 2 HBl W +BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 3 HBl W +BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 HBl W +BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 HBl W +BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 2 HBl W +BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 3 HBl W +BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 HBl W -ROM/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 HBl W -ROM/=IWRAM 3 | DEADBEEC | DEADBEF2 |
| 2 HBl W -ROM/=IWRAM 3 | DEADBEEC | DEADBEF2 |
| 3 HBl W -ROM/=IWRAM 3 | DEADBEEC | DEADBEF2 |
| 0 HBl W -ROM/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 HBl W -ROM/=EWRAM 3 | DEADBEEC | DEADBEF2 |
| 2 HBl W -ROM/=EWRAM 3 | DEADBEEC | DEADBEF2 |
| 3 HBl W -ROM/=EWRAM 3 | DEADBEEC | DEADBEF2 |
| 0 HBl W -BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 HBl W -BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 2 HBl W -BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 3 HBl W -BIOS/=IWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 HBl W -BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 1 HBl W -BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 2 HBl W -BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 3 HBl W -BIOS/=EWRAM 3 | FEFFCAFE | CAFECAFE |
| 0 HBl W -SRAM/=IWRAM 3 | A5B6C7D8 | 00000000 |
| 0 HBl W -SRAM/=EWRAM 3 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+IWRAM 3 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+IWRAM 4 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+IWRAM 5 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+IWRAM 6 | A5B6C7D8 | 00000000 |
| 1 Imm W R+0x10/+IWRAM 3 | FFFFDEAD | DEADDEAD |
| 1 Imm W R+0x10/+IWRAM 4 | FFFFDEAD | DEADDEAD |
| 1 Imm W R+0x10/+IWRAM 5 | FFFFDEAD | DEADDEAD |
| 1 Imm W R+0x10/+IWRAM 6 | FFFFDEAD | DEADDEAD |
| 2 Imm W R+0x10/+IWRAM 3 | FFFFDEAD | DEADDEAD |
| 2 Imm W R+0x10/+IWRAM 4 | FFFFDEAD | DEADDEAD |
| 2 Imm W R+0x10/+IWRAM 5 | FFFFDEAD | DEADDEAD |
| 2 Imm W R+0x10/+IWRAM 6 | FFFFDEAD | DEADDEAD |
| 3 Imm W R+0x10/+IWRAM 3 | FFFFDEAD | DEADDEAD |
| 3 Imm W R+0x10/+IWRAM 4 | FFFFDEAD | DEADDEAD |
| 3 Imm W R+0x10/+IWRAM 5 | FFFFDEAD | DEADDEAD |
| 3 Imm W R+0x10/+IWRAM 6 | FFFFDEAD | DEADDEAD |
| 0 Imm W R+0x10/+EWRAM 3 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+EWRAM 4 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+EWRAM 5 | A5B6C7D8 | 00000000 |
| 0 Imm W R+0x10/+EWRAM 6 | A5B6C7D8 | 00000000 |
| 1 Imm W R+0x10/+EWRAM 3 | FFFFDEAD | DEADDEAD |
| 1 Imm W R+0x10/+EWRAM 4 | FFFFDEAD | DEADDEAD |
| 1 Imm W R+0x10/+EWRAM 5 | FFFFDEAD | DEADDEAD |
| 1 Imm W R+0x10/+EWRAM 6 | FFFFDEAD | DEADDEAD |
| 2 Imm W R+0x10/+EWRAM 3 | FFFFDEAD | DEADDEAD |
| 2 Imm W R+0x10/+EWRAM 4 | FFFFDEAD | DEADDEAD |
| 2 Imm W R+0x10/+EWRAM 5 | FFFFDEAD | DEADDEAD |
| 2 Imm W R+0x10/+EWRAM 6 | FFFFDEAD | DEADDEAD |
| 3 Imm W R+0x10/+EWRAM 3 | FFFFDEAD | DEADDEAD |
| 3 Imm W R+0x10/+EWRAM 4 | FFFFDEAD | DEADDEAD |
| 3 Imm W R+0x10/+EWRAM 5 | FFFFDEAD | DEADDEAD |
| 3 Imm W R+0x10/+EWRAM 6 | FFFFDEAD | DEADDEAD |

## SIO register R/W tests

All tests passed.

## SIO timing tests

All tests passed.

## Misc. edge case tests (1/10 passed)

1/10 tests passed, 9 failed:

| Test | Actual | Expected |
|------|--------|----------|
| DMA Prefetch Break | 0x10002A64 | 0x10000004 |
| DMA Prefetch Read | 0xDEAD0000 | 0xE25EF004 |
| H-blank bit start Hblank | 0x000004D1 | 0x000004D0 |
| H-blank bit start Flip 1 | 0x00000085 | 0x000000DB |
| H-blank bit start Flip 2 | 0x000003EC | 0x00000420 |
| H-blank bit start Flip 3 | 0x000000E4 | 0x000000C1 |
| H-blank bit start Flip 4 | 0x000003EC | 0x000003E0 |
| H-blank bit start Flip 5 | 0x000000E4 | 0x000000E0 |
| H-blank bit start Flip 6 | 0x000003F5 | 0x000003EF |

## Video tests (timed out)

Suite did not complete (emulator timed out).

## Summary

- **Total:** 7008
- **Pass:** 4239
- **Fail:** 2769
