@ payload: the keypad interrupt -- an edge or a level, and what a KEYCNT
@ write does, with no button held
@
@ WHY: Ghost Rider and Catwoman (one engine) put the console to sleep with
@ SWI 3 (Stop) and KEYCNT 0xC304 (IRQ on L+R+SELECT, AND). Once woken they
@ write KEYCNT 0xC000 -- IRQ on, AND, no key selected, which matches
@ vacuously -- and Stop again, and expect that second Stop to return.
@ dingbat raises the keypad interrupt on a rising edge of the condition
@ only, and the condition was already true (the wake combination, or the
@ vacuous match), so the second Stop never returns: both games stay black
@ after sleep mode. Cabbage Patch Kids - The Patch Puppy Rescue sleeps with
@ KEYCNT 0x8304 (AND, L+R+SELECT, IRQ enable clear) and IE = keypad |
@ gamepak, so it can only wake if the condition sets IF without bit 14.
@ Both references treat Stop as a halt that the next interrupt ends, so
@ they cannot say. This asks the console, without pressing anything.
@
@ IME is clear throughout; IF is only read back. Each step starts from a
@ clean IF bit 12 (written 1 to acknowledge):
@
@   bit 0  KEYCNT 0 -> 0xC000 (16-bit store): the vacuous AND sets IF?
@   bit 1  acknowledged, r0 (the argument) delay iterations, read again:
@          set again = a level
@   bit 2  acknowledged, 0xC000 stored again over 0xC000: a write that
@          keeps the condition true raises it?
@   bit 3  acknowledged, KEYCNT 0, then 0xC000: a false -> true write
@   bit 4  acknowledged, 0x8000 (AND, empty, IRQ enable clear): IF without
@          bit 14?
@   bit 5  acknowledged, 0x4000 (OR, empty): expected clear
@   bit 6  acknowledged, 0xC001 (AND, A, not held): expected clear
@   bit 7  acknowledged, 0x4001 (OR, A, not held): expected clear
@   bit 8  acknowledged, 0x0000 then byte stores 0x00 to 0x132, 0xC0 to
@          0x133: the byte path
@   bit 9  acknowledged, 0x8000 stored over 0x8000, then 0xC000 stored over
@          it (the enable turned on while the vacuous AND already holds)
@
@ answer: bits 0-9 as above, bits 16-25 KEYINPUT (0x3FF: nothing held).
@ KEYCNT, IE and IME are put back.
@
@ Argument bit 31 (ad hoc only, NOT in the r0table row): IE = keypad,
@ KEYCNT 0xC000 (bit 0 of the argument clear) or 0x8000 (set: the IRQ
@ enable off), IF clean, then SWI 3 (Stop). The answer is 0x57000000 | IF
@ bit 12 if the console comes back: the vacuous condition ends a Stop, as
@ Ghost Rider's second Stop needs (0xC000), and does so without KEYCNT's
@ IRQ enable, as the 0x8304 sleepers need (0x8000). If it does not come
@ back, nothing else can wake it here: the console needs a power cycle.
@ dingbat (stop_key_condition) returns 0x57000000 for both; the references
@ return from any Stop (they treat it as a halt).
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r9, lr}
    mov r9, r0                     @ the delay for bit 1
    ldr r4, =0x04000200
    ldr r3, =0x04000130
    ldrh r6, [r4, #8]              @ IME
    ldrh r7, [r4]                  @ IE
    ldrh r8, [r3, #2]              @ KEYCNT
    mov r0, #0
    strh r0, [r4, #8]              @ IME off, and it stays off
    mov r0, #0x1000
    strh r0, [r4]                  @ IE: keypad (IF latches regardless)
    mov r5, #0
    mov r2, #0x1000                @ the acknowledge value
    tst r9, #0x80000000
    bne stopcell

    @ bit 0
    mov r0, #0
    strh r0, [r3, #2]
    strh r2, [r4, #2]
    mov r0, #0xC000
    strh r0, [r3, #2]
    bl  sample
    orr r5, r5, r1

    @ bit 1
    strh r2, [r4, #2]
    movs r0, r9
1:  subs r0, r0, #1
    bpl 1b
    bl  sample
    orr r5, r5, r1, lsl #1

    @ bit 2
    strh r2, [r4, #2]
    mov r0, #0xC000
    strh r0, [r3, #2]
    bl  sample
    orr r5, r5, r1, lsl #2

    @ bit 3
    strh r2, [r4, #2]
    mov r0, #0
    strh r0, [r3, #2]
    bl  sample                     @ (the 0 store must not set it either)
    strh r2, [r4, #2]
    mov r0, #0xC000
    strh r0, [r3, #2]
    bl  sample
    orr r5, r5, r1, lsl #3

    @ bit 4
    mov r0, #0
    strh r0, [r3, #2]
    strh r2, [r4, #2]
    mov r0, #0x8000
    strh r0, [r3, #2]
    bl  sample
    orr r5, r5, r1, lsl #4

    @ bit 5
    mov r0, #0
    strh r0, [r3, #2]
    strh r2, [r4, #2]
    mov r0, #0x4000
    strh r0, [r3, #2]
    bl  sample
    orr r5, r5, r1, lsl #5

    @ bit 6
    mov r0, #0
    strh r0, [r3, #2]
    strh r2, [r4, #2]
    ldr r0, =0xC001
    strh r0, [r3, #2]
    bl  sample
    orr r5, r5, r1, lsl #6

    @ bit 7
    mov r0, #0
    strh r0, [r3, #2]
    strh r2, [r4, #2]
    ldr r0, =0x4001
    strh r0, [r3, #2]
    bl  sample
    orr r5, r5, r1, lsl #7

    @ bit 8
    mov r0, #0
    strh r0, [r3, #2]
    strh r2, [r4, #2]
    strb r0, [r3, #2]
    mov r0, #0xC0
    strb r0, [r3, #3]
    bl  sample
    orr r5, r5, r1, lsl #8

    @ bit 9
    mov r0, #0
    strh r0, [r3, #2]
    mov r0, #0x8000
    strh r0, [r3, #2]
    strh r2, [r4, #2]
    strh r0, [r3, #2]
    mov r0, #0xC000
    strh r0, [r3, #2]
    bl  sample
    orr r5, r5, r1, lsl #9

    ldrh r0, [r3]                  @ KEYINPUT
    mov r0, r0, lsl #22
    orr r5, r5, r0, lsr #6         @ bits 16-25

restore:
    strh r8, [r3, #2]              @ KEYCNT, IE back; IF bit 12 clean
    strh r2, [r4, #2]
    strh r7, [r4]
    strh r6, [r4, #8]
    mov r0, r5
    ldmfd sp!, {r4-r9, lr}
    bx  lr

stopcell:
    mov r0, #0xC000
    tst r9, #1
    movne r0, #0x8000
    strh r0, [r3, #2]
    strh r2, [r4, #2]
    swi 0x030000                   @ Stop
    bl  sample
    orr r5, r1, #0x57000000
    b   restore

sample:                            @ r1 = IF bit 12 a few cycles on
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldrh r1, [r4, #2]
    mov r1, r1, lsr #12
    and r1, r1, #1
    bx  lr
    .ltorg
