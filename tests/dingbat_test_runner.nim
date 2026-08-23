import std/[os, osproc, strutils, strformat, tables, sequtils, times, algorithm, parseopt, sha1]
import zippy/ziparchives
import png_reader

let RomCacheDir =
  # CI points DINGBAT_ROM_CACHE at an actions/cache-backed dir so the ROMs
  # survive between runs; locally a temp dir.
  block:
    let env = getEnv("DINGBAT_ROM_CACHE")
    if env.len > 0: env
    elif defined(windows): getTempDir() / "dingbat-test-roms"
    else: "/tmp/dingbat-test-roms"

type
  TestMode = enum
    tmSerial, tmSram, tmMooneye, tmMgba, tmMgbaSuite, tmScreenshot, tmJsmolka,
    tmFuzzArm, tmMagenGreen, tmMagenNoRed, tmMicrotest

  TestDef = object
    name: string
    rom_path: string
    mode: TestMode
    timeout: int
    expected_png: string  # for screenshot mode
    alt_pngs: seq[string] # screenshot mode: references that are ALSO a pass
                          # (daid's ppu_scanline_bgp has three legitimate DMG
                          # outcomes)
    expected_hash: string # screenshot mode, alternative to expected_png:
                          # FNV-1a of the PPM, for ROMs that ship no reference
                          # image (see build_jsmolka_tests)
    grey_tolerance: int   # screenshot mode. 0 = exact match (right for raw
                          # framebuffer dumps). >0 = 8-bit luma per pixel
                          # within this tolerance, the gbdev shootout's own
                          # `compareImage` rule: its references are emulator
                          # screen captures carrying CGB colour correction
                          # (#009100, which (X<<3)|(X>>2) cannot produce).
    color: bool           # true = RGB comparison, false = greyscale
    cgb: bool             # force CGB mode (DMG cart on CGB hardware tests)
    dmg: bool             # force DMG mode (--dmg): the cart header picks the
                          # device by default; this is for rows whose suite
                          # names the hardware instead.
    sgb: bool             # run the cart in a Super Game Boy (--sgb)
    model: string         # mooneye per-model boot table (--model=...); "" = default
    no_save: bool         # blank cart RAM + detach the .sav (battery-backed ROMs)
    ed_breakpoint: bool   # opcode 0xED ends the run (wilbertpol mooneye fork)
    bb_breakpoint: bool   # LD B,B always ends the run, pass or fail (AGE)
    screen_check: bool    # after the verdict, require the panel to have settled
                          # and to show more than one shade. Deliberately NOT a
                          # glyph check — see tests/README.md, "blargg's
                          # on-screen text is NOT an oracle".

  TestResult = object
    name: string
    passed: bool
    output: string
    timed_out: bool
    always_detail: bool  # keep `output` in results.md even on a pass
                         # (aggregated rows carry their pass COUNT there)
    device: string       # what lands in the results.md Device column: the
                         # hardware the row was scored on ("" renders as an
                         # em-dash, used for the GBA suites)

  SuiteResults = object
    suite_name: string
    results: seq[TestResult]

  MgbaTestDetail = object
    name: string
    passed: bool
    actual: string
    expected: string

  MgbaSuiteDetail = object
    name: string
    passes: int
    total: int
    tests: seq[MgbaTestDetail]
    timed_out: bool


proc has_rom_files(dir: string): bool =
  ## Check if a directory tree contains at least one .gb ROM file.
  for path in walkDirRec(dir):
    if path.endsWith(".gb"):
      return true
  false

proc download_file(url, path: string) =
  ## Fetch `url` to `path`. curl retries transient failures itself
  ## (--retry-all-errors covers connection errors, not just HTTP 5xx); --fail
  ## keeps an error page from being saved as a ROM.
  let cmd = "curl -L --fail --show-error --silent " &
    "--retry 5 --retry-all-errors --retry-delay 3 " &
    "--connect-timeout 30 --max-time 600 " &
    &"-o {path.quoteShell} {url.quoteShell}"
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    echo &"Failed to download {url} (curl exit {code}): ", output
    quit(1)

# The GB ROM bundle release. Referenced by the download URL AND by
# results.md's provenance line, so bumping it updates both.
const GbBundleVersion = "v7.0"

proc ensure_gameboy_test_roms(): string =
  let dir = RomCacheDir / "game-boy-test-roms"
  if dirExists(dir) and has_rom_files(dir):
    return dir
  if dirExists(dir):
    echo "Cached game-boy-test-roms directory has no ROMs, re-downloading..."
    removeDir(dir)
  echo "Downloading game-boy-test-roms release..."
  createDir(RomCacheDir)
  let url = "https://github.com/c-sp/game-boy-test-roms/releases/download/" &
    GbBundleVersion & "/game-boy-test-roms-" & GbBundleVersion & ".zip"
  let zipfile = RomCacheDir / "gb-roms.zip"
  download_file(url, zipfile)
  try:
    # extractAll requires that dir not exist yet; it creates it
    extractAll(zipfile, dir)
  except ZippyError, IOError, OSError:
    echo "Failed to extract: ", getCurrentExceptionMsg()
    if dirExists(dir): removeDir(dir)
    removeFile(zipfile)
    quit(1)
  removeFile(zipfile)
  dir


proc find_roms(dir: string; ext: string): seq[string] =
  var roms: seq[string]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(ext):
      roms.add(path)
  roms.sort(cmp[string])
  roms

proc find_roms_recursive(dir: string; ext: string): seq[string] =
  var roms: seq[string]
  for path in walkDirRec(dir):
    if path.endsWith(ext):
      roms.add(path)
  roms.sort(cmp[string])
  roms

proc skip_ppm_header(data: string): int =
  var pos = 0
  for _ in 0 ..< 3:
    while pos < data.len and data[pos] != '\n': inc pos
    inc pos
  pos

proc read_ppm_greyscale(path: string): seq[uint8] =
  ## Read a P6 PPM and return one greyscale byte per pixel (R channel, since R=G=B).
  let data = readFile(path)
  var pos = skip_ppm_header(data)
  var pixels: seq[uint8]
  while pos + 2 < data.len:
    pixels.add(uint8(data[pos]))
    pos += 3
  pixels

proc read_ppm_rgb(path: string): seq[uint8] =
  ## Read a P6 PPM and return all RGB bytes (3 per pixel).
  let data = readFile(path)
  var pos = skip_ppm_header(data)
  var pixels: seq[uint8]
  while pos < data.len:
    pixels.add(uint8(data[pos]))
    inc pos
  pixels

proc ensure_rom_download(url, filename: string; expect_sha = ""): string =
  ## Download a ROM if not cached. With expect_sha the cached file's SHA-1 is
  ## checked and a mismatch reported, so a URL that tracks "latest" cannot
  ## silently re-baseline a suite while looking like an emulator change.
  let path = RomCacheDir / filename
  if not fileExists(path):
    echo &"Downloading {filename}..."
    createDir(RomCacheDir)
    download_file(url, path)
  if expect_sha.len > 0:
    let got = toLowerAscii($secureHashFile(path))
    if got != expect_sha:
      echo &"  !! {filename} is not the build these results were baselined on"
      echo &"     expected sha1 {expect_sha}"
      echo &"     got             {got}"
      echo "     scoring it anyway; rebaseline and update the constant if this is intended"
  path

proc ensure_png_download(url, filename: string): string =
  ## Download a reference PNG if not already cached.
  let path = RomCacheDir / filename
  if fileExists(path):
    return path
  createDir(RomCacheDir)
  download_file(url, path)
  path

proc run_test(test: TestDef; harness_path: string): TestResult =
  let mode_str = case test.mode
    of tmSerial: "serial"
    of tmSram: "sram"
    of tmMooneye: "mooneye"
    of tmMgba: "mgba"
    of tmMgbaSuite: "mgba-suite"
    of tmScreenshot: "screenshot"
    of tmJsmolka: "jsmolka"
    of tmFuzzArm: "fuzzarm"
    of tmMagenGreen: "magen-green"
    of tmMagenNoRed: "magen-nored"
    of tmMicrotest: "microtest"
  if test.mode == tmScreenshot:
    let tmp_ppm = getTempDir() / "dingbat_test_" & test.rom_path.splitFile().name & ".ppm"
    var cmd = &"{harness_path.quoteShell} {test.rom_path.quoteShell} --mode=screenshot --timeout={test.timeout} --screenshot={tmp_ppm.quoteShell}"
    if test.color:
      cmd.add(" --color")
    if test.cgb:
      cmd.add(" --cgb")
    if test.dmg:
      cmd.add(" --dmg")
    if test.sgb:
      cmd.add(" --sgb")
    if test.model.len > 0:
      cmd.add(" --model=" & test.model)
    if test.no_save:
      cmd.add(" --nosave")
    let (run_output, run_code) = execCmdEx(cmd, options = {poUsePath})
    if run_code != 0:
      return TestResult(name: test.name, passed: false, output: run_output.strip())
    if test.expected_hash.len > 0:
      # No reference image ships with these ROMs; the gate is a pinned frame
      # hash (build_jsmolka_tests).
      var h = 0xCBF29CE484222325'u64
      for c in readFile(tmp_ppm):
        h = (h xor uint64(uint8(c))) * 0x100000001B3'u64
      removeFile(tmp_ppm)
      let got = h.toHex(16)
      return TestResult(
        name: test.name,
        passed: got == test.expected_hash,
        output: if got == test.expected_hash: "frame hash " & got
                else: &"frame hash {got}, expected {test.expected_hash}",
      )
    let actual = if test.color: read_ppm_rgb(tmp_ppm) else: read_ppm_greyscale(tmp_ppm)
    removeFile(tmp_ppm)
    proc score_against(png_path: string): tuple[matched, total: int, err: string] =
      ## Pixels matching `png_path`, or a non-empty `err` if it is unusable.
      ## `--color` sets the capture format; the reference decides the
      ## comparison, since suites mix PNG formats (mealybug `_cgb_c` has 1-bit
      ## greyscale files). A greyscale reference is widened to RGB rather than
      ## the capture narrowed to R, so a wrongly coloured frame still fails.
      var expected = read_png(png_path)
      if not test.color and expected.channels == 3:
        # Greyscale capture vs RGB reference (mooneye's sprite_priority-dmg.png
        # stores greys as R=G=B truecolor): collapse the reference to R.
        var grey = newSeq[uint8](expected.pixels.len div 3)
        for i in 0 ..< grey.len:
          grey[i] = expected.pixels[i * 3]
        expected.pixels = grey
        expected.channels = 1
      elif test.color and expected.channels == 1:
        # RGB capture vs greyscale reference: widen the reference to R=G=B.
        var rgb = newSeq[uint8](expected.pixels.len * 3)
        for i in 0 ..< expected.pixels.len:
          rgb[i * 3] = expected.pixels[i]
          rgb[i * 3 + 1] = expected.pixels[i]
          rgb[i * 3 + 2] = expected.pixels[i]
        expected.pixels = rgb
        expected.channels = 3
      if actual.len != expected.pixels.len:
        return (0, 0, &"size mismatch: {actual.len} vs {expected.pixels.len}")
      let bytes_per_pixel = if expected.channels == 3: 3 else: 1
      let total_pixels = actual.len div bytes_per_pixel
      var diff_count = 0
      if test.grey_tolerance > 0:
        # The shootout's own rule (util.py `compareImage`): 8-bit luma per
        # pixel within a tolerance. See `grey_tolerance` on TestDef.
        proc luma(p: openArray[uint8]; base, n: int): int =
          if n == 1: int(p[base])
          else: (299 * int(p[base]) + 587 * int(p[base + 1]) +
                 114 * int(p[base + 2])) div 1000
        for px in 0 ..< total_pixels:
          let base = px * bytes_per_pixel
          if abs(luma(actual, base, bytes_per_pixel) -
                 luma(expected.pixels, base, bytes_per_pixel)) > test.grey_tolerance:
            inc diff_count
      else:
        for px in 0 ..< total_pixels:
          let base = px * bytes_per_pixel
          var differs = false
          for c in 0 ..< bytes_per_pixel:
            if actual[base + c] != expected.pixels[base + c]:
              differs = true
              break
          if differs:
            inc diff_count
      (total_pixels - diff_count, total_pixels, "")

    # A row passes if the frame matches ANY of its references; when none match,
    # report the closest one, since that is the reference worth diffing against.
    var best_matched = -1
    var best_total = 0
    var best_name = ""
    var last_err = ""
    for png_path in @[test.expected_png] & test.alt_pngs:
      let (matched, total, err) = score_against(png_path)
      if err.len > 0:
        last_err = err
        continue
      if matched == total:
        best_matched = matched
        best_total = total
        best_name = png_path
        break
      if matched > best_matched:
        best_matched = matched
        best_total = total
        best_name = png_path
    if best_matched < 0:
      return TestResult(name: test.name, passed: false, output: last_err)
    let pct = 100.0 * float(best_matched) / float(best_total)
    let passed = best_matched == best_total
    # Only name the reference when there was a choice to make.
    let which = if test.alt_pngs.len > 0: " vs " & best_name.extractFilename else: ""
    return TestResult(
      name: test.name,
      passed: passed,
      output: &"{pct:.1f}% correct ({best_matched}/{best_total} pixels match){which}",
    )
  else:
    var cmd = &"{harness_path.quoteShell} {test.rom_path.quoteShell} --mode={mode_str} --timeout={test.timeout}"
    if test.cgb:
      cmd.add(" --cgb")
    if test.dmg:
      cmd.add(" --dmg")
    if test.sgb:
      cmd.add(" --sgb")
    if test.model.len > 0:
      cmd.add(" --model=" & test.model)
    if test.no_save:
      cmd.add(" --nosave")
    if test.ed_breakpoint:
      cmd.add(" --ed-breakpoint")
    if test.bb_breakpoint:
      cmd.add(" --bb-breakpoint")
    if test.screen_check:
      cmd.add(" --screen-check")
    # fuzzarm writes its triage to stderr. execCmdEx reads only stdout, so
    # stderr must be merged: unread, it is lost and deadlocks once the triage
    # outgrows the pipe buffer (500 failures is ~100 KB).
    let opts = if test.mode == tmFuzzArm: {poUsePath, poStdErrToStdOut}
               else: {poUsePath}
    let (output, code) = execCmdEx(cmd, options = opts)
    var text = output.strip()
    if test.mode == tmFuzzArm:
      # Keep only the "FUZZARM: " verdict for results.md. Match on the marker,
      # not position: the merged streams interleave unpredictably. Echo the
      # rest on failure so the triage lands in the runner's log.
      const Marker = "FUZZARM: "
      var verdict = ""
      for line in text.splitLines():
        let s = line.strip()
        if s.startsWith(Marker): verdict = s[Marker.len .. ^1]
      if code != 0:
        for line in text.splitLines():
          let s = line.strip()
          if s.len > 0 and not s.startsWith(Marker): echo line
      if verdict.len > 0: text = verdict
    if test.mode == tmMicrotest:
      # Keep only the $FF80/$FF81/$FF82 line: a verdict of 0x00 (never
      # written) reads very differently from 0xFF (ran and mismatched).
      for line in text.splitLines():
        if line.startsWith("MICROTEST actual"):
          text = line[len("MICROTEST ") .. ^1]
          break
    return TestResult(
      name: test.name,
      passed: code == 0,
      output: text,
      timed_out: output.contains("TIMEOUT") or text.contains("timed out"),
    )

