# iOS feasibility: dingbat as an iPhone app in the style of the mobile web UI

*Investigation date: 2026-07-10. Host: macOS (Darwin 24.6), Xcode 26.2 (iOS SDK 26.2),
Nim 2.2.6. All compile experiments below were actually run on this machine; commands are
reproducible via `docs/ios-experiment/build-ios-core.sh`.*

## Executive summary

Shipping dingbat on iOS is very feasible. The emulator core cross-compiles to arm64 iOS
**with zero source changes**, passes the mGBA test suite on the iOS simulator with scores
bit-identical to macOS, and runs at ~15x realtime there. Apple's App Store guideline 4.7
has explicitly allowed retro console emulators since April 2024, and dingbat's
pure-interpreter design sidesteps the JIT ban entirely.

**Recommended architecture: #3 — a native Swift/SwiftUI shell around the Nim core built as
a C static library**, re-implementing the mobile web UI natively (Delta-style: CAMetalLayer
video, AVAudioEngine audio, SwiftUI touch gamepad). The WKWebView wrapper (#1) is a
legitimate 1-week MVP — the web build needs no SharedArrayBuffer, so the scariest WKWebView
limitation doesn't apply — but its storage-durability and audio-session quirks require
native bridging anyway, eroding most of its simplicity advantage. The SDL2 port (#2) is
the weakest option: it inherits a desktop-shaped frontend that would need a rewrite anyway
(GL 3.3 core shaders don't exist on iOS) and no shipped iOS emulator uses SDL2 as its
frontend.

Effort to a shippable App Store build with the recommended architecture: roughly
**6–10 weeks** of focused work (prototype in under a week).

---

## What exists today (relevant inventory)

### The core is already iOS-shaped

- Pure Nim, single-threaded (`--mm:arc --threads:off` per `nim.cfg`), interpreter-only
  (no JIT — this matters for App Store rules, see below).
- The core modules (`src/dingbat/gba/`, `src/dingbat/gb/`, `src/dingbat/common/`) have
  **no SDL/GL/imgui imports**. All frontend deps live in `src/dingbat.nim` and
  `src/dingbat/frontend/`. The only frontend tendril into the core is audio output in
  `src/dingbat/gba/apu.nim` / `src/dingbat/gb/apu.nim`, which is already cleanly gated
  three ways: `test_harness` (no audio), `emscripten` (push float32 stereo samples to a
  ring via an `appendAudioSample` callback), or default (SDL2 audio queue).
- HLE BIOS works (`use_hle = true` is the web default) — no copyrighted GBA BIOS needs to
  ship, which is an App Store compliance requirement.
- Battery saves are plain files: GBA writes `<rom>.sav` next to the ROM
  (`src/dingbat/gba/gba.nim:477`), GB flushes via `mbc_save` (`src/dingbat/gb/gb.nim:516`).
  Path-based persistence maps directly onto an iOS app's Documents directory.
- **Save states do not exist yet** in the core (deliberately deferred during the web UI
  redesign). Any iOS save-state feature is new core work, not porting work.

### The wasm build already defines the iOS core API

`src/dingbat_wasm.nim` exports exactly the surface a native shell needs
(emcc `EXPORTED_FUNCTIONS` in `src/dingbat_wasm.nims`):

| wasm export | purpose |
|---|---|
| `initFromEmscripten(rom_path)` | load ROM by path, pick GBA/GB by extension, HLE BIOS fallback |
| `loop_tick()` | run one frame + present |
| `benchFrames(n)` | run n frames headless |
| `setInput(id, pressed)` | digital input push (`Input` enum: UP..R = 0..9) |
| `isStopped()` | GBA Stop-mode (sleep) indicator for the UI |
| `getAudioBufferPtr/Len`, `clearAudioBuffer` | pull-style float32 stereo ring @ 32768 Hz |
| `appendAudioSample(l, r)` | APU→ring callback (provided by the wrapper) |
| `frameCount` | fps counter support |
| `setKeybindingForInput` | keyboard remap (browser-only concern) |

Notably absent from the emcc link flags: `-pthread` / `USE_PTHREADS`. And a grep of
`web/index.js`, `web/embed.js`, `web/sw.js` finds **no `SharedArrayBuffer` or
`crossOriginIsolated` usage**. The COOP/COEP headers in `web/serve.py` are precautionary,
not load-bearing. This is decisive for the WKWebView option below.

### The mobile web UI to mimic

`web/index.html` + `web/index.js` (1563 lines) + `web/styles.css` (1611 lines):

- **Home screen**: brand header, drop-zone/file-picker, recent-ROM library with
  screenshots, storage usage readout; ROMs/saves/BIOS persisted in IndexedDB.
- **Play screen**: canvas with integer scaling, top bar (menu, reset, pause,
  fast-forward, fps/SLEEPING status, volume, fullscreen), on-screen touch gamepad
  (8-way d-pad with diagonal wedges, A/B, L/R shoulders, Select/Start pills,
  multi-touch, `data-inputs` mapping to the same 0–9 input ids).
- **Menu/modals**: save import/export, screenshot, BIOS/bootrom management, keyboard
  remapping, big-d-pad accessibility toggle, update flow via service worker.
- **Audio**: `AudioContext({sampleRate: 32768})` + scheduled `AudioBufferSource` chunks
  pulled from the wasm ring each frame; `navigator.audioSession.type = "playback"` for
  the iOS silent switch; unlock-on-gesture dance.
- **Input**: touch, keyboard, and Gamepad-API polling each rAF tick.

The desktop frontend (`src/dingbat.nim`, 791 lines) uses `#version 330 core` GLSL
(lines 37/47/64/77) — OpenGL 3.3 core profile does not exist on iOS (GLES 2/3 or Metal
only), so **no path reuses the desktop presentation layer**; that's a constant across all
three options, not a differentiator.

---

## Compile experiments (all actually run)

Nimcache was isolated to `/tmp/agent-ios-cache` throughout. Reproduce with
`docs/ios-experiment/build-ios-core.sh`.

### 1. SDL-free core → arm64 iOS *device* executable: works, zero changes

```
nim c --os:ios --cpu:arm64 --cc:clang -d:test_harness -d:release --path:src \
  --passC:"-isysroot $IOS_SDK -target arm64-apple-ios15.0" \
  --passL:"-isysroot $IOS_SDK -target arm64-apple-ios15.0" \
  tests/dingbat_test.nim
```

First-try success (6.5 s, 65k lines of C). `file`/`otool` confirm a genuine iOS binary:
`Mach-O 64-bit executable arm64`, `LC_BUILD_VERSION platform 2 (iOS) minos 15.0 sdk 26.2`,
660 KB. **No source edits were needed anywhere in the core.** (Nim's stdlib `os`, `times`,
`parseopt` etc. all compiled clean against the iPhoneOS SDK.)

### 2. Simulator build → the full mGBA suite passes *on iOS*, bit-identical

Same command with the iphonesimulator SDK and `-target arm64-apple-ios15.0-simulator`,
then run inside a booted iPhone 17 Pro simulator:

```
xcrun simctl spawn booted dingbat_test_iossim /tmp/dingbat-test-roms/mgba-suite.gba \
  --mode=mgba-suite --timeout=36000   # exit 0
```

END-line scores: 1448/1552, 130/130, 183/2020, 339/936, 0/90, 140/140, 93/93, 72/72,
615/615, 1124/1256, 90/90, 4/4, 1/10 — **exactly the macOS baseline**. The emulator core
is proven correct on the iOS runtime, not merely compilable.

### 3. Static library + C API (the architecture-3 skeleton): works end-to-end

`docs/ios-experiment/ios_core_api.nim` is a ~120-line wrapper modeled on
`dingbat_wasm.nim` exposing `dingbat_init` (runs `NimMain`), `dingbat_load_rom`,
`dingbat_run_frame`, `dingbat_framebuffer` (+`fb_width/height/frame_static`),
`dingbat_set_input`, `dingbat_is_stopped`, `dingbat_flush_save`. Built with:

```
nim c --app:staticlib --noMain --os:ios --cpu:arm64 -d:test_harness -d:release ...
```

→ `libdingbat_core.a`, 1.4 MB, all 11 symbols exported (verified with `nm -gU`). A plain
C driver (`docs/ios-experiment/driver.c`) linked against the simulator variant with
nothing but `clang -isysroot $SIM_SDK` — i.e., exactly how an Xcode/Swift target would
consume it — and run under `simctl spawn`:

```
OK 240x160 fbhash=420c2d7c nonblack=37912/38400
BENCH 1000 frames in 1.106s = 904 fps (15.1x realtime)
```

It loaded a real GBA ROM, emulated 120 frames, produced a rendered framebuffer, and then
benchmarked ~15x realtime (18.5x — `1000 frames in 0.903s` — once rebuilt with the pinned
`--mm:arc --threads:off -d:noSignalHandler` flags in the final script; the first ad-hoc
build had silently fallen back to orc/threads:on because `nim.cfg` wasn't picked up when
compiling from outside the repo). (Caveats: simulator runs on the host M-series CPU, so treat
this as an upper bound for iPhone hardware; and dingbat's waitloop fast-forward may
inflate numbers on this particular ROM. Still, the margin is enormous — a GBA interpreter
that does 15x on an M-series core will comfortably exceed 1x on any iPhone from the last
several years; Delta ships GBA interpretation to the same hardware.)

### What a real port needs beyond the experiment

- **Audio gate (~4 lines)**: widen `when defined(emscripten)` around the
  `appendAudioSample` path in `src/dingbat/gba/apu.nim` and `src/dingbat/gb/apu.nim` to
  also cover an `ios_shell` define, so the native build reuses the exact wasm audio-ring
  design instead of the SDL branch. (The experiment used `-d:test_harness` to avoid this
  edit; it compiles out audio.)
- **Recommended extra flags** for the production lib: `-d:noSignalHandler` (don't fight
  the iOS crash reporter), keep `--mm:arc --threads:off` explicitly (a build invoked from
  outside the repo root misses `nim.cfg` — the first experiment silently built with
  orc/threads:on and still worked, but pin it).
- **Packaging**: two static libs (device + simulator) wrapped in an **XCFramework** with a
  small handwritten header; `lipo` is no longer the way.

---

## Architecture 1: WKWebView shell around the existing web build

Package `web/` + `em.js`/`em.wasm` into an app bundle, load in WKWebView.

### What research says (verified July 2026)

- **WebAssembly: full speed.** WKWebView pages run in Apple's out-of-process WebContent
  helper, which has the JIT entitlement — wasm gets JavaScriptCore's full BBQ/OMG JIT
  pipeline, same as Safari. The "no JIT in apps" rule applies to in-process
  JavaScriptCore.framework, not WKWebView. (webkit.org/blog/7691; HN threads confirming
  WKWebView JIT.)
- **SharedArrayBuffer: a real WKWebView pain point — but dingbat doesn't need it.**
  WebKit supports SAB only under COOP/COEP cross-origin isolation (since 15.2), and
  inside WKWebView there is *no confirmed way* to get `crossOriginIsolated = true`:
  `loadFileURL`/`loadHTMLString` can't set headers; `WKURLSchemeHandler` custom schemes
  with COOP/COEP headers demonstrably did **not** isolate (Capacitor issue #6182); a
  localhost HTTP server with the headers is plausible but unproven publicly. **None of
  this matters for dingbat**: the wasm build is single-threaded, links without
  `-pthread`, and the JS never touches `SharedArrayBuffer`. `serve.py`'s COOP/COEP
  headers are precautionary only.
- **Web Audio**: AudioWorklet exists but dingbat uses plain scheduled buffer sources —
  fine. Known WKWebView quirks: AudioContext needs a user gesture (the web UI already
  does the unlock dance, and `navigator.audioSession.type = "playback"` is already set
  for the silent switch); a documented bug where audio stays dead after screen
  lock/unlock until the AudioContext is suspended/resumed from native lifecycle events;
  the host app's AVAudioSession is largely ignored by the web view.
- **Storage durability is the biggest real problem.** IndexedDB in the default persistent
  `WKWebsiteDataStore` does survive relaunches, but: embedded-WebKit apps get a smaller
  quota (~15% of disk), eviction is per-origin all-or-nothing under disk pressure,
  **ITP is force-enabled in all WKWebView apps since iOS 14 and its 7-day script-storage
  deletion applies** — an emulator not opened for a week could lose every save. Capacitor's
  own docs say to treat WKWebView IndexedDB as transient. A shipping wrapper must bridge
  saves out to native files via `WKScriptMessageHandler` (and origin identity forces
  serving content from a custom scheme or localhost server — `file://` origins are opaque
  and fragile).
- **Service worker**: only works with App-Bound Domains over HTTPS, which conflicts with
  both custom-scheme serving and the JS bridge. Drop `sw.js` in the wrapper (assets are
  local; the update flow becomes App Store updates).
- **rAF**: 60 Hz cap (fine — GBA is 59.73 Hz), throttled to 30 fps in Low Power Mode
  (should be detected and surfaced), fully suspended in background (need native lifecycle
  → pause/flush-save hooks).

### Verdict

| | |
|---|---|
| **Pros** | Reuses ~100% of the existing polished UI; fastest to a working iPhone build (days); wasm performance is a non-issue; single codebase with the web product. |
| **Cons** | Must rip out the SW/update flow, add a native save-persistence bridge, add lifecycle/audio-session native glue — i.e., a real native layer anyway; audio remains at the mercy of WebKit quirks (screen-lock bug, mute switch behavior); no 120 Hz ever; feels like a web view (keyboard modal, fullscreen API weirdness); App Store reviewers accept wrapped HTML5 content under 4.7 but "web app in a can" adds minor 4.2 (minimum functionality) review risk. |
| **Effort** | Prototype: **2–4 days**. Shippable (native save bridge, audio lifecycle, document-picker ROM import, icons/branding): **2–4 weeks**. |

Good as a stopgap or market test; not the best end state.

---

## Architecture 2: Native SDL2 iOS port of the desktop frontend

SDL2 officially supports iOS (Xcode project templates, `SDL_uikit_main.c`,
CADisplayLink-driven `SDL_iPhoneSetAnimationCallback`, touch events, GCController
wrapping, CoreAudio backend). The Nim core compiles — proven above. So this *works*
mechanically. But:

- The desktop frontend is unusable as-is: `#version 330 core` GLSL must be rewritten
  (GLES3 or Metal via SDL_Renderer), and the whole windowed/ImGui-menu interaction model
  is desktop-shaped. The "port" is really a rewrite of `src/dingbat.nim`'s presentation +
  input + a from-scratch touch UI — the same work as architecture 3, minus the native
  toolkit.
- Dear ImGui on iOS is fine for debug overlays (imgui_impl_metal supports iOS) but a poor
  consumer UI: no accessibility, no iOS text input, HIG-pickiness in review. The
  keybindings/config/file-explorer ImGui widgets don't translate to touch.
- SDL2's iOS audio backend has documented rough edges: it ignores requested sample rates
  (returns hardware rate), buffer-size requests are approximate, and RetroArch abandoned
  the SDL2 audio driver on iOS because it freezes across interruptions (alarms/calls) —
  they use raw CoreAudio, Delta uses AVAudioEngine.
- Precedent check: **none of the shipped App Store emulators (Delta, RetroArch, PPSSPP,
  Gamma, Folium) use SDL2 as their iOS frontend.**
- SDL2 is in maintenance mode (SDL3 shipped 2025), so new investment would target SDL3
  anyway, adding migration work.

| | |
|---|---|
| **Pros** | One frontend codebase could theoretically serve desktop + iOS; SDL abstracts touch/controllers/lifecycle events; Nim stays the only language. |
| **Cons** | Rewrites the renderer *and* the UI anyway; ImGui unfit for the consumer UI; SDL2 iOS audio known-bad across interruptions; no shipped-emulator precedent; fighting the platform for lifecycle/session/document-picker features that are trivial in Swift. |
| **Effort** | Playable: **3–6 weeks**. Shippable with web-UI-quality polish: **8–12 weeks**, and the result is still less native-feeling than #3. |

Not recommended.

---

## Architecture 3: Swift/SwiftUI shell + Nim core as a static library (RECOMMENDED)

This is the Delta architecture, and the experiment above already built its foundation:
the core as `libdingbat_core.a` with a C API mirroring `dingbat_wasm.nim`, consumed by a
plain-clang (i.e., Xcode-equivalent) link, running real ROMs in the simulator.

### Design

- **Core**: XCFramework wrapping the device + simulator static libs, built by a script
  derived from `docs/ios-experiment/build-ios-core.sh` (runs as an Xcode build phase or
  checked-in artifact). C header ~40 lines. Swift calls it directly — no bridging pain
  for this shape of API (paths, ints, pointers).
- **Video**: `CAMetalLayer` + `CADisplayLink` at 60 Hz (59.73 content on a 60 Hz vsync —
  same situation as the web build; ProMotion devices can use 120 Hz link with frame
  pacing later). Per frame: `dingbat_run_frame()`, skip upload when
  `dingbat_frame_static()`, else convert BGR555 via the same precomputed LUT
  `dingbat_wasm.nim` uses (port `build_color_lut` to Swift or expose the RGBA buffer from
  the wrapper) into an `MTLTexture`, blit with a trivial fragment shader. Alternatively
  do BGR555→RGBA + LCD color-correction *in the Metal shader* and upload the raw 15-bit
  framebuffer — cheaper CPU-side than the wasm build can manage.
- **Audio**: reuse the wasm audio-ring design (the ~4-line APU gate change): APU pushes
  float32 stereo @ 32768 Hz into the ring; an `AVAudioSourceNode` (pull-based) drains it
  through `AVAudioConverter` to the hardware rate, inside `AVAudioEngine` with an
  `AVAudioUnitTimePitch` node for pitch-preserving fast-forward — exactly Delta's stack.
  AVAudioSession `.playback` category solves the silent switch *properly* (the web UI can
  only ask nicely). Handle interruption/route-change notifications.
- **Input**: SwiftUI/UIKit touch overlay recreating the web gamepad (the web CSS/layout is
  the spec: 8-way d-pad with diagonal wedges, A/B cluster, L/R, Select/Start, big-d-pad
  option), multi-touch tracking mapped to `dingbat_set_input(0..9)`. `GCController` for
  MFi/DualSense/Xbox pads (the web Gamepad-API mapping table translates directly).
  Hardware keyboard via `UIKeyCommand` if desired.
- **Library/home screen**: SwiftUI grid mimicking the web home screen; ROMs imported via
  `UIDocumentPickerViewController` / Files drag-in / share sheet ("Open in dingbat" via
  UTI registration for .gba/.gb/.gbc); ROMs + `.sav` files live in Documents (visible in
  the Files app for free export — better than the web UI's export button); screenshots
  for the recents grid captured from the framebuffer.
- **Persistence**: battery saves already write `<rom>.sav` — just point the core at
  Documents and call `dingbat_flush_save()` on `scenePhase` background. BIOS/bootrom
  optional imports like the web UI; HLE default means none required.
- **Save states**: not in the core today. When implemented (planned rewind/save-state
  work), expose as `dingbat_savestate_size/save/load` over a byte buffer; the Swift shell
  then gets slots + auto-save-on-background almost for free.

### App Store compliance (verified current, July 2026)

- Guideline 4.7 explicitly allows "retro game console and PC emulator apps" (worldwide,
  since April 2024; PC emulators added Aug 2024; reaffirmed unchanged in the June 2026
  guideline revision). Delta, RetroArch, PPSSPP, Gamma, Folium all live since 2024 with
  no reversals.
- JIT remains banned (UTM SE precedent: interpreter-only was approved) — dingbat is a
  pure interpreter, so this is a non-issue.
- Compliance requirements in practice: ship no ROMs/BIOS (HLE BIOS + user import — 
  already dingbat's model), user-supplied files via document picker (the accepted model;
  don't build a ROM downloader, which would trigger 4.7.1–4.7.5 catalog obligations),
  no Nintendo trademarks/game imagery in store assets (use homebrew, e.g. the bundled
  goodboy-demo).
- Nim-on-iOS App Store precedent exists (Reel Valley, ~100% Nim).

| | |
|---|---|
| **Pros** | Best runtime quality (native audio session, lifecycle, Files integration, haptics, Game Controller framework, ProMotion path); matches how every successful iOS emulator is built; core stays one codebase with desktop/web (the C API is a sibling of the wasm API); storage is boring native files; App Store profile identical to Delta's. |
| **Cons** | UI built twice (web + SwiftUI) — the web UI becomes a design spec, not shared code; requires Swift/Xcode competence and an Apple Developer account; save-state feature still needs core work; build pipeline gains an Xcode leg. |
| **Effort** | See phased estimate below. |

---

## Recommendation and phased effort estimate

**Build architecture 3.** Architecture 1 is a fine 2–4 day tech demo and could even ship
as an interim, but every one of its real problems (save durability, audio lifecycle,
update flow) is solved by adding native code — at which point the web view is just a
worse renderer with a better-looking UI on day one. Architecture 2 does the same rewrite
work as 3 with worse tools and no precedent.

Phases (single experienced developer; Swift-newcomer adds ~30–50%):

1. **Prototype — ~1 week.** XCFramework build script (exists in embryo:
   `docs/ios-experiment/build-ios-core.sh`), Xcode app target, CAMetalLayer +
   CADisplayLink loop, LUT color correction, AVAudioSourceNode ring (includes the
   ~4-line APU gate change in its own commit), document-picker ROM load, crude on-screen
   buttons. *Exit criterion: a game plays with sound on a physical iPhone.*
2. **Playable — +2–3 weeks.** Full touch gamepad to the web design (diagonal wedges,
   big-d-pad option, haptics), home screen/recents grid with screenshots, battery-save
   flush on background + Files-app exposure, GCController support, pause/reset/
   fast-forward (time-pitch), BIOS import, audio interruption + route handling,
   Low-Power-Mode/thermal behavior, iPad layout basics.
3. **Shippable — +3–6 weeks.** Polish pass against the web UI (animations, iconography,
   dark/light), settings (controller remap, volume, integer scaling), onboarding/empty
   states, accessibility labels on the touch controls, App Store assets with homebrew
   ROMs, TestFlight beta across device generations (incl. an older A-series perf check),
   review submission + iteration. Optional stretch: save states (core work first),
   ProMotion pacing, Game Center-free leaderboard-less simplicity kept deliberately.

**Total: ~6–10 weeks to App Store submission.**

## Honest unknowns

1. **No physical-device run.** Everything device-flavored was proven at the compile/link
   level (LC_BUILD_VERSION platform 2 binaries); execution was proven on the arm64
   simulator. A device run needs a signing identity — first prototype task. Risk is low
   (same ISA, same libSystem) but nonzero (jetsam limits, code-signing of Nim-generated
   code — precedent says fine).
2. **Real iPhone performance.** 15.1x realtime was measured on the simulator (M-series
   host, and dingbat's waitloop fast-forward may flatter that specific ROM). Expect
   comfortable margins on A14+, but the oldest-supported-device floor is unmeasured.
3. **Nim runtime under iOS memory pressure.** ARC + default allocator worked in the
   simulator; `-d:nimAllocPagesViaMalloc` is the documented fallback if the page
   allocator misbehaves on-device. Untested here.
4. **Audio latency tuning.** The ring + AVAudioSourceNode design is proven by Delta, but
   dingbat's pacing (recently verified on desktop/web) will need re-verification against
   CoreAudio buffer sizes; the 32768 Hz→hardware-rate conversion point is a place drift
   bugs like the recent web pre-unlock backlog could recur.
5. **Save states** are assumed future core work — the serialize/savestate layer referenced
   in early planning does not exist in the tree yet; nothing iOS-specific blocks it.
6. **WKWebView cross-origin isolation** (only if architecture 1 is chosen *and* the wasm
   build ever adopts threads): unproven publicly inside WKWebView; would need an on-device
   spike. Currently moot — the build is single-threaded by design.

## Experiment artifacts

- `docs/ios-experiment/build-ios-core.sh` — reproduces all four builds + verification.
- `docs/ios-experiment/ios_core_api.nim` — the candidate C API wrapper (staticlib entry).
- `docs/ios-experiment/driver.c` — minimal native consumer (load ROM, 120 frames,
  framebuffer checksum, 1000-frame bench).
