@ payload: the arithmetic BIOS calls at their edges, against the real BIOS.
@
@ dingbat ships an HLE BIOS by default, so every one of these calls is our own
@ code standing in for Nintendo's. The console in the rig runs the real thing,
@ which makes this the one comparison that can say whether the replacement is
@ right rather than merely self-consistent: same payload, same inputs, one
@ side executing the BIOS.
@
@ Ordinary inputs are not interesting -- any implementation gets 10 / 3 right.
@ These are the cases where an implementation has to have made a decision:
@ division by zero, the one quotient that overflows, the ends of Sqrt's range,
@ and ArcTan2 on the axes and at the origin, where the quadrant is ambiguous.
@
@ Results, 32-bit words at 0x02008000:
@   +0  GetBiosChecksum        (identifies the BIOS: 0xBAAE187F on AGB)
@   +1  Div 10 / 3             quotient
@   +2  Div 10 / 3             remainder
@   +3  Div -7 / 2             quotient (rounding direction of a negative)
@   +4  Div -7 / 2             remainder (sign of the remainder)
@   +5  Div 1 / 0              quotient
@   +6  Div 1 / 0              remainder
@   +7  Div -1 / 0             quotient (is the sign of the numerator kept?)
@   +8  Div 0x80000000 / -1    quotient (the one case that overflows)
@   +9  Div 0x80000000 / -1    remainder
@   +10 DivArm 10 / 3          quotient (SWI 07, operands the other way round)
@   +11 Sqrt 0
@   +12 Sqrt 1
@   +13 Sqrt 0x3FFFFFFF        (just below a perfect square)
@   +14 Sqrt 0xFFFFFFFF        (the top of the range)
@   +15 ArcTan 0
@   +16 ArcTan 0x4000          (1.0 in Q14)
@   +17 ArcTan 0xFFFFC000      (-1.0)
@   +18 ArcTan2 (0, 0)         the origin: no angle exists
@   +19 ArcTan2 (0x4000, 0)    +x axis
@   +20 ArcTan2 (0, 0x4000)    +y axis
@   +21 ArcTan2 (0xFFFFC000, 0)   -x axis
@   +22 ArcTan2 (0, 0xFFFFC000)   -y axis
@   +23 ArcTan2 (0x4000, 0x4000)  the diagonal
    .arm
    .text
    .global _start

.equ RESULTS, 0x02008000

@ store r0 at word \n of the results block (r8 = results)
.macro put n
    str r0, [r8, #(\n * 4)]
.endm

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r8, =RESULTS

    swi 0x0D0000                   @ GetBiosChecksum
    put 0

    mov r0, #10
    mov r1, #3
    swi 0x060000                   @ Div
    put 1
    mov r0, r1
    put 2

    mvn r0, #6                     @ -7
    mov r1, #2
    swi 0x060000
    put 3
    mov r0, r1
    put 4

    mov r0, #1
    mov r1, #0
    swi 0x060000                   @ division by zero
    put 5
    mov r0, r1
    put 6

    mvn r0, #0                     @ -1
    mov r1, #0
    swi 0x060000
    put 7

    mov r0, #0x80000000
    mvn r1, #0                     @ -1: quotient overflows
    swi 0x060000
    put 8
    mov r0, r1
    put 9

    mov r0, #3                     @ DivArm takes the operands swapped
    mov r1, #10
    swi 0x070000
    put 10

    mov r0, #0
    swi 0x080000                   @ Sqrt
    put 11
    mov r0, #1
    swi 0x080000
    put 12
    ldr r0, =0x3FFFFFFF
    swi 0x080000
    put 13
    mvn r0, #0
    swi 0x080000
    put 14

    mov r0, #0
    swi 0x090000                   @ ArcTan
    put 15
    mov r0, #0x4000
    swi 0x090000
    put 16
    ldr r0, =0xFFFFC000
    swi 0x090000
    put 17

    mov r0, #0                     @ ArcTan2: x in r0, y in r1
    mov r1, #0
    swi 0x0A0000
    put 18
    mov r0, #0x4000
    mov r1, #0
    swi 0x0A0000
    put 19
    mov r0, #0
    mov r1, #0x4000
    swi 0x0A0000
    put 20
    ldr r0, =0xFFFFC000
    mov r1, #0
    swi 0x0A0000
    put 21
    mov r0, #0
    ldr r1, =0xFFFFC000
    swi 0x0A0000
    put 22
    mov r0, #0x4000
    mov r1, #0x4000
    swi 0x0A0000
    put 23

    ldr r0, =0x53574921            @ 'SWI!': the payload ran to the end
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg
