# GBA I/O register definitions using packed objects with bitsize pragmas.
# This file is `include`d by gba.nim; it shares gba.nim's scope.
# Approach borrowed from reference/gba — uses Nim's native {.packed.} +
# {.bitsize:N.} instead of a custom macro.

####################
# CPU mode enum (must come before PSR since it lives in reg.nim now)

type
  CpuMode* = enum
    modeUSR = 0x10, modeFIQ = 0x11, modeIRQ = 0x12, modeSVC = 0x13,
    modeABT = 0x17, modeUND = 0x1B, modeSYS = 0x1F

####################
# CPU PSR (Program Status Register) — 32-bit

type
  PSR* {.packed.} = object
    mode*        {.bitsize:  5.}: uint32
    thumb*       {.bitsize:  1.}: bool
    fiq_disable* {.bitsize:  1.}: bool
    irq_disable* {.bitsize:  1.}: bool
    reserved*    {.bitsize: 20.}: uint32
    overflow*    {.bitsize:  1.}: bool
    carry*       {.bitsize:  1.}: bool
    zero*        {.bitsize:  1.}: bool
    negative*    {.bitsize:  1.}: bool

converter toU32*(psr: PSR): uint32 = cast[uint32](psr)
converter toPSR*(v: uint32): PSR   = cast[PSR](v)

####################
# GBA 16-bit I/O registers

type
  WAITCNT* {.packed.} = object
    sram_wait_control*          {.bitsize: 2.}: uint16
    wait_state_0_first_access*  {.bitsize: 2.}: uint16
    wait_state_0_second_access* {.bitsize: 1.}: uint16
    wait_state_1_first_access*  {.bitsize: 2.}: uint16
    wait_state_1_second_access* {.bitsize: 1.}: uint16
    wait_state_2_first_access*  {.bitsize: 2.}: uint16
    wait_state_2_second_access* {.bitsize: 1.}: uint16
    phi_terminal_output*        {.bitsize: 2.}: uint16
    not_used*                   {.bitsize: 1.}: bool
    gamepack_prefetch_buffer*   {.bitsize: 1.}: bool
    gamepak_type*               {.bitsize: 1.}: bool

  InterruptReg* {.packed.} = object
    vblank*   {.bitsize: 1.}: bool
    hblank*   {.bitsize: 1.}: bool
    vcounter* {.bitsize: 1.}: bool
    timer0*   {.bitsize: 1.}: bool
    timer1*   {.bitsize: 1.}: bool
    timer2*   {.bitsize: 1.}: bool
    timer3*   {.bitsize: 1.}: bool
    serial*   {.bitsize: 1.}: bool
    dma0*     {.bitsize: 1.}: bool
    dma1*     {.bitsize: 1.}: bool
    dma2*     {.bitsize: 1.}: bool
    dma3*     {.bitsize: 1.}: bool
    keypad*   {.bitsize: 1.}: bool
    game_pak* {.bitsize: 1.}: bool
    not_used* {.bitsize: 2.}: uint16

  SOUNDCNT_L* {.packed.} = object
    right_volume*    {.bitsize: 3.}: uint16
    not_used_2*      {.bitsize: 1.}: bool
    left_volume*     {.bitsize: 3.}: uint16
    not_used_1*      {.bitsize: 1.}: bool
    channel_1_right* {.bitsize: 1.}: uint16
    channel_2_right* {.bitsize: 1.}: uint16
    channel_3_right* {.bitsize: 1.}: uint16
    channel_4_right* {.bitsize: 1.}: uint16
    channel_1_left*  {.bitsize: 1.}: uint16
    channel_2_left*  {.bitsize: 1.}: uint16
    channel_3_left*  {.bitsize: 1.}: uint16
    channel_4_left*  {.bitsize: 1.}: uint16

  SOUNDCNT_H* {.packed.} = object
    sound_volume*       {.bitsize: 2.}: uint16
    dma_sound_a_volume* {.bitsize: 1.}: uint16
    dma_sound_b_volume* {.bitsize: 1.}: uint16
    not_used*           {.bitsize: 4.}: uint16
    dma_sound_a_right*  {.bitsize: 1.}: uint16
    dma_sound_a_left*   {.bitsize: 1.}: uint16
    dma_sound_a_timer*  {.bitsize: 1.}: uint16
    dma_sound_a_reset*  {.bitsize: 1.}: bool
    dma_sound_b_right*  {.bitsize: 1.}: uint16
    dma_sound_b_left*   {.bitsize: 1.}: uint16
    dma_sound_b_timer*  {.bitsize: 1.}: uint16
    dma_sound_b_reset*  {.bitsize: 1.}: bool

  SOUNDBIAS* {.packed.} = object
    not_used_2*          {.bitsize:  1.}: bool
    bias_level*          {.bitsize:  9.}: uint16
    not_used_1*          {.bitsize:  4.}: uint16
    amplitude_resolution* {.bitsize: 2.}: uint16

  DMACNT* {.packed.} = object
    not_used*       {.bitsize: 5.}: uint16
    dest_control*   {.bitsize: 2.}: uint16
    source_control* {.bitsize: 2.}: uint16
    repeat*         {.bitsize: 1.}: bool
    xfer_type*      {.bitsize: 1.}: uint16
    game_pak*       {.bitsize: 1.}: bool
    start_timing*   {.bitsize: 2.}: uint16
    irq_enable*     {.bitsize: 1.}: bool
    enable*         {.bitsize: 1.}: bool

  TMCNT* {.packed.} = object
    frequency*  {.bitsize: 2.}: uint16
    cascade*    {.bitsize: 1.}: bool
    not_used_2* {.bitsize: 3.}: uint16
    irq_enable* {.bitsize: 1.}: bool
    enable*     {.bitsize: 1.}: bool
    not_used_1* {.bitsize: 8.}: uint16

  DISPCNT* {.packed.} = object
    bg_mode*              {.bitsize: 3.}: uint16
    reserved_for_bios*    {.bitsize: 1.}: bool
    display_frame_select* {.bitsize: 1.}: bool
    hblank_interval_free* {.bitsize: 1.}: bool
    obj_mapping_1d*       {.bitsize: 1.}: bool
    forced_blank*         {.bitsize: 1.}: bool
    default_enable_bits*  {.bitsize: 5.}: uint16
    window_0_display*     {.bitsize: 1.}: bool
    window_1_display*     {.bitsize: 1.}: bool
    obj_window_display*   {.bitsize: 1.}: bool

  DISPSTAT* {.packed.} = object
    vblank*              {.bitsize: 1.}: bool
    hblank*              {.bitsize: 1.}: bool
    vcounter*            {.bitsize: 1.}: bool
    vblank_irq_enable*   {.bitsize: 1.}: bool
    hblank_irq_enable*   {.bitsize: 1.}: bool
    vcounter_irq_enable* {.bitsize: 1.}: bool
    not_used*            {.bitsize: 2.}: uint16
    vcount_setting*      {.bitsize: 8.}: uint16

  BGCNT* {.packed.} = object
    priority*             {.bitsize: 2.}: uint16
    character_base_block* {.bitsize: 2.}: uint16
    not_used*             {.bitsize: 2.}: uint16
    mosaic*               {.bitsize: 1.}: bool
    color_mode_8bpp*      {.bitsize: 1.}: bool
    screen_base_block*    {.bitsize: 5.}: uint16
    affine_wrap*          {.bitsize: 1.}: bool
    screen_size*          {.bitsize: 2.}: uint16

  BGOFS* {.packed.} = object
    offset*   {.bitsize: 9.}: uint16
    not_used* {.bitsize: 7.}: uint16

  BGAFF* {.packed.} = object
    fraction* {.bitsize: 8.}: uint16
    integer*  {.bitsize: 7.}: uint16
    sign*     {.bitsize: 1.}: bool

  WINH* {.packed.} = object
    x2* {.bitsize: 8.}: uint16
    x1* {.bitsize: 8.}: uint16

  WINV* {.packed.} = object
    y2* {.bitsize: 8.}: uint16
    y1* {.bitsize: 8.}: uint16

  WININ* {.packed.} = object
    window_0_enable_bits*          {.bitsize: 5.}: uint16
    window_0_color_special_effect* {.bitsize: 1.}: bool
    not_used_0*                    {.bitsize: 2.}: uint16
    window_1_enable_bits*          {.bitsize: 5.}: uint16
    window_1_color_special_effect* {.bitsize: 1.}: bool
    not_used_1*                    {.bitsize: 2.}: uint16

  WINOUT* {.packed.} = object
    outside_enable_bits*             {.bitsize: 5.}: uint16
    outside_color_special_effect*    {.bitsize: 1.}: bool
    not_used_outside*                {.bitsize: 2.}: uint16
    obj_window_enable_bits*          {.bitsize: 5.}: uint16
    obj_window_color_special_effect* {.bitsize: 1.}: bool
    not_used_obj*                    {.bitsize: 2.}: uint16

  MOSAIC* {.packed.} = object
    bg_mosiac_h_size*  {.bitsize: 4.}: uint16
    bg_mosiac_v_size*  {.bitsize: 4.}: uint16
    obj_mosiac_h_size* {.bitsize: 4.}: uint16
    obj_mosiac_v_size* {.bitsize: 4.}: uint16

  BLDCNT* {.packed.} = object
    bg0_1st_target_pixel* {.bitsize: 1.}: bool
    bg1_1st_target_pixel* {.bitsize: 1.}: bool
    bg2_1st_target_pixel* {.bitsize: 1.}: bool
    bg3_1st_target_pixel* {.bitsize: 1.}: bool
    obj_1st_target_pixel* {.bitsize: 1.}: bool
    bd_1st_target_pixel*  {.bitsize: 1.}: bool
    blend_mode*           {.bitsize: 2.}: uint16
    bg0_2nd_target_pixel* {.bitsize: 1.}: bool
    bg1_2nd_target_pixel* {.bitsize: 1.}: bool
    bg2_2nd_target_pixel* {.bitsize: 1.}: bool
    bg3_2nd_target_pixel* {.bitsize: 1.}: bool
    obj_2nd_target_pixel* {.bitsize: 1.}: bool
    bd_2nd_target_pixel*  {.bitsize: 1.}: bool
    not_used*             {.bitsize: 2.}: uint16

  BLDALPHA* {.packed.} = object
    eva_coefficient* {.bitsize: 5.}: uint16
    not_used_5_7*    {.bitsize: 3.}: uint16
    evb_coefficient* {.bitsize: 5.}: uint16
    not_used_13_15*  {.bitsize: 3.}: uint16

  BLDY* {.packed.} = object
    evy_coefficient* {.bitsize:  5.}: uint16
    not_used*        {.bitsize: 11.}: uint16

  KEYINPUT* {.packed.} = object
    a*        {.bitsize: 1.}: bool
    b*        {.bitsize: 1.}: bool
    select*   {.bitsize: 1.}: bool
    start*    {.bitsize: 1.}: bool
    right*    {.bitsize: 1.}: bool
    left*     {.bitsize: 1.}: bool
    up*       {.bitsize: 1.}: bool
    down*     {.bitsize: 1.}: bool
    r*        {.bitsize: 1.}: bool
    l*        {.bitsize: 1.}: bool
    not_used* {.bitsize: 6.}: uint16

  KEYCNT* {.packed.} = object
    a*             {.bitsize: 1.}: bool
    b*             {.bitsize: 1.}: bool
    select*        {.bitsize: 1.}: bool
    start*         {.bitsize: 1.}: bool
    right*         {.bitsize: 1.}: bool
    left*          {.bitsize: 1.}: bool
    up*            {.bitsize: 1.}: bool
    down*          {.bitsize: 1.}: bool
    r*             {.bitsize: 1.}: bool
    l*             {.bitsize: 1.}: bool
    not_used*      {.bitsize: 4.}: uint16
    irq_enable*    {.bitsize: 1.}: bool
    irq_condition* {.bitsize: 1.}: bool

  # BGREF is 32-bit, handled separately from the GbaReg16 type class
  BGREF* {.packed.} = object
    fraction* {.bitsize:  8.}: uint32
    integer*  {.bitsize: 19.}: uint32
    sign*     {.bitsize:  1.}: bool
    not_used* {.bitsize:  4.}: uint32

  # Type class covering all 16-bit GBA I/O registers
  GbaReg16* = WAITCNT | InterruptReg | SOUNDCNT_L | SOUNDCNT_H | SOUNDBIAS |
              DMACNT | TMCNT | DISPCNT | DISPSTAT | BGCNT | BGOFS | BGAFF |
              WINH | WINV | WININ | WINOUT | MOSAIC | BLDCNT | BLDALPHA | BLDY |
              KEYINPUT | KEYCNT

