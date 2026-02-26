# Progress

## Completed Work

### Phase 1: Initial Nim Port (pre-session)
- Ported all Crystal source files to Nim under `src/crab/gba/`
- Fixed all compilation errors (type mismatches, forward declarations, include order)
- Added SDL2 frontend (`src/crab.nim`) with keyboard input and video rendering
- Fixed ARM exception handling

### Phase 2: Runtime Fixes

#### Fix: Infinite recursion / segfault on Kirby ROM
**Problem**: Stack overflow when launching `./crab KirbyNightmareInDreamland.gba`.
- `ppu[]` else-clause called `read_open_bus_value(io_addr)`, which called `read_word_internal(cpu.r[15])`.
- When PC pointed into MMIO space (0x04xxxxxxx), this re-entered MMIO reads → infinite loop.

**Fix** (`src/crab/gba/bus.nim`):
- Added guard in `read_open_bus_value`: if PC is in region 0x4 (MMIO) or > 0xD (unmapped), return 0.

#### Fix: All ROMs freezing on startup
**Problem**: Games rendered the first frame then froze. CPU was executing zeros at BIOS addresses.
- Without a real BIOS file, addresses 0x00–0x3FFF are zero-filled.
- SWI instructions jump to 0x08 in supervisor mode. Zero bytes decode as `ANDEQ R0, R0, R0` — CPU looped forever executing no-ops.
- IRQ vector at 0x18 was also zeros — interrupts also went nowhere.

**Fix — HLE BIOS** (`src/crab/gba/bus.nim`, `arm/software_interrupt.nim`, `thumb/software_interrupt.nim`):

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

**Fix** (`src/crab/gba/apu.nim`, `src/crab/gba/gba.nim`, `src/crab.nim`):
- Added raw C bindings for `SDL_OpenAudio`, `SDL_PauseAudio`, `SDL_QueueAudio`, `SDL_GetQueuedAudioSize`, `SDL_ClearQueuedAudio` (the Nim SDL2 package is missing `SDL_ClearQueuedAudio`).
- In `new_apu`: call `SDL_OpenAudio` with 32768 Hz, S16LE, stereo, 512 samples/buffer. Unpause with `SDL_PauseAudio(0)`.
- In `get_sample`: when buffer fills, optionally clear queue (async mode) or throttle until queue < 2 buffers (sync mode), then `SDL_QueueAudio`.
- Added `audio_dev: uint32` field to `APU` type in `gba.nim` (`SDL_OpenAudio` always assigns device ID 1).
- Moved `sdl2.init(INIT_VIDEO or INIT_AUDIO)` in `crab.nim` to before `new_gba()` — APU opens the audio device during construction.

### Phase 3: ARM Instruction Set Correctness

#### Fix: LSL by 32 (test 152 in gba-tests/arm)
**Problem**: `word shl 32` for a `uint32` is undefined behavior in C/Nim. On x86, the hardware
takes shift amount mod 32, so `1 shl 32 = 1` instead of 0. This caused `LSLS r0, r1` (r1=32)
to produce result=1 (Z clear) instead of result=0 (Z set), failing the branch test.

**Fix** (`src/crab/gba/cpu.nim` — `lsl` proc):
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

**Fix** (`src/crab/gba/arm/multiply_long.nim`):
Changed `res` from `int64` to `uint64`, matching Crystal's `UInt64` type. The signed path uses
`cast[uint64](int64_product)` (bitwise reinterpret, no range check). All arithmetic and
`set_reg` calls now use pure `uint64` — no checked conversions.

#### Fix: STM^ user-bank register access (test 511 in gba-tests/arm)
**Problem**: Nim's `defer` is scoped to its **enclosing block**, not the enclosing proc. The
`if s_bit:` block used `defer: cpu.switch_mode(saved_mode)`, which fired immediately when the
`if` block ended — before the transfer loop. The STM then ran in the original (FIQ) mode,
storing FIQ-banked r8 (64) instead of USR-banked r8 (32).

**Fix** (`src/crab/gba/arm/block_data_transfer.nim`):
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

**Fix** (`src/crab/gb/apu.nim`):
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
