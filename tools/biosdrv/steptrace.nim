# Step trace of a biosdrv probe ROM: every instruction executed inside the
# probe's bracketed calls (marker 0xF0 to 0xF1, bd_callfn), one line each
# with its address, its cycles and the bus accesses it made (with their
# cycle into the step), and the DMA bursts that ran in it. Run once on the
# HLE BIOS and once on a BIOS image, the two traces show where a routine's
# time and accesses differ. The output stays local: it names BIOS
# addresses, and nothing of it is to be committed.
#
# Build: nim c -d:release -d:test_harness -d:biosdrvtrace --path:src \
#          -o:steptrace tools/biosdrv/steptrace.nim
# Usage: steptrace <rom> <out.txt> <frames> [bios.bin | hle] [first_call] [ncalls]
#   (BD_ALLSTEPS=1: log the caller's steps too, not only the BIOS's;
#   BD_SWIWIN=1: the calls are the SWIs from code outside the BIOS, each
#   from the swi to its return, for a game that writes no markers;
#   BD_IRQREGS=1: at each interrupt taken in a call, r0-r12 and the System
#   sp and lr it found)
import std/[os, strutils, streams]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let rom_path = paramStr(1)
  let outp = paramStr(2)
  let frames = parseInt(paramStr(3))
  let bios = if paramCount() >= 4 and paramStr(4) != "hle": paramStr(4) else: ""
  let first_call = if paramCount() >= 5: parseInt(paramStr(5)) else: 0
  let ncalls = if paramCount() >= 6: parseInt(paramStr(6)) else: 1_000_000
  let allsteps = getEnv("BD_ALLSTEPS") == "1"
  let swiwin = getEnv("BD_SWIWIN") == "1"
  let irqregs = getEnv("BD_IRQREGS") == "1"
  let watchreg = if getEnv("BD_WATCHREG").len > 0: parseInt(getEnv("BD_WATCHREG")) else: -1
  var swi_ret = 0'u32
  let emu = new_gba(bios, rom_path, run_bios = false, use_hle = bios == "")
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = false
  emu.cpu.attempt_waitloop_detection = false
  for i in 0 ..< emu.storage.memory.len: emu.storage.memory[i] = 0xFF
  emu.storage.save_path = ""
  let f = newFileStream(outp, fmWrite)
  var inwin = false
  var call = -1
  var acc = ""
  var step_t0 = 0'i64
  proc now(): int64 = emu.rebased + int64(emu.scheduler.cycles) + int64(emu.bus.cycles)
  proc logging(): bool = inwin and call >= first_call and call < first_call + ncalls
  if swiwin:
    bdSwiHook = proc(n: uint32) =
      let th = emu.cpu.cpsr.thumb
      let pc = emu.cpu.r[15] - (if th: 4'u32 else: 8'u32)
      if pc >= 0x4000'u32 and not inwin:
        inc call
        inwin = true
        swi_ret = pc + (if th: 2'u32 else: 4'u32)
        if logging(): f.writeLine("CALL " & $call & " t=" & $now() & " swi " & toHex(n, 2) &
                                  " r0=" & toHex(emu.cpu.r[0], 8) & " r1=" & toHex(emu.cpu.r[1], 8) &
                                  " r2=" & toHex(emu.cpu.r[2], 8) & " r3=" & toHex(emu.cpu.r[3], 8))
  bdIoHook = proc(address: uint32; value: uint8) =
    let a = address and 0xFFFFFF'u32
    if swiwin and a == 0xFF0'u32: discard
    elif a == 0xFF0'u32:
      if value == 0xF0:
        inc call
        inwin = true
        if logging(): f.writeLine("CALL " & $call & " t=" & $now())
      elif value == 0xF1:
        if logging(): f.writeLine("END " & $call & " t=" & $now())
        inwin = false
    elif logging() and not emu.bus.dma_active:
      acc.add(" IO" & toHex(a, 3) & "=" & toHex(value, 2) & "@" & $(now() - step_t0))
  bdReadHook = proc(address: uint32; width: int) =
    if logging() and (address shr 24) != 0:
      acc.add((if emu.bus.dma_active: " dR" else: " R") & $width & ":" &
              toHex(address, 8) & "@" & $(now() - step_t0))
  bdMemHook = proc(address: uint32; width: int; value: uint32) =
    if logging():
      acc.add((if emu.bus.dma_active: " dW" else: " W") & $width & ":" &
              toHex(address, 8) & "=" & toHex(value, width * 2) & "@" & $(now() - step_t0))
  var frame = 0
  while frame < frames:
    let pc = emu.cpu.r[15] - (if emu.cpu.cpsr.thumb: 4'u32 else: 8'u32)
    let th = emu.cpu.cpsr.thumb
    step_t0 = now()
    acc = ""
    let was = logging()
    let mode0 = emu.cpu.cpsr.mode
    let w0 = if watchreg >= 0: emu.cpu.r[watchreg] else: 0'u32
    emu.cpu.tick()
    if was and watchreg >= 0 and emu.cpu.r[watchreg] != w0:
      f.writeLine("REG r" & $watchreg & " " & toHex(w0, 8) & " -> " &
                  toHex(emu.cpu.r[watchreg], 8) & " at " & toHex(pc, 8) &
                  " mode " & toHex(uint32(emu.cpu.cpsr.mode), 2))
    if was and irqregs and emu.cpu.cpsr.mode != mode0 and
       cast[CpuMode](emu.cpu.cpsr.mode) == modeIRQ:
      # an interrupt taken in this step: the registers it found
      var s = "IRQREGS"
      for k in 0 .. 12: s.add(" " & toHex(emu.cpu.r[k], 8))
      s.add(" " & toHex(emu.cpu.reg_banks[0][5], 8) & " " & toHex(emu.cpu.reg_banks[0][6], 8))
      f.writeLine(s)
    let t1 = now()
    if was and (allsteps or pc < 0x4000'u32 or acc.len > 0):
      f.writeLine(toHex(pc, 8) & (if th: " T " else: " A ") & $(t1 - step_t0) &
                  " t=" & $step_t0 & acc)
    if swiwin and inwin and emu.cpu.r[15] - (if emu.cpu.cpsr.thumb: 4'u32 else: 8'u32) == swi_ret:
      if was: f.writeLine("END " & $call & " t=" & $now())
      inwin = false
    if emu.ppu.frame != 0:
      emu.end_frame()
      inc frame
      emu.frame_start_cycles = emu.scheduler.cycles
  f.close()

main()
