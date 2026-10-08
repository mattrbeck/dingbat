@ payload: two H-blank DMAs on the same line, the second reading write-only
@ BG1VOFS -- does it see the word the first just wrote there?
@
@ Phantasy Star Collection's Master System player runs DMA1 (H-blank,
@ repeat, 16-bit, a ROM table -> BG1VOFS) and DMA2 (H-blank, repeat, FIXED
@ source BG1VOFS -> BG0VOFS), so its window layer scrolls with the picture.
@ A DMA read of a write-only register gets whatever is on the data bus. For
@ a burst's first transfer that is the CPU's last bus transaction
@ (DMA_READS_CPU_BUS, dmaobus.s on an AGB SP) -- but when two channels are
@ granted on the same H-blank, the second's first read is the cycle after
@ the first's last write (hdmalag.s on an AGB SP, 2026-09-24), so the CPU
@ never had the bus between them and the word on it is the first burst's.
@
@ Here the writer moves one halfword a line from an EWRAM table
@ X_k = 0xA500 | 0x11k (k = 0..15) to BG1VOFS; the reader moves one halfword
@ a line from BG1VOFS (fixed) to an EWRAM buffer cleared to 0xEEEE. Both are
@ armed on line 40, so line 40 + k's bursts are the k-th; they are
@ disarmed on line 48 (eight bursts each).
@
@ r0 bits 0..3  k: which line's reader halfword to answer with
@    bit 8      0: writer DMA1, reader DMA2 (the writer goes first)
@               1: reader DMA0, writer DMA1 (the reader goes first: the
@                  CPU had the bus last, since the line before)
@    bit 9      0: the CPU runs a Thumb NOP sled (0x46C0) from IWRAM across
@                  lines 40 and 41 (k = 0, 1), then polls VCOUNT
@               1: the CPU halts (SWI 2, IME clear) from line 40 until
@                  line 46's V-count match (k = 0..5 run under the halt)
@
@ answer: bits 0..15  the halfword the reader stored on line 40 + k
@         bits 16..23 how many of the 16 buffer slots the reader wrote (8)
@
@ AGB SP, 2026-10-02 (tools/hwlink/r0-agb.json 'hdmaobus'):
@   writer first, sled or halt:  X_k for every k (0008A500 0008A511 ...
@     0008A577) -- DMA_BUS_BACK_TO_BACK; mGBA the same
@   reader first, sled, k = 0, 1:  0008 46C0, the CPU's opcode
@     (DMA_READS_CPU_BUS); mGBA the same. From k = 2 the bursts race the
@     VCOUNT poll (where the arming left the sled is not fixed): every cell
@     answers several of the poll loop's bus words (its opcodes, or the line
@     number it loaded) and is no law
@   reader first, halt, k = 0:  00080300, the BIOS's last fetch (the stack
@     literal after Halt's `bx lr`; the HLE's stub BIOS has the same word)
@   reader first, halt, k = 1..5:  X_(k-1), the writer's word from the line
@     before: the halted CPU drives nothing (DMA_BUS_WHILE_HALTED)
@   reader first, halt, k = 6, 7 (woken on line 46, polling VCOUNT):
@     0008002E, the line number the poll's `ldrh` read (DMA_READS_IO_LOAD),
@     then 0008E150, the loop's `cmp` (the two channels hold the CPU 10
@     cycles, DMA_PENDING_CHAIN). tests/roms/payloads/hdmaphase.s takes
@     these two apart.
@ Before DMA_BUS_BACK_TO_BACK, writer first read the CPU's word too: 46C0 in
@ the sled, 1AFF / E1C6 from the VCOUNT poll after it, 0000 / 0300 under the
@ halt. That is what garbled the game's windows.
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
