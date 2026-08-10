@ gbaedge.s — GBA hardware edge-case probe ROM (see gbaedge.py, which
@ builds this and documents the philosophy; docs/hwprobe.md catalogs every
@ page).  Probes store RAW observed values into 32-byte slots at
@ 0x02000000; the viewer pages through them as hex.  Real hardware is the
@ oracle — nothing here encodes an expected value.
@
@ Page/slot order (viewer order == slot index, run order differs so the
@ BIOS open-bus probes execute before the first SWI dirties the latch):
@   0 IDENT     1 OPENBUS   2 BIOSPROT  3 SWITIME  4 TIMERS   5 DMALATCH
@   6 LDMSTM    7 MULFLAGS  8 MSRTBIT*  9 PPUSTAT 10 PSGSTAT 11 WAITSTATE
@ (*interactive: runs when START is pressed on its page — it deliberately
@  provokes UNPREDICTABLE MSR behavior and can require a power cycle,
@  though a timer-IRQ watchdog tries to recover first)
@
@ Build: python3 gbaedge.py   (as -> ld -Ttext=0x08000000 -> objcopy,
@ then the Nintendo logo + complement are patched in)

    .arm
    .text
    .global _start

.equ IOBASE,   0x04000000
.equ SLOTS,    0x02000000
.equ SLOTSZ,   32
.equ SCRATCH,  0x02001000          @ boot-time captures + IRQ scratch
.equ MARKER,   0x02002000          @ MSR probe bookkeeping
.equ VPAGE,    0x02002100          @ viewer: +0 page +4 prev-keys +8 autoctr
.equ EWSTUB,   0x02003000          @ open-bus read stub (EWRAM copy)
.equ EWDST,    0x02004000          @ DMA / CpuSet destination area
.equ IWSTUB,   0x03000100          @ open-bus read stub (IWRAM copy)
.equ IWBLOCK,  0x03000200          @ MSR probe block
.equ VRAM,     0x06000000

@ ───────────────────────────── header ────────────────────────────────────
_start:
    b   header_end                 @ 0x00: BIOS jumps here after the logo
    .space 0x9C                    @ 0x04-0x9F: logo (patched by gbaedge.py)
    .space 0x20                    @ 0xA0-0xBF: title/codes (patched)
header_end:                        @ 0xC0
    b   main

