@ prefetchdma.s — the mGBA suite's last red row, taken apart on a cartridge.
@
@ Misc "DMA Prefetch Break" expects 0x10002A94 and we report 0x100025C8:
@ iteration 2725 against 2418, 307 short. Reading the suite's own source
@ settled what the test does, and three things in it matter here.
@
@ The deficit is not a free number. A line is 1232 cycles and the loop is 36,
@ so 34.2 passes fit in a line and every constant in the emulator moves the
@ exit in whole steps of 34 passes. The reachable values lie on two ladders
@ one pass apart -- 2350 + 34k and 2351 + 34k -- and the expected 2725 is on
@ the second. Nothing that only shifts timing along the first ladder can ever
@ land on it; what picks the ladder is which loop pass of a line catches the
@ DMA's word, so the window's width and edges are the whole question.
@
@ It arms DMA3 for one 32-bit word, source and destination both fixed, on
@ H-blank, repeating, then spins a seven-instruction Thumb loop in ROM that
@ reads unmapped 0x10000000 + 4i. Open bus there is the Thumb halfword at the
@ load's own address + 4, doubled -- the `ands` in the loop, 0x40034003 --
@ and the loop's masked compare passes on that, so it spins until an H-blank
@ DMA's word lands close enough to the read that the read returns the DMA's
@ datum instead. The reported number is how many passes that took.
@
@ So it is a phase coincidence between a ROM-fetched loop and a once-a-line
@ DMA, and the three things that set it are the loop's period, what the DMA
@ costs the loop, and how wide the window is in which the DMA's word survives
@ on the bus. NONE of the three can be measured without a cartridge: the link
@ rig multiboots into EWRAM, and both the loop's fetches and the window's
@ closing edge are gamepak events.
@
@ Note what the suite does NOT do: it never writes WAITCNT. The test runs at
@ whatever is left over, which from a cold boot and after the timing suites
@ alike is 0x0000 -- four-cycle ROM accesses with the gamepak prefetch buffer
@ OFF. Every part here sweeps the wait settings anyway, but 4/2 pf-off is the
@ row that speaks to the suite.
@
@   A  the loop's period, four shapes across four wait settings
@   B  what an H-blank DMA costs a loop fetched from the cartridge, which on
@      the link rig (loop in EWRAM) is exactly 3 + 2N
@   C  the post-DMA open-bus window scanned a cycle at a time from ROM code.
@      obuswin.s and obuswint.s measured this window from EWRAM and found it
@      one cycle narrower than we model; the window is supposed to close on
@      the next gamepak fetch, which is the part EWRAM cannot test
@   D  a faithful replica of the suite's own loop and DMA, reporting the
@      break address, at sixteen entry phases
@
@ Part D already separates the two emulators before hardware is involved, and
@ not in the way the row does. dingbat spins the replica and reports a break
@ address; mGBA breaks on the FIRST pass, having read back an opcode from
@ twenty instructions earlier -- its open-bus latch in a ROM-resident Thumb
@ loop is stale where ours tracks the fetch. The loop layout was checked by
@ disassembly: `ands` (0x4003) sits exactly four bytes after the `ldmia`, in
@ the priming read and in the loop alike, so the suite's own rule says both
@ should read 0x40034003. Whichever of us is right about that, it is not a
@ matter of a delay constant, and hardware settles it in one run.
@
@ Part D is the one that matters most, because the suite's expected value has
@ a provenance problem: 0x10002A94 was written in the same commit that
@ rewrote the code it measures, with no hardware claim, and its predecessor
@ 0x10002A64 was mGBA's own number while a GBA SP reported 0x10002AF8. A
@ three-way reading of the SAME replica -- silicon, us, mGBA -- is worth more
@ than agreeing with a constant nobody has checked.
@
@ Results: 393 words at 0x02000000, the last of them the marker 0x600D0002.
@ Streamed down the link cable (linkreport.inc) so a host reads it exactly
@ rather than a camera reading it approximately, and copied into SRAM so a
@ cart that writes its save file out is a second route. prefetchdma.py builds
@ it and prints the tables; tools/hwlink/gblink.py report reads real silicon.
    .arm
    .text
    .global _start

.equ IOBASE,    0x04000000
.equ WAITCNT,   0x04000204
.equ TM0CNT_L,  0x04000100
.equ DMA3SAD,   0x040000D4
.equ IE,        0x04000200

.equ RESULTS,   0x02000000
.equ WORDS,     393
.equ MARKER,    0x600D0002

.equ IW_SRC,    0x03000000         @ the DMA's source word, 0xDEAD0000
.equ IW_DST,    0x03000200         @ the DMA's destination
.equ IW_CODE,   0x03001000         @ copy of the iwram block
.equ IW_SAMP,   0x03002000         @ scratch for part C and D

.equ ITERS,     512                @ iterations in every part A / B loop
.equ SYNCLINE,  100                @ the line parts A-C start on
.equ DLINE,     160                @ part D enters on V-blank, as the suite
                                   @ does through VBlankIntrWait

_start:
    b   main
    .space 0x9C
    .space 0x20

main:
    ldr sp, =0x03007F00

    @ The routines that have to be timed from RAM as well as from ROM are
    @ assembled once, position-independently, and copied.
    ldr r0, =iwram_code
    ldr r1, =IW_CODE
    ldr r2, =iwram_code_end
    ldr r3, =iwram_code
    sub r2, r2, r3
1:  ldr r4, [r0], #4
    str r4, [r1], #4
    subs r2, r2, #4
    bgt 1b

    @ The suite's own source word, so a part C sample either is the DMA's
    @ datum or is not, with nothing to interpret.
    ldr r0, =IW_SRC
    ldr r1, =0xDEAD0000
    str r1, [r0]
    ldr r0, =IW_DST
    mov r1, #0
    str r1, [r0]

    ldr r10, =RESULTS

    bl  part_a
    bl  part_b
    bl  part_c
    bl  part_d

    ldr r1, =MARKER
    str r1, [r10], #4

    @ Into SRAM as well, a byte at a time as that bus requires, so a cart
    @ that writes its save file out is a second way to read this.
    ldr r0, =RESULTS
    ldr r1, =0x0E000000
    ldr r2, =(WORDS * 4)
1:  ldrb r3, [r0], #1
    strb r3, [r1], #1
    subs r2, r2, #1
    bgt 1b

    @ And down the link cable, which is the route that gives exact numbers.
    @ With no cable attached no transfer ever completes and this is a spin.
    ldr r0, =RESULTS
    ldr r1, =WORDS
    bl  link_report_init
1:  bl  link_report_poll
    b   1b
    .ltorg

    .include "linkreport.inc"

@ ---------------------------------------------------------------------------
@ Part A: how long is the loop?
@
@ Four shapes at four wait settings, 16 words; divide by ITERS for the
@ period. TM0 counts cycles with TM1 cascaded off it, so a slow shape at 4/2
@ waits cannot wrap the count.
@ ---------------------------------------------------------------------------
    .align 2
part_a:
    stmfd sp!, {r4-r9, r11, lr}
    adr r11, a_subjects
