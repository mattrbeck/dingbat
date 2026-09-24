# BIOS sound-driver probe harness: run a ROM headless on the HLE BIOS or on
# a real BIOS image and record what the BIOS-resident MP2K driver does to the
# machine, so the two can be diffed (tools/biosdrv/). The oracle is the real
# BIOS executing inside dingbat; nothing here reads BIOS code.
#
# Build: nim c -d:release -d:test_harness -d:biosdrvtrace --path:src \
#          -o:biosdrv_probe tests/biosdrv_probe.nim
# Usage: biosdrv_probe <rom> <out_prefix> <frames> [bios.bin | hle]
#
# Outputs (<out_prefix>.*):
#   io.txt     every I/O write outside the sound FIFOs to 0x060-0x0DF,
#              0x100-0x10F and 0x200-0x20B: frame, absolute cycle, PC, DMA
#              flag, address, byte
#   fifoA.bin / fifoB.bin  every byte that reached FIFO A / B, in order
#   fifo.txt   one line per FIFO word burst: frame, cycle, channel, 4 bytes
#   marks.bin  at every byte write to 0x04000FF0 (a probe ROM's marker):
#              u32 marker, u32 frame, u64 cycle, then the snapshot regions
#              (BD_SNAP="addr:len,addr:len", hex) back to back
#   frames.txt one framebuffer hash per frame
#   iwram.bin / ewram.bin  work RAM after the last frame
import std/[os, strutils, streams, hashes]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  if paramCount() < 3:
    quit "usage: biosdrv_probe <rom> <out_prefix> <frames> [bios.bin|hle]"
  let rom_path = paramStr(1)
  let prefix = paramStr(2)
  let frames = parseInt(paramStr(3))
  let bios = if paramCount() >= 4 and paramStr(4) != "hle": paramStr(4) else: ""
  let emu = new_gba(bios, rom_path, run_bios = false, use_hle = bios == "")
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = false
  var regions: seq[(uint32, int)]
  for part in getEnv("BD_SNAP").split(','):
    if part.len == 0: continue
    let kv = part.split(':')
    regions.add((uint32(parseHexInt(kv[0])), parseHexInt(kv[1])))
  let io = newFileStream(prefix & ".io.txt", fmWrite)
  let fa = newFileStream(prefix & ".fifoA.bin", fmWrite)
  let fb = newFileStream(prefix & ".fifoB.bin", fmWrite)
  let ft = newFileStream(prefix & ".fifo.txt", fmWrite)
  let mk = newFileStream(prefix & ".marks.bin", fmWrite)
  var frame = 0
  var word: array[4, uint8]
  var abs_base = 0'i64   # absolute cycles at the current frame's start
  var s0 = 0'i64         # scheduler.cycles at the current frame's start
  proc now(): int64 =
    abs_base + (int64(emu.scheduler.cycles) - s0) + int64(emu.bus.cycles)
  bdIoHook = proc(address: uint32; value: uint8) =
    let a = address and 0xFFFFFF'u32
    if a >= 0xA0'u32 and a <= 0xA7'u32:
      let ch = int((a - 0xA0) shr 2)
      if ch == 0: fa.write(value) else: fb.write(value)
      word[int(a and 3)] = value
      if (a and 3) == 3:
        ft.writeLine($frame & " " & $now() & " " & $ch & " " &
                      toHex(word[0], 2) & toHex(word[1], 2) & toHex(word[2], 2) &
                      toHex(word[3], 2))
    elif (a >= 0x60'u32 and a <= 0xDF'u32) or (a >= 0x100'u32 and a <= 0x10F'u32) or
         (a >= 0x200'u32 and a <= 0x20B'u32):
      io.writeLine($frame & " " & $now() & " pc=" & toHex(emu.cpu.r[15], 8) &
                   (if emu.bus.dma_active: " D " else: " - ") &
                   toHex(a, 3) & "=" & toHex(value, 2))
    elif a == 0xFF0'u32:
      mk.write(uint32(value)); mk.write(uint32(frame)); mk.write(now())
      for (ad, ln) in regions:
        for i in 0 ..< ln:
          mk.write(emu.bus.read_byte_internal(ad + uint32(i)))
  # BD_MEMTRACE=1: every store the BIOS makes (PC below 0x4000), DMA excluded
  let mt = if getEnv("BD_MEMTRACE") == "1": newFileStream(prefix & ".mem.txt", fmWrite) else: nil
  if mt != nil:
    bdMemHook = proc(address: uint32; width: int; value: uint32) =
      if emu.cpu.r[15] < 0x4000'u32 and not emu.bus.dma_active and
         (address shr 24) != 4:
        mt.writeLine($frame & " " & $now() & " pc=" & toHex(emu.cpu.r[15], 4) & " " &
                     toHex(address, 8) & ":" & $width & "=" & toHex(value, width * 2))
  # BD_IOREAD=1: every I/O read the BIOS makes
  let ir = if getEnv("BD_IOREAD") == "1": newFileStream(prefix & ".ioread.txt", fmWrite) else: nil
  if ir != nil:
    bdIoReadHook = proc(address: uint32) =
      if emu.cpu.r[15] < 0x4000'u32 and not emu.bus.dma_active:
        ir.writeLine($frame & " " & $now() & " pc=" & toHex(emu.cpu.r[15], 4) & " " &
                     toHex(address, 8) & " vc=" & $emu.ppu.vcount)
  # BD_MEMREAD=1: every data read the BIOS makes outside I/O
  let mr = if getEnv("BD_MEMREAD") == "1": newFileStream(prefix & ".memread.txt", fmWrite) else: nil
  if mr != nil:
    bdReadHook = proc(address: uint32; width: int) =
      if emu.cpu.r[15] < 0x4000'u32 and not emu.bus.dma_active and (address shr 24) != 4:
        mr.writeLine($frame & " " & $now() & " pc=" & toHex(emu.cpu.r[15], 4) & " " &
                     toHex(address, 8) & ":" & $width)
  # BD_SWILOG=1: every SWI with its caller PC and r0-r3 (driver SWIs and the
  # BIOS-region traps only unless BD_SWILOG=all)
  let sl = if getEnv("BD_SWILOG").len > 0: newFileStream(prefix & ".swi.txt", fmWrite) else: nil
  let slall = getEnv("BD_SWILOG") == "all"
  if sl != nil:
    bdSwiHook = proc(n: uint32) =
      if slall or (n >= 0x19'u32 and n <= 0x2A'u32):
        let pc = emu.cpu.r[15] - (if emu.cpu.cpsr.thumb: 4'u32 else: 8'u32)
        sl.writeLine($frame & " " & $now() & " swi " & toHex(n, 2) & " pc=" & toHex(pc, 8) &
                     " r0=" & toHex(emu.cpu.r[0], 8) & " r1=" & toHex(emu.cpu.r[1], 8) &
                     " r2=" & toHex(emu.cpu.r[2], 8) & " r3=" & toHex(emu.cpu.r[3], 8))
  let fr = newFileStream(prefix & ".frames.txt", fmWrite)
  for f in 0 ..< frames:
    frame = f
    s0 = int64(emu.scheduler.cycles)
    emu.step_frame()
    # end_frame rebased the scheduler to cycles & 1023: rebuild the
    # pre-rebase count as the one nearest a frame's length on from s0
    let post = int64(emu.scheduler.cycles)
    var best = post
    while best - s0 < 280896 - 512: best += 1024
    abs_base += best - s0
    fr.writeLine($f & " " & toHex(cast[uint64](hash(emu.ppu.framebuffer)), 16))
  bdIoHook = nil
  bdMemHook = nil
  bdIoReadHook = nil
  bdSwiHook = nil
  if sl != nil: sl.close()
  bdReadHook = nil
  if mr != nil: mr.close()
  if ir != nil: ir.close()
  for s in [io, fa, fb, ft, mk, fr]: s.close()
  if mt != nil: mt.close()
  var iw = newSeq[uint8](0x8000)
  for i in 0 ..< iw.len: iw[i] = emu.bus.read_byte_internal(0x03000000'u32 + uint32(i))
  writeFile(prefix & ".iwram.bin", cast[string](iw))
  var ew = newSeq[uint8](0x40000)
  for i in 0 ..< ew.len: ew[i] = emu.bus.read_byte_internal(0x02000000'u32 + uint32(i))
  writeFile(prefix & ".ewram.bin", cast[string](ew))

main()
