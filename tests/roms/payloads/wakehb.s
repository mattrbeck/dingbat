@ payload: wakeirq.s with an H-blank source (bit 7) -- the halted and the
@ running CPU's H-blank interrupt timed from a controlled cycle.
@
@ gbaedge IRQDECOMP's "halted H-blank wake +19" (docs/hwprobe-results-agb.md
@ session 5) was a row whose HALTCNT write came from cartridge code, which
@ the console ignores (haltprobe.s): it never halted, and its anchor is a
@ poll of the H-blank flag's fall, a quantiser one ROM loop wide. halthb.s
@ and breakram.s pin the halted H-blank wake; nothing on record times a
@ RUNNING CPU's H-blank interrupt from a controlled cycle. This does: parked
@ on line 100 by a V-count halt, TM1 started, then line 100's own H-blank
@ (DISPSTAT bit 4, IE bit 1) instead of wakeirq's V-count match on 102.
@
@ r0 as wakeirq.s, plus
@      bit 7      the source is line 100's H-blank. With bit 7 clear the
@                 cells are the control: r0-agb.json's wakeirq answers,
@                 except that the four added instructions (4 cycles, run
@                 before the halt or the sled) put the interrupt 4 NOPs
@                 earlier in the sled (0x28: 095B, recorded 095F) and its
@                 end 4 cycles later (0x60: 0AFE, recorded 0AFA).
@
@ Predicted before any console run, 2026-10-14 (dingbat, both BIOSes; the
@ model: the H-blank interrupt rises with the flag at 1007 through the PPU's
@ 4-cycle sync, and the entry/return split is the V-count's):
@   0x80 017003EF   0x90 000003EB   0xA0 041903EC
@   0xA8 03A803EC   0xE0 0B3603EC   0xA2 03EC0000
@ mGBA: 01B403F3 000003F3 042003F3 03B003F3 0B3403F3 03F40000. Every
@ bit-7 cell is its V-count twin less 0x5B2 (1458 = line 102 + 5 less
@ line 100's 1007 + 4), but 0xE0, whose sled also takes line 101's H-blank.
@ A console 15 cycles early on the running rows (IRQDECOMP's irqlat-hblank
@ residual read as a law) would give 0xA0 040A03DD, 0xA8 039903DD.
@
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r9, r0
    mov r4, #0x04000000
    add r5, r4, #0x200
    ldr r12, =vars
    ldrh r1, [r5, #8]
    str r1, [r12, #16]             @ IME
    ldrh r1, [r5]
    str r1, [r12, #20]             @ IE
    ldrh r1, [r4, #4]
    str r1, [r12, #24]             @ DISPSTAT
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #28]             @ the IRQ vector
    mov r0, #0
    strh r0, [r5, #8]
    adr r2, handler
    tst r9, #0x02
    adrne r2, handler_stop
    str r2, [r1]
    str r0, [r12]
    str r0, [r12, #4]
    str r0, [r12, #8]
    str r0, [r12, #12]

    ldr r11, =0x04000104
    str r0, [r11]
    mov r0, #100                   @ park on line 100
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    swi 0x020000
    ldr r0, =0x00800000
    str r0, [r11]                  @ TM1 runs from here
    str r0, [r11, #-4]             @ and TM0, for bit 1
    tst r9, #0x04
    beq 3f
    ldr r0, =0x00C0F6A0            @ bit 2: TM2 overflows 2400 cycles on, and
    str r0, [r11, #4]              @ interrupts instead of the V-count match
    mov r0, #0x20
    strh r0, [r5]
3:

    mov r0, #102
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    tst r9, #0x80
    movne r0, #0x10                @ bit 7: line 100's own H-blank instead
    strh r0, [r4, #4]
    movne r0, #0x02
    strneh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    mov r6, #0
    mov r7, #0
    mvn r8, #0                     @ a multiplier of four significant bytes
    ldr r10, =0x02008000
    tst r9, #0x10
    moveq r0, #1
    movne r0, #0
    strh r0, [r5, #8]              @ IME
    tst r9, #0x10
    bne plain
    tst r9, #0x20
    bne running
    swi 0x020000                   @ halt; the interrupt is taken on the wake
    b finish

running:
    adr r0, after
    tst r9, #0x40
    movne r0, #0                   @ bit 6: return into the sled instead
    str r0, [r12, #8]
    ldr pc, =sled
after:
    ldrh r1, [r11]                 @ R
    tst r9, #0x02
    ldrneh r1, [r11, #-4]          @ bit 1: TM0 as the handler froze it
    tst r9, #0x08
    beq 2f
    ldr r1, [r12, #4]              @ bit 3: which NOP was next, instead of R
    ldr r0, =sled
    sub r1, r1, r0
    sub r1, r1, #4
    mov r1, r1, lsr #2
2:
    mov r0, #0
    strh r0, [r5, #8]
    ldr r0, [r12]
    orr r0, r0, r1, lsl #16
    b leave

plain:
    swi 0x020000
    ldrh r0, [r11]                 @ W
    b leave

finish:
    mov r0, #0
    strh r0, [r5, #8]
    ldr r0, [r12]                  @ H
    ldr r1, [r12, #4]              @ the interrupted address + 4
    sub r1, r1, #4
    orr r0, r0, r1, lsl #16

leave:
    mov r1, #0
    str r1, [r11, #-4]
    strh r1, [r5, #8]
    str r1, [r11]
    str r1, [r11, #4]
    ldr r1, [r12, #24]
    strh r1, [r4, #4]
    mvn r1, #0
    strh r1, [r5, #2]
    ldr r1, [r12, #20]
    strh r1, [r5]
    ldr r1, [r12, #28]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #16]
    strh r1, [r5, #8]
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

@ Called by the BIOS's dispatcher, which has pushed r0-r3, r12 and lr.
handler:
    mov r0, #0x04000000
    add r1, r0, #0x100
    ldrh r1, [r1, #4]              @ H, first thing
    ldr r2, =vars
    ldr r3, [r2, #4]
    cmp r3, #0
    bne 1f                         @ only the first interrupt is the question
    str r1, [r2]
    ldr r1, [sp, #20]
    str r1, [r2, #4]
    ldr r1, [r2, #8]
    cmp r1, #0
    addne r1, r1, #4
    strne r1, [sp, #20]            @ the control returns to `after`
1:  add r0, r0, #0x200
    ldrh r1, [r0, #2]
    strh r1, [r0, #2]
    bx lr
    .ltorg

@ bit 1: the handler's first act is to stop TM0 -- what the mGBA suite's
@ timer rows do, and they pin the value it freezes at.
handler_stop:
    mov r0, #0x04000000
    add r1, r0, #0x100
    mov r2, #0
    strh r2, [r1, #2]
    ldr r2, =vars
    ldr r1, [sp, #20]
    str r1, [r2, #4]
    ldr r1, [r2, #8]
    cmp r1, #0
    addne r1, r1, #4
    strne r1, [sp, #20]
    add r0, r0, #0x200
    ldrh r1, [r0, #2]
    strh r1, [r0, #2]
    bx lr
    .ltorg
vars:
    .space 32

sled:
    .rept 2700
    mov r0, r0
    .endr
    b after
