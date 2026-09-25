# dbsuite - Detailed Results

*Generated: 2026-09-25 02:22:34 · commit a5854d68 · game-boy-test-roms v7.0*

tests/roms/dbsuite/dbsuite.gba (cartridge build) in dingbat. Every expected value is an AGB SP (AGS-001) answer; each case's source comment in tests/roms/dbsuite/ gives its provenance. A case that is not PASS here is dingbat disagreeing with the console.

**Total: 861/884**

## cpu (117/117)

All pass.

## irq (145/145)

All pass.

## timer (26/26)

All pass.

## dma (258/262)

| Case | Status | Got / expected |
|------|--------|----------------|
| dma/dmatime-burst-vram-mode3 | FAIL | got=000000B2 exp=000000B1 |
| dma/fifodma-k20-n14 | FAIL | got=00000014 exp=00000050 |
| dma/fifodma-k20-n24 | FAIL | got=0000003C exp=0000005A |
| dma/fifodma-ewram-load-k20-n17 | FAIL | got=0000003D exp=0000005B |

## bus (76/79)

| Case | Status | Got / expected |
|------|--------|----------------|
| bus/contend-pram-mode0 | FAIL | got=000000E6 exp=000000E7 |
| bus/contend-vram-mode0 | FAIL | got=000000F4 exp=000000F6 |
| bus/contend-vram-mode2-locked-out | FAIL | got=0000042E exp=0000042A |

## ppu (156/156)

All pass.

## apu (36/52)

| Case | Status | Got / expected |
|------|--------|----------------|
| apu/psg-ch1-first-trigger-dies | FAIL | got=00004731 exp=00000000 |
| apu/psg-ch1-nr10-0-dies | FAIL | got=000044BA exp=00000000 |
| apu/psg-ch1-second-trigger-dies | FAIL | got=00004BD8 exp=00000000 |
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
| apu/ram-psg-ch2-before-ch1 | FAIL | got=0000732F exp=000083F9..00009593 |

## bios (47/47)

All pass.
