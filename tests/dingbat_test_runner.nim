import std/[os, osproc, strutils, strformat, tables, sequtils, times, algorithm, parseopt, sha1, json]
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
    tmFuzzArm, tmMagenGreen, tmMagenNoRed, tmMicrotest,
    tmMbc30Test

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
    press: string         # screenshot mode: --press schedule (F:BTN[+BTN],...)
    input: string         # --input schedule: exact-time key changes (tests/gb_timed_input.nim)
    pass_rgb: string      # screenshot mode: pass iff the bottom-right pixel is
                          # this RRGGBB (ROMs whose verdict is the backdrop)
    verdict_glyphs: string # screenshot mode: the suite's font source; the row
                           # is scored on the verdict line it draws (read_verdict_text)
    agbeeg_check: string  # screenshot mode: pass iff the harness printed
                          # `AGBEEG <this> PASS` (the cartridge's CI port)
    ed_breakpoint: bool   # opcode 0xED ends the run (wilbertpol mooneye fork)
    bb_breakpoint: bool   # LD B,B always ends the run, pass or fail (AGE)
    mbc30_screen: string  # mbc30test mode: which of the ROM's screens, rom|sram
    serial_pass: string   # serial mode: the ROM's own pass text ("" = blargg's
    serial_fail: string   # "Passed"); its failure text ends the run early
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


const TreeStamp = ".dingbat-files"

proc stamp_tree(dir: string) =
  ## List every file an extracted tree holds, for tree_intact. The local
  ## cache lives in /tmp, where the OS deletes files nobody has read for a
  ## while (macOS: three days) and leaves the directories: a tree that still
  ## looked populated was missing ROMs, and those rows failed as regressions.
  var files: seq[string]
  for path in walkDirRec(dir, relative = true):
    files.add path
  writeFile(dir / TreeStamp, files.join("\n"))

proc tree_intact(dir: string): bool =
  ## Is every file stamp_tree listed still there? No stamp (a cache from
  ## before the stamp) counts as not intact, so it is fetched again once.
  let stamp = dir / TreeStamp
  if not fileExists(stamp): return false
  for rel in readFile(stamp).splitLines:
    if rel.len > 0 and not fileExists(dir / rel): return false
  true

proc download_file(url, path: string; first_bytes = 0) =
  ## Fetch `url` to `path`. curl retries transient failures itself
  ## (--retry-all-errors covers connection errors, not just HTTP 5xx); --fail
  ## keeps an error page from being saved as a ROM. `first_bytes` > 0 fetches
  ## only that much of the file (an HTTP range).
  let range = if first_bytes > 0: &"-r 0-{first_bytes - 1} " else: ""
  let cmd = "curl -L --fail --show-error --silent " &
    "--retry 5 --retry-all-errors --retry-delay 3 " &
    "--connect-timeout 30 --max-time 600 " & range &
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
  if dirExists(dir) and tree_intact(dir):
    return dir
  if dirExists(dir):
    echo "Cached game-boy-test-roms directory is incomplete, re-downloading..."
    removeDir(dir)
  echo "Downloading game-boy-test-roms release..."
  createDir(RomCacheDir)
  let url = "https://github.com/c-sp/game-boy-test-roms/releases/download/" &
    GbBundleVersion & "/game-boy-test-roms-" & GbBundleVersion & ".zip"
  # Download and extract under this process's own names, then rename into
  # place: runners sharing the cache otherwise find each other's
  # half-extracted tree, judge it empty and delete it mid-extraction.
  let pid = $getCurrentProcessId()
  let zipfile = RomCacheDir / "gb-roms-" & pid & ".zip"
  let staging = RomCacheDir / "game-boy-test-roms-" & pid
  download_file(url, zipfile)
  try:
    # extractAll requires that staging not exist yet; it creates it
    extractAll(zipfile, staging)
  except ZippyError, IOError, OSError:
    echo "Failed to extract: ", getCurrentExceptionMsg()
    if dirExists(staging): removeDir(staging)
    removeFile(zipfile)
    quit(1)
  removeFile(zipfile)
  stamp_tree(staging)
  try:
    moveDir(staging, dir)
  except OSError:
    # Another runner put its copy in place first
    removeDir(staging)
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
  ## R channel only: the harness writes greys as R=G=B.
  let data = readFile(path)
  var pos = skip_ppm_header(data)
  var pixels: seq[uint8]
  while pos + 2 < data.len:
    pixels.add(uint8(data[pos]))
    pos += 3
  pixels

proc read_ppm_rgb(path: string): seq[uint8] =
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
  let path = RomCacheDir / filename
  if fileExists(path):
    return path
  createDir(RomCacheDir)
  download_file(url, path)
  path

proc load_verdict_glyphs(asm_path: string): seq[(char, array[8, uint8])] =
  ## The 8x8 font of the jsmolka test framework (lib/glyphs.asm: `dw` words,
  ## two per glyph from ' ', one byte per row, bit c = column c).
  var words: seq[uint32]
  for line in lines(asm_path):
    var rest = line
    while true:
      let i = rest.find("0x")
      if i < 0: break
      words.add(uint32(parseHexInt(rest[i + 2 ..< i + 10])))
      rest = rest[i + 10 .. ^1]
  for g in 0 ..< words.len div 2:
    var rows: array[8, uint8]
    for r in 0 ..< 8:
      let w = words[2 * g + r div 4]
      rows[r] = uint8((w shr (8 * (r mod 4))) and 0xFF)
    result.add((char(32 + g), rows))

proc read_verdict_text(ppm: seq[uint8]; glyphs: seq[(char, array[8, uint8])]): string =
  ## The framework's verdict line: "All tests passed" at (56, 76) or
  ## "Failed test NNN" at (60, 76) in a 240-wide RGB frame, ink = anything
  ## not the colour of pixel (0, 0). The column origin with fewer unknown
  ## cells wins.
  const w = 240
  const y0 = 76
  proc px(x, y: int): (uint8, uint8, uint8) =
    let b = 3 * (y * w + x)
    (ppm[b], ppm[b + 1], ppm[b + 2])
  let bg = px(0, 0)
  var best = ""
  var best_unknown = high(int)
  for x0 in [56, 60]:
    var text = ""
    var unknown = 0
    var cx = x0
    while cx + 8 <= w:
      var cell: array[8, uint8]
      for r in 0 ..< 8:
        for c in 0 ..< 8:
          if px(cx + c, y0 + r) != bg: cell[r] = cell[r] or uint8(1 shl c)
      var ch = '?'
      for (k, g) in glyphs:
        if g == cell:
          ch = k
          break
      if ch == '?': inc unknown
      text.add(ch)
      cx += 8
    if unknown < best_unknown:
      best_unknown = unknown
      best = text.strip()
  best

# --bios: GBA screenshot rows run on this BIOS image instead of the HLE.
var screenshot_bios = ""

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
    of tmMbc30Test: "mbc30test"
  if test.mode == tmScreenshot:
    let tmp_ppm = getTempDir() / "dingbat_test_" & test.rom_path.splitFile().name &
                  "-" & $getCurrentProcessId() & ".ppm"
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
    if test.press.len > 0:
      cmd.add(" --press=" & test.press)
    if test.input.len > 0:
      cmd.add(" --input=" & test.input.quoteShell)
    if screenshot_bios.len > 0 and test.rom_path.endsWith(".gba"):
      cmd.add(" --bios=" & screenshot_bios.quoteShell)
    let (run_output, run_code) = execCmdEx(cmd, options = {poUsePath})
    if run_code != 0:
      return TestResult(name: test.name, passed: false, output: run_output.strip())
    if test.agbeeg_check.len > 0:
      removeFile(tmp_ppm)
      let line = "AGBEEG " & test.agbeeg_check & " "
      for l in run_output.splitLines():
        if l.startsWith(line):
          let verdict = l[line.len .. ^1].strip()
          return TestResult(name: test.name, passed: verdict == "PASS", output: verdict)
      return TestResult(name: test.name, passed: false, output: "not reported")
    if test.verdict_glyphs.len > 0:
      let text = read_verdict_text(read_ppm_rgb(tmp_ppm),
                                   load_verdict_glyphs(test.verdict_glyphs))
      removeFile(tmp_ppm)
      return TestResult(name: test.name, passed: text == "All tests passed",
                        output: if text.len > 0: text else: "no verdict on screen")
    if test.pass_rgb.len > 0:
      let px = read_ppm_rgb(tmp_ppm)
      removeFile(tmp_ppm)
      let got = px[^3].toHex(2) & px[^2].toHex(2) & px[^1].toHex(2)
      return TestResult(name: test.name, passed: got == test.pass_rgb.toUpperAscii,
                        output: &"bottom-right pixel #{got}, pass is #{test.pass_rgb.toUpperAscii}")
    if test.expected_hash.len > 0:
      # No reference image ships with these ROMs; the gate is a pinned frame
      # hash (build_jsmolka_tests).
      var h = 0xCBF29CE484222325'u64
      for c in readFile(tmp_ppm):
        h = (h xor uint64(uint8(c))) * 0x100000001B3'u64
      removeFile(tmp_ppm)
      let got = h.toHex(16)
      if test.expected_hash == "unpinned":
        # No run has produced the all-pass frame yet, so there is nothing to
        # pin; the row stays red until one does and is pinned by eye.
        return TestResult(name: test.name, passed: false,
                          output: &"no all-pass frame pinned yet (frame hash {got})")
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
    if test.mbc30_screen.len > 0:
      cmd.add(" --mbc30-screen=" & test.mbc30_screen)
    if test.serial_pass.len > 0:
      cmd.add(" --serial-pass=" & test.serial_pass.quoteShell)
    if test.serial_fail.len > 0:
      cmd.add(" --serial-fail=" & test.serial_fail.quoteShell)
    if test.input.len > 0:
      cmd.add(" --input=" & test.input.quoteShell)
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
    if test.mode == tmMbc30Test:
      # The one verdict line (the harness's screen dump goes to stderr).
      for line in text.splitLines():
        if line.startsWith("MBC30TEST: "):
          text = line[len("MBC30TEST: ") .. ^1]
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

proc mooneye_machines_for(base: string; cgb_rep = "cgbc"): seq[string] =
  ## Every `--model` a mooneye/wilbertpol ROM's filename claims (README, "Test
  ## naming": G = dmg+mgb, S = sgb+sgb2, C = cgb+agb+ags, A = agb+ags; a group
  ## token is the union of its letters). Revisions fan out only where the
  ## name lists them (`cgbABCDE` -> four rows); a bare model token gets one
  ## representative revision, `cgb_rep`, since the ROM makes no per-revision
  ## claim. Gekkio's suite keeps the default CGB-C (its README's device table
  ## verifies on CPU CGB C and D); wilbertpol's fork passes CGB-E, see
  ## build_wilbertpol_tests. Revision 0 is never in a fan-out: the suite ships
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
      of 'C': picked.add(cgb_rep); picked.add("agb")
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
    of "cgb":           picked.add(cgb_rep)
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
        # This reference uses grey ramp 255/176/104 where mooneye (and dingbat)
        # use 255/170/85. Shade deltas are 0/6/19 and the ramp's smallest step
        # is 72, so any tolerance in [19, 71] is shade-index equality.
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
    if name in MicrotestNoVerdict:
      continue
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
          no_save = false; model = ""; press = ""): TestDef =
  ## One screenshot TestDef. The bundled references use the palettes the
  ## harness renders (DMG #00/#55/#AA/#FF, CGB channels (X<<3)|(X>>2)).
  TestDef(name: name, rom_path: rom, mode: tmScreenshot, timeout: timeout,
          expected_png: png, color: color, cgb: cgb, no_save: no_save,
          model: model, press: press)

proc build_small_screenshot_tests(roms_dir: string): seq[TestDef] =
  ## The bundle's small screenshot suites, from an explicit table: each has
  ## its own exit condition (from its howto) and device, and the reference
  ## name encodes the capture device. A CGB-compatibility capture of a DMG
  ## cart runs with `--cgb` (force_cgb), the mealybug `_cgb_c` path. Frame
  ## counts are the howtos' run times; a ROM that signals LD B,B
  ## (cgb-acid-hell) stops there anyway.
  var tests: seq[TestDef]
  template add_if(name, rom, png: string; timeout: int; color = false;
                  cgb = false; no_save = false; model = ""; press = "") =
    if fileExists(rom) and fileExists(png):
      tests.add(shot(name, rom, png, timeout, color, cgb, no_save, model, press))

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

  # little-things-gb (pinobatch).
  let little = roms_dir / "little-things-gb"
  add_if("little-things-gb/firstwhite", little / "firstwhite.gb",
         little / "firstwhite-dmg-cgb.png", 60)
  # tellinglys: the eight keys pressed one after another; the joypad handler
  # records LY at each interrupt, and the ROM draws its pass screen when the
  # recorded LYs differ in at least 5 bits (its README: hardware passes with
  # an essentially random arrow), its fail screen otherwise. The references
  # are that pass screen. Input between frames (--press) lands on the same
  # line every time and fails, so the presses are timed (--input). The
  # schedule is DocBoy's manifest entry for this ROM (tests/config/dmg.json):
  # 1310720 dots apart, which is not a whole number of frames. The howto's
  # exit condition is 5 emulated seconds after the last press; 720 frames is
  # about 6 after the last release.
  const TellinglysInput =
    "2621440:a:press,3932160:a:release,6553600:b:press,7864320:b:release," &
    "9175040:start:press,10485760:start:release," &
    "11796480:select:press,13107200:select:release," &
    "14417920:left:press,15728640:left:release," &
    "17039360:right:press,19660800:right:release," &
    "22282240:up:press,23592960:up:release," &
    "24903680:down:press,26214400:down:release"
  let tl_rom = little / "tellinglys.gb"
  if fileExists(tl_rom) and fileExists(little / "tellinglys-dmg.png"):
    var t = shot("little-things-gb/tellinglys-dmg", tl_rom,
                 little / "tellinglys-dmg.png", 720)
    t.input = TellinglysInput
    tests.add(t)
  if fileExists(tl_rom) and fileExists(little / "tellinglys-cgb.png"):
    var t = shot("little-things-gb/tellinglys-cgb", tl_rom,
                 little / "tellinglys-cgb.png", 720, color = true, cgb = true)
    t.input = TellinglysInput
    tests.add(t)

  # MBC3 bank tester: device-independent (the howto: untested on hardware,
  # "should work on all revisions since it tests a cartridge"). The CGB
  # reference is the DMG cart in CGB compatibility mode, which --cgb can run
  # (the mealybug `_cgb_c` path) and which lays out pixel-for-pixel the same
  # here at every CGB revision -- but its green is #7BFF4A where the howto
  # beside it, every mealybug `_cgb_c` capture and the boot ROM's default
  # compat palette ($1BEF) say #7BFF31, so an exact row fails on 3,825 pixels
  # of one wrong colour. Recorded in NotScored; only the DMG row is scored.
  # Battery-backed, hence --nosave.
  let mbc3 = roms_dir / "mbc3-tester"
  add_if("mbc3-tester/mbc3-tester", mbc3 / "mbc3-tester.gb",
         mbc3 / "mbc3-tester-dmg.png", 60, no_save = true)

  # rtc3test (aaaaaa123456789): the MBC3 clock, device-independent (howto).
  # A menu picks the subtest; --press drives it and the frame budget is the
  # howto's run time plus margin (13 / 8 / 26 emulated seconds; 700 and 1500
  # frames stop short of the basic and sub-second verdicts). CGB rows are the
  # DMG cart in compatibility mode. Battery-backed, hence --nosave. The
  # shootout's pre-split builds (build_shootout_tests) cover the native-CGB
  # arm under a tolerance; these are exact and add the DMG.
  let rtc = roms_dir / "rtc3test"
  for (sub, press, frames) in [("basic-tests", "60:a", 1000),
                               ("range-tests", "60:down,80:a", 800),
                               ("sub-second-writes", "60:down,80:down,100:a", 1900)]:
    add_if("rtc3test/" & sub & "-dmg", rtc / "rtc3test.gb",
           rtc / ("rtc3test-" & sub & "-dmg.png"), frames, no_save = true,
           press = press)
    add_if("rtc3test/" & sub & "-cgb", rtc / "rtc3test.gb",
           rtc / ("rtc3test-" & sub & "-cgb.png"), frames, color = true,
           cgb = true, no_save = true, press = press)
  tests

