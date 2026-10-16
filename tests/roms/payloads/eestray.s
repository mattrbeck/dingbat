@ eestray.s -- what does a lone CPU access do to the cartridge EEPROM's
@ serial command?
@
@ WHAT: the cart's last two EEPROM blocks are read cleanly (DMA3, one
@ halfword per bit, GBATEK "GBA Cart Backup EEPROM"): L, all address bits
@ set, and P, the same but bit 0 clear. Then P is read again with a stray
@ CPU access next to its read request. A chip that takes a lone `strh 1` as
@ a serial bit sees "1" + "11" + P + "0": its address is then P's bits
@ shifted one place, which is L, with the stop bit still a 0 -- so the
@ shifted parse is a valid read of L. Which block comes back says what the
@ chip did with the stray.
@ WHY: Columns Crown probes for a flash chip at boot with strh 0xFF, 0x90,
@ 0xFF to 0x0DFFFFFE and a word read of 0x09FFE000, ~7000 cycles before
@ its first command DMA (docs/playtest-bugs.md §95). dingbat took them as
@ bits 1, 0, 1, sized the chip from a stale DMA3 count and lost every
@ save; it now drops a command on a store outside a DMA (storage/eeprom.nim:
@ a CPU access is its own /CS frame, after GBATEK's "manual transfers via
@ LDRH/STRH won't work"). The game shipped saving, so the console's chip
@ discards those three stores somehow; the cells below tell the ways apart
@ (tools/hwlink/predicted.py, written before any console run):
@   frame    each /CS-low frame is parsed alone and a short one dropped,
@            an addressed read kept (dingbat now): every cell reads P
@   shift    every written bit shifts in and nothing resets the parser:
@            cells 1-5, 7, 8 do not read P (later cells inherit the
@            leftover bits, so only "not P" is predicted)
@   timeout  bits shift in, an idle gap resets the parser: cell 2 (16k
@            idle cycles) reads P, cells 1, 3, 4, 5, 7, 8 do not
@   readrst  a read the chip sees resets it: cell 3 (a ready poll) and
@            cell 8 (A23 is high at 0x09FFE000 on a cart of 16 MB or less,
@            so the chip sees that read) read P, cells 1, 2, 5, 7 do not
@   romrst   a ROM access (/CS low with A23 low) resets it: cell 4 reads
@            P, cells 1, 2, 3, 5, 7, 8 do not
@ Cell 6 asks whether a read already addressed survives a stray store
@ (frame: P; a chip that drops it answers neither, 2). Bits 24-27 also
@ record what the four bits GBATEK says to ignore read as.
@
@ SAFETY (it never writes): every bit the payload writes to the chip is a
@ 1 except the last one or two of each read request ("11" + P ends "0",
@ then the stop bit "0"), so the only "10" in the stream is at a request's
@ end, and at most two written bits follow it before the cell's barrier.
@ A write needs "10" + n address bits + 64 data bits written after it, so
@ no parse completes one inside a cell. Between cells the barrier gives the
@ chip every reset Columns Crown's boot gives it before its first command
@ (an idle gap of ~65k cycles, a ROM read, a ready poll, and /CS rising):
@ a chip that kept a command across all of them would have taken that
@ boot's 1, 0, 1 as a write command and lost the game's saves, which
@ shipped working. No cell stores a 0 to the chip.
@
@ RIG: as eesettle.s: the cart in the slot, the console booted holding
@ SELECT+START, the monitor installed, then
@ `python3 tools/hwlink/r0table.py --record eestray4k --cart=<game code>`
@ (a 4 Kbit cart; `eestray` for a 64 Kbit one). No cart (or no Nintendo
@ header) answers DEAD0001 without touching the bus. A cart whose blocks L
@ and P hold the same bytes (a blank chip: every emulator here) answers
@ code 3 and says nothing; Columns Crown's own save fills both.
@
@ r0 bits 0..3  n: 0  P again, no stray (the control's repeat)
@                  1  strh 1, then P's request DMA at once
@                  2  strh 1, ~16k cycles idle (past Columns' ~7k), P
@                  3  strh 1, a ready poll (ldrh 0x0DFFFF00), P
@                  4  strh 1, a ROM read (ldrh 0x08000000), P
@                  5  strb 1, then P's request at once
@                  6  P's request, then strh 1, then the 68-bit read
@                  7  strh 1 twice, then P's request at once
@                  8  strh 1, ldr 0x09FFE000 (Columns' read), P
@    bit 8      address width: 0 = 14 bits (64 Kbit), 1 = 6 bits (4 Kbit)
@ answer: bits 28-31 0 = the stray cell read P (aligned), 1 = it read L
@         (shifted one bit), 2 = neither, 3 = L and P hold the same bytes
@         (no answer on this cart); bits 24-27 the 4 bits read before the
@         data (first in bit 27); bits 0-23 the data's first three bytes
@ DEAD0001 = no cartridge header
@
@ PROVENANCE (2026-10-16): r0table.py eestray4k --emulators-only, a blank
@ chip: dingbat and dingbat-bios 3FFFFFFF in every cell, mgba 30FFFFFF
@ (its four lead bits read 0) but 3FFFFFFF in cell 6. Seeded with Columns
@ Crown's 512-byte save (P = 4F 43 00 01 .., L = 00 00 00 00 ..), every
@ save byte unchanged afterwards: dingbat 0F4F4300 in every cell; dingbat
@ before the §95 fix 1F000000 (L) in cells 1, 2, 3, 4, 7, 8 and 0F4F4300 in
@ 0, 5 (a byte store was a read there) and 6; mgba 004F4300 in 0 and 5,
@ 20FFFFFF in 1-4 and 8, 2FFFFFFF in 6, 10FFFFFF in 7 (it re-sized the
@ chip to 64 Kbit on the way and wrote an 8 KB file). Console: not yet run.
    .include "probe.inc"
    .arm
    .text
    .global _start

.equ EEPROM,  0x0DFFFF00
.equ STRAY,   0x0DFFFFFE

_start:
    probe_enter
    ldrh r0, [r5, #4]
    str r0, savedws                @ WAITCNT
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
    sub r7, r7, #1                 @ L: every address bit set

    bl  barrier
    mov r0, r7
    bl  build_request
    bl  send_request
    adr r2, blk_l
    bl  fetch
    bl  barrier
    sub r0, r7, #1                 @ P
    bl  build_request
    bl  send_request
    adr r2, blk_p
    bl  fetch
    bl  barrier

    sub r0, r7, #1                 @ the cell: P, with its stray
    bl  build_request
    ldr r3, =STRAY
    mov r1, #1
    and r0, r9, #15
    cmp r0, #1
    beq c_now
    cmp r0, #2
    beq c_idle
    cmp r0, #3
    beq c_poll
    cmp r0, #4
    beq c_rom
    cmp r0, #5
    beq c_byte
    cmp r0, #6
    beq c_between
    cmp r0, #7
    beq c_two
    cmp r0, #8
    beq c_high
    bl  send_request               @ n = 0 (and anything else): no stray
    b   c_read
c_now:
    strh r1, [r3]
    bl  send_request
    b   c_read
c_idle:
    strh r1, [r3]
    ldr r0, =4096                  @ ~4 cycles a turn from IWRAM
1:  subs r0, r0, #1
    bne 1b
    bl  send_request
    b   c_read
c_poll:
    strh r1, [r3]
    ldr r0, =EEPROM
    ldrh r0, [r0]
    bl  send_request
    b   c_read
c_rom:
    strh r1, [r3]
    mov r0, #0x08000000
    ldrh r0, [r0]
    bl  send_request
    b   c_read
c_byte:
    strb r1, [r3]
    bl  send_request
    b   c_read
c_between:
    bl  send_request
    ldr r3, =STRAY
    mov r1, #1
    strh r1, [r3]
    b   c_read
c_two:
    strh r1, [r3]
    strh r1, [r3]
    bl  send_request
    b   c_read
c_high:
    strh r1, [r3]
    ldr r0, =0x09FFE000
    ldr r0, [r0]
    bl  send_request
c_read:
    adr r2, blk_x
    bl  fetch
    mov r6, r0                     @ the 4 lead bits
    bl  barrier

    @ the answer
    adr r0, blk_l
    adr r1, blk_p
    bl  same8
    movne r3, #0
    moveq r3, #3                   @ L == P: this cart cannot tell
    bne 2f
    b   3f
2:  adr r0, blk_x
    adr r1, blk_p
    bl  same8
    moveq r3, #0
    beq 3f
    adr r0, blk_x
    adr r1, blk_l
    bl  same8
    moveq r3, #1
    movne r3, #2
3:  ldrb r0, blk_x
    ldrb r1, blk_x + 1
    orr r0, r1, r0, lsl #8
    ldrb r1, blk_x + 2
    orr r0, r1, r0, lsl #8
    orr r0, r0, r6, lsl #24
    orr r0, r0, r3, lsl #28

done:
    ldr r1, savedws
    strh r1, [r5, #4]
    probe_leave

@ Z set if the 8 bytes at r0 and r1 match
same8:
    ldr r2, [r0]
    ldr r3, [r1]
    cmp r2, r3
    ldreq r2, [r0, #4]
    ldreq r3, [r1, #4]
    cmpeq r2, r3
    bx  lr

@ what Columns Crown's boot gives the chip before its first command: idle
@ time (~65k cycles), a ROM read, a ready poll
barrier:
    ldr r0, =16384
1:  subs r0, r0, #1
    bne 1b
    mov r0, #0x08000000
    ldrh r0, [r0]
    ldr r0, =EEPROM
    ldrh r0, [r0]
    bx  lr

@ append r1 bits of r0 (MSB first) at r3 (halfwords), r3 advances
put_bits:
    subs r1, r1, #1
    bxmi lr
    mov r2, r0, lsr r1
    and r2, r2, #1
    strh r2, [r3], #2
    b   put_bits

@ "11" + r0 (r6 bits) + "0" into cmdbuf, not yet sent
build_request:
    stmfd sp!, {r0, lr}
    adr r3, cmdbuf
    mov r0, #3
    mov r1, #2
    bl  put_bits
    ldmfd sp!, {r0}
    mov r1, r6
    bl  put_bits
    mov r0, #0
    mov r1, #1
    bl  put_bits
    ldmfd sp!, {pc}

@ cmdbuf -> the chip: DMA3 16-bit, inc/inc, now; waits. Keeps r3.
send_request:
    add r2, r4, #0xD4
    adr r0, cmdbuf
    str r0, [r2]
    ldr r0, =EEPROM
    str r0, [r2, #4]
    add r0, r6, #3
    orr r0, r0, #0x80000000
    str r0, [r2, #8]
1:  ldrh r0, [r2, #10]
    tst r0, #0x8000
    bne 1b
    bx  lr

@ 68 bits in; the 64 data bits into r2 (8 bytes); r0 = the first 4 bits
fetch:
    stmfd sp!, {r2, lr}
    add r3, r4, #0xD4
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
    adr r3, rdbuf
    mov r1, #4
    mov r0, #0
4:  ldrh lr, [r3], #2
    and lr, lr, #1
    orr r0, lr, r0, lsl #1
    subs r1, r1, #1
    bne 4b
    ldr r12, =probe_vars
    ldmfd sp!, {pc}

    .ltorg
    .balign 4
savedws: .word 0
blk_l:   .space 8
blk_p:   .space 8
blk_x:   .space 8
cmdbuf:  .space 2 * 18
rdbuf:   .space 2 * 68
    @ the save-type marker: the emulators' cartridge wrapper carries these
    @ bytes, so it gets an EEPROM
    .ascii "EEPROM_V122"
    .balign 4
    probe_data
