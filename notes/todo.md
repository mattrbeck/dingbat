# TODOs and known gaps

## Deliberate HLE BIOS gaps (`src/dingbat/gba/hle_bios.nim`)

A real BIOS avoids all of these.

- **MultiBoot (SWI 0x25)** returns failure — multiboot cable download is not emulated
  (link-cable play is).
- **Sound-driver / music-player SWIs (0x1A–0x1E, 0x20–0x24, 0x28, 0x29)** are stubs;
  games ship their own sound engine.

See `docs/hle-bios-shortcomings.md`.

## Cart peripherals

- Solar sensor (Boktai) is not wired; GPIO drives RTC, rumble, tilt and gyro.

## Decode fallbacks

Two `raise newException` arms remain in `arm/arm.nim` for decode cases correct decoding
never produces. They are cheap invariant asserts and stay.

## Open

- GBA save-type database for carts that misreport their type (Classic NES series).
- Debugger with breakpoints and stepping.
- Web audio dropouts under main-thread hitches (`docs/web_audio_pacing.md`).
