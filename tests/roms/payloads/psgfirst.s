@ payload: whose first trigger dies after a PSG master-on?
@
@ This is gbaedge slot 51 (PSGFIRST), re-hosted as a link-cable payload. Rows,
@ macros and byte layout are the probe page's, unchanged.
@
@ It was already run on the console from a cartridge (docs/hwprobe-results-agb.md
@ session 6, transcribed in tests/roms/expected/agb-sp-6.txt), so it is not
@ here for its own answer -- it is the baseline that makes psgwhy.s readable.
@ Every row's poll count depends on the gap between the two stores that set a
@ channel up and trigger it, and that gap is not the same when the code runs
@ from RAM as when it runs from a cartridge at its wait states. Running this
@ page both ways pins the difference down, so that if psgwhy's +0 row
@ disagrees with the photographed column we can tell a model difference from a
@ code-region difference.
@
@ +0  (h) ch1 counter 16, the first trigger after a master off/on
@ +2  (h) ch2 counter 16, the first trigger after a master off/on
@ +4  (h) ch3 counter 16, the first trigger after a master off/on
@ +6  (h) ch4 counter 16, the first trigger after a master off/on
@ +8  (h) ch1 as +0 with NR10 written 0 (sweep off, the reset state)
@ +10 (h) ch1 as +0 with NR10 = 0x11 (sweep period 1, shift 1: unit active)
@ +12 (h) ch1 triggered SECOND, after a ch2 trigger took the first slot
@ +14 (h) that ch2 trigger's own count
@ +16 (h) ch1's second trigger, its own first one discarded
@ +18 (h) ch1 again with no master toggle at all in front of it
@ +20 (b) SOUNDCNT_X on entry, as whatever ran before us left it
@ +21/+22/+23 (b,b,b) SOUNDCNT_X read immediately after the +0, +2, +6 triggers
@ +24 (h) ch1's first trigger with the length counter DISABLED
@ +26 (h) ch2's first trigger with the length counter DISABLED
@ +28 (h) rows that hit the poll cap; a capped row itself reads FFFF
@ +31 (b) marker 51
    .arm
    .text
    .global _start

.equ IOBASE,  0x04000000
.equ RESULTS, 0x02008000

@ r4 = IOBASE, r9 = poll-cap hits.  r0 = the NRx1/NRx2 halfword, r1 = the
@ trigger halfword -> r3 = poll iterations, r6 = SOUNDCNT_X after the trigger
.macro pf_wait ctl, trig, bit
    strh r0, [r4, #\ctl]
    strh r1, [r4, #\trig]
    ldrh r6, [r4, #0x84]
    ldr r2, =0x00060000
    mov r3, #0
1:  ldrh r0, [r4, #0x84]
    tst r0, #\bit
    beq 2f
    add r3, r3, #1
    subs r2, r2, #1
    bne 1b
    add r9, r9, #1
    mvn r3, #0                     @ never expired: 0xFFFF, not a truncated
                                   @ 0x60000 that would read as "died at once"
2:
.endm

@ master off (which clears every PSG register) then on, and the mixer set up
@ for all four channels
.macro pf_reset
    mov r0, #0
    strh r0, [r4, #0x84]
    mov r0, #0x80
    strh r0, [r4, #0x84]
    ldr r0, =0xFF77                @ all four channels, both sides, full
    strh r0, [r4, #0x80]
    mov r0, #2
    strh r0, [r4, #0x82]           @ PSG ratio 100 %
.endm

@ ch3 needs its DAC on and a non-zero wave before it will play at all
.macro pf_wave
    mov r0, #0x80
    strh r0, [r4, #0x70]           @ NR30: DAC on, bank 0
    ldr r0, =0x04000090
    mvn r1, #0
    str r1, [r0, #0]
    str r1, [r0, #4]
    str r1, [r0, #8]
    str r1, [r0, #12]
.endm

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r8, =RESULTS               @ EWRAM boots as noise; clear the slot
    mov r0, #0
    mov r1, #0
    mov r2, #0
    mov r3, #0
    stmia r8, {r0-r3}
    add r12, r8, #16
    stmia r12, {r0-r3}
    mov r4, #IOBASE
    mov r9, #0                     @ poll-cap hits
    ldrh r10, [r4, #0x84]          @ before this page writes it

    @ -- the first trigger after a master-on, one channel at a time --
    pf_reset
    ldr r0, =0xF0B0                @ envelope 15, duty 2, counter 16
    ldr r1, =0xC400                @ trigger + length enable
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #0]
    strb r6, [r8, #21]

    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x68, 0x6C, 2
    strh r3, [r8, #2]
    strb r6, [r8, #22]

    pf_reset
    pf_wave
    ldr r0, =0x20F0                @ NR32 volume 100 %, NR31 counter 16
    ldr r1, =0xC000                @ trigger + length enable
    pf_wait 0x72, 0x74, 4
    strh r3, [r8, #4]

    pf_reset
    ldr r0, =0xF030                @ NR42 envelope 15, NR41 counter 16
    ldr r1, =0xC000                @ NR44 trigger + length enable, NR43 = 0
    pf_wait 0x78, 0x7C, 8
    strh r3, [r8, #6]
    strb r6, [r8, #23]

    @ -- ch1's sweep unit idle vs running --
    pf_reset
    mov r0, #0
    strh r0, [r4, #0x60]           @ NR10: no sweep (also the reset state)
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #8]

    pf_reset
    mov r0, #0x11                  @ NR10: period 1, shift 1 -- unit running
    strh r0, [r4, #0x60]
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #10]

    @ -- is it ch1, or is it whoever goes first? --
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x68, 0x6C, 2          @ ch2 takes the first slot ...
    strh r3, [r8, #14]
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1          @ ... so ch1 is only the second trigger
    strh r3, [r8, #12]

    @ -- ch1's own second trigger, and ch1 with no master toggle --
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1          @ discarded
    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #16]

    ldr r0, =0xF0B0
    ldr r1, =0xC400
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #18]

    @ -- the same two first triggers with the length counter disabled --
    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0x8000                @ trigger, length enable CLEAR
    pf_wait 0x62, 0x64, 1
    strh r3, [r8, #24]

    pf_reset
    ldr r0, =0xF0B0
    ldr r1, =0x8000
    pf_wait 0x68, 0x6C, 2
    strh r3, [r8, #26]

    strb r10, [r8, #20]            @ SOUNDCNT_X as we found it
    strh r9, [r8, #28]
    mov r0, #51
    strb r0, [r8, #31]
    mov r0, #0
    strh r0, [r4, #0x84]           @ leave the PSG off behind us
    ldr r0, =0x50534631            @ 'PSF1': the payload ran to the end
    ldmfd sp!, {r4-r11, lr}
    bx  lr
    .ltorg
