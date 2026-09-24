@ suite_ppu.inc -- scanline timing as the CPU and the DMA see it: when the
@ DISPSTAT flags change against VCOUNT, when an H-blank or V-blank DMA
@ writes, and the whole path from a V-blank interrupt through the BIOS's
@ VBlankIntrWait and a table-walking dispatcher to an H-blank DMA's word
@ on the bus -- the mGBA suite's `DMA Prefetch Break`, measured end to end.

    suite "ppu"

@ ─────────────────────────── DISPSTAT byte writes ─────────────────────────
@ WHAT: at the top of line 160 (V-blank flag set, H-blank not yet),
@ DISPSTAT written a byte at a time: 0x38 to the low byte, 0x38 to the
@ high byte (the V-count setting), a 16-bit 0x38, then a byte-clear of the
@ low byte on top of it.
@ WHY: DISPSTAT's low byte takes byte writes (0x38 reads back 0x39 with
@ the live V-blank flag), the high byte is the LYC setting on its own
@ (0x3801), and a byte-clear clears the enables (0x0001).  An emulator
@ that ignores byte writes to DISPSTAT, or lets one clobber the status
@ flags, differs.
@ PROVENANCE: AGB SP, gbaedge page 34 IOBYTE2 (session 4, CRC AF19;
@ agb-sp-4.txt); docs/hwprobe-results-agb.md "22 IOBYTE2".
run_iobyte2:
    push {r4-r8, lr}
    ldr r8, =SLOT
    mov r4, #IOBASE
    add r5, r4, #4
    ldrh r6, [r5]
    bl  wait_vblank
    mov r0, #0x38
    strb r0, [r5]
    ldrh r0, [r5]
    strh r0, [r8, #0]
    strh r6, [r5]
    mov r0, #0x38
    strb r0, [r5, #1]
    ldrh r0, [r5]
    strh r0, [r8, #2]
    strh r6, [r5]
    mov r0, #0x38
    strh r0, [r5]
    ldrh r0, [r5]
    strh r0, [r8, #4]
    mov r0, #0
    strb r0, [r5]
    ldrh r0, [r5]
    strh r0, [r8, #6]
    strh r6, [r5]
    ldr r1, =0x04000202
    ldr r0, =0x3FFF
    strh r0, [r1]
    pop {r4-r8, pc}
    .ltorg
    chalf "dispstat-lo-byte-write",  run_iobyte2, 0, 0x0039
    chalf "dispstat-hi-byte-is-lyc", RUN_SAME, 2, 0x3801
    chalf "dispstat-16-bit-write",   RUN_SAME, 4, 0x0039
    chalf "dispstat-lo-byte-clear",  RUN_SAME, 6, 0x0001

    payload_blob pl_breakram, "breakram.bin"
    .include "gen_ppu.inc"
