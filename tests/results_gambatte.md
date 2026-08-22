# gambatte Test Suite - Detailed Results

*Generated: 2026-08-22 07:26:52*

Each row is one ROM run on one device. `[dmg]` / `[cgb]` is the
device the filename asks for; `[.., png]` rows are scored against the
reference image next to the ROM, the rest against the hex value the
ROM draws on screen. See tests/README.md for the mechanism.

**4614/4996 passed.**

## bgen

All 2 tests passed.

## bgtiledata

All 34 tests passed.

## bgtilemap

All 40 tests passed.

## cgbpal_m3 (33/44 passed)

33/44 tests passed, 11 failed:

| Test | Result |
|------|--------|
| cgbpal_m3/cgbpal_m3end_1_cgb04c_out7 [cgb] | got 0, expected 7 |
| cgbpal_m3/cgbpal_m3end_3_cgb04c_out0 [cgb] | got 1, expected 0 |
| cgbpal_m3/cgbpal_m3end_ds_1_cgb04c_out7 [cgb] | got 0, expected 7 |
| cgbpal_m3/cgbpal_m3end_ds_3_cgb04c_out0 [cgb] | got 1, expected 0 |
| cgbpal_m3/cgbpal_m3end_scx5_ds_1_cgb04c_out7 [cgb] | got 0, expected 7 |
| cgbpal_m3/cgbpal_m3end_scx5_ds_3_cgb04c_out0 [cgb] | got 1, expected 0 |
| cgbpal_m3/cgbpal_m3start_ds_1_cgb04c_out1 [cgb] | got 0, expected 1 |
| cgbpal_m3/cgbpal_read_m3start_ds_1_cgb04c_out00 [cgb] | got FF, expected 00 |
| cgbpal_m3/cgbpal_read_m3start_lcdoffset1_1_cgb04c_out00 [cgb] | got FF, expected 00 |
| cgbpal_m3/cgbpal_write_m3start_ds_1_cgb04c_out01 [cgb] | got 00, expected 01 |
| cgbpal_m3/cgbpal_write_m3start_lcdoffset1_1_cgb04c_out01 [cgb] | got 00, expected 01 |

## display_startstate (10/14 passed)

10/14 tests passed, 4 failed:

| Test | Result |
|------|--------|
| display_startstate/stat_2_cgb04c_out84 [cgb] | got 87, expected 84 |
| display_startstate/stat_scx2_2_cgb04c_out84 [cgb] | got 87, expected 84 |
| display_startstate/stat_scx3_2_cgb04c_out84 [cgb] | got 87, expected 84 |
| display_startstate/stat_scx5_2_cgb04c_out84 [cgb] | got 87, expected 84 |

## div

All 8 tests passed.

## dma (190/229 passed)

190/229 tests passed, 39 failed:

| Test | Result |
|------|--------|
| dma/hdma_disable_display_1_cgb04c_out1 [cgb] | got 0, expected 1 |
| dma/hdma_late_enable_ds_lcdoffset1_2_cgb04c_out0 [cgb] | got 1, expected 0 |
| dma/hdma_late_enable_lcdoffset3_2_cgb04c_out0 [cgb] | got 1, expected 0 |
| dma/hdma_late_m0unhalt_2_cgb04c_outFF [cgb] | got 00, expected FF |
| dma/hdma_late_m0unhalt_ds_2_cgb04c_outFF [cgb] | got 00, expected FF |
| dma/hdma_late_m3halt_m2unhalt_inc_scx1_2_cgb04c_out02 [cgb] | got 01, expected 02 |
| dma/hdma_late_m3halt_m2unhalt_inc_scx2_2_cgb04c_out02 [cgb] | got 01, expected 02 |
| dma/hdma_late_m3halt_m2unhalt_ly_scx2_4_cgb04c_out03 [cgb] | got 02, expected 03 |
| dma/hdma_late_m3halt_m2unhalt_scx1_2_cgb04c_outFF [cgb] | got 00, expected FF |
| dma/hdma_late_m3speedchange_hdma5_scx1_ds_1_cgb04c_out00 [cgb] | got 80, expected 00 |
| dma/hdma_late_m3speedchange_hdma5_scx1_ds_2_cgb04c_outFF [cgb] | got 00, expected FF |
| dma/hdma_late_m3speedchange_hdma5_scx2_2_cgb04c_out80 [cgb] | got 00, expected 80 |
| dma/hdma_late_m3speedchange_hdma5_scx2_ds_2_cgb04c_outFF [cgb] | got 00, expected FF |
| dma/hdma_late_m3speedchange_inc_scx1_2_cgb04c_out02 [cgb] | got 01, expected 02 |
| dma/hdma_late_m3speedchange_ly_scx1_4_cgb04c_out93 [cgb] | got 92, expected 93 |
| dma/hdma_late_m3speedchange_read_hdmadst00_scx1_2_cgb04c_out9F [cgb] | got 00, expected 9F |
| dma/hdma_late_m3speedchange_read_hdmadst00_scx1_ds_2_cgb04c_out9F [cgb] | got 00, expected 9F |
| dma/hdma_late_m3speedchange_read_hdmadst00_scx2_2_cgb04c_out9F [cgb] | got 00, expected 9F |
| dma/hdma_late_m3speedchange_read_hdmadst00_scx2_ds_2_cgb04c_out9F [cgb] | got 00, expected 9F |
| dma/hdma_late_m3speedchange_tima_scx1_ds_3_cgb04c_outF6 [cgb] | got F4, expected F6 |
| dma/hdma_late_m3speedchange_tima_scx1_ds_4_cgb04c_outF7 [cgb] | got F4, expected F7 |
| dma/hdma_late_speedchange_inc_scx1_ds_2_cgb04c_out02 [cgb] | got 01, expected 02 |
| dma/hdma_m0halt_late_m3unhalt_scx1_2_cgb04c_out00 [cgb] | got FF, expected 00 |
| dma/hdma_m0speedchange_late_m3wakeup_scx1_2_cgb04c_out00 [cgb] | got FF, expected 00 |
| dma/hdma_m0speedchange_late_m3wakeup_scx2_2_cgb04c_out00 [cgb] | got FF, expected 00 |
| dma/hdma_pc_7ffe_cgb04c_out02 [cgb] | got 80, expected 02 |
| dma/hdma_transition_7fffhalt_inc_m3unhalt_cgb04c_out01 [cgb] | got 00, expected 01 |
| dma/hdma_transition_ei_halt_late_unhalt_ldaaimm_hdma_scx1_1_cgb04c_out00 [cgb] | got 01, expected 00 |
| dma/hdma_transition_ei_halt_late_unhalt_ldaaimm_hdma_scx1_2_cgb04c_out02 [cgb] | got 01, expected 02 |
| dma/hdma_transition_ei_halt_late_unhalt_scx1_2_cgb04c_outFF [cgb] | got 00, expected FF |
| dma/hdma_transition_halt_late_unhalt_ldaaimm_hdma_scx1_1_cgb04c_out00 [cgb] | got 01, expected 00 |
| dma/hdma_transition_halt_late_unhalt_ldaaimm_hdma_scx1_2_cgb04c_out02 [cgb] | got FF, expected 02 |
| dma/hdma_transition_halt_late_unhalt_scx1_2_cgb04c_outFF [cgb] | got 00, expected FF |
| dma/hdma_transition_halt_m0unhalt_ldaaimm_scx1_cgb04c_out02 [cgb] | got 01, expected 02 |
| dma/hdma_transition_speedchange_7fffstop_inc_cgb04c_out02 [cgb] | got 01, expected 02 |
| dma/hdma_transition_speedchange_ldaaimm_scx1_cgb04c_outFF [cgb] | got 31, expected FF |
| dma/hdma_transition_speedchange_ldaaimm_scx1_ds_cgb04c_out03 [cgb] | got 31, expected 03 |
| dma/hdma_transition_speedchange_oamdma_cgb04c_out71 [cgb] | got 72, expected 71 |
| dma/late_gdma_pc_7ffe_1_cgb04c_out02 [cgb] | got 00, expected 02 |

