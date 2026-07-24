# Front-end parity & gap analysis (2026-07-15)

> **Stale — historical snapshot.** This survey describes the code as of
> 2026-07-15 and has since been overtaken: cheats shipped on both front-ends
> (`common/cheats.nim`, the web Cheats modal), display filters exist
> (scanlines, hq4x/xBR, LCD grid), and the save/sync story was rebuilt around
> Google Drive. Read it for the survey method and the parity axes, not for
> current facts; `docs/features.md` tracks what actually exists.

A survey of dingbat across five axes — correctness, features, quality-of-life,
polish, and **web ↔ native feature parity** — plus the low-hanging fruit that
was implemented in the same pass. Netcode/link/signaling files were excluded
from edits (other work in flight); they are described only where they bear on
parity.

> **Caveat:** several older notes (`notes/todo.md`, `notes/progress.md`) were
> found badly out of date. The "Surprising findings" section lists what is
> actually already done. This document reflects the *current* code, verified by
> reading it on 2026-07-15.

## Parity matrix — web vs native

Legend: ✅ present · ⚠️ partial/limited · ❌ absent

| Capability                     | Native (`src/dingbat.nim`) | Web (`web/index.js` + `dingbat_wasm.nim`) | Notes |
|--------------------------------|:--:|:--:|---|
| Load ROM (GBA/GB/GBC)          | ✅ | ✅ | native adds `.zip` extraction |
| Recents list                   | ✅ | ✅ | |
| Battery-save persistence       | ✅ | ✅ | web → IndexedDB; native → `.sav` next to ROM |
| Save-state save/load           | ✅ | ✅ | same file format both sides |
| Save-state export/import file  | ✅ (files on disk) | ✅ (`.state` download/upload) | |
| Rewind (hold)                  | ✅ | ✅ | |
| Fast-forward (uncapped)        | ✅ | ✅ | |
| 2× speed (audio-paced)         | ✅ | ✅ | |
| Frame advance (while paused)   | ✅ | ❌ | web pauses but has no single-step |
| Pause                          | ✅ | ✅ | |
| Reset                          | ✅ | ✅ | |
| Volume slider + mute           | ✅ | ✅ | |
| **LCD color-correction toggle**| ✅ | ✅ *(added this pass)* | was forced-on on web |
| Per-channel audio mute (PSG/DMA)| ✅ (keys 1–6 / menu) | ❌ | GBA only |
| **Screenshot**                 | ✅ *(added this pass)* | ✅ | web captures canvas; native writes PNG |
| Fullscreen                     | ✅ | ✅ | |
| Frame-size / integer scaling   | ✅ (1–8×) | ⚠️ (CSS fit) | |
| Keybinding remap UI            | ✅ (config editor) | ✅ (kb modal + presets) | |
| Controller / gamepad           | ✅ (SDL, hotplug, stick-as-dpad, trigger-FF) | ✅ (Gamepad API, P2 in link) | |
| Touch controls                 | ❌ (n/a) | ✅ | |
| BIOS / bootrom file support    | ✅ (CLI + config) | ✅ (upload modal) | HLE default both sides |
| Debug windows (PPU/sched/mem)  | ✅ (imgui) | ❌ | native-only, by design |
| 2P local link                  | ✅ (TCP) | ✅ (same-ROM dual core) | |
| Online link / trades           | ✅ (TCP) | ✅ (WebRTC + BroadcastChannel) | out of scope this pass |
| Cheats (GameShark/AR/codebreaker)| ❌ | ❌ | absent on both |
| Selectable shader/filters      | ⚠️ (color-correct only) | ⚠️ (color-correct only) | no scanlines/LCD-grid |

### Remaining parity gaps (both directions)

- **Frame advance on web** (native-only). S effort, low risk, low-moderate
  value. The RAF loop already gates on `paused`; a "step one frame" button
  would call the single-core tick once. Kept out of this pass because the tick
  path is entangled with the link/rollback branches in the RAF loop — small but
  needs care not to step those.
- **Per-channel audio mute on web** (native-only). S–M. Needs a wasm export to
  set `apu.channel_mask[]` + a small UI. Niche (mostly a chiptune/debug toy).
- **Cheats** — absent on both. Large; a real feature, not a parity item.
- **Extra display filters** (scanlines, LCD grid, integer-scale on web) —
  absent on both. M each; cosmetic.

## Prioritized gap list (impact / effort / risk)

### Correctness

