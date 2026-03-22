import std/[os, osproc, strutils, strformat, tables, sequtils, times, algorithm]
import png_reader

const RomCacheDir = "/tmp/dingbat-test-roms"

type
  TestMode = enum
    tmSerial, tmSram, tmMooneye, tmMgba, tmMgbaSuite, tmScreenshot

  TestDef = object
    name: string
    rom_path: string
    mode: TestMode
    timeout: int
    expected_png: string  # for screenshot mode
    color: bool           # true = RGB comparison, false = greyscale

  TestResult = object
    name: string
    passed: bool
    output: string
    timed_out: bool

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


proc ensure_gameboy_test_roms(): string =
  let dir = RomCacheDir / "game-boy-test-roms"
  if dirExists(dir):
    return dir
  echo "Downloading game-boy-test-roms release..."
  createDir(dir)
  let url = "https://github.com/c-sp/game-boy-test-roms/releases/download/v7.0/game-boy-test-roms-v7.0.zip"
  let zipfile = dir / "roms.zip"
  let (dl_output, dl_code) = execCmdEx(&"curl -L -o {zipfile} {url}")
  if dl_code != 0:
    echo "Failed to download: ", dl_output
    removeDir(dir)
    quit(1)
  let (extract_output, extract_code) = execCmdEx(&"unzip -q {zipfile} -d {dir}")
  if extract_code != 0:
    echo "Failed to extract: ", extract_output
    removeDir(dir)
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

proc ensure_rom_download(url, filename: string): string =
  ## Download a single ROM file if not already cached.
  let path = RomCacheDir / filename
  if fileExists(path):
    return path
  echo &"Downloading {filename}..."
  createDir(RomCacheDir)
  let (output, code) = execCmdEx(&"curl -L -o {path.quoteShell} {url}")
  if code != 0:
    echo "Failed to download: ", output
    quit(1)
  path

proc ensure_png_download(url, filename: string): string =
  ## Download a reference PNG if not already cached.
  let path = RomCacheDir / filename
  if fileExists(path):
    return path
  createDir(RomCacheDir)
  let (output, code) = execCmdEx(&"curl -L -o {path.quoteShell} {url}")
  if code != 0:
    echo "Failed to download: ", output
    quit(1)
  path

