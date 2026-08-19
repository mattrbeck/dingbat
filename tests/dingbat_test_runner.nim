import std/[os, osproc, strutils, strformat, tables, sequtils, times, algorithm, parseopt, sha1]
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
    tmFuzzArm, tmMagenGreen, tmMagenNoRed, tmMicrotest

  TestDef = object
    name: string
    rom_path: string
    mode: TestMode
    timeout: int
    expected_png: string  # for screenshot mode
    alt_pngs: seq[string] # screenshot mode: additional references that are
                          # ALSO a pass. Hardware itself is non-deterministic
                          # for a few tests (daid's ppu_scanline_bgp ships
                          # three legitimate DMG outcomes), so the verdict is
                          # "matches any listed reference", not "matches one".
    expected_hash: string # screenshot mode, alternative to expected_png:
                          # FNV-1a of the PPM, for ROMs that ship no reference
                          # image (see build_jsmolka_tests)
    grey_tolerance: int   # screenshot mode. 0 (the default) = every pixel must
                          # match the reference exactly, which is right for
                          # every suite that ships raw framebuffer dumps.
                          # Above 0, the comparison instead converts both sides
                          # to luma and allows that much difference per pixel —
                          # the gbdev shootout's own `compareImage` rule, and
                          # the only honest way to score ITS reference images,
                          # which are screen captures of a running emulator
                          # rather than framebuffer dumps and so carry that
                          # emulator's CGB colour correction. Measured: their
                          # green is #009100, which the raw 5-to-8-bit
                          # expansion `(X<<3)|(X>>2)` cannot even produce (it
                          # emits #00CE00 for that channel value). Exact
                          # matching would mark a correct frame wrong, so the
                          # suite's own tolerance is the mechanism to copy.
    color: bool           # true = RGB comparison, false = greyscale
    cgb: bool             # force CGB mode (DMG cart on CGB hardware tests)
    dmg: bool             # force DMG mode (--dmg) for a row whose cart carries a
                          # CGB header but whose suite verified it on a DMG. The
                          # cart header is the default device everywhere else;
                          # this is the per-row override for the rows where the
                          # suite's own howto names the hardware instead.
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
    always_detail: bool  # keep `output` in results.md even when the row passes
                         # (aggregated rows carry their pass COUNT there, and
                         # the count is what the regression gate compares)
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
  ## Download a single ROM file if not already cached. When expect_sha is given
  ## the cached file's SHA-1 is checked against it and a mismatch is reported —
  ## for a URL that tracks "latest" this is what keeps a new upstream build from
  ## silently re-baselining a whole suite while looking like an emulator change.
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
    proc score_against(png_path: string): tuple[matched, total: int, err: string] =
      ## Pixels matching `png_path`, or a non-empty `err` if it is unusable.
      ##
      ## `--color` sets the *capture* format, but the reference decides the
      ## comparison. Reference sets really do mix PNG formats within one suite —
      ## daid's three legitimate `ppu_scanline_bgp` outcomes are two truecolour
      ## images and one indexed, and mealybug's `_cgb_c` set mixes indexed with
      ## 1-bit greyscale, because a frame that came out black-and-white was
      ## saved as such. So both sides are brought to a common channel count
      ## before any comparison runs; every reference here stores greys as
      ## R=G=B, so nothing is lost.
      ##
      ## Note which side moves in the colour-vs-greyscale case: the REFERENCE
      ## is widened to RGB, rather than the capture being narrowed to its R
      ## channel. That keeps all three channels under test, so a frame that is
      ## actually coloured is a real mismatch instead of passing on R alone.
      ## Without this branch at all, a colour capture against a greyscale
      ## reference fails as an opaque "size mismatch", which the results writer
      ## drops as an unrecognised detail string — a silently blank row, and a
      ## blank row reads as a pass at a glance. Seven of mealybug's `_cgb_c`
      ## references are 1-bit greyscale and hit exactly this.
      var expected = read_png(png_path)
      if not test.color and expected.channels == 3:
        # Greyscale capture vs RGB reference (e.g. mooneye's
        # sprite_priority-dmg.png stores grey shades as R=G=B truecolor):
        # collapse the reference to one byte per pixel via the R channel.
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
        # The shootout's own criterion (util.py `compareImage`): convert both
        # frames to 8-bit luma and accept while every pixel is within a
        # tolerance. See `grey_tolerance` on TestDef for why these references
        # need it.
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
        # Count differing pixels (for RGB, compare 3 bytes at a time)
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
    # fuzzarm writes its per-failure triage to stderr and one summary line to
    # stdout. execCmdEx only ever reads the child's stdout pipe, so stderr must
    # be merged in: unread, it is both lost and a deadlock waiting to happen
    # once the triage outgrows the pipe buffer (500 failures is ~100 KB).
    let opts = if test.mode == tmFuzzArm: {poUsePath, poStdErrToStdOut}
               else: {poUsePath}
    let (output, code) = execCmdEx(cmd, options = opts)
    var text = output.strip()
    if test.mode == tmFuzzArm:
      # Keep only the "FUZZARM: " verdict for results.md — the triage would
      # otherwise become a multi-line table cell. Match on the marker, not on
      # position: the two streams interleave unpredictably once merged. Echo
      # everything else when the ROM failed, so what broke lands in the
      # runner's log where a CI failure can actually be read.
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
        # These eleven are the runner's only GB rows that run a whole ROM to a
        # verdict with nothing looking at the screen at all, which is how a PPU
        # change that blanked or wedged the panel could once merge green. The
        # check is weak on purpose; the reason it cannot assert the text is in
        # tests/README.md.
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
  # The rest of the bundled Blargg suites. They all report through the newer
  # framework's SRAM protocol that tmSram already reads ($A000 status byte +
  # "DEB061" signature + text), so wiring them up is just naming the paths.
  #
  # oam_bug wants ~21 emulated seconds per the suite howto (~1260 frames) —
  # hence the larger timeout. It only costs anything for a ROM that never
  # reports, since tmSram stops the moment the status byte lands.
  #
  # oam_bug also has to run on a DMG, and its carts do not say so: all eight
  # carry $0143 = $80, so the header-picks-the-device default runs them on a
  # CGB. The suite names the hardware instead — blargg's `readme.txt` opens
  # with "Verifies OAM corruption bug on DMG", the bundle's
  # `blargg/game-boy-test-roms-howto.md` lists `oam_bug` in its DMG-C table and
  # in NEITHER CGB one, and the shootout's `blargg.py` marks only
  # `interrupt_time` as `model=CGB`, so every other blargg row there is a DMG
  # row. The bug is DMG silicon (Pan Docs: "Game Boy Color and Advance are not
  # affected by this bug, even when running monochrome software"), which the
  # core models by gating on the console, so on the CGB these rows were being
  # scored against hardware that cannot pass them.
  for (subdir, secs) in [("oam_bug", 21), ("mem_timing-2", 4)]:
    let singles = repo_dir / subdir / "rom_singles"
    if not dirExists(singles): continue
    for rom in find_roms(singles, ".gb"):
      # Standalone 7-timing_effect is a broken BUILD, not a hard test: its
      # verbose per-timing output overruns the $A004..$BFFF text window into
      # the $C000 copy of its own code (the standalone builds copy themselves
      # to WRAM; the combined ROM runs from ROM and is immune), so it blanks
      # out before ever writing a result block. Confirmed unreportable on a
      # real DMG (Docheinstein/docboy#33, Everdrive X7: "stucks with a blank
      # screen there as well"), and the shootout's blargg.py comments it out
      # as "This test is broken." The same test logic is scored through the
      # combined oam_bug.gb row below, which reports 07:ok against the same
      # $7D792E7C CRC.
      if subdir == "oam_bug" and rom.splitFile().name == "7-timing_effect":
        continue
      tests.add(TestDef(
        name: "blargg/" & subdir & "/" & rom.splitFile().name,
        rom_path: rom,
        mode: tmSram,
        timeout: max(1800, secs * 70),
        dmg: subdir == "oam_bug",
      ))
  # The combined oam_bug.gb: same eight tests, but built NO_COPY (runs from
  # ROM), which is what makes test 7 reportable at all — see the skip above.
  # Runs in well under its budget because tmSram stops on the status byte.
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
  ## DMG-only, and forced (`dmg = true`) rather than left to the cart header
  ## after the oam_bug lesson: the suite names the hardware, the header does
  ## not. Part of the default run; --apu runs only the APU suites.
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
  ## SameSuite names its per-revision ROMs the way mooneye and AGE do: a
  ## trailing `-<devices>` token listing the revisions the ROM's own
  ## `CorrectResults` table was taken on — `channel_1_extra_length_clocking-cgb0B`,
  ## `channel_3_extra_length_clocking-cgb0` / `-cgbB`,
  ## `channel_1_freq_change_timing-A` / `-cgb0BC` / `-cgbDE`. Nine of the 70 APU
  ## ROMs carry one.
  ##
  ## Without this the runner scores every one of them on the default revision,
  ## where most of them CANNOT pass by construction: `-cgb0B` asserts the
  ## extra-length-clocking rule that CPU CGB C fixed, so a green default row
  ## would mean the default was wrong. Passing the token through to
  ## `--model=` is what makes "this ROM passes on revision X" expressible; the
  ## harness resolves it with the same gb_revision_from_name the emulator uses.
  ##
  ## Only tokens after the LAST '-' are considered, and only if they look like
  ## a device list, so `channel_1_freq_change` (no suffix) and
  ## `div_write_trigger_10` are left on the default.
  if '-' notin base: return ""
  let tok = base.rsplit('-', maxsplit = 1)[1]
  if tok.len == 0: return ""
  let head = tok.toLowerAscii()
  if head == "a" or head.startsWith("cgb") or head.startsWith("dmg") or
     head.startsWith("agb") or head.startsWith("mgb"):
    return tok
  ""

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
      model: samesuite_model_for(rom.splitFile().name),
    ))
  tests

