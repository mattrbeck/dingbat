@ payload: is the V-count match an edge, and does a register write make one?
@
@ breakram.s found the match flag in DISPSTAT to be a live compare: rewrite
@ the setting mid-line and the flag is already clear. That leaves the
@ interrupt. Parked on line 100 by a halt (IME clear throughout, so nothing is
@ ever taken and IF is just read back), three questions, each from a clean IF:
@
@   A  setting moved 50 -> 100 mid-line, interrupt enable already on
@   B  setting already 100 and matching, interrupt enable turned on mid-line
@   C  setting 100, enable on, IF cleared mid-line: does the level re-raise it?
@
@ answer: bit 0/8/16 = IF's V-count bit after A/B/C; bits 4/12/20 = DISPSTAT's
@ match flag read at the same moment; bits 24..31 = VCOUNT at the end (100, or
@ the page took too long to mean anything).
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r8, lr}
    ldr r4, =0x04000200
    mov r3, #0x04000000
    ldrh r6, [r4, #8]              @ IME
    ldrh r7, [r4]                  @ IE
    ldrh r8, [r3, #4]              @ DISPSTAT
    mov r0, #0
    strh r0, [r4, #8]              @ IME off, and it stays off

    mov r0, #100                   @ park on line 100
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r3, #4]
    mov r0, #0x04
    strh r0, [r4]
    mvn r0, #0
    strh r0, [r4, #2]
    swi 0x020000

    @ A: the setting arrives at the current line with the enable on
    mov r0, #50
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r3, #4]
    mvn r0, #0
    strh r0, [r4, #2]              @ IF clean
    mov r0, #100
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r3, #4]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r1, [r4, #2]
    ldrh r2, [r3, #4]
    and r5, r1, #4
    mov r5, r5, lsr #2
    and r2, r2, #4
    orr r5, r5, r2, lsl #2         @ bit 0, bit 4

    @ B: matching already, the enable arrives
    mov r0, #100
    mov r0, r0, lsl #8
    strh r0, [r3, #4]              @ enable off, still matching
    mvn r0, #0
    strh r0, [r4, #2]
    mov r0, #100
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r3, #4]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r1, [r4, #2]
    ldrh r2, [r3, #4]
    and r1, r1, #4
    orr r5, r5, r1, lsl #6         @ bit 8
    and r2, r2, #4
    orr r5, r5, r2, lsl #10        @ bit 12

    @ C: matching, enabled, IF acknowledged: a level would come straight back
    mvn r0, #0
    strh r0, [r4, #2]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r1, [r4, #2]
    ldrh r2, [r3, #4]
    and r1, r1, #4
    orr r5, r5, r1, lsl #14        @ bit 16
    and r2, r2, #4
    orr r5, r5, r2, lsl #18        @ bit 20

    ldrh r1, [r3, #6]
    orr r5, r5, r1, lsl #24

    strh r8, [r3, #4]
    mvn r0, #0
    strh r0, [r4, #2]
    strh r7, [r4]
    strh r6, [r4, #8]
    mov r0, r5
    ldmfd sp!, {r4-r8, lr}
    bx lr
