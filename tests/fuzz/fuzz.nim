## libFuzzer targets for the bytes dingbat takes from outside: a save state
## (a file, or a link peer's), a packed stream, a zip. One binary per target,
## chosen with -d:fuzz_target=gbstate|gbastate|inflate|zip; tools/fuzz.sh
## builds and runs them.
##
## A state target's input is a machine index and a whole state image. The
## image's length and hash are set right before it is loaded (a fuzzer cannot
## guess a hash, and a peer can compute one); every other byte, header
## included, is the fuzzer's. A state that loads is then run for two frames
## and saved again: the fields a loader lets through are used.
##
## DINGBAT_FUZZ_SEEDS=<dir> writes the genuine images as a seed corpus and
## exits.

import std/[os, strutils]
import dingbat/common/[serialize, inflate_bound]

const fuzz_target {.strdefine.} = ""

proc NimMain() {.importc, cdecl.}
proc c_abort() {.importc: "abort", header: "<stdlib.h>", noreturn.}
proc c_freopen(path, mode: cstring; f: File): File {.importc: "freopen", header: "<stdio.h>".}

var seeds: seq[string]
var calls, tried, loaded: int     # DINGBAT_FUZZ_STATS=1: how many states loaded, on stderr

proc reseal(image: var string) =
  let n = image.len - STATE_HEADER_SIZE
  for i in 0 .. 3: image[24 + i] = char(uint8(uint32(n) shr (8 * i)))
  let h = fnv1a(image[STATE_HEADER_SIZE ..< image.len])
  for i in 0 .. 3: image[28 + i] = char(uint8(h shr (8 * i)))

proc fixtures(rom: string): seq[string] =
  ## The older builds' states of `rom` kept under tests/states, unpacked.
  for path in walkFiles("tests/states" / (rom & ".*.state")):
    try: result.add unpack_state(readFile(path))
    except CatchableError: discard

when fuzz_target == "gbstate":
  import dingbat/gb/gb

  type Machine = object
    gb: GB
    home: string    # its own state: where every input starts from

  var machines: seq[Machine]

  proc add_machine(path: string; frames: int) =
    var g: GB
    try:
      g = new_gb("", path, headless = true, run_bios = false)
      g.post_init()
    except CatchableError: return
    for _ in 0 ..< frames: g.step_frame()
    let home = g.state_bytes()
    if not g.load_state_bytes(home):
      stderr.writeLine path, ": its own state does not load (", last_state_error, "); left out"
      return
    machines.add Machine(gb: g, home: home)
    seeds.add char(machines.high) & machines[^1].home
    for f in fixtures(path.extractFilename): seeds.add char(machines.high) & f

  proc setup() =
    add_machine("tests/roms/gblinktest.gb", 30)
    add_machine("tests/roms/gbhdmatest.gbc", 30)
    # A blank cartridge of each kind with state of its own: the mappers.
    for kind in [0x00'u8, 0x03, 0x06, 0x0D, 0x10, 0x13, 0x1B, 0x1E, 0x20, 0x22,
                 0xFC, 0xFD, 0xFE, 0xFF]:
      var rom = newString(0x10000)
      rom[0x147] = char(kind)
      rom[0x148] = char(1)
      rom[0x149] = char(3)
      let path = getTempDir() / ("dingbat_fuzz_" & toHex(kind) & ".gb")
      writeFile(path, rom)
      add_machine(path, 2)

  proc one(data: string) =
    if data.len < 1 + STATE_HEADER_SIZE: return
    let m = addr machines[int(uint8(data[0])) mod machines.len]
    doAssert m.gb.load_state_bytes(m.home), "machine " & $(int(uint8(data[0])) mod machines.len) & " refuses its own state after " & $tried & " states: " & last_state_error
    var image = data[1 .. ^1]
    reseal(image)
    inc tried
    if m.gb.load_state_bytes(image):
      inc loaded
      m.gb.step_frame()
      m.gb.step_frame()
      discard m.gb.state_bytes()

