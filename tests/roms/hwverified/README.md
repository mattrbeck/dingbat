# hwverified — self-judging hardware proof ROMs

One minimal GBA ROM per hardware-verified behavior from the AGS-001
probe sessions (gbaedge pages 8 and 16-27; raw transcriptions in
`../expected/agb-sp-*.txt`, analysis in `docs/hwprobe-results-agb.md`).
Each ROM runs a single experiment at boot, prints the raw observed
bytes as hex and loops forever, so a photo of real hardware and an
emulator screenshot are directly comparable.

This directory is the **canonical, generously annotated** copy — each
`.s` explains what is exercised, how the experiment works, why the
expected values are what they are, and the provenance.  The PR-facing
copies (sparser comments, no repo references) live on the
`hwprobe-test-roms` branch of the NanoBoyAdvance fork; the assembled
`.gba` files are byte-identical.

## Self-judging display

Every ROM carries the hardware-verified expected value for each cell:
matching cells render black-on-white, MISMATCHED cells render inverted
(white on a black block), timing-jittery counts are range-checked
against a band instead of exact-matched (in-band renders normally),
and the runtime also supports blue informational cells (displayed,
never checked) — currently unused.  After everything is drawn, a 4x4
verdict block is painted in the bottom-right corner: GREEN if every
checked cell matched, RED otherwise.  **Automated tests sample pixel
(239,159)**; it stays white until the verdict is painted, so a hang
can never read as a pass.  The CRC line hashes the raw slot and can
vary run-to-run on the ROMs with range-checked cells (irqwin, sweep) —
the cells and the verdict pixel are the judge.

## Running

```
python3 tests/roms/hwverified/run.py
```

builds nothing (the `.gba` files are checked in; `python3 build.py`
rebuilds them with arm-none-eabi-{as,ld,objcopy}) and runs each ROM
through `./dingbat_test <rom> --mode=screenshot --color --nosave
--timeout=600`, sampling the verdict pixel: green = PASS, red = FAIL,
anything else = INCONCLUSIVE (hung or crashed).  `--color` matters:
the harness writes greyscale PPMs by default, which folds green and
red to the same grey.  All 11 pass against current main.  Local runner
only — deliberately not wired into CI.

## The ROMs

| ROM | behavior | jitter handling |
|---|---|---|
| msrtbit | `msr` sets Thumb-bit from ARM: resumes at A+8, skips A+10 | all exact |
| psrmask | PSR write mask is 0xF00000FF, bit4 reads as one | all exact |
| thumbcmp | Thumb hi-reg CMP pc = full SPSR restore; ADD/MOV pc don't touch CPSR | all exact |
| ldmuser | stm^ banked base: banked address, user value, writeback to user bank; post-ldm^ SPSR unchanged | all exact |
| pcwb | r15 base writeback: ldm none, str base+4, ldr base+8 + load suppressed | all exact |
| bxdecode | ARMv5 BLX word executes as BX; BX r15 branches $+8 | all exact |
| irqwin | 3 instructions run after IME/IE stores, 2 after msr, 2 EWRAM loads | ack-survivors word range 6..10 |
| dmabyte | DMA3CNT_H bit7 byte-write anomaly (mirror up, drop low) | all exact |
| capdma | capture DMA runs every line of every armed frame, enable self-clears | all exact |
| sweep | trigger runs the overflow check twice; divider 0 never ticks | tick-1 poll count range 0x800..0x1800 |
| iomap | unused/write-only IO: which registers read zero vs open bus | all exact (open-bus cells are the ROM's own prefetch, deterministic) |

The wedge encoding 0xE120FF11 (locks up a real console) is
deliberately excluded from bxdecode, and msrtbit's experiment is the
one that crashes emulators which mis-handle the MSR — an emulator that
crashes shows as INCONCLUSIVE here, which is itself the finding.
