@ payload: dbsuite irqdecomp's anchors -- its poll loops on DISPSTAT's
@ H-blank flag and on VCOUNT, run from EWRAM as the page runs -- timed
@ from a fixed cycle.
@
@ irqpoll.s cleared the interrupt's way into the page's id_delta loop (512
@ console cells, every one dingbat's), yet irqlat-hblank-haltcnt,
@ irqlat-vblank and irqlat-vblank-haltcnt still disagree from EWRAM. What
@ is left is where each case starts: id_anchor_hb polls the H-blank flag
@ set and then clear, id_anchor_vb polls VCOUNT to 157 and then 158. A
@ cycle's error in the flag's or VCOUNT's edge, as an EWRAM `ldrh` sees it,
@ moves a poll's exit by a whole iteration at some phases only.
@
@ Park on a V-count match (a fixed cycle), d + 4c cycles, start TM1, run
@ the loop from EWRAM, read TM1 on its way out.
@ r0: bits 0-3 d, bits 16-19 c, bits 4-5 mode: 0 = the H-blank flag's
@     rise (poll until set), 1 = its fall (set, then clear: id_anchor_hb),
@     2 = VCOUNT to 157 then 158 (id_anchor_vb), bits 8-15 the park line
@     (0 = 100, 150 for mode 2).
@ answer: TM1 at the loop's exit.
    .arm
    .text
    .global _start
    .include "probe.inc"
.equ EWSTUB, 0x02010000

_start:
    probe_enter
    @ the mode's loop to EWRAM
    mov r1, r9, lsr #4
    and r1, r1, #3
    adr r0, rise
    adr r2, fall
    cmp r1, #1
    moveq r0, r2
    adr r2, vbl
    cmp r1, #2
    moveq r0, r2
    adr r2, stubs_end
    ldr r1, =EWSTUB
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    cmp r0, r2
    blt 1b
    ldr r6, =EWSTUB
    @ the park line
    mov r1, r9, lsr #8
    ands r1, r1, #0xFF
    bne 2f
    mov r2, r9, lsr #4
    and r2, r2, #3
    cmp r2, #2
    moveq r1, #150
    movne r1, #100
2:  mov r0, r1, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    swi 0x020000                   @ park
    mov r0, r9, lsr #16
    and r0, r0, #15
    add r0, r0, #1
4:  subs r0, r0, #1
    bne 4b
    probe_sled
    str r11, [r10, #4]             @ TM1 starts
    mov lr, pc
    bx  r6
    probe_read_tm1 r0
    probe_leave

rise:                              @ poll until the H-blank flag is set
1:  ldrh r0, [r4, #4]
    tst r0, #2
    beq 1b
    bx  lr
fall:                              @ id_anchor_hb: set, then clear
1:  ldrh r0, [r4, #4]
    tst r0, #2
    beq 1b
2:  ldrh r0, [r4, #4]
    tst r0, #2
    bne 2b
    bx  lr
vbl:                               @ id_anchor_vb: VCOUNT to 157, then 158
1:  ldrh r0, [r4, #6]
    cmp r0, #157
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #158
    bne 2b
    bx  lr
stubs_end:
    probe_data
