# TODOs and Known Issues

## TODOs in Code

### `src/crab/gba/bus.nim:84`
```nim
of 0x1: 0'u8  # open bus todo
```
Memory region 0x1 (unmapped between BIOS and EWRAM) should return the proper open bus value (the last fetched instruction word), but currently returns 0. Low-priority; rarely accessed in practice.

### `src/crab/gba/rtc.nim:85`
```nim
if rtc.irq: echo "TODO: implement rtc irq"
```
RTC can signal an IRQ (e.g., every second, or at a set alarm time). The IRQ line from the RTC to the GBA interrupt controller is not wired up. Games that use timed RTC events may behave incorrectly. Medium priority.

### `src/crab/gba/arm/block_data_transfer.nim:13`
```nim
raise newException(Exception, "todo: handle cases with r15 in list")
```
When R15 (PC) appears in the register list of LDM/STM, there are special behaviors (for LDM: load value into PC, optionally copying SPSR to CPSR; for STM: the stored value is PC+12 or PC+8). This is uncommon but used by some games for long jumps/returns. Will crash if hit.

### `src/crab/gba/keypad.nim:15`
```nim
discard  # TODO: stop mode via keycnt
```
KEYCNT (key interrupt control) can trigger a STOP mode when certain key combinations are pressed. Stop mode is a deep sleep state. Not implemented — write to KEYCNT is silently ignored.

### `src/crab/gba/mmio.nim:30`
```nim
of 0x120..0x12B, 0x134..0x15B: discard  # serial, todo
```
Serial communication registers (SIO, JOY bus) are silently discarded. Games that use multiplayer/serial features will not work. Low priority for single-player emulation.

### `src/crab/gba/mmio.nim:36`
```nim
discard  # TODO: stop mode
```
Writing to HALTCNT with bit 7 set should trigger STOP mode (deep sleep until a keypad interrupt). Currently a no-op. Related to the KEYCNT TODO above.

### `src/crab/gba/dma.nim:109`
```nim
echo "todo: video capture dma"
```
DMA channel 3 supports a "video capture" mode that transfers data in sync with the PPU during H-blank for special effects. This mode prints a warning and does nothing. Rare feature; most games don't use it.

---

## HLE BIOS Gaps

Only these SWI numbers are implemented in HLE mode (no BIOS file):

| SWI | Name          | Status      |
|-----|---------------|-------------|
| 02h | Halt          | Implemented |
| 04h | IntrWait      | Implemented |
| 05h | VBlankIntrWait| Implemented |
| 06h | Halt (alias)  | Implemented |
| *   | Everything else | No-op (returns immediately) |

Missing SWIs that games commonly use:
- **01h** (RegisterRamReset) — clears RAM regions
- **08h** (Sqrt)
- **09h** (ArcTan) / **0Ah** (ArcTan2)
- **0Bh** (CpuSet) — fast memory copy/fill
- **0Ch** (CpuFastSet) — faster copy/fill
- **0Dh** (GetBiosChecksum)
- **0Eh** (BgAffineSet) / **0Fh** (ObjAffineSet)
- **10h** (BitUnPack)
- **11h** (LZ77UnCompWram) / **12h** (LZ77UnCompVram)
- **13h** (HuffUnComp)
- **14h** (RLUnCompWram) / **15h** (RLUnCompVram)

Many of these are math/decompression routines. Games that call them as no-ops may display garbage graphics or hang. Using a real BIOS file (`gba_bios.bin`) avoids all these issues.

---

## Known Exception Sites

These `raise newException` calls will crash the emulator if hit. Most represent hardware edge cases that real software rarely exercises:

| File | Condition |
|------|-----------|
| `arm/block_data_transfer.nim:13` | LDM/STM with R15 in register list |
| `arm/halfword_data_transfer_reg.nim:18,31` | SWP instruction encoded as halfword transfer; invalid SH field |
| `arm/halfword_data_transfer_imm.nim:19,32` | Same as above but immediate offset variant |
| `arm/data_processing.nim:87` | Unimplemented data processing opcode (should be impossible with correct decoding) |
| `thumb/move_compare_add_subtract.nim:14` | Invalid op field (should be impossible) |
| `thumb/alu_operations.nim:34` | Invalid ALU op (should be impossible) |
| `thumb/move_shifted_register.nim:14` | Invalid shift op (should be impossible) |
| `thumb/load_store_sign_extended.nim:19` | Invalid HS field |
| `interrupts.nim:26,36` | Read/write to unimplemented interrupt register addresses |
| `ppu.nim:141` | Impossible BGCNT screen size value |
| `ppu.nim:404` | Invalid background mode (> 5) |
| `bus.nim:102,128,156` | Unmapped bus read — address doesn't map to any hardware |
| `apu.nim:113` | SOUNDCNT_H sound_volume field set to 3 (prohibited value) |
| `keypad.nim:12` | Read from unmapped keypad address |
