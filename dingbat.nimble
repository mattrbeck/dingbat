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

task test_timestretch, "Run the WSOLA time-stretch unit test":
  exec "nim c -r -d:release --path:src -o:dingbat_ts_test tests/timestretch_test.nim"

task test_ppucomposite, "Run the GBA PPU compositor invariant tests":
  exec "nim c -r -d:release --path:src -o:dingbat_ppucomposite_test tests/ppucomposite_test.nim"

task test_savestate_compat, "Run the save-state format compatibility guards":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_savestate_compat_test tests/savestate_compat_test.nim"

task test_cheats, "Run the cheat-engine unit + integration tests":
  exec "nim c -r -d:release --path:src -o:dingbat_cheat_test tests/cheats_test.nim"
  exec "nim c -r -d:release --path:src -o:dingbat_cheat_int_test tests/cheats_integration_test.nim"
