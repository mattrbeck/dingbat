@ suite_dma.inc -- DMA: the CNT_H byte-write anomaly, video-capture DMA,
@ the H-blank DMA's grant against every phase of an instruction, the
@ immediate DMA's start and burst length, and what a DMA reading unmapped
@ memory gets off the data bus.

    suite "dma"

@ ───────────────────────── CNT_H byte writes ──────────────────────────────
@ WHAT: byte writes to DMA3CNT_H.  Each poke primes DMA3 with a valid
@ source, a cleared marker word as destination and 4 units, then reads the
@ marker (did it run?) and CNT_H back.
@ WHY: `strb 0x80` to the UPPER byte mirrors bit 7 into the lower byte too
@ (runs, reads back 0080 once the enable self-clears); `strb 0x80` to the
@ LOWER byte stores nothing.  Only bit 7 mirrors or drops: hi 0xC0 reads
@ 4080 (not 40C0), lo 0xC0 reads 0040 (not 0000).  An emulator with plain
@ byte writes gets every row but the controls wrong.
@ PROVENANCE: AGB SP, gbaedge pages 21 DMAEDGE, 27 IOBYTE, 30 DMABYTE2
@ (sessions 2-4, photographed; the anomaly holds on all four channels);
@ hwverified/dmabyte.s.
run_dmabyte:
    push {r4-r8, lr}
    ldr r8, =SLOT
    ldr r4, =0x040000D4