elif fuzz_target == "gbastate":
  import dingbat/gba/gba

  type Machine = object
    gba: GBA
    home: string

  var machines: seq[Machine]

  proc setup() =
    for rom in ["linktest.gba", "inputrec.gba", "gbaedge.gba"]:
      var g: GBA
      try:
        g = new_gba("", "tests/roms" / rom, run_bios = false, use_hle = true)
        g.post_init()
      except CatchableError: continue
      for _ in 0 ..< 30: g.step_frame()
      let home = g.state_bytes()
      if not g.load_state_bytes(home):
        stderr.writeLine rom, ": its own state does not load (", last_state_error, "); left out"
        continue
      machines.add Machine(gba: g, home: home)
      seeds.add char(machines.high) & machines[^1].home
      for f in fixtures(rom): seeds.add char(machines.high) & f

  proc one(data: string) =
    if data.len < 1 + STATE_HEADER_SIZE: return
    let m = addr machines[int(uint8(data[0])) mod machines.len]
    doAssert m.gba.load_state_bytes(m.home), "machine " & $(int(uint8(data[0])) mod machines.len) & " refuses its own state after " & $tried & " states: " & last_state_error
    var image = data[1 .. ^1]
    reseal(image)
    inc tried
    if m.gba.load_state_bytes(image):
      inc loaded
      m.gba.step_frame()
      m.gba.step_frame()
      discard m.gba.state_bytes()

elif fuzz_target == "inflate":
  import zippy

  proc setup() =
    for plain in ["", "a", repeat("dingbat ", 500), repeat('\0', 100_000)]:
      for level in [0, 1, 9]:
        seeds.add compress(plain, level, dfZlib)
        seeds.add compress(plain, level, dfDeflate)

  proc one(data: string) =
    if data.len == 0: return
    for limit in [0, 1000, 1 shl 20]:
      try:
        doAssert zlib_inflate_capped(unsafeAddr data[0], data.len, limit).len <= limit
      except InflateError: discard
      try:
        doAssert deflate_inflate_capped(unsafeAddr data[0], data.len, limit, hint = 77).len <= limit
      except InflateError: discard
    # A packed state's way in: the header's own size as the hint.
    try: discard unpack_state(data)
    except CatchableError: discard

elif fuzz_target == "zip":
  import zippy/ziparchives
  import dingbat/frontend/game_load

  proc setup() =
    let dir = getTempDir() / "dingbat_fuzz_zip"
    createDir(dir)
    writeFile(dir / "game.gba", repeat("rom!", 2000))
    writeFile(dir / "notes.txt", "not a rom")
    let z = dir / "seed.zip"
    createZipArchive(dir & "/", z)
    seeds.add readFile(z)

  proc one(data: string) =
    try:
      let (name, rom) = zip_first_rom(data, ROM_EXTS)
      doAssert rom.len <= ZIP_ENTRY_MAX and (name.len > 0 or rom.len == 0)
    except CatchableError: discard

else:
  {.error: "-d:fuzz_target=gbstate|gbastate|inflate|zip".}

var ready = false
var stats = false

proc start() =
  # Not LLVMFuzzerInitialize: libFuzzer looks that up by name at run time,
  # and finds it only where the linker kept the symbol.
  NimMain()
  setup()
  let dir = getEnv("DINGBAT_FUZZ_SEEDS")
  if dir.len > 0:
    createDir(dir)
    for i, s in seeds: writeFile(dir / ("seed-" & $i), s)
    echo fuzz_target, ": ", seeds.len, " seeds in ", dir
    quit(0)
  # The loaders say why they refuse a state, once per input.
  discard c_freopen("/dev/null", "w", stdout)
  stats = existsEnv("DINGBAT_FUZZ_STATS")
  ready = true

proc LLVMFuzzerTestOneInput(data: ptr UncheckedArray[byte]; size: csize_t): cint {.exportc, cdecl.} =
  # An exception that reaches here is a finding (a Defect the checks raised,
  # or an error no loader caught): left to return into C it would be dropped.
  try:
    if not ready: start()
    var s = newString(int(size))
    if size > 0: copyMem(addr s[0], data, int(size))
    one(s)
  except Exception as e:
    stderr.writeLine "uncaught ", e.name, ": ", e.msg
    stderr.writeLine e.getStackTrace()
    c_abort()
  inc calls
  if (calls and 0x3FF) == 0 and stats:
    stderr.writeLine "states loaded: ", loaded, " of ", tried, " tried in ", calls, " inputs"
  0
