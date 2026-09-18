@ payload: which condition kills channel 1's trigger?
@
@ This is gbaedge slot 52 (PSGWHY), re-hosted as a link-cable payload so it
@ can be run without a flashcart or a photograph. The rows, the macros and
@ the byte layout are the probe's, unchanged, so its results table reads
@ against this one directly; only the plumbing differs -- it writes its 32
@ bytes to 0x02008000 for the host to read back rather than to a screen slot.
@
@ p44 and p51 (docs/hwprobe-results-agb.md session 6) agree that a ch1
@ trigger shortly after a SOUNDCNT_X master-on dies while ch2/3/4 live, that
@ NR10 = 0x11 saves it, and that the first two ch1 triggers die while a third
@ lives. Every ch1 row that died triggered at frequency 0x400 -- exactly half
@ the sweep's overflow limit 0x800. The candidate: ch1's sweep overflow check
@ runs on trigger even with shift 0, computes f + f, and at f = 0x400
@ overflows. Rows +16..+20 separate elapsed time from trigger count.
@
@ Every row is two bytes:
@   +n    polls until SOUNDCNT_X bit 0 ROSE (0 = set on the first read after
@         the store; FF = never rose within 255 polls)
@   +n+1  polls it then stayed set, >> 8 (FF = never fell before the cap,
@         00 = fell at once)
@ so a trigger that never enables reads FF 00, one that enables late nn 49,
@ and a healthy counter-16 tone 00 49. Both p44 and p51 could only watch the
@ bit fall, which is why neither could tell those two apart.
    .arm
    .text
    .global _start

.equ IOBASE,  0x04000000
.equ RESULTS, 0x02008000

@ r4 = IOBASE, r8 = results, r9 = cap hits.  r0 = NR11/NR12 halfword,
@ r1 = NR13/NR14 halfword -> r3 = rise polls (byte), r2 = fall polls >> 8
.macro pw_trigger
    strh r0, [r4, #0x62]
    strh r1, [r4, #0x64]
    mov r3, #0
1:  ldrh r0, [r4, #0x84]
    tst r0, #1
    bne 2f
    add r3, r3, #1
    cmp r3, #255
    bcc 1b
    mov r2, #0                     @ never rose
    b   4f
2:  ldr r12, =0x00060000
    mov r2, #0
3:  ldrh r0, [r4, #0x84]
    tst r0, #1
    beq 5f
    add r2, r2, #1
    subs r12, r12, #1
    bne 3b
    add r9, r9, #1
    mov r2, #0xFF00                @ never fell
5:  mov r2, r2, lsr #8
    cmp r2, #255
    movhi r2, #255
4:
.endm

.macro pw_row off
    strb r3, [r8, #\off]
    strb r2, [r8, #(\off + 1)]
.endm

@ master off (clears every PSG register) then on, mixer routes ch1-4
.macro pw_reset
    mov r0, #0
    strh r0, [r4, #0x84]
    mov r0, #0x80
    strh r0, [r4, #0x84]
    ldr r0, =0xFF77
    strh r0, [r4, #0x80]
    mov r0, #2
    strh r0, [r4, #0x82]
.endm

@ wait for n V-blank rises
.macro pw_frames n
    mov r12, #\n
1:  ldrh r0, [r4, #4]
    tst r0, #1
    bne 1b
2:  ldrh r0, [r4, #4]
    tst r0, #1
    beq 2b
    subs r12, r12, #1
    bne 1b
.endm

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r8, =RESULTS
    mov r0, #0                     @ EWRAM boots as noise; clear the slot
    mov r1, #0
    mov r2, #0
    mov r3, #0
    stmia r8, {r0-r3}
    add r12, r8, #16
    stmia r12, {r0-r3}
    mov r4, #IOBASE
    mov r9, #0

    pw_reset
    ldr r0, =0xF0B0                @ envelope 15, duty 2, counter 16
    ldr r1, =0xC400                @ trigger, length on, f = 0x400
    pw_trigger
    pw_row 0
    ldr r0, =0xF0B0                @ +20: retrigger straight away
    ldr r1, =0xC400
    pw_trigger
    pw_row 20

    pw_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC3FF                @ f = 0x3FF
    pw_trigger
    pw_row 2

    pw_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC000                @ f = 0, length on
    pw_trigger
    pw_row 4

    pw_reset
    ldr r0, =0xF0B0
    ldr r1, =0x8400                @ f = 0x400, length OFF
    pw_trigger
    pw_row 6

    .irp nr10, 0x08, 0x10, 0x01
    pw_reset
    mov r0, #\nr10
    strh r0, [r4, #0x60]
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pw_trigger
    .if \nr10 == 0x08
    pw_row 8
    .elseif \nr10 == 0x10
    pw_row 10
    .else
    pw_row 12
    .endif
    .endr

    pw_reset
    mov r0, #0x01
    strh r0, [r4, #0x60]
    ldr r0, =0xF0B0
    ldr r1, =0xC7FF                @ f = 0x7FF, shift 1: overflows
    pw_trigger
    pw_row 14

    pw_reset
    pw_frames 2
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pw_trigger
    pw_row 16

    pw_reset
    pw_frames 16
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pw_trigger
    pw_row 18

    pw_reset
    ldr r0, =0xF0B0
    strh r0, [r4, #0x68]           @ ch2 NR21/NR22
    ldr r0, =0xC400
    strh r0, [r4, #0x6C]           @ ch2 trigger, then ch1 at once
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pw_trigger
    pw_row 22

    pw_reset
    ldr r0, =0x4400                @ length on, frequency, NO trigger
    strh r0, [r4, #0x64]
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pw_trigger
    pw_row 24

    pw_reset
    mov r0, #0
    strh r0, [r4, #0x80]           @ SOUNDCNT_L: nothing routed
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pw_trigger
    pw_row 26

    pw_reset
    pw_frames 16
    mov r0, #0x80
    strh r0, [r4, #0x84]           @ on -> on: no 0 -> 1 edge
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pw_trigger
    pw_row 28

    strb r9, [r8, #30]
    mov r0, #52
    strb r0, [r8, #31]
    mov r0, #0
    strh r0, [r4, #0x84]           @ leave the PSG off behind us
    ldr r0, =0x50534700            @ 'PSG\0': the payload ran to the end
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg
