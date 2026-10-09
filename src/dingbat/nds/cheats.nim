## DS cheat codes: Action Replay DS lists and unencrypted CodeBreaker DS
## lists, run once a frame at the start of V-blank against the memory a
## cheat device sees (nds.nim `cheat_read` / `cheat_write`).
##
## Format: GBATEK "DS Cart Cheat Action Replay DS" and "DS Cart Cheat
## Codebreaker DS". Every line is two 32-bit hex words, `XXXXXXXX YYYYYYYY`.
##
## Action Replay DS: writes (0/1/2), word and masked-halfword conditions
## (3-A, nested), the offset/data registers (B, D3-DC, C6), the loop (C0
## with D1/D2), the counter condition (C5), the parameter copy (E) and the
## memory copy (F), with the v1.54 rules (a condition with address 0 reads
## [offset]; DB leaves the offset alone). The hook lines (`00000000
## XXXXXXXX`) are word writes to address 0, which ignores stores: harmless.
## C4 (the offset becomes the address of the C4 line itself, inside the
## device's code list, which is not in the DS's memory here) is refused.
##
## CodeBreaker DS: a list whose first line is the unencrypted header
## `8000CR16 GAMECODE` runs as CodeBreaker: writes (0/1/2), add (3), OR /
## AND / XOR (7), fill (4), copy (5), the pointer write (6, and its
## conditional form with the skip GBATEK calls a bug) and the working
## condition (D). An encrypted list (header `0000CR16 GAMECODE`), BEEFC0DE
## key changes and the hooks (A, F) are refused.
##
## Each cheat runs as its own list, its registers (offset, data, conditions,
## loop) fresh every frame; the C5 counter is the cheat's own and carries
## over from frame to frame. A cheat stops after STEP_LIMIT steps a frame,
## so a runaway loop costs a bounded time, never a hang.

import std/strutils

type
  DsCheatMem* = object
    ## The memory a cheat reads and writes (the core's, or a test's).
    read8*: proc(a: uint32): uint32 {.closure.}
    read16*: proc(a: uint32): uint32 {.closure.}
    read32*: proc(a: uint32): uint32 {.closure.}
    write8*: proc(a: uint32; v: uint32) {.closure.}
    write16*: proc(a: uint32; v: uint32) {.closure.}
    write32*: proc(a: uint32; v: uint32) {.closure.}

  DsCheatKind* = enum
    dckActionReplay, dckCodeBreaker

  DsCheat* = object
    name*: string
    codes*: string
    enabled*: bool
    error*: string             ## non-empty: refused, never run
    kind*: DsCheatKind
    lines*: seq[(uint32, uint32)]
    counter: uint32            ## AR C5

  DsCheats* = ref object
    cheats*: seq[DsCheat]
    gamecode*: uint32          ## header 00Ch, little-endian (the CB header check)
    crc16*: uint32             ## header 15Eh

const STEP_LIMIT* = 1 shl 18   ## steps (lines, copied words) a cheat may take a frame

proc active*(e: DsCheats): bool =
  if e == nil: return false
  for c in e.cheats:
    if c.enabled and c.error.len == 0: return true
  false

# --- Parsing ------------------------------------------------------------

proc hex_word(s: string; ok: var bool): uint32 =
  if s.len != 8:
    ok = false
    return 0
  for ch in s:
    let d = case ch
            of '0'..'9': ord(ch) - ord('0')
            of 'a'..'f': ord(ch) - ord('a') + 10
            of 'A'..'F': ord(ch) - ord('A') + 10
            else: -1
    if d < 0:
      ok = false
      return 0
    result = (result shl 4) or uint32(d)

proc parse_lines(codes: string; lines: var seq[(uint32, uint32)]): string =
  ## Every non-blank line two 8-digit hex words (spaces between them or
  ## not). A game-ID line (`ABCD-NNNNNNNN`) is skipped.
  for raw in codes.splitLines():
    var t = ""
    for ch in raw:
      if ch notin {' ', '\t'}: t.add ch
    if t.len == 0: continue
    if t.len == 13 and t[4] == '-': continue
    if t.len != 16: return "\"" & raw.strip() & "\" is not two 8-digit hex words"
    var ok = true
    let l = hex_word(t[0 ..< 8], ok)
    let r = hex_word(t[8 ..< 16], ok)
    if not ok: return "\"" & raw.strip() & "\" is not hex"
    lines.add (l, r)
  if lines.len == 0: return "no codes"
  ""

proc check_ar(lines: seq[(uint32, uint32)]): string =
  var i = 0
  while i < lines.len:
    let (l, r) = lines[i]
    inc i
    case l shr 28
    of 0xC:
      case (l shr 24) and 0xF
      of 0, 5, 6: discard
      of 4: return "C4 (the code's own address) is not supported"
      else: return "unknown code type " & toHex(l shr 24, 2)
    of 0xD:
      if ((l shr 24) and 0xF) > 0xC: return "unknown code type " & toHex(l shr 24, 2)
    of 0xE:
      let extra = int((uint64(r) + 7) div 8)
      if r > uint32(STEP_LIMIT) or i + extra > lines.len:
        return "the E code's " & $r & " bytes need " & $extra & " lines after it"
      i += extra
    else: discard
  ""

proc cb_code(l: uint32): uint32 {.inline.} = l shr 27   ## 5-bit code number
proc cb_addr(l: uint32): uint32 {.inline.} = l and 0x07FF_FFFF'u32

proc check_cb(lines: seq[(uint32, uint32)]): string =
  var i = 1                    # line 0 is the header
  while i < lines.len:
    let (l, _) = lines[i]
    inc i
    case cb_code(l)
    of 0x00, 0x02, 0x04, 0x06, 0x07, 0x0E, 0x1A: discard
    of 0x08, 0x0A, 0x0C:
      if i >= lines.len: return "code " & toHex(l shr 24, 2) & " needs its second line"
      inc i
    of 0x14, 0x15, 0x1E, 0x1F: return "hook codes (A0, A8, F0, F8) are not supported"
    else:
      if l == 0xBEEF_C0DE'u32: return "BEEFC0DE (new encryption keys) is not supported"
      return "unknown code type " & toHex(l shr 24, 2)
  ""

proc be32(x: uint32): uint32 =
  (x shr 24) or ((x shr 8) and 0xFF00) or ((x shl 8) and 0xFF0000) or (x shl 24)

proc parse*(e: DsCheats; c: var DsCheat) =
  ## Fill `c.lines`, `c.kind` and `c.error` from `c.codes`.
  c.lines = @[]
  c.error = parse_lines(c.codes, c.lines)
  c.kind = dckActionReplay
  c.counter = 0
  if c.error.len > 0: return
  let (l0, r0) = c.lines[0]
  let game = r0 == be32(e.gamecode) or r0 == e.gamecode
  if (l0 shr 16) == 0x8000:
    c.kind = dckCodeBreaker
    if e.gamecode != 0 and not game:
      c.error = "a CodeBreaker list for another game (its header names " &
                toHex(r0, 8) & ")"
    else:
      c.error = check_cb(c.lines)
  elif (l0 shr 16) == 0 and game and e.gamecode != 0:
    c.error = "encrypted CodeBreaker codes are not supported (header 0000" &
              toHex(l0 and 0xFFFF, 4) & ")"
  else:
    c.error = check_ar(c.lines)
  if c.error.len > 0: c.lines = @[]

proc load*(e: DsCheats; text: string) =
  ## Replace the list from `.cht` text: `[x] name` (x: on) then its lines.
  e.cheats.setLen(0)
  var cur: DsCheat
  var have = false
  template flush() =
    if have:
      cur.codes = cur.codes.strip()
      e.parse(cur)
      e.cheats.add cur
    have = false
    cur = DsCheat()
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0: continue
    if line.len >= 3 and line[0] == '[' and line[2] == ']':
      flush()
      have = true
      cur.enabled = line[1] in {'x', 'X'}
      cur.name = (if line.len > 3: line[3 .. ^1].strip() else: "")
    elif have:
      if cur.codes.len > 0: cur.codes.add "\n"
      cur.codes.add line
  flush()

proc errors*(e: DsCheats): string =
  ## "name: error" per refused cheat, one a line ("" when all parse).
  for c in e.cheats:
    if c.error.len > 0:
      if result.len > 0: result.add "\n"
      result.add (if c.name.len > 0: c.name else: "?") & ": " & c.error

