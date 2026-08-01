import std/[os, osproc, strutils, strformat, tables, sequtils, times, algorithm, parseopt]
import zippy/ziparchives
import png_reader

let RomCacheDir =
  # CI sets DINGBAT_ROM_CACHE to a stable, actions/cache-backed path so the test
  # ROMs survive between runs (no re-download, no per-run network dependency).
  # Locally it falls back to a temp dir.
  block:
    let env = getEnv("DINGBAT_ROM_CACHE")
    if env.len > 0: env
    elif defined(windows): getTempDir() / "dingbat-test-roms"
    else: "/tmp/dingbat-test-roms"

type
  TestMode = enum
    tmSerial, tmSram, tmMooneye, tmMgba, tmMgbaSuite, tmScreenshot, tmJsmolka

  TestDef = object
    name: string
    rom_path: string
    mode: TestMode
    timeout: int
    expected_png: string  # for screenshot mode
    expected_hash: string # screenshot mode, alternative to expected_png:
                          # FNV-1a of the PPM, for ROMs that ship no reference
                          # image (see build_jsmolka_tests)
    color: bool           # true = RGB comparison, false = greyscale
    cgb: bool             # force CGB mode (DMG cart on CGB hardware tests)
    model: string         # mooneye per-model boot table (--model=...); "" = default

  TestResult = object
    name: string
    passed: bool
    output: string
    timed_out: bool
    always_detail: bool  # keep `output` in results.md even when the row passes
                         # (aggregated rows carry their pass COUNT there, and
                         # the count is what the regression gate compares)

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
  ## Fetch `url` to `path`, retrying transient network failures. CI runners
  ## intermittently fail to reach github.com (curl exit 28, "Failed to connect
  ## ... after 21015 ms"), which used to abort the whole suite and fail dozens of
  ## unrelated ROM tests. --retry-all-errors makes curl itself ride those out
  ## (connection errors included, not just HTTP 5xx); --fail avoids saving an
  ## error page as a ROM. A genuine outage still fails hard, but only after the
  ## retries are exhausted.
  let cmd = "curl -L --fail --show-error --silent " &
    "--retry 5 --retry-all-errors --retry-delay 3 " &
    "--connect-timeout 30 --max-time 600 " &
    &"-o {path.quoteShell} {url.quoteShell}"
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    echo &"Failed to download {url} (curl exit {code}): ", output
    quit(1)

proc ensure_gameboy_test_roms(): string =
  let dir = RomCacheDir / "game-boy-test-roms"
  if dirExists(dir) and has_rom_files(dir):
    return dir
  if dirExists(dir):
    echo "Cached game-boy-test-roms directory has no ROMs, re-downloading..."
    removeDir(dir)
  echo "Downloading game-boy-test-roms release..."
  createDir(RomCacheDir)
  let url = "https://github.com/c-sp/game-boy-test-roms/releases/download/v7.0/game-boy-test-roms-v7.0.zip"
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

proc ensure_rom_download(url, filename: string): string =
  ## Download a single ROM file if not already cached.
  let path = RomCacheDir / filename
  if fileExists(path):
    return path
  echo &"Downloading {filename}..."
  createDir(RomCacheDir)
  download_file(url, path)
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
  if test.mode == tmScreenshot:
    let tmp_ppm = getTempDir() / "dingbat_test_" & test.rom_path.splitFile().name & ".ppm"
    var cmd = &"{harness_path.quoteShell} {test.rom_path.quoteShell} --mode=screenshot --timeout={test.timeout} --screenshot={tmp_ppm.quoteShell}"
    if test.color:
      cmd.add(" --color")
    let (run_output, run_code) = execCmdEx(cmd, options = {poUsePath})
    if run_code != 0:
      return TestResult(name: test.name, passed: false, output: run_output.strip())
    if test.expected_hash.len > 0:
      # No reference image ships with these ROMs, so the gate is a pinned hash
      # of the rendered frame (see build_jsmolka_tests for where it came from).
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
    # Read actual pixels from PPM
    let actual = if test.color: read_ppm_rgb(tmp_ppm) else: read_ppm_greyscale(tmp_ppm)
    removeFile(tmp_ppm)
    # Read expected pixels from PNG
    var expected = read_png(test.expected_png)
    if not test.color and expected.channels == 3:
      # Greyscale comparison against an RGB reference (e.g. mooneye's
      # sprite_priority-dmg.png stores grey shades as R=G=B truecolor):
      # collapse to one byte per pixel via the R channel.
      var grey = newSeq[uint8](expected.pixels.len div 3)
      for i in 0 ..< grey.len:
        grey[i] = expected.pixels[i * 3]
      expected.pixels = grey
      expected.channels = 1
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
    var cmd = &"{harness_path.quoteShell} {test.rom_path.quoteShell} --mode={mode_str} --timeout={test.timeout}"
    if test.cgb:
      cmd.add(" --cgb")
    if test.model.len > 0:
      cmd.add(" --model=" & test.model)
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

