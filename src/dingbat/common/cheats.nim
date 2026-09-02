## Cheat-code engine, shared by the GBA and GB cores.
##
## The engine is deliberately decoupled from the emulator cores: it only knows
## how to parse cheat codes into a flat list of `CheatOp`s and how to apply them
## through a small set of memory-access callbacks (`MemHooks`). Each core wires
## its own memory in and calls `apply_ram`/`apply_rom` — cheats.nim never imports
## gba/gb, so there is no dependency cycle.
##
## Supported formats (auto-detected from the code's shape):
##   GB / GBC
##     * Game Genie   AAA-BBB-CCC   (9 hex) or AAA-BBB (6 hex)  -> ROM patch
##     * GameShark     TTDDAAAA      (8 hex)                     -> RAM write / frame
##   GBA
##     * Pro Action Replay v3 / GameShark v3   XXXXXXXX YYYYYYYY  (8+8,
##       encrypted with the device's TEA seeds, or already decrypted — the
##       list is decrypted when its decryption reads as RAW-table codes
##       throughout). Writes, fills, adds, indirect writes, conditionals, the
##       AR_BUTTON activator (L+R), slides and ROM patches are applied; the
##       hook, ID, reseed, slowdown and ELSE/ENDIF lines are inert.
##     * CodeBreaker / Xploder   82XXXXXX YYYY  (8+4, unencrypted) — the
##       common Pokémon item/money form; writes, OR/AND/ADD, conditionals and
##       the joypad gate are honoured.
##
## Not supported: encrypted CodeBreaker (type 9), the DEADFACE reseed (its
## translation tables live inside the cartridge), CodeBreaker slides/byte
## lists, nested if-blocks, and true code hooks (they inject ARM code, which a
## per-frame poke engine cannot run).
##
## Formats: Pan Docs "Game Genie" / "Game Shark" (GB), Frohwein's Game Genie
## page (GB compare-byte encoding), GBATEK "GBA Cheat Codes" (CodeBreaker
## and Pro Action Replay V3 tables, cipher and seeds).

import std/[strutils, tables]

type
  CheatPlatform* = enum
    cpGB, cpGBA

  CheatFormat* = enum
    cfAuto,        ## detect from the code shape
    cfGbGameGenie,
    cfGbGameShark,
    cfGbaPar3,        ## encrypted Action Replay v3 / GameShark v3, 8+8 (PARv3)
    cfGbaRaw,         ## already-decrypted PARv3 words, 8+8
    cfGbaCbRaw        ## raw (unencrypted) CodeBreaker / short GameShark, 8+4

  CheatCmp* = enum
    ccEq, ccNe, ccLtS, ccGtS, ccLtU, ccGtU, ccAnd

  CheatAction* = enum
    caWrite8, caWrite16, caWrite32,   ## per-frame RAM writes
    caOr, caAnd, caAdd,               ## read-modify-write (width in op.width)
    caIndirect,                       ## write value to *[address] + offset (pointer follow)
    caCond,                           ## gate the next `skip` ops on a compare
    caIfButtons,                      ## gate the next `skip` ops unless buttons held
    caRomPatch,                       ## one-shot ROM byte patch (Game Genie / GSA_PATCH)
    caUnsupported

  CheatOp* = object
    action*: CheatAction
    address*: uint32
    value*: uint32
    compare*: int         ## caRomPatch: expected byte, or -1 for "no compare"
    width*: uint8         ## caCond/caIndirect: width in bytes (1/2/4)
    cmp*: CheatCmp        ## caCond: comparison kind
    skip*: uint8          ## caCond/caIfButtons: how many following ops to gate
    offset*: uint32       ## caIndirect: added to the dereferenced pointer

  Cheat* = object
    name*: string         ## human label
    codes*: string        ## raw multi-line text the user typed
    format*: CheatFormat   ## cfAuto unless the user pinned a format
    enabled*: bool
    ops*: seq[CheatOp]     ## parsed result (empty when error != "")
    error*: string        ## non-empty => parse failed, shown in the UI

  CheatEngine* = ref object
    platform*: CheatPlatform
    cheats*: seq[Cheat]
    ## Original ROM bytes displaced by an applied ROM patch, keyed by offset, so
    ## Game Genie codes can be toggled off live without reloading the game.
    rom_backup: Table[int, byte]

  ## Memory access the cores hand to `apply_ram`. Only the widths cheats need.
  MemHooks* = object
    read8*:  proc(a: uint32): uint8  {.closure.}
    read16*: proc(a: uint32): uint16 {.closure.}
    read32*: proc(a: uint32): uint32 {.closure.}
    write8*: proc(a: uint32; v: uint8) {.closure.}
    write16*: proc(a: uint32; v: uint16) {.closure.}
    write32*: proc(a: uint32; v: uint32) {.closure.}

proc new_cheat_engine*(platform: CheatPlatform): CheatEngine =
  CheatEngine(platform: platform, rom_backup: initTable[int, byte]())

# ---------------------------------------------------------------------------
# Small hex helpers
# ---------------------------------------------------------------------------

proc parse_hex_exact(s: string; want: int; ok: var bool): uint32 =
  ## Parse exactly `want` hex digits (no more, no less). Sets ok=false on any
  ## non-hex character or wrong length.
  ok = s.len == want
  if not ok: return 0
  for c in s:
    let d =
      case c
      of '0'..'9': ord(c) - ord('0')
      of 'a'..'f': ord(c) - ord('a') + 10
      of 'A'..'F': ord(c) - ord('A') + 10
      else: -1
    if d < 0:
      ok = false
      return 0
    result = (result shl 4) or uint32(d)

proc strip_code(s: string): string =
  ## Drop whitespace so "1234 5678" and "12345678" tokenise the same.
  for c in s:
    if c notin {' ', '\t'}: result.add c

# ---------------------------------------------------------------------------
# GB Game Genie (ROM patch). Code ABC-DEF-GHI: AB = replacement byte,
# CDE = address bits 11..0, F = address bits 15..12 complemented, GI = the
# compare byte encoded as ((x xor $FF) ror 2) xor $45, H = check digit.
# Reference: Jeff Frohwein, "Game Genie for GameBoy Technical Page"
# (devrs.com/gb/files/gg.html).
# ---------------------------------------------------------------------------

proc parse_gb_game_genie(code: string; op: var CheatOp): string =
  ## "AAA-BBB" or "AAA-BBB-CCC"; returns "" on success.
  let parts = code.split('-')
  if parts.len != 2 and parts.len != 3:
    return "Game Genie code needs 2 or 3 groups (AAA-BBB[-CCC])"
  var ok: bool
  let abc = parse_hex_exact(parts[0], 3, ok)
  if not ok: return "bad hex in group 1"
  let def = parse_hex_exact(parts[1], 3, ok)
  if not ok: return "bad hex in group 2"
  let nib_c = abc and 0xF
  let nib_f = def and 0xF
  op.action = caRomPatch
  op.address = ((nib_f xor 0xF) shl 12) or (nib_c shl 8) or (def shr 4)
  op.value = abc shr 4
  op.compare = -1
  if parts.len == 3:
    let ghi = parse_hex_exact(parts[2], 3, ok)
    if not ok: return "bad hex in group 3"
    let enc = ((ghi shr 8) shl 4) or (ghi and 0xF)
    let inv = (enc xor 0xFF) and 0xFF
    let rot = ((inv shr 2) or (inv shl 6)) and 0xFF
    op.compare = int(rot xor 0x45)
  return ""

# ---------------------------------------------------------------------------
# GB GameShark (per-frame RAM write). Pan Docs, "Game Genie/Shark Cheats".
# ---------------------------------------------------------------------------


proc parse_gb_gameshark(code: string; op: var CheatOp): string =
  ## Pan Docs: "Game Shark codes consist of eight hexadecimal digits ...
  ## 01234567: digits 0-1 SRAM bank, 2-3 new value, 4-7 address", and the
  ## address digits are stored low byte first ("010238CD ... writes $02 at
  ## address $CD38"). The bank rides in address bits 16-23; the GB core only
  ## consults it for an $A000-BFFF target.
  var ok: bool
  let digits = parse_hex_exact(code, 8, ok)
  if not ok: return "GameShark code needs 8 hex digits (BBVVLLHH)"
  let bank = digits shr 24
  let new_value = (digits shr 16) and 0xFF
  let addr_low = (digits shr 8) and 0xFF
  let addr_high = digits and 0xFF
  op.action = caWrite8
  op.value = new_value
  op.address = (bank shl 16) or (addr_high shl 8) or addr_low
  return ""

# ---------------------------------------------------------------------------
# GBA cipher. GBATEK "Gameshark Encryption": 32 rounds of
#   A=A + (V*16+S0) XOR (V+I*9E3779B9h) XOR (V/32+S1)
#   V=V + (A*16+S2) XOR (A+I*9E3779B9h) XOR (A/32+S3)
# with A/V the left/right code halves. That is TEA (Wheeler & Needham) with
# the device's four seeds as the key. "Pro Action Replay V3 Encryption works
# exactly as for Gameshark Encryption, but with different initial seeds".
# ---------------------------------------------------------------------------

const PROAR3_INITIAL_SEEDS: array[4, uint32] =
  [0x7AA9648F'u32, 0x7FAE6994'u32, 0xC0EFAAD5'u32, 0x42712C57'u32]

proc gba_gs_decrypt*(op1, op2: var uint32; seeds: array[4, uint32]) =
  ## TEA decryption (32 rounds), reversing the cheat-device encryption.
  var sum = 0xC6EF3720'u32
  for _ in 0 ..< 32:
    op2 = op2 - (((op1 shl 4) + seeds[2]) xor (op1 + sum) xor ((op1 shr 5) + seeds[3]))
    op1 = op1 - (((op2 shl 4) + seeds[0]) xor (op2 + sum) xor ((op2 shr 5) + seeds[1]))
    sum = sum - 0x9E3779B9'u32

proc gba_gs_encrypt*(op1, op2: var uint32; seeds: array[4, uint32]) =
  ## Forward TEA — the exact inverse of `gba_gs_decrypt`. Used only by tests to
  ## prove the cipher round-trips.
  var sum = 0'u32
  for _ in 0 ..< 32:
    sum = sum + 0x9E3779B9'u32
    op1 = op1 + (((op2 shl 4) + seeds[0]) xor (op2 + sum) xor ((op2 shr 5) + seeds[1]))
    op2 = op2 + (((op1 shl 4) + seeds[2]) xor (op1 + sum) xor ((op1 shr 5) + seeds[3]))

# ---------------------------------------------------------------------------
# GBA Pro Action Replay V3 / GameShark V3, decrypted form "ttaaaaaa xxxxyyzz".
# GBATEK "Code Format":
#   adr mask = 003FFFFF      n/a mask = 00C00000 (not used)
#   xtr mask = 01000000      (I/O write width, and MSB of the hook address)
#   siz mask = 06000000      typ mask = 38000000 (0=normal, other=conditional)
#   sub mask = C0000000
# RAM operands are written [a0aaaaa]: the 24-bit field's top digit is the
# region digit of a 28-bit address (2 = EWRAM, 3 = IWRAM); under the adr mask
# only bits 21-20 of that digit exist.
#
# A first word of exactly 00000000 selects the "special" second-word table
# (ELSE, ENDIF, slowdown, end of list, and the four-word AR_BUTTON / ROM patch
# / slide codes); a second word of 001DC0DE is the ID code; a first word of
# DEADFACE changes the seeds.
# ---------------------------------------------------------------------------

const
  ARV3_ID_CODE = 0x001DC0DE'u32   ## "xxxxxxxx 001DC0DE  Enable Code - ID Code [080000AC]"
  ARV3_RESEED  = 0xDEADFACE'u32   ## "DEADFACE 0000xxxx  Enable Code - Change Encryption Seeds"
  ARV3_ELSE    = 0x60000000'u32   ## "00000000 60000000  ELSE (?)"
  ARV3_ENDIF   = 0x40000000'u32   ## "00000000 40000000  ENDIF (?)"
  KEYINPUT_ADDRESS = 0x04000130'u32
  ## "IF AR_BUTTON": which button the device means is not written down; this
  ## engine gates on L+R held together (KEYINPUT bits 9 and 8, active low).
  AR_BUTTON_MASK = 0x0300'u32
  ## A fill "[a0aaaaa..a0aaaaa+xxxxxx]=yy" expands to one op per element; a
  ## count past this is rejected rather than allocating millions of ops.
  ## Assumed: no real code fills more than a few KB.
  FILL_LIMIT = 0x1000

type
  Arv3Fields = object   ## the masked fields of a decrypted first word
    sub: int            ## bits 31-30: action / base
    typ: int            ## bits 29-27: 0 normal, else the condition
    siz: int            ## bits 26-25: 0/1/2 = 8/16/32-bit, 3 = special
    xtr: bool           ## bit 24
    adr: uint32         ## bits 21-0

