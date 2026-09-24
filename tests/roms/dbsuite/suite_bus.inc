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

@ ──────────────────────── renderer contention ─────────────────────────────
@ WHAT: gbaedge page 41 CONTEND2, its code unchanged: sixteen back-to-back
@ `ldrh` from one region, timed from the top of line 40's visible part,
@ with 128 64x64 OBJs covering the line, in mode 0 (BG0-3 + OBJ), mode 2
@ (affine BG2+BG3 + OBJ), mode 0 without OBJs, with H-blank-interval-free,
@ and under forced blank; plus the reads executed from a stub in VRAM.
@ WHY: OAM never stalls the CPU; palette RAM costs +1 over sixteen reads;
@ VRAM in mode 0 costs +1 per CPU halfword read (OBJ layer irrelevant), and
@ in mode 2 the CPU is locked out of VRAM until H-blank (1066 vs 230).
@ Code fetched from VRAM costs more than a flat per-access model says.  An
@ emulator with no renderer contention reads 230 everywhere.
@ PROVENANCE: AGB SP, gbaedge page 41 CONTEND2 (session 5, 2026-09-04,
@ CRC 9365; agb-sp-5.txt).  Timed from the cartridge: cartridge only.
.equ C2_M0,    0x1F40
.equ C2_M2,    0x1C42
.equ C2_M0NO,  0x0F40
.equ C2_HBF,   0x1F60
.equ C2_BLANK, 0x1F80
.equ V8VSTUB,  0x06014000
.macro wait_line40
1:  ldrh r0, [r4, #6]
    cmp r0, #39
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #40
    bne 2b
.endm
.macro c2_row cfg, base, off
    ldr r0, =\cfg
    strh r0, [r4]
    wait_line40
    bl  tm_start
    ldr r2, =\base
    .rept 16
    ldrh r3, [r2]
    .endr
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
.macro c2_vrun cfg, off
    ldr r0, =\cfg
    strh r0, [r4]
    wait_line40
    bl  tm_start
    ldr r2, =0x03000000
    ldr r1, =V8VSTUB
    mov lr, pc
    bx  r1
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
run_contend2:
    push {r4-r9, lr}
    ldr r8, =SLOT
    mov r4, #IOBASE
    mov r0, #0x80
    strh r0, [r4]
    mov r0, #0                     @ BG0-3CNT as the page found them
    strh r0, [r4, #0x08]
    strh r0, [r4, #0x0A]
    strh r0, [r4, #0x0C]
    strh r0, [r4, #0x0E]
    ldr r0, =0x07000000            @ 128 OBJs, 64x64, Y = 40, X = 0..127
    mov r1, #0
1:  mov r2, #40
    orr r3, r1, #0xC000
    orr r2, r2, r3, lsl #16
    str r2, [r0], #4
    mov r2, #0
    str r2, [r0], #4
    add r1, r1, #1
    cmp r1, #128
    blt 1b
    mov r0, #0x100
    strh r0, [r4, #0x20]
    strh r0, [r4, #0x26]
    strh r0, [r4, #0x30]
    strh r0, [r4, #0x36]
    ldr r0, =c2_vram_stub
    ldr r1, =V8VSTUB
    mov r2, #(c2_vram_end - c2_vram_stub) / 4
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b
    c2_row C2_M0,   0x05000000, 0
    c2_row C2_M0,   0x06000000, 2
    c2_row C2_M0,   0x07000000, 4
    c2_row C2_M0,   0x03000000, 6
    c2_row C2_M2,   0x05000000, 8
    c2_row C2_M2,   0x06000000, 10
    c2_row C2_M2,   0x07000000, 12
    c2_row C2_M0NO, 0x05000000, 16
    c2_row C2_M0NO, 0x06000000, 18
    c2_row C2_M0NO, 0x07000000, 20
    c2_vrun C2_M0,    22
    c2_vrun C2_BLANK, 14
    c2_row C2_HBF,   0x06000000, 24
    c2_row C2_HBF,   0x07000000, 26
    c2_row C2_BLANK, 0x06000000, 28
    c2_row C2_BLANK, 0x03000000, 30
    mov r0, #0x80
    strh r0, [r4]
    ldr r0, =0x07000000            @ every OBJ disabled again
    ldr r1, =0x00000200
    mov r2, #0
    mov r3, #128
2:  str r1, [r0], #4
    str r2, [r0], #4
    subs r3, r3, #1
    bne 2b
    pop {r4-r9, pc}
    .ltorg
c2_vram_stub:
    .rept 16
    ldrh r3, [r2]
    .endr
    bx  lr
c2_vram_end:
    chalf "contend-pram-mode0",     run_contend2, 0, 0x00E7, F_CART
    chalf "contend-vram-mode0",     RUN_SAME, 2, 0x00F6, F_CART
    chalf "contend-oam-mode0",      RUN_SAME, 4, 0x00E6, F_CART
    chalf "contend-iwram-control",  RUN_SAME, 6, 0x00E6, F_CART
    chalf "contend-pram-mode2",     RUN_SAME, 8, 0x00E7, F_CART
    chalf "contend-vram-mode2-locked-out", RUN_SAME, 10, 0x042A, F_CART
    chalf "contend-oam-mode2",      RUN_SAME, 12, 0x00E6, F_CART
    chalf "contend-vram-code-blank", RUN_SAME, 14, 0x00DC, F_CART
    chalf "contend-pram-no-obj",    RUN_SAME, 16, 0x00E6, F_CART
    chalf "contend-vram-no-obj",    RUN_SAME, 18, 0x00F8, F_CART
    chalf "contend-oam-no-obj",     RUN_SAME, 20, 0x00E6, F_CART
    chalf "contend-vram-code-mode0", RUN_SAME, 22, 0x00DD, F_CART
    chalf "contend-vram-hblank-free", RUN_SAME, 24, 0x00F6, F_CART
    chalf "contend-oam-hblank-free", RUN_SAME, 26, 0x00E6, F_CART
    chalf "contend-vram-blank",     RUN_SAME, 28, 0x00E6, F_CART
    chalf "contend-iwram-blank",    RUN_SAME, 30, 0x00E6, F_CART

    .include "bus_payloads.inc"
