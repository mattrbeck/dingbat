@ ewrombench.s -- EWRAM data accesses from Thumb code fetched FROM the
@ cartridge, across wait settings with the prefetcher on and off.
@
@ The question (docs/playtest-bugs.md §63, §78, §88, §102, Banjo Pilot's
@ select_cup): what does an EWRAM load or store cost when the code issuing it
@ comes from the gamepak with the prefetcher on? slotexec.s answered it on the
@ console at WS0 4/2 (dingbat right, mGBA charging nothing), but an empty slot
@ is only safe at WAITCNT 0 and 0x4000, and the games run WS0 3/1 (0x4314 /
@ 0x4014). This ROM is for the flashcart: every subject is cartridge code.
@
@ Banjo Pilot's slow frame spends ~8.8k of its 9.9k extra cycles (dingbat
@ against mGBA) on single EWRAM loads and stores in object-list code at
@ 0x08025E4C-0x08025F5E and friends; subject G is that code's straight run.
@
@ Subjects (Thumb, from ROM unless said; r5 = an EWRAM block, r6 = IWRAM):
@   A  64 x mov r0, r0                          sequential fetch only
@   B  16 x ldr r0, [r5]                         EWRAM word loads back to back
@   C  16 x (ldr r0, [r5]; cmp r0, #0)           a load, then ALU (the game's shape)
@   D  16 x str r0, [r5, #20]                    EWRAM word stores
@   E  16 x ldrh r0, [r5]                        EWRAM halfword loads
@   F  16 x ldr r0, [r6]                         IWRAM word loads (control)
@   G  8 x Banjo Pilot 0x08025E4C..0x08025E76    loads/stores via r5, ALU, a literal
@   H  16 x (ldr r0, [r5]; 3 x mov r0, r0)       a load with fetch time after it
@   I  subject G copied into IWRAM               the floor: no gamepak fetches
@
@ Results: 9 subjects x 4 wait settings, 36 words at 0x02000000 (TM0 at one
@ tick a cycle, call overhead included and identical everywhere), marker
@ 0x600D0000 at 0x02000FFC, then offered over the link (linkreport.inc).
    .arm
    .text
    .global _start

.equ WAITCNT,  0x04000204
.equ TM0CNT_L, 0x04000100
.equ TM0CNT_H, 0x04000102
.equ EWBLOCK,  0x02010000
.equ IWBLOCK,  0x03002000
.equ IWCODE,   0x03001000

_start:
    b   main
    .space 0x9C
    .space 0x20
main:
    ldr sp, =0x03007F00
    @ subject G's copy in IWRAM (position-independent: its one literal is a
    @ word inside the block itself, addressed pc-relative)
    ldr r0, =subject_g
    ldr r1, =IWCODE
    ldr r2, =subject_g_end
    sub r2, r2, r0
1:  ldr r4, [r0], #4
    str r4, [r1], #4
    subs r2, r2, #4
    bgt 1b
    @ EWRAM and IWRAM data blocks: words that keep every cmp/branch the same
    ldr r0, =EWBLOCK
    mov r1, #0
    mov r2, #64
2:  str r1, [r0], #4
    subs r2, r2, #1
    bgt 2b
    ldr r10, =0x02000000           @ where results go
    adr r11, subjects
subject_loop:
    ldr r8, [r11]                  @ routine
    cmp r8, #0
    beq done
    adr r7, waits
    mov r9, #4                     @ four wait settings each
wait_loop:
    ldr r0, [r7], #4
    ldr r1, =WAITCNT
    strh r0, [r1]
    ldr r5, =EWBLOCK
    ldr r6, =IWBLOCK
    ldr r4, =TM0CNT_L
    ldr r3, =TM0CNT_H
    mov r0, #0
    strh r0, [r3]                  @ stop
    strh r0, [r4]                  @ count from zero
    mov r0, #0x80                  @ enable, no prescaler: one tick per cycle
    strh r0, [r3]
    mov lr, pc
    bx  r8
    ldr r4, =TM0CNT_L
    ldr r3, =TM0CNT_H
    ldrh r0, [r4]
    mov r1, #0
    strh r1, [r3]                  @ stop
    str r0, [r10], #4
    subs r9, r9, #1
    bgt wait_loop
    add r11, r11, #4
    b   subject_loop
done:
    ldr r0, =0x4014                @ leave the cart's code at a safe setting
    ldr r1, =WAITCNT
    strh r0, [r1]
    ldr r0, =0x02000FFC
    ldr r1, =0x600D0000
    str r1, [r0]
    ldr r0, =0x02000000
    mov r1, #(9 * 4)
    bl  link_report_init
1:  bl  link_report_poll
    b   1b
    .ltorg

    .include "linkreport.inc"

    .align 2
waits:
    .word 0x4014                   @ WS0 3/1, prefetch on  (the games' WS0)
    .word 0x0014                   @ WS0 3/1, prefetch off
    .word 0x4000                   @ WS0 4/2, prefetch on  (slotexec's console setting)
    .word 0x0000                   @ WS0 4/2, prefetch off
subjects:
    .word subject_a + 1
    .word subject_b + 1
    .word subject_c + 1
    .word subject_d + 1
    .word subject_e + 1
    .word subject_f + 1
    .word subject_g + 1
    .word subject_h + 1
    .word IWCODE + 1               @ subject I: subject G in IWRAM
    .word 0

    .thumb
    .align 2
subject_a:
    .rept 64
    mov r0, r0
    .endr
    bx  lr

    .align 2
subject_b:
    .rept 16
    ldr r0, [r5]
    .endr
    bx  lr

    .align 2
subject_c:
    .rept 16
    ldr r0, [r5]
    cmp r0, #0
    .endr
    bx  lr

    .align 2
subject_d:
    .rept 16
    str r0, [r5, #20]
    .endr
    bx  lr

    .align 2
subject_e:
    .rept 16
    ldrh r0, [r5]
    .endr
    bx  lr

    .align 2
subject_f:
    .rept 16
    ldr r0, [r6]
    .endr
    bx  lr

    @ Banjo Pilot 0x08025E4C-0x08025E76 (the not-taken path), eight times.
    @ sp is the IWRAM stack; r5's block is zero, so r4 = 0 and the game's
    @ `bne` at 0x08025E54 would fall through, as here.
    .align 2
subject_g:
    sub sp, #8
    .rept 8
    ldr r0, [r5, #48]
    ldr r4, [r5, #40]
    str r0, [sp, #4]
    cmp r4, #0
    ldr r0, [r5, #20]
    mov r3, #128
    lsl r3, r3, #7
    orr r0, r3
    mov r3, #128
    lsl r3, r3, #8
    orr r0, r3
    ldr r2, [r5, #24]
    ldr r3, g_lit
    str r0, [r5, #20]
    cmp r2, r3
    mov r3, #128
    lsl r3, r3, #7
    orr r0, r3
    str r0, [r5, #20]
    lsl r1, r0, #24
    .endr
    add sp, #8
    bx  lr
    .align 2
g_lit:
    .word 0x01000100
subject_g_end:

    .align 2
subject_h:
    .rept 16
    ldr r0, [r5]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    .endr
    bx  lr