@ ─────────────────────────── entry / runner ──────────────────────────────
main:
    mov r0, #IOBASE                @ IME off before anything else
    add r0, r0, #0x208
    mov r1, #0
    strh r1, [r0]

    @ capture the BIOS handoff state before we touch the machine
    ldr r4, =SCRATCH
    mov r5, #IOBASE
    ldrh r0, [r5, #0x00]           @ DISPCNT
    strh r0, [r4, #0]
    ldrh r0, [r5, #0x02]           @ green swap
    strh r0, [r4, #2]
    ldr r0, =0x04000204
    ldrh r0, [r0]                  @ WAITCNT
    strh r0, [r4, #4]
    ldr r0, =0x04000130
    ldrh r0, [r0]                  @ KEYINPUT
    strh r0, [r4, #6]
    ldr r0, =0x04000300
    ldrb r0, [r0]                  @ POSTFLG
    strb r0, [r4, #8]
    ldr r0, =0x04000800
    ldr r0, [r0]                   @ internal memory control
    str r0, [r4, #12]
    mrs r0, CPSR
    str r0, [r4, #16]
    str sp, [r4, #20]

    @ zero every slot
    ldr r0, =SLOTS
    mov r1, #(NPAGES * SLOTSZ / 4)
    mov r2, #0
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b

    @ install the IRQ handler (used by BIOSPROT and the MSR watchdog)
    ldr r0, =0x03007FFC
    ldr r1, =irq_handler
    str r1, [r0]

    @ mode 3 + BG2, white screen
    ldr r0, =0x0403
    mov r1, #IOBASE
    strh r0, [r1]
    bl  clear_screen

    bl  probe_openbus              @ MUST run before any SWI
    bl  probe_biosprot
    bl  probe_ident
    bl  probe_switime
    bl  probe_timers
    bl  probe_dmalatch
    bl  probe_ldmstm
    bl  probe_mulflags
    bl  probe_ppustat
    bl  probe_psgstat
    bl  probe_waitstate
    bl  probe_pfphase
    bl  probe_swiregion
    @ MSRTBIT: interactive only — mark the slot so the page says so
    ldr r8, =SLOTS + 8*SLOTSZ
    mov r0, #0x99
    strb r0, [r8, #0]
    mov r0, #0xEE
    strb r0, [r8, #31]
.ifdef MSRBOOT                     @ debug builds: run it unattended
    bl  run_msr_probe
.endif

@ ─────────────────────────────── viewer ──────────────────────────────────
viewer:
    ldr r4, =VPAGE
    mov r0, #0
    str r0, [r4, #0]               @ page
    str r0, [r4, #8]               @ autopage counter
    ldr r0, =0x03FF
    str r0, [r4, #4]               @ prev keys (none pressed: bits high)
    mov r0, #0
    bl  draw_page
view_loop:
    bl  wait_vblank
    ldr r4, =VPAGE
    ldr r0, =0x04000130
    ldrh r0, [r0]                  @ 0 = pressed
    ldr r1, [r4, #4]
    str r0, [r4, #4]
    mvn r2, r0                     @ pressed bits high
    and r2, r2, r1                 @ newly pressed (were released before)
    ldr r5, [r4, #0]               @ current page
.ifdef AUTOPAGE
    ldr r3, [r4, #8]
    add r3, r3, #1
    cmp r3, #64
    movge r3, #0
    str r3, [r4, #8]
    bge page_next
.endif
    tst r2, #0x11                  @ RIGHT or A
    bne page_next
    tst r2, #0x22                  @ LEFT or B
    bne page_prev
    tst r2, #0x08                  @ START
    beq view_loop
    cmp r5, #8                     @ only meaningful on the MSRTBIT page
    bne view_loop
    bl  run_msr_probe
    b   page_redraw
page_next:
    add r5, r5, #1
    cmp r5, #NPAGES
    movge r5, #0
    b   page_store
page_prev:
    subs r5, r5, #1
    movlt r5, #NPAGES-1
page_store:
    ldr r4, =VPAGE
    str r5, [r4, #0]
page_redraw:
    ldr r4, =VPAGE
    ldr r0, [r4, #0]
    bl  draw_page
    b   view_loop
    .ltorg

wait_vblank:
    ldr r0, =0x04000006
1:  ldrh r1, [r0]
    cmp r1, #159
    bne 1b
2:  ldrh r1, [r0]
    cmp r1, #160
    bne 2b
    bx  lr
    .ltorg

@ ──────────────────────────── IRQ handler ────────────────────────────────
@ Entered from the BIOS dispatcher in IRQ mode; sp_irq points at the
@ BIOS-saved {r0-r3,r12,lr} block, so [sp,#20] is the return address the
@ BIOS will `subs pc, lr, #4` through.
irq_handler:
    ldr r0, =0x04000200
    ldrh r1, [r0, #2]              @ IF
    tst r1, #1                     @ ── vblank: BIOSPROT's mid-IRQ read
    beq 1f
    mov r2, #0
    ldr r3, [r2]                   @ BIOS region read DURING the IRQ
    ldr r2, =SCRATCH
    str r3, [r2, #0x40]
    mov r3, #1
    str r3, [r2, #0x44]
1:  tst r1, #0x40                  @ ── timer 3: MSR watchdog
    beq 2f
    ldr r2, =MARKER
    ldr r3, [r2, #8]
    cmp r3, #1                     @ probe in flight?
    bne 2f
    mov r3, #2                     @ mark "watchdog fired"
    str r3, [r2, #8]
    ldr r3, =msr_recover
    add r3, r3, #4
    str r3, [sp, #20]              @ divert the IRQ return to recovery
    mov r3, #0x9F                  @ system mode, ARM, IRQs masked
    msr SPSR_cxsf, r3
2:  strh r1, [r0, #2]              @ ack everything we saw
    bx  lr
    .ltorg

@ ─────────────────────────── timing helpers ──────────────────────────────
@ TM0 (prescaler 1) + TM1 cascade give a 32-bit cycle counter.  The fixed
@ call overhead is part of every measurement — constant per implementation.
tm_start:
    ldr r3, =0x04000100
    mov r2, #0
    str r2, [r3]
    str r2, [r3, #4]
    ldr r1, =0x00840000            @ TM1: enable + cascade
    str r1, [r3, #4]
    ldr r2, =0x00800000            @ TM0: enable, prescaler 1
    str r2, [r3]
    bx  lr
tm_stop:                           @ -> r0 = 32-bit elapsed
    ldr r3, =0x04000100
    ldrh r0, [r3]
    ldrh r1, [r3, #4]
    mov r2, #0
    str r2, [r3]
    str r2, [r3, #4]
    orr r0, r0, r1, lsl #16
    bx  lr
    .ltorg

@ ══════════════════════════════ PROBES ═══════════════════════════════════

@ ── slot 1: OPENBUS — what unmapped addresses return, per executing bus ──
@ +0  word at 0x00000000 (BIOS protection latch, post-startup, pre-SWI)
@ +4  word at 0x00004000   +8  word at 0x01000000   +12 word at 0x10000000
@ +16 half at 0x00004000   +18 byte at 0x00004001
@ +20 word at 0x10000000 read by a stub executing from EWRAM
@ +24 word at 0x10000000 read by a stub executing from IWRAM
@ +28 half at 0x10000000 read from ROM (16-bit open-bus duplication)
probe_openbus:
    push {r4-r5, lr}
    ldr r8, =SLOTS + 1*SLOTSZ
    mov r0, #0
    ldr r1, [r0]
    str r1, [r8, #0]
    mov r0, #0x4000
    ldr r1, [r0]
    str r1, [r8, #4]
    mov r0, #0x01000000
    ldr r1, [r0]
    str r1, [r8, #8]
    mov r0, #0x10000000
    ldr r1, [r0]
    str r1, [r8, #12]
    mov r0, #0x4000
    ldrh r1, [r0]
    strh r1, [r8, #16]
    ldrb r1, [r0, #1]
    strb r1, [r8, #18]
    @ copy the 2-instruction stub and run it from EWRAM, then IWRAM
    ldr r4, =ob_stub
    ldr r5, =EWSTUB
    ldr r0, [r4]
    str r0, [r5]
    ldr r0, [r4, #4]
    str r0, [r5, #4]
    mov r0, #0x10000000
    mov lr, pc
    bx  r5
    str r1, [r8, #20]
    ldr r5, =IWSTUB
    ldr r0, [r4]
    str r0, [r5]
    ldr r0, [r4, #4]
    str r0, [r5, #4]
    mov r0, #0x10000000
    mov lr, pc
    bx  r5
    str r1, [r8, #24]
    mov r0, #0x10000000
    ldrh r1, [r0]
    strh r1, [r8, #28]
    pop {r4-r5, pc}
ob_stub:
    ldr r1, [r0]
    bx  lr
    .ltorg

@ ── slot 2: BIOSPROT — the BIOS read-protection latch, per CPU state ─────
@ +0  read now (still post-startup — must equal OPENBUS+0)
@ +4  read after a SWI returns
@ +8  read taken INSIDE a vblank IRQ handler
@ +12 read after that IRQ returns
@ +16 halfword read at 0x0    +18 halfword read at 0x2
@ +20 word at 0x3FF0 (same latch at any BIOS address?)
@ +24 watchdog: 1 if the IRQ actually happened, else 0
probe_biosprot:
    push {r4, lr}
    ldr r8, =SLOTS + 2*SLOTSZ
    mov r0, #0
    ldr r1, [r0]
    str r1, [r8, #0]
    ldr r0, =0x12345678            @ now dirty the latch with a SWI
    mov r1, #7
    swi 0x060000                   @ Div
    mov r0, #0
    ldr r1, [r0]
    str r1, [r8, #4]
    @ vblank IRQ with an in-handler read
    ldr r4, =SCRATCH
    mov r0, #0
    str r0, [r4, #0x44]
    mov r1, #IOBASE
    ldrh r0, [r1, #4]              @ DISPSTAT
    orr r0, r0, #8                 @ vblank IRQ enable
    strh r0, [r1, #4]
    ldr r1, =0x04000200
    mov r0, #1
    strh r0, [r1]                  @ IE = vblank
    ldr r1, =0x04000208
    strh r0, [r1]                  @ IME on
    ldr r2, =0x00100000            @ poll cap (~2 frames of iterations)
1:  ldr r0, [r4, #0x44]
    cmp r0, #1
    beq 2f
    subs r2, r2, #1
    bne 1b
2:  mov r0, #0
    ldr r1, =0x04000208
    strh r0, [r1]                  @ IME off
    ldr r1, =0x04000200
    strh r0, [r1]                  @ IE off
    mov r1, #IOBASE
    ldrh r3, [r1, #4]
    bic r3, r3, #8
    strh r3, [r1, #4]
    ldr r0, [r4, #0x40]
    str r0, [r8, #8]
    mov r0, #0
    ldr r1, [r0]
    str r1, [r8, #12]
    ldrh r1, [r0]
    strh r1, [r8, #16]
    ldrh r1, [r0, #2]
    strh r1, [r8, #18]
    ldr r0, =0x3FF0
    ldr r1, [r0]
    str r1, [r8, #20]
    ldr r0, [r4, #0x44]
    str r0, [r8, #24]
    pop {r4, pc}
    .ltorg

@ ── slot 0: IDENT — model fingerprint + boot handoff ─────────────────────
@ +0  GetBiosChecksum word (AGB: BAAE187F; AGS/DS silicon differs)
@ +4  boot DISPCNT       +6  boot green-swap    +8  boot WAITCNT
@ +10 boot KEYINPUT      +12 boot POSTFLG       +13 spare
@ +16 boot 0x04000800 word    +20 boot CPSR word   +24 boot SP word
@ +28 word at 0x10000000 as of now (post-everything open bus)
probe_ident:
    push {r4, lr}
    ldr r8, =SLOTS + 0*SLOTSZ
    swi 0x0D0000                   @ GetBiosChecksum
    str r0, [r8, #0]
    ldr r4, =SCRATCH
    ldrh r0, [r4, #0]
    strh r0, [r8, #4]
    ldrh r0, [r4, #2]
    strh r0, [r8, #6]
    ldrh r0, [r4, #4]
    strh r0, [r8, #8]
    ldrh r0, [r4, #6]
    strh r0, [r8, #10]
    ldrb r0, [r4, #8]
    strb r0, [r8, #12]
    ldr r0, [r4, #12]
    str r0, [r8, #16]
    ldr r0, [r4, #16]
    str r0, [r8, #20]
    ldr r0, [r4, #20]
    str r0, [r8, #24]
    mov r0, #0x10000000
    ldr r1, [r0]
    str r1, [r8, #28]
    pop {r4, pc}
    .ltorg

@ ── slot 3: SWITIME — BIOS call cycle counts (the HLE timing oracle) ─────
@ Eight 32-bit cycle counts (TM0/TM1 cascade, includes constant call
@ overhead): Div, Sqrt, ArcTan2, CpuSet halfword-copy 256 ROM->EWRAM,
@ CpuSet word-fill 256, CpuFastSet word-copy 256, CpuSet halfword-copy
@ 256 IWRAM->IWRAM, BgAffineSet 1 entry.
probe_switime:
    push {r4-r5, lr}
    ldr r8, =SLOTS + 3*SLOTSZ

    bl  tm_start
    ldr r0, =0x12345678
    mov r1, #7
    swi 0x060000
    bl  tm_stop
    str r0, [r8, #0]

    bl  tm_start
    ldr r0, =0x7FFFFFFF
    swi 0x080000
    bl  tm_stop
    str r0, [r8, #4]

    bl  tm_start
    ldr r0, =0x1234
    ldr r1, =0x5678
    swi 0x0A0000
    bl  tm_stop
    str r0, [r8, #8]

    bl  tm_start
    ldr r0, =rom_pattern
    ldr r1, =EWDST
    mov r2, #256                   @ halfword copy
    swi 0x0B0000
    bl  tm_stop
    str r0, [r8, #12]

    bl  tm_start
    ldr r0, =rom_pattern
    ldr r1, =EWDST
    ldr r2, =0x05000100            @ word fill, 256
    swi 0x0B0000
    bl  tm_stop
    str r0, [r8, #16]

    bl  tm_start
    ldr r0, =rom_pattern
    ldr r1, =EWDST
    mov r2, #256                   @ word copy
    swi 0x0C0000
    bl  tm_stop
    str r0, [r8, #20]

    ldr r4, =IWSTUB                @ IWRAM->IWRAM copy source=dest area ok
    bl  tm_start
    mov r0, r4
    add r1, r4, #0x200
    mov r2, #256
    swi 0x0B0000
    bl  tm_stop
    str r0, [r8, #24]

    bl  tm_start
    ldr r0, =affine_src
    ldr r1, =EWDST
    mov r2, #1
    swi 0x0E0000
    bl  tm_stop
    str r0, [r8, #28]
    pop {r4-r5, pc}
    .ltorg

@ ── slot 4: TIMERS — prescaler free-run phase & latching ─────────────────
@ +0..+5  TM2 (prescaler 64) count after a fixed short delay, started
@         k=0..5 extra cycles later: the free-running prescaler phase
@ +6/+7   TM0 read twice back-to-back right after enabling (start latency)
@ +8/+10  TM1 (cascade), TM0 after TM0 ran from 0xFFFC (halfwords)
@ +12     TM0 count read right after writing a new reload mid-run (should
@         be unaffected)   +14  TM0 after stop/restart (new reload taken)
probe_timers:
    push {r4-r6, lr}
    ldr r8, =SLOTS + 4*SLOTSZ
    ldr r4, =0x04000108            @ TM2
    mov r6, #0
tphase_loop:
    mov r0, #0
    str r0, [r4]
    mov r5, r6                     @ k extra cycles (1-cycle sub each)
1:  subs r5, r5, #1
    bpl 1b
    ldr r0, =0x00810000            @ enable, prescaler 64
    str r0, [r4]
    mov r5, #16
2:  subs r5, r5, #1
    bne 2b
    ldrh r0, [r4]
    add r1, r8, r6
    strb r0, [r1]
    mov r0, #0
    str r0, [r4]
    add r6, r6, #1
    cmp r6, #6
    blt tphase_loop

    ldr r4, =0x04000100
    mov r0, #0
    str r0, [r4]
    ldr r0, =0x00800000
    str r0, [r4]
    ldrh r1, [r4]
    ldrh r2, [r4]
    strb r1, [r8, #6]
    strb r2, [r8, #7]
    mov r0, #0
    str r0, [r4]

    ldr r0, =0x0080FFFC            @ TM0: reload FFFC, enable
    ldr r1, =0x00840000            @ TM1: cascade
    str r1, [r4, #4]
    str r0, [r4]
    mov r5, #8
1:  subs r5, r5, #1
    bne 1b
    ldrh r0, [r4, #4]
    strh r0, [r8, #8]
    ldrh r0, [r4]
    strh r0, [r8, #10]
    mov r0, #0
    str r0, [r4]
    str r0, [r4, #4]

    ldr r0, =0x00800000            @ run from 0
    str r0, [r4]
    ldr r0, =0x00801234            @ new reload, still enabled
    str r0, [r4]
    ldrh r1, [r4]
    strh r1, [r8, #12]             @ mid-run: reload must NOT latch
    mov r0, #0
    str r0, [r4]
    ldr r0, =0x00801234
    str r0, [r4]                   @ restart: reload 0x1234 taken now
    ldrh r1, [r4]
    strh r1, [r8, #14]
    mov r0, #0
    str r0, [r4]
    pop {r4-r6, pc}
    .ltorg

@ ── slot 5: DMALATCH — DMA bus latch & restricted sources ────────────────
@ +0  word at 0x10000000 right after a DMA3 ROM->EWRAM (the DMA latch is
@     what open bus returns now — emulators split on this)
@ +4  word at 0x01000000 at the same moment
@ +8  cycles stolen by a 16-word EWRAM->EWRAM DMA3 (halfword count)
@ +12 dest word after DMA3 from 0x00000000 (BIOS: protected source)
@ +16 dest word after DMA0 from ROM (DMA0 cannot address ROM)
@ +20 dest words after halfword-DMA3 with source address |1 (misaligned)
@ +24 word at 0x10000000 after the BIOS-source DMA (latch again)
probe_dmalatch:
    push {r4-r5, lr}
    ldr r8, =SLOTS + 5*SLOTSZ
    ldr r4, =0x040000D4            @ DMA3: SAD DAD CNT
    ldr r0, =rom_pattern
    ldr r1, =EWDST
    str r0, [r4]
    str r1, [r4, #4]
    ldr r0, =0x84000004            @ enable, word, count 4
    str r0, [r4, #8]
    nop
    mov r0, #0x10000000
    ldr r1, [r0]
    str r1, [r8, #0]
    mov r0, #0x01000000
    ldr r1, [r0]
    str r1, [r8, #4]

    bl  tm_start
    ldr r0, =EWDST
    add r1, r0, #0x100
    str r0, [r4]
    str r1, [r4, #4]
    ldr r0, =0x84000010            @ word, count 16
    str r0, [r4, #8]
    bl  tm_stop
    strh r0, [r8, #8]

    ldr r1, =EWDST
    ldr r0, =0xDEADBEEF
    str r0, [r1]
    mov r0, #0                     @ SAD = BIOS
    str r0, [r4]
    str r1, [r4, #4]
    ldr r0, =0x84000001
    str r0, [r4, #8]
    nop
    ldr r0, [r1]
    str r0, [r8, #12]

    ldr r5, =0x040000B0            @ DMA0
    ldr r1, =EWDST
    ldr r0, =0xDEADBEEF
    str r0, [r1]
    ldr r0, =rom_pattern           @ illegal source bus for DMA0
    str r0, [r5]
    str r1, [r5, #4]
    ldr r0, =0x84000001
    str r0, [r5, #8]
    nop
    ldr r0, [r1]
    str r0, [r8, #16]

    ldr r1, =EWDST
    ldr r0, =0xDEADBEEF
    str r0, [r1]
    str r0, [r1, #4]
    ldr r0, =rom_pattern + 1       @ misaligned halfword source
    str r0, [r4]
    str r1, [r4, #4]
    ldr r0, =0x80000002            @ halfword, count 2
    str r0, [r4, #8]
    nop
    ldr r0, [r1]
    str r0, [r8, #20]

    mov r0, #0x10000000
    ldr r1, [r0]
    str r1, [r8, #24]
    pop {r4-r5, pc}
    .ltorg

@ ── slot 6: LDMSTM — ARM7TDMI block-transfer corner cases ────────────────
@ +0  stm r0!,{r0,r1}: the r0 value that hit memory (old base on ARM7)
@ +4  stm r1!,{r0,r1}, base NOT first in list: old or written-back base?
@ +8  ldm r0!,{r0}: loaded value wins over writeback?
@ +12 empty-rlist STM (0xE8A00000): the word it stored (PC+12?)
@ +16 its base delta (0x40?)
@ +20 empty-rlist LDM (0xE8B00000): 1 = jumped through [base] (PC loaded),
@     2 = fell through   +24 its base delta
@ +28 unaligned: ldr [p+1] rotate   +? (see docs) — packed low halves
probe_ldmstm:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 6*SLOTSZ
    ldr r4, =EWDST

    ldr r1, =0x11111111
    mov r0, r4
    stmia r0!, {r0, r1}
    ldr r2, [r4]
    str r2, [r8, #0]

    mov r0, #0x22
    mov r1, r4
    stmia r1!, {r0, r1}
    ldr r2, [r4, #4]
    str r2, [r8, #4]

    ldr r0, =0xCAFEBABE
    str r0, [r4]
    mov r0, r4
    ldmia r0!, {r0}
    str r0, [r8, #8]

    mov r0, r4
    .word 0xE8A00000               @ stmia r0!, {} — empty rlist
    ldr r1, [r4]
    str r1, [r8, #12]
    sub r1, r0, r4
    str r1, [r8, #16]

    ldr r0, =EWDST + 0x80
    ldr r1, =ldm_empty_cont
    str r1, [r0]                   @ if PC gets loaded, it lands there
    mov r7, #0
    .word 0xE8B00000               @ ldmia r0!, {} — empty rlist
    mov r7, #2                     @ fell through
    b   ldm_empty_join
ldm_empty_cont:
    mov r7, #1                     @ PC was loaded from [base]
ldm_empty_join:
    str r7, [r8, #20]
    ldr r1, =EWDST + 0x80
    sub r1, r0, r1
    str r1, [r8, #24]

    ldr r4, =rom_pattern
    add r3, r4, #1
    ldr r0, [r3]                   @ rotated load
    str r0, [r8, #28]
    pop {r4-r7, pc}
    .ltorg

@ ── slot 7: MULFLAGS — the "meaningless" carry after MUL family ──────────
@ ARM7TDMI destroys C with a value derived from the early-termination
@ logic; deterministic on silicon, guessed-at by emulators.  8 operand
@ pairs, flags nibble stored per run: +0..7 with C preset 1, +8..15 with
@ C preset 0, +16..19 UMULLS/SMULLS pairs, +20..23 unaligned LDRH/LDRSH
@ low halves (overflow from LDMSTM's slot).
probe_mulflags:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 7*SLOTSZ
    mov r6, #0                     @ run index
    ldr r7, =mul_ops
mf_loop:
    ldr r1, [r7, r6, lsl #3]
    add r0, r7, r6, lsl #3
    ldr r2, [r0, #4]
    cmp r6, #8
    blt mf_carry_set
    adds r0, r6, #0                @ C := 0
    b   mf_go
mf_carry_set:
    subs r0, r6, #0                @ C := 1 (no borrow)
mf_go:
    muls r0, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    add r0, r8, r6
    strb r3, [r0]
    add r6, r6, #1
    cmp r6, #16
    blt mf_loop

    ldr r1, =0xFFFFFFFF
    ldr r2, =0xFFFFFFFF
    subs r0, r0, r0                @ C=1 (and Z, N=0)
    umulls r0, r4, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    strb r3, [r8, #16]
    smulls r0, r4, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    strb r3, [r8, #17]
    ldr r1, =0x0000FFFF
    ldr r2, =0x00010001
    umulls r0, r4, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    strb r3, [r8, #18]
    smulls r0, r4, r1, r2
    mrs r3, CPSR
    mov r3, r3, lsr #28
    strb r3, [r8, #19]

    ldr r4, =rom_pattern
    add r3, r4, #1
    ldrh r0, [r3]                  @ misaligned LDRH (rotate)
    strh r0, [r8, #20]
    ldrsh r0, [r3]                 @ misaligned LDRSH (acts as LDRSB)
    strh r0, [r8, #22]
    pop {r4-r7, pc}
    .ltorg
mul_ops:
    .word 0x00000000, 0x00000000
    .word 0xFFFFFFFF, 0xFFFFFFFF
    .word 0x000000FF, 0xFF00FF00
    .word 0x12345678, 0x9ABCDEF0
    .word 0x0000FFFF, 0x0000FFFF
    .word 0x80000000, 0x00000002
    .word 0xFFFFFF00, 0x00000100
    .word 0x00000001, 0xFFFFFFFF

@ ── slot 9: PPUSTAT — DISPSTAT/VCOUNT around the line boundaries ─────────
@ +0..15  8 pairs [DISPSTAT-lo, VCOUNT] at ~150-cycle stride across line
@         40 (maps hblank set/clear at coarse resolution)
@ +16..23 8 DISPSTAT-lo samples back-to-back right after the hblank flag
@         was seen to rise (poll-anchored fine window)
@ +24..31 4 pairs [DISPSTAT-lo, VCOUNT] at ~600-cycle stride from the
@         VCOUNT 159->160 area (vblank flag rise)
probe_ppustat:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 9*SLOTSZ
    mov r4, #IOBASE
1:  ldrh r0, [r4, #6]
    cmp r0, #39
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #40
    bne 2b
    mov r6, #0
3:  ldrh r0, [r4, #4]
    add r1, r8, r6, lsl #1
    strb r0, [r1]
    ldrh r0, [r4, #6]
    strb r0, [r1, #1]
    mov r5, #24
4:  subs r5, r5, #1
    bne 4b
    add r6, r6, #1
    cmp r6, #8
    blt 3b

1:  ldrh r0, [r4, #4]              @ wait for hblank flag LOW
    tst r0, #2
    bne 1b
2:  ldrh r0, [r4, #4]              @ then its rise
    tst r0, #2
    beq 2b
    ldrh r0, [r4, #4]
    strb r0, [r8, #16]
    ldrh r0, [r4, #4]
    strb r0, [r8, #17]
    ldrh r0, [r4, #4]
    strb r0, [r8, #18]
    ldrh r0, [r4, #4]
    strb r0, [r8, #19]
    mov r5, #40
3:  subs r5, r5, #1
    bne 3b
    ldrh r0, [r4, #4]
    strb r0, [r8, #20]
    ldrh r0, [r4, #4]
    strb r0, [r8, #21]
    mov r5, #40
4:  subs r5, r5, #1
    bne 4b
    ldrh r0, [r4, #4]
    strb r0, [r8, #22]
    ldrh r0, [r4, #4]
    strb r0, [r8, #23]

1:  ldrh r0, [r4, #6]
    cmp r0, #158
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #159
    bne 2b
    mov r6, #0
3:  ldrh r0, [r4, #4]
    add r1, r8, #24
    add r1, r1, r6, lsl #1
    strb r0, [r1]
    ldrh r0, [r4, #6]
    strb r0, [r1, #1]
    mov r5, #100
4:  subs r5, r5, #1
    bne 4b
    add r6, r6, #1
    cmp r6, #4
    blt 3b
    pop {r4-r7, pc}
    .ltorg

@ ── slot 10: PSGSTAT — GB channels on AGB silicon ────────────────────────
@ +0  SOUNDCNT_X right after triggering ch1 with length 63 (+len enable)
@ +2  poll iterations (capped) until the ch1 active flag dropped
@ +4  SOUNDCNT_X after that
@ +6  SOUNDBIAS boot value
@ +8  wave RAM byte readback while ch3 plays the OTHER bank (bank quirk)
@ +10 SOUNDCNT_X after ch3 trigger
probe_psgstat:
    push {r4-r5, lr}
    ldr r8, =SLOTS + 10*SLOTSZ
    mov r4, #IOBASE
    ldr r0, =0x04000088
    ldrh r1, [r0]
    strh r1, [r8, #6]
    mov r0, #0x80
    strh r0, [r4, #0x84]           @ SOUNDCNT_X: master on
    ldr r0, =0x1177
    strh r0, [r4, #0x80]           @ ch1 L+R, full PSG volume
    mov r0, #2
    strh r0, [r4, #0x82]           @ PSG ratio 100%
    ldr r0, =0xF0BF                @ env F, duty 2, length 63
    strh r0, [r4, #0x62]
    ldr r0, =0xC400                @ trigger + length enable, mid freq
    strh r0, [r4, #0x64]
    ldrh r0, [r4, #0x84]
    strb r0, [r8, #0]
    ldr r2, =0x00060000            @ poll cap
    mov r3, #0
1:  ldrh r0, [r4, #0x84]
    tst r0, #1
    beq 2f
    add r3, r3, #1
    subs r2, r2, #1
    bne 1b
2:  strh r3, [r8, #2]
    ldrh r0, [r4, #0x84]
    strb r0, [r8, #4]
    @ ch3: load bank 0, play bank 0, then read wave RAM (which maps to
    @ the bank NOT selected for playback — which one do we see?)
    mov r0, #0x40                  @ bank select 1 -> wave RAM = bank 0
    strh r0, [r4, #0x70]
    ldr r0, =0x5A5A
    strh r0, [r4, #0x90]           @ write into bank 0
    mov r0, #0x00                  @ play bank 0, ch3 on
    strh r0, [r4, #0x70]
    mov r0, #0x80
    strh r0, [r4, #0x70]           @ ch3 enable (dimension 0, bank 0)
    ldr r0, =0x2000
    strh r0, [r4, #0x72]           @ 100% volume
    ldr r0, =0xC400
    strh r0, [r4, #0x74]           @ trigger ch3
    ldrh r0, [r4, #0x90]           @ wave RAM readback while playing
    strh r0, [r8, #8]
    ldrh r0, [r4, #0x84]
    strb r0, [r8, #10]
    mov r0, #0
    strh r0, [r4, #0x84]           @ APU off
    pop {r4-r5, pc}
    .ltorg

@ ── slot 11: WAITSTATE — ROM timing under WAITCNT, incl. prefetch ────────
@ Halfword cycle counts: 16 sequential ROM reads under WAITCNT = 0x0000 /
@ 0x0014 / 0x4014 / 0x4000, then a 32-nop ROM subroutine call under
@ 0x0000 and 0x4000 (prefetch on: the buffer serves sequential fetches).
@ WAITCNT is restored to the boot value afterwards.
probe_waitstate:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 11*SLOTSZ
    ldr r4, =0x04000204
    mov r6, #0
    ldr r7, =ws_values
ws_loop:
    ldrh r0, [r7, r6]
    strh r0, [r4]
    bl  tm_start
    ldr r2, =rom_pattern
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    ldrh r3, [r2], #2
    bl  tm_stop
    add r1, r8, r6
    strh r0, [r1]
    add r6, r6, #2
    cmp r6, #8
    blt ws_loop

    mov r0, #0
    strh r0, [r4]
    bl  tm_start
    bl  rom_nopsled
    bl  tm_stop
    strh r0, [r8, #8]
    ldr r0, =0x4000
    strh r0, [r4]
    bl  tm_start
    bl  rom_nopsled
    bl  tm_stop
    strh r0, [r8, #10]
    ldr r0, =SCRATCH               @ restore the boot WAITCNT
    ldrh r0, [r0, #4]
    strh r0, [r4]
    pop {r4-r7, pc}
    .ltorg
ws_values:
    .hword 0x0000, 0x0014, 0x4014, 0x4000
rom_nopsled:
    .rept 32
    nop
    .endr
    bx  lr

@ ── slot 12: PFPHASE — the prefetch dead-cycle phase rule ────────────────
@ dingbat's bus model decides whether a ROM data access pays an extra
@ cycle from `elapsed mod s == s-1` — a rule fitted per-row to the mGBA
@ suite's CPU column, and docs/prefetch-model-rewrite.md proves no rule of
@ that shape fits the DMA rows.  This page reads the rule off silicon:
@ k = 0..7 sequential ROM fetches (nops) after a fixed non-sequential
@ point, then one timer-bracketed ROM data read.  The cost-vs-k pattern
@ IS the phase rule, at two waitstate settings.
@ +0..+15   halfword cycle counts, k=0..7, WAITCNT=0x4000 (4/2, prefetch)
@ +16..+31  the same under WAITCNT=0x4014 (3/1, prefetch)
.macro pf_one k, off
    bl  tm_start
    .rept \k
    nop
    .endr
    ldrh r3, [r5]
    bl  tm_stop
    strh r0, [r8, #\off]
.endm

probe_pfphase:
    push {r4-r8, lr}
    ldr r8, =SLOTS + 12*SLOTSZ
    ldr r4, =0x04000204
    ldr r5, =rom_pattern
    ldr r0, =0x4000
    strh r0, [r4]
    .irp k, 0, 1, 2, 3, 4, 5, 6, 7
    pf_one \k, (\k * 2)
    .endr
    ldr r0, =0x4014
    strh r0, [r4]
    .irp k, 0, 1, 2, 3, 4, 5, 6, 7
    pf_one \k, (16 + \k * 2)
    .endr
    ldr r0, =SCRATCH               @ restore the boot WAITCNT
    ldrh r0, [r0, #4]
    strh r0, [r4]
    pop {r4-r8, pc}
    .ltorg

@ ── slot 13: SWIREGION — HLE timing oracles the suite never measured ─────
@ dingbat's SWI_HLE_BASE / refill residual are calibrated against the mGBA
@ suite's IWRAM column only, and its Sqrt cost is a 3-point piecewise fit.
@ +0..+7   Sqrt cycle counts for r0 = 0x10 / 0x1000 / 0x100000 /
@          0x40000000 (halfwords — bit-length sweep between the fit's
@          calibration points)
@ +8/+10   Div (0x12345678 / 7) issued from an IWRAM / EWRAM caller
@ +12/+14  CpuSet 64-halfword ROM->EWRAM copy from an IWRAM / EWRAM caller
@ +16      Div from this ROM caller (cross-check against SWITIME +0)
probe_swiregion:
    push {r4-r8, lr}
    ldr r8, =SLOTS + 13*SLOTSZ
    bl  tm_start
    mov r0, #0x10
    swi 0x080000
    bl  tm_stop
    strh r0, [r8, #0]
    bl  tm_start
    mov r0, #0x1000
    swi 0x080000
    bl  tm_stop
    strh r0, [r8, #2]
    bl  tm_start
    ldr r0, =0x100000
    swi 0x080000
    bl  tm_stop
    strh r0, [r8, #4]
    bl  tm_start
    ldr r0, =0x40000000
    swi 0x080000
    bl  tm_stop
    strh r0, [r8, #6]
    @ copy the two "swi ; bx lr" stubs into IWRAM and EWRAM
    ldr r4, =swi_stubs
    ldr r5, =IWSTUB + 0x40
    ldmia r4, {r0-r3}
    stmia r5, {r0-r3}
    ldr r6, =EWSTUB + 0x40
    stmia r6, {r0-r3}
    @ Div from IWRAM
    bl  tm_start
    ldr r0, =0x12345678
    mov r1, #7
    mov lr, pc
    bx  r5
    bl  tm_stop
    strh r0, [r8, #8]
    @ Div from EWRAM
    bl  tm_start
    ldr r0, =0x12345678
    mov r1, #7
    mov lr, pc
    bx  r6
    bl  tm_stop
    strh r0, [r8, #10]
    @ CpuSet from IWRAM (stub at +8 in the block)
    add r5, r5, #8
    add r6, r6, #8
    bl  tm_start
    ldr r0, =rom_pattern
    ldr r1, =EWDST
    mov r2, #64
    mov lr, pc
    bx  r5
    bl  tm_stop
    strh r0, [r8, #12]
    @ CpuSet from EWRAM
    bl  tm_start
    ldr r0, =rom_pattern
    ldr r1, =EWDST
    mov r2, #64
    mov lr, pc
    bx  r6
    bl  tm_stop
    strh r0, [r8, #14]
    @ Div from ROM (baseline)
    bl  tm_start
    ldr r0, =0x12345678
    mov r1, #7
    swi 0x060000
    bl  tm_stop
    strh r0, [r8, #16]
    pop {r4-r8, pc}
    .ltorg
swi_stubs:
    .word 0xEF060000               @ swi 0x06 (Div)
    .word 0xE12FFF1E               @ bx lr
    .word 0xEF0B0000               @ swi 0x0B (CpuSet)
    .word 0xE12FFF1E               @ bx lr
sqrt_inputs:
    .word 0x10, 0x1000, 0x100000, 0x40000000

@ ── slot 8: MSRTBIT — MSR CPSR with T set, from ARM state (interactive) ──
@ Slot before running: +0 = 0x99, +31 = 0xEE ("press START on this page").
@ After: +0 breadcrumb r7 (15/14/12/8/0 = resumed at A+4/A+6/A+8/A+10/
@ continued as ARM), +1 phase flags (1 ok, 2 watchdog recovered), +2
@ control-run r7 (must be 15 — validates the breadcrumbs), +3 CPSR low
@ byte at recovery, +4 marker word from the thumb str, +8 = 0xAA "ran".
run_msr_probe:
    push {r4-r11, lr}
    ldr r2, =MARKER
    str sp, [r2, #12]
    @ copy the probe block into IWRAM
    ldr r0, =msr_block
    ldr r1, =IWBLOCK
    ldmia r0!, {r3-r8}
    stmia r1!, {r3-r8}
    ldr r8, =SLOTS + 8*SLOTSZ
    mov r0, #0
    str r0, [r2, #0]               @ marker word
    str r0, [r2, #16]              @ phase = 0 (main run)
    mov r0, #1
    str r0, [r2, #8]               @ in-flight flag (watchdog looks at it)
    @ watchdog: TM3 overflow IRQ in 65536 cycles
    ldr r4, =0x0400010C            @ TM3
    mov r0, #0
    str r0, [r4]
    ldr r0, =0x00C00000            @ enable + IRQ, prescaler 1, reload 0
    str r0, [r4]
    ldr r4, =0x04000200
    mov r0, #0x40
    strh r0, [r4]                  @ IE = timer3
    ldr r4, =0x04000208
    mov r0, #1
    strh r0, [r4]                  @ IME on
    @ go
    ldr r6, =MARKER                @ r6: thumb str target
    ldr r5, =msr_recover           @ r5: bx target from the block
    mov r7, #0
    mrs r4, CPSR
    orr r0, r4, #0x20              @ T bit
    cmp r7, #0                     @ pin flags: Z=1 C=1 (see block comment)
    ldr r1, =IWBLOCK
    bx  r1
msr_recover:
    ldr r2, =MARKER
    ldr sp, [r2, #12]              @ sp may be anything if we crashed wild
    mov r0, #0                     @ watchdog off
    ldr r3, =0x04000208
    strh r0, [r3]
    ldr r3, =0x04000200
    strh r0, [r3]
    ldr r3, =0x0400010C
    str r0, [r3]
    ldr r8, =SLOTS + 8*SLOTSZ
    ldr r3, [r2, #16]              @ which phase was this?
    cmp r3, #1
    beq msr_after_control
    @ main run results
    strb r7, [r8, #0]
    ldr r3, [r2, #8]               @ 1 = clean, 2 = watchdog fired
    strb r3, [r8, #1]
    mrs r3, CPSR
    strb r3, [r8, #3]
    ldr r3, [r2, #0]
    str r3, [r8, #4]
    @ control run: enter the block in THUMB at A+4, skipping the MSR —
    @ validates that the breadcrumb/str/bx mechanics themselves work
    mov r0, #1
    str r0, [r2, #16]              @ phase = 1
    mov r7, #0
    ldr r6, =MARKER
    ldr r5, =msr_recover
    ldr r1, =IWBLOCK + 4 + 1       @ thumb entry at A+4
    bx  r1
msr_after_control:
    strb r7, [r8, #2]
    mov r0, #0xAA
    strb r0, [r8, #8]
    mov r0, #0
    str r0, [r2, #8]
    pop {r4-r11, pc}
    .ltorg

@ The block run from IWRAM.  If MSR enters Thumb cleanly at A+4 the adds
@ accumulate a distinct r7 per entry point, the str drops r7 at [r6], and
@ bx r5 recovers.  If the core instead keeps fetching ARM, the halfword
@ pairs decode as condition-LO / condition-MI words that the pinned Z=1,
@ C=1, N=0 flags skip, and the trailing ARM `bx r5` nets execution out.
msr_block:
    .word 0xE121F000               @ A+0: msr CPSR_c, r0
    .hword 0x3701                  @ A+4:  adds r7, #1   (thumb)
    .hword 0x3702                  @ A+6:  adds r7, #2
    .hword 0x3704                  @ A+8:  adds r7, #4
    .hword 0x3708                  @ A+10: adds r7, #8
    .hword 0x6037                  @ A+12: str r7, [r6]
    .hword 0x4728                  @ A+14: bx r5
    .word 0xE12FFF15               @ A+16: bx r5 (ARM safety net)
    .word 0xE12FFF15               @ A+20
    .ltorg

@ ═══════════════════════════ RENDERING ═══════════════════════════════════

clear_screen:
    ldr r0, =VRAM
    ldr r1, =0x7FFF7FFF
    ldr r2, =240*160/2
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    bx  lr
    .ltorg

@ r0 = cell x (0-29), r1 = cell y (0-19), r2 = font tile
draw_glyph:
    push {r4-r7, lr}
    ldr r3, =VRAM
    mov r4, #480
    mul r5, r1, r4
    add r3, r3, r5, lsl #3         @ + y*8*480
    add r3, r3, r0, lsl #4         @ + x*8*2
    ldr r5, =font_data
    add r5, r5, r2, lsl #3
    ldr r1, =0x7FFF                @ paper
    mov r6, #8
dg_row:
    ldrb r7, [r5], #1
    mov r2, #0x80
    mov r12, r3
dg_col:
    tst r7, r2
    movne r4, #0                   @ ink
    moveq r4, r1
    strh r4, [r12], #2
    movs r2, r2, lsr #1
    bne dg_col
    add r3, r3, #480
    subs r6, r6, #1
    bne dg_row
    pop {r4-r7, pc}
    .ltorg

@ r0 = x, r1 = y, r2 = string (font tile bytes), r3 = length
draw_str:
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
1:  ldrb r2, [r6], #1
    mov r0, r4
    mov r1, r5
    bl  draw_glyph
    add r4, r4, #1
    subs r7, r7, #1
    bne 1b
    pop {r4-r7, pc}

@ r0 = x, r1 = y, r2 = byte
print_hex8:
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r2, r6, lsr #4
    and r2, r2, #0xF
    add r2, r2, #1                 @ font tile = nibble + 1
    bl  draw_glyph
    and r2, r6, #0xF
    add r2, r2, #1
    add r0, r4, #1
    mov r1, r5
    bl  draw_glyph
    pop {r4-r6, pc}

@ r0 = ptr, r1 = len -> r0 = CRC-16/CCITT (poly 1021, init FFFF)
crc16:
    ldr r2, =0xFFFF
1:  ldrb r3, [r0], #1
    eor r2, r2, r3, lsl #8
    mov r12, #8
2:  tst r2, #0x8000
    mov r2, r2, lsl #1
    eorne r2, r2, #0x1000
    eorne r2, r2, #0x0021
    subs r12, r12, #1
    bne 2b
    bic r2, r2, #0xFF000000
    bic r2, r2, #0x00FF0000
    subs r1, r1, #1
    bne 1b
    mov r0, r2
    bx  lr
    .ltorg

@ r0 = page
draw_page:
    push {r4-r9, lr}
    mov r9, r0
    bl  clear_screen
    mov r0, #0
    mov r1, #0
    ldr r2, =str_title
    mov r3, #str_title_len
    bl  draw_str
    mov r0, #15
    mov r1, #0
    mov r2, #26                    @ 'P'
    bl  draw_glyph
    mov r0, #16
    mov r1, #0
    mov r2, r9
    bl  print_hex8
    @ name
    mov r0, #0
    mov r1, #2
    ldr r2, =name_table
    mov r3, #10
    mla r2, r9, r3, r2
    bl  draw_str
    @ hex rows
    ldr r6, =SLOTS
    mov r0, #SLOTSZ
    mla r6, r9, r0, r6             @ slot base
    mov r7, #0                     @ byte offset
dp_row:
    add r1, r7, #16                @ y = 4 + off/4
    mov r1, r1, lsr #2
    mov r0, #0
    mov r2, r7
    bl  print_hex8
    mov r4, #0                     @ col within row
dp_col:
    add r0, r4, r4, lsl #1         @ x = 3 + col*3
    add r0, r0, #3
    add r1, r7, #16
    mov r1, r1, lsr #2
    ldrb r2, [r6, r4]
    bl  print_hex8
    add r4, r4, #1
    cmp r4, #4
    blt dp_col
    add r6, r6, #4
    add r7, r7, #4
    cmp r7, #SLOTSZ
    blt dp_row
    @ CRC of this slot
    mov r0, #0
    mov r1, #13
    ldr r2, =str_crc
    mov r3, #str_crc_len
    bl  draw_str
    ldr r0, =SLOTS
    mov r1, #SLOTSZ
    mla r0, r9, r1, r0
    bl  crc16
    mov r8, r0
    mov r0, #4
    mov r1, #13
    mov r2, r8, lsr #8
    bl  print_hex8
    mov r0, #6
    mov r1, #13
    and r2, r8, #0xFF
    bl  print_hex8
    @ global CRC
    mov r0, #0
    mov r1, #14
    ldr r2, =str_all
    mov r3, #str_all_len
    bl  draw_str
    ldr r0, =SLOTS
    mov r1, #(NPAGES * SLOTSZ)
    bl  crc16
    mov r8, r0
    mov r0, #4
    mov r1, #14
    mov r2, r8, lsr #8
    bl  print_hex8
    mov r0, #6
    mov r1, #14
    and r2, r8, #0xFF
    bl  print_hex8
    @ the MSRTBIT page carries its trigger hint
    cmp r9, #8
    bne dp_model
    mov r0, #0
    mov r1, #15
    ldr r2, =str_press
    mov r3, #str_press_len
    bl  draw_str
dp_model:
    mov r0, #0
    mov r1, #16
    ldr r2, =str_model
    mov r3, #str_model_len
    bl  draw_str
    ldr r6, =SLOTS                 @ IDENT slot: BIOS checksum low half
    mov r0, #6
    mov r1, #16
    ldrb r2, [r6, #1]
    bl  print_hex8
    mov r0, #9
    mov r1, #16
    ldrb r2, [r6, #0]
    bl  print_hex8
    pop {r4-r9, pc}
    .ltorg

@ ─────────────────────────────── data ────────────────────────────────────
    .align 2
rom_pattern:
    .word 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00
    .word 0x01020304, 0x05060708, 0x090A0B0C, 0x0D0E0F10
    .word 0xA1A2A3A4, 0xB1B2B3B4, 0xC1C2C3C4, 0xD1D2D3D4
    .word 0xE1E2E3E4, 0xF1F2F3F4, 0x21222324, 0x31323334
affine_src:
    .word 0x00000000                @ original data center x (8.8… 19.8)
    .word 0x00000000                @ center y
    .hword 0x0040, 0x0040           @ display center
    .hword 0x0100, 0x0100           @ scale x, y (1.0)
    .hword 0x0000                   @ angle
    .hword 0x0000                   @ (alignment pad)

    .include "gbaedge_gen.inc"