proc age_device_tokens(base: string): seq[string] =
  ## Trailing device tokens of an AGE test-rom name. AGE encodes the devices a
  ## test was verified on as dash-separated suffixes (README, "Test naming"):
  ## `ei-halt-dmgC-cgbBCE` -> @["dmgC", "cgbBCE"], `ly-ncmE` -> @["ncmE"].
  ## `ncm` means "CGB in non-CGB mode": the same CGB revision running a
  ## DMG-flagged cart, which `--cgb` forces (compatibility mode).
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
  # `ncm` = the same CGB revisions running a DMG cart in compatibility mode
  # (force_cgb, the mealybug `_cgb_c` path); the span letters mean the same.
  if not (d.startsWith("cgb") or d.startsWith("ncm")) or d.len <= 3:
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
    # `oam/oam-write-dmgC`: not scored. Its author's runner blacklists it (the
    # AGE emulator's test-blacklist.txt names it, `_in-progress` and
    # `speed-switch/caution`, nothing else of the suite), and the source
    # marks its delay-2 line as depending on when the LCD was last switched
    # off, changing when the test runs more frames. Verified on one
    # DMG-CPU-08 in 2021. Every other line of the ROM passes here, and the
    # CGB twin (oam-write-cgbBCE) is scored on all three revisions.
    if rel == "oam" / "oam-write-dmgC":
      continue
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
        # `ncm` (CGB in non-CGB mode) is a DMG-flagged cart on a CGB: --cgb
        # forces compatibility mode, exactly as mealybug's `_cgb_c` rows run.
        let cgb = device.startsWith("cgb") or device.startsWith("ncm")
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
    # `ncm` rows are DMG-flagged carts ($143 = $00) run on a CGB, i.e. CGB
    # compatibility mode, which --cgb forces (force_cgb). Same machine as the
    # mealybug `_cgb_c` captures; every ncm arm passes.
    let cgb = devices.anyIt(it.startsWith("cgb") or it.startsWith("ncm"))
    if not dmg and not cgb:
      continue   # no device token the harness can name
    # One row per machine the name declares (`ei-halt-dmgC-cgbBCE` runs on
    # four). Failing rows stop at LD B,B (bb_breakpoint), so the extra arms
    # cost little.
    var arms: seq[(bool, string)]   # (run as CGB, --model token)
    for d in devices:
      let is_cgb = d.startsWith("cgb") or d.startsWith("ncm")
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
    # This fork's `-C` is the Color GROUP (README: cgb+agb+ags), and its
    # sources name no CPU revision ("pass: CGB, AGS"). Its Color rows run on
    # CGB-E: every `-C`/`-cgb` ROM in the fork passes on CGB D and E and six
    # (`ly_lyc{,_0,_144,_153}-C`, `ly_new_frame-C`, `ly00_mode1_2-C`) fail on
    # C, while the CPU-CGB-C rows of gambatte (`ly0/lycint152_ly153_*`,
    # `lycint152_ly0stat_*`) and AGE (`ly-dmgC-cgbBC`, `stat-mode-dmgC-cgbBC`
    # against their `-cgbE` twins) assert the C behaviour dingbat has -- no
    # machine passes both. SameBoy, which claims the whole fork, tests it on
    # CGB-E too. Upstream mooneye never carried these gpu ROMs (they were
    # written for the fork after its author's one upstream PR).
    const WilbertpolCgbRep = "cgbe"
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
    # including under misc/, which in this fork also holds boot_hwio-S and
    # boot_regs-mgb/sgb/sgb2.
    let suffix = if '-' in base: base.rsplit('-', maxsplit = 1)[1] else: ""
    let machines = mooneye_machines_for(base, WilbertpolCgbRep)
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
      for m in machines:
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
  # RAM-enable width. DMG, half a second each.
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
  # `sgb-ext-test`: the SGB packet-protocol stress test, run on the SGB
  # (--sgb; the shootout's `model=SGB`). Its `runtime=0.5` is a lower bound:
  # the shootout polls for `runtime + startup_time(1.0) + 5.0` seconds and the
  # ROM's report is still blank at 30 frames, complete well inside that
  # budget (the same rule rtc3test uses above).
  tests.add(TestDef(
    name: "cpp/sgb-ext-test",
    rom_path: ensure_shootout_file("cpp/sgb-ext-test.gb"),
    mode: tmScreenshot,
    grey_tolerance: ShootoutTolerance,
    timeout: int((0.5 + 6.0) * 59.7275),
    expected_png: ensure_shootout_file("cpp/sgb-ext-test.png"),
    sgb: true,
    no_save: true,
  ))

  # daid's tests: STOP / speed-switch behaviour and a mid-scanline BGP probe.
  # `ppu_scanline_bgp`, `stop_instr` and `stop_instr_gbc_mode3` are
  # DMG-flagged carts the shootout runs "on GBC", i.e. CGB compatibility
  # mode. `rom_and_ram.gb` ships no reference (the shootout classes it INFO).
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
  # is of (`--cgb --cgb-rev=E` is what the shootout adapter runs). Passes at
  # cgbD and cgbE, refused at cgb0/AB/C/agb: the split is
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
  # Pan Docs ("Using the STOP Instruction"): STOP turns the DMG's LCD off, so
  # the reference is a blank panel.
  tests.add(TestDef(
    name: "daid/stop_instr-dmg",
    rom_path: ensure_shootout_file("daid/stop_instr.gb"),
    mode: tmScreenshot,
    grey_tolerance: ShootoutTolerance,
    timeout: 30,
    expected_png: ensure_shootout_file("daid/stop_instr.dmg.png"),
  ))
  # The same ROM on a CGB (compatibility mode, at the revision the shootout
  # adapter runs). daid's note: the PPU keeps running through STOP but cannot
  # reach VRAM, so the panel goes black. That is a distinct outcome from a
  # blanked panel, which this harness paints white (ppu_blank_frame, and the
  # DMG reference above), so the all-black reference does discriminate.
  tests.add(TestDef(
    name: "daid/stop_instr-gbc",
    rom_path: ensure_shootout_file("daid/stop_instr.gb"),
    mode: tmScreenshot,
    grey_tolerance: ShootoutTolerance,
    timeout: 30,
    expected_png: ensure_shootout_file("daid/stop_instr.gbc.png"),
    color: true,
    cgb: true,
    model: "cgbe",
  ))
  # The ROM prints "LCD on: PASS", spins until STAT reads mode 3, then STOPs;
  # daid's note says a mode-3 STOP on a CGB keeps displaying because the PPU
  # keeps running. Refused by an implementation that blanks the panel.
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
  if tree_intact(dir):
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
  stamp_tree(dir)
  inner

# alyosha-tas/gba-tests (MIT), which extends the jsmolka framework with DMA,
# IRQ, prefetcher, bus, FIFO, LDM, serial and timer timing ROMs, and png183's
# fork of it. Pinned like JsmolkaRev.
const AlyoshaRev = "66f5f1d60cd7030b600606886c76f5c821ecaf9d"
const Png183Rev = "87937453b780e7fafc64eef80b89293ead9c636c"

proc ensure_github_tree(repo, rev, prefix: string;
                        cache_dir = RomCacheDir): string =
  ## Fetch (and cache) a GitHub repo at a commit; returns the extracted tree.
  let dir = cache_dir / prefix & "-" & rev[0 ..< 7]
  let inner = dir / repo.split('/')[1] & "-" & rev
  if tree_intact(dir): return inner
  if dirExists(dir): removeDir(dir)
  echo &"Downloading {repo}..."
  createDir(cache_dir)
  let zipfile = cache_dir / prefix & ".zip"
  download_file(&"https://github.com/{repo}/archive/{rev}.zip", zipfile)
  try:
    extractAll(zipfile, dir)
  except ZippyError, IOError, OSError:
    echo "Failed to extract: ", getCurrentExceptionMsg()
    if dirExists(dir): removeDir(dir)
    removeFile(zipfile)
    quit(1)
  removeFile(zipfile)
  stamp_tree(dir)
  inner

proc build_alyosha_tests(alyosha, png183, jsmolka: string): seq[TestDef] =
  ## Every self-checking ROM, scored on the verdict line the framework draws
  ## (read_verdict_text; the jsmolka r12 protocol misreads the LDM and halt
  ## ROMs). Left out: byte-identical copies of jsmolka's ROMs (scored there,
  ## and the fork's copies of alyosha's), and the three that only draw
  ## (`Sprite_Disable_Midline`, `Sprite_Disable_on_VRAM_Access`,
  ## `stripes_x_offset`), which ship no reference, and the ROMs whose
  ## expected values no console produced (NoHardwareVerdict; NotScored). The
  ## verdict is on screen within 30 frames; 600 is margin. Runs with HLE BIOS
  ## unless --bios: six halt/IRQ rows read differently on the real BIOS.
  const DrawOnly = ["Sprite_Disable_Midline", "Sprite_Disable_on_VRAM_Access",
                    "stripes_x_offset"]
  const NoHardwareVerdict = ["unsafe/prefetcher_branch_thumb_arm_2",
                             "fifo_dma/fifo"]
  var seen: seq[string]
  for rom in walkDirRec(jsmolka):
    if rom.endsWith(".gba"): seen.add($secureHashFile(rom))
  for (label, root) in [("alyosha", alyosha), ("png183", png183)]:
    let glyphs = root / "lib" / "glyphs.asm"
    var roms: seq[string]
    for rom in walkDirRec(root):
      if rom.endsWith(".gba"): roms.add(rom)
    roms.sort()
    for rom in roms:
      let h = $secureHashFile(rom)
      if h in seen or rom.splitFile().name in DrawOnly: continue
      seen.add(h)   # the fork's copy of a skipped ROM is skipped with it
      if rom.relativePath(root).changeFileExt("") in NoHardwareVerdict: continue
      result.add(TestDef(
        name: label & "/" & rom.relativePath(root).changeFileExt(""),
        rom_path: rom,
        mode: tmScreenshot,
        timeout: 600,
        color: true,
        no_save: true,
        verdict_glyphs: glyphs,
      ))

# Single-ROM GBA suites fetched from release assets, each pinned by SHA-1.
const RtcTestUrl = "https://github.com/CasualPokePlayer/gba-rtc-test/releases/download/r2/RtcTestROM.gba"
const RtcTestSha1 = "b76a045b79b2c7ec73787a73ceee8508355af43e"

# PeterLemon/GBA: bare-metal BIOS-call ROMs, each shipping the frame it draws
# (results and TIMER0 cycle counts) as a PNG; the author tests on a real GBA
# only. Pinned to a commit; downloaded, never vendored (no licence file).
const PeterLemonRev = "efdb535c9c6212c154379c947e758e173fd1e03d"
const PeterLemonBios = [
  "Arithmetic/ARCTAN/BIOSARCTAN", "Arithmetic/DIV/BIOSDIV",
  "Arithmetic/SQRT/BIOSSQRT", "Decompress/BIT/1BPP/BIOSBIT1BPP",
  "Decompress/BIT/2BPP/BIOSBIT2BPP", "Decompress/BIT/4BPP/BIOSBIT4BPP",
  "Decompress/BIT/8BPP/BIOSBIT8BPP", "Decompress/DIFF/BIOSDIFF",
  "Decompress/HUFFMAN/BIOSHUFFMAN", "Decompress/LZ77/BIOSLZ77",
  "Decompress/RLE/BIOSRLE", "MemoryCopy/CPUFASTSET/BIOSCPUFASTSET",
  "MemoryCopy/CPUSET/BIOSCPUSET", "Misc/CHECKSUM/BIOSCHECKSUM",
  "Reset/RegisterRam/BIOSRegisterRamReset",
  "RotationScaling/BGAffineSet/BIOSBGAFFINESET",
  "RotationScaling/OBJAffineSet/BIOSOBJAFFINESET", "Sound/Bias/BIOSSoundBias",
  "Sound/ChannelClear/BIOSSoundChannelClear",
  "Sound/DriverInit/BIOSSoundDriverInit", "Sound/DriverMain/BIOSSoundDriverMain",
  "Sound/DriverMode/BIOSSoundDriverMode",
  "Sound/DriverVSync/BIOSSoundDriverVSync",
  "Sound/GetJumpList/BIOSSoundGetJumpList",
  "Sound/MidiKey2Freq/BIOSMidiKey2Freq"]

