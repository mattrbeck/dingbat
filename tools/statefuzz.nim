## Hostile-input fuzzer for the save-state loader. The FNV-1a payload hash is
## an integrity check, not a security control, so mutants are re-sealed
## (payload_len/payload_hash rewritten) to get past parse_state_payload and
## into the per-subsystem readers.
##
## Per iteration: load (does apply_state_payload survive?) then run N frames
## (a state that loads and faults later is the same bug).
##
## Build (or `nimble statefuzz_build`):
##   nim c -d:test_harness -d:release -d:gba_quirky=false --path:src -o:statefuzz tools/statefuzz.nim
## (-d:gba_quirky=false: a quirky core goes on past a failed check, so a stray
## index is a SIGSEGV that ends the run instead of a Defect it counts)
##
## `sweep` sets every payload byte in turn and exits non-zero on any
## uncontained Defect, so it is usable as a gate:
##   ./statefuzz roms/some.gb  sweep 255
##   ./statefuzz roms/some.gba sweep 255
## A sweep takes a payload offset range after the post-frame count, to split
## it over processes: `sweep 255 4 0 100000` (a DS sweep also `sweep 255 4
## 2/8`: the third of eight equal shares).
##
## DS states (a `.nds` ROM) go through the same modes and the DS loader
## (nds/savestate.nim). Build with the DS core unquirky and its renderers
## index-checked too (or `nimble statefuzz_build`):
##   nim c -d:test_harness -d:release -d:gba_quirky=false -d:nds_quirky=false
##     -d:nds_render_checks --path:src -o:statefuzz tools/statefuzz.nim
## The base state is the machine 120 frames after a direct boot, or
## STATEFUZZ_BASE: a frame count, or a state file (an `ndsrun --state-save`
## of a game in play: `STATEFUZZ_BASE=ss_7000.state ./statefuzz ss.nds sweep
## 255`). BIOS dumps from $DINGBAT_NDS_BIOS, the HLE BIOS without; the RTC
## runs on emulated time from 2004-01-01 (as `ndsrun --rtc`). A DS payload is
## mostly memory (main RAM, VRAM, the save chip: ~6 MB for a game), which the
## guest writes itself, so the core already takes any value there; the sweep
## and the mutants change only the other bytes (NDS_NOT_FUZZED; `blocks`
## lists the large arrays and which are left alone, `where OFFSET..` names
## the field at an offset). Each DS mutant runs in a child process, so a
## fault no check saw (a signal) or a hang is counted like a Defect.

import std/[os, strutils, random, strformat, posix, times]
import dingbat/common/serialize
import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/nds/[nds, savestate]
import dingbat/nds/io/rtc
import dingbat/gba/rtc_calendar
import dingbat/common/test_output

proc patch_le32(s: var string; pos: int; v: uint32) =
  for i in 0 .. 3: s[pos + i] = char(uint8(v shr (8 * i)))

proc reseal(image: var string) =
  ## Recompute payload_len/payload_hash over the mutated payload.
  let payload_len = image.len - STATE_HEADER_SIZE
  patch_le32(image, 24, uint32(payload_len))
  patch_le32(image, 28, fnv1a(image[STATE_HEADER_SIZE ..< image.len]))

proc strip_trailers(image: string): string =
  ## Header and payload only: the base every mutant starts from, so that
  ## reseal's "everything after the header" is exactly the payload.
  var r = Reader(buf: image, pos: 24)
  result = image[0 ..< STATE_HEADER_SIZE + int(r.read_u32())]
  result[14] = '\0'
  result[15] = '\0'

proc mutate(base: string; rng: var Rand; aggressive: bool;
            fields: seq[int] = @[]): string =
  ## `fields`: the payload offsets to choose from (all of them when empty)
  result = base
  let payload_lo = STATE_HEADER_SIZE
  let n = if aggressive: rng.rand(1 .. 64) else: rng.rand(1 .. 4)
  for _ in 0 ..< n:
    let i = if fields.len > 0: payload_lo + fields[rng.rand(fields.high)]
            else: rng.rand(payload_lo ..< result.len)
    case rng.rand(0 .. 3)
    of 0: result[i] = char(rng.rand(0 .. 255))
    of 1: result[i] = char(0xFF)
    of 2: result[i] = char(0x00)
    else:
      # flip one bit — the cheapest way to hit a length/index field's high bits
      result[i] = char(uint8(result[i]) xor uint8(1 shl rng.rand(0 .. 7)))
  if aggressive and rng.rand(0 .. 9) == 0:
    # truncate: exercises the reader's `need()` guards
    result.setLen(max(STATE_HEADER_SIZE + 1, rng.rand(payload_lo ..< result.len)))
  reseal(result)

