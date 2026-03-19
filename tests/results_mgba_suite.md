# mGBA Test Suite - Detailed Results

*Generated: 2026-03-19 13:09:33*

## Memory tests (1376/1552 passed)

1376/1552 tests passed, 176 failed:

| Test | Actual | Expected |
|------|--------|----------|
| ROM load DMA0 16 | 0x00001DB2 | 0x0000FACE |
| ROM load DMA0 16 (unaligned) | 0x00001DB2 | 0x0000FACE |
| ROM load DMA0 32 | 0xE1C21DB2 | 0xFEEDFACE |
| ROM load DMA0 32 (unaligned 1) | 0xE1C21DB2 | 0xFEEDFACE |
| ROM load DMA0 32 (unaligned 2) | 0xE1C21DB2 | 0xFEEDFACE |
| ROM load DMA0 32 (unaligned 3) | 0xE1C21DB2 | 0xFEEDFACE |
| ROM out-of-bounds load DMA0 16 | 0x00000000 | 0x0000FACE |
| ROM out-of-bounds load DMA0 16 (unaligned) | 0x00000000 | 0x0000FACE |
| ROM out-of-bounds load DMA0 32 | 0x00000000 | 0xFEEDFACE |
| ROM out-of-bounds load DMA0 32 (unaligned 1) | 0x00000000 | 0xFEEDFACE |
| ROM out-of-bounds load DMA0 32 (unaligned 2) | 0x00000000 | 0xFEEDFACE |
| ROM out-of-bounds load DMA0 32 (unaligned 3) | 0x00000000 | 0xFEEDFACE |
| SRAM load U16 (unaligned) | 0x47000047 | 0x61000061 |
| SRAM load 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM load 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM load 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM load swi B 16 (unaligned) | 0x006D0047 | 0x00650061 |
| SRAM load swi B 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM load swi B 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM load swi B 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM load swi C 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM load swi C 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM load swi C 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM mirror load U16 (unaligned) | 0x47000047 | 0x61000061 |
| SRAM mirror load 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM mirror load 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM mirror load 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM mirror load swi B 16 (unaligned) | 0x006D0047 | 0x00650061 |
| SRAM mirror load swi B 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM mirror load swi B 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM mirror load swi B 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM mirror load swi C 32 (unaligned 1) | 0x47474747 | 0x61616161 |
| SRAM mirror load swi C 32 (unaligned 2) | 0x47474747 | 0x6D6D6D6D |
| SRAM mirror load swi C 32 (unaligned 3) | 0x47474747 | 0x65656565 |
| SRAM store U16 (unaligned) | 0x0000D8D8 | 0x00006666 |
| SRAM store 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi B 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi B 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi B 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi C 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi C 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM store swi C 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store U16 (unaligned) | 0x0000D8D8 | 0x00006666 |
| SRAM mirror store 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi B 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi B 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi B 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi C 32 (unaligned 1) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi C 32 (unaligned 2) | 0xD8D8D8D8 | 0x66666666 |
| SRAM mirror store swi C 32 (unaligned 3) | 0xD8D8D8D8 | 0x66666666 |
| BIOS load U8 | 0x00000006 | 0x00000004 |
| BIOS load S8 | 0x00000006 | 0x00000004 |
| BIOS load U16 | 0x00000006 | 0x00002004 |
| BIOS load U16 (unaligned) | 0x06000000 | 0x04000020 |
| BIOS load S16 | 0x00000006 | 0x00002004 |
| BIOS load S16 (unaligned) | 0x00000000 | 0x00000020 |
| BIOS load 32 | 0xEA000006 | 0xE3A02004 |
| BIOS load 32 (unaligned 1) | 0x06EA0000 | 0x04E3A020 |
| BIOS load 32 (unaligned 2) | 0x0006EA00 | 0x2004E3A0 |
| BIOS load 32 (unaligned 3) | 0x000006EA | 0xA02004E3 |
| BIOS load DMA0 16 | 0x00000006 | 0x0000FACE |
| BIOS load DMA0 16 (unaligned) | 0x00000006 | 0x0000FACE |
| BIOS load DMA0 32 | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA0 32 (unaligned 1) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA0 32 (unaligned 2) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA0 32 (unaligned 3) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA1 16 | 0x00000006 | 0x0000FACE |
| BIOS load DMA1 16 (unaligned) | 0x00000006 | 0x0000FACE |
| BIOS load DMA1 32 | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA1 32 (unaligned 1) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA1 32 (unaligned 2) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA1 32 (unaligned 3) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA2 16 | 0x00000006 | 0x0000FACE |
| BIOS load DMA2 16 (unaligned) | 0x00000006 | 0x0000FACE |
| BIOS load DMA2 32 | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA2 32 (unaligned 1) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA2 32 (unaligned 2) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA2 32 (unaligned 3) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA3 16 | 0x00000006 | 0x0000FACE |
| BIOS load DMA3 16 (unaligned) | 0x00000006 | 0x0000FACE |
| BIOS load DMA3 32 | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA3 32 (unaligned 1) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA3 32 (unaligned 2) | 0xEA000006 | 0xFEEDFACE |
| BIOS load DMA3 32 (unaligned 3) | 0xEA000006 | 0xFEEDFACE |
| BIOS load swi B 16 | 0xEA000006 | 0x00000000 |
| BIOS load swi B 16 (unaligned) | 0x00EA0000 | 0x00000000 |
| BIOS load swi B 32 | 0xEA000006 | 0x00000000 |
| BIOS load swi B 32 (unaligned 1) | 0xEA000006 | 0x00000000 |
| BIOS load swi B 32 (unaligned 2) | 0xEA000006 | 0x00000000 |
| BIOS load swi B 32 (unaligned 3) | 0xEA000006 | 0x00000000 |
| BIOS load swi C 32 | 0xEA000006 | 0x00000000 |
| BIOS load swi C 32 (unaligned 1) | 0xEA000006 | 0x00000000 |
| BIOS load swi C 32 (unaligned 2) | 0xEA000006 | 0x00000000 |
| BIOS load swi C 32 (unaligned 3) | 0xEA000006 | 0x00000000 |
| BIOS out-of-bounds load U8 | 0x00000006 | 0x00000001 |
| BIOS out-of-bounds load S8 | 0x00000006 | 0x00000002 |
| BIOS out-of-bounds load U16 | 0x00000006 | 0x00002003 |
| BIOS out-of-bounds load U16 (unaligned) | 0x06000000 | 0x04000020 |
| BIOS out-of-bounds load S16 | 0x00000006 | 0x00002005 |
| BIOS out-of-bounds load S16 (unaligned) | 0x00000000 | 0x00000020 |
| BIOS out-of-bounds load 32 | 0xEA000006 | 0xE3A02007 |
| BIOS out-of-bounds load 32 (unaligned 1) | 0x06EA0000 | 0x08E3A020 |
| BIOS out-of-bounds load 32 (unaligned 2) | 0x0006EA00 | 0x2009E3A0 |
| BIOS out-of-bounds load 32 (unaligned 3) | 0x000006EA | 0x9F000CE5 |
| BIOS out-of-bounds load DMA0 16 | 0x00000006 | 0x0000FACE |
| BIOS out-of-bounds load DMA0 16 (unaligned) | 0x00000006 | 0x0000FACE |
| BIOS out-of-bounds load DMA0 32 | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA0 32 (unaligned 1) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA0 32 (unaligned 2) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA0 32 (unaligned 3) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA1 16 | 0x00000006 | 0x0000FACE |
| BIOS out-of-bounds load DMA1 16 (unaligned) | 0x00000006 | 0x0000FACE |
| BIOS out-of-bounds load DMA1 32 | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA1 32 (unaligned 1) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA1 32 (unaligned 2) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA1 32 (unaligned 3) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA2 16 | 0x00000006 | 0x0000FACE |
| BIOS out-of-bounds load DMA2 16 (unaligned) | 0x00000006 | 0x0000FACE |
| BIOS out-of-bounds load DMA2 32 | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA2 32 (unaligned 1) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA2 32 (unaligned 2) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA2 32 (unaligned 3) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA3 16 | 0x00000006 | 0x0000FACE |
| BIOS out-of-bounds load DMA3 16 (unaligned) | 0x00000006 | 0x0000FACE |
| BIOS out-of-bounds load DMA3 32 | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA3 32 (unaligned 1) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA3 32 (unaligned 2) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load DMA3 32 (unaligned 3) | 0xEA000006 | 0xFEEDFACE |
| BIOS out-of-bounds load swi B 16 | 0xEA000006 | 0x00000000 |
| BIOS out-of-bounds load swi B 16 (unaligned) | 0x00EA0000 | 0x00000000 |
| BIOS out-of-bounds load swi B 32 | 0xEA000006 | 0x00000000 |
| BIOS out-of-bounds load swi B 32 (unaligned 1) | 0xEA000006 | 0x00000000 |
| BIOS out-of-bounds load swi B 32 (unaligned 2) | 0xEA000006 | 0x00000000 |
| BIOS out-of-bounds load swi B 32 (unaligned 3) | 0xEA000006 | 0x00000000 |
| BIOS out-of-bounds load swi C 32 | 0xEA000006 | 0x00000000 |
| BIOS out-of-bounds load swi C 32 (unaligned 1) | 0xEA000006 | 0x00000000 |
| BIOS out-of-bounds load swi C 32 (unaligned 2) | 0xEA000006 | 0x00000000 |
| BIOS out-of-bounds load swi C 32 (unaligned 3) | 0xEA000006 | 0x00000000 |
| Out-of-bounds load U8 | 0x00000000 | 0x00000001 |
| Out-of-bounds load S8 | 0x00000000 | 0x00000002 |
| Out-of-bounds load U16 | 0x00000000 | 0x00002003 |
| Out-of-bounds load U16 (unaligned) | 0x00000000 | 0x04000020 |
| Out-of-bounds load S16 | 0x00000000 | 0x00002005 |
| Out-of-bounds load S16 (unaligned) | 0x00000000 | 0x00000020 |
| Out-of-bounds load 32 | 0x00000000 | 0xE3A02007 |
| Out-of-bounds load 32 (unaligned 1) | 0x00000000 | 0x08E3A020 |
| Out-of-bounds load 32 (unaligned 2) | 0x00000000 | 0x2009E3A0 |
| Out-of-bounds load 32 (unaligned 3) | 0x00000000 | 0x9F000CE5 |
| Out-of-bounds load DMA0 16 | 0x00000000 | 0x0000FACE |
| Out-of-bounds load DMA0 16 (unaligned) | 0x00000000 | 0x0000FACE |
| Out-of-bounds load DMA0 32 | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA0 32 (unaligned 1) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA0 32 (unaligned 2) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA0 32 (unaligned 3) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA1 16 | 0x00000000 | 0x0000FACE |
| Out-of-bounds load DMA1 16 (unaligned) | 0x00000000 | 0x0000FACE |
| Out-of-bounds load DMA1 32 | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA1 32 (unaligned 1) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA1 32 (unaligned 2) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA1 32 (unaligned 3) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA2 16 | 0x00000000 | 0x0000FACE |
| Out-of-bounds load DMA2 16 (unaligned) | 0x00000000 | 0x0000FACE |
| Out-of-bounds load DMA2 32 | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA2 32 (unaligned 1) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA2 32 (unaligned 2) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA2 32 (unaligned 3) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA3 16 | 0x00000000 | 0x0000FACE |
| Out-of-bounds load DMA3 16 (unaligned) | 0x00000000 | 0x0000FACE |
| Out-of-bounds load DMA3 32 | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA3 32 (unaligned 1) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA3 32 (unaligned 2) | 0x00000000 | 0xFEEDFACE |
| Out-of-bounds load DMA3 32 (unaligned 3) | 0x00000000 | 0xFEEDFACE |

