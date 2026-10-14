@ payload: does the keypad interrupt's latency depend on the cycle phase of
@ the KEYCNT store -- a divided clock -- and what sets that phase?
@
@ WHY: keyirq2's console row (2026-10-13) times KEYCNT 0 -> 0xC000 to IF at
@ 0x4F timer cycles (0x46 once in nine), and the byte path at 0x46 three
@ times in three, though the code from the store to the poll is the same
@ in both cases: the two differ only in the cycles before the store. A
@ fixed hold (keypad.nim KEYPAD_IRQ_HOLD) cannot answer both; a condition
@ sampled on a divided clock can.
@
@ The case is keyirq2's case 0 (IME clear, IE keypad, KEYCNT 0, a quiet
@ 0x400-turn loop, acknowledge, TM0:TM1 started, KEYCNT 0xC000, poll IF bit
@ 12 every 9 cycles), with n = argument bits 0-4 one-cycle NOPs inserted:
@   bit 8 clear (set A): after the quiet loop, just before the timer starts
@                        -- the store moves against the quiet KEYCNT 0
@                        store and against any free-running clock
@   bit 8 set   (set B): before the quiet KEYCNT 0 store -- everything moves
@                        together, so only a free-running clock sees n
@ The answer is TM1:TM0 when IF bit 12 is seen, 0xFFFFFFFF on a timeout.
@ Latency that cycles with n in set A only: the phase is the last KEYCNT
@ write's. In both: a free-running clock the monitor's call happens to fix.
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r9, r0
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
    mov r5, #0xC000

    tst r9, #0x100
    blne sled                      @ set B: n cycles before everything

    mov r0, #0                     @ a quiet start
    strh r0, [r3, #2]
    mov r0, #0x400
1:  subs r0, r0, #1
    bpl 1b
    strh r2, [r4, #2]

    tst r9, #0x100
    bleq sled                      @ set A: n cycles before the store only

    bl  timer_start
    strh r5, [r3, #2]
    bl  poll

    mov r5, r0
    strh r8, [r3, #2]              @ KEYCNT, IE, IME back; IF bit 12 clean
    strh r2, [r4, #2]
    strh r7, [r4]
    strh r6, [r4, #8]
    mov r0, r5
    ldmfd sp!, {r4-r11, lr}
    bx  lr

sled:                              @ n = r9 bits 0-4 one-cycle NOPs, then back
    and r0, r9, #0x1F
    rsb r0, r0, #32
    add pc, pc, r0, lsl #2         @ pc reads 8 on: skip 32 - n of the 32
    mov r0, r0
    .rept 32
    mov r0, r0
    .endr
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
