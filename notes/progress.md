# Progress

## Completed Work

### Phase 1: Initial Nim Port (pre-session)
- Ported all Crystal source files to Nim under `src/dingbat/gba/`
- Fixed all compilation errors (type mismatches, forward declarations, include order)
- Added SDL2 frontend (`src/dingbat.nim`) with keyboard input and video rendering
- Fixed ARM exception handling

### Phase 2: Runtime Fixes

#### Fix: Infinite recursion / segfault on Kirby ROM
**Problem**: Stack overflow when launching `./dingbat KirbyNightmareInDreamland.gba`.
- `ppu[]` else-clause called `read_open_bus_value(io_addr)`, which called `read_word_internal(cpu.r[15])`.
- When PC pointed into MMIO space (0x04xxxxxxx), this re-entered MMIO reads → infinite loop.

**Fix** (`src/dingbat/gba/bus.nim`):
- Added guard in `read_open_bus_value`: if PC is in region 0x4 (MMIO) or > 0xD (unmapped), return 0.

#### Fix: All ROMs freezing on startup
**Problem**: Games rendered the first frame then froze. CPU was executing zeros at BIOS addresses.
- Without a real BIOS file, addresses 0x00–0x3FFF are zero-filled.
- SWI instructions jump to 0x08 in supervisor mode. Zero bytes decode as `ANDEQ R0, R0, R0` — CPU looped forever executing no-ops.
- IRQ vector at 0x18 was also zeros — interrupts also went nowhere.

**Fix — HLE BIOS** (`src/dingbat/gba/bus.nim`, `arm/software_interrupt.nim`, `thumb/software_interrupt.nim`):

1. **ARM-level SWI interception**: In `arm_software_interrupt` and `thumb_software_interrupt`, when `gba.bios_path == ""`, dispatch SWI at the Nim level instead of jumping to 0x08.
   - SWI 02h / 06h (Halt): set `cpu.halted = true`
   - SWI 04h (IntrWait): optionally clear IF flags, set IE flags, halt
   - SWI 05h (VBlankIntrWait): clear VBlank IF, set VBlank IE, halt
   - All others: no-op (return immediately)

2. **Binary IRQ stub in BIOS memory**: Load a minimal ARM program into BIOS bytes 0x00–0x37 at startup when no BIOS file is provided. This handles the IRQ vector at 0x18:
   ```
   0x08: MOVS PC, LR          ; fallback SWI return (HLE intercepts first anyway)
   0x18: STMFD SP!, {R0, LR}  ; IRQ entry
   0x1C: LDR R0, [PC, #16]    ; R0 = &0x03FFFFFC
   0x20: LDR R0, [R0]         ; R0 = user ISR address
   0x24: BLX R0               ; call user ISR
   0x28: LDMFD SP!, {R0, LR}  ; restore
   0x2C: SUBS PC, LR, #4      ; return from IRQ
   0x34: .word 0x03FFFFFC     ; constant (user ISR pointer location)
   ```

#### Fix: No audio output
**Problem**: APU was correctly generating samples but had `# TODO: SDL audio` stubs instead of actual output.

**Fix** (`src/dingbat/gba/apu.nim`, `src/dingbat/gba/gba.nim`, `src/dingbat.nim`):
- Added raw C bindings for `SDL_OpenAudio`, `SDL_PauseAudio`, `SDL_QueueAudio`, `SDL_GetQueuedAudioSize`, `SDL_ClearQueuedAudio` (the Nim SDL2 package is missing `SDL_ClearQueuedAudio`).
- In `new_apu`: call `SDL_OpenAudio` with 32768 Hz, S16LE, stereo, 512 samples/buffer. Unpause with `SDL_PauseAudio(0)`.
- In `get_sample`: when buffer fills, optionally clear queue (async mode) or throttle until queue < 2 buffers (sync mode), then `SDL_QueueAudio`.
- Added `audio_dev: uint32` field to `APU` type in `gba.nim` (`SDL_OpenAudio` always assigns device ID 1).
- Moved `sdl2.init(INIT_VIDEO or INIT_AUDIO)` in `dingbat.nim` to before `new_gba()` — APU opens the audio device during construction.

### Phase 3: ARM Instruction Set Correctness

#### Fix: LSL by 32 (test 152 in gba-tests/arm)
**Problem**: `word shl 32` for a `uint32` is undefined behavior in C/Nim. On x86, the hardware
takes shift amount mod 32, so `1 shl 32 = 1` instead of 0. This caused `LSLS r0, r1` (r1=32)
to produce result=1 (Z clear) instead of result=0 (Z set), failing the branch test.

**Fix** (`src/dingbat/gba/cpu.nim` — `lsl` proc):
Handle all shift-amount cases explicitly per ARM7TDMI spec:
- `bits == 0`: return word unchanged
- `bits < 32`: normal shift
- `bits == 32`: result = 0, carry = bit 0 of source
- `bits > 32`: result = 0, carry = 0

Crystal didn't have this problem because Crystal's `<<` operator returns 0 for shifts ≥ type width.

#### Fix: UMULL/SMULL RangeDefect (crash between tests 152 and 511)
**Problem**: `multiply_long.nim` used `int64` for the result variable. The unsigned path computed
`int64(uint64(rm) * uint64(rs))`, which throws `RangeDefect` at runtime when the product exceeds
`int64.max` — since Nim debug builds check integer range on conversion.

**Fix** (`src/dingbat/gba/arm/multiply_long.nim`):
Changed `res` from `int64` to `uint64`, matching Crystal's `UInt64` type. The signed path uses
`cast[uint64](int64_product)` (bitwise reinterpret, no range check). All arithmetic and
`set_reg` calls now use pure `uint64` — no checked conversions.

#### Fix: STM^ user-bank register access (test 511 in gba-tests/arm)
**Problem**: Nim's `defer` is scoped to its **enclosing block**, not the enclosing proc. The
`if s_bit:` block used `defer: cpu.switch_mode(saved_mode)`, which fired immediately when the
`if` block ended — before the transfer loop. The STM then ran in the original (FIQ) mode,
storing FIQ-banked r8 (64) instead of USR-banked r8 (32).

**Fix** (`src/dingbat/gba/arm/block_data_transfer.nim`):
Removed `defer`. Now matches Crystal exactly: save mode before `switch_mode(USR)`, run the
transfer loop, then explicitly call `switch_mode(saved_mode)` after the loop (outside the
`if` block).

**Key lesson**: Never use `defer` inside an `if` block when the deferred work must outlive that
block. Nim `defer` ≠ Go `defer` (which is proc-scoped).

### Phase 4: GB/GBC Port

#### GB/GBC emulator implemented
Full Game Boy / Game Boy Color port translated from Crystal to Nim:
- SM83 CPU with all 512 opcodes (unprefixed + CB-prefixed)
- Memory bus with MBC1/2/3/5 and plain ROM support
- Dual PPU renderers: scanline (simple) and FIFO (cycle-accurate, default)
- APU with channels 1–4 (square×2, wave, noise), frame sequencer, SDL2 output
- Timer, joypad, interrupts, OAM DMA, HDMA (CGB), CGB double-speed mode
- Multi-core frontend: `.gb`/`.gbc` → GB, `.gba` → GBA (detected by extension)

