@ pfram.s — prefetchbench's subjects, timed from RAM, over the link.
@
@ prefetchbench.gba times the same eight instruction patterns fetched from a
@ cartridge, which is the one place a multiboot payload cannot reach. This is
@ its floor: the identical sequences, timed out of IWRAM, where the
@ prefetcher never engages because no opcode comes from the gamepak. The
@ prefetch effect the cartridge run is after is (cartridge - this), per
@ subject, and having this half measured on the same silicon means the
@ cartridge run does not have to borrow an emulator's idea of the floor.
@
@ Two things here are live measurements rather than controls:
@
@   * Subjects C and G load from 0x08000000 while the code itself runs from
@     IWRAM. GBATEK says the prefetch buffer serves opcode fetches only, so
@     the pf-ON and pf-off columns of those two rows should be equal. If they
@     are not, the prefetcher touches data loads too, and every emulator here
@     models that wrong.
@   * The gamepak slot is empty, and waitprobe.s established that it still
@     honours WAITCNT, so the 3/1 and 4/2 columns of C and G should differ by
@     the wait-state arithmetic and nothing else.
@
@ It also exercises linkreport.inc on real hardware for the first time. The
@ cartridge run reports its results down the cable rather than to a camera,
@ and that path has only ever run in an emulator; here the same code streams
@ the same way under the resident monitor, so a failure shows up now rather
@ than during the one run that needs the cartridge in the slot.
@
@ r0 out: 'PFRA' once the block is filled and streamed.
@
@ Results at 0x02008000, 33 words: eight subjects of four wait settings each
@ in the order below, then the marker.
    .arm
    .text
    .global _start

.equ WAITCNT,  0x04000204
.equ TM0BASE,  0x04000100
.equ RESULTS,  0x02008000
.equ WORDS,    33
.equ GAMEPAK,  0x08000000

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r1, =WAITCNT
    ldrh r0, [r1]
    stmfd sp!, {r0}                @ WAITCNT as we found it
    ldr r0, =TM0BASE
    ldrh r1, [r0, #2]
    stmfd sp!, {r1}                @ and TM0's control

    ldr r10, =RESULTS
    ldr r11, =subjects
subject_loop:
    ldr r8, [r11]
    cmp r8, #0
    beq done
    ldr r7, =waits
    mov r6, #4                     @ four wait settings each
wait_loop:
    ldr r0, [r7], #4
    ldr r1, =WAITCNT
    strh r0, [r1]

    @ r9 holds TM0 across the call: the Thumb subjects can only reach r0-r7,
    @ and the ARM ones touch nothing above r3, so the read after the call is
    @ the instruction after the return and adds nothing to the count.
    ldr r9, =TM0BASE
    mov r0, #0
    str r0, [r9]                   @ stop, and count from zero
    mov r0, #0x80
    strh r0, [r9, #2]              @ start, prescaler 1: one tick per cycle
    mov lr, pc
    bx  r8
    ldrh r0, [r9]                  @ elapsed ticks
    mov r1, #0
    strh r1, [r9, #2]              @ stop
    str r0, [r10], #4

    subs r6, r6, #1
    bgt wait_loop
    add r11, r11, #4
    b   subject_loop
done:
    ldr r1, =RESULTS
    ldr r0, =0x50465241            @ 'PFRA'
    str r0, [r1, #(32 * 4)]

    ldmfd sp!, {r1}                @ TM0 control and WAITCNT back as found
    ldr r0, =TM0BASE
    strh r1, [r0, #2]
    ldmfd sp!, {r1}
    ldr r0, =WAITCNT
    strh r1, [r0]

    @ Stream the block until the host has had it a few times over. The count
    @ is of words the host actually clocked out, so with no host this falls
    @ through on the spin bound instead of hanging the monitor.
    ldr r0, =RESULTS
    mov r1, #WORDS
    bl  link_report_init
    mov r5, #0                     @ words the host has taken
    ldr r6, =0x00300000            @ spin bound, about three seconds
1:  ldr r4, =lr_state
    ldr r7, [r4, #8]
    bl  link_report_poll
    ldr r4, =lr_state
    ldr r0, [r4, #8]
    cmp r0, r7                     @ position moved = that word went out
    addne r5, r5, #1
    cmp r5, #(4 * (WORDS + 2))     @ four passes of magic, count and block
    bcs 2f
    subs r6, r6, #1
    bne 1b
2:  ldr r0, =0x50465241
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg

    .include "linkreport.inc"

    .align 2
waits:
    .word 0x4014                   @ WS0 3/1, prefetch on
    .word 0x0014                   @ WS0 3/1, prefetch off
    .word 0x4000                   @ WS0 4/2, prefetch on
    .word 0x0000                   @ WS0 4/2, prefetch off
subjects:
    .word subject_a
    .word subject_b
    .word subject_c
    .word subject_d
    .word subject_e + 1            @ +1: entered as Thumb
    .word subject_f + 1
    .word subject_g + 1
    .word subject_h + 1
    .word 0

@ The four ARM patterns, instruction for instruction as prefetchbench.s has
@ them. The one deliberate change is in C and G, where the load's address is
@ the gamepak rather than the routine's own: from RAM, `adr` would aim the
@ load at IWRAM and the subject would stop being about the cartridge bus.
    .align 2
subject_a:                         @ 256 sequential instructions
    .rept 256
    mov r0, r0
    .endr
    bx  lr

    .align 2
subject_b:                         @ 128 iterations of a two-instruction loop
    mov r2, #128
1:  subs r2, r2, #1
    bne 1b
    bx  lr

    .align 2
subject_c:                         @ 32 x (8 instructions + a load from ROM)
    ldr r3, =GAMEPAK
    .rept 32
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldr r1, [r3]
    .endr
    bx  lr
    .ltorg

    .align 2
subject_d:                         @ 64 multiplies: internal cycles throughout
    mov r1, #7
    mov r2, #13
    .rept 64
    mul r0, r1, r2
    .endr
    bx  lr

    .align 2
    .thumb
subject_e:                         @ 256 sequential Thumb instructions
    .rept 256
    mov r0, r0
    .endr
    bx  lr

    .align 2
subject_f:                         @ 128 iterations of a two-instruction loop
    mov r2, #128
1:  sub r2, #1
    bne 1b
    bx  lr

    .align 2
subject_g:                         @ 32 x (8 instructions + a load from ROM)
    ldr r3, =GAMEPAK
    .rept 32
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    mov r0, r0
    ldr r1, [r3, #0]
    .endr
    bx  lr
    .ltorg

    .align 2
subject_h:                         @ 64 multiplies: internal cycles throughout
    mov r1, #7
    mov r2, #13
    .rept 64
    mul r1, r2
    .endr
    bx  lr
