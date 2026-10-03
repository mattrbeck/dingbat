@ ldmvar.s -- is a 5-register ldm's cost fixed when the code runs from
@ IWRAM? 64 trials of: TM0 start, ARM `ldmia r2!, {r0, r1, r3, r4, r5}`
@ from r0 = 0 EWRAM, 1 IWRAM, 2 VRAM, TM0 read; halfwords to 0x02008000.
@ AGB SP, 2026-10-02: 32 / 7 / 12 in all 64 trials of each, as dingbat and
@ mGBA say -- the control for slotldm.s, whose same loads from the empty
@ slot's code vary by 2.
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    ldr r7, =0x04000100
    ldr r8, =0x02008000
    adr r9, bases
    ldr r9, [r9, r0, lsl #2]
    mov r10, #64
    mov r11, #0
    str r11, [r7]
    mov r6, #0x80
1:  mov r2, r9
    strh r11, [r7, #2]             @ TM0 off
    strh r6, [r7, #2]              @ TM0 on
    ldmia r2!, {r0, r1, r3, r4, r5}
    ldrh r3, [r7]
    strh r3, [r8], #2
    subs r10, r10, #1
    bne 1b
back:
    mov r0, #0
    str r0, [r7]
    ldr r0, =0x4C444D56
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg
bases:
    .word 0x02010000, 0x03006000, 0x06010000