#### Fix: GB APU audio garbled
**Problem**: `AUDIO_F32SYS` was hardcoded as `0x9120` (`AUDIO_F32MSB` — big-endian float32).
On macOS (little-endian), SDL2 performs byte-swap conversion from the declared big-endian
format to the system's little-endian format. But the actual sample data in the buffer is
already little-endian, so SDL double-swaps every float, completely garbling the audio.

**Fix** (`src/dingbat/gb/apu.nim`):
- Changed constant to `AUDIO_F32LSB = 0x8120` (little-endian float32), matching the GBA
  APU which correctly uses `AUDIO_S16LSB = 0x8010`.
- Also changed initialization to call `tick_frame_sequencer` and `get_sample` directly
  (matching Crystal/GBA behavior) instead of only scheduling them, so the frame sequencer
  advances to stage 1 at startup and the buffer is pre-filled before any CPU cycles run.

#### Fix: GB APU zombie mode double-increment
**Problem**: `write_NRx2` in `abstract_channels.nim` had two separate `if` blocks for the
zombie mode glitch, which could increment `current_volume` twice in cases where both
conditions were true.

**Fix**: Merged into a single `if (period == 0 and updating) or (not add_mode)` matching
Crystal's single `||` condition exactly.

### Refactor: GBA bitfield registers — native packed objects

Replaced the custom `bitfield` macro (`src/dingbat/bitfield.nim`) with Nim's native
`{.packed.}` + `{.bitsize:N.}` struct pragmas, mirroring `reference/gba`'s approach.

**Why**: The macro approach generated a wrapper type with a `.value: T` field and
individual getter/setter procs. The native approach maps directly to hardware layout
without any wrapper — fields are accessed directly as struct members.

**Key changes**:
- `src/dingbat/gba/reg.nim` — complete rewrite; all 24 GBA I/O registers now use
  `{.packed.}` objects. Added `GbaReg16` type class and `converter toU16`/`toU32`
  for implicit coercions. Added `read(reg, byteNum)` and `write(reg, value, byteNum)`
  procs for both packed register types and plain `uint16 | uint32`.
- `CpuMode` enum moved from `gba.nim` type block into `reg.nim` (must precede PSR).
- `import ../bitfield` removed from `gba.nim`.
- All `.value` accesses replaced: `psr.value` → `uint32(psr)`, raw assignment via
  `cast[T](raw_value)`.
- All `read_byte(n)` / `write_byte(n, v)` call sites updated to `read(reg, n)` /
  `write(reg, v, n)` — note the parameter order swap (value before byteNum).
- Case branches halved where possible using `of 0xNN..0xNN+1: read(reg, io_addr and 1)`.
- Validated all register bit totals: PSR=32, BGREF=32, all others=16. ✓

**Not adopted from reference**:
- Reverse converter `toReg16*[T](num: uint16): T` — explicit `cast[T](...)` is clearer.
- `put` helper proc — equivalent to our inline `write` approach.
- `{.packed.}` Sprite type — our Sprite uses three `uint16` attrs + accessor procs
  (potential future improvement).

## Current Status

| Subsystem     | Status        | Notes                                            |
|---------------|---------------|--------------------------------------------------|
| CPU (ARM)     | Working       | All standard instructions; gba-tests/arm passes  |
| CPU (Thumb)   | Working       | All standard instructions implemented            |
| PPU           | Working       | Modes 0–5, sprites, windowing                    |
| APU (GBA)     | Working       | PSG channels 1–4 + DMA channels A/B; SDL2 output |
| DMA           | Working       | All 4 channels; video capture mode stubbed       |
| Timers        | Working       | Cascade mode, overflow IRQ                       |
| Interrupts    | Working       | IE/IF/IME; halt/unhalt cycle                     |
| Keypad        | Working       | 10 buttons; stop mode not implemented            |
| Cartridge I/O | Working       | ROM loading; SRAM/Flash/EEPROM save types        |
| RTC           | Partial       | Read/write works; IRQ not implemented            |
| Serial I/O    | Stubbed       | Registers discarded silently                     |
| HLE BIOS      | Partial       | Halt/IntrWait/VBlankIntrWait; other SWIs are no-ops |
| Real BIOS     | Working       | Pass `[bios.bin] [rom.gba]` to use               |
| GB/GBC CPU    | Working       | SM83, all 512 opcodes                            |
| GB/GBC PPU    | Working       | Scanline + FIFO renderers; CGB palettes/HDMA     |
| GB/GBC APU    | Working       | Channels 1–4; correct SDL2 float32 LE output     |
| GB/GBC MBC    | Working       | ROM, MBC1/2/3/5; battery saves                  |
| GB/GBC Timer  | Working       | DIV/TIMA/TMA/TAC; falling-edge detection         |
| GB/GBC Misc   | Working       | Joypad, OAM DMA, CGB double-speed, WRAM banks    |

### GB APU: lazy closed-form waveform catch-up (replaces per-period scheduler events)

**Problem**: `gb/apu/channel{1,2,3,4}.nim` scheduled one scheduler event per
waveform period. A square channel's period is `(0x800 - frequency) * 4` T-cycles,
so a channel parked near frequency `0x7FF` fires every few cycles. Alone in the
Dark leaves ch1/ch2/ch3 parked at ~`0x7FC` while all three are **disabled**, and
measured **20,113 channel events per frame, 100% of them on disabled channels**,
producing no audio at all. (The often-quoted 70,224/frame is the theoretical
ceiling — four channels at exactly `0x7FF` — not a state any measured title
reaches.) Pokemon Crystal spends 8,778 events/frame in the noise channel and
Tetris 3,996.

**Fix**: each channel now carries `next_step`, the absolute scheduler cycle of
its next waveform step, and is advanced *in closed form* only when something can
observe it. A square's duty counter is a free-running mod-8 counter, so N periods
of advance is `pos = (pos + N) and 7`; the wave pointer is mod-32. Cost is
independent of frequency, and a disabled channel costs nothing at all until the
next thing that can see it. This is what mGBA (`GBAudioRun`, `src/gb/audio.c:503`
— `diff /= period; index = (index + diff) & 7`) and Gambatte
(`DutyUnit::updatePos`) do. Phase is preserved exactly, so a trigger still
inherits the free-running duty position the way hardware does — hardware only
resets the duty counter on an APU power-off, which is why *parking* disabled
channels (freezing the phase) would have been wrong even though SameBoy does it.

Channel 4 still iterates: the LFSR has no cheap closed form (Gambatte exploits
`reg ^ reg>>1` == 15 shifts; not worth the divergence risk). The win there is
that it iterates in a tight loop instead of paying a scheduler insert + heap pop
+ closure dispatch per shift.

