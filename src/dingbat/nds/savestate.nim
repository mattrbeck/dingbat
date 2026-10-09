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

import std/[deques, importutils, strutils, typetraits]
import ../common/serialize
from ../gba/storage_chip import StorageType, FlashStateFlag, storage_bytes
import nds, sched, timing
import arm/[cpu, cp15]
import mem/vram
import gpu/[gpu, engine2d]
import gpu3d/[gpu3d, geometry, render]
import io/[irq, timers, ipc, divsqrt, dma, input, spi, cart, backup, spu, rtc, wifi,
           mic, slot2]

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
    "slot2", "tm",                        # its own section, without the derived tables
    "bios9", "bios7",            # supplied on load
    "hle_bios9", "hle_bios7",    # checked against the loading machine (preamble)
    "unmapped_log", "iolog", "watch", "io_last", "io_repeat",   # debug logging
    "idle_epoch", "idle_epoch9", "idle_epoch7", "ev_epoch", "dev9", "dev7",   # idle-loop skipping (arm/cpu.nim), re-proved after a load
    "fline9", "fptr9", "fitcm9", "fpage7", "fptr7", "fseq7", "fjump7",   # fetch fast paths, off after a load
    "rtlb9", "wtlb9", "dtlb_log", "dtlb_dlog", "dtlb_logged", "dtlb_dlogged",   # ARM9 data TLB, off after a load
    "long_on", "long_slice", "long_h9", "slice_from", "long_next", "cut_at",   # run_until's long slices
    "ovl9", "ovlx9", "ovl_top9"]   # one opcode's data overlap (bus9.nim), stale between opcodes
  CPU_SKIP = ["bus", "trace", "profiling", "profile", "cprofile", "attn",
              # idle-loop skipping: a fresh detector proves the same loops again
              "wl_on", "wl_until", "wl_bump", "wl_head", "wl_other", "wl_epoch", "wl_have",
              "wl_tries", "wl_idle", "wl_cycles", "wl_instrs", "wl_fails", "wl_skipped",
              "wl_cold", "wl_regs", "wl_cpsr", "wl_spsr", "wl_sig", "wl_ev"]
  # cachability by address and the cache enables: update_regions(cp15)
  TIMING_SKIP = ["ic_on", "dc_on", "icode", "idata", "ibuf", "mcode", "mdata", "mbuf"]
  # mmem_req/mmem_ctx: the machine's DMA mode 4 hook, set at construction
  GPU_SKIP = ["vram", "engine_a", "engine_b", "gpu3d", "mmem_req", "mmem_ctx",
              # HD 3D: the frontend's setting and its pictures (docs/nds/hd3d.md)
              "hd", "hd_top", "hd_bottom", "hd_sub", "hd_out", "hd_out2", "hd_a_gfx", "hd_a_line",
              "cap_hd", "cap_1x", "hd_vline", "hd_bline", "hd_clear_gfx", "hd_clear_line", "hd_paint"]
  # page tables, fast pointers and VRAMSTAT: remap() rebuilds them from cnt
  # tex_gen: the 3D renderer's reuse check (gpu3d.nim), bumped by remap()
  # vgen/remap_gen/pbase: the 2D engines' line reuse (engine2d.nim); remap()
  # in after_load bumps remap_gen, so no line is reused across a load
  VRAM_SKIP = ["pages", "fast", "wfast", "zero", "vramstat", "tex_gen", "vgen", "remap_gen", "pbase"]
  # pointers into Gpu's palette/OAM (kept); line3d is set before each use;
  # the line buffers and per-line scratch are rewritten before they are read
  # (line, gfx, bgpix ... obj_prios); touch, lc_*, mem_gen: line reuse,
  # which remap() in after_load restarts (vram.remap_gen)
  ENGINE_SKIP = ["vram", "palette", "oam", "line3d", "line", "gfx", "lsb", "lsb_on", "bgpix", "objpix",
                 "objprio", "objattr", "winmask", "line_semi", "line_objwin", "obj_prios",
                 "lc_on", "mem_gen", "lgen", "touch", "lc_valid", "lc_key", "lc_touch", "lc_vsum",
                 "lc_line", "lc_3d", "lc_reused", "hd_on"]
  # reuse_*/last_*: what the last real render drew (render_frame); the
  # remap() in after_load bumps vram.tex_gen, so a loaded machine draws afresh
  GPU3D_SKIP = ["geo", "ren", "vram", "irq", "sched", "reuse_on", "reuse_ok", "reused", "last_gen",
                "last_disp3dcnt", "last_param", "last_regs", "last_polys", "last_verts",
                "last_is_cur",
                # HD rendering: the frontend's display setting and its pictures
                # (docs/nds/hd3d.md)
                "hd_scale", "hpos", "hd_verts", "hd2", "hd3", "hd4", "hd_frame"]
  GEO_SKIP = ["hd_on", "hpos"]   # HD rendering's vertex positions (docs/nds/hd3d.md)
  # Per-frame scratch: render_frame's clear() rewrites each dot's `px`
  # (depth, IDs, flags, coverage and the layer behind) before anything
  # reads them, the page pointers and `order` are rebuilt
  # per frame. `color` (the frame being shown) and `regs` are saved.
  # tc_*: decoded texels, a cache keyed by vram.tex_gen (remap() in
  # after_load bumps it, so a loaded machine decodes afresh)
  RENDER_SKIP = ["px", "tex_pages", "pal_pages", "zero_page", "mixed", "order",
                 "tc_gen", "tc_pool", "tc_used", "tc_index"]
  TIMERS_SKIP = ["sched", "irq"]
  DMA_SKIP = ["irq"]
  IPC_SKIP = ["arm9", "arm7"]
  IPC_END_SKIP = ["irq"]
  DIVSQRT_SKIP = ["sched"]
  SPI_SKIP = ["firmware", "irq", "input", "sched", "mic"]   # firmware supplied on load
  MIC_SKIP = ["sched"]
  # key1_table (from BIOS7), key1 (from it and the game code) and secure (the
  # secure area in card form) are rebuilt by set_key1_table at construction
  # from the ROM and BIOS7, both identity-checked, and never change after
  CART_SKIP = ["rom", "irq9", "irq7", "sched", "backup", "spilog", "cartlog",
               "key1_table", "key1", "secure"]
  BACKUP_SKIP = ["dirty"]        # frontend bookkeeping; set after a load
  SPU_SKIP = ["samples"]         # host output queue, emptied on load
  # `fixed` = the clock follows emulated time: the loading frontend's
  # setting (ndsrun --rtc), not the state's
  RTC_SKIP = ["sched", "irq", "fixed"]
  # masks: constant per register. The Air (`air`, `station`, `air_offset`)
  # is the frontend's link between machines, not one machine's state; the
  # firmware image is supplied. Frames in flight (tx_frame, rx) are saved.
  WIFI_SKIP = ["sched", "irq", "masks", "air", "station", "air_offset", "firmware",
               "log_last", "log_repeat"]
  # the GBA cart ROM is supplied (and identity-checked, preamble); `dirty`
  # is set after a load as for the card's save chip
  SLOT2_SKIP = ["rom", "dirty"]
  NO_SKIP: array[0, string] = []
  # Fields added to the payload since states were first kept, oldest first,
  # with their type as the layout names it. A state whose layout is this
  # one's without the newest k of them still loads: those fields keep the
  # loading machine's value (a running game's, or what boot gave). Only a
  # plain field whose boot value is right for any moment belongs here;
  # anything else changes the layout outright and old states are refused.
  ADDED_FIELDS = [
    ("wifiwaitcnt", "uint16"),   # ARM7 WIFIWAITCNT (bus7.nim): boot leaves 0030h, as games keep it
  ]

# Seqs whose length varies at run time, with the longest a machine makes;
# every other seq must match the loading machine's length.
template var_seq_max(name: static string): int =
  when name == "events": 64                    # NdsScheduler: one per kind
  elif name == "buf": 1 shl 20                 # Cart: one ROMCTRL block (after_load
                                               # holds it to 16 KB); Mic: its queue
  elif name == "data": 16 * 1024 * 1024        # Backup: the save chip
  elif name == "detect": 64                    # Backup: bytes held in bkAuto
  elif name == "save": 1 shl 20                # Slot2: the GBA cart's save chip
  elif name == "rx": 256                       # Wifi: frames being received
  elif name == "bytes": 1 shl 16               # AirFrame: one frame
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
    missing: seq[string]   ## test only: write an older layout (state_payload_older)

    min_block: int      ## record blocks this long or longer (0: none; state_blocks)
    blocks: seq[tuple[name: string; lo, hi: int]]
  Loader = object
    data: ptr UncheckedArray[char]
    len, pos: int
    missing: seq[string]   ## ADDED_FIELDS the state's older layout lacks
  Layout = object
    text: string
    depth: int

proc put(s: var Saver; p: pointer; n: int) {.inline.} =
  if n == 0: return
  if s.pos + n > s.buf.len: s.buf.setLen(max(2 * s.buf.len, s.pos + n))
  copyMem(addr s.buf[s.pos], p, n)
  s.pos += n

proc note_block(s: var Saver; name: string; at, n: int) {.inline.} =
  if s.min_block > 0 and n >= s.min_block: s.blocks.add((name, at, at + n))

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
      when typeof(s) is (Loader or Saver):
        if s.missing.len == 0 or fname notin s.missing: io(s, f, fname)
      else:
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
  const leaf = not (T is (array or seq or Deque or object or tuple or AirFrame))
  when S is Saver and leaf:
    let at = s.pos
  when S is Layout:
    when T is (array or seq or Deque or object or tuple):
      var e: T     # walked once for its element/field types below
    when T is enum:
      s.note(name, $T & enum_names(T))
    elif T is set:
      s.note(name, $T & set_names(e_of_set(x)))
    else:
      s.note(name, $T)
  when T is AirFrame:
    # a frame in flight, owned by this machine's transmitter or receiver:
    # saved by value (present flag, then its fields)
    when S is Layout:
      var one = AirFrame()
      inc s.depth
      walk(s, one[], NO_SKIP)
      dec s.depth
    else:
      var present = x != nil
      io(s, present, name)
      when S is Loader:
        x = if present: AirFrame() else: nil
      if present: walk(s, x[], NO_SKIP)
  elif T is (ref or ptr or pointer or proc or cstring or string):
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
      when S is Saver:
        s.note_block(name, s.pos, sizeof(x))
        s.put(addr x, sizeof(x))
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
          when S is Saver:
            s.note_block(name, s.pos, n * sizeof(E))
            s.put(addr x[0], n * sizeof(E))
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
  when S is Saver and leaf:
    s.note_block(name, at, s.pos - at)

proc section[S](s: var S; tag: uint8; title: static string) =
  ## A marker byte between sections: a desynchronised read stops at the
  ## next one instead of loading garbage further on.
  when S is Saver:
    if s.min_block > 0: s.blocks.add(("[" & title & "]", s.pos, s.pos))
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
  ## The payload after the preamble: one section per subsystem object,
  ## those of fixed size first. Sections holding seqs whose length changes
  ## while a game runs (the card's transfer, the IPC FIFOs, the event queue,
  ## the GX FIFO and polygon/vertex RAM) come last, so between two snapshots
  ## everything before them stays at the same offset: a rewind ring's XOR
  ## delta of a 6 MB SoulSilver payload is then mostly zeros. The tags are
  ## the sections' names, not their order.
  obj_section(s, 1, "machine (NDS)", n[], NDS_SKIP)
  obj_section(s, 3, "ARM9", n.arm9[], CPU_SKIP)
  obj_section(s, 4, "ARM7", n.arm7[], CPU_SKIP)
  obj_section(s, 5, "ARM9 memory timing (cache tags)", n.tm, TIMING_SKIP)
  obj_section(s, 6, "display (Gpu)", n.gpu[], GPU_SKIP)
  obj_section(s, 7, "VRAM", n.gpu.vram[], VRAM_SKIP)
  obj_section(s, 12, "3D renderer", n.gpu3d.ren[], RENDER_SKIP)
  obj_section(s, 13, "ARM9 IRQ", n.irq9[], NO_SKIP)
  obj_section(s, 14, "ARM7 IRQ", n.irq7[], NO_SKIP)
  obj_section(s, 15, "ARM9 timers", n.timers9[], TIMERS_SKIP)
  obj_section(s, 16, "ARM7 timers", n.timers7[], TIMERS_SKIP)
  obj_section(s, 17, "ARM9 DMA", n.dma9[], DMA_SKIP)
  obj_section(s, 18, "ARM7 DMA", n.dma7[], DMA_SKIP)
  obj_section(s, 20, "IPC ARM9 side", n.ipc.arm9[], IPC_END_SKIP)
  obj_section(s, 21, "IPC ARM7 side", n.ipc.arm7[], IPC_END_SKIP)
  obj_section(s, 22, "DIV/SQRT", n.divsqrt[], DIVSQRT_SKIP)
  obj_section(s, 23, "input", n.input[], NO_SKIP)
  obj_section(s, 24, "SPI (power manager, firmware flash, touch)", n.spi[], SPI_SKIP)
  obj_section(s, 31, "GBA slot", n.slot2[], SLOT2_SKIP)
  obj_section(s, 27, "sound", n.spu[], SPU_SKIP)
  obj_section(s, 28, "RTC", n.rtc[], RTC_SKIP)
  obj_section(s, 29, "wifi", n.wifi[], WIFI_SKIP)
  # the save chip's size is fixed once the game has used it
  obj_section(s, 26, "backup chip", n.cart.backup[], BACKUP_SKIP)
  # the main-memory display frame appears once and stays
  obj_section(s, 8, "2D engine A", n.gpu.engine_a[], ENGINE_SKIP)
  obj_section(s, 9, "2D engine B", n.gpu.engine_b[], ENGINE_SKIP)
  # lengths that change frame to frame
  obj_section(s, 25, "card", n.cart[], CART_SKIP)
  obj_section(s, 19, "IPC FIFOs", n.ipc[], IPC_SKIP)
  obj_section(s, 30, "microphone queue", n.spi.mic[], MIC_SKIP)
  obj_section(s, 2, "scheduler", n.sched[], NO_SKIP)
  obj_section(s, 10, "3D engine (Gpu3d)", n.gpu3d[], GPU3D_SKIP)
  obj_section(s, 11, "3D geometry", n.gpu3d.geo[], GEO_SKIP)
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

proc older_layout_hash(n: NDS; k: int): uint32 =
  ## The layout hash of this build's layout without the newest k of
  ## ADDED_FIELDS: what a build from before them wrote.
  let lines = state_layout(n).split('\n')
  var gone: seq[string]
  for (name, kind) in ADDED_FIELDS[^k .. ^1]: gone.add name & ": " & kind
  var text = ""
  for i, line in lines:
    if line.strip() in gone: continue
    text.add line
    if i < lines.high: text.add '\n'
  fnv1a(text) or 1

proc older_layout_fields(n: NDS; hash: uint32): int =
  ## How many of ADDED_FIELDS (the newest) a state with this layout hash
  ## lacks, when its layout is this one's without them; -1 for any other.
  for k in 1 .. ADDED_FIELDS.len:
    if n.older_layout_hash(k) == hash: return k
  -1

proc bios_identity(n: NDS; arm9: bool): uint32 =
  if arm9: fnv1a(n.bios9) else: fnv1a(n.bios7)

const PREAMBLE_MAGIC = 0x5344_534E'u32   ## "NDSS"

proc slot2_identity(n: NDS): uint32 =
  ## What is in the GBA slot: the device, and for a GBA cart fnv1a over its
  ## header (0xC0 bytes: title, game code, version, checksum) and length.
  ## Its ROM is supplied like the card's, so a state needs the same one.
  let r = n.slot2.rom
  result = fnv1a(r.toOpenArray(0, min(r.len, 0xC0) - 1))
  result = (result xor uint32(r.len)) * 0x01000193'u32

proc write_preamble(s: var Saver; n: NDS) =
  var w = [PREAMBLE_MAGIC,
           (if s.missing.len > 0: n.older_layout_hash(s.missing.len) else: n.layout_hash()),
           uint32(ord(n.hle_bios9)) or (uint32(ord(n.hle_bios7)) shl 1),
           n.bios_identity(true), n.bios_identity(false),
           uint32(ord(n.slot2.kind)), n.slot2_identity()]
  s.put(addr w[0], sizeof(w))

proc check_preamble(l: var Loader; n: NDS) =
  var w: array[7, uint32]
  l.get(addr w[0], sizeof(w))
  if w[0] != PREAMBLE_MAGIC:
    raise state_error("DS state payload has no preamble")
  if w[1] != n.layout_hash():
    let k = n.older_layout_fields(w[1])
    if k < 0:
      raise state_error("DS state was made by a build whose DS state layout " &
                        "differs from this one's", srkIncompatible)
    for (name, _) in ADDED_FIELDS[^k .. ^1]: l.missing.add name
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
  if w[5] != uint32(ord(n.slot2.kind)) or w[6] != n.slot2_identity():
    raise state_error("DS state was made with something else in the GBA " &
                      "slot (insert the same cart or pak first)", srkIncompatible)