proc arv3_fields(left: uint32): Arv3Fields =
  Arv3Fields(sub: int(left shr 30), typ: int((left shr 27) and 7),
             siz: int((left shr 25) and 3), xtr: ((left shr 24) and 1) != 0,
             adr: left and 0x003FFFFF'u32)

proc ram_operand(adr: uint32): uint32 {.inline.} =
  ## [a0aaaaa]: region bits 21-20 of the field move up to address bits 25-24.
  ((adr and 0x300000'u32) shl 4) or (adr and 0x0FFFFF'u32)

proc siz_bytes(siz: int): int {.inline.} = 1 shl siz          # 0/1/2 -> 1/2/4
proc siz_mask(siz: int): uint32 {.inline.} =
  if siz >= 2: 0xFFFFFFFF'u32 else: (1'u32 shl (8 * siz_bytes(siz))) - 1
proc plain_write(nbytes: int): CheatAction {.inline.} =
  case nbytes
  of 1: caWrite8
  of 2: caWrite16
  else: caWrite32

proc arv3_condition(f: Arv3Fields; right: uint32; op: var CheatOp): string =
  ## "iiaaaaaa yyyyyyyy  IF [a0aaaaa] <cond> <value> THEN <action>" with
  ## <cond> = typ (08 =, 10 <>, 18 signed <, 20 signed >, 28 unsigned <,
  ## 30 unsigned >, 38 logical AND), <value> = siz (00/02/04 = width, 06 =
  ## "always false") and <action> = sub (00 next code, 40 next two codes,
  ## 80 all following codes until ELSE or ENDIF, C0 turn off all codes).
  op.action = caCond
  op.address = ram_operand(f.adr)
  op.cmp =
    case f.typ
    of 1: ccEq
    of 2: ccNe
    of 3: ccLtS
    of 4: ccGtS
    of 5: ccLtU
    of 6: ccGtU
    else: ccAnd
  if f.siz == 3:
    # "always false": a logical AND against zero can never pass.
    op.width = 1
    op.cmp = ccAnd
    op.value = 0
  else:
    op.width = uint8(siz_bytes(f.siz))
    op.value = right and siz_mask(f.siz)
  op.skip =
    case f.sub
    of 0: 1
    of 1: 2
    # Assumed: the per-frame engine has a flat skip counter and no block
    # nesting, so "until ELSE or ENDIF" and "turn off all codes" are both
    # approximated as gating the single next op.
    else: 1
  return ""

proc arv3_normal(f: Arv3Fields; left, right: uint32; ops: var seq[CheatOp]): string =
  ## typ = 0. sub selects: 0 fill/write, 1 indirect, 2 add, 3 hook or I/O.
  var op: CheatOp
  case f.sub
  of 3:
    if f.siz == 2:
      # "C4aaaaaa 0000yyyy  Enable Code - Hook Routine at [8aaaaaa]": the
      # device injects its handler there; a per-frame poke engine has nothing
      # to inject, so the line is recognised and left inert.
      op.action = caUnsupported
      ops.add op
      return ""
    if f.siz == 3:
      # "C6aaaaaa 0000yyyy  [4aaaaaa]=yyyy" / "C7aaaaaa yyyyyyyy  [4aaaaaa]=yyyyyyyy"
      op.address = 0x04000000'u32 or f.adr
      if f.xtr:
        op.action = caWrite32
        op.value = right
        op.width = 4
      else:
        op.action = caWrite16
        op.value = right and 0xFFFF
        op.width = 2
      ops.add op
      return ""
  else: discard
  if f.sub == 3 or f.siz == 3:
    # Combinations the RAW table does not list (C0/C2/C3, and 06/46/86).
    # Assumed: recognised and left inert, like the enable codes, so one odd
    # line in a published list does not disable the whole cheat.
    op.action = caUnsupported
    ops.add op
    return ""
  let nbytes = siz_bytes(f.siz)
  let mask = siz_mask(f.siz)
  op.address = ram_operand(f.adr)
  op.value = right and mask
  case f.sub
  of 0:
    # "00aaaaaa xxxxxxyy  [a0aaaaa..a0aaaaa+xxxxxx]=yy"
    # "02aaaaaa xxxxyyyy  [a0aaaaa..a0aaaaa+xxxx*2]=yyyy"
    # "04aaaaaa yyyyyyyy  [a0aaaaa]=yyyyyyyy"
    let count = if f.siz == 2: 0'u32 else: right shr (8 * nbytes)
    if count > uint32(FILL_LIMIT): return "fill of " & $count & " elements is too long"
    op.action = plain_write(nbytes)
    op.width = uint8(nbytes)
    for k in 0'u32 .. count:
      op.address = ram_operand(f.adr) + k * uint32(nbytes)
      ops.add op
  of 1:
    # "40aaaaaa xxxxxxyy  [ [a0aaaaa] + xxxxxx ]=yy"
    # "42aaaaaa xxxxyyyy  [ [a0aaaaa] + xxxx*2 ]=yyyy"
    # "44aaaaaa yyyyyyyy  [ [a0aaaaa] ]=yyyyyyyy"
    op.action = caIndirect
    op.width = uint8(nbytes)
    op.offset = if f.siz == 2: 0'u32 else: (right shr (8 * nbytes)) * uint32(nbytes)
    ops.add op
  else:
    # "80aaaaaa 000000yy  [a0aaaaa]=[a0aaaaa]+yy" (and 82/84 wider)
    op.action = caAdd
    op.width = uint8(nbytes)
    ops.add op
  return ""

proc arv3_special_needs_pair(right: uint32): bool {.inline.} =
  ## The four-word codes of the special table (first word 00000000): AR_BUTTON
  ## 10/12/14, ROM patch 18/1A/1C/1E, slide 80/82/84.
  (right shr 24) in {0x10'u32, 0x12, 0x14, 0x18, 0x1A, 0x1C, 0x1E, 0x80, 0x82, 0x84}

proc arv3_special(right: uint32; have_pair: bool; third, fourth: uint32;
                  ops: var seq[CheatOp]): string =
  ## First word 00000000. `third`/`fourth` are the following pair when
  ## `have_pair` (required by the four-word forms).
  var op: CheatOp
  let kind = right shr 24
  if right == 0 or right == ARV3_ELSE or right == ARV3_ENDIF or
     (right and 0xFFFF00FF'u32) == 0x08000000'u32:
    # "00000000 00000000 End of the code list", ELSE, ENDIF and
    # "00000000 0800xx00 AR Slowdown": no per-frame effect here.
    op.action = caUnsupported
    ops.add op
    return ""
  if not arv3_special_needs_pair(right):
    # A second word the special table does not list. Assumed: inert.
    op.action = caUnsupported
    ops.add op
    return ""
  if not have_pair:
    return "code 00000000 " & toHex(right, 8) & " needs a second line"
  case kind
  of 0x10, 0x12, 0x14:
    # "00000000 1Saaaaaa 000000zz 00000000  IF AR_BUTTON THEN [a0aaaaa]=zz"
    let nbytes = 1 shl int((kind shr 1) and 3)     # 10 -> 1, 12 -> 2, 14 -> 4
    op.action = caIfButtons
    op.value = AR_BUTTON_MASK
    op.skip = 1
    ops.add op
    op = CheatOp(action: plain_write(nbytes), address: ram_operand(right and 0x3FFFFF),
                 value: third and siz_mask(nbytes shr 1), width: uint8(nbytes))
    ops.add op
  of 0x18, 0x1A, 0x1C, 0x1E:
    # "00000000 18aaaaaa 0000zzzz 00000000  [8000000+aaaaaa*2]=zzzz (ROM Patch 1)"
    op.action = caRomPatch
    op.address = 0x08000000'u32 + (right and 0xFFFFFF'u32) * 2
    op.value = third and 0xFFFF
    op.width = 2
    op.compare = -1
    ops.add op
  else:
    # "00000000 80aaaaaa 000000yy ssccssss  repeat cc times [a0aaaaa]=yy"
    # (with yy=yy+ss, a0aaaaa=a0aaaaa+ssss after each step); 82/84 wider.
    let nbytes = 1 shl int((kind shr 1) and 3)
    let repeat = (fourth shr 16) and 0xFF
    let value_step = fourth shr 24
    let addr_step = (fourth and 0xFFFF) * uint32(nbytes)
    op.action = plain_write(nbytes)
    op.width = uint8(nbytes)
    var value = third and siz_mask(nbytes shr 1)
    var address = ram_operand(right and 0x3FFFFF)
    for _ in 0'u32 ..< repeat:
      op.address = address
      op.value = value and siz_mask(nbytes shr 1)
      ops.add op
      value += value_step
      address += addr_step
  return ""

proc arv3_reads_as_plaintext(pairs: seq[(uint32, uint32)]): bool =
  ## Does a (candidate) decrypted list read as RAW-table codes throughout?
  ## Every pair must be a listed form, with RAM operands in EWRAM/IWRAM, I/O
  ## operands inside the I/O area and the hook/reseed/slowdown pads zero.
  ## Random words almost never satisfy all of that at once.
  var i = 0
  while i < pairs.len:
    let (left, right) = pairs[i]
    inc i
    if left == 0:
      if arv3_special_needs_pair(right):
        if i >= pairs.len: return false
        let (_, pad) = pairs[i]
        inc i
        # The fourth word is a zero pad except for the slide's "ssccssss".
        if pad != 0 and (right shr 24) < 0x80: return false
        if (right and 0x00C00000'u32) != 0 and (right shr 24) < 0x18: return false
      elif not (right == 0 or right == ARV3_ELSE or right == ARV3_ENDIF or
                (right and 0xFFFF00FF'u32) == 0x08000000'u32):
        return false
      continue
    if right == ARV3_ID_CODE: continue
    if left == ARV3_RESEED:
      if (right shr 16) != 0: return false
      continue
    let f = arv3_fields(left)
    if (left and 0x00C00000'u32) != 0: return false
    if f.typ == 0 and f.sub == 3:
      if f.siz == 2:
        if (right shr 16) != 0: return false          # hook pad
      elif f.siz == 3:
        if f.adr >= 0x400: return false               # I/O area only
      else:
        return false
      continue
    if f.typ == 0 and f.siz == 3: return false
    if f.xtr: return false
    if ((f.adr shr 20) and 3) < 2: return false        # EWRAM / IWRAM only
  return true

# ---------------------------------------------------------------------------
# GBA CodeBreaker / Xploder, unencrypted "Taaaaaaa yyyy" (type nibble T,
# 28-bit address, 16-bit operand). GBATEK "Codebreaker Codes".
# ---------------------------------------------------------------------------

proc codebreaker_line(first, operand: uint32; ops: var seq[CheatOp]): string =
  var op: CheatOp
  let kind = first shr 28
  op.address = first and 0x0FFFFFFF'u32
  op.value = operand and 0xFFFF
  op.width = 2
  case kind
  of 0x0, 0x1:
    # "0000xxxx 000y Enable Code 1 - Game ID", "1aaaaaaa 000z Enable Code 2 -
    # Hook Address": verification and the handler hook, nothing to poke.
    op.action = caUnsupported
  of 0x2: op.action = caOr                # "[aaaaaaa]=[aaaaaaa] OR yyyy"
  of 0x3:                                 # "3aaaaaaa 00yy  [aaaaaaa]=yy"
    op.action = caWrite8
    op.value = operand and 0xFF
    op.width = 1
  of 0x4, 0x5:
    # Slide "4aaaaaaa yyyy / iiiicccc ssss" and byte list "5aaaaaaa cccc /
    # 11223344 5566 ...": need their parameter lines. Assumed: recognised
    # and left inert, like the enable codes.
    op.action = caUnsupported
  of 0x6: op.action = caAnd               # "[aaaaaaa]=[aaaaaaa] AND yyyy"
  of 0x7: op.action = caCond; op.cmp = ccEq; op.skip = 1
  of 0x8: op.action = caWrite16           # "8aaaaaaa yyyy  [aaaaaaa]=yyyy"
  of 0x9:
    # "9xyyxxxx xxxx  Enable Code 0 - Encrypt all following codes": the
    # CodeBreaker cipher is not implemented, so everything after it would be
    # applied as garbage.
    return "encrypted CodeBreaker codes are not supported"
  of 0xA: op.action = caCond; op.cmp = ccNe; op.skip = 1
  of 0xB: op.action = caCond; op.cmp = ccGtS; op.skip = 1   # "(signed comparison)"
  of 0xC: op.action = caCond; op.cmp = ccLtS; op.skip = 1
  of 0xD:
    # "D0000020 yyyy  IF [joypad] AND yyyy = 0 THEN (next code)": KEYINPUT is
    # active low, so the gate passes when every button in yyyy is held.
    op.action = caIfButtons
    op.address = KEYINPUT_ADDRESS
    op.skip = 1
  of 0xE: op.action = caAdd               # "[aaaaaaa]=[aaaaaaa]+yyyy"
  else:   op.action = caCond; op.cmp = ccAnd; op.skip = 1   # "IF [aaaaaaa] AND yyyy"
  ops.add op
  return ""

# ---------------------------------------------------------------------------
# GBA code lists: one line per code (8+8 = Action Replay pair, 8+4 =
# CodeBreaker), with the four-word Action Replay forms spanning two lines.
# ---------------------------------------------------------------------------

type
  GbaCodeLine = object
    text: string          ## as typed, for error messages
    codebreaker: bool     ## 8+4 form
    left, right: uint32   ## the pair (8+8) or word + operand (8+4)

proc tokenise_gba(codes: string; forced: CheatFormat;
                  lines: var seq[GbaCodeLine]): string =
  for raw_line in codes.splitLines():
    let text = raw_line.strip()
    if text.len == 0 or text.startsWith("#"): continue
    let hex = text.strip_code()
    var line = GbaCodeLine(text: text)
    var ok1, ok2: bool
    case forced
    of cfGbaCbRaw:
      line.codebreaker = true
    of cfGbaPar3, cfGbaRaw:
      line.codebreaker = false
    else:
      line.codebreaker = hex.len == 12
    if line.codebreaker:
      if hex.len != 12: return "\"" & text & "\": CodeBreaker code needs 8+4 hex digits"
      line.left = parse_hex_exact(hex[0 ..< 8], 8, ok1)
      line.right = parse_hex_exact(hex[8 ..< 12], 4, ok2)
    else:
      if hex.len != 16: return "\"" & text & "\": Action Replay code needs 8+8 hex digits"
      line.left = parse_hex_exact(hex[0 ..< 8], 8, ok1)
      line.right = parse_hex_exact(hex[8 ..< 16], 8, ok2)
    if not (ok1 and ok2): return "\"" & text & "\": bad hex"
    lines.add line
  return ""

proc parse_gba_codes(codes: string; forced: CheatFormat):
    tuple[ops: seq[CheatOp]; error: string] =
  var lines: seq[GbaCodeLine]
  let tok_err = tokenise_gba(codes, forced, lines)
  if tok_err.len > 0: return (@[], tok_err)
  # Encrypted or plain? A forced format decides. Otherwise: published lists
  # are encrypted far more often than not, so that is tried first — the list
  # is encrypted when its decryption reads entirely as RAW-table codes, and
  # is taken as already decrypted when it does not. (An encrypted line reads
  # as a plausible RAW code by accident a few percent of the time; a plain
  # line decrypts to one about one percent of the time, and every extra line
  # shrinks that.)
  var trial: seq[(uint32, uint32)]
  for l in lines:
    if l.codebreaker: continue
    var (a, b) = (l.left, l.right)
    gba_gs_decrypt(a, b, PROAR3_INITIAL_SEEDS)
    trial.add (a, b)
  let encrypted =
    case forced
    of cfGbaPar3: true
    of cfGbaRaw, cfGbaCbRaw: false
    else: trial.len > 0 and arv3_reads_as_plaintext(trial)
  if encrypted:
    for l in lines.mitems:
      if not l.codebreaker: gba_gs_decrypt(l.left, l.right, PROAR3_INITIAL_SEEDS)
  var i = 0
  while i < lines.len:
    let l = lines[i]
    inc i
    var err: string
    if l.codebreaker:
      err = codebreaker_line(l.left, l.right, result.ops)
    elif l.left == 0:
      var have_pair = false
      var third, fourth: uint32
      if arv3_special_needs_pair(l.right) and i < lines.len and not lines[i].codebreaker:
        have_pair = true
        third = lines[i].left
        fourth = lines[i].right
        inc i
      err = arv3_special(l.right, have_pair, third, fourth, result.ops)
    elif l.right == ARV3_ID_CODE or l.left == ARV3_RESEED:
      # ID code: "just a verification". Reseed: the T1/T2 translation tables
      # are inside the cartridge and unpublished, so later codes keep the
      # initial seeds.
      result.ops.add CheatOp(action: caUnsupported)
    else:
      let f = arv3_fields(l.left)
      if f.typ == 0:
        err = arv3_normal(f, l.left, l.right, result.ops)
      else:
        var op: CheatOp
        err = arv3_condition(f, l.right, op)
        if err.len == 0: result.ops.add op
    if err.len > 0:
      return (@[], "\"" & l.text & "\": " & err)

proc detect_format(platform: CheatPlatform; line: string): CheatFormat =
  case platform
  of cpGB:
    if '-' in line: cfGbGameGenie
    else: cfGbGameShark
  of cpGBA:
    # 8+8 hex = Action Replay pair; 8+4 hex = CodeBreaker.
    if line.strip_code().len == 12: cfGbaCbRaw
    else: cfGbaPar3

proc parse_line(platform: CheatPlatform; fmt: CheatFormat; line: string;
                op: var CheatOp): string =
  case fmt
  of cfGbGameGenie: parse_gb_game_genie(line.strip(), op)
  of cfGbGameShark: parse_gb_gameshark(line.strip_code(), op)
  of cfGbaPar3, cfGbaRaw, cfGbaCbRaw:
    let (ops, err) = parse_gba_codes(line, fmt)
    if err.len == 0 and ops.len > 0: op = ops[0]
    err
  of cfAuto:        parse_line(platform, detect_format(platform, line), line, op)

proc parse_cheat*(platform: CheatPlatform; codes: string;
                  fmt: CheatFormat = cfAuto): tuple[ops: seq[CheatOp]; error: string] =
  ## Parse the full (possibly multi-line) code blob for one cheat. Any line may
  ## be its own code; blank lines and `#` comments are ignored.
  if platform == cpGBA:
    return parse_gba_codes(codes, fmt)
  for rawLine in codes.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let useFmt = if fmt == cfAuto: detect_format(platform, line) else: fmt
    var op: CheatOp
    let err = parse_line(platform, useFmt, line, op)
    if err.len > 0:
      return (@[], "\"" & line & "\": " & err)
    result.ops.add op

proc reparse*(engine: CheatEngine; cheat: var Cheat) =
  let (ops, err) = parse_cheat(engine.platform, cheat.codes, cheat.format)
  cheat.ops = ops
  cheat.error = err

# ---------------------------------------------------------------------------
# Applying RAM-write cheats (called once per emulated frame)
# ---------------------------------------------------------------------------

proc cond_read(mem: MemHooks; address: uint32; width: uint8): uint32 {.inline.} =
  case width
  of 1: uint32(mem.read8(address))
  of 2: uint32(mem.read16(address))
  else: mem.read32(address)

proc width_write(mem: MemHooks; address: uint32; value: uint32; width: uint8) {.inline.} =
  case width
  of 1: mem.write8(address, uint8(value))
  of 2: mem.write16(address, uint16(value))
  else: mem.write32(address, value)

proc cond_passes(cur, want: uint32; cmp: CheatCmp): bool {.inline.} =
  case cmp
  of ccEq:  cur == want
  of ccNe:  cur != want
  of ccLtU: cur <  want
  of ccGtU: cur >  want
  of ccLtS: cast[int32](cur) <  cast[int32](want)
  of ccGtS: cast[int32](cur) >  cast[int32](want)
  of ccAnd: (cur and want) != 0

proc apply_ram*(engine: CheatEngine; mem: MemHooks) =
  ## Apply every enabled cheat's per-frame RAM writes. A conditional op gates the
  ## `skip` ops that follow it within the same cheat when its compare fails.
  for cheat in engine.cheats:
    if not cheat.enabled or cheat.error.len > 0: continue
    var skip = 0
    for op in cheat.ops:
      if skip > 0:
        dec skip
        continue
      case op.action
      of caWrite8:  mem.write8(op.address, uint8(op.value))
      of caWrite16: mem.write16(op.address, uint16(op.value))
      of caWrite32: mem.write32(op.address, op.value)
      of caOr:  width_write(mem, op.address, cond_read(mem, op.address, op.width) or op.value, op.width)
      of caAnd: width_write(mem, op.address, cond_read(mem, op.address, op.width) and op.value, op.width)
      of caAdd: width_write(mem, op.address, cond_read(mem, op.address, op.width) + op.value, op.width)
      of caIndirect:
        # Follow the pointer stored at op.address, then write at ptr + offset.
        let target = mem.read32(op.address) + op.offset
        width_write(mem, target, op.value, op.width)
      of caCond:
        if not cond_passes(cond_read(mem, op.address, op.width), op.value, op.cmp):
          skip = int(op.skip)
      of caIfButtons:
        # KEYINPUT is active-low: a held button reads 0. Gate unless every button
        # in the mask is held.
        if (uint32(mem.read16(KEYINPUT_ADDRESS)) and op.value) != 0:
          skip = int(op.skip)
      of caRomPatch, caUnsupported: discard

# ---------------------------------------------------------------------------
# Applying ROM patches (Game Genie / GSA_PATCH), reversible for live toggling
# ---------------------------------------------------------------------------

proc rom_patch_offsets(rom_len: int; op: CheatOp): seq[int] =
  ## CPU addresses map to one or more ROM offsets. GB Game Genie addresses
  ## are 16-bit; GBA GSA_PATCH addresses are already absolute cart offsets.
  if op.address >= 0x08000000'u32:
    # GBA: address is 0x08000000-based into the ROM image.
    let off = int(op.address - 0x08000000'u32)
    if off < rom_len: result.add off
    return
  # GB Game Genie.
  let addr16 = int(op.address and 0xFFFF)
  if addr16 >= 0x8000: return  # not ROM
  if addr16 < 0x4000:
    if addr16 < rom_len: result.add addr16   # fixed bank 0
  else:
    let in_bank = addr16 - 0x4000
    var base = 0
    while base < rom_len:
      let o = base + in_bank
      if o < rom_len: result.add o
      base += 0x4000

proc revert_rom*(engine: CheatEngine; rom: var seq[byte]) =
  ## Restore any bytes a previous `apply_rom` displaced.
  for off, orig in engine.rom_backup:
    if off < rom.len: rom[off] = orig
  engine.rom_backup.clear()

proc apply_rom*(engine: CheatEngine; rom: var seq[byte]) =
  ## Revert previous patches, then apply all enabled ROM-patch cheats. Call this
  ## at load and whenever the cheat set changes.
  engine.revert_rom(rom)
  for cheat in engine.cheats:
    if not cheat.enabled or cheat.error.len > 0: continue
    for op in cheat.ops:
      if op.action != caRomPatch: continue
      let nbytes = max(1, int(op.width))   # GB Game Genie = 1, GBA patch = 2
      for base in rom_patch_offsets(rom.len, op):
        if op.compare >= 0 and int(rom[base]) != op.compare:
          continue  # Game Genie compare byte doesn't match this bank
        for i in 0 ..< nbytes:
          let off = base + i
          if off >= rom.len: break
          if not engine.rom_backup.hasKey(off):
            engine.rom_backup[off] = rom[off]
          rom[off] = byte(op.value shr (i * 8))

proc has_rom_patches*(engine: CheatEngine): bool =
  for cheat in engine.cheats:
    if cheat.enabled and cheat.error.len == 0:
      for op in cheat.ops:
        if op.action == caRomPatch: return true

# ---------------------------------------------------------------------------
# Persistence: a tiny sidecar text format (.cht), one cheat per block
# ---------------------------------------------------------------------------

proc serialize*(engine: CheatEngine): string =
  ## Write the cheat list as a simple, human-editable text file.
  for cheat in engine.cheats:
    result.add "[" & (if cheat.enabled: "x" else: " ") & "] " & cheat.name & "\n"
    for line in cheat.codes.splitLines():
      let l = line.strip()
      if l.len > 0: result.add l & "\n"
    result.add "\n"

proc deserialize*(engine: CheatEngine; text: string) =
  ## Inverse of `serialize`. Each `[x] name` header starts a new cheat; the
  ## following non-blank lines are its codes until the next header/blank run.
  engine.cheats.setLen(0)
  var cur: Cheat
  var have = false
  proc flush() =
    if have:
      cur.codes = cur.codes.strip()
      engine.reparse(cur)
      engine.cheats.add cur
    have = false
    cur = Cheat()
  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0: continue
    if line.len >= 3 and line[0] == '[' and line[2] == ']':
      flush()
      have = true
      cur.enabled = line[1] in {'x', 'X'}
      cur.name = (if line.len > 3: line[3 .. ^1].strip() else: "")
      cur.format = cfAuto
    elif have:
      if cur.codes.len > 0: cur.codes.add "\n"
      cur.codes.add line
  flush()