**Observation points** (the whole correctness argument; the list is in
`gb/apu.nim` above `apu_catchup_all`): `etAPUSample`; wave RAM read *and* write
at `0xFF30-0xFF3F`; `PCM12`/`PCM34` at `0xFF76`/`0xFF77` (stubbed to 0x00 today,
but the sync call is wired up so the real implementation drops in); every
`0xFF10-0xFF26` register write; frame-sequencer ticks (`length_step` can clear
`enabled`, which parks ch4; `sweep_step` rewrites `ch1.frequency`); `NR52`
channel-active bits (report `enabled`, which no catch-up changes — no sync
needed); the CGB speed switch; the per-frame `scheduler.rebase()`; and save
states / rollback snapshots.

Two things fall out of the rebase hook being mandatory: it bounds how stale a
deadline can get (one frame), which bounds ch4's loop and keeps the wasm build's
`uint32` `CycleCount` from wrapping under a channel nobody has looked at.

**Save-state format is unchanged.** Rather than append four fields to a
positional, unversioned format, `savestate.nim` round-trips `next_step` through
the `etAPUChannel<N>` events it replaced (`apu_arm_state_events` /
`apu_extract_state_events`). Verified: a state written by this build is
**byte-identical** to one written by the pre-change build, and each loads in the
other. That also keeps rollback/netplay snapshots interchangeable.

**The scheduler tie-break had to be reproduced.** When a waveform step landed on
exactly the cycle an observing event ran on, both were due at the same cycle and
`Scheduler.schedule` gave priority to the more recently scheduled one — i.e. the
one with the *shorter* period, since each re-arms itself one period ahead. So a
channel whose period is shorter than the observer's stepped first, and a longer
one stepped after. Getting this wrong is the difference between "phase-exact" and
bit-identical: before modelling it, 7 of 8 test titles differed in the PCM diff;
after, 5 of 8 are byte-identical. See `gb_steps_due` in `apu/abstract_channels.nim`.

**Known non-exact case (deliberate).** When a channel's step period is *exactly*
equal to an observing event's period, the two events were armed on the same cycle
and the old code's tie winner **alternated** with every shared cycle — producing
0 then 2 steps per sample rather than 1. The alternation phase depends on
insertion history and cannot be reconstructed without new serialized state, so
this resolves them uniformly as "include" (one step per sample). Every remaining
PCM difference against the pre-change build is confined to this case: measured
over 3.3M samples per title, 100% of differing samples were on a channel whose
period was exactly 128 T-cycles = `GB_SAMPLE_PERIOD` (ch4 with `NR43 = 0x22` is
the common trigger; squares hit it at frequency `0x7E0`, ch3 at `0x7C0`). It
affects 0.02–0.13% of samples by a fraction of one channel's DAC swing, and the
uniform behaviour is the more defensible of the two — a period equal to the
sample interval *should* advance one step per sample. Cross-checked against
SameBoy: per-100ms RMS envelope Pearson is identical to 4 decimal places between
the two builds (Pokemon Blue +0.9735 vs +0.9734, Crystal +0.9967 both, Oracle of
Seasons +0.9996 both), i.e. the difference is below the resolution of the
cross-emulator gate. Making it bit-identical would cost a per-channel tie-parity
bit in the save state, breaking format compatibility, to reproduce an artifact of
our scheduler's insertion order that no hardware behaviour corresponds to.

**APU oracle (built for this change; there was none before).**
- `./dingbat_test_runner --apu` runs 94 GB APU cases — blargg `dmg_sound` (7/12),
  blargg `cgb_sound` (12/12), SameSuite `apu` (3/70). Opt-in so the default run
  stays at 169/137/32. Two harness fixes were needed to make blargg's sound ROMs
  score at all: `tmSram` latched the `0x80` "still running" status as the verdict,
  and a stale `.sav` next to the ROM was read back as the verdict at frame 0.
- `DINGBAT_GB_AUDIO_DUMP=<path>` writes the mixed GB output as raw s16le stereo
  at 32768 Hz, from the headless test build; `tools/pcmdiff.py` diffs two dumps
  byte-for-byte (strict) or by cross-correlation and RMS envelope (`--correlate`).
  Byte-comparing two builds' PCM is the audio equivalent of the byte-identical
  screenshot gate, and it is what caught the tie-break bug — the framebuffer was
  identical across all 140 sweep titles the whole time.
- `GBFUZZ_PCM=<path>` + `GBFUZZ_PCM_FRAMES=<N>` do the same for SameBoy in
  `tools/gbfuzz/sameboy_runner.c`. Sample equality with SameBoy is not achievable
  (it band-limits and models DAC charge); use `--correlate`, gate on envelope
  Pearson >= 0.7. `GBFUZZ_PCM_HIGHPASS=off|accurate|dc` picks whether SameBoy
  applies its hardware DC blocker; `off` is the like-for-like setting against a
  dingbat dump, `accurate` is the hardware reference.
- `tools/popscan.py` measures *pops* rather than differences: it tracks the
  signal's local mean over a window long enough to average musical content away
  (default 31 ms, so everything above ~32 Hz cancels) and counts step changes in
  it. A step in the DC level is what a speaker reproduces as a click, and it is
  comparable across emulators. Do NOT use a raw sample-delta threshold for this —
  a Game Boy square wave is full-scale sample-to-sample jumps by nature, so that
  measures how much music is playing, not how much popping.
- `tools/gbaudio_at.py <ref> --rom <path>` builds dingbat at an arbitrary git ref
  in a `git archive` scratch tree (never touching the worktree, index or stash),
  injecting the `DINGBAT_GB_AUDIO_DUMP` hook when the ref predates it, and dumps
  PCM. That is what makes "is this audio artefact a regression?" answerable; the
  dump hook itself only exists from c7fb1a7 onward.

**Measured** (best-of-7, interleaved, `.sav` cleared, per-build ROM copies;
noise floor from two builds of identical source was −1.24%..+0.59%):
Alone in the Dark in-game **+6.1%**, Pokemon Crystal in-game **+7.1%**, Crystal
boot **+13.3%**, Tetris **+7.7%**, Shantae +2.4%, Zelda: Link's Awakening +0.7%.
The per-event cost works out at ~3 ns, so the win scales linearly with the event
count a title was burning; the theoretical 70,224/frame ceiling would be ~+27%.

### GB core: generalising lazy catch-up past the APU (2026-07-26, branch `lazy-catchup`)

Follow-up to the APU work above: the same "keep a last-synced cycle, materialise
only at the points that can observe it" idea applied to the rest of the GB core,
plus the dispatch cost it exposed once the event traffic was gone.

**Profile first** (Apple M-series, `sample`, self time, idle threads excluded).
Alone in the Dark and Pokemon Blue, in-game after a scripted nav, at `c7fb1a7`:

| symbol | AitD | Blue |
|---|---|---|
| `fifo_tick` | 17.7% | 18.4% |
| `tick_shifter` | 12.8% | 22.1% |
| `mem_tick_components` | 17.0% | 11.9% |
| `read_byte` | 8.7% | 8.1% |
| `timer_tick_slow` | 7.9% | — |
| `mbc_read` (2 instantiations) | 7.0% | 6.1% |
| `tick_bg_fetcher` (incl. `.cold`) | 5.4% | 9.8% |
| `chckNilDisp` | 1.7% | 1.5% |

