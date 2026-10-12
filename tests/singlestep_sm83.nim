## SingleStepTests/sm83 against dingbat's SM83 (tests/singlestep_test.nim
## drives it). Each vector is one instruction from a register and RAM state,
## with the final state and the bus as it stood on each M-cycle: `r-m` a
## read, `-wm` a write, `---` no memory request.
##
## The CPU runs in a real GB built from a blank ROM-only cart, so it is
## dingbat's own `tick` (fetch, execute, the instruction's padding M-cycles,
## the interrupt check) that runs. Only the bus is replaced: built with
## -d:cpu_testbus, mem_read/mem_write still tick their M-cycle and then hand
## the access to the flat 64 KB array here (gb.nim, gb_testbus_read). The
## interrupt controller is the real one with IE = 0, so nothing is
## dispatched; the vectors do not test dispatch.
##
## Scored per case:
## - state: A F B C D E H L SP PC, IME, and a pending EI (the vectors' `ei`
##   key; dingbat books EI's delayed IME as an etIME event), and every RAM
##   byte the vector lists.
## - bus: the M-cycle sequence. Each M-cycle is a read, a write or neither;
##   reads and writes compare address and data. A `---` cycle's address is
##   not compared: dingbat does not drive an address on internal M-cycles
##   (the OAM bug's IDU address is modelled apart, oam_bug_if).

import std/[json, os, strutils, strformat]
import dingbat/gb/gb
import dingbat/common/[scheduler, test_output]

type
  Access = object
    m: int          # M-cycle index within the instruction
    write: bool
    address: int
    value: uint8

  CaseResult* = object
    state_ok*, bus_ok*: bool
    why*: string     # what differed, first difference per check

var mem: array[0x10000, uint8]
var accesses: seq[Access]
var gbref: GB
var t0: CycleCount

proc mcycle_now(): int =
  # The hooks run after their M-cycle has ticked.
  int((gbref.scheduler.cycles - t0) div 4) - 1

proc tb_read(address: int): uint8 {.nimcall.} =
  result = mem[address and 0xFFFF]
  accesses.add Access(m: mcycle_now(), write: false, address: address and 0xFFFF,
                      value: result)

proc tb_write(address: int; value: uint8) {.nimcall.} =
  mem[address and 0xFFFF] = value
  accesses.add Access(m: mcycle_now(), write: true, address: address and 0xFFFF,
                      value: value)

proc blank_rom(dir: string): string =
  ## A 32 KB ROM-only DMG cart: the GB the CPU runs in needs a cartridge.
  result = dir / "singlestep-blank.gb"
  if not fileExists(result):
    var rom = newString(0x8000)
    writeFile(result, rom)

proc new_test_gb*(scratch: string): GB =
  gb_testbus_read = tb_read
  gb_testbus_write = tb_write
  result = new_gb("", blank_rom(scratch), headless = true, run_bios = false)
  result.test_output = new_test_output()
  result.post_init()
  gbref = result

proc reg(j: JsonNode; k: string): int = j[k].getInt

