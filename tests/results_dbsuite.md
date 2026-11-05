# dbsuite - Detailed Results

*Generated: 2026-11-04 20:24:46 · commit a84dab1a · game-boy-test-roms v7.0*

tests/roms/dbsuite/dbsuite.gba (cartridge build) in dingbat. Every expected value is an AGB SP (AGS-001) answer; each case's source comment in tests/roms/dbsuite/ gives its provenance. A case that is not PASS here is dingbat disagreeing with the console.

**Total: 881/884**

## cpu (117/117)

All pass.

## irq (145/145)

All pass.

## timer (26/26)

All pass.

## dma (262/262)

All pass.

## bus (77/79)

| Case | Status | Got / expected |
|------|--------|----------------|
| bus/contend-vram-mode0 | FAIL | got=000000F8 exp=000000F6 |
| bus/contend-vram-mode2-locked-out | FAIL | got=00000444 exp=0000042A |

## ppu (156/156)

All pass.

## apu (51/52)

| Case | Status | Got / expected |
|------|--------|----------------|
| apu/sweeptrig-shift0-400-after-rows-d33 | FAIL | got=00000001 exp=00000000 |

## bios (47/47)

All pass.
