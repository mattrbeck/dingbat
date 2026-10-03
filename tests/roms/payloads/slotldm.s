@ slotldm.s -- slotbranch.s's home trial for Thumb `ldmia r2!, {...}` of 2
@ to 6 registers from IWRAM, EWRAM and VRAM, fetched from the empty slot
@ (WAITCNT 0x4000), each at k = 0..3 one-cycle steps of an ARM sled before
@ the trial (r11 = the row's last word):
@     python3 tools/hwlink/slotbranch.py --tally --source=tests/roms/payloads/slotldm.s
@
@ AGB SP, 2026-10-02, 3 runs x 2 passes x 4 k = 24 trials a row: 2-register
@ rows always dingbat's (19 / 29 / 21); 3 to 6 registers read dingbat's
@ value or 2 more, from trial to trial, in proportions that differ by row
@ (3 regs IWRAM 1 / 24 high, 6 regs IWRAM 23 / 24, 6 regs VRAM 0 / 24) and
@ do not follow the sled. The same ldm from IWRAM code (ldmvar.s) is
@ fixed in every region. Not a law: no rule found, the slot is empty.
@
@ slotbranch.s's notes, which this keeps:
@ payload: a load fetched from the gamepak, then a branch whose target is
@ also in the gamepak -- does the branch wait for a committed prefetch?
@
@ slotexec.s's trick (an empty slot answers a nonsequential halfword read
@ with addr >> 1 and a sequential one with 0xFFFF, the Thumb BL suffix), with
@ the suffix aimed at a second hop INSIDE the slot instead of home: the
@ opcode at 0x08008E60 is 0x4730, `bx r6`, and r6 is the landing pad. So a
@ trial is
@
@     bx A          -> A: (A >> 1), a load: its own fetch, data, I cycle;
@                      the prefetcher reads A+4, A+6, ... meanwhile
@     A+2: 0xFFFF   -> BL suffix, a branch: first fetch (from the buffer
@                      if the load gave the prefetcher time), then a
@                      NONSEQUENTIAL gamepak fetch of 0x08008E60
@     0x08008E60    -> bx r6, home
@
@ and the same trial with the suffix aimed straight home (lr = land - 0xFFE)
@ is its control: the difference is what the gamepak branch target costs.
@ dingbat says that difference is one cycle more whenever the branch's
@ nonsequential fetch starts in the final cycle of a halfword the prefetcher
@ has started (it has "committed" and the bus is not free until it lands);
@ with S = 3 cycles (WAITCNT 0x4000) that is a load whose data + internal
@ cycles d satisfy d mod 3 == 1, and never for d < 3. mGBA charges no such
@ cycle. Final Fight One's LZ decompressor pays it on every other byte at
@ WAITCNT 0x4314 (docs/playtest-bugs.md, "Final Fight One").
@
@ Display is forced blank for the trials, so palette/VRAM loads see no
@ renderer contention (DISPCNT is restored afterwards).
@
@ r0 on entry = the WAITCNT value to run under. 0x4000 is the only
@ prefetch-on setting known safe on an empty slot (docs/playtest-bugs.md
@ section 22).
@ +0 + 8*i (h) TM0 at the landing pad for trial i, 0xFFFF = watchdog fired
@    +2     (h) 0
@    +4     (w) lr at the pad = (hop 1's suffix address + 2) | 1
@ then the whole table again (every trial is run twice; they must agree)
    .arm
    .text
    .global _start
.equ RESULTS, 0x02008000
.equ SCRATCH, 0x03006000
.equ NTRIALS, 60
.equ HOP2,    0x08008E60          @ 0x4730: bx r6
.equ VIA_ROM, (HOP2 - 0xFFE)
.equ HOME,    0                   @ table marker: lr = land - 0xFFE

_start:
    stmfd sp!, {r4-r11, lr}
    ldr r12, =vars
    str sp, [r12]                  @ the watchdog unwinds to here
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
    ldrh r2, [r3]
    str r2, [r12, #28]             @ DISPCNT
    orr r2, r2, #0x80
    strh r2, [r3]                  @ forced blank: no renderer contention
    mov r2, #0
    strh r2, [r4, #8]
    adr r2, watchdog
    str r2, [r1]
    mov r2, #0x40                  @ IE: timer 3 only
    strh r2, [r4]
    strh r0, [r4, #4]              @ WAITCNT under test
    mov r0, #0
    str r0, [r12, #4]              @ trial index

next:
    ldr r12, =vars
    ldr r6, [r12, #4]
    cmp r6, #(NTRIALS * 2)
    bge done
    ldr r4, =0x04000200
    mvn r1, #0
    strh r1, [r4, #2]              @ IF clear
    ldr r7, =0x04000100
    mov r1, #0
    str r1, [r7]                   @ TM0 off, reload 0
    str r1, [r7, #12]              @ TM3 off
    ldr r1, =0x00C3FF00            @ TM3: 256 x 1024 cycles, IRQ, enable
    str r1, [r7, #12]
    mov r1, #1
    strh r1, [r4, #8]              @ IME on: the watchdog is armed

    cmp r6, #NTRIALS
    subge r6, r6, #NTRIALS
    adr r8, table
    add r8, r8, r6, lsl #4
    add r8, r8, r6, lsl #2         @ 20 bytes a row
    ldr r12, [r8]                  @ A
    orr r12, r12, #1
    ldr r2, [r8, #4]               @ load base
    ldr r9, [r8, #8]               @ lr for hop 1's suffix (HOME: the pad)
    ldr r10, [r8, #12]             @ r3
    ldr r11, [r8, #16]             @ sled: k + 1 cycles before the trial
    ldr r5, =(land - 0xFFE)
    cmp r9, #HOME
    moveq r9, r5
    rsb r11, r11, #15
    add pc, pc, r11, lsl #2
    mov r0, r0
    .rept 16
    mov r0, r0
    .endr
    ldr r0, =0xFFC0FFC0
    ldr r1, =0x40004000
    mov r3, r10
    adr r4, land
    orr r4, r4, #1                 @ r4 = r5 = r6 = the pad: a hop landing a
    mov r5, r4                     @ few halfwords short of 0x08008E60 reads
    mov r8, r4                     @ bx r4 / bx r5 there and still comes home
    mov r6, #0x80
    adr r10, go
    orr r10, r10, #1
    bx r10

    .thumb
go: mov lr, r9
    strh r6, [r7, #2]              @ TM0 starts
    mov r6, r8
    bx r12
    .align 2
land:
    ldrh r6, [r7]
    mov r8, lr                     @ hop 1's suffix address + 2, | 1
    bx pc                          @ MUST sit on a word boundary: silicon does
    nop                            @ not forgive a misaligned one (it hung)
    .arm
    ldr r12, =vars
    mov r9, #0
    ldr r5, [r12, #4]
store:
    ldr r1, =RESULTS
    add r1, r1, r5, lsl #3
    strh r6, [r1]
    strh r9, [r1, #2]
    str r8, [r1, #4]
    add r5, r5, #1
    str r5, [r12, #4]
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
    ldr r6, =0xFFFF
    mov r9, r6
    mov r8, #0
    b store

done:
    ldr r4, =0x04000200
    mov r1, #0
    strh r1, [r4, #8]
    ldr r7, =0x04000100
    str r1, [r7]
    str r1, [r7, #12]
    mvn r1, #0
    strh r1, [r4, #2]
    ldr r1, [r12, #24]
    ldr r2, =0x03007FFC
    str r1, [r2]
    ldr r1, [r12, #20]
    strh r1, [r4, #4]
    ldr r1, [r12, #16]
    strh r1, [r4]
    ldr r1, [r12, #12]
    strh r1, [r4, #8]
    ldr r1, [r12, #28]
    mov r2, #0x04000000
    strh r1, [r2]                  @ DISPCNT back
    ldr sp, [r12]
    ldr r0, =0x534C4252            @ 'SLBR'
    ldmfd sp!, {r4-r11, lr}
    bx lr
    .ltorg

vars:
    .space 32

@ A, load base, suffix lr (HOME or VIA_ROM), r3, 0. The opcode is A >> 1,
@ so the comment IS the address. d = the load's data + internal cycles.
@ Pairs: the same hop home, then via the gamepak branch target.
table:
    .word 0x08019412, SCRATCH, HOME, 0, 0   @ CA09 ldmia r2!, 2 regs IWRAM k=0
    .word 0x08019412, 0x02010000, HOME, 0, 0   @ CA09 ldmia r2!, 2 regs EWRAM k=0
    .word 0x08019412, 0x06010000, HOME, 0, 0   @ CA09 ldmia r2!, 2 regs VRAM k=0
    .word 0x08019416, SCRATCH, HOME, 0, 0   @ CA0B ldmia r2!, 3 regs IWRAM k=0
    .word 0x08019416, 0x02010000, HOME, 0, 0   @ CA0B ldmia r2!, 3 regs EWRAM k=0
    .word 0x08019416, 0x06010000, HOME, 0, 0   @ CA0B ldmia r2!, 3 regs VRAM k=0
    .word 0x08019436, SCRATCH, HOME, 0, 0   @ CA1B ldmia r2!, 4 regs IWRAM k=0
    .word 0x08019436, 0x02010000, HOME, 0, 0   @ CA1B ldmia r2!, 4 regs EWRAM k=0
    .word 0x08019436, 0x06010000, HOME, 0, 0   @ CA1B ldmia r2!, 4 regs VRAM k=0
    .word 0x08019476, SCRATCH, HOME, 0, 0   @ CA3B ldmia r2!, 5 regs IWRAM k=0
    .word 0x08019476, 0x02010000, HOME, 0, 0   @ CA3B ldmia r2!, 5 regs EWRAM k=0
    .word 0x08019476, 0x06010000, HOME, 0, 0   @ CA3B ldmia r2!, 5 regs VRAM k=0
    .word 0x080194f6, SCRATCH, HOME, 0, 0   @ CA7B ldmia r2!, 6 regs IWRAM k=0
    .word 0x080194f6, 0x02010000, HOME, 0, 0   @ CA7B ldmia r2!, 6 regs EWRAM k=0
    .word 0x080194f6, 0x06010000, HOME, 0, 0   @ CA7B ldmia r2!, 6 regs VRAM k=0
    .word 0x08019412, SCRATCH, HOME, 0, 1   @ CA09 ldmia r2!, 2 regs IWRAM k=1
    .word 0x08019412, 0x02010000, HOME, 0, 1   @ CA09 ldmia r2!, 2 regs EWRAM k=1
    .word 0x08019412, 0x06010000, HOME, 0, 1   @ CA09 ldmia r2!, 2 regs VRAM k=1
    .word 0x08019416, SCRATCH, HOME, 0, 1   @ CA0B ldmia r2!, 3 regs IWRAM k=1
    .word 0x08019416, 0x02010000, HOME, 0, 1   @ CA0B ldmia r2!, 3 regs EWRAM k=1
    .word 0x08019416, 0x06010000, HOME, 0, 1   @ CA0B ldmia r2!, 3 regs VRAM k=1
    .word 0x08019436, SCRATCH, HOME, 0, 1   @ CA1B ldmia r2!, 4 regs IWRAM k=1
    .word 0x08019436, 0x02010000, HOME, 0, 1   @ CA1B ldmia r2!, 4 regs EWRAM k=1
    .word 0x08019436, 0x06010000, HOME, 0, 1   @ CA1B ldmia r2!, 4 regs VRAM k=1
    .word 0x08019476, SCRATCH, HOME, 0, 1   @ CA3B ldmia r2!, 5 regs IWRAM k=1
    .word 0x08019476, 0x02010000, HOME, 0, 1   @ CA3B ldmia r2!, 5 regs EWRAM k=1
    .word 0x08019476, 0x06010000, HOME, 0, 1   @ CA3B ldmia r2!, 5 regs VRAM k=1
    .word 0x080194f6, SCRATCH, HOME, 0, 1   @ CA7B ldmia r2!, 6 regs IWRAM k=1
    .word 0x080194f6, 0x02010000, HOME, 0, 1   @ CA7B ldmia r2!, 6 regs EWRAM k=1
    .word 0x080194f6, 0x06010000, HOME, 0, 1   @ CA7B ldmia r2!, 6 regs VRAM k=1
    .word 0x08019412, SCRATCH, HOME, 0, 2   @ CA09 ldmia r2!, 2 regs IWRAM k=2
    .word 0x08019412, 0x02010000, HOME, 0, 2   @ CA09 ldmia r2!, 2 regs EWRAM k=2
    .word 0x08019412, 0x06010000, HOME, 0, 2   @ CA09 ldmia r2!, 2 regs VRAM k=2
    .word 0x08019416, SCRATCH, HOME, 0, 2   @ CA0B ldmia r2!, 3 regs IWRAM k=2
    .word 0x08019416, 0x02010000, HOME, 0, 2   @ CA0B ldmia r2!, 3 regs EWRAM k=2
    .word 0x08019416, 0x06010000, HOME, 0, 2   @ CA0B ldmia r2!, 3 regs VRAM k=2
    .word 0x08019436, SCRATCH, HOME, 0, 2   @ CA1B ldmia r2!, 4 regs IWRAM k=2
    .word 0x08019436, 0x02010000, HOME, 0, 2   @ CA1B ldmia r2!, 4 regs EWRAM k=2
    .word 0x08019436, 0x06010000, HOME, 0, 2   @ CA1B ldmia r2!, 4 regs VRAM k=2
    .word 0x08019476, SCRATCH, HOME, 0, 2   @ CA3B ldmia r2!, 5 regs IWRAM k=2
    .word 0x08019476, 0x02010000, HOME, 0, 2   @ CA3B ldmia r2!, 5 regs EWRAM k=2
    .word 0x08019476, 0x06010000, HOME, 0, 2   @ CA3B ldmia r2!, 5 regs VRAM k=2
    .word 0x080194f6, SCRATCH, HOME, 0, 2   @ CA7B ldmia r2!, 6 regs IWRAM k=2
    .word 0x080194f6, 0x02010000, HOME, 0, 2   @ CA7B ldmia r2!, 6 regs EWRAM k=2
    .word 0x080194f6, 0x06010000, HOME, 0, 2   @ CA7B ldmia r2!, 6 regs VRAM k=2
    .word 0x08019412, SCRATCH, HOME, 0, 3   @ CA09 ldmia r2!, 2 regs IWRAM k=3
    .word 0x08019412, 0x02010000, HOME, 0, 3   @ CA09 ldmia r2!, 2 regs EWRAM k=3
    .word 0x08019412, 0x06010000, HOME, 0, 3   @ CA09 ldmia r2!, 2 regs VRAM k=3
    .word 0x08019416, SCRATCH, HOME, 0, 3   @ CA0B ldmia r2!, 3 regs IWRAM k=3
    .word 0x08019416, 0x02010000, HOME, 0, 3   @ CA0B ldmia r2!, 3 regs EWRAM k=3
    .word 0x08019416, 0x06010000, HOME, 0, 3   @ CA0B ldmia r2!, 3 regs VRAM k=3
    .word 0x08019436, SCRATCH, HOME, 0, 3   @ CA1B ldmia r2!, 4 regs IWRAM k=3
    .word 0x08019436, 0x02010000, HOME, 0, 3   @ CA1B ldmia r2!, 4 regs EWRAM k=3
    .word 0x08019436, 0x06010000, HOME, 0, 3   @ CA1B ldmia r2!, 4 regs VRAM k=3
    .word 0x08019476, SCRATCH, HOME, 0, 3   @ CA3B ldmia r2!, 5 regs IWRAM k=3
    .word 0x08019476, 0x02010000, HOME, 0, 3   @ CA3B ldmia r2!, 5 regs EWRAM k=3
    .word 0x08019476, 0x06010000, HOME, 0, 3   @ CA3B ldmia r2!, 5 regs VRAM k=3
    .word 0x080194f6, SCRATCH, HOME, 0, 3   @ CA7B ldmia r2!, 6 regs IWRAM k=3
    .word 0x080194f6, 0x02010000, HOME, 0, 3   @ CA7B ldmia r2!, 6 regs EWRAM k=3
    .word 0x080194f6, 0x06010000, HOME, 0, 3   @ CA7B ldmia r2!, 6 regs VRAM k=3
@ planted for the emulator image only (never a trial):
plant:
    .word 0x08008E60, 0                              @ B 4730 bx r6