# --- Running: Action Replay DS ----------------------------------------------

proc run_ar(c: var DsCheat; m: DsCheatMem) =
  let lines = c.lines
  var offset, datareg: uint32
  var exec = true                 # every condition so far held
  var conds: seq[bool]            # exec before each open IF
  var loop_at = -1                # the line after C0 (-1: no loop running)
  var loop_left: uint32
  var loop_exec = true
  var loop_conds: seq[bool]
  var steps = 0
  var i = 0
  template open_if(cond: untyped) =
    conds.add exec
    if exec: exec = cond
  while i < lines.len and steps < STEP_LIMIT:
    let (l, r) = lines[i]
    inc i
    inc steps
    let a = l and 0x0FFF_FFFF'u32
    let ca = if a == 0: offset else: a   # v1.54: a condition on address 0 reads [offset]
    case l shr 28
    of 0x0: (if exec: m.write32(a + offset, r))
    of 0x1: (if exec: m.write16(a + offset, r and 0xFFFF))
    of 0x2: (if exec: m.write8(a + offset, r and 0xFF))
    of 0x3: open_if(r > m.read32(ca))
    of 0x4: open_if(r < m.read32(ca))
    of 0x5: open_if(r == m.read32(ca))
    of 0x6: open_if(r != m.read32(ca))
    of 0x7, 0x8, 0x9, 0xA:
      let want = r and 0xFFFF
      let got = if exec: (not (r shr 16)) and m.read16(ca) and 0xFFFF else: 0'u32
      case l shr 28
      of 0x7: open_if(want > got)
      of 0x8: open_if(want < got)
      of 0x9: open_if(want == got)
      else: open_if(want != got)
    of 0xB: (if exec: offset = m.read32(a + offset))
    of 0xC:
      case (l shr 24) and 0xF
      of 0:
        # FOR: Y+1 passes; it keeps the condition flags for NEXT, and
        # replaces any loop running
        if exec:
          loop_at = i
          loop_left = r
          loop_exec = exec
          loop_conds = conds
      of 5:
        inc c.counter          # counted whether or not the list is running here
        open_if((c.counter and (r and 0xFFFF)) == (r shr 16))
      of 6: (if exec: m.write32(r, offset))
      else: discard            # C4: refused at parse
    of 0xD:
      case (l shr 24) and 0xF
      of 0:
        if conds.len > 0: exec = conds.pop()
        else: exec = true
      of 1, 2:
        if loop_at >= 0 and loop_left > 0:
          dec loop_left
          i = loop_at
        else:
          if loop_at >= 0:
            exec = loop_exec
            conds = loop_conds
          loop_at = -1
          if ((l shr 24) and 0xF) == 2:
            offset = 0
            datareg = 0
            exec = true
            conds.setLen(0)
      of 3: (if exec: offset = r)
      of 4: (if exec: datareg += r)
      of 5: (if exec: datareg = r)
      of 6:
        if exec:
          m.write32(r + offset, datareg)
          offset += 4
      of 7:
        if exec:
          m.write16(r + offset, datareg and 0xFFFF)
          offset += 2
      of 8:
        if exec:
          m.write8(r + offset, datareg and 0xFF)
          offset += 1
      of 9: (if exec: datareg = m.read32(r + offset))
      of 0xA: (if exec: datareg = m.read16(r + offset))
      of 0xB: (if exec: datareg = m.read8(r + offset))
      of 0xC: (if exec: offset += r)
      else: discard
    of 0xE:
      # Y parameter bytes in the lines that follow, low byte of the left
      # word first
      let n = int(r)
      let extra = (n + 7) div 8
      if exec:
        let dst = a + offset
        for k in 0 ..< n:
          let (pl, pr) = lines[i + k div 8]
          let w = if (k and 7) < 4: pl else: pr
          m.write8(dst + uint32(k), (w shr ((k and 3) * 8)) and 0xFF)
        steps += n div 4
      i += extra
    of 0xF:
      if exec:
        let n = int(min(r, uint32(STEP_LIMIT)))
        var k = 0
        while k + 4 <= n:
          m.write32(a + uint32(k), m.read32(offset + uint32(k)))
          k += 4
        while k < n:
          m.write8(a + uint32(k), m.read8(offset + uint32(k)))
          inc k
        steps += n div 4
    else: discard

