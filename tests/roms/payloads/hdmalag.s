@ payload: an H-blank DMA whose burst outlasts the line
@
@ What does the console do with an H-blank request that arrives while the
@ same channel's burst (or another channel's) is still running: run it once
@ straight after, wait for the next H-blank, or queue one burst per line?
@
@ AGB SP, 2026-09-24 (tools/hwlink/r0-agb.json 'hdmalag', three passes):
@ - A request that finds its own channel's burst still running is DROPPED.
@   The next burst waits for the first H-blank after the burst ends, so
@   bursts of 1.0-1.9, 2.0-2.9 and 3.0+ lines start every 2nd, 3rd and 4th
@   line, exactly on the H-blank (every start is +1232k from the first).
@   Nothing is queued: the CPU runs from the last burst's end.
@ - The edge, to the cycle (configurations 16-20 and 23-30): with F the
@   cycle a burst granted on that H-blank makes its first read on (981 +
@   1232k here), the request is dropped when the channel's last write is
@   still going on cycle F - 2, and kept when that write's last cycle is
@   F - 3 (24: F - 3, kept; 28: F - 2, dropped). One channel alone: 307
@   units (last write done on F - 5) run every line, 308 (F - 1) every
@   other line.
@ - A request that finds ANOTHER channel's burst running stays latched and
@   runs when that burst ends (12: DMA2 behind DMA1's 1.4-line bursts runs
@   straight after each; 13, 14: DMA2 preempted by DMA1 each line). A
@   latched request collapses with a later one; a burst paused by a
@   higher-priority channel still counts as running for its own requests.
@ - No H-blank requests on lines 160-227 (8: armed on line 225, the first
@   burst is line 0's). A burst running at line 160 runs to its end, and a
@   request latched on line 159 (another channel's) runs in V-blank (12).
@ - Two channels granted on the same H-blank: the second's first read is
@   the cycle after the first's last write (d = 2, 4, 7, 21 below: A starts
@   at 981 + d). dingbat starts it two cycles later; that moves configs 24
@   and 29 across the edge above, which is why 23-30 are not in the law.
@   A DMA1 preempting a running DMA2 on the next H-blank (13, 14) makes its
@   first read at 2217 on the console, 2212 in dingbat.
@
@ Every transferred halfword stamps itself: the source is TM0CNT_L (fixed),
@ the destination an EWRAM buffer (incrementing across the repeats), so the
@ buffer is the exact timeline of every unit the channel moved. TM0 runs at
@ one tick a cycle; the buffer is cleared first, and two zeros in a row are
@ where the DMA stopped writing (stamps are at least 4 cycles apart). The
@ burst length N is exact, so burst k is units kN .. kN+N-1 whatever the
@ gaps; the payload unwraps the 16-bit stamps into cycles since TM0 started
@ (started by the store after the wake on line L's V-count match) and keeps
@ each burst's first and last stamp. A unit costs 4 cycles (TM0 read 1,
@ EWRAM write 3); a line is 1232.
@
@ Safety. If the console queued a burst per line, a burst longer than a line
@ would keep the CPU off the bus for good. DMA0 is the bound: V-blank, repeat,
@ one halfword from {N, 0} to the long channel's CNT_L upward, so the first
@ V-blank rewrites CNT_L with its own value and the second writes 0 to
@ CNT_H, which ends the channel (DMA0 preempts every other channel). The CPU
@ disables everything at line D of the first frame it gets to run in, which
@ under any bounded rule is the first V-blank. The worst case (stamps from
@ line 100 to the next frame's line 160, back to back at 4 cycles a unit)
@ is 177 KB; the buffers have 192 KB between them: channel A (DMA1 or DMA3)
@ grows up from 0x02010000, channel B (DMA2) down from 0x0203FFFE. Under a
@ burst-per-request rule the longest configuration writes 179 KB and
@ returns. Configurations 31-34 arm nothing else (no DMA0), so a core that
@ only drains events mid-burst when a higher channel is armed runs them on
@ its other path; they are short enough that even a burst per request would
@ be over by line 200. 21 has neither bound and was never sent.
@
@ r0 bits 0..7  which word of the result block to answer with
@    bits 8..15 the configuration (the table at the end)
@
@ Result block, 0x02008000 (words):
@   +0  A units   +4  A bursts   +8  A first start   +12 A last start
@   +16 A last unit
@   +20 .. +36    the same for B
@   +40 A last start, +44 A last unit, +48 B first start, +52 B last unit,
@       all less A's first start; +56 A burst 1's start less burst 0's last
@       unit; +60 A burst 1's start less A's first
@   +64 ..        A's bursts: (start, end) for k = 0..47
@   +448 ..       B's bursts, the same
@ Times are cycles since TM0 started (the unit's read of TM0CNT_L).
    .include "probe.inc"
    .arm
    .text
    .global _start

.equ OUT,     0x02008000
.equ BUF_LO,  0x02010000
.equ BUF_HI,  0x02040000
.equ BUF_A,   0x02010000
.equ BUF_B,   0x0203FFFE
.equ TM0CNTL, 0x04000100

_start:
    probe_enter
    mov r0, r9, lsr #8
    and r0, r0, #0xFF
    adr r1, configs
    add r7, r1, r0, lsl #5
    str r7, [r12, #32]             @ the configuration entry

    @ clear the buffers and the result block
    mov r1, #0
    mov r2, #0
    mov r3, #0
    mov r6, #0
    ldr r0, =BUF_LO
    ldr r7, =BUF_HI
1:  stmia r0!, {r1-r3, r6}
    cmp r0, r7
    blo 1b
    ldr r0, =OUT
    add r7, r0, #0x400
2:  stmia r0!, {r1-r3, r6}
    cmp r0, r7
    blo 2b

    ldr r7, [r12, #32]
    ldr r0, [r7, #12]
    tst r0, #0x10000               @ A is DMA3 rather than DMA1
    addeq r1, r8, #0x0C
    addne r1, r8, #0x24
    str r1, [r12, #36]             @ A's SAD
    ldr r2, =TM0CNTL
    str r2, [r1]
    ldr r3, =BUF_A
    str r3, [r1, #4]
    mov r3, #0
    str r3, [r1, #8]
    str r2, [r8, #0x18]            @ B = DMA2
    ldr r3, =BUF_B
    str r3, [r8, #0x1C]
    mov r3, #0
    str r3, [r8, #0x20]

    @ C = DMA1 when A is DMA3: a short burst ahead of A's at every H-blank,
    @ armed now (it runs through the park; fixed source and destination)
    ldr r0, [r7, #16]
    cmp r0, #0
    beq 5f
    ldr r2, =TM0CNTL
    str r2, [r8, #0x0C]
    ldr r2, [r7, #20]
    str r2, [r8, #0x10]
    str r0, [r8, #0x14]
5:
    @ DMA0, the bound: {N of the target, 0} -> target CNT_L, CNT_H
    ldr r2, [r7, #8]               @ target CNT_L address, 0 = none
    add r3, r1, #8                 @ A's CNT_L address
    cmp r2, r3
    ldreq r0, [r7, #0]
    ldrne r0, [r7, #4]
    mov r0, r0, lsl #16
    mov r0, r0, lsr #16            @ {N, 0}
    str r0, [r12, #40]
    add r0, r12, #40
    str r0, [r8]
    str r2, [r8, #4]
    cmp r2, #0
    ldrne r3, =0x92000001          @ V-blank, repeat, 16-bit, both increment
    moveq r3, #0

    ldr r0, [r7, #12]
    ldr r6, =0x00800000            @ TM0: reload 0, start
    ldr r1, =65536
    tst r0, #0x40000
    orrne r6, r6, #1               @ or reload 1 (period 65535)
    subne r1, r1, #1
    str r1, period
    and r0, r0, #0xFF
    ldr r1, [r7, #0]               @ A's CNT word
    ldr r2, [r7, #4]               @ B's
    ldr r7, [r12, #36]
    add r7, r7, #8                 @ A's CNT
    @ probe_park with the line in r0
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r5]
    mvn r0, #0
    strh r0, [r5, #2]
    swi 0x020000
    str r6, [r10]
    str r1, [r7]
    str r2, [r8, #0x20]
    str r3, [r8, #8]

    @ wait for line D of the first frame the CPU runs in after the arming
    ldr r0, [r12, #32]
    ldr r1, [r0, #12]
    and r2, r1, #0xFF
    mov r3, r1, lsr #8
    and r3, r3, #0xFF
    cmp r2, #160
    blo 4f
3:  ldrh r0, [r4, #6]
    cmp r0, #160
    bhs 3b
4:  ldrh r0, [r4, #6]
    cmp r0, r3
    blo 4b
    mov r0, #0
    str r0, [r8, #8]
    str r0, [r8, #0x14]
    str r0, [r8, #0x20]
    str r0, [r8, #0x2C]
    str r0, [r10]

    @ the timelines
    ldr r7, [r12, #32]
    ldr r2, [r7, #0]
    mov r2, r2, lsl #16
    mov r2, r2, lsr #16
    ldr r0, =BUF_A
    mov r1, #2
    ldr r3, =OUT
    stmfd sp!, {r12}
    add r12, r3, #64
    bl scan
    ldmfd sp!, {r12}
    ldr r7, [r12, #32]
    ldr r2, [r7, #4]
    mov r2, r2, lsl #16
    mov r2, r2, lsr #16
    ldr r0, =BUF_B
    mvn r1, #1                     @ -2
    ldr r3, =(OUT + 20)
    stmfd sp!, {r12}
    ldr r12, =(OUT + 448)
    bl scan
    ldmfd sp!, {r12}

    @ the same, from A's first start: nothing below depends on the anchor
    ldr r3, =OUT
    ldr r2, [r3, #8]
    ldr r0, [r3, #12]
    sub r0, r0, r2
    str r0, [r3, #40]              @ +40 A last start
    ldr r0, [r3, #16]
    sub r0, r0, r2
    str r0, [r3, #44]              @ +44 A last unit
    ldr r0, [r3, #28]
    sub r0, r0, r2
    str r0, [r3, #48]              @ +48 B first start
    ldr r0, [r3, #36]
    sub r0, r0, r2
    str r0, [r3, #52]              @ +52 B last unit
    ldr r0, [r3, #72]
    ldr r1, [r3, #68]
    sub r1, r0, r1
    str r1, [r3, #56]              @ +56 A burst 1's start less burst 0's end
    sub r0, r0, r2
    str r0, [r3, #60]              @ +60 A burst 1's start

    and r0, r9, #0xFF
    ldr r1, =OUT
    ldr r0, [r1, r0, lsl #2]
    probe_leave

@ r0 = the buffer, r1 = its step, r2 = N (0: the channel is unused),
@ r3 = the summary (5 words), r12 = the burst list (48 x (start, end))
scan:
    stmfd sp!, {r4-r11, lr}
    mov r4, #0                     @ units
    mov r5, #0                     @ bursts begun
    mov r6, #0                     @ unit index within the burst
    ldr r7, period                 @ TM0's period
    sub r7, r7, #0x10000           @ -reload: cycles since TM0 started, less the first stamp
    mvn r8, #0                     @ the previous stamp (-1: none yet)
    ldr r9, =0x18000               @ the whole buffer area, in units
    ldr r11, period
    cmp r2, #0
    beq 9f
1:  cmp r4, r9
    bhs 9f
    ldrh r10, [r0]
    cmp r10, #0                    @ a 0 is the end when the next is 0 too:
    ldreqh lr, [r0, r1]            @ stamps are 4+ cycles apart
    cmpeq lr, #0
    beq 9f
    cmp r8, #0
    addlt r7, r7, r10              @ the first: the stamp less the reload
    blt 2f
    subs lr, r10, r8
    addlt lr, lr, r11
    add r7, r7, lr
2:  mov r8, r10
    cmp r6, #0
    bne 3f
    str r7, [r3, #12]              @ a burst starts: the last start so far
    cmp r5, #0
    streq r7, [r3, #8]
    cmp r5, #48
    strlo r7, [r12, r5, lsl #3]
    add r5, r5, #1
3:  add r6, r6, #1
    cmp r6, r2
    moveq r6, #0
    str r7, [r3, #16]              @ the last unit so far
    sub lr, r5, #1
    cmp lr, #48
    addlo lr, r12, lr, lsl #3
    strlo r7, [lr, #4]
    add r4, r4, #1
    add r0, r0, r1
    b 1b
9:  str r4, [r3]
    str r5, [r3, #4]
    ldmfd sp!, {r4-r11, pc}
period:
    .word 65536
    .ltorg

@ A: DMA1 (or DMA3), 16-bit, H-blank, repeat, source fixed, destination up.
@ B: DMA2, the same with the destination down.
.equ CTL_A, 0xA3000000
.equ CTL_B, 0xA3200000
.equ K_A,   0x040000C4             @ DMA1CNT_L
.equ K_A3,  0x040000DC             @ DMA3CNT_L
.equ K_B,   0x040000D0             @ DMA2CNT_L
@ C: DMA1, H-blank, repeat, both fixed; 16- or 32-bit
.equ C16,   0xA3400000
.equ C32,   0xA7400000
.equ IWSCR, 0x03007C00             @ 1-cycle writes
.equ EWSCR, 0x02004000             @ 3 a halfword
@ \a, \b: CNT words (0: unused), \k: DMA0's target (0: no bound),
@ \l: the park line, \d: the line the CPU stops everything at,
@ \c, \cd: DMA1's CNT word and fixed destination (A must be DMA3)
.macro cfg a, b, k, l, d, flags=0, c=0, cd=0
    .word \a, \b, \k, (\l) | ((\d) << 8) | (\flags), \c, \cd, 0, 0
.endm
.equ DMA3, 0x10000
.equ RELOAD1, 0x40000                @ TM0 from reload 1 (period 65535)
    .align 2
configs:
    cfg CTL_A | 154,  0, K_A, 100, 200            @ 0: 0.5 line
    cfg CTL_A | 277,  0, K_A, 100, 200            @ 1: 0.9
    cfg CTL_A | 308,  0, K_A, 100, 200            @ 2: 1.0
    cfg CTL_A | 339,  0, K_A, 100, 200            @ 3: 1.1
    cfg CTL_A | 431,  0, K_A, 100, 200            @ 4: 1.4
    cfg CTL_A | 616,  0, K_A, 100, 200            @ 5: 2.0
    cfg CTL_A | 708,  0, K_A, 100, 200            @ 6: 2.3
    cfg CTL_A | 1078, 0, K_A, 100, 200            @ 7: 3.5
    cfg CTL_A | 10,   0, K_A, 225, 200            @ 8: armed in V-blank
    cfg CTL_A | 708,  0, K_A, 150, 200            @ 9: 2.3 across V-blank
    cfg CTL_A | 708,  0, K_A, 155, 200            @ 10
    cfg CTL_A | 339,  0, K_A, 158, 200            @ 11: 1.1, two lines
    cfg CTL_A | 431,  CTL_B | 40,  K_A, 100, 200  @ 12: B short under A long
    cfg CTL_A | 40,   CTL_B | 431, K_B, 100, 200  @ 13: A short over B long
    cfg CTL_A | 200,  CTL_B | 200, K_A, 100, 200  @ 14: 0.65 + 0.65
    cfg CTL_A | 708,  0, K_A3, 100, 200, DMA3     @ 15: 6 on DMA3
    cfg CTL_A | 305,  0, K_A, 140, 200            @ 16: about a line
    cfg CTL_A | 306,  0, K_A, 140, 200            @ 17
    cfg CTL_A | 307,  0, K_A, 140, 200            @ 18
    cfg CTL_A | 308,  0, K_A, 140, 200            @ 19
    cfg CTL_A | 309,  0, K_A, 140, 200            @ 20
    cfg CTL_A | 708,  0, 0,   100, 200            @ 21: 6 without the bound
    cfg CTL_A | 431,  0, K_A, 100, 200, RELOAD1   @ 22: 4, TM0 reloading 1
@ 23..: DMA3's burst behind DMA1's d cycles at each H-blank, x = d + 4N
@ about 1230 (A alone: x = 1228 runs every line, 1232 every other line)
    cfg CTL_A | 306,  0, K_A3, 140, 200, DMA3, C16 | 1, IWSCR  @ 23: d 2, x 1226
    cfg CTL_A | 307,  0, K_A3, 140, 200, DMA3, C16 | 1, IWSCR  @ 24: d 2, x 1230
    cfg CTL_A | 306,  0, K_A3, 140, 200, DMA3, C16 | 1, EWSCR  @ 25: d 4, x 1228
    cfg CTL_A | 307,  0, K_A3, 140, 200, DMA3, C16 | 1, EWSCR  @ 26: d 4, x 1232
    cfg CTL_A | 305,  0, K_A3, 140, 200, DMA3, C32 | 1, EWSCR  @ 27: d 7, x 1227
    cfg CTL_A | 306,  0, K_A3, 140, 200, DMA3, C32 | 1, EWSCR  @ 28: d 7, x 1231
    cfg CTL_A | 302,  0, K_A3, 140, 200, DMA3, C32 | 3, EWSCR  @ 29: d 21, x 1229
    cfg CTL_A | 301,  0, K_A3, 140, 200, DMA3, C32 | 3, EWSCR  @ 30: d 21, x 1225
@ 31..: nothing else armed (no DMA0), and few enough lines that even a burst
@ per request would be over by line 200: 60 x 1.1, 40 x 1.4, 20 x 2.3 and
@ 10 x 3.5 lines
    cfg CTL_A | 339,  0, 0,   100, 200            @ 31
    cfg CTL_A | 431,  0, 0,   120, 200            @ 32
    cfg CTL_A | 708,  0, 0,   140, 200            @ 33
    cfg CTL_A | 1078, 0, 0,   150, 200            @ 34
    probe_data
