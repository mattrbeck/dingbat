@ payload: hdmaobus.s with the console's run-to-run phase made an argument
@
@ hdmaobus's reader-first sled cells (0x102-0x107) answer several words on
@ the console: the arming polls VCOUNT in a 7-cycle loop, and where in that
@ loop line 40 starts depends on where the payload was entered, which the
@ link rig does not fix. An emulator enters on one cycle and so answers one
@ of the words. This is the same probe woken on a fixed cycle of line 37
@ (probe_park), then d = bits 12..15 one-cycle NOPs ahead of the arming's
@ poll (probe_sled), so the entry phase is an argument. The 1232-cycle line
@ is 176 polls, so the phase survives the line changes: d and d + 7 answer
@ alike. tools/hwlink/r0table.py RACES walks d = 0..6 and scores each
@ hdmaobus racing cell by whether every word the console gave is among the
@ core's seven; tests/roms/cyclelaws holds that.
@
@ r0 as hdmaobus.s, plus bits 12..15 d.
@
@ Predicted before any console run, 2026-10-14 (dingbat, both BIOSes),
@ reader first in the sled (bit 8 set, bit 9 clear), the low halfword for
@ k = 2..7 (bits 16..23 read 08 everywhere):
@   d = 0  E150 E3A0 1AFF E1C6 002E E150
@   d = 1  E1D4 002B E150 E3A0 1AFF E1C6
@   d = 2  E1C6 002B E150 E3A0 1AFF E1C6
@   d = 3  E3A0 1AFF E1C6 002D E150 E3A0
@   d = 4  002A E150 E3A0 1AFF E1C6 002F
@   d = 5  002A E150 E3A0 1AFF E1C6 002F
@   d = 6  1AFF E1C6 002C E150 E3A0 1AFF
@ Each line the poll's bus word steps one along 00LL (the line its ldrh
@ loaded), E150 (cmp), E3A0, 1AFF (bne), E1C6, E1D4 only at k = 2 and d = 1.
@ The console was woken on the same cycle (hdmaphase, halthb), so each cell
@ should be unanimous and the table this one -- or, if the wake differs by
@ c cycles, this table with its rows rotated by c. Every other cell (k = 0,
@ 1, writer first, halted) answers as hdmaobus does at every d. mGBA: 0000,
@ 0001 or FFFC in the racing cells, 7F00 under the halt (k = 0..5).
    .include "probe.inc"
    .arm
    .text
    .global _start

.equ TABLE,   0x02010000
.equ BUF,     0x02010100
.equ BG1VOFS, 0x04000016
.equ LINE,    40
.equ SENT,    0xEEEE

_start:
    probe_enter
    mov r0, #0
    str r0, [r8, #0x14]            @ DMA1 off
    str r0, [r8, #0x20]            @ DMA2 off

    @ the writer's table and the reader's buffer
    ldr r1, =TABLE
    ldr r2, =0xA500
    mov r3, #0
1:  orr r0, r2, r3
    strh r0, [r1], #2
    add r3, r3, #0x11
    cmp r3, #0x110
    blo 1b
    ldr r1, =BUF
    ldr r0, =SENT
    mov r3, #16
2:  strh r0, [r1], #2
    subs r3, r3, #1
    bne 2b

    @ r6 the writer's SAD, r7 the reader's
    add r6, r8, #0x0C              @ the writer is DMA1 either way
    tst r9, #0x100
    addeq r7, r8, #0x18            @ reader DMA2, after the writer
    movne r7, r8                   @ reader DMA0, before it
    ldr r0, =TABLE
    str r0, [r6]
    ldr r0, =BG1VOFS
    str r0, [r6, #4]
    str r0, [r7]
    ldr r0, =BUF
    str r0, [r7, #4]
    mov r0, #1
    strh r0, [r6, #8]
    strh r0, [r7, #8]
    ldr r2, =0xA240                @ on, H-blank, repeat, 16-bit, dst fixed
    ldr r3, =0xA300                @ on, H-blank, repeat, 16-bit, src fixed

    @ wake on a fixed cycle of line LINE - 3, d cycles, then arm both at
    @ the start of line LINE: its H-blank is the first burst
    probe_park (LINE - 3)
    mov r0, r9, lsr #12
    probe_sled r0
    mov r1, #(LINE - 1)
3:  ldrh r0, [r4, #6]
    cmp r0, r1
    bne 3b
    add r1, r1, #1
4:  ldrh r0, [r4, #6]
    cmp r0, r1
    bne 4b
    strh r2, [r6, #10]
    strh r3, [r7, #10]

    tst r9, #0x200
    bne 5f
    adr r0, sled
    add r0, r0, #1
    adr lr, 6f
    bx r0
5:  probe_park (LINE + 6)

6:  mov r1, #(LINE + 8)
7:  ldrh r0, [r4, #6]
    cmp r0, r1
    bne 7b
    mov r0, #0
    strh r0, [r6, #10]
    strh r0, [r7, #10]
    ldr r1, =BG1VOFS
    strh r0, [r1]

    @ the answer: slot k, and how many slots were written
    ldr r1, =BUF
    and r0, r9, #0x0F
    mov r0, r0, lsl #1
    ldrh r2, [r1, r0]
    ldr r6, =SENT
    mov r3, #0
    mov r0, #0
8:  ldrh r7, [r1, r0]
    cmp r7, r6
    addne r3, r3, #1
    add r0, r0, #2
    cmp r0, #32
    blo 8b
    orr r0, r2, r3, lsl #16
    probe_leave
    .ltorg                         @ ahead of the sled, in reach of the loads

    @ about 3000 one-cycle Thumb NOPs from IWRAM: lines 40 and 41's H-blanks
    @ land in it, wherever the arming stores left the CPU on line 40
    .thumb
    .align 2
sled:
    .rept 3000
    mov r8, r8
    .endr
    bx lr
    .align 2
    .arm
    probe_data
