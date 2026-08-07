# "The web front end serialises mid-frame"

Investigated 2026-08-07, from a report raised while verifying save states
embedded in PNGs:

> The round-trip matched to within 6 bytes, and a control proved those same 6
> offsets drift on the plain `.state` path with no PNG involved — **web
> serializes mid-frame**; the differing fields were `cpu.halted` /
> `halt_wake`.

**Short answer: the web front end does not serialise mid-frame. It cannot.**
A state written by the browser at frame *N* is byte-for-byte the state native
writes at frame *N*, all 505 824 of them, on the same ROM. The six drifting
bytes are real, they reproduce with no browser anywhere near them, and they come
from the **load** side: `gba_apply_state` ended by calling
`interrupts.check_interrupts()`, which is not the pure recompute the comment
above it claimed — it also resolves the halt, three cycles ahead of the
scheduler event that the state itself carries for exactly that purpose.

Severity of the original symptom: cosmetic. Loading such a state and resuming
produces the same machine, measured to the byte. But the same call sits on the
path that rewind, netplay rollback and run-ahead take *sixty times a second*,
and there the three-cycle-early wake is not free — see §5.

---

## 1. What "a frame boundary" is here, and why the web can't miss one

`GBA.step_frame` (`src/dingbat/gba/gba.nim:1254`) runs `while gba.ppu.frame == 0:
gba.cpu.tick()`. `ppu.frame` is incremented at `vcount == 160`
(`src/dingbat/gba/ppu.nim:120-132`) — the instant vblank starts. So a "frame
boundary" is the first instruction boundary at or after the start of vblank, and
every state, native or web, is written there.

The two front ends reach it differently but land in the same place:

- **Native** (`src/dingbat.nim`): a keypress sets `app.pending_save`; the main
  loop services it at line 2112, immediately after `run_until_frame()`, through
  `process_pending_state()` (line 670), whose docstring already says "runs
  between frames only".
- **Web** (`src/dingbat_wasm.nim:347` `wasm_state_size`): called from JS event
  handlers. The build is `--threads:off`, single-threaded, with **no ASYNCIFY**
  (see the `passL` line in `src/dingbat_wasm.nims`), and every `_loop_tick()` /
  `_runahead_tick()` call in `web/index.js` is a synchronous call inside the rAF
  callback (lines 9081-9134). A JS event handler cannot interleave with a
  synchronous wasm call, so `wasm_state_size` can only ever run between ticks.

That is an argument, not a measurement. The measurement is §2.

## 2. Reproduction: web vs native, byte for byte

`web/midframe-probe.html` (not committed; see §7) loads `em.js` on its own,
writes the ROM into MEMFS, calls `initFromEmscripten`, drives exactly *N*
`_loop_tick()` calls and hands `wasm_state_size`/`wasm_state_data` back to
Playwright. A native harness runs `new_gba(...)` + *N* × `step_frame()` and
writes `state_bytes()`.

ROM: `web/goodboy-demo-en.gba`, HLE BIOS both sides, no thumbnail either side.

| N | result |
|---|--------|
| 1, 7, 137, 300, 901 | **byte-identical** (505 824 bytes) |

Two traps cost an hour each and are worth writing down:

- `web/em.js`/`em.wasm` in a fresh worktree are **stale artifacts**. The
  pre-copied pair was built at GBA payload revision 4 while the tree is at 5, so
  the first comparison differed by 8 bytes of length and a rev byte. `nimble
  wasm` first, always.
- The native harness writes `<rom>.sav` next to the ROM. A second core
  constructed afterwards loads it, and the two runs then "diverge" by whatever
  the first one flushed. Delete the `.sav`, or construct every core before any
  of them runs.

The phase fields agree exactly, which is the direct refutation: a web state at
frame 300 decodes to `vcount=160 ppuframe=0 sched=960 pc=0800081a`, the same
values the native core holds at frame 300.

## 3. Reproduction: the six bytes, with no browser

```
probe web/goodboy-demo-en.gba idem 300
  before-save@300: vcount=160 halted=true  halt_wake=false irq_line=false ie=0001 if=0001 ime=true
  after-load@300:  vcount=160 halted=false halt_wake=true  irq_line=true  ie=0001 if=0001 ime=true
  save/load/save@300: 6 differing bytes of 505824: @[28, 29, 30, 31, 307, 316]
  second round trip@300: identical
```

Native, one process, no PNG, no web. The offsets decode as:

- `28..31` — the header's `fnv1a(payload)`, which moves because the payload did.
- `307` — payload offset 275 = `cpu.halted`.
- `316` — payload offset 284 = `cpu.halt_wake`.

