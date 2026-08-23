## Save-state format compatibility guards.
##
## Two silent ways users lose states: a payload-revision bump whose reader
## refuses older files, and a field added (or an EventType inserted rather
## than appended) without a bump, so the reader walks off by a few bytes.
## `tests/states/*.state` are REAL images written by builds checked out at
## the commit that shipped each format (`git archive <commit> | tar -x`,
## compile a small generator against that tree, run it on a committed test
## ROM), so they prove the migration paths against what those builds wrote.
##
## When this fails after an INTENTIONAL format change: bump only the changed
## core's payload revision (GBA_PAYLOAD_VERSION / GB_PAYLOAD_VERSION) and add
## the matching `if rev >= N` to its loader (docs/savestate_compat.md); if a
## field genuinely cannot be reconstructed, refuse THAT case with a message
## naming it. Never delete a corpus entry.
##
## Run with: nimble test_savestate_compat
## Regenerate the current-version corpus: <this binary> --write-corpus
## (older entries can only come from an old checkout)

import std/[os, strutils, algorithm]
import tables
import dingbat/common/serialize
import dingbat/common/scheduler
import dingbat/gb/gb
import dingbat/gba/gba

var failures = 0

proc check(cond: bool; name: string; detail = "") =
  if cond:
    echo "  [PASS] ", name
  else:
    echo "  [FAIL] ", name, (if detail.len > 0: "  " & detail else: "")
    inc failures