a_subject:
    ldr r8, [r11]                  @ the Thumb routine, already +1
    cmp r8, #0
    beq 9f
    ldr r6, [r11, #4]              @ the address it loads from
    adr r7, a_waits
    mov r5, #4
1:  ldr r0, [r7], #4
    ldr r1, =WAITCNT
    strh r0, [r1]
    mov r1, #ITERS
    mov r2, r6
    bl  timer_start
    mov lr, pc
    bx  r8
    bl  timer_read                 @ -> r0
    str r0, [r10], #4
    subs r5, r5, #1
    bgt 1b
    add r11, r11, #8
    b   a_subject
9:  ldmfd sp!, {r4-r9, r11, pc}
    .ltorg

    .align 2
a_waits:
    .word 0x4014                   @ WS0 3/1, prefetch on
    .word 0x0014                   @ WS0 3/1, prefetch off
    .word 0x4000                   @ WS0 4/2, prefetch on
    .word 0x0000                   @ WS0 4/2, prefetch off -- the suite's own
a_subjects:
    .word shape_openbus + 1, 0x10000000     @ an unmapped load, from ROM
    .word shape_fixed + 1,   0x03000000     @ the same, loading mapped IWRAM
    .word shape_nops + 1,    0x03000000     @ no load at all: pure fetch
    .word IW_CODE + (shape_openbus - iwram_code) + 1, 0x10000000
    .word 0, 0                              @ ... the unmapped load from IWRAM

@ ---------------------------------------------------------------------------
@ Part B: what does an H-blank DMA cost a loop fetched from the cartridge?
@
@ A FIXED iteration count, so no poll quantises anything, run across whatever
@ H-blanks it crosses, with the DMA armed and then not. Two words per row:
@ elapsed cycles and scanlines crossed -- both are needed, because the line
@ count itself moves when the loop gets slower.
@
@ 28 rows, 56 words: {ROM code, IWRAM code} x {prefetch on, off} x
@ N in {0, 1, 2, 4, 8, 16, 32}. N = 0 arms no DMA at all.
@ ---------------------------------------------------------------------------
    .align 2
part_b:
    stmfd sp!, {r4-r9, r11, lr}
    adr r11, b_configs
b_config:
    ldr r9, [r11]                  @ the Thumb routine, already +1
    cmp r9, #0
    beq 9f
    ldr r0, [r11, #4]              @ WAITCNT for this config
    ldr r1, =WAITCNT
    strh r0, [r1]
    adr r7, b_counts
    mov r5, #7
1:  ldr r6, [r7], #4               @ N
    bl  sync_line
    mov r0, r6
    bl  dma_arm                    @ N = 0 leaves DMA3 disabled
    mov r4, #IOBASE
    ldrh r8, [r4, #6]              @ VCOUNT before
    mov r1, #ITERS
    ldr r2, =0x10000000
    bl  timer_start
    mov lr, pc
    bx  r9
    bl  timer_read
    mov r4, #IOBASE
    ldrh r1, [r4, #6]              @ VCOUNT after
    sub r1, r1, r8
    and r1, r1, #0xFF
    str r0, [r10], #4
    str r1, [r10], #4
    mov r0, #0
    bl  dma_arm                    @ off again
    subs r5, r5, #1
    bgt 1b
    add r11, r11, #8
    b   b_config
9:  ldmfd sp!, {r4-r9, r11, pc}
    .ltorg

    .align 2
b_counts:
    .word 0, 1, 2, 4, 8, 16, 32
b_configs:
    .word shape_openbus + 1, 0x4014         @ ROM code, prefetch on
    .word shape_openbus + 1, 0x0000         @ ROM code, 4/2 pf-off: the suite
    .word IW_CODE + (shape_openbus - iwram_code) + 1, 0x4014
    .word IW_CODE + (shape_openbus - iwram_code) + 1, 0x0000
    .word 0, 0

@ ---------------------------------------------------------------------------
@ Part C: how wide is the post-DMA open-bus window, from ROM code?
@
@ One single-word DMA -- the suite's own shape -- one sampled read of
@ 0x10000000, and a sled walking that read one cycle at a time across 32
@ consecutive cycles. Two words per trial: the timer at the moment of the
@ read, and the value it returned. The timer makes the scan self-locating, so
@ the H-blank poll's own quantisation (section 17's trap) cannot mislead:
@ whatever phase the poll lands on, the recorded cycle says which one.
@
@ 0xDEAD0000 is the transferred word. The k at which it appears and the k at
@ which it stops appearing ARE the window, to the cycle.
@
@ Three configurations, 32 sleds, three words each: 288 words.
@ ---------------------------------------------------------------------------
    .align 2
part_c:
    stmfd sp!, {r4-r9, r11, lr}
    adr r11, c_configs
c_config:
    ldr r9, [r11]                  @ the ARM probe
    cmp r9, #0
    beq 9f
    ldr r0, [r11, #4]
    ldr r1, =WAITCNT
    strh r0, [r1]
    mov r5, #0                     @ sled: cycles of delay after the flag
1:  bl  sync_line
    mov r0, #1                     @ one word, as the suite arms it
    bl  dma_arm
    bl  timer_start
    mov r4, #IOBASE
    ldr r6, =TM0CNT_L
    ldr r3, =IW_SAMP
    mov r2, #0x10000000
    mov r0, r5
    mov lr, pc
    bx  r9
    mov r0, #0
    bl  dma_arm
    ldr r0, =IW_SAMP
    ldr r1, [r0]                   @ the cycle it was read at, then the two
    str r1, [r10], #4              @ consecutive words it read
    ldr r1, [r0, #4]
    str r1, [r10], #4
    ldr r1, [r0, #8]
    str r1, [r10], #4
    add r5, r5, #1
    cmp r5, #32
    blt 1b
    add r11, r11, #8
    b   c_config
9:  ldmfd sp!, {r4-r9, r11, pc}
    .ltorg

    .align 2
c_configs:
    .word c_probe, 0x0000                   @ ROM code at the suite's waits
    .word c_probe, 0x4014                   @ ROM code, prefetch on
    .word IW_CODE + (c_probe - iwram_code), 0x0000  @ IWRAM: the control the
    .word 0, 0                              @ link rig already measured

@ ---------------------------------------------------------------------------
@ Part D: the suite's own experiment, replicated.
@
@ The same DMA3 control word the suite writes (0xA7400001: enable, H-blank,
@ repeat, 32-bit, source and destination both fixed, one transfer), the same
@ seven-instruction Thumb loop in ROM, the same mask and target. It reports
@ the break address, which is what the row reports.
@
@ It will NOT be 0x10002A94: that constant is specific to the suite build's
@ own code addresses and alignment. That is the point. What matters is the
@ SAME replica read three times -- on silicon, here, and in mGBA -- because
@ the suite's constant has never been checked against hardware for the build
@ we run, and the one time its predecessor was checked, silicon disagreed
@ with it and with mGBA alike.
@
@ Sixteen entry phases, because the suite enters through VBlankIntrWait and
@ we should know how much of the answer is the entry rather than the machine.
@ If the break address is stable across all sixteen, the number means
@ something; if it scatters, no emulator can be graded on it at all.
@
@ Two words per trial: the break address and the word that broke it. 32.
@ ---------------------------------------------------------------------------
    .align 2
part_d:
    stmfd sp!, {r4-r9, r11, lr}
    ldr r0, =WAITCNT
    mov r1, #0                     @ exactly what the suite runs at
    strh r1, [r0]
    mov r5, #0
1:  mov r0, #DLINE
    bl  sync_at
    mov r0, #1
    bl  dma_arm
    ldr r3, =IW_SAMP
    mov r0, r5                     @ entry phase, 0..15 cycles
    ldr r9, =d_replica + 1
    mov lr, pc
    bx  r9
    mov r0, #0
    bl  dma_arm
    ldr r0, =IW_SAMP
    ldr r1, [r0]
    str r1, [r10], #4
    ldr r1, [r0, #4]
    str r1, [r10], #4
    add r5, r5, #1
    cmp r5, #16
    blt 1b
    ldmfd sp!, {r4-r9, r11, pc}
    .ltorg

@ ---------------------------------------------------------------------------
@ Helpers
@ ---------------------------------------------------------------------------

@ Enter the top of a chosen line exactly, by halting on its V-count match.
@ IME stays off, so no handler runs and the vector is never needed; HALT
@ still exits on IE & IF. Proven on this rig, docs/playtest-bugs.md 18.
@ r0 = the line.
    .align 2
sync_at:
    stmfd sp!, {r4, lr}
    mov r4, #IOBASE
    ldr r1, =IE
    mov r2, #0
    strh r2, [r1, #8]              @ IME off
    mov r0, r0, lsl #8
    orr r0, r0, #0x20              @ V-count match interrupt on that line
    strh r0, [r4, #4]
    mov r0, #0x04
    strh r0, [r1]                  @ IE = V-count match only
    mvn r0, #0
    strh r0, [r1, #2]              @ IF: clear everything
    swi 0x020000
    ldr r1, =IE
    mov r0, #0
    strh r0, [r1]                  @ IE off again
    mvn r0, #0
    strh r0, [r1, #2]
    mov r4, #IOBASE
    mov r0, #0                     @ DISPSTAT: no LYC, no interrupt enables
    strh r0, [r4, #4]
    ldmfd sp!, {r4, pc}
    .ltorg

    .align 2
sync_line:
    stmfd sp!, {lr}
    mov r0, #SYNCLINE
    bl  sync_at
    ldmfd sp!, {pc}

@ r0 = transfer count, 0 to disable. The suite's own control word, with the
@ count filled in: 32-bit, H-blank, repeating, source and destination fixed.
    .align 2
dma_arm:
    stmfd sp!, {lr}
    ldr r1, =DMA3SAD
    mov r2, #0
    str r2, [r1, #8]               @ off first
    cmp r0, #0
    beq 9f
    ldr r2, =IW_SRC
    str r2, [r1]
    ldr r2, =IW_DST
    str r2, [r1, #4]
    ldr r2, =0xA7400000
    orr r2, r2, r0
    str r2, [r1, #8]
9:  ldmfd sp!, {pc}
    .ltorg

@ TM0 counts cycles, TM1 counts TM0's overflows, so the pair is 32 bits.
@ Preserves r1 and r2, which carry the timed routine's arguments.
    .align 2
timer_start:
    ldr r3, =TM0CNT_L
    mov r0, #0
    strh r0, [r3, #2]              @ both off
    strh r0, [r3, #6]
    strh r0, [r3]                  @ both reload 0
    strh r0, [r3, #4]
    mov r0, #0x84                  @ TM1: enable, count-up from TM0
    strh r0, [r3, #6]
    mov r0, #0x80                  @ TM0: enable, prescaler 1
    strh r0, [r3, #2]
    bx  lr
    .ltorg

    .align 2
timer_read:
    ldr r3, =TM0CNT_L
    ldrh r0, [r3]
    ldrh r1, [r3, #4]
    mov r2, #0
    strh r2, [r3, #2]
    strh r2, [r3, #6]
    orr r0, r0, r1, lsl #16
    bx  lr
    .ltorg

@ ---------------------------------------------------------------------------
@ The suite's loop, replicated. Thumb, in ROM, sixteen-byte aligned as the
@ compiler left it, and -- this is the part that has to be exact -- with the
@ `ands` sitting four bytes after the load, because open bus IS that opcode
@ doubled and the loop's compare is what that opcode happens to satisfy.
@
@ r0 = entry phase in cycles (0..15), r3 = where the two results go.
@ ---------------------------------------------------------------------------
    .align 2
d_replica:
    .thumb
    push {r4-r7, lr}
    cmp r0, #0                     @ shift the entry phase: a few cycles per
    beq 5f                         @ step, which is all a sensitivity scan
4:  sub r0, #1                     @ needs -- the question is whether the
    bne 4b                         @ break address moves at all, not by how
5:                                 @ much per cycle
    ldr r0, =0xFFC0FFC0            @ the suite's mask
    ldr r2, =0x10000000            @ the moving pointer
    ldr r5, =0x10020000            @ the sentinel: 0x8000 passes at most
    ldr r4, =IW_SAMP
    @ The suite compares against the literal 0x40004000, which is its own
    @ `ands` opcode doubled and masked -- open bus in that loop is the Thumb
    @ halfword at the load's address + 4. Taking the baseline from a priming
    @ read instead comes to the same thing when a machine composes open bus
    @ that way, and unlike a literal it cannot make the loop break on pass one
    @ on a machine that composes it differently. What is counted either way is
    @ passes until the bus value CHANGES, which is what the row reports.
    @
    @ The priming read has the same ldmia / str / and shape as the loop, so
    @ its own load+4 is an `and` too and it sees what the loop will see.
    ldmia r2!, {r3}
    str r3, [r4, #4]
    and r3, r0
    mov r1, r3                     @ the baseline
    ldr r2, =0x10000000            @ rewind: the count starts at the loop

    .align 4
1:  cmp r2, r5
    beq 2f
3:  ldmia r2!, {r3}
    str r3, [r4, #4]
    and r3, r0                     @ this opcode is 0x4003, and on a machine
                                   @ that composes open bus the way the suite
                                   @ assumes, r3 is 0x40004000 every pass
    cmp r3, r1
    beq 1b
2:  str r2, [r4, #0]               @ out[0] = the break address, as the suite
    pop {r4-r7}                    @ reports it; out[1] is the word that broke
    pop {r3}                       @ NOT `pop {pc}`: on ARMv4T that does not
    bx  r3                         @ interwork, and the caller is ARM
    .align 2
    .ltorg
    .arm

@ ---------------------------------------------------------------------------
@ The timed shapes, and part C's probe. Assembled inside the iwram block so
@ the very same bytes can run from ROM and from IWRAM; nothing here may use a
@ literal pool. Arguments in r1 (iterations) and r2 (load address); they
@ touch nothing above r3, so the ARM caller's registers survive.
@ ---------------------------------------------------------------------------
    .align 2
iwram_code:
    .thumb
shape_openbus:                     @ load, step the pointer, count down
1:  ldr r0, [r2]
    add r2, #4
    sub r1, #1
    bne 1b
    bx  lr

    .align 2
shape_fixed:                       @ the same, loading one mapped address
1:  ldr r0, [r2]
    add r3, #4
    sub r1, #1
    bne 1b
    bx  lr

    .align 2
shape_nops:                        @ no load: what the fetch alone costs
1:  mov r0, r0
    add r3, #4
    sub r1, #1
    bne 1b
    bx  lr

    .arm
@ r2 = 0x10000000, r3 = where the two samples go, r0 = cycles of delay after
@ the H-blank flag (0..31), r4 = IOBASE, r6 = TM0CNT_L.
    .align 2
c_probe:
    stmfd sp!, {r5-r7, lr}
1:  ldrh r1, [r4, #4]              @ wait out an H-blank we may be inside
    tst r1, #2
    bne 1b
2:  ldrh r1, [r4, #4]              @ then take the next one from its start
    tst r1, #2
    beq 2b
    rsb r0, r0, #31
    add pc, pc, r0, lsl #2
    mov r0, r0                     @ pc reads +8, so this word is skipped
    .rept 32
    mov r0, r0
    .endr
    ldr r5, [r2]                   @ the sampled read ...
    ldr r1, [r2]                   @ ... and the one straight after it, since
    ldrh r7, [r6]                  @ the window may be "the NEXT access", and
    str r7, [r3], #4               @ a single sample cannot tell the two apart
    str r5, [r3], #4
    str r1, [r3], #4
    ldmfd sp!, {r5-r7, pc}
iwram_code_end:
