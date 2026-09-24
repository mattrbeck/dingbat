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

    payload_blob pl_wakeirq, "wakeirq.bin"
    payload_blob pl_lycwrite, "lycwrite.bin"
    .include "gen_irq.inc"