# 1. EventType ordinals are the save-state format: scheduler.save_to writes
# `ord(kind)` and load_from reads it back, so inserting a kind mid-enum
# silently reinterprets every pending event in every existing state. This
# block is compile-time, so a reorder fails the BUILD; appending a kind only
# needs a new line here.
static:
  const pinned: array[19, (EventType, int)] = [
    (etAPUFrameSeq,      0),
    (etAPUSample,        1),
    (etAPUChannel1,      2),
    (etAPUChannel2,      3),
    (etAPUChannel3,      4),
    (etAPUChannel4,      5),
    (etHandleInput,      6),
    (etIME,              7),
    (etRtcSecond,        8),
    (etSaves,            9),
    (etInterrupts,      10),
    (etPPUStartLine,    11),
    (etPPUStartHBlank,  12),
    (etPPUSetHBlankFlag,13),
    (etPPUEndHBlank,    14),
    (etTimer0,          15),
    (etTimer1,          16),
    (etTimer2,          17),
    (etTimer3,          18),
  ]
  for (kind, want) in pinned:
    doAssert ord(kind) == want,
      "EventType ordinals are save-state format: " & $kind & " moved from " &
      $want & " to " & $ord(kind) & ".  Append new kinds at the END of the enum."
  # Kinds appended after the block above. Appending is safe for OLD states;
  # a NEW state carrying a kind an OLD build rejects is a downgrade, out of
  # scope.
  doAssert ord(etSerial) == 19
  doAssert ord(etDMA) == 20
  doAssert ord(etCameraDone) == 21
  doAssert ord(etGbLycEdge) == 22
  doAssert ord(high(EventType)) == 22,
    "an EventType was appended without pinning its ordinal here"

  # Every other enum whose ordinal (or `set` bit position) reaches a state
  # file. Append only.
  doAssert (ord(stEEPROM), ord(stSRAM), ord(stFLASH),
            ord(stFLASH512), ord(stFLASH1M)) == (0, 1, 2, 3, 4),
    "StorageType ordinals are save-state format (flash_type, storage tags)"
  doAssert ord(high(StorageType)) == 4,
    "a StorageType was appended without pinning it here"

  doAssert (ord(fsReady), ord(fsCmd1), ord(fsCmd2), ord(fsIdentification),
            ord(fsPrepareWrite), ord(fsPrepareErase), ord(fsSetBank)) ==
           (0, 1, 2, 3, 4, 5, 6),
    "FlashStateFlag bit positions are save-state format (set[FlashStateFlag] " &
    "is cast to a u8)"
  doAssert ord(high(FlashStateFlag)) == 6,
    "a FlashStateFlag was appended without pinning it here"

  doAssert (ord(esReady), ord(esRead), ord(esReadIgnore), ord(esWrite),
            ord(esAddress), ord(esWriteFinalBit), ord(esLockAddress)) ==
           (0, 1, 2, 3, 4, 5, 6),
    "EepromStateFlag bit positions are save-state format (set[...] cast to u16)"
  doAssert ord(high(EepromStateFlag)) == 12,
    "an EepromStateFlag was appended without pinning it here"

  doAssert (ord(eeprom4k), ord(eeprom64k)) == (0, 1),
    "EepromSize ordinals are save-state format"

  doAssert (ord(rtcWaiting), ord(rtcCommand), ord(rtcReading), ord(rtcWriting)) ==
           (0, 1, 2, 3),
    "RtcState ordinals are save-state format"
  doAssert ord(high(RtcState)) == 3,
    "an RtcState was appended without pinning it here"

  # The scheduler refuses a state carrying more pending events than it can
  # hold, so this constant is a compatibility floor and not just a capacity.
  doAssert MAX_EVENTS >= 64,
    "MAX_EVENTS is a save-state floor: lowering it refuses existing states"

  # The event-deadline guard (scheduler.load_from) is the same kind of floor:
  # lowering either constant refuses states that already exist.
  doAssert MAX_EVENT_HORIZON >= CycleCount(1'u32 shl 27),
    "MAX_EVENT_HORIZON is a save-state floor: the longest thing this emulator " &
    "books is a GBA timer at prescaler 1024 over a full 16-bit period, 67.1M " &
    "cycles, and the guard must stay above it"
  doAssert MAX_EVENT_OVERDUE >= CycleCount(1'u32 shl 20),
    "MAX_EVENT_OVERDUE is a save-state floor: call_current drains due events " &
    "lazily, so a state may carry one slightly in the past"

# 2. Header layout constants. Changing one breaks the DETECTION of old
# states: parse_state_payload would report "not a dingbat save state".
static:
  doAssert STATE_MAGIC == "DGBSTATE"
  doAssert STATE_HEADER_SIZE == 32
  doAssert STATE_FLAG_THUMBNAIL == 0x0001'u16
  doAssert ord(ckGBA) == 0 and ord(ckGB) == 1
  # The legacy container -> payload revision table is derived from history and
  # can never change; pinning it makes an edit to legacy_payload_version fail
  # the build.
  const legacy: array[6, (uint32, uint32, uint32)] = [
    #  container, GBA rev, GB rev
    (1'u32, 1'u32, 1'u32),
    (2'u32, 2'u32, 1'u32),
    (3'u32, 3'u32, 1'u32),
    (4'u32, 3'u32, 2'u32),
    (5'u32, 4'u32, 2'u32),
    (6'u32, 4'u32, 3'u32),
  ]
  for (container, gba_rev, gb_rev) in legacy:
    doAssert legacy_payload_version(ckGBA, container) == gba_rev
    doAssert legacy_payload_version(ckGB, container) == gb_rev

# ---------------------------------------------------------------------------
# 3. The corpus.
# ---------------------------------------------------------------------------

const
  ROM_DIR = "tests/roms"
  CORPUS_DIR = "tests/states"
  # Corpus ROMs and the frames to run first (far enough in that the
  # subsystems have state worth serializing).
  GBA_ROMS = [("inputrec.gba", 30), ("linktest.gba", 30)]
  GB_ROMS  = [("gbhdmatest.gbc", 30), ("gblinktest.gb", 30)]

proc corpus_name(rom: string; version: uint32): string =
  rom & ".v" & $version & ".state"

proc new_gba_for(rom: string): GBA =
  result = new_gba("", ROM_DIR / rom, run_bios = false, use_hle = true)
  result.post_init()

proc new_gb_for(rom: string): GB =
  result = new_gb("", ROM_DIR / rom, fifo = true, headless = true,
                  run_bios = false)
  result.post_init()

proc write_corpus() =
  ## Regenerate the reference states at the CURRENT format version. Only ever
  ## run deliberately, and never as a way to make a red test go green — read
  ## the header of this file first.
  createDir(CORPUS_DIR)
  for (rom, frames) in GBA_ROMS:
    let emu = new_gba_for(rom)
    for _ in 0 ..< frames: emu.step_frame()
    let path = CORPUS_DIR / corpus_name(rom, STATE_VERSION)
    writeFile(path, emu.state_bytes(thumbnail = true))
    echo "wrote ", path
  for (rom, frames) in GB_ROMS:
    let emu = new_gb_for(rom)
    for _ in 0 ..< frames: emu.step_frame()
    let path = CORPUS_DIR / corpus_name(rom, STATE_VERSION)
    writeFile(path, emu.state_bytes(thumbnail = true))
    echo "wrote ", path

proc file_version(data: string): uint32 =
  var r = Reader(buf: data, pos: STATE_MAGIC.len)
  r.read_u32()

proc file_core(data: string): uint8 =
  uint8(data[12])

proc rom_identity(data: string): tuple[checksum, size: uint32] =
  ## The rom_checksum / rom_size pair a state image carries (header offsets
  ## 16 and 20).
  var r = Reader(buf: data, pos: 16)
  result.checksum = r.read_u32()
  result.size = r.read_u32()

proc run_corpus() =
  echo "corpus: reference states from older builds still load"
  if not dirExists(CORPUS_DIR):
    check(false, "corpus directory exists", CORPUS_DIR & " is missing")
    return
  var entries: seq[string] = @[]
  for kind, path in walkDir(CORPUS_DIR):
    if kind == pcFile and path.endsWith(".state"): entries.add(path)
  sort(entries)
  if entries.len == 0:
    check(false, "corpus is non-empty",
          "no .state files in " & CORPUS_DIR & " — regenerate with --write-corpus")
    return
  var revs_seen: array[CoreKind, set[uint8]]
  for path in entries:
    # <rom-with-extension>.v<N>.state, N = the CONTAINER version in the header
    let base = path.extractFilename
    let parts = base.split('.')
    if parts.len < 3:
      check(false, "corpus filename is <rom>.v<N>.state", base)
      continue
    let rom = parts[0 .. ^3].join(".")
    let data = readFile(path)
    let ver = file_version(data)
    let core = if file_core(data) == uint8(ckGBA): ckGBA else: ckGB
    let want_rev = if ver >= 7: uint32(data[13]) else: legacy_payload_version(core, ver)
    let label = base & " (container v" & $ver & ", " &
                (if core == ckGBA: "GBA" else: "GB") & " rev " & $want_rev & ")"
    if not fileExists(ROM_DIR / rom):
      check(false, label, "ROM " & rom & " is missing from " & ROM_DIR)
      continue
    revs_seen[core].incl(uint8(want_rev))
    # The revision the reader derives is the whole basis for the migration it
    # then applies, so assert it rather than only that the load worked.
    var got_rev = 0'u32
    var ok = false
    if core == ckGBA:
      let emu = new_gba_for(rom)
      # parse_state_image is the door load_state_bytes goes through, so the
      # test sees the same legacy identities a real load accepts (deriving the
      # identity from a state THIS build writes would fail against a corpus
      # entry carrying a superseded checksum and skip the assertion below).
      try:
        got_rev = emu.parse_state_image(data, base).rev
      except CatchableError: discard   # reported by the load below
      ok = emu.load_state_bytes(data)
      # Loading is not enough: a migration that leaves the machine wedged still
      # "loads". Run real frames through the restored state.
      if ok:
        try:
          for _ in 0 ..< 60: emu.step_frame()
        except CatchableError:
          ok = false
    else:
      let emu = new_gb_for(rom)
      try:
        got_rev = emu.parse_state_image(data, base).rev
      except CatchableError: discard
      ok = emu.load_state_bytes(data)
      if ok:
        try:
          for _ in 0 ..< 60: emu.step_frame()
        except CatchableError:
          ok = false
    check(ok, label,
          (if ok: "" else:
             "this state no longer loads (or wedges after loading). If the " &
             "format change was deliberate, see the header of " &
             "tests/savestate_compat_test.nim before touching this file."))
    if got_rev != 0:
      check(got_rev == want_rev, label & " revision derivation",
            "reader said rev " & $got_rev & ", history says " & $want_rev)
  # A corpus that has quietly lost its old entries passes vacuously, so state
  # the coverage the migrations are supposed to have.
  check(revs_seen[ckGBA] >= {3'u8, 4'u8},
        "corpus covers GBA payload revisions 3 and 4",
        "GBA revisions present: " & $revs_seen[ckGBA])
  check(revs_seen[ckGB] >= {1'u8, 2'u8, 3'u8},
        "corpus covers GB payload revisions 1, 2 and 3",
        "GB revisions present: " & $revs_seen[ckGB])

proc run_roundtrip() =
  ## A state taken by THIS build must load in THIS build; separates "the
  ## format moved" from "the serializer is broken".
  echo "round-trip: this build reads its own states"
  for (rom, frames) in GBA_ROMS:
    let emu = new_gba_for(rom)
    for _ in 0 ..< frames: emu.step_frame()
    let bytes = emu.state_bytes(thumbnail = true)
    check(emu.load_state_bytes(bytes), "GBA " & rom)
    let (tw, th, px) = parse_state_thumbnail(bytes)
    check(tw > 0 and th > 0 and px.len == tw * th * 2,
          "GBA " & rom & " thumbnail trailer")
    # The loader refuses a GBA state with no pending PPU event (step_frame's
    # `while ppu.frame == 0` would never end); assert every writer makes one.
    var ppu_events = 0
    for ev in emu.scheduler.events:
      if ev.kind in {etPPUStartLine, etPPUStartHBlank, etPPUSetHBlankFlag,
                     etPPUEndHBlank}:
        inc ppu_events
    check(ppu_events > 0,
          "GBA " & rom & " carries a pending PPU event at a frame boundary",
          "got " & $ppu_events)
  for (rom, frames) in GB_ROMS:
    let emu = new_gb_for(rom)
    for _ in 0 ..< frames: emu.step_frame()
    let bytes = emu.state_bytes(thumbnail = true)
    check(emu.load_state_bytes(bytes), "GB " & rom)
    let (tw, th, px) = parse_state_thumbnail(bytes)
    check(tw > 0 and th > 0 and px.len == tw * th * 2,
          "GB " & rom & " thumbnail trailer")
    # The GB rev 2 -> 3 migration defaults dots_since_frame to 0, legitimate
    # only because the counter resets at every frame push and states are
    # written at frame boundaries. Assert the premise.
    check(emu.ppu.dots_since_frame >= 0 and emu.ppu.dots_since_frame < 456,
          "GB " & rom & " dots_since_frame is ~0 at a frame boundary",
          "got " & $emu.ppu.dots_since_frame)
    # The loader REFUSES a state whose PPU is in mode 2 or 3 (the per-line
    # render scratch is not in the format; see load_ppu_state). Legitimate
    # only while no writer produces one, so assert the premise.
    check((emu.ppu.lcd_status and 3) < 2,
          "GB " & rom & " is in mode 0/1 at a frame boundary (the loader " &
          "refuses 2 and 3)",
          "got mode " & $(emu.ppu.lcd_status and 3) & " at ly " & $emu.ppu.ly)
    # The other pair the loader refuses: a vblank LINE in a non-vblank MODE.
    # With the LCD on a boundary is LY 144 mode 1; with it off, LY 0 mode 0.
    check(int(emu.ppu.ly) < 144 or (emu.ppu.lcd_status and 3) == 1,
          "GB " & rom & " is in mode 1 on a vblank line at a frame boundary",
          "got mode " & $(emu.ppu.lcd_status and 3) & " at ly " & $emu.ppu.ly)

# 3b. ROM identity is a property of the ROM FILE, not of the buffer. The
# header's rom_checksum used to be fnv1a over the first 1 MB of the
# ALLOCATED buffer, which is padded to the next power of two, so a change to
# the allocation rule (2dfd27e) silently re-identified every cart under
# 1 MB. `a`/`b` pin the identity to the file; `c` proves a state written
# with either old identity still loads (gba_legacy_rom_checksums) while a
# foreign checksum is refused; `d` proves carts >= 1 MB never moved. If the
# allocation rule changes again, `c` goes red on purpose.

proc with_checksum(img: string; v: uint32): string =
  ## A copy of a state image with the header's rom_checksum (offset 16)
  ## replaced. Nothing else in the header covers it — payload_hash is over the
  ## payload — so this is exactly the image an older build would have written.
  result = img
  for i in 0 .. 3: result[16 + i] = char(uint8(v shr (8 * i)))

proc run_rom_identity() =
  echo "ROM identity: the ROM file, not the buffer we allocate for it"
  const rom = GBA_ROMS[0][0]        # inputrec.gba, 56 bytes
  let file = readFile(ROM_DIR / rom)
  let n = file.len
  check(n > 0 and (n and (n - 1)) != 0,
        "fixture " & rom & " has a non-power-of-two length",
        "got " & $n & " bytes — pick a ROM that is padded when it is loaded")

  let emu = new_gba_for(rom)
  for _ in 0 ..< 30: emu.step_frame()
  check(emu.cartridge.rom.len > n and emu.cartridge.rom_size == n,
        "fixture is loaded into a padded buffer",
        "buffer " & $emu.cartridge.rom.len & ", file " & $n)

  # (a) the identity is the hash of the file's own bytes, capped at 1 MB.
  let (sum, size) = rom_identity(emu.state_bytes())
  check(sum == fnv1a(toOpenArrayByte(file, 0, min(n, 0x100000) - 1)),
        "identity is fnv1a over the ROM file (first 1 MB)")
  check(size == 0x02000000'u32, "rom_size field is still the fixed tag")

  # (b) no byte of the padding may reach the identity: scribbling on the pad
  # stands in for the next change to how the buffer is sized or filled.
  let taken_before = emu.state_bytes()
  for i in n ..< emu.cartridge.rom.len: emu.cartridge.rom[i] = 0xA5'u8
  check(rom_identity(emu.state_bytes()).checksum == sum,
        "buffer padding is not part of the identity")
  check(emu.load_state_bytes(taken_before),
        "a state survives a change to the buffer's size/padding")

  # (c) the two identities older builds computed for this cart, written as
  # the historical expressions rather than fetched from the code under test.
  let fresh = new_gba_for(rom)
  for _ in 0 ..< 30: fresh.step_frame()
  let img = fresh.state_bytes()
  # 2dfd27e .. today: the whole next_pow2 buffer, zero past the file, 32 KB
  # floor. Spelled out rather than read off cartridge.rom.len, because the
  # allocation rule is what may move underneath this test.
  var legacy_pad = 0x8000
  while legacy_pad < n: legacy_pad = legacy_pad shl 1
  var legacy_buf = newSeq[byte](min(legacy_pad, 0x100000))
  for i in 0 ..< min(n, legacy_buf.len): legacy_buf[i] = uint8(file[i])
  let legacy_pow2 = fnv1a(legacy_buf)
  # Pinned literals: the reconstruction above and the code under test could
  # still be "corrected" together in one edit; a hand-computed constant
  # cannot move with them (historical rule: 0x8000 floor, zero-filled).
  const pinned = {
    "inputrec.gba":       0x0E29A8EB'u32,
    "rumbletest.gba":     0xA80EEEA7'u32,
    "attachtest.gba":     0x1F8CDD74'u32,
    "linktest.gba":       0x1F7AB09F'u32,
    "linkskew.gba":       0xCE5B56E1'u32,
    "normlinktest.gba":   0xDA35CE65'u32,
    "norm32linktest.gba": 0xC7241AF7'u32,
    "speclinkbench.gba":  0xC2EC95B1'u32,
    "speclinkdep.gba":    0xC0DB6CBD'u32,
  }.toTable
  let base = rom.extractFilename
  if base in pinned:
    check(legacy_pow2 == pinned[base],
          "legacy identity for " & base & " matches its pinned value",
          "got 0x" & toHex(legacy_pow2, 8) & ", pinned 0x" & toHex(pinned[base], 8))
  # before 2dfd27e: 32 MB pre-filled with the open-bus address pattern, the
  # file over the front, [file, next_pow2) re-zeroed (only when the file was
  # not already a power of two).
  var old_buf = newSeq[byte](0x100000)
  for a in 0 ..< old_buf.len:
    let oob = 0xFFFF'u32 and (uint32(a) shr 1)
    old_buf[a] = uint8(oob shr (8 * (a and 1)))
  for i in 0 ..< n: old_buf[i] = uint8(file[i])
  var pw = 1
  while pw < n: pw = pw shl 1
  if pw != n:
    for i in n ..< pw: old_buf[i] = 0'u8
  let legacy_openbus = fnv1a(old_buf)

  check(legacy_pow2 != sum and legacy_openbus != sum and
        legacy_pow2 != legacy_openbus,
        "the three identities really are three different values",
        "current " & $sum & ", pow2 " & $legacy_pow2 &
        ", open-bus " & $legacy_openbus)
  check(fresh.load_state_bytes(img.with_checksum(legacy_pow2)),
        "a state written between 2dfd27e and this fix still loads")
  check(fresh.load_state_bytes(img.with_checksum(legacy_openbus)),
        "a state written before 2dfd27e still loads")
  check(not fresh.load_state_bytes(img.with_checksum(legacy_pow2 xor 0x5A5A5A5A'u32)),
        "an identity belonging to no revision of this cart is still refused")

  # (d) >= 1 MB: the cap means the hashed window is all file either way, so
  # these carts never moved. 1 MB exactly is the interesting one — it is the
  # Classic NES size, where the buffer is four mirrored copies.
  let big_path = getTempDir() / "dingbat_identity_1mb.gba"
  var big = newString(0x100000)
  for i in 0 ..< big.len:
    big[i] = char(uint8((i * 31 + (i shr 7) * 17 + 3) and 0xFF))
  for i in 0 ..< n: big[i] = file[i]      # keep a plausible cart header
  writeFile(big_path, big)
  defer: removeFile(big_path)
  let bigemu = new_gba("", big_path, run_bios = false, use_hle = true)
  bigemu.post_init()
  check(bigemu.cartridge.rom.len == 0x400000 and
        bigemu.cartridge.rom_size == 0x100000,
        "1 MB cart is loaded 4x mirrored into a 4 MB buffer",
        "buffer " & $bigemu.cartridge.rom.len)
  let big_sum = rom_identity(bigemu.state_bytes()).checksum
  check(big_sum == fnv1a(toOpenArray(bigemu.cartridge.rom, 0, 0x100000 - 1)),
        "1 MB cart's identity is unchanged by this fix (old expression agrees)")
  check(big_sum == fnv1a(toOpenArrayByte(big, 0, 0x100000 - 1)),
        "1 MB cart's identity is the file")

proc run_cart_shapes() =
  ## Every corpus state comes from a cart with no backup chip and, on the GB
  ## side, a plain 32 KB ROM with no mapper, so the Flash/EEPROM and mapper
  ## save/load branches would otherwise never run in CI. Committing a state
  ## per shape would prove nothing about migrations (all this build's
  ## revision), so instead synthesise each shape, take a state, put it back.
  echo "cart shapes: every storage kind and mapper round-trips a state"
  let tmp = getTempDir()

  # --- GBA: one ROM per backup type -----------------------------------------
  # find_storage_type scans the file for a marker string, so appending exactly
  # one marker selects the chip. Markers are checked in StorageType order, so
  # each ROM carries only its own.
  let base = readFile(ROM_DIR / GBA_ROMS[0][0])
  for (marker, want) in [("SRAM_V", stSRAM), ("EEPROM_V", stEEPROM),
                         ("FLASH_V", stFLASH), ("FLASH512_V", stFLASH512),
                         ("FLASH1M_V", stFLASH1M)]:
    let path = tmp / ("dingbat_shape_" & marker & ".gba")
    writeFile(path, base & marker & "\0")
    defer: removeFile(path)
    let emu = new_gba("", path, run_bios = false, use_hle = true)
    emu.post_init()
    # storage_kind_tag is private, so assert on the object shape it encodes:
    # EEPROM and Flash are distinct ref types, SRAM is the plain base.
    let shape =
      if emu.storage of EEPROM: "eeprom"
      elif emu.storage of Flash: "flash"
      else: "sram"
    let want_shape =
      case want
      of stEEPROM: "eeprom"
      of stFLASH, stFLASH512, stFLASH1M: "flash"
      else: "sram"
    check(shape == want_shape,
          "GBA " & marker & " is detected as " & want_shape,
          "got " & shape)
    for _ in 0 ..< 30: emu.step_frame()
    let img = emu.state_bytes()
    check(emu.load_state_bytes(img),
          "GBA " & $want & " state round-trips")

  # GB: one minimal 32 KB image per mapper; the header's cart type picks the
  # mapper and the RAM size byte gives it cart RAM to serialize. Nothing
  # executes.
  for (ctype, ramsz, name) in [(0x03'u8, 0x02'u8, "MBC1+RAM+BAT"),
                               (0x06'u8, 0x00'u8, "MBC2+BAT"),
                               (0x10'u8, 0x02'u8, "MBC3+TIMER+RAM+BAT"),
                               (0x1B'u8, 0x03'u8, "MBC5+RAM+BAT"),
                               (0x22'u8, 0x02'u8, "MBC7"),
                               (0xFE'u8, 0x02'u8, "HuC3")]:
    let path = tmp / ("dingbat_shape_gb_" & name & ".gb")
    var rom = newString(0x8000)
    for i in 0 ..< rom.len: rom[i] = char(uint8((i * 37 + 11) and 0xFF))
    rom[0x0147] = char(ctype)
    rom[0x0148] = '\0'          # 32 KB
    rom[0x0149] = char(ramsz)
    writeFile(path, rom)
    defer:
      removeFile(path)
      removeFile(path[0 ..< path.rfind('.')] & ".sav")
    let emu = new_gb("", path, fifo = false, headless = true, run_bios = false)
    emu.post_init()
    for _ in 0 ..< 30: emu.step_frame()
    let img = emu.state_bytes()
    check(emu.load_state_bytes(img), "GB " & name & " state round-trips")

proc run_rejections() =
  ## The rejection path must stay a clean refusal, never a partial apply: a
  ## user who loads a state from the wrong ROM keeps playing, they do not get
  ## a half-restored machine.
  echo "rejection: bad images are refused without disturbing the emulator"
  let emu = new_gba_for(GBA_ROMS[0][0])
  for _ in 0 ..< 30: emu.step_frame()
  let good = emu.state_bytes()
  let before = emu.state_payload()

  var wrong_version = good
  wrong_version[8] = char(uint8(STATE_VERSION) + 1)
  check(not emu.load_state_bytes(wrong_version), "future version refused")
  check(emu.state_payload() == before, "emulator untouched after version refusal")

  var wrong_rom = good
  wrong_rom[16] = char(uint8(good[16]) xor 0xFF'u8)   # rom_checksum byte 0
  check(not emu.load_state_bytes(wrong_rom), "other ROM refused")
  check(emu.state_payload() == before, "emulator untouched after ROM refusal")

  var wrong_core = good
  wrong_core[12] = char(uint8(ckGB))
  check(not emu.load_state_bytes(wrong_core), "other core refused")

  check(not emu.load_state_bytes(good[0 ..< good.len div 2]), "truncated refused")
  check(not emu.load_state_bytes("not a state at all"), "garbage refused")
  check(emu.state_payload() == before, "emulator untouched after every refusal")

# 4. The GBA rev 3 -> 4 IntrWait migration, the only one that rewrites guest
# memory. Shapes:
#   rev 4 (parked in IntrWait): System sp lowered 16, the four frame words
#     in memory, r4 = 1, r2 = mirror, lr_sys = 0x34C
#   rev 3: sp unshifted, no frame in memory, r4/r2/lr_sys still the CALLER's
# migrate_intr_wait_frame maps the second onto the first, so converting a
# rev-4 shape DOWN to rev 3 and migrating back must reproduce the rev-4
# payload byte for byte, with no reference to the migration's own code. No
# committed test ROM calls IntrWait, so the shape is built by hand,
# mirroring hle_intr_wait (gba/hle_bios.nim).

# Offset of halt_resume_pop, the last byte of the CPU section — the one byte
# that separates a rev-4 payload from a rev-3 one.
const CPU_SEC_LEN =
  1 +           # section tag
  16 * 4 +      # r0..r15
  4 + 4 +       # cpsr, spsr
  6 * 7 * 4 +   # reg_banks
  6 * 4 +       # spsr_banks
  4 + 4 +       # pipeline buffer
  1 + 1 +       # pipeline pos, size
  1 + 1 +       # halted, stopped
  1 + 2 + 4 +   # intr_wait active/mask/resume_addr
  1 + 4 + 4 +   # halt_wake, halt_resume_charge, halt_resume_addr
  1             # halt_resume_pop
const HALT_RESUME_POP_OFFSET = CPU_SEC_LEN - 1

# The DMA section (tag GBA_SEC_DMA, four channels) gained a u16 `count` per
# channel at rev 5. Its offset is not constant (the bus and scheduler
# sections ahead of it are variable-length), so it is located by its tag and
# confirmed by GBA_SEC_GPIO landing one section-length later.
const
  DMA_TAG      = 0xC9'u8
  GPIO_TAG     = 0xCA'u8
  DMA_CH_LEN   = 4 + 4 + 4 + 4 + 2 + 2 + 4 + 2  # sad dad src dst cnt_l cnt_h latch count
  DMA_SEC_LEN  = 1 + 4 * DMA_CH_LEN
  DMA_COUNT_AT = DMA_CH_LEN - 2                 # `count` is last in a channel

proc strip_dma_count(payload: var string): bool =
  ## Rewrite a payload this build wrote into the pre-rev-5 DMA layout by
  ## dropping each channel's `count`. Returns false if the section could not
  ## be located unambiguously.
  var found = -1
  for i in 0 .. payload.len - DMA_SEC_LEN - 1:
    if payload[i] == char(DMA_TAG) and payload[i + DMA_SEC_LEN] == char(GPIO_TAG):
      if found >= 0: return false  # ambiguous
      found = i
  if found < 0: return false
  # Delete from the last channel backwards so earlier offsets stay valid.
  for ch in countdown(3, 0):
    let at = found + 1 + ch * DMA_CH_LEN + DMA_COUNT_AT
    payload.delete(at .. at + 1)
  true

proc park_in_intr_wait(emu: GBA; shifted: bool) =
  ## The shape an HLE IntrWait leaves the machine in, current (`shifted`) or
  ## pre-32dd8bb; copied from hle_intr_wait, not from the migration.
  let cpu = emu.cpu
  cpu.cpsr.mode = 0x1F        # System: sys_sp is plain r13
  cpu.r[13] = 0x03007F00'u32  # somewhere sane in IWRAM
  cpu.r[2]  = 0xCAFEBABE'u32  # the caller's r2 ...
  cpu.r[4]  = 0x12345678'u32  # ... r4 ...
  cpu.r[14] = 0x08001234'u32  # ... and lr
  cpu.intr_wait_active = true
  cpu.intr_wait_mask = 1
  cpu.intr_wait_resume_addr = 0x08000100'u32
  cpu.halted = true
  if shifted:
    let usp = cpu.r[13]
    emu.bus.write_word_internal(usp - 4,  cpu.r[14])
    emu.bus.write_word_internal(usp - 8,  cpu.r[2])
    emu.bus.write_word_internal(usp - 12, 0x170'u32)
    emu.bus.write_word_internal(usp - 16, cpu.r[4])
    cpu.r[13] = usp - 16
    cpu.r[4] = 1
    cpu.r[2] = uint32(emu.bus.wram_chip[0x7FF8]) or
               (uint32(emu.bus.wram_chip[0x7FF9]) shl 8)
    cpu.r[14] = 0x34C'u32

proc run_intr_wait_migration() =
  echo "GBA rev 3 -> 4: the IntrWait frame retrofit is the exact inverse"
  # (a) the shape this build produces
  let a = new_gba_for(GBA_ROMS[0][0])
  for _ in 0 ..< 30: a.step_frame()
  a.park_in_intr_wait(shifted = true)
  let rev4 = a.state_payload()

  # (b) the shape the old build produced for the same wait
  let b = new_gba_for(GBA_ROMS[0][0])
  for _ in 0 ..< 30: b.step_frame()
  b.park_in_intr_wait(shifted = false)
  var rev3 = b.state_payload()
  # A rev-3 payload has no halt_resume_pop byte (rev 4) and no per-channel
  # DMA `count` (rev 5); every later field addition belongs here too.
  check(rev3.len == rev4.len, "the two parked payloads differ only by the flag")
  rev3.delete(HALT_RESUME_POP_OFFSET .. HALT_RESUME_POP_OFFSET)
  check(strip_dma_count(rev3), "rev-5 DMA count fields located and removed")

  # (c) read the rev-3 payload as rev 3 and compare against (a)
  let c = new_gba_for(GBA_ROMS[0][0])
  for _ in 0 ..< 30: c.step_frame()
  var migrated = false
  try:
    c.apply_state_payload(rev3, 3)
    migrated = true
  except CatchableError:
    check(false, "rev-3 IntrWait state applies", getCurrentExceptionMsg())
  if migrated:
    check(c.state_payload() == rev4,
          "migrated rev-3 payload is byte-identical to the rev-4 one")
    check(c.cpu.r[13] == 0x03007F00'u32 - 16, "System sp lowered by the frame")
    check(c.bus.read_word_internal(0x03007F00'u32 - 8) == 0xCAFEBABE'u32,
          "caller's r2 is where the resume pops it from")
    check(c.bus.read_word_internal(0x03007F00'u32 - 16) == 0x12345678'u32,
          "caller's r4 is where the resume pops it from")
    check(c.bus.read_word_internal(0x03007F00'u32 - 4) == 0x08001234'u32,
          "caller's lr is where the resume pops it from")

  # (d) not reconstructible, so must be refused: intr_wait_active with the
  # CPU running means the user IRQ handler owns the System stack.
  let d = new_gba_for(GBA_ROMS[0][0])
  for _ in 0 ..< 30: d.step_frame()
  d.park_in_intr_wait(shifted = false)
  d.cpu.halted = false
  var rev3_running = d.state_payload()
  rev3_running.delete(HALT_RESUME_POP_OFFSET .. HALT_RESUME_POP_OFFSET)
  check(strip_dma_count(rev3_running), "rev-5 DMA count fields located and removed (running)")
  let e = new_gba_for(GBA_ROMS[0][0])
  for _ in 0 ..< 30: e.step_frame()
  let untouched = e.state_payload()
  var refused = false
  try:
    e.apply_state_payload(rev3_running, 3)
  except StateError:
    refused = true
  check(refused, "rev-3 IntrWait state with the handler running is refused")

  # Refusing must leave the caller able to recover (load_state_bytes's
  # backup/restore).
  e.apply_state_payload(untouched)
  check(e.state_payload() == untouched, "the pre-load state restores cleanly")


proc run_in_process_boundary() =
  ## The rewind ring, rollback snapshots and clip history are padded to a
  ## fixed length (PAD_RATIONALE in common/scheduler.nim); anything that can
  ## reach a FILE is not. Getting the boundary wrong writes bytes no other
  ## build can read.
  echo ""
  echo "--- in-process vs file payload boundary ---"

  for (romName, isGba) in [(GBA_ROMS[0][0], true), (GB_ROMS[0][0], false)]:
    let tag = (if isGba: "GBA" else: "GB") & ": "
    var inproc, fileImg, reInproc: string
    if isGba:
      let e = new_gba_for(romName)
      for _ in 0 ..< 40: e.step_frame()
      inproc = e.state_payload()
      fileImg = e.state_bytes()
      # in-process round trip
      for _ in 0 ..< 5: e.step_frame()
      e.apply_state_payload(inproc)
      reInproc = e.state_payload()
      # file round trip, through the real file reader
      check(e.load_state_bytes(fileImg), tag & "file image loads")
      check(e.state_bytes() == fileImg, tag & "file image re-serializes identically")
    else:
      let g = new_gb_for(romName)
      for _ in 0 ..< 40: g.step_frame()
      inproc = g.state_payload()
      fileImg = g.state_bytes()
      for _ in 0 ..< 5: g.step_frame()
      g.apply_state_payload(inproc)
      reInproc = g.state_payload()
      check(g.load_state_bytes(fileImg), tag & "file image loads")
      check(g.state_bytes() == fileImg, tag & "file image re-serializes identically")

    check(reInproc == inproc, tag & "in-process payload round-trips byte-exactly")
    # The file image carries a header and is still smaller than the bare
    # in-process payload: that is the padding.
    check(fileImg.len < inproc.len,
          tag & "file image is smaller than the padded in-process payload",
          "file " & $fileImg.len & " vs in-process " & $inproc.len)

  # Padding sits immediately before a section tag, so a writer/reader that
  # disagree about it cannot pass silently.
  block:
    let s0 = new_scheduler()
    var w = Writer()
    s0.save_to(w, pad = true)
    w.write_tag(0x5A'u8)
    var r = Reader(buf: w.buf)
    let s1 = new_scheduler()
    var caught = false
    try:
      s1.load_from(r, pad = false)     # deliberately mismatched
      r.expect_tag(0x5A'u8)
    except CatchableError:
      caught = true
    check(caught, "a pad-flag mismatch is caught at the next section tag")

when isMainModule:
  # Run from the repo root: the ROM and corpus paths are relative to it.
  if paramCount() >= 1 and paramStr(1) == "--write-corpus":
    write_corpus()
    quit(0)
  run_roundtrip()
  run_rom_identity()
  run_cart_shapes()
  run_rejections()
  run_intr_wait_migration()
  run_corpus()
  run_in_process_boundary()
  echo ""
  if failures > 0:
    echo failures, " save-state compatibility check(s) FAILED"
    quit(1)
  echo "all save-state compatibility checks passed"