proc build_blargg_tests(repo_dir: string): seq[TestDef] =
  var tests: seq[TestDef]
  let cpu_instrs_dir = repo_dir / "cpu_instrs" / "individual"
  if dirExists(cpu_instrs_dir):
    for rom in find_roms(cpu_instrs_dir, ".gb"):
      let name = rom.splitFile().name
      tests.add(TestDef(
        name: "blargg/cpu_instrs/" & name,
        rom_path: rom,
        mode: tmSerial,
        timeout: 1800,
        # The only GB rows that run a whole ROM to a verdict with nothing
        # looking at the screen. Deliberately weak: tests/README.md explains
        # why blargg's on-screen text is not an oracle.
        screen_check: true,
      ))
  let instr_timing = repo_dir / "instr_timing" / "instr_timing.gb"
  if fileExists(instr_timing):
    tests.add(TestDef(
      name: "blargg/instr_timing",
      rom_path: instr_timing,
      mode: tmSerial,
      timeout: 1800,
    ))
  let mem_timing = repo_dir / "mem_timing" / "individual"
  if dirExists(mem_timing):
    for rom in find_roms(mem_timing, ".gb"):
      let name = rom.splitFile().name
      tests.add(TestDef(
        name: "blargg/mem_timing/" & name,
        rom_path: rom,
        mode: tmSerial,
        timeout: 1800,
      ))
  # The remaining Blargg suites report through the SRAM protocol tmSram reads.
  # oam_bug wants ~21 emulated seconds (suite howto). Its carts carry
  # $0143 = $80, but the bug is DMG silicon (Pan Docs: CGB and AGB are not
  # affected) and the howto lists oam_bug only in its DMG table, so the rows
  # are forced --dmg rather than left to the header.
  for (subdir, secs) in [("oam_bug", 21), ("mem_timing-2", 4)]:
    let singles = repo_dir / subdir / "rom_singles"
    if not dirExists(singles): continue
    for rom in find_roms(singles, ".gb"):
      # Standalone 7-timing_effect is a broken build: its verbose output
      # overruns the $A004..$BFFF text window into the $C000 copy of its own
      # code and it never reports, on real DMG hardware too
      # (Docheinstein/docboy#33). Test 7 is scored via the combined ROM below.
      if subdir == "oam_bug" and rom.splitFile().name == "7-timing_effect":
        continue
      tests.add(TestDef(
        name: "blargg/" & subdir & "/" & rom.splitFile().name,
        rom_path: rom,
        mode: tmSram,
        timeout: max(1800, secs * 70),
        dmg: subdir == "oam_bug",
      ))
  # The combined oam_bug.gb is built NO_COPY (runs from ROM), which is what
  # makes test 7 reportable.
  let oam_bug_all = repo_dir / "oam_bug" / "oam_bug.gb"
  if fileExists(oam_bug_all):
    tests.add(TestDef(
      name: "blargg/oam_bug/combined",
      rom_path: oam_bug_all,
      mode: tmSram,
      timeout: 4200,
      dmg: true,
    ))
  let halt_bug = repo_dir / "halt_bug.gb"
  if fileExists(halt_bug):
    tests.add(TestDef(
      name: "blargg/halt_bug",
      rom_path: halt_bug,
      mode: tmSram,
      timeout: 1800,
    ))
  # interrupt_time is CGB-only (the howto records DMG-C failing it). The cart
  # is $0143 = $C0, so `cgb = true` only restates what the header picks.
  let interrupt_time = repo_dir / "interrupt_time" / "interrupt_time.gb"
  if fileExists(interrupt_time):
    tests.add(TestDef(
      name: "blargg/interrupt_time",
      rom_path: interrupt_time,
      mode: tmSram,
      timeout: 1800,
      cgb: true,
    ))
  tests

proc build_blargg_sound_tests(sound_dir, suite: string; cgb: bool): seq[TestDef] =
  ## blargg's dmg_sound / cgb_sound (rom_singles), reporting through the SRAM
  ## protocol tmSram reads. The suite names the hardware, so the device is
  ## forced rather than left to the header. The howto records cgb_sound
  ## failing on CPU CGB B (03-trigger) and passing on C and E.
  var tests: seq[TestDef]
  let singles = sound_dir / "rom_singles"
  if not dirExists(singles):
    echo &"  Warning: blargg {suite} rom_singles directory not found"
    return tests
  for rom in find_roms(singles, ".gb"):
    let name = rom.splitFile().name
    tests.add(TestDef(
      name: "blargg/" & suite & "/" & name,
      rom_path: rom,
      mode: tmSram,
      dmg: not cgb,
      timeout: 1800,
      cgb: cgb,
    ))
  tests

proc samesuite_model_for(base: string): string =
  ## SameSuite's trailing `-<devices>` token (`-cgb0B`, `-cgbDE`, `-A`), passed
  ## through to `--model=` so a ROM is scored on a revision its CorrectResults
  ## table was taken on. gb_revision_from_name resolves a range to its highest
  ## member, which is right here: the `-cgb0B` rows pass at cgb0 and cgbAB
  ## only, and `-cgb0` / `-cgbB` must stay distinct. Only a token after the
  ## LAST '-' that looks like a device list counts.
  if '-' notin base: return ""
  let tok = base.rsplit('-', maxsplit = 1)[1]
  if tok.len == 0: return ""
  let head = tok.toLowerAscii()
  if head == "a" or head.startsWith("cgb") or head.startsWith("dmg") or
     head.startsWith("agb") or head.startsWith("mgb"):
    return tok
  ""

proc build_samesuite_apu_tests(samesuite_dir: string): seq[TestDef] =
  ## SameSuite's sample-accurate APU tests: mooneye LD B,B + Fibonacci verdict,
  ## all CGB (they read PCM12/PCM34). The default revision is CPU CGB E, not
  ## the tree's CGB C: `same-suite/apu/README.md` states CGB C fails most
  ## channel 1/2/4 tests through the PCM12/34 same-M-cycle read glitch
  ## (GbQuirks.pcm_read_edge_zero) and D/E pass all. A filename device token
  ## still overrides. Opt-in via --apu, see main().
  var tests: seq[TestDef]
  let apu_dir = samesuite_dir / "apu"
  if not dirExists(apu_dir):
    echo "  Warning: same-suite apu directory not found"
    return tests
  for rom in find_roms_recursive(apu_dir, ".gb"):
    let rel = rom.relativePath(apu_dir)
    let tok = samesuite_model_for(rom.splitFile().name)
    tests.add(TestDef(
      name: "same-suite/apu/" & rel.changeFileExt(""),
      rom_path: rom,
      mode: tmMooneye,
      timeout: 1800,
      cgb: true,
      model: if tok.len > 0: tok else: "cgbE",
    ))
  tests

proc build_samesuite_core_tests(samesuite_dir: string): seq[TestDef] =
  ## SameSuite's dma/ppu/interrupt groups (same LD B,B verdict), all CGB and
  ## in the default run. `sgb/` tests the SGB packet protocol and runs --sgb:
  ## a CGB ignores the packet stream, so scoring it there would score a
  ## different machine.
  var tests: seq[TestDef]
  for group in ["dma", "ppu", "interrupt", "sgb"]:
    let dir = samesuite_dir / group
    if not dirExists(dir):
      echo "  Warning: same-suite ", group, " directory not found"
      continue
    let is_sgb = group == "sgb"
    for rom in find_roms_recursive(dir, ".gb"):
      tests.add(TestDef(
        name: "same-suite/" & group & "/" & rom.splitFile().name,
        rom_path: rom,
        mode: tmMooneye,
        timeout: 1800,
        cgb: not is_sgb,
        sgb: is_sgb,
      ))
  tests

proc mooneye_model_for(base: string): string =
  ## boot_* ROMs name one hardware revision as the suffix after the last '-'
  ## (boot_regs-mgb, boot_div-S); map it to --model. The default-model
  ## suffixes (dmgABC, dmgABCmgb, cgb, cgbABCDE, C) stay unmapped.
  if not base.startsWith("boot_") or '-' notin base:
    return ""
  case base.rsplit('-', maxsplit = 1)[1]
  of "dmg0": "dmg0"
  of "mgb":  "mgb"
  of "sgb":  "sgb"
  of "sgb2": "sgb2"
  of "S":    "sgb"    # boot_div-S / boot_div2-S / boot_hwio-S
  of "A":    "agb"    # misc/boot_regs-A / boot_div-A
  of "cgb0": "cgb0"
  else: ""

proc is_cgb_model(m: string): bool =
  ## --model tokens that boot as a CGB. AGB/AGS are CGB silicon in another
  ## package (suite README), so they run with --cgb.
  m.startsWith("cgb") or m == "agb" or m == "ags"

proc mooneye_machines_for(base: string): seq[string] =
  ## Every `--model` a mooneye/wilbertpol ROM's filename claims (README, "Test
  ## naming": G = dmg+mgb, S = sgb+sgb2, C = cgb+agb+ags, A = agb+ags; a group
  ## token is the union of its letters). Revisions fan out only where the
  ## name lists them (`cgbABCDE` -> four rows); a bare model token gets one
  ## representative revision, the default CGB-C, since the ROM makes no
  ## per-revision claim. Revision 0 is never in a fan-out: the suite ships
  ## separate `-dmg0`/`-cgb0` ROMs. `ags` folds into `agb` (same SoC).
  if '-' notin base:
    return @[]
  let tok = base.rsplit('-', maxsplit = 1)[1]
  const CgbRevs = ["cgbab", "cgbc", "cgbd", "cgbe"]
  var picked: seq[string]
  if tok.len > 0 and tok.allIt(it in {'G', 'S', 'C', 'A'}):
    for ch in tok:
      case ch
      of 'G': picked.add("dmgABC"); picked.add("mgb")
      of 'S': picked.add("sgb"); picked.add("sgb2")
      of 'C': picked.add("cgbc"); picked.add("agb")
      of 'A': picked.add("agb")
      else: discard
  else:
    case tok
    of "dmg", "dmgABC": picked.add("dmgABC")
    of "dmgABCmgb":     picked.add("dmgABC"); picked.add("mgb")
    of "dmg0":          picked.add("dmg0")
    of "mgb":           picked.add("mgb")
    of "sgb":           picked.add("sgb")
    of "sgb2":          picked.add("sgb2")
    of "cgb":           picked.add("cgbc")
    of "cgbABCDE":      (for r in CgbRevs: picked.add(r))
    of "cgb0":          picked.add("cgb0")
    else: return @[]
  # Order-preserving dedupe: `GS`-style unions can name the same machine twice.
  for m in picked:
    if m notin result: result.add(m)

