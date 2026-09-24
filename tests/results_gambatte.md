# gambatte Test Suite - Detailed Results

*Generated: 2026-09-23 22:00:50*

Each row is one ROM run on one device. `[dmg]` / `[cgb]` is the
device the filename asks for; `[.., png]` rows are scored against the
reference image next to the ROM, the rest against the hex value the
ROM draws on screen. See tests/README.md for the mechanism.

**5192/5216 passed.**

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

## dmgpalette_during_m3 (9/17 passed)

9/17 tests passed, 8 failed:

| Test | Result |
|------|--------|
| dmgpalette_during_m3/dmgpalette_during_m3_3 [dmg, png] | 1/23040 pixels differ |
| dmgpalette_during_m3/dmgpalette_during_m3_4 [dmg, png] | 144/23040 pixels differ |
| dmgpalette_during_m3/dmgpalette_during_m3_5 [dmg, png] | 144/23040 pixels differ |
| dmgpalette_during_m3/dmgpalette_during_m3_scx1_4 [dmg, png] | 1/23040 pixels differ |
| dmgpalette_during_m3/lycint_dmgpalette_during_m3_3 [dmg, png] | 143/23040 pixels differ |
| dmgpalette_during_m3/lycint_dmgpalette_during_m3_4 [dmg, png] | 143/23040 pixels differ |
| dmgpalette_during_m3/scx3/dmgpalette_during_m3_4 [dmg, png] | 1/23040 pixels differ |
| dmgpalette_during_m3/scx3/dmgpalette_during_m3_5 [dmg, png] | 144/23040 pixels differ |

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

## scx_during_m3 (138/141 passed)

138/141 tests passed, 3 failed:

| Test | Result |
|------|--------|
| scx_during_m3/scx_attrib_during_m3_spx2_ds [cgb, png] | 8/23040 pixels differ |
| scx_during_m3/scx_during_m3_spx2 [cgb, png] | 8/23040 pixels differ |
| scx_during_m3/scx_during_m3_spx2_ds [cgb, png] | 8/23040 pixels differ |

## scy

All 67 tests passed.

## serial

All 82 tests passed.

## sound

All 300 tests passed.

## speedchange (231/244 passed)

231/244 tests passed, 13 failed:

| Test | Result |
|------|--------|
| speedchange/speedchange2_ch1_duty0_pos6_to_pos7_timing_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange2_ch1_duty0_pos6_to_pos7_timing_ds_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange2_ch1_duty0_pos6_to_pos7_timing_nop_ds_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange2_nop_ch1_duty0_pos6_to_pos7_timing_ds_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange3_ch1_duty0_pos6_to_pos7_timing_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange3_ch1_duty0_pos6_to_pos7_timing_nop_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange3_nop_ch1_duty0_pos6_to_pos7_timing_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange4_ch1_duty0_pos6_to_pos7_timing_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange4_ch1_duty0_pos6_to_pos7_timing_nop_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange5_ch1_duty0_pos6_to_pos7_timing_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange5_ch1_duty0_pos6_to_pos7_timing_nop_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange5_nop_ch1_duty0_pos6_to_pos7_timing_1_cgb04c_outaudio0 [cgb, audio] | audio1 (mix varies over 35112 samples), expected audio0 |
| speedchange/speedchange_ch1_nr4init_duty0_pos6_to_pos7_timing_2_cgb04c_outaudio1 [cgb, audio] | audio0 (mix constant over 35112 samples), expected audio1 |

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
