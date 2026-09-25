# Renderer contention (included by gba.nim, after ppu.nim)
#
# During active display the renderer reads palette RAM, VRAM and OAM on
# fixed dots of the line, and a CPU or DMA access that lands on one of them
# waits until the renderer lets go. Measured on an AGB SP with
# tests/roms/payloads/contmap.s: halt on a V-count match, wait k cycles,
# make ONE access, read a timer -- the wait at every dot of a line, for each
# memory, BG mode, layer set, fine scroll, blend and OBJ arrangement (the
# recorded cells are tools/hwlink/r0-agb.json "contmap"; c2seq.s and
# c2code.s hold whole access sequences and code run from VRAM to it). Dots
# below are this core's (0 = VCOUNT changes; the H-blank flag rises at
# 1007):
#
#   palette RAM   one read a pixel, dots 46 + 4x (x = 0..239); a second at
#                 48 + 4x under alpha blending; none in mode 3, and in mode
#                 5 only right of its 160-pixel bitmap
#   text BG n     per 8-pixel block, from base = 31 + 32b + n - 4*(HOFS & 7):
#                 the map entry at base, tile data at base+4 and base+20
#                 (4bpp) or base+4, +12, +20, +28 (8bpp); cont_text_bg says
#                 how many blocks
#   affine BG2    dots 33 + 4n and 34 + 4n (n = 0..242), then 1005
#   affine BG3    dots 31 + 4n and 32 + 4n (n = 0..243)
#   bitmap BG2    dots 34 + 4n (n = 0..242), modes 3, 4 and 5 alike
#   OBJ layer     OAM and OBJ VRAM by the OAM scan below; unlike the rest it
#                 keeps going under forced blank
#
# BG VRAM, OBJ VRAM, palette RAM and OAM are held independently: the OBJ
# layer never delays a BG VRAM access and the reverse. A 16-bit memory
# serves a 32-bit access as two halfwords, each waiting on its own dot (a
# VRAM word measured; palette RAM's assumed alike); OAM, 32 bits wide, serves
# a word in one access. Code fetched from these memories waits like data,
# the refill after a branch included (cpu.nim contend_refill).
#
# Cost: bus.access_cycles asks bus.contend_cost only for pages 5-7 while
# Bus.contended has them (lines 0-159 and 227, display on or OBJ on); the
# common palette/BG case is answered there from the map, the rest here.

const CONT_DOTS = CONT_WORDS * 32

