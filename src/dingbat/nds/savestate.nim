## DS save states: the whole machine as one deterministic snapshot, for
## resume, state slots and rewind. Format: docs/nds/savestate.md.
##
## Container: common/serialize.nim's 32-byte header (core ckNDS, payload
## revision NDS_PAYLOAD_VERSION, the ROM identity below), the payload, and
## optionally a thumbnail trailer; `pack_state` deflates it for storage as it
## does GB/GBA states. The ROM, BIOS and firmware images are not stored: the
## loading machine supplies them.
##
## Payload. Every subsystem object is walked field by field in declaration
## order (`fieldPairs`), one generic rule per field type (below), so a plain
## field added to any of them is saved without touching this module. What
## is NOT saved is listed per object in the *_SKIP tables: references to
## other subsystems (each owned one is a section of its own), pointers and
## tables rebuilt from saved fields on load (`after_load`), per-frame
## renderer scratch, the host-side output queues and debug switches. A
## field of reference or pointer type that is in no skip table stops the
## build, so nothing is left out silently. The payload starts with a hash
## of this field walk (names and types), checked on load: a build whose
## layout differs refuses the state (srkIncompatible) instead of misreading
## it, even if NDS_PAYLOAD_VERSION was not bumped.
##
## Encodings: bool and char 1 byte, enums int32, `int`/`uint` 8 bytes
## (states move between 64-bit native and 32-bit wasm builds), fixed-width
## numbers and sets as their little-endian bytes, arrays element by element
## (numeric arrays as one block), seqs and Deques as a u32 count then their
## elements, objects as their fields.

import std/[deques, importutils, typetraits]
import ../common/serialize
import nds, sched, timing
import arm/[cpu, cp15]
import mem/vram
import gpu/[gpu, engine2d]
import gpu3d/[gpu3d, geometry, render]
import io/[irq, timers, ipc, divsqrt, dma, input, spi, cart, backup, spu, rtc, wifi]

export StateRejectKind, last_state_reject_kind, last_state_error, pack_state,
       unpack_state, parse_state_thumbnail

when cpuEndian == bigEndian:
  {.error: "DS save states copy numeric fields as little-endian bytes".}

const
  # Fields each object does not save. Everything else is saved.
  NDS_SKIP = [
    # owned subsystems: sections of their own (io_machine)
    "sched", "arm9", "arm7", "gpu", "gpu3d", "irq9", "irq7", "timers9", "timers7",
    "dma9", "dma7", "ipc", "divsqrt", "input", "spi", "cart", "spu", "rtc", "wifi",
    "tm",                        # its own section, without the derived tables
    "bios9", "bios7",            # supplied on load
    "hle_bios9", "hle_bios7",    # checked against the loading machine (preamble)
    "unmapped_log", "iolog", "watch", "io_last", "io_repeat"]   # debug logging
  CPU_SKIP = ["bus", "trace", "profiling", "profile", "cprofile"]
  # cachability by address and the cache enables: update_regions(cp15)
  TIMING_SKIP = ["ic_on", "dc_on", "icode", "idata", "ibuf", "mcode", "mdata", "mbuf"]
  GPU_SKIP = ["vram", "engine_a", "engine_b", "gpu3d"]
  # page tables, fast pointers and VRAMSTAT: remap() rebuilds them from cnt
  VRAM_SKIP = ["pages", "fast", "wfast", "zero", "vramstat"]
  # pointers into Gpu's palette/OAM (kept); line3d is set before each use
  ENGINE_SKIP = ["vram", "palette", "oam", "line3d"]
  GPU3D_SKIP = ["geo", "ren", "vram", "irq"]
  # Per-frame scratch: render_frame's clear() rewrites depth, IDs, flags and
  # coverage before anything reads them, `below` is written with every
  # coverage < 31 that reads it, the page pointers and `order` are rebuilt
  # per frame. `color` (the frame being shown) and `regs` are saved.
  RENDER_SKIP = ["depth", "opaque_id", "trans_id", "flags", "below", "aacov",
                 "tex_pages", "pal_pages", "zero_page", "mixed", "order"]
  TIMERS_SKIP = ["sched", "irq"]
  DMA_SKIP = ["irq"]
  IPC_SKIP = ["arm9", "arm7"]
  IPC_END_SKIP = ["irq"]
  DIVSQRT_SKIP = ["sched"]
  SPI_SKIP = ["firmware", "irq", "input", "sched"]   # firmware supplied on load
  CART_SKIP = ["rom", "irq9", "irq7", "sched", "backup", "spilog"]
  BACKUP_SKIP = ["dirty"]        # frontend bookkeeping; set after a load
  SPU_SKIP = ["samples"]         # host output queue, emptied on load
  # `sched` set = the clock follows emulated time: the loading frontend's
  # setting (ndsrun --rtc), not the state's
  RTC_SKIP = ["sched"]
  WIFI_SKIP = ["sched", "irq", "masks"]   # masks: constant per register
  NO_SKIP: array[0, string] = []

  # Seqs whose length varies at run time, with the longest a machine makes;
  # every other seq must match the loading machine's length.
  MMEM_PIXELS = 256 * 192

template var_seq_max(name: static string): int =
  when name == "events": 64                    # NdsScheduler: one per kind
  elif name == "buf": 0x4000                   # Cart: one ROMCTRL block
  elif name == "data": 16 * 1024 * 1024        # Backup: the save chip
  elif name == "detect": 64                    # Backup: bytes held in bkAuto
  elif name == "mmem": MMEM_PIXELS             # Engine2D: 0 or a whole frame
  elif name == "polys": MAX_POLYS              # Polygon RAM (either side)
  elif name == "verts": MAX_POLYS * 10         # clipped polygons: up to 10 each
  elif name == "fifo": 1 shl 20                # GX FIFO: unbounded behind a swap
  elif name == "q": 16                         # IPC FIFOs
  else: -1

# ---------------------------------------------------------------------------
# The three walkers: Saver writes, Loader reads back into a machine, Layout
# describes (its hash guards the format).

type
  Saver = object
    buf: string
    pos: int
  Loader = object
    data: ptr UncheckedArray[char]
    len, pos: int
  Layout = object
    text: string
    depth: int

proc put(s: var Saver; p: pointer; n: int) {.inline.} =
  if n == 0: return
  if s.pos + n > s.buf.len: s.buf.setLen(max(2 * s.buf.len, s.pos + n))
  copyMem(addr s.buf[s.pos], p, n)
  s.pos += n

proc get(l: var Loader; p: pointer; n: int) {.inline.} =
  if n == 0: return
  if l.len - l.pos < n: raise state_error("truncated DS state data", srkTruncated)
  copyMem(p, addr l.data[l.pos], n)
  l.pos += n

proc note(l: var Layout; name, kind: string) =
  for _ in 0 ..< l.depth: l.text.add "  "
  l.text.add name
  l.text.add ": "
  l.text.add kind
  l.text.add '\n'

template is_block(T: typedesc): bool =
  T is int8 or T is int16 or T is int32 or T is int64 or T is uint8 or
    T is uint16 or T is uint32 or T is uint64 or T is float32 or T is float64

proc io[S, T](s: var S; x: var T; name: static string)

proc set_is_clean[E](v: set[E]): bool =
  ## No bit set that names no element.
  var clean: set[E]
  for e in low(E) .. high(E):
    if e in v: clean.incl e
  equalMem(unsafeAddr clean, unsafeAddr v, sizeof(v))

proc enum_names(T: typedesc[enum]): string =
  ## The members with their ordinals: the stored int32 means nothing once
  ## a member moves, so the layout hash covers them.
  result = " {"
  for i in ord(low(T)) .. ord(high(T)):
    when T is HoleyEnum:
      var known = false
      for e in T:
        if ord(e) == i: known = true
      if not known: continue
    if result.len > 2: result.add ", "
    result.add $T(i) & "=" & $i
  result.add "}"

