# dbsuite - Detailed Results

*Generated: 2026-09-25 12:54:11 · commit f9404fb5 · game-boy-test-roms v7.0*

tests/roms/dbsuite/dbsuite.gba (cartridge build) in dingbat. Every expected value is an AGB SP (AGS-001) answer; each case's source comment in tests/roms/dbsuite/ gives its provenance. A case that is not PASS here is dingbat disagreeing with the console.

**Total: 878/884**

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

## apu (50/52)

| Case | Status | Got / expected |
|------|--------|----------------|
| apu/psg-ch1-after-ch2-lives | FAIL | got=00000000 exp=0000413F..00004CF7 |
| apu/sweeptrig-shift0-400-after-rows-d33 | FAIL | got=00000001 exp=00000000 |

## bios (47/47)

All pass.
