# Architecture Notes

## Project Layout

```
crab_nim/
├── src/
│   ├── crab.nim                  # SDL2 frontend (main entry point)
│   └── crab/
│       ├── common/
│       │   └── input.nim         # Input enum (A/B/Start/Select/Directions/L/R)
│       └── gba/
│           ├── gba.nim           # Central hub: all types + includes all other files
│           ├── bus.nim           # Memory map, open bus, HLE BIOS stub
│           ├── cpu.nim           # CPU state, register access, mode switching
│           ├── reg.nim           # CPSR/SPSR bitfield definitions
│           ├── ppu.nim           # Pixel processing unit (video)
│           ├── apu.nim           # Audio processing unit
│           ├── dma.nim           # DMA controller (4 channels)
│           ├── timer.nim         # Timer controller (4 timers)
│           ├── interrupts.nim    # IE/IF/IME registers, IRQ dispatch
│           ├── keypad.nim        # Keypad registers, input handling
│           ├── mmio.nim          # I/O register dispatch (0x04000000–)
│           ├── cartridge.nim     # ROM loading, title extraction
│           ├── storage.nim       # Save type detection + dispatch
│           ├── gpio.nim          # GPIO (used by RTC)
│           ├── rtc.nim           # Real-time clock (GPIO-based)
│           ├── scheduler.nim     # Event scheduler (priority queue)
│           ├── waitloop.nim      # Wait-loop detection optimization
│           ├── pipeline.nim      # ARM/Thumb instruction pipeline
│           ├── arm/              # ARM instruction implementations
│           │   ├── arm.nim       # Decoder + barrel shifter
│           │   ├── software_interrupt.nim  # SWI + HLE BIOS dispatch
│           │   └── ...           # One file per instruction class
│           ├── thumb/            # Thumb instruction implementations
│           │   ├── thumb.nim     # Decoder
│           │   └── ...           # One file per instruction class
│           ├── apu/              # APU channel implementations
│           │   ├── abstract_channels.nim
│           │   ├── channel1.nim  # Square wave + sweep
│           │   ├── channel2.nim  # Square wave
│           │   ├── channel3.nim  # Wave RAM
│           │   ├── channel4.nim  # Noise
│           │   └── dma_channels.nim  # FIFO channels A and B
│           └── storage/
│               ├── sram.nim
│               ├── flash.nim
│               └── eeprom.nim
├── nim.cfg                       # Nim compiler config (SDL2 linking, etc.)
├── crab.nimble                   # Nimble package config
└── reference/crab/               # Original Crystal source (reference only)
```

## Key Design Pattern: include-based monolith

`gba.nim` does NOT use `import` for sibling GBA files. Instead it uses `include`:

```nim
# In gba.nim:
include crab/gba/bus
include crab/gba/cpu
include crab/gba/ppu
# ... etc
```

**Why**: The Crystal original used a similar pattern (files included into a single GBA class). All included files share the same namespace and can call each other's procs freely without import cycles.

**Consequence**: All GBA types (`GBA`, `CPU`, `PPU`, `APU`, `Bus`, etc.) are defined in `gba.nim` using forward declarations. The included files only add procs — they don't define types.

**For new code**: Add proc implementations to the appropriate included file. Add new fields to the corresponding type in `gba.nim`. Do NOT add `import` statements for GBA-internal files.

## Type Definitions (all in gba.nim)

All hardware component types are defined at the top of `gba.nim` using `ref object`:

```nim
type
  GBA* = ref object
    cpu*: CPU
    bus*: Bus
    ppu*: PPU
    apu*: APU
    # ...

  CPU* = ref object
    gba*: GBA       # back-pointer
    r*: array[16, uint32]
    cpsr*: CPSR
    # ...

  APU* = ref object
    gba*: GBA
    audio_dev*: uint32  # SDL2 device ID (1 when open, 0 when not)
    buffer*: seq[int16]
    buffer_pos*: int
    sync*: bool
    # ...
```

Every component holds a back-pointer `gba: GBA` to reach other components.

## SDL2 Bindings

The project links SDL2 via `nim.cfg`:
```
passL = "-lSDL2"
```

The `sdl2` Nim package is used for higher-level SDL2 in `src/crab.nim` (window, renderer, events). For audio, the package is missing `SDL_ClearQueuedAudio`, so `apu.nim` declares raw C bindings directly:

```nim
proc sdl_clear_queued_audio(dev: SDL_AudioDeviceID)
  {.importc: "SDL_ClearQueuedAudio", cdecl.}
```

This works because included files are compiled as part of `gba.nim` which is ultimately linked with `-lSDL2`.

## Audio Architecture

- Sample rate: 32768 Hz (= CPU clock / APU_SAMPLE_PERIOD)
- Format: S16LE stereo (2 channels × int16)
- Buffer: 1024 samples = 512 stereo pairs
- `get_sample()` is called by the event scheduler every `APU_SAMPLE_PERIOD` CPU cycles
- When `buffer_pos >= APU_BUFFER_SIZE`, the buffer is submitted via `SDL_QueueAudio`
- Sync mode (default): spin-wait until SDL's queue < 2 buffers before submitting
- Async mode (toggle with `toggle_sync`): clear the queue before submitting (for fast-forward)

`SDL_OpenAudio` always assigns device ID 1, which is stored as `apu.audio_dev`.

## Scheduler

`scheduler.nim` implements a priority-queue event scheduler. Hardware units schedule future events by calling:

```nim
g.scheduler.schedule(cycles_from_now, callback, event_type)
```

Event types (`etPPU`, `etAPU`, `etDMA`, etc.) allow canceling all events of a given type. The CPU advances cycle-by-cycle and fires events when their deadline is reached.

## HLE BIOS

When no BIOS file path is given, `bus.nim` loads a minimal ARM binary into the first 56 bytes of BIOS memory. Key vectors:

- **0x08** (SWI vector): `MOVS PC, LR` — returns from SWI (only used as fallback; Nim intercepts SWIs first)
- **0x18** (IRQ vector): Minimal dispatcher that reads the user ISR address from `[0x03FFFFFC]` and BLX to it

SWI dispatch is intercepted at the Nim level in `arm/software_interrupt.nim` (`hle_swi` proc). Only a handful of SWIs are implemented; see `todo.md` for the full list.

## Building and Running

```bash
# Release build
nim c -d:release src/crab.nim

# Debug build
nim c src/crab.nim

# Run with real BIOS
./crab /path/to/gba_bios.bin /path/to/rom.gba

# Run without BIOS (HLE mode)
./crab /path/to/rom.gba

# Options
./crab --run-bios  ...   # (default) boot through BIOS intro
./crab --skip-bios ...   # skip BIOS intro (not yet implemented -- currently same as --run-bios)
```

## Crystal → Nim Translation Patterns

| Crystal | Nim |
|---------|-----|
| `class Foo` with mixin | `ref object` types with `include` |
| `@field` | `self.field` (passed as first arg) |
| `Foo.new(...)` | `new_foo(...)` (by convention) |
| `def foo(x : T) : R` | `proc foo(x: T): R` |
| Struct bitfields | `object` with manual bit ops or `bitfield` macro |
| `include Module` | `include file` (but all types must be pre-declared) |
| `UInt8`, `Int16` | `uint8`, `int16` |
| `0x_DEAD_BEEF_u32` | `0xDEAD_BEEF'u32` |
| `raise "msg"` | `raise newException(Exception, "msg")` |
| `puts "..."` | `echo "..."` |
