# dbsuite - Detailed Results

*Generated: 2026-09-25 09:15:48 · commit 03b0c276 · game-boy-test-roms v7.0*

tests/roms/dbsuite/dbsuite.gba (cartridge build) in dingbat. Every expected value is an AGB SP (AGS-001) answer; each case's source comment in tests/roms/dbsuite/ gives its provenance. A case that is not PASS here is dingbat disagreeing with the console.

**Total: 870/884**

## cpu (117/117)

All pass.

## irq (145/145)

All pass.

## timer (26/26)

All pass.

## dma (261/262)

| Case | Status | Got / expected |
|------|--------|----------------|
| dma/dmatime-burst-vram-mode3 | FAIL | got=000000B2 exp=000000B1 |

## bus (76/79)

| Case | Status | Got / expected |
|------|--------|----------------|
| bus/contend-pram-mode0 | FAIL | got=000000E6 exp=000000E7 |
| bus/contend-vram-mode0 | FAIL | got=000000F0 exp=000000F6 |
| bus/contend-vram-mode2-locked-out | FAIL | got=00000444 exp=0000042A |

## ppu (156/156)

All pass.

## apu (42/52)

| Case | Status | Got / expected |
|------|--------|----------------|
| apu/psg-ch1-first-trigger-dies | FAIL | got=00004979 exp=00000000 |
| apu/psg-ch1-nr10-0-dies | FAIL | got=00004979 exp=00000000 |
| apu/psg-ch1-second-trigger-dies | FAIL | got=00004BD8 exp=00000000 |
| apu/psg-soundcnt-x-after-ch1 | FAIL | got=00000081 exp=00000080 |
| apu/sweeptrig-shift0-400-d33 | FAIL | got=00040000 exp=00000001 |
| apu/sweeptrig-shift0-400-d37 | FAIL | got=00040000 exp=00000001 |
| apu/sweeptrig-shift0-400-length-d33 | FAIL | got=00040000 exp=00000001 |
| apu/sweeptrig-shift0-400-length-d37 | FAIL | got=00040000 exp=00000001 |
| apu/sweeptrig-shift0-400-after-rows-d30 | FAIL | got=00040000 exp=00000000/00000001 |
| apu/sweeptrig-shift0-400-after-rows-d33 | FAIL | got=00040000 exp=00000000 |

## bios (47/47)

All pass.
