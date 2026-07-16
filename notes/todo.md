# TODOs and Known Issues

> Refreshed 2026-07-15. The previous revision of this file was badly out of
> date — most items it listed as open (open-bus recursion, LDM/STM with R15,
> Stop mode, KEYCNT, serial registers, DMA video capture, and nearly the entire
> HLE SWI table) have since been implemented. See
> `docs/frontend-gap-analysis.md` for the full survey. What follows is what is
> *actually* still open, verified against the current code.

## Genuinely open

### RTC IRQ — `src/dingbat/gba/rtc.nim:110`
```nim
if rtc.irq: echo "TODO: implement rtc irq"
```
The RTC can raise an IRQ (per-second, per-minute, or alarm). The IRQ line into
the interrupt controller is not wired up, so games relying on timed RTC
interrupts (rare) behave incorrectly. The `rtc.irq` enable bit is stored and
read back correctly; only the interrupt delivery is missing. Effort: M (needs a
scheduler event + IRQ raise). Risk: medium.

### Deliberate HLE gaps
Using a real BIOS avoids all of these; they only matter in HLE mode.
- **MultiBoot (SWI 0x25)** returns failure — multiboot cable download is not
  emulated (normal link cable play is, via the netcode paths).
- **Sound-driver / music-player SWIs (0x1A–0x1E, 0x20–0x24, 0x28, 0x29)** are
  stubbed — games ship their own sound engine, so this is virtually never hit.

### "Impossible" decode fallbacks
A handful of `raise newException` arms remain in `arm/arm.nim` (×2) and
`thumb/thumb.nim` (×1) for decode cases that correct decoding never produces.
They act as cheap invariant asserts; left in place intentionally.

## Cart peripherals not implemented
GPIO currently drives only the RTC. Tilt/gyro (WarioWare Twisted, Yoshi's
Universal Gravitation), solar (Boktai), and rumble are not wired. Few carts use
them; effort is L each.

## Feature gaps (not bugs)
- No cheat support (GameShark / Action Replay / CodeBreaker) on either front-end.
- Save states: one slot per ROM (the state header reserves a slot byte for more).
- Display filters: only LCD color correction; no scanline/LCD-grid options.
- See `docs/frontend-gap-analysis.md` for the web ↔ native parity matrix.
</content>