| Item | Impact | Effort | Risk | Status |
|---|---|---|---|---|
| Open-bus exec recursion (PC in region 0x1) | High (segfault) | — | — | **Already fixed** (commit 2055c82); guard covers 0x1/0x4/>0xD. `notes/todo.md` was stale. |
| RTC IRQ line not wired (`rtc.nim:110` still `echo "TODO"`) | Low–Med (few games use timed RTC IRQ) | M | Med (IRQ + scheduler) | Open. Needs a scheduler event to raise the keypad/gamepak IRQ; not attempted (risk vs payoff). |
| LDM/STM with R15 in list | — | — | — | **Already implemented** (no longer raises). |
| Stop mode / KEYCNT wake | — | — | — | **Already implemented** (`mmio.nim`, `keypad.nim`). |
| Video-capture DMA (DMA3) | — | — | — | **Already implemented** (`trigger_video_capture`). |
| Residual `raise newException` decode fallbacks (arm×2, thumb×1) | Low (unreachable "impossible" arms) | S | Low | Left as-is; they document invariants and are cheap asserts. |

### Features

| Item | Impact | Effort | Risk | Status |
|---|---|---|---|---|
| Cheats (GameShark/AR) | High for some users | L | Med | Not done. Needs a code DB/parser + per-frame RAM patch hook. |
| Save-state slots (>1 per ROM) | Med | M | Low | Header already reserves a slot byte; UI/keys not wired. |
| Tilt/gyro/solar/rumble carts (Boktai, WarioWare Twisted, yoshi) | Low (few carts) | L | Med | Not present. GPIO exists (RTC only); no sensor/rumble lines. |

### Quality of life

| Item | Impact | Effort | Risk | Status |
|---|---|---|---|---|
| Native screenshot | Med | S | Low | **Done this pass** (F12 / File menu → PNG). |
| Web color-correction toggle | Med | S | Low | **Done this pass.** |
| On-screen toast/OSD for save/load (native) | Low | S | Low | Not done; `process_pending_state` currently only `echo`s. Hook is ready ("bool results are ready for a future toast"). |
| Frame advance on web | Low–Med | S | Low | Not done (see parity gaps). |

### Polish / flares

| Item | Impact | Effort | Risk | Status |
|---|---|---|---|---|
| Screenshot honors on-screen color correction | Low | — | — | Done (part of native screenshot). |
| Pause/rewind badge (native) | — | — | — | Already present. |
| Scanline/LCD-grid shader | Low | M | Low | Not done. |

## What was implemented this pass

1. **`native: add screenshot (F12 / File menu)`** — `src/dingbat.nim`.
   Framebuffer → BGR555→RGB8 (replicating the display shader's LCD correction
   when enabled) → `stb_image` `writePNG` at
   `config_dir/screenshots/<rom>-<timestamp>.png`. Bound to F12 and a File-menu
   item. Verified: native release build succeeds; the conversion + PNG-write
   path was exercised standalone producing valid 240×160 PNGs (raw + corrected)
   confirmed with `file` and visual check.

2. **`web: add an LCD color-correction toggle`** — `src/dingbat_wasm.nim`,
   `src/dingbat_wasm.nims`, `web/index.html`, `web/index.js`. Parametrized the
   shared BGR555→RGBA LUT (raw expansion vs gamma-corrected mix), exposed
   `wasm_set_color_correction`, added a persisted menu toggle. Verified: wasm
   `em.js`/`em.wasm` rebuild with the export present; driven in Chrome — toggle
   flips the label On/Off, calls the setter with 0/1, no console errors.

Both changes are frontend-only and do not touch the emulation core, so the
mGBA test suite score (baseline 6734/7218) is unaffected.

## Surprising findings

- **`notes/todo.md` is largely obsolete and misleading.** Its "TODOs in Code",
  "HLE BIOS Gaps", and "Known Exception Sites" sections mostly describe fixed
  work: the open-bus recursion, LDM/STM-with-R15, Stop mode, KEYCNT, serial I/O
  registers, and DMA video capture are all implemented, and the HLE SWI table
  now spans SoftReset (0x00) through Diff16bitUnFilter (0x18) plus the math and
  (de)compression BIOS calls — not just Halt/IntrWait as the file claims. Only
  the RTC-IRQ item is still genuinely open. `notes/todo.md` was refreshed in the
  same pass.
- The web front-end is at near-full parity with native and in a couple of areas
  ahead (touch controls, same-browser BroadcastChannel link). The remaining
  native-only items are debug windows (intentional) and per-channel audio mute.
</content>