i.e. PPU ~48% / ~54%, memory path ~16%, everything else small. The one place this
differs from an earlier profile is the timer: Blue never enables it, Alone in the
Dark runs it with TAC=`0b01` (tap bit 3, an edge every 16 T-cycles) and pays 8%.

#### 1. FIFO PPU: idle spans cost no call (bit-identical)

Modes 0, 1 and 2 do nothing until the dot counter reaches a single trigger value,
and together they are ~65% of the 70,224 dots in a frame. The loop inside
`fifo_tick` already collapsed those dots — but `fifo_tick` itself was a
non-inlined call made once per 4 T-cycles of *every* memory access, ~17,500 times
a frame, just to reach that collapse. The skip branch is now an `{.inline.}`
prologue and the loop moved to `fifo_tick_slow`.

**Observation points** (at the guard in `fifo_ppu.nim`): while a span stays
strictly inside one idle stretch there is no mode change, no LY change, no
STAT/VBlank interrupt, no HDMA block and no pixel. Two level-triggered rules opt
out and fall through to the loop exactly as they did inside it — mode 3, and
mode 1 with LY 153 — as does an LCD that is off. `read_mode` is still latched on
the fast path: `mode_flag` cannot change there, but a *preceding* slow tick may
have changed it, and a STAT read would then observe a mode two M-cycles old.

#### 2. Timer: closed-form TIMA (bit-identical)

The fast path bailed to the per-cycle loop as soon as one falling edge of the
tapped DIV bit landed in the span. The number of edges in `(t0, t1]` is
`floor(t1/2^s) - floor(t0/2^s)` for `s = bit_for_tima + 1`, and that count *is*
the TIMA advance — `previous_bit` is high at every one of those cycles by
construction. Exact across the divider's 16-bit wrap because 65536 is a multiple
of `2^s` for every tap (`s <= 10`), so `t1` can be left unwrapped for the shift.

A TIMA **overflow** is the one case that is not closed form: it arms a 4-cycle
countdown whose expiry (reload from TMA + the timer IRQ) has to land on its own
cycle, and the countdown can expire inside the same span. That still falls through
to the loop — which is also the only path that raises an interrupt, so the lazy
path provably cannot skip one. A *disabled* timer now short-circuits before
computing the tap at all, which is where Pokemon Blue's share of this win is.

