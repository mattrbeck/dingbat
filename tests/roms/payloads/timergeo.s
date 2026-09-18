@ payload: is the timer prescaler a global free-running divider, or does it
@ restart when the timer is enabled?
@
@ A classic place for emulators to differ, and one that has never been
@ decidable here: the answer shows up as a phase, and until a V-count match
@ halt fixed the entry (docs/playtest-bugs.md section 18) the payload's own
@ phase relative to the machine was whatever the monitor happened to hand us.
@ With entry controlled the question becomes a single reproducible number.
@
@ Enter at the top of line 100. Start TM0 at prescaler 1 as the clock, start
@ TM1 at the prescaler under test with reload 0, spin a FIXED 1200 cycles --
@ no poll, nothing quantised -- then read both.
@
@ If the prescaler restarts on enable, TM1 = floor(elapsed / P) and the answer
@ is the same wherever in the line we started. If it is a global divider that
@ free-runs, TM1's first tick lands early or late by the phase the divider
@ happened to be in, so TM1 = floor((elapsed + phase) / P) -- still fixed,
@ because entry is fixed, but a different number, and one that changes with
@ the line we enter on.
@
@ r0 in  bits 0-1   the TM1 prescaler select: 0 = 1, 1 = 64, 2 = 256, 3 = 1024
@        bits 8-15  override the V-count match line (0 => 100), so the page can
@                   ask whether the answer moves with where we entered
@        bits 16-23 extra cycles before the timers are read, 0..63. Sweeping
@                   this walks the read point one cycle at a time and the tick
@                   threshold falls somewhere in it; the k at which TM1 steps
@                   IS the divider's phase, to the cycle. Comparing that k
@                   between hardware and here measures the phase error exactly,
@                   which counting ticks at one k can only bound.
@ r0 out = (TM1 << 16) | TM0, both read after the fixed spin.
    .arm
    .text
    .global _start

.equ IOBASE,   0x04000000
.equ TM0BASE,  0x04000100
.equ TM1BASE,  0x04000104
.equ TGSTUB,   0x03002000          @ IWRAM copy of tg_stub, clear of us
.equ SPIN,     300                 @ 300 x 4 cycles = 1200

_start:
    stmfd sp!, {r4-r11, lr}
    mov r7, r0

    ldr r0, =tg_stub               @ the stub runs from IWRAM
    ldr r1, =TGSTUB
    mov r2, #((tg_stub_end - tg_stub) / 4)
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b

    mov r4, #IOBASE
    ldr r10, =TM0BASE
    ldr r11, =TM1BASE
    ldr r0, =0x04000200
    ldrh r6, [r0, #8]              @ everything we disturb, saved
    push {r6}
    ldrh r6, [r0]
    push {r6}
    mov r1, #0
    strh r1, [r0, #8]              @ IME off before touching IE
    ldrh r6, [r4, #4]
    push {r6}
    ldrh r6, [r10, #2]
    push {r6}
    ldrh r6, [r11, #2]
    push {r6}

    ldr r5, =0x00800000            @ TM0: reload 0, enable, prescaler 1
    and r0, r7, #3                 @ TM1: the prescaler under test
    ldr r8, =0x00800000
    orr r8, r8, r0, lsl #16
    mov r6, r7, lsr #8             @ the line to enter on
    and r6, r6, #0xFF
    cmp r6, #0
    moveq r6, #100
    mov r9, r7, lsr #16            @ the read sled
    and r9, r9, #0x3F
    ldr r12, =TGSTUB
    mov lr, pc
    bx  r12

    pop {r6}                       @ everything back as we found it
    strh r6, [r11, #2]
    pop {r6}
    strh r6, [r10, #2]
    pop {r6}
    strh r6, [r4, #4]
    ldr r0, =0x04000200
    mvn r1, #0
    strh r1, [r0, #2]
    pop {r6}
    strh r6, [r0]
    pop {r6}
    strh r6, [r0, #8]
    mov r0, r7
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

@ r4 = IOBASE, r10 = TM0BASE, r11 = TM1BASE, r5 = TM0 control word,
@ r8 = TM1 control word, r6 = the line to enter on, r9 = the read sled.
@ -> r7 = (TM1 << 16) | TM0.
@ No literal pools: the routine is copied to IWRAM.
tg_stub:
    add r2, r4, #0x200             @ IE at [r2], IF at [r2,#2], IME at [r2,#8]
    mov r12, #0
    str r12, [r10]                 @ both timers off, reload 0
    str r12, [r11]
    strh r12, [r2, #8]             @ IME off: no handler, but HALT still exits
                                   @ on IE & IF
    mov r0, r6, lsl #8             @ V-count match on the chosen line ...
    orr r0, r0, #0x20              @ ... and enable its interrupt
    strh r0, [r4, #4]
    mov r0, #0x04                  @ IE = V-count match only
    strh r0, [r2]
    mvn r0, #0
    strh r0, [r2, #2]              @ IF: clear all
    swi 0x020000                   @ HALT: we resume at the top of that line
    add r2, r4, #0x200             @ the SWI clobbers r0-r3

    mov r0, #0
    strh r0, [r4, #4]              @ DISPSTAT interrupts off again
    strh r0, [r2]                  @ IE off, so nothing else wakes us
    str r5, [r10]                  @ TM0: the clock
    str r8, [r11]                  @ TM1: the prescaler under test

    mov r1, #SPIN                  @ a fixed count: no poll, no quantiser
1:  subs r1, r1, #1
    bne 1b
    rsb r9, r9, #63                @ walk the read point one cycle at a time:
    add pc, pc, r9, lsl #2         @ skip 63-k entries, so k+1 NOPs run
    mov r0, r0                     @ (pc reads +8: this word is jumped over)
    .rept 64
    mov r0, r0
    .endr
    ldrh r7, [r11]                 @ TM1 first ...
    ldrh r0, [r10]                 @ ... then TM0, a fixed skew later

    mov r12, #0
    str r12, [r10]
    str r12, [r11]
    orr r7, r0, r7, lsl #16        @ (TM1 << 16) | TM0
    bx  lr
tg_stub_end:
