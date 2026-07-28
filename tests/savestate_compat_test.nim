## Save-state format compatibility guards.
##
## Why this exists: users lose save states to routine emulator updates, and
## until this file nothing in the tree noticed. The two ways it happens are
## both silent at build time:
##
##   1. STATE_VERSION is bumped, and `parse_state_payload` then refuses EVERY
##      older state — for BOTH cores, even when the change touched only one of
##      them. That is what invalidated the 2026-07-24 states: b398a7b added one
##      GB PPU field (v5 -> v6) while the GBA payload stayed byte-identical, so
##      every GBA state in existence was rejected for a GB reason.
##   2. A field is added to a subsystem, or an EventType is inserted rather
##      than appended, WITHOUT a version bump. Nothing rejects those states —
##      the reader walks off by a few bytes and either trips a section tag or,
##      worse, restores plausible garbage.
##
## The corpus below catches both. `tests/states/*.state` are real state images
## taken from the committed test ROMs at the format version named in each
## filename; this test boots the matching ROM and asserts they still load.
##
##   - Break the format silently (case 2)  -> the load fails on a section tag,
##     a truncation, or an unknown event kind.
##   - Bump STATE_VERSION (case 1)         -> the load fails with the version
##     message, which is the point: it makes "this update throws away every
##     user's save states" a decision someone has to take on purpose.
##
## When it fails after an INTENTIONAL format change, the options are, in order
## of preference:
##   a. Make the reader version-tolerant (read the old layout, fill the new
##      field with a sane default) and keep the corpus entry loading. See
##      docs/research_savestate_compat.md.
##   b. Bump the version, keep the old corpus entries as documentation of what
##      is being dropped, and regenerate with `--write-corpus`. Users lose
##      their states; say so in the commit message.
## Never "fix" it by deleting the corpus entry.
##
## Run with: nimble test_savestate_compat
## Regenerate the corpus: <this binary> --write-corpus

import std/[os, strutils, algorithm]
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

# ---------------------------------------------------------------------------
# 1. EventType ordinals are the save-state format.
#
# scheduler.save_to writes each pending event's kind as `ord(kind)` and
# load_from reads it straight back, so the ordinal of every enumerator is
# frozen the moment a state file exists. scheduler.nim says so in a comment
# ("Appended, never inserted"), and a comment is not a guard: inserting a kind
# anywhere above the end silently reinterprets every pending event in every
# existing state as the wrong kind — a PPU deadline becomes a timer deadline
# and the machine wedges or desyncs, with no error anywhere.
#
# This block is the guard. It is compile-time, so a reorder fails the BUILD,
# not a run. Adding a kind at the end is fine and only needs a new line here;
# any other change to the list makes this file stop compiling, which is the
# moment to ask whether users' states can survive it.
# ---------------------------------------------------------------------------
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
  # Kinds appended after the block above. Appending is safe for OLD states
  # (their ordinals are untouched); it does mean a state written by the NEW
  # build can carry a kind an OLD build rejects, which is a downgrade, not an
  # update, and is out of scope.
  doAssert ord(etSerial) == 19
  doAssert ord(etDMA) == 20
  doAssert ord(etCameraDone) == 21
  doAssert ord(high(EventType)) == 21,
    "an EventType was appended without pinning its ordinal here"

# ---------------------------------------------------------------------------
# 2. Header layout constants.
#
# Every state ever written begins with these. Changing one does not just break
# old states, it breaks the *detection* of old states — parse_state_payload
# would stop recognising them as dingbat states at all, so a user gets "not a
# dingbat save state" instead of anything actionable.
# ---------------------------------------------------------------------------
static:
  doAssert STATE_MAGIC == "DGBSTATE"
  doAssert STATE_HEADER_SIZE == 32
  doAssert STATE_FLAG_THUMBNAIL == 0x0001'u16
  doAssert ord(ckGBA) == 0 and ord(ckGB) == 1

# ---------------------------------------------------------------------------
# 3. The corpus.
# ---------------------------------------------------------------------------

const
  ROM_DIR = "tests/roms"
  CORPUS_DIR = "tests/states"
  # ROMs the corpus is taken from, and how many frames to run first. Small,
  # already committed, and booted by CI elsewhere. The frame counts are only
  # "far enough in that the subsystems have state worth serializing".
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
  for path in entries:
    # <rom-with-extension>.v<N>.state
    let base = path.extractFilename
    let parts = base.split('.')
    if parts.len < 3:
      check(false, "corpus filename is <rom>.v<N>.state", base)
      continue
    let rom = parts[0 .. ^3].join(".")
    let data = readFile(path)
    let ver = file_version(data)
    let label = base & " (v" & $ver & ")"
    if not fileExists(ROM_DIR / rom):
      check(false, label, "ROM " & rom & " is missing from " & ROM_DIR)
      continue
    let ok =
      if file_core(data) == uint8(ckGBA): new_gba_for(rom).load_state_bytes(data)
      else: new_gb_for(rom).load_state_bytes(data)
    check(ok, label,
          (if ok: "" else:
             "this state no longer loads. If the format change was deliberate, " &
             "see the header of tests/savestate_compat_test.nim before touching " &
             "this file."))

proc run_roundtrip() =
  ## The floor the corpus sits on: a state taken by THIS build must load in
  ## THIS build. Cheap, and it separates "the format moved" from "the
  ## serializer is broken outright" when both tests go red at once.
  echo "round-trip: this build reads its own states"
  for (rom, frames) in GBA_ROMS:
    let emu = new_gba_for(rom)
    for _ in 0 ..< frames: emu.step_frame()
    let bytes = emu.state_bytes(thumbnail = true)
    check(emu.load_state_bytes(bytes), "GBA " & rom)
    let (tw, th, px) = parse_state_thumbnail(bytes)
    check(tw > 0 and th > 0 and px.len == tw * th * 2,
          "GBA " & rom & " thumbnail trailer")
  for (rom, frames) in GB_ROMS:
    let emu = new_gb_for(rom)
    for _ in 0 ..< frames: emu.step_frame()
    let bytes = emu.state_bytes(thumbnail = true)
    check(emu.load_state_bytes(bytes), "GB " & rom)
    let (tw, th, px) = parse_state_thumbnail(bytes)
    check(tw > 0 and th > 0 and px.len == tw * th * 2,
          "GB " & rom & " thumbnail trailer")

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

when isMainModule:
  # Run from the repo root: the ROM and corpus paths are relative to it.
  if paramCount() >= 1 and paramStr(1) == "--write-corpus":
    write_corpus()
    quit(0)
  run_roundtrip()
  run_rejections()
  run_corpus()
  echo ""
  if failures > 0:
    echo failures, " save-state compatibility check(s) FAILED"
    quit(1)
  echo "all save-state compatibility checks passed"