# ---------------------------------------------------------------------------
# Payload

proc state_payload*(n: NDS): string =
  ## The machine as payload bytes (no header): what rewind deltas compare.
  var s = Saver(buf: newString(8 * 1024 * 1024))
  s.write_preamble(n)
  io_machine(s, n)
  s.buf.setLen(s.pos)
  move(s.buf)

when defined(test_harness):
  proc state_payload_older*(n: NDS; k: int): string =
    ## The payload a build from before the newest k ADDED_FIELDS wrote
    ## (nds_savestate_test: such a state still loads).
    var s = Saver(buf: newString(8 * 1024 * 1024))
    for (name, _) in ADDED_FIELDS[^k .. ^1]: s.missing.add name
    s.write_preamble(n)
    io_machine(s, n)
    s.buf.setLen(s.pos)
    move(s.buf)

proc state_blocks*(n: NDS; min_bytes: int): seq[tuple[name: string; lo, hi: int]] =
  ## The payload ranges (`state_payload` offsets) of the numeric arrays and
  ## seqs and the single fields of at least `min_bytes`, by field name: with
  ## 256 the memories (RAM, VRAM, palettes, OAM, the save chip) and the
  ## large tables, which tools/statefuzz.nim leaves out of a sweep; with 1
  ## every field, to name the one at an offset. Each section starts with an
  ## empty range named "[its title]".
  var s = Saver(buf: newString(8 * 1024 * 1024), min_block: max(min_bytes, 1))
  s.write_preamble(n)
  io_machine(s, n)
  s.blocks

proc check_range64(v, lo, hi: int64; field: string) =
  ## `check_range` for 64-bit fields and uint32s (an int is 32 bits on wasm)
  if v < lo or v > hi:
    raise state_error("DS state field '" & field & "' is out of range (" &
                      $v & " not in " & $lo & ".." & $hi & ")")

const
  MAX_CLOCK = 1'i64 shl 55
    ## The master clock's bound (17 years of running), far from where the
    ## difference of two times overflows an int64
  MAX_BOOKING = 1'i64 shl 40
    ## The furthest ahead an event may be booked (~4.5 hours; a machine's
    ## furthest is the RTC's next minute)

