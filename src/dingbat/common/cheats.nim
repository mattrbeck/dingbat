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
##     * Action Replay v3 / GameShark v3   XXXXXXXX YYYYYYYY  (encrypted, the
##       "PARv3" format) — TEA cipher + PARv3 opcode table. Simple RAM writes and
##       conditionals are applied; hook / button / indirect / slowdown codes are
##       parsed but not executed.
##     * CodeBreaker / short GameShark   82XXXXXX YYYY  (8+4, unencrypted) — the
##       common Pokémon item/money form; writes + conditionals honoured.
##     * "raw" (already-decrypted) PARv3 words, when the cheat is flagged raw.
##
## Applied: writes (8/16/32), read-modify-write (OR/AND/ADD), conditionals,
## pointer/indirect writes, button activators (PARv3 BUTTON, default L+R combo),
## and ROM patches (Game Genie + PARv3 PATCH = walk-through-walls).
##
## Not supported: encrypted CodeBreaker, GameShark-v1 (GSAv1) seeds, DEADFACE
## reseed, fill-lists, nested if-blocks, and true code hooks (op1>>24==0xC4 —
## these execute injected ARM, which a per-frame poke engine cannot do).
##
## Formats: Pan Docs "Game Genie/Shark Cheats" (GB), Frohwein's Game Genie
## page (GB compare-byte encoding), GBATEK "GBA Cheat Devices" (PARv3 opcode
## layout); the PARv3 cipher is TEA with the published PARv3 seeds.

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
  var ok: bool
  let raw = parse_hex_exact(code, 8, ok)
  if not ok: return "GameShark code must be 8 hex digits (TTDDAAAA)"
  # Address bytes are stored little-endian in the code, then byte-swapped.
  # The leading two digits are the SRAM bank (Pan Docs, Shark Cheats:
  # `010238CD` = bank $01, value $02, address $CD38). GB addresses are 16-bit,
  # so the bank rides bits 16-23 of `address` for the core's write hook to
  # decode — only an $A000-BFFF target consults it.
  op.action = caWrite8
  op.address = ((raw and 0xFF) shl 8) or ((raw shr 8) and 0xFF) or
               (((raw shr 24) and 0xFF) shl 16)
  op.value = (raw shr 16) and 0xFF
  op.compare = -1
  return ""

# ---------------------------------------------------------------------------
# GBA Action Replay v3 / GameShark v3 (PARv3): TEA-encrypted 64-bit codes,
# opcode layout per GBATEK "GBA Cheat Devices".
# ---------------------------------------------------------------------------

# PARv3 (the common Pokémon-era format) uses these fixed seeds. A code list's
# master line decrypts to the game id + the 0x001DC0DE verification marker.
const PAR3_SEEDS: array[4, uint32] =
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

# PARv3 opcode fields of the decrypted first word (GBATEK "GBA Cheat Devices")
const
  PAR3_COND       = 0x38000000'u32
  PAR3_WIDTH_MASK = 0x06000000'u32
  PAR3_WIDTH_BASE = 25
  PAR3_ACTION     = 0xC0000000'u32
  PAR3_BASE_MASK  = 0xC0000000'u32
  PAR3_BASE_ASSIGN   = 0x00000000'u32
  PAR3_BASE_INDIRECT = 0x40000000'u32
  PAR3_BASE_ADD      = 0x80000000'u32

# GBA KEYINPUT register (16-bit, active-low: a held button reads 0). Button
# activators read this to gate a cheat on a held combo.
const GBA_KEYINPUT = 0x04000130'u32
# Default activation combo for button codes that don't name one: L+R.
const GBA_BTN_L = 0x0200'u32
const GBA_BTN_R = 0x0100'u32

proc par3_addr(x: uint32): uint32 {.inline.} =
  ## Low 20 bits are the offset; bits 20-23 become the region nibble (24-27).
  (x and 0xFFFFF'u32) or ((x shl 4) and 0x0F000000'u32)

proc par3_width_bytes(op1: uint32): int {.inline.} =
  1 shl int((op1 and PAR3_WIDTH_MASK) shr PAR3_WIDTH_BASE)   # 1 / 2 / 4 / (8=invalid)

proc write_action(width: int): CheatAction {.inline.} =
  case width
  of 1: caWrite8
  of 2: caWrite16
  else: caWrite32

