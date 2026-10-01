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
task test_mp2kpass, "Run the MP2K HLE pass-detection and level-control tests":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_mp2kpass_test tests/mp2k_pass_test.nim"

task test_ppuobjlist, "Run the GBA per-line OBJ candidate list differential fuzz":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_ppuobjlist_test tests/ppuobjlist_test.nim"

task test_savestate_compat, "Run the save-state format compatibility guards":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_savestate_compat_test tests/savestate_compat_test.nim"

task test_gbartc, "Run the GBA cartridge RTC + battery-save RTC trailer tests":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_gbartc_test tests/gba_rtc_test.nim"

task test_ndsspu, "Run the DS ARM7 sound (SPU) tests":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_ndsspu_test tests/nds_spu_test.nim"

task test_ndssystem, "Run the DS system device tests (maths unit, RTC, save chip, IPC, card)":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_ndssystem_test tests/nds_system_test.nim"

task test_nds3d, "Run the DS 3D engine tests (command scenes + the 3d_* test ROMs)":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_nds3d_test tests/nds_3d_test.nim nds3d_out"

task test_ndshlebios,"Run the DS HLE BIOS SWIs against the real BIOS (or computed expectations)":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_ndshlebios_test tests/nds_hle_bios_test.nim"

task test_ndsboot, "Run the DS boot tests (card KEY1/KEY2 handshake, secure area, direct boot)":
  exec "nim c -r -d:test_harness -d:release --path:src -o:dingbat_ndsboot_test tests/nds_boot_test.nim"

task ndsref_build, "Build the DS reference tools (tools/ndsref: a headless libretro runner, and ndsrun beside it)":
  exec "sh tools/ndsref/build.sh"
  exec "nim c -d:test_harness -d:release --hints:off --path:src -o:tools/ndsref/ndsrun tools/ndsrun.nim"

task test_desktop, "Run the desktop frontend tests (input, settings, link, saves, game loading, modals)":
  # modal drives Dear ImGui headless, so it needs imguin (CI's test job
  # installs it: .github/scripts/install-test-deps.sh).
  for t in ["input", "settings", "netlink", "persist", "lifecycle", "modal"]:
    exec "nim c -r -d:test_harness -d:release --path:src " &
         "-o:dingbat_desktop_" & t & "_test tests/desktop_" & t & "_test.nim"

task statefuzz_build, "Build the hostile-input save-state fuzzer":
  # Run by hand, not in the suite (minutes per core): `./statefuzz <rom>
  # sweep 255` exits non-zero on any uncontained Defect.
  exec "nim c -d:test_harness -d:release --path:src -o:statefuzz tools/statefuzz.nim"

task test_rewind, "Run the rewind-ring property tests (IDs, eviction, keyframes)":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_rewind_test tests/rewind_test.nim"

task test_gbapurebase, "Run the GB APU deadline checks across the per-frame scheduler rebase":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_gbapurebase_test tests/gbapu_rebase_test.nim"

task test_psgagb, "Run the PSG's AGB-only checks (the SP's answers) on both cores":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_psgagb_test tests/psg_agb_test.nim"

task test_ndscpu, "Run the DS CPU interpreter's one-instruction checks (ARM9 and ARM7)":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_ndscpu_test tests/nds_cpu_test.nim"

task test_statesoak, "Run the range-checked serialize-while-running soak (both cores)":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_state_soak_test tests/state_soak_test.nim"

task test_cyclelaws,"Hold the core to the cycle laws recorded from an AGB SP":
  exec "nim c -r -d:test_harness -d:release --path:src " &
       "-o:dingbat_cyclelaws_test tests/cyclelaws_test.nim"

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