####################
# Converters and I/O helpers

converter toU16*(reg: GbaReg16): uint16 = cast[uint16](reg)
converter toU32*(reg: BGREF): uint32     = cast[uint32](reg)

proc read*(reg: GbaReg16; byte_num: SomeInteger): uint8 {.inline.} =
  cast[uint8](toU16(reg) shr (8 * byte_num))

proc write*[T: GbaReg16](reg: var T; value: uint8; byte_num: SomeInteger) {.inline.} =
  let shift = 8 * byte_num
  let mask  = not(0xFF'u16 shl shift)
  reg = cast[T]((mask and toU16(reg)) or (value.uint16 shl shift))

proc read*(reg: BGREF; byte_num: SomeInteger): uint8 {.inline.} =
  cast[uint8](toU32(reg) shr (8 * byte_num))

proc write*(reg: var BGREF; value: uint8; byte_num: SomeInteger) {.inline.} =
  let shift = 8 * byte_num
  let mask  = not(0xFF'u32 shl shift)
  reg = cast[BGREF]((mask and toU32(reg)) or (value.uint32 shl shift))

proc read*[T: uint16 | uint32](reg: T; byte_num: SomeInteger): uint8 {.inline.} =
  cast[uint8](reg shr (8 * byte_num))

proc write*[T: uint16 | uint32](reg: var T; value: uint8; byte_num: SomeInteger) {.inline.} =
  let shift = 8 * byte_num
  let mask  = not(0xFF.T shl shift)
  reg = (mask and reg) or (value.T shl shift)

####################
# Custom procs

proc num*(self: BGAFF): int16 {.inline.} =
  cast[int16](toU16(self))

proc num*(self: BGREF): int32 {.inline.} =
  cast[int32](toU32(self) shl 4) shr 4

proc layer_target*(self: BLDCNT; layer, target: int): bool {.inline.} =
  bit(toU16(self), layer + (target - 1) * 8)
