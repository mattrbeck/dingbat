@ suite_irq.inc -- when an interrupt is taken: the dispatch window after
@ the gate that opens it, a timer interrupt raised thousands of times under
@ a DMA burst, the halted CPU's wake, and the V-count match edge.

    suite "irq"

@ ────────────────────────────── IRQ window ───────────────────────────────
@ WHAT: a TM2 overflow parked in IF; then one gate opened (IME store, IE
@ store, `msr` clearing I) with a sled of instructions behind it.  The
@ handler records the interrupted return address: how far the sled ran.
@ Sled variants (EWRAM loads, 4-I-cycle MULs, waitstated ROM loads, a mixed
@ NOP/ROM-load sled) separate an instruction-counted window from a
@ cycle-counted one.  Last, 16 IF acks race a TM2 that overflows every 16
@ cycles.
@ WHY: hardware dispatches after THREE sled instructions for IME and IE
@ stores (offset 0x0C) but TWO for the msr (0x08), and one cycle-counted
@ window predicts every sled's count.  Emulators that dispatch at the next
@ instruction read 4 everywhere.
@ PROVENANCE: AGB SP, gbaedge pages 20 IRQWIN, 26 IRQWIN2, 32 IRQWIN3
@ (sessions 2-4, photographed); hwverified/irqwin.s.  The sleds execute
@ from the cartridge (WAITCNT 0), so every row is cartridge only; the
@ ack-race count is phase-sensitive and range-checked 6..10 (hardware 8).
run_irqwin:
    push {r4-r11, lr}
    ldr r8, =SLOT
    ldr r7, =SCRATCH
    ldr r4, =0x04000200
    ldr r9, =iw_rom_pattern
    mov r10, #1
    ldr r11, =0x12345678
.macro iw_prime
    ldr r5, =0x04000108
    mov r0, #0
    str r0, [r5]
    str r0, [r7, #0x4C]
    str r0, [r7, #0x50]
    ldr r0, =0x00C0FFFF
    str r0, [r5]
    mov r1, #0x10000
1:  ldrh r0, [r4, #2]
    tst r0, #0x20
    bne 2f
    subs r1, r1, #1
    bne 1b
2:  mov r0, #0
    str r0, [r5]
.endm
.macro iw_sled slot_off, base_lbl
    ldr r0, [r7, #0x50]
    adr r1, \base_lbl
    sub r0, r0, r1
    strh r0, [r8, #\slot_off]
.endm
    mov r0, #0
    strh r0, [r4, #8]
    mov r0, #0x20
    strh r0, [r4]
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]
iw1:
    .rept 8
    add r6, r6, #1
    .endr
    iw_sled 0, iw1
    mov r0, #0
    strh r0, [r4, #8]
    mrs r5, CPSR
    orr r0, r5, #0x80
    msr CPSR_c, r0
    mov r0, #1
    strh r0, [r4, #8]
    iw_prime
    mrs r0, CPSR
    bic r0, r0, #0x80
    msr CPSR_c, r0
iw2:
    .rept 8
    add r6, r6, #1
    .endr
    iw_sled 2, iw2
    mov r0, #0
    strh r0, [r4]
    iw_prime
    mov r0, #0x20
    strh r0, [r4]
iw3:
    .rept 8
    add r6, r6, #1
    .endr
    iw_sled 4, iw3
    mov r0, #0
    strh r0, [r4, #8]
    iw_prime
    ldr r3, =EWDST
    mov r0, #1
    strh r0, [r4, #8]
iw4:
    .rept 8
    ldr r0, [r3]
    .endr
    iw_sled 8, iw4
    mov r0, #0
    strh r0, [r4, #8]
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]
iw5:
    .rept 8
    mul r6, r10, r11
    .endr
    iw_sled 16, iw5
    mov r0, #0
    strh r0, [r4, #8]
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]
iw6:
    .rept 8
    ldr r0, [r9]
    .endr
    iw_sled 18, iw6
    mov r0, #0
    strh r0, [r4, #8]
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]
iw7:
    .rept 4
    nop
    ldr r0, [r9]
    .endr
    iw_sled 20, iw7
    mov r0, #0
    strh r0, [r4, #8]
    strh r0, [r4]
    ldr r5, =0x04000108
    str r0, [r5]
    ldr r0, =0x00C0FFF0
    str r0, [r5]
    mov r6, #0
    mov r2, #16
    mov r1, #0x20
1:  strh r1, [r4, #2]
    ldrh r0, [r4, #2]
    tst r0, #0x20
    addne r6, r6, #1
    subs r2, r2, #1
    bne 1b
    str r6, [r8, #12]
    mov r0, #0
    str r0, [r5]
    mov r0, #0x20
    strh r0, [r4, #2]
    pop {r4-r11, pc}
    .ltorg
iw_rom_pattern:
    .word 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00
    chalf "irqwin-ime-store-3-insns", run_irqwin, 0, 0x000C, F_CART
    chalf "irqwin-msr-clear-i-2-insns", RUN_SAME, 2, 0x0008, F_CART
    chalf "irqwin-ie-store-3-insns", RUN_SAME, 4, 0x000C, F_CART
    chalf "irqwin-ewram-load-sled", RUN_SAME, 8, 0x0008, F_CART
    chalf "irqwin-mul-sled",        RUN_SAME, 16, 0x0008, F_CART
    chalf "irqwin-rom-load-sled",   RUN_SAME, 18, 0x0008, F_CART
    chalf "irqwin-mixed-sled",      RUN_SAME, 20, 0x000C, F_CART
    crange "irqwin-if-ack-race",    RUN_SAME, 12, 0xFFFFFFFF, 6, 10, F_CART

@ ────────────────────────────── IRQ storm ────────────────────────────────
@ WHAT: TM0 raises its interrupt every P cycles while DMA3 copies N words
@ EWRAM->EWRAM; the handler stops TM0 and reads TM1 (counting from TM0's
@ start).  Answer: TM1 at entry | entries << 16 | TM0 low byte << 24.
@ WHY: it is ONE interrupt, taken once, at a fixed cycle after the burst.
@ An emulator that books one event per raise overflows its queue (Golden
@ Nugget Casino, Caesar's Palace Advance and Corvette crashed that way in
@ dingbat); one that holds the synchroniser for the whole burst is late.
@ PROVENANCE: AGB SP through tools/hwlink (payloadcmp on_hardware, the
@ payload byte for byte at 0x03000000), 2026-09-23, asked twice with
@ identical answers; hwverified/irqstorm.s.
    payload_blob pl_irqstorm, "irqstorm.bin"
    cpay "irqstorm-p16-no-dma",   pl_irqstorm, 0xFFF00000, 0xFF01002F
    cpay "irqstorm-p1-no-dma",    pl_irqstorm, 0xFFFF0000, 0xFF01001E
    cpay "irqstorm-p16-64-words", pl_irqstorm, 0xFFF00040, 0xF1010321
    cpay "irqstorm-p16-128-words", pl_irqstorm, 0xFFF00080, 0xF1010621
    cpay "irqstorm-p16-1024-words", pl_irqstorm, 0xFFF00400, 0xF1013021
    cpay "irqstorm-p1-1024-words", pl_irqstorm, 0xFFFF0400, 0xFF01301F
    cpay "irqstorm-p64-1024-words", pl_irqstorm, 0xFFC00400, 0xE1013021
    cpay "irqstorm-p256-4096-words", pl_irqstorm, 0xFF001000, 0x2101C021

@ ──────────────────────── interrupt latency, decomposed ───────────────────
@ WHAT: gbaedge page 40 IRQDECOMP, its code unchanged: the handler's TM0
@ entry stamp less a stamp taken just before the arming store, for a TM2
@ overflow (one 32-bit arm, two halfword arms, reloads 0000/0001, and with
@ a HALTCNT write behind it), H-blank, V-blank and DMA3-complete, each
@ with the CPU running and with a HALTCNT write behind the arm; then IF
@ read one instruction after acknowledging it, at eight spacings across a
@ TM2 overflow (0x20 while the acknowledge lands before the raise).
@ WHY: each row is one path from a source to the handler; differences
@ between rows are the pipeline, decomposed.  (The HALTCNT writes come from
@ cartridge code, which silicon ignores -- HALTCNT answers only to the
@ BIOS -- so those rows run too, as the console's did.)
@ PROVENANCE: AGB SP, gbaedge page 40 IRQDECOMP (session 5, 2026-09-04,
@ CRC F533; agb-sp-5.txt).  From the cartridge: cartridge only.  Every
@ latency includes the BIOS dispatcher's six-register push and pop, and on
@ that run the IRQ stack was in EWRAM: gbaedge's THUMBPC and LDMUSER pages
@ moved sp_irq to SCRATCH+0xF0 and never put it back.  So this port runs
@ with sp_irq there too (sp_irq_ewram); from the BIOS's IWRAM stack every
@ row reads 30 cycles lower.  The H-blank and V-blank rows are anchored by
@ a polling loop (the flag's fall, VCOUNT reaching 158) whose phase depends
@ on where the page started, so they are checked +-32; the timer and DMA
@ rows have no anchor and are exact.
.equ V8STUB, 0x03000500
.macro id_clear
    mov r0, #0
    str r0, [r7, #0x4C]
.endm
.macro id_delta off
    ldr r6, =0x00080000
9:  ldr r0, [r7, #0x4C]
    cmp r0, #0
    bne 7f
    subs r6, r6, #1
    bne 9b
    ldrb r0, [r8, #31]
    add r0, r0, #1
    strb r0, [r8, #31]
7:  ldrh r0, [r7, #0x48]
    sub r0, r0, r5
    strh r0, [r8, #\off]
.endm
.macro id_ie bits
    ldr r0, =0x04000200
    ldr r1, =\bits
    strh r1, [r0]
    ldr r1, =0x3FFF
    strh r1, [r0, #2]
.endm
.macro id_ime v
    ldr r0, =0x04000200
    mov r1, #\v
    strh r1, [r0, #8]
.endm
.macro id_mark n
    mov r0, #\n
    strb r0, [r8, #30]
.endm
.macro id_halt
    ldr r0, =0x04000301
    mov r1, #0
    strb r1, [r0]
.endm
.macro id_anchor_hb
    id_ime 0
    ldrh r0, [r4, #4]
    orr r0, r0, #0x10
    strh r0, [r4, #4]
1:  ldrh r0, [r4, #4]
    tst r0, #2
    beq 1b
2:  ldrh r0, [r4, #4]
    tst r0, #2
    bne 2b
    id_clear
    id_ie 0x0042
.endm
.macro id_anchor_vb
    id_ime 0
    ldrh r0, [r4, #4]
    orr r0, r0, #0x08
    strh r0, [r4, #4]
1:  ldrh r0, [r4, #6]
    cmp r0, #157
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #158
    bne 2b
    id_clear
    id_ie 0x0041
.endm
.macro id_dma3
    ldr r6, =0x040000D4
    ldr r0, =iw_rom_pattern
    str r0, [r6]
    ldr r0, =EWDST
    str r0, [r6, #4]
    id_clear
    id_ie 0x0840
    id_ime 1
    ldr r1, =0xC4000004
.endm
.macro id_timer_row cnt, off, halt
    mov r0, #0
    str r0, [r9]
    id_clear
    id_ie 0x0060
    id_ime 1
    ldr r1, =\cnt
    ldrh r5, [r10]
    str r1, [r9]
.if \halt
    id_halt
.endif
    id_delta \off
    mov r0, #0
    str r0, [r9]
.endm
v8_id_handler:
    ldr r0, =0x04000100
    ldrh r1, [r0]                  @ entry stamp: the first thing, always
    ldr r0, =0x04000200
    mov r2, #0
    strh r2, [r0, #8]
    ldrh r2, [r0, #2]
    strh r2, [r0, #2]
    ldr r0, =0x04000108
    mov r2, #0
    str r2, [r0]
    ldr r0, =SCRATCH
    ldr r2, [r0, #0x4C]
    cmp r2, #0
    streqh r1, [r0, #0x48]
    moveq r2, #1
    streq r2, [r0, #0x4C]
    bx  lr
    .ltorg
run_irqdecomp:
    push {r4-r11, lr}
    bl  sp_irq_ewram
    ldr r8, =SLOT
    ldr r7, =SCRATCH
    mov r4, #IOBASE
    ldr r9, =0x04000108
    ldr r10, =0x04000100
    ldr r11, =0x0400010C
    ldr r0, =0x03007FFC
    ldr r1, =v8_id_handler
    str r1, [r0]
    bl  tm_start
    mov r0, #0
    str r0, [r11]
    ldr r0, =0x00C10000
    str r0, [r11]
    id_mark 0
    id_timer_row 0x00C0FFF0, 0, 0
    id_mark 1
    mov r0, #0
    str r0, [r9]
    id_clear
    id_ie 0x0060
    id_ime 1
    ldr r1, =0xFFF0
    mov r2, #0xC0
    ldrh r5, [r10]
    strh r1, [r9]
    strh r2, [r9, #2]
    id_delta 2
    mov r0, #0
    str r0, [r9]
    id_mark 2
    id_timer_row 0x00C00000, 4, 0
    id_mark 3
    id_timer_row 0x00C00001, 6, 0
    id_mark 4
    id_timer_row 0x00C0FFF0, 8, 1
    id_mark 5
    id_anchor_hb
    ldr r0, =0x04000200
    mov r1, #1
    ldrh r5, [r10]
    strh r1, [r0, #8]
    id_delta 10
    id_mark 6
    id_anchor_hb
    ldr r0, =0x04000200
    mov r1, #1
    ldrh r5, [r10]
    strh r1, [r0, #8]
    id_halt
    id_delta 12
    ldrh r0, [r4, #4]
    bic r0, r0, #0x10
    strh r0, [r4, #4]
    id_mark 7
    id_anchor_vb
    ldr r0, =0x04000200
    mov r1, #1
    ldrh r5, [r10]
    strh r1, [r0, #8]
    id_delta 14
    id_mark 8
    id_anchor_vb
    ldr r0, =0x04000200
    mov r1, #1
    ldrh r5, [r10]
    strh r1, [r0, #8]
    id_halt
    id_delta 16
    ldrh r0, [r4, #4]
    bic r0, r0, #0x08
    strh r0, [r4, #4]
    id_mark 9
    id_dma3
    ldrh r5, [r10]
    str r1, [r6, #8]
    id_delta 18
    id_mark 10
    id_dma3
    ldrh r5, [r10]
    str r1, [r6, #8]
    id_halt
    id_delta 20
    id_ime 0
    id_ie 0
    mov r0, #0
    str r0, [r11]
    str r0, [r9]
    id_mark 11
    ldr r0, =v8_race_stub
    ldr r1, =V8STUB
    mov r2, #(v8_race_end - v8_race_stub) / 4
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b
    mov r11, #0
1:  mov r0, #0
    str r0, [r9]
    ldr r0, =0x04000200
    ldr r1, =0x3FFF
    strh r1, [r0, #2]
    ldr r0, =0x00C0FFF0
    mov r1, r9
    ldr r2, =0x04000202
    ldr r3, =0xFFFF
    mov r6, r11, lsl #3
    ldr r12, =V8STUB
    mov lr, pc
    bx  r12
    add r0, r8, #22
    strb r5, [r0, r11]
    add r11, r11, #1
    cmp r11, #8
    blt 1b
    mov r0, #0
    str r0, [r9]
    ldr r0, =0x04000200
    ldr r1, =0x3FFF
    strh r1, [r0, #2]
    bl  tm_stop
    ldr r0, =0x03007FFC
    ldr r1, =irq_handler
    str r1, [r0]
    id_mark 0xFF
    pop {r4-r11, pc}
    .ltorg
v8_race_stub:
    str r0, [r1]
    add pc, pc, r6
    nop
    .rept 24
    nop
    .endr
    strh r3, [r2]
    ldrh r5, [r2]
    bx  lr
v8_race_end:
    chalf "irqlat-tm2-one-write",   run_irqdecomp, 0, 0x007C, F_CART
    chalf "irqlat-tm2-two-writes",  RUN_SAME, 2, 0x0085, F_CART
    chalf "irqlat-tm2-reload-0000", RUN_SAME, 4, 0x0072, F_CART
    chalf "irqlat-tm2-reload-0001", RUN_SAME, 6, 0x0072, F_CART
    chalf "irqlat-tm2-haltcnt-ignored", RUN_SAME, 8, 0x0087, F_CART
    crange "irqlat-hblank",         RUN_SAME, 10, 0xFFFF, 0x03BD - 32, 0x03BD + 32, F_CART
    crange "irqlat-hblank-haltcnt", RUN_SAME, 12, 0xFFFF, 0x03DD - 32, 0x03DD + 32, F_CART
    crange "irqlat-vblank",         RUN_SAME, 14, 0xFFFF, 0x0989 - 32, 0x0989 + 32, F_CART
    crange "irqlat-vblank-haltcnt", RUN_SAME, 16, 0xFFFF, 0x0974 - 32, 0x0974 + 32, F_CART
    chalf "irqlat-dma3",            RUN_SAME, 18, 0x00B2, F_CART
    chalf "irqlat-dma3-haltcnt",    RUN_SAME, 20, 0x00AC, F_CART
    cword "if-ack-race-j0-3",       RUN_SAME, 22, 0x00000000, F_CART
    chalf "if-ack-race-j4-5",       RUN_SAME, 26, 0x0000, F_CART
    chalf "if-ack-race-j6-7",       RUN_SAME, 28, 0x0020, F_CART
    cbyte "irqlat-every-irq-arrived", RUN_SAME, 31, 0x00, F_CART

    payload_blob pl_wakeirq, "wakeirq.bin"
    payload_blob pl_lycwrite, "lycwrite.bin"
    .include "gen_irq.inc"