proc build_peterlemon_bios_tests(): seq[TestDef] =
  ## One exact-image row per ROM. Run on the HLE BIOS (CI has no BIOS image):
  ## the results match, the printed cycle counts are the real BIOS's, so a red
  ## row here is HLE SWI timing. With the real BIOS all 25 match.
  for rel in PeterLemonBios:
    let base = &"https://raw.githubusercontent.com/PeterLemon/GBA/{PeterLemonRev}/BIOS/{rel}"
    let file = "peterlemon-" & PeterLemonRev[0 ..< 7] & "-" & rel.splitPath().tail
    result.add(TestDef(
      name: "peterlemon/" & rel.splitPath().tail,
      rom_path: ensure_rom_download(base & ".gba", file & ".gba"),
      mode: tmScreenshot,
      timeout: 300,
      color: true,
      no_save: true,
      expected_png: ensure_rom_download(base & ".png", file & ".png"),
    ))

const HadesTestsRev = "29274ce31005f45bf5ca214bbb599377633a511e"
const SwpTestUrl = "https://github.com/zaydlang/SwpTestsGBA/releases/download/v1.0.0/SwpBusLocking.gba"
const AgbeegUrl = "https://github.com/zaydlang/AGBEEG-Aging-Cartridge/releases/download/v0.0.2/AGBEEG_AGING_CARTRIDGE.gba"
const AgbeegSha1 = "4949798dde70f46d24bca5ee9c890cfa7c5101d8"

proc build_gba_misc_tests(): seq[TestDef] =
  ## ROMs that print their verdicts and ship no reference image, scored on a
  ## pinned hash of the frame whose every verdict reads "Passed" (checked by
  ## eye when pinned; the frame shows no clock or other varying value), plus
  ## this repo's own reference-frame ROMs at the end.
  # gba-rtc-test r2: 17 pin-level tests of the cart's Seiko S-3511A (the RTC
  # state machine: CS/SCK framing, SIO sampling, read looping, status write
  # commit points, in-pin levels). The cartridge build, not the multiboot one.
  result.add(TestDef(
    name: "gba-rtc-test/RtcTestROM",
    rom_path: ensure_rom_download(RtcTestUrl, "gba-rtc-test-r2.gba", RtcTestSha1),
    mode: tmScreenshot,
    timeout: 300,
    color: true,
    no_save: true,
    expected_hash: "5E310AB13DD390CA",
  ))

  # hades-emu/Hades-Tests (GPL-2.0): per-check PASS/FAIL and a "Total: a/b"
  # line. dma-start-delay's eight values match an AGB SP where the rig can
  # run them (its IWRAM and board-WRAM rows, tests/roms/payloads/hadesdsd.s).
  # dma-latch (3/4) has never drawn its all-pass frame here, so nothing is
  # pinned for it yet.
  for (rom, hash) in [("bios-openbus", "2E1EF1B0B52F22CA"),
                      ("timer-basic", "65ABD86A89664A82"),
                      ("dma-latch", "unpinned"),
                      ("dma-start-delay", "827A85AE0D672D8E")]:
    result.add(TestDef(
      name: "hades/" & rom,
      rom_path: ensure_rom_download(
        &"https://raw.githubusercontent.com/hades-emu/Hades-Tests/{HadesTestsRev}/roms/{rom}.gba",
        "hades-" & HadesTestsRev[0 ..< 7] & "-" & rom & ".gba"),
      mode: tmScreenshot,
      timeout: 300,
      color: true,
      no_save: true,
      expected_hash: hash,
    ))

  # zaydlang/SwpTestsGBA: a DMA and a SWP race for one word; SWP locks the bus
  # across its read and write, so the DMA's 0xCAFEBABE lands last. The verdict
  # is the backdrop: RGB8(25, 179, 25) green, drawn as #18B518.
  result.add(TestDef(
    name: "swp/SwpBusLocking",
    rom_path: ensure_rom_download(SwpTestUrl, "swp-v1.0.0-SwpBusLocking.gba"),
    mode: tmScreenshot,
    timeout: 120,
    color: true,
    no_save: true,
    pass_rgb: "18B518",
  ))

  # zaydlang/AGBEEG-Aging-Cartridge v0.0.2: hardware-measured cartridge, CPU
  # and DMA checks, each reported through the cartridge's CI port at
  # 0x04999990 (dingbat_test prints them); one row per check.
  for check in ["ROM_ACCESS_DURING_PREFETCH", "TOGGLE_PREFETCHER", "SWP_LOCKS_BUS",
                "LDM_DOES_NOT_LOCK_BUS", "STM_DOES_NOT_LOCK_BUS",
                "CPU_RUNS_IDLES_DURING_DMA"]:
    result.add(TestDef(
      name: "agbeeg/" & check.toLowerAscii,
      rom_path: ensure_rom_download(AgbeegUrl, "agbeeg-v0.0.2.gba", AgbeegSha1),
      mode: tmScreenshot,
      timeout: 600,
      color: true,
      no_save: true,
      agbeeg_check: check,
    ))

  # This repo's semiobjwin.gba (tests/roms/semiobjwin.s): a semi-transparent
  # OBJ alpha-blends with a 2nd target under a window whose colour-effect bit
  # is clear, and nothing else blends there. Scored against a reference frame
  # (tests/roms/semiobjwin_expected.png) that both reference emulators draw
  # identically in 5-bit colour; not hardware-photographed.
  result.add(TestDef(
    name: "dingbat/semiobjwin",
    rom_path: "tests/roms/semiobjwin.gba",
    mode: tmScreenshot,
    timeout: 400,          # the picture is static; 400 clears a --bios boot
    color: true,
    no_save: true,
    expected_png: "tests/roms/semiobjwin_expected.png",
  ))

proc build_hwverified_tests(): seq[TestDef] =
  ## This repo's own proof ROMs (tests/roms/hwverified), each carrying the
  ## values an AGS-001 gave and painting a green verdict pixel at (239,159)
  ## only if every checked cell matched (red otherwise; white = never
  ## finished). irqstorm is also the crash repro for a per-raise interrupt
  ## synchroniser (see its header).
  for rom in ["msrtbit", "psrmask", "thumbcmp", "ldmuser", "pcwb", "bxdecode",
              "irqwin", "dmabyte", "capdma", "sweep", "iomap", "irqstorm"]:
    result.add(TestDef(
      name: "hwverified/" & rom,
      rom_path: "tests/roms/hwverified" / (rom & ".gba"),
      mode: tmScreenshot,
      timeout: 600,
      color: true,
      no_save: true,
      pass_rgb: "00FF00",
    ))

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

# MBC30 (Pan Docs, "MBC3": the MBC30 of Japanese Pokemon Crystal drives 8
# ROM-bank bits for 4 MiB and 3 RAM-bank bits for 64 KiB). Two self-checking
# ROMs, each a release asset pinned by SHA-1:
#   ZoomTen/mbc30test v1.1 (WTFPL; source at commit 16571ba1) -- the screen it
#   draws is the verdict, read by --mode=mbc30test (see dingbat_test.nim).
#   deltabeard/simple-mbc3O-test v1.0.3 (permissive; source at 9a5f841c) --
#   prints "All banks OK" or "Bank check fail" over serial.
const Mbc30TestRelease = "v1.1"
const Mbc30TestSha = "ea2061146246ec251aeec11a8822a6d4f677c471"
const Mbc3oTestRelease = "v1.0.3"
const Mbc3oTestSha = "482bb40be9220c1fdd77cc9e469a0c22422664b9"

proc build_mbc_tests(): seq[TestDef] =
  ## Both carts are CGB-enhanced ($0143 = $80) and the mapper is on the cart,
  ## so each runs on the header's device (CGB) and forced DMG. mbc30test's
  ## ROM screen settles at frame ~271 and its SRAM screen at ~545 (two
  ## screens of one run, one row each); simple-mbc3O-test reports within a
  ## frame. 1200 / 300 are slack, not waits.
  let zoomten = ensure_rom_download(
    "https://github.com/ZoomTen/mbc30test/releases/download/" &
      Mbc30TestRelease & "/MBC3_Test.gbc",
    "zoomten-mbc30test-" & Mbc30TestRelease & "-MBC3_Test.gbc", Mbc30TestSha)
  let deltabeard = ensure_rom_download(
    "https://github.com/deltabeard/simple-mbc3O-test/releases/download/" &
      Mbc3oTestRelease & "/mbc3Otest.gb",
    "deltabeard-simple-mbc3O-test-" & Mbc3oTestRelease & "-mbc3Otest.gb",
    Mbc3oTestSha)
  var tests: seq[TestDef]
  for dmg in [false, true]:
    let suffix = if dmg: "-dmg" else: ""
    for screen in ["rom", "sram"]:
      tests.add(TestDef(name: "mbc30test/" & screen & suffix, rom_path: zoomten,
                        mode: tmMbc30Test, mbc30_screen: screen, dmg: dmg,
                        timeout: 1200))
    tests.add(TestDef(name: "simple-mbc3O-test" & suffix, rom_path: deltabeard,
                      mode: tmSerial, serial_pass: "All banks OK",
                      serial_fail: "Bank check fail", no_save: true, dmg: dmg,
                      timeout: 300))
  tests

# A seq, not a fixed-size array, so an added entry needs no bound edit.