# --- Running: CodeBreaker DS --------------------------------------------------

proc cb_cond(c: uint32; mem, imm: uint32): bool =
  case c and 7
  of 0: mem == imm
  of 1: mem != imm
  of 2: mem < imm
  of 3: mem > imm
  of 4: (mem and imm) == 0
  of 5: (mem and imm) != 0
  of 6: (mem and imm) == imm
  else: (mem and imm) != imm

proc run_cb(c: var DsCheat; m: DsCheatMem) =
  let lines = c.lines
  var steps = 0
  var i = 1
  while i < lines.len and steps < STEP_LIMIT:
    let (l, r) = lines[i]
    inc i
    inc steps
    let a = cb_addr(l)
    case cb_code(l)
    of 0x00: m.write8(a, r and 0xFF)
    of 0x02: m.write16(a, r and 0xFFFF)
    of 0x04: m.write32(a, r)
    of 0x06:
      if ((r shr 16) and 0xF) == 1: m.write16(a, (m.read16(a) + (r and 0xFFFF)) and 0xFFFF)
      else: m.write8(a, (m.read8(a) + (r and 0xFF)) and 0xFF)
    of 0x07: m.write32(a, m.read32(a) + r)
    of 0x0E:
      let half = ((r shr 16) and 0xF) == 1
      let v = if half: r and 0xFFFF else: r and 0xFF
      let cur = if half: m.read16(a) else: m.read8(a)
      let nv = case (r shr 20) and 0xF
               of 1: cur and v
               of 2: cur xor v
               else: cur or v
      if half: m.write16(a, nv) else: m.write8(a, nv)
    of 0x08:
      # fill: NUM items STEP units apart, the value growing by Z each
      let (y, z) = lines[i]
      inc i
      let size = r shr 28
      let num = int((r shr 16) and 0xFFF)
      let step = (r and 0xFFFF)
      let unit = case size
                 of 2: 1'u32
                 of 1: 2'u32
                 else: 4'u32
      for k in 0 ..< num:
        let at = a + uint32(k) * step * unit
        let v = y + uint32(k) * z
        case size
        of 2: m.write8(at, v and 0xFF)
        of 1: m.write16(at, v and 0xFFFF)
        else: m.write32(at, v)
      steps += num
    of 0x0A:
      let (z, _) = lines[i]
      inc i
      let n = int(min(r, uint32(STEP_LIMIT)))
      for k in 0 ..< n: m.write8(z + uint32(k), m.read8(a + uint32(k)))
      steps += n div 4
    of 0x0C:
      let (z, last) = lines[i]
      inc i
      let at = m.read32(a) + z
      let size = last shr 28
      template put() =
        case size
        of 0: m.write8(at, r and 0xFF)
        of 1: m.write16(at, r and 0xFFFF)
        else: m.write32(at, r)
      if ((last shr 24) and 0xF) == 1:
        let byte_cmp = ((last shr 16) and 0xF) == 1
        let mem = if byte_cmp: m.read8(at) else: m.read16(at)
        let imm = if byte_cmp: last and 0xFF else: last and 0xFFFF
        if cb_cond(last shr 20, mem, imm): put()
        else: i += int(last shr 24)   # GBATEK: skips NN lines when false
      else:
        put()
    of 0x1A:
      let byte_cmp = ((r shr 16) and 0xF) == 1
      let mem = if byte_cmp: m.read8(a) else: m.read16(a)
      let imm = if byte_cmp: r and 0xFF else: r and 0xFFFF
      if not cb_cond(r shr 20, mem, imm): i += max(1, int(r shr 24))
    else: discard

proc run*(e: DsCheats; m: DsCheatMem) =
  ## One frame of every enabled cheat, in list order.
  if e == nil: return
  for c in e.cheats.mitems:
    if not c.enabled or c.error.len > 0: continue
    case c.kind
    of dckActionReplay: run_ar(c, m)
    of dckCodeBreaker: run_cb(c, m)