proc build_mooneye_tests(roms_dir: string): seq[TestDef] =
  var tests: seq[TestDef]
  let mooneye_dir = roms_dir / "mooneye-test-suite"
  if not dirExists(mooneye_dir):
    echo "  Warning: mooneye-test-suite directory not found in game-boy-test-roms"
    return tests
  for rom in find_roms_recursive(mooneye_dir, ".gb"):
    let rel = rom.relativePath(mooneye_dir)
    let name = "mooneye/" & rel.changeFileExt("")
    # utils/ holds tools, not tests: bootrom_dumper can only time out and
    # dump_boot_hwio sets the success byte unconditionally. Both in NotScored.
    if rel.startsWith("utils"):
      continue
    # sprite_priority has no serial verdict; mooneye ships a DMG reference
    # image, so it is a screenshot row like mealybug/acid2.
    if rel == "manual-only" / "sprite_priority.gb":
      tests.add(TestDef(
        name: name,
        rom_path: rom,
        mode: tmScreenshot,
        timeout: 120,
        expected_png: rom.parentDir / "sprite_priority-dmg.png",
      ))
      continue
    # The suite's other screenshot ROM: ships `_expected.png` beside it and
    # targets an MGB. The wilbertpol bundle's ROM of the same name differs
    # (md5) but shares the reference, so both rows are legitimate.
    if rel == "madness" / "mgb_oam_dma_halt_sprites.gb":
      tests.add(TestDef(
        name: name,
        rom_path: rom,
        mode: tmScreenshot,
        timeout: 120,
        expected_png: rom.parentDir / "mgb_oam_dma_halt_sprites_expected.png",
        # This reference uses grey ramp 255/176/104 where the rest of mooneye
        # (and dingbat) use 255/170/85; compared exactly every non-white pixel
        # is wrong. Shade deltas are 0/6/19 and the ramp's smallest step is
        # 72, so any tolerance in [19, 71] is shade-index equality; 32 is
        # mid-band (8 was below the shade-2 delta and scored correct objects
        # as wrong).
        grey_tolerance: 32,
        model: "mgb",
      ))
      continue
    let base = rom.splitFile().name
    let machines = mooneye_machines_for(base)
    if machines.len == 0:
      tests.add(TestDef(
        name: name,
        rom_path: rom,
        mode: tmMooneye,
        timeout: 1800,
        # misc/ holds the CGB/AGB-hardware tests (DMG-flagged carts that
        # assert CGB boot state); run them as a DMG cart on CGB hardware
        cgb: rel.startsWith("misc"),
        model: mooneye_model_for(base),
      ))
    else:
      # One row per machine the TOKEN names, not the directory: the
      # wilbertpol fork's misc/ mixes SGB and MGB ROMs in with CGB ones.
      for m in machines:
        tests.add(TestDef(
          name: name & (if machines.len > 1: "@" & m else: ""),
          rom_path: rom,
          mode: tmMooneye,
          timeout: 1800,
          cgb: is_cgb_model(m),
          model: m,
        ))
  tests

proc build_mealybug_tests(mealybug_dir: string): seq[TestDef] =
  ## Every mealybug ROM is a DMG cart; the suite ships `_dmg_blob.png` (DMG)
  ## and `_cgb_c.png` / `_cgb_d.png` (the same cart on CPU CGB C / D in
  ## compatibility mode: CGB timing, boot-ROM fallback palette). The sets do
  ## not cover the same ROMs (`*2.gb` are CGB-only, `m3_wx_4/5/6_change`
  ## DMG-only). Each capture is scored at the revision it names.
  var tests: seq[TestDef]
  let ppu_dir = mealybug_dir / "ppu"
  if not dirExists(ppu_dir):
    echo "  Warning: mealybug ppu directory not found"
    return tests
  for rom in find_roms(ppu_dir, ".gb"):
    let test_name = rom.splitFile().name
    let dmg_png = ppu_dir / test_name & "_dmg_blob.png"
    if fileExists(dmg_png):
      tests.add(TestDef(
        name: "mealybug/" & test_name,
        rom_path: rom,
        mode: tmScreenshot,
        timeout: 120,
        expected_png: dmg_png,
      ))
    let cgb_png = ppu_dir / test_name & "_cgb_c.png"
    if fileExists(cgb_png):
      tests.add(TestDef(
        name: "mealybug-cgb/" & test_name,
        rom_path: rom,
        mode: tmScreenshot,
        timeout: 120,
        expected_png: cgb_png,
        color: true,
        cgb: true,
        # Pinned to the revision the `_cgb_c` capture is of rather than
        # inherited from the default; also labels the Device column.
        model: "cgbc",
        no_save: true,
      ))
    # The `_cgb_d` capture at CGB-D, for all twenty ROMs that ship one.
    # Thirteen are pixel-identical to their `_cgb_c` twin; running them checks
    # that claim. Gated on the file existing so the set tracks the bundle.
    let cgb_d_png = ppu_dir / test_name & "_cgb_d.png"
    if fileExists(cgb_d_png):
      tests.add(TestDef(
        name: "mealybug-cgbd/" & test_name,
        rom_path: rom,
        mode: tmScreenshot,
        timeout: 120,
        expected_png: cgb_d_png,
        color: true,
        cgb: true,
        model: "cgbd",
        no_save: true,
      ))
  # `dma/` and `mbc/` ship no reference image and need none: they are built
  # without DISPLAY_RESULTS_ONLY, so inc/base.asm compares against the ROM's
  # CorrectResults table and ends on LD B,B with the Fibonacci registers,
  # which tmMooneye reads. Both dma/ ROMs REQUIRE CGB and carry mooneye's
  # `-C` token, named here as `cgbc`; an agb arm would add no information
  # (hdma_during_halt-C passes and hdma_timing-C fails on every revision).
  # --nosave: mbc3_rtc is battery-backed with an RTC.
  for (group, name, cgb, model) in [("dma", "hdma_during_halt-C", true, "cgbc"),
                                    ("dma", "hdma_timing-C", true, "cgbc"),
                                    ("mbc", "mbc3_rtc", false, "")]:
    let rom = mealybug_dir / group / (name & ".gb")
    if not fileExists(rom): continue
    tests.add(TestDef(
      name: "mealybug/" & group & "/" & name,
      rom_path: rom,
      mode: tmMooneye,
      timeout: 1800,
      cgb: cgb,
      model: model,
      no_save: true,
    ))
  tests

const MicrotestNoVerdict = [
  # The 31 bundled GBMicrotest ROMs that never write $FF82, the verdict byte
  # --mode=microtest reads: none contains `E0 82` (`ldh ($82),a`) or
  # `EA 82 FF` (`ld ($ff82),a`), so the row could only read uninitialised
  # HRAM. Listed by name so the skip stays reviewable. Denominator 482.
  "000-oam_lock",
  "000-write_to_x8000",
  "001-vram_unlocked",
  "002-vram_locked",
  "004-tima_boot_phase",
  "004-tima_cycle_timer",
  "007-lcd_on_stat",
  "400-dma",
  "500-scx-timing",
  "800-ppu-latch-scx",
  "801-ppu-latch-scy",
  "802-ppu-latch-tileselect",
  "803-ppu-latch-bgdisplay",
  "audio_testbench",
  "cpu_bus_1",
  "dma_basic",
  "flood_vram",
  "lcdon_write_timing",
  "ly_while_lcd_off",
  "minimal",
  "mode2_stat_int_to_oam_unlock",
  "oam_sprite_trashing",
  "poweron",
  "ppu_scx_vs_bgp",
  "ppu_sprite_testbench",
  "ppu_spritex_vs_scx",
  "ppu_win_vs_wx",
  "ppu_wx_early",
  "temp",
  "toggle_lcdc",
  "wave_write_to_0xC003",
]

const MicrotestBrokenExpected = [
  # Two GBMicrotest ROMs whose $FF81 "expected" byte no Game Boy can produce.
  # `halt_op_dupe_delay` expects DIV = $55 about 62 M-cycles after resetting
  # DIV (DIV steps every 64 M-cycles; $55 is the suite's scratch marker; the
  # sibling `halt_op_dupe` is correctly written and passes). Derivation:
  # docs/gb-test-suite-sources.md 8.6.
  # `stat_write_glitch_l154_d` lacks the `xor a ; ldh ($FF0F),a` its three
  # siblings have at $0170, so it asserts IF = $E0 across a whole frame of
  # LCD-on time in which VBlank was never cleared. Restoring that clear makes
  # it pass; removing it from `_c` at identical timing yields `_d`'s byte.
  # Denominator 480.
  "halt_op_dupe_delay",
  "stat_write_glitch_l154_d",
]

proc build_gbmicrotest_tests(dir: string): seq[TestDef] =
  ## aappleby's GBMicrotest. Each ROM writes $FF80 actual, $FF81 expected,
  ## $FF82 $01/$FF and keeps running, so the harness runs a fixed frame count
  ## and reads $FF82 (--mode=microtest); the howto says two frames suffice,
  ## bar one ROM needing ~380 ms. All 513 carts carry $0143 = $00 and run as
  ## a DMG, which is what the howto asks for; on a CGB ~110 rows fail.
  var tests: seq[TestDef]
  if not dirExists(dir):
    echo "  Warning: gbmicrotest directory not found"
    return tests
  for rom in find_roms(dir, ".gb"):
    let name = rom.splitFile().name
    # ROMs with no verdict byte to read — see MicrotestNoVerdict above.
    if name in MicrotestNoVerdict:
      continue
    # ROMs whose expected byte is unreachable — see MicrotestBrokenExpected.
    if name in MicrotestBrokenExpected:
      continue
    tests.add(TestDef(
      name: "gbmicrotest/" & name,
      rom_path: rom,
      mode: tmMicrotest,
      # ~380 ms emulated == ~23 frames; 30 leaves headroom without making the
      # one slow ROM noticeable.
      timeout: if name == "is_if_set_during_ime0": 30 else: 2,
      no_save: true,
    ))
  tests

proc shot(name, rom, png: string; timeout: int; color = false; cgb = false;
          no_save = false): TestDef =
  ## One screenshot TestDef. The bundled references use the palettes the
  ## harness renders (DMG #00/#55/#AA/#FF, CGB channels (X<<3)|(X>>2)).
  TestDef(name: name, rom_path: rom, mode: tmScreenshot, timeout: timeout,
          expected_png: png, color: color, cgb: cgb, no_save: no_save)

proc build_small_screenshot_tests(roms_dir: string): seq[TestDef] =
  ## The bundle's small screenshot suites, from an explicit table: each has
  ## its own exit condition (from its howto) and device, and the reference
  ## name encodes the capture device. "-ncm" / CGB-compatibility images are a
  ## third device not modelled here. Frame counts are the howtos' run times;
  ## a ROM that signals LD B,B (cgb-acid-hell) stops there anyway.
  var tests: seq[TestDef]
  template add_if(name, rom, png: string; timeout: int; color = false;
                  cgb = false; no_save = false) =
    if fileExists(rom) and fileExists(png):
      tests.add(shot(name, rom, png, timeout, color, cgb, no_save))

  # BullyGB (Hacktix). The only bundled reference is a CGB capture, and
  # --mode=screenshot treats a missing --cgb as DMG, so the device is named.
  let bully = roms_dir / "bully"
  add_if("bully/bully", bully / "bully.gb", bully / "bully.png", 120,
         color = true, cgb = true)

  # strikethrough (Hacktix): forty objects crossed by a running OAM DMA
  # (obj_oam_dma_read in fifo_ppu.nim). Both devices scored; the references
  # differ only in palette, so a device-specific break shows on one row.
  let strike = roms_dir / "strikethrough"
  add_if("strikethrough/strikethrough-dmg", strike / "strikethrough.gb",
         strike / "strikethrough-dmg.png", 60)
  add_if("strikethrough/strikethrough-cgb", strike / "strikethrough.gb",
         strike / "strikethrough-cgb.png", 60, color = true, cgb = true)

  # scribbltests (Hacktix). fairylake and winpos ship no reference image, so
  # they cannot be scored; statcount has an "-auto" variant that is the one
  # with a reference. "-cgb-dmg" images are identical on both devices.
  let scribbl = roms_dir / "scribbltests"
  add_if("scribbltests/lycscx", scribbl / "lycscx" / "lycscx.gb",
         scribbl / "lycscx" / "lycscx-cgb-dmg.png", 30)
  add_if("scribbltests/lycscy", scribbl / "lycscy" / "lycscy.gb",
         scribbl / "lycscy" / "lycscy-cgb-dmg.png", 30)
  add_if("scribbltests/palettely", scribbl / "palettely" / "palettely.gb",
         scribbl / "palettely" / "palettely-dmg.png", 30)
  add_if("scribbltests/scxly", scribbl / "scxly" / "scxly.gb",
         scribbl / "scxly" / "scxly-dmg.png", 30)
  add_if("scribbltests/statcount-auto", scribbl / "statcount" / "statcount-auto.gb",
         scribbl / "statcount" / "statcount_auto-cgb-dmg.png", 300)

  # turtle-tests (Powerlated) — window Y-trigger behavior.
  let turtle = roms_dir / "turtle-tests"
  for name in ["window_y_trigger", "window_y_trigger_wx_offscreen"]:
    add_if("turtle-tests/" & name, turtle / name / (name & ".gb"),
           turtle / name / (name & ".png"), 60)

  # cgb-acid-hell (mattcurrie). Finishes on LD B,B.
  let hell = roms_dir / "cgb-acid-hell"
  add_if("cgb-acid-hell/cgb-acid-hell", hell / "cgb-acid-hell.gbc",
         hell / "cgb-acid-hell.png", 120, color = true, cgb = true)

  # little-things-gb (pinobatch). tellinglys needs a scripted button press,
  # which dingbat_test cannot do.
  let little = roms_dir / "little-things-gb"
  add_if("little-things-gb/firstwhite", little / "firstwhite.gb",
         little / "firstwhite-dmg-cgb.png", 60)

  # MBC3 bank tester: device-independent; the CGB reference is a compat-mode
  # capture, so only the DMG row is scored. Battery-backed, hence --nosave.
  let mbc3 = roms_dir / "mbc3-tester"
  add_if("mbc3-tester/mbc3-tester", mbc3 / "mbc3-tester.gb",
         mbc3 / "mbc3-tester-dmg.png", 60, no_save = true)
  tests

proc age_device_tokens(base: string): seq[string] =
  ## Trailing device tokens of an AGE test-rom name. AGE encodes the devices a
  ## test was verified on as dash-separated suffixes (README, "Test naming"):
  ## `ei-halt-dmgC-cgbBCE` -> @["dmgC", "cgbBCE"], `ly-ncmE` -> @["ncmE"].
  ## `ncm` means "CGB in non-CGB mode", a third device this harness does not
  ## model.
  let parts = base.split('-')
  for i in countdown(parts.high, 0):
    let p = parts[i]
    if p.len > 3 and (p.startsWith("dmg") or p.startsWith("cgb") or
                      p.startsWith("ncm")):
      result.insert(p, 0)
    else:
      break

proc age_model_for(device: string): string =
  ## `--model=` token for one AGE device token, or "" for the default. The
  ## accepted set mirrors gb_revision_from_name and must stay a subset of it:
  ## dingbat_test quits on a token it cannot parse, so a span like `cgbBCE`
  ## is left to age_models_for rather than guessed at.
  case device.toLowerAscii()
  of "dmg0", "dmg", "dmga", "dmgb", "dmgc", "dmgabc", "mgb",
     "cgb0", "cgb0b", "cgba", "cgbab", "cgbb", "cgbc", "cgb0bc", "cgbbc",
     "cgbd", "cgbcd", "cgb", "cgbe", "cgbde", "cgbcde", "cgbabcde": device
  else: ""

proc age_models_for(device: string): seq[string] =
  ## Every distinct dingbat revision an AGE span names: `cgbBCE` -> cgbab,
  ## cgbc, cgbe, one row each. DMG spans need no expansion (only grDmg0 and
  ## grDmgABC are modelled). An unrecognised character falls back to the
  ## single-token form rather than guessing, because dingbat_test quits on a
  ## token it cannot parse. The arms matter for the speed-switch ROMs
  ## (`spsw-tima-cgbBC` vs `-cgbE`, `caution/spsw-interrupts-*`), served by
  ## GbQuirks.spsw_div_mid_taps_slow / spsw_irq_leaf_hold_short.
  let d = device.toLowerAscii()
  if d.startsWith("ncm"): return @[]        # CGB in non-CGB mode: not modelled
  if not d.startsWith("cgb") or d.len <= 3:
    let one = age_model_for(device)
    return if one.len > 0: @[one] else: @[]
  for ch in d[3 .. ^1]:
    let name = case ch
               of '0': "cgb0"
               of 'a', 'b': "cgbab"
               of 'c': "cgbc"
               of 'd': "cgbd"
               of 'e': "cgbe"
               else: ""
    if name.len == 0:                        # not a revision span after all
      let one = age_model_for(device)
      return if one.len > 0: @[one] else: @[]
    if name notin result: result.add(name)

proc build_age_tests(age_dir: string): seq[TestDef] =
  ## c-sp's AGE test roms. Most end on LD B,B with the mooneye Fibonacci
  ## registers (tmMooneye); the rest ship `<rom>-<device>.png` references
  ## beside the ROM (tmScreenshot).
  var tests: seq[TestDef]
  if not dirExists(age_dir):
    echo "  Warning: age-test-roms directory not found"
    return tests
  for rom in find_roms_recursive(age_dir, ".gb"):
    let rel = rom.relativePath(age_dir).changeFileExt("")
    let base = rom.splitFile().name
    # Screenshot ROMs are the ones with `<base>-<device>.png` siblings.
    var shots: seq[(string, string)]   # (device, png path)
    for png in find_roms(rom.parentDir, ".png"):
      let pbase = png.splitFile().name
      if '-' notin pbase: continue
      let cut = pbase.rfind('-')
      if pbase[0 ..< cut] == base:
        shots.add((pbase[cut + 1 .. ^1], png))
    if shots.len > 0:
      for (device, png) in shots:
        if device.startsWith("ncm"): continue   # device not modeled
        let cgb = device.startsWith("cgb")
        let models = age_models_for(device)
        # A span becomes one row per revision it names; the suffix is added
        # only when there is more than one, so single-revision rows keep the
        # name their baseline is recorded under.
        for m in (if models.len == 0: @[""] else: models):
          var t = shot("age/" & rel & "-" & device &
                       (if models.len > 1: "@" & m else: ""),
                       rom, png, timeout = 120, color = cgb, cgb = cgb)
          t.model = m
          t.dmg = not cgb          # see the DMG arms below
          tests.add(t)
      continue
    let devices = age_device_tokens(base)
    let dmg = devices.anyIt(it.startsWith("dmg"))
    let cgb = devices.anyIt(it.startsWith("cgb"))
    if not dmg and not cgb:
      continue   # ncm-only: CGB in non-CGB mode, which this harness cannot run
    # One row per machine the name declares (`ei-halt-dmgC-cgbBCE` runs on
    # four). Failing rows stop at LD B,B (bb_breakpoint), so the extra arms
    # cost little.
    var arms: seq[(bool, string)]   # (run as CGB, --model token)
    for d in devices:
      if d.startsWith("ncm"): continue     # CGB in non-CGB mode: not modelled
      let is_cgb = d.startsWith("cgb")
      for m in age_models_for(d):
        if (is_cgb, m) notin arms: arms.add((is_cgb, m))
    if arms.len == 0: arms.add((not dmg, ""))
    for (arm_cgb, m) in arms:
      tests.add(TestDef(
        name: "age/" & rel & (if arms.len > 1: "@" & m else: ""),
        rom_path: rom,
        mode: tmMooneye,
        timeout: 1800,
        cgb: arm_cgb,
        # A DMG arm must say so: 8 AGE ROMs carry a `$80` CGB flag, and
        # without --dmg the header would run their `-dmgC` arm on a CGB while
        # the Device column (computed from --model) said DMG.
        dmg: not arm_cgb,
        model: m,
        # AGE signals failure with non-Fibonacci registers, not a signature,
        # so LD B,B must end the run or a failing ROM burns the whole timeout.
        bb_breakpoint: true,
      ))
  tests

proc build_wilbertpol_tests(roms_dir: string): seq[TestDef] =
  ## wilbertpol's fork of the Mooneye suite, built against 2016 mooneye-gb
  ## whose breakpoint was the undefined opcode 0xED (ed_breakpoint; see the
  ## 0xED handler in gb/opcodes.nim). Namespaced `mooneye-wilbertpol/`.
  ## `utils/` is a dump tool; `logic-analysis/` ROMs have no verdict.
  var tests: seq[TestDef]
  let dir = roms_dir / "mooneye-test-suite-wilbertpol"
  if not dirExists(dir):
    echo "  Warning: mooneye-test-suite-wilbertpol directory not found"
    return tests
  for rom in find_roms_recursive(dir, ".gb"):
    let rel = rom.relativePath(dir)
    let name = "mooneye-wilbertpol/" & rel.changeFileExt("")
    if rel.startsWith("utils") or rel.startsWith("logic-analysis"):
      continue
    # `ly_lyc{,_0,_144,_153}-C`: the CGB arm is not scored. The ROMs assert a
    # CGB LY=LYC behaviour dingbat produces only from CPU CGB D onward, and
    # this fork's `-C` (README: cgb+agb+ags) has no revision axis to say
    # otherwise; upstream mooneye later gained that axis and ships no ly_lyc*
    # at all. Inference from a deletion, not proof; a hardware probe would
    # settle it. The agb arms pass and are kept, as are the `_write` siblings.
    const ly_lyc_c_skip = ["ly_lyc-C.gb", "ly_lyc_0-C.gb",
                           "ly_lyc_144-C.gb", "ly_lyc_153-C.gb"]
    # The two screenshot ROMs: sprite_priority (same DMG reference as Gekkio's)
    # and madness/mgb_oam_dma_halt_sprites (MGB capture).
    if rel == "manual-only" / "sprite_priority.gb":
      tests.add(shot(name, rom, rom.parentDir / "sprite_priority-dmg.png", 120))
      continue
    if rel == "madness" / "mgb_oam_dma_halt_sprites.gb":
      var t = shot(name, rom, rom.parentDir / "mgb_oam_dma_halt_sprites_expected.png", 120)
      # Same 255/176/104 grey ramp as the Gekkio row of this name; see there.
      t.grey_tolerance = 32
      t.model = "mgb"
      tests.add(t)
      continue
    let base = rom.splitFile().name
    # The suffix after the last '-' is the only thing that picks the device,
    # including under misc/: this fork's misc/ also holds boot_hwio-S and
    # boot_regs-mgb/sgb/sgb2, which a directory-wide --cgb ran as a CGB
    # wearing an SGB boot table.
    let suffix = if '-' in base: base.rsplit('-', maxsplit = 1)[1] else: ""
    let machines = mooneye_machines_for(base)
    if machines.len == 0:
      tests.add(TestDef(
        name: name,
        rom_path: rom,
        mode: tmMooneye,
        timeout: 1800,
        cgb: suffix in ["C", "cgb", "cgb0", "A"],
        model: mooneye_model_for(base),
        ed_breakpoint: true,
      ))
    else:
      # Same per-machine fan-out as the Gekkio builder.
      for m in machines:
        # The four withdrawn ly_lyc* `-C` ROMs: drop the CGB arm only, keep AGB.
        if m == "cgbc" and rel.extractFilename in ly_lyc_c_skip: continue
        tests.add(TestDef(
          name: name & (if machines.len > 1: "@" & m else: ""),
          rom_path: rom,
          mode: tmMooneye,
          timeout: 1800,
          cgb: is_cgb_model(m),
          model: m,
          ed_breakpoint: true,
        ))
  tests

proc build_acid2_tests(): seq[TestDef] =
  var tests: seq[TestDef]
  # DMG Acid2
  let dmg_rom = ensure_rom_download(
    "https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb",
    "dmg-acid2.gb")
  let dmg_ref = ensure_png_download(
    "https://raw.githubusercontent.com/mattcurrie/dmg-acid2/master/img/reference-dmg.png",
    "dmg-acid2-reference.png")
  tests.add(TestDef(
    name: "acid2/dmg-acid2",
    rom_path: dmg_rom,
    mode: tmScreenshot,
    timeout: 120,
    expected_png: dmg_ref,
    color: false,
  ))
  # CGB Acid2
  let cgb_rom = ensure_rom_download(
    "https://github.com/mattcurrie/cgb-acid2/releases/download/v1.1/cgb-acid2.gbc",
    "cgb-acid2.gbc")
  let cgb_ref = ensure_png_download(
    "https://raw.githubusercontent.com/mattcurrie/cgb-acid2/master/img/reference.png",
    "cgb-acid2-reference.png")
  tests.add(TestDef(
    name: "acid2/cgb-acid2",
    rom_path: cgb_rom,
    mode: tmScreenshot,
    timeout: 120,
    expected_png: cgb_ref,
    color: true,
    cgb: true,
  ))
  tests

# gbdev/GBEmulatorShootout. Pinned to a commit so a CI run is reproducible and
# the ROM cache key in .github/workflows/test.yml stays meaningful; bump both
# together.
const ShootoutRev = "38b926bdbc26993d1b4c43e97979ecc66287bf02"

const ShootoutTolerance = 50
  ## The per-pixel luma tolerance gbdev's own runner uses for its references
  ## (`util.py: compareImage`, "if color > 50"); see `grey_tolerance`.

proc ensure_shootout_file(rel: string): string =
  ## One file from gbdev/GBEmulatorShootout's `testroms/` tree at ShootoutRev.
  ## daid's, CasualPokePlayer's, `which.gb` and the pre-split rtc3test builds
  ## exist nowhere else, so they are fetched file-by-file (~30 small files).
  let dir = RomCacheDir / ("shootout-" & ShootoutRev[0 ..< 7])
  let path = dir / rel
  if fileExists(path):
    return path
  createDir(path.parentDir)
  download_file("https://raw.githubusercontent.com/gbdev/GBEmulatorShootout/" &
                ShootoutRev & "/testroms/" & rel, path)
  path

