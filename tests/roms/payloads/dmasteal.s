@ payload: how many cycles does an H-blank DMA actually take from the CPU?
@
@ Everything measured so far says WHEN the grant happens. Nothing says how
@ long the DMA then holds the bus, and that is the other half of what moves
@ the mGBA suite's `DMA Prefetch Break`: the burst's theft shifts the phase of
@ the loop the row is counting (docs/playtest-bugs.md section 16).
@
@ Entry is fixed by a V-count match halt on line 100, so the loop below starts
@ at a cycle the PPU chose. TM0 then free-runs while the CPU executes a loop
@ of a FIXED iteration count -- no polling anywhere, so the measurement is not
@ quantised by anything -- long enough to span that line's H-blank. Run once
@ with no DMA and once with a DMA of N transfers, and the difference is the
@ steal, exactly.
@
@ Both DMA ends are in IWRAM: this rig has no cartridge, so nothing here can
@ say anything about gamepak timing, and it does not try to.
@
@ r0 in  bits 0-7   the transfer count, 0 for no DMA at all (the baseline)
@        bits 8-11  source region      0 IWRAM 1 EWRAM 2 VRAM 3 palette 4 OAM
@        bits 12-15 destination region  (the same table)
@        bit  16    set for 32-bit transfers
@ r0 out = TM0 after the fixed loop. Subtract the baseline (arg 0) for the
@ steal; the baseline does not depend on the regions, so one covers them all.
    .arm
    .text
    .global _start

.equ IOBASE,   0x04000000
.equ TM0BASE,  0x04000100
.equ HPSRC,    0x03002800          @ the halfword the DMA reads
.equ HPDST,    0x03002900          @ and the one it writes
.equ DSSTUB,   0x03002000          @ IWRAM copy of ds_stub, clear of both
.equ SPIN,     300                 @ 300 x 4 cycles = 1200, spans H-blank

_start:
    stmfd sp!, {r4-r11, lr}
    mov r7, r0                     @ transfer count, 0 = baseline

    ldr r0, =ds_stub               @ the stub runs from IWRAM
    ldr r1, =DSSTUB
    mov r2, #((ds_stub_end - ds_stub) / 4)
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b

    mov r4, #IOBASE
    ldr r10, =TM0BASE
    ldr r9, =0x040000B0            @ DMA0
    ldr r0, =0x04000200
    ldrh r6, [r0, #8]              @ everything we disturb, saved: a resident
    push {r6}                      @ monitor has to survive us
    ldrh r6, [r0]
    push {r6}
    mov r1, #0
    strh r1, [r0, #8]              @ IME off before touching IE
    ldrh r6, [r4, #4]              @ DISPSTAT
    push {r6}
    ldrh r6, [r10, #2]
    push {r6}

    ldr r3, =region_table
    mov r0, r7, lsr #8             @ source region index
    and r0, r0, #0x0F
    ldr r0, [r3, r0, lsl #2]
    str r0, [r9]                   @ DMA0 source
    mov r1, r7, lsr #12            @ destination region index
    and r1, r1, #0x0F
    ldr r1, [r3, r1, lsl #2]
    str r1, [r9, #4]               @ DMA0 destination

    ldr r5, =0x00800000            @ reload 0, enable, prescaler 1
    ldr r8, =0xA1400000            @ enable, hblank, fixed source, fixed dest
    tst r7, #0x10000               @ DMACNT_H bit 10 = 32-bit, so bit 26 of
    orrne r8, r8, #0x04000000      @ the word written to DMA0CNT
    and r0, r7, #0xFF              @ the transfer count
    orr r8, r8, r0
    cmp r0, #0
    moveq r8, #0                   @ count 0 = the baseline: arm nothing
    ldr r12, =DSSTUB
    mov lr, pc
    bx  r12

    mov r0, #0                     @ everything back as we found it
    str r0, [r9, #8]
    pop {r6}
    strh r6, [r10, #2]
    pop {r6}
    strh r6, [r4, #4]
    ldr r0, =0x04000200
    mvn r1, #0
    strh r1, [r0, #2]
    pop {r6}
    strh r6, [r0]
    pop {r6}
    strh r6, [r0, #8]
    mov r0, r7
    ldmfd sp!, {r4-r11, lr}
    bx  lr

region_table:
    .word 0x03002800               @ 0 IWRAM
    .word 0x02000400               @ 1 EWRAM
    .word 0x06000000               @ 2 VRAM
    .word 0x05000200               @ 3 palette
    .word 0x07000200               @ 4 OAM
    .word 0x03002800
    .word 0x03002800
    .word 0x03002800
    .ltorg

@ r4 = IOBASE, r10 = TM0BASE, r9 = DMA0, r5 = 0x00800000,
@ r8 = the DMA control word, or 0 to arm nothing.
@ -> r7 = TM0 after a fixed-length loop spanning one H-blank.
@ No literal pools: the routine is copied to IWRAM.
ds_stub:
    add r2, r4, #0x200             @ IE at [r2], IF at [r2,#2], IME at [r2,#8]
    mov r12, #0
    str r12, [r9, #8]              @ DMA0 off
    str r12, [r10]                 @ TM0 off, reload 0
    strh r12, [r2, #8]             @ IME off: no handler runs, but HALT still
                                   @ exits on IE & IF, which is what we want
    mov r0, #100                   @ V-count match on line 100 ...
    mov r0, r0, lsl #8
    orr r0, r0, #0x20              @ ... and enable its interrupt
    strh r0, [r4, #4]
    mov r0, #0x04                  @ IE = V-count match only
    strh r0, [r2]
    mvn r0, #0
    strh r0, [r2, #2]              @ IF: clear all
    swi 0x020000                   @ HALT: we resume at the top of line 100
    add r2, r4, #0x200             @ the SWI clobbers r0-r3

    mov r0, #0
    strh r0, [r4, #4]              @ DISPSTAT interrupts off again
    strh r0, [r2]                  @ IE off, so nothing else wakes us
    str r5, [r10]                  @ TM0: free-running from the line's top
    cmp r8, #0
    strne r8, [r9, #8]             @ arm the H-blank DMA, unless baseline

    mov r1, #SPIN                  @ a fixed count: no poll, no quantiser
1:  subs r1, r1, #1
    bne 1b
    ldrh r7, [r10]                 @ however long that took

    mov r0, #0
    str r0, [r9, #8]
    str r0, [r10]
    bx  lr
ds_stub_end:
