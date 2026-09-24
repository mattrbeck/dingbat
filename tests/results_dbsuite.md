# dbsuite - Detailed Results

*Generated: 2026-09-24 10:57:45 · commit aa98ecdac · game-boy-test-roms v7.0*

tests/roms/dbsuite/dbsuite.gba (cartridge build) in dingbat. Every expected value is an AGB SP (AGS-001) answer; each case's source comment in tests/roms/dbsuite/ gives its provenance. A case that is not PASS here is dingbat disagreeing with the console.

**Total: 694/716**

## cpu (102/102)

All pass.

## irq (94/101)

| Case | Status | Got / expected |
|------|--------|----------------|
| irq/irqlat-tm2-one-write | FAIL | got=0000007B exp=0000007C |
| irq/irqlat-tm2-two-writes | FAIL | got=00000084 exp=00000085 |
| irq/irqlat-tm2-reload-0000 | FAIL | got=0000006D exp=00000072 |
| irq/irqlat-tm2-reload-0001 | FAIL | got=0000006D exp=00000072 |
| irq/irqlat-tm2-haltcnt-ignored | FAIL | got=0000007F exp=00000087 |
| irq/irqlat-dma3 | FAIL | got=000000B1 exp=000000B2 |
| irq/irqlat-dma3-haltcnt | FAIL | got=000000AB exp=000000AC |

## timer (14/14)

All pass.

## dma (215/217)

| Case | Status | Got / expected |
|------|--------|----------------|
| dma/dmatime-burst-vram-mode3 | FAIL | got=0000009C exp=000000B1 |
| dma/dmatime-completion-irq-after-resume | FAIL | got=0000005D exp=0000006D |

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

## apu (19/23)

| Case | Status | Got / expected |
|------|--------|----------------|
| apu/psg-ch1-first-trigger-dies | FAIL | got=00004806 exp=00000000 |
| apu/psg-ch1-nr10-0-dies | FAIL | got=000044BA exp=00000000 |
| apu/psg-ch1-second-trigger-dies | FAIL | got=00004BD8 exp=00000000 |
| apu/psg-soundcnt-x-after-ch1 | FAIL | got=00000081 exp=00000080 |

## bios (24/24)

All pass.
