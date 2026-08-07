## Hostile-input fuzzer for the save-state loader.
##
## The threat model is "a stranger's file": save states get shared, and the
## format's FNV-1a payload hash is an INTEGRITY check, not a security
## control — an attacker recomputes it trivially — so this fuzzer does exactly
## that: mutate the payload, then rewrite payload_len/payload_hash so the
## mutant sails through parse_state_payload and reaches the per-subsystem
## readers, which is where the interesting code is.
##
## Two phases per iteration:
##   1. load  — does apply_state_payload survive the mutant?
##   2. run   — does the emulator survive N frames afterwards? A state that
##              loads cleanly and then faults 3 frames later is the same bug.
##
## Build (or `nimble statefuzz_build`):
##   nim c -d:test_harness -d:release --path:src -o:statefuzz tools/statefuzz.nim
##
## The audit that matters is the SWEEP, which sets every payload byte in turn:
##   ./statefuzz roms/some.gb  sweep 255
##   ./statefuzz roms/some.gba sweep 255
## It exits non-zero on any uncontained Defect, so it is usable as a gate.

import std/[os, strutils, random, strformat]
import dingbat/common/serialize
import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/common/test_output

proc patch_le32(s: var string; pos: int; v: uint32) =
  for i in 0 .. 3: s[pos + i] = char(uint8(v shr (8 * i)))

proc reseal(image: var string) =
  ## Recompute payload_hash over the (mutated) payload, exactly as an attacker
  ## would. payload_len is left alone unless the mutation changed the length.
  let payload_len = image.len - STATE_HEADER_SIZE
  patch_le32(image, 24, uint32(payload_len))
  patch_le32(image, 28, fnv1a(image[STATE_HEADER_SIZE ..< image.len]))

proc mutate(base: string; rng: var Rand; aggressive: bool): string =
  result = base
  let payload_lo = STATE_HEADER_SIZE
  let n = if aggressive: rng.rand(1 .. 64) else: rng.rand(1 .. 4)
  for _ in 0 ..< n:
    let i = rng.rand(payload_lo ..< result.len)
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

when isMainModule:
  let args = commandLineParams()
  if args.len < 2:
    echo "usage: statefuzz <rom> <iterations|sweep|poke|reject|dump> " &
         "[seed|byteval|path] [post_frames]"
    quit 2
  let rom = args[0]
  let is_gba = rom.splitFile().ext.toLowerAscii() in [".gba", ".bin"]

  if args[1] == "reject":
    # Offer a file to the core and report WHICH refusal came back — the same
    # classification each frontend turns into a sentence. Pair it with
    # tools/make_bad_states.py, which builds one deliberately broken state per
    # cause, to check that every sentence is still reachable by hand.
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
               let e = new_gb("", rom, fifo = true, headless = true,
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
    # A pristine .state for this ROM, so tools/make_bad_states.py has something
    # to corrupt without needing a frontend to have written one first.
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
      let e = new_gb("", rom, fifo = true, headless = true, run_bios = false)
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
    base = e.state_bytes()
  else:
    let e = new_gb("", rom, fifo = true, headless = true, run_bios = false)
    e.test_output = new_test_output()
    e.post_init()
    for _ in 0 ..< 120: e.step_frame()
    base = e.state_bytes()

  if args[1] == "poke":
    # Reproduce one sweep finding exactly: set payload byte `seed` to `post`.
    # Built with --stacktrace:on this names the line that actually faults,
    # which is what turns "offset 298 crashes" into "bound THIS field".
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
      let e = new_gb("", rom, fifo = true, headless = true, run_bios = false)
      e.test_output = new_test_output()
      e.post_init()
      echo "  load -> ", e.load_state_bytes(mutant)
      for i in 0 ..< 8:
        echo "  frame ", i
        e.step_frame()
    echo "  survived"
    quit 0

  if sweep_mode:
    # Systematic single-byte sweep: set EVERY payload byte in turn to `seed`
    # (used as the byte value, default 0xFF) and see whether the loader — or
    # the emulator four frames later — survives. This is the audit that answers
    # "is a hostile file containable", because it visits every length, index
    # and enum field in the format exactly once instead of hoping to hit one.
    let bval = char(uint8(seed and 0xFF))
    var bad = 0
    var refused = 0
    let total = base.len - STATE_HEADER_SIZE
    for off in STATE_HEADER_SIZE ..< base.len:
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
          let e = new_gb("", rom, fifo = true, headless = true, run_bios = false)
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
         &"{total} offsets, refused {refused}, UNCONTAINED {bad}"
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
        let e = new_gb("", rom, fifo = true, headless = true, run_bios = false)
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
