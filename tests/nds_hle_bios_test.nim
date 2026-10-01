## DS HLE BIOS (src/dingbat/nds/hle_bios.nim + hle_bios.s) against the real
## BIOS, SWI by SWI, inside the emulator.
##
## Each case puts a two-instruction program in main RAM (`swi N` then
## `b .`), sets the registers and the memory the SWI reads, runs the machine
## until the CPU reaches the `b .`, and compares registers and the memory
## the SWI writes. With Nintendo's dumps present (--bios DIR,
## $DINGBAT_NDS_BIOS, or the default path below) every case runs on both
## BIOSes and must agree; without them the HLE side is checked against the
## expected results this file computes itself (the compressed streams are
## generated here from known data).
##
##   nim c -r -d:release -d:test_harness --path:src tests/nds_hle_bios_test.nim [--bios DIR] [-v]

import std/[os, strutils, random, sequtils, math]
import dingbat/nds/nds

var failures = 0
var passes = 0
var verbose = false
let trace_name = getEnv("HLE_TRACE")

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    inc passes
    if verbose: echo "  [PASS] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

iterator vals[T](a: openArray[T]): T =
  ## Loop values by copy, so closures in the loop body can capture them.
  for i in 0 ..< a.len: yield a[i]

proc h(v: uint32): string = "0x" & toHex(v, 8)

# ---------------------------------------------------------------------------
# Machine

const
  CODE9 = 0x02100000'u32     ## the swi + b . for the ARM9
  CODE7 = 0x02180000'u32     ## ... and for the ARM7
  SRC = 0x02200000'u32       ## SWI input data
  DST = 0x02280000'u32       ## SWI output
  INFO = 0x02300000'u32      ## BitUnPack info, callback table, temp buffer
  CB = 0x02310000'u32        ## callback code
  HANDLER = 0x02320000'u32   ## user IRQ handler
  DTCM_BASE = 0x00800000'u32 ## where direct boot puts the ARM9 DTCM

