@ suite_ppu.inc -- scanline timing as the CPU and the DMA see it: when the
@ DISPSTAT flags change against VCOUNT, when an H-blank or V-blank DMA
@ writes, and the whole path from a V-blank interrupt through the BIOS's
@ VBlankIntrWait and a table-walking dispatcher to an H-blank DMA's word
@ on the bus -- the mGBA suite's `DMA Prefetch Break`, measured end to end.

    suite "ppu"

    payload_blob pl_breakram, "breakram.bin"
    .include "gen_ppu.inc"
