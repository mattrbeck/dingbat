@ payload: which of the CPU's bus cycles an H-blank DMA reading write-only
@ I/O finds on the data bus, around a halt's wake (hdmaobus.s's halted half,
@ taken apart)
@
@ hdmaobus.s on an AGB SP, reader first under a halt that wakes on line
@ 46's V-count match: line 46's burst reads the line number the CPU's VCOUNT
@ poll loaded (002E), line 47's the poll loop's `cmp` opcode (E150). Which
@ cycle of the loop each line's request lands in moves by however long the
@ line-46 bursts held the CPU; this page walks the loop's phase on line 46
@ one cycle at a time and reads where it lands on lines 47 and 48, with and
@ without the writer's burst behind the reader's. It also reads which byte
@ lanes a narrow I/O load leaves on the 32-bit bus.
@
@ As hdmaobus.s: DMA0 (H-blank, repeat, 16-bit, source fixed) reads a
@ write-only register into an EWRAM buffer; DMA1 (H-blank, repeat, 16-bit,
@ destination fixed) moves X_k = 0xA500 | 0x11k from an EWRAM table to
@ BG1VOFS. Both armed at the start of line 40, the CPU halted (SWI 2, IME
@ clear) until line 46's V-count match; then n one-cycle ARM NOPs from IWRAM
@ and a poll of VCOUNT from IWRAM until line 49, when both are disarmed.
@ The poll loop is 7 cycles: load (fetch, I/O read, internal), cmp, bne
@ (three fetches), and its bus words are bne / the load / the load /
@ mov / strh / the load again / cmp.
@
@ r0 bits 0..3  k: which line's reader halfword to answer with (40 + k)
@    bits 4..6  n: NOPs between the wake and the poll loop (0..6)
@    bit 8      1: no writer (DMA0 alone)
@    bit 9      the reader's source: 0 BG1VOFS 04000016 (a word's upper
@               half), 1 BG1HOFS 04000014 (its lower half)
@    bits 12..13 the poll's load: 0 ldrh VCOUNT, 1 ldrb VCOUNT,
@               2 ldr of DISPSTAT | VCOUNT << 16
@
@ answer: bits 0..15  the halfword the reader stored on line 40 + k
@         bits 16..23 how many of the 16 buffer slots the reader wrote (9)
@
@ AGB SP, 2026-10-02 (tools/hwlink/r0-agb.json 'hdmaphase', three passes,
@ every cell unanimous):
@ - Line 46, n = 0..6: cmp, ldrh (the branch target: the first refill
@   fetch), ldrb, b, the load, the load, bne -- one bus cycle each, so the
@   load's value stays on the bus through its internal cycle and a request
@   between the two refill fetches finds the first (DMA_SEES_REFILL_FETCH).
@ - Reader alone, the next line is one bus cycle further back in the loop:
@   the reader holds the CPU 6 cycles (lead, I/O read, EWRAM write,
@   hand-back), 5 when the request lands in the load and the load's
@   internal cycle runs under it.
@ - Writer behind it, three cycles further on: 10 cycles, not 12 -- the
@   second channel follows the first with no hand-back and no lead between
@   them (DMA_PENDING_CHAIN; hdmalag.s saw the same from the DMA's side).
@ - Any load width of VCOUNT leaves the whole I/O word on the bus: upper
@   half 002E, lower half DISPSTAT 2E26 (DMA_READS_IO_LOAD).
@ - Under the halt the reader alone reads its own word from the line before
@   (0300, the BIOS's, every line: DMA_BUS_WHILE_HALTED).
@ mGBA: 9/80. dingbat before these rules: 38/80 (HLE), 41/80 (Nintendo's).
    .include "probe.inc"
    .arm
    .text
    .global _start

.equ TABLE,   0x02010000
.equ BUF,     0x02010100
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

    @ r6 the writer's SAD (DMA1), r7 the reader's (DMA0)
    add r6, r8, #0x0C
    mov r7, r8
    ldr r0, =TABLE
    str r0, [r6]
    ldr r0, =0x04000016
    str r0, [r6, #4]
    tst r9, #0x200
    ldreq r0, =0x04000016
    ldrne r0, =0x04000014
    str r0, [r7]
    ldr r0, =BUF
    str r0, [r7, #4]
    mov r0, #1
    strh r0, [r6, #8]
    strh r0, [r7, #8]
    ldr r2, =0xA240                @ on, H-blank, repeat, 16-bit, dst fixed
    tst r9, #0x100
    movne r2, #0                   @ no writer
    ldr r3, =0xA300                @ on, H-blank, repeat, 16-bit, src fixed

    @ r11 the NOP sled's entry (6 - n NOPs from its end), r7 the poll loop
    and r0, r9, #0x70
    mov r0, r0, lsr #2             @ n * 4
    adr r11, sled_end
    sub r11, r11, r0
    and r0, r9, #0x3000
    adr r1, polls
    add r1, r1, r0, lsr #8         @ (kind) * 16
    str r1, [r12, #16]             @ the loop's address

    @ arm both at the start of line LINE: its H-blank is the first burst
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

    probe_park (LINE + 6)
    mov r1, #(LINE + 9)
    ldr r7, [r12, #16]
    bx r11
    .rept 6
    mov r0, r0
    .endr
sled_end:
    bx r7

    .align 4
polls:
5:  ldrh r0, [r4, #6]
    cmp r0, r1
    bne 5b
    b 8f
6:  ldrb r0, [r4, #6]
    cmp r0, r1
    bne 6b
    b 8f
7:  ldr r0, [r4, #4]
    cmp r1, r0, lsr #16
    bne 7b
    b 8f

8:  mov r0, #0
    add r6, r8, #0x0C
    strh r0, [r6, #10]
    strh r0, [r8, #10]
    ldr r1, =0x04000016
    strh r0, [r1]
    strh r0, [r1, #-2]

    @ the answer: slot k, and how many slots were written
    ldr r1, =BUF
    and r0, r9, #0x0F
    mov r0, r0, lsl #1
    ldrh r2, [r1, r0]
    ldr r6, =SENT
    mov r3, #0
    mov r0, #0
9:  ldrh r7, [r1, r0]
    cmp r7, r6
    addne r3, r3, #1
    add r0, r0, #2
    cmp r0, #32
    blo 9b
    orr r0, r2, r3, lsl #16
    probe_leave
    probe_data