proc build_samesuite_core_tests(samesuite_dir: string): seq[TestDef] =
  ## SameSuite's non-APU groups: `dma` (4), `ppu` (1) and `interrupt` (1).
  ## They come down in the same game-boy-test-roms bundle as the APU half and
  ## use the same mooneye LD B,B + Fibonacci verdict, so they cost nothing to
  ## fetch and nothing to interpret — they were simply never wired up, because
  ## `build_samesuite_apu_tests` globs only `apu/`.
  ##
  ## Unlike the APU half these are NOT sample-accurate audio tests, so they
  ## belong in the default run rather than behind --apu. All of them are CGB
  ## (GBC HDMA/GDMA, CGB palette-index blocking, CGB interrupt timing).
  ##
  ## `sgb/` is the exception: those two ROMs test the Super Game Boy packet
  ## protocol, so they name a DEVICE the way the shootout does and run with
  ## --sgb rather than --cgb (an SGB has no CGB in it, and a CGB ignores the
  ## packet stream, so scoring them on a CGB would score a different machine —
  ## the same reason the AGE `ncm*` (CGB-in-non-CGB-mode) images are skipped).
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

proc is_cgb_model(m: string): bool =
  ## Which --model tokens name a machine that boots as a CGB. AGB/AGS are CGB
  ## silicon in a different package (the suite's README says so outright), so
  ## they run with --cgb like any other.
  m.startsWith("cgb") or m == "agb" or m == "ags"

