@ gbamon.s — a monitor that stays resident on a real GBA so the host can run
@ experiments on it without touching the console (built by gbamon.py, driven
@ by tools/hwlink/monitor.py).
@
@ Uploaded once over the link cable, it then loops on the serial port taking
@ commands, each a 32-bit word followed by its operands.  The host can put
@ code and data anywhere in memory, call it, and read the results back, so a
@ new experiment costs a transfer rather than a power cycle.
@
@   'PING' -> answers 'PONG'
@   'WR>>' addr count word*count   -> answers 'DONE'
@   'RD>>' addr count              -> answers count words, then 'DONE'
@   'CALL' addr arg                -> runs it (ARM, r0 = arg), answers 'DONE';
@                                     'GETR' then fetches the returned r0
@   'BOOT' -> SWI 26h HardReset: reboots through the BIOS, which with no
@             cartridge returns to the multiboot wait loop, so the host can
@             upload a new image without anyone touching the console
@   'ABRT' abandons a transfer in progress and returns to the command loop
@   anything else is echoed back, which is the host's liveness check
@
@ Every transfer is a full 32-bit exchange: the monitor stages its answer
@ before arming, so the word the host clocks out is the answer to the
@ transfer it is making, with no pipeline offset to unpick.
@
@ Staying recoverable is the whole point, because the one failure nothing can
@ talk its way out of is a monitor that stops listening.  The adapter does
@ drop the occasional transfer, which slides every following word one place
@ along and turns a data word into a count; a first version took a count of
@ half a billion that way and had to be power-cycled out.  So counts are
@ capped at MAX_WORDS, both streaming loops watch for 'ABRT', and a write
@ outside the areas an experiment owns is consumed but discarded rather than
@ landing on the monitor itself.  The stack, RCNT and the serial mode are
@ re-established every iteration, so a payload that trashes the stack or
@ leaves the link port in general-purpose mode does not take the session down
@ either.  A payload that hangs or masks interrupts still does.

    .arm
    .text
    .global _start

.equ DISPCNT,   0x04000000
.equ VRAM,      0x06000000
.equ SIODATA32, 0x04000120
.equ SIOCNT,    0x04000128
.equ RCNT,      0x04000134
.equ STACK,     0x03007F00

.equ CMD_PING,  0x50494E47         @ 'PING'
.equ CMD_WRITE, 0x57523E3E         @ 'WR>>'
.equ CMD_READ,  0x52443E3E         @ 'RD>>'
.equ CMD_CALL,  0x43414C4C         @ 'CALL'
.equ CMD_GETR,  0x47455452         @ 'GETR'
.equ CMD_BOOT,  0x424F4F54         @ 'BOOT'
.equ CMD_ABRT,  0x41425254         @ 'ABRT'
.equ ANS_PONG,  0x504F4E47         @ 'PONG'
.equ ANS_DONE,  0x444F4E45         @ 'DONE'

@ A bad count costs one transfer each to walk off, so the cap is what bounds
@ how long a desync lasts: 1024 words is a fifth of a second.
.equ MAX_WORDS, 1024
@ Where an experiment may write: IWRAM below the stacks, and EWRAM above the
@ monitor's own image and state.
.equ IWRAM_LO,  0x03000000
.equ IWRAM_HI,  0x03007E00
.equ EWRAM_LO,  0x02004000
.equ EWRAM_HI,  0x02040000

_start:
    b   main                       @ 0x00: the BIOS enters here
    .space 0x9C                    @ 0x04-0x9F: logo (patched by the builder)
    .space 0x20                    @ 0xA0-0xBF: title/codes (patched)

