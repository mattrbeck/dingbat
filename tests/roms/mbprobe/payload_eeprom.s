@ payload_eeprom.s — EEPROM write-settle probe (docs/hwprobe-questions.md,
@ multiboot row 1).  Pins EEPROM_SETTLE_CYCLES (storage/eeprom.nim, 108368
@ from GBATEK) and where the settle window starts (dingbat: after the LAST
@ data bit, Assumed).
@
@ Runs from EWRAM on the slave (multiboot) or from ROM (cart-boot twin for
@ dingbat; build.py passes CARTBOOT=1).  The block it touches is the LAST
@ block of the chip and every timed write is a write-back of what was read,
@ except the one deliberately changed write, which is undone by the next.
@ The save is left as found unless power is lost mid-write.
@
@ Gate keys: A = 64 Kbit chip (14 address bits), B = 4 Kbit (6 bits).
@ Block address = all address bits set (0x3FFF / 0x3F): on a 64 Kbit chip
@ only the low 10 bits count (GBATEK), and a 4 Kbit chip fed the 14-bit
@ command takes its first 6 bits, so a wrong pick still lands on the last
@ block.
@
@ RESULT layout (big-endian fields; shown as 8-byte rows, label = row):
@   00 boot mode (0xC4)  01 slave id (0xC5)  02 unused  03 address bits
@   04-0B  block data read with the chosen protocol (original)
@   10+8n  trial n (0-7), write-back unchanged:
@          +0 u16 TM0/1 count when the command DMA had finished
@          +2 u32 count when the ready poll first read bit 0 = 1
@          (0xFFFFFFFF = no ready within ~0.5 s of polling)  +6 pad
@   50     same for a CHANGED write (data XOR 0xFF)
@   58     same for the write that restores the original
@   60-67  block data read back after all writes   68 = 1 if it == original
@   70 u32 min of the 8 trials' ready counts   74 u32 max
@   78-7F  block data read with the OTHER address width (diagnostic: on the
@          right chip the 04-0B read is the save's last block and this one
@          is garbage/FF; done LAST because an incomplete command may leave
@          the chip mid-stream)
@ TM0 runs at prescaler 1 (16.78 MHz) with TM1 cascaded; both are zeroed
@ right before the write command's DMA3 is triggered.

.set IS_CHILD, 1
.include "mbprobe.inc"

.equ SCRATCH, 0x03000800
.equ EEPROM,  0x0DFFFF00

    IMAGE_HEADER start
    .ascii "EEPROM_V122\0"         @ save-type marker (dingbat, flashcarts)
    .balign 4

