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
    tmSerial, tmSram, tmMooneye, tmMgba, tmMgbaSuite, tmScreenshot, tmJsmolka,
    tmMicrotest

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
    no_save: bool         # blank cart RAM + detach the .sav (battery-backed ROMs)
    ed_breakpoint: bool   # opcode 0xED ends the run (wilbertpol mooneye fork)
    bb_breakpoint: bool   # LD B,B always ends the run, pass or fail (AGE)

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
    of tmMicrotest: "microtest"
  if test.mode == tmScreenshot:
    let tmp_ppm = getTempDir() / "dingbat_test_" & test.rom_path.splitFile().name & ".ppm"
    var cmd = &"{harness_path.quoteShell} {test.rom_path.quoteShell} --mode=screenshot --timeout={test.timeout} --screenshot={tmp_ppm.quoteShell}"
    if test.color:
      cmd.add(" --color")
    if test.cgb:
      cmd.add(" --cgb")
    if test.model.len > 0:
      cmd.add(" --model=" & test.model)
    if test.no_save:
      cmd.add(" --nosave")
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
    if test.no_save:
      cmd.add(" --nosave")
    if test.ed_breakpoint:
      cmd.add(" --ed-breakpoint")
    if test.bb_breakpoint:
      cmd.add(" --bb-breakpoint")
    let (output, code) = execCmdEx(cmd, options = {poUsePath})
    var text = output.strip()
    if test.mode == tmMicrotest:
      # Keep only the one line that carries the $FF80/$FF81/$FF82 triple: it is
      # what makes a failing row actionable in results.md, and a verdict of
      # 0x00 (the ROM never wrote one) reads very differently from 0xFF (the
      # ROM ran and reported a mismatch).
      for line in text.splitLines():
        if line.startsWith("MICROTEST actual"):
          text = line[len("MICROTEST ") .. ^1]
          break
    return TestResult(
      name: test.name,
      passed: code == 0,
      output: text,
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
  # The rest of the bundled Blargg suites. They all report through the newer
  # framework's SRAM protocol that tmSram already reads ($A000 status byte +
  # "DEB061" signature + text), so wiring them up is just naming the paths.
  #
  # oam_bug wants ~21 emulated seconds per the suite howto (~1260 frames) —
  # hence the larger timeout. It only costs anything for a ROM that never
  # reports, since tmSram stops the moment the status byte lands.
  for (subdir, secs) in [("oam_bug", 21), ("mem_timing-2", 4)]:
    let singles = repo_dir / subdir / "rom_singles"
    if not dirExists(singles): continue
    for rom in find_roms(singles, ".gb"):
      tests.add(TestDef(
        name: "blargg/" & subdir & "/" & rom.splitFile().name,
        rom_path: rom,
        mode: tmSram,
        timeout: max(1800, secs * 70),
      ))
  let halt_bug = repo_dir / "halt_bug.gb"
  if fileExists(halt_bug):
    tests.add(TestDef(
      name: "blargg/halt_bug",
      rom_path: halt_bug,
      mode: tmSram,
      timeout: 1800,
    ))
  # interrupt_time is a CGB-only ROM (the howto records DMG-C failing it with
  # checksum 7F8F4AAF: "this is a CGB-only rom, so failure was expected"), but
  # the cart is DMG-flagged — so it needs the CGB boot state forced, exactly
  # like blargg's cgb_sound.
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

proc mooneye_model_for(base: string): string =
  ## The boot_regs/boot_div/boot_hwio ROMs each target one specific hardware
  ## revision, encoded as the filename suffix after the last '-' (e.g.
  ## boot_regs-mgb, boot_div-S, misc/boot_regs-A). Map that suffix to the
  ## harness --model flag so the right boot table is applied. Only boot_* ROMs
  ## are model-scoped; everything else uses the default boot state. The
  ## default-model suffixes (dmgABC, dmgABCmgb, cgb, cgbABCDE, C) are left
  ## unmapped so their long-standing passing behavior is untouched.
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

proc build_mooneye_tests(roms_dir: string): seq[TestDef] =
  var tests: seq[TestDef]
  let mooneye_dir = roms_dir / "mooneye-test-suite"
  if not dirExists(mooneye_dir):
    echo "  Warning: mooneye-test-suite directory not found in game-boy-test-roms"
    return tests
  for rom in find_roms_recursive(mooneye_dir, ".gb"):
    let rel = rom.relativePath(mooneye_dir)
    let name = "mooneye/" & rel.changeFileExt("")
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
    let model = mooneye_model_for(rom.splitFile().name)
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

proc build_gbmicrotest_tests(dir: string): seq[TestDef] =
  ## aappleby's GBMicrotest: 500+ tiny DMG timing probes. Per the suite's howto
  ## each writes its verdict into HRAM — $FF80 actual, $FF81 expected, $FF82
  ## $01/$FF pass/fail — and then keeps running, so there is no completion
  ## signal: the harness runs a fixed number of frames and reads $FF82 out (see
  ## --mode=microtest). "Running the emulation for two frames should be
  ## sufficient", with one documented exception that needs ~380 ms.
  ##
  ## Two frames per ROM is why 500 processes cost about as much as one mGBA
  ## suite run; the whole suite is ~2 s wall clock.
  var tests: seq[TestDef]
  if not dirExists(dir):
    echo "  Warning: gbmicrotest directory not found"
    return tests
  for rom in find_roms(dir, ".gb"):
    let name = rom.splitFile().name
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
  ## One screenshot-comparison TestDef. The bundled reference PNGs use the same
  ## palette conventions the harness already renders (DMG shades
  ## #000000/#555555/#AAAAAA/#FFFFFF, CGB channels expanded (X<<3)|(X>>2)),
  ## which is why acid2 and mealybug compare cleanly and these need no new
  ## color work.
  TestDef(name: name, rom_path: rom, mode: tmScreenshot, timeout: timeout,
          expected_png: png, color: color, cgb: cgb, no_save: no_save)

proc build_small_screenshot_tests(roms_dir: string): seq[TestDef] =
  ## The bundle's small screenshot suites, wired from an explicit table rather
  ## than by globbing: each one has its own exit condition (from its howto) and
  ## its own device story, and the reference PNG names encode which device the
  ## image was captured on. Only DMG and CGB-native references are used — the
  ## "-ncm"/"CGB compatibility mode" images are a third device (a CGB booting a
  ## non-CGB cart) with its own palette, which this harness does not model.
  ##
  ## Frame counts come from the howtos: half a second (~30 frames) for bully,
  ## strikethrough and turtle-tests; ~10 frames for most scribbltests but ~270
  ## for statcount-auto; 40 for mbc3-tester. Where a ROM signals mooneye's
  ## LD B,B breakpoint (cgb-acid-hell) the run stops there anyway and the frame
  ## count is only an upper bound.
  var tests: seq[TestDef]
  template add_if(name, rom, png: string; timeout: int; color = false;
                  cgb = false; no_save = false) =
    if fileExists(rom) and fileExists(png):
      tests.add(shot(name, rom, png, timeout, color, cgb, no_save))

  # BullyGB (Hacktix) — broad hardware-behavior torture test. The one bundled
  # reference is a CGB capture (the howto records the author's own DMG-C
  # failing it with "Bad Echo RAM Reads"); the cart's CGB flag is $80, so it
  # boots CGB without --cgb.
  let bully = roms_dir / "bully"
  add_if("bully/bully", bully / "bully.gb", bully / "bully.png", 120, color = true)

  # strikethrough (Hacktix) — OAM DMA behavior. Also a $80 (CGB-capable) cart,
  # so only the CGB reference is usable: scoring the -dmg one would mean
  # running a CGB-flagged cart as a DMG, which this harness cannot do (--cgb
  # only forces CGB *on*).
  let strike = roms_dir / "strikethrough"
  add_if("strikethrough/strikethrough-cgb", strike / "strikethrough.gb",
         strike / "strikethrough-cgb.png", 60, color = true)

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

  # cgb-acid-hell (mattcurrie) — CGB PPU torture test, the companion to the
  # cgb-acid2 already scored above. Finishes on LD B,B.
  let hell = roms_dir / "cgb-acid-hell"
  add_if("cgb-acid-hell/cgb-acid-hell", hell / "cgb-acid-hell.gbc",
         hell / "cgb-acid-hell.png", 120, color = true)

  # little-things-gb (pinobatch). Only firstwhite is scoreable here: tellinglys
  # needs a scripted button press per its howto, and dingbat_test has no input
  # scripting yet.
  let little = roms_dir / "little-things-gb"
  add_if("little-things-gb/firstwhite", little / "firstwhite.gb",
         little / "firstwhite-dmg-cgb.png", 60)

  # MBC3 bank tester — a mapper test, so it is device-independent; the CGB
  # reference is a CGB-compatibility-mode capture, which is not modeled, so
  # only the DMG one is scored. Battery-backed: --nosave keeps a .sav from
  # leaking into the next run.
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

proc build_age_tests(age_dir: string): seq[TestDef] =
  ## c-sp's own AGE test roms. Two verdicts, both already implemented here:
  ## most ROMs end on LD B,B with the mooneye Fibonacci registers (tmMooneye),
  ## and the handful that cannot self-verify ship reference PNGs named
  ## `<rom>-<device>.png` next to the ROM (tmScreenshot).
  ##
  ## Coverage is concentrated on mid-scanline PPU timing (m3-bg-*, stat-mode,
  ## lcd-align-ly), OAM/VRAM access windows and CGB speed switching.
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
        tests.add(shot("age/" & rel & "-" & device, rom, png,
                       timeout = 120, color = cgb, cgb = cgb))
      continue
    let devices = age_device_tokens(base)
    let dmg = devices.anyIt(it.startsWith("dmg"))
    let cgb = devices.anyIt(it.startsWith("cgb"))
    if not dmg and not cgb:
      continue   # ncm-only: CGB in non-CGB mode, which this harness cannot run
    tests.add(TestDef(
      name: "age/" & rel,
      rom_path: rom,
      mode: tmMooneye,
      timeout: 1800,
      cgb: not dmg,   # prefer DMG when the ROM is verified on both
      # AGE signals failure with "any register values other than the Fibonacci
      # ones", not with a dedicated failure signature, so LD B,B has to end the
      # run unconditionally. Without this a failing ROM never stops and burns
      # the whole 1800-frame timeout — which, with most of this suite red
      # today, was the single biggest chunk of the runner's wall clock.
      bb_breakpoint: true,
    ))
  tests

proc build_wilbertpol_tests(roms_dir: string): seq[TestDef] =
  ## wilbertpol's fork of the Mooneye suite. Same Fibonacci-register verdict as
  ## Gekkio's, but built against mooneye-gb as it stood in 2016, when the magic
  ## breakpoint was the undefined opcode 0xED rather than LD B,B — hence
  ## ed_breakpoint (see the 0xED handler in src/dingbat/gb/opcodes.nim).
  ##
  ## Roughly 80% of the content overlaps the Gekkio suite scored above, so the
  ## rows are namespaced `mooneye-wilbertpol/` and never collide with it.
  ##
  ## Not every directory is scoreable: `utils/` holds a dump tool rather than a
  ## test, and `logic-analysis/` ROMs are meant to be observed on a logic
  ## analyzer and have no pass/fail signal at all.
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
    # The two screenshot ROMs: sprite_priority (DMG reference, the same one the
    # Gekkio suite uses) and madness/mgb_oam_dma_halt_sprites, whose reference
    # was captured on an MGB.
    if rel == "manual-only" / "sprite_priority.gb":
      tests.add(shot(name, rom, rom.parentDir / "sprite_priority-dmg.png", 120))
      continue
    if rel == "madness" / "mgb_oam_dma_halt_sprites.gb":
      var t = shot(name, rom, rom.parentDir / "mgb_oam_dma_halt_sprites_expected.png", 120)
      t.model = "mgb"
      tests.add(t)
      continue
    let base = rom.splitFile().name
    # Device suffix after the last '-': -C/-A are CGB/AGB tests, -G/-S/-GS are
    # DMG/SGB. misc/ is the CGB-hardware directory, same convention as Gekkio's.
    let suffix = if '-' in base: base.rsplit('-', maxsplit = 1)[1] else: ""
    tests.add(TestDef(
      name: name,
      rom_path: rom,
      mode: tmMooneye,
      timeout: 1800,
      cgb: rel.startsWith("misc") or suffix in ["C", "cgb", "cgb0", "A"],
      model: mooneye_model_for(base),
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
      if not r.passed:
        if r.output.contains("% correct") or r.output.contains("passed") or
           r.output.contains("timed out") or r.output.contains("verdict=0x"):
          detail = " " & r.output
      # The row name is the FULL test name, suite prefix included. It is the
      # key the regression comparison reads back (load_previous_results), and
      # with ~20 suites in here — several of them forks of each other, e.g.
      # mooneye vs mooneye-wilbertpol, blargg/mem_timing vs mem_timing-2 —
      # anything shorter collides across suites and silently mis-keys the gate.
      lines.add("| " & r.name & " | " & emoji & detail & " |")
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
  ## The committed baseline, keyed by the full test name exactly as
  ## generate_results_md writes it. A name that is not in the table (a suite
  ## added since the baseline was committed) is simply not gated — which is why
  ## the baseline has to be regenerated and committed whenever suites are added.
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
    if test.mode in {tmScreenshot, tmMicrotest}:
      echo &"  [{status}] {test.name} - {r.output}"
    else:
      echo &"  [{status}] {test.name}"
    results.add(r)
    if previous.getOrDefault(test.name) and not r.passed:
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
        if previous.getOrDefault("mgba-suite/" & current_suite) and not passed:
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

  # GBMicrotest (HRAM verdict byte)
  all_suites.add(run_suite("Game Boy - GBMicrotest",
    build_gbmicrotest_tests(gb_test_roms_dir / "gbmicrotest"),
    harness, previous, regressions))

  # AGE test roms (mooneye-style verdict + screenshot comparison)
  all_suites.add(run_suite("Game Boy - AGE",
    build_age_tests(gb_test_roms_dir / "age-test-roms"),
    harness, previous, regressions))

  # The bundle's small screenshot suites (bully, strikethrough, scribbltests,
  # turtle-tests, cgb-acid-hell, little-things-gb, mbc3-tester)
  all_suites.add(run_suite("Game Boy - Screenshot suites",
    build_small_screenshot_tests(gb_test_roms_dir), harness, previous, regressions))

  # Mooneye suite, wilbertpol fork (0xED breakpoint)
  all_suites.add(run_suite("Game Boy - Mooneye (wilbertpol)",
    build_wilbertpol_tests(gb_test_roms_dir), harness, previous, regressions))

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
