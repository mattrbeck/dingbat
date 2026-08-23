# iOS: what is proven and how to build it

`docs/ios-experiment/build-ios-core.sh` reproduces every build below;
`ios_core_api.nim` is the C API wrapper; `driver.c` a minimal consumer.
`src/dingbat_ios.nim` is the in-tree entry point.

## Proven

* The SDL-free core cross-compiles to arm64 iOS with no source changes:

  ```
  nim c --os:ios --cpu:arm64 --cc:clang -d:test_harness -d:release --path:src \
    --passC:"-isysroot $IOS_SDK -target arm64-apple-ios15.0" \
    --passL:"-isysroot $IOS_SDK -target arm64-apple-ios15.0" tests/dingbat_test.nim
  ```

  (`LC_BUILD_VERSION platform 2 minos 15.0`.) The simulator build runs the
  full mGBA suite with scores identical to macOS.
* `--app:staticlib --noMain` produces `libdingbat_core.a` (~1.4 MB) whose
  C API (`dingbat_init` runs `NimMain`, `dingbat_load_rom`,
  `dingbat_run_frame`, `dingbat_framebuffer` + size/static flags,
  `dingbat_set_input`, `dingbat_is_stopped`, `dingbat_flush_save`) links
  with plain `clang -isysroot $SIM_SDK` — i.e. how an Xcode target consumes
  it — and emulates at ~15–18x realtime in the simulator (host CPU; an upper
  bound for a phone).
* Pin `--mm:arc --threads:off` explicitly and add `-d:noSignalHandler`: a
  build invoked outside the repo root misses `nim.cfg` and silently falls
  back to orc/threads:on.
* Package device + simulator libs as an XCFramework with a small header.

## The core is already iOS-shaped

Single-threaded pure interpreter (no JIT — App Store guideline 4.7 allows
retro emulators since April 2024; JIT stays banned). No SDL/GL/ImGui imports
in `src/dingbat/{gba,gb,common}`; the one frontend tendril is audio output
in the two `apu.nim`, gated `test_harness` / `emscripten` / SDL. Widen the
`emscripten` branch to an `ios_shell` define to reuse the float32 stereo
ring at 32768 Hz. HLE BIOS means no BIOS ships; battery saves are plain
files next to the ROM; save states are a byte buffer
(`docs/savestate_compat.md`).

## Architecture

**Native Swift shell around the static library** — how the shipped iOS
emulators are built. `CAMetalLayer` + `CADisplayLink` (BGR555 → RGBA and the
LCD colour LUT can run in the fragment shader); `AVAudioEngine` with an
`AVAudioSourceNode` pulling the ring through `AVAudioConverter`, an
`AVAudioUnitTimePitch` for pitch-preserving fast-forward, `.playback`
session category for the silent switch; a SwiftUI touch overlay built to the
web gamepad's layout plus `GCController`; ROMs via the document picker and
UTI registration, saves in Documents (visible in Files). Flush saves on
`scenePhase` background.

Rejected:

* **WKWebView around the web build.** Wasm runs at full speed there (the
  WebContent process has the JIT entitlement) and dingbat needs no
  `SharedArrayBuffer`, but IndexedDB in WKWebView is transient in practice
  (ITP's 7-day script-storage deletion applies to all WKWebView apps since
  iOS 14; eviction is per-origin all-or-nothing; `file://` origins are
  opaque), service workers need App-Bound Domains over HTTPS, audio dies
  after screen lock until the context is resumed from native lifecycle
  events, and rAF is suspended in background. Every real problem needs a
  native bridge anyway. Fine as a days-long demo.
* **SDL2 port of the desktop frontend.** The desktop presenter is
  `#version 330 core` GLSL (not on iOS) and the ImGui interaction model is
  desktop-shaped, so it is the same rewrite with worse tools; SDL2's iOS
  audio ignores requested rates and freezes across interruptions.

Compliance: ship no ROMs/BIOS, take user files through the picker (no
downloader, which triggers 4.7.1–4.7.5), no Nintendo imagery in store assets
(use the bundled homebrew demo).

## Unknowns

* No physical-device run yet (signing identity needed); jetsam limits and
  Nim's page allocator under memory pressure (`-d:nimAllocPagesViaMalloc` is
  the fallback) are untested on device.
* Real iPhone throughput; the oldest-supported-device floor
  (`docs/performance.md`, "Old and constrained devices").
* Audio latency against CoreAudio buffer sizes; the 32768 Hz → hardware-rate
  conversion is where pacing drift would recur (`docs/web_audio_pacing.md`).
