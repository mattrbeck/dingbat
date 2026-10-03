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

const
  FW_WIFI_CONFIG_LEN* = 0x138
    ## firmware[02Ch]: the wifi settings CRC covers 02Ch..163h (GBATEK "DS
    ## Firmware Wifi Calibration Data": "usually 0138h")
  FW_RF_INIT = [0x00C007'u32, 0x129C03, 0x141728, 0x1AE8BA, 0x1D456F, 0x23FFFA,
                0x241D50, 0x280001, 0x2C0000, 0x069C03, 0x080022, 0x0DFF6F]
    ## RF[0,4,5,6,7,8,9,0Ah,0Bh,1,2,3] as 24-bit index<<18 | data: GBATEK
    ## "DS Wifi RF9008 Registers", the example table, with RF[09h] = 01D50h
    ## ("firmware v5 and up uses narrower tx filter")
  FW_W_CONFIG = [0x0002'u16, 0x0017, 0x0026, 0x1818, 0x0048, 0x4840, 0x0058,
                 0x0042, 0x0140, 0x8064, 0xE0E0, 0x2443, 0x0003, 0x0032,
                 0x01F4, 0x0101]
    ## firmware[044h..063h] for W_CONFIG_146h,148h,14Ah,14Ch,120h,122h,154h,
    ## 144h,130h,132h,140h,142h, W_POWER_TX, 124h,128h,150h: the "new value
    ## after initialization from firmware settings" of GBATEK "DS Wifi
    ## Configuration Ports" ("identical in all currently existing consoles").
    ## W_POWER_TX has no listed value: Assumed its reset value 0003h.

proc fw_rf_channel(ch: int): (uint32, uint32) =
  ## The type-2 RF's two writes for channel `ch` (firmware[0F2h + (ch-1)*6]):
  ## RF[05h] = divide-by-N << 6 | numerator bits 23-18, RF[06h] = numerator
  ## bits 17-0 (GBATEK "DS Wifi RF9008 Registers"), a fractional-N divider
  ## of the RFU's 22 MHz clock (GBATEK "DS Wifi" pin-outs). GBATEK's example
  ## RF[05h]/RF[06h] (01728h, 2E8BAh) are N = 92 + 10676410/2^24 = 2038 MHz /
  ## 22 MHz, channel 1 (2412 MHz) less a 374 MHz IF; the other channels move
  ## the LO with the carrier (GBATEK "Channels": 2412..2472 MHz in 5 MHz steps,
  ## 2484 MHz for 14), the fraction rounded to nearest.
  let mhz = if ch == 14: 2484 else: 2407 + 5 * ch
  let num = (int64(mhz - 374) shl 25 + 22) div 44   # round(lo / 22 * 2^24)
  let n = uint32(num shr 24)
  let frac = uint32(num and 0xFFFFFF)
  ((5'u32 shl 18) or (n shl 6) or (frac shr 18), (6'u32 shl 18) or (frac and 0x3FFFF))

proc synth_firmware*(): seq[uint8] =
  ## A 256 KB firmware image for running without a firmware dump (GBATEK "DS
  ## Firmware Header", "Wifi Calibration Data", "Wifi Internet Access
  ## Points", "User Settings"): an original-DS (type FFh, wifi v5) header
  ## with a MAC, a complete CRC-valid type-2 wifi calibration section,
  ## three unconfigured access points, and two user-settings copies with
  ## valid CRCs (nickname "dingbat", English, touch calibration 1:1-ish).
  ## No firmware code: a firmware boot needs a real dump.
  result = newSeq[uint8](256 * 1024)
  for i in 0x200 ..< result.len: result[i] = 0xFF
  let us = 0x3FE00
  template w16at(o, v: int) =
    result[o] = uint8(v and 0xFF); result[o + 1] = uint8((v shr 8) and 0xFF)
  template w24at(o: int; v: uint32) =
    result[o] = uint8(v and 0xFF); result[o + 1] = uint8((v shr 8) and 0xFF)
    result[o + 2] = uint8((v shr 16) and 0xFF)
  result[0x08] = uint8('M'); result[0x09] = uint8('A'); result[0x0A] = uint8('C')
  result[0x0B] = uint8('P')
  result[0x1D] = 0xFF                       # console type: DS
  result[0x1E] = 0xFF; result[0x1F] = 0xFF  # unused, FFh-filled
  result[0x20] = uint8((us div 8) and 0xFF)
  result[0x21] = uint8((us div 8) shr 8)
  result[0x28] = 0xFF; result[0x29] = 0xFF  # unused, FFh-filled
  # Wifi calibration (GBATEK "DS Firmware Wifi Calibration Data"). Games'
  # wireless code refuses a section with config length 0 or no enabled
  # channel ("A communication error has occurred" in SoulSilver's CONTINUE).
  w16at(0x2C, FW_WIFI_CONFIG_LEN)
  result[0x2F] = 3                          # wifi version: firmware v5
  let mac = [0x00'u8, 0x09, 0xBF, 0x12, 0x34, 0x56]   # v1-v5 form 0009BFxxxxxx
  for i in 0..5: result[0x36 + i] = mac[i]
  w16at(0x3C, 0x3FFE)                       # channels 1..13 enabled
  w16at(0x3E, 0xFFFF)                       # flags, "usually FFFFh"
  result[0x40] = 2                          # RF chip type 2 (RF9008), as an original DS
  result[0x41] = 0x18                       # 24 bits per RF entry
  result[0x42] = uint8(FW_RF_INIT.len)      # 0Ch entries
  result[0x43] = 1                          # unknown, "usually 01h"
  for i, v in FW_W_CONFIG: w16at(0x44 + i * 2, int(v))
  # BB[0..68h]: GBATEK names only 01h = 9Eh, 13h = 00h (CCA: carrier sense),
  # 1Eh = BBh (gain), 35h = 1Fh (ED threshold); 00h reads 6Dh (chip ID).
  # The rest: Assumed 00h (the BB chip's own settings, no model reads them).
  result[0x64 + 0x00] = 0x6D
  result[0x64 + 0x01] = 0x9E
  result[0x64 + 0x1E] = 0xBB
  result[0x64 + 0x35] = 0x1F
  for i, v in FW_RF_INIT: w24at(0xCE + i * 3, v)
  for ch in 1..14:
    let (rf5, rf6) = fw_rf_channel(ch)
    w24at(0xF2 + (ch - 1) * 6, rf5)
    w24at(0xF5 + (ch - 1) * 6, rf6)
    result[0x146 + ch - 1] = 0xB4           # BB[1Eh] per channel: "B1h..B7h", Assumed B4h
    result[0x154 + ch - 1] = 0x10           # RF[9] TXVGC per channel: "usually 10h"
  result[0x162] = 0x1A                      # unknown, "usually 19h..1Ch": Assumed 1Ah
  for i in 0x163 .. 0x1FF: result[i] = 0xFF
  let wc = crc16(result.toOpenArray(0x2C, 0x2C + FW_WIFI_CONFIG_LEN - 1), 0)
  w16at(0x2A, int(wc))
  # Access points 1-3 (GBATEK "DS Firmware Wifi Internet Access Points"):
  # zero-filled, status FFh ("not configured"), CRC16 (initial 0) valid.
  for ap in 0..2:
    let base = us - 0x400 + ap * 0x100
    for i in 0 ..< 0x100: result[base + i] = 0
    result[base + 0xE7] = 0xFF
    w16at(base + 0xFE, int(crc16(result.toOpenArray(base, base + 0xFD), 0)))
  for copy in 0..1:
    let base = us + copy * 0x100
    for i in 0 ..< 0x74: result[base + i] = 0  # 74h..FFh stay FFh: no extended settings
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
  # Secure area (GBATEK "DS Cartridge Secure Area"): the BIOS decrypts the
  # first 2 KB, checks the "encryObj" ID and overwrites it with E7FFDEFF
  # E7FFDEFF. Dumps come decrypted (ID kept or already overwritten) or
  # encrypted; the encrypted form needs the BIOS7 dump's KEY1 table.
  if arm9_off == 0x4000 and arm9_size >= 0x800 and rom.has_secure_area():
    var area = rom[0x4000 ..< 0x4800]
    if boot_secure_area(rom, n.cart.key1_table, area):
      for i in 0 ..< 0x800: n.write9(arm9_ram + uint32(i), uint32(area[i]), 8)
    elif n.cart.key1_table.len == 0 and area.anyIt(it != 0):
      stderr.writeLine("nds: the secure area looks encrypted and there is no BIOS7 " &
                       "dump to decrypt it (--bios); the game will likely crash")
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
  let gba = n.slot2.gba_header_info()                   # 0xFF: no GBA cart
  for i in 0 ..< 12: n.main_ram[0x3FFC30 + i] = gba[i]
  m16(0x027FFC40'u32, 1)                                 # boot indicator
  let us = n.spi.user_settings()
  for i in 0 ..< 0x70: n.main_ram[0x3FFC80 + i] = n.spi.firmware[us + i]
  wr32(n.arm7_wram, 0xF980, 0xFBDD37BB'u32)
  # I/O
  n.postflg9 = 1
  n.postflg7 = 1
  n.exmemcnt = 0x6000
  n.exmem7_lo = 0
  n.slot9_t = slot_timing(n.exmemcnt)
  n.slot7_t = slot_timing(n.exmem7_lo)
  # LCDs, both 2D engines, 3D rendering + geometry, engine A on top: what
  # the real firmware leaves at the cart's entry (disp_powcnt booted
  # through the dumps, --boot firmware) and the reference's direct boot
  # (docs/oracles.md)
  n.gpu.write_powcnt1(0x820F)
  n.powcnt2 = 1
  n.biosprot = 0x1204
  n.cart.romctrl = 0x2000_0000'u32  # reset released, KEY2 data mode
  # CP15 and CPUs as the BIOS's own hand-off leaves them: on its way to the
  # entry point (SoftReset and the firmware boot both pass through it) the
  # ARM9 BIOS writes control = 0x00012078 (DTCM on, ITCM off, high vectors),
  # DTCM = 0x0080000A (0x00800000, 16 KB) and sets the stacks in that DTCM;
  # the ARM7 BIOS sets its stacks at the top of its WRAM. Both end in system
  # mode with IRQs unmasked in the CPSR (IME is 0) and FIQs masked.
  n.cp15.reset()
  n.cp15.write(0, 9, 1, 0, 0x0080000A'u32)
  n.cp15.write(0, 1, 0, 0, 0x00012078'u32)
  # The BIOS hand-off leaves the protection unit off but doesn't touch its
  # regions, permissions or cache bits: they stay as the firmware set them,
  # and old homebrew crt0s that enable the PU after adding only their own
  # regions rely on that (the 4K intro sd4k defines just its ITCM region,
  # then runs from main RAM under the firmware's region 1). Assumed: these
  # values are a reference core's direct boot (docs/oracles.md, NDS core,
  # tests/nds/src/boot_cp15); GBATEK lists none. ITCM size 32 MB likewise.
  for (cm, v) in [(0'u32, 0x0400_0033'u32), (1, 0x0200_002B'u32), (2, 0'u32),
                  (3, 0x0800_0035'u32), (4, 0x0300_001B'u32), (5, 0'u32),
                  (6, 0xFFFF_001D'u32), (7, 0x027F_F017'u32)]:
    n.cp15.write(0, 6, cm, 0, v)
  n.cp15.write(0, 5, 0, 2, 0x1511_1011'u32)   # data permissions
  n.cp15.write(0, 5, 0, 3, 0x0510_0011'u32)   # code permissions
  n.cp15.write(0, 2, 0, 0, 0x42)              # data cachable: regions 1, 6
  n.cp15.write(0, 2, 0, 1, 0x42)              # code cachable
  n.cp15.write(0, 3, 0, 0, 0x02)              # write buffer: region 1
  n.cp15.write(0, 9, 1, 1, 0x20)
  n.tm.update_regions(n.cp15)
  n.fetch_paths_off()
  n.arm9.vector_base = n.cp15.vector_base()
  n.arm9.set_cpsr(uint32(mSYS) or FLAG_F)
  n.arm9.set_mode_sp(mSYS, 0x00803EC0'u32)
  n.arm9.set_mode_sp(mIRQ, 0x00803FA0'u32)
  n.arm9.set_mode_sp(mSVC, 0x00803FC0'u32)
  n.arm9.r[12] = arm9_entry; n.arm9.r[14] = arm9_entry
  n.arm9.next_pc = arm9_entry
  n.arm7.set_cpsr(uint32(mSYS) or FLAG_F)
  n.arm7.set_mode_sp(mSYS, 0x0380FF00'u32)
  n.arm7.set_mode_sp(mIRQ, 0x0380FFB0'u32)
  n.arm7.set_mode_sp(mSVC, 0x0380FFDC'u32)
  n.arm7.r[12] = arm7_entry; n.arm7.r[14] = arm7_entry
  n.arm7.next_pc = arm7_entry
  n.arm7.vector_base = 0
  discard b9
  discard b7

proc firmware_boot*(n: NDS) =
  ## Power-on: both CPUs at their reset vectors in the real BIOSes, which
  ## load the firmware from SPI flash; the firmware shows its menu and
  ## boots the card through the KEY1/KEY2 handshake (cart.nim). Values not
  ## given by GBATEK are marked Assumed.
  n.wramcnt = 0                      # Assumed: all shared WRAM to the ARM9
  n.fetch_paths_off()
  n.exmemcnt = 0x2000                # bit 13 reads set (GBATEK); ARM9 owns the slots
  n.cart.owner_arm7 = false
  n.exmem7_lo = 0
  n.postflg9 = 0
  n.postflg7 = 0
  n.biosprot = 0                     # GBATEK "BIOSPROT": zero on power-up
  n.gpu.write_powcnt1(0)             # Assumed: everything off
  n.powcnt2 = 1                      # GBATEK "POWCNT2": speakers on, wifi off
  n.cart.power_on()
  n.cp15.reset()
  n.arm9.vector_base = n.cp15.vector_base()
  n.arm9.set_cpsr(uint32(mSVC) or FLAG_I or FLAG_F)
  n.arm9.next_pc = n.arm9.vector_base
  n.arm7.set_cpsr(uint32(mSVC) or FLAG_I or FLAG_F)
  n.arm7.vector_base = 0
  n.arm7.next_pc = 0
