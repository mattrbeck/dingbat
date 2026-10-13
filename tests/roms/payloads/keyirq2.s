@ payload: how long the keypad interrupt takes to reach IF, whether it is a
@ level, and whether a short true pulse of the KEYCNT condition is caught
@
@ WHY: keyirq's console row (2026-10-13) set IF bit 12 in none of its
@ immediate samples, not even after the vacuous AND (KEYCNT 0 -> 0xC000) or
@ a false -> true write, but did after an acknowledge and 16 or 4096 delay
@ iterations (bit 1). dingbat sets IF on the store itself (03FF0309), so
@ the keypad condition reaches IF late on the console. This times it.
@
@ IME is clear throughout and IE = keypad; IF is only read. Every case
@ starts from KEYCNT 0, 0x400 idle iterations for a late IF to land, and an
@ acknowledge. TM0 (no prescaler) cascaded into TM1 is started, the case's
@ store follows, and IF bit 12 is polled (8 cycles a poll from IWRAM). The
@ answer is TM1:TM0 when the bit is seen, or 0xFFFFFFFF when it does not
@ come within 0x40000 polls (about 2M cycles).
@
@ argument bits 0-3 select the case, bits 8-15 a width; bits 4-7 are a
@ repeat tag and ignored, so one case can appear several times in a row:
@   0  KEYCNT 0xC000 (16-bit store): the latency
@   1  KEYCNT 0x8000 (AND, empty, IRQ enable clear): IF without bit 14?
@   2  0xC000, wait for IF, acknowledge, time it again: set again = a level
@   3  KEYCNT 0x4000 (OR, empty): expected never
@   4  a byte store of 0xC0 to 0x04000133: the byte path's latency
@   5  0xC000, then (width) delay iterations, then 0: is a pulse caught?
@
@ KEYCNT, IE and IME are put back and the timers stopped.
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r9, r0
    and r11, r9, #0xF              @ the case
    ldr r4, =0x04000200
    ldr r3, =0x04000130
    ldr r10, =0x04000100
    ldrh r6, [r4, #8]              @ IME
    ldrh r7, [r4]                  @ IE
    ldrh r8, [r3, #2]              @ KEYCNT
    mov r0, #0
    strh r0, [r4, #8]              @ IME off, and it stays off
    mov r0, #0x1000
    strh r0, [r4]                  @ IE: keypad
    mov r2, #0x1000                @ the acknowledge value

    mov r0, #0                     @ a quiet start
    strh r0, [r3, #2]
    mov r0, #0x400
1:  subs r0, r0, #1
    bpl 1b
    strh r2, [r4, #2]

    cmp r11, #2
    beq level
    cmp r11, #4
    beq bytes
    cmp r11, #5
    beq pulse

    mov r5, #0xC000                @ cases 0, 1, 3: one 16-bit store
    cmp r11, #1
    moveq r5, #0x8000
    cmp r11, #3
    moveq r5, #0x4000
    bl  timer_start
    strh r5, [r3, #2]
    bl  poll
    b   done

bytes:
    mov r5, #0xC0
    bl  timer_start
    strb r5, [r3, #3]
    bl  poll
    b   done

level:
    mov r5, #0xC000
    bl  timer_start
    strh r5, [r3, #2]
    bl  poll
    cmn r0, #1
    beq done                       @ never set at all
    strh r2, [r4, #2]              @ acknowledge, condition still true
    bl  timer_start
    bl  poll
    b   done

pulse:
    mov r5, r9, lsr #8
    and r5, r5, #0xFF              @ the width
    mov r1, #0xC000
    mov r12, #0
    bl  timer_start
    strh r1, [r3, #2]
    movs r0, r5
2:  subs r0, r0, #1
    bpl 2b
    strh r12, [r3, #2]
    bl  poll

done:
    mov r5, r0
    strh r8, [r3, #2]              @ KEYCNT, IE, IME back; IF bit 12 clean
    strh r2, [r4, #2]
    strh r7, [r4]
    strh r6, [r4, #8]
    mov r0, r5
    ldmfd sp!, {r4-r11, lr}
    bx  lr

timer_start:                       @ TM0 every cycle, TM1 counting its overflows
    mov r0, #0
    strh r0, [r10, #2]
    strh r0, [r10, #6]
    strh r0, [r10]
    strh r0, [r10, #4]
    mov r0, #0x84
    strh r0, [r10, #6]
    mov r0, #0x80
    strh r0, [r10, #2]
    bx  lr

poll:                              @ r0 = TM1:TM0 when IF bit 12 is seen, or ~0
    ldr r1, =0x40000
3:  ldrh r0, [r4, #2]
    tst r0, #0x1000
    bne 4f
    subs r1, r1, #1
    bne 3b
    mvn r0, #0
    b   5f
4:  ldrh r0, [r10]
    ldrh r1, [r10, #4]
    orr r0, r0, r1, lsl #16
5:  mov r1, #0
    strh r1, [r10, #2]
    strh r1, [r10, #6]
    bx  lr
    .ltorg
