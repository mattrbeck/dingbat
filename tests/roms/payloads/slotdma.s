@ payload: land an H-blank DMA inside code FETCHED FROM THE GAMEPAK REGION,
@ one cycle at a time, with no cartridge
@
@ slotexec.s executes one opcode out of an empty slot and lets the floating
@ 0xFFFF -- the Thumb BL suffix -- branch home. The suffix jumps to lr + 0xFFE
@ and leaves lr = its own address + 2, so with lr aimed back INTO the slot
@ the excursion chains: every hop is one nonsequential fetch of addr >> 1, a
@ sequential fetch of 0xFFFF, and a branch, and the hop after next lands
@ 0x1002 further on, where the opcode is 0x801 greater. Two interleaved
@ families walk through harmless encodings until the second reaches `bx r6`:
@
@   A  2000 mov r0,#0   2801 cmp r0,#1   3002 add r0,#2   3803 sub r0,#3
@      4004 and r4,r0
@   B  272C mov r7,#44  2F2D cmp r7,#45  372E add r7,#46  3F2F sub r7,#47
@      4730 bx r6
@
@ That is about 130 cycles of continuous gamepak-region opcode fetching at
@ the WAITCNT in force, in the repeating shape N S S S -- long enough to put
@ an H-blank DMA anywhere inside it. Which is the one thing about the mGBA
@ suite's `DMA Prefetch Break` that nothing had been able to measure: what a
@ DMA costs a loop fetched from ROM, and when it is granted against a
@ gamepak fetch in flight.
@
@ Entry is the halthb.s shape: halt on a V-count match with IME clear, wake on
@ a cycle the PPU chose, start TM0 and TM1 two instructions apart, arm DMA0
@ for H-blank with TM1CNT_H as its destination so the DMA's own write freezes
@ TM1. A fixed delay and a k-NOP sled then slide the excursion across the
@ H-blank a cycle at a time.
@
@ r0 = base k (bits 0..7), | 0x100 for the control: the same walk with the
@ excursion replaced by 130 cycles of IWRAM NOPs; | 0x200 for no DMA at all;
@ bits 16..31 = WAITCNT -- but ONLY 0 is safe: at other first-access waits the
@ empty slot's float is unreliable and the console has been lost to it twice.
@ 14 trials, k = base .. base + 13, 16 bytes each at 0x02008000:
@   +0 (h) T  TM0 at the landing pad        +2 (h) D  TM1 as the DMA froze it
@   +4 (h) TM1CNT_H at the pad (bit 7 clear = the DMA had fired)
@   +8 (w) r0 at the pad (0xFFFFFFFF = family A ran as written); for a single
@          hop, r3 -- what the opcode loaded
@   +12 (w) lr at the pad
@ T = 0xFFFF: the watchdog fired.
    .arm
    .text
    .global _start
.equ RESULTS, 0x02008000
.equ HPZERO,  0x03006100
.equ LINE,    40
.equ DELAY,   215
.equ A0,      0x08004000
.equ B0,      0x08004E58

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str sp, [r12]
    str r0, [r12, #8]
    ldr r4, =0x04000200
    ldrh r1, [r4, #8]
    str r1, [r12, #12]             @ IME
    ldrh r1, [r4]
    str r1, [r12, #16]             @ IE
    ldrh r1, [r4, #4]
    str r1, [r12, #20]             @ WAITCNT
    ldr r1, =0x03007FFC
    ldr r2, [r1]
    str r2, [r12, #24]             @ the IRQ vector
    mov r3, #0x04000000
    ldrh r2, [r3, #4]
    str r2, [r12, #28]             @ DISPSTAT
    mov r2, #0
    strh r2, [r4, #8]
    adr r2, watchdog
    str r2, [r1]
    mov r2, r0, lsr #16
    strh r2, [r4, #4]              @ WAITCNT under test
    ldr r1, =HPZERO
    mov r2, #0
    str r2, [r1]
    str r2, [r12, #4]              @ trial index

next:
    ldr r12, =vars
    ldr r6, [r12, #4]
    cmp r6, #14
    bge done
    mov r4, #0x04000000
    add r2, r4, #0x200
    ldr r10, =0x04000100
    ldr r11, =0x04000104
    ldr r9, =0x040000B0
    mov r1, #0
    strh r1, [r2, #8]              @ IME off: HALT still wakes on IE & IF
    str r1, [r9, #8]               @ DMA0 off
    str r1, [r10]
    str r1, [r11]
    str r1, [r10, #12]             @ TM3 off
    ldr r1, =0x00C3F800            @ TM3: 2048 x 1024 cycles, IRQ -- the watchdog
    str r1, [r10, #12]
    ldr r1, =HPZERO
    str r1, [r9]
    ldr r1, =0x04000106
    str r1, [r9, #4]

    ldr r7, [r12, #8]
    and r1, r7, #0xFF
    add r6, r6, r1                 @ k
    ldr r5, =0x00800000
    ldr r8, =0xA1400001
    tst r7, #0x200                 @ | 0x200: the same write with the enable
    bicne r8, r8, #0x80000000      @ bit clear -- the no-DMA baseline

    mov r0, #LINE
    mov r0, r0, lsl #8
    orr r0, r0, #0x20
    strh r0, [r4, #4]              @ DISPSTAT: match on LINE, and its interrupt
    mov r0, #0x44                  @ IE = V-count match, and the watchdog
    strh r0, [r2]
    mvn r0, #0
    strh r0, [r2, #2]
    swi 0x020000                   @ HALT, through the BIOS (section 18)
    add r2, r4, #0x200             @ the SWI clobbers r0-r3

    str r5, [r10]                  @ TM0: the clock
    str r5, [r11]                  @ TM1: the same clock, a fixed skew behind
    str r8, [r9, #8]               @ arm the H-blank DMA for this line
    mov r0, #0x40
    strh r0, [r2]                  @ IE = watchdog only, so that ...
    mov r0, #1
    strh r0, [r2, #8]              @ ... IME can come back on

    mov r0, #DELAY
    and r1, r7, #0xF000            @ bits 12..15: four more cycles of delay each,
    add r0, r0, r1, lsr #12        @ for an excursion shorter than the chain
1:  subs r0, r0, #1
    bne 1b

    ldr r3, =(sled_end + 1)
    sub r3, r3, r6, lsl #1         @ k NOPs, then the way in
    and r1, r7, #0xC00             @ bits 10..11: which excursion
    adr r0, hops
    add r0, r0, r1, lsr #6         @ 16 bytes a row
    ldr r12, [r0]
    ldr lr, [r0, #4]
    ldr r2, [r0, #8]
    tst r7, #0x100
    ldrne r12, =(control + 1)
    ldr r5, =(land + 1)
    mov r6, r5                     @ a hop landing short turns bx r6 into bx r5
    mov r0, #0
    bx r3

@ entry, lr, r2. Rows 1..3 are single hops: one opcode, and the float goes
@ straight to the pad. Row 2 is the Break row's own instruction, and what it
@ READ comes back in place of r0.
hops:
    .word A0 + 1, B0 - 0xFFE, 0, 0                   @ 0 the chain
    .word 0x0800D027, land - 0xFFE, HPZERO, 0        @ 1 6813 ldr r3,[r2] IWRAM
    .word 0x08019411, land - 0xFFE, 0x10000000, 0    @ 2 CA08 ldmia r2!,{r3} unmapped
    .word 0x08004401, land - 0xFFE, 0, 0             @ 3 2200 mov r2,#0 (clear of A4:
                                                     @   the emulators' image cannot
                                                     @   float a planted halfword)

    .thumb
    .rept 48
    mov r8, r8
    .endr
sled_end:
    bx r12

    .align 2
control:                           @ the excursion's length, spent in IWRAM
    .rept 128
    mov r8, r8
    .endr
    mvn r0, r0                     @ r0 = 0xFFFFFFFF, as family A leaves it
    bx r6

    .align 2
land:
    bx pc                          @ on a word boundary, or silicon hangs
    nop
    .arm
    ldrh r1, [r10]                 @ T
    ldrh r2, [r11]                 @ D, if the DMA has frozen it
    mov r4, r3                     @ a single hop's load, before r3 is reused
    ldrh r3, [r11, #2]
    mov r8, lr
    ldr r12, =vars
    ldr r9, [r12, #8]
    tst r9, #0xC00
    moveq r9, r0                   @ the chain reports r0,
    movne r9, r4                   @ a single hop what its opcode loaded

    ldr r5, [r12, #4]
store:
    ldr r4, =RESULTS
    add r4, r4, r5, lsl #4
    strh r1, [r4]
    strh r2, [r4, #2]
    str r3, [r4, #4]
    str r9, [r4, #8]
    str r8, [r4, #12]
    add r5, r5, #1
    str r5, [r12, #4]
    ldr r9, =0x040000B0
    mov r1, #0
    str r1, [r9, #8]               @ DMA0 off before the next line's H-blank
    b next

watchdog:                          @ IRQ mode, called by the BIOS
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr sp, =0x03007FA0            @ drop the BIOS's frame
    msr cpsr_c, #0x1F              @ system mode, ARM
    ldr r12, =vars
    ldr sp, [r12]
    ldr r5, [r12, #4]
    ldr r1, =0xFFFF
    mov r2, r1
    mov r3, r1
    mov r8, #0
    mov r9, #0
    b store

done:
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    ldr r7, =0x04000100
    str r1, [r7]
    str r1, [r7, #4]
    str r1, [r7, #12]
    ldr r9, =0x040000B0
    str r1, [r9, #8]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, [r12, #24]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #28]
    mov r3, #0x04000000
    strh r1, [r3, #4]
    ldr r1, [r12, #20]
    strh r1, [r4, #4]
    ldr r1, [r12, #16]
    strh r1, [r4]
    ldr r1, [r12, #12]
    strh r1, [r4, #8]
    ldr sp, [r12]
    ldr r0, =0x534C444D            @ 'SLDM'
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

vars:
    .space 32

@ Every address the excursion fetches nonsequentially; the opcode is A >> 1.
@ tools/hwlink/slotexec.py plants these in the emulators' cartridge image.
table:
    .word 0x08004000, 0   @ A0 2000
    .word 0x08004E58, 0   @ B0 272C
    .word 0x08005002, 0   @ A1 2801
    .word 0x08005E5A, 0   @ B1 2F2D
    .word 0x08006004, 0   @ A2 3002
    .word 0x08006E5C, 0   @ B2 372E
    .word 0x08007006, 0   @ A3 3803
    .word 0x08007E5E, 0   @ B3 3F2F
    .word 0x08008008, 0   @ A4 4004
    .word 0x08008E60, 0   @ B4 4730
    .word 0x0800D026, 0   @ hop 1
    .word 0x08019410, 0   @ hop 2
    .word 0x08004400, 0   @ hop 3 (not 0x08008516: its float is unreliable)