.macro de_prime
    ldr r0, =db_pattern
    str r0, [r4]
    ldr r5, =EWDST + 0x100
    mov r0, #0
    str r0, [r5]
    str r5, [r4, #4]
    mov r0, #4
    strh r0, [r4, #8]
    mov r0, #0
    strh r0, [r4, #10]
.endm
.macro de_verdict slot_off
    ldr r5, =EWDST + 0x100
    ldr r0, [r5]
    cmp r0, #0
    movne r0, #1
    strb r0, [r8, #\slot_off]
    ldrh r0, [r4, #10]
    strh r0, [r8, #\slot_off + 2]
    mov r0, #0
    strh r0, [r4, #10]
.endm
.macro de_poke val, addr, slot_off
    de_prime
    mov r0, #\val
    ldr r1, =\addr
    strb r0, [r1]
    nop
    nop
    nop
    nop
    de_verdict \slot_off
.endm
    de_poke 0x80, 0x040000DF, 0
    de_poke 0x80, 0x040000DE, 4
    de_poke 0x44, 0x040000DE, 8
    de_poke 0x44, 0x040000DF, 12
    de_poke 0xC0, 0x040000DF, 16
    de_poke 0xC0, 0x040000DE, 20
    de_poke 0x40, 0x040000DF, 24
    pop {r4-r8, pc}
    .ltorg
db_pattern:
    .word 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00
    cbyte "cnth-hi-80-runs",        run_dmabyte, 0, 1
    chalf "cnth-hi-80-reads-0080",  RUN_SAME, 2, 0x0080
    cbyte "cnth-lo-80-no-run",      RUN_SAME, 4, 0
    chalf "cnth-lo-80-stores-nothing", RUN_SAME, 6, 0x0000
    chalf "cnth-lo-44-control",     RUN_SAME, 10, 0x0040
    chalf "cnth-hi-44-control",     RUN_SAME, 14, 0x4400
    cbyte "cnth-hi-c0-runs",        RUN_SAME, 16, 1
    chalf "cnth-hi-c0-bit7-only-mirrors", RUN_SAME, 18, 0x4080
    chalf "cnth-lo-c0-bit7-dropped", RUN_SAME, 22, 0x0040
    cbyte "cnth-hi-40-no-run",      RUN_SAME, 24, 0
    chalf "cnth-hi-40-control",     RUN_SAME, 26, 0x4000

@ ─────────────────────────── capture DMA ──────────────────────────────────
@ WHAT: DMA3 in Special timing (video capture) with repeat, fixed source,
@ into a zeroed 16 KB ring; nonzero words counted after each of three
@ frames, the enable read back; then re-armed at each of three V-blanks.
@ WHY: it runs on every line of every armed frame (160 x 4 words = 0x280)
@ -- no every-other-frame pattern -- and the enable bit clears itself at
@ frame end (0xB700 reads back 0x3700); a re-enable reloads the internal
@ destination from DAD.
@ PROVENANCE: AGB SP, gbaedge page 22 CAPDMA (session 2, CRC F9B7);
@ hwverified/capdma.s.
run_capdma:
    push {r4-r8, lr}
    ldr r8, =SLOT
    ldr r0, =CAPDST
    mov r1, #0x1000
    mov r2, #0
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b
    bl  wait_vblank
    ldr r4, =0x040000D4
    ldr r0, =cap_pattern
    str r0, [r4]
    ldr r0, =CAPDST
    str r0, [r4, #4]
    mov r0, #4
    strh r0, [r4, #8]
    ldr r0, =0xB700
    strh r0, [r4, #10]
    mov r7, #0
2:  bl  wait_vblank
    bl  capdma_count
    str r0, [r8, r7]
    add r7, r7, #4
    cmp r7, #12
    blt 2b
    ldrh r0, [r4, #10]
    strh r0, [r8, #12]
    mov r0, #0
    strh r0, [r4, #10]
    mov r7, #16
2:  bl  wait_vblank
    ldr r0, =0xB700
    strh r0, [r4, #10]
    bl  wait_vblank
    bl  capdma_count
    str r0, [r8, r7]
    add r7, r7, #4
    cmp r7, #28
    blt 2b
    ldrh r0, [r4, #10]
    strh r0, [r8, #28]
    mov r0, #0
    strh r0, [r4, #10]
    pop {r4-r8, pc}
capdma_count:
    ldr r1, =CAPDST
    mov r2, #0x1000
    mov r0, #0
1:  ldr r3, [r1], #4
    cmp r3, #0
    addne r0, r0, #1
    subs r2, r2, #1
    bne 1b
    bx  lr
    .ltorg
cap_pattern:
    .word 0x11223344
    cword "capture-frame-1-every-line", run_capdma, 0, 0x280
    cword "capture-frame-2",        RUN_SAME, 4, 0x280
    cword "capture-frame-3",        RUN_SAME, 8, 0x280
    chalf "capture-enable-self-clears", RUN_SAME, 12, 0x3700
    cword "capture-rearm-1",        RUN_SAME, 16, 0x280
    cword "capture-rearm-2",        RUN_SAME, 20, 0x280
    cword "capture-rearm-3",        RUN_SAME, 24, 0x280
    chalf "capture-rearm-self-clears", RUN_SAME, 28, 0x3700

@ ───────────────────── immediate DMA start and length ─────────────────────
@ WHAT/WHY/PROVENANCE: payloads/dmatime.s -- TM1 read four NOPs after the
@ enable store of an EWRAM->EWRAM DMA3 of N units: 6 + the burst (a 32-bit
@ unit costs 12 EWRAM cycles after the first).  AGB SP, 2026-09-24.
    payload_blob pl_dmatime, "dmatime.bin"
    cpay "imm-dma-none",            pl_dmatime, 0x00000, 6
    cpay "imm-dma-1-word",          pl_dmatime, 0x00001, 20
    cpay "imm-dma-2-words",         pl_dmatime, 0x00002, 32
    cpay "imm-dma-4-words",         pl_dmatime, 0x00004, 56
    cpay "imm-dma-64-words",        pl_dmatime, 0x00040, 776
    cpay "imm-dma-1024-words",      pl_dmatime, 0x00400, 12296
    cpay "imm-dma-4096-words",      pl_dmatime, 0x01000, 49160
    cpay "imm-dma-1-halfword",      pl_dmatime, 0x10001, 14
    cpay "imm-dma-2-halfwords",     pl_dmatime, 0x10002, 20
    cpay "imm-dma-64-halfwords",    pl_dmatime, 0x10040, 392

@ ───────────────── DMA from unmapped memory reads the data bus ─────────────
@ WHAT/WHY/PROVENANCE: payloads/dmaobus.s and dmaobus2.s -- an immediate
@ DMA1 from 0x04001000 (unmapped IO) copies whatever the data bus holds
@ when it starts: the CPU's last load (a 16-bit memory repeats a halfword,
@ a byte fills all four lanes; IWRAM drives only its own lanes) or the
@ last opcode fetch.  AGB SP through the link rig, 2026-09-24.
    payload_blob pl_dmaobus, "dmaobus.bin"
    cpay "unmapped-src-after-ldrsh-odd", pl_dmaobus, 0, 0xFF24FF24
    cpay "unmapped-src-after-ldrh", pl_dmaobus, 1, 0xFF24FF24
    cpay "unmapped-src-after-ldrb", pl_dmaobus, 2, 0xFFFFFFFF
    cpay "unmapped-src-no-load-opcode", pl_dmaobus, 3, 0x46C046C0
    cpay "unmapped-src-after-ldr",  pl_dmaobus, 4, 0x11223344
    payload_blob pl_dmaobus2, "dmaobus2.bin"
    cpay "bus-iw-thumb-adds",       pl_dmaobus2, 0x000, 0x31033104
    cpay "bus-iw-ldrh-lo",          pl_dmaobus2, 0x001, 0x46C03344
    cpay "bus-iw-ldrh-hi",          pl_dmaobus2, 0x002, 0x112246C0
    cpay "bus-iw-ldrb-0",           pl_dmaobus2, 0x003, 0x46C04644
    cpay "bus-iw-ldrb-1",           pl_dmaobus2, 0x004, 0x46C033C0
    cpay "bus-iw-ldrb-2",           pl_dmaobus2, 0x005, 0x462246C0
    cpay "bus-iw-ldrb-3",           pl_dmaobus2, 0x006, 0x11C046C0
    cpay "bus-iw-store-then-fetch", pl_dmaobus2, 0x007, 0x46C046C0
    cpay "bus-iw-ldr",              pl_dmaobus2, 0x008, 0x11223344
    cpay "bus-iw-arm-adds",         pl_dmaobus2, 0x009, 0xE2811004
    cpay "bus-iw-ldrh-ewram",       pl_dmaobus2, 0x00A, 0x55665566
    cpay "bus-iw-arm-ldr",          pl_dmaobus2, 0x00B, 0x11223344
    cpay "bus-iw-arm-ldrh-hi",      pl_dmaobus2, 0x00C, 0x11220000
    cpay "bus-ew-thumb-adds",       pl_dmaobus2, 0x100, 0x31033103
    cpay "bus-ew-ldrh-lo",          pl_dmaobus2, 0x101, 0x46C046C0
    cpay "bus-ew-ldrh-hi",          pl_dmaobus2, 0x102, 0x46C046C0
    cpay "bus-ew-ldrb-0",           pl_dmaobus2, 0x103, 0x46C046C0
    cpay "bus-ew-ldrb-1",           pl_dmaobus2, 0x104, 0x46C046C0
    cpay "bus-ew-ldrb-2",           pl_dmaobus2, 0x105, 0x46C046C0
    cpay "bus-ew-ldrb-3",           pl_dmaobus2, 0x106, 0x46C046C0
    cpay "bus-ew-store-then-fetch", pl_dmaobus2, 0x107, 0x46C046C0
    cpay "bus-ew-ldr",              pl_dmaobus2, 0x108, 0x46C046C0
    cpay "bus-ew-arm-adds",         pl_dmaobus2, 0x109, 0xE2811003
    cpay "bus-ew-ldrh-ewram",       pl_dmaobus2, 0x10A, 0x46C046C0
    cpay "bus-ew-arm-ldr",          pl_dmaobus2, 0x10B, 0xE1A00000
    cpay "bus-ew-arm-ldrh-hi",      pl_dmaobus2, 0x10C, 0xE1A00000

@ ───────────────── DMA start, per-region burst, trigger instant ────────────
@ WHAT: gbaedge page 46 DMATIME, its code unchanged: (a) TM0 read by the
@ instruction right after the store enabling an immediate DMA0 of 1/4/16
@ words, with the enable-clear stream as baseline; (b) 16-word DMA3 bursts
@ between EWRAM, IWRAM, VRAM, palette, OAM and from ROM, timed by the
@ cartridge stopwatch; (c) the H-blank and V-blank DMA's word landing
@ against the polled flag rise; (d) a 16-word DMA3 with its completion IRQ:
@ the handler's TM0 stamp less the CPU's own resume stamp, and whether the
@ last word was already in memory when the CPU resumed.
@ WHY: an emulator's DMA start delay, per-region access costs (a VRAM
@ burst pays mode-3 contention) and completion-interrupt latency against a
@ running CPU all show up as cycle counts.
@ PROVENANCE: AGB SP, gbaedge page 46 DMATIME (session 5, 2026-09-04, CRC
@ 8367; agb-sp-5.txt).  The code runs from the cartridge at WAITCNT 0:
@ cartridge only.  VCOUNT at the H-blank DMA (+21) depends on where the
@ page happened to start and is not checked; the two flag-to-word rows
@ include a polling loop and are checked +-4.
.equ V8SRC, 0x0200A000
.equ V8DST, 0x0200E000
fill_words:
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    bx  lr
.macro dt_burst src, dst, off
    ldr r0, =\src
    str r0, [r6]
    ldr r0, =\dst
    str r0, [r6, #4]
    bl  tm_start
    ldr r1, =0x84000010
    str r1, [r6, #8]
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
.macro dt_start cnt, off
    ldr r0, =V8SRC
    str r0, [r5]
    ldr r0, =V8DST
    str r0, [r5, #4]
    bl  tm_start
    ldr r1, =\cnt
    str r1, [r5, #8]
    ldrh r9, [r10]
    bl  tm_stop
    strh r9, [r8, #\off]
.endm
run_dmatime:
    push {r4-r11, lr}
    bl  sp_irq_ewram               @ as the photographed run (suite_irq.inc)
    ldr r8, =SLOT
    ldr r7, =SCRATCH
    mov r4, #IOBASE
    ldr r10, =0x04000100
    ldr r5, =0x040000B0
    ldr r6, =0x040000D4
    ldr r0, =V8SRC
    ldr r1, =0xC0FFEE46
    mov r2, #64
    bl  fill_words
    dt_start 0x84000001, 0
    dt_start 0x04000001, 2
    dt_start 0x84000004, 4
    dt_start 0x84000010, 6
    dt_burst V8SRC,      V8DST,      8
    dt_burst 0x03001000, 0x03001100, 10
    dt_burst 0x06010000, 0x06010100, 12
    dt_burst 0x05000000, 0x05000100, 14
    dt_burst 0x07000000, 0x07000100, 16
    dt_burst db_pattern, V8DST,      18
    ldr r11, =V8DST + 0x400
    mov r0, #0
    str r0, [r11]
    ldr r0, =V8SRC
    str r0, [r6]
    str r11, [r6, #4]
1:  ldrh r0, [r4, #4]
    tst r0, #2
    beq 1b
2:  ldrh r0, [r4, #4]
    tst r0, #2
    bne 2b
    ldr r0, =0xA4000001
    str r0, [r6, #8]
    bl  tm_start
3:  ldrh r0, [r4, #4]
    tst r0, #2
    beq 3b
    ldrh r9, [r10]
4:  ldr r0, [r11]
    cmp r0, #0
    beq 4b
    ldrh r1, [r10]
    sub r1, r1, r9
    ldrh r2, [r4, #4]
    strb r2, [r8, #20]
    ldrh r2, [r4, #6]
    strb r2, [r8, #21]
    strh r1, [r8, #24]
    bl  tm_stop
    mov r0, #0
    str r0, [r11]
    ldr r0, =V8SRC
    str r0, [r6]
    str r11, [r6, #4]
1:  ldrh r0, [r4, #6]
    cmp r0, #100
    bne 1b
    ldr r0, =0x94000001
    str r0, [r6, #8]
    bl  tm_start
2:  ldrh r0, [r4, #4]
    tst r0, #1
    beq 2b
    ldrh r9, [r10]
3:  ldr r0, [r11]
    cmp r0, #0
    beq 3b
    ldrh r1, [r10]
    sub r1, r1, r9
    ldrh r2, [r4, #4]
    strb r2, [r8, #22]
    ldrh r2, [r4, #6]
    strb r2, [r8, #23]
    strh r1, [r8, #26]
    bl  tm_stop
    ldr r0, =V8DST
    mov r1, #0
    mov r2, #16
    bl  fill_words
    mov r0, #0
    str r0, [r7, #0x4C]
    ldr r0, =0x04000200
    mov r1, #0x0800
    strh r1, [r0]
    ldr r1, =0x3FFF
    strh r1, [r0, #2]
    mov r1, #1
    strh r1, [r0, #8]
    ldr r0, =V8SRC
    str r0, [r6]
    ldr r0, =V8DST
    str r0, [r6, #4]
    ldr r12, =V8DST + 60
    bl  tm_start
    ldr r1, =0xC4000010
    str r1, [r6, #8]
    ldrh r9, [r10]
    ldr r11, [r12]
    ldr r6, =0x00080000
5:  ldr r0, [r7, #0x4C]
    cmp r0, #0
    bne 6f
    subs r6, r6, #1
    bne 5b
6:  ldrh r0, [r7, #0x48]
    sub r0, r0, r9
    strh r0, [r8, #28]
    ldr r3, =0xC0FFEE46
    cmp r11, r3
    moveq r0, #1
    movne r0, #0
    strb r0, [r8, #30]
    bl  tm_stop
    ldr r0, =0x04000200
    mov r1, #0
    strh r1, [r0, #8]
    strh r1, [r0]
    pop {r4-r11, pc}
    .ltorg
    chalf "dmatime-imm-1-word-resume", run_dmatime, 0, 0x0038, F_CART
    chalf "dmatime-enable-clear-baseline", RUN_SAME, 2, 0x002A, F_CART
    chalf "dmatime-imm-4-words-resume", RUN_SAME, 4, 0x0067, F_CART
    chalf "dmatime-imm-16-words-resume", RUN_SAME, 6, 0x00F7, F_CART
    chalf "dmatime-burst-ewram",    RUN_SAME, 8, 0x011C, F_CART
    chalf "dmatime-burst-iwram",    RUN_SAME, 10, 0x007C, F_CART
    chalf "dmatime-burst-vram-mode3", RUN_SAME, 12, 0x00B1, F_CART
    chalf "dmatime-burst-palette",  RUN_SAME, 14, 0x009C, F_CART
    chalf "dmatime-burst-oam",      RUN_SAME, 16, 0x007C, F_CART
    chalf "dmatime-burst-rom-ewram", RUN_SAME, 18, 0x011E, F_CART
    cbyte "dmatime-hblank-dma-in-hblank", RUN_SAME, 20, 0x02, F_CART
    cbyte "dmatime-vblank-dma-in-vblank", RUN_SAME, 22, 0x01, F_CART
    cbyte "dmatime-vblank-dma-line-160", RUN_SAME, 23, 0xA0, F_CART
    crange "dmatime-hblank-flag-to-word", RUN_SAME, 24, 0xFFFF, 0x0025 - 4, 0x0025 + 4, F_CART
    crange "dmatime-vblank-flag-to-word", RUN_SAME, 26, 0xFFFF, 0x0025 - 4, 0x0025 + 4, F_CART
    chalf "dmatime-completion-irq-after-resume", RUN_SAME, 28, 0x006D, F_CART
    cbyte "dmatime-cpu-resumes-after-last-word", RUN_SAME, 30, 0x01, F_CART

    payload_blob pl_dmaphase, "dmaphase.bin"
    payload_blob pl_kitdemo, "kitdemo.bin"
    .include "gen_dma.inc"
