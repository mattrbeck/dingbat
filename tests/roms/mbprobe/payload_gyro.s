@ payload_gyro.s — gyro ADC clock-edge probe (docs/hwprobe-questions.md,
@ multiboot row 2, gyro half).  Pins gpio.nim gyro_update's edge: dingbat
@ shifts the next data bit out on the FALLING clock edge (Assumed).
@
@ Cart: WarioWare: Twisted! (RZWE/RZWP/RZWJ).  Follows GBATEK "GBA Cart
@ Gyro Sensor" read_gyro exactly (GPIO enable, direction 0x0B, start pulse
@ on bit 0, 16 clocks on bit 1, data on bit 2) but samples the port three
@ times per clock: with the clock still high (GBATEK's own sample point),
@ after the falling edge, and after the rising edge.  Bit 3 (rumble) is
@ preserved from whatever the port read.  WAITCNT = Wario's own 0x45B7.
@
@ RESULT layout (raw = the low nibble of a 0x080000C4 read):
@   00 boot mode  01 slave id  02 unused
@   03 raw 0xC4 after enabling the port   04 raw 0xC6   05 raw 0xC8
@   08+3k conversion A, clock k (0-15): +0 before falling edge (clock high)
@                                       +1 after falling edge
@                                       +2 after rising edge
@   38+3k conversion B, same
@   68 u16 A assembled from the "before" bits, MSB first (= GBATEK's value
@      with the 4 dummy bits still in the top nibble)
@   6A u16 A from "after falling"   6C u16 A from "after rising"
@   6E/70/72 the same three for B
@   74+3k conversion C with ~100 us between edges   A4/A6/A8 its three values
@ Falling-edge shifting (dingbat) predicts after-falling == after-rising ==
@ next clock's before; rising-edge shifting predicts before == after-falling.

.set IS_CHILD, 1
.include "mbprobe.inc"

.equ CART, 0x08000000

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
    ldr r1, =WAITCNT_GYRO
    strh r1, [r0]

    bl  cart_gate
    ldr r5, =RESULT
    mov r4, #CART
    mov r0, #1
    strh r0, [r4, #0xC8]           @ GPIO readable
    mov r0, #0x0B
    strh r0, [r4, #0xC6]           @ bits 0,1,3 out; bit 2 in
    ldrh r0, [r4, #0xC4]
    strb r0, [r5, #3]
    ldrh r0, [r4, #0xC6]
    strb r0, [r5, #4]
    ldrh r0, [r4, #0xC8]
    strb r0, [r5, #5]

    STATUS_MSG str_clocking
    add r0, r5, #0x08
    mov r1, #0
    bl  gyro_conv
    add r0, r5, #0x38
    mov r1, #0
    bl  gyro_conv
    add r0, r5, #0x74
    mov r1, #26                    @ ~100 us
    bl  gyro_conv
    add r0, r5, #0x08
    add r1, r5, #0x68
    bl  gyro_pack
    add r0, r5, #0x38
    add r1, r5, #0x6E
    bl  gyro_pack
    add r0, r5, #0x74
    add r1, r5, #0xA4
    bl  gyro_pack

    STATUS_MSG str_done
    b   viewer

@ One 16-clock conversion; r0 dest (48 bytes), r1 delay ticks between
@ edges (0 = a few EWRAM-fetched nops, as Wario's own loop).
gyro_conv:
    push {r4-r9, lr}
    mov r6, r0
    mov r7, r1
    mov r4, #CART
    ldrh r8, [r4, #0xC4]
    and r8, r8, #0xF
    orr r8, r8, #3
    strh r8, [r4, #0xC4]           @ start = 1, clock = 1
    bic r8, r8, #1
    strh r8, [r4, #0xC4]           @ start = 0, clock stays 1
    mov r9, #16
1:  ldrh r0, [r4, #0xC4]
    and r0, r0, #0xF
    strb r0, [r6], #1              @ before the falling edge
    bic r2, r8, #2
    strh r2, [r4, #0xC4]           @ clock low
    bl  gdelay
    ldrh r0, [r4, #0xC4]
    and r0, r0, #0xF
    strb r0, [r6], #1              @ after the falling edge
    strh r8, [r4, #0xC4]           @ clock high
    bl  gdelay
    ldrh r0, [r4, #0xC4]
    and r0, r0, #0xF
    strb r0, [r6], #1              @ after the rising edge
    subs r9, r9, #1
    bne 1b
    pop {r4-r9, pc}

gdelay:
    cmp r7, #0
    bne 1f
    nop
    nop
    nop
    nop
    bx  lr
1:  push {lr}
    mov r0, r7
    bl  delay
    pop {pc}

@ Assemble the three bit series of a 48-byte block into 16-bit values
@ (bit 2 of each raw nibble, first clock = MSB); r0 src, r1 dest (6 bytes).
gyro_pack:
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, #0                     @ which of the three reads
1:  mov r2, #0
    mov r3, #16
    add r7, r4, r6
2:  ldrb r0, [r7], #3
    mov r0, r0, lsr #2
    and r0, r0, #1
    orr r2, r0, r2, lsl #1
    subs r3, r3, #1
    bne 2b
    STORE_BE16 r5, 0, r2
    add r5, r5, #2
    add r6, r6, #1
    cmp r6, #3
    bne 1b
    pop {r4-r7, pc}

DEFSTR str_title,    "GYRO EDGES"
DEFSTR str_clocking, "CLOCKING"

    .include "mbcommon.inc"