proc mooneye_machines_for(base: string): seq[string] =
  ## Every `--model` a mooneye/wilbertpol ROM's own filename says it should pass
  ## on. Straight out of the suite's README.markdown, "Test naming":
  ##
  ##     G = dmg+mgb    S = sgb+sgb2    C = cgb+agb+ags    A = agb+ags
  ##     "a test with GS in the name is expected to pass on dmg+mgb+sgb+sgb2"
  ##
  ## so a group token is the UNION of its letters and every member deserves a
  ## run. Before this, all nine of Gekkio's `-GS` ROMs and all seventeen of
  ## wilbertpol's scored on exactly one machine (the default DMG-ABC), and the
  ## MGB/SGB/SGB2 thirds of the claim were never checked at all.
  ##
  ## Revisions fan out only where the FILENAME names revisions — `cgbABCDE`
  ## becomes four rows, `dmgABCmgb` becomes two. A token that names only a
  ## model (`cgb`, or the `C` group) gets ONE representative revision, the
  ## default CGB-C, because the ROM is not making a per-revision claim for a
  ## row to check. That line was drawn by measurement, not taste: fanning `C`
  ## across all four modelled CGB revisions was tried on 2026-08-19 and every
  ## one of the seventeen `-C` tests returned the same verdict on all four,
  ## for 51 extra rows and no information — while the ONE thing that fan-out
  ## did find (`misc/boot_hwio-C` passing on CGB and failing on AGB) is a
  ## MODEL difference that the cgb+agb pair still catches.
  ##
  ## Revision 0 is never in a fan-out: the suite treats it as its own machine
  ## and ships separate `-dmg0`/`-cgb0` ROMs precisely because it diverges.
  ##
  ## `ags` collapses into `agb` — same SoC in a different package, again per the
  ## README — rather than inventing a machine dingbat does not model.
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
    # utils/ holds tools, not tests — the same skip the wilbertpol builder
    # makes. `bootrom_dumper` waits for a boot ROM to dump and can only ever
    # time out (docs/gb-failure-triage.md calls it unrecoverable), and
    # `dump_boot_hwio` is the opposite trap: it ends in `quit_dump_mem`, which
    # sets the success byte `ld d, $00` unconditionally, so its green row was
    # a gate that could not fail. Both are recorded in NotScored.
    if rel.startsWith("utils"):
      continue
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
    # madness/mgb_oam_dma_halt_sprites is the suite's other screenshot ROM: it
    # ships `mgb_oam_dma_halt_sprites_expected.png` beside it and targets an
    # MGB, so scoring it as a serial test on a default DMG was wrong twice and
    # produced nothing but a 1800-frame timeout. Same treatment as the
    # wilbertpol fork's row of the same name — the two bundles' ROMs are NOT
    # byte-identical (md5s differ), though their expected PNGs are, so both
    # rows are legitimate and they happen to agree today.
    if rel == "madness" / "mgb_oam_dma_halt_sprites.gb":
      tests.add(TestDef(
        name: name,
        rom_path: rom,
        mode: tmScreenshot,
        timeout: 120,
        expected_png: rom.parentDir / "mgb_oam_dma_halt_sprites_expected.png",
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
      # One row per machine the filename claims. The device comes from the
      # TOKEN, not the directory: every ROM under Gekkio's misc/ carries a
      # CGB/AGB suffix anyway, so this agrees with the old `startsWith("misc")`
      # on all eight of them while also being right for the fork below, whose
      # misc/ mixes SGB and MGB ROMs in with the CGB ones.
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
  ## Both devices. Every one of these ROMs is a DMG cart, and the suite ships a
  ## `_dmg_blob.png` for what it draws on a DMG and a `_cgb_c.png` for what the
  ## same cart draws on a CPU CGB C — which is DMG-compatibility mode: CGB
  ## timing driving a DMG picture through the boot ROM's fallback palette. The
  ## two reference sets do NOT cover the same ROMs (the seven `*2.gb` variants
  ## are CGB-only, `m3_wx_4/5/6_change` are DMG-only), which is the suite
  ## telling you where it thinks the models diverge.
  ##
  ## The CGB half is the only mid-mode-3 CGB oracle in the tree apart from
  ## gambatte. Its author's own note is the reason it is worth having: "These
  ## tests examine very specific PPU behaviour/timings, so produce different
  ## results on a DMG compared to a CGB." A change that moves the fetcher can
  ## now be read on both devices instead of one.
  ##
  ## The `cgb: true` rows are scored on the DEFAULT revision, which is `grCgbC`
  ## — the same device the `_cgb_c` captures are of. That is not a coincidence
  ## any more: as of 2026-08-10 the default was moved to CGB C partly because
  ## these references are what the tree is scored against.
  ##
  ## `_cgb_d.png` (CPU CGB D) is wired for ALL twenty ROMs that ship one, as of
  ## 2026-08-19. Thirteen of those captures are pixel-identical to their
  ## `_cgb_c` twin, and running them anyway is the point: "these two revisions
  ## draw this the same" is a claim, and a row is how it gets checked.
  ##
  ## The old reason for holding all twenty out — "~20 rows for an axis no
  ## shipping frontend can reach" — was a bad trade and it cost something real.
  ## With nothing scoring `_cgb_d`, and the shootout's own RevC/RevD mealybug
  ## variants absent from its active list, the entire revision axis was
  ## unobserved by every harness in play. `m3_scy_change` was sitting in that
  ## gap: dingbat renders the CGB-C picture at C, D **and** E and misses
  ## `_cgb_d` by 6217 pixels — a different palette attribute on 855 of them and
  ## different tile rows on the rest, so a whole revision's worth of mid-line
  ## SCY behaviour that is simply not modelled. Seven rows is a cheap price for
  ## seeing that class of defect at all.
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
        # Pinned rather than left to the default. The default IS grCgbC today,
        # so this changes no verdict — but a `_cgb_c` capture is a photograph of
        # one specific revision, and a row scored against it should name that
        # revision instead of inheriting whatever the default happens to be. It
        # also makes the Device column say "CGB cgbc" rather than a bare "CGB".
        model: "cgbc",
        no_save: true,
      ))
    # ...and the CGB-D capture, at CGB-D. ALL twenty of them, including the
    # thirteen whose picture is identical to their `_cgb_c` twin.
    #
    # Those thirteen were held out until 2026-08-19 on the grounds that a row
    # which can only restate what the `_cgb_c` row already says is pure
    # duplication. That reasoning was about the REFERENCE and it should have
    # been about the MACHINE: "CGB-C and CGB-D draw this identically" is a claim
    # the suite is making, and the only way to have coverage of it is to run
    # BOTH revisions and check. An identical capture is not a reason to skip the
    # second run — it is the expected result OF the second run, and a revision
    # that quietly stopped agreeing would otherwise go unnoticed. The seven
    # differing pairs catch a defect by disagreeing; the thirteen matching ones
    # catch a defect by ceasing to agree, and both need the row to exist.
    #
    # Still gated on the reference file existing, so the set tracks the bundle.
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
  # The bundle's other two mealybug directories, `dma/` and `mbc/`, ship no
  # reference image and upstream ships none either (its `expected/` tree is
  # ppu-only, and so is `photos/`) — which is why they were never scored. They
  # do not need one: unlike the ppu ROMs they are built WITHOUT
  # DISPLAY_RESULTS_ONLY, so `inc/base.asm` runs CompareResults against the
  # `CorrectResults` table each one carries and then falls into `Quit`, which
  # sets mooneye's Fibonacci registers (3/5/8/13/21/34) on a pass, $42 across
  # the board on a failure, and ends on LD B,B. That is exactly what tmMooneye
  # reads, so these are self-checking rows in the plainest sense.
  #
  # Both `dma/` ROMs declare REQUIRES_CGB and bail out with "CGB Required"
  # otherwise; `mbc/mbc3_rtc` is device-independent. All three run --nosave:
  # mbc3_rtc is battery-backed with an RTC, so without it the next run starts
  # from the previous run's clock, and it costs the other two nothing.
  for (group, name, cgb) in [("dma", "hdma_during_halt-C", true),
                             ("dma", "hdma_timing-C", true),
                             ("mbc", "mbc3_rtc", false)]:
    let rom = mealybug_dir / group / (name & ".gb")
    if not fileExists(rom): continue
    tests.add(TestDef(
      name: "mealybug/" & group & "/" & name,
      rom_path: rom,
      mode: tmMooneye,
      timeout: 1800,
      cgb: cgb,
      no_save: true,
    ))
  tests