## dmgpalette_during_m3 (9/17 passed)

9/17 tests passed, 8 failed:

| Test | Result |
|------|--------|
| dmgpalette_during_m3/dmgpalette_during_m3_3 [dmg, png] | 1/23040 pixels differ |
| dmgpalette_during_m3/dmgpalette_during_m3_4 [dmg, png] | 144/23040 pixels differ |
| dmgpalette_during_m3/dmgpalette_during_m3_5 [dmg, png] | 144/23040 pixels differ |
| dmgpalette_during_m3/dmgpalette_during_m3_scx1_4 [dmg, png] | 144/23040 pixels differ |
| dmgpalette_during_m3/lycint_dmgpalette_during_m3_3 [dmg, png] | 143/23040 pixels differ |
| dmgpalette_during_m3/lycint_dmgpalette_during_m3_4 [dmg, png] | 143/23040 pixels differ |
| dmgpalette_during_m3/scx3/dmgpalette_during_m3_4 [dmg, png] | 1/23040 pixels differ |
| dmgpalette_during_m3/scx3/dmgpalette_during_m3_5 [dmg, png] | 144/23040 pixels differ |

## enable_display (158/184 passed)

158/184 tests passed, 26 failed:

| Test | Result |
|------|--------|
| enable_display/enable_display_ly0_oambusy_read_ds_1_cgb04c_out0 [cgb] | got 7, expected 0 |
| enable_display/enable_display_ly0_sprites_m0stat_2_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| enable_display/enable_display_ly0_sprites_m0stat_2_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| enable_display/frame0_m0irq_count_scx2_ds_1_cgb04c_out90 [cgb] | got 00, expected 90 |
| enable_display/frame0_m0irq_count_scx3_ds_1_cgb04c_out90 [cgb] | got 00, expected 90 |
| enable_display/frame0_m2irq_count_ds_1_cgb04c_out98 [cgb] | got 90, expected 98 |
| enable_display/frame0_m2stat_count_ds_1_cgb04c_out91 [cgb] | got 01, expected 91 |
| enable_display/frame0_m3stat_count_ds_1_cgb04c_out90 [cgb] | got 00, expected 90 |
| enable_display/frame1_ly_count_2_dmg08_cgb04c_out9A [cgb] | got 00, expected 9A |
| enable_display/frame1_m0irq_count_scx3_ds_1_cgb04c_out90 [cgb] | got 00, expected 90 |
| enable_display/frame1_m2irq_count_ds_1_cgb04c_out98 [cgb] | got 90, expected 98 |
| enable_display/frame1_m2stat_count_1_dmg08_cgb04c_out91 [cgb] | got 00, expected 91 |
| enable_display/frame1_m2stat_count_ds_1_cgb04c_out91 [cgb] | got 01, expected 91 |
| enable_display/ly0_late_cgbpr_2_cgb04c_outFF [cgb] | got 55, expected FF |
| enable_display/ly0_late_cgbpr_ds_2_cgb04c_outFF [cgb] | got 55, expected FF |
| enable_display/ly0_late_cgbpw_2_cgb04c_out55 [cgb] | got AA, expected 55 |
| enable_display/ly0_late_cgbpw_ds_2_cgb04c_out55 [cgb] | got AA, expected 55 |
| enable_display/ly0_late_scx7_m3stat_scx0_2_dmg08_out87_cgb04c_out84 [dmg] | got 84, expected 87 |
| enable_display/ly0_late_scx7_m3stat_scx1_1_dmg08_cgb04c_out87 [cgb] | got 84, expected 87 |
| enable_display/ly0_late_scx7_m3stat_scx3_1_dmg08_cgb04c_out87 [dmg] | got 84, expected 87 |
| enable_display/ly0_late_scx7_m3stat_scx3_1_dmg08_cgb04c_out87 [cgb] | got 84, expected 87 |
| enable_display/ly0_late_vramr_2_dmg08_outFF_cgb04c_out55 [cgb] | got FF, expected 55 |
| enable_display/ly0_late_vramr_ds_1_cgb04c_out55 [cgb] | got FF, expected 55 |
| enable_display/ly0_late_vramw_2_dmg08_out55_cgb04c_outAA [cgb] | got 55, expected AA |
| enable_display/ly0_m0irq_scx0_ds_1_cgb04c_outE0 [cgb] | got E2, expected E0 |
| enable_display/ly0_m0irq_scx1_ds_1_cgb04c_outE0 [cgb] | got E2, expected E0 |