proc mini_rom(): seq[uint8] =
  ## A header plus `b .` for each CPU: ARM9 at 0x02000000, ARM7 at
  ## 0x02380000. The cases take a CPU over from there.
  result = newSeq[uint8](0x1000)
  proc w32(r: var seq[uint8]; o: int; v: uint32) =
    for i in 0..3: r[o + i] = uint8((v shr (8 * i)) and 0xFF)
  for i, c in "HLEBIOSTEST": result[i] = uint8(c)
  result.w32(0x20, 0x200); result.w32(0x24, 0x02000000); result.w32(0x28, 0x02000000)
  result.w32(0x2C, 4)
  result.w32(0x30, 0x204); result.w32(0x34, 0x02380000); result.w32(0x38, 0x02380000)
  result.w32(0x3C, 4)
  result.w32(0x200, 0xEAFFFFFE'u32)
  result.w32(0x204, 0xEAFFFFFE'u32)

var bios9, bios7: seq[uint8]
let rom = mini_rom()

proc machine(hle: bool): NDS =
  new_nds(rom, bios9, bios7, @[], force_hle = hle)

proc w8(n: NDS; a: uint32; v: uint8) = write8(Arm9Bus(nds: n), a, v)
proc w16(n: NDS; a: uint32; v: uint16) = write16(Arm9Bus(nds: n), a, v)
proc w32(n: NDS; a: uint32; v: uint32) = write32(Arm9Bus(nds: n), a, v)
proc r8(n: NDS; a: uint32): uint8 = uint8(read8(Arm9Bus(nds: n), a))
proc r32(n: NDS; a: uint32): uint32 = read32(Arm9Bus(nds: n), a)
proc w32_7(n: NDS; a: uint32; v: uint32) = write32(Arm7Bus(nds: n), a, v)
proc r32_7(n: NDS; a: uint32): uint32 = read32(Arm7Bus(nds: n), a)

proc put(n: NDS; a: uint32; data: openArray[uint8]) =
  for i, b in data: n.w8(a + uint32(i), b)

proc get(n: NDS; a: uint32; len: int): seq[uint8] =
  for i in 0 ..< len: result.add n.r8(a + uint32(i))

# ---------------------------------------------------------------------------
# Running one SWI

type
  Outcome = object
    returned: bool
    r: array[16, uint32]
    cpsr: uint32
    mem: seq[seq[uint8]]
    words: seq[uint32]       ## extra words a case reads back (flags, logs)

  Case = object
    name: string
    arm9: bool
    num: uint32
    thumb: bool
    regs: array[13, uint32]
    irqs_on: bool            ## CPSR I clear while the SWI runs
    limit: int64             ## master cycles before giving up
    setup: proc (n: NDS)
    windows: seq[(uint32, int)]
    readback: proc (n: NDS): seq[uint32]
    ignore: set[0..16]       ## registers (16 = cpsr) not compared with the real BIOS
    expect_mem: seq[seq[uint8]]       ## HLE-only check, per window (empty = skip)
    expect_regs: seq[(int, uint32)]   ## HLE-only check
    expect_return: bool

proc default_regs(): array[13, uint32] =
  for i in 0..12: result[i] = 0xA0A0A000'u32 + uint32(i)

proc run_cpu[B](n: NDS; cpu: ArmCpu[B]; c: Case; code: uint32): Outcome =
  let done = if c.thumb: code + 2 else: code + 4
  if c.thumb:
    n.w16(code, uint16(0xDF00'u32 or c.num))
    n.w16(code + 2, 0xE7FE'u16)
  else:
    n.w32(code, 0xEF000000'u32 or (c.num shl 16))
    n.w32(code + 4, 0xEAFFFFFE'u32)
  if c.arm9:
    cpu.set_mode_sp(mSVC, DTCM_BASE + 0x3F00)
    cpu.set_mode_sp(mIRQ, DTCM_BASE + 0x3E00)
    cpu.set_mode_sp(mSYS, DTCM_BASE + 0x3D00)
  else:
    cpu.set_mode_sp(mSVC, 0x0380FF00'u32)
    cpu.set_mode_sp(mIRQ, 0x0380FE00'u32)
    cpu.set_mode_sp(mSYS, 0x0380F000'u32)
  cpu.set_cpsr(uint32(mSYS) or (if c.irqs_on: 0'u32 else: FLAG_I) or FLAG_F)
  if c.thumb: cpu.cpsr = cpu.cpsr or FLAG_T
  for i in 0..12: cpu.r[i] = c.regs[i]
  cpu.r[14] = 0x0E0E0E0E'u32
  cpu.next_pc = code
  cpu.halted = false
  let limit = n.sched.now + (if c.limit > 0: c.limit else: 4_000_000'i64)
  if trace_name.len > 0 and c.name.startsWith(trace_name):
    # HLE_TRACE=<case name prefix>: single-step the CPU under test, print
    for _ in 0 ..< 400:
      echo "  ", h(cpu.next_pc), "  ", cpu.reg_dump()
      if cpu.next_pc == done: break
      cpu.step()
  while n.sched.now < limit:
    n.run_until(n.sched.now + 64)
    if cpu.next_pc == done and not cpu.halted:
      result.returned = true
      break
  for i in 0..14: result.r[i] = cpu.r[i]
  result.r[15] = cpu.next_pc
  result.cpsr = cpu.cpsr

proc run_case(c: Case; hle: bool): Outcome =
  let n = machine(hle)
  if c.setup != nil: c.setup(n)
  result = if c.arm9: run_cpu(n, n.arm9, c, CODE9) else: run_cpu(n, n.arm7, c, CODE7)
  for (a, len) in c.windows: result.mem.add n.get(a, len)
  if c.readback != nil: result.words = c.readback(n)

proc hexdiff(a, b: seq[uint8]): string =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      return "first difference at +0x" & toHex(i, 4) & ": " & toHex(a[i], 2) &
             " vs " & toHex(b[i], 2)
  "lengths " & $a.len & " vs " & $b.len

var have_real = false

proc run(c: Case) =
  let tag = (if c.arm9: "ARM9 " else: "ARM7 ") & c.name
  let hle = run_case(c, true)
  check(hle.returned == c.expect_return, tag & ": HLE " &
        (if c.expect_return: "returns" else: "keeps waiting"),
        "pc=" & h(hle.r[15]))
  for wi, exp in c.expect_mem:
    if exp.len > 0:
      check(hle.mem[wi] == exp, tag & ": HLE output window " & $wi & " as expected",
            hexdiff(hle.mem[wi], exp))
  for (ri, v) in c.expect_regs:
    check(hle.r[ri] == v, tag & ": HLE r" & $ri & " = " & h(v), "got " & h(hle.r[ri]))
  if not have_real: return
  let real = run_case(c, false)
  check(real.returned == hle.returned, tag & ": returns like the real BIOS",
        "real " & $real.returned & " hle " & $hle.returned)
  if not real.returned:
    return
  for i in 0..15:
    if i notin c.ignore:
      check(real.r[i] == hle.r[i], tag & ": r" & $i & " matches the real BIOS",
            "real " & h(real.r[i]) & " hle " & h(hle.r[i]))
  if 16 notin c.ignore:
    check(real.cpsr == hle.cpsr, tag & ": cpsr matches the real BIOS",
          "real " & h(real.cpsr) & " hle " & h(hle.cpsr))
  for wi in 0 ..< real.mem.len:
    check(real.mem[wi] == hle.mem[wi], tag & ": memory window " & $wi &
          " matches the real BIOS", hexdiff(real.mem[wi], hle.mem[wi]))
  for wi in 0 ..< real.words.len:
    check(real.words[wi] == hle.words[wi], tag & ": readback word " & $wi &
          " matches the real BIOS", "real " & h(real.words[wi]) & " hle " & h(hle.words[wi]))

proc base_case(name: string; arm9: bool; num: uint32): Case =
  Case(name: name, arm9: arm9, num: num, regs: default_regs(), expect_return: true)

# ---------------------------------------------------------------------------
# Stream generators (the expected output is known by construction)

var rng = initRand(0x5EED)

proc random_bytes(n: int; alphabet = 256): seq[uint8] =
  for _ in 0 ..< n: result.add uint8(rng.rand(alphabet - 1))

proc header(kind, size: int): seq[uint8] =
  let v = uint32(kind) or (uint32(size) shl 8)
  @[uint8(v and 0xFF), uint8((v shr 8) and 0xFF), uint8((v shr 16) and 0xFF),
    uint8(v shr 24)]

proc window(d: seq[uint8]; len: int): seq[uint8] =
  ## The first `len` bytes of the expected output, zero-padded.
  result = d[0 ..< min(len, d.len)]
  while result.len < len: result.add 0

proc even(d: seq[uint8]): seq[uint8] =
  ## What a 16-bit-write decompressor leaves: an odd last byte stays in its
  ## half-built halfword and is never stored.
  d[0 ..< (d.len and not 1)]

proc pad4(s: var seq[uint8]) =
  while (s.len and 3) != 0: s.add 0

proc lz77_stream(size: int; min_disp = 1): (seq[uint8], seq[uint8]) =
  ## A random valid LZ77 stream: literals and back-references
  ## (distance >= min_disp) over what has been produced so far. The
  ## expected output runs to the end of the last token, past `size`, as
  ## the console's decompressors write it.
  var data: seq[uint8]
  var s = header(0x10, size)
  while data.len < size:
    let flag_at = s.len
    s.add 0
    var flags = 0'u8
    for blk in 0 ..< 8:
      if data.len >= size: break
      let disp = if data.len > 0: 1 + rng.rand(min(data.len, 4096) - 1) else: 0
      if disp >= min_disp and rng.rand(1) == 1:
        let length = 3 + rng.rand(15)
        flags = flags or (0x80'u8 shr blk)
        s.add uint8(((length - 3) shl 4) or ((disp - 1) shr 8))
        s.add uint8((disp - 1) and 0xFF)
        for _ in 0 ..< length:
          data.add data[data.len - disp]
      else:
        let b = uint8(rng.rand(255))
        s.add b
        data.add b
    s[flag_at] = flags
  s.pad4()
  (s, data)

proc rl_stream(size: int): (seq[uint8], seq[uint8]) =
  var data: seq[uint8]
  var s = header(0x30, size)
  while data.len < size:
    if rng.rand(1) == 1:
      let n = 3 + rng.rand(127)
      let b = uint8(rng.rand(255))
      s.add uint8(0x80 or (n - 3))
      s.add b
      for _ in 0 ..< n: data.add b
    else:
      let n = 1 + rng.rand(127)
      s.add uint8(n - 1)
      for _ in 0 ..< n:
        let b = uint8(rng.rand(255))
        s.add b
        data.add b
  s.pad4()
  (s, data)

proc huff_stream(size: int; bits: int): (seq[uint8], seq[uint8]) =
  ## A complete binary tree in BFS order (node i at table offset i, the
  ## size byte being "node 0"), depth 4 for 4-bit data (16 leaves, one per
  ## nibble) or depth 5 for 8-bit (32 random symbols), then a random
  ## bitstream decoded here for the expected output.
  let depth = if bits == 4: 4 else: 5
  let leaves = 1 shl depth
  var syms: seq[uint8]
  if bits == 4:
    syms = toSeq(0'u8 .. 15'u8)
    rng.shuffle(syms)
  else:
    syms = random_bytes(leaves)
  var s = header(0x20 or bits, size)
  var table = newSeq[uint8](2 * leaves)
  table[0] = uint8(leaves - 1)               # (2 * leaves) / 2 - 1
  for i in 1 ..< leaves:
    var node = uint8(i - (i and not 1) div 2 - 1)
    if i >= leaves div 2: node = node or 0xC0  # both children are data
    table[i] = node
  for k in 0 ..< leaves: table[leaves + k] = syms[k]
  s.add table
  var data: seq[uint8]
  var outw = 0'u32
  var outbits = 0
  var produced = 0
  var bitstream: seq[uint32]
  var cur = 0'u32
  var nb = 0
  while produced < size:
    let leaf = rng.rand(leaves - 1)
    for d in countdown(depth - 1, 0):
      cur = (cur shl 1) or uint32((leaf shr d) and 1)
      inc nb
      if nb == 32:
        bitstream.add cur
        cur = 0
        nb = 0
    outw = outw or (uint32(syms[leaf]) shl outbits)
    outbits += bits
    if outbits == 32:
      for i in 0..3: data.add uint8((outw shr (8 * i)) and 0xFF)
      produced += 4
      outw = 0
      outbits = 0
  if nb > 0: bitstream.add cur shl (32 - nb)
  for w in bitstream:
    for i in 0..3: s.add uint8((w shr (8 * i)) and 0xFF)
  (s, data)

# ---------------------------------------------------------------------------
# Guest code the cases install

proc install_callbacks(n: NDS) =
  ## CB+0 open, +8 close (logs its r0 at +20, returns 0), +24 get8,
  ## +32 get16, +40 get32, +48 Thumb get8, +52 open failing with -1,
  ## +60 close failing with -1. Tables at INFO+0x100 (ARM) and +0x120
  ## (Thumb get8, and an always-null close).
  let code = [0xE5900000'u32, 0xE12FFF1E'u32,                    # open: ldr r0,[r0]
              0xE58F0004'u32, 0xE3A00000'u32, 0xE12FFF1E'u32, 0, # close
              0xE5D00000'u32, 0xE12FFF1E'u32,                    # get8
              0xE1D000B0'u32, 0xE12FFF1E'u32,                    # get16
              0xE5900000'u32, 0xE12FFF1E'u32,                    # get32
              0x47707800'u32,                                    # thumb get8
              0xE3E00000'u32, 0xE12FFF1E'u32,                    # open -> -1
              0xE3E00000'u32, 0xE12FFF1E'u32]                    # close -> -1
  for i, w in code: n.w32(CB + uint32(i * 4), w)
  n.w32(CB + 20, 0xDEADBEEF'u32)
  for i, w in [CB, CB + 8, CB + 24, CB + 32, CB + 40]:
    n.w32(INFO + 0x100 + uint32(i * 4), w)
  for i, w in [CB, 0'u32, CB + 49, CB + 32, CB + 40]:
    n.w32(INFO + 0x120 + uint32(i * 4), w)
  for i, w in [CB + 52, CB + 8, CB + 24, CB + 32, CB + 40]:
    n.w32(INFO + 0x140 + uint32(i * 4), w)
  for i, w in [CB, CB + 60, CB + 24, CB + 32, CB + 40]:
    n.w32(INFO + 0x160 + uint32(i * 4), w)

proc flags_addr(arm9: bool): uint32 =
  if arm9: DTCM_BASE + 0x3FF8 else: 0x0380FFF8'u32

proc install_irq_handler(n: NDS; arm9: bool) =
  ## Acknowledge IE & IF, OR them into the BIOS check word, count the call
  ## in the word below it.
  let code = [0xE3A0C301'u32, 0xE59C1210'u32, 0xE59C2214'u32, 0xE0011002'u32,
              0xE58C1214'u32, 0xE59F0018'u32, 0xE5902000'u32, 0xE1822001'u32,
              0xE5802000'u32, 0xE5102004'u32, 0xE2822001'u32, 0xE5002004'u32,
              0xE12FFF1E'u32, flags_addr(arm9)]
  let base = HANDLER + (if arm9: 0'u32 else: 0x100'u32)
  for i, w in code: n.w32(base + uint32(i * 4), w)
  if arm9:
    n.w32(DTCM_BASE + 0x3FFC, base)
    n.w32(DTCM_BASE + 0x3FF8, 0)
    n.w32(DTCM_BASE + 0x3FF4, 0)
  else:
    n.w32_7(0x0380FFFC'u32, base)
    n.w32_7(0x0380FFF8'u32, 0)
    n.w32_7(0x0380FFF4'u32, 0)

proc start_timer0(n: NDS; arm9: bool) =
  ## Timer 0 with its IRQ enabled, overflowing every 16 x 1024 system
  ## cycles: rarely enough that no second IRQ lands between the SWI's
  ## return and the end of the run, whichever BIOS ran it.
  if arm9:
    n.w32(0x04000210'u32, 1'u32 shl 3)
    n.w32(0x04000100'u32, 0x00C3FFF0'u32)
  else:
    n.w32_7(0x04000210'u32, 1'u32 shl 3)
    n.w32_7(0x04000100'u32, 0x00C3FFF0'u32)

proc irq_words(arm9: bool): proc (n: NDS): seq[uint32] =
  ## Check word, handler call count, IME, IF.
  result = proc (n: NDS): seq[uint32] =
    let f = flags_addr(arm9)
    if arm9: @[n.r32(f), n.r32(f - 4), n.r32(0x04000208'u32)]
    else: @[n.r32_7(f), n.r32_7(f - 4), n.r32_7(0x04000208'u32)]

# ---------------------------------------------------------------------------
# Cases

proc div_cases() =
  let pairs = [(1234'i32, 10'i32), (-1234'i32, 10'i32), (1234'i32, -10'i32),
               (-1234'i32, -10'i32), (0'i32, 7'i32), (7'i32, 7'i32), (1'i32, 3'i32),
               (low(int32), -1'i32), (low(int32), 1'i32), (high(int32), 2'i32),
               (100000'i32, 3'i32), (-5'i32, 2'i32), (0x12345678'i32, 0x1234'i32)]
  for arm9 in vals([true, false]):
    for (a, b) in pairs:
      var c = base_case("Div(" & $a & ", " & $b & ")", arm9, 0x09)
      c.regs[0] = cast[uint32](a)
      c.regs[1] = cast[uint32](b)
      let q = int64(a) div int64(b)
      c.expect_regs = @[(0, uint32(q and 0xFFFFFFFF)),
                        (1, uint32((int64(a) mod int64(b)) and 0xFFFFFFFF)),
                        (3, uint32(abs(q) and 0xFFFFFFFF))]
      run(c)

proc div_random_cases() =
  var r = initRand(0xD1D)
  for arm9 in vals([true, false]):
    for _ in 0 ..< 40:
      let a = cast[int32](uint32(r.next() and 0xFFFFFFFF'u64)) shr r.rand(31)
      var b = cast[int32](uint32(r.next() and 0xFFFFFFFF'u64)) shr r.rand(31)
      if b == 0: b = 3
      var c = base_case("Div(" & $a & ", " & $b & ")", arm9, 0x09)
      c.regs[0] = cast[uint32](a)
      c.regs[1] = cast[uint32](b)
      run(c)
      let x = uint32(r.next() and 0xFFFFFFFF'u64) shr r.rand(31)
      var d = base_case("Sqrt(" & h(x) & ")", arm9, 0x0D)
      d.regs[0] = x
      d.expect_regs = @[(0, uint32(floor(sqrt(float(x)))))]
      run(d)
    # A zero denominator: the console only comes back for |numerator| <= 1
    for a in vals([0'i32, 1, -1]):
      var c = base_case("Div(" & $a & ", 0)", arm9, 0x09)
      c.regs[0] = cast[uint32](a)
      c.regs[1] = 0
      c.limit = 200_000
      run(c)

proc sqrt_cases() =
  for arm9 in vals([true, false]):
    for x in vals([0'u32, 1, 2, 3, 4, 15, 16, 17, 0xFF, 0xFFFF, 0x10000, 0x12345678,
              0x40000000, 0x7FFFFFFF, 0xFFFFFFFF'u32, 0xFFFE0001'u32]):
      var c = base_case("Sqrt(" & h(x) & ")", arm9, 0x0D)
      c.regs[0] = x
      c.expect_regs = @[(0, uint32(floor(sqrt(float(x)))))]
      run(c)

proc copy_cases() =
  let data = random_bytes(0x400)
  for arm9 in vals([true, false]):
    for (name, ctrl, fast) in vals([("CpuSet copy32 x37", 37'u32 or (1'u32 shl 26), false),
                               ("CpuSet fill32 x21", 21'u32 or (5'u32 shl 24), false),
                               ("CpuSet copy16 x41", 41'u32, false),
                               ("CpuSet fill16 x13", 13'u32 or (1'u32 shl 24), false),
                               ("CpuSet count 0", 1'u32 shl 26, false),
                               ("CpuFastSet copy x45", 45'u32, true),
                               ("CpuFastSet fill x19", 19'u32 or (1'u32 shl 24), true),
                               ("CpuFastSet copy x8", 8'u32, true)]):
      var c = base_case(name, arm9, if fast: 0x0C else: 0x0B)
      if not fast: c.ignore = {3}   # CpuSet: r3 = a BIOS-internal address
      c.regs[0] = SRC
      c.regs[1] = DST
      c.regs[2] = ctrl
      c.setup = proc (n: NDS) = n.put(SRC, data)
      c.windows = @[(DST, 0x140)]
      var exp = newSeq[uint8](0x140)
      let count = int(ctrl and 0x1FFFFF)
      let unit = if fast or (ctrl and (1'u32 shl 26)) != 0: 4 else: 2
      let fill = (ctrl and (1'u32 shl 24)) != 0
      for i in 0 ..< count * unit:
        exp[i] = if fill: data[i mod unit] else: data[i]
      c.expect_mem = @[exp]
      run(c)
  # The ARM7 refuses sources in the BIOS; the ARM9 has nothing to refuse.
  var c = base_case("CpuSet from the BIOS area", false, 0x0B)
  c.ignore = {3}
  c.regs[0] = 0x1000
  c.regs[1] = DST
  c.regs[2] = 16'u32 or (1'u32 shl 26)
  c.windows = @[(DST, 0x40)]
  c.expect_mem = @[newSeq[uint8](0x40)]
  run(c)

proc crc_cases() =
  let data = random_bytes(0x100)
  for arm9 in vals([true, false]):
    for (init, len) in vals([(0xFFFF'u32, 0x100'u32), (0'u32, 2'u32), (0x1234'u32, 0x3E'u32),
                        (0xFFFF'u32, 0'u32)]):
      var c = base_case("GetCRC16(" & h(init) & ", len " & $len & ")", arm9, 0x0E)
      c.regs[0] = init
      c.regs[1] = SRC
      c.regs[2] = len
      c.setup = proc (n: NDS) = n.put(SRC, data)
      var crc = init
      for i in 0 ..< int(len):
        crc = crc xor data[i]
        for _ in 0..7: crc = if (crc and 1) != 0: (crc shr 1) xor 0xA001'u32 else: crc shr 1
      c.expect_regs = @[(0, crc)]
      run(c)

proc bitunpack_cases() =
  let data = random_bytes(16)
  for arm9 in vals([true, false]):
    for (sw, dw, offset) in vals([(1, 4, 0'u32), (1, 8, 0x80000001'u32), (2, 8, 3'u32),
                             (4, 8, 0x10'u32), (4, 16, 0x80000000'u32),
                             (8, 32, 0x12345'u32), (2, 4, 1'u32), (8, 8, 0'u32)]):
      var c = base_case("BitUnPack " & $sw & "->" & $dw & " " & h(offset), arm9, 0x10)
      c.regs[0] = SRC
      c.regs[1] = DST
      c.regs[2] = INFO
      let src_len = 8
      c.setup = proc (n: NDS) =
        n.put(SRC, data)
        n.w16(INFO, uint16(src_len))
        n.w8(INFO + 2, uint8(sw))
        n.w8(INFO + 3, uint8(dw))
        n.w32(INFO + 4, offset)
      c.windows = @[(DST, 0x100)]
      var exp = newSeq[uint8](0x100)
      var o = 0
      var acc = 0'u64
      var nbits = 0
      for i in 0 ..< src_len:
        var b = 0
        while b < 8:
          let v = (uint32(data[i]) shr b) and ((1'u32 shl sw) - 1)
          let e = if v != 0 or (offset and 0x80000000'u32) != 0: v + (offset and 0x7FFFFFFF) else: 0
          let m = if dw == 32: 0xFFFFFFFF'u32 else: (1'u32 shl dw) - 1
          acc = acc or (uint64(e and m) shl nbits)
          nbits += dw
          if nbits >= 32:
            for k in 0..3: exp[o + k] = uint8((acc shr (8 * k)) and 0xFF)
            o += 4
            acc = 0
            nbits = 0
          b += sw
      c.expect_mem = @[exp]
      run(c)

proc decompress_cases() =
  for arm9 in vals([true, false]):
    for size in vals([1, 37, 0x200, 0x1000]):
      block:
        let (s, d) = lz77_stream(size)
        var c = base_case("LZ77UnCompReadNormalWrite8bit " & $size, arm9, 0x11)
        c.ignore = {3}
        c.regs[0] = SRC
        c.regs[1] = DST
        c.setup = proc (n: NDS) = n.put(SRC, s)
        c.windows = @[(DST, size + 0x90)]
        c.expect_mem = @[window(d, size + 0x90)]
        run(c)
      block:
        let (s, d) = rl_stream(size)
        var c = base_case("RLUnCompReadNormalWrite8bit " & $size, arm9, 0x14)
        # BIOS-internal values: r3 (ARM9), r0 and r3 (ARM7)
        c.ignore = if arm9: {3} else: {0, 3}
        c.regs[0] = SRC
        c.regs[1] = DST
        c.setup = proc (n: NDS) = n.put(SRC, s)
        c.windows = @[(DST, size + 0x90)]
        c.expect_mem = @[window(d, size + 0x90)]
        run(c)
    if arm9:
      for size in vals([1, 2, 37, 0x100]):
        let d = random_bytes(size)
        var s8 = header(0x81, size)
        var prev = 0'u8
        for i, b in d:
          s8.add(if i == 0: b else: b - prev)
          prev = b
        s8.pad4()
        var c = base_case("Diff8bitUnFilterWrite8bit " & $size, arm9, 0x16)
        c.ignore = {3}
        c.regs[0] = SRC
        c.regs[1] = DST
        c.setup = proc (n: NDS) = n.put(SRC, s8)
        c.windows = @[(DST, size + 0x90)]
        c.expect_mem = @[window(d, size + 0x90)]
        run(c)
      for size in vals([2, 4, 38, 0x100]):
        let d = random_bytes(size)
        var s16 = header(0x82, size)
        var prev = 0'u16
        for i in countup(0, size - 2, 2):
          let v = uint16(d[i]) or (uint16(d[i + 1]) shl 8)
          let e = if i == 0: v else: v - prev
          s16.add uint8(e and 0xFF)
          s16.add uint8(e shr 8)
          prev = v
        s16.pad4()
        var c = base_case("Diff16bitUnFilter " & $size, arm9, 0x18)
        c.ignore = {3}
        c.regs[0] = SRC
        c.regs[1] = DST
        c.setup = proc (n: NDS) = n.put(SRC, s16)
        c.windows = @[(DST, size + 0x90)]
        c.expect_mem = @[window(d, size + 0x90)]
        run(c)

proc callback_cases() =
  for arm9 in vals([true, false]):
    for thumb_cb in vals([false, true]):
      let table = INFO + (if thumb_cb: 0x120'u32 else: 0x100'u32)
      let suffix = if thumb_cb: " (Thumb get8, no close)" else: ""
      for size in vals([2, 38, 0x200, 0x800]):
        block:
          let (s, d) = lz77_stream(size, min_disp = 2)
          var c = base_case("LZ77UnCompReadByCallbackWrite16bit " & $size & suffix, arm9, 0x12)
          c.regs[0] = SRC
          c.regs[1] = DST
          c.regs[2] = 0x12345678
          c.regs[3] = table
          c.setup = proc (n: NDS) =
            n.put(SRC, s)
            install_callbacks(n)
          c.windows = @[(DST, size + 0x90)]
          c.readback = proc (n: NDS): seq[uint32] = @[n.r32(CB + 20)]
          c.expect_mem = @[window(even(d), size + 0x90)]
          c.ignore = {3}
          c.expect_regs = @[(0, uint32(size))]
          run(c)
        block:
          let (s, d) = rl_stream(size)
          var c = base_case("RLUnCompReadByCallbackWrite16bit " & $size & suffix, arm9, 0x15)
          c.regs[0] = SRC
          c.regs[1] = DST
          c.regs[2] = 0
          c.regs[3] = table
          c.setup = proc (n: NDS) =
            n.put(SRC, s)
            install_callbacks(n)
          c.windows = @[(DST, size + 0x90)]
          c.readback = proc (n: NDS): seq[uint32] = @[n.r32(CB + 20)]
          c.expect_mem = @[window(even(d), size + 0x90)]
          c.ignore = {3}
          c.expect_regs = @[(0, uint32(size))]
          run(c)
      for (size, bits) in vals([(4, 8), (0x40, 4), (0x200, 8), (0x400, 4)]):
        let (s, d) = huff_stream(size, bits)
        var c = base_case("HuffUnCompReadByCallback " & $bits & "-bit " & $size & suffix,
                          arm9, 0x13)
        c.regs[0] = SRC
        c.regs[1] = DST
        c.regs[2] = INFO + 0x400
        c.regs[3] = table
        c.setup = proc (n: NDS) =
          n.put(SRC, s)
          install_callbacks(n)
        c.windows = @[(DST, size + 8), (INFO + 0x400, 0x40)]
        c.readback = proc (n: NDS): seq[uint32] = @[n.r32(CB + 20)]
        c.expect_mem = @[d & newSeq[uint8](8), @[]]
        c.ignore = {3}
        c.expect_regs = @[(0, uint32(size))]
        run(c)
    # open / close reporting errors
    for (name, table, num) in vals([("LZ77 callback, open fails", INFO + 0x140, 0x12'u32),
                               ("LZ77 callback, close fails", INFO + 0x160, 0x12'u32),
                               ("RL callback, open fails", INFO + 0x140, 0x15'u32),
                               ("Huffman callback, close fails", INFO + 0x160, 0x13'u32)]):
      let (s, _) = if num == 0x13: huff_stream(8, 8)
                   elif num == 0x12: lz77_stream(16, 2) else: rl_stream(16)
      var c = base_case(name, arm9, num)
      c.regs[0] = SRC
      c.regs[1] = DST
      c.regs[2] = INFO + 0x400
      c.regs[3] = table
      c.setup = proc (n: NDS) =
        n.put(SRC, s)
        install_callbacks(n)
      c.windows = @[(DST, 24)]
      c.expect_regs = @[(0, 0xFFFFFFFF'u32)]
      c.ignore = {3}
      run(c)

proc table_cases() =
  ## ARM7 GetSineTable / GetPitchTable / GetVolumeTable: every index.
  for (name, num, count) in vals([("GetSineTable", 0x1A'u32, 64), ("GetPitchTable", 0x1B'u32, 768),
                             ("GetVolumeTable", 0x1C'u32, 724)]):
    var hle_vals, real_vals: seq[uint32]
    let n_h = machine(true)
    let n_r = if have_real: machine(false) else: nil
    for i in 0 ..< count:
      var c = base_case(name, false, num)
      c.regs[0] = uint32(i)
      hle_vals.add run_cpu(n_h, n_h.arm7, c, CODE7).r[0]
      if have_real: real_vals.add run_cpu(n_r, n_r.arm7, c, CODE7).r[0]
    if have_real:
      var bad = 0
      var first = ""
      for i in 0 ..< count:
        if hle_vals[i] != real_vals[i]:
          if bad == 0: first = "index " & $i & ": real " & h(real_vals[i]) & " hle " & h(hle_vals[i])
          inc bad
      check(bad == 0, "ARM7 " & name & ": all " & $count & " entries match the real BIOS",
            $bad & " differ, " & first)
    else:
      check(hle_vals[^1] != 0, "ARM7 " & name & ": table populated")

proc misc_cases() =
  for arm9 in vals([true, false]):
    block:
      var c = base_case("IsDebugger", arm9, 0x0F)
      c.ignore = {3}
      let scratch = if arm9: 0x027FFFF8'u32 else: 0x027FFFFA'u32
      c.setup = proc (n: NDS) = n.w16(scratch, 0x5A5A)
      c.windows = @[(scratch, 2)]
      c.expect_regs = @[(0, 0'u32)]
      run(c)
    for count in vals([1'u32, 100, 0x1000]):
      var c = base_case("WaitByLoop(" & $count & ")", arm9, 0x03)
      c.regs[0] = count
      c.expect_regs = @[(0, 0'u32)]
      run(c)
    block:  # Thumb caller: the comment byte comes from the halfword
      var c = base_case("Div from Thumb", arm9, 0x09)
      c.thumb = true
      c.regs[0] = 1000
      c.regs[1] = 7
      c.expect_regs = @[(0, 142'u32), (1, 6'u32), (3, 142'u32)]
      run(c)
    block:
      var c = base_case("LZ77 callback from Thumb", arm9, 0x12)
      c.thumb = true
      let (s, d) = lz77_stream(40, 2)
      c.regs[0] = SRC
      c.regs[1] = DST
      c.regs[3] = INFO + 0x100
      c.setup = proc (n: NDS) =
        n.put(SRC, s)
        install_callbacks(n)
      c.windows = @[(DST, 0x40)]
      c.expect_mem = @[window(even(d), 0x40)]
      c.ignore = {3}
      run(c)
  for r0 in vals([0'u32, 1]):
    var c = base_case("SoundBias(" & $r0 & ")", false, 0x08)
    c.regs[0] = r0
    c.regs[1] = 1
    c.setup = proc (n: NDS) = write16(Arm7Bus(nds: n), 0x04000504'u32, 0x100)
    c.readback = proc (n: NDS): seq[uint32] = @[read16(Arm7Bus(nds: n), 0x04000504'u32)]
    c.limit = 2_000_000
    run(c)
  block:
    var c = base_case("CustomPost(1)", true, 0x1F)
    c.regs[0] = 1
    c.readback = proc (n: NDS): seq[uint32] = @[n.r32(0x04000300'u32) and 0xFF]
    run(c)

proc irq_cases() =
  for arm9 in vals([true, false]):
    let f = flags_addr(arm9)
    block:
      var c = base_case("IntrWait(1, timer 0)", arm9, 0x04)
      c.regs[0] = 1
      c.regs[1] = 1'u32 shl 3
      c.setup = proc (n: NDS) =
        install_irq_handler(n, arm9)
        start_timer0(n, arm9)
      c.irqs_on = true
      c.ignore = {0, 1, 3}
      c.readback = irq_words(arm9)
      run(c)
    block:
      # A wanted flag already in the check word: the ARM7 returns at once,
      # the ARM9 (GBATEK: bugged) still waits for an IRQ; with none coming
      # it never returns.
      var c = base_case("IntrWait(0, flag already set, no IRQ source)", arm9, 0x04)
      c.regs[0] = 0
      c.regs[1] = 1'u32 shl 3
      c.setup = proc (n: NDS) =
        install_irq_handler(n, arm9)
        if arm9: n.w32(f, 1'u32 shl 3) else: n.w32_7(f, 1'u32 shl 3)
      c.irqs_on = true
      c.limit = 400_000
      c.ignore = {0, 1, 3}
      c.readback = irq_words(arm9)
      c.expect_return = not arm9
      run(c)
    block:
      var c = base_case("IntrWait(0, flag already set, timer running)", arm9, 0x04)
      c.regs[0] = 0
      c.regs[1] = 1'u32 shl 3
      c.setup = proc (n: NDS) =
        install_irq_handler(n, arm9)
        if arm9: n.w32(f, 1'u32 shl 3) else: n.w32_7(f, 1'u32 shl 3)
        start_timer0(n, arm9)
      c.irqs_on = true
      c.ignore = {0, 1, 3}
      c.readback = irq_words(arm9)
      run(c)
    block:
      var c = base_case("IntrWait(1, flag already set, timer running)", arm9, 0x04)
      c.regs[0] = 1
      c.regs[1] = 1'u32 shl 3
      c.setup = proc (n: NDS) =
        install_irq_handler(n, arm9)
        if arm9: n.w32(f, 1'u32 shl 3) else: n.w32_7(f, 1'u32 shl 3)
        start_timer0(n, arm9)
      c.irqs_on = true
      c.ignore = {0, 1, 3}
      c.readback = irq_words(arm9)
      run(c)
    block:
      var c = base_case("IntrWait(0, other flag set, timer running)", arm9, 0x04)
      c.regs[0] = 0
      c.regs[1] = 1'u32 shl 3
      c.setup = proc (n: NDS) =
        install_irq_handler(n, arm9)
        if arm9: n.w32(f, 1'u32 shl 4) else: n.w32_7(f, 1'u32 shl 4)
        start_timer0(n, arm9)
      c.irqs_on = true
      c.ignore = {0, 1, 3}
      c.readback = irq_words(arm9)
      run(c)
    # The check word's starting state against r0: which flags count, and
    # (ARM9, r0 = 0) GBATEK's "doesn't work" path.
    for pre in vals([0'u32, 0x10, 0x18, 0x08, 0x80000008'u32]):
      for r0 in vals([0'u32, 1]):
        var c = base_case("IntrWait(" & $r0 & ", timer 0), check word " & h(pre), arm9, 0x04)
        c.regs[0] = r0
        c.regs[1] = 1'u32 shl 3
        c.setup = proc (n: NDS) =
          install_irq_handler(n, arm9)
          if arm9: n.w32(f, pre) else: n.w32_7(f, pre)
          start_timer0(n, arm9)
        c.irqs_on = true
        c.ignore = {0, 1, 3}
        c.readback = irq_words(arm9)
        run(c)
    block:
      var c = base_case("VBlankIntrWait", arm9, 0x05)
      c.setup = proc (n: NDS) =
        install_irq_handler(n, arm9)
        if arm9:
          n.w32(0x04000210'u32, 1)
          n.w16(0x04000004'u32, 1'u16 shl 3)
        else:
          n.w32_7(0x04000210'u32, 1)
          write16(Arm7Bus(nds: n), 0x04000004'u32, 1'u16 shl 3)
      c.irqs_on = true
      c.limit = 3_000_000
      c.ignore = {0, 1, 3}
      c.readback = irq_words(arm9)
      run(c)
    block:
      var c = base_case("Halt, woken by timer 0", arm9, 0x06)
      c.setup = proc (n: NDS) =
        install_irq_handler(n, arm9)
        start_timer0(n, arm9)
        if arm9: n.w32(0x04000208'u32, 1) else: n.w32_7(0x04000208'u32, 1)
      c.irqs_on = true
      c.readback = irq_words(arm9)
      run(c)
    block:
      var c = base_case("Halt with IRQs masked in CPSR", arm9, 0x06)
      c.setup = proc (n: NDS) =
        install_irq_handler(n, arm9)
        start_timer0(n, arm9)
        if arm9: n.w32(0x04000208'u32, 1) else: n.w32_7(0x04000208'u32, 1)
      c.readback = proc (n: NDS): seq[uint32] =
        let f = flags_addr(arm9)
        if arm9: @[n.r32(f - 4)] else: @[n.r32_7(f - 4)]
      run(c)

proc softreset_cases() =
  for arm9 in vals([true, false]):
    var c = base_case("SoftReset", arm9, 0x00)
    let ret = 0x02120000'u32 + (if arm9: 0'u32 else: 0x100'u32)
    c.setup = proc (n: NDS) =
      n.w32(if arm9: 0x027FFE24'u32 else: 0x027FFE34'u32, ret)
      n.w32(ret, 0xEAFFFFFE'u32)
      if arm9: n.w32(DTCM_BASE + 0x3FF0, 0x11111111'u32)
      else: n.w32_7(0x0380FFF0'u32, 0x11111111'u32)
    c.readback = proc (n: NDS): seq[uint32] =
      if arm9: @[n.r32(DTCM_BASE + 0x3FF0), n.cp15.control]
      else: @[n.r32_7(0x0380FFF0'u32)]
    c.expect_return = false   # it never comes back to the caller
    c.limit = 20_000
    let n_h = machine(true)
    if c.setup != nil: c.setup(n_h)
    let hle = if arm9: run_cpu(n_h, n_h.arm9, c, CODE9) else: run_cpu(n_h, n_h.arm7, c, CODE7)
    let tag = (if arm9: "ARM9 " else: "ARM7 ") & "SoftReset"
    check(hle.r[15] == ret, tag & ": HLE jumps to the return address", h(hle.r[15]))
    if have_real:
      let n_r = machine(false)
      c.setup(n_r)
      let real = if arm9: run_cpu(n_r, n_r.arm9, c, CODE9) else: run_cpu(n_r, n_r.arm7, c, CODE7)
      for i in 0..15:
        check(real.r[i] == hle.r[i], tag & ": r" & $i & " matches the real BIOS",
              "real " & h(real.r[i]) & " hle " & h(hle.r[i]))
      check((real.cpsr and 0xFF) == (hle.cpsr and 0xFF),
            tag & ": cpsr mode/T/I/F match the real BIOS",
            "real " & h(real.cpsr) & " hle " & h(hle.cpsr))
      let rw = c.readback(n_r)
      let hw = c.readback(n_h)
      check(rw == hw, tag & ": cleared RAM / CP15 match the real BIOS", $rw & " vs " & $hw)
      # Banked registers
      template banked(cpu: untyped): seq[uint32] =
        var s: seq[uint32]
        let saved = cpu.cpsr
        for m in vals([mSVC, mIRQ]):
          cpu.set_cpsr(uint32(m) or FLAG_I or FLAG_F)
          s.add cpu.r[13]; s.add cpu.r[14]; s.add cpu.spsr
        cpu.set_cpsr(saved)
        s
      let rb = if arm9: banked(n_r.arm9) else: banked(n_r.arm7)
      let hb = if arm9: banked(n_h.arm9) else: banked(n_h.arm7)
      check(rb == hb, tag & ": SVC/IRQ sp, lr, spsr match the real BIOS", $rb & " vs " & $hb)

proc irq_vector_cases() =
  ## The BIOS IRQ dispatcher on its own: a timer IRQ taken from a busy loop
  ## reaches the handler (ARM9: also a Thumb handler) and returns.
  for arm9 in vals([true, false]):
    for thumb_handler in vals(if arm9: @[false, true] else: @[false]):
      let tag = (if arm9: "ARM9 " else: "ARM7 ") & "IRQ dispatch" &
                (if thumb_handler: " (Thumb handler)" else: "")
      proc go(hle: bool): (uint32, uint32, uint32, uint32) =
        let n = machine(hle)
        install_irq_handler(n, arm9)
        if thumb_handler:
          # The BIOS calls a Thumb stub that tail-calls the ARM handler
          let stub = HANDLER + 0x200
          n.w16(stub, 0x4B00'u16)        # ldr r3, [pc, #0]
          n.w16(stub + 2, 0x4718'u16)    # bx r3
          n.w32(stub + 4, HANDLER)
          n.w32(DTCM_BASE + 0x3FFC, stub or 1)
        start_timer0(n, arm9)
        if arm9: n.w32(0x04000208'u32, 1) else: n.w32_7(0x04000208'u32, 1)
        var c = base_case("", arm9, 0)
        c.irqs_on = true
        let code = if arm9: CODE9 else: CODE7
        if arm9:
          n.w32(code, 0xEAFFFFFE'u32)
          n.arm9.set_cpsr(uint32(mSYS))
          n.arm9.set_mode_sp(mIRQ, DTCM_BASE + 0x3E00)
          n.arm9.r[5] = 0x55555555'u32
          n.arm9.next_pc = code
        else:
          n.w32(code, 0xEAFFFFFE'u32)
          n.arm7.set_cpsr(uint32(mSYS))
          n.arm7.r[5] = 0x55555555'u32
          n.arm7.next_pc = code
        n.run_until(n.sched.now + 40_000)
        let f = flags_addr(arm9)
        if arm9: (n.r32(f - 4), n.arm9.next_pc, n.arm9.r[5], n.arm9.cpsr)
        else: (n.r32_7(f - 4), n.arm7.next_pc, n.arm7.r[5], n.arm7.cpsr)
      let hle = go(true)
      check(hle[0] == 1, tag & ": HLE handler runs", $hle[0])
      check(hle[1] == (if arm9: CODE9 else: CODE7) and hle[2] == 0x55555555'u32,
            tag & ": HLE returns to the interrupted loop", h(hle[1]))
      if have_real:
        let real = go(false)
        check(real == hle, tag & ": same as the real BIOS", $real & " vs " & $hle)

# ---------------------------------------------------------------------------

when isMainModule:
  var bios_dir = getEnv("DINGBAT_NDS_BIOS")
  if bios_dir.len == 0: bios_dir = getHomeDir() / "Documents/emu/nds/NDS Bios & Firmware"
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    case args[i]
    of "--bios": bios_dir = args[i + 1]; inc i
    of "-v": verbose = true
    else: discard
    inc i
  if fileExists(bios_dir / "bios9.bin") and fileExists(bios_dir / "bios7.bin"):
    bios9 = cast[seq[uint8]](readFile(bios_dir / "bios9.bin"))
    bios7 = cast[seq[uint8]](readFile(bios_dir / "bios7.bin"))
    have_real = true
    echo "comparing against the real BIOS in ", bios_dir
  else:
    echo "no BIOS dumps: HLE against computed expectations only"
  div_cases()
  div_random_cases()
  sqrt_cases()
  copy_cases()
  crc_cases()
  bitunpack_cases()
  decompress_cases()
  callback_cases()
  table_cases()
  misc_cases()
  irq_cases()
  irq_vector_cases()
  softreset_cases()
  echo passes, " passed, ", failures, " failed"
  if failures > 0: quit(1)