start:
    mov r0, #IOBASE
    add r0, r0, #0x208
    mov r1, #0
    strh r1, [r0]                  @ IME off
    ldr sp, =0x03007F00
    bl  sio_child_init
    bl  result_init
    bl  vid_init
    bl  timer3_init
    DRAW 1, 0, str_title
    ldr r0, =0x04000204
    ldr r1, =WAITCNT_EEPROM
    strh r1, [r0]

    bl  cart_gate                  @ A (or nothing) = 64 Kbit, B = 4 Kbit
    mov r4, #14
    tst r0, #KEY_B
    movne r4, #6
    ldr r5, =RESULT
    strb r4, [r5, #3]
    mov r6, #1
    mov r6, r6, lsl r4
    sub r6, r6, #1                 @ address = all bits set

    STATUS_MSG str_read
    mov r0, r4
    mov r1, r6
    add r2, r5, #4
    bl  eeprom_read                @ original -> 04..0B

    @ eight unchanged write-backs
    STATUS_MSG str_write
    mov r7, #0
1:  mov r0, r4
    mov r1, r6
    add r2, r5, #4
    bl  eeprom_write_timed
    add r8, r5, #0x10
    add r8, r8, r7, lsl #3
    STORE_BE16 r8, 0, r0
    STORE_BE32 r8, 2, r1
    add r7, r7, #1
    cmp r7, #8
    bne 1b

    @ changed write (complement), then restore
    ldr r8, =SCRATCH
    mov r7, #0
2:  add r0, r5, #4
    ldrb r0, [r0, r7]
    mvn r0, r0
    strb r0, [r8, r7]
    add r7, r7, #1
    cmp r7, #8
    bne 2b
    mov r0, r4
    mov r1, r6
    ldr r2, =SCRATCH
    bl  eeprom_write_timed
    add r8, r5, #0x50
    STORE_BE16 r8, 0, r0
    STORE_BE32 r8, 2, r1
    mov r0, r4
    mov r1, r6
    add r2, r5, #4
    bl  eeprom_write_timed
    add r8, r5, #0x58
    STORE_BE16 r8, 0, r0
    STORE_BE32 r8, 2, r1

    @ read back and compare
    mov r0, r4
    mov r1, r6
    add r2, r5, #0x60
    bl  eeprom_read
    mov r7, #0
    mov r1, #1
3:  add r0, r5, #4
    ldrb r2, [r0, r7]
    add r0, r5, #0x60
    ldrb r3, [r0, r7]
    cmp r2, r3
    movne r1, #0
    add r7, r7, #1
    cmp r7, #8
    bne 3b
    strb r1, [r5, #0x68]

    @ min / max of the eight ready counts
    mvn r8, #0                     @ min
    mov r9, #0                     @ max
    mov r7, #0
4:  add r0, r5, #0x12
    add r0, r0, r7, lsl #3
    ldrb r1, [r0]
    ldrb r2, [r0, #1]
    orr r1, r2, r1, lsl #8
    ldrb r2, [r0, #2]
    orr r1, r2, r1, lsl #8
    ldrb r2, [r0, #3]
    orr r1, r2, r1, lsl #8
    cmp r1, r8
    movlo r8, r1
    cmp r1, r9
    movhi r9, r1
    add r7, r7, #1
    cmp r7, #8
    bne 4b
    STORE_BE32 r5, 0x70, r8
    STORE_BE32 r5, 0x74, r9

    @ diagnostic read with the other address width, last: an incomplete
    @ command may leave the chip mid-stream, so nothing must follow it
    STATUS_MSG str_diag
    rsb r0, r4, #20                @ 14 <-> 6
    mov r1, #1
    mov r1, r1, lsl r0
    sub r1, r1, #1
    add r2, r5, #0x78
    bl  eeprom_read

    STATUS_MSG str_done
    b   viewer

@ ───────────────────────────── EEPROM protocol ──────────────────────────
@ GBATEK "GBA Cart Backup EEPROM": one halfword per bit, bit 0 only, DMA3
@ 16-bit src/dst incrementing; read = "11" + addr + "0", then 68 bits in
@ (4 ignored); write = "10" + addr + 64 data + "0".

dma3_copy16:                       @ r0 count, r1 src, r2 dst; waits for done
    mov r3, #IOBASE
    add r3, r3, #0xD4
    str r1, [r3]                   @ DMA3SAD
    str r2, [r3, #4]               @ DMA3DAD
    orr r0, r0, #0x80000000        @ DMA3CNT: enable, 16-bit, inc/inc, now
    str r0, [r3, #8]
1:  ldrh r0, [r3, #10]
    tst r0, #0x8000
    bne 1b
    bx  lr

put_bits:                          @ r0 value, r1 nbits, r7 = out ptr (halfwords)
    sub r1, r1, #1
1:  mov r2, r0, lsr r1
    and r2, r2, #1
    strh r2, [r7], #2
    subs r1, r1, #1
    bpl 1b
    bx  lr

eeprom_read:                       @ r0 addr bits, r1 address, r2 dest (8 bytes)
    push {r4-r8, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    ldr r7, =CMDBUF
    mov r0, #3
    mov r1, #2
    bl  put_bits                   @ "11"
    mov r0, r5
    mov r1, r4
    bl  put_bits                   @ address, MSB first
    mov r0, #0
    mov r1, #1
    bl  put_bits                   @ "0"
    add r0, r4, #3
    ldr r1, =CMDBUF
    ldr r2, =EEPROM
    bl  dma3_copy16
    mov r0, #68
    ldr r1, =EEPROM
    ldr r2, =RDBUF
    bl  dma3_copy16
    ldr r7, =RDBUF + 8             @ skip the 4 ignored bits
    mov r8, #8
1:  mov r1, #8
    mov r0, #0
2:  ldrh r2, [r7], #2
    and r2, r2, #1
    orr r0, r2, r0, lsl #1
    subs r1, r1, #1
    bne 2b
    strb r0, [r6], #1
    subs r8, r8, #1
    bne 1b
    pop {r4-r8, pc}

read_timer01:                      @ -> r0 = TM1:TM0 (carry-safe)
    mov r3, #IOBASE
    add r3, r3, #0x100
1:  ldrh r1, [r3, #4]
    ldrh r0, [r3]
    ldrh r2, [r3, #4]
    cmp r1, r2
    bne 1b
    orr r0, r0, r1, lsl #16
    bx  lr

eeprom_write_timed:                @ r0 addr bits, r1 address, r2 src (8 bytes)
                                   @ -> r0 count at DMA end, r1 count at ready
    push {r4-r8, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    ldr r7, =CMDBUF
    mov r0, #2
    mov r1, #2
    bl  put_bits                   @ "10"
    mov r0, r5
    mov r1, r4
    bl  put_bits                   @ address
    mov r8, #8
1:  ldrb r0, [r6], #1
    mov r1, #8
    bl  put_bits                   @ data, MSB first
    subs r8, r8, #1
    bne 1b
    mov r0, #0
    mov r1, #1
    bl  put_bits                   @ "0"
    @ timers: zero, TM1 cascaded first, then TM0 at prescaler 1
    mov r3, #IOBASE
    add r3, r3, #0x100
    mov r0, #0
    str r0, [r3]
    str r0, [r3, #4]
    ldr r0, =0x00840000
    str r0, [r3, #4]
    ldr r0, =0x00800000
    str r0, [r3]
    add r0, r4, #67
    ldr r1, =CMDBUF
    ldr r2, =EEPROM
    bl  dma3_copy16
    bl  read_timer01
    mov r7, r0                     @ DMA done
    ldr r8, =EEPROM
    ldr r2, =0x40000               @ poll cap (~0.5 s)
2:  ldrh r0, [r8]
    tst r0, #1
    bne 3f
    subs r2, r2, #1
    bne 2b
    mvn r1, #0
    b   4f
3:  bl  read_timer01
    mov r1, r0
4:  mov r0, r7
    pop {r4-r8, pc}

DEFSTR str_title, "EEPROM SETTLE"
DEFSTR str_read,  "READ BLOCK"
DEFSTR str_write, "TIMED WRITES"
DEFSTR str_diag,  "DIAG READ"

    .include "mbcommon.inc"