## halt (150/158 passed)

150/158 tests passed, 8 failed:

| Test | Result |
|------|--------|
| halt/late_m0int_halt_m0stat_scx2_3a_dmg08_cgb04c_out0 [dmg] | got 2, expected 0 |
| halt/late_m0int_halt_m0stat_scx2_3a_dmg08_cgb04c_out0 [cgb] | got 2, expected 0 |
| halt/late_m0int_halt_m0stat_scx3_2b_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| halt/late_m0int_halt_m0stat_scx3_3a_dmg08_cgb04c_out0 [dmg] | got 2, expected 0 |
| halt/late_m0int_halt_m0stat_scx3_3a_dmg08_cgb04c_out0 [cgb] | got 2, expected 0 |
| halt/late_m0int_halt_m0stat_scx3_3b_dmg08_out0_cgb04c_out2 [dmg] | got 2, expected 0 |
| halt/late_m0irq_halt_m0stat_scx3_2b_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| halt/noime_m2irq_m0stat_1_dmg08_cgb04c_out0 [cgb] | got 2, expected 0 |

## irq_precedence (47/64 passed)

47/64 tests passed, 17 failed:

| Test | Result |
|------|--------|
| irq_precedence/hdma_vs_m0_scx2_cgb04c_out0183 [cgb] | got 1234, expected 0183 |
| irq_precedence/hdma_vs_m0_scx2_halt_cgb04c_out1234 [cgb] | got 0184, expected 1234 |
| irq_precedence/late_hdma_vs_ei_scx1_2_cgb04c_out1234 [cgb] | got 102F, expected 1234 |
| irq_precedence/late_hdma_vs_ie_scx1_2_cgb04c_out1234 [cgb] | got 102F, expected 1234 |
| irq_precedence/late_hdma_vs_tima_scx1_1_cgb04c_out1234 [cgb] | got 11E9, expected 1234 |
| irq_precedence/late_hdma_vs_tima_scx1_halt_1_cgb04c_out1234 [cgb] | got 11C9, expected 1234 |
| irq_precedence/late_hdma_vs_tima_scx2_halt_1_cgb04c_out1234 [cgb] | got 11C9, expected 1234 |
| irq_precedence/late_m0irq_retrigger_2_dmg08_cgb04c_outE0 [dmg] | got E2, expected E0 |
| irq_precedence/late_m0irq_retrigger_2_dmg08_cgb04c_outE0 [cgb] | got E2, expected E0 |
| irq_precedence/late_m0irq_vs_tima_scx2_1_dmg08_cgb04c_out4 [dmg] | got 2, expected 4 |
| irq_precedence/late_m0irq_vs_tima_scx2_1_dmg08_cgb04c_out4 [cgb] | got 2, expected 4 |
| irq_precedence/late_m0irq_vs_tima_scx2_halt_1_dmg08_cgb04c_out4 [dmg] | got 2, expected 4 |
| irq_precedence/late_m0irq_vs_tima_scx2_halt_1_dmg08_cgb04c_out4 [cgb] | got 2, expected 4 |
| irq_precedence/late_m0irq_vs_tima_scx3_1_dmg08_cgb04c_out4 [dmg] | got 2, expected 4 |
| irq_precedence/late_m0irq_vs_tima_scx3_1_dmg08_cgb04c_out4 [cgb] | got 2, expected 4 |
| irq_precedence/late_m0irq_vs_tima_scx3_halt_1_dmg08_cgb04c_out4 [dmg] | got 2, expected 4 |
| irq_precedence/late_m0irq_vs_tima_scx3_halt_1_dmg08_cgb04c_out4 [cgb] | got 2, expected 4 |

## lcd_offset (42/62 passed)

42/62 tests passed, 20 failed:

| Test | Result |
|------|--------|
| lcd_offset/offset1_lyc8fint_m1stat_1_cgb04c_outC4 [cgb] | got C1, expected C4 |
| lcd_offset/offset1_lyc98int_ly_count_1_cgb04c_out99 [cgb] | got 00, expected 99 |
| lcd_offset/offset1_lyc98int_ly_count_2_cgb04c_out9A [cgb] | got 99, expected 9A |
| lcd_offset/offset1_lyc98int_ly_count_ds_2_cgb04c_out9A [cgb] | got 02, expected 9A |
| lcd_offset/offset1_lyc99int_m0irq_count_scx2_ds_1_cgb04c_out90 [cgb] | got 00, expected 90 |
| lcd_offset/offset1_lyc99int_m0stat_count_scx2_1_cgb04c_out90 [cgb] | got 00, expected 90 |
| lcd_offset/offset1_lyc99int_m0stat_count_scx3_1_cgb04c_out90 [cgb] | got 00, expected 90 |
| lcd_offset/offset1_lyc99int_m2irq_count_1_cgb04c_out98 [cgb] | got 01, expected 98 |
| lcd_offset/offset1_lyc99int_m2irq_count_ds_1_cgb04c_out98 [cgb] | got 90, expected 98 |
| lcd_offset/offset1_lyc99int_m2stat_count_1_cgb04c_out91 [cgb] | got 00, expected 91 |
| lcd_offset/offset1_lyc99int_m2stat_count_ds_2_cgb04c_out90 [cgb] | got 00, expected 90 |
| lcd_offset/offset1_lyc99int_m3stat_count_ds_2_cgb04c_out90 [cgb] | got 00, expected 90 |
| lcd_offset/offset2_lyc8fint_m1stat_1_cgb04c_outC4 [cgb] | got C1, expected C4 |
| lcd_offset/offset2_lyc98int_ly_count_1_cgb04c_out99 [cgb] | got 00, expected 99 |
| lcd_offset/offset2_lyc98int_ly_count_2_cgb04c_out9A [cgb] | got 01, expected 9A |
| lcd_offset/offset2_lyc98int_ly_count_3_cgb04c_out9A [cgb] | got 99, expected 9A |
| lcd_offset/offset2_lyc99int_m0stat_count_scx1_1_cgb04c_out90 [cgb] | got 00, expected 90 |
| lcd_offset/offset2_lyc99int_m0stat_count_scx2_1_cgb04c_out90 [cgb] | got 00, expected 90 |
| lcd_offset/offset2_lyc99int_m2irq_count_1_cgb04c_out98 [cgb] | got 01, expected 98 |
| lcd_offset/offset3_lyc8fint_m1stat_1_cgb04c_outC0 [cgb] | got C1, expected C0 |

## lcdirq_precedence

All 62 tests passed.

## ly0 (88/96 passed)

88/96 tests passed, 8 failed:

| Test | Result |
|------|--------|
| ly0/lycint152_ly0stat_2_dmg08_cgb04c_outC0 [cgb] | got C1, expected C0 |
| ly0/lycint152_ly153_3_dmg08_cgb04c_out00 [cgb] | got 99, expected 00 |
| ly0/lycint152_lyc0flag_ds_3_cgb04c_outC4 [cgb] | got C0, expected C4 |
| ly0/lycint152_lyc0irq_late_retrigger_2_dmg08_cgb04c_outE0 [dmg] | got E2, expected E0 |
| ly0/lycint152_lyc0irq_late_retrigger_2_dmg08_cgb04c_outE0 [cgb] | got E2, expected E0 |
| ly0/lycint152_lyc153flag_ds_3_cgb04c_outC5 [cgb] | got C1, expected C5 |
| ly0/lycint152_lyc153irq_late_retrigger_2_dmg08_cgb04c_outE0 [dmg] | got E2, expected E0 |
| ly0/lycint152_lyc153irq_late_retrigger_2_dmg08_cgb04c_outE0 [cgb] | got E2, expected E0 |

## lyc0int_m0irq

All 6 tests passed.

## lyc153int_m2irq (14/16 passed)

14/16 tests passed, 2 failed:

| Test | Result |
|------|--------|
| lyc153int_m2irq/lyc153int_m2irq_late_retrigger_2_dmg08_cgb04c_out0 [dmg] | got 2, expected 0 |
| lyc153int_m2irq/lyc153int_m2irq_late_retrigger_2_dmg08_cgb04c_out0 [cgb] | got 2, expected 0 |

## lycEnable (192/225 passed)

192/225 tests passed, 33 failed:

| Test | Result |
|------|--------|
| lycEnable/ff41_disable_2_dmg08_out0_cgb04c_out2 [cgb] | got 0, expected 2 |
| lycEnable/ff45_enable_weirdpoint_2_dmg08_out3_cgb04c_out1 [cgb] | got 3, expected 1 |
| lycEnable/ff45_enable_weirdpoint_ds_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| lycEnable/ff45_enable_weirdpoint_ds_lcdoffset1_2_cgb04c_out0 [cgb] | got 2, expected 0 |
| lycEnable/ff45_enable_weirdpoint_ds_lcdoffset1_3_cgb04c_out0 [cgb] | got 2, expected 0 |
| lycEnable/ff45_enable_weirdpoint_ds_lcdoffset1_4_cgb04c_out2 [cgb] | got 0, expected 2 |
| lycEnable/ff45_enable_weirdpoint_lcdoffset1_2_cgb04c_out0 [cgb] | got 2, expected 0 |
| lycEnable/late_ff41_enable_after_m2int_disable_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| lycEnable/late_ff41_enable_after_m2int_disable_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| lycEnable/late_ff41_enable_after_m2int_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| lycEnable/late_ff41_enable_after_m2int_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| lycEnable/late_ff41_enable_ds_1_cgb04c_out3 [cgb] | got 1, expected 3 |
| lycEnable/late_ff41_enable_lcdoffset1_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| lycEnable/late_ff45_enable_ds_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| lycEnable/late_ff45_enable_ds_lcdoffset1_2_cgb04c_out0 [cgb] | got 2, expected 0 |
| lycEnable/late_ff45_enable_lcdoffset1_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| lycEnable/lcdoff_lycirqen_1_dmg08_cgb04c_outE2 [dmg] | got E0, expected E2 |
| lycEnable/lcdoff_lycirqen_1_dmg08_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lcdoff_lycirqen_4_dmg08_outE2_cgb04c_outE0 [dmg] | got E0, expected E2 |
| lycEnable/lyc0_ff41_disable_ds_1_cgb04c_outE0 [cgb] | got E2, expected E0 |
| lycEnable/lyc0_m1disable_2_dmg08_outE2_cgb04c_outE0 [dmg] | got E0, expected E2 |
| lycEnable/lyc0_m1disable_ds_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lyc153_late_enable_m1disable_2_dmg08_outE2_cgb04c_outE0 [dmg] | got E0, expected E2 |
| lycEnable/lyc153_late_ff41_enable_ds_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lyc153_late_ff41_enable_ds_lcdoffset1_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lyc153_late_ff41_enable_lcdoffset1_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lyc153_late_ff45_enable_2_dmg08_outE2_cgb04c_outE0 [cgb] | got E2, expected E0 |
| lycEnable/lyc153_late_ff45_enable_ds_2_cgb04c_outE0 [cgb] | got E2, expected E0 |
| lycEnable/lyc153_late_ff45_enable_lcdoffset1_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lyc153_late_m1disable_2_dmg08_outE2_cgb04c_outE0 [dmg] | got E0, expected E2 |
| lycEnable/lyc153_m1disable_ds_1_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lycwirq_trigger_ly00_stat50_ds_lcdoffset1_2_cgb04c_outE2 [cgb] | got E0, expected E2 |
| lycEnable/lycwirq_trigger_ly00_stat50_lcdoffset1_1_cgb04c_outE0 [cgb] | got E2, expected E0 |

## lycint_ly

All 6 tests passed.

## lycint_lycflag (11/12 passed)

11/12 tests passed, 1 failed:

| Test | Result |
|------|--------|
| lycint_lycflag/lycint_lycflag_ds_3_cgb04c_out4 [cgb] | got 0, expected 4 |

## lycint_lycirq

All 4 tests passed.

## lycint_m0stat

All 6 tests passed.

## lycm2int

All 18 tests passed.

## lywrite

All 8 tests passed.

## m0enable (149/167 passed)

149/167 tests passed, 18 failed:

| Test | Result |
|------|--------|
| m0enable/disable_ds_1_cgb04c_out1 [cgb] | got 3, expected 1 |
| m0enable/disable_scx5_ds_2_cgb04c_out3 [cgb] | got 1, expected 3 |
| m0enable/enable_wxA6_2x_spxA7_ds_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| m0enable/late_enable_lcdoffset1_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| m0enable/lycdisable_ff41_2_dmg08_out2_cgb04c_out0 [dmg] | got 0, expected 2 |
| m0enable/lycdisable_ff41_ds_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| m0enable/lycdisable_ff41_scx1_1_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| m0enable/lycdisable_ff41_scx1_1_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| m0enable/lycdisable_ff41_scx1_ds_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| m0enable/lycdisable_ff41_scx2_1_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| m0enable/lycdisable_ff41_scx2_1_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| m0enable/lycdisable_ff41_scx3_2_dmg08_out2_cgb04c_out0 [dmg] | got 0, expected 2 |
| m0enable/lycdisable_ff45_3_dmg08_out2_cgb04c_out0 [dmg] | got 0, expected 2 |
| m0enable/lycdisable_ff45_scx1_1_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| m0enable/lycdisable_ff45_scx1_2_dmg08_out2_cgb04c_out0 [dmg] | got 0, expected 2 |
| m0enable/lycdisable_ff45_scx1_ds_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| m0enable/lycdisable_ff45_scx2_1_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| m0enable/lycdisable_ff45_scx2_2_dmg08_out2_cgb04c_out0 [dmg] | got 0, expected 2 |

## m0int_m0irq

All 4 tests passed.

## m0int_m0stat (11/12 passed)

11/12 tests passed, 1 failed:

| Test | Result |
|------|--------|
| m0int_m0stat/m0int_m0stat_scx5_ds_2_cgb04c_out2 [cgb] | got 0, expected 2 |

## m0int_m3stat

All 6 tests passed.

## m1 (143/170 passed)

143/170 tests passed, 27 failed:

| Test | Result |
|------|--------|
| m1/ly143_late_m0enable_2_dmg08_out3_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/ly143_late_m0enable_lcdoffset1_1_cgb04c_out3 [cgb] | got 1, expected 3 |
| m1/ly143_late_m2enable_2_dmg08_out3_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/ly143_late_m2enable_ds_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/ly143_late_m2enable_ds_lcdoffset1_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/lyc143_late_m2enable_lycdisable_2_dmg08_cgb04c_out1 [dmg] | got 3, expected 1 |
| m1/lyc143_late_m2enable_lycdisable_2_dmg08_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/lyc143_late_m2enable_lycdisable_ds_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/lycint143_m1irq_late_retrigger_2_dmg08_cgb04c_out1 [dmg] | got 3, expected 1 |
| m1/lycint143_m1irq_late_retrigger_2_dmg08_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/lycint_vblankirq_late_retrigger_2_dmg08_cgb04c_out0 [dmg] | got 1, expected 0 |
| m1/lycint_vblankirq_late_retrigger_2_dmg08_cgb04c_out0 [cgb] | got 1, expected 0 |
| m1/m1irq_enable_after_lyc144_2_dmg08_out1_cgb04c_out3 [cgb] | got 1, expected 3 |
| m1/m1irq_late_enable_2_dmg08_out2_cgb04c_out0 [cgb] | got 2, expected 0 |
| m1/m1irq_late_enable_lcdoffset1_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| m1/m1irq_m0disable_2_dmg08_out3_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/m1irq_m2disable_lycdisable_2_dmg08_out3_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/m1irq_m2disable_lycdisable_3_dmg08_cgb04c_out1 [dmg] | got 3, expected 1 |
| m1/m1irq_m2disable_lycdisable_3_dmg08_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/m1irq_m2disable_lycdisable_ds_2_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/m1irq_m2enable_lyc_1_dmg08_cgb04c_out1 [dmg] | got 3, expected 1 |
| m1/m1irq_m2enable_lyc_1_dmg08_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/m1irq_m2enable_lyc_2_dmg08_out1_cgb04c_out3 [dmg] | got 3, expected 1 |
| m1/m1irq_m2enable_lyc_ds_1_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/m2m1irq_ifw_2_dmg08_cgb04c_out1 [dmg] | got 3, expected 1 |
| m1/m2m1irq_ifw_2_dmg08_cgb04c_out1 [cgb] | got 3, expected 1 |
| m1/m2m1irq_ifw_ds_2_cgb04c_out1 [cgb] | got 3, expected 1 |

## m2enable (100/120 passed)

100/120 tests passed, 20 failed:

| Test | Result |
|------|--------|
| m2enable/late_enable_after_lycint_2_dmg08_out0_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/late_enable_after_lycint_disable_1_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| m2enable/late_enable_after_lycint_disable_1_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/late_enable_after_lycint_disable_2_dmg08_out0_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/late_enable_m0disable_1_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| m2enable/late_enable_m0disable_1_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/late_enable_m0disable_2_dmg08_out0_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/late_enable_m1disable_ly0_2_dmg08_out2_cgb04c_out0 [cgb] | got 2, expected 0 |
| m2enable/late_m1disable_ly0_2_dmg08_out2_cgb04c_out0 [cgb] | got 2, expected 0 |
| m2enable/lyc0_late_m2enable_lycdisable_2_dmg08_out2_cgb04c_out0 [cgb] | got 2, expected 0 |
| m2enable/lyc1_late_m2enable_lycdisable_1_dmg08_out0_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/lyc1_late_m2enable_lycdisable_ds_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/lyc1_m2irq_late_lyc255_1_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/lyc1_m2irq_late_lyc255_2_dmg08_out2_cgb04c_out0 [dmg] | got 0, expected 2 |
| m2enable/lyc1_m2irq_late_lycdisable_1_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| m2enable/lyc1_m2irq_late_lycdisable_1_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/lyc1_m2irq_late_lycdisable_ds_1_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/m2_late_m0disable_1_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| m2enable/m2_late_m0disable_1_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| m2enable/m2_late_m0disable_ds_1_cgb04c_out2 [cgb] | got 0, expected 2 |

## m2int_m0irq (67/72 passed)

67/72 tests passed, 5 failed:

| Test | Result |
|------|--------|
| m2int_m0irq/m2int_m0irq_scx3_ifw_2_dmg08_cgb04c_out0 [dmg] | got 2, expected 0 |
| m2int_m0irq/m2int_m0irq_scx3_ifw_2_dmg08_cgb04c_out0 [cgb] | got 2, expected 0 |
| m2int_m0irq/m2int_m0irq_scx3_ifw_4_dmg08_cgb04c_out0 [dmg] | got 8, expected 0 |
| m2int_m0irq/m2int_m0irq_scx3_ifw_4_dmg08_cgb04c_out0 [cgb] | got 8, expected 0 |
| m2int_m0irq/m2int_m0irq_scx5_ds_1_cgb04c_out1 [cgb] | got 3, expected 1 |

## m2int_m0stat

All 6 tests passed.

## m2int_m2irq

All 18 tests passed.

## m2int_m2stat

All 8 tests passed.

## m2int_m3stat

All 44 tests passed.

## miscmstatirq (272/279 passed)

272/279 tests passed, 7 failed:

| Test | Result |
|------|--------|
| miscmstatirq/lycstatwirq_trigger_ly00_10_50_lcdoffset3_2_cgb04c_outE2 [cgb] | got E0, expected E2 |
| miscmstatirq/lycstatwirq_trigger_m0_late_ly44_lyc44_08_40_ds_3_cgb04c_outE2 [cgb] | got E0, expected E2 |
| miscmstatirq/lycwirq_trigger_m0_late_ly44_lyc45_4_dmg08_cgb04c_outE2 [dmg] | got E0, expected E2 |
| miscmstatirq/lycwirq_trigger_m0_late_ly44_lyc45_ds_3_cgb04c_outE2 [cgb] | got E0, expected E2 |
| miscmstatirq/m0statwirq_scx2_2_dmg08_out2 [dmg] | got 0, expected 2 |
| miscmstatirq/m0statwirq_scx5_2_dmg08_out2 [dmg] | got 0, expected 2 |
| miscmstatirq/m1statwirq_trigger_ly94_lyc94_40_50_2_dmg08_outE0_cgb04c_outE2 [cgb] | got E0, expected E2 |

## oam_access (56/69 passed)

56/69 tests passed, 13 failed:

| Test | Result |
|------|--------|
| oam_access/10spritesprline_postread_2_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| oam_access/10spritesprline_postread_2_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| oam_access/midwrite_2_dmg08_out1_cgb04c_out0 [cgb] | got 1, expected 0 |
| oam_access/postread_scx2_2_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| oam_access/postread_scx2_2_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| oam_access/postread_scx3_2_dmg08_xout1_cgb04c_out0 [cgb] | got 3, expected 0 |
| oam_access/postwrite_2_scx3_dmg08_cgb04c_out1 [dmg] | got 0, expected 1 |
| oam_access/postwrite_2_scx3_dmg08_cgb04c_out1 [cgb] | got 0, expected 1 |
| oam_access/preread_ds_1_cgb04c_out0 [cgb] | got 3, expected 0 |
| oam_access/preread_lcdoffset1_1_cgb04c_out0 [cgb] | got 3, expected 0 |
| oam_access/prewrite_2_dmg08_out1_cgb04c_out0 [cgb] | got 1, expected 0 |
| oam_access/prewrite_ds_2_cgb04c_out0 [cgb] | got 1, expected 0 |
| oam_access/prewrite_ds_lcdoffset1_2_cgb04c_out0 [cgb] | got 1, expected 0 |

## oamdma (788/802 passed)

788/802 tests passed, 14 failed:

| Test | Result |
|------|--------|
| oamdma/late_sp00x_ds_2_cgb04c_out3 [cgb] | got 0, expected 3 |
| oamdma/late_sp00y_ds_1_cgb04c_out3 [cgb] | got 0, expected 3 |
| oamdma/late_sp01x_ds_2_cgb04c_out3 [cgb] | got 0, expected 3 |
| oamdma/late_sp01y_ds_1_cgb04c_out3 [cgb] | got 0, expected 3 |
| oamdma/late_sp39x_4_cgb04c_out3 [cgb] | got 0, expected 3 |
| oamdma/late_sp39x_ds_2_cgb04c_out3 [cgb] | got 0, expected 3 |
| oamdma/late_sp39y_ds_1_cgb04c_out3 [cgb] | got 0, expected 3 |
| oamdma/oamdma_late_halt_stat_2_dmg08_cgb04c_out3 [dmg] | got 0, expected 3 |
| oamdma/oamdma_late_halt_stat_2_dmg08_cgb04c_out3 [cgb] | got 0, expected 3 |
| oamdma/oamdma_late_speedchange_stat_2_cgb04c_out3 [cgb] | got 0, expected 3 |
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

## serial (75/82 passed)

75/82 tests passed, 7 failed:

| Test | Result |
|------|--------|
| serial/nopx1_start83_wait_read_if_2_dmg08_outE0_cgb04c_outE8 [cgb] | got E0, expected E8 |
| serial/nopx1_start_wait_read_if_2_dmg08_cgb04c_outE8 [dmg] | got E0, expected E8 |
| serial/nopx1_start_wait_read_if_2_dmg08_cgb04c_outE8 [cgb] | got E0, expected E8 |
| serial/start83_late_div_write_wait_read_if_1b_cgb04c_outE8 [cgb] | got E0, expected E8 |
| serial/start83_late_div_write_wait_read_if_2b_cgb04c_outE8 [cgb] | got E0, expected E8 |
| serial/start_wait_trigger_int8_read_if_2_dmg08_outE8_cgb04c_outE0 [cgb] | got E8, expected E0 |
| serial/start_wait_trigger_int8_read_if_ds_2_cgb04c_outE0 [cgb] | got E8, expected E0 |

## sound (113/116 passed)

113/116 tests passed, 3 failed:

| Test | Result |
|------|--------|
| sound/ch2_late_reset_nr52_2b_dmg08_cgb04c_out0 [dmg] | got 2, expected 0 |
| sound/ch2_late_reset_nr52_2b_dmg08_cgb04c_out0 [cgb] | got 2, expected 0 |
| sound/ch2_late_reset_nr52_ds_2b_cgb04c_out0 [cgb] | got 2, expected 0 |

## speedchange (202/208 passed)

202/208 tests passed, 6 failed:

| Test | Result |
|------|--------|
| speedchange/speedchange2_ch2_nr52_ds_1a_cgb04c_outF2 [cgb] | got F0, expected F2 |
| speedchange/speedchange2_ch2_nr52_ds_2a_cgb04c_outF2 [cgb] | got F0, expected F2 |
| speedchange/speedchange5_ch2_nr52_1a_cgb04c_outF2 [cgb] | got F0, expected F2 |
| speedchange/speedchange5_ch2_nr52_2a_cgb04c_outF2 [cgb] | got F0, expected F2 |
| speedchange/speedchange_ch2_nr52_1a_cgb04c_outF2 [cgb] | got F0, expected F2 |
| speedchange/speedchange_ch2_nr52_2a_cgb04c_outF2 [cgb] | got F0, expected F2 |

## sprites (472/476 passed)

472/476 tests passed, 4 failed:

| Test | Result |
|------|--------|
| sprites/10spritesPrLine_10xposA7_m0irq_2_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| sprites/10spritesPrLine_10xposA7_m0irq_2_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| sprites/enable/late_disable_ds_3_cgb04c_out3 [cgb] | got 0, expected 3 |
| sprites/late_disable_ds_1_cgb04c_out3 [cgb] | got 0, expected 3 |

## tima (224/232 passed)

224/232 tests passed, 8 failed:

| Test | Result |
|------|--------|
| tima/tc00_irq_late_retrigger_2_dmg08_outE4_cgb04c_outE0 [cgb] | got E4, expected E0 |
| tima/tc00_irq_late_retrigger_3_dmg08_cgb04c_outE0 [dmg] | got E4, expected E0 |
| tima/tc00_irq_late_retrigger_3_dmg08_cgb04c_outE0 [cgb] | got E4, expected E0 |
| tima/tc00_irq_late_retrigger_ds_2_cgb04c_outE0 [cgb] | got E4, expected E0 |
| tima/tc00_late_tc01_5_dmg08_cgb04c_out00 [dmg] | got FF, expected 00 |
| tima/tc00_late_tc01_5_dmg08_cgb04c_out00 [cgb] | got FF, expected 00 |
| tima/tc00_late_tc01_7_dmg08_cgb04c_outFF [dmg] | got FE, expected FF |
| tima/tc00_late_tc01_7_dmg08_cgb04c_outFF [cgb] | got FE, expected FF |