const NotScored: seq[(string, string)] = @[
  # Every deliberate skip, so "why isn't X here?" is answerable from the
  # results page. Keep in sync with the skip sites (each names its builder).
  ("blargg/oam_bug/7-timing_effect", "broken standalone build: its verbose " &
    "output overruns the $A004..$BFFF text window into the $C000 copy of its " &
    "own code, so it never reports — on real DMG hardware too (docboy#33: " &
    "the maintainer reproduced the blank screen on a DMG through an " &
    "Everdrive X7, and the shootout leaves it out for the same reason). " &
    "Test 7 is scored through `blargg/oam_bug/combined` instead. " &
    "(build_blargg_tests)"),
  ("daid/rom_and_ram, acid/which", "ship no reference image; the shootout's " &
    "test.py gives a test with no pass image the default result INFO, not " &
    "pass/fail. (build_shootout_tests)"),
  ("magen/oam_internal_priority", "its only stated criterion is prose (\"2 " &
    "pairs of rectangles connected or touching\") plus a SameBoy window " &
    "capture in the repo's images/ (318x295, an emulator's output, not a " &
    "hardware frame); nothing machine-checkable to score against. The " &
    "harness frame shows the same two touching pairs. (build_magen_tests)"),
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
  ("age `oam/oam-write-dmgC`", "the AGE emulator's own runner blacklists it " &
    "(its test-blacklist.txt names this ROM, `_in-progress` and " &
    "`speed-switch/caution`, nothing else of the suite), and the source marks " &
    "the delay-2 line as depending on when the LCD was last switched off, " &
    "changing when the test covers more frames; verified on one DMG-CPU-08 " &
    "in 2021. Every other line of the ROM passes here; the CGB twin " &
    "`oam-write-cgbBCE` is scored on B, C and E. (build_age_tests)"),
  ("gambatte `oamdma_src{FE00,FF00}_*read*` DMG rows (9)", "their verdict " &
    "is a byte of uninitialised WRAM. That source fetches through the echo, " &
    "so it reads $DE00/$DF00, and a colliding CPU read gets the DMA's latch " &
    "rather than its own byte -- Pan Docs says WRAM is random on power-up and " &
    "GB_POWERUP_WRAM_PATTERN honours that, so these encode gambatte's capture " &
    "rig, not hardware. The non-colliding members of the same family " &
    "(`busyread8000`, `busyreadFF4B`) and every CGB arm ARE scored. " &
    "(build_gambatte_rows / gambatte_row_reads_powerup_wram)"),
  ("gambatte `scx_during_m3_spx2{,_ds}`, `scx_attrib_during_m3_spx2_ds` " &
    "CGB rows (3)", "their only disagreement is x = 0 on lines 0-7, the " &
    "object's column 6 in OBJ palette 0 colour 2, which the ROM never " &
    "writes (no OCPS/OCPD store in any of the three). Pan Docs: in CGB mode " &
    "the boot ROM leaves object colours uninitialised apart from byte 0, " &
    "and the CGB boot ROM disassembly agrees. The reference colour is the " &
    "word gambatte-core's power-on table holds there; with that one word " &
    "in place dingbat matches all three frames, and SameBoy draws the same " &
    "pixel in its own random word. The DMG halves, `spx0`/`spx1` and the " &
    "other scx_during_m3 rows ARE scored. " &
    "(build_gambatte_rows / gambatte_row_reads_powerup_objpal)"),
  ("gambatte's AGB column", "gambatte's runner marks it `FIXME: Actual AGB " &
    "results` and feeds it the CGB expectations, so it asserts nothing " &
    "about AGB. (build_gambatte_rows)"),
  ("gbmicrotest: 31 ROMs that never write the $FF82 verdict byte", "scanned " &
    "all 513 bundled ROMs for `ldh ($82),a` / `ld ($ff82),a`; 482 contain one " &
    "and these 31 contain neither, so the harness would be scoring " &
    "uninitialised HRAM rather than a result. The upstream sources agree " &
    "(none of the 31 .s files calls a test_finish macro) and GateBoy's own " &
    "test list never runs them. All 31 were failing rows before the skip. " &
    "The honest suite denominator is 482. (build_gbmicrotest_tests)"),
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
    "image: the bundle's howto says so and upstream has only animated " &
    "GIFs; fairylake is a WIP demo and winpos is a joypad-driven WX/WY " &
    "explorer. (build_small_screenshot_tests)"),
  ("gambatte/jpadirq_1, gambatte/jpadirq_2", "interactive observation ROMs " &
    "with no expected result: each shows a running hex count of joypad " &
    "interrupts (jpadirq_2 also the live P1 nibble while it flips the " &
    "selected group) for a person pressing buttons on hardware. The " &
    "filenames carry no `_out` verdict, gambatte's testrunner does not run " &
    "them, and gambatte's own note on them (test/hwtests/jpadirq.txt) says " &
    "a real press bounces several times on DMG and CGB, so the count for a " &
    "press has no single right value. (build_gambatte_rows)"),
  ("gambatte root: cgb_bgp_dumper, cgb_objp_dumper, fexx_ffxx_dumper, " &
    "fexx_read_reset_set_dumper, ioregs_reset_dumper, vram_dumper, " &
    "wram_dumper, sram", "tools, not tests: the dumpers copy palette, " &
    "$FExx/$FFxx, I/O, VRAM or WRAM contents into cart RAM for study on " &
    "hardware, and sram writes four bytes to cart RAM and shows $00. No " &
    "`_out` verdict, no reference beside them in the bundle, and gambatte's " &
    "testrunner does not run them. (gambatte-core's test/hwtests keeps " &
    "hardware cart-RAM dumps for five of the seven dumpers; the bundle does " &
    "not ship them.) (build_gambatte_rows)"),
  ("mbc3-tester CGB reference", "a CGB compatibility-mode capture the " &
    "harness can run (--cgb) and matches pixel-for-pixel in layout at every " &
    "CGB revision, except that its green is #7BFF4A where the howto beside " &
    "it, every mealybug `_cgb_c` capture and the boot ROM's default compat " &
    "palette ($1BEF) give #7BFF31 -- a colour no compat palette produces. " &
    "An exact row fails on those 3,825 pixels alone, so only the DMG row is " &
    "scored. (build_small_screenshot_tests)"),
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
  ("DocBoy: 645 rows its own manifests disable", "`\"enabled\": false`, " &
    "so DocBoy's runner never runs them and states no verdict for them: " &
    "640 `double_speed/apu/ch4` and 2 `double_speed/apu/ch3` CGB rows, " &
    "`mbc/huc3/huc3_tick` (\"takes a long time (1 real minute)\") and two " &
    "`cgb_dmg_mode` `m3_lcdc_win_en_change_multiple_wx_*_signed_addressing_" &
    "source` rows (\"glitch is different, probably uses another memory " &
    "bus\"). (build_docboy_rows)"),
  ("alyosha `unsafe/prefetcher_branch_thumb_arm_2`", "its expected values " &
    "were never produced by a console: the suite's own unsafe/README.md " &
    "says the ROM \"crashes on console due to the prefetcher being " &
    "misaligned when switching from thumb to arm mode\", and the author " &
    "moved it out of `prefetcher/` (whose `_arm`, `_arm_3` and `_arm_4` " &
    "siblings are scored) for that reason. The check it fails is that " &
    "switch: TM0 after the Thumb `bx r2` at 0x0800019E into ARM code at " &
    "0x080001A4, a branch from an odd halfword, expected 0x53, read 0x4E " &
    "here. Its first check, the ARM-to-Thumb branch before it, reads the " &
    "expected 0x3A. (build_alyosha_tests)"),
  ("alyosha `fifo_dma/fifo`", "its source marks the one check it fails, test " &
    "2 (FIFO stores while the master is off), \"gives unexpected results on " &
    "hardware\". The shipped binary (the 2023-09-01 upload, never rebuilt) " &
    "checks only that test's first TM1 read, 0x68: the value of an \"every " &
    "word of a fixed-source gamepak burst is nonsequential\" rule its upload " &
    "states and its author's next commit withdrew. On an AGB SP " &
    "(tests/roms/payloads/fifoslot.s) a fixed source bursts as an incrementing " &
    "one and the second refill comes right behind the first; dingbat reads " &
    "0x84. The test's own subject, stores with the master off being dropped, " &
    "holds on the SP and here. `fifo_2`..`fifo_6` ARE scored. " &
    "(build_alyosha_tests)"),
  ("DocBoy manifests: 725 vendored ROMs of other suites", "everything " &
    "outside `docboy/` in its manifests (blargg, mooneye, gbmicrotest, " &
    "mealybug, SameSuite, daid, magen, acid2, little-things-gb, hacktix, " &
    "firstwhite, rtc3test, cpp, zoomten, tepples). Those are scored from " &
    "their upstream releases in the sections above, each by its own " &
    "author's verdict; DocBoy's entries re-check them against DocBoy's own " &
    "frame dumps, and 8 are DocBoy edits (`samesuite/apu/channel_1/*-cgbE`, " &
    "expectations rewritten for CPU CGB E). (build_docboy_rows)"),
  ("DocBoy: the KEY1 switch's IME-set leaf (8)", "`{,double_speed_}" &
    "stop_key1_joypad0_interrupt1_ime1_*_div_round1`: `EI; STOP` with a " &
    "request pending, the leaf Pan Docs' STOP chart calls \"The CPU glitches " &
    "non-deterministically\". DocBoy wants the divider held 8 T; c-sp " &
    "`speed-switch/caution/spsw-interrupts-cgbE`, checked on a CPU CGB E, " &
    "measures 4 for the same sequence (`spsw_irq_leaf_hold_short`), and " &
    "SameBoy (CGB E) fails these eight as dingbat does. The IME-clear leaf " &
    "beside it IS scored. (build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: a joypad interrupt on key release (3)", "`joypad_{buttons,dpad}_" &
    "interrupt_release` and `cpu/interactive_visual/stop_immediate_exit_" &
    "joypad_interrupt` want the interrupt when the key is let go, from switch " &
    "bounce (DocBoy's own comment), while its `joypad_keep_pressed_interrupt` " &
    "wants exactly one for a press: a fixed bounce on every release only. Pan " &
    "Docs (\"INT $60\") raises it on a high-to-low edge and describes bounce on " &
    "a press as a mechanical effect, and gambatte's hardware note " &
    "(test/hwtests/jpadirq.txt) has a real press bounce a varying number of " &
    "times; a deterministic release model would change every game. SameBoy " &
    "fails both release rows. (build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: $FEA0-$FEFF as RAM on the CGB E (29)", "13 rows in `cgb/memory` " &
    "and 13 in `cgb_dmg_mode/memory` write the area outside modes 2/3 and read " &
    "it back as RAM, `$FEC0-$FEFF` repeating 16 bytes (Pan Docs' description " &
    "of CGB revisions 0-D). Pan Docs (\"FEA0-FEFF range\") has CGB E, AGB, AGS " &
    "and GBP return the high nibble of the low address byte twice, and the AGS " &
    "read exactly that under gbedge p0F (`$FEA0`..`$FEF8` = `AA AA BB BB .. FF " &
    "FF`, `$FEA5` still `$AA` after writing `$5A`; docs/flashcart-runbook.md). " &
    "SameBoy (CGB E, either boot ROM) fails all 26. Three `cgb/hdma/gdma_source_" &
    "wram_dma_source_ram_{160,256,480_bytes_overflow}` rows compare `$FE00-$FEFF` " &
    "after an OAM DMA beside a GDMA, the area filled with `$EF` first: OAM " &
    "matches byte for byte and only `$FEA0-$FEFF` differs (SameBoy fails them " &
    "too). The two read-while-blocked " &
    "rows per manifest ($FF) ARE scored. (build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: `boot_hram` (4)", "dmg (two), cgb, cgb_dmg_mode: every byte " &
    "matches what running Nintendo's boot ROMs leaves (dingbat's skip-boot " &
    "carries it) except `$FFFE`, which no boot ROM writes and DocBoy fixes " &
    "(\"hardcoded ... even before boot rom\"); Pan Docs (\"Power Up Sequence\") " &
    "has power-up HRAM random. SameBoy fails all four even through the real " &
    "boot ROMs. (build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: MBC3 RTC latch on a $00-then-$01 pair only (3)", "`mbc3_rtc_" &
    "latch_{0_to_2,1_to_0,1_to_1}` want no latch unless $00 is followed by $01; " &
    "CasualPokePlayer's `latch-rtc-test` hardware capture has ANY write to " &
    "`$6000-$7FFF` latch (51/51 of its cells under that rule, 23/51 under a " &
    "bit-0 edge rule; mbc3.nim), and SameBoy fails these three as well. " &
    "(build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: the window tile under a mid-fetch LCDC.5 clear (43)",
    "`dmg/ppu/visual/window_turn_off_*`: LCDC.5 cleared during the window's " &
    "first tile fetch. On 40 rows the write lands between the window map read " &
    "and its bitplane reads and DocBoy draws that tile from the BACKGROUND's " &
    "row; mealybug's hardware notes have the disable \"take effect at the end " &
    "of the current window tile\", and SameBoy (DMG B) draws dingbat's frame " &
    "pixel for pixel on all 40; on the other 3 all three emulators differ. " &
    "Hardware check pending: `window_turn_off_nops22_sprite_x4` on an MGB, " &
    "line 8, x = 9..16 (docs/gb-failure-triage.md I6). The window retrigger " &
    "and resume rows ARE scored. (build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: single-unit OAM-bug margins (10)", "`oam_bug_ld_{hl,hli}_a_" &
    "round3_{fe5c,fe5e_noisy,fe5f}` and `_round23_{fe46,fe47}`: in these " &
    "truth tables of DocBoy's DMG the written bit as it lands in row 0 " &
    "depends on row 0's old bits, or a word-3 write also rewrites word 2's " &
    "low byte, where the sibling tables in the same position on other byte " &
    "lanes (`fe58`..`fe5b`, `fe5d`) give the written bit, the maintainer marks " &
    "`fe5b`/`fe5d`/`fe5e` noisy (hardware runs that did not repeat), and " &
    "SameBoy gives the written bit on all ten. The other 258 rows of the " &
    "family ARE scored. Hardware check pending: the ten on an MGB " &
    "(docs/gb-failure-triage.md I5). (build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: a CGB trigger 2 M-cycles before a sweep clock (2)",
    "`cgb/apu/ch1/ch1_period_sweep_change_period_nr14_during_recalc_" &
    "{delay14284,step0_delay14284_round1}` want the clock 2 M-cycles after a " &
    "retrigger to take the new frequency, the DMG's 1 M-cycle trigger lead. " &
    "On the CGB a trigger that close misses the clock: SameSuite " &
    "`channel_1_sweep_restart_2` (CGB hardware; a restart 3 M-cycles before " &
    "the clock is seen, 2 is not), gambatte `sound/ch1_init_reset_sweep_" &
    "counter_timing_10` [cgb04c] (SWEEP_TRIGGER_LEAD_T_CGB = 8 T), and " &
    "SameBoy (CGB E) fails both. The DMG rows of the same family ARE scored " &
    "and pass (docs/gb-failure-triage.md I2). (build_docboy_rows, " &
    "DocboyNotScored)"),
  ("DocBoy: compat-mode window frames under mid-line LCDC.5 pulses (51)",
    "`cgb_dmg_mode/ppu/visual/m3_lcdc_win_en_change_multiple_wx_*`: mealybug's " &
    "ROM (WX = LY, LCDC.5 pulsed low twice in mode 3) with DocBoy's tile data, " &
    "on a CPU CGB E with a DMG cart. mealybug ships captures of this ROM for " &
    "the DMG only, so no CGB picture of it was measured. dingbat matches " &
    "SameBoy (CGB E) on all but 18 of the 7,344 lines; on about 520 DocBoy " &
    "alone draws other bytes for a window tile cut short by LCDC.5 (cut k <= 4 " &
    "dots after the WX match: the high plane is the tile index; k = 0: two " &
    "colour-0 tiles), on 87 SameBoy alone differs. The same ROMs' timing twins " &
    "(`m3_lcdc_win_en_change_multiple_wx_timing_*`, 90) ARE scored and pass; " &
    "DocBoy disables two signed-addressing variants itself (\"glitch is " &
    "different\"). (docs/gb-failure-triage.md I3; build_docboy_rows, " &
    "DocboyNotScored)"),
  ("DocBoy: the CGB LCDC.4 tile-data glitch, DocBoy's variations (73)",
    "`change_{bg,win}_tile_data_glitch_*` in `cgb_dmg_mode/ppu/visual` (63) and " &
    "`cgb/ppu/visual` (10): LCDC.4 flipped across a bitplane read with objects " &
    "and windows at other phases. Per line over the 73 frames: 1,562 lines are " &
    "DocBoy's alone, 1,831 SameBoy's alone (SameBoy, CGB E, passes none), 954 " &
    "three-way, 82 dingbat's alone. dingbat's glitch (CGB_TDSEL_GLITCH) is " &
    "fitted to the hardware captures mealybug ships for CGB C and D " &
    "(`m3_lcdc_tile_sel_change`, `_change2`, `_win_change`) and to " &
    "cgb-acid-hell, all of which pass; the family's other 56 rows (26 " &
    "`mealybug_shift*`, 24 `mealybug_var*`, 6 `sprites_nops*`) ARE scored and " &
    "pass. (docs/gb-failure-triage.md I3; build_docboy_rows, " &
    "DocboyNotScored)"),
  ("DocBoy: the CGB background column resumed after the window at WX = 25 (1)",
    "`cgb/ppu/visual/window_bg_reprise_wx25`: the window disabled on the WY " &
    "line, the background resuming where the fetcher stood. DocBoy differs in " &
    "3 pixels on line 12 (x = 26, 32, 33); SameBoy (CGB E) draws dingbat's " &
    "frame pixel for pixel, and the 17 CGB siblings (`_wx8`..`_wx24`, the " &
    "same rule at every other WX) ARE scored and pass. (docs/gb-failure-" &
    "triage.md I12; build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: the CGB panel across LCD off/on (13)",
    "`cgb/ppu/visual/turn_off_y*`: \"Depending on the timing, the next lines " &
    "are either kept, rendered, or cleared\" (the ROMs' own comment): the " &
    "references keep on the panel the rows drawn before LCDC.7 went low and " &
    "show later rows white or redrawn. Pan Docs (LCDC.7): \"When the display " &
    "is disabled the screen is blank\", and on re-enabling \"the screen will " &
    "stay blank during the first frame\", which dingbat's frames follow. " &
    "SameBoy (CGB E) fails all 13. The three `_b` partners checked a frame " &
    "later (`turn_off_y42_turn_on_y148_round2 #2`, `..._y52_wait144 #2`, " &
    "`..._y52_wait150 #2`) ARE scored and pass. (docs/gb-failure-triage.md " &
    "I12; build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: fresh cart RAM reading $FF (1)", "`dmg/mbc/mbc1/mbc1_initial_ram` " &
    "wants every byte of a new MBC1 cart's RAM to read $FF before anything " &
    "is written. That is an emulator convention, not hardware: a new battery " &
    "cart holds whatever its SRAM cells settled to (flash and EEPROM saves " &
    "erase to $FF; static RAM does not), and Pan Docs says nothing. No suite " &
    "in the tree reads cart RAM before writing it; mooneye's " &
    "`emulator-only/mbc1/ram_*` read it disabled ($FF, open bus) and clear " &
    "it first. dingbat keeps $00 for a cart with no save file; $FF stays a " &
    "choice open to Matt (it would change every new save's first boot). " &
    "SameBoy passes it. (docs/gb-failure-triage.md I \"Small\"; " &
    "build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: a serial slave shifting with SC = $00 (1)", "the two-player " &
    "`dmg/serial/serial_two_players_basic_transfer_master + " &
    "serial_two_players_basic_transfer_slave_sc_00`: the slave writes SC = " &
    "$00 and expects the master's byte and the serial interrupt (its source: " &
    "\"Serial transfer should start even with SC = 0\"). Pan Docs (\"Serial " &
    "Data Transfer\"): the externally clocked side \"has to set SC's Bit 7 " &
    "(that is, SC=$80) to enable the serial port\", which dingbat follows; " &
    "Gekkio's SCLK experiment (8 external edges counted with the main clock " &
    "stopped) does not say what bit 7 = 0 does. The SC = $80 pair " &
    "(`..._master + ..._slave`) IS scored and passes. Hardware question " &
    "row 24 in docs/hwprobe-questions.md (the pair on two consoles and a " &
    "cable). (build_docboy_rows, DocboyNotScored)"),
  ("DocBoy: a VRAM DMA beside an object at X = 7 (1)", "`cgb/hdma/" &
    "gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x07`: a " &
    "GDMA across mode 3 of line 1 with one object at X = 7, the ROM checking " &
    "which bytes the fetcher's VRAM reads cost it. Objects at X = 5, 6 and 7 " &
    "all pay the same 6-dot penalty (Pan Docs' OBJ penalty algorithm); at " &
    "X = 5 and 6 DocBoy, SameBoy (CGB E, VRAM dumped as a black box) and " &
    "dingbat put the object's two plane reads on the same dots, and at " &
    "X = 7 DocBoy alone moves them two dots later. SameBoy's VRAM equals " &
    "dingbat's byte for byte from byte 7 on (the row checks 16 on). No spec " &
    "text places them. The other 82 rows of the family (SCX 0..7, a window, " &
    "one or two objects at X 1..50) ARE scored and pass (VDMA_M3_PORT). " &
    "Hardware question 21 (gbedge p21 VDMABUS) covers the background map. " &
    "(docs/gb-failure-triage.md I4; build_docboy_rows, DocboyNotScored)"),
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

const DbsuiteSuiteName = "GBA - dbsuite (AGS-001)"

proc results_rank(suite_name: string): (int, string) =
  ## results.md order: every Game Boy suite before every GBA one, each
  ## console alphabetical.
  let console =
    if suite_name.startsWith("Game Boy"): 0
    elif suite_name.startsWith("GBA"): 1
    else: 2
  (console, suite_name.toLowerAscii)

proc detail_page(suite_name: string): string =
  ## The per-test page a suite writes beside results.md, or "".
  if suite_name == "GBA - mGBA Test Suite": "results_mgba_suite.md"
  elif suite_name == DbsuiteSuiteName: "results_dbsuite.md"
  elif suite_name.contains("SingleStepTests"): "results_singlestep.md"
  elif suite_name == "Game Boy - gambatte": "results_gambatte.md"
  elif suite_name == "Game Boy - DocBoy": "results_docboy.md"
  else: ""

proc generate_results_md(unordered: seq[SuiteResults]): string =
  let suites = unordered.sortedByIt(results_rank(it.suite_name))
  var lines: seq[string]
  lines.add("# Dingbat Test Results")
  lines.add("")
  lines.add(provenance_line())
  lines.add("")
  lines.add("Device column: the hardware the row is scored on. `cart` = the " &
    "cart header picks the device (DMG-ABC for a DMG cart, CPU CGB C for a " &
    "CGB one); `DMG`/`CGB`/`SGB` = forced; a trailing token is a specific " &
    "boot table/revision (`--model`); `\xE2\x80\x94` = GBA, which has no " &
    "device axis here. A row name ending `@<model>` is one ARM of a test whose name declares several machines: a ROM that states the devices it was verified on (AGE's `ei-halt-dmgC-cgbBCE`, mealybug's `_cgb_c`/`_cgb_d` capture pair, mooneye's `-GS` family) gets one row per revision rather than one row on whichever machine happened to be the default, so each revision is actually covered. A suite where every row passes has only its summary row — its per-row section comes back as soon as anything in it fails.")
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
  # The suite name links to its detail page; load_previous_results reads an
  # all-pass row here as "every row of this suite was green".
  lines.add("| Suite | Pass | Total | Status |")
  lines.add("|-------|------|-------|--------|")
  for suite in suites:
    let p = suite.results.countIt(it.passed)
    let page = detail_page(suite.suite_name)
    let name = if page.len > 0: "[" & suite.suite_name & "](" & page & ")"
               else: suite.suite_name
    let status = if suite.results.len > 0 and p == suite.results.len:
                   "\xF0\x9F\x91\x8C" else: "\xF0\x9F\x91\x80"
    lines.add("| " & name & " | " & $p & " | " & $suite.results.len &
      " | " & status & " |")
  lines.add("")

  for suite in suites:
    let p = suite.results.countIt(it.passed)
    # An all-pass suite gets no section; its summary row says it all. The
    # gate loses nothing: load_previous_results records that row under
    # suite_allpass_key and was_passing treats absence there as "was green";
    # aggregated rows only pass at 100%, so any drop flips the boolean. The
    # SingleStepTests rows are green below 100% (known divergences); their
    # pass counts are gated from results_singlestep.md instead
    # (load_singlestep_counts).
    if suite.results.len > 0 and p == suite.results.len:
      continue
    lines.add("## " & suite.suite_name & " (" & $p & "/" &
      $suite.results.len & ")")
    lines.add("")
    lines.add("| Test | Device | Result |")
    lines.add("|------|--------|--------|")
    for r in suite.results:
      let emoji = if r.passed: "\xF0\x9F\x91\x8C" else: "\xF0\x9F\x91\x80"
      let dev = if r.device.len > 0: r.device else: "\xE2\x80\x94"
      # The FULL test name, suite prefix included: it is the key the gate
      # reads back, and forks of suites (mooneye vs mooneye-wilbertpol)
      # would collide on anything shorter.
      lines.add("| " & r.name & " | " & dev & " | " & emoji & row_detail(r) & " |")
    let page = detail_page(suite.suite_name)
    if suite.suite_name == DbsuiteSuiteName:
      lines.add("")
      lines.add("One row per dbsuite sub-suite (tests/roms/dbsuite). See " &
        "[detailed results](" & page & ") for every case that is not a pass.")
    elif suite.suite_name.contains("SingleStepTests"):
      lines.add("")
      lines.add("One row per vector file (ARM7TDMI) or opcode block (SM83), " &
        "green when every failure is a known divergence. See " &
        "[detailed results](" & page & ") for the checks and the " &
        "divergences per row, tests/README.md for the evidence.")
    elif suite.suite_name == "Game Boy - gambatte":
      lines.add("")
      lines.add("Each row is one gambatte subdirectory. See " &
        "[detailed results](" & page & ") for individual test outcomes.")
    elif suite.suite_name == "Game Boy - DocBoy":
      lines.add("")
      lines.add("Each row is one section of a DocBoy manifest " &
        "(`docboy/<manifest>/<section>`). See " &
        "[detailed results](" & page & ") for individual test outcomes.")
    elif page.len > 0:
      lines.add("")
      lines.add("See [detailed results](" & page & ") for individual test outcomes.")
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
  ## regenerated when suites are added. An all-green suite has no rows, so
  ## its Summary row (`| <name> | <pass> | <total> | ...`, the name possibly
  ## a link) is recorded instead; a `## <name> (<pass>/<total>)` header, the
  ## older collapsed form, counts the same.
  result = initTable[string, bool]()
  if not fileExists(path):
    return
  let content = readFile(path)
  var in_summary = false
  for line in content.splitLines():
    if line.startsWith("| Suite |"):
      in_summary = true
      continue
    if in_summary:
      if not line.startsWith("|"):
        in_summary = false
      elif not line.startsWith("|---"):
        let parts = line.split("|").mapIt(it.strip())
        if parts.len >= 4:
          var name = parts[1]
          if name.startsWith("[") and "](" in name:
            name = name[1 ..< name.find("](")]
          try:
            let p = parseInt(parts[2])
            let t = parseInt(parts[3])
            if t > 0 and p == t:
              result[suite_allpass_key(name)] = true
          except ValueError: discard
      continue
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

proc load_singlestep_counts(path: string; counts: var Table[string, int]) =
  ## The SingleStepTests rows' pass counts from results_singlestep.md
  ## (`| <row> | <cases> | <pass> | ...`). results.md drops an all-green
  ## suite's rows, but these rows are green below 100% (known divergences),
  ## so a case sliding into a known bucket is caught by its count alone.
  if not fileExists(path):
    return
  var in_table = false
  for line in readFile(path).splitLines():
    if line.startsWith("| Row |"):
      in_table = true
    elif not line.startsWith("|"):
      in_table = false
    elif in_table and not line.startsWith("|---"):
      let parts = line.split("|").mapIt(it.strip())
      if parts.len >= 4:
        try: counts[parts[1]] = parseInt(parts[3])
        except ValueError: discard

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
  ## blocks.
  result = newSeq[string](list_lines.len)
  if list_lines.len == 0: return
  # Per process: concurrent runners (one per worktree) shared one directory
  # and deleted each other's shards
  let work_dir = getTempDir() / work_name & "-" & $getCurrentProcessId()
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

type
  DbsuiteCase = object
    name: string       # "<suite>/<case>"
    status: string     # PASS FAIL TIMEOUT CRASH SKIP, or "NOT REACHED"
    detail: string     # "got=.. exp=.." as the ROM printed it

  DbsuiteGroup = object
    name: string
    passes: int
    total: int
    cases: seq[DbsuiteCase]


proc run_dbsuite(harness: string; previous: Table[string, bool];
                 previous_counts: Table[string, int];
                 regressions: var seq[string];
                 groups: var seq[DbsuiteGroup];
                 bios_path = ""): SuiteResults =
  ## tests/roms/dbsuite: one ROM of every behaviour this project has
  ## measured on its AGB SP, each case carrying the console's answer. The ROM
  ## prints `DBSUITE case <suite>/<name> <STATUS> got=.. exp=..` per case
  ## through the mGBA debug registers and `DBSUITE ALL DONE` at the end;
  ## tests/roms/dbsuite/cases.json lists every case, so one the run never
  ## reached (a hang) is a row too. One row per sub-suite with its pass count
  ## (gated like gambatte's: all-green going red, or the count dropping);
  ## every case is in tests/results_dbsuite.md.
  echo &"\n=== {DbsuiteSuiteName} ==="
  let rom = "tests" / "roms" / "dbsuite" / "dbsuite.gba"
  var cmd = &"{harness.quoteShell} {rom.quoteShell} --mode=mgba-suite --timeout=20000"
  if bios_path.len > 0:
    cmd.add(&" --bios={bios_path.quoteShell}")
  let (output, _) = execCmdEx(cmd, options = {poUsePath})
  var reported = initTable[string, DbsuiteCase]()
  for line in output.splitLines():
    let s = line.strip()
    if not s.startsWith("DBSUITE case "): continue
    let words = s["DBSUITE case ".len .. ^1].splitWhitespace()
    if words.len < 2: continue
    reported[words[0]] = DbsuiteCase(name: words[0], status: words[1],
                                     detail: words[2 .. ^1].join(" "))
  let listing = parseJson(readFile("tests" / "roms" / "dbsuite" / "cases.json"))
  var order: seq[string]
  var by_suite = initTable[string, DbsuiteGroup]()
  for c in listing["cases"]:
    let suite = c["suite"].getStr
    let name = suite & "/" & c["name"].getStr
    if suite notin by_suite:
      order.add(suite)
      by_suite[suite] = DbsuiteGroup(name: suite)
    let got = reported.getOrDefault(name,
      DbsuiteCase(name: name, status: "NOT REACHED",
                  detail: "the run stopped before this case"))
    by_suite.withValue(suite, g):
      inc g.total
      if got.status == "PASS": inc g.passes
      g.cases.add(got)
  var results: seq[TestResult]
  for suite in order:
    let g = by_suite[suite]
    groups.add(g)
    let all_pass = g.passes == g.total
    let short_name = "dbsuite/" & suite
    echo &"  [{(if all_pass: \"PASS\" else: \"FAIL\")}] {short_name} - {g.passes}/{g.total} passed"
    for c in g.cases:
      if c.status != "PASS":
        echo &"      {c.status} {c.name} {c.detail}"
    results.add(TestResult(name: short_name, passed: all_pass,
                           output: &"{g.passes}/{g.total} passed",
                           always_detail: true))
    if was_passing(previous, DbsuiteSuiteName, short_name) and not all_pass:
      regressions.add(short_name)
    elif previous_counts.hasKey(short_name) and g.passes < previous_counts[short_name]:
      regressions.add(&"{short_name} ({previous_counts[short_name]} -> {g.passes} passing)")
  SuiteResults(suite_name: DbsuiteSuiteName, results: results)

proc generate_dbsuite_detail_md(groups: seq[DbsuiteGroup]): string =
  var lines: seq[string]
  lines.add("# dbsuite - Detailed Results")
  lines.add("")
  lines.add(provenance_line())
  lines.add("")
  lines.add("tests/roms/dbsuite/dbsuite.gba (cartridge build) in dingbat. Every " &
    "expected value is an AGB SP (AGS-001) answer; each case's source " &
    "comment in tests/roms/dbsuite/ gives its provenance. A case that is not " &
    "PASS here is dingbat disagreeing with the console.")
  lines.add("")
  var p, t = 0
  for g in groups:
    p += g.passes
    t += g.total
  lines.add(&"**Total: {p}/{t}**")
  lines.add("")
  for g in groups:
    lines.add(&"## {g.name} ({g.passes}/{g.total})")
    lines.add("")
    var bad = g.cases.filterIt(it.status != "PASS")
    if bad.len == 0:
      lines.add("All pass.")
    else:
      lines.add("| Case | Status | Got / expected |")
      lines.add("|------|--------|----------------|")
      for c in bad:
        lines.add(&"| {c.name} | {c.status} | {c.detail.replace(\"|\", \"/\")} |")
    lines.add("")
  lines.join("\n")