The full lazy form (drop `timer_tick` from `mem_tick_components` entirely and
schedule the next overflow, as mGBA's `GBATimerUpdateRegister` does) was **not**
done: DIV is also the GB serial clock's tap, and `timer_tick_slow` drives
`serial_tick` per cycle, so a fully lazy timer needs the serial shifter's
observation points too. Closed-form batching gets most of the win with none of
that coupling.

#### 3. Mode 3: one dispatch per span, not per dot (bit-identical)

Mode 3 is the one mode with genuine per-dot work, so it cannot be collapsed —
but it does not need the mode re-decoded on each of its ~26,000 dots a frame
either. Nothing inside the pixel pipeline changes the mode: only the
`lx >= GB_WIDTH` test does, and that becomes the loop condition, with the dot
that actually ends mode 3 still handled by the generic path. Worth **+1.8%** on
its own on three of four titles measured, which is more than the shape of the
change suggests.

#### 4. ROM window: devirtualised (bit-identical, and machine-checked)

Once the event traffic was gone, `mbc_read` — a Nim `method`, so dynamic dispatch
+ `chckNilDisp` + the post-call error-flag test Nim's goto-exceptions emit — was
the biggest single non-PPU cost, for what is almost always one array index. For
every mapper except MBC6 the CPU's 0x0000-0x7FFF window is two flat 16 KiB views
into `rom`. A new `mbc_rom_map` method returns the two base offsets (written next
to each mapper's own `mbc_read`, in the same expressions, so they cannot drift
apart unnoticed) and `read_byte` indexes the buffer directly — same index, so the
same bounds check.

**Observation points** here are "what can move the bases", all three enumerated
and resynced in `mbc/mbc.nim`: any cartridge write below 0x8000; cartridge
construction (MBC1 multicart detection, MMM01 `rom_rotate`); and save-state /
rollback-snapshot load, which writes the banking registers back directly rather
than through `mbc_write`. **Missing that third one would have left every rollback
restore reading the pre-load ROM bank** — it is the kind of gap that produces a
netplay desync rather than a visible bug.

MBC6 opts out (0x4000-0x7FFF is two independent 8 KiB windows, each ROM or
flash — there is no single `hi`). TAMA5 opts out because its ROM bank comes from
registers written through 0xA000-0xBFFF, which is *not* one of the resync points;
covering it would cost a virtual call on every cart-RAM write for one cartridge.

**Proved, not argued**: `-d:mbc_map_check` compiles every ROM read as "compute
both, compare, abort on mismatch". Over 160 sweep titles — the 140 regular ones
plus `tools/gbfuzz`'s mapper set, which is where the HuC1/HuC3/MBC7/MMM01/TAMA5
coverage lives — it never fired, and that build's screenshots were byte-identical
to baseline. The harness was falsified first: skewing the MBC5 base by 16 makes it
abort on Alone in the Dark inside 350 frames.

#### Measured

Wall clock was unusable — the machine sat at load ~18, where best-of-9 interleaved
runs still swung ±2.6% between two builds of *identical source*. **Instructions
retired** (`/usr/bin/time -l`) repeated to ±0.5% on the same pair and is the
primary metric below; wall clock (best of N, interleaved, per-build ROM scratch
dirs, `.sav` cleared) is the sanity check.

| title | instructions | wall (best of 9) |
|---|---|---|
| Alone in the Dark | **+18.8%** | +28.6% |
| Shantae | **+14.9%** | +13.4% |
| Zelda: Link's Awakening DX | **+12.1%** | +11.3% |
| Pokemon Blue | **+11.6%** | +11.4% |
| Tetris | **+11.2%** | +11.3% |
| Pokemon Crystal | **+8.0%** | +9.4% |

Gates, all against a baseline build of `c7fb1a7`: `dingbat_gb_nav` checkpoint
screenshots byte-identical on 140/140 sweep titles; `DINGBAT_GB_AUDIO_DUMP` PCM
byte-identical on 6/6 titles; `dingbat_test_runner` 169/137/32 with `results.md`
differing only in its timestamp; `--apu` 22/94 with identical per-test verdicts;
`gbhdmatest.gbc` screenshot byte-identical; `gblinktest` PASS; `stateroundtrip`,
`rollback` and `rollbacknet` MATCH; save states byte-identical across builds and
cross-loadable (MBC1/MBC3/MBC5, 300 frames to the same framebuffer hash);
headless, native SDL and wasm all build.

#### Tried and rejected

**Mode 3 cannot be made lazy in the useful sense.** The pixel pipeline is the
remaining ~35% of the GB profile and it is genuinely per-dot. It is worth being
precise about *why*, because the naive argument says it should work: the
framebuffer is not CPU-observable until the frame ends, LY and the STAT mode bits
are constant throughout mode 3, VRAM/OAM stay blocked throughout, and no interrupt
fires until it ends. So in principle the whole of mode 3 could be deferred.

Two things kill it. First, the CPU can *write* VRAM, OAM (including via OAM DMA)
and the PPU registers mid-line, and the renderer reads all of those per dot — so
the pipeline must be materialised before any such write, and a raster-effect game
does exactly that. Second, and fatally: **the end of mode 3 is observable** (it is
the mode-0 STAT interrupt, the HBlank DMA trigger, and when VRAM becomes
accessible again), and its exact dot is not known without running the pipeline.
A hybrid would therefore have to either (a) use the analytic mode-3 length formula
— which is an approximation of what this FIFO produces and would move timing on
the mooneye/mealybug tests, i.e. an accuracy regression — or (b) run the line
speculatively and roll back on a mid-line write. (b) is bit-identical in principle
but the win is only the outer loop's dispatch, since the per-dot work is unchanged,
and it would be *slower* for exactly the raster-effect titles that need the FIFO in
the first place.

The cheap subset of the idea — not re-dispatching the mode per dot — is item 3
above and is worth +1.8%. That is all that was on the table.

Note also that dingbat's existing scanline renderer is not a drop-in for the
"batch a clean line" half of a hybrid: it does not produce the FIFO's pixels
byte-for-byte, so using it per-line would fail the screenshot gate. A hybrid
needs a *new* batch renderer that is bit-exact with the FIFO.

**Sprites as a fixed `array[10, GbSprite]`** instead of a `seq`: reverted.
`tick_shifter` consults the list on every mode-3 dot, and the seq costs a pointer
chase plus a bounds check to reach element 0, plus a heap allocation, an ARC
destructor and an `O(n) delete(0)` per line — it looked like a clear win.
Measured: **0.3-0.6% WORSE** in instructions retired on 4 of 6 titles, neutral on
the other two. The insertion sort's explicit shift loop costs more than the seq's
`memmove`, and 50 bytes of inline array pushes the genuinely hot `GbFifoPpu`
fields (the FIFO, `lx`, the fetcher counters) further apart. Not worth re-trying
without a layout change.

**Turning off bounds checks** on the hot path would be a large win — the native
build is `-d:release`, which keeps `raiseIndexError2` and therefore the
`nimErrorFlag()` test after every call in `read_byte` — but that is a project
policy decision, not a perf change, and the codebase has at least one comment
(The Fish Files, `tick_bg_fetcher`) about an out-of-bounds VRAM read that a check
caught. Left alone. Worth knowing that the **wasm** build already compiles with
`-d:danger`, so its profile is not the same shape as the native one.

#### GBA core: the same idea — the census that motivated the work

**The GBA PSG had
has the exact pre-`c7fb1a7` problem, and worse.** `gba/apu/channel4.nim`'s
`ch4_step` reschedules `etAPUChannel4` unconditionally — not even gated on
`enabled` — and with the power-on divisor that is one event every 32 cycles,
8,778 per frame. Measured event census over 1200 frames: `etAPUChannel4` is
**81.3%** of all scheduler events in Pokemon Emerald, 75.8% in Golden Sun, 83.5%
in Mother 3, 81.5% in Kirby, and the count is the same ±0.2% in all four because
it is fixed by the reset divisor rather than by anything the game does.

The damage is larger than the event count suggests: a permanent 32-cycle
`next_event` horizon defeats three separate inline fast paths — `scheduler.tick`,
`bus.catch_up` (so every MMIO access takes the slow path), and
`scheduler.fast_forward`, which is what HALT and the whole waitloop-detection
subsystem rely on. Mother 3 spends 46% of its runtime in `schedule` +
`fast_forward` alone.

Measured with a proxy that does the same LFSR work without the event chain,
framebuffer-hash-identical: **−12% to −31% instructions retired, +14% to +45%
throughput** (Kirby +45%, Emerald +41%, Golden Sun +29%, Mother 3 +14%).
Note the cheap half-fix — gating the reschedule on `ch.enabled` — measures
**exactly zero**: the m4a driver leaves CH4 genuinely enabled, so unlike Alone in
the Dark on the GB there is no parked-silent-channel shortcut. The win requires
the real lazy conversion.

The port is near-mechanical and *simpler* than the GB one: no CGB speed switch, no
PCM12/PCM34 observation point, and `gba.end_frame` already does the rebase (with
`keep_phase_mask`) that bounds staleness. The pieces: `next_step` on each channel;
observation points at `get_sample`, `tick_frame_sequencer`, `0x60-0x89` register
writes, wave-RAM read/write while CH3 is enabled, and `end_frame`; drop
`etAPUChannel1..4` from `gba_dispatch` while **keeping the enum ordinals** (they
are savestate format); round-trip `next_step` through those events in
`gba/savestate.nim` as the GB one does. One extra hazard the GB did not have:
`gba/rollback.nim`'s `LinkSnapshot` must carry `next_step` — see
`rollback-multirecv-desync` in the notes for what happens when it does not.

Everything else on the GBA is already lazy or already scheduler-driven, and that
is the more useful half of the finding: the **timers** are a textbook
implementation of this exact pattern (`ticks_between(anchor, now, period)`, one
overflow event per running channel, cascade channels scheduling nothing —
matching mGBA's `GBATimerUpdateRegister` and NanoBoyAdvance's
`Timer::ReadCounter`); the **PPU** is already collapsed to one `ppu.scanline()`
per line driven by 4 events, and its state is a function of VRAM/OAM/PRAM
*contents* rather than of elapsed cycles, so it is not a candidate at all;
**DMA** bursts are per-unit on purpose (that is what implements priority
preemption and the CPU stall accounting); the **bus** already *is* a lazy
catch-up and is a victim of the APU rather than a candidate; **SIO** schedules
one completion event.

Reference points for the PSG work: mGBA's `GBAudioRun` (`src/gb/audio.c:485`) is
shared by its GB and GBA cores and has **zero** per-channel events — only
`sampleEvent` and the frame sequencer — and batches ch4's LFSR ("Batch 5 steps at
a time when possible"). NanoBoyAdvance's `QuadChannel::Generate` /
`NoiseChannel::Generate` are where dingbat is today, i.e. one event per waveform
sub-period; it is not a design to copy for a constrained target.

#### GBA core: landed

Done, on `gba-apu-lazy`. Numbers are instructions retired (`/usr/bin/time -l`),
min of 7 interleaved runs from an in-game save state, 900 frames; the noise floor
from two runs of the same binary was **±0.002%** on the min and ≤0.078%
run-to-run spread. fps is best-of-7 (noise ±0.56%).

| title       | instructions | fps      |
|-------------|--------------|----------|
| Golden Sun  | **−9.5%**  | **+16.2%** |
| Mother 3    | **−4.8%**  | **+12.6%** |
| Pokemon Emerald | **−2.2%** | **+6.4%** |
| Kirby: Nightmare in Dream Land | **−2.5%** | **+5.8%** |

Scheduler dispatches per frame fell from ~10,800 to ~1,970 (−82%);
`etAPUChannel4` alone was 8,778/frame — 81% of all events — in every one of the
four titles, as the census above predicted.

**That is a lot less than the +14-45% the proxy promised, and the gap is the
interesting part of this round.** See "the bound" below: the proxy measured a
build that had silently coarsened every idle loop in the machine, and buying that
accuracy back costs Emerald 44 points of throughput and Kirby 20. Golden Sun and
Mother 3 keep essentially all of theirs, because their win came from the dispatch
cost rather than from deeper skips.

The observation points are enumerated above `apu_catchup_all` in `gba/apu.nim`.
Two GBA-specific notes: the wave channel's 64-step mode flips `wave_ram_bank`
once per wrap, so the closed form is `bank ^= ((pos + N) div 32) and 1`; and
channel 4's old `ch4_step` re-armed **unconditionally**, so unlike the GB there is
no park-when-disabled case to model — a triggered chain runs until
`RegisterRamReset` or a re-trigger. CH4 still iterates the LFSR (a tight loop, not
one scheduler dispatch per shift); mGBA batches 5 shifts at a time and there is a
clean closed form for k ≤ 14 shifts (`s' = (s >> k) | (((s xor (s>>1)) and ((1<<k)-1)) << (15-k))`,
valid while the feedback bits are still original state), but at the measured
8,778 shifts/frame the loop is ~0.3% of a frame and it was not worth the
divergence risk. Build with `-d:psgverify` to shadow every closed-form catch-up
with the per-period loop it replaced and assert they agree.

**The tie-break needed one more piece than the GB version.** When a waveform step
lands on exactly the observer's cycle, the old scheduler resolved it in favour of
whichever event was armed more recently — i.e. the shorter *delay*, which is not
always the current period: a frequency write changes the period without moving
the already-armed step, and a trigger arms with the frequency timer in force at
trigger time (+6 on CH3). Channels therefore carry `arm_delay` alongside
`next_step`. Modelling only "current period" left Mother 3 differing on 0.075% of
samples. `arm_delay` is transient (rebuilt as the current period on state load);
the state format is unchanged, which is what keeps rollback/netplay snapshots
interchangeable.

##### The bound, and why the first attempt regressed

Taking events out of the scheduler is **not** behaviour-neutral, because two
places in the core decide how far to skip the clock by reading
`scheduler.next_event`:

1. `cpu.tick`'s idle-loop path calls `scheduler.fast_forward()`, which snaps
   `scheduler.cycles` to `next_event` and discards the loop body's own cycles.
   A spin loop re-reads what it polls once per skip, so **the skip length is that
   loop's sampling resolution**, and the body's fetches move `rom_free_since`,
   which is absolute-cycle state.
2. `dma.nim`'s mid-burst preemption check only drained accumulated bus cycles
   into the scheduler when an event was already due, so `scheduler.cycles` (the
   anchor for anything the burst schedules) lagged the burst's true position.

The PSG's 32-cycle channel-4 chain was holding both at a fine granularity **by
accident**. The first version of this branch removed it and left both unbounded,
which measured as: the mGBA suite's six "H-blank bit start Flip" values — a loop
that spins on DISPSTAT and times the gaps with TM0 (`suite/src/misc-edge.c`) —
went from 3-48 cycles out to **124-394** (one of them landed on exactly 0x200,
the 512-cycle sample-event period, which is what gave the mechanism away), and
Emerald's and Mother 3's PCM drifted on 1.27% / 0.49% of samples.

The fix is to state the bound instead of inheriting it: the deadlines are still
events, they just live outside `evbuf`, so both places consult
`apu_next_step()`. `scheduler.fast_forward_bounded` takes the ceiling; the DMA
drain takes `min(next_event, apu_next_step())`. With that, every row of
`results_mgba_suite.md` and all four titles' PCM are byte-identical to `main`.

Alternatives measured and rejected:

* **A fixed cap on the skip** (`cycles + N`, N a constant, `-d:gbaskipcap=N`) —
  physically the more defensible bound, since a real Thumb spin loop resolves ~15
  cycles. It is measurably more accurate and *substantially slower*, and an
  earlier revision of this note recorded only the first half. Measured 2026-07-26,
  instructions retired (min of 5) on Pokemon Emerald from an in-game save state,
  against the shipped adaptive bound:

  | bound                | suite | H-blank err | instructions |
  |----------------------|-------|-------------|--------------|
  | `apu_next_step()`    | 6910  | 130 cycles  | —            |
  | N=4                  | 6912  | 59          | **-65.6%**   |
  | N=8                  | 6910  | 83          | -50.1%       |
  | N=16                 | 6910  | 77          | -33.4%       |
  | N=32                 | 6913  | 89          | -19.1%       |
  | N=64                 | 6912  | 125         | -9.2%        |

  So it is a monotone accuracy/throughput trade with no free point, not a win
  being left on the table. `apu_next_step()` beats every constant on throughput
  because it is ADAPTIVE: the deadline sits far out while the channels are idle
  and tightens only when they are active, so it buys long skips where they are
  free and short ones where they are observable. A constant can only do one.
  One row (Flip 1) is worse than baseline at every N, and no N reproduces the old
  sampling phase, so audio also stops being bit-identical. Kept behind the define
  rather than adopted: it costs ~1.65x the CPU work in an idle-heavy scene to buy
  71 cycles of H-blank error and two suite tests.

* **Clipping only the adaptive bound's outliers** (`min(apu_next_step(), cycles + N)`)
  — tried at N=128/256/512 hoping to buy accuracy cheaply. It buys none: score,
  total error and all six per-row deltas are IDENTICAL to the unclipped bound at
  every N, while costing -4.6%/-1.3%/-0.02%. The error therefore does not come
  from occasional over-long skips; it comes from the TYPICAL skip being ~32
  cycles rather than ~4, which is exactly the part that cannot be tightened for
  free. Removed.
* **Bounding only loops that poll MMIO** — a PSG step cannot change RAM, so a
  RAM-polling loop looks safe to skip freely, and only 1,800 of Emerald's
  3,875,881 waitloop skips per 600 frames touch MMIO (Kirby 1,200 of 3,020,289;
  Mother 3 7,200 of 7,200; Golden Sun has none at all). It does not work: the
  loop *body* fetches from the gamepak, which moves `rom_free_since`, so how many
  times it runs is observable. Emerald's PCM went straight back to 1.27%.
  Extending the test to "polls MMIO **or** fetches from ROM" is bit-identical
  again, but measured within noise of bounding everything (Emerald +6.29% vs
  +6.42%), because those loops are in ROM. Not worth the extra state.

##### Verification

`-d:psgverify` shadows every closed-form catch-up with the per-period loop the
events used to run and asserts they land on the same state; it passed over 20 GBA
titles × 2000 frames, and a deliberately-broken control confirmed the assert
fires. No title in the sweep set uses CH3's 64-step mode, so `-d:psgdim` in
`tools/romfuzz/dingbat_nav` forces it (~35,000 bank flips per title, verified).
`DINGBAT_GBA_AUDIO_DUMP` + `tools/pcmdiff.py` is the PCM oracle.

Gates, all against a build of `main` at `669eb99`: `dingbat_test_runner`
169/137/32 with `results.md` differing only in its timestamp and **every row of
`results_mgba_suite.md` byte-identical** (6910/7008); `--apu` 94 verdicts
identical (22/94); PCM byte-identical on Emerald, Golden Sun, Mother 3 and Kirby
over 3000 frames both from boot and from an in-game save state, in the default
configuration; `dingbat_nav` checkpoint framebuffers byte-identical on 20/20 GBA
titles; `dingbat_gb_nav` byte-identical on 365/365 GB/GBC titles; stateroundtrip,
rewindtest, linktest ×4, attachtest, rollback, rollbacknet, speclink ×3,
speclinkbench and gbhdmatest all pass; wasm, native SDL and headless all compile.

Two harness facts worth inheriting, because both cost time here:

* **`results_mgba_suite.md` is fully deterministic** — it is a usable gate, both
  columns, all 98 rows. An earlier draft of this note claimed the `Expected`
  column shuffled between runs; that was wrong. `dingbat_test_runner` is only a
  driver: it shells out to `./dingbat_test` for every case, so comparing "two
  runs of the same runner binary" compares whatever `dingbat_test` happens to be
  sitting in the working directory. Rebuild **both**. Note also that the column
  headed `Actual` holds the value the ROM expects and the one headed `Expected`
  holds what dingbat measured — the labels are the wrong way round, and checking
  the first one is a gate that can never fail.
* **Save states are not run-to-run stable for RTC carts.** Two runs of the same
  binary on Pokemon Emerald or Ruby differ in 6 bytes (the payload hash plus the
  game's copy of the clock); non-RTC titles are stable at 0. `dingbat_nav` now
  takes `ROMFUZZ_RTC_EPOCH` to freeze it. The framebuffer gate never needed it.

One state-file caveat, since the GB write-up claimed strict byte-identity and
this one cannot: the payload FORMAT is unchanged and states cross-load between
this build and `main` with identical framebuffer hashes (verified on 5 titles,
both directions), but the re-armed `etAPUChannel*` events are inserted at save
time, so when a channel deadline ties with a real event the two land in the
serialized array in the other order. One checkpoint of 80 across the 20-title
sweep hit it (Mega Man Battle Network at frame 1200: `etAPUChannel2` and
`etPPUEndHBlank` swapped). It is inert here — the dispatch arm for those kinds is
`discard` and the deadline is extracted into `next_step` either way — and
reconstructing the original order would need each event's arm time, which the
scheduler never stored.

## GBA PPU: lazy layer materialization investigated, no-go (2026-07-26)

The question was whether the PSG's lazy catch-up could be carried to the PPU:
render layers on demand and let compositing pull what it needs, so BG pixels
hidden under a higher-priority opaque layer are never produced. `next_layer`
does stop at the first opaque layer, so the wasted work is real in principle.

It is not real in practice, and the reason is measurable. Elision is only sound
on `composite`'s fast path — windows re-enable layers per column, and blending
deliberately reads the layer *underneath* the winner, so with either active
nothing below the top layer is dead. A `-d:ppu_probe` instrumentation counted,
per scanline, how many BGs in the walk sat entirely under fully-opaque coverage:

| title (1200 frames from boot) | scanlines on fast path | BG renders elidable |
|---|---|---|
| Metroid Fusion | 0% | 0% |
| Mega Man Battle Network | 0.3% | 0% |
| Kirby & the Amazing Mirror | 0.5% | 0% |
| Golden Sun: The Lost Age | 2.3% | 0% |
| Superstar Saga | 11.8% | 0% |
| FireRed | 15.6% | 0% |
| FF Tactics Advance | 21.4% | 0% |
| Advance Wars 2 | 31.8% | 0.6% |
| Emerald (title/intro) | 85.8% | 23.8% |
| **Emerald at a real save state** | **0%** | **0%** |

Zero in seven of nine titles. The one encouraging number is Emerald's *intro*,
which is static and unblended; at an actual gameplay save state the same game
runs windows or blending on 100% of scanlines and the figure is 0%. GBA games
use blending and windows more or less constantly, so the precondition for
elision is normally absent.

The deeper reason it does not transfer: the PSG win was **elision**, not
deferral — many wave steps collapsed into one modulo because the intermediate
positions were genuinely never observed, so the work was deleted. Every
composited pixel *is* observed (it goes to the framebuffer), so deferring the
same pixel work later only adds bookkeeping.

Profile for orientation (Emerald at the save state, `sample`, 5149 samples):
PPU rendering ~36% (`next_layer` 14%, `render_reg_bg` 12%, `render_sprites` 6%),
CPU interpreter + bus ~52%, scheduler dispatch ~3%, **entire APU ~1.4%** — the
lazy catch-up work already took the APU off the table, and there is no second
subsystem shaped like it. The GBA has no per-cycle loops (so the GB timer's
bulk-advance trick has no target) and its timers already schedule directly at
the computed overflow cycle.

The probe did find one small real win, which is committed: the per-scanline
`layer_palettes` clear ran for all four BGs unconditionally, and 0.5% (MMBN) to
57% (FireRed) of those clears were for BGs DISPCNT had disabled — never written
(every renderer returns on that bit) and never read (`compute_layer_walk` omits
them). Worth +0.18% to +0.75%.

## GBA PPU slow-path compositing: +3% to +26% (2026-07-27)

Follow-up to the negative result above. Having established that the *fast* path
is rarely taken (0% of scanlines on Emerald at a real save state), the slow path
— per-column window enables, and `next_layer` called 1-3x per pixel — was the
real target. Six commits, `src/dingbat/gba/ppu.nim`, no behaviour change.

What the counters found, which redirected the work:

* **`next_layer` was not actually being inlined** despite its `{.inline.}`
  pragma and the comment claiming it was. `nm` showed a real symbol and
  `composite` held three `bl` calls to it — so every pixel paid a call, a
  tuple return through memory, and a `var int` round-tripping to the stack.
* **Colour math is unreachable for most columns that reach the slow path** —
  52-100% by title, and 100% on the Emerald save state, where `line_effects`
  is false on every column of every line. Reaching the slow path does not mean
  doing slow-path work.
* **The blend "bottom layer" second walk is nearly free** (1.00-1.14 calls per
  column), so optimizing it — an obvious-looking target — would have bought
  approximately nothing.

The shape that won: composite per *window span* rather than per pixel, resolve
the filtered walk and "can colour math apply at all" once per span, then
dispatch to one of three specialized inner loops (opaque / alpha / shade), with
the opaque and shade loops instantiated per walk length.

Measured independently of the agent that wrote it, best-of-5, native:
Metroid Fusion +25.9%, Superstar Saga +21.9%, Kirby +19.3%, Mega Man Battle
Network +16.5%, Emerald@save-state +11.7%, Golden Sun TLA +10.5%, FireRed
+8.3%, Advance Wars 2 +7.6%, FF Tactics Advance +5.3%, Emerald intro +3.4%.

Verification: per-frame framebuffer hashes byte-identical over 730 frames on all
nine titles plus Emerald from the save state; gate 169/137/32; mGBA 6910/7008
with `results_mgba_suite.md` byte-identical to a *freshly generated* main
baseline (the committed one is stale — do not diff against it). Plus the agent's
own randomized differential test, 4000 random register/VRAM/PRAM/OAM
configurations = 640k scanlines, hash-identical, and mutation-tested to confirm
the harness actually reaches bitmap modes, the OBJ window and the blend bottom.

Two findings worth keeping:

* **Splitting the alpha loop into its own proc costs 1.2-2.2%**, while splitting
  out the opaque and shade loops is required (10 instantiations inline cost the
  blend loop 2-5%). The asymmetry is load-bearing; don't "tidy" it.
* **`compute_layer_walk` is not a bottleneck.** A cheaper insertion sort
  measured dead flat (-0.9% .. +0.5%) and was reverted.

Where the next round should go: `render_reg_bg` is now the largest PPU symbol
(13.5% on Emerald@state) and `render_sprites` the largest on MMBN (12.9%).
Compositing itself is down to ~6-10% of total runtime with no runtime checks
left in any of the three loops.

A/B trap that cost me an hour: `rm -f roms/*.sav roms/*.sa1` in zsh aborts the
WHOLE command when either glob has no match, so the save file survives into the
second run and four titles report bogus hash mismatches. Use `find -delete`.

## GB APU: DAC polarity, disabled-channel level, NR50 volume law, headroom (2026-08-01)

Follow-up to the output DC blocker. Three things in the GB mixer were wrong
against Pan Docs; a fourth was a headroom bug the DC blocker had introduced.

**1. The DAC slope was inverted.** Pan Docs, Audio Details / DACs: "the digital
range $0 to $F is linearly translated to the analog range -1 to 1... Importantly,
the slope is NEGATIVE: 'digital 0' maps to 'analog 1', not 'analog -1'."
`chN_get_amplitude` computed `digital/7.5 - 1`, i.e. the other way up. Measured
against SameBoy on identical 60 s runs, peak waveform cross-correlation was
negative on every title (-0.21 to -0.60); it is positive now. Replaced by
`GB_DAC_LUT` in `apu/abstract_channels.nim`.

**2. A switched-off channel was silent instead of parked at a rail.** Pan Docs,
Channels: "a disabled channel outputs 0, which an enabled DAC will dutifully
convert into analog 1"; only a *disabled DAC* "fades to an analog value of 0".
`chN_get_amplitude` gated on `enabled and dac_enabled` and returned 0 for both
cases. It now gates on `dac_enabled` alone and reads the LUT, which is 0 for a
switched-off channel because `chN_dac_input` already returns digital 0 for it.
This is what makes channel on/off transitions continuous (they are on hardware)
while DAC on/off still steps (it does on hardware, and Pan Docs tells drivers to
avoid it). The `enabled` gate on the catch-up in `get_sample` is still correct:
a switched-off channel's amplitude does not depend on its phase either way.

**3. NR50 was `V/7`, not `(V+1)/8`.** Pan Docs, NR50: "A value of 0 is treated as
a volume of 1 (very quiet), and a value of 7 is treated as a volume of 8 (no
volume reduction). Importantly, the amplifier never mutes a non-silent input."
A driver fading NR50 to 0 went fully silent; on hardware it stops an eighth above
silence. `GB_MASTER_VOLUME` (folded with `GB_MIX_SCALE`, one multiply).

**4. Headroom: one channel now gets 1/8 of full scale, not 1/4.** The DC blocker
emits `mix - cap` where the charge tracks the mix's local mean, and both terms
are bounded by the mixer range independently, so the output can reach 2x it. With
fix 2 the mean genuinely does sit near a rail for long stretches. At 1/4 that
clipped: **0.110% of samples in Prehistorik Man and 0.001% in Pokemon Blue hit
the rail** on 60 s in-game runs. At 1/8 overflow is arithmetically impossible,
and it lands on exactly SameBoy's level (`MAX_CH_AMP` 0xFF0 -> four channels =
half of int16), so the two emulators' dumps are now directly comparable without
renormalising. Output is 6 dB quieter than before; it is still louder than the
GBA core (GB in-game RMS 1200-3700 vs GBA 860-1600), so the cross-core balance
improved rather than inverted.

**Result, 60 s in-game per title, dingbat vs SameBoy (CGB-E / DMG-B, hardware
high-pass on, both playing the real boot ROM from frame 0).** RMS gain ratio went
from 2.009-2.090 to 1.002-1.049. Polarity from negative to positive. DC
trajectory (`tools/popscan.py`, threshold scaled per level) now within a few per
cent of SameBoy's on all five titles.

**Conformance: unchanged, per test.** `--apu` before and after: blargg
`dmg_sound` 7/12, `cgb_sound` 12/12, SameSuite `apu` 10/70 — and the pass/fail
list diffs empty, not just the totals. Default suite 182/150/32, unchanged.
**Perf: no measurable change** (a table lookup replaced a float64 divide).
Best-of-5 interleaved with `DINGBAT_GB_AUDIO_DUMP` set on *both* sides, which is
mandatory: with it unset under `-d:test_harness` the mixed sample is unused and
the whole mixer is dead-code-eliminated, so the A/B measures nothing. Crystal
+1.4%, Shantae +0.6%, Blue +0.4%, all inside the noise floor.

**What is still different from SameBoy, and why it is not a bug list.** With gain
and polarity normalised, per-channel realigned correlation over 18 s of Crystal
is CH1 0.974, CH2 0.985, CH3 0.995, CH4 0.43. CH4 is not a broken LFSR: widening
the lag search on a diverged window recovers 0.67 at a 34 ms offset, i.e. the
same sequence at a different time. Two independent emulations of a game drift,
and correlation is brutally sensitive to that — low-passing to 2 kHz barely moves
the number (0.83 -> 0.86), so it is timing, not spectrum. The one systematic
spectral difference is aliasing: dingbat has **~34% more energy above 8 kHz**
because it samples-and-holds the mix at 32768 Hz while SameBoy band-limits each
channel. Band-limited synthesis is the genuinely more faithful model (the
hardware output is continuous-time) and is the obvious next piece of work; it is
also a much larger change with a real per-sample cost.

`GBFUZZ_CHANNELS=<4 chars, '1'/'0'>` now mutes channels in *both*
`tools/gbfuzz/dingbat_gb_nav` and `tools/gbfuzz/sameboy_runner`, which is what
makes per-channel isolation against the reference possible.

Two traps for the next person. Pokemon Crystal is **not** run-to-run reproducible
across a long gap: it is MBC3+RTC and has day/night music, so two dumps taken
hours apart legitimately differ (same binary back to back is byte-identical).
And a 60 s Shantae run drifts far enough from SameBoy that the global
cross-correlation is meaningless either way (0.10); use the first 15 s.
