# gambatte Test Suite - Detailed Results

*Generated: 2026-09-22 17:25:39*

Each row is one ROM run on one device. `[dmg]` / `[cgb]` is the
device the filename asks for; `[.., png]` rows are scored against the
reference image next to the ROM, the rest against the hex value the
ROM draws on screen. See tests/README.md for the mechanism.

**5151/5216 passed.**

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

## dma (223/229 passed)

223/229 tests passed, 6 failed:

| Test | Result |
|------|--------|
| dma/hdma_late_enable_ds_lcdoffset1_2_cgb04c_out0 [cgb] | got 1, expected 0 |
| dma/hdma_late_enable_lcdoffset3_2_cgb04c_out0 [cgb] | got 1, expected 0 |
| dma/hdma_pc_7ffe_cgb04c_out02 [cgb] | got 80, expected 02 |
| dma/hdma_transition_ei_halt_late_unhalt_ldaaimm_hdma_scx1_1_cgb04c_out00 [cgb] | got 01, expected 00 |
| dma/hdma_transition_speedchange_7fffstop_inc_cgb04c_out02 [cgb] | got 01, expected 02 |
| dma/late_gdma_pc_7ffe_1_cgb04c_out02 [cgb] | got 00, expected 02 |

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

## enable_display (182/184 passed)

182/184 tests passed, 2 failed:

| Test | Result |
|------|--------|
| enable_display/ly0_late_scx7_m3stat_scx0_2_dmg08_out87_cgb04c_out84 [dmg] | got 84, expected 87 |
| enable_display/ly0_late_scx7_m3stat_scx1_1_dmg08_cgb04c_out87 [cgb] | got 84, expected 87 |

## halt

All 158 tests passed.

## irq_precedence

All 64 tests passed.

## lcd_offset (59/62 passed)

59/62 tests passed, 3 failed:

| Test | Result |
|------|--------|
| lcd_offset/offset1_lyc99int_m2stat_count_ds_2_cgb04c_out90 [cgb] | got 00, expected 90 |
| lcd_offset/offset1_lyc99int_m3stat_count_ds_2_cgb04c_out90 [cgb] | got 00, expected 90 |
| lcd_offset/offset3_lyc8fint_m1stat_1_cgb04c_outC0 [cgb] | got C1, expected C0 |

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

## m1 (169/170 passed)

169/170 tests passed, 1 failed:

| Test | Result |
|------|--------|
| m1/ly143_late_m2enable_ds_lcdoffset1_1_cgb04c_out3 [cgb] | got 1, expected 3 |

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

## miscmstatirq (276/279 passed)

276/279 tests passed, 3 failed:

| Test | Result |
|------|--------|
| miscmstatirq/lycwirq_trigger_m0_late_ly44_lyc45_4_dmg08_cgb04c_outE2 [dmg] | got E0, expected E2 |
| miscmstatirq/m0statwirq_scx2_2_dmg08_out2 [dmg] | got 0, expected 2 |
| miscmstatirq/m0statwirq_scx5_2_dmg08_out2 [dmg] | got 0, expected 2 |

## oam_access

All 69 tests passed.

## oamdma (798/802 passed)

798/802 tests passed, 4 failed:

| Test | Result |
|------|--------|
| oamdma/oamdma_src0000_busyint0002_dmg08_cgb04c_outFF941234 [dmg] | got 76871234, expected FF941234 |
| oamdma/oamdma_src0000_busyint0002_dmg08_cgb04c_outFF941234 [cgb] | got 76871234, expected FF941234 |
| oamdma/oamdma_src8000_srcchange0000_busyinc_dmg08_cgb04c_out0 [dmg] | got 1, expected 0 |
| oamdma/oamdma_src8000_srcchange0000_busyinc_dmg08_cgb04c_out0 [cgb] | got 1, expected 0 |

## scx_during_m3 (131/141 passed)

131/141 tests passed, 10 failed:

| Test | Result |
|------|--------|
| scx_during_m3/scx_0761c0/scx_during_m3_2 [cgb, png] | 9/23040 pixels differ |
| scx_during_m3/scx_0761c0/scx_during_m3_3 [cgb, png] | 2448/23040 pixels differ |
| scx_during_m3/scx_0761c0/scx_during_m3_4 [cgb, png] | 3575/23040 pixels differ |
| scx_during_m3/scx_0761c0/scx_during_m3_ds_2 [cgb, png] | 9/23040 pixels differ |
| scx_during_m3/scx_0761c0/scx_during_m3_ds_3 [cgb, png] | 2440/23040 pixels differ |
| scx_during_m3/scx_0761c0/scx_during_m3_ds_4 [cgb, png] | 2448/23040 pixels differ |
| scx_during_m3/scx_0761c0/scx_during_m3_ds_5 [cgb, png] | 2431/23040 pixels differ |
| scx_during_m3/scx_attrib_during_m3_spx2_ds [cgb, png] | 8/23040 pixels differ |
| scx_during_m3/scx_during_m3_spx2 [cgb, png] | 8/23040 pixels differ |
| scx_during_m3/scx_during_m3_spx2_ds [cgb, png] | 8/23040 pixels differ |

## scy

All 67 tests passed.

## serial (77/82 passed)

77/82 tests passed, 5 failed:

| Test | Result |
|------|--------|
| serial/nopx1_start83_wait_read_if_2_dmg08_outE0_cgb04c_outE8 [cgb] | got E0, expected E8 |
| serial/nopx1_start_wait_read_if_2_dmg08_cgb04c_outE8 [dmg] | got E0, expected E8 |
| serial/nopx1_start_wait_read_if_2_dmg08_cgb04c_outE8 [cgb] | got E0, expected E8 |
| serial/start83_late_div_write_wait_read_if_1b_cgb04c_outE8 [cgb] | got E0, expected E8 |
| serial/start83_late_div_write_wait_read_if_2b_cgb04c_outE8 [cgb] | got E0, expected E8 |

## sound (299/300 passed)

299/300 tests passed, 1 failed:

| Test | Result |
|------|--------|
| sound/ch1_duty0_pos6_to_pos7_timing_ds_6_cgb04c_outaudio1 [cgb, audio] | audio0 (mix constant over 35112 samples), expected audio1 |

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

## tima (228/232 passed)

228/232 tests passed, 4 failed:

| Test | Result |
|------|--------|
| tima/tc00_late_tc01_5_dmg08_cgb04c_out00 [dmg] | got FF, expected 00 |
| tima/tc00_late_tc01_5_dmg08_cgb04c_out00 [cgb] | got FF, expected 00 |
| tima/tc00_late_tc01_7_dmg08_cgb04c_outFF [dmg] | got FE, expected FF |
| tima/tc00_late_tc01_7_dmg08_cgb04c_outFF [cgb] | got FE, expected FF |

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

## window (473/476 passed)

473/476 tests passed, 3 failed:

| Test | Result |
|------|--------|
| window/late_disable_scx5_ds_1_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/on_screen/wx17_weoff_wxA5_weon [cgb, png] | 960/23040 pixels differ |
| window/on_screen/wxA6_late_we_reenable_3 [dmg, png] | 916/23040 pixels differ |
