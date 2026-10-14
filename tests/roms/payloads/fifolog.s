@ payload: fifoffff.s's refill stream logged -- ten TM1 reads 3 cycles apart
@ instead of one, so one run shows every burst that lands in a ~30-cycle
@ window and how long each held the CPU
@
@ WHY: fifoffff.s (AGB SP, 2026-09-25; tools/hwlink/open-agb.json 'fifo')
@ fits a toy rule at k = 1, 2 and 4 (docs/playtest-bugs.md, "FIFO refills
@ at periods 1-3"): a refill request lands 4 cycles after its overflow; the
@ FIFO's level is counted as the burst's words land; a request landing in
@ the burst's last cycle chains the next burst (8 cycles, no lead / trail),
@ one landing earlier in the burst is dropped. k = 3 fits nothing: its
@ extras 11 (n = 0), 19 (n = 1..28), 29 (n = 29..) are odd, where bursts are
@ 10 and 8. One read a run cannot say which burst carries the odd cycle;
@ ten reads 3 cycles apart can: a gap between consecutive samples of
@ 3 + L is a burst of L cycles before that read.
@
@ WHAT: as fifoffff.s (FIFO A on TM0 at reload 0x10000 - k, DMA1 32-bit
@ repeat from IWRAM, w words stored first, TM0 / TM1 started together, n
@ one-cycle NOPs), then ten `ldrh` of TM1 back to back (fetch, IO data,
@ internal: 3 cycles each), stored after the last; the answer is sample i.
@ Sample 0 is fifoffff.s's read: it must equal that payload's recorded cell
@ for the same k, w, n, bit 10.
@
@ SAFETY: fifoffff.s's exit path unchanged (TM0 stopped, ~160 cycles, DMA1
@ off, the V-blank DMA0 guard). Keep to k = 1..4 and the IWRAM source: those
@ fifoffff cells went through 632 runs; the console wedged in its k = 6..20
@ set (docs/hwprobe-questions.md, "Rig hazard"), and an EWRAM source at
@ k <= 3 would starve the CPU (a 30-cycle burst brings 16 bytes).
@
@ r0 bits 0..7   n  NOPs (0..63)
@    bits 8..9   w  words stored in FIFO A before the start (0..3)
@    bit  10     TM0's count left at 0xFFFF before the enable (else ~0)
@    bit  11     DMA1 source EWRAM 0x02004000 (else IWRAM) -- see SAFETY
@    bits 16..23 k: TM0 reload 0x10000 - k (0 = 1)
@    bits 24..27 i: which of the ten samples to answer with (0..9)
@ answer: TM1 at sample i; bit 31 = the guard ran
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r11, r0
    mov r4, #0x04000000
    ldrh r0, [r4, #0x84]
    ldrh r1, [r4, #0x82]
    orr r0, r0, r1, lsl #16
    str r0, saved                  @ SOUNDCNT_H << 16 | SOUNDCNT_X
    mov r0, #0
    str r0, [r4, #0x104]           @ TM1 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    strh r0, [r4, #0xBA]           @ DMA0 off
    @ TM0's count: run it from the reload and stop it again
    tst r11, #0x400
    ldreq r1, =0x00800000          @ from 0: stops at ~2
    ldrne r1, =0x0080FFFF          @ from 0xFFFF: every tick reloads 0xFFFF
    str r1, [r4, #0x100]
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, #0
    add r1, r4, #0x100
    strh r0, [r1, #2]              @ stop (reload kept: 0xFFFF stays 0xFFFF)
    @ the guard: DMA0 on V-blank writes 0 to DMA1CNT_H, once
    adr r1, zero
    str r1, [r4, #0xB0]
    add r1, r4, #0xC6
    str r1, [r4, #0xB4]
    mov r1, #1
    strh r1, [r4, #0xB8]
    ldr r1, =0x9140                @ on, V-blank, 16-bit, src fixed, dst fixed
    strh r1, [r4, #0xBA]
    mov r1, #0x80
    strh r1, [r4, #0x84]           @ SOUNDCNT_X: master on
    ldr r1, =0x0B04
    strh r1, [r4, #0x82]           @ SOUNDCNT_H: FIFO A L+R, TM0, reset
    and r2, r11, #0x300
    movs r2, r2, lsr #8
    beq 2f
    ldr r3, =0x5A5A5A5A
1:  str r3, [r4, #0xA0]            @ w words into FIFO A
    subs r2, r2, #1
    bne 1b
2:
    adr r1, word
    tst r11, #0x800
    ldrne r1, =0x02004000
    str r1, [r4, #0xBC]            @ DMA1SAD
    ldr r1, =0x040000A0
    str r1, [r4, #0xC0]            @ DMA1DAD
    mov r1, #4
    strh r1, [r4, #0xC4]
    ldr r1, =0xB740
    strh r1, [r4, #0xC6]           @ DMA1: on, special, 32-bit, repeat, src+dst fixed
    and r0, r11, #0xFF             @ n
    rsb r0, r0, #64
    ldr r9, =sled
    add r9, r9, r0, lsl #2
    mov r7, r11, lsr #16
    ands r7, r7, #0xFF             @ k (0 = 1)
    moveq r7, #1
    rsb r7, r7, #0x10000
    orr r7, r7, #0x00800000        @ TM0: reload 0x10000 - k, /1, on
    mov r8, #0x00800000            @ TM1: /1, on
    add r1, r4, #0x100
    ldr r2, =0x04000FF0
    adr r10, t_log
    mov lr, pc
    b go
    mov r5, r11, lsr #24
    and r5, r5, #0x0F
    adr r0, logbuf
    ldr r5, [r0, r5, lsl #2]       @ the answer: sample i
    mov r0, #0
    str r0, [r4, #0x100]           @ TM0 off: no more requests
    mov r2, #40                    @ ~160 cycles: any burst still owed ends
1:  subs r2, r2, #1
    bne 1b
    str r0, [r4, #0x104]           @ TM1 off
    strh r0, [r4, #0xC6]           @ DMA1 off
    ldrh r2, [r4, #0xBA]
    tst r2, #0x8000
    orreq r5, r5, #0x80000000      @ the guard ran
    strh r0, [r4, #0xBA]           @ DMA0 off
    ldr r0, saved
    orr r1, r0, #0x88000000        @ FIFO A and B reset, as found otherwise
    mov r1, r1, lsr #16
    strh r1, [r4, #0x82]
    strh r0, [r4, #0x84]
    mov r0, r5
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .align 2
saved:
    .word 0
zero:
    .word 0
word:
    .word 0xFEEDC0DE
    .ltorg
go:
    stmia r1, {r7, r8}             @ TM0, then TM1
    bx r9
    .align 2
sled:
    .rept 64
    mov r0, r0
    .endr
    bx r10
t_log:
    ldrh r0, [r1, #4]
    ldrh r2, [r1, #4]
    ldrh r3, [r1, #4]
    ldrh r5, [r1, #4]
    ldrh r6, [r1, #4]
    ldrh r7, [r1, #4]
    ldrh r8, [r1, #4]
    ldrh r9, [r1, #4]
    ldrh r10, [r1, #4]
    ldrh r12, [r1, #4]
    adr r1, logbuf
    stmia r1, {r0, r2, r3, r5, r6, r7, r8, r9, r10, r12}
    mov pc, lr
    .align 2
logbuf:
    .space 40
    .ltorg
