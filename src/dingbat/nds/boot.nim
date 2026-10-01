# Direct boot (included by nds.nim): put the machine in the state the BIOS
# and firmware leave it in when they jump to a cart, without running them.
# docs/nds/gbatek-notes.md 12.2 is the checklist this follows.

proc crc16*(data: openArray[uint8]; start = 0xFFFF'u16): uint16 =
  ## The BIOS GetCRC16 / header CRC: reflected 0xA001, byte-wise.
  var crc = start
  for b in data:
    crc = crc xor uint16(b)
    for _ in 0..7:
      crc = if (crc and 1) != 0: (crc shr 1) xor 0xA001'u16 else: crc shr 1
  crc

proc synth_firmware*(): seq[uint8] =
  ## A 256 KB firmware image good enough for games that read their user
  ## settings: header, MAC, and two identical user-settings copies with
  ## valid CRCs (nickname "dingbat", English, touch calibration 1:1-ish).
  result = newSeq[uint8](256 * 1024)
  for i in 0x200 ..< result.len: result[i] = 0xFF
  let us = 0x3FE00
  result[0x08] = uint8('M'); result[0x09] = uint8('A'); result[0x0A] = uint8('C')
  result[0x0B] = uint8('P')
  result[0x1D] = 0xFF                       # console type: DS
  result[0x20] = uint8((us div 8) and 0xFF)
  result[0x21] = uint8((us div 8) shr 8)
  let mac = [0x00'u8, 0x09, 0xBF, 0x12, 0x34, 0x56]
  for i in 0..5: result[0x36 + i] = mac[i]
  for copy in 0..1:
    let base = us + copy * 0x100
    for i in 0 ..< 0x100: result[base + i] = 0
    result[base + 0x00] = 5                 # version
    result[base + 0x02] = 11                # favourite colour
    result[base + 0x03] = 1                 # birthday month
    result[base + 0x04] = 1                 # birthday day
    let nick = "dingbat"
    for i, ch in nick:
      result[base + 0x06 + i * 2] = uint8(ch)
    result[base + 0x1A] = uint8(nick.len)
    # touch calibration: adc (0x200,0x200) <-> (1,1); (0xE00,0xA00) <-> (255,191)
    template w16(o, v: int) =
      result[base + o] = uint8(v and 0xFF); result[base + o + 1] = uint8(v shr 8)
    w16(0x58, 0x200); w16(0x5A, 0x200)
    result[base + 0x5C] = 1; result[base + 0x5D] = 1
    w16(0x5E, 0xE00); w16(0x60, 0xA00)
    result[base + 0x62] = 255; result[base + 0x63] = 191
    w16(0x64, 1 or (3 shl 4) or (0xFC shl 8))  # English, max backlight, flags
    result[base + 0x66] = 26                # year 2026
    result[base + 0x70] = uint8(copy)       # update counter: copy 1 newer
    let c = crc16(result.toOpenArray(base, base + 0x6F))
    w16(0x72, int(c))

proc direct_boot*(n: NDS) =
  let rom = n.cart.rom
  if rom.len < 0x200:
    stderr.writeLine("nds: ROM too small for a header; nothing to boot")
    return
  template hdr32(o: int): uint32 = rd32(rom, o)
  let arm9_off = int(hdr32(0x20))
  let arm9_entry = hdr32(0x24)
  let arm9_ram = hdr32(0x28)
  let arm9_size = int(hdr32(0x2C))
  let arm7_off = int(hdr32(0x30))
  let arm7_entry = hdr32(0x34)
  let arm7_ram = hdr32(0x38)
  let arm7_size = int(hdr32(0x3C))
  # Binaries go through the CPUs' own maps, so 0x037F8000 / 0x0380xxxx ARM7
  # loads land in WRAM. WRAMCNT=3 first: all shared WRAM to the ARM7.
  n.wramcnt = 3
  let b9 = Arm9Bus(nds: n)
  let b7 = Arm7Bus(nds: n)
  for i in 0 ..< arm9_size:
    if arm9_off + i < rom.len:
      n.write9(arm9_ram + uint32(i), uint32(rom[arm9_off + i]), 8)
  for i in 0 ..< arm7_size:
    if arm7_off + i < rom.len:
      n.write7(arm7_ram + uint32(i), uint32(rom[arm7_off + i]), 8)
  # Secure area: a decrypted dump starts its first 8 bytes with "encryObj";
  # the BIOS replaces them with E7FFDEFF E7FFDEFF.
  if arm9_off == 0x4000 and arm9_size >= 8 and rom.len >= 0x4008:
    var tag = ""
    for i in 0..7: tag.add(char(rom[0x4000 + i]))
    if tag == "encryObj":
      wr32(n.main_ram, int(arm9_ram and 0x3FFFFF), 0xE7FFDEFF'u32)
      wr32(n.main_ram, int((arm9_ram + 4) and 0x3FFFFF), 0xE7FFDEFF'u32)
  # Header to 0x27FFE00
  for i in 0 ..< 0x170: n.main_ram[0x3FFE00 + i] = rom[i]
  # Boot info (GBATEK 12.2)
  template m32(a: uint32; v: uint32) = wr32(n.main_ram, int(a and 0x3FFFFF), v)
  template m16(a: uint32; v: uint32) = wr16(n.main_ram, int(a and 0x3FFFFF), v)
  let chip = n.cart.chip_id
  m32(0x027FF800'u32, chip); m32(0x027FF804'u32, chip)
  m32(0x027FFC00'u32, chip); m32(0x027FFC04'u32, chip)
  m16(0x027FF808'u32, rd16(rom, 0x15E)); m16(0x027FFC08'u32, rd16(rom, 0x15E))
  m16(0x027FF80A'u32, rd16(rom, 0x06C)); m16(0x027FFC0A'u32, rd16(rom, 0x06C))
  m16(0x027FF810'u32, 0xFFFF)
  m16(0x027FF850'u32, 0x5835); m16(0x027FFC10'u32, 0x5835)
  m32(0x027FF880'u32, 7); m32(0x027FF884'u32, 6)
  m32(0x027FF868'u32, uint32(n.spi.user_settings_offset()))
  for i in 0 ..< 12: n.main_ram[0x3FFC30 + i] = 0xFF   # no GBA cart
  m16(0x027FFC40'u32, 1)                                 # boot indicator
  let us = n.spi.user_settings()
  for i in 0 ..< 0x70: n.main_ram[0x3FFC80 + i] = n.spi.firmware[us + i]
  wr32(n.arm7_wram, 0xF980, 0xFBDD37BB'u32)
  # I/O
  n.postflg9 = 1
  n.postflg7 = 1
  n.exmemcnt = 0x6000
  n.exmem7_lo = 0
  n.gpu.write_powcnt1(0x0203)
  n.powcnt2 = 1
  n.biosprot = 0x1204
  n.cart.romctrl = 0x2000_0000'u32  # reset released, KEY2 data mode
  # CP15 (derived; the crt0 reprograms it): DTCM 0x027C0000 16 KB, ITCM
  # 32 MB window from 0, high vectors.
  n.cp15.reset()
  n.cp15.write(0, 9, 1, 0, 0x027C000A'u32)
  n.cp15.write(0, 9, 1, 1, 0x00000020'u32)
  n.cp15.write(0, 1, 0, 0, 0x00052078'u32)  # + ITCM on
  n.arm9.vector_base = n.cp15.vector_base()
  # CPUs: system mode, ARM, stacks per GBATEK.
  for cpu9 in [n.arm9]:
    cpu9.set_cpsr(uint32(mSYS) or FLAG_I or FLAG_F)
    cpu9.set_mode_sp(mSYS, 0x03002F7C'u32)
    cpu9.set_mode_sp(mIRQ, 0x03003F80'u32)
    cpu9.set_mode_sp(mSVC, 0x03003FC0'u32)
    cpu9.r[12] = arm9_entry; cpu9.r[14] = arm9_entry
    cpu9.next_pc = arm9_entry
  n.arm7.set_cpsr(uint32(mSYS) or FLAG_I or FLAG_F)
  n.arm7.set_mode_sp(mSYS, 0x0380FD80'u32)
  n.arm7.set_mode_sp(mIRQ, 0x0380FF80'u32)
  n.arm7.set_mode_sp(mSVC, 0x0380FFC0'u32)
  n.arm7.r[12] = arm7_entry; n.arm7.r[14] = arm7_entry
  n.arm7.next_pc = arm7_entry
  n.arm7.vector_base = 0
  discard b9
  discard b7
