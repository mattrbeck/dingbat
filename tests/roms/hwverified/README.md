# hwverified — self-judging hardware proof ROMs

One minimal GBA ROM per hardware-verified behaviour from the AGS-001 probe sessions
(transcriptions in `../expected/agb-sp-*.txt`, analysis in `docs/hwprobe-results-agb.md`).
Each ROM runs one experiment at boot, prints the raw bytes as hex and loops, so a photo of
real hardware and an emulator screenshot compare directly. Each `.s` explains the
experiment and the provenance of its expected values.

## Self-judging display

Every cell carries its hardware-verified expected value: matching cells render
black-on-white, mismatches inverted; timing-jittery counts are range-checked. A 4x4
verdict block is painted bottom-right after everything is drawn — GREEN if every checked
cell matched, RED otherwise. Automated tests sample pixel (239,159); it stays white until
the verdict is painted, so a hang cannot read as a pass. The CRC line can vary run to run
on the range-checked ROMs (irqwin, sweep); the cells and the verdict pixel are the judge.

## Running

```
python3 tests/roms/hwverified/run.py      # python3 build.py rebuilds with arm-none-eabi-{as,ld,objcopy}
```

Runs each committed `.gba` through `./dingbat_test <rom> --mode=screenshot --color
--nosave --timeout=600` and samples the verdict pixel (green PASS, red FAIL, anything else
INCONCLUSIVE). `--color` matters: the default greyscale PPM folds green and red to the
same grey. Local runner only; not in CI.

## The ROMs

| ROM | behaviour | jitter |
|---|---|---|
| msrtbit | `msr` sets the Thumb bit from ARM: resumes at A+8, skips A+10 | exact |
| psrmask | PSR write mask is 0xF00000FF; bit 4 reads as one | exact |
| thumbcmp | Thumb hi-reg CMP pc = full SPSR restore; ADD/MOV pc leave CPSR alone | exact |
| ldmuser | stm^ banked base: banked address, user value, writeback to user bank; SPSR unchanged after ldm^ | exact |
| pcwb | r15 base writeback: PC := writeback address (+4 for ldr, load suppressed) for str/ldr; no writeback for ldm and stm | exact |
| bxdecode | ARMv5 BLX word executes as BX; BX r15 branches $+8 (the wedge encoding 0xE120FF11 is excluded — it locks up a real console) | exact |
| irqwin | 3 instructions run after IME/IE stores, 2 after msr; the window is cycle-counted across four sled compositions | ack-survivor word range 6..10 |
| dmabyte | DMA CNT_H bit-7 byte-write anomaly on all four channels: hi 0x80 → 0080, hi 0xC0 → 4080, lo 0xC0 → 0040, lo 0x80 drops | exact |
| capdma | capture DMA runs every line of every armed frame; enable self-clears | exact |
| sweep | trigger runs the overflow check twice (same offset, strictly >2048) with no write-back; the tick path writes back and re-checks at >=2048; divider 0 never ticks | poll-count ranges at tick-bucket midpoints |
| iomap | unused/write-only IO: which registers read zero vs open bus (open-bus cells are the ROM's own prefetch) | exact |

msrtbit is the experiment that crashes emulators which mishandle the MSR; a crash shows as
INCONCLUSIVE, which is itself the finding.
