@ eesettle.s -- how long does the cartridge's EEPROM take to program a block?
@
@ WHAT: the cart's LAST EEPROM block is read, then written back (the same
@ eight bytes, or their complement and then the original again), with TM0
@ (prescaler 1) cascaded into TM1 started just before the DMA3 that clocks
@ the write command out ("10" + address + 64 data bits + "0", one halfword
@ per bit, GBATEK "GBA Cart Backup EEPROM"). The payload then polls the
@ chip (ldrh 0x0DFFFF00, bit 0) until it reads 1 (ready) and answers the
@ cycles from the end of the DMA to that first ready read.
@ WHY: Super Mario Advance 3 - Yoshi's Island formats a blank EEPROM at
@ first boot with 196 block writes, each polled to ready. The frame counter
@ the game seeds its level decorations from starts when they end, so the
@ programming time decides what grows on 1-1's first bush (tulip buds or
@ white puffs) and where its first Shy Guy walks: one block write longer or
@ shorter by ~1500 cycles moves the boot by a frame and can flip it
@ (docs/playtest-bugs.md, "Super Mario Advance 3: the cart's EEPROM decides
@ 1-1"). dingbat programs in GBATEK's "ca. 108368 clock cycles (ca. 6.5ms)"
@ (storage/eeprom.nim EEPROM_SETTLE_CYCLES); the playtest's references
@ behave as if ~115000 (mgba) and ~101500 (the second reference).
@
@ RIG: the console boots into the multiboot wait WITH the cart inserted if
@ SELECT+START are held at power-on (GBATEK "Multiboot Slave with
@ Cartridge"); install the monitor then, as usual. No cart (or no Nintendo
@ header at 0x08000000) answers DEAD0001 without touching the bus. The
@ block is left as it was found (the changed write is undone by the next
@ one and read back); a power loss during the ~15 ms of writes could lose
@ that one block, the save's last 8 bytes. Each cell costs one or two
@ program cycles of the chip's ~100k.
@
@ r0 bits 0..3  n: 0  write back unchanged; answer ready - DMA end
@                  1  write the complement, answer its ready - DMA end; then
@                     restore the original (waited, not timed) and read it
@                     back: bit 31 set if the block did not come back
@                  2  write back unchanged; answer the DMA's own length
@                     (timer start to DMA end): with n = 0 this anchors
@                     where the busy window starts (dingbat: at the last
@                     data bit, Assumed)
@                  3  no write: the block's first four bytes (big-endian),
@                     to check the width
@    bit 8      address width: 0 = 14 bits (64 Kbit, 8 KB saves, Super
@               Mario Advance 3), 1 = 6 bits (4 Kbit, 512 B saves)
@ answer: cycles (one per CPU cycle); FFFFFFFF = never ready within ~0.25 s;
@ DEAD0001 = no cartridge header
@
@ PROVENANCE: dingbat (r0table.py --emulators-only): n = 3 FFFFFFFF (a
@ blank block), n = 2 848, n = 0 and 1 108362 (EEPROM_SETTLE_CYCLES from
@ the last data bit, less the stop bit's transfer, plus the poll). mgba:
@ 849, then 38 for n = 0 / 1 -- it keeps the chip busy only for a command
@ of the width it settled on (a 6-bit write reads 114992), though in the
@ game it waits ~114750 a block (as if 115000). Console: not yet run. A
@ spread between runs, or between n = 0 and n = 1 (a chip that skips the
@ erase of an unchanged block), is part of the answer.
    .include "probe.inc"
    .arm
    .text
    .global _start

.equ EEPROM,  0x0DFFFF00

_start:
    probe_enter
    ldrh r0, [r5, #4]
    str r0, savedws                @ WAITCNT
    @ a Nintendo header: logo's first word and the fixed 0x96 at 0xB2
    mov r0, #0x08000000
    ldr r1, [r0, #4]
    ldr r2, =0x51AEFF24
    cmp r1, r2
    ldreqb r1, [r0, #0xB2]
    cmpeq r1, #0x96
    ldrne r0, =0xDEAD0001
    bne done
    ldr r0, =0x4317                @ WS2 8/8 clocks, the library's setting
    strh r0, [r5, #4]

    mov r6, #14                    @ address bits
    tst r9, #0x100
    movne r6, #6
    mov r7, #1
    mov r7, r7, lsl r6
    sub r7, r7, #1                 @ address = all bits set: the last block

    adr r2, orig
    bl  ee_read
    and r0, r9, #15
    cmp r0, #3
    beq read_only
    cmp r0, #1
    beq changed

    adr r2, orig                   @ n = 0 / 2: unchanged write-back
    bl  ee_write_timed
    and r2, r9, #15
    cmp r2, #2
    moveq r0, r3                   @ n = 2: the DMA's length
    b   done

changed:
    adr r0, orig
    adr r1, comp
    mov r2, #8
1:  ldrb r3, [r0], #1
    mvn r3, r3
    strb r3, [r1], #1
    subs r2, r2, #1
    bne 1b
    adr r2, comp
    bl  ee_write_timed
    str r0, answer
    adr r2, orig                   @ restore, then check it came back
    bl  ee_write_timed
    adr r2, back
    bl  ee_read
    ldr r0, answer
    ldr r1, orig
    ldr r2, back
    cmp r1, r2
    ldreq r1, orig + 4
    ldreq r2, back + 4
    cmpeq r1, r2
    orrne r0, r0, #0x80000000
    b   done

read_only:
    ldrb r0, orig
    ldrb r1, orig + 1
    orr r0, r1, r0, lsl #8
    ldrb r1, orig + 2
    orr r0, r1, r0, lsl #8
    ldrb r1, orig + 3
    orr r0, r1, r0, lsl #8

done:
    ldr r1, savedws
    strh r1, [r5, #4]
    probe_leave

@ r1 = halfword count, r2 = source; DMA3 16-bit, inc/inc, now; waits
dma3_to_eeprom:
    add r3, r4, #0xD4
    str r2, [r3]
    ldr r2, =EEPROM
    str r2, [r3, #4]
    orr r1, r1, #0x80000000
    str r1, [r3, #8]
1:  ldrh r1, [r3, #10]
    tst r1, #0x8000
    bne 1b
    bx  lr

@ append r1 bits of r0 (MSB first) at r3 (halfwords), r3 advances
put_bits:
    subs r1, r1, #1
    bxmi lr
    mov r2, r0, lsr r1
    and r2, r2, #1
    strh r2, [r3], #2
    b   put_bits

@ read the block at address r7 (r6 bits) into r2 (8 bytes)
ee_read:
    stmfd sp!, {r2, lr}
    adr r3, cmdbuf
    mov r0, #3
    mov r1, #2
    bl  put_bits                   @ "11"
    mov r0, r7
    mov r1, r6
    bl  put_bits                   @ address
    mov r0, #0
    mov r1, #1
    bl  put_bits                   @ "0"
    add r1, r6, #3
    adr r2, cmdbuf
    bl  dma3_to_eeprom
    add r3, r4, #0xD4              @ 68 bits in: 4 ignored, then the data
    ldr r2, =EEPROM
    str r2, [r3]
    adr r2, rdbuf
    str r2, [r3, #4]
    ldr r1, =0x80000044
    str r1, [r3, #8]
1:  ldrh r1, [r3, #10]
    tst r1, #0x8000
    bne 1b
    ldmfd sp!, {r2}
    adr r3, rdbuf + 8
    mov r12, #8
2:  mov r1, #8
    mov r0, #0
3:  ldrh lr, [r3], #2
    and lr, lr, #1
    orr r0, lr, r0, lsl #1
    subs r1, r1, #1
    bne 3b
    strb r0, [r2], #1
    subs r12, r12, #1
    bne 2b
    ldr r12, =probe_vars
    ldmfd sp!, {pc}

@ write r2's 8 bytes to the block at r7, then poll to ready.
@ -> r0 = ready - DMA end (FFFFFFFF never), r3 = DMA end (timer start = 0)
ee_write_timed:
    stmfd sp!, {r4, r8, lr}
    mov r8, r2
    adr r3, cmdbuf
    mov r0, #2
    mov r1, #2
    bl  put_bits                   @ "10"
    mov r0, r7
    mov r1, r6
    bl  put_bits                   @ address
    mov r4, #8
1:  ldrb r0, [r8], #1
    mov r1, #8
    bl  put_bits                   @ data, MSB first
    subs r4, r4, #1
    bne 1b
    mov r0, #0
    mov r1, #1
    bl  put_bits                   @ "0"
    mov r4, #0x04000000            @ dma3_to_eeprom's I/O base again
    mov r0, #0
    str r0, [r10]
    str r0, [r10, #4]
    ldr r0, =0x00840000
    str r0, [r10, #4]              @ TM1 cascade
    str r11, [r10]                 @ TM0 prescaler 1
    add r1, r6, #67
    adr r2, cmdbuf
    bl  dma3_to_eeprom
    bl  read_timers
    mov r4, r0                     @ DMA end
    ldr r3, =EEPROM
    ldr r2, =0x40000
2:  ldrh r0, [r3]
    tst r0, #1
    bne 3f
    subs r2, r2, #1
    bne 2b
    mvn r0, #0
    b   4f
3:  bl  read_timers
    sub r0, r0, r4
4:  mov r3, r4
    ldr r12, =probe_vars
    ldmfd sp!, {r4, r8, pc}

@ -> r0 = TM1:TM0, carry-safe
read_timers:
1:  ldrh r1, [r10, #4]
    ldrh r0, [r10]
    ldrh r2, [r10, #4]
    cmp r1, r2
    bne 1b
    orr r0, r0, r1, lsl #16
    bx  lr

    .ltorg
    .balign 4
savedws: .word 0
answer:  .word 0
orig:    .space 8
comp:    .space 8
back:    .space 8
cmdbuf:  .space 2 * 82
rdbuf:   .space 2 * 68
    @ the save-type marker: the emulators' cartridge wrapper carries these
    @ bytes, so it gets an EEPROM
    .ascii "EEPROM_V122"
    .balign 4
    probe_data
