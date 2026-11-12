# gambatte Test Suite - Detailed Results

*Generated: 2026-11-12 11:02:19*

Each row is one ROM run on one device. `[dmg]` / `[cgb]` is the
device the filename asks for; `[.., png]` rows are scored against the
reference image next to the ROM, the rest against the hex value the
ROM draws on screen. See tests/README.md for the mechanism.

**5184/5213 passed.**

## bgen

All 2 tests passed.

## bgtiledata

All 34 tests passed.

## bgtilemap

All 40 tests passed.

## cgbpal_m3

All 44 tests passed.

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

## lycEnable (208/225 passed)

208/225 tests passed, 17 failed:

| Test | Result |
|------|--------|
| lycEnable/ff41_disable_2_dmg08_out0_cgb04c_out2 [cgb] | got 0, expected 2 |
| lycEnable/ff45_enable_weirdpoint_2_dmg08_out3_cgb04c_out1 [cgb] | got 3, expected 1 |
| lycEnable/ff45_enable_weirdpoint_ds_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| lycEnable/ff45_enable_weirdpoint_ds_lcdoffset1_2_cgb04c_out0 [cgb] | got 2, expected 0 |
| lycEnable/ff45_enable_weirdpoint_ds_lcdoffset1_3_cgb04c_out0 [cgb] | got 2, expected 0 |
| lycEnable/ff45_enable_weirdpoint_ds_lcdoffset1_4_cgb04c_out2 [cgb] | got 0, expected 2 |
| lycEnable/ff45_enable_weirdpoint_lcdoffset1_2_cgb04c_out0 [cgb] | got 2, expected 0 |
| lycEnable/late_ff41_enable_ds_1_cgb04c_out3 [cgb] | got 1, expected 3 |
| lycEnable/late_ff41_enable_lcdoffset1_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| lycEnable/late_ff45_enable_ds_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| lycEnable/late_ff45_enable_ds_lcdoffset1_2_cgb04c_out0 [cgb] | got 2, expected 0 |
| lycEnable/lyc153_late_ff41_enable_ds_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lyc153_late_ff41_enable_ds_lcdoffset1_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lyc153_late_ff41_enable_lcdoffset1_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lyc153_late_ff45_enable_ds_2_cgb04c_outE0 [cgb] | got E2, expected E0 |
| lycEnable/lyc153_late_ff45_enable_lcdoffset1_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lycwirq_trigger_ly00_stat50_ds_lcdoffset1_2_cgb04c_outE2 [cgb] | got E0, expected E2 |

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

## m1 (164/170 passed)

164/170 tests passed, 6 failed:

| Test | Result |
|------|--------|
| m1/ly143_late_m0enable_2_dmg08_out3_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/ly143_late_m2enable_2_dmg08_out3_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/ly143_late_m2enable_ds_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/ly143_late_m2enable_ds_lcdoffset1_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/lyc143_late_m0enable_lycdisable_2_dmg08_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/lyc143_late_m2enable_lycdisable_2_dmg08_cgb04c_out1 [cgb] | got 3, expected 1 |

## m2enable (117/120 passed)

117/120 tests passed, 3 failed:

| Test | Result |
|------|--------|
| m2enable/late_enable_lcdoffset2_2_cgb04c_out0 [cgb] | got 2, expected 0 |
| m2enable/late_enable_ly0_lcdoffset2_2_cgb04c_out0 [cgb] | got 2, expected 0 |
| m2enable/late_enable_m0disable_2_dmg08_out0_cgb04c_out2 [cgb] | got 0, expected 2 |

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

## miscmstatirq (276/279 passed)

276/279 tests passed, 3 failed:

| Test | Result |
|------|--------|
| miscmstatirq/lycstatwirq_trigger_ly00_10_50_lcdoffset3_2_cgb04c_outE2 [cgb] | got E0, expected E2 |
| miscmstatirq/lycstatwirq_trigger_m0_late_ly44_lyc44_08_40_ds_3_cgb04c_outE2 [cgb] | got E0, expected E2 |
| miscmstatirq/lycwirq_trigger_m0_late_ly44_lyc45_ds_3_cgb04c_outE2 [cgb] | got E0, expected E2 |

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

## vram_m3

All 50 tests passed.

## vramw_m3end

All 36 tests passed.

## window

All 476 tests passed.