const MicrotestNoVerdict = [
  # The 31 bundled GBMicrotest ROMs that never write $FF82 at all — the byte
  # `--mode=microtest` scores. With nothing written, the harness reads
  # uninitialised HRAM and the row can only ever be red: they are not failures
  # of this emulator, they are ROMs with no verdict to read.
  #
  # Method (docs/gb-failure-triage.md, "First, shrink the denominator"): every
  # one of the 513 bundled ROMs was scanned for the two encodings that can
  # write that address with an immediate operand — `E0 82` (`ldh ($82),a`) and
  # `EA 82 FF` (`ld ($ff82),a`). 482 contain one, these 31 contain neither, and
  # all 31 were already failing rows (no passing row is in this list, so the
  # scan is not hiding a green one). Listed by name rather than re-scanned at
  # runtime so the skip stays reviewable in the diff.
  #
  # Honest suite denominator: 482, not 513. Recorded in NotScored.
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
    # ROMs with no verdict byte to read — see MicrotestNoVerdict above.
    if name in MicrotestNoVerdict:
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
  # used to boot CGB from the header alone. --mode=screenshot now takes the
  # absence of --cgb as "run it on a DMG", so the device has to be named.
  let bully = roms_dir / "bully"
  add_if("bully/bully", bully / "bully.gb", bully / "bully.png", 120,
         color = true, cgb = true)

  # strikethrough (Hacktix) — OAM DMA behavior. Also a $80 (CGB-capable) cart.
  # BOTH devices are scored. The picture is one line of forty objects crossed
  # with a running OAM DMA (see obj_oam_dma_read in fifo_ppu.nim) and the two
  # references differ only in palette, so a device-specific break would show on
  # one row and not the other — which is exactly what makes the pair worth two
  # rows rather than the CGB one this table used to carry alone.
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

  # cgb-acid-hell (mattcurrie) — CGB PPU torture test, the companion to the
  # cgb-acid2 already scored above. Finishes on LD B,B.
  let hell = roms_dir / "cgb-acid-hell"
  add_if("cgb-acid-hell/cgb-acid-hell", hell / "cgb-acid-hell.gbc",
         hell / "cgb-acid-hell.png", 120, color = true, cgb = true)

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

proc age_model_for(device: string): string =
  ## The `--model=` token for one AGE device token, or "" to leave the row on
  ## the default revision.
  ##
  ## AGE names the devices a test was verified on, and some of those names are
  ## a single revision family (`-cgbE`, `-cgbBC`, `-dmgC`) that the emulator
  ## can actually be set to. Passing it through means a row named `cgbE` is
  ## scored on a CPU CGB E instead of on whatever the default happens to be —
  ## which is CPU CGB C, so today the Device column was claiming a machine the
  ## row's own name contradicts.
  ##
  ## MEASURED 2026-08-13: this changes no verdict anywhere in the suite (the
  ## five failing `-cgbE` rows still fail under `--model=cgbE`, `ly-cgbE` still
  ## passes, and the three `-dmgC` screenshot rows are pixel-identical either
  ## way). It is a labelling fix that pre-positions the rows for the day the
  ## C-vs-E differences are modelled.
  ##
  ## The accepted set mirrors gb_revision_from_name (src/dingbat/gb/gb.nim) and
  ## must stay a subset of it: dingbat_test *quits* on a token it cannot parse,
  ## so a name like `cgbBCE` — a span with no single revision behind it — is
  ## deliberately left empty rather than guessed at.
  case device.toLowerAscii()
  of "dmg0", "dmg", "dmga", "dmgb", "dmgc", "dmgabc", "mgb",
     "cgb0", "cgb0b", "cgba", "cgbab", "cgbb", "cgbc", "cgb0bc", "cgbbc",
     "cgbd", "cgbcd", "cgb", "cgbe", "cgbde", "cgbcde", "cgbabcde": device
  else: ""

proc age_models_for(device: string): seq[string] =
  ## Every DISTINCT dingbat revision an AGE device token names.
  ##
  ## AGE writes the devices a test was verified on as a span — `cgbBCE` means
  ## "B, C and E" — and `age_model_for` above can only answer with a single
  ## `--model=` token, so a span got none and the row silently ran on the
  ## default machine (CPU CGB C) while its name claimed three. That is a real
  ## coverage hole: the revision the row is scored on is the one thing its name
  ## is most explicit about.
  ##
  ## dingbat models five CGB revisions (`grCgb0, grCgbAB, grCgbC, grCgbD,
  ## grCgbE`), so `cgbBCE` covers three of them and becomes three rows. The DMG
  ## side needs no expansion: dingbat models `grDmg0` and `grDmgABC`, so a DMG
  ## span already IS one machine.
  ##
  ## An unrecognised character falls back to the single-token behaviour rather
  ## than guessing, because dingbat_test QUITS on a token it cannot parse.
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
        let models = age_models_for(device)
        # A span becomes one row per revision it names; the suffix is added
        # only when there is more than one, so single-revision rows keep the
        # name their baseline is recorded under.
        for m in (if models.len == 0: @[""] else: models):
          var t = shot("age/" & rel & "-" & device &
                       (if models.len > 1: "@" & m else: ""),
                       rom, png, timeout = 120, color = cgb, cgb = cgb)
          t.model = m
          tests.add(t)
      continue
    let devices = age_device_tokens(base)
    let dmg = devices.anyIt(it.startsWith("dmg"))
    let cgb = devices.anyIt(it.startsWith("cgb"))
    if not dmg and not cgb:
      continue   # ncm-only: CGB in non-CGB mode, which this harness cannot run
    # ONE ROW PER MACHINE THE NAME DECLARES. `ei-halt-dmgC-cgbBCE` is verified
    # on four machines and now runs on four; before, it ran on ONE (DMG at the
    # default revision) and the other three tokens were decoration. Both halves
    # of that were wrong: the CGB arm was never run at all, and the CGB span
    # got no `--model` because it names three revisions and `age_model_for`
    # can only answer with one — so the row silently used CPU CGB C while its
    # name claimed B, C and E.
    #
    # Failing AGE rows stop at LD B,B rather than burning the 1800-frame
    # timeout (see bb_breakpoint below), so the extra arms cost little wall
    # clock.
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
        model: m,
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
    # DMG/SGB.
    #
    # The suffix is the ONLY thing that picks the device, including under misc/.
    # Gekkio's misc/ really is a CGB-only directory, but this fork's is not: it
    # also holds `boot_hwio-S`, `boot_regs-mgb`, `boot_regs-sgb` and
    # `boot_regs-sgb2`. Blanketing the directory with --cgb ran those four as a
    # CGB wearing an SGB/MGB boot table — a machine that does not exist, and it
    # printed as such in the Device column ("CGB sgb"). `boot_hwio-S` failed
    # purely because of it (the Gekkio builder passes the same ROM name with
    # model=sgb and no --cgb, and it passes there).
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
      # Same per-machine fan-out as the Gekkio builder above, and the same
      # reason it belongs here in particular: this fork's misc/ is the one that
      # mixes machines, so the suffix has to be what picks the device.
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
  ## The per-pixel luma tolerance gbdev's own runner uses for these reference
  ## images (`util.py: compareImage`, "if color > 50: return False"). Scoring
  ## its images by any tighter rule than the one it publishes them under would
  ## measure our colour conversion rather than the emulator; see
  ## `grey_tolerance` on TestDef.

proc ensure_shootout_file(rel: string): string =
  ## One file out of gbdev/GBEmulatorShootout's committed `testroms/` tree,
  ## pinned to ShootoutRev.
  ##
  ## Four of the shootout's suites exist nowhere else as a distributable
  ## artifact — daid's and CasualPokePlayer's ROMs are only ever published in
  ## that repo, `which.gb` likewise, and its rtc3test ROMs are custom builds
  ## (see build_shootout_tests). So they are fetched file-by-file from
  ## raw.githubusercontent at a fixed commit, exactly as FuzzARM is: ~30 small
  ## files totalling under a megabyte, which is far cheaper than the repo's
  ## 32 MB `testroms/` archive and pins the reference images just as tightly.
  let dir = RomCacheDir / ("shootout-" & ShootoutRev[0 ..< 7])
  let path = dir / rel
  if fileExists(path):
    return path
  createDir(path.parentDir)
  download_file("https://raw.githubusercontent.com/gbdev/GBEmulatorShootout/" &
                ShootoutRev & "/testroms/" & rel, path)
  path

proc build_shootout_tests(): seq[TestDef] =
  ## The suites the gbdev shootout runs that are not in any bundle we already
  ## download. Every one is scored the way the shootout scores everything: the
  ## frame after a fixed run, against a committed reference image.
  ##
  ## Frame counts are the shootout's own `runtime=` seconds x 60, which is what
  ## its `Test` objects feed each emulator.
  var tests: seq[TestDef]
  echo "Downloading shootout test ROMs..."

  # --- ax6/rtc3test (MBC3 RTC) -------------------------------------------
  # rtc3test upstream is ONE ROM with a three-way menu picked by button input
  # (A / down-A / down-down-A), which is why it was previously listed as
  # unscoreable here: dingbat_test has no input scripting. The shootout ships
  # three separate 32 KB builds, one per sub-test, with the menu resolved at
  # build time — so the input problem simply does not arise and no parser needs
  # porting from dingbat_bench. This is real MBC3 RTC coverage, which dingbat
  # implements and nothing else in the runner exercises.
  #
  # The shootout runs all three as CGB, and these carts are CGB-capable
  # ($143 = $80) so they boot CGB from the header anyway — `cgb` here is
  # belt-and-braces. Their references are genuinely native-CGB captures (they
  # contain #009100, which is not in the CGB-compatibility palette), so unlike
  # mealybug's CGB set these really do measure dingbat's CGB.
  for (n, secs) in [(1, 9.5), (2, 7.5), (3, 20.0)]:
    tests.add(TestDef(
      name: &"rtc3test/rtc3test-{n}",
      rom_path: ensure_shootout_file(&"ax6/rtc3test-{n}.gb"),
      mode: tmScreenshot,
      grey_tolerance: ShootoutTolerance,
      timeout: int(secs * 60),
      expected_png: ensure_shootout_file(&"ax6/rtc3test-{n}.png"),
      cgb: true,
      color: true,
      # Battery-backed RTC cart: without this it drops a .sav into the shared
      # cache dir and the next run starts from the previous run's clock.
      no_save: true,
    ))

  # --- CasualPokePlayer's MBC3 tests -------------------------------------
  # More MBC3 corners: invalid RTC bank numbers, the single-write latch, and
  # the width of the RAM-enable register. DMG, half a second each.
  # `sgb-ext-test` is skipped — it is an SGB packet-protocol test and the
  # shootout runs it on an SGB, which dingbat does not model.
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

  # --- daid's tests ------------------------------------------------------
  # STOP-instruction and speed-switch behaviour, plus a mid-scanline BGP probe.
  #
  # Only the rows worth gating on are wired up. The shootout also runs
  # `ppu_scanline_bgp`, `stop_instr` and `stop_instr_gbc_mode3` "on GBC", but
  # all three carts are DMG-flagged ($143 = $00), so that is a CGB in
  # **compatibility mode** — the same mode the mealybug `_cgb_c` references
  # capture. That mode IS modelled here (see `cgb_native` in gb.nim, and
  # build_mealybug_tests, which scores 27 rows against it), so the first two are
  # skipped as redundant rather than as unmodellable: mealybug covers the same
  # machine far more precisely. `ppu_scanline_bgp.gbc.png` is visibly a compat
  # capture — its only colours are #0063C6/#7BFF31/#FFFFFF, straight out of the
  # compat background palette. The third, `stop_instr_gbc_mode3`, IS wired —
  # see below.
  #
  # "The same machine" was measured in 2026-08-09 and it is NOT the same
  # machine, which was the reason for leaving `ppu_scanline_bgp` "(GBC)" out.
  # Run it `--cgb --color` and every band of the frame is exactly 3 pixels
  # early against that PNG (92.50%), and the 3 decompose as one M-cycle at the
  # handler's entry MINUS one dot of palette write step — and that one dot is
  # the CGB-C/CGB-D revision split, which mealybug ships both sides of:
  # `CGB_MIXER_LATENCY=1` is pixel-exact on `m3_bgp_change_cgb_c.png` and `=0`
  # is pixel-exact on `_cgb_d.png`, and only `=0` can reach daid's capture.
  #
  # **That reason expired when the revision axis landed, and the row is wired
  # now (2026-08-18).** It does not put two references for one register on
  # opposite sides of a revision any more, because the row NAMES its revision:
  # `--cgb --model=cgbe` is exactly what the shootout's adapter passes, and at
  # it the frame is pixel-exact while the 27 mealybug rows keep scoring the
  # default CGB-C. Leaving it out had a cost that showed up the day it
  # mattered: `CGB_HALT_PPU_LEAD=1` was measured, run through the whole local
  # suite with NO regressions, committed and pushed — and it takes this row
  # from 0 px to 2304 at every one of the six revisions. It is a silicon
  # reference the shootout scores and nothing here gated it. See
  # docs/gb-failure-triage.md and CGB_HALT_PPU_LEAD in gb.nim.
  #
  # `stop_instr` "(GBC)" is the trap worth naming, because it would have gone
  # in GREEN for the wrong reason. Its reference is an all-black frame, which is
  # also what a blanked panel produces however STOP got there, so the row cannot
  # distinguish a correct implementation from several wrong ones. A gate that
  # cannot fail is worse than no gate.
  #
  # `rom_and_ram.gb` is skipped for a different reason: it ships no reference
  # image at all (the shootout classes it INFO, not pass/fail).
  #
  # Mid-scanline BGP writes have three legitimate DMG outcomes (old palette,
  # new palette, or their OR — which one you get is per-console), so the
  # shootout accepts any of the three images and so does this row.
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
  # The same ROM on a CGB in compatibility mode, at the revision its capture is
  # of. One reference, no alternates: unlike the DMG arm this frame has a single
  # legitimate outcome. `model: "cgbe"` is the passthrough and `--cgb --model=
  # cgbe` is what the shootout adapter runs; the row is pixel-exact there and
  # nowhere else (2304 px at every other revision). See the note above for why
  # it was held out until 2026-08-18 and what leaving it out cost.
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
  # The mode-3 sibling is the one GBC daid row that IS worth gating on, and the
  # exception to the paragraph above. Same DMG-flagged cart on a CGB, but its
  # reference is not a blank panel: the ROM prints "LCD on: PASS" and only then
  # spins until STAT reads mode 3 before executing STOP, and daid's own note
  # says a mode-3 STOP on a CGB "will keep the screen displaying the same data,
  # as the PPU keeps running, and during mode3 it can access VRAM". So the
  # reference is the text still on screen, and an implementation that blanks the
  # panel — the DMG behaviour, and the one `stop_instr.gbc.png` cannot tell
  # apart — scores 1.1% against it. Measured 2026-08-13: dingbat is pixel-exact
  # here even at tolerance 0, so unlike `ppu_scanline_bgp` (GBC) there is no
  # CGB-revision split hiding in it. See docs/gb-test-suite-sources.md §1.5.
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
  # The speed-switch trio: a STOP-driven double-speed switch must reset DIV,
  # and must land LY and STAT where hardware does. These three ARE native CGB
  # carts ($143 = $C0), so unlike the rest of daid's set they measure the
  # machine dingbat actually implements.
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

  # `acid/which.gb` is deliberately absent. The shootout lists it twice (DMG
  # and CGB) but ships no reference image for it, so its own `Test` scores it
  # INFO rather than PASS/FAIL — it exists to be eyeballed in the results table,
  # and there is nothing here to gate on.
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

# DenSinH/FuzzARM (GPL-3.0). Five prebuilt ROMs are committed to the repo's
# master branch; there is no release tag, so the download is pinned to a commit
# the same way jsmolka is. Bump this SHA and the ROM cache key in
# .github/workflows/test.yml together.
#
# The ROMs are *randomly generated at build time*: the instruction mix, the
# operands and therefore the expected values are all specific to this SHA. A
# new SHA means a different 10000 tests, so the committed pass/fail baseline in
# tests/results.md is only meaningful for this pin. Re-baseline on a bump.
const FuzzArmRev = "a675329cd57da48e3e406216ba2d79dd7e09ee20"

const FuzzArmRoms = ["ARM_DataProcessing", "ARM_Any",
                     "THUMB_DataProcessing", "THUMB_Any", "FuzzARM"]

proc ensure_fuzzarm_test_roms(): seq[string] =
  ## Fetch (and cache) the five prebuilt FuzzARM ROMs at the pinned commit.
  ## They live at the repo root, not in a release archive, so each is pulled
  ## individually from raw.githubusercontent.com — no zip, nothing to build.
  ## The short SHA is in the cached filename so a bump can't reuse stale ROMs.
  var paths: seq[string]
  for rom in FuzzArmRoms:
    paths.add(ensure_rom_download(
      "https://raw.githubusercontent.com/DenSinH/FuzzARM/" & FuzzArmRev &
        "/" & rom & ".gba",
      "fuzzarm-" & FuzzArmRev[0 ..< 7] & "-" & rom & ".gba"))
  paths

proc build_fuzzarm_tests(paths: seq[string]): seq[TestDef] =
  ## Each ROM is 10000 randomized instruction tests. --mode=fuzzarm drives the
  ## ROM's own "press a button to continue" gate so it reports EVERY failing
  ## test, not just the first, and reads the verdict out of the structured
  ## 16-word dump the ROM leaves at the base of eWRAM — so no BIOS, no PPU and
  ## no pinned frame hash sits between the CPU and the score. The per-failure
  ## detail (instruction, shift, operands, got vs expected r3/r4/CPSR) and a
  ## rollup by failure class go to stderr; stdout is the one-line tally that
  ## lands in results.md.
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

# alloncm/MagenTests (MIT). Tagged releases ship the assembled .gbc files, so
# this pins a release tag rather than a commit. Covers CGB corners nothing else
# dingbat runs touches: HBlank VRAM DMA (including that it must stop while the
# CPU is halted), the KEY0 lock after boot, STAT's reported mode while the PPU
# is off, and MBC1/3/5 out-of-bounds SRAM addressing.
const MagenRelease = "0.5.0"

proc build_magen_tests(): seq[TestDef] =
  ## Verdict is the screen colour, per src/common.asm's palette and each
  ## test's README entry — see the mode comment in dingbat_test.nim for why
  ## this is NOT a screenshot comparison (the repo ships no 160x144 reference
  ## image; images/ is upscales, swatches and a photo of real hardware).
  ##
  ## oam_internal_priority is deliberately absent: it draws a pattern whose
  ## only stated criterion is prose ("2 pairs of rectangles connected or
  ## touching each other"), red is a legitimate colour in it, and the only
  ## reference is a 318x295 SameBoy window grab. There is nothing to score it
  ## against that would not just be a golden of dingbat's own output.
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

# Deliberately a seq, not a fixed-size array: it used to be `array[16, ...]`
# and every entry added or removed here meant editing the bound too, which is
# a compile error waiting to happen for no benefit.
const NotScored: seq[(string, string)] = @[
  # The page's own record of every deliberate skip, so "why isn't X here?"
  # is answerable from the page itself instead of from runner comments.
  # Keep in sync with the skip sites (each entry names its builder).
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
  ("gambatte `_outaudio0/1` rows (220) + the AGB column", "audio-register " &
    "sampling and the AGB device are not scored; see results_gambatte.md's " &
    "source notes. (build_gambatte_rows)"),
  ("gbmicrotest: 31 ROMs that never write the $FF82 verdict byte", "scanned " &
    "all 513 bundled ROMs for `ldh ($82),a` / `ld ($ff82),a`; 482 contain one " &
    "and these 31 contain neither, so the harness would be scoring " &
    "uninitialised HRAM rather than a result. All 31 were failing rows before " &
    "the skip. The honest suite denominator is 482. " &
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
  ## One line of "what produced this file": timestamp, the commit the runner
  ## ran at (best-effort — absent outside a git checkout), and the ROM-bundle
  ## version, so a stale page is recognizable as stale.
  result = "*Generated: " & now().format("yyyy-MM-dd HH:mm:ss")
  let (sha, code) = execCmdEx("git rev-parse --short HEAD", options = {poUsePath})
  if code == 0 and sha.strip().len > 0:
    result.add(" \xC2\xB7 commit " & sha.strip())
  result.add(" \xC2\xB7 game-boy-test-roms " & GbBundleVersion & "*")

proc row_detail(r: TestResult): string =
  ## The Result-cell text after the emoji. Aggregated rows always carry their
  ## pass count (the regression gate compares it); every other failing row
  ## carries its harness output — flattened to one bounded line so the table
  ## survives — because a bare eyes-emoji row gives a reader nothing to act
  ## on, and output that used to be silently dropped ("size mismatch: ...")
  ## made a failing row look no different from a healthy one.
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
    # A section where everything passes says so in one line instead of
    # hundreds of identical thumbs-up rows — most of this file was that.
    #
    # Nothing is lost to the regression gate. load_previous_results reads the
    # `(<pass>/<total>)` in the header line directly above and records the
    # section as all-passing, and run_suite treats "absent from the baseline
    # but in a section that was all-passing" as "was passing" rather than as
    # "new, therefore ungated". Aggregated rows are safe here too: they only
    # ever pass at 100% (`67/67 passed`), so in an all-pass section every count
    # is already at its maximum and any drop turns the row red, which the
    # boolean gate catches even though the collapsed section carries no counts
    # for load_previous_counts to read. The moment ONE row fails, the whole
    # table comes back and every row is individually keyed again.
    if suite.results.len > 0 and p == suite.results.len:
      lines.add("**All " & $p & " tests passed.**")
    else:
      lines.add("| Test | Device | Result |")
      lines.add("|------|--------|--------|")
      for r in suite.results:
        let emoji = if r.passed: "\xF0\x9F\x91\x8C" else: "\xF0\x9F\x91\x80"
        let dev = if r.device.len > 0: r.device else: "\xE2\x80\x94"
        # The row name is the FULL test name, suite prefix included. It is the
        # key the regression comparison reads back (load_previous_results), and
        # with ~20 suites in here — several of them forks of each other, e.g.
        # mooneye vs mooneye-wilbertpol, blargg/mem_timing vs mem_timing-2 —
        # anything shorter collides across suites and silently mis-keys the gate.
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
  ## passing in the baseline". It lives in the same table as the per-test
  ## entries rather than in a second one so that every existing run_suite call
  ## site keeps working unchanged; the NUL prefix is what keeps it from ever
  ## colliding with a real test name, which cannot contain one.
  "\0suite-all-passed\0" & suite_name

proc was_passing(previous: Table[string, bool];
                 suite_name, test_name: string): bool =
  ## Did the committed baseline have this row green?
  ##
  ## A name the baseline does not carry is normally ungated — that is how a
  ## newly added suite avoids reporting every row as a regression on its first
  ## run. The exception is a section the baseline COLLAPSED because everything
  ## in it passed: there, absence means "was green", not "unknown".
  ##
  ## Every regression gate in this file must go through here. There are four of
  ## them and they do NOT share a code path (run_suite, run_microtest_suite,
  ## run_mgba_suite and the gambatte group loop each roll their own), so fixing
  ## only the obvious one leaves the other three silently disarmed for exactly
  ## the sections that collapse. That was the state this proc was written to
  ## end, and it was caught by faking an all-pass GBMicrotest baseline and
  ## watching 52 real failures come back as zero regressions.
  if test_name in previous: previous[test_name]
  else: previous.getOrDefault(suite_allpass_key(suite_name))

proc load_previous_results(path: string): Table[string, bool] =
  ## The committed baseline, keyed by the full test name exactly as
  ## generate_results_md writes it. A name that is not in the table (a suite
  ## added since the baseline was committed) is simply not gated — which is why
  ## the baseline has to be regenerated and committed whenever suites are added.
  ##
  ## Sections that were entirely green are collapsed to "All N tests passed."
  ## and have no rows to read, so their `## <name> (<pass>/<total>)` header is
  ## the record instead: it is stored under suite_allpass_key and run_suite
  ## falls back to it. Without that, collapsing a section would quietly turn
  ## its regression gate off — the opposite of what a green section deserves.
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
  ## The results.md Device column: which hardware the row is scored on.
  ## "cart" means no override — the cart header picks the device, which
  ## resolves to DMG-ABC for a DMG cart and CPU CGB C for a CGB one (see
  ## gb_set_revision). A --model token rides along after the base, so the
  ## column also exposes contradictions (a row asking for --cgb AND an SGB
  ## boot table prints as "CGB sgb"). GBA rows have no device axis.
  if t.mode in {tmMgba, tmMgbaSuite, tmJsmolka, tmFuzzArm}:
    return ""
  # ...and neither does a GBA ROM scored by SCREENSHOT. jsmolka's ppu/ and nes/
  # ROMs are compared by frame hash rather than by its own pass protocol, so
  # they arrive here as tmScreenshot and used to fall into the DMG fallback
  # below — printing "DMG" against four .gba rows. The mode does not identify
  # the machine; the ROM does.
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
  ## Runs `list_lines` through one `--mode=<mode> --list=<file>` process per
  ## core and returns, per input line, the verdict its shard reported — the
  ## remainder of the `<prefix> <local index> <...>` line the harness wrote,
  ## or "" if no verdict came back for it.
  ##
  ## This exists because two suites (gambatte, GBMicrotest) are thousands of
  ## runs whose per-ROM emulation is far cheaper than a fork/exec. Splitting
  ## them cannot change a verdict: every list entry builds a fresh emulator and
  ## none of them write files.
  ##
  ## Spawn rule, which is the whole reason this is one shared proc: real argv,
  ## no shell, no redirection, and `--out` so the CHILD opens its own verdict
  ## file. Do NOT rebuild this as a command string ending in `> out.txt 2>&1`.
  ## Nim's poEvalCommand is `/bin/sh -c` on POSIX but goes straight to
  ## CreateProcessW on Windows, where those tokens are not redirection but
  ## three more argv entries — the verdicts then land in a pipe that nothing
  ## drains, every shard blocks on a full buffer, and the job hangs until it is
  ## killed. That cost the Windows CI job six hours a push (see 23dcae4).
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
  ## GBMicrotest, batched. 513 ROMs that each run for two frames: a process
  ## apiece made spawn+load the whole cost (11.2s of the runner's 31s locally,
  ## and process creation is dearer on Windows). Same rows, same verdicts, one
  ## process per core. These ROMs are `no_save` and write nothing, so there is
  ## no state for concurrent entries to race.
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
  # The suite ROM tracks mattrbeck/mgba-suite-auto's LATEST release rather than
  # a pinned tag, at the maintainer's request. That URL is a moving target, so
  # the sha1 below is what tests/results_mgba_suite.md was baselined against
  # and a mismatch is reported loudly — otherwise a new upstream release would
  # silently re-baseline the whole section and look like an emulator change.
  # It is a warning, not a failure: the runner still scores the ROM it got.
  #
  # When it does move, rebaselining is part of the same commit as the bump
  # here, and the row COUNT can change as well as the scores (going from v1.0
  # to this build, DMA went 1256 -> 1244 as two DMA0 wrap-around tests were
  # de-flaked, and Misc 10 -> 12 as "DMA count latching" was added). Also bump
  # `suite<n>` in the rom-cache `key:` in .github/workflows/test.yml — that key
  # is exact-match, so a stale key serves the OLD ROM from cache and the change
  # looks like a no-op.
  #
  # Note the Misc "H-blank bit start" Flip rows measure dingbat's idle-loop
  # SKIP RESOLUTION, not its PPU timing: they spin on DISPSTAT and the waitloop
  # fast-forward resolves the edge at whatever bound it was given, so they move
  # by a whole quantum whenever anything shifts the loop's phase. The "Hblank"
  # row is different and is a real defect — see docs/mgba-suite-verdicts.md.
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
          # misc-edge.c is the one suite source whose doResult call passes
          # (expected, value) where every other file passes (value, expected),
          # so for this section alone the ROM's own constant is printed as
          # "Got" and OUR measurement as "vs". Un-swap it here rather than
          # print the table backwards (see docs/mgba-suite-verdicts.md).
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
  # frames (a few ms), and there are thousands of them. run_sharded_batch puts
  # them through one --mode=gambatte process per core. Rows are independent —
  # each builds a fresh GB — so the split cannot change a verdict;
  # `tests/README.md` records how that was verified.
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
    # Regression on either bit: a group that used to be all-green going red, or
    # a group whose pass COUNT dropped. Key on `short_name`, the FULL row name:
    # that is what generate_results_md writes and what load_previous_results /
    # load_previous_counts read back. Keying on the bare group name here reads
    # an empty table and silently ungates all 48 rows.
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

  # --apu (or --suite=apu) is a fast-iteration filter: it runs ONLY the GB APU
  # suites and prints tallies without touching any results file. The same
  # three suites are also part of the default run below — they used to be
  # opt-in-only, which meant 94 cases (blargg dmg_sound/cgb_sound, SameSuite
  # apu/) never ran in CI and had no written record at all.
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

  # GBMicrotest (HRAM verdict byte)
  # Batched rather than a process per ROM — see run_microtest_suite. Same rows
  # and same verdicts as run_suite would produce, which is gated by results.md
  # coming back byte-identical.
  all_suites.add(run_microtest_suite("Game Boy - GBMicrotest",
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

  # SameSuite dma/ppu/interrupt (mooneye-style verdict); these do not need
  # the audio path at all.
  all_suites.add(run_suite("Game Boy - SameSuite",
    build_samesuite_core_tests(gb_test_roms_dir / "same-suite"),
    harness, previous, regressions))

  # SameSuite apu/ — sample-accurate APU tests (also reachable alone via --apu)
  all_suites.add(run_suite("Game Boy - SameSuite APU",
    build_samesuite_apu_tests(gb_test_roms_dir / "same-suite"),
    harness, previous, regressions))

  # The gbdev shootout's own ROMs: rtc3test, CasualPokePlayer's MBC3 tests and
  # daid's STOP/speed-switch tests (screenshot comparison)
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