proc build_shootout_tests(): seq[TestDef] =
  ## The shootout's suites that are in no bundle already downloaded, scored
  ## the way the shootout scores everything: the frame after a fixed run
  ## against a committed reference. Frame counts are its `runtime=` x 60.
  var tests: seq[TestDef]
  echo "Downloading shootout test ROMs..."

  # ax6/rtc3test (MBC3 RTC). Upstream is one ROM with a button-picked menu;
  # the shootout ships three pre-split builds, one per sub-test. Carts are
  # $143 = $80 and the references are native-CGB captures (they contain
  # #009100, outside the compat palette).
  for (n, secs) in [(1, 9.5), (2, 7.5), (3, 20.0)]:
    tests.add(TestDef(
      name: &"rtc3test/rtc3test-{n}",
      rom_path: ensure_shootout_file(&"ax6/rtc3test-{n}.gb"),
      mode: tmScreenshot,
      grey_tolerance: ShootoutTolerance,
      # The shootout's own budget: emulator.py polls for
      # `runtime + startup_time(1.0) + 5.0` seconds and emulators/dingbat.py
      # turns that into frames at 59.7275. `runtime` alone is a tighter rule
      # than gbdev's and fails rtc3test-1/-3.
      timeout: int((secs + 6.0) * 59.7275),
      expected_png: ensure_shootout_file(&"ax6/rtc3test-{n}.png"),
      cgb: true,
      color: true,
      # Battery-backed RTC cart: without this it drops a .sav into the shared
      # cache dir and the next run starts from the previous run's clock.
      no_save: true,
    ))

  # CasualPokePlayer's MBC3 tests: invalid RTC banks, single-write latch,
  # RAM-enable width. DMG, half a second each. `sgb-ext-test` is an SGB
  # packet-protocol test the shootout runs on an SGB; skipped.
  for name in ["rtc-invalid-banks-test", "latch-rtc-test", "ramg-mbc3-test"]:
    tests.add(TestDef(
      name: "cpp/" & name,
      rom_path: ensure_shootout_file("cpp/" & name & ".gb"),
      mode: tmScreenshot,
      grey_tolerance: ShootoutTolerance,
      timeout: 30,
      expected_png: ensure_shootout_file("cpp/" & name & ".png"),
      no_save: true,
    ))

  # daid's tests: STOP / speed-switch behaviour and a mid-scanline BGP probe.
  # `ppu_scanline_bgp`, `stop_instr` and `stop_instr_gbc_mode3` are
  # DMG-flagged carts the shootout runs "on GBC", i.e. CGB compatibility
  # mode. `stop_instr` (GBC) is not scored: its reference is an all-black
  # frame, which a blanked panel matches however STOP got there.
  # `rom_and_ram.gb` ships no reference (the shootout classes it INFO).
  # Mid-scanline BGP writes have three legitimate DMG outcomes (old palette,
  # new, or their OR, per console); the shootout accepts any, and so does
  # this row.
  tests.add(TestDef(
    name: "daid/ppu_scanline_bgp-dmg",
    rom_path: ensure_shootout_file("daid/ppu_scanline_bgp.gb"),
    mode: tmScreenshot,
    grey_tolerance: ShootoutTolerance,
    timeout: 30,
    expected_png: ensure_shootout_file("daid/ppu_scanline_bgp_0.dmg.png"),
    alt_pngs: @[ensure_shootout_file("daid/ppu_scanline_bgp_1.dmg.png"),
                ensure_shootout_file("daid/ppu_scanline_bgp_2.dmg.png")],
  ))
  # The same ROM on a CGB in compatibility mode at the revision its capture
  # is of (`--cgb --cgb-rev=E` is what the shootout adapter runs). Exact at
  # cgbD and cgbE, 576 px off at cgb0/AB/C/agb: the split is
  # quirks.mixer_write_immediate. The only row in either harness that
  # separates CGB-C from CGB-E.
  tests.add(TestDef(
    name: "daid/ppu_scanline_bgp-gbc",
    rom_path: ensure_shootout_file("daid/ppu_scanline_bgp.gb"),
    mode: tmScreenshot,
    grey_tolerance: ShootoutTolerance,
    timeout: 30,
    expected_png: ensure_shootout_file("daid/ppu_scanline_bgp.gbc.png"),
    color: true,
    cgb: true,
    model: "cgbe",
  ))
  # STOP blanks the DMG panel, because the PPU stops with it.
  tests.add(TestDef(
    name: "daid/stop_instr-dmg",
    rom_path: ensure_shootout_file("daid/stop_instr.gb"),
    mode: tmScreenshot,
    grey_tolerance: ShootoutTolerance,
    timeout: 30,
    expected_png: ensure_shootout_file("daid/stop_instr.dmg.png"),
  ))
  # The one GBC daid row worth gating: the ROM prints "LCD on: PASS", spins
  # until STAT reads mode 3, then STOPs; daid's note says a mode-3 STOP on a
  # CGB keeps displaying because the PPU keeps running. An implementation
  # that blanks the panel scores 1.1%.
  tests.add(TestDef(
    name: "daid/stop_instr_gbc_mode3",
    rom_path: ensure_shootout_file("daid/stop_instr_gbc_mode3.gb"),
    mode: tmScreenshot,
    grey_tolerance: ShootoutTolerance,
    timeout: 30,
    expected_png: ensure_shootout_file("daid/stop_instr_gbc_mode3.png"),
    color: true,
    cgb: true,
  ))
  # Speed-switch trio: a STOP-driven switch must reset DIV and land LY/STAT
  # where hardware does. Native CGB carts ($143 = $C0).
  for which in ["div", "ly", "stat"]:
    tests.add(TestDef(
      name: "daid/speed_switch_timing_" & which,
      rom_path: ensure_shootout_file("daid/speed_switch_timing_" & which & ".gbc"),
      mode: tmScreenshot,
      grey_tolerance: ShootoutTolerance,
      timeout: 30,
      expected_png: ensure_shootout_file(
        "daid/speed_switch_timing_" & which & ".png"),
      color: true,
      cgb: true,
    ))

  # `acid/which.gb` ships no reference image; the shootout scores it INFO.
  tests

# jsmolka/gba-tests. Pinned to a commit so a CI run is reproducible and the
# ROM cache key stays meaningful; bump both together.
const JsmolkaRev = "a6447c5404c8fc2898ddc51f438271f832083b7e"

proc ensure_jsmolka_test_roms(): string =
  ## Fetch (and cache) the jsmolka gba-tests tree, returning the directory that
  ## holds arm/, thumb/, ... The upstream repo ships the assembled .gba files,
  ## so there is nothing to build.
  let dir = RomCacheDir / "gba-tests-" & JsmolkaRev[0 ..< 7]
  let inner = dir / "gba-tests-" & JsmolkaRev
  if fileExists(inner / "arm" / "arm.gba"):
    return inner
  if dirExists(dir): removeDir(dir)
  echo "Downloading jsmolka/gba-tests..."
  createDir(RomCacheDir)
  let zipfile = RomCacheDir / "gba-tests.zip"
  download_file(&"https://github.com/jsmolka/gba-tests/archive/{JsmolkaRev}.zip", zipfile)
  try:
    extractAll(zipfile, dir)
  except ZippyError, IOError, OSError:
    echo "Failed to extract: ", getCurrentExceptionMsg()
    if dirExists(dir): removeDir(dir)
    removeFile(zipfile)
    quit(1)
  removeFile(zipfile)
  inner

proc build_jsmolka_tests(dir: string): seq[TestDef] =
  ## arm, thumb, memory, bios, save/*, unsafe report through the r12 protocol
  ## --mode=jsmolka reads, all-or-nothing, naming the first failed check. The
  ## ppu/ and nes/ ROMs only draw and ship no reference, so they are gated on
  ## a pinned hash of the frame.
  var tests: seq[TestDef]
  for (group, rom) in [("arm", "arm"), ("thumb", "thumb"), ("memory", "memory"),
                       ("bios", "bios"), ("save", "none"), ("save", "sram"),
                       ("save", "flash64"), ("save", "flash128"),
                       ("unsafe", "unsafe")]:
    tests.add(TestDef(
      name: "jsmolka/" & rom,
      rom_path: dir / group / (rom & ".gba"),
      mode: tmJsmolka,
      timeout: 600,
    ))
  for (group, rom, hash) in [
      ("ppu", "hello",   "6D0A0BE051BD8867"),
      ("ppu", "shades",  "75702E9A20F4A272"),
      ("ppu", "stripes", "3A6AD0222561C072"),
      ("nes", "nes",     "20BEB1A765920412")]:
    tests.add(TestDef(
      name: "jsmolka/" & rom,
      rom_path: dir / group / (rom & ".gba"),
      mode: tmScreenshot,
      timeout: 120,
      expected_hash: hash,
      color: true,
    ))
  tests

# DenSinH/FuzzARM (GPL-3.0). Five prebuilt ROMs on the master branch, no
# release tag, so the download is pinned to a commit; bump it and the ROM
# cache key in .github/workflows/test.yml together. The ROMs are randomly
# generated at build time, so a new SHA is a different 10000 tests and the
# baseline in tests/results.md must be regenerated.
const FuzzArmRev = "a675329cd57da48e3e406216ba2d79dd7e09ee20"

const FuzzArmRoms = ["ARM_DataProcessing", "ARM_Any",
                     "THUMB_DataProcessing", "THUMB_Any", "FuzzARM"]

proc ensure_fuzzarm_test_roms(): seq[string] =
  ## The five FuzzARM ROMs at the pinned commit, pulled individually from
  ## raw.githubusercontent.com. The short SHA is in the cached filename.
  var paths: seq[string]
  for rom in FuzzArmRoms:
    paths.add(ensure_rom_download(
      "https://raw.githubusercontent.com/DenSinH/FuzzARM/" & FuzzArmRev &
        "/" & rom & ".gba",
      "fuzzarm-" & FuzzArmRev[0 ..< 7] & "-" & rom & ".gba"))
  paths

proc build_fuzzarm_tests(paths: seq[string]): seq[TestDef] =
  ## Each ROM is 10000 randomized instruction tests. --mode=fuzzarm drives the
  ## ROM's "press a button to continue" gate so every failing test is
  ## reported, reading the 16-word dump at the base of eWRAM. Per-failure
  ## detail goes to stderr; stdout is the one-line tally for results.md.
  var tests: seq[TestDef]
  for i, rom in FuzzArmRoms:
    tests.add(TestDef(
      name: "fuzzarm/" & rom,
      rom_path: paths[i],
      mode: tmFuzzArm,
      # Generous: a clean pass is ~40 frames, and each reported failure costs
      # two more (one to hold the button, one to release it).
      timeout: 20000,
    ))
  tests

# alloncm/MagenTests (MIT). Releases ship the assembled .gbc files, so a
# release tag is pinned. CGB corners nothing else here touches: HBlank VRAM
# DMA (must stop while halted), KEY0 lock, STAT while the PPU is off, MBC
# out-of-bounds SRAM.
const MagenRelease = "0.5.0"

proc build_magen_tests(): seq[TestDef] =
  ## Verdict is the screen colour per src/common.asm's palette and each
  ## test's README entry; the repo ships no 160x144 reference image (see the
  ## mode comment in dingbat_test.nim). oam_internal_priority is absent: its
  ## only criterion is prose and red is a legitimate colour in it.
  var tests: seq[TestDef]
  for rom in ["hblank_vram_dma", "key0_lock_after_boot", "mbc_oob_sram_mbc1",
              "mbc_oob_sram_mbc3", "mbc_oob_sram_mbc5", "ppu_disabled_state",
              "bg_oam_priority"]:
    let path = ensure_rom_download(
      "https://github.com/alloncm/MagenTests/releases/download/" &
        MagenRelease & "/" & rom & ".gbc",
      "magen-" & MagenRelease & "-" & rom & ".gbc")
    tests.add(TestDef(
      name: "magen/" & rom,
      rom_path: path,
      # bg_oam_priority is the one that draws rather than filling the screen;
      # its documented result is "... with no red lines".
      mode: if rom == "bg_oam_priority": tmMagenNoRed else: tmMagenGreen,
      # Every one of them settles by frame 60; 300 is slack, not a wait.
      timeout: 300,
    ))
  tests

# A seq, not a fixed-size array, so an added entry needs no bound edit.
const NotScored: seq[(string, string)] = @[
  # Every deliberate skip, so "why isn't X here?" is answerable from the
  # results page. Keep in sync with the skip sites (each names its builder).
  ("blargg/oam_bug/7-timing_effect", "broken standalone build: its verbose " &
    "output overruns the $A004..$BFFF text window into the $C000 copy of its " &
    "own code, so it never reports — on real DMG hardware too (docboy#33). " &
    "Test 7 is scored through `blargg/oam_bug/combined` instead. " &
    "(build_blargg_tests)"),
  ("daid/ppu_scanline_bgp (GBC)", "its reference captures a CGB-D-or-later " &
    "palette-write dot; the tree deliberately scores CPU CGB C, which " &
    "mealybug's 27 compat-mode rows pin from the other side. " &
    "(build_shootout_tests)"),
  ("daid/stop_instr (GBC)", "reference is an all-black frame, which a " &
    "blanked panel matches however STOP got there — a gate that cannot " &
    "fail. (build_shootout_tests)"),
  ("daid/rom_and_ram, acid/which", "ship no reference image; the shootout " &
    "classes them INFO, not pass/fail. (build_shootout_tests)"),
  ("cpp/sgb-ext-test", "SGB packet-protocol test the shootout scores on an " &
    "SGB; not covered by dingbat's SGB adapter model. " &
    "(build_shootout_tests)"),
  ("magen/oam_internal_priority", "its only stated criterion is prose (\"2 " &
    "pairs of rectangles connected or touching\"); nothing machine-checkable " &
    "to score against. (build_magen_tests)"),
  ("mooneye/wilbertpol `ags` arms", "`ags` is AGB silicon in a different " &
    "package — the suite's own README says so — and dingbat models one AGB, " &
    "so a `-C`/`-A` token's `ags` member folds into its `agb` arm rather " &
    "than inventing a machine. Everything else those tokens name IS run: " &
    "see mooneye_machines_for. (build_mooneye_tests / build_wilbertpol_tests)"),
  ("mooneye/wilbertpol revision 0 inside a bare model token", "`-cgb` and " &
    "`-dmg` fan out across the revisions dingbat models but deliberately " &
    "stop short of revision 0, which the suite treats as its own machine and " &
    "ships separate `-cgb0`/`-dmg0` ROMs for precisely because it diverges. " &
    "Those separate ROMs ARE scored. (build_mooneye_tests)"),
  ("age `ncm*` rows", "CGB running in non-CGB mode, a device this harness " &
    "does not model. (build_age_tests)"),
  ("mooneye-wilbertpol `acceptance/gpu/ly_lyc{,_0,_144,_153}-C` (4 arms)",
    "they assert a CGB LY=LYC behaviour dingbat models from CPU CGB D onward, " &
    "for a `-C` group this 2016 fork's README defines as `cgb+agb+ags` with " &
    "no revision axis. Upstream mooneye later added that axis and dropped " &
    "ly_lyc* entirely. Assumed, not hardware-proven: no probe pins the C/D " &
    "split. The `_write` arms of the same family pass and ARE scored. " &
    "(build_wilbertpol_tests)"),
  ("gambatte `oamdma_src{FE00,FF00}_*read*` DMG rows (9)", "their verdict " &
    "is a byte of uninitialised WRAM. That source fetches through the echo, " &
    "so it reads $DE00/$DF00, and a colliding CPU read gets the DMA's latch " &
    "rather than its own byte -- Pan Docs says WRAM is random on power-up and " &
    "GB_POWERUP_WRAM_PATTERN honours that, so these encode gambatte's capture " &
    "rig, not hardware. The non-colliding members of the same family " &
    "(`busyread8000`, `busyreadFF4B`) and every CGB arm ARE scored. " &
    "(build_gambatte_rows / gambatte_row_reads_powerup_wram)"),
  ("gambatte `_outaudio0/1` rows (220) + the AGB column", "audio-register " &
    "sampling and the AGB device are not scored; see results_gambatte.md's " &
    "source notes. (build_gambatte_rows)"),
  ("gbmicrotest: 31 ROMs that never write the $FF82 verdict byte", "scanned " &
    "all 513 bundled ROMs for `ldh ($82),a` / `ld ($ff82),a`; 482 contain one " &
    "and these 31 contain neither, so the harness would be scoring " &
    "uninitialised HRAM rather than a result. All 31 were failing rows before " &
    "the skip. The honest suite denominator is 482. " &
    "(build_gbmicrotest_tests)"),
  ("gbmicrotest: 2 ROMs whose expected byte is unreachable", "`halt_op_dupe_delay` " &
    "wants DIV = $55 about 62 M-cycles after resetting DIV, which needs a " &
    "5,440 M-cycle HALT its own HBlank-every-line setup rules out ($55 is the " &
    "suite's scratch marker; its sibling `halt_op_dupe` is correctly written " &
    "and passes). `stat_write_glitch_l154_d` is missing the `xor a ; " &
    "ldh ($FF0F),a` its three siblings have, so it asserts IF = $E0 across a " &
    "whole frame of LCD-on time it never cleared VBlank in -- restore that " &
    "clear and it passes, strip it from `_c` at identical timing and `_c` " &
    "produces `_d`'s byte. Both are ROM " &
    "defects, not verdicts. The honest suite denominator is 480. " &
    "(build_gbmicrotest_tests)"),
  ("scribbltests/fairylake, scribbltests/winpos", "ship no reference " &
    "image. (build_small_screenshot_tests)"),
  ("little-things-gb/tellinglys", "needs scripted joypad input mid-run. " &
    "(build_small_screenshot_tests)"),
  ("mbc3-tester CGB reference", "a CGB compat-mode capture; only the DMG " &
    "row is scored. (build_small_screenshot_tests)"),
  ("mooneye/utils/ (bootrom_dumper, dump_boot_hwio)", "tools, not pass/fail " &
    "tests. bootrom_dumper waits for a boot ROM to dump and can only time out " &
    "(docs/gb-failure-triage.md calls it unrecoverable); dump_boot_hwio ends " &
    "in quit_dump_mem, which sets the success byte unconditionally, so its " &
    "green row was a gate that could not fail. (build_mooneye_tests)"),
  ("mooneye-wilbertpol utils/, logic-analysis/", "tools and analysis " &
    "captures, not pass/fail tests. (build_wilbertpol_tests)"),
  ("rtc3test upstream single ROM", "needs menu input to select a sub-test; " &
    "the shootout's three pre-split builds are scored instead. " &
    "(build_shootout_tests)"),
]