# ---- SingleStepTests: per-instruction CPU vectors ----
#
# SingleStepTests/sm83 and SingleStepTests/ARM7TDMI (MIT), run by
# ./singlestep_test (tests/singlestep_test.nim, built with -d:cpu_testbus)
# straight against the CPU cores on a flat test bus. Downloaded, never
# committed, into DINGBAT_SINGLESTEP_CACHE (default ~/.cache/dingbat-singlestep;
# CI points it into the cached rom-cache). Pinned to commits: bumping either
# is a re-baseline. The SM83 set is whole (500 files x 1,000 cases, 31 MB
# zipped). The ARM7TDMI set is 45 files of 50,000 cases, 20 MB each; the
# runner takes the first Arm7tdmiPrefixBytes of each (the cases are random,
# so a prefix is a random sample, ~5,000 a file), which keeps CI's download
# and cache at 90 MB. `./singlestep_test arm7tdmi <dir of whole files>` runs
# all 2.25 M. tests/README.md, "SingleStepTests", has the scoring rules and
# the known divergences.
const Sm83TestsRev = "f9c30210245dd691661db39f5ace022c465ecc2f"
const Arm7tdmiTestsRev = "e3097d88d428752736b949d94c094d5da50f0db6"
const Arm7tdmiPrefixBytes = 2 * 1024 * 1024
const Arm7tdmiFiles = [
  "arm_b_bl", "arm_bx", "arm_cdp", "arm_data_proc_immediate",
  "arm_data_proc_immediate_shift", "arm_data_proc_register_shift",
  "arm_ldm_stm", "arm_ldr_str_immediate_offset", "arm_ldr_str_register_offset",
  "arm_ldrh_strh", "arm_ldrsb_ldrsh", "arm_mcr_mrc", "arm_mrs", "arm_msr_imm",
  "arm_msr_reg", "arm_mul_mla", "arm_mull_mlal", "arm_stc_ldc", "arm_swi",
  "arm_swp", "thumb_add_cmp_mov_hi", "thumb_add_sp_or_pc", "thumb_add_sub",
  "thumb_add_sub_sp", "thumb_b", "thumb_bcc", "thumb_bl_blx_prefix",
  "thumb_bl_suffix", "thumb_bx", "thumb_data_proc", "thumb_ldm_stm",
  "thumb_ldr_pc_rel", "thumb_ldr_str_imm_offset", "thumb_ldr_str_reg_offset",
  "thumb_ldr_str_sp_rel", "thumb_ldrb_strb_imm_offset",
  "thumb_ldrh_strh_imm_offset", "thumb_ldrh_strh_reg_offset",
  "thumb_ldrsb_strb_reg_offset", "thumb_ldrsh_ldrsb_reg_offset",
  "thumb_lsl_lsr_asr", "thumb_mov_cmp_add_sub", "thumb_push_pop", "thumb_swi",
  "thumb_undefined_bcc"]

let SingleStepCacheDir =
  block:
    let env = getEnv("DINGBAT_SINGLESTEP_CACHE")
    if env.len > 0: env else: getHomeDir() / ".cache" / "dingbat-singlestep"

proc ensure_sm83_vectors(): string =
  ensure_github_tree("SingleStepTests/sm83", Sm83TestsRev, "sm83",
                     SingleStepCacheDir) / "v1"

proc ensure_arm7tdmi_vectors(): string =
  result = SingleStepCacheDir / "arm7tdmi-" & Arm7tdmiTestsRev[0 ..< 7] & "-" &
           $(Arm7tdmiPrefixBytes div (1024 * 1024)) & "m"
  createDir(result)
  var announced = false
  for f in Arm7tdmiFiles:
    let path = result / f & ".json.bin"
    if fileExists(path) and getFileSize(path) == Arm7tdmiPrefixBytes: continue
    if not announced:
      echo "Downloading SingleStepTests/ARM7TDMI (first ",
           Arm7tdmiPrefixBytes div (1024 * 1024), " MB of each file)..."
      announced = true
    download_file("https://raw.githubusercontent.com/SingleStepTests/ARM7TDMI/" &
                  Arm7tdmiTestsRev & "/v1/" & f & ".json.bin", path & ".part",
                  Arm7tdmiPrefixBytes)
    moveFile(path & ".part", path)

type
  SstRow = object
    name: string
    cases, pass, state, bus, access: int
    known: seq[(int, string)]

proc sst_group(suite, stem: string): string =
  ## The results.md row a vector file belongs to: one per ARM7TDMI file; the
  ## SM83's 500 files fold into one row per unprefixed high nibble and four
  ## for the CB page.
  if suite == "arm7tdmi": return "arm7tdmi/" & stem
  if stem.startsWith("cb_"):
    let op = parseHexInt(stem[3 .. ^1])
    return "sm83/" & (case op shr 6
      of 0: "CB 00-3F (rotate, shift, SWAP)"
      of 1: "CB 40-7F (BIT)"
      of 2: "CB 80-BF (RES)"
      else: "CB C0-FF (SET)")
  "sm83/" & stem[0].toUpperAscii & "0-" & stem[0].toUpperAscii & "F"

proc run_singlestep_suite(suite, title, vector_dir: string;
                          previous: Table[string, bool];
                          previous_counts: Table[string, int];
                          regressions: var seq[string];
                          detail: var seq[(string, seq[SstRow])]): SuiteResults =
  echo &"\n=== {title} ==="
  let exe = getCurrentDir() / (when defined(windows): "singlestep_test.exe"
                               else: "singlestep_test")
  if not fileExists(exe):
    echo "Error: singlestep_test not found. Run 'nimble test_build' first."
    quit(1)
  let (output, code) = execCmdEx(&"{exe.quoteShell} {suite} {vector_dir.quoteShell}")
  if code != 0:
    echo &"singlestep_test {suite} exited {code}:\n", output
    quit(1)
  var rows: seq[SstRow]
  var index = initTable[string, int]()
  for line in output.splitLines():
    let w = line.splitWhitespace()
    if w.len >= 8 and w[0] == "SST":
      let g = sst_group(suite, w[2])
      if g notin index:
        index[g] = rows.len
        rows.add SstRow(name: g)
      let r = addr rows[index[g]]
      r.cases += parseInt(w[3]); r.pass += parseInt(w[4])
      r.state += parseInt(w[5]); r.bus += parseInt(w[6]); r.access += parseInt(w[7])
    elif w.len >= 5 and w[0] == "KNOWN":
      let g = sst_group(suite, w[2])
      let n = parseInt(w[3])
      let why = w[4 .. ^1].join(" ")
      let r = addr rows[index[g]]
      var merged = false
      for k in r.known.mitems:
        if k[1] == why:
          k[0] += n
          merged = true
      if not merged: r.known.add((n, why))
  if rows.len == 0:
    echo "singlestep_test reported nothing:\n", output
    quit(1)
  var results: seq[TestResult]
  for r in rows:
    var known = 0
    for k in r.known: known += k[0]
    # Green when every failure is a known divergence; the pass count is
    # gated as well (load_singlestep_counts), so a case moving into a
    # known bucket still counts as a regression.
    let ok = r.pass + known == r.cases
    let unexplained = r.cases - r.pass - known
    # "<pass>/<cases> passed" stands alone: load_previous_counts reads the
    # word before a bare "passed".
    var txt = &"{r.pass}/{r.cases} passed"
    var notes: seq[string]
    if known > 0: notes.add &"{known} known divergence" & (if known == 1: "" else: "s")
    if unexplained > 0: notes.add &"{unexplained} unexplained"
    if notes.len > 0: txt.add " (" & notes.join(", ") & ")"
    echo &"  [{(if ok: \"PASS\" else: \"FAIL\")}] {r.name} - {txt}"
    results.add TestResult(name: r.name, passed: ok, output: txt, always_detail: true)
    if was_passing(previous, title, r.name) and not ok:
      regressions.add(r.name)
    elif previous_counts.hasKey(r.name) and r.pass < previous_counts[r.name]:
      regressions.add(&"{r.name} ({previous_counts[r.name]} -> {r.pass} passing)")
  detail.add((title, rows))
  SuiteResults(suite_name: title, results: results)

proc generate_singlestep_detail_md(detail: seq[(string, seq[SstRow])]): string =
  var lines: seq[string]
  lines.add("# SingleStepTests - Detailed Results")
  lines.add("")
  lines.add(&"SingleStepTests/sm83 at `{Sm83TestsRev[0 ..< 7]}` (every case) and " &
    &"SingleStepTests/ARM7TDMI at `{Arm7tdmiTestsRev[0 ..< 7]}` (the first " &
    &"{Arm7tdmiPrefixBytes div (1024 * 1024)} MB of each file), run by " &
    "`singlestep_test` on the CPU cores. A case passes when the final " &
    "registers and memory and the bus sequence all agree; ARM7TDMI also " &
    "scores each access's N/S type. Known divergences are failures where " &
    "dingbat follows the console or the documentation, or the encoding is " &
    "UNPREDICTABLE; tests/README.md, \"SingleStepTests\", gives the evidence " &
    "for each.")
  lines.add("")
  for (title, rows) in detail:
    lines.add("## " & title)
    lines.add("")
    lines.add("| Row | Cases | Pass | State | Bus | Access | Known divergences |")
    lines.add("|-----|-------|------|-------|-----|--------|-------------------|")
    for r in rows:
      var ks: seq[string]
      for k in r.known: ks.add &"{k[0]} {k[1]}"
      lines.add(&"| {r.name} | {r.cases} | {r.pass} | {r.state} | {r.bus} | " &
                &"{r.access} | {ks.join(\"; \")} |")
    lines.add("")
  lines.join("\n")

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
  # The Misc "H-blank bit start" rows time compiler output, so the fork pins
  # `devkitpro/devkitarm:20260221` — the image that was `latest` when those
  # constants were re-measured. Built by any other gcc they disagree with
  # their own expected values (docs/mgba-suite-verdicts.md).
  const MgbaSuiteSha1 = "35d330ee6b6ab0004c473d0f62c2c91b2f34f60a"
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
# sinamas' gambatte suite from the game-boy-test-roms bundle; filename rules
# and scoring in tests/README.md. `_outaudio0/1` rows are scored by a 2 MHz
# probe on the mixer (gambatte's own rule; see gambatte_run in
# dingbat_test.nim). Not scored: the AGB column. Reported per subdirectory;
# detail in tests/results_gambatte.md.

type
  GambatteRow = object
    dev: string        # "dmg" | "cgb"
    kind: string       # "hex" | "png" | "audio"
    expected: string   # hex string, the reference PNG's path, or "0"/"1"
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

proc gambatte_row_reads_powerup_objpal(stem: string): bool =
  ## gambatte `scx_during_m3` rows whose CGB picture shows a colour the ROM
  ## never writes: the object at OAM X = 2 puts its column 6 (colour 2) at
  ## x = 0, and no OCPS/OCPD store exists, so the pixel is OBJ palette 0
  ## colour 2's power-on SRAM word. Pan Docs ("Palettes"): in CGB mode the
  ## boot ROM leaves object colours uninitialised apart from byte 0. The DMG
  ## halves (through OBP0) and `spx0`/`spx1` (no visible object pixel) are
  ## scored.
  stem in ["scx_during_m3_spx2", "scx_during_m3_spx2_ds",
           "scx_attrib_during_m3_spx2_ds"]

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
        # Audio verdict: the final frame's mix is constant (0) or not (1);
        # scored by the mixer probe in --mode=gambatte (gambatte_run).
        rows.add(GambatteRow(
          dev: dev, kind: "audio", expected: $tail[5], rom: rom, group: group,
          name: rel.changeFileExt("") & " [" & dev & ", audio]",
        ))
        continue
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
      if dev == "cgb" and gambatte_row_reads_powerup_objpal(stem):
        continue  # pixel 0 is uninitialised OBJ palette RAM; in NotScored
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

# ==================== DocBoy ====================
# Docheinstein/docboy's own test ROMs (MIT; sources in
# Docheinstein/docboy-test-suite), scored the way its runner scores them:
# tests/config/{dmg,cgb,cgb_dmg_mode,cgb_dmg_ext_mode}.json name each ROM's
# verdict, `--mode=docboy` (docboy_batch in dingbat_test.nim) reproduces
# tests/testutils/testutils/runners.h. One results.md row per manifest
# section; every row in tests/results_docboy.md. Only the ROMs under
# `docboy/` are DocBoy's own; the manifests also vendor other suites, which
# are scored from upstream (NotScored lists every skip).

const DocboyRev = "01e04d3d9fcb4ea28d05f468771127b2f6bd3549"
const DocboySuiteName = "Game Boy - DocBoy"
const DocboyManifests = ["dmg", "cgb", "cgb_dmg_mode", "cgb_dmg_ext_mode"]

proc docboy_keep(rel: string): bool =
  ## The part of the repository the suite needs: the four manifests, the
  ## reference PNGs and DocBoy's own ROMs. The rest of tests/roms is other
  ## suites (and most of the 412 MB the archive extracts to).
  if not rel.startsWith("tests/"): return false
  let parts = rel.split('/')
  if parts.len == 3 and parts[1] == "config": return rel.endsWith(".json")
  if parts.len >= 3 and parts[1] == "results": return true
  parts.len >= 4 and parts[1] == "roms" and parts[3] == "docboy"

proc ensure_docboy_tests(): string =
  ## DocBoy's tests/ tree at DocboyRev (a 19 MB GitHub archive), extracted
  ## selectively: ~355 MB of it, ~10,000 32 KB ROMs.
  let dir = RomCacheDir / "docboy-" & DocboyRev[0 ..< 7]
  let tests = dir / "tests"
  if tree_intact(dir): return tests
  if dirExists(dir): removeDir(dir)
  echo "Downloading Docheinstein/docboy..."
  createDir(RomCacheDir)
  let pid = $getCurrentProcessId()
  let zipfile = RomCacheDir / "docboy-" & pid & ".zip"
  let staging = RomCacheDir / "docboy-" & pid
  download_file(&"https://github.com/Docheinstein/docboy/archive/{DocboyRev}.zip", zipfile)
  let prefix = "docboy-" & DocboyRev & "/"
  try:
    let reader = openZipArchive(zipfile)
    try:
      for path in reader.walkFiles:
        if not path.startsWith(prefix): continue
        let rel = path[prefix.len .. ^1]
        if not docboy_keep(rel): continue
        let dest = staging / rel
        createDir(dest.parentDir)
        writeFile(dest, reader.extractFile(path))
    finally:
      reader.close()
  except ZippyError, IOError, OSError:
    echo "Failed to extract: ", getCurrentExceptionMsg()
    if dirExists(staging): removeDir(staging)
    removeFile(zipfile)
    quit(1)
  removeFile(zipfile)
  stamp_tree(staging)
  try:
    moveDir(staging, dir)
  except OSError:
    removeDir(staging)  # another runner put its copy in place first
  tests

