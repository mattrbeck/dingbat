@ payload_tilt.s — tilt sensor ready-bit probe (docs/hwprobe-questions.md,
@ multiboot row 2, tilt half).  Pins bus.nim tilt_read's always-ready
@ status bit: dingbat returns bit 7 of 0x0E008300 set on the first read
@ after the 0x55/0xAA start, so every count below is 0 in dingbat.
@
@ Carts: Yoshi's Universal Gravitation / Topsy-Turvy (KYGE/KYGP/KYGJ),
@ Koro Koro Puzzle (KHPJ).  Read-only on the cart; nothing is written but
@ the two start-conversion registers.  WAITCNT = 0x4B17 (SRAM 8 clocks,
@ PHI 4 MHz — both required by GBATEK "GBA Cart Tilt Sensor").
@
@ RESULT layout:
@   00 boot mode  01 slave id  02 unused
@   03 raw 0x0E008300 before any conversion (idle status)
@   04-07 raw 0x8200 / 0x8300 / 0x8400 / 0x8500 before any conversion
@   08+6n sample n (0-15), one per frame:
@         +0 u16 number of reads of 0x8300 that had bit 7 = 0 before the
@            first read with bit 7 = 1 (0xFFFF = never, gave up)
@         +2 raw 0x8300 (X high nibble | status)   +3 raw 0x8200 (X low)
@         +4 raw 0x8500 (Y high nibble)            +5 raw 0x8400 (Y low)
@   68 u16 min count   6A u16 max count   6C number of samples that gave up

.set IS_CHILD, 1
.include "mbprobe.inc"

.equ TILT_START0, 0x0E008000
.equ TILT_START1, 0x0E008100
.equ TILT_XL,     0x0E008200
.equ TILT_XH,     0x0E008300
.equ TILT_YL,     0x0E008400
.equ TILT_YH,     0x0E008500

    IMAGE_HEADER start

start:
    mov r0, #IOBASE
    add r0, r0, #0x208
    mov r1, #0
    strh r1, [r0]
    ldr sp, =0x03007F00
    bl  sio_child_init
    bl  result_init
    bl  vid_init
    bl  timer3_init
    DRAW 1, 0, str_title
    ldr r0, =0x04000204
    ldr r1, =WAITCNT_TILT
    strh r1, [r0]

    bl  cart_gate
    ldr r5, =RESULT

    @ idle readings
    ldr r0, =TILT_XH
    ldrb r1, [r0]
    strb r1, [r5, #3]
    ldr r0, =TILT_XL
    ldrb r1, [r0]
    strb r1, [r5, #4]
    ldr r0, =TILT_XH
    ldrb r1, [r0]
    strb r1, [r5, #5]
    ldr r0, =TILT_YL
    ldrb r1, [r0]
    strb r1, [r5, #6]
    ldr r0, =TILT_YH
    ldrb r1, [r0]
    strb r1, [r5, #7]

    STATUS_MSG str_sampling
    mov r6, #0                     @ sample index
    add r7, r5, #8                 @ record pointer
    mvn r8, #0                     @ min
    mov r9, #0                     @ max
    mov r10, #0                    @ timeouts
1:  bl  wait_vblank
    ldr r0, =TILT_START0
    mov r1, #0x55
    strb r1, [r0]
    ldr r0, =TILT_START1
    mov r1, #0xAA
    strb r1, [r0]
    ldr r0, =TILT_XH
    mov r1, #0                     @ busy count
    ldr r2, =0xFFFF
2:  ldrb r3, [r0]
    tst r3, #0x80
    bne 3f
    add r1, r1, #1
    cmp r1, r2
    blo 2b
    add r10, r10, #1               @ gave up
3:  STORE_BE16 r7, 0, r1
    ldr r0, =TILT_XH
    ldrb r2, [r0]
    strb r2, [r7, #2]
    ldr r0, =TILT_XL
    ldrb r2, [r0]
    strb r2, [r7, #3]
    ldr r0, =TILT_YH
    ldrb r2, [r0]
    strb r2, [r7, #4]
    ldr r0, =TILT_YL
    ldrb r2, [r0]
    strb r2, [r7, #5]
    cmp r1, r8
    movlo r8, r1
    cmp r1, r9
    movhi r9, r1
    add r7, r7, #6
    add r6, r6, #1
    cmp r6, #16
    bne 1b
    STORE_BE16 r5, 0x68, r8
    STORE_BE16 r5, 0x6A, r9
    strb r10, [r5, #0x6C]

    STATUS_MSG str_done
    b   viewer

DEFSTR str_title,    "TILT STATUS"
DEFSTR str_sampling, "SAMPLING"

    .include "mbcommon.inc"
