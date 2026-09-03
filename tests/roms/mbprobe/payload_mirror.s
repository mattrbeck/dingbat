@ payload_mirror.s — ROM mirror / open-bus map (docs/hwprobe-questions.md,
@ multiboot row 3).  Pins cartridge.nim's 1 MiB rule (Classic NES Series:
@ image mirrored 4x in a 4 MiB window, then the (addr/2)&0xFFFF pattern,
@ Assumed) and what the WS1/WS2 regions return for a small cart.
@
@ Read-only.  WAITCNT = 0x4317.  Every read is a 16-bit LDRH.
@
@ RESULT layout:
@   00 boot mode  01 slave id  02 unused  03 unused
@   04 u32 first 32-byte-aligned ROM offset whose 16 halfwords equal the
@      open-bus pattern ((addr/2)&0xFFFF), by binary search over 0..32 MiB
@      assuming ROM-then-open-bus is monotone (0x02000000 = none found:
@      the whole window is ROM or mirrors)
@   0C-0F game code from the cart header (0x080000AC)
@   10+8n 8 bytes at address n of the table below
@   70+8n 8 bytes at address n + 0x20 (a mirror shows ROM content; open bus
@         shows the pattern advanced by 0x10 per halfword)
@   D0 u16 bit i set = 32 bytes at 0x08000000 + (64 KiB << i) are open bus
@   D2 u16 bit i set = those 32 bytes equal the 32 at 0x08000000 (mirror)
@      (i = 0..9: 64K 128K 256K 512K 1M 2M 4M 8M 16M 32M)
@   D4 u16 raw LDRH of 0x0DFFFF00 (an EEPROM cart answers on bit 0)
@ Address table (n = 0..11): 08000000 08100000 08200000 08400000 08800000
@   08FFFFF0 09000000 09FFFFF0 0A000000 0BFFFFF0 0C000000 0DFFFFF0

.set IS_CHILD, 1
.include "mbprobe.inc"

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
    ldr r1, =WAITCNT_ROM
    strh r1, [r0]

    bl  cart_gate
    ldr r5, =RESULT
    ldr r0, =0x080000AC
    ldr r1, [r0]
    str r1, [r5, #0x0C]

    STATUS_MSG str_reading
    ldr r6, =addr_table
    mov r7, #0
1:  ldr r0, [r6, r7, lsl #2]
    add r1, r5, #0x10
    add r1, r1, r7, lsl #3
    bl  copy8
    ldr r0, [r6, r7, lsl #2]
    add r0, r0, #0x20
    add r1, r5, #0x70
    add r1, r1, r7, lsl #3
    bl  copy8
    add r7, r7, #1
    cmp r7, #12
    bne 1b

    @ power-of-two scan
    mov r7, #0
    mov r8, #0                     @ open-bus mask
    mov r9, #0                     @ mirror-of-base mask
2:  mov r0, #0x10000
    mov r0, r0, lsl r7
    add r0, r0, #0x08000000
    bl  is_openbus
    orr r8, r8, r0, lsl r7
    mov r0, #0x10000
    mov r0, r0, lsl r7
    add r0, r0, #0x08000000
    bl  eq_base
    orr r9, r9, r0, lsl r7
    add r7, r7, #1
    cmp r7, #10
    bne 2b
    STORE_BE16 r5, 0xD0, r8
    STORE_BE16 r5, 0xD2, r9
    ldr r0, =0x0DFFFF00
    ldrh r1, [r0]
    STORE_BE16 r5, 0xD4, r1

    @ binary search for the first open-bus offset
    mov r7, #0                     @ lo (ROM)
    mov r8, #0x02000000            @ hi (assumed open bus)
3:  sub r0, r8, r7
    cmp r0, #32
    bls 4f
    add r0, r7, r8
    mov r0, r0, lsr #1
    bic r0, r0, #31
    mov r9, r0
    add r0, r0, #0x08000000
    bl  is_openbus
    cmp r0, #0
    moveq r7, r9
    movne r8, r9
    b   3b
4:  STORE_BE32 r5, 0x04, r8

    STATUS_MSG str_done
    b   viewer

copy8:                             @ r0 src, r1 dst: four LDRH
    mov r3, #4
1:  ldrh r2, [r0], #2
    strb r2, [r1], #1
    mov r2, r2, lsr #8
    strb r2, [r1], #1
    subs r3, r3, #1
    bne 1b
    bx  lr

is_openbus:                        @ r0 address -> 1 if 16 halfwords = pattern
    mov r1, #16
1:  ldrh r2, [r0]
    mov r3, r0, lsr #1
    mov r3, r3, lsl #16
    mov r3, r3, lsr #16
    cmp r2, r3
    movne r0, #0
    bxne lr
    add r0, r0, #2
    subs r1, r1, #1
    bne 1b
    mov r0, #1
    bx  lr

eq_base:                           @ r0 address -> 1 if 32 bytes = 0x08000000's
    mov r1, #0x08000000
    mov r3, #16
1:  ldrh r2, [r0], #2
    ldrh r12, [r1], #2
    cmp r2, r12
    movne r0, #0
    bxne lr
    subs r3, r3, #1
    bne 1b
    mov r0, #1
    bx  lr

    .balign 4
addr_table:
    .word 0x08000000, 0x08100000, 0x08200000, 0x08400000
    .word 0x08800000, 0x08FFFFF0, 0x09000000, 0x09FFFFF0
    .word 0x0A000000, 0x0BFFFFF0, 0x0C000000, 0x0DFFFFF0

DEFSTR str_title,   "ROM MIRRORS"
DEFSTR str_reading, "READING"

    .include "mbcommon.inc"