proc e_of_set[E](v: set[E]): E = low(E)
proc set_names[E](e: E): string = enum_names(E)

template walk(s, obj, skip: untyped) =
  for fname, f in fieldPairs(obj):
    when fname notin skip:
      io(s, f, fname)

proc io_seq_len[S](s: var S; cur: int; name: static string): int =
  ## A seq's or Deque's count: written, or read and checked.
  when S is Saver:
    var n = uint32(cur)
    s.put(addr n, 4)
    cur
  else:
    var n: uint32
    s.get(addr n, 4)
    const maxlen = var_seq_max(name)
    when maxlen < 0:
      if int(n) != cur:
        raise state_error("DS state field '" & name & "' has length " & $n &
                          ", this machine's is " & $cur)
    else:
      check_range(int(n), 0, maxlen, name)
    int(n)

proc io[S, T](s: var S; x: var T; name: static string) =
  when S is Layout:
    when T is (array or seq or Deque or object or tuple):
      var e: T     # walked once for its element/field types below
    when T is enum:
      s.note(name, $T & enum_names(T))
    elif T is set:
      s.note(name, $T & set_names(e_of_set(x)))
    else:
      s.note(name, $T)
  when T is (ref or ptr or pointer or proc or cstring or string):
    {.error: "DS save state: field '" & name & "' is a reference, pointer or " &
             "string; add it to its object's *_SKIP table and save what it " &
             "points to explicitly (nds/savestate.nim)".}
  elif T is bool:
    when S is Saver:
      var b = uint8(ord(x))
      s.put(addr b, 1)
    elif S is Loader:
      var b: uint8
      s.get(addr b, 1)
      x = b != 0
  elif T is enum:
    when S is Saver:
      var v = int32(ord(x))
      s.put(addr v, 4)
    elif S is Loader:
      var v: int32
      s.get(addr v, 4)
      check_range(int(v), ord(low(T)), ord(high(T)), name)
      x = T(v)
  elif T is int:
    when S is Saver:
      var v = int64(x)
      s.put(addr v, 8)
    elif S is Loader:
      var v: int64
      s.get(addr v, 8)
      if v < int64(low(int)) or v > int64(high(int)):
        raise state_error("DS state field '" & name & "' does not fit this build's int")
      x = int(v)
  elif T is uint:
    when S is Saver:
      var v = uint64(x)
      s.put(addr v, 8)
    elif S is Loader:
      var v: uint64
      s.get(addr v, 8)
      if v > uint64(high(uint)):
        raise state_error("DS state field '" & name & "' does not fit this build's uint")
      x = uint(v)
  elif is_block(T) or T is char:
    when S is Saver: s.put(addr x, sizeof(T))
    elif S is Loader: s.get(addr x, sizeof(T))
  elif T is set:
    when S is Saver: s.put(addr x, sizeof(T))
    elif S is Loader:
      var v: T
      s.get(addr v, sizeof(T))
      # no bit past the last element (the reader of a set iterates them all)
      if not set_is_clean(v):
        raise state_error("DS state field '" & name & "' has undefined bits set")
      x = v
  elif T is array:
    type E = typeof(x[low(x)])
    when S is Layout:
      inc s.depth
      io(s, e[low(e)], "[]")
      dec s.depth
    elif is_block(E):
      when S is Saver: s.put(addr x, sizeof(x))
      else: s.get(addr x, sizeof(x))
    else:
      for i in low(x) .. high(x): io(s, x[i], name)
  elif T is seq:
    type E = typeof(x[0])
    when S is Layout:
      var one: E
      inc s.depth
      io(s, one, "[]")
      dec s.depth
    else:
      let n = io_seq_len(s, x.len, name)
      when S is Loader: x.setLen(n)
      when is_block(E):
        if n > 0:
          when S is Saver: s.put(addr x[0], n * sizeof(E))
          else: s.get(addr x[0], n * sizeof(E))
      else:
        for i in 0 ..< n: io(s, x[i], name)
  elif T is Deque:
    type E = typeof(x.peekFirst)
    when S is Layout:
      var one: E
      inc s.depth
      io(s, one, "[]")
      dec s.depth
    elif S is Saver:
      discard io_seq_len(s, x.len, name)
      for i in 0 ..< x.len:
        var v = x[i]
        io(s, v, name)
    else:
      let n = io_seq_len(s, x.len, name)
      x.clear()
      for _ in 0 ..< n:
        var v: E
        io(s, v, name)
        x.addLast(v)
  elif T is (object or tuple):
    when S is Layout:
      inc s.depth
      walk(s, e, NO_SKIP)
      dec s.depth
    else:
      walk(s, x, NO_SKIP)
  else:
    {.error: "DS save state: no rule for field '" & name & "'".}