Reproduced at N = 100, 300, 301, 600, 901, and on Golden Sun 2, Mother 3 and the
mGBA suite ROM. The second round trip is always identical: one load is a
fixpoint.

## 4. Mechanism

`interrupts.check_interrupts()` (`src/dingbat/gba/interrupts.nim:26`) does two
jobs. It recomputes the derived `cpu.irq_line` from IE/IF/IME — which is why
`gba_apply_state` has to call it, since `irq_line` is not serialised. It also
**resolves the halt**: `halt_wake = true`, `halted = false`, `stopped = false`.

Hardware does not recognise an IRQ the moment a peripheral raises IF. dingbat
models the synchronisation latency with `IRQ_SYNC_DELAY = 3`
(`interrupts.nim:20`): every raise site schedules an `etInterrupts` event three
cycles out rather than calling `check_interrupts` inline. The PPU's vblank raise
is one of them (`ppu.nim:124-129`).

And that is precisely the boundary. The frame ends because vblank started; the
vblank IF bit was set in the same event; the recognition check is three cycles in
the future. So **a state written at a frame boundary by a game that idles in
HALT or IntrWait almost always carries a not-yet-fired `etInterrupts` event**,
and `halted = true` with `IE & IF != 0` is the correct, expected content of that
state, not a bug.

`gba_apply_state` then fired that check by hand at load time, three cycles early,
and the serialised event fired again on schedule and redid the same work. Hence
the two bytes.

The report's "6 bytes" and "`cpu.halted`/`halt_wake`" are exactly right. Only the
attribution — save side, web-specific — was wrong. The likely path to that
conclusion: the web front end's run-ahead is a per-frame
`state_payload`/`apply_state_payload` pair (`dingbat_wasm.nim:840`), so with
run-ahead on, the *live web core* carries the post-load values while a native
core does not. Measured on the pre-fix build, web@300 with run-ahead 1, 2 or 3
differs from native@300 by exactly those 6 bytes and nothing else.

## 5. Severity

### 5.1 Resume divergence: none measured

The test that matters. For each checkpoint: save, load into a **fresh** core, run
M frames, compare every frame's framebuffer hash *and* the full state image
against an uninterrupted reference run.

| ROM | checkpoints (stride 37, to frame 900) | M | fb divergences | state divergences |
|---|---|---|---|---|
| goodboy-demo-en | 24 | 20 | 0 | 0 |
| Golden Sun 2 | 24 | 20 | 0 | 0 |
| Mother 3 | 24 | 20 | 0 | 0 |
| mGBA suite | 24 | 20 | 0 | 0 |

Also at N=300 with M = 1, 2, 10, 120 and 600: framebuffer *and* full state image
identical after resume. So for a user's save state the answer is **cosmetic** —
the early wake reaches the same machine the scheduled check would have reached,
because nothing can run while the CPU is halted and therefore the pending set
cannot change between the save point and the check.

### 5.2 Rewind / rollback / run-ahead: the same funnel, 60× a second

