@ suite_bus.inc -- the memory bus: what unused and write-only IO reads
@ back, the internal memory control register, cartridge-window wait
@ states, and what an unmapped read returns (open bus) from ARM and Thumb
@ code in every memory, and right after a DMA.

    suite "bus"

@ ─────────────────────────────── IO read map ─────────────────────────────
@ WHAT: sixteen halfword reads of unused and write-only IO registers.
@ WHY: 0x66/0x6A/0x78 (sound gaps), 0x136/0x142 (SIO/JOY gaps) and
@ 0x206/0x20A read ZERO; the write-only PPU registers (0x10, 0x28, 0x40,
@ 0x4C, 0x54), the unused 0x4E/0x56, 0x110 and 0x12C read OPEN BUS -- in
@ ARM code the opcode two instructions past the load, here the loop's own
@ `subs r6, r6, #1` (E2566001; the halfword the address's bit 1 selects).
@ Emulators that read zero everywhere, or open bus everywhere, fail.
@ PROVENANCE: AGB SP, gbaedge page 16 IORW (session 2, CRC 626A: 6001 and
@ E256 there are halves of the same opcode); hwverified/iomap.s.
run_iomap:
    push {r4-r6, lr}
    ldr r4, =SLOT
    ldr r5, =iorw_offsets
    mov r6, #16
    ldr r3, =IOBASE
1:  ldrh r0, [r5], #2
    ldrh r0, [r3, r0]
    strh r0, [r4], #2
    subs r6, r6, #1                @ E2566001: what open bus returns above
    bne 1b
    pop {r4-r6, pc}
iorw_offsets:
    .hword 0x010, 0x028, 0x040, 0x04C, 0x04E, 0x054, 0x056, 0x066
    .hword 0x06A, 0x078, 0x110, 0x12C, 0x136, 0x142, 0x206, 0x20A
    .ltorg
    chalf "io-010-bg0hofs-open-bus", run_iomap, 0, 0x6001
    chalf "io-028-bg2x-open-bus",   RUN_SAME, 2, 0x6001
    chalf "io-040-win0h-open-bus",  RUN_SAME, 4, 0x6001
    chalf "io-04c-mosaic-open-bus", RUN_SAME, 6, 0x6001
    chalf "io-04e-open-bus",        RUN_SAME, 8, 0xE256
    chalf "io-054-bldy-open-bus",   RUN_SAME, 10, 0x6001
    chalf "io-056-open-bus",        RUN_SAME, 12, 0xE256
    chalf "io-066-reads-0",         RUN_SAME, 14, 0x0000
    chalf "io-06a-reads-0",         RUN_SAME, 16, 0x0000
    chalf "io-078-reads-0",         RUN_SAME, 18, 0x0000
    chalf "io-110-open-bus",        RUN_SAME, 20, 0x6001
    chalf "io-12c-open-bus",        RUN_SAME, 22, 0x6001
    chalf "io-136-reads-0",         RUN_SAME, 24, 0x0000
    chalf "io-142-reads-0",         RUN_SAME, 26, 0x0000
    chalf "io-206-reads-0",         RUN_SAME, 28, 0x0000
    chalf "io-20a-reads-0",         RUN_SAME, 30, 0x0000

@ ────────────────────── internal memory control ───────────────────────────
@ WHAT: 0x04000800 read as a word, through the 0x04010800 and 0x04FF0800
@ mirrors, as halfwords and as bytes (its boot value 0D000020 written back
@ first); then (cartridge only) its EWRAM wait field: 16 EWRAM word reads
@ timed at the boot WS 13, at WS 14 and at WS 4, and the field read back
@ after each write and after a write through a mirror.
@ WHY: the register is mirrored every 64 KB of IO space and readable at
@ every width; the WS field is live silicon (waits = 15 - WS: 321 / 289 /
@ 609 cycles).  Emulators that treat it as readback-only read 321 for all
@ three.  WS 15 locks the console and is never written.
@ PROVENANCE: AGB SP, gbaedge page 45 MEMCTL (session 5, 2026-09-04, CRC
@ B63F; agb-sp-5.txt); the boot value on gbaedge page 0 IDENT.
run_memctl:
    push {r4-r9, lr}
    ldr r8, =SLOT
    ldr r5, =0x04000800
    ldr r6, =0x0D000020
    str r6, [r5]
    ldr r0, [r5]
    str r0, [r8, #0]
    ldr r1, =0x04010800
    ldr r0, [r1]
    str r0, [r8, #4]
    ldr r1, =0x04FF0800
    ldr r0, [r1]
    str r0, [r8, #8]
    ldrh r0, [r5]
    strh r0, [r8, #12]
    ldrh r0, [r5, #2]
    strh r0, [r8, #14]
    ldrb r0, [r5]
    strb r0, [r8, #16]
    ldrb r0, [r5, #1]
    strb r0, [r8, #17]
    ldrb r0, [r5, #2]
    strb r0, [r8, #18]
    ldrb r0, [r5, #3]
    strb r0, [r8, #19]
.if MB == 0                        @ the WS writes run only from the
.macro mc_time off                 @ cartridge: from EWRAM they would
    bl  tm_start                   @ retime the code itself
    ldr r2, =EWDST
    .rept 16
    ldr r3, [r2]
    .endr
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
    str r6, [r5]
    mc_time 20
    bic r0, r6, #0x0F000000        @ WS := 14 (one wait)
    orr r0, r0, #0x0E000000
    str r0, [r5]
    mc_time 22
    ldr r0, [r5]
    mov r0, r0, lsr #24
    strb r0, [r8, #26]
    bic r0, r6, #0x0F000000        @ WS := 4
    orr r0, r0, #0x04000000
    str r0, [r5]
    mc_time 24
    ldr r0, [r5]
    mov r0, r0, lsr #24
    strb r0, [r8, #27]
    str r6, [r5]
    ldr r0, [r5]
    mov r0, r0, lsr #24
    strb r0, [r8, #28]
    ldr r1, =0x04010800
    str r6, [r1]
    ldr r0, [r5]
    mov r0, r0, lsr #24
    strb r0, [r8, #29]
.endif
    str r6, [r5]
    pop {r4-r9, pc}
    .ltorg
    cword "memctl-reads-0d000020",  run_memctl, 0, 0x0D000020
    cword "memctl-mirror-04010800", RUN_SAME, 4, 0x0D000020
    cword "memctl-mirror-04ff0800", RUN_SAME, 8, 0x0D000020
    cword "memctl-halfword-reads",  RUN_SAME, 12, 0x0D000020
    cword "memctl-byte-reads",      RUN_SAME, 16, 0x0D000020
    chalf "ewram-16-reads-ws13",    RUN_SAME, 20, 0x0141, F_CART
    chalf "ewram-16-reads-ws14",    RUN_SAME, 22, 0x0121, F_CART
    chalf "ewram-16-reads-ws4",     RUN_SAME, 24, 0x0261, F_CART
    cbyte "memctl-ws14-reads-back", RUN_SAME, 26, 0x0E, F_CART
    cbyte "memctl-ws4-reads-back",  RUN_SAME, 27, 0x04, F_CART
    cbyte "memctl-ws13-reads-back", RUN_SAME, 28, 0x0D, F_CART
    cbyte "memctl-write-via-mirror", RUN_SAME, 29, 0x0D, F_CART

    .include "bus_payloads.inc"