# ---------------------------------------------------------------------------
# DS

const
  NDS_BLOCK_MIN = 256
    ## A numeric array or seq this long is memory or a table (`blocks`)
  NDS_NOT_FUZZED = ["main_ram", "shared_wram", "arm7_wram", "itcm", "dtcm",
                    "palette", "oam", "mem", "data", "save", "exp_ram", "ram",
                    "mmem_line", "top", "bottom", "color", "frame", "line",
                    "slot_of", "page_apart", "dperm", "cperm", "mdperm", "mcperm"]
    ## The blocks a sweep leaves alone: memories the guest writes itself
    ## (VRAM is `mem`, the save chip `data`, the GBA slot's `save` and
    ## `exp_ram`, wifi's `ram`), pictures (the screens, the 3D frame, a
    ## line), and the tables a load rebuilds over what the state says (the
    ## caches' per-line and per-page tables, the protection unit's
    ## rights). The other tables (cache tags, register files) are swept.
  HANG_SECONDS = 20.0
    ## A mutant whose load and frames take longer has hung the machine

proc nds_machine(rom: seq[uint8]): NDS =
  let b = getEnv("DINGBAT_NDS_BIOS")
  proc file(name: string): seq[uint8] =
    if b.len == 0 or not fileExists(b / name): @[]
    else: cast[seq[uint8]](readFile(b / name))
  result = new_nds(rom, file("bios9.bin"), file("bios7.bin"), file("firmware.bin"))
  result.rtc.set_fixed_clock(result.sched, to_calendar_seconds(2004, 1, 1, 0, 0, 0))

proc nds_main(args: seq[string]) =
  let rom = cast[seq[uint8]](readFile(args[0]))
  let m = nds_machine(rom)

  if args[1] == "reject":
    if args.len < 3:
      echo "usage: statefuzz <rom> reject <state-file>"
      quit 2
    let ok = m.load_state_bytes(readFile(args[2]))
    echo &"{args[2].extractFilename}: ", (if ok: "ACCEPTED" else: "refused")
    if not ok:
      echo &"  kind   {last_state_reject_kind}"
      echo &"  detail {last_state_error}"
    quit(if ok: 0 else: 1)

  # The base state: a frame count or a state file (STATEFUZZ_BASE)
  let base_arg = getEnv("STATEFUZZ_BASE", "120")
  if base_arg.allCharsInSet(Digits):
    for _ in 0 ..< parseInt(base_arg): m.run_frame()
  elif not m.load_state_bytes(readFile(base_arg)):
    echo &"{base_arg}: {last_state_reject_kind}: {last_state_error}"
    quit 2

  if args[1] == "dump":
    if args.len < 3:
      echo "usage: statefuzz <rom> dump <out.state>"
      quit 2
    writeFile(args[2], m.state_bytes())
    echo &"wrote {args[2]} (frame {m.gpu.frame_count})"
    quit 0

  let base = strip_trailers(m.state_bytes())
  let blocks = m.state_blocks(NDS_BLOCK_MIN)
  var fields: seq[int]
  block:
    var at = 0
    for b in blocks:
      if b.name notin NDS_NOT_FUZZED: continue
      for o in at ..< b.lo: fields.add o
      at = b.hi
    for o in at ..< base.len - STATE_HEADER_SIZE: fields.add o
  echo &"base: frame {m.gpu.frame_count}, payload {base.len - STATE_HEADER_SIZE} B, " &
       &"{fields.len} bytes to fuzz"

  if args[1] == "where":
    # Name the field at each payload offset (a sweep's finding)
    let all = m.state_blocks(1)
    for a in args[2 .. ^1]:
      let off = parseInt(a)
      var section = ""
      for b in all:
        if b.lo == b.hi:
          if b.lo <= off: section = b.name
        elif off >= b.lo and off < b.hi:
          echo &"  {off}: {section} {b.name} (+{off - b.lo} of {b.hi - b.lo} B)"
          break
    quit 0

  if args[1] == "blocks":
    for b in blocks:
      echo &"  {b.lo:>8} {b.hi - b.lo:>8}  {b.name}",
           (if b.name in NDS_NOT_FUZZED: "  (not fuzzed)" else: "")
    quit 0

  let sweep_mode = args[1] == "sweep"
  let iters = if sweep_mode or args[1] == "poke": 0 else: parseInt(args[1])
  let seed = if args.len > 2: parseInt(args[2]) else: 12345
  let post = if args.len > 3: parseInt(args[3]) else: 4

  if args[1] == "poke":
    let off = STATE_HEADER_SIZE + seed
    var mutant = base
    mutant[off] = char(uint8(post and 0xFF))
    reseal(mutant)
    echo &"poking payload offset {seed} := 0x{toHex(post and 0xFF, 2)}"
    echo "  load -> ", m.load_state_bytes(mutant), " ", last_state_error
    for i in 0 ..< 8:
      echo "  frame ", i
      m.run_frame()
    echo "  survived"
    quit 0

  proc try_one(mutant, what: string; refused, bad: var int) =
    ## Load and run `post` frames in a child process (a copy of this one,
    ## the machine in the base state), so that a fault no check saw (a
    ## signal) or a hang ends the child, not the sweep.
    flushFile(stdout)
    let pid = fork()
    if pid == 0:
      var code = 0
      var phase = "LOAD"
      try:
        if m.load_state_bytes(mutant):
          phase = "RUN"
          for _ in 0 ..< post: m.run_frame()
        else: code = 1
      except Defect, CatchableError:
        echo &"[{phase} DEFECT] {what}: {getCurrentExceptionMsg()}"
        code = 2
      flushFile(stdout)
      exitnow(cint(code))
    var status: cint
    let t0 = epochTime()
    while waitpid(pid, status, WNOHANG) == 0:
      if epochTime() - t0 > HANG_SECONDS:
        discard kill(pid, SIGKILL)
        discard waitpid(pid, status, 0)
        echo &"[HANG] {what}: no end after {HANG_SECONDS} s"
        inc bad
        return
      sleep(1)
    if WIFSIGNALED(status):
      echo &"[FAULT] {what}: signal {WTERMSIG(status)}"
      inc bad
    elif WEXITSTATUS(status) == 1: inc refused
    elif WEXITSTATUS(status) != 0: inc bad

  if sweep_mode:
    let bval = char(uint8(seed and 0xFF))
    let total = base.len - STATE_HEADER_SIZE
    # A payload offset range [lo, hi), or `K/N`: the Kth of N equal shares
    # of the bytes to fuzz
    var lo = 0
    var hi = total
    if args.len > 4 and '/' in args[4]:
      let kn = args[4].split('/')
      let (k, nn) = (parseInt(kn[0]), parseInt(kn[1]))
      let a = fields.len * k div nn
      let b = fields.len * (k + 1) div nn
      lo = if a < fields.len: fields[a] else: total
      hi = if b < fields.len: fields[b] else: total
    elif args.len > 4:
      lo = parseInt(args[4])
      if args.len > 5: hi = min(parseInt(args[5]), total)
    var bad, refused, tried = 0
    for poff in fields:
      if poff < lo or poff >= hi: continue
      let off = STATE_HEADER_SIZE + poff
      if base[off] == bval: continue
      var mutant = base
      mutant[off] = bval
      reseal(mutant)
      inc tried
      try_one(mutant, &"payload offset {poff} (0x{toHex(poff, 6)}) := " &
                      &"0x{toHex(int(uint8(bval)), 2)}", refused, bad)
      if tried mod 2000 == 0: echo &"  ... {tried} tried, at offset {poff}"
    echo &"\nSWEEP {args[0]} byte=0x{toHex(int(uint8(bval)), 2)} " &
         &"offsets {lo}..<{hi} of {total}: {tried} bytes tried, " &
         &"refused {refused}, UNCONTAINED {bad}"
    quit(if bad > 0: 1 else: 0)

  var rng = initRand(seed)
  var bad, refused = 0
  for it in 0 ..< iters:
    let mutant = mutate(base, rng, aggressive = (it mod 3 == 0), fields)
    let was = bad
    try_one(mutant, &"iter {it}", refused, bad)
    if bad > was:
      # the bytes it changed, for `where` and `poke`
      var changed: seq[string]
      for i in STATE_HEADER_SIZE ..< min(base.len, mutant.len):
        if base[i] != mutant[i]:
          changed.add &"{i - STATE_HEADER_SIZE}:=0x{toHex(int(uint8(mutant[i])), 2)}"
      echo "  changed ", changed.join(" "),
           (if mutant.len < base.len: &" (cut to {mutant.len - STATE_HEADER_SIZE})" else: "")
  echo &"\n{args[0]}  {iters} mutants (seed {seed}, {post} post-frames)"
  echo &"  refused cleanly    {refused}"
  echo &"  accepted           {iters - refused - bad}"
  echo &"  UNCONTAINED        {bad}"
  quit(if bad > 0: 1 else: 0)

