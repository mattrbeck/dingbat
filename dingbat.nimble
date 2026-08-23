# Package
version = "0.1.0"
author  = "Matthew Beck"
description = "A GBA/GBC emulator"
license = "MIT"

srcDir = "src"
bin    = @["dingbat"]

# Dependencies
requires "nim >= 2.0.0"
requires "sdl2 >= 2.0.4"
requires "imguin"
requires "yaml"
requires "stb_image"
requires "zippy"

task wasm, "Build the WASM/Emscripten target":
  exec "nim c -d:emscripten src/dingbat_wasm.nim"

task test_build, "Build the test harness":
  exec "nim c -d:test_harness -d:release --path:src -o:dingbat_test tests/dingbat_test.nim"
  exec "nim c -d:test_harness -d:release --path:src --path:tests -o:dingbat_test_runner tests/dingbat_test_runner.nim"

task bench_build, "Build the headless benchmark harness":
  exec "nim c -d:test_harness -d:release --path:src -o:dingbat_bench tests/dingbat_bench.nim"

# Every test task builds with -d:test_harness: it stops nim.cfg from adding
# the GUI SDL2/OpenGL link flags, which only resolve on a machine with the
# SDL2/GL dev libraries installed. Keep it on when adding a task.
task test_timestretch, "Run the WSOLA time-stretch unit test":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_ts_test tests/timestretch_test.nim"

task test_ppucomposite, "Run the GBA PPU compositor invariant tests":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_ppucomposite_test tests/ppucomposite_test.nim"

task test_ppubgunpack, "Run the 4bpp BG tile-unpack equivalence tests":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_ppubgunpack_test tests/ppubgunpack_test.nim"
task test_ppuobjlist, "Run the GBA per-line OBJ candidate list differential fuzz":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_ppuobjlist_test tests/ppuobjlist_test.nim"

task test_savestate_compat, "Run the save-state format compatibility guards":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_savestate_compat_test tests/savestate_compat_test.nim"

task statefuzz_build, "Build the hostile-input save-state fuzzer":
  # Run by hand, not in the suite (minutes per core): `./statefuzz <rom>
  # sweep 255` exits non-zero on any uncontained Defect.
  exec "nim c -d:test_harness -d:release --path:src -o:statefuzz tools/statefuzz.nim"

task test_rewind, "Run the rewind-ring property tests (IDs, eviction, keyframes)":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_rewind_test tests/rewind_test.nim"

task test_clipreplay, "Run the clip-capture replay determinism tests":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_clipreplay_test tests/clip_replay_test.nim"

task test_printer, "Run the Game Boy Printer protocol unit tests":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_printer_test tests/gb_printer_test.nim"

task test_lcdresponse, "Run the LCD panel-response model invariants":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_lcdresponse_test tests/lcdresponse_test.nim"

task test_cheats, "Run the cheat-engine unit + integration tests":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_cheat_test tests/cheats_test.nim"
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_cheat_int_test tests/cheats_integration_test.nim"

task test_sgb, "Run the Super Game Boy acceptance test (packets, palettes, border)":
  exec "python3 tests/roms/sgbtest.py"
  exec "nim c -r -d:test_harness -d:release -d:sgb_png --path:src " &
       "-o:dingbat_sgb_test tests/sgb_test.nim"