proc run_test(test: TestDef; harness_path: string): TestResult =
  let mode_str = case test.mode
    of tmSerial: "serial"
    of tmSram: "sram"
    of tmMooneye: "mooneye"
    of tmMgba: "mgba"
    of tmMgbaSuite: "mgba-suite"
    of tmScreenshot: "screenshot"
  if test.mode == tmScreenshot:
    let tmp_ppm = getTempDir() / "dingbat_test_" & test.rom_path.splitFile().name & ".ppm"
    var cmd = &"{harness_path} {test.rom_path.quoteShell} --mode=screenshot --timeout={test.timeout} --screenshot={tmp_ppm.quoteShell}"
    if test.color:
      cmd.add(" --color")
    let (run_output, run_code) = execCmdEx(cmd, options = {poUsePath})
    if run_code != 0:
      return TestResult(name: test.name, passed: false, output: run_output.strip())
    # Read actual pixels from PPM
    let actual = if test.color: read_ppm_rgb(tmp_ppm) else: read_ppm_greyscale(tmp_ppm)
    removeFile(tmp_ppm)
    # Read expected pixels from PNG
    let expected = read_png(test.expected_png)
    # Compare
    if actual.len != expected.pixels.len:
      return TestResult(name: test.name, passed: false,
        output: &"size mismatch: {actual.len} vs {expected.pixels.len}")
    # Count differing pixels (for RGB, compare 3 bytes at a time)
    let bytes_per_pixel = if test.color: 3 else: 1
    let total_pixels = actual.len div bytes_per_pixel
    var diff_count = 0
    for px in 0 ..< total_pixels:
      let base = px * bytes_per_pixel
      var differs = false
      for c in 0 ..< bytes_per_pixel:
        if actual[base + c] != expected.pixels[base + c]:
          differs = true
          break
      if differs:
        inc diff_count
    let pct = 100.0 * float(total_pixels - diff_count) / float(total_pixels)
    let passed = diff_count == 0
    return TestResult(
      name: test.name,
      passed: passed,
      output: &"{pct:.1f}% correct ({total_pixels - diff_count}/{total_pixels} pixels match)",
    )
  else:
    let cmd = &"{harness_path} {test.rom_path.quoteShell} --mode={mode_str} --timeout={test.timeout}"
    let (output, code) = execCmdEx(cmd, options = {poUsePath})
    return TestResult(
      name: test.name,
      passed: code == 0,
      output: output.strip(),
      timed_out: output.contains("TIMEOUT"),
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
  tests

proc build_mooneye_tests(roms_dir: string): seq[TestDef] =
  var tests: seq[TestDef]
  let mooneye_dir = roms_dir / "mooneye-test-suite"
  if not dirExists(mooneye_dir):
    echo "  Warning: mooneye-test-suite directory not found in game-boy-test-roms"
    return tests
  for rom in find_roms_recursive(mooneye_dir, ".gb"):
    let rel = rom.relativePath(mooneye_dir)
    let name = "mooneye/" & rel.changeFileExt("")
    tests.add(TestDef(
      name: name,
      rom_path: rom,
      mode: tmMooneye,
      timeout: 1800,
    ))
  tests

proc build_mealybug_tests(mealybug_dir: string): seq[TestDef] =
  var tests: seq[TestDef]
  let ppu_dir = mealybug_dir / "ppu"
  if not dirExists(ppu_dir):
    echo "  Warning: mealybug ppu directory not found"
    return tests
  for rom in find_roms(ppu_dir, ".gb"):
    let test_name = rom.splitFile().name
    let expected_png = ppu_dir / test_name & "_dmg_blob.png"
    if not fileExists(expected_png):
      continue  # Skip ROMs without DMG expected images
    tests.add(TestDef(
      name: "mealybug/" & test_name,
      rom_path: rom,
      mode: tmScreenshot,
      timeout: 120,
      expected_png: expected_png,
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
  ))
  tests

proc generate_results_md(suites: seq[SuiteResults]): string =
  var lines: seq[string]
  lines.add("# Dingbat Test Results")
  lines.add("")
  lines.add("*Generated: " & now().format("yyyy-MM-dd HH:mm:ss") & "*")
  lines.add("")

  var total = 0
  var pass_count = 0
  var fail_count = 0

  for suite in suites:
    lines.add("## " & suite.suite_name)
    lines.add("")
    lines.add("| Test | Result |")
    lines.add("|------|--------|")
    for r in suite.results:
      let emoji = if r.passed: "\xF0\x9F\x91\x8C" else: "\xF0\x9F\x91\x80"
      var detail = ""
      if not r.passed:
        if r.output.contains("% correct") or r.output.contains("passed") or r.output.contains("timed out"):
          detail = " " & r.output
      let short_name = if r.name.contains("/"): r.name.split("/", maxsplit = 1)[1] else: r.name
      lines.add("| " & short_name & " | " & emoji & detail & " |")
      inc total
      if r.passed: inc pass_count else: inc fail_count
    if suite.suite_name == "GBA - mGBA Test Suite":
      lines.add("")
      lines.add("See [detailed results](results_mgba_suite.md) for individual test outcomes.")
    lines.add("")

  lines.add("## Summary")
  lines.add("")
  lines.add("- **Total:** " & $total)
  lines.add("- **Pass:** " & $pass_count)
  lines.add("- **Fail:** " & $fail_count)
  lines.add("")
  lines.join("\n")

proc load_previous_results(path: string): Table[string, bool] =
  result = initTable[string, bool]()
  if not fileExists(path):
    return
  let content = readFile(path)
  for line in content.splitLines():
    if line.startsWith("| ") and not line.startsWith("| Test") and not line.startsWith("|---"):
      let parts = line.split("|").mapIt(it.strip())
      if parts.len >= 3:
        let name = parts[1]
        let passed = parts[2].contains("\xF0\x9F\x91\x8C")
        result[name] = passed

proc run_suite(name: string; tests: seq[TestDef]; harness: string;
               previous: Table[string, bool]; regressions: var seq[string]): SuiteResults =
  echo &"\n=== {name} ==="
  var results: seq[TestResult]
  for test in tests:
    let r = run_test(test, harness)
    let status = if r.passed: "PASS" else: "FAIL"
    if test.mode == tmScreenshot:
      echo &"  [{status}] {test.name} - {r.output}"
    else:
      echo &"  [{status}] {test.name}"
    results.add(r)
    let short_name = test.name.split("/")[^1]
    if previous.hasKey(short_name) and previous[short_name] and not r.passed:
      regressions.add(test.name)
  SuiteResults(suite_name: name, results: results)

proc run_mgba_suite(harness: string; previous: Table[string, bool];
                    regressions: var seq[string];
                    detail: var seq[MgbaSuiteDetail]): SuiteResults =
  echo &"\n=== GBA - mGBA Test Suite ==="
  let rom_path = ensure_rom_download(
    "https://github.com/mattrbeck/mgba-suite-auto/releases/download/v1.0/suite.gba",
    "mgba-suite.gba")
  let cmd = &"{harness} {rom_path.quoteShell} --mode=mgba-suite --timeout=36000"
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
        let short_name = current_suite
        if previous.hasKey(short_name) and previous[short_name] and not passed:
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
          current_tests[^1].actual = inner[0 ..< vs_pos]
          current_tests[^1].expected = inner[vs_pos + 4 .. ^1]
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

proc main() =
  let harness = getCurrentDir() / "dingbat_test"
  if not fileExists(harness):
    echo "Error: dingbat_test not found. Run 'nimble test_build' first."
    quit(1)

  let results_path = getCurrentDir() / "tests" / "results.md"
  let previous = load_previous_results(results_path)

  var all_suites: seq[SuiteResults]
  var regressions: seq[string]

  # All GB tests come from the game-boy-test-roms release
  let gb_test_roms_dir = ensure_gameboy_test_roms()

  # Blargg tests
  let blargg_tests = build_blargg_tests(gb_test_roms_dir / "blargg")
  all_suites.add(run_suite("Game Boy - Blargg", blargg_tests, harness, previous, regressions))

  # Mooneye tests
  let mooneye_tests = build_mooneye_tests(gb_test_roms_dir)
  all_suites.add(run_suite("Game Boy - Mooneye", mooneye_tests, harness, previous, regressions))

  # mGBA Test Suite (GBA)
  var mgba_detail: seq[MgbaSuiteDetail]
  let mgba_results = run_mgba_suite(harness, previous, regressions, mgba_detail)
  all_suites.add(mgba_results)

  # Acid2 tests (screenshot comparison)
  let acid2_tests = build_acid2_tests()
  all_suites.add(run_suite("Game Boy - Acid2", acid2_tests, harness, previous, regressions))

  # Mealybug Tearoom tests (screenshot comparison)
  let mealybug_tests = build_mealybug_tests(gb_test_roms_dir / "mealybug-tearoom-tests")
  all_suites.add(run_suite("Game Boy - Mealybug Tearoom", mealybug_tests, harness, previous, regressions))

  # Write results
  createDir(getCurrentDir() / "tests")
  writeFile(results_path, generate_results_md(all_suites))
  let mgba_detail_path = getCurrentDir() / "tests" / "results_mgba_suite.md"
  writeFile(mgba_detail_path, generate_mgba_detail_md(mgba_detail))
  echo &"\nResults written to {results_path}"
  echo &"mGBA detail written to {mgba_detail_path}"

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
