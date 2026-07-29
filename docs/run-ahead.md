# Run-ahead: findings & design notes

Status (2026-07-29): implemented behind an **opt-in runtime setting**
(Settings → Controls → Run-ahead, default Off, chips Off/1/2/3) on branch
`worktree-feature-prototypes`. This doc captures the algorithm, the
measurements, and the design decisions.

## Cost of the runtime option (measured)

Off is free by construction: the tick loop's Off path calls the identical
`loop_tick` that predates the feature (one boolean test per RAF tick in JS
selects the export). Verified two ways:

- `tools/webbench` interleaved A/B, pristine-main control rebuilt with the
  same emcc vs the feature branch, best-of-N over Emerald + Kirby:
  emu/tick/ffsim deltas **0.2–1.6% in the branch's favor** — inside the
  harness's ~1.3% noise floor. No regression from any prototype change
  (including the per-sample slow-mo flag test in appendAudioSample).
- Direct per-call timing: `loop_tick` 2.44 ms vs `runahead_tick(0)` 2.30 ms
  — the degenerate path is not slower, so routing everything through one
  export would also be fine if ever preferred.

Toolchain footnote from the same session: the *deployed* em.wasm (built
Jul 26) measured ~12% slower than a fresh rebuild of identical sources
with emsdk 4.0.23 — rebuilding is worth a free double-digit win on its own.

## What it is

Most GB/GBA games have 1–3 frames of *internal* input latency: they poll the
keypad, run game logic, and the visible result reaches the LCD 1–3 frames
after the press. That lag is in the game's own code — no amount of frontend
latency work removes it. Run-ahead cancels it by always *displaying* the
frame the game will render N frames from now, computed under the assumption
that the currently-held buttons stay held. When a press does arrive, the
world it affects is already on screen, so the response appears up to N
frames (16.7 ms each) sooner. RetroArch popularized this as its flagship
"next-frame response" feature.

## The algorithm (single-instance method)

Per 60 Hz tick — see `runahead_tick(n)` in `src/dingbat_wasm.nim`:

1. `step_frame()` — the canonical frame; **its audio is the only audio kept**.
2. `snap = state_payload()` — same snapshot path rewind uses (no thumbnail).
3. `audioSuppressed = true`; run `n` more `step_frame()`s; restore flag.
   The APU must actually run during lookahead (its state feeds emulation
   timing); only the sample *append* is skipped — the same mechanism 2P
   link mode uses to mute core 2, so it is known not to perturb emulation.
4. Copy `ppu.framebuffer` into a retained buffer and present **that**.
5. `apply_state_payload(snap)` — the machine is back at the canonical frame.

Authoritative state is frame F while the screen shows F+n, every tick.
`n <= 0` degenerates to exactly `loop_tick`. Input applied between ticks
lands before the next canonical step, so the future is simply re-predicted;
mispredictions cost one ephemeral wrong frame (≤16 ms), never a correction.
This is rollback netplay's speculation trick with the replay pass deleted.

## Non-obvious implementation facts (the ones that will bite)

- **`ppu.framebuffer` is serialized** in the state payload (that's why
  rewind pops present instantly). `apply_state_payload` therefore REVERTS
  the pixels you are about to display, and `prepare_game_frame` is
  zero-copy (`gamePtr` aims straight at the PPU buffer). The future frame
  must be `copyMem`'d to a retained buffer (`runaheadFrame`) and presented
  from there. Skip this and run-ahead silently displays the present frame.
- **Audio is pop-free by construction**: canonical samples are contiguous
  across ticks because APU state round-trips through the snapshot. This is
  the property RetroArch's two-instance mode exists to work around — our
  save states are clean enough that the cheap mode works.
- **Keypad state is part of the snapshot** and JS sets input event-style
  before the tick, so lookahead frames automatically inherit "buttons stay
  held" — no separate input model needed.
- Run-ahead is **single-core only**: the linked/netplay modes are
  frame-synced with a peer and must never run ahead of the sync point.
  (Rewind-ring pushes stay on the canonical step, so rewind still works.)

## Measured cost (M-series Mac, m7 demo, wasm build)

| step               | ms/frame |
|--------------------|----------|
| `loop_tick`        | 2.0      |
| `runahead_tick(2)` | 6.5      |

≈2 ms per extra frame-step plus ≈0.4 ms snapshot+restore. n=4 still fits a
16.7 ms budget on desktop with room for present/audio. **Open question:
phone headroom** — iPhones start near ~5 ms/frame for heavy GBA titles, so
n=2 could exceed budget there; needs measurement before shipping a setting.

## A/B harness (kept on the branch)

`web/runahead.html` — two `embed.html` iframes: left `loop_tick`, right
`?runahead=N` (N selectable 1–4). Serve `web/` and open `/runahead.html`;
"Load demo ROM" uses the bundled goodboy demo. Design points worth keeping:

- Parent page owns input: maps `e.code` → `Input` enum ids and posts
  `db-input` to both panes, which call `_setInput` directly — no SDL
  keyboard path, no per-pane timing skew.
- `?bridge` makes it focus-proof: each embed hooks game keys in the CAPTURE
  phase *before* `em.js` loads (same script-order trick as the embed's Tab
  hatch, which is what outranks SDL's window key grab), swallows them, and
  forwards `db-key` to the parent for rebroadcast. Without this, clicking a
  pane focuses the iframe and that pane plays alone — the exact split-input
  failure an A/B rig must not have.
- postMessage bridge in `embed.js`: `db-rom` / `db-input` / `db-reset` /
  `db-pause`, with a `db-ready` handshake so a reloading pane (changing N
  swaps the right iframe's URL) re-receives the ROM.
- Amber bars under the panes light at *input* time (parent keydown). Film
  at 120/240 fps and count frames from bar-on to sprite response per pane:
  baseline − run-ahead ≈ N frames.
- Panes are not frame-locked to each other (they boot RAF-ticks apart);
  the rig measures response latency, not lockstep identity — the right
  metric for this feature.

## The shipped setting (web)

Settings → Controls → Run-ahead: chip group Off/1/2/3, default Off,
persisted under the `runahead` IndexedDB key, included in SETTINGS_KEYS /
reset-to-defaults. The tick loop engages `runahead_tick(N)` only in the
normal-speed single-core branch — never during fast-forward, 2x or slow
motion (the (N+1)x per-frame cost buys nothing there) and structurally
never in the link/rollback/net branches. Frame advance and the FF loop
keep calling `loop_tick`.

## Still open for a full release

- Per-game N override (games differ in internal lag; wrong N eats real
  time). Finding N for a game: pause, hold a direction, frame-advance
  until the character reacts, minus one.
- A future RetroAchievements hardcore mode treats run-ahead as fine (RA
  allows it) but rewind/states/cheats not.
- Native frontend could reuse the identical algorithm around its own
  save/load; nothing here is wasm-specific except the framebuffer-retention
  detail (native presents via its own path).
- Phone perf pass (see cost table); consider auto-disabling below a
  headroom threshold rather than exposing a footgun.