proc run_case*(gb: GB; t: JsonNode): CaseResult =
  let ini = t["initial"]
  let fin = t["final"]
  let cpu = gb.cpu
  for cell in ini["ram"]:
    mem[cell[0].getInt] = uint8(cell[1].getInt)
  # A fresh CPU: whatever the last case left (HALT, STOP, a lockup, a
  # pending EI, an idle-loop edge) must not leak into this one.
  cpu.halted = false; cpu.locked = false; cpu.stopped = false
  cpu.halt_bug = false; cpu.cached_hl = -1; cpu.wl_edge = false
  gb.scheduler.clear(etIME)
  cpu.af = uint16(ini.reg("a") shl 8 or ini.reg("f"))
  cpu.bc = uint16(ini.reg("b") shl 8 or ini.reg("c"))
  cpu.de = uint16(ini.reg("d") shl 8 or ini.reg("e"))
  cpu.hl = uint16(ini.reg("h") shl 8 or ini.reg("l"))
  cpu.sp = uint16(ini.reg("sp"))
  cpu.pc = uint16(ini.reg("pc"))
  cpu.ime = ini.reg("ime") != 0
  accesses.setLen(0)
  t0 = gb.scheduler.cycles
  cpu.tick(gb)
  let mcycles = int((gb.scheduler.cycles - t0) div 4)

  # ---- state ----
  var diffs: seq[string]
  template chk(label: string; got, want: int) =
    if got != want: diffs.add label & "=" & toHex(got, 2) & "/" & toHex(want, 2)
  chk("a", int(cpu.a), fin.reg("a"))
  chk("f", int(cpu.af and 0xFF), fin.reg("f"))
  chk("b", int(cpu.bc shr 8), fin.reg("b"))
  chk("c", int(cpu.bc and 0xFF), fin.reg("c"))
  chk("d", int(cpu.de shr 8), fin.reg("d"))
  chk("e", int(cpu.de and 0xFF), fin.reg("e"))
  chk("h", int(cpu.hl shr 8), fin.reg("h"))
  chk("l", int(cpu.hl and 0xFF), fin.reg("l"))
  chk("sp", int(cpu.sp), fin.reg("sp"))
  chk("pc", int(cpu.pc), fin.reg("pc"))
  chk("ime", int(cpu.ime), fin.reg("ime"))
  let ei_want = if fin.hasKey("ei"): fin.reg("ei") else: 0
  chk("ei", int(gb.scheduler.has_event(etIME)), ei_want)
  for cell in fin["ram"]:
    chk(&"[{cell[0].getInt:04X}]", int(mem[cell[0].getInt]), cell[1].getInt)
  result.state_ok = diffs.len == 0
  if diffs.len > 0: result.why = "state " & diffs.join(" ")

  # ---- bus ----
  var mine = newSeq[(string, int, int)](mcycles)   # kind, address, data
  for i in 0 ..< mcycles: mine[i] = ("---", -1, -1)
  var bus_why = ""
  for a in accesses:
    if a.m < 0 or a.m >= mcycles:
      bus_why = &"access outside the instruction at M{a.m}"
    else:
      mine[a.m] = ((if a.write: "-wm" else: "r-m"), a.address, int(a.value))
  let want = t["cycles"]
  if bus_why.len == 0 and want.len != mcycles:
    bus_why = &"M-cycles {mcycles}/{want.len}"
  if bus_why.len == 0:
    for i in 0 ..< mcycles:
      let w = want[i]
      let kind = w[2].getStr
      let (k, ad, d) = mine[i]
      if kind != k:
        bus_why = &"M{i} {k}/{kind}"
        break
      if kind != "---" and (ad != w[0].getInt or d != w[1].getInt):
        bus_why = &"M{i} {k} {ad:04X}={d:02X}/{w[0].getInt:04X}={w[1].getInt:02X}"
        break
  result.bus_ok = bus_why.len == 0
  if bus_why.len > 0:
    if result.why.len > 0: result.why.add "; "
    result.why.add "bus " & bus_why
  for cell in fin["ram"]: mem[cell[0].getInt] = 0
  for cell in ini["ram"]: mem[cell[0].getInt] = 0
  for a in accesses: mem[a.address] = 0

proc known_divergence*(stem: string; r: CaseResult): string =
  ## Failures that are a documented choice, not a bug (tests/README.md,
  ## "SingleStepTests").
  case stem
  of "10":
    # Pan Docs, "Reducing Power Consumption", STOP: with no interrupt
    # pending the byte after $10 is consumed (2 bytes) and the CPU enters
    # STOP mode. The vectors take it as one byte and three M-cycles.
    "documented: STOP is two bytes with no interrupt pending"
  of "76":
    # The HALT's own M-cycle ends the instruction: the halted M-cycles are
    # the next ticks' (cpu.nim, tick's halted branch). The vectors count two
    # of them into the instruction; registers and PC agree.
    if r.state_ok: "convention: HALT's halted M-cycles are not the instruction's"
    else: ""
  else: ""