# Every index below is bounded by construction (dots are range-checked where
# they are set and scanned), and this is the path every contended access
# takes: no runtime checks.
{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

proc cont_clear(m: var array[CONT_WORDS, uint32]) {.inline.} =
  for i in 0 ..< CONT_WORDS: m[i] = 0

proc cont_set(m: var array[CONT_WORDS, uint32]; dot: int) {.inline.} =
  if dot >= 0 and dot < CONT_DOTS:
    m[dot shr 5] = m[dot shr 5] or (1'u32 shl (dot and 31))

proc cont_next_free(m: array[CONT_WORDS, uint32]; t: int): int {.inline.} =
  ## The first dot at or after t the renderer does not hold (t < CONT_DOTS);
  ## past the map's end everything is free.
  if t >= CONT_DOTS: return t
  var i = t shr 5
  var w = (not m[i]) and (0xFFFFFFFF'u32 shl (t and 31))
  while w == 0:
    inc i
    if i >= CONT_WORDS: return CONT_DOTS
    w = not m[i]
  (i shl 5) + countTrailingZeroBits(w)

proc cont_text_bg(m: var array[CONT_WORDS, uint32]; n: int; bpp8: bool; hofs: int) =
  # A fine scroll starts the fetch 4 dots a pixel earlier. The blocks run on
  # while their map read is due by dot 1003 (BG0's frame); a block's tile
  # reads happen only if its map read is due by 999. Fine scroll 0-4 fetch
  # 31 blocks, 5 fetches the 32nd's map entry alone, 6 and 7 all of it
  # (contmap scenes 06, 15-17, 2C-2F, 38-3B; BG1 and 8bpp alike).
  const TEXT_LAST_MAP = 1003
  const TEXT_LAST_TILES = 999
  let first = 31 + n - 4 * (hofs and 7)
  var b = 0
  while true:
    let base = first + 32 * b
    if base - n > TEXT_LAST_MAP: break
    m.cont_set(base)
    if base - n <= TEXT_LAST_TILES:
      m.cont_set(base + 4)
      m.cont_set(base + 20)
      if bpp8:
        m.cont_set(base + 12)
        m.cont_set(base + 28)
    inc b

proc cont_build_bg(ppu: PPU; key: uint32) =
  ppu.cont_bg.cont_clear()
  ppu.cont_bg_key = key
  if ppu.dispcnt.forced_blank: return
  let en = (uint16(ppu.dispcnt) shr 8) and 0xF
  case int(ppu.dispcnt.bg_mode)
  of 0, 1:
    let texts = if ppu.dispcnt.bg_mode == 0: 4 else: 2
    for n in 0 ..< texts:
      if bit(en, n):
        ppu.cont_bg.cont_text_bg(n, ppu.bgcnt[n].color_mode_8bpp,
                                 int(ppu.bghofs[n].offset))
    if ppu.dispcnt.bg_mode == 1 and bit(en, 2):
      for n in 0 .. 242:
        ppu.cont_bg.cont_set(33 + 4 * n)
        ppu.cont_bg.cont_set(34 + 4 * n)
      ppu.cont_bg.cont_set(1005)
  of 2:
    if bit(en, 2):
      for n in 0 .. 242:
        ppu.cont_bg.cont_set(33 + 4 * n)
        ppu.cont_bg.cont_set(34 + 4 * n)
      ppu.cont_bg.cont_set(1005)
    if bit(en, 3):
      for n in 0 .. 243:
        ppu.cont_bg.cont_set(31 + 4 * n)
        ppu.cont_bg.cont_set(32 + 4 * n)
  of 3, 4, 5:
    if bit(en, 2):
      for n in 0 .. 242:
        ppu.cont_bg.cont_set(34 + 4 * n)
  else: discard

proc cont_bg_key_now(ppu: PPU): uint32 {.inline.} =
  var k = uint32(uint16(ppu.dispcnt) and 0x0F87'u16)
  for n in 0 .. 3:
    if ppu.bgcnt[n].color_mode_8bpp: k = k or (1'u32 shl (16 + n))
    k = k or ((uint32(ppu.bghofs[n].offset) and 7) shl (20 + 3 * n))
  k

proc cont_pram_key_now(ppu: PPU): uint32 {.inline.} =
  # Alpha blending with a second target reads a second palette entry a
  # pixel (contmap scene 19; no second read with the effect off, scene 1A)
  let bld = uint16(ppu.bldcnt)
  let alpha = ((bld shr 6) and 3) == 1 and (bld and 0x3F00'u16) != 0
  uint32(uint16(ppu.dispcnt) and 0x0087'u16) or (if alpha: 0x100'u32 else: 0'u32)

proc cont_build_pram(ppu: PPU; key: uint32) =
  ppu.cont_pram.cont_clear()
  ppu.cont_pram_key = key
  if ppu.dispcnt.forced_blank: return
  # Mode 3 reads no palette; mode 5 only for the backdrop right of its
  # 160-pixel bitmap (contmap scenes 0B, 14)
  let mode = int(ppu.dispcnt.bg_mode)
  if mode == 3: return
  for x in (if mode == 5: 160 else: 0) .. 239:
    ppu.cont_pram.cont_set(46 + 4 * x)
    if (key and 0x100'u32) != 0: ppu.cont_pram.cont_set(48 + 4 * x)

# ---- the OBJ layer ----
#
# During line L the OBJ layer fetches line L+1 (lines 227 and 0-158), from
# dot 40 until dot 1272 (the next line's 40), or 1000 with H-Blank Interval
# Free; nothing it would do from there on happens. contmap scenes 1B-2B:
#
#   OAM scan   entry i's first word (attr0/1) at an even dot, 2 dots an
#              entry, from dot 40; an entry not on the line costs just that
#   a sprite   found at dot p: its second word (attr2) at W = p + 2;
#              regular: VRAM from W + 2, one read every 2 dots, width/2
#              reads; affine: the four parameters at W+2..W+8, VRAM from
#              W + 12, one read every 2 dots, one read a drawn pixel
#   look-ahead the next entry's first word is read as the sprite starts
#              (regular: at its first VRAM read; affine: at W + 10), and
#              the scan then waits for the sprite's last VRAM read, L. If
#              that entry is on the line its second word is read at L and
#              its VRAM starts at L + 2 (so sprites follow back to back);
#              if not, the scan resumes with the entry after it at L.
#
# The renderer draws from its own latched OAM view; this reads live OAM,
# as the scan does.

const OBJ_SCAN_START = 40

proc cont_obj_on_line(sp: ptr UncheckedArray[Sprite]; e, target: int): bool {.inline.} =
  let s = sp[e]
  if (s.attr0 and 0x0300'u16) == 0x0200'u16: return false  # disabled
  let g = obj_geometry(s)
  g.h > 0 and g.y <= target and target < g.y + g.h

proc cont_build_obj(ppu: PPU; line: int; key: int64) =
  ppu.cont_objv.cont_clear()
  ppu.cont_oam.cont_clear()
  ppu.cont_obj_key = key
  # Forced blank stops the BG layers and the palette reads, not the OBJ
  # layer: with OBJ on, OBJ VRAM and OAM are held as in a drawn frame
  # (contmap scene 04, DISPCNT 0x1F80)
  if not bit(uint16(ppu.dispcnt), 12): return
  if not (line == 227 or line < 159): return
  let target = (line + 1) mod 228
  let limit = if ppu.dispcnt.hblank_interval_free: 1000 else: 1272
  let sp = cast[ptr UncheckedArray[Sprite]](addr ppu.oam[0])
  template oam_at(t: int) =
    if t < limit: ppu.cont_oam.cont_set(t)
  var p = OBJ_SCAN_START
  var i = 0
  var done = false
  while not done and i < 128 and p < limit:
    oam_at(p)
    if not sp.cont_obj_on_line(i, target):
      p += 2
      inc i
      continue
    var e = i
    var w = p + 2
    while true:
      oam_at(w)
      let s = sp[e]
      let g = obj_geometry(s)
      var v, look, n: int
      if bit(s.attr0, 8):
        for j in 1 .. 4: oam_at(w + 2 * j)
        look = w + 10
        v = w + 12
        n = g.w
      else:
        look = w + 2
        v = w + 2
        n = g.w shr 1
      for j in 0 ..< max(n, 1):
        if v + 2 * j >= limit: break
        ppu.cont_objv.cont_set(v + 2 * j)
      let last = v + 2 * (max(n, 1) - 1)
      if e == 127:
        done = true
        break
      oam_at(look)
      if sp.cont_obj_on_line(e + 1, target):
        # its second word is read at `last` even when the limit cut this
        # sprite short (scene 03: OAM at 1002 with H-blank free), and
        # nothing after it happens
        if last >= limit:
          if last < limit + 4: ppu.cont_oam.cont_set(last)
          done = true
          break
        inc e
        w = last
      else:
        p = last
        i = e + 2
        break

proc cont_obj_free(ppu: PPU; want_oam: bool; line, t: int): int =
  ## The first dot at or after t the OBJ layer does not hold OAM / OBJ VRAM;
  ## both relative to `line`'s start. Dots 0-39 of a line still belong to
  ## the previous line's fetch.
  var l = line
  var d = t
  var base = 0
  while d >= 1232:
    l = (l + 1) mod 228
    d -= 1232
    base += 1232
  if d < OBJ_SCAN_START:
    l = (l + 227) mod 228
    d += 1232
    base -= 1232
  for hop in 0 .. 2:
    # OAM writes clear the key (ppu.oam_touched)
    let key = (int64(l) shl 8) or int64((uint16(ppu.dispcnt) shr 5) and 0xFF)
    if key != ppu.cont_obj_key: ppu.cont_build_obj(l, key)
    let f = if want_oam: ppu.cont_oam.cont_next_free(d)
            else: ppu.cont_objv.cont_next_free(d)
    if f < 1232 + OBJ_SCAN_START:
      return base + f
    # ran into the next line's fetch
    l = (l + 1) mod 228
    d = f - 1232
    base += 1232
  base + d

proc contend_wait(bus: Bus; address: uint32; is32: bool; cost: int): int =
  ## Cycles an access to palette RAM, VRAM or OAM that started `cost` cycles
  ## ago waits for the renderer.
  if address >= 0x10000000'u32: return 0
  let ppu {.cursor.} = bus.gba.ppu
  let page = int(bits_range(address, 24, 27))
  var dot = int(int64(bus.sched.cycles) + int64(bus.cycles - cost) - ppu.line_start_cycle)
  var line = int(ppu.vcount)
  while dot >= 1232:
    dot -= 1232
    line = if line == 227: 0 else: line + 1
  if dot < 0: return 0
  var obj = page == 7
  if page == 6:
    var a = address and 0x1FFFF'u32
    if a > 0x17FFF'u32: a -= 0x8000'u32
    obj = a >= (if ppu.dispcnt.bg_mode >= 3: 0x14000'u32 else: 0x10000'u32)
  let halves = if is32 and page != 7: 2 else: 1
  var t = dot
  if obj:
    for h in 0 ..< halves:
      let f = ppu.cont_obj_free(page == 7, line, t)
      result += f - t
      t = f + 1
    return
  if line >= 160: return 0
  if ppu.cont_regs_stale:
    # A register the maps depend on was written since they were keyed
    ppu.cont_regs_stale = false
    let pk = ppu.cont_pram_key_now()
    if pk != ppu.cont_pram_key: ppu.cont_build_pram(pk)
    let bk = ppu.cont_bg_key_now()
    if bk != ppu.cont_bg_key: ppu.cont_build_bg(bk)
  if page == 5:
    for h in 0 ..< halves:
      let f = ppu.cont_pram.cont_next_free(t)
      result += f - t
      t = f + 1
  else:
    for h in 0 ..< halves:
      let f = ppu.cont_bg.cont_next_free(t)
      result += f - t
      t = f + 1

proc contend_slow(bus: Bus; address: uint32; is32: bool; cost: int): int {.noinline, raises: [].} =
  ## bus.contend_cost's way out: an access starting now, the whole question
  cost + bus.contend_wait(address, is32, 0)

{.pop.}
