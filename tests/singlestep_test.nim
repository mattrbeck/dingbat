## SingleStepTests per-instruction vectors against dingbat's CPU cores.
##
##   nim c -d:test_harness -d:cpu_testbus -d:release --warning:UnreachableCode:off \
##     --path:src --path:tests -o:singlestep_test tests/singlestep_test.nim
##   ./singlestep_test sm83 <dir of v1/*.json> [--only=<stem>] [--show=N] [--match=<s>]
##   ./singlestep_test arm7tdmi <dir of v1/*.json.bin> [--only=<stem>] [--show=N] [--match=<s>]
##
## One line per vector file on stdout:
##   SST <suite> <file> <cases> <pass> <state> <bus> <access>
## `pass` = every check right, `state`/`bus`/`access` each check alone (SM83
## has no access-type check: its column repeats `bus`). Then one line per
## bucket of the file's failures that is a known divergence:
##   KNOWN <suite> <file> <cases> <why>
## (singlestep_arm7.known_divergence, singlestep_sm83.known_divergence). A
## failure in no bucket is unexplained. --show=N prints the first N
## unexplained failures of each file to stderr with what differed (--match
## keeps those whose difference signature contains <s>) and a histogram of
## their signatures. The runner (dingbat_test_runner, "SingleStepTests")
## downloads the vectors and scores these lines; tests/README.md has the rules.

import std/[json, os, strutils, strformat, parseopt, algorithm, tables]
import singlestep_sm83, singlestep_arm7

when not defined(cpu_testbus):
  {.error: "singlestep_test needs -d:cpu_testbus (the CPU's test-bus hooks)".}

type Tally = object
  cases, pass, state, bus, access, shown: int
  known, sigs: CountTable[string]

proc report(suite, stem: string; t: var Tally; show: int) =
  echo &"SST {suite} {stem} {t.cases} {t.pass} {t.state} {t.bus} {t.access}"
  for k, n in t.known: echo &"KNOWN {suite} {stem} {n} {k}"
  if show > 0 and t.sigs.len > 0:
    t.sigs.sort()
    var k = 0
    for sig, n in t.sigs:
      stderr.writeLine &"    {n:6} {sig}"
      inc k
      if k >= 12: break

proc main() =
  var args: seq[string]
  var only = ""
  var show = 0
  var match = ""
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument: args.add p.key
    of cmdLongOption, cmdShortOption:
      case p.key
      of "only": only = p.val
      of "show": show = parseInt(p.val)
      of "match": match = p.val
      else: discard
  if args.len < 2:
    stderr.writeLine "usage: singlestep_test sm83|arm7tdmi <vector dir> [--only=<stem>] [--show=N] [--match=<s>]"
    quit(2)
  let suite = args[0]
  let dir = args[1]
  let scratch = getTempDir()
  case suite
  of "sm83":
    let gb = new_test_gb(scratch)
    var files: seq[string]
    for f in walkFiles(dir / "*.json"): files.add f
    files.sort()
    if files.len == 0: quit("no vectors in " & dir, 2)
    for f in files:
      let stem = f.splitFile.name.replace(' ', '_')
      if only.len > 0 and stem != only: continue
      var t = Tally(known: initCountTable[string](), sigs: initCountTable[string]())
      for c in parseFile(f):
        let r = gb.run_case(c)
        inc t.cases
        if r.state_ok: inc t.state
        if r.bus_ok: inc t.bus; inc t.access
        if r.state_ok and r.bus_ok:
          inc t.pass
          continue
        let k = known_divergence(stem, r)
        if k.len > 0:
          t.known.inc(k)
          continue
        t.sigs.inc(r.why.split(' ')[0])
        if t.shown < show and (match.len == 0 or match in r.why):
          inc t.shown
          stderr.writeLine "  " & c["name"].getStr & ": " & r.why
      report("sm83", stem, t, show)
  of "arm7tdmi":
    let gba = new_test_gba(scratch)
    var files: seq[string]
    for f in walkFiles(dir / "*.json.bin"): files.add f
    files.sort()
    if files.len == 0: quit("no vectors in " & dir, 2)
    for f in files:
      let stem = f.extractFilename.replace(".json.bin", "")
      if only.len > 0 and stem != only: continue
      var cases = load_cases(f)
      var t = Tally(known: initCountTable[string](), sigs: initCountTable[string]())
      for i in 0 ..< cases.len:
        let r = gba.run_case(cases[i])
        inc t.cases
        if r.state_ok: inc t.state
        if r.bus_ok: inc t.bus
        if r.access_ok: inc t.access
        if r.state_ok and r.access_ok:
          inc t.pass
          continue
        let k = known_divergence(stem, cases[i], r)
        if k.len > 0:
          t.known.inc(k)
          continue
        t.sigs.inc(r.sig)
        if t.shown < show and (match.len == 0 or match in r.sig):
          inc t.shown
          let c = cases[i]
          stderr.writeLine &"  {stem}#{i} op={c.opcode:08X} cpsr={c.initial.cpsr:08X}: {r.why}"
      report("arm7tdmi", stem, t, show)
  else:
    stderr.writeLine "unknown suite: ", suite
    quit(2)

main()