proc provenance_line(): string =
  ## Timestamp, commit (absent outside a git checkout) and ROM-bundle version,
  ## so a stale page is recognizable.
  result = "*Generated: " & now().format("yyyy-MM-dd HH:mm:ss")
  let (sha, code) = execCmdEx("git rev-parse --short HEAD", options = {poUsePath})
  if code == 0 and sha.strip().len > 0:
    result.add(" \xC2\xB7 commit " & sha.strip())
  result.add(" \xC2\xB7 game-boy-test-roms " & GbBundleVersion & "*")

proc row_detail(r: TestResult): string =
  ## The Result-cell text after the emoji. Aggregated rows always carry their
  ## pass count (the gate compares it); other failing rows carry their harness
  ## output flattened to one bounded line.
  if r.always_detail:
    return " " & r.output
  if r.passed:
    return ""
  var d = r.output.strip().splitLines().join("; ").replace("|", "/")
  if d.len == 0:
    d = "(no output)"
  elif d.len > 160:
    d = d[0 ..< 157] & "..."
  " " & d

proc generate_results_md(suites: seq[SuiteResults]): string =
  var lines: seq[string]
  lines.add("# Dingbat Test Results")
  lines.add("")
  lines.add(provenance_line())
  lines.add("")
  lines.add("Device column: the hardware the row is scored on. `cart` = the " &
    "cart header picks the device (DMG-ABC for a DMG cart, CPU CGB C for a " &
    "CGB one); `DMG`/`CGB`/`SGB` = forced; a trailing token is a specific " &
    "boot table/revision (`--model`); `\xE2\x80\x94` = GBA, which has no " &
    "device axis here. A row name ending `@<model>` is one ARM of a test whose name declares several machines: a ROM that states the devices it was verified on (AGE's `ei-halt-dmgC-cgbBCE`, mealybug's `_cgb_c`/`_cgb_d` capture pair, mooneye's `-GS` family) gets one row per revision rather than one row on whichever machine happened to be the default, so each revision is actually covered. Sections where every row passes are collapsed to a single line — the per-row table comes back as soon as anything in them fails.")
  lines.add("")

  var total = 0
  var pass_count = 0
  for suite in suites:
    for r in suite.results:
      inc total
      if r.passed: inc pass_count

  lines.add("## Summary")
  lines.add("")
  lines.add("- **Total:** " & $total)
  lines.add("- **Pass:** " & $pass_count)
  lines.add("- **Fail:** " & $(total - pass_count))
  lines.add("")
  lines.add("| Suite | Pass | Total |")
  lines.add("|-------|------|-------|")
  for suite in suites:
    let p = suite.results.countIt(it.passed)
    lines.add("| " & suite.suite_name & " | " & $p & " | " &
      $suite.results.len & " |")
  lines.add("")

  for suite in suites:
    let p = suite.results.countIt(it.passed)
    lines.add("## " & suite.suite_name & " (" & $p & "/" &
      $suite.results.len & ")")
    lines.add("")
    # An all-pass section collapses to one line. The gate loses nothing:
    # load_previous_results records the `(<pass>/<total>)` header under
    # suite_allpass_key and was_passing treats absence there as "was green";
    # aggregated rows only pass at 100%, so any drop flips the boolean.
    if suite.results.len > 0 and p == suite.results.len:
      lines.add("**All " & $p & " tests passed.**")
    else:
      lines.add("| Test | Device | Result |")
      lines.add("|------|--------|--------|")
      for r in suite.results:
        let emoji = if r.passed: "\xF0\x9F\x91\x8C" else: "\xF0\x9F\x91\x80"
        let dev = if r.device.len > 0: r.device else: "\xE2\x80\x94"
        # The FULL test name, suite prefix included: it is the key the gate
        # reads back, and forks of suites (mooneye vs mooneye-wilbertpol)
        # would collide on anything shorter.
        lines.add("| " & r.name & " | " & dev & " | " & emoji & row_detail(r) & " |")
    if suite.suite_name == "GBA - mGBA Test Suite":
      lines.add("")
      lines.add("See [detailed results](results_mgba_suite.md) for individual test outcomes.")
    elif suite.suite_name == "Game Boy - gambatte":
      lines.add("")
      lines.add("Each row is one gambatte subdirectory. See " &
        "[detailed results](results_gambatte.md) for individual test outcomes.")
    lines.add("")

  # Bullets, not a table: the baseline parsers treat every "| x | y |" line
  # as a potential result row, and these must never be keyed by the gate.
  lines.add("## Deliberately not scored")
  lines.add("")
  lines.add("Everything skipped on purpose, with the reason and the builder " &
    "that skips it. If a suite's row count looks short, the answer is here.")
  lines.add("")
  for (what, why) in NotScored:
    lines.add("- **" & what & "** \xE2\x80\x94 " & why)
  lines.add("")
  lines.join("\n")

proc suite_allpass_key(suite_name: string): string =
  ## Key under which load_previous_results records "this whole section was
  ## passing". Same table as the per-test entries; the NUL prefix cannot
  ## collide with a real test name.
  "\0suite-all-passed\0" & suite_name

proc was_passing(previous: Table[string, bool];
                 suite_name, test_name: string): bool =
  ## Did the committed baseline have this row green? A name absent from the
  ## baseline is ungated (new suites), EXCEPT inside a section the baseline
  ## collapsed as all-passing, where absence means "was green". Every
  ## regression gate must go through here: run_suite, run_microtest_suite,
  ## run_mgba_suite and the gambatte loop do not share a code path.
  if test_name in previous: previous[test_name]
  else: previous.getOrDefault(suite_allpass_key(suite_name))

proc load_previous_results(path: string): Table[string, bool] =
  ## The committed baseline keyed by full test name as generate_results_md
  ## writes it; a name not present is not gated, so the baseline must be
  ## regenerated when suites are added. Collapsed all-green sections have no
  ## rows, so their `## <name> (<pass>/<total>)` header is recorded instead.
  result = initTable[string, bool]()
  if not fileExists(path):
    return
  let content = readFile(path)
  for line in content.splitLines():
    if line.startsWith("## ") and line.endsWith(")"):
      let open = line.rfind('(')
      if open > 3:
        let inner = line[open + 1 ..< line.high]
        let halves = inner.split('/')
        if halves.len == 2:
          try:
            let p = parseInt(halves[0].strip())
            let t = parseInt(halves[1].strip())
            if t > 0 and p == t:
              result[suite_allpass_key(line[3 ..< open].strip())] = true
          except ValueError: discard
      continue
  for line in content.splitLines():
    if line.startsWith("| ") and not line.startsWith("| Test") and not line.startsWith("|---") and
       not line.startsWith("| Suite"):
      let parts = line.split("|").mapIt(it.strip())
      if parts.len >= 3:
        let name = parts[1]
        # The verdict cell is found by content, not position: the table grew a
        # Device column between name and verdict, and the first run after any
        # such change still reads a baseline in the OLD shape.
        var passed = false
        for cell in parts[2 .. ^1]:
          if cell.contains("\xF0\x9F\x91\x8C"):
            passed = true
            break
        result[name] = passed

proc load_previous_counts(path: string): Table[string, int] =
  ## Pass COUNTS for the aggregated "<passes>/<total> passed" rows: a drop
  ## from 1974/2020 to 1970/2020 is a regression even though the pass/fail
  ## bit never changed.
  result = initTable[string, int]()
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    if not line.startsWith("| ") or line.startsWith("| Test") or line.startsWith("|---"):
      continue
    let parts = line.split("|").mapIt(it.strip())
    if parts.len < 3: continue
    # Scan every cell after the name: the count sits in the verdict cell,
    # whose column index depends on whether the baseline predates the
    # Device column.
    block cells:
      for cell in parts[2 .. ^1]:
        let words = cell.splitWhitespace()
        for i, w in words:
          if w == "passed" and i > 0 and '/' in words[i - 1]:
            let halves = words[i - 1].split('/')
            try:
              result[parts[1]] = parseInt(halves[0])
            except ValueError: discard
            break cells

proc device_label(t: TestDef): string =
  ## The results.md Device column. "cart" = no override, the header picks
  ## (DMG-ABC for a DMG cart, CPU CGB C for a CGB one, see gb_set_revision).
  ## A --model token rides along, which also exposes contradictions ("CGB
  ## sgb"). GBA rows have no device axis.
  if t.mode in {tmMgba, tmMgbaSuite, tmJsmolka, tmFuzzArm}:
    return ""
  # Nor does a GBA ROM scored by screenshot (jsmolka's ppu/ and nes/ rows):
  # the mode does not identify the machine, the ROM does.
  if t.rom_path.endsWith(".gba"):
    return ""
  result =
    if t.sgb: "SGB"
    elif t.dmg: "DMG"
    elif t.cgb: "CGB"
    # Screenshot rows are the one mode where the harness takes the absence of
    # --cgb as "force a DMG" instead of letting the header decide (see
    # force_dmg in dingbat_test.nim), so "cart" would be a lie there.
    elif t.mode == tmScreenshot: "DMG"
    else: "cart"
  if t.model.len > 0:
    # A `--model` token pins the machine even when no --dmg/--cgb flag was
    # passed, so "cart" would understate it: the header is not deciding
    # anything any more. Promote the base to the family the token names, which
    # is what makes `age/.../-dmgC` print "DMG dmgC" rather than "cart dmgC".
    if result == "cart":
      let m = t.model.toLowerAscii()
      result = if m.startsWith("dmg") or m == "mgb": "DMG"
               elif m.startsWith("cgb"): "CGB"
               elif m.startsWith("sgb"): "SGB"
               elif m.startsWith("agb"): "AGB"
               else: result
    result.add(" " & t.model)

proc run_suite(name: string; tests: seq[TestDef]; harness: string;
               previous: Table[string, bool]; regressions: var seq[string]): SuiteResults =
  echo &"\n=== {name} ==="
  var results: seq[TestResult]
  for test in tests:
    var r = run_test(test, harness)
    r.device = device_label(test)
    let status = if r.passed: "PASS" else: "FAIL"
    if test.mode in {tmScreenshot, tmFuzzArm, tmMagenGreen, tmMagenNoRed, tmMicrotest}:
      echo &"  [{status}] {test.name} - {r.output}"
    else:
      echo &"  [{status}] {test.name}"
    results.add(r)
    if was_passing(previous, name, test.name) and not r.passed:
      regressions.add(test.name)
  SuiteResults(suite_name: name, results: results)