`apply_state_payload` → `gba_apply_state` is the single load funnel. It serves
the rewind ring (`dingbat_wasm.nim:791`, `dingbat.nim:2070`), netplay rollback
(`link.nim`'s `LinkSnapshot` is built from `state_payload`) and run-ahead. None
of those are version-exposed, so the blast radius is larger than manual saves.

Measured with `selfrestore`: run 400 frames doing `state_payload` +
`apply_state_payload` on the **live** core every frame, and compare per-frame
against a clean run (masking the two known bytes so this measures timeline
divergence, not the normalisation itself).

| ROM | before the fix (bytes differing at frame 400) | after |
|---|---|---|
| goodboy-demo-en | 0 | 0 |
| Mother 3 | first diff frame 41, 0 by frame 200 | **none at all** |
| mGBA suite | first diff frame 9; 4 bytes at frame 200 | 0 at frame 200; first diff frame ~210 |
| Golden Sun 2 | 3-4 bytes (cpu/bus/sched) from frame 3 | **unchanged** |

Two readings. The eager wake was a genuine, if small, per-restore perturbation,
and removing it removes it. And there is a **second, independent** apply-side
non-idempotency that this does not touch (§6).

The framebuffer never diverged in 400 frames on any of the four ROMs, in any
variant. What diverges is a banked LR, a couple of words at the top of IWRAM (the
IRQ/SVC stack), and a scheduler deadline — the signature of an IRQ entered from a
marginally different instruction.

### 5.3 Link / netplay determinism

Not a desync source. The normalisation is deterministic and identical in both
peers' builds; a peer that rolls back and a peer that does not would end at
different machines only if the normalisation changed behaviour, and §5.1 says it
does not. It does, however, mean a rolled-back peer and a straight-through peer
were not bit-identical at the payload level, which matters for the relaxed-CRC
comparisons the link protocol uses.

## 6. The residual: a separate apply-side non-idempotency

Golden Sun 2 keeps a 3-4 byte drift (one CPU banked register, one IWRAM byte,
one or two scheduler-event bytes) across repeated live restores, with or without
the fix. It is **not** the save side — a control that calls `state_payload()` an
extra time per frame and never applies it is bit-identical for 400 frames on
every ROM tried. It is **not** the APU `arm_delay` reconstruction — pinning
`arm_delay` across the load changes nothing. Remaining suspects, untested:
`scheduler.load_from` replacing the event array (event ordering at equal
deadlines) and `apu_extract_state_events` clearing and re-appending the four PSG
events into that array; `bus.fetch_page` invalidation.

The mGBA suite is worth flagging separately: it measures cycle counts and
auto-advances on a timer, so it amplifies any perturbation. Under per-frame live
restore it goes fully out of phase with a clean run between frames ~210 and ~330
(tens of KB of VRAM and SRAM differ, though the visible framebuffer never does)
and settles into a stable offset afterwards. That is not new with this fix — the
unfixed build did the same, starting earlier.

## 7. The change

`src/dingbat/gba/savestate.nim`, in `gba_apply_state`: keep `check_interrupts`
for the derived `irq_line`, restore `halted` / `halt_wake` / `stopped` around it,
and let the serialised `etInterrupts` event resolve the halt on schedule.

Safety rests on one invariant, checked by inspection: every path that raises IF
schedules the recognition check in the same breath — `dma.nim:237`,
`keypad.nim:20`, `timer.nim:41`, `ppu.nim:100/117/124`, `serial.nim:120`,
`rtc.nim:35/151`, `hle_bios.nim` ×4, and the IE/IF/IME writes in `mmio.nim:46`.
So a state with a pending interrupt always carries the event that will resolve
its halt, and nothing runs while the CPU is halted that could change the pending
set in between.

**Alternatives considered and rejected.** *Defer the web save to the next frame
boundary* — the premise is false, it is already at one, and deferring would move
where the user's save lands relative to the button press for nothing. *Serialise
`irq_line`* — a payload revision bump to buy back three cycles on the one case
(saved while running, IRQ pending and masked) that the eager recompute already
handles conservatively; not worth the compatibility cost. *Accept it as
cosmetic* — defensible for manual saves, but it is on the rewind/rollback path,
and the fix is four lines that no test can tell apart.

### Evidence

- `save/load/save` is now byte-identical (505 824 bytes) at every N tried, on
  every ROM tried, including the ones that showed 6 bytes before.
- Web vs native still byte-identical at N = 137, 300, 901 after rebuilding
  `em.wasm`; and web **with run-ahead 1, 2 and 3** is now also byte-identical to
  a plain native run at the same frame (it differed by the 6 bytes before).
- `./dingbat_test_runner`: 978 rows, 691 pass, gambatte 3618/5005 — the results
  files are byte-identical to the committed ones apart from the timestamp line.
- `nimble test_savestate_compat`, `test_rewind`, `test_timestretch`,
  `test_printer`, `test_cheats`, `test_ppucomposite`, `test_ppubgunpack`,
  `test_ppuobjlist` all pass; `node --test web/tests/*.test.mjs` 212/212.
- Every committed GBA corpus state (`tests/states/*.gba.*.state`, container v4-v7)
  loads and then makes progress over 120 frames — the case the change could in
  principle have hung.

### Game Boy

`gb_apply_state` has no equivalent call and is structurally immune. Verified:
`gbhdmatest.gbc` and `gblinktest.gb` at frame 200 give a 0-byte
save/load/save diff and no framebuffer divergence over 30 resumed frames.

## 8. Harnesses

Throwaway, in the investigation scratch dir rather than the tree:

- `probe.nim` — `dump` / `phase` / `idem` / `resume` / `idemfile` modes over one
  GBA core. `phase` prints vcount, scheduler cycles, halt flags, IE/IF/IME and pc
  for any `.state` file, which is what proves where a state was taken.
- `sweep.nim` — idempotency + fresh-core resume divergence at every checkpoint.
- `selfrestore.nim` — live-core `plain` / `saveonly` / `selfrestore` / `runahead`
  modes with a per-section breakdown of what differs. The section offset table it
  uses came from a temporary `-d:statesections` instrumentation of
  `gba_state_payload`.
- `web/midframe-probe.html` + a Playwright driver — a bare page that loads
  `em.js`, drives an exact number of `loop_tick` calls and returns the state
  bytes, with none of `index.js` in the way. Deliberately not committed; it is
  ten lines to rewrite and it would otherwise be shipped to users by the service
  worker's asset precache.