proc par3_interpret(op1, op2: uint32; op: var CheatOp): string =
  ## Decrypted PARv3 (op1, op2) -> a CheatOp. Only the code classes a per-frame
  ## poke engine can honour (writes + conditionals) are applied; hook / button /
  ## indirect / IO / slowdown / patch-list codes are recognised but marked
  ## unsupported so they no-op instead of corrupting memory.
  op.compare = -1
  if op2 == 0x001DC0DE'u32:
    op.action = caUnsupported     # master / game-id verification line — no-op
    return ""
  if op1 == 0x00000000'u32 or op1 == 0xDEADFACE'u32:
    op.action = caUnsupported     # special block / reseed — not executed
    return ""
  if (op1 shr 24) == 0xC4:
    op.action = caUnsupported     # code hook (executes injected asm) — can't poke
    return ""
  let width = par3_width_bytes(op1)
  if width > 4:
    op.action = caUnsupported
    return ""
  if (op1 and PAR3_COND) != 0:
    # Conditional: compare [addr] (width) to op2, gate the following ops.
    op.action = caCond
    op.address = par3_addr(op1)
    op.width = uint8(width)
    op.value = op2 and (0xFFFFFFFF'u32 shr uint32((4 - width) * 8))
    op.cmp = case op1 and PAR3_COND
      of 0x08000000'u32: ccEq
      of 0x10000000'u32: ccNe
      of 0x18000000'u32: ccLtS
      of 0x20000000'u32: ccGtS
      of 0x28000000'u32: ccLtU
      of 0x30000000'u32: ccGtU
      else:              ccAnd    # 0x38000000
    op.skip = case op1 and PAR3_ACTION
      of 0x00000000'u32: 1'u8     # NEXT
      of 0x40000000'u32: 2'u8     # NEXT_TWO
      else:              1'u8     # BLOCK/DISABLE approximated as skip-1
    return ""
  op.address = par3_addr(op1)
  op.value = op2 and (0xFFFFFFFF'u32 shr uint32((4 - width) * 8))
  op.width = uint8(width)
  case op1 and PAR3_BASE_MASK
  of PAR3_BASE_ASSIGN:
    op.action = write_action(width)
  of PAR3_BASE_ADD:
    op.action = caAdd
  of PAR3_BASE_INDIRECT:
    # Write to *[address] + offset; the offset rides op2's bytes above the
    # value: offset = (op2 >> (width*8)) * width for width < 4, else 0.
    op.action = caIndirect
    op.offset = (if width < 4: (op2 shr uint32(width * 8)) * uint32(width) else: 0'u32)
  else:                        # OTHER(IO) — not honoured by a poke engine
    op.action = caUnsupported
  return ""

proc parse_gba_line(code: string; raw: bool; op: var CheatOp): string =
  ## One "XXXXXXXX YYYYYYYY" line -> one CheatOp (decrypting unless raw).
  let toks = code.strip_code()
  if toks.len != 16:
    return "GBA code must be two 8-digit words (XXXXXXXX YYYYYYYY)"
  var ok: bool
  var op1 = parse_hex_exact(toks[0 ..< 8], 8, ok)
  if not ok: return "bad hex in first word"
  var op2 = parse_hex_exact(toks[8 ..< 16], 8, ok)
  if not ok: return "bad hex in second word"
  if not raw:
    gba_gs_decrypt(op1, op2, PAR3_SEEDS)
  return par3_interpret(op1, op2, op)

# ---------------------------------------------------------------------------
# GBA raw CodeBreaker / short GameShark  (TXXXXXXX YYYY, unencrypted)
# The common Pokémon item/money code form, e.g. 82025840 0044. Type in the top
# nibble; opcode meanings per GBATEK, "GBA Cheat Codes - CodeBreaker".
# ---------------------------------------------------------------------------

proc parse_gba_cb_raw(code: string; op: var CheatOp): string =
  let toks = code.strip_code()
  if toks.len != 12:
    return "CodeBreaker code must be 8+4 hex (XXXXXXXX YYYY)"
  var ok: bool
  let op1 = parse_hex_exact(toks[0 ..< 8], 8, ok)
  if not ok: return "bad hex in address word"
  let val = parse_hex_exact(toks[8 ..< 12], 4, ok)
  if not ok: return "bad hex in value"
  let address = op1 and 0x0FFFFFFF'u32
  op.address = address
  op.compare = -1
  case op1 shr 28
  of 0x3:                                  # CB_ASSIGN_1 (8-bit write)
    op.action = caWrite8;  op.value = val and 0xFF
  of 0x8:                                  # CB_ASSIGN_2 (16-bit write)
    op.action = caWrite16; op.value = val and 0xFFFF
  of 0x2:                                  # CB_OR_2 (16-bit OR)
    op.action = caOr;  op.width = 2; op.value = val and 0xFFFF
  of 0x6:                                  # CB_AND_2 (16-bit AND)
    op.action = caAnd; op.width = 2; op.value = val and 0xFFFF
  of 0xE:                                  # CB_ADD_2 (16-bit ADD)
    op.action = caAdd; op.width = 2; op.value = val and 0xFFFF
  of 0x7, 0xA, 0xB, 0xC, 0xF:              # conditionals (gate next line)
    op.action = caCond
    op.width = 2
    op.value = val and 0xFFFF
    op.skip = 1
    op.cmp = case op1 shr 28
      of 0x7: ccEq      # CB_IF_EQ
      of 0xA: ccNe      # CB_IF_NE
      of 0xB: ccGtU     # CB_IF_GT
      of 0xC: ccLtU     # CB_IF_LT
      else:   ccAnd     # 0xF CB_IF_AND
  of 0x0, 0x9:                             # game-id / encrypt marker — inert
    op.action = caUnsupported
  else:                                    # hook / fill / special — not honoured
    op.action = caUnsupported
  return ""

# ---------------------------------------------------------------------------
# Format detection + top-level parse of one cheat's (multi-line) code text
# ---------------------------------------------------------------------------

proc detect_format(platform: CheatPlatform; line: string): CheatFormat =
  case platform
  of cpGB:
    if '-' in line: cfGbGameGenie
    else: cfGbGameShark
  of cpGBA:
    # 8+8 hex = encrypted PARv3; 8+4 hex = raw CodeBreaker/short GameShark.
    if line.strip_code().len == 12: cfGbaCbRaw
    else: cfGbaPar3

proc parse_line(platform: CheatPlatform; fmt: CheatFormat; line: string;
                op: var CheatOp): string =
  case fmt
  of cfGbGameGenie: parse_gb_game_genie(line.strip(), op)
  of cfGbGameShark: parse_gb_gameshark(line.strip_code(), op)
  of cfGbaPar3:     parse_gba_line(line, raw = false, op)
  of cfGbaRaw:      parse_gba_line(line, raw = true, op)
  of cfGbaCbRaw:    parse_gba_cb_raw(line, op)
  of cfAuto:        parse_line(platform, detect_format(platform, line), line, op)

proc par3_plausible(op1, op2: uint32): bool =
  ## Does a (op1, op2) pair look like a valid decrypted PARv3 code? Used to
  ## auto-decide whether an 8+8 line is encrypted (decrypt) or already raw.
  ## Real codes are either a recognised special or a write/cond whose target
  ## lands in EWRAM/IWRAM; ciphertext read as raw almost never does.
  if op2 == 0x001DC0DE'u32: return true       # game-id verification
  if op1 == 0x00000000'u32: return true       # special block
  if op1 == 0xDEADFACE'u32: return true       # reseed
  if (op1 shr 24) == 0xC4: return true         # code hook
  let region = (par3_addr(op1) shr 24) and 0xF'u32
  region == 0x2 or region == 0x3               # EWRAM / IWRAM write or compare

proc gba_stream_is_encrypted(codes: string): bool =
  ## Peek the first 8+8 line: if decrypting it yields a plausible PARv3 code,
  ## treat the whole stream as encrypted; otherwise it's raw.
  for rawLine in codes.splitLines():
    let s = rawLine.strip().strip_code()
    if s.len != 16: continue
    var ok: bool
    var d1 = parse_hex_exact(s[0 ..< 8], 8, ok)
    if not ok: continue
    var d2 = parse_hex_exact(s[8 ..< 16], 8, ok)
    if not ok: continue
    let r1 = d1
    let r2 = d2
    gba_gs_decrypt(d1, d2, PAR3_SEEDS)
    if par3_plausible(d1, d2): return true      # decrypts cleanly -> encrypted
    if par3_plausible(r1, r2): return false     # already valid raw -> raw
    return true                                 # ambiguous: default to encrypted
  return true

proc parse_gba_blob(codes: string; forced: CheatFormat):
    tuple[ops: seq[CheatOp]; error: string] =
  ## GBA needs whole-blob parsing because PARv3 ROM-patch codes (the mechanism
  ## behind walk-through-walls) span two lines: an `op1==0` PATCH line gives the
  ## ROM address, and the following line's decrypted op1 is the patch value.
  ##
  ## Encrypted-vs-raw is auto-detected (see gba_stream_is_encrypted) unless the
  ## caller pins cfGbaPar3 (always decrypt) or cfGbaRaw (never decrypt).
  let decrypt =
    case forced
    of cfGbaRaw:  false
    of cfGbaPar3: true
    else:         gba_stream_is_encrypted(codes)
  # Some PARv3 codes span two lines: the first sets up an operation whose value
  # comes from the second line's op1. pk_none / pk_patch (ROM patch) / pk_write
  # (button-gated RAM write).
  var pk = 0   # 0=none, 1=patch, 2=write
  var pend_addr: uint32
  var pend_width: uint8
  template fail(line, msg: string): untyped = return (@[], "\"" & line & "\": " & msg)
  for rawLine in codes.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let s = line.strip_code()
    let is_cb = forced == cfGbaCbRaw or (forced == cfAuto and s.len == 12)
    if is_cb:
      var op: CheatOp
      let err = parse_gba_cb_raw(line, op)
      if err.len > 0: fail(line, err)
      result.ops.add op
      continue
    if s.len != 16:
      fail(line, "GBA code must be 8+8 (XXXXXXXX YYYYYYYY) or 8+4 (XXXXXXXX YYYY) hex")
    var ok: bool
    var op1 = parse_hex_exact(s[0 ..< 8], 8, ok)
    if not ok: fail(line, "bad hex in first word")
    var op2 = parse_hex_exact(s[8 ..< 16], 8, ok)
    if not ok: fail(line, "bad hex in second word")
    if decrypt:
      gba_gs_decrypt(op1, op2, PAR3_SEEDS)
    if pk != 0:
      # This line supplies the pending operation's value (in op1).
      let mask = 0xFFFFFFFF'u32 shr uint32((4 - int(pend_width)) * 8)
      if pk == 1:                      # ROM patch value
        result.ops.add CheatOp(action: caRomPatch, address: pend_addr,
                               value: op1 and mask, width: pend_width, compare: -1)
      else:                            # button-gated RAM write value
        result.ops.add CheatOp(action: write_action(int(pend_width)),
                               address: pend_addr, value: op1 and mask,
                               width: pend_width, compare: -1)
      pk = 0
      continue
    if op1 == 0x00000000'u32:
      # PARv3 "special" (op2 top byte selects it):
      #   0x18/1A/1C/1E  PATCH_1..4  -> begin a ROM patch (value on next line)
      #   0x10/12/14     BUTTON_1/2/4 -> gate a RAM write (value on next line) on
      #                  a held button combo (default L+R; the code names no combo)
      # Everything else (fill, slowdown, endif/else) is recognised but not run.
      let sub = op2 and 0xFF000000'u32
      if sub == 0x18000000'u32 or sub == 0x1A000000'u32 or
         sub == 0x1C000000'u32 or sub == 0x1E000000'u32:
        pk = 1
        pend_addr = 0x08000000'u32 or ((op2 and 0xFFFFFF'u32) shl 1)
        pend_width = 2
      elif sub == 0x10000000'u32 or sub == 0x12000000'u32 or sub == 0x14000000'u32:
        pk = 2
        pend_addr = par3_addr(op2)
        pend_width = (if sub == 0x10000000'u32: 1'u8
                      elif sub == 0x12000000'u32: 2'u8 else: 4'u8)
        # Gate the write that the next line will emit.
        result.ops.add CheatOp(action: caIfButtons, value: GBA_BTN_L or GBA_BTN_R,
                               skip: 1)
      else:
        result.ops.add CheatOp(action: caUnsupported)
      continue
    var op: CheatOp
    let err = par3_interpret(op1, op2, op)
    if err.len > 0: fail(line, err)
    result.ops.add op

proc parse_cheat*(platform: CheatPlatform; codes: string;
                  fmt: CheatFormat = cfAuto): tuple[ops: seq[CheatOp]; error: string] =
  ## Parse the full (possibly multi-line) code blob for one cheat. Any line may
  ## be its own code; blank lines and `#` comments are ignored.
  if platform == cpGBA:
    return parse_gba_blob(codes, fmt)
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
        if (uint32(mem.read16(GBA_KEYINPUT)) and op.value) != 0:
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
