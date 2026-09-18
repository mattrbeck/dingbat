@ payloadrun.s — cartridge ROM that runs a monitor payload the way the
@ monitor does, so an experiment can be dry-run in an emulator before it is
@ sent to hardware. Copies the payload to IWRAM 0x03000000, calls it once per
@ argument in arg_table, and stores each returned r0 at 0x02000000 onward.
    .arm
    .text
    .global _start

_start:
    b   main
    .space 0x9C
    .space 0x20
main:
    ldr sp, =0x03007F00
    @ copy the payload into IWRAM
    adr r0, payload
    ldr r1, =0x03000000
    ldr r2, =payload_end
    adr r3, payload
    sub r2, r2, r3                 @ byte length
1:  ldr r4, [r0], #4
    str r4, [r1], #4
    subs r2, r2, #4
    bgt 1b

    ldr r7, =0x02000000            @ where results go
    adr r8, arg_table
    ldr r9, =arg_count
    ldr r9, [r9]
2:  ldr r0, [r8], #4
    ldr r10, =0x03000000
    mov lr, pc
    bx  r10
    str r0, [r7], #4
    subs r9, r9, #1
    bgt 2b

    ldr r0, =0x02000FFC            @ a marker saying the run finished
    ldr r1, =0x600D0000
    str r1, [r0]
3:  b   3b
    @ Before the payload, not after it: the default pool goes to the end of
    @ the section, and a payload of more than 4K puts it out of reach of the
    @ loads above.
    .ltorg

    .align 2
arg_count:
    .word 6
arg_table:
    .word 0x0000                   @ WS0 4/2, prefetch off
    .word 0x0004                   @ WS0 3/2, prefetch off
    .word 0x0008                   @ WS0 2/2, prefetch off
    .word 0x0014                   @ WS0 3/1, prefetch off
    .word 0x4014                   @ WS0 3/1, prefetch on
    .word 0x4000                   @ WS0 4/2, prefetch on

    .align 2
payload:
    .incbin "p_waitcnt.bin"
    .align 2
payload_end:
