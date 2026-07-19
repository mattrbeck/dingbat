@ GBA GPIO rumble test ROM: drives the cart rumble motor line (GPIO bit 3,
@ the Drill Dozer / WarioWare: Twisted! wiring) in a ~0.5 s on / ~0.5 s off
@ cycle forever. Used to eyeball/E2E-test the frontends' rumble plumbing
@ (controller vibration + screen shake) without a licensed rumble cart.
@
@ Build:
@   arm-none-eabi-as -mcpu=arm7tdmi -o rumbletest.o rumbletest.s
@   arm-none-eabi-objcopy -O binary rumbletest.o rumbletest.gba

    .arm
    .text
    .global _start
_start:
    b   init

init:
    ldr r0, =0x080000C6        @ GPIO port direction
    mov r1, #0x8               @ bit 3 = output (motor); RTC bits left inputs
    strh r1, [r0]
    ldr r2, =0x080000C4        @ GPIO port data

loop:
    mov r1, #0x8
    strh r1, [r2]              @ motor on
    bl  wait
    mov r1, #0x0
    strh r1, [r2]              @ motor off
    bl  wait
    b   loop

wait:
    ldr r3, =400000            @ ~0.5 s busy loop (ROM waitstates make
                               @ each subs/bne iteration ~20 cycles)
w1: subs r3, r3, #1
    bne w1
    bx  lr

    .ltorg
