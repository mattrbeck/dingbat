# dbsuite - Detailed Results

*Generated: 2026-09-24 23:38:31 · commit ea5e0019 · game-boy-test-roms v7.0*

tests/roms/dbsuite/dbsuite.gba (cartridge build) in dingbat. Every expected value is an AGB SP (AGS-001) answer; each case's source comment in tests/roms/dbsuite/ gives its provenance. A case that is not PASS here is dingbat disagreeing with the console.

**Total: 843/884**

## cpu (116/117)

| Case | Status | Got / expected |
|------|--------|----------------|
| cpu/thumb-cmp-pc-halfword-skips-the-add | FAIL | got=00000002 exp=00000000 |

## irq (138/145)

| Case | Status | Got / expected |
|------|--------|----------------|
| irq/irqlat-tm2-one-write | FAIL | got=0000007B exp=0000007C |
| irq/irqlat-tm2-two-writes | FAIL | got=00000084 exp=00000085 |
| irq/irqlat-tm2-reload-0000 | FAIL | got=00000073 exp=00000072 |
| irq/irqlat-tm2-reload-0001 | FAIL | got=00000073 exp=00000072 |
| irq/irqlat-tm2-haltcnt-ignored | FAIL | got=00000086 exp=00000087 |
| irq/irqlat-dma3 | FAIL | got=000000B1 exp=000000B2 |
| irq/irqlat-dma3-haltcnt | FAIL | got=000000AB exp=000000AC |

## timer (26/26)

All pass.

## dma (254/262)

| Case | Status | Got / expected |
|------|--------|----------------|
| dma/dmatime-burst-vram-mode3 | FAIL | got=0000009C exp=000000B1 |
| dma/dmatime-completion-irq-after-resume | FAIL | got=0000006C exp=0000006D |
| dma/fifodma-k20-n14 | FAIL | got=00000014 exp=00000050 |
| dma/fifodma-k20-n24 | FAIL | got=0000003C exp=0000005A |
| dma/fifodma-ewram-load-k20-n11 | FAIL | got=00000037 exp=00000036 |
| dma/fifodma-ewram-load-k20-n16 | FAIL | got=0000003C exp=0000003B |
| dma/fifodma-ewram-load-k20-n17 | FAIL | got=0000003D exp=0000005B |
| dma/fifodma-ewram-load-k20-n21 | FAIL | got=0000005F exp=0000005E |

## bus (70/79)

| Case | Status | Got / expected |
|------|--------|----------------|
| bus/contend-pram-mode0 | FAIL | got=000000E6 exp=000000E7 |
| bus/contend-vram-mode0 | FAIL | got=000000E6 exp=000000F6 |
| bus/contend-pram-mode2 | FAIL | got=000000E6 exp=000000E7 |
| bus/contend-vram-mode2-locked-out | FAIL | got=000000E6 exp=0000042A |
| bus/contend-vram-code-blank | FAIL | got=000000B7 exp=000000DC |
| bus/contend-vram-no-obj | FAIL | got=000000E6 exp=000000F8 |
| bus/contend-vram-code-mode0 | FAIL | got=000000B7 exp=000000DD |
| bus/contend-vram-hblank-free | FAIL | got=000000E6 exp=000000F6 |
| bus/obuswint-2-nops-half-dma-word | FAIL | got=60A86019 exp=DEAD6019 |

## ppu (156/156)

All pass.

## apu (36/52)

| Case | Status | Got / expected |
|------|--------|----------------|
| apu/psg-ch1-first-trigger-dies | FAIL | got=0000479B exp=00000000 |
| apu/psg-ch1-nr10-0-dies | FAIL | got=000044BA exp=00000000 |
| apu/psg-ch1-second-trigger-dies | FAIL | got=00004BD9 exp=00000000 |
| apu/psg-soundcnt-x-after-ch1 | FAIL | got=00000081 exp=00000080 |
| apu/sweeptrig-shift0-400-d33 | FAIL | got=00040000 exp=00000001 |
| apu/sweeptrig-shift0-400-d37 | FAIL | got=00040000 exp=00000001 |
| apu/sweeptrig-shift0-400-length-d33 | FAIL | got=00040000 exp=00000001 |
| apu/sweeptrig-shift0-400-length-d37 | FAIL | got=00040000 exp=00000001 |
| apu/sweeptrig-sweep21-1300-d30 | FAIL | got=00000000 exp=00004E25..0000634B |
| apu/sweeptrig-sweep21-1300-d33 | FAIL | got=00000000 exp=00004E33..000062C3 |
| apu/sweeptrig-sweep21-1300-d37 | FAIL | got=00000000 exp=000050E6..000064F0 |
| apu/sweeptrig-shift0-400-after-rows-d30 | FAIL | got=00040000 exp=00000000/00000001 |
| apu/sweeptrig-shift0-400-after-rows-d33 | FAIL | got=00040000 exp=00000000 |
| apu/ram-psg-ch3-first | FAIL | got=0000732E exp=000083FB..00009594 |
| apu/ram-psg-ch4-first | FAIL | got=0000732F exp=000083FC..00009595 |
| apu/ram-psg-ch2-before-ch1 | FAIL | got=00007330 exp=000083F9..00009593 |

## bios (47/47)

All pass.
