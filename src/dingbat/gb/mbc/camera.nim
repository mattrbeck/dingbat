# Game Boy Camera / Pocket Camera cartridge (included by gb.nim)
#
# Cart type 0xFC. The mapper IC is Nintendo's MAC-GBD; the image sensor on its
# own daughterboard is a Mitsubishi M64282FP "retina" chip.
#
# Pan Docs, "Game Boy Camera" (Antonio Niño Díaz's reverse engineering,
# https://github.com/AntonioND/gbcam-rev-engineer); the capture pipeline
# follows that page's sample code.
#
# Banking is MBC3-shaped: a 6-bit ROM bank at 0x2000-0x3FFF and a RAM bank at
# 0x4000-0x5FFF. What makes it a camera is bit 4 of the RAM bank register: set
# it and 0xA000-0xBFFF stops being RAM and becomes 54 registers, mirrored every
# 0x80 bytes. Register A000 is the shutter — writing bit 0 starts a capture and
# reading bit 0 says whether one is still running — and A001-A005 are five of
# the M64282FP's own registers passed straight through. The remaining 48 form a
# 4x4x3 threshold matrix that belongs to the MAC-GBD rather than the sensor, and
# is what turns the sensor's analogue level into two bits per pixel.
#
# Two things about the memory window are unlike any other mapper:
#   * "Reading from RAM or registers is always enabled. Writing to registers is
#     always enabled." Only RAM *writes* obey the 0x0A enable.
#   * While a capture is running the whole RAM window reads back 0x00 and
#     ignores writes, because the MAC-GBD has the RAM bus to itself. Register
#     A000 keeps answering, which is how the game knows when to look again.

const
  CAM_SENSOR_W       = 128
  CAM_SENSOR_EXTRA   = 8    # rows the sensor delivers that the MAC-GBD discards
  CAM_H              = 112
  CAM_SENSOR_H       = CAM_H + CAM_SENSOR_EXTRA
  CAM_IMAGE_OFFSET   = 0x0100  # where in RAM bank 0 the captured tiles land
  CAM_IMAGE_LEN      = 14 * 16 * 16

# ---------------------------------------------------------------------------
# Sensor image source: a deterministic synthetic scene unless a frontend
# installs one with set_camera_source (sensor coordinates 0..127, 0..119 ->
# 8-bit grey). Nothing downstream knows where the pixels came from.
# ---------------------------------------------------------------------------

proc camera_test_pattern(x, y: int): uint8 =
  ## Stand-in scene. Chosen to exercise the pipeline rather than to look like
  ## anything: a diagonal ramp for the ROM's auto-exposure loop to converge on,
  ## hard-edged blocks for edge enhancement to bite on, and a disc of smoothly
  ## varying level for the dither matrix to work over.
  var v = (x * 3 + y * 2) and 0xFF
  if (((x shr 4) + (y shr 4)) and 1) == 1: v = (v + 96) and 0xFF
  let dx = x - 64
  let dy = y - CAM_SENSOR_H div 2
  if dx * dx + dy * dy < 30 * 30: v = 255 - v
  uint8(v)

proc camera_pixel(cart: PocketCamera; x, y: int): int =
  let cx = clamp(x, 0, CAM_SENSOR_W - 1)
  let cy = clamp(y, 0, CAM_SENSOR_H - 1)
  let src = cart.sensor
  if src != nil: int(src(cx, cy)) else: int(camera_test_pattern(cx, cy))

proc set_camera_source*(cart: Mbc; src: proc(x, y: int): uint8) =
  ## Replace the synthetic scene with a real image source. A no-op on every
  ## other mapper, so callers need not check the cartridge type first.
  if cart of PocketCamera: PocketCamera(cart).sensor = src

# ---------------------------------------------------------------------------
# Capture pipeline
# ---------------------------------------------------------------------------

proc cam_matrix_process(cart: PocketCamera; value, x, y: int): int =
  ## The MAC-GBD's 4x4 threshold matrix: three ascending thresholds per cell
  ## turn one grey level into one of four output levels. Being per-(x,y) is what
  ## makes it a dither pattern as well as a contrast curve.
  let base = 6 + ((y and 3) * 4 + (x and 3)) * 3
  if value < int(cart.regs[base]):     0x00
  elif value < int(cart.regs[base+1]): 0x40
  elif value < int(cart.regs[base+2]): 0x80
  else:                                0xC0

proc camera_capture(cart: PocketCamera) =
  ## Run the sensor and the MAC-GBD over one frame and leave the result in RAM.
  # The real cartridge writes pixels to RAM as the sensor clocks them out;
  # collapsed to one instant as the Pan Docs sample code does, since the RAM
  # window is unreadable for the whole capture.
  if cart.ram.len < CAM_IMAGE_OFFSET + CAM_IMAGE_LEN: return

  # --- sensor configuration ---
  # Register A000 bits 1-2 pick the M64282FP's registers 4, 5 and 6, which are
  # the coefficients of its one-dimensional filter: P is what is added, M what
  # is subtracted, each over {this pixel, the pixel below}.
  var p_bits, m_bits: int
  case (int(cart.regs[0]) shr 1) and 3
  of 0: p_bits = 0x00; m_bits = 0x01
  of 1: p_bits = 0x01; m_bits = 0x00
  else: p_bits = 0x01; m_bits = 0x02   # values 2 and 3 behave alike

  let n_bit    = (int(cart.regs[1]) shr 7) and 1        # M64282FP reg 1 bit 7
  let vh_bits  = (int(cart.regs[1]) shr 5) and 3        # reg 1 bits 6-5
  let exposure = (int(cart.regs[2]) shl 8) or int(cart.regs[3])
  const edge_ratio_lut = [0.50, 0.75, 1.00, 1.25, 2.00, 3.00, 4.00, 5.00]
  let alpha  = edge_ratio_lut[(int(cart.regs[4]) shr 4) and 7]  # reg 7 bits 6-4
  let e3_bit = (int(cart.regs[4]) shr 7) and 1
  let i_bit  = (int(cart.regs[4]) shr 3) and 1

  var buf: array[CAM_SENSOR_W, array[CAM_SENSOR_H, int]]
  var tmp: array[CAM_SENSOR_W, array[CAM_SENSOR_H, int]]

  # --- exposure and level shift ---
  # Pan Docs: the sensor's gain and level control are deliberately NOT
  # emulated (a real capture source has its own auto-exposure). Only the
  # exposure register is applied, as the Pan Docs sample code does.
  for i in 0 ..< CAM_SENSOR_W:
    for j in 0 ..< CAM_SENSOR_H:
      var v = camera_pixel(cart, i, j)
      v = (v * exposure) div 0x0300
      v = 128 + ((v - 128) * 1) div 8
      buf[i][j] = clamp(v, 0, 255)

  if i_bit != 0:   # M64282FP register 7 bit 3 inverts the image
    for i in 0 ..< CAM_SENSOR_W:
      for j in 0 ..< CAM_SENSOR_H: buf[i][j] = 255 - buf[i][j]

  for i in 0 ..< CAM_SENSOR_W:
    for j in 0 ..< CAM_SENSOR_H: buf[i][j] = buf[i][j] - 128   # make signed

  # --- edge processing ---
  # Mode = N, the two VH bits and E3. Only the four cases below are
  # documented; anything else passes the image through, as the sample code does.
  case (n_bit shl 3) or (vh_bits shl 1) or e3_bit
  of 0x0:   # plain 1-D filter
    for i in 0 ..< CAM_SENSOR_W:
      for j in 0 ..< CAM_SENSOR_H: tmp[i][j] = buf[i][j]
    for i in 0 ..< CAM_SENSOR_W:
      for j in 0 ..< CAM_SENSOR_H:
        let ms = tmp[i][min(j + 1, CAM_SENSOR_H - 1)]
        let px = tmp[i][j]
        var v = 0
        if (p_bits and 1) != 0: v += px
        if (p_bits and 2) != 0: v += ms
        if (m_bits and 1) != 0: v -= px
        if (m_bits and 2) != 0: v -= ms
        buf[i][j] = clamp(v, -128, 127)
  of 0x2:   # 1-D filter with horizontal enhancement: P + (2P - MW - ME) * alpha
    for i in 0 ..< CAM_SENSOR_W:
      for j in 0 ..< CAM_SENSOR_H:
        let mw = buf[max(0, i - 1)][j]
        let me = buf[min(i + 1, CAM_SENSOR_W - 1)][j]
        let px = buf[i][j]
        # The Pan Docs sample clamps this intermediate to 0..255 though the
        # buffer is signed (the 2-D case clamps to -128..127). Reproduced as
        # published; the Camera ROM uses the 2-D mode, so no title settles it.
        tmp[i][j] = clamp(int(float(px) + float(2 * px - mw - me) * alpha), 0, 255)
    for i in 0 ..< CAM_SENSOR_W:
      for j in 0 ..< CAM_SENSOR_H:
        let ms = tmp[i][min(j + 1, CAM_SENSOR_H - 1)]
        let px = tmp[i][j]
        var v = 0
        if (p_bits and 1) != 0: v += px
        if (p_bits and 2) != 0: v += ms
        if (m_bits and 1) != 0: v -= px
        if (m_bits and 2) != 0: v -= ms
        buf[i][j] = clamp(v, -128, 127)
  of 0xE:   # 2-D enhancement: P + (4P - MN - MS - ME - MW) * alpha
    for i in 0 ..< CAM_SENSOR_W:
      for j in 0 ..< CAM_SENSOR_H:
        let ms = buf[i][min(j + 1, CAM_SENSOR_H - 1)]
        let mn = buf[i][max(0, j - 1)]
        let mw = buf[max(0, i - 1)][j]
        let me = buf[min(i + 1, CAM_SENSOR_W - 1)][j]
        let px = buf[i][j]
        tmp[i][j] = clamp(int(float(px) + float(4 * px - mw - me - mn - ms) * alpha),
                          -128, 127)
    for i in 0 ..< CAM_SENSOR_W:
      for j in 0 ..< CAM_SENSOR_H: buf[i][j] = tmp[i][j]
  of 0x1:
    # Pan Docs: "In my GB Camera cartridge this is always the same color."
    for i in 0 ..< CAM_SENSOR_W:
      for j in 0 ..< CAM_SENSOR_H: buf[i][j] = 0
  else: discard   # undocumented combination: pass the image through unfiltered

  for i in 0 ..< CAM_SENSOR_W:
    for j in 0 ..< CAM_SENSOR_H: buf[i][j] = buf[i][j] + 128   # make unsigned

  # --- MAC-GBD: threshold to 2 bits and pack into Game Boy tiles ---
  # The sensor hands over 128 rows but the MAC-GBD keeps only the middle ones,
  # so the vertical index is offset by half the discarded rows.
  for i in 0 ..< CAM_IMAGE_LEN: cart.ram[CAM_IMAGE_OFFSET + i] = 0
  for i in 0 ..< CAM_SENSOR_W:
    for j in 0 ..< CAM_H:
      let level = cam_matrix_process(cart, buf[i][j + CAM_SENSOR_EXTRA div 2], i, j)
      let outcolor = 3 - (level shr 6)
      # 16 tiles across, 14 down, in the Game Boy's 2bpp interleaved format
      let base = CAM_IMAGE_OFFSET + ((j shr 3) * 16 + (i shr 3)) * 16 + (j and 7) * 2
      if (outcolor and 1) != 0:
        cart.ram[base]     = cart.ram[base]     or (1'u8 shl (7 - (i and 7)))
      if (outcolor and 2) != 0:
        cart.ram[base + 1] = cart.ram[base + 1] or (1'u8 shl (7 - (i and 7)))
  cart.ram_dirty = true

proc camera_capture_cycles(cart: PocketCamera): int =
  ## How long the cartridge holds the RAM bus, in Game Boy T-cycles.
  # Pan Docs, in M-cycles: CYCLES = 32446 + (N ? 0 : 512) + 16 * exposure.
  let exposure = (int(cart.regs[2]) shl 8) or int(cart.regs[3])
  let n_term = if (cart.regs[1] and 0x80) != 0: 0 else: 512
  4 * (32446 + n_term + 16 * exposure)

proc camera_schedule(cart: PocketCamera) =
  cart.gb_ref.scheduler.clear(etCameraDone)
  # Raw scheduler cycles, not schedule_gb: the cartridge clocks itself from
  # PHI, which doubles with the CPU in double speed (Pan Docs: "the values
  # used for exposure time should be doubled").
  cart.gb_ref.scheduler.schedule(cart.capture_cycles_left, etCameraDone)

proc camera_done*(cart: PocketCamera) =
  cart.capture_cycles_left = 0
  cart.regs[0] = cart.regs[0] and not 1'u8

# ---------------------------------------------------------------------------
# Register file
# ---------------------------------------------------------------------------

proc camera_reg_write(cart: PocketCamera; idx: int; val: uint8) =
  let reg = (idx - 0xA000) and 0x7F   # mirrored every 0x80 bytes
  if reg == 0:
    # "The lower 3 bits of this register can be read and write. The other bits
    # return '0'."
    let v = val and 0x07
    let was_busy = (cart.regs[0] and 1) != 0
    if (v and 1) != 0 and not was_busy:
      cart.regs[0] = v
      if cart.capture_cycles_left == 0:
        # Fresh capture: run the whole pipeline now, then hold the bus.
        cart.camera_capture()
        cart.capture_cycles_left = cart.camera_capture_cycles()
      # else: resuming a stopped capture with the old parameters (Pan Docs).
      cart.camera_schedule()
    elif (v and 1) == 0 and was_busy:
      # Stopping a capture (Pan Docs documents stop and resume). The partially
      # written image a real cartridge leaves is not modelled.
      let s = cart.gb_ref.scheduler
      var remaining = cart.capture_cycles_left
      for ev in s.events:
        if ev.kind == etCameraDone: remaining = int(ev.cycles - s.cycles)
      cart.capture_cycles_left = max(remaining, 0)
      s.clear(etCameraDone)
      cart.regs[0] = v
    else:
      cart.regs[0] = v
  elif reg < 0x36:
    cart.regs[reg] = val
  # 0x36-0x7F decode to nothing at all

proc camera_reg_read(cart: PocketCamera; idx: int): uint8 =
  # "All registers are write-only, except the register A000. The others return
  # $00 when read."
  if ((idx - 0xA000) and 0x7F) == 0: cart.regs[0] and 0x07 else: 0x00'u8

method mbc_rom_map*(cart: PocketCamera): (int, int) =
  (0, mbc_rom_bank_offset(cart, int(cart.rom_bank_num)))

method mbc_read*(cart: PocketCamera; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    # "This area may contain any ROM bank (0 included)" — no remap away from 0
    cart.rom[mbc_rom_bank_offset(cart, int(cart.rom_bank_num)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    if cart.regs_mapped: camera_reg_read(cart, idx)
    elif (cart.regs[0] and 1) != 0:
      0x00'u8   # capture in progress: the MAC-GBD has the RAM to itself
    elif cart.ram.len > 0:
      # Note the missing ram_enabled test: "Reading from RAM or registers is
      # always enabled."
      cart.ram[mbc_ram_bank_offset(cart, int(cart.ram_bank_num)) + mbc_ram_offset(cart, idx)]
    else: 0xFF'u8
  else: 0xFF'u8

method mbc_write*(cart: PocketCamera; idx: int; val: uint8) =
  case idx
  of 0x0000..0x1FFF:
    let was_enabled = cart.ram_enabled
    cart.ram_enabled = (val and 0x0F) == 0x0A
    if was_enabled and not cart.ram_enabled: mbc_save(cart)
  of 0x2000..0x3FFF: cart.rom_bank_num = val and 0x3F
  of 0x4000..0x5FFF:
    cart.ram_bank_num = val and 0x0F
    cart.regs_mapped  = (val and 0x10) != 0
  of 0x6000..0x7FFF: discard
  of 0xA000..0xBFFF:
    if cart.regs_mapped:
      camera_reg_write(cart, idx, val)   # "Writing to registers is always enabled"
    elif (cart.regs[0] and 1) == 0 and cart.ram_enabled and cart.ram.len > 0:
      cart.ram_dirty = true
      cart.ram[mbc_ram_bank_offset(cart, int(cart.ram_bank_num)) + mbc_ram_offset(cart, idx)] = val
  else: discard