proc run_sharded_batch(harness, mode, work_name, prefix: string;
                       list_lines: seq[string]): seq[string] =
  ## One `--mode=<mode> --list=<file>` process per core; returns, per input
  ## line, the verdict its shard wrote (`<prefix> <local index> <...>`) or ""
  ## if none came back. Rows build a fresh emulator each and write no files,
  ## so sharding cannot change a verdict.
  ##
  ## Spawn with real argv and `--out`, never a command string ending in
  ## `> out.txt 2>&1`: poEvalCommand is not a shell on Windows, the tokens
  ## become argv, the verdicts land in an undrained pipe and every shard
  ## blocks (23dcae4).
  result = newSeq[string](list_lines.len)
  if list_lines.len == 0: return
  let work_dir = getTempDir() / work_name
  removeDir(work_dir)
  createDir(work_dir)
  defer: removeDir(work_dir)
  let shards = max(1, min(countProcessors(), 16))
  var shard_rows = newSeq[seq[int]](shards)
  # Round-robin, not contiguous blocks: cost per entry is far from uniform, so
  # dealing them out keeps the shards balanced.
  for i in 0 ..< list_lines.len: shard_rows[i mod shards].add(i)
  var out_paths = newSeq[string](shards)
  var procs: seq[Process]
  for s in 0 ..< shards:
    if shard_rows[s].len == 0: continue
    let list_path = work_dir / &"list{s}.tsv"
    out_paths[s] = work_dir / &"out{s}.txt"
    var lines: seq[string]
    for i in shard_rows[s]: lines.add(list_lines[i])
    writeFile(list_path, lines.join("\n") & "\n")
    procs.add(startProcess(harness, args = @[&"--mode={mode}",
                                             "--list=" & list_path,
                                             "--out=" & out_paths[s]],
                           options = {poUsePath, poParentStreams}))
  for p in procs:
    discard p.waitForExit()
    p.close()
  for s in 0 ..< shards:
    if out_paths[s].len == 0 or not fileExists(out_paths[s]): continue
    for line in readFile(out_paths[s]).splitLines():
      if not line.startsWith(prefix & " "): continue
      let parts = line.split(' ', maxsplit = 2)
      if parts.len < 3: continue
      var local: int
      try: local = parseInt(parts[1])
      except ValueError: continue
      if local < 0 or local >= shard_rows[s].len: continue
      result[shard_rows[s][local]] = parts[2]

proc split_verdict(v: string): tuple[passed: bool; detail: string] =
  ## `"PASS some detail"` -> (true, "some detail"). An empty verdict is a shard
  ## that never reported this row, which is a failure with a legible reason
  ## rather than a silent pass.
  if v.len == 0:
    return (false, "harness produced no verdict (crash or timeout in its shard)")
  let sp = v.find(' ')
  if sp < 0: (v == "PASS", "")
  else: (v[0 ..< sp] == "PASS", v[sp + 1 .. ^1].strip())

proc run_microtest_suite(name: string; tests: seq[TestDef]; harness: string;
                         previous: Table[string, bool];
                         regressions: var seq[string]): SuiteResults =
  ## GBMicrotest, batched one process per core: spawn+load dominated a
  ## process-per-ROM run. The ROMs are no_save and write nothing.
  echo &"\n=== {name} ==="
  var list_lines: seq[string]
  for t in tests: list_lines.add($t.timeout & "\t" & t.rom_path)
  let verdicts = run_sharded_batch(harness, "microtest", "dingbat-microtest",
                                   "MT", list_lines)
  var results: seq[TestResult]
  for i, t in tests:
    let (passed, detail) = split_verdict(verdicts[i])
    echo &"  [{(if passed: \"PASS\" else: \"FAIL\")}] {t.name} - {detail}"
    results.add(TestResult(name: t.name, passed: passed, output: detail,
                           device: device_label(t)))
    if was_passing(previous, name, t.name) and not passed:
      regressions.add(t.name)
  SuiteResults(suite_name: name, results: results)

proc run_mgba_suite(harness: string; previous: Table[string, bool];
                    regressions: var seq[string];
                    detail: var seq[MgbaSuiteDetail];
                    bios_path: string = ""): SuiteResults =
  echo &"\n=== GBA - mGBA Test Suite ==="
  # The suite ROM tracks mattrbeck/mgba-suite-auto's LATEST release, so the
  # sha1 is what tests/results_mgba_suite.md was baselined on; a mismatch is
  # a loud warning, not a failure. On a bump, rebaseline in the same commit
  # (row counts can change too) and bump `suite<n>` in the rom-cache key in
  # .github/workflows/test.yml, or the stale key serves the old ROM.
  # The Misc "H-blank bit start" Flip rows measure the waitloop skip
  # resolution, not PPU timing (docs/mgba-suite-verdicts.md).
  const MgbaSuiteSha1 = "00480cf1d95de6236ddcbf7026fc6e11c384528a"
  let rom_path = ensure_rom_download(
    "https://github.com/mattrbeck/mgba-suite-auto/releases/latest/download/suite.gba",
    "mgba-suite.gba", MgbaSuiteSha1)
  var cmd = &"{harness.quoteShell} {rom_path.quoteShell} --mode=mgba-suite --timeout=36000"
  if bios_path.len > 0:
    cmd.add(&" --bios={bios_path.quoteShell}")
  let (output, code) = execCmdEx(cmd, options = {poUsePath})
  var results: seq[TestResult]
  var current_suite = ""
  var current_tests: seq[MgbaTestDetail]
  var pending_fail = false
  var seen_suites: seq[string]
  for line in output.strip().splitLines():
    let stripped = line.strip()
    if stripped.len == 0: continue
    if stripped.startsWith("BEGIN: "):
      let name = stripped[7 .. ^1]
      if name in seen_suites:
        break  # Suite is looping; stop after first complete pass
      current_suite = name
      current_tests = @[]
      pending_fail = false
    elif stripped.startsWith("END: "):
      let counts = stripped[5 .. ^1]
      let parts = counts.split("/")
      if parts.len == 2:
        let passes = parseInt(parts[0].strip())
        let total = parseInt(parts[1].strip())
        let passed = passes == total
        let status = if passed: "PASS" else: "FAIL"
        echo &"  [{status}] mgba-suite/{current_suite} - {passes}/{total} passed"
        results.add(TestResult(
          name: "mgba-suite/" & current_suite,
          passed: passed,
          output: &"{passes}/{total} passed",
        ))
        detail.add(MgbaSuiteDetail(
          name: current_suite, passes: passes, total: total,
          tests: current_tests,
        ))
        if was_passing(previous, "GBA - mGBA Test Suite",
                       "mgba-suite/" & current_suite) and not passed:
          regressions.add("mgba-suite/" & current_suite)
        seen_suites.add(current_suite)
      pending_fail = false
    elif stripped.startsWith("PASS: "):
      current_tests.add(MgbaTestDetail(name: stripped[6 .. ^1], passed: true))
      pending_fail = false
    elif stripped.startsWith("FAIL: "):
      current_tests.add(MgbaTestDetail(name: stripped[6 .. ^1], passed: false))
      pending_fail = true
    elif pending_fail and stripped.endsWith(": FAIL"):
      # "DMA0 16: Got 0x00001DB2 vs 0x0000FACE: FAIL" -> actual/expected from "Got X vs Y"
      let colon_pos = stripped.find(": ")
      if colon_pos >= 0 and current_tests.len > 0 and stripped.len >= colon_pos + 2 + 7:
        let reason = stripped[colon_pos + 2 .. ^7].splitWhitespace().join(" ")  # strip ": FAIL", collapse ws
        if reason.startsWith("Got ") and reason.contains(" vs "):
          let inner = reason[4 .. ^1]  # strip "Got "
          let vs_pos = inner.find(" vs ")
          # misc-edge.c alone passes (expected, value) to doResult where every
          # other suite source passes (value, expected); un-swap it here
          # (docs/mgba-suite-verdicts.md).
          let swapped = current_suite.startsWith("Misc")
          current_tests[^1].actual =
            if swapped: inner[vs_pos + 4 .. ^1] else: inner[0 ..< vs_pos]
          current_tests[^1].expected =
            if swapped: inner[0 ..< vs_pos] else: inner[vs_pos + 4 .. ^1]
        else:
          current_tests[^1].actual = reason
      pending_fail = false
  # If a suite was started but never finished (timeout), record it
  if current_suite.len > 0 and (results.len == 0 or results[^1].name != "mgba-suite/" & current_suite):
    echo &"  [TIMEOUT] mgba-suite/{current_suite}"
    results.add(TestResult(
      name: "mgba-suite/" & current_suite,
      passed: false,
      output: "timed out",
      timed_out: true,
    ))
    detail.add(MgbaSuiteDetail(
      name: current_suite, tests: current_tests, timed_out: true,
    ))
  SuiteResults(suite_name: "GBA - mGBA Test Suite", results: results)

proc generate_mgba_detail_md(details: seq[MgbaSuiteDetail]): string =
  var lines: seq[string]
  lines.add("# mGBA Test Suite - Detailed Results")
  lines.add("")
  lines.add("*Generated: " & now().format("yyyy-MM-dd HH:mm:ss") & "*")
  lines.add("")
  var total_pass = 0
  var total_all = 0
  for suite in details:
    total_pass += suite.passes
    total_all += suite.total
    let status = if suite.timed_out: " (timed out)"
                 elif suite.passes == suite.total: ""
                 else: &" ({suite.passes}/{suite.total} passed)"
    lines.add("## " & suite.name & status)
    lines.add("")
    let failures = suite.tests.filterIt(not it.passed)
    if suite.timed_out:
      lines.add("Suite did not complete (emulator timed out).")
      lines.add("")
    elif failures.len == 0:
      lines.add("All tests passed.")
      lines.add("")
    else:
      lines.add(&"{suite.passes}/{suite.total} tests passed, {failures.len} failed:")
      lines.add("")
      lines.add("| Test | Actual | Expected |")
      lines.add("|------|--------|----------|")
      for t in failures:
        lines.add("| " & t.name & " | " & t.actual & " | " & t.expected & " |")
      lines.add("")
  if total_all > 0:
    lines.add("## Summary")
    lines.add("")
    lines.add(&"- **Total:** {total_all}")
    lines.add(&"- **Pass:** {total_pass}")
    lines.add(&"- **Fail:** {total_all - total_pass}")
    lines.add("")
  lines.join("\n")

# ==================== gambatte ====================
# sinamas' gambatte suite, in the game-boy-test-roms bundle. Filename rules
# per gambatte/game-boy-test-roms-howto.md (scoring in --mode=gambatte):
#   * `dmg08` = a DMG test, `cgb04c` = a CGB test; most ROMs carry both.
#   * `_out<hex>` is the expected value per device, drawn as hex glyphs;
#     `_outaudio0/1` is an audio test; an `x` prefix disables a tag.
#   * a <rom>_dmg08.png / _cgb04c.png / _dmg08_cgb04c.png beside the ROM
#     makes it a screenshot test.
# Not scored: the 220 `_outaudio0/1` rows (the verdict needs a 2 MHz sample
# stream; dingbat's APU emits at 32,768 Hz) and the AGB column (gambatte's
# runner marks it FIXME). Reported per subdirectory; detail in
# tests/results_gambatte.md.

type
  GambatteRow = object
    dev: string        # "dmg" | "cgb"
    kind: string       # "hex" | "png"
    expected: string   # hex string, or the reference PNG's path
    rom: string
    group: string      # top-level directory under gambatte/
    name: string       # display name, unique per row

  GambatteGroup = object
    name: string
    passes: int
    total: int
    failures: seq[(string, string)]  # (row name, detail)

proc gambatte_hex_prefix(tail: string): string =
  ## The leading run of hex digits: gambatte's runner walks the tail glyph by
  ## glyph and stops at the first non-hex character.
  for c in tail:
    if c in {'0'..'9', 'a'..'f', 'A'..'F'}: result.add(c)
    else: break

proc gambatte_row_reads_powerup_wram(stem: string): bool =
  ## gambatte `oamdma` rows whose DMG verdict is a byte of uninitialised WRAM.
  ## A $FE00/$FF00 source fetches through the echo ($DE00/$DF00, mooneye
  ## oam_dma/sources-GS) and a colliding CPU read gets the DMA's latch; Pan
  ## Docs says WRAM is random on power-up (GB_POWERUP_WRAM_PATTERN). The
  ## non-colliding `busyread8000`/`busyreadFF4B` rows and the CGB arm (source
  ## on the external bus, reads $FF) are scored.
  if not (stem.startsWith("oamdma_srcFE00_") or
          stem.startsWith("oamdma_srcFF00_")): return false
  for target in ["read0000", "readA000", "readC000", "readFE00", "readFE45"]:
    if target in stem: return true
  false

proc build_gambatte_rows(gambatte_dir: string): seq[GambatteRow] =
  var rows: seq[GambatteRow]
  var roms: seq[string]
  for path in walkDirRec(gambatte_dir):
    if path.endsWith(".gb") or path.endsWith(".gbc"):
      roms.add(path)
  roms.sort(cmp[string])
  for rom in roms:
    let rel = rom.relativePath(gambatte_dir)
    let group = if DirSep in rel: rel.split(DirSep)[0] else: "(root)"
    let fname = rom.extractFilename
    let stem = fname.changeFileExt("")
    # Device markers, in gambatte's own precedence order.
    var dmg_marker, cgb_marker = ""
    if "dmg08_cgb04c_out" in stem:
      dmg_marker = "dmg08_cgb04c_out"
      cgb_marker = "dmg08_cgb04c_out"
    elif "dmg08_out" in stem:
      dmg_marker = "dmg08_out"
      if "cgb04c_out" in stem: cgb_marker = "cgb04c_out"
    elif "_out" in stem:
      cgb_marker = "_out"
    for (dev, marker) in [("dmg", dmg_marker), ("cgb", cgb_marker)]:
      if marker.len == 0: continue
      let tail = fname[fname.find(marker) + marker.len .. ^1]
      if tail.startsWith("audio0") or tail.startsWith("audio1"):
        continue  # audio verdict is out of reach, see the header comment
      if dev == "dmg" and gambatte_row_reads_powerup_wram(stem):
        continue  # verdict is uninitialised WRAM; recorded in NotScored
      let expected = gambatte_hex_prefix(tail)
      if expected.len == 0: continue
      rows.add(GambatteRow(
        dev: dev, kind: "hex", expected: expected.toUpperAscii(), rom: rom,
        group: group, name: rel.changeFileExt("") & " [" & dev & "]",
      ))
    # Reference-image rows. A shared _dmg08_cgb04c.png scores both devices.
    let base = rom.changeFileExt("")
    let both = base & "_dmg08_cgb04c.png"
    var png_for: seq[(string, string)]
    if fileExists(both):
      png_for = @[("dmg", both), ("cgb", both)]
    else:
      if fileExists(base & "_dmg08.png"): png_for.add(("dmg", base & "_dmg08.png"))
      if fileExists(base & "_cgb04c.png"): png_for.add(("cgb", base & "_cgb04c.png"))
    for (dev, png) in png_for:
      rows.add(GambatteRow(
        dev: dev, kind: "png", expected: png, rom: rom, group: group,
        name: rel.changeFileExt("") & " [" & dev & ", png]",
      ))
  rows

