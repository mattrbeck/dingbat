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
  Pearson >= 0.7.

**Measured** (best-of-7, interleaved, `.sav` cleared, per-build ROM copies;
noise floor from two builds of identical source was −1.24%..+0.59%):
Alone in the Dark in-game **+6.1%**, Pokemon Crystal in-game **+7.1%**, Crystal
boot **+13.3%**, Tetris **+7.7%**, Shantae +2.4%, Zelda: Link's Awakening +0.7%.
The per-event cost works out at ~3 ns, so the win scales linearly with the event
count a title was burning; the theoretical 70,224/frame ceiling would be ~+27%.