proc section[S](s: var S; tag: uint8; title: static string) =
  ## A marker byte between sections: a desynchronised read stops at the
  ## next one instead of loading garbage further on.
  when S is Saver:
    var t = tag
    s.put(addr t, 1)
  elif S is Loader:
    var t: uint8
    s.get(addr t, 1)
    if t != tag:
      raise state_error("DS state section " & title & " marker mismatch")
  else:
    s.depth = 0
    s.text.add "[" & $tag & " " & title & "]\n"

template obj_section(s, tag, title, x, skip: untyped) =
  section(s, uint8(tag), title)
  when typeof(s) is Layout: inc s.depth
  walk(s, x, skip)
  when typeof(s) is Layout: dec s.depth

proc io_machine[S](s: var S; n: NDS) =
  ## The payload after the preamble: one section per subsystem object.
  obj_section(s, 1, "machine (NDS)", n[], NDS_SKIP)
  obj_section(s, 2, "scheduler", n.sched[], NO_SKIP)
  obj_section(s, 3, "ARM9", n.arm9[], CPU_SKIP)
  obj_section(s, 4, "ARM7", n.arm7[], CPU_SKIP)
  obj_section(s, 5, "ARM9 memory timing (cache tags)", n.tm, TIMING_SKIP)
  obj_section(s, 6, "display (Gpu)", n.gpu[], GPU_SKIP)
  obj_section(s, 7, "VRAM", n.gpu.vram[], VRAM_SKIP)
  obj_section(s, 8, "2D engine A", n.gpu.engine_a[], ENGINE_SKIP)
  obj_section(s, 9, "2D engine B", n.gpu.engine_b[], ENGINE_SKIP)
  obj_section(s, 10, "3D engine (Gpu3d)", n.gpu3d[], GPU3D_SKIP)
  obj_section(s, 11, "3D geometry", n.gpu3d.geo[], NO_SKIP)
  obj_section(s, 12, "3D renderer", n.gpu3d.ren[], RENDER_SKIP)
  obj_section(s, 13, "ARM9 IRQ", n.irq9[], NO_SKIP)
  obj_section(s, 14, "ARM7 IRQ", n.irq7[], NO_SKIP)
  obj_section(s, 15, "ARM9 timers", n.timers9[], TIMERS_SKIP)
  obj_section(s, 16, "ARM7 timers", n.timers7[], TIMERS_SKIP)
  obj_section(s, 17, "ARM9 DMA", n.dma9[], DMA_SKIP)
  obj_section(s, 18, "ARM7 DMA", n.dma7[], DMA_SKIP)
  obj_section(s, 19, "IPC FIFOs", n.ipc[], IPC_SKIP)
  obj_section(s, 20, "IPC ARM9 side", n.ipc.arm9[], IPC_END_SKIP)
  obj_section(s, 21, "IPC ARM7 side", n.ipc.arm7[], IPC_END_SKIP)
  obj_section(s, 22, "DIV/SQRT", n.divsqrt[], DIVSQRT_SKIP)
  obj_section(s, 23, "input", n.input[], NO_SKIP)
  obj_section(s, 24, "SPI (power manager, firmware flash, touch)", n.spi[], SPI_SKIP)
  obj_section(s, 25, "card", n.cart[], CART_SKIP)
  obj_section(s, 26, "backup chip", n.cart.backup[], BACKUP_SKIP)
  obj_section(s, 27, "sound", n.spu[], SPU_SKIP)
  obj_section(s, 28, "RTC", n.rtc[], RTC_SKIP)
  obj_section(s, 29, "wifi", n.wifi[], WIFI_SKIP)
  section(s, 0xFF'u8, "end")

# ---------------------------------------------------------------------------
# Identity: the ROM in the header, the BIOS and layout in the preamble

const
  ROM_ID_HEADER = 0x200       ## the cartridge header
  ROM_ID_ARM9 = 0x10000       ## and the start of the ARM9 binary

proc rom_identity*(rom: openArray[uint8]): uint32 =
  ## fnv1a over the cartridge header (title, game code, version, the
  ## binaries' offsets and sizes, the header and secure-area CRCs) and the
  ## first 64 KB of the ARM9 binary it points to: different games and
  ## revisions differ here, and it costs microseconds per state (rewind).
  ## The header's rom_size field holds the file length beside it.
  if rom.len == 0: return 0x811C9DC5'u32    # fnv1a of nothing
  let h = min(rom.len, ROM_ID_HEADER)
  result = fnv1a(rom.toOpenArray(0, h - 1))
  if rom.len >= 0x30:
    let off = int(uint32(rom[0x20]) or (uint32(rom[0x21]) shl 8) or
                  (uint32(rom[0x22]) shl 16) or (uint32(rom[0x23]) shl 24))
    let size = int(uint32(rom[0x2C]) or (uint32(rom[0x2D]) shl 8) or
                   (uint32(rom[0x2E]) shl 16) or (uint32(rom[0x2F]) shl 24))
    if off >= ROM_ID_HEADER and off < rom.len:
      let last = min(rom.len, off + min(size, ROM_ID_ARM9)) - 1
      if last >= off: result = fnv1a_more(result, rom.toOpenArray(off, last))

var layout_hash_cache: uint32   ## 0 = not computed (plain global: wasm-safe)

proc state_layout*(n: NDS): string =
  ## The payload's field walk as text: every saved field with its type, by
  ## section (ndsrun --state-layout prints it; docs/nds/savestate.md).
  var l = Layout()
  io_machine(l, n)
  l.text

proc layout_hash(n: NDS): uint32 =
  if layout_hash_cache == 0:
    layout_hash_cache = fnv1a(state_layout(n)) or 1
  layout_hash_cache

proc bios_identity(n: NDS; arm9: bool): uint32 =
  if arm9: fnv1a(n.bios9) else: fnv1a(n.bios7)

const PREAMBLE_MAGIC = 0x5344_534E'u32   ## "NDSS"

proc write_preamble(s: var Saver; n: NDS) =
  var w = [PREAMBLE_MAGIC, n.layout_hash(),
           uint32(ord(n.hle_bios9)) or (uint32(ord(n.hle_bios7)) shl 1),
           n.bios_identity(true), n.bios_identity(false)]
  s.put(addr w[0], sizeof(w))

proc check_preamble(l: var Loader; n: NDS) =
  var w: array[5, uint32]
  l.get(addr w[0], sizeof(w))
  if w[0] != PREAMBLE_MAGIC:
    raise state_error("DS state payload has no preamble")
  if w[1] != n.layout_hash():
    raise state_error("DS state was made by a build whose DS state layout " &
                      "differs from this one's", srkIncompatible)
  for (arm9, name, hle_bit, hle) in [(true, "ARM9", 1'u32, n.hle_bios9),
                                     (false, "ARM7", 2'u32, n.hle_bios7)]:
    let state_hle = (w[2] and hle_bit) != 0
    if state_hle != hle:
      raise state_error("DS state was made with the " &
                        (if state_hle: "HLE" else: "real") & " " & name &
                        " BIOS, this machine runs the " &
                        (if hle: "HLE" else: "real") & " one", srkIncompatible)
    if w[if arm9: 3 else: 4] != n.bios_identity(arm9):
      raise state_error("DS state was made with a different " & name &
                        " BIOS image", srkIncompatible)

# ---------------------------------------------------------------------------
# Payload

proc state_payload*(n: NDS): string =
  ## The machine as payload bytes (no header): what rewind deltas compare.
  var s = Saver(buf: newString(8 * 1024 * 1024))
  s.write_preamble(n)
  io_machine(s, n)
  s.buf.setLen(s.pos)
  move(s.buf)

proc after_load(n: NDS) =
  ## Rebuild what the state leaves out, then refuse values the machine would
  ## index out of range with (a state is a stranger's file).
  n.gpu.vram.remap()
  n.tm.update_regions(n.cp15)
  privateAccess(Geometry)
  privateAccess(Gpu3d)
  privateAccess(Cart)
  privateAccess(Backup)
  privateAccess(Rtc)
  privateAccess(Spi)
  privateAccess(Wifi)
  privateAccess(NdsScheduler)
  let g = n.gpu3d.geo
  check_range(g.nbuf, 0, 3, "geometry.nbuf")
  check_range(n.gpu3d.ex_n, 0, 31, "gpu3d.ex_n")
  check_range(n.gpu3d.pk_left, 0, 32, "gpu3d.pk_left")
  let c = n.cart
  check_range(c.pos, 0, c.buf.len, "cart.pos")
  if (c.pos and 3) != 0 or (c.buf.len and 3) != 0:
    raise state_error("DS state card transfer is not word aligned")
  let b = c.backup
  check_range(b.id_idx, 0, high(int32), "backup.id_idx")
  check_range(b.addr_left, 0, 3, "backup.addr_left")
  check_range(b.dummy, 0, 1, "backup.dummy")
  check_range(n.rtc.count, 0, 7, "rtc.count")
  check_range(n.rtc.index, 0, 7, "rtc.index")
  check_range(n.rtc.bit, 0, 8, "rtc.bit")
  check_range(n.rtc.command, 0, 7, "rtc.command")
  check_range(n.spi.fid_idx, 0, high(int32), "spi.fid_idx")
  check_range(n.spi.pm_index, -1, 0xFF, "spi.pm_index")
  check_range(n.wifi.tx_loc, 0, 3, "wifi.tx_loc")
  for ch in n.spu.ch:
    check_range(ch.adpcm_index, 0, 88, "spu.adpcm_index")
    check_range(ch.loop_index, 0, 88, "spu.loop_index")
  for e in [n.gpu.engine_a, n.gpu.engine_b]:
    check_one_of(e.mmem.len, [0, MMEM_PIXELS], "engine.mmem")
    check_range(e.mmem_wr, 0, MMEM_PIXELS - 2, "engine.mmem_wr")
    if (e.mmem_wr and 1) != 0: raise state_error("DS state engine.mmem_wr is odd")
  check_range(n.gpu.vcount, 0, LINES - 1, "gpu.vcount")
  check_range(n.vcount_write, -1, LINES - 1, "vcount_write")
  var seen: set[NdsEvent]
  for e in n.sched.events:
    for name, f in e.fieldPairs:   # Pending is private to sched.nim
      when name == "kind":
        if f in seen: raise state_error("DS state books an event twice")
        seen.incl f

proc apply_payload(n: NDS; payload: string) =
  var l = Loader(data: cast[ptr UncheckedArray[char]](unsafeAddr payload[0]),
                 len: payload.len)
  l.check_preamble(n)
  io_machine(l, n)
  if l.pos != l.len: raise state_error("DS state payload has trailing bytes")
  n.after_load()

proc apply_new(n: NDS; payload: string) =
  ## A state replacing the running game: its sound queue goes (the samples
  ## were the old timeline's), and the save chip it carries is marked for
  ## the frontend to write out, as if the game had (as the GB/GBA cores do).
  n.apply_payload(payload)
  n.spu.clear_samples()
  n.cart.backup.dirty = true

# ---------------------------------------------------------------------------
# Images

const
  THUMB_W* = 128                ## both screens at half size, top above bottom
  THUMB_H* = 192

proc thumbnail(n: NDS): seq[byte] =
  var both = newSeq[uint16](256 * 384)
  for i in 0 ..< 256 * 192:
    both[i] = n.gpu.top[i]
    both[256 * 192 + i] = n.gpu.bottom[i]
  downscale_bgr555(both, 256, 384, THUMB_W, THUMB_H)

proc state_bytes*(n: NDS; thumbnail = false): string =
  ## The full plain state image: header, payload and (with `thumbnail`) a
  ## 128x192 BGR555 picture of both screens. What rewind and tests trade in
  ## memory; `pack_state` it for a file, a slot or the network.
  let payload = n.state_payload()
  let rom_id = rom_identity(n.cart.rom)
  if thumbnail:
    make_state_bytes(ckNDS, rom_id, uint32(n.cart.rom.len), payload,
                     n.thumbnail(), uint16(THUMB_W), uint16(THUMB_H))
  else:
    make_state_bytes(ckNDS, rom_id, uint32(n.cart.rom.len), payload)

proc save_state*(n: NDS; thumbnail = false): seq[uint8] =
  ## `state_bytes` as bytes.
  let s = n.state_bytes(thumbnail)
  result = newSeq[uint8](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc state_is_for*(n: NDS; data: string): bool =
  ## A DS state image (plain or packed) made for this game: what a slot
  ## list shows as loadable. Never raises.
  var img: string
  let kind = last_state_reject_kind
  try: img = unpack_state(data)
  except CatchableError: img = ""
  last_state_reject_kind = kind
  state_names_rom(img, ckNDS, rom_identity(n.cart.rom), uint32(n.cart.rom.len))

proc apply_checked(n: NDS; payload: string): bool =
  ## Apply a payload; on any refusal put the machine back as it was.
  let before = n.state_payload()
  let dirty = n.cart.backup.dirty
  try:
    n.apply_new(payload)
    last_state_reject_kind = srkNone
    return true
  except CatchableError, Defect:
    last_state_error = getCurrentExceptionMsg()
    if last_state_reject_kind == srkNone: last_state_reject_kind = srkCorrupt
    let kind = last_state_reject_kind
    restore_backup(n.apply_payload(before))
    n.cart.backup.dirty = dirty
    last_state_reject_kind = kind
    return false

proc load_state_payload*(n: NDS; payload: string): bool =
  ## Apply a bare payload (`state_payload`), for the in-memory snapshots
  ## of rewind and run-ahead: no header, ROM check or payload hash, so it
  ## costs about what saving does. The preamble (layout, BIOS) and every
  ## range guard still apply, and a refusal leaves the machine untouched.
  last_state_reject_kind = srkNone
  last_state_error = ""
  if payload.len == 0:
    last_state_error = "empty DS state payload"
    last_state_reject_kind = srkTruncated
    return false
  n.apply_checked(payload)

proc load_state_bytes*(n: NDS; data: string): bool =
  ## Validate and apply a state image (plain or packed). False on refusal,
  ## the machine untouched; `last_state_reject_kind` says why and
  ## `last_state_error` gives the detail.
  last_state_reject_kind = srkNone
  last_state_error = ""
  var payload: string
  try:
    let img = unpack_state(data)
    let (p, rev) = parse_state_payload(img, ckNDS, rom_identity(n.cart.rom),
                                       uint32(n.cart.rom.len), "DS state")
    if rev != NDS_PAYLOAD_VERSION:
      # no older DS revision exists to migrate from yet
      raise state_error("DS state payload revision " & $rev & " is not this " &
                        "build's (" & $NDS_PAYLOAD_VERSION & ")", srkIncompatible)
    if p.len == 0: raise state_error("DS state payload is empty")
    payload = p
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    return false
  n.apply_checked(payload)

proc load_state*(n: NDS; data: openArray[uint8]): bool =
  ## `load_state_bytes` for bytes.
  var s = newString(data.len)
  if data.len > 0: copyMem(addr s[0], unsafeAddr data[0], data.len)
  n.load_state_bytes(s)
