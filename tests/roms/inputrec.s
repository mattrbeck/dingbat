@ Input-timeline recorder (tests/dingbat_test.nim --mode=rollback).
@
@ A tiny, input-SENSITIVE ROM used to validate GGPO-style input rollback over
@ the local 2-core link. It samples KEYINPUT in a tight loop and folds each
@ sample together with a monotonic counter, so the final accumulator depends on
@ WHICH iterations each button was held — i.e. the exact input TIMELINE, not
@ just the set of buttons. That is precisely the property a rollback must
@ preserve: predicting the peer's input wrong and later rolling back + replaying
@ the corrected input must reproduce the same accumulator as knowing it upfront.
@
@ EWRAM: 0x02000000 = accumulator (fold of key*counter), 0x02000004 = counter.
@ No SIO — the two cores run independently, each driven by its own player's
@ inputs; this isolates input-rollback determinism from the SIO link (which
@ linktest covers).
@
@ Build: arm-none-eabi-as -mcpu=arm7tdmi -o inputrec.o inputrec.s
@        arm-none-eabi-objcopy -O binary inputrec.o inputrec.gba

    .arm
    .text
    .global _start
_start:
    b   init
init:
    ldr r4, =0x04000130       @ KEYINPUT (active-low: 0 = pressed)
    ldr r10, =0x02000000      @ EWRAM accumulator
    mov r5, #0                @ accumulator
    mov r6, #0                @ monotonic counter (iteration index = time)
loop:
    ldrh r0, [r4]             @ sample held buttons
    add r6, r6, #1
    mul r1, r0, r6            @ weight the sample by time (Rd != Rm on ARM7TDMI)
    add r5, r5, r1            @ fold into the accumulator
    eor r5, r5, r6            @ mix so order matters
    str r5, [r10]            @ publish accumulator
    str r6, [r10, #4]        @ publish counter
    b   loop

    .pool
