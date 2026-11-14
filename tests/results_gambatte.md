# gambatte Test Suite - Detailed Results

*Generated: 2026-11-13 17:47:39*

Each row is one ROM run on one device. `[dmg]` / `[cgb]` is the
device the filename asks for; `[.., png]` rows are scored against the
reference image next to the ROM, the rest against the hex value the
ROM draws on screen. See tests/README.md for the mechanism.

**5208/5213 passed.**

## bgen

All 2 tests passed.

## bgtiledata

All 34 tests passed.

## bgtilemap

All 40 tests passed.

## cgbpal_m3 (43/44 passed)

43/44 tests passed, 1 failed:

| Test | Result |
|------|--------|
| cgbpal_m3/cgbpal_read_m3start_lcdoffset1_1_cgb04c_out00 [cgb] | got FF, expected 00 |

## display_startstate

All 14 tests passed.

## div

All 8 tests passed.

## dma

All 229 tests passed.

## dmgpalette_during_m3

All 17 tests passed.

## enable_display

All 184 tests passed.

## halt

All 158 tests passed.

## irq_precedence

All 64 tests passed.

## lcd_offset

All 62 tests passed.

## lcdirq_precedence

All 62 tests passed.

## ly0

All 96 tests passed.

## lyc0int_m0irq

All 6 tests passed.

## lyc153int_m2irq

All 16 tests passed.

## lycEnable

All 225 tests passed.

## lycint_ly

All 6 tests passed.

## lycint_lycflag

All 12 tests passed.

## lycint_lycirq

All 4 tests passed.

## lycint_m0stat

All 6 tests passed.

## lycm2int

All 18 tests passed.

## lywrite

All 8 tests passed.

## m0enable

All 167 tests passed.

## m0int_m0irq

All 4 tests passed.

## m0int_m0stat

All 12 tests passed.

## m0int_m3stat

All 6 tests passed.

## m1

All 170 tests passed.

## m2enable

All 120 tests passed.

## m2int_m0irq

All 72 tests passed.

## m2int_m0stat

All 6 tests passed.

## m2int_m2irq

All 18 tests passed.

## m2int_m2stat

All 8 tests passed.

## m2int_m3stat

All 44 tests passed.

## miscmstatirq

All 279 tests passed.

## oam_access

All 69 tests passed.

## oamdma

All 802 tests passed.

## scx_during_m3

All 138 tests passed.

## scy

All 67 tests passed.

## serial

All 82 tests passed.

## sound

All 300 tests passed.

## speedchange

All 244 tests passed.

## sprites

All 476 tests passed.

## tima

All 232 tests passed.

## undef_ops

All 20 tests passed.

## vram_m3 (48/50 passed)

48/50 tests passed, 2 failed:

| Test | Result |
|------|--------|
| vram_m3/preread_lcdoffset1_2_cgb04c_out3 [cgb] | got 0, expected 3 |
| vram_m3/prewrite_lcdoffset1_2_cgb04c_out0 [cgb] | got 1, expected 0 |

## vramw_m3end

All 36 tests passed.

## window (474/476 passed)

474/476 tests passed, 2 failed:

| Test | Result |
|------|--------|
| window/arg/late_wy_1toFF_lcdoffset1_1_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/late_enable_afterVblank_lcdoffset1_1_cgb04c_out3 [cgb] | got 0, expected 3 |