proc check_clocks(n: NDS) =
  ## The master clock and what is dated by it. Each CPU runs from its own
  ## clock to the slice end, so one far behind would run for hours to catch
  ## up; an event booked far in the past would repeat to catch up the same
  ## way (the display's line, the sound mixer's tick).
  privateAccess(NdsScheduler)
  template time_in(t: int64; lo, hi: int64; name: string) = check_range64(t, lo, hi, name)
  let now = n.sched.now
  time_in(now, 0, MAX_CLOCK, "sched.now")
  time_in(n.arm9.cycles, now - FRAME_CYCLES, now + 64 * FRAME_CYCLES, "arm9.cycles")
  time_in(n.arm7.cycles, now - FRAME_CYCLES, now + 64 * FRAME_CYCLES, "arm7.cycles")
  # cycles an instruction has run up and not yet charged (0 between them)
  time_in(n.wait9, 0, FRAME_CYCLES, "wait9")
  time_in(n.wait7, 0, FRAME_CYCLES, "wait7")
  time_in(n.arm9.icycles, 0, FRAME_CYCLES, "arm9.icycles")
  time_in(n.arm7.icycles, 0, FRAME_CYCLES, "arm7.icycles")
  time_in(n.line_start, now - FRAME_CYCLES, now + LINE_CYCLES, "line_start")
  time_in(n.spu.next_tick, now - FRAME_CYCLES, now + FRAME_CYCLES, "spu.next_tick")
  # the machine's constants, set when it is made: what an instruction
  # costs, which events are a timer unit's, which DMA unit and which
  # display engine is which
  if n.arm9.base_cycles != ARM9_CYCLES_PER_INSTR or
     n.arm7.base_cycles != ARM7_CYCLES_PER_INSTR or
     n.timers9.first_event != evTimer9_0 or n.timers7.first_event != evTimer7_0 or
     not n.dma9.is9 or n.dma7.is9 or
     n.gpu.engine_a.id != engA or n.gpu.engine_b.id != engB:
    raise state_error("DS state has another machine's constants")
  # the GBA slot's access times (bus cycles), from EXMEMCNT (slot_timing;
  # all 0 before the first write)
  for t in [n.slot9_t, n.slot7_t]:
    for v in [t.rom_n, t.rom_s, t.ram]: time_in(v, 0, 18, "slot timing")
  # Times a unit counts from or compares with the clock (the timers, the
  # divider, the busy flags, wifi's timers and frames in flight, the 3D
  # engine's FIFO and rendering, the RTC's base): any time, past or future,
  # as long as a difference of two cannot overflow. -1 and high(int64) are
  # "none" to the units that use them.
  template dated(t: int64; name: string) = time_in(t, -MAX_CLOCK, MAX_CLOCK, name)
  privateAccess(Spi)
  privateAccess(Cart)
  privateAccess(Wifi)
  privateAccess(Gpu3d)
  privateAccess(Rtc)
  privateAccess(Mic)
  for t in [n.timers9, n.timers7]:
    for v in t.start_at: dated(v, "timers.start_at")
  dated(n.divsqrt.div_done, "divsqrt.div_done")
  dated(n.divsqrt.sqrt_done, "divsqrt.sqrt_done")
  dated(n.spi.busy_until, "spi.busy_until")
  dated(n.spi.wip_until, "spi.wip_until")
  dated(n.cart.spi_busy_until, "cart.spi_busy_until")
  let w = n.wifi
  for v in [w.random_at, w.us_base_at, w.next_ms, w.irq15_at, w.cmd_count_at,
            w.tx_at, w.reply_at]:
    dated(v, "wifi time")
  template frame_times(f: AirFrame) =
    if f != nil:
      for v in [f.start, f.data_at, f.stop]: dated(v, "wifi frame time")
  frame_times(w.tx_frame)
  for r in w.rx:
    for name, f in r.fieldPairs:   # RxSlot is private to wifi.nim
      when name == "f": frame_times(f)
      elif name in ["start_at", "end_at"]: dated(f, "wifi.rx")
  let g = n.gpu3d
  for v in [g.cur_end, g.stall_until, g.next_vblank, g.render_t0]: dated(v, "gpu3d time")
  for e in g.fifo:
    for name, f in e.fieldPairs:   # FifoEntry is private to gpu3d.nim
      when name == "at": dated(f, "gpu3d.fifo")
  check_range(g.done_lines, 0, 192, "gpu3d.done_lines")
  let r = n.rtc
  for v in [r.offset, r.adj_since, r.fixed_start, r.last_ticks]: dated(v, "rtc ticks")
  time_in(r.slept, 0, MAX_CLOCK, "rtc.slept")
  if r.next_due != high(int64): dated(r.next_due, "rtc.next_due")
  # the microphone queue is played out from `last` to now at `rate` (samples
  # a second; a frontend's is at most 48000) and `acc` is a sample's fraction
  let m = n.spi.mic
  time_in(m.last, 0, now, "mic.last")
  check_range(m.rate, 0, 1 shl 20, "mic.rate")
  time_in(m.acc, 0, MASTER_HZ - 1, "mic.acc")
  # `next` is the earliest booking, kept by the scheduler as events come and
  # go; one later than that never fires (run_until stops at `next`), one
  # earlier stops the clock there for good
  var seen: set[NdsEvent]
  n.sched.next = high(int64)
  for e in n.sched.events:
    for name, f in e.fieldPairs:   # Pending is private to sched.nim
      when name == "kind":
        if f in seen: raise state_error("DS state books an event twice")
        seen.incl f
      elif name == "at":
        time_in(f, now - FRAME_CYCLES, now + MAX_BOOKING, "event")
        n.sched.next = min(n.sched.next, f)

proc check_caches(n: NDS) =
  ## The ARM9 caches' contents (timing.nim, bus9.nim dc_*/ic_*): every line
  ## held is a main RAM line in the set its address picks, the data cache
  ## holds a line in one slot only, an empty slot holds nothing dirty, and
  ## the round-robin and victim pointers stay inside their sets. The tables
  ## built from the slots (`slot_of`, `page_apart`, `shadows`) are then
  ## rebuilt from them rather than trusted: each is an index or a count the
  ## next fill or eviction follows.
  privateAccess(TagCache)
  let t = addr n.tm
  let lines = n.main_ram.len div 32
  for (c, name) in [(addr t.icache, "icache"), (addr t.dcache, "dcache")]:
    if int(c.set_mask) + 1 != c.rr.len or c.tags.len != 4 * c.rr.len:
      raise state_error("DS state " & name & " has the wrong number of sets")
    for r in c.rr: check_range(int(r), 0, 3, name & ".rr")
    check_range(c.victim, 0, c.tags.len - 1, name & ".victim")
  template in_its_set(line1: uint32; slot: int; c: TagCache; name: string) =
    check_range64(int64(line1), 0, lines, name)
    if line1 != 0 and int((line1 - 1) and c.set_mask) != slot div 4:
      raise state_error("DS state field '" & name & "' is a line outside its set")
  for v in t.slot_of.mitems: v = 0
  for v in t.page_apart.mitems: v = 0
  t.shadows = 0
  for slot in 0 ..< t.dline.len:
    let d = t.dline[slot]
    in_its_set(d.line1, slot, t.dcache, "dline.line1")
    if d.line1 == 0:
      if d.dirty or d.shadowed:
        raise state_error("DS state has an empty data-cache slot holding data")
      continue
    let line = int(d.line1 - 1)
    if t.slot_of[line] != 0:
      raise state_error("DS state holds a main RAM line in two data-cache slots")
    t.slot_of[line] = uint16(slot + 1)
    if d.shadowed:
      inc t.shadows
      inc t.page_apart[line shr 7]
  for slot in 0 ..< t.iline.len:
    let il = t.iline[slot]
    in_its_set(il.line1, slot, t.icache, "iline.line1")
    if il.line1 == 0: continue
    let line = int(il.line1 - 1)
    t.slot_of[line] += IC_ONE
    if il.kept: inc t.page_apart[line shr 7]

proc after_load(n: NDS) =
  ## Rebuild what the state leaves out, then refuse values the machine would
  ## index out of range with (a state is a stranger's file).
  n.gpu.vram.remap()
  n.fetch_paths_off()
  inc n.idle_epoch            # every idle-loop proof starts over
  n.tm.update_regions(n.cp15)
  privateAccess(Geometry)
  privateAccess(Gpu3d)
  privateAccess(Cart)
  privateAccess(Backup)
  privateAccess(Rtc)
  privateAccess(Spi)
  privateAccess(Wifi)
  privateAccess(Mic)
  privateAccess(Engine2D)
  privateAccess(NdsScheduler)
  privateAccess(Slot2)
  privateAccess(Gpu)
  let g = n.gpu3d.geo
  check_range(g.nbuf, 0, 3, "geometry.nbuf")
  check_range(n.gpu3d.pk_left, 0, 32, "gpu3d.pk_left")
  check_range(g.vram_count, 0, MAX_VERTS, "geometry.vram_count")
  # what the commands mask them to (geometry.nim), so their next step
  # cannot overflow
  check_range(g.mode, 0, 3, "geometry.mode")
  check_range(g.prim, 0, 3, "geometry.prim")
  check_range(g.proj_sp, 0, 1, "geometry.proj_sp")
  check_range(g.tex_sp, 0, 1, "geometry.tex_sp")
  check_range(g.pos_sp, 0, 63, "geometry.pos_sp")
  for v in [g.vp_x1, g.vp_y1, g.vp_x2, g.vp_y2]:
    check_range(int(v), 0, 255, "geometry.viewport")   # VIEWPORT's bytes
  # a polygon's vertices are a run of its list's (render.nim draw_polygon)
  for (polys, verts) in [(addr g.polys, addr g.verts), (addr n.gpu3d.polys, addr n.gpu3d.verts)]:
    for p in polys[]:
      if p.first < 0 or p.count < 0 or int(p.first) + int(p.count) > verts[].len:
        raise state_error("DS state has a polygon past the end of its vertices")
  let c = n.cart
  check_range(c.buf.len, 0, 0x4000, "cart.buf")
  check_range(c.pos, 0, c.buf.len, "cart.pos")
  check_range(c.sec_pos, 0, high(int32), "cart.sec_pos")
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
  check_range(n.wifi.tx_src, -1, 6, "wifi.tx_src")
  check_range(n.wifi.tx_hdr, -1, 0xFFFF, "wifi.tx_hdr")
  check_range(n.spi.mic.rd, 0, n.spi.mic.buf.len, "mic.rd")
  # the stylus on the bottom screen (set_touch clamps it), which the touch
  # controller scales by the firmware's calibration
  check_range(n.input.touch_x, 0, 255, "input.touch_x")
  check_range(n.input.touch_y, 0, 191, "input.touch_y")
  for ch in n.spu.ch:
    check_range(ch.adpcm_index, 0, 88, "spu.adpcm_index")
    check_range(ch.loop_index, 0, 88, "spu.loop_index")
    # the decoder's sample, a header's int16 or clipped to it (adpcm_step
    # adds a step to it)
    check_range(ch.adpcm_pcm, -0x8000, 0x7FFF, "spu.adpcm_pcm")
    check_range(ch.loop_pcm, -0x8000, 0x7FFF, "spu.loop_pcm")
    # SOUNDxLEN as written (22 bits; the stream length is PNT + LEN in an
    # int32); the read-ahead runs from the word being played to FIFO_WORDS
    # past it (`fill` loops until it gets there); the timer count stays
    # under a step past 0x10000 (`advance` steps until it is back below),
    # and a start delay is at most 11 samples
    check_range64(int64(ch.len), 0, 0x3F_FFFF, "spu.len")
    check_range(int(ch.sw), 0, high(int32) - FIFO_WORDS, "spu.sw")
    check_range64(ch.fetched, ch.sw, int64(ch.sw) + FIFO_WORDS, "spu.fetched")
    check_range64(int64(ch.ctr), 0, 0x1_0000 + int64(TIMER_STEP), "spu.ctr")
    check_range(int(ch.pos), -11, high(int32), "spu.pos")
  # a block runs to its end in one go (dma.nim `transfer`): no longer than
  # DMAxCNT can ask for (count_of)
  for (d, most) in [(n.dma9, 0x20_0000'i64), (n.dma7, 0x1_0000'i64)]:
    for c in d.ch: check_range64(int64(c.cur_count), 0, most, "dma.cur_count")
  for k in n.spu.cap:
    # bytes of a word gathered (a shift: `capture_store`), words left of LEN
    check_range(k.acc_bytes, 0, 3, "capture.acc_bytes")
    check_range64(int64(k.words_left), 0, 0x1_0000, "capture.words_left")
  # The GBA slot's save chip: its memory as long as its type's (insert_gba),
  # the FLASH bank inside it (storage_chip.nim indexes it unmasked), and the
  # EEPROM's bit counts (`eeprom_read` shifts by what is left)
  let s2 = n.slot2
  if s2.kind == s2GbaCart:
    if s2.save_type == stEEPROM: check_one_of(s2.save.len, [0x200, 0x2000], "slot2.save")
    else: check_one_of(s2.save.len, [storage_bytes(s2.save_type)], "slot2.save")
    if s2.save_type in {stFLASH, stFLASH512, stFLASH1M}:
      check_range(int(s2.flash_bank), 0, s2.save.len div 0x10000 - 1, "slot2.flash_bank")
      if fsSetBank in s2.flash_state and s2.save_type != stFLASH1M:
        raise state_error("DS state sets a bank on a one-bank FLASH")
  check_range(s2.ee_bits, 0, high(int32), "slot2.ee_bits")
  check_range(s2.ee_out_left, 0, 68, "slot2.ee_out_left")
  for e in [n.gpu.engine_a, n.gpu.engine_b]:
    check_range(e.mmem_rd, 0, MMEM_FIFO_WORDS * 2 - 1, "engine.mmem_rd")
    check_range(e.mmem_n, 0, MMEM_FIFO_WORDS * 2, "engine.mmem_n")
  check_range(n.gpu.vcount, 0, LINES - 1, "gpu.vcount")
  check_range(n.gpu.mmem_need, 0, 256 * 192, "gpu.mmem_need")
  check_range(n.vcount_write, -1, LINES - 1, "vcount_write")
  n.check_clocks()
  n.check_caches()

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
  if n.slot2.save.len > 0: n.slot2.dirty = true

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
  let dirty2 = n.slot2.dirty
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
    n.slot2.dirty = dirty2
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