main:
    ldr r0, =DISPCNT               @ a green screen says the monitor is alive
    ldr r1, =0x0403                @ mode 3, BG2 on
    strh r1, [r0]
    ldr r0, =VRAM
    ldr r1, =0x03E0                @ BGR555 green
    orr r1, r1, r1, lsl #16
    ldr r2, =(240 * 160 / 2)
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b

    ldr r0, =state
    ldr r1, =ANS_PONG              @ first answer out of the gate
    str r1, [r0, #0]               @ state+0: staged answer
    mov r1, #0
    str r1, [r0, #4]               @ state+4: last CALL return value

loop:
    ldr sp, =STACK                 @ re-established every time: a payload may
    ldr r0, =RCNT                  @ have left either of these in any state
    mov r1, #0                     @ serial mode, chosen by SIOCNT
    strh r1, [r0]

    ldr r6, =state
    ldr r0, [r6, #0]
    bl  sio_xfer
    mov r5, r0                     @ the command word

    ldr r1, =CMD_PING
    cmp r5, r1
    ldreq r1, =ANS_PONG
    streq r1, [r6, #0]
    beq loop

    ldr r1, =CMD_WRITE
    cmp r5, r1
    beq do_write
    ldr r1, =CMD_READ
    cmp r5, r1
    beq do_read
    ldr r1, =CMD_CALL
    cmp r5, r1
    beq do_call
    ldr r1, =CMD_GETR
    cmp r5, r1
    beq do_getr
    ldr r1, =CMD_BOOT
    cmp r5, r1
    beq do_boot

    str r5, [r6, #0]               @ unknown word: echo it back
    b   loop

do_write:
    mov r0, #0
    bl  sio_xfer
    mov r7, r0                     @ destination
    mov r0, #0
    bl  sio_xfer
    bl  clamp_count
    mov r8, r0                     @ word count

    mov r9, #4                     @ the step: zero means discard
    ldr r1, =IWRAM_LO
    ldr r2, =IWRAM_HI
    cmp r7, r1
    bcc 1f
    cmp r7, r2
    bcc 2f
1:  ldr r1, =EWRAM_LO
    ldr r2, =EWRAM_HI
    cmp r7, r1
    bcc 3f
    cmp r7, r2
    bcc 2f
3:  ldr r7, =sink                  @ out of bounds: consume, do not store
    mov r9, #0
2:
1:  cmp r8, #0
    beq 2f
    mov r0, r8                     @ the answer meanwhile is the words left
    bl  sio_xfer
    ldr r1, =CMD_ABRT
    cmp r0, r1
    beq 2f
    str r0, [r7]
    add r7, r7, r9
    sub r8, r8, #1
    b   1b
2:  ldr r6, =state
    ldr r1, =ANS_DONE
    str r1, [r6, #0]
    b   loop

do_read:
    mov r0, #0
    bl  sio_xfer
    mov r7, r0                     @ source
    mov r0, #0
    bl  sio_xfer
    bl  clamp_count
    mov r8, r0                     @ word count
1:  cmp r8, #0
    beq 2f
    ldr r0, [r7], #4
    bl  sio_xfer
    ldr r1, =CMD_ABRT
    cmp r0, r1
    beq 2f
    sub r8, r8, #1
    b   1b
2:  ldr r6, =state
    ldr r1, =ANS_DONE
    str r1, [r6, #0]
    b   loop

do_call:
    mov r0, #0
    bl  sio_xfer
    mov r7, r0                     @ entry point
    mov r0, #0
    bl  sio_xfer                   @ r0 = the argument, as the payload wants
    mov lr, pc                     @ ARM7TDMI has no BLX register
    bx  r7
    ldr r6, =state                 @ reload: the payload may have used r6
    str r0, [r6, #4]
    ldr r1, =ANS_DONE
    str r1, [r6, #0]
    b   loop

do_boot:
    swi 0x260000                   @ undocumented, and the only way back to an
    b   loop                       @ uploadable state without a power cycle

do_getr:
    ldr r1, [r6, #4]
    str r1, [r6, #0]
    b   loop

@ A count the host never meant is the classic way to lose a session: cap it.
clamp_count:
    ldr r1, =MAX_WORDS
    cmp r0, r1
    movhi r0, r1
    bx  lr

@ One 32-bit exchange as the link's slave: r0 in, the word the host sent out.
sio_xfer:
    ldr r1, =SIODATA32
    str r0, [r1]
    mov r2, #0x1000                @ 32-bit transfer, external clock
    orr r2, r2, #0x80              @ ready for the host's clock
    strh r2, [r1, #8]
1:  ldrh r2, [r1, #8]
    tst r2, #0x80
    bne 1b
    ldr r0, [r1]
    bx  lr

    .align 2
state:
    .word 0                        @ staged answer
    .word 0                        @ last CALL return value
sink:
    .word 0                        @ where a write nobody asked for lands
