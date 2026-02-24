# GBA I/O register definitions using the bitfield macro.
# This file is `include`d by gba.nim; it shares gba.nim's scope.

####################
# CPU PSR (defined here for cpu.nim, but logically belongs with the CPU)
bitfield PSR, uint32:
  num mode, 5
  bool thumb
  bool fiq_disable
  bool irq_disable
  num reserved, 20, read_only = true
  bool overflow
  bool carry
  bool zero
  bool negative

####################
# General

bitfield WAITCNT, uint16:
  num sram_wait_control, 2
  num wait_state_0_first_access, 2
  num wait_state_0_second_access, 1
  num wait_state_1_first_access, 2
  num wait_state_1_second_access, 1
  num wait_state_2_first_access, 2
  num wait_state_2_second_access, 1
  num phi_terminal_output, 2
  bool not_used, read_only = true
  bool gamepack_prefetch_buffer
  bool gamepak_type, read_only = true

####################
# Interrupts

bitfield InterruptReg, uint16:
  bool vblank
  bool hblank
  bool vcounter
  bool timer0
  bool timer1
  bool timer2
  bool timer3
  bool serial
  bool dma0
  bool dma1
  bool dma2
  bool dma3
  bool keypad
  bool game_pak
  num not_used, 2, read_only = true

####################
# APU

bitfield SOUNDCNT_L, uint16:
  num right_volume, 3
  bool not_used_2, read_only = true
  num left_volume, 3
  bool not_used_1, read_only = true
  num channel_1_right, 1
  num channel_2_right, 1
  num channel_3_right, 1
  num channel_4_right, 1
  num channel_1_left, 1
  num channel_2_left, 1
  num channel_3_left, 1
  num channel_4_left, 1

bitfield SOUNDCNT_H, uint16:
  num sound_volume, 2
  num dma_sound_a_volume, 1
  num dma_sound_b_volume, 1
  num not_used, 4, read_only = true
  num dma_sound_a_right, 1
  num dma_sound_a_left, 1
  num dma_sound_a_timer, 1
  bool dma_sound_a_reset, read_only = true
  num dma_sound_b_right, 1
  num dma_sound_b_left, 1
  num dma_sound_b_timer, 1
  bool dma_sound_b_reset, read_only = true

bitfield SOUNDBIAS, uint16:
  bool not_used_2
  num bias_level, 9
  num not_used_1, 4
  num amplitude_resolution, 2

####################
# DMA

bitfield DMACNT, uint16:
  num not_used, 5, read_only = true
  num dest_control, 2
  num source_control, 2
  bool repeat
  num xfer_type, 1          # renamed from "type" (Nim keyword)
  bool game_pak
  num start_timing, 2
  bool irq_enable
  bool enable

####################
# Timer

bitfield TMCNT, uint16:
  num frequency, 2
  bool cascade
  num not_used_2, 3, read_only = true
  bool irq_enable
  bool enable
  num not_used_1, 8, read_only = true

####################
# PPU

bitfield DISPCNT, uint16:
  num bg_mode, 3
  bool reserved_for_bios, read_only = true
  bool display_frame_select
  bool hblank_interval_free
  bool obj_mapping_1d
  bool forced_blank
  num default_enable_bits, 5
  bool window_0_display
  bool window_1_display
  bool obj_window_display

bitfield DISPSTAT, uint16:
  bool vblank
  bool hblank
  bool vcounter
  bool vblank_irq_enable
  bool hblank_irq_enable
  bool vcounter_irq_enable
  num not_used, 2
  num vcount_setting, 8

bitfield BGCNT, uint16:
  num priority, 2
  num character_base_block, 2
  num not_used, 2
  bool mosaic
  bool color_mode_8bpp
  num screen_base_block, 5
  bool affine_wrap
  num screen_size, 2

bitfield BGOFS, uint16:
  num offset, 9
  num not_used, 7, read_only = true

bitfield BGAFF, uint16:
  num fraction, 8
  num integer, 7
  bool sign

proc num*(self: BGAFF): int16 {.inline.} =
  cast[int16](self.value)

bitfield BGREF, uint32:
  num fraction, 8
  num integer, 19
  bool sign
  num not_used, 4, read_only = true

proc num*(self: BGREF): int32 {.inline.} =
  int32(self.value shl 4) shr 4

bitfield WINH, uint16:
  num x2, 8
  num x1, 8

bitfield WINV, uint16:
  num y2, 8
  num y1, 8

bitfield WININ, uint16:
  num window_0_enable_bits, 5
  bool window_0_color_special_effect
  num not_used_0, 2, read_only = true
  num window_1_enable_bits, 5
  bool window_1_color_special_effect
  num not_used_1, 2, read_only = true

bitfield WINOUT, uint16:
  num outside_enable_bits, 5
  bool outside_color_special_effect
  num not_used_outside, 2, read_only = true
  num obj_window_enable_bits, 5
  bool obj_window_color_special_effect
  num not_used_obj, 2, read_only = true

bitfield MOSAIC, uint16:
  num bg_mosiac_h_size, 4
  num bg_mosiac_v_size, 4
  num obj_mosiac_h_size, 4
  num obj_mosiac_v_size, 4

bitfield BLDCNT, uint16:
  bool bg0_1st_target_pixel
  bool bg1_1st_target_pixel
  bool bg2_1st_target_pixel
  bool bg3_1st_target_pixel
  bool obj_1st_target_pixel
  bool bd_1st_target_pixel
  num blend_mode, 2
  bool bg0_2nd_target_pixel
  bool bg1_2nd_target_pixel
  bool bg2_2nd_target_pixel
  bool bg3_2nd_target_pixel
  bool obj_2nd_target_pixel
  bool bd_2nd_target_pixel
  num not_used, 2, read_only = true

proc layer_target*(self: BLDCNT; layer, target: int): bool {.inline.} =
  bit(self.value, layer + (target - 1) * 8)

bitfield BLDALPHA, uint16:
  num eva_coefficient, 5
  num not_used_5_7, 3, read_only = true
  num evb_coefficient, 5
  num not_used_13_15, 3, read_only = true

bitfield BLDY, uint16:
  num evy_coefficient, 5
  num not_used, 11, read_only = true

####################
# Keypad

bitfield KEYINPUT, uint16:
  bool a
  bool b
  bool select
  bool start
  bool right
  bool left
  bool up
  bool down
  bool r
  bool l
  num not_used, 6

bitfield KEYCNT, uint16:
  bool a
  bool b
  bool select
  bool start
  bool right
  bool left
  bool up
  bool down
  bool r
  bool l
  num not_used, 4
  bool irq_enable
  bool irq_condition