## I/O read tests

All tests passed.

## Timing tests (177/2020 passed)

177/2020 tests passed, 1843 failed:

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
| b pc ARM/ROM ... | 8 | 26 |
| b pc ARM/ROM P.. | 8 | 26 |
| b pc ARM/ROM .N. | 8 | 25 |
| b pc ARM/ROM PN. | 8 | 25 |
| b pc ARM/ROM ..S | 8 | 19 |
| b pc ARM/ROM P.S | 8 | 19 |
| b pc ARM/ROM .NS | 8 | 18 |
| b pc ARM/ROM PNS | 8 | 18 |
| b pc ARM/WRAM | 12 | 24 |
| b pc ARM/IWRAM | 2 | 4 |
| b pc Thumb/ROM ... | 4 | 14 |
| b pc Thumb/ROM P.. | 4 | 14 |
| b pc Thumb/ROM .N. | 4 | 13 |
| b pc Thumb/ROM PN. | 4 | 13 |
| b pc Thumb/ROM ..S | 4 | 11 |
| b pc Thumb/ROM P.S | 4 | 11 |
| b pc Thumb/ROM .NS | 4 | 10 |
| b pc Thumb/ROM PNS | 4 | 10 |
| b pc Thumb/WRAM | 6 | 12 |
| b pc Thumb/IWRAM | 2 | 4 |
| nop ; b pc ARM/ROM ... | 8 | 26 |
| nop ; b pc ARM/ROM P.. | 8 | 26 |
| nop ; b pc ARM/ROM .N. | 8 | 25 |
| nop ; b pc ARM/ROM PN. | 8 | 25 |
| nop ; b pc ARM/ROM ..S | 8 | 19 |
| nop ; b pc ARM/ROM P.S | 8 | 19 |
| nop ; b pc ARM/ROM .NS | 8 | 18 |
| nop ; b pc ARM/ROM PNS | 8 | 18 |
| nop ; b pc ARM/WRAM | 12 | 24 |
| nop ; b pc ARM/IWRAM | 2 | 4 |
| nop ; b pc Thumb/ROM ... | 4 | 14 |
| nop ; b pc Thumb/ROM P.. | 4 | 14 |
| nop ; b pc Thumb/ROM .N. | 4 | 13 |
| nop ; b pc Thumb/ROM PN. | 4 | 13 |
| nop ; b pc Thumb/ROM ..S | 4 | 11 |
| nop ; b pc Thumb/ROM P.S | 4 | 11 |
| nop ; b pc Thumb/ROM .NS | 4 | 10 |
| nop ; b pc Thumb/ROM PNS | 4 | 10 |
| nop ; b pc Thumb/WRAM | 6 | 12 |
| nop ; b pc Thumb/IWRAM | 2 | 4 |
| bx ARM/ROM ... | 34 | 78 |
| bx ARM/ROM P.. | 34 | 78 |
| bx ARM/ROM .N. | 34 | 74 |
| bx ARM/ROM PN. | 34 | 74 |
| bx ARM/ROM ..S | 34 | 59 |
| bx ARM/ROM P.S | 34 | 59 |
| bx ARM/ROM .NS | 34 | 55 |
| bx ARM/ROM PNS | 34 | 55 |
| bx ARM/WRAM | 50 | 72 |
| bx ARM/IWRAM | 10 | 22 |
| bx Thumb/ROM ... | 24 | 57 |
| bx Thumb/ROM P.. | 24 | 57 |
| bx Thumb/ROM .N. | 24 | 53 |
| bx Thumb/ROM PN. | 24 | 53 |
| bx Thumb/ROM ..S | 24 | 45 |
| bx Thumb/ROM P.S | 24 | 45 |
| bx Thumb/ROM .NS | 24 | 41 |
| bx Thumb/ROM PNS | 24 | 41 |
| bx Thumb/WRAM | 35 | 51 |
| bx Thumb/IWRAM | 12 | 24 |
| Trivial loop ARM/ROM ... | 200 | 510 |
| Trivial loop ARM/ROM P.. | 200 | 510 |
| Trivial loop ARM/ROM .N. | 200 | 495 |
| Trivial loop ARM/ROM PN. | 200 | 495 |
| Trivial loop ARM/ROM ..S | 200 | 365 |
| Trivial loop ARM/ROM P.S | 200 | 365 |
| Trivial loop ARM/ROM .NS | 200 | 350 |
| Trivial loop ARM/ROM PNS | 200 | 350 |
| Trivial loop ARM/WRAM | 300 | 480 |
| Trivial loop ARM/IWRAM | 50 | 80 |
| Trivial loop Thumb/ROM ... | 100 | 270 |
| Trivial loop Thumb/ROM P.. | 100 | 270 |
| Trivial loop Thumb/ROM .N. | 100 | 255 |
| Trivial loop Thumb/ROM PN. | 100 | 255 |
| Trivial loop Thumb/ROM ..S | 100 | 205 |
| Trivial loop Thumb/ROM P.S | 100 | 205 |
| Trivial loop Thumb/ROM .NS | 100 | 190 |
| Trivial loop Thumb/ROM PNS | 100 | 190 |
| Trivial loop Thumb/WRAM | 150 | 240 |
| Trivial loop Thumb/IWRAM | 50 | 80 |
| C loop ARM/ROM ... | 169 | 346 |
| C loop ARM/ROM P.. | 169 | 231 |
| C loop ARM/ROM .N. | 169 | 309 |
| C loop ARM/ROM PN. | 169 | 227 |
| C loop ARM/ROM ..S | 169 | 309 |
| C loop ARM/ROM P.S | 169 | 161 |
| C loop ARM/ROM .NS | 169 | 272 |
| C loop ARM/ROM PNS | 169 | 157 |
| C loop ARM/WRAM | 185 | 340 |
| C loop ARM/IWRAM | 145 | 290 |
| C loop Thumb/ROM ... | 159 | 325 |
| C loop Thumb/ROM P.. | 159 | 210 |
| C loop Thumb/ROM .N. | 159 | 288 |
| C loop Thumb/ROM PN. | 159 | 206 |
| C loop Thumb/ROM ..S | 159 | 295 |
| C loop Thumb/ROM P.S | 159 | 147 |
| C loop Thumb/ROM .NS | 159 | 258 |
| C loop Thumb/ROM PNS | 159 | 143 |
| C loop Thumb/WRAM | 170 | 319 |
| C loop Thumb/IWRAM | 147 | 292 |
| BIOS Division ARM/ROM ... | 295 | 398 |
| BIOS Division ARM/ROM P.. | 295 | 398 |
| BIOS Division ARM/ROM .N. | 295 | 394 |
| BIOS Division ARM/ROM PN. | 295 | 394 |
| BIOS Division ARM/ROM ..S | 295 | 381 |
| BIOS Division ARM/ROM P.S | 295 | 381 |
| BIOS Division ARM/ROM .NS | 295 | 377 |
| BIOS Division ARM/ROM PNS | 295 | 377 |
| BIOS Division ARM/WRAM | 312 | 390 |
| BIOS Division ARM/IWRAM | 270 | 338 |
| BIOS Division Thumb/ROM ... | 281 | 371 |
| BIOS Division Thumb/ROM P.. | 281 | 371 |
| BIOS Division Thumb/ROM .N. | 281 | 367 |
| BIOS Division Thumb/ROM PN. | 281 | 367 |
| BIOS Division Thumb/ROM ..S | 281 | 363 |
| BIOS Division Thumb/ROM P.S | 281 | 363 |
| BIOS Division Thumb/ROM .NS | 281 | 359 |
| BIOS Division Thumb/ROM PNS | 281 | 359 |
| BIOS Division Thumb/WRAM | 291 | 363 |
| BIOS Division Thumb/IWRAM | 270 | 338 |
| BIOS Division 2 ARM/ROM ... | 95 | 138 |
| BIOS Division 2 ARM/ROM P.. | 95 | 138 |
| BIOS Division 2 ARM/ROM .N. | 95 | 134 |
| BIOS Division 2 ARM/ROM PN. | 95 | 134 |
| BIOS Division 2 ARM/ROM ..S | 95 | 121 |
| BIOS Division 2 ARM/ROM P.S | 95 | 121 |
| BIOS Division 2 ARM/ROM .NS | 95 | 117 |
| BIOS Division 2 ARM/ROM PNS | 95 | 117 |
| BIOS Division 2 ARM/WRAM | 112 | 130 |
| BIOS Division 2 ARM/IWRAM | 70 | 78 |
| BIOS Division 2 Thumb/ROM ... | 81 | 111 |
| BIOS Division 2 Thumb/ROM P.. | 81 | 111 |
| BIOS Division 2 Thumb/ROM .N. | 81 | 107 |
| BIOS Division 2 Thumb/ROM PN. | 81 | 107 |
| BIOS Division 2 Thumb/ROM ..S | 81 | 103 |
| BIOS Division 2 Thumb/ROM P.S | 81 | 103 |
| BIOS Division 2 Thumb/ROM .NS | 81 | 99 |
| BIOS Division 2 Thumb/ROM PNS | 81 | 99 |
| BIOS Division 2 Thumb/WRAM | 91 | 103 |
| BIOS Division 2 Thumb/IWRAM | 70 | 78 |
| BIOS Sqrt ARM/ROM ... | 84 | 150 |
| BIOS Sqrt ARM/ROM P.. | 84 | 150 |
| BIOS Sqrt ARM/ROM .N. | 84 | 148 |
| BIOS Sqrt ARM/ROM PN. | 84 | 148 |
| BIOS Sqrt ARM/ROM ..S | 84 | 135 |
| BIOS Sqrt ARM/ROM P.S | 84 | 135 |
| BIOS Sqrt ARM/ROM .NS | 84 | 133 |
| BIOS Sqrt ARM/ROM PNS | 84 | 133 |
| BIOS Sqrt ARM/WRAM | 97 | 146 |
| BIOS Sqrt ARM/IWRAM | 65 | 104 |
| BIOS Sqrt Thumb/ROM ... | 72 | 126 |
| BIOS Sqrt Thumb/ROM P.. | 72 | 126 |
| BIOS Sqrt Thumb/ROM .N. | 72 | 124 |
| BIOS Sqrt Thumb/ROM PN. | 72 | 124 |
| BIOS Sqrt Thumb/ROM ..S | 72 | 119 |
| BIOS Sqrt Thumb/ROM P.S | 72 | 119 |
| BIOS Sqrt Thumb/ROM .NS | 72 | 117 |
| BIOS Sqrt Thumb/ROM PNS | 72 | 117 |
| BIOS Sqrt Thumb/WRAM | 79 | 122 |
| BIOS Sqrt Thumb/IWRAM | 65 | 104 |
| BIOS Sqrt 2 ARM/ROM ... | 108 | 265 |
| BIOS Sqrt 2 ARM/ROM P.. | 108 | 265 |
| BIOS Sqrt 2 ARM/ROM .N. | 108 | 263 |
| BIOS Sqrt 2 ARM/ROM PN. | 108 | 263 |
| BIOS Sqrt 2 ARM/ROM ..S | 108 | 250 |
| BIOS Sqrt 2 ARM/ROM P.S | 108 | 250 |
| BIOS Sqrt 2 ARM/ROM .NS | 108 | 248 |
| BIOS Sqrt 2 ARM/ROM PNS | 108 | 248 |
| BIOS Sqrt 2 ARM/WRAM | 121 | 261 |
| BIOS Sqrt 2 ARM/IWRAM | 89 | 219 |
| BIOS Sqrt 2 Thumb/ROM ... | 96 | 241 |
| BIOS Sqrt 2 Thumb/ROM P.. | 96 | 241 |
| BIOS Sqrt 2 Thumb/ROM .N. | 96 | 239 |
| BIOS Sqrt 2 Thumb/ROM PN. | 96 | 239 |
| BIOS Sqrt 2 Thumb/ROM ..S | 96 | 234 |
| BIOS Sqrt 2 Thumb/ROM P.S | 96 | 234 |
| BIOS Sqrt 2 Thumb/ROM .NS | 96 | 232 |
| BIOS Sqrt 2 Thumb/ROM PNS | 96 | 232 |
| BIOS Sqrt 2 Thumb/WRAM | 103 | 237 |
| BIOS Sqrt 2 Thumb/IWRAM | 89 | 219 |
| BIOS Sqrt 3 ARM/ROM ... | 222 | 1192 |
| BIOS Sqrt 3 ARM/ROM P.. | 222 | 1192 |
| BIOS Sqrt 3 ARM/ROM .N. | 222 | 1188 |
| BIOS Sqrt 3 ARM/ROM PN. | 222 | 1188 |
| BIOS Sqrt 3 ARM/ROM ..S | 222 | 1177 |
| BIOS Sqrt 3 ARM/ROM P.S | 222 | 1177 |
| BIOS Sqrt 3 ARM/ROM .NS | 222 | 1173 |
| BIOS Sqrt 3 ARM/ROM PNS | 222 | 1173 |
| BIOS Sqrt 3 ARM/WRAM | 237 | 1184 |
| BIOS Sqrt 3 ARM/IWRAM | 200 | 1137 |
| BIOS Sqrt 3 Thumb/ROM ... | 210 | 1168 |
| BIOS Sqrt 3 Thumb/ROM P.. | 210 | 1168 |
| BIOS Sqrt 3 Thumb/ROM .N. | 210 | 1164 |
| BIOS Sqrt 3 Thumb/ROM PN. | 210 | 1164 |
| BIOS Sqrt 3 Thumb/ROM ..S | 210 | 1161 |
| BIOS Sqrt 3 Thumb/ROM P.S | 210 | 1161 |
| BIOS Sqrt 3 Thumb/ROM .NS | 210 | 1157 |
| BIOS Sqrt 3 Thumb/ROM PNS | 210 | 1157 |
| BIOS Sqrt 3 Thumb/WRAM | 219 | 1160 |
| BIOS Sqrt 3 Thumb/IWRAM | 200 | 1137 |
| BIOS ArcTan ARM/ROM ... | 93 | 150 |
| BIOS ArcTan ARM/ROM P.. | 93 | 150 |
| BIOS ArcTan ARM/ROM .N. | 93 | 148 |
| BIOS ArcTan ARM/ROM PN. | 93 | 148 |
| BIOS ArcTan ARM/ROM ..S | 93 | 135 |
| BIOS ArcTan ARM/ROM P.S | 93 | 135 |
| BIOS ArcTan ARM/ROM .NS | 93 | 133 |
| BIOS ArcTan ARM/ROM PNS | 93 | 133 |
| BIOS ArcTan ARM/WRAM | 106 | 146 |
| BIOS ArcTan ARM/IWRAM | 74 | 104 |
| BIOS ArcTan Thumb/ROM ... | 81 | 126 |
| BIOS ArcTan Thumb/ROM P.. | 81 | 126 |
| BIOS ArcTan Thumb/ROM .N. | 81 | 124 |
| BIOS ArcTan Thumb/ROM PN. | 81 | 124 |
| BIOS ArcTan Thumb/ROM ..S | 81 | 119 |
| BIOS ArcTan Thumb/ROM P.S | 81 | 119 |
| BIOS ArcTan Thumb/ROM .NS | 81 | 117 |
| BIOS ArcTan Thumb/ROM PNS | 81 | 117 |
| BIOS ArcTan Thumb/WRAM | 88 | 122 |
| BIOS ArcTan Thumb/IWRAM | 74 | 104 |
| CpuSet ARM/ROM ... | 3293 | 3453 |
| CpuSet ARM/ROM P.. | 3293 | 3453 |
| CpuSet ARM/ROM .N. | 3293 | 3451 |
| CpuSet ARM/ROM PN. | 3293 | 3451 |
| CpuSet ARM/ROM ..S | 3293 | 3434 |
| CpuSet ARM/ROM P.S | 3293 | 3434 |
| CpuSet ARM/ROM .NS | 3293 | 3432 |
| CpuSet ARM/ROM PNS | 3293 | 3432 |
| CpuSet ARM/WRAM | 3310 | 3449 |
| CpuSet ARM/IWRAM | 3268 | 3397 |
| CpuSet Thumb/ROM ... | 3289 | 3456 |
| CpuSet Thumb/ROM P.. | 3289 | 3456 |
| CpuSet Thumb/ROM .N. | 3289 | 3448 |
| CpuSet Thumb/ROM PN. | 3289 | 3448 |
| CpuSet Thumb/ROM ..S | 3289 | 3447 |
| CpuSet Thumb/ROM P.S | 3289 | 3447 |
| CpuSet Thumb/ROM .NS | 3289 | 3439 |
| CpuSet Thumb/ROM PNS | 3289 | 3439 |
| CpuSet Thumb/WRAM | 3304 | 3440 |
| CpuSet Thumb/IWRAM | 3271 | 3403 |
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

## Timer count-up tests (timed out)

Suite did not complete (emulator timed out).

## Summary

- **Total:** 3702
- **Pass:** 1683
- **Fail:** 2019