## undef_ops

All 20 tests passed.

## vram_m3 (42/50 passed)

42/50 tests passed, 8 failed:

| Test | Result |
|------|--------|
| vram_m3/10spritesprline_postread_2_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| vram_m3/10spritesprline_postread_2_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| vram_m3/postread_scx2_2_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| vram_m3/postread_scx2_2_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| vram_m3/postread_scx3_2_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| vram_m3/postread_scx3_2_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| vram_m3/preread_lcdoffset2_1_cgb04c_out0 [cgb] | got 3, expected 0 |
| vram_m3/prewrite_lcdoffset2_1_cgb04c_out1 [cgb] | got 0, expected 1 |

## vramw_m3end (32/36 passed)

32/36 tests passed, 4 failed:

| Test | Result |
|------|--------|
| vramw_m3end/vramw_m3end_scx3_3_dmg08_cgb04c_out0 [dmg] | got 7, expected 0 |
| vramw_m3end/vramw_m3end_scx3_3_dmg08_cgb04c_out0 [cgb] | got 7, expected 0 |
| vramw_m3end/vramw_m3end_scx3_5_dmg08_cgb04c_out3 [dmg] | got 0, expected 3 |
| vramw_m3end/vramw_m3end_scx3_5_dmg08_cgb04c_out3 [cgb] | got 0, expected 3 |

## window (426/476 passed)

426/476 tests passed, 50 failed:

| Test | Result |
|------|--------|
| window/arg/late_enable_afterVblank_4_dmg08_out3_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_enable_afterVblank_5_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| window/arg/late_enable_afterVblank_5_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_scx_late_wy_FFto4_ly4_wx00_1_dmg08_cgb04c_out3 [cgb] | got 0, expected 3 |
| window/arg/late_scx_late_wy_FFto4_ly4_wx00_2_dmg08_out3_cgb04c_out0 [dmg] | got 0, expected 3 |
| window/arg/late_wy_10to0_ly1_2_dmg08_out3_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_wy_10to0_ly1_3_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| window/arg/late_wy_10to0_ly1_3_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_wy_1toFF_2_dmg08_out0_cgb04c_out3 [cgb] | got 0, expected 3 |
| window/arg/late_wy_1toFF_lcdoffset1_2_cgb04c_out3 [cgb] | got 0, expected 3 |
| window/arg/late_wy_2toFF_2_dmg08_out0_cgb04c_out3 [cgb] | got 0, expected 3 |
| window/arg/late_wy_FFto0_ly2_2_dmg08_out3_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_wy_FFto0_ly2_3_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| window/arg/late_wy_FFto0_ly2_3_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_wy_FFto0_ly2_ds_2_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_wy_FFto1_ly2_2_dmg08_out3_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_wy_FFto1_ly2_3_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| window/arg/late_wy_FFto1_ly2_3_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_wy_FFto2_ly2_scx2_2_dmg08_out3_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_wy_FFto2_ly2_scx3_2_dmg08_out3_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/arg/late_wy_FFto2_ly2_scx3_3_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| window/late_disable_scx5_ds_1_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/late_enable_afterVblank_2_dmg08_out3_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/late_enable_afterVblank_3_dmg08_cgb04c_out0 [dmg] | got 3, expected 0 |
| window/late_enable_afterVblank_3_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/late_enable_afterVblank_ds_2_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/late_enable_afterVblank_ds_lcdoffset1_2_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/late_enable_afterVblank_lcdoffset1_1_cgb04c_out3 [cgb] | got 0, expected 3 |
| window/late_reenable_scx3_2_dmg08_out3_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/late_wx_scx3_2_dmg08_out0_cgb04c_out3 [cgb] | got 0, expected 3 |
| window/late_wy_ds_1_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/late_wy_ds_lcdoffset1_1_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/late_wy_lcdoffset1_2_cgb04c_out3 [cgb] | got 0, expected 3 |
| window/m2int_wxA5_m0irq_2_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| window/m2int_wxA5_m0irq_2_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| window/m2int_wxA6_firstline_m3stat_3_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/m2int_wxA6_m0irq2_2_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| window/m2int_wxA6_m0irq_2_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| window/m2int_wxA6_m3stat_3_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/m2int_wxA6_m3stat_ds_2_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/m2int_wxA6_scx3_m3stat_2_dmg08_out0_cgb04c_out3 [dmg] | got 3, expected 0 |
| window/m2int_wxA6_scx5_m3stat_3_dmg08_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/m2int_wxA6_scx5_m3stat_ds_2_cgb04c_out0 [cgb] | got 3, expected 0 |
| window/m2int_wxA6_spxA7_m0irq_2_dmg08_cgb04c_out2 [dmg] | got 0, expected 2 |
| window/m2int_wxA6_spxA7_m0irq_2_dmg08_cgb04c_out2 [cgb] | got 0, expected 2 |
| window/m2int_wxA6_spxA7_m3stat_2_dmg08_out0_cgb04c_out3 [cgb] | got 0, expected 3 |
| window/m2int_wxA6_spxA7_m3stat_4_dmg08_out0_cgb04c_out3 [cgb] | got 0, expected 3 |
| window/m2int_wxA6_vrambusyread_3_dmg08_cgb04c_out5 [cgb] | got 0, expected 5 |
| window/on_screen/wx17_weoff_wxA5_weon [cgb, png] | 960/23040 pixels differ |
| window/on_screen/wxA6_late_we_reenable_3 [dmg, png] | 916/23040 pixels differ |
