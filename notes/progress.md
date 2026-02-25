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

## Current Status

| Subsystem     | Status        | Notes                                            |
|---------------|---------------|--------------------------------------------------|
| CPU (ARM)     | Working       | All standard instructions implemented            |
| CPU (Thumb)   | Working       | All standard instructions implemented            |
| PPU           | Working       | Modes 0–5, sprites, windowing                    |
| APU           | Working       | PSG channels 1–4 + DMA channels A/B; SDL2 output |
| DMA           | Working       | All 4 channels; video capture mode stubbed       |
| Timers        | Working       | Cascade mode, overflow IRQ                       |
| Interrupts    | Working       | IE/IF/IME; halt/unhalt cycle                     |
| Keypad        | Working       | 10 buttons; stop mode not implemented            |
| Cartridge I/O | Working       | ROM loading; SRAM/Flash/EEPROM save types        |
| RTC           | Partial       | Read/write works; IRQ not implemented            |
| Serial I/O    | Stubbed       | Registers discarded silently                     |
| HLE BIOS      | Partial       | Halt/IntrWait/VBlankIntrWait; other SWIs are no-ops |
| Real BIOS     | Working       | Pass `[bios.bin] [rom.gba]` to use               |