proc run_gambatte_suite(harness: string; previous: Table[string, bool];
                        previous_counts: Table[string, int];
                        regressions: var seq[string];
                        groups: var seq[GambatteGroup];
                        gb_test_roms_dir: string): SuiteResults =
  echo "\n=== Game Boy - gambatte ==="
  let gambatte_dir = gb_test_roms_dir / "gambatte"
  if not dirExists(gambatte_dir):
    echo "  Warning: gambatte directory not found in game-boy-test-roms"
    return SuiteResults(suite_name: "Game Boy - gambatte")
  let rows = build_gambatte_rows(gambatte_dir)
  if rows.len == 0:
    echo "  Warning: gambatte directory held no scorable ROMs"
    return SuiteResults(suite_name: "Game Boy - gambatte")

  # Sharded one --mode=gambatte process per core (run_sharded_batch); rows
  # are independent, so the split cannot change a verdict.
  var list_lines: seq[string]
  for r in rows:
    list_lines.add(r.dev & "\t" & r.kind & "\t" & r.expected & "\t" & r.rom)
  let verdicts = run_sharded_batch(harness, "gambatte", "dingbat-gambatte",
                                   "GAM", list_lines)
  var passed = newSeq[bool](rows.len)
  var detail = newSeq[string](rows.len)
  for i in 0 ..< rows.len:
    (passed[i], detail[i]) = split_verdict(verdicts[i])

  var order: seq[string]
  var by_group = initTable[string, GambatteGroup]()
  for i, row in rows:
    if row.group notin by_group:
      order.add(row.group)
      by_group[row.group] = GambatteGroup(name: row.group)
    by_group.withValue(row.group, g):
      inc g.total
      if passed[i]: inc g.passes
      else: g.failures.add((row.name, detail[i]))

  var results: seq[TestResult]
  var total_pass, total_all = 0
  for name in order:
    let g = by_group[name]
    groups.add(g)
    total_pass += g.passes
    total_all += g.total
    let all_pass = g.passes == g.total
    let short_name = "gambatte/" & name
    echo &"  [{(if all_pass: \"PASS\" else: \"FAIL\")}] {short_name} - {g.passes}/{g.total} passed"
    results.add(TestResult(
      name: short_name,
      passed: all_pass,
      output: &"{g.passes}/{g.total} passed",
      always_detail: true,
      # Each gambatte subdirectory mixes DMG and CGB rows (the device is in
      # each ROM's own filename), so the aggregate has no single device.
      device: "per-ROM",
    ))
    # Regression on either bit: an all-green group going red, or a pass COUNT
    # dropping. Key on `short_name`, the FULL row name, which is what the
    # baseline loaders read back; the bare group name ungates every row.
    if was_passing(previous, "Game Boy - gambatte", short_name) and not all_pass:
      regressions.add(short_name)
    elif previous_counts.hasKey(short_name) and g.passes < previous_counts[short_name]:
      regressions.add(&"{short_name} ({previous_counts[short_name]} -> {g.passes} passing)")
  echo &"  gambatte total: {total_pass}/{total_all} passed"
  SuiteResults(suite_name: "Game Boy - gambatte", results: results)

proc generate_gambatte_detail_md(groups: seq[GambatteGroup]): string =
  var lines: seq[string]
  lines.add("# gambatte Test Suite - Detailed Results")
  lines.add("")
  lines.add("*Generated: " & now().format("yyyy-MM-dd HH:mm:ss") & "*")
  lines.add("")
  lines.add("Each row is one ROM run on one device. `[dmg]` / `[cgb]` is the")
  lines.add("device the filename asks for; `[.., png]` rows are scored against the")
  lines.add("reference image next to the ROM, the rest against the hex value the")
  lines.add("ROM draws on screen. See tests/README.md for the mechanism.")
  lines.add("")
  var total_pass, total_all = 0
  for g in groups:
    total_pass += g.passes
    total_all += g.total
  lines.add(&"**{total_pass}/{total_all} passed.**")
  lines.add("")
  for g in groups:
    let status = if g.passes == g.total: "" else: &" ({g.passes}/{g.total} passed)"
    lines.add("## " & g.name & status)
    lines.add("")
    if g.failures.len == 0:
      lines.add(&"All {g.total} tests passed.")
      lines.add("")
    else:
      lines.add(&"{g.passes}/{g.total} tests passed, {g.failures.len} failed:")
      lines.add("")
      lines.add("| Test | Result |")
      lines.add("|------|--------|")
      for (name, det) in g.failures:
        lines.add("| " & name & " | " & det & " |")
      lines.add("")
  lines.join("\n")

proc main() =
  let harness_name = when defined(windows): "dingbat_test.exe" else: "dingbat_test"
  let harness = getCurrentDir() / harness_name
  if not fileExists(harness):
    echo "Error: dingbat_test not found. Run 'nimble test_build' first."
    quit(1)

  var bios_path = ""
  var apu_only = false
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument: discard
    of cmdLongOption, cmdShortOption:
      case p.key
      of "bios":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        bios_path = v
      of "apu":
        apu_only = true
      of "suite":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        if v == "apu": apu_only = true
        else:
          echo "Unknown suite: ", v, " (only 'apu' can be selected)"
          quit(1)
      else: discard

  # --apu (or --suite=apu): run ONLY the GB APU suites and print tallies
  # without touching any results file. They are also in the default run.
  if apu_only:
    let gb_roms = ensure_gameboy_test_roms()
    let no_previous = initTable[string, bool]()
    var apu_suites: seq[SuiteResults]
    var apu_regressions: seq[string]
    apu_suites.add(run_suite("Game Boy - Blargg dmg_sound",
      build_blargg_sound_tests(gb_roms / "blargg" / "dmg_sound", "dmg_sound", cgb = false),
      harness, no_previous, apu_regressions))
    apu_suites.add(run_suite("Game Boy - Blargg cgb_sound",
      build_blargg_sound_tests(gb_roms / "blargg" / "cgb_sound", "cgb_sound", cgb = true),
      harness, no_previous, apu_regressions))
    apu_suites.add(run_suite("Game Boy - SameSuite APU",
      build_samesuite_apu_tests(gb_roms / "same-suite"),
      harness, no_previous, apu_regressions))
    var apu_total = 0
    var apu_pass = 0
    echo ""
    for suite in apu_suites:
      let passes = suite.results.countIt(it.passed)
      echo &"{suite.suite_name}: {passes}/{suite.results.len} pass"
      apu_total += suite.results.len
      apu_pass += passes
    echo &"\nAPU total: {apu_total}, Pass: {apu_pass}, Fail: {apu_total - apu_pass}"
    quit(0)

  let results_path = getCurrentDir() / "tests" / "results.md"
  let previous = load_previous_results(results_path)
  let previous_counts = load_previous_counts(results_path)

  var all_suites: seq[SuiteResults]
  var regressions: seq[string]

  # All GB tests come from the game-boy-test-roms release
  let gb_test_roms_dir = ensure_gameboy_test_roms()

  # Blargg tests
  let blargg_tests = build_blargg_tests(gb_test_roms_dir / "blargg")
  all_suites.add(run_suite("Game Boy - Blargg", blargg_tests, harness, previous, regressions))

  # Blargg APU suites (also reachable alone via --apu)
  all_suites.add(run_suite("Game Boy - Blargg dmg_sound",
    build_blargg_sound_tests(gb_test_roms_dir / "blargg" / "dmg_sound", "dmg_sound", cgb = false),
    harness, previous, regressions))
  all_suites.add(run_suite("Game Boy - Blargg cgb_sound",
    build_blargg_sound_tests(gb_test_roms_dir / "blargg" / "cgb_sound", "cgb_sound", cgb = true),
    harness, previous, regressions))

  # Mooneye tests
  let mooneye_tests = build_mooneye_tests(gb_test_roms_dir)
  all_suites.add(run_suite("Game Boy - Mooneye", mooneye_tests, harness, previous, regressions))

  # mGBA Test Suite (GBA)
  var mgba_detail: seq[MgbaSuiteDetail]
  let mgba_results = run_mgba_suite(harness, previous, regressions, mgba_detail, bios_path)
  all_suites.add(mgba_results)

  # jsmolka gba-tests (GBA)
  let jsmolka_tests = build_jsmolka_tests(ensure_jsmolka_test_roms())
  all_suites.add(run_suite("GBA - jsmolka gba-tests", jsmolka_tests, harness,
                           previous, regressions))

  # DenSinH/FuzzARM randomized ARM/Thumb tests (GBA)
  let fuzzarm_tests = build_fuzzarm_tests(ensure_fuzzarm_test_roms())
  all_suites.add(run_suite("GBA - FuzzARM", fuzzarm_tests, harness,
                           previous, regressions))

  # Acid2 tests (screenshot comparison)
  let acid2_tests = build_acid2_tests()
  all_suites.add(run_suite("Game Boy - Acid2", acid2_tests, harness, previous, regressions))

  # MagenTests CGB corners (colour verdict)
  all_suites.add(run_suite("Game Boy - MagenTests", build_magen_tests(), harness,
                           previous, regressions))

  # Mealybug Tearoom tests (screenshot comparison)
  let mealybug_tests = build_mealybug_tests(gb_test_roms_dir / "mealybug-tearoom-tests")
  all_suites.add(run_suite("Game Boy - Mealybug Tearoom", mealybug_tests, harness, previous, regressions))

  # GBMicrotest (HRAM verdict byte), batched; see run_microtest_suite.
  all_suites.add(run_microtest_suite("Game Boy - GBMicrotest",
    build_gbmicrotest_tests(gb_test_roms_dir / "gbmicrotest"),
    harness, previous, regressions))

  # AGE test roms (mooneye-style verdict + screenshot comparison)
  all_suites.add(run_suite("Game Boy - AGE",
    build_age_tests(gb_test_roms_dir / "age-test-roms"),
    harness, previous, regressions))

  # The bundle's small screenshot suites
  all_suites.add(run_suite("Game Boy - Screenshot suites",
    build_small_screenshot_tests(gb_test_roms_dir), harness, previous, regressions))

  # SameSuite dma/ppu/interrupt (mooneye-style verdict)
  all_suites.add(run_suite("Game Boy - SameSuite",
    build_samesuite_core_tests(gb_test_roms_dir / "same-suite"),
    harness, previous, regressions))

  # SameSuite apu/ — sample-accurate APU tests (also reachable alone via --apu)
  all_suites.add(run_suite("Game Boy - SameSuite APU",
    build_samesuite_apu_tests(gb_test_roms_dir / "same-suite"),
    harness, previous, regressions))

  # The gbdev shootout's own ROMs (screenshot comparison)
  all_suites.add(run_suite("Game Boy - Shootout ROMs",
    build_shootout_tests(), harness, previous, regressions))

  # Mooneye suite, wilbertpol fork (0xED breakpoint)
  all_suites.add(run_suite("Game Boy - Mooneye (wilbertpol)",
    build_wilbertpol_tests(gb_test_roms_dir), harness, previous, regressions))

  # gambatte (aggregated per subdirectory; detail in results_gambatte.md)
  var gambatte_groups: seq[GambatteGroup]
  all_suites.add(run_gambatte_suite(harness, previous, previous_counts,
                                    regressions, gambatte_groups,
                                    gb_test_roms_dir))

  # Write results
  createDir(getCurrentDir() / "tests")
  writeFile(results_path, generate_results_md(all_suites))
  let mgba_detail_path = getCurrentDir() / "tests" / "results_mgba_suite.md"
  writeFile(mgba_detail_path, generate_mgba_detail_md(mgba_detail))
  let gambatte_detail_path = getCurrentDir() / "tests" / "results_gambatte.md"
  if gambatte_groups.len > 0:
    writeFile(gambatte_detail_path, generate_gambatte_detail_md(gambatte_groups))
  echo &"\nResults written to {results_path}"
  echo &"mGBA detail written to {mgba_detail_path}"
  if gambatte_groups.len > 0:
    echo &"gambatte detail written to {gambatte_detail_path}"

  # Summary
  var total = 0
  var pass_count = 0
  for suite in all_suites:
    for r in suite.results:
      inc total
      if r.passed: inc pass_count
  echo &"\nTotal: {total}, Pass: {pass_count}, Fail: {total - pass_count}"

  if regressions.len > 0:
    echo "\n!!! REGRESSIONS DETECTED !!!"
    for r in regressions:
      echo "  - ", r
    quit(1)

main()