when isMainModule:
  let args = commandLineParams()
  if args.len < 2:
    echo "usage: statefuzz <rom> <iterations|sweep|poke|reject|dump|blocks|where> " &
         "[seed|byteval|path] [post_frames]"
    quit 2
  let rom = args[0]
  if rom.splitFile().ext.toLowerAscii() == ".nds":
    nds_main(args)
  let is_gba = rom.splitFile().ext.toLowerAscii() in [".gba", ".bin"]

  if args[1] == "reject":
    # Offer a file to the core and report which refusal came back (the
    # classification each frontend turns into a sentence). Pairs with
    # tools/make_bad_states.py.
    if args.len < 3:
      echo "usage: statefuzz <rom> reject <state-file>"
      quit 2
    let data = readFile(args[2])
    last_state_error = ""
    last_state_reject_kind = srkNone
    let ok = if is_gba:
               let e = new_gba("", rom, run_bios = false, use_hle = true)
               e.test_output = new_test_output()
               e.post_init()
               e.load_state_bytes(data)
             else:
               let e = new_gb("", rom, headless = true,
                              run_bios = false)
               e.test_output = new_test_output()
               e.post_init()
               e.load_state_bytes(data)
    echo &"{args[2].extractFilename}: ", (if ok: "ACCEPTED" else: "refused")
    if not ok:
      echo &"  kind   {last_state_reject_kind}"
      echo &"  detail {last_state_error}"
    quit(if ok: 0 else: 1)

  if args[1] == "dump":
    # A pristine .state for this ROM, for tools/make_bad_states.py to corrupt.
    if args.len < 3:
      echo "usage: statefuzz <rom> dump <out.state> [frames]"
      quit 2
    let frames = if args.len > 3: parseInt(args[3]) else: 120
    var good: string
    if is_gba:
      let e = new_gba("", rom, run_bios = false, use_hle = true)
      e.test_output = new_test_output()
      e.post_init()
      for _ in 0 ..< frames: e.step_frame()
      good = e.state_bytes()
    else:
      let e = new_gb("", rom, headless = true, run_bios = false)
      e.test_output = new_test_output()
      e.post_init()
      for _ in 0 ..< frames: e.step_frame()
      good = e.state_bytes()
    writeFile(args[2], good)
    echo &"wrote {args[2]} ({good.len} B, frame {frames})"
    quit 0

  let sweep_mode = args[1] == "sweep"
  let iters = if sweep_mode or args[1] == "poke": 0 else: parseInt(args[1])
  let seed = if args.len > 2: parseInt(args[2]) else: 12345
  let post = if args.len > 3: parseInt(args[3]) else: 4
  var rng = initRand(seed)

  # A pristine state to mutate.
  var base: string
  if is_gba:
    let e = new_gba("", rom, run_bios = false, use_hle = true)
    e.test_output = new_test_output()
    e.post_init()
    for _ in 0 ..< 120: e.step_frame()
    base = strip_trailers(e.state_bytes())
  else:
    let e = new_gb("", rom, headless = true, run_bios = false)
    e.test_output = new_test_output()
    e.post_init()
    for _ in 0 ..< 120: e.step_frame()
    base = strip_trailers(e.state_bytes())

  if args[1] == "poke":
    # Reproduce one sweep finding: set payload byte `seed` to `post`. Build
    # with --stacktrace:on to get the faulting line.
    let off = STATE_HEADER_SIZE + seed
    var mutant = base
    mutant[off] = char(uint8(post and 0xFF))
    reseal(mutant)
    echo &"poking payload offset {seed} := 0x{toHex(post and 0xFF, 2)}"
    if is_gba:
      let e = new_gba("", rom, run_bios = false, use_hle = true)
      e.test_output = new_test_output()
      e.post_init()
      echo "  load -> ", e.load_state_bytes(mutant)
      for i in 0 ..< 8:
        echo "  frame ", i
        e.step_frame()
    else:
      let e = new_gb("", rom, headless = true, run_bios = false)
      e.test_output = new_test_output()
      e.post_init()
      echo "  load -> ", e.load_state_bytes(mutant)
      for i in 0 ..< 8:
        echo "  frame ", i
        e.step_frame()
    echo "  survived"
    quit 0

  if sweep_mode:
    # Single-byte sweep: set every payload byte in turn to `seed` (the byte
    # value, default 0xFF) and check the loader and four frames of emulation
    # survive. Visits every length, index and enum field exactly once.
    let bval = char(uint8(seed and 0xFF))
    var bad = 0
    var refused = 0
    let total = base.len - STATE_HEADER_SIZE
    # Optional payload offset range [lo, hi), to shard a sweep over processes
    # (a GBA state is ~500k offsets, hours on one core)
    let lo = if args.len > 4: parseInt(args[4]) else: 0
    let hi = if args.len > 5: min(parseInt(args[5]), total) else: total
    for off in STATE_HEADER_SIZE + lo ..< STATE_HEADER_SIZE + hi:
      if base[off] == bval: continue
      var mutant = base
      mutant[off] = bval
      reseal(mutant)
      let poff = off - STATE_HEADER_SIZE
      try:
        if is_gba:
          let e = new_gba("", rom, run_bios = false, use_hle = true)
          e.test_output = new_test_output()
          e.post_init()
          if e.load_state_bytes(mutant):
            for _ in 0 ..< post: e.step_frame()
          else: inc refused
        else:
          let e = new_gb("", rom, headless = true, run_bios = false)
          e.test_output = new_test_output()
          e.post_init()
          if e.load_state_bytes(mutant):
            for _ in 0 ..< post: e.step_frame()
          else: inc refused
      except Defect, CatchableError:
        inc bad
        echo &"[UNCONTAINED] payload offset {poff} (0x{toHex(poff, 6)}) := " &
             &"0x{toHex(int(uint8(bval)), 2)}: {getCurrentExceptionMsg()}"
      if (off - STATE_HEADER_SIZE) mod 20000 == 0:
        echo &"  ... {poff}/{total}"
    echo &"\nSWEEP {rom} byte=0x{toHex(int(uint8(bval)), 2)} " &
         &"offsets {lo}..<{hi} of {total}, refused {refused}, UNCONTAINED {bad}"
    quit(if bad > 0: 1 else: 0)

  var accepted = 0      # loaded without raising
  var rejected = 0      # refused with a StateError (the good path)
  var crashed = 0       # a defect the loader did NOT convert into a rejection
  var ran_ok = 0        # accepted AND survived `post` frames
  var run_crash = 0     # accepted then faulted while running

  for it in 0 ..< iters:
    let mutant = mutate(base, rng, aggressive = (it mod 3 == 0))
    try:
      if is_gba:
        let e = new_gba("", rom, run_bios = false, use_hle = true)
        e.test_output = new_test_output()
        e.post_init()
        if e.load_state_bytes(mutant):
          inc accepted
          try:
            for _ in 0 ..< post: e.step_frame()
            inc ran_ok
          except Defect, CatchableError:
            inc run_crash
            echo &"[RUN CRASH] iter {it}: {getCurrentExceptionMsg()}"
        else:
          inc rejected
      else:
        let e = new_gb("", rom, headless = true, run_bios = false)
        e.test_output = new_test_output()
        e.post_init()
        if e.load_state_bytes(mutant):
          inc accepted
          try:
            for _ in 0 ..< post: e.step_frame()
            inc ran_ok
          except Defect, CatchableError:
            inc run_crash
            echo &"[RUN CRASH] iter {it}: {getCurrentExceptionMsg()}"
        else:
          inc rejected
    except Defect:
      inc crashed
      echo &"[LOAD DEFECT] iter {it}: {getCurrentExceptionMsg()}"
    except CatchableError:
      inc crashed
      echo &"[LOAD ESCAPE] iter {it}: {getCurrentExceptionMsg()}"

  echo &"\n{rom}  {iters} mutants (seed {seed}, {post} post-frames)"
  echo &"  refused cleanly    {rejected}"
  echo &"  accepted           {accepted}  (ran {post} frames OK: {ran_ok})"
  echo &"  DEFECT/ESCAPE      {crashed}   <- loader failed to contain it"
  echo &"  RUN CRASH          {run_crash} <- loaded, then faulted while running"
  quit(if crashed + run_crash > 0: 1 else: 0)