type
  DocboyRow = object
    dev: string        # "dmg" | "cgb" (CPU CGB E; the header picks the mode)
    kind: string       # "mem" | "fb" | "fb2"
    instr: int         # check_at_instruction opcode, -1 = periodic checks
    expected: string   # see docboy_batch
    rom, rom2: string
    input: string      # --input spec from the manifest's `inputs`, or "-"
    group: string      # "docboy/<manifest>/<section>"
    name: string

  DocboyGroup = object
    name: string
    device: string
    passes: int
    total: int
    failures: seq[(string, string)]

  DocboySkips = object
    disabled, vendored, not_scored: int

const DocboyNotScored: seq[string] = @[
  # Row-name globs (`*` = any run of characters) of DocBoy rows whose
  # expectation is not established hardware behaviour. Each family is one
  # "DocBoy: ..." entry in NotScored, which gives the evidence.
  # The KEY1 switch's IME-set leaf (8).
  "cgb/docboy/double_speed/interactive/*stop_key1_joypad0_interrupt1_ime1_*_div_round1",
  # A joypad interrupt on key release (3).
  "dmg/docboy/joypad/interactive/joypad_*_interrupt_release",
  "dmg/docboy/cpu/interactive_visual/stop_immediate_exit_joypad_interrupt",
  # $FEA0-$FEFF as RAM on a CPU CGB E (29).
  "cgb/docboy/hdma/gdma_source_wram_dma_source_ram_160_bytes",
  "cgb/docboy/hdma/gdma_source_wram_dma_source_ram_256_bytes",
  "cgb/docboy/hdma/gdma_source_wram_dma_source_ram_480_bytes_overflow",
  "cgb/docboy/memory/not_usable_area_write*",
  "cgb/docboy/memory/not_usable_read_hblank",
  "cgb/docboy/memory/not_usable_read_ppu_off",
  "cgb/docboy/memory/not_usable_read_vblank",
  "cgb/docboy/memory/not_usable_write_*",
  "cgb_dmg_mode/docboy/memory/not_usable_area_write*",
  "cgb_dmg_mode/docboy/memory/not_usable_read_hblank",
  "cgb_dmg_mode/docboy/memory/not_usable_read_ppu_off",
  "cgb_dmg_mode/docboy/memory/not_usable_read_vblank",
  "cgb_dmg_mode/docboy/memory/not_usable_write_*",
  # $FFFE after the boot ROM (4).
  "*/docboy/boot/boot_hram*",   # the dmg manifest lists it twice (`#2`)
  # MBC3 RTC latch on a $00-then-$01 pair only (3).
  "dmg/docboy/mbc/mbc3/mbc3_rtc_latch_0_to_2",
  "dmg/docboy/mbc/mbc3/mbc3_rtc_latch_1_to_0",
  "dmg/docboy/mbc/mbc3/mbc3_rtc_latch_1_to_1",
  # The window's first tile when LCDC.5 clears mid-fetch (43 of the
  # 107 `window_turn_off_*` rows; the other 64 pass and stay scored).
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x3",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x4",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x5",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x6",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x7",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops23_sprite_x0",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops23_sprite_x1",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops23_sprite_x2",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops23_sprite_x3",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x2",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x3",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x4",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x5",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x6",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x7",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops25_sprite_x0",
  "dmg/docboy/ppu/visual/window_turn_off_alt_nops25_sprite_x1",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x3_variation_a",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x3_variation_b",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x4",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x4_variation_a",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x4_variation_b",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x5",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x5_variation_a",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x5_variation_b",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x6",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x6_variation_a",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x6_variation_b",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x7",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x7_variation_a",
  "dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x7_variation_b",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x0",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x0_variation_a",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x0_variation_b",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x1",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x1_variation_a",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x1_variation_b",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x2",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x2_variation_a",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x2_variation_b",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x3",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x3_variation_a",
  "dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x3_variation_b",
  # Single-unit OAM-bug margins (10).
  "dmg/docboy/oam_bug/oam_bug_ld_hl_a_round3_fe5c",
  "dmg/docboy/oam_bug/oam_bug_ld_hl_a_round3_fe5e_noisy",
  "dmg/docboy/oam_bug/oam_bug_ld_hl_a_round3_fe5f",
  "dmg/docboy/oam_bug/oam_bug_ld_hli_a_round3_fe5c",
  "dmg/docboy/oam_bug/oam_bug_ld_hli_a_round3_fe5e_noisy",
  "dmg/docboy/oam_bug/oam_bug_ld_hli_a_round3_fe5f",
  "dmg/docboy/oam_bug/oam_bug_ld_hl_a_round23_fe46",
  "dmg/docboy/oam_bug/oam_bug_ld_hl_a_round23_fe47",
  "dmg/docboy/oam_bug/oam_bug_ld_hli_a_round23_fe46",
  "dmg/docboy/oam_bug/oam_bug_ld_hli_a_round23_fe47",
  # A CGB trigger 2 M-cycles before a sweep clock (2).
  "cgb/docboy/apu/ch1/ch1_period_sweep_change_period_nr14_during_recalc_delay14284",
  "cgb/docboy/apu/ch1/ch1_period_sweep_change_period_nr14_during_recalc_step0_delay14284_round1",
  # Compat-mode window frames under mid-line LCDC.5 pulses (51).
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_0000_win_0000",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_0000_win_00ff",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_0000_win_ff00",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_0000_win_ffff",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_0000",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_00ff",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_afff",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ff00",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x16",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x16_sources",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x17",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x17_sources",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x17_sources_b",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x17_sources_c",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x18",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x18_sources",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x19",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x19_sources",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x19_sources_b",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x19_wly",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x20",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x20_sources",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21_sources",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21_sources_b",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21_sources_c",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21_sources_d",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x22",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x22_sources",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x23",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x23_sources",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x24",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_win_tilenum_02",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ff00_win_0000",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ff00_win_00ff",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ff00_win_ff00",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ff00_win_ffff",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ffff_win_0000",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ffff_win_00ff",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ffff_win_ff00",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ffff_win_ffff",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly10_second_tile_source_both_bytes",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly10_second_tile_source",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly32_to_40_tilenums",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_a",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_b",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_c",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_d",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_e",
  "cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_f",
  # The CGB LCDC.4 tile-data glitch, DocBoy's variations (73).
  "cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops26",
  "cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops27",
  "cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops28",
  "cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29",
  "cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops30",
  "cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops26",
  "cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops27",
  "cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops28",
  "cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops29",
  "cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops30",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_shift8_delay0_alt_sprite_data_var4",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var8",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var9",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var10",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var11",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var12",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var13",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var14",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var15",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var16",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var17",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var18",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var19",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var20",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var21",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var24",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var40",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var41",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var42",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43_alt",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43_alt2",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43_alt3",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43_alt4",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var44",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var44_alt",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops26",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops27",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops28",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_a",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_b",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_c",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_d",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var1",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var2",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var3",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops28",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops29",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops30",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops31",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops32",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops85",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops98",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops99",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops100",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops101",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops102",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var5_nops30",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var5_nops30_alt",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var6_nops30",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var10",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops30",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops34",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops35",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops36",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops37",
  "cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops38",
  "cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops26",
  "cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops27",
  "cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops28",
  "cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops29",
  "cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops30",
  # The CGB background column resumed after the window at WX = 25 (1).
  "cgb/docboy/ppu/visual/window_bg_reprise_wx25",
  # The CGB panel across LCD off/on (13).
  "cgb/docboy/ppu/visual/turn_off_y42_turn_on_y148_round1",
  "cgb/docboy/ppu/visual/turn_off_y42_turn_on_y148_round1 #2",
  "cgb/docboy/ppu/visual/turn_off_y42_turn_on_y148_round2",
  "cgb/docboy/ppu/visual/turn_off_y42_turn_on_y52_wait144",
  "cgb/docboy/ppu/visual/turn_off_y42_turn_on_y52_wait150",
  "cgb/docboy/ppu/visual/turn_off_y50_skip_y16_stall_nops50",
  "cgb/docboy/ppu/visual/turn_off_y50_skip_y16_stall_nops51",
  "cgb/docboy/ppu/visual/turn_off_y50_skip_y16_stall_nops99",
  "cgb/docboy/ppu/visual/turn_off_y50_skip_y16_stall_nops100",
  "cgb/docboy/ppu/visual/turn_off_y48_skip_y16_stall_nops50",
  "cgb/docboy/ppu/visual/turn_off_y48_skip_y16_stall_nops51",
  "cgb/docboy/ppu/visual/turn_off_y50_stall_nops50",
  "cgb/docboy/ppu/visual/turn_off_y50_stall_nops51",
  # Fresh cart RAM reading $FF (1).
  "dmg/docboy/mbc/mbc1/mbc1_initial_ram",
  # A serial slave shifting with SC = $00 (1).
  "dmg/docboy/serial/serial_two_players_basic_transfer_master + serial_two_players_basic_transfer_slave_sc_00",
  # A VRAM DMA beside an object at X = 7 (1).
  "cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x07",
]

proc docboy_glob(pat, s: string): bool =
  ## `*` matches any run of characters, everything else itself.
  var p, i = 0
  var star, mark = -1
  while i < s.len:
    if p < pat.len and pat[p] != '*' and pat[p] == s[i]:
      inc p; inc i
    elif p < pat.len and pat[p] == '*':
      star = p; mark = i; inc p
    elif star >= 0:
      p = star + 1; inc mark; i = mark
    else: return false
  while p < pat.len and pat[p] == '*': inc p
  p == pat.len

proc docboy_not_scored(name: string): bool =
  for pat in DocboyNotScored:
    if docboy_glob(pat, name): return true

proc docboy_opcode(n: JsonNode): int =
  ## runtests.cpp parse_instruction: an opcode number or a mnemonic. DocBoy's
  ## own rows use `ld b,b` and `ld c,c`; any `ld r,r'` is $40 + 8r + r'
  ## (r in b c d e h l (hl) a).
  if n.kind == JInt: return n.getInt
  const regs = ["b", "c", "d", "e", "h", "l", "(hl)", "a"]
  let m = n.getStr.toLowerAscii.replace(" ", "")
  if m.startsWith("ld") and ',' in m:
    let halves = m[2 .. ^1].split(',')
    let d = regs.find(halves[0])
    let r = regs.find(halves[1])
    if d >= 0 and r >= 0 and not (d == 6 and r == 6):
      return 0x40 + 8 * d + r
  raise newException(ValueError, "unknown instruction " & n.getStr)

proc docboy_input_spec(inputs: JsonNode): string =
  ## A manifest `inputs` list as dingbat_test's --input syntax (README, "Timed
  ## joypad input"), one item per entry in list order: trigger_at_tick N ->
  ## `N`, trigger_at_instruction -> `@HH`.
  var items: seq[string]
  for e in inputs:
    let at = if e.hasKey("trigger_at_tick"): $e["trigger_at_tick"].getBiggestInt
             else: "@" & toHex(docboy_opcode(e["trigger_at_instruction"]), 2)
    items.add(at & ":" & e["key"].getStr & ":" & e["state"].getStr)
  items.join(",")

proc build_docboy_rows(tests: string; skips: var DocboySkips): seq[DocboyRow] =
  var seen = initCountTable[string]()
  for manifest in DocboyManifests:
    let doc = parseFile(tests / "config" / manifest & ".json")
    let dev = if manifest == "dmg": "dmg" else: "cgb"
    let roms = tests / "roms" / manifest
    let refs = tests / "results" / manifest
    for section, entries in doc.pairs:
      for t in entries:
        let rom = t["rom"].getStr
        if not rom.startsWith("docboy/"):
          inc skips.vendored
          continue
        if t.hasKey("enabled") and not t["enabled"].getBool:
          inc skips.disabled
          continue
        var row = DocboyRow(dev: dev, instr: -1, rom: roms / rom, rom2: "-",
                            input: "-",
                            group: "docboy/" & manifest & "/" & section)
        if t.hasKey("inputs"):
          row.input = docboy_input_spec(t["inputs"])
        if t.hasKey("check_at_instruction"):
          row.instr = docboy_opcode(t["check_at_instruction"])
        if t.hasKey("framebuffer"):
          if t.hasKey("rom2"):
            row.kind = "fb2"
            row.rom2 = roms / t["rom2"].getStr
            row.expected = refs / t["framebuffer"].getStr & "|" &
                           refs / t["framebuffer2"].getStr
          else:
            row.kind = "fb"
            row.expected = refs / t["framebuffer"].getStr
        elif t.hasKey("memory"):
          row.kind = "mem"
          var parts: seq[string]
          for m in t["memory"]:
            let fail = if m.hasKey("fail_value"): m["fail_value"].getInt else: -1
            parts.add(&"{m[\"address\"].getInt}:{m[\"value\"].getInt}:{fail}")
          row.expected = parts.join(",")
        else:
          # DocBoy's own rows are memory or framebuffer; anything else would
          # be a manifest this runner does not understand yet.
          echo &"  Warning: DocBoy row {manifest}/{rom} has no verdict this runner knows"
          continue
        var name = manifest & "/" & rom.changeFileExt("")
        if row.kind == "fb2": name.add(" + " & t["rom2"].getStr.extractFilename.changeFileExt(""))
        seen.inc(name)
        if seen[name] > 1: name.add(" #" & $seen[name])
        if docboy_not_scored(name):
          inc skips.not_scored
          continue
        row.name = name
        result.add(row)