proc build_blargg_sound_tests(sound_dir, suite: string; cgb: bool): seq[TestDef] =
  ## blargg's dmg_sound / cgb_sound APU suites (rom_singles). Unlike cpu_instrs
  ## these print nothing to the serial port: they report through the newer
  ## framework's SRAM protocol ($A000 status byte + "DEB061" signature + text),
  ## which is what tmSram reads. cgb_sound asserts CGB APU behavior from a
  ## DMG-flagged cart, so it needs the CGB boot state (cgb = true); dmg_sound is
  ## DMG-only. Opt-in, see --apu in main().
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
      timeout: 1800,
      cgb: cgb,
    ))
  tests

proc build_samesuite_apu_tests(samesuite_dir: string): seq[TestDef] =
  ## SameSuite's sample-accurate APU tests. They signal the verdict with
  ## mooneye's magic LD B,B breakpoint (registers = fibonacci 3/5/8/13/21/34 on
  ## pass), so tmMooneye reads them as-is. Every one of them samples the CGB-only
  ## PCM12/PCM34 registers, so they all run on CGB hardware (per the suite's
  ## README, pre-CGB devices only pass the div_write_trigger pair). Opt-in, see
  ## --apu in main().
  var tests: seq[TestDef]
  let apu_dir = samesuite_dir / "apu"
  if not dirExists(apu_dir):
    echo "  Warning: same-suite apu directory not found"
    return tests
  for rom in find_roms_recursive(apu_dir, ".gb"):
    let rel = rom.relativePath(apu_dir)
    tests.add(TestDef(
      name: "same-suite/apu/" & rel.changeFileExt(""),
      rom_path: rom,
      mode: tmMooneye,
      timeout: 1800,
      cgb: true,
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
    # The boot_regs-*/boot_div-*/boot_hwio-* ROMs each target one specific
    # hardware revision, encoded as the filename suffix after the last '-'
    # (e.g. boot_regs-mgb, boot_div-S, misc/boot_regs-A). Map that suffix to
    # the harness --model flag so the right boot table is applied. Only boot_*
    # ROMs are model-scoped; everything else uses the default boot state. The
    # default-model suffixes (dmgABC, dmgABCmgb, cgb, cgbABCDE, C) are left
    # unmapped so their long-standing passing behavior is untouched.
    # manual-only/sprite_priority has no serial pass/fail signal — mooneye
    # ships a reference image instead. Run it as a screenshot comparison
    # against the bundled DMG reference (same convention as mealybug/acid2).
    if rel == "manual-only" / "sprite_priority.gb":
      tests.add(TestDef(
        name: name,
        rom_path: rom,
        mode: tmScreenshot,
        timeout: 120,
        expected_png: rom.parentDir / "sprite_priority-dmg.png",
      ))
      continue
    var model = ""
    let base = rom.splitFile().name
    if base.startsWith("boot_") and '-' in base:
      case base.rsplit('-', maxsplit = 1)[1]
      of "dmg0": model = "dmg0"
      of "mgb":  model = "mgb"
      of "sgb":  model = "sgb"
      of "sgb2": model = "sgb2"
      of "S":    model = "sgb"    # boot_div-S / boot_div2-S / boot_hwio-S
      of "A":    model = "agb"    # misc/boot_regs-A / boot_div-A
      of "cgb0": model = "cgb0"
      else: discard
    tests.add(TestDef(
      name: name,
      rom_path: rom,
      mode: tmMooneye,
      timeout: 1800,
      # misc/ holds the CGB/AGB-hardware tests (DMG-flagged carts that
      # assert CGB boot state); run them as a DMG cart on CGB hardware
      cgb: rel.startsWith("misc"),
      model: model,
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

# jsmolka/gba-tests. Pinned to a commit so a CI run is reproducible and the
# ROM cache key below stays meaningful; bump both together.
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
  ## Two kinds of ROM live in this suite.
  ##
  ## The self-checking ones (arm, thumb, memory, bios, save/*, unsafe) report
  ## through the shared r12 protocol that --mode=jsmolka reads; each is
  ## all-or-nothing and names the FIRST check it failed, because the ROM stops
  ## there. Timeouts are generous but the ROMs finish in a handful of frames.
  ##
  ## The ppu/ and nes/ ROMs have no self-check at all — they just draw. They
  ## still make good render regressions, so they are gated on a pinned hash of
  ## the frame instead. Those hashes are not self-generated goldens: each was
  ## confirmed byte-identical against BOTH mGBA and NanoBoyAdvance (via
  ## tools/romfuzz's headless runners) before being written down, so a change
  ## here means dingbat moved away from two independent implementations.
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
      if r.always_detail:
        detail = " " & r.output
      elif not r.passed:
        if r.output.contains("% correct") or r.output.contains("passed") or r.output.contains("timed out"):
          detail = " " & r.output
      let short_name = if r.name.contains("/"): r.name.split("/", maxsplit = 1)[1] else: r.name
      lines.add("| " & short_name & " | " & emoji & detail & " |")
      inc total
      if r.passed: inc pass_count else: inc fail_count
    if suite.suite_name == "GBA - mGBA Test Suite":
      lines.add("")
      lines.add("See [detailed results](results_mgba_suite.md) for individual test outcomes.")
    elif suite.suite_name == "Game Boy - gambatte":
      lines.add("")
      lines.add("Each row is one gambatte subdirectory. See " &
        "[detailed results](results_gambatte.md) for individual test outcomes.")
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

proc load_previous_counts(path: string): Table[string, int] =
  ## Pass COUNTS from a committed results.md, for the rows that report
  ## "<passes>/<total> passed" (the aggregated suites). A row that goes from
  ## 1974/2020 to 1970/2020 is a regression even though its pass/fail bit
  ## never changed, so the aggregated suites gate on this rather than on
  ## load_previous_results' boolean.
  result = initTable[string, int]()
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    if not line.startsWith("| ") or line.startsWith("| Test") or line.startsWith("|---"):
      continue
    let parts = line.split("|").mapIt(it.strip())
    if parts.len < 3: continue
    let words = parts[2].splitWhitespace()
    for i, w in words:
      if w == "passed" and i > 0 and '/' in words[i - 1]:
        let halves = words[i - 1].split('/')
        try:
          result[parts[1]] = parseInt(halves[0])
        except ValueError: discard
        break

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
                    detail: var seq[MgbaSuiteDetail];
                    bios_path: string = ""): SuiteResults =
  echo &"\n=== GBA - mGBA Test Suite ==="
  let rom_path = ensure_rom_download(
    "https://github.com/mattrbeck/mgba-suite-auto/releases/download/v1.0/suite.gba",
    "mgba-suite.gba")
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

# ==================== gambatte ====================
#
# sinamas' gambatte suite, shipped inside the same game-boy-test-roms bundle as
# Blargg/Mooneye/Mealybug/SameSuite — 3,524 ROMs, no extra download. The rules
# for turning a filename into a test are the bundle's own
# gambatte/game-boy-test-roms-howto.md; --mode=gambatte in dingbat_test.nim
# carries the long-form explanation and does the scoring. In brief:
#
#   * `dmg08` in the name = a DMG test, `cgb04c` = a CGB test. Most ROMs carry
#     both and are two rows here.
#   * `_out<hex>` is the expected value, per device, rendered on screen as hex
#     glyphs. `_outaudio0/1` is an audio test (see below). An `x` in front of a
#     tag disables it.
#   * a <rom>_dmg08.png / _cgb04c.png / _dmg08_cgb04c.png next to the ROM makes
#     it a full-frame screenshot test instead.
#
# NOT scored: the 220 `_outaudio0/1` rows. Gambatte decides them by asking
# whether all 35,112 samples of the final frame are identical — that is a
# 2 MHz sample stream, one sample per two clocks, and several of those ROMs
# turn on a difference lasting a handful of clocks (ch1_duty0_pos6_to_pos7_*).
# dingbat's APU emits at 32,768 Hz, 64x coarser, so a faithful verdict is not
# available from the sample path as it stands and a coarse one would be
# scored noise. Also not scored: gambatte's AGB column, which its own runner
# marks "FIXME: Actual AGB results" and gives the CGB expectations.
#
# Reporting is per-subdirectory (`| oamdma | 800/884 passed |`), like the mGBA
# suite: 5,005 individual rows would drown results.md. The per-test detail
# goes to tests/results_gambatte.md.

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
  ## The leading run of hex digits, which is exactly what gambatte's runner
  ## reads: it walks the filename tail glyph by glyph and stops at the first
  ## character that is not 0-9/A-F (the '.' of the extension, or the '_' that
  ## starts the other device's tag).
  for c in tail:
    if c in {'0'..'9', 'a'..'f', 'A'..'F'}: result.add(c)
    else: break

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

  # One process per ROM would cost more than the emulation: each row is 15
  # frames (a few ms), and there are thousands of them. Batch them into one
  # --mode=gambatte process per core instead, round-robin so the shards stay
  # balanced (the suite's cost per ROM is far from uniform). Rows are
  # independent — each builds a fresh GB — so the split cannot change a
  # verdict; `tests/README.md` records how that was verified.
  let work_dir = getTempDir() / "dingbat-gambatte"
  removeDir(work_dir)
  createDir(work_dir)
  defer: removeDir(work_dir)
  let shards = max(1, min(countProcessors(), 16))
  var shard_rows = newSeq[seq[int]](shards)
  for i in 0 ..< rows.len: shard_rows[i mod shards].add(i)
  var cmds: seq[string]
  var out_paths: seq[string]
  for s in 0 ..< shards:
    let list_path = work_dir / &"list{s}.tsv"
    let out_path = work_dir / &"out{s}.txt"
    var lines: seq[string]
    for i in shard_rows[s]:
      lines.add(rows[i].dev & "\t" & rows[i].kind & "\t" & rows[i].expected &
                "\t" & rows[i].rom)
    writeFile(list_path, lines.join("\n") & "\n")
    cmds.add(&"{harness.quoteShell} --mode=gambatte --list={list_path.quoteShell}" &
             &" > {out_path.quoteShell} 2>&1")
    out_paths.add(out_path)
  discard execProcesses(cmds, options = {poUsePath, poEvalCommand}, n = shards)

  var passed = newSeq[bool](rows.len)
  var detail = newSeq[string](rows.len)
  var seen = newSeq[bool](rows.len)
  for s in 0 ..< shards:
    if not fileExists(out_paths[s]): continue
    for line in readFile(out_paths[s]).splitLines():
      if not line.startsWith("GAM "): continue
      let parts = line.split(' ', maxsplit = 3)
      if parts.len < 3: continue
      var local: int
      try: local = parseInt(parts[1])
      except ValueError: continue
      if local < 0 or local >= shard_rows[s].len: continue
      let g = shard_rows[s][local]
      seen[g] = true
      passed[g] = parts[2] == "PASS"
      detail[g] = if parts.len > 3: parts[3].strip() else: ""
  for i in 0 ..< rows.len:
    if not seen[i]:
      detail[i] = "harness produced no verdict (crash or timeout in its shard)"

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
    ))
    # Regression on either bit: a group that used to be all-green going red, or
    # a group whose pass COUNT dropped.
    if previous.hasKey(name) and previous[name] and not all_pass:
      regressions.add(short_name)
    elif previous_counts.hasKey(name) and g.passes < previous_counts[name]:
      regressions.add(&"{short_name} ({previous_counts[name]} -> {g.passes} passing)")
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

  # The GB APU suites are opt-in (--apu, or --suite=apu). They are deliberately
  # NOT part of the default run: most of SameSuite's sample-accurate tests fail
  # today, and folding them in would change both the headline case count and
  # tests/results.md. So --apu runs only them and prints its tallies rather than
  # rewriting any results file.
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

  # Acid2 tests (screenshot comparison)
  let acid2_tests = build_acid2_tests()
  all_suites.add(run_suite("Game Boy - Acid2", acid2_tests, harness, previous, regressions))

  # Mealybug Tearoom tests (screenshot comparison)
  let mealybug_tests = build_mealybug_tests(gb_test_roms_dir / "mealybug-tearoom-tests")
  all_suites.add(run_suite("Game Boy - Mealybug Tearoom", mealybug_tests, harness, previous, regressions))

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