proc run_docboy_suite(harness: string; previous: Table[string, bool];
                      previous_counts: Table[string, int];
                      regressions: var seq[string];
                      groups: var seq[DocboyGroup]): SuiteResults =
  echo &"\n=== {DocboySuiteName} ==="
  var skips: DocboySkips
  let rows = build_docboy_rows(ensure_docboy_tests(), skips)
  echo &"  {rows.len} rows; not scored: {skips.disabled} disabled upstream, " &
       &"{skips.vendored} vendored from other suites, " &
       &"{skips.not_scored} DocboyNotScored"
  var list_lines: seq[string]
  for r in rows:
    list_lines.add([r.dev, r.kind, $r.instr, r.expected, r.rom, r.rom2,
                    r.input].join("\t"))
  let verdicts = run_sharded_batch(harness, "docboy", "dingbat-docboy", "DOC", list_lines)
  var order: seq[string]
  var by_group = initTable[string, DocboyGroup]()
  for i, row in rows:
    if row.group notin by_group:
      order.add(row.group)
      by_group[row.group] = DocboyGroup(name: row.group,
        device: if row.dev == "dmg": "DMG dmgABC" else: "CGB cgbE")
    let (passed, detail) = split_verdict(verdicts[i])
    by_group.withValue(row.group, g):
      inc g.total
      if passed: inc g.passes
      else: g.failures.add((row.name, detail))
  var results: seq[TestResult]
  var total_pass, total_all = 0
  for name in order:
    let g = by_group[name]
    groups.add(g)
    total_pass += g.passes
    total_all += g.total
    let all_pass = g.passes == g.total
    echo &"  [{(if all_pass: \"PASS\" else: \"FAIL\")}] {name} - {g.passes}/{g.total} passed"
    results.add(TestResult(name: name, passed: all_pass,
                           output: &"{g.passes}/{g.total} passed",
                           always_detail: true, device: g.device))
    # Gated as gambatte's groups are: all-green going red, or the count dropping.
    if was_passing(previous, DocboySuiteName, name) and not all_pass:
      regressions.add(name)
    elif previous_counts.hasKey(name) and g.passes < previous_counts[name]:
      regressions.add(&"{name} ({previous_counts[name]} -> {g.passes} passing)")
  echo &"  DocBoy total: {total_pass}/{total_all} passed"
  SuiteResults(suite_name: DocboySuiteName, results: results)

proc generate_docboy_detail_md(groups: seq[DocboyGroup]): string =
  var lines: seq[string]
  lines.add("# DocBoy Test Suite - Detailed Results")
  lines.add("")
  lines.add("*Generated: " & now().format("yyyy-MM-dd HH:mm:ss") &
            " \xC2\xB7 Docheinstein/docboy " & DocboyRev[0 ..< 8] & "*")
  lines.add("")
  lines.add("DocBoy's own ROMs (`docboy/` in its tests/config manifests), each")
  lines.add("scored by the verdict its manifest names, the way DocBoy's runner")
  lines.add("checks it: `$FFF0` = 1 pass / 2 fail, polled every 100,000 4 MHz")
  lines.add("ticks, or an exact RGB565 match with the reference PNG at the next")
  lines.add("VBlank (or at `ld b,b` / `ld c,c` when the row names one). DMG rows")
  lines.add("run on a DMG ABC, the three CGB manifests on a CPU CGB E with the")
  lines.add("cart header picking the mode. See tests/README.md for the mechanism")
  lines.add("and docs/gb-failure-triage.md for the failing families.")
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
      lines.add(&"All {g.total} tests passed ({g.device}).")
      lines.add("")
    else:
      lines.add(&"{g.passes}/{g.total} tests passed on {g.device}, {g.failures.len} failed:")
      lines.add("")
      lines.add("| Test | Result |")
      lines.add("|------|--------|")
      for (name, det) in g.failures:
        lines.add("| " & name & " | " & det.replace("|", "/") & " |")
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
  var gba_only = false
  var sst_only = false
  var docboy_only = false
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
        screenshot_bios = v
      of "apu":
        apu_only = true
      of "suite":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        if v == "apu": apu_only = true
        elif v == "gba": gba_only = true
        elif v == "singlestep": sst_only = true
        elif v == "docboy": docboy_only = true
        else:
          echo "Unknown suite: ", v, " (only 'apu', 'gba', 'singlestep' or 'docboy' can be selected)"
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

  # --suite=singlestep: run ONLY the SingleStepTests CPU vectors (both
  # cores) and print tallies without touching any results file.
  if sst_only:
    let no_previous = initTable[string, bool]()
    var sst_regressions: seq[string]
    var sst_detail: seq[(string, seq[SstRow])]
    var sst_suites: seq[SuiteResults]
    sst_suites.add(run_singlestep_suite("sm83", "Game Boy - SingleStepTests SM83",
      ensure_sm83_vectors(), no_previous, initTable[string, int](),
      sst_regressions, sst_detail))
    sst_suites.add(run_singlestep_suite("arm7tdmi", "GBA - SingleStepTests ARM7TDMI",
      ensure_arm7tdmi_vectors(), no_previous, initTable[string, int](),
      sst_regressions, sst_detail))
    echo ""
    for suite in sst_suites:
      echo &"{suite.suite_name}: {suite.results.countIt(it.passed)}/{suite.results.len} pass"
    quit(0)

  # --suite=docboy: run ONLY the DocBoy suite and print its tallies without
  # touching any results file.
  if docboy_only:
    var docboy_regressions: seq[string]
    var docboy_groups: seq[DocboyGroup]
    let r = run_docboy_suite(harness, initTable[string, bool](),
                             initTable[string, int](), docboy_regressions,
                             docboy_groups)
    var p, t = 0
    for g in docboy_groups:
      p += g.passes
      t += g.total
    echo &"\n{r.suite_name}: {p}/{t} pass ({r.results.countIt(it.passed)}/{r.results.len} sections green)"
    quit(0)

  # --suite=gba: run ONLY the GBA suites and print tallies without touching
  # any results file.
  if gba_only:
    let no_previous = initTable[string, bool]()
    var gba_regressions: seq[string]
    var gba_suites: seq[SuiteResults]
    var mgba_detail: seq[MgbaSuiteDetail]
    gba_suites.add(run_mgba_suite(harness, no_previous, gba_regressions,
                                  mgba_detail, bios_path))
    gba_suites.add(run_suite("GBA - jsmolka gba-tests",
      build_jsmolka_tests(ensure_jsmolka_test_roms()), harness, no_previous,
      gba_regressions))
    gba_suites.add(run_suite("GBA - FuzzARM",
      build_fuzzarm_tests(ensure_fuzzarm_test_roms()), harness, no_previous,
      gba_regressions))
    gba_suites.add(run_suite("GBA - alyosha gba-tests", build_alyosha_tests(
      ensure_github_tree("alyosha-tas/gba-tests", AlyoshaRev, "alyosha-gba-tests"),
      ensure_github_tree("png183/gba-tests", Png183Rev, "png183-gba-tests"),
      ensure_jsmolka_test_roms()), harness, no_previous, gba_regressions))
    gba_suites.add(run_suite("GBA - PeterLemon BIOS", build_peterlemon_bios_tests(),
                             harness, no_previous, gba_regressions))
    gba_suites.add(run_suite("GBA - Other test ROMs", build_gba_misc_tests(),
                             harness, no_previous, gba_regressions))
    gba_suites.add(run_suite("GBA - hwverified (AGS-001)", build_hwverified_tests(),
                             harness, no_previous, gba_regressions))
    var dbsuite_groups: seq[DbsuiteGroup]
    gba_suites.add(run_dbsuite(harness, no_previous, initTable[string, int](),
                               gba_regressions, dbsuite_groups, bios_path))
    var sst_detail: seq[(string, seq[SstRow])]
    gba_suites.add(run_singlestep_suite("arm7tdmi", "GBA - SingleStepTests ARM7TDMI",
      ensure_arm7tdmi_vectors(), no_previous, initTable[string, int](),
      gba_regressions, sst_detail))
    echo ""
    for suite in gba_suites:
      echo &"{suite.suite_name}: {suite.results.countIt(it.passed)}/{suite.results.len} pass"
    quit(0)

  let results_path = getCurrentDir() / "tests" / "results.md"
  let previous = load_previous_results(results_path)
  var previous_counts = load_previous_counts(results_path)
  load_singlestep_counts(getCurrentDir() / "tests" / "results_singlestep.md",
                         previous_counts)

  var all_suites: seq[SuiteResults]
  var regressions: seq[string]

  let gb_test_roms_dir = ensure_gameboy_test_roms()

  let blargg_tests = build_blargg_tests(gb_test_roms_dir / "blargg")
  all_suites.add(run_suite("Game Boy - Blargg", blargg_tests, harness, previous, regressions))

  all_suites.add(run_suite("Game Boy - Blargg dmg_sound",
    build_blargg_sound_tests(gb_test_roms_dir / "blargg" / "dmg_sound", "dmg_sound", cgb = false),
    harness, previous, regressions))
  all_suites.add(run_suite("Game Boy - Blargg cgb_sound",
    build_blargg_sound_tests(gb_test_roms_dir / "blargg" / "cgb_sound", "cgb_sound", cgb = true),
    harness, previous, regressions))

  let mooneye_tests = build_mooneye_tests(gb_test_roms_dir)
  all_suites.add(run_suite("Game Boy - Mooneye", mooneye_tests, harness, previous, regressions))

  var mgba_detail: seq[MgbaSuiteDetail]
  let mgba_results = run_mgba_suite(harness, previous, regressions, mgba_detail, bios_path)
  all_suites.add(mgba_results)

  let jsmolka_tests = build_jsmolka_tests(ensure_jsmolka_test_roms())
  all_suites.add(run_suite("GBA - jsmolka gba-tests", jsmolka_tests, harness,
                           previous, regressions))

  let alyosha_tests = build_alyosha_tests(
    ensure_github_tree("alyosha-tas/gba-tests", AlyoshaRev, "alyosha-gba-tests"),
    ensure_github_tree("png183/gba-tests", Png183Rev, "png183-gba-tests"),
    ensure_jsmolka_test_roms())
  all_suites.add(run_suite("GBA - alyosha gba-tests", alyosha_tests, harness,
                           previous, regressions))

  all_suites.add(run_suite("GBA - PeterLemon BIOS", build_peterlemon_bios_tests(),
                           harness, previous, regressions))

  all_suites.add(run_suite("GBA - Other test ROMs", build_gba_misc_tests(),
                           harness, previous, regressions))

  all_suites.add(run_suite("GBA - hwverified (AGS-001)", build_hwverified_tests(),
                           harness, previous, regressions))

  var dbsuite_groups: seq[DbsuiteGroup]
  all_suites.add(run_dbsuite(harness, previous, previous_counts, regressions,
                             dbsuite_groups, bios_path))

  let fuzzarm_tests = build_fuzzarm_tests(ensure_fuzzarm_test_roms())
  all_suites.add(run_suite("GBA - FuzzARM", fuzzarm_tests, harness,
                           previous, regressions))

  let acid2_tests = build_acid2_tests()
  all_suites.add(run_suite("Game Boy - Acid2", acid2_tests, harness, previous, regressions))

  all_suites.add(run_suite("Game Boy - MagenTests", build_magen_tests(), harness,
                           previous, regressions))

  let mealybug_tests = build_mealybug_tests(gb_test_roms_dir / "mealybug-tearoom-tests")
  all_suites.add(run_suite("Game Boy - Mealybug Tearoom", mealybug_tests, harness, previous, regressions))

  all_suites.add(run_suite("Game Boy - MBC", build_mbc_tests(), harness,
                           previous, regressions))

  all_suites.add(run_microtest_suite("Game Boy - GBMicrotest",
    build_gbmicrotest_tests(gb_test_roms_dir / "gbmicrotest"),
    harness, previous, regressions))

  all_suites.add(run_suite("Game Boy - AGE",
    build_age_tests(gb_test_roms_dir / "age-test-roms"),
    harness, previous, regressions))

  all_suites.add(run_suite("Game Boy - Screenshot suites",
    build_small_screenshot_tests(gb_test_roms_dir), harness, previous, regressions))

  all_suites.add(run_suite("Game Boy - SameSuite",
    build_samesuite_core_tests(gb_test_roms_dir / "same-suite"),
    harness, previous, regressions))

  all_suites.add(run_suite("Game Boy - SameSuite APU",
    build_samesuite_apu_tests(gb_test_roms_dir / "same-suite"),
    harness, previous, regressions))

  all_suites.add(run_suite("Game Boy - Shootout ROMs",
    build_shootout_tests(), harness, previous, regressions))

  all_suites.add(run_suite("Game Boy - Mooneye (wilbertpol)",
    build_wilbertpol_tests(gb_test_roms_dir), harness, previous, regressions))

  var gambatte_groups: seq[GambatteGroup]
  all_suites.add(run_gambatte_suite(harness, previous, previous_counts,
                                    regressions, gambatte_groups,
                                    gb_test_roms_dir))

  var docboy_groups: seq[DocboyGroup]
  all_suites.add(run_docboy_suite(harness, previous, previous_counts,
                                  regressions, docboy_groups))

  var sst_detail: seq[(string, seq[SstRow])]
  all_suites.add(run_singlestep_suite("sm83", "Game Boy - SingleStepTests SM83",
    ensure_sm83_vectors(), previous, previous_counts, regressions, sst_detail))
  all_suites.add(run_singlestep_suite("arm7tdmi", "GBA - SingleStepTests ARM7TDMI",
    ensure_arm7tdmi_vectors(), previous, previous_counts, regressions, sst_detail))

  createDir(getCurrentDir() / "tests")
  writeFile(results_path, generate_results_md(all_suites))
  let mgba_detail_path = getCurrentDir() / "tests" / "results_mgba_suite.md"
  writeFile(mgba_detail_path, generate_mgba_detail_md(mgba_detail))
  let dbsuite_detail_path = getCurrentDir() / "tests" / "results_dbsuite.md"
  writeFile(dbsuite_detail_path, generate_dbsuite_detail_md(dbsuite_groups))
  let gambatte_detail_path = getCurrentDir() / "tests" / "results_gambatte.md"
  let sst_detail_path = getCurrentDir() / "tests" / "results_singlestep.md"
  writeFile(sst_detail_path, generate_singlestep_detail_md(sst_detail))
  if gambatte_groups.len > 0:
    writeFile(gambatte_detail_path, generate_gambatte_detail_md(gambatte_groups))
  let docboy_detail_path = getCurrentDir() / "tests" / "results_docboy.md"
  if docboy_groups.len > 0:
    writeFile(docboy_detail_path, generate_docboy_detail_md(docboy_groups))
  echo &"\nResults written to {results_path}"
  echo &"mGBA detail written to {mgba_detail_path}"
  echo &"dbsuite detail written to {dbsuite_detail_path}"
  if gambatte_groups.len > 0:
    echo &"gambatte detail written to {gambatte_detail_path}"

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
