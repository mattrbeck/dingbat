@ gbaedge.s — GBA hardware edge-case probe ROM (built by gbaedge.py;
@ docs/hwprobe.md catalogs every page).  Probes store RAW observed values
@ into 32-byte slots at 0x02000000; the viewer pages through them as hex.
@ Real hardware is the oracle — nothing here encodes an expected value.
@
@ Page/slot order (viewer order == slot index; run order differs so the
@ BIOS open-bus probes execute before the first SWI dirties the latch and
@ IORW reads the write-only IO before any probe writes it):
@   0 IDENT     1 OPENBUS   2 BIOSPROT  3 SWITIME  4 TIMERS   5 DMALATCH
@   6 LDMSTM    7 MULFLAGS  8 MSRTBIT*  9 PPUSTAT 10 PSGSTAT 11 WAITSTATE
@  12 PFPHASE  13 SWIREGION 14 CONTEND 15 IRQLAT  16 IORW    17 CPSRBITS
@  18 THUMBPC  19 LDMUSER  20 IRQWIN   21 DMAEDGE 22 CAPDMA  23 SWEEPQ
@  24 BXDECODE* 25 THUMBPC2 26 IRQWIN2 27 IOBYTE  28 LDMUSER2 29 PCWB2
@  30 DMABYTE2 31 SWEEP2   32 IRQWIN3  33 IRQLAT2 34 IOBYTE2 35 THUMBPC3
@  36 MSRTBIT2  37 OBJBUDGET† 38 OBJGEOM† 39 DMAOPENBUS
@  40 IRQDECOMP 41 CONTEND2 42 MULTIME  43 TIMPHASE 44 PSGPHASE
@  45 MEMCTL   46 DMATIME  47 IWCYCLE  48 DMAFIFO  49 UNDMODE‡
@ (†visual: the page is a picture drawn with OBJs in mode 0, not a hex
@  dump — tests/roms/README-probes-gba.md says what to photograph)
@ (‡UNDMODE writes an undefined CPSR mode number: HOLD SELECT AT POWER-ON
@  to skip it, since a console that wedges there shows no page at all)
@ (*interactive: runs when START is pressed on its page — these two
@  deliberately provoke UNPREDICTABLE behavior (MSR setting T from ARM /
@  executing near-BX encodings) and can require a power cycle, though a
@  timer-IRQ watchdog tries to recover first)
@
@ The question list is docs/hwprobe-questions.md; results are in
@ docs/hwprobe-results-agb.md.  Pages 28-36 each isolate a model split the
@ earlier pages could not separate; their comment blocks carry the
@ discriminator math.
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

    @ zero every slot, and the IRQ scratch block (EWRAM boots as noise)
    ldr r0, =SLOTS
    mov r1, #(37 * SLOTSZ / 4)     @ the session-4 slot count: the v7 slots
    mov r2, #0                     @ are zeroed in probe_tail so the frame
1:  str r2, [r0], #4               @ phase PPUSTAT/IRQLAT see is unchanged
    subs r1, r1, #1
    bne 1b
    ldr r0, =SCRATCH + 0x40
    mov r1, #8
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
    bl  probe_iorw                 @ before any probe writes IO registers
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
    bl  probe_contend
    bl  probe_irqlat
    bl  probe_cpsrbits
    bl  probe_thumbpc
    bl  probe_ldmuser
    bl  probe_irqwin
    bl  probe_dmaedge
    bl  probe_capdma
    bl  probe_sweepq
    bl  probe_thumbpc2
    bl  probe_irqwin2
    bl  probe_iobyte
    bl  probe_ldmuser2
    bl  probe_pcwb2
    bl  probe_dmabyte2
    bl  probe_sweep2
    bl  probe_irqwin3
    bl  probe_irqlat2
    bl  probe_iobyte2
    bl  probe_thumbpc3
    bl  probe_tail                 @ msrtbit2 + the v7 pages (37-39): one
                                   @ call so no earlier byte moves
    @ MSRTBIT + BXDECODE: interactive only — mark the slots so the pages
    @ say so
    ldr r8, =SLOTS + 8*SLOTSZ
    mov r0, #0x99
    strb r0, [r8, #0]
    mov r0, #0xEE
    strb r0, [r8, #31]
    ldr r8, =SLOTS + 24*SLOTSZ
    mov r0, #0x99
    strb r0, [r8, #0]
    mov r0, #0xEE
    strb r0, [r8, #31]
.ifdef MSRBOOT                     @ debug builds: run them unattended
    bl  run_msr_probe
    bl  run_bxdecode               @ one candidate per call
    bl  run_bxdecode
    bl  run_bxdecode
    bl  run_bxdecode
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
    bl  draw_page2                 @ v7: hex page, or a visual page (37/38)
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
    tst r2, #0x04                  @ SELECT
    bne 6f
    tst r2, #0x08                  @ START
    beq view_loop
    cmp r5, #8                     @ meaningful on the interactive pages
    bne 5f
    bl  run_msr_probe
    b   page_redraw
5:  cmp r5, #24
    bne view_loop
    bl  run_bxdecode               @ START: run the NEXT candidate only
    b   page_redraw
6:  cmp r5, #24                    @ SELECT on the BXDECODE page: skip the
    bne view_loop                  @ next candidate (for one that wedges
    bl  bx_skip                    @ the console — power cycle, then skip)
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
    bl  draw_page2
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
    ldr r0, =0x04000100            @ first thing: timestamp the entry
    ldrh r1, [r0]                  @ (TM0 keeps running through the IRQ)
    ldr r0, =SCRATCH
    ldr r2, [r0, #0x4C]            @ only the FIRST entry since the flag
    cmp r2, #0                     @ was cleared gets recorded — repeat
    streqh r1, [r0, #0x48]         @ fires must not overwrite it
    ldreq r3, [sp, #20]            @ the interrupted return address: tells
    streq r3, [r0, #0x50]          @ IRQWIN which sled instruction was next
    moveq r2, #1
    streq r2, [r0, #0x4C]
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
    ldr r3, [r2, #20]              @ recovery address the probe deposited
    str r3, [sp, #20]              @ divert the IRQ return to recovery
                                   @ (MSRTBIT or BXDECODE — whoever armed)
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
@ +0  word at 0x10000000 right after a DMA3 ROM->EWRAM (is the DMA latch
@     what open bus returns now?)
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
@ logic; deterministic on silicon.  8 operand
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
@ Whether a ROM data access pays an extra prefetch cycle depends on bus
@ phase (dingbat's bus model: `elapsed mod s == s-1`, fitted to the mGBA
@ suite's CPU column).  This page reads the rule off silicon:
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
@ SWI costs by caller region and operand size (dingbat's SWI_HLE_BASE is
@ calibrated on the mGBA suite's IWRAM column only).
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

@ ── slot 14: CONTEND — PPU/CPU memory contention ─────────────────────────
@ Hardware stalls the CPU when the renderer owns the bus (bus.nim's
@ ACCESS_TIMING_TABLE charges PRAM/VRAM/OAM a constant).  Every access
@ here is on-die, so the flashcart cannot influence this page.  Rendering
@ load: mode 3 bitmap + OBJ enabled (mode3 streams VRAM continuously).
@ +0..7   16x ldrh from PRAM/VRAM/OAM/EWRAM, mid-line visible (halfwords)
@ +8..15  the same four under FORCED BLANK (the free-access baseline)
@ +16..21 8x ldrh PRAM/VRAM/OAM inside hblank
@ +22     16x ldrh VRAM during vblank
@ +24     8x strh to VRAM mid-line visible    +26  same in forced blank
probe_contend:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 14*SLOTSZ
    mov r4, #IOBASE
    ldr r0, =0x1403                @ mode 3, BG2 + OBJ: heavy VRAM traffic
    strh r0, [r4]

.macro cont_reads base, n, off
    ldr r2, =\base
    bl  tm_start
    .rept \n
    ldrh r3, [r2]
    .endr
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
.macro cont_writes base, n, off
    ldr r2, =\base
    bl  tm_start
    .rept \n
    strh r3, [r2]
    .endr
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
.macro wait_line40
1:  ldrh r0, [r4, #6]
    cmp r0, #39
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #40
    bne 2b
.endm

    wait_line40
    cont_reads 0x05000000, 16, 0
    wait_line40
    cont_reads 0x06000000, 16, 2
    wait_line40
    cont_reads 0x07000000, 16, 4
    wait_line40
    cont_reads 0x02000000, 16, 6
    ldr r0, =0x1483                @ forced blank
    strh r0, [r4]
    cont_reads 0x05000000, 16, 8
    cont_reads 0x06000000, 16, 10
    cont_reads 0x07000000, 16, 12
    cont_reads 0x02000000, 16, 14
    ldr r0, =0x1403
    strh r0, [r4]
1:  ldrh r0, [r4, #4]              @ wait hblank flag low, then its rise
    tst r0, #2
    bne 1b
2:  ldrh r0, [r4, #4]
    tst r0, #2
    beq 2b
    cont_reads 0x05000000, 8, 16
2:  ldrh r0, [r4, #4]
    tst r0, #2
    beq 2b
    cont_reads 0x06000000, 8, 18
2:  ldrh r0, [r4, #4]
    tst r0, #2
    beq 2b
    cont_reads 0x07000000, 8, 20
    bl  wait_vblank
    cont_reads 0x06000000, 16, 22
    wait_line40
    cont_writes 0x06012C00, 8, 24  @ VRAM well away from the visible bitmap
    ldr r0, =0x1483
    strh r0, [r4]
    cont_writes 0x06012C00, 8, 26
    ldr r0, =0x0403                @ restore the viewer's DISPCNT
    strh r0, [r4]
    pop {r4-r7, pc}
    .ltorg

@ ── slot 15: IRQLAT — IRQ recognition latency per source ─────────────────
@ dingbat's IRQ_SYNC_DELAY / HBLANK_IRQ_SYNC_DELAY are each fitted to one
@ mGBA-suite row.  Here every IRQ entry is timestamped
@ against free-running TM0 by the handler itself; the trigger instant is
@ timestamped by the arming code.  The per-source (entry - trigger)
@ deltas share every fixed cost (BIOS dispatch, pipeline), so the
@ DIFFERENCES between sources are pure synchronizer latency.
@ +0/+2   TM2-overflow IRQ: trigger TM0 stamp / handler TM0 stamp
@ +4/+6   DMA3-complete IRQ: the same pair
@ +8/+10  hblank IRQ: DISPSTAT-armed, trigger stamp is the poll exit
@ +12/+14 vblank IRQ: the same pair
probe_irqlat:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 15*SLOTSZ
    ldr r7, =SCRATCH
    mov r4, #IOBASE

.macro irq_arm ie_bits
    ldr r5, =0x04000200
    mov r0, #\ie_bits
    strh r0, [r5]
    ldr r0, =0x3FFF
    strh r0, [r5, #2]              @ ack everything stale
    ldr r5, =0x04000208
    mov r0, #1
    strh r0, [r5]
.endm
.macro irq_disarm
    ldr r5, =0x04000208
    mov r0, #0
    strh r0, [r5]
    ldr r5, =0x04000200
    mov r0, #0
    strh r0, [r5]
.endm
.macro irq_spin
    ldr r6, =0x00040000
9:  subs r6, r6, #1
    beq 8f
    ldr r0, [r7, #0x4C]            @ handler sets this flag
    cmp r0, #0
    beq 9b
8:
.endm

    bl  tm_start                   @ TM0 free-runs as the session clock

    @ ── TM2 overflow ──
    mov r0, #0
    str r0, [r7, #0x4C]
    ldr r5, =0x04000108            @ TM2
    str r0, [r5]
    irq_arm 0x20                   @ IE: timer 2 (macro CLOBBERS r5 —
    ldr r5, =0x04000108            @ reload it, or the arming word lands
                                   @ on IME)
    ldr r0, =0x00C00000            @ reload 0: one overflow 65536 cycles
    str r0, [r5]                   @ in (enable + IRQ); TM0 wraps too, so
                                   @ the mod-2^16 delta is still the latency
    ldr r6, =0x04000100
    ldrh r0, [r6]                  @ trigger-side stamp
    strh r0, [r8, #0]
    irq_spin
    irq_disarm
    mov r0, #0
    str r0, [r5]
    ldrh r0, [r7, #0x48]
    strh r0, [r8, #2]

    @ ── DMA3 complete ──
    mov r0, #0
    str r0, [r7, #0x4C]
    irq_arm 0x0800                 @ IE: DMA3
    ldr r5, =0x040000D4
    ldr r0, =rom_pattern
    str r0, [r5]
    ldr r1, =EWDST
    str r1, [r5, #4]
    ldr r6, =0x04000100
    ldrh r0, [r6]
    strh r0, [r8, #4]
    ldr r0, =0xC4000004            @ enable + IRQ, word, count 4
    str r0, [r5, #8]
    irq_spin
    irq_disarm
    ldrh r0, [r7, #0x48]
    strh r0, [r8, #6]

    @ ── hblank ──
    mov r0, #0
    str r0, [r7, #0x4C]
    ldrh r0, [r4, #4]
    orr r0, r0, #0x10              @ DISPSTAT hblank IRQ enable
    strh r0, [r4, #4]
    irq_arm 0x02
    ldr r6, =0x04000100
    ldrh r0, [r6]
    strh r0, [r8, #8]
    irq_spin
    irq_disarm
    ldrh r0, [r4, #4]
    bic r0, r0, #0x10
    strh r0, [r4, #4]
    ldrh r0, [r7, #0x48]
    strh r0, [r8, #10]

    @ ── vblank ──
    mov r0, #0
    str r0, [r7, #0x4C]
    ldrh r0, [r4, #4]
    orr r0, r0, #0x08
    strh r0, [r4, #4]
    irq_arm 0x01
    ldr r6, =0x04000100
    ldrh r0, [r6]
    strh r0, [r8, #12]
    irq_spin
    irq_disarm
    ldrh r0, [r4, #4]
    bic r0, r0, #0x08
    strh r0, [r4, #4]
    ldrh r0, [r7, #0x48]
    strh r0, [r8, #14]

    bl  tm_stop
    pop {r4-r7, pc}
    .ltorg

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
    ldr r0, =msr_recover
    str r0, [r2, #20]              @ where the watchdog should divert to
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

@ ═══════ pages 16-24 (question list: docs/hwprobe-questions.md) ══════════

.equ CAPDST,   0x02008000          @ CAPDMA destination ring
.equ BXBLOCK,  0x03000300          @ BXDECODE candidate block (IWRAM copy)
.equ PCWB2BLK, 0x02005000          @ PCWB2 candidate block (EWRAM copy)

@ ── slot 16: IORW — write-only / unused IO read map ──────────────────────
@ Do write-only and unused IO reads return zero or open bus?  16 halfword
@ reads in table order, stored raw.  Runs BEFORE any probe writes IO, so
@ write-only registers still hold boot values and the answer is purely
@ "what does a read return".
probe_iorw:
    push {r4-r6, lr}
    ldr r4, =SLOTS + 16*SLOTSZ
    ldr r5, =iorw_offsets
    mov r6, #16
    ldr r3, =IOBASE
1:  ldrh r0, [r5], #2
    ldrh r0, [r3, r0]
    strh r0, [r4], #2
    subs r6, r6, #1
    bne 1b
    pop {r4-r6, pc}
iorw_offsets:
    .hword 0x010                   @ BG0HOFS   (write-only)
    .hword 0x028                   @ BG2X_L    (write-only)
    .hword 0x040                   @ WIN0H     (write-only)
    .hword 0x04C                   @ MOSAIC    (write-only)
    .hword 0x04E                   @ unused
    .hword 0x054                   @ BLDY      (write-only)
    .hword 0x056                   @ unused
    .hword 0x066                   @ unused
    .hword 0x06A                   @ unused
    .hword 0x078                   @ unused
    .hword 0x110                   @ unused (timer gap)
    .hword 0x12C                   @ unused
    .hword 0x136                   @ unused (lore: reads 0, not open bus)
    .hword 0x142                   @ unused
    .hword 0x206                   @ unused
    .hword 0x20A                   @ unused
    .ltorg

@ ── slot 17: CPSRBITS — which CPSR/SPSR bits are actually writable ───────
@ Which CPSR/SPSR bits are physically writable, and what an SPSR read
@ returns in a mode that has none.  All-ones writes per MSR field, raw
@ mrs readback.
@ +0  CPSR after msr CPSR_f, 0xFF000000
@ +4  CPSR after msr CPSR_s, 0x00FF0000
@ +8  CPSR after msr CPSR_x, 0x0000FF00
@ +12 SPSR_irq after msr SPSR_cxsf, 0xFFFFFFFF
@ +16 SPSR_irq after msr SPSR_cxsf, 0x00000000
@ +20 SPSR_irq after msr SPSR_cxsf, 0x0000000F (is bit4 forced high?)
@ +24 mrs SPSR in SYSTEM mode (no SPSR exists — what does it return?)
probe_cpsrbits:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 17*SLOTSZ
    mrs r7, CPSR                   @ saved state to restore
    ldr r0, =0xFF000000
    msr CPSR_f, r0
    mrs r1, CPSR
    str r1, [r8, #0]
    ldr r0, =0x00FF0000
    msr CPSR_s, r0
    mrs r1, CPSR
    str r1, [r8, #4]
    ldr r0, =0x0000FF00
    msr CPSR_x, r0
    mrs r1, CPSR
    str r1, [r8, #8]
    msr CPSR_cxsf, r7              @ full restore, whatever latched above
    bic r0, r7, #0x1F              @ -> IRQ mode, IRQs masked
    orr r0, r0, #0x92
    msr CPSR_c, r0
    ldr r0, =0xFFFFFFFF
    msr SPSR_cxsf, r0
    mrs r1, SPSR
    str r1, [r8, #12]
    mov r0, #0
    msr SPSR_cxsf, r0
    mrs r1, SPSR
    str r1, [r8, #16]
    mov r0, #0x0F
    msr SPSR_cxsf, r0
    mrs r1, SPSR
    str r1, [r8, #20]
    msr CPSR_c, r7                 @ back to system mode
    mrs r1, SPSR                   @ ARM7TDMI has no SPSR here
    str r1, [r8, #24]
    pop {r4-r7, pc}
    .ltorg

@ ── slot 18: THUMBPC — r15 as operand: stored values + the CMP theory ────
@ Does Thumb CMP with rd=r15 load SPSR into CPSR (like the ARM S-suffix
@ r15 forms)?  Plus the stored-PC offsets.
@ +0  byte: (value stored by `str pc`) - instruction address
@ +1  byte: same for `stmia r4, {pc}`
@ +2  byte: same for the pc entry of `stmia r4, {lr, pc}`
@ +4  word: r1 after `ldmia pc, {r1}` (raw word tells the fetch offset)
@ +8  word: CPSR flags after Thumb `cmp pc, r0` with r0=0 and SPSR set to
@           a distinct flag pattern (0x20000000 = normal compare;
@           the SPSR pattern = the SPSR-load theory)
@ +12 word: SPSR after the same (did the CMP touch it?)
@ +16 byte: Thumb `mov r0, pc` delta
probe_thumbpc:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 18*SLOTSZ
    ldr r4, =EWDST
1:  str pc, [r4]
    ldr r0, [r4]
    adr r1, 1b
    sub r0, r0, r1
    strb r0, [r8, #0]
2:  .word 0xE8848000               @ stmia r4, {pc}
    ldr r0, [r4]
    adr r1, 2b
    sub r0, r0, r1
    strb r0, [r8, #1]
3:  .word 0xE884C000               @ stmia r4, {lr, pc}
    ldr r0, [r4, #4]               @ pc is the second (ascending) entry
    adr r1, 3b
    sub r0, r0, r1
    strb r0, [r8, #2]
    mov r1, #0
4:  .word 0xE89F0002               @ ldmia pc, {r1}
    b   5f
    .word 0xC0DEC0DE               @ sits at 4b+8
5:  str r1, [r8, #4]
    @ Thumb CMP pc, r0 with a loaded SPSR: IRQ mode, SPSR = CPSR pattern
    @ with N|C flags (mode bits = IRQ so a "load" cannot wander off)
    mrs r7, CPSR
    bic r0, r7, #0x1F
    orr r0, r0, #0x92              @ IRQ mode, I set
    msr CPSR_c, r0
    mrs r1, CPSR
    bic r1, r1, #0xF0000000
    orr r1, r1, #0xA0000000        @ N and C
    msr SPSR_cxsf, r1
    msr CPSR_f, #0                 @ flags cleared going in
    mov r0, #0                     @ cmp operand
    adr r3, 7f                     @ ARM return target for the pad's bx
    adr r1, 6f
    orr r1, r1, #1
    bx  r1                         @ enter the Thumb pad
    .thumb
6:  .hword 0x4587                  @ cmp pc, r0  (hi-register CMP)
    .hword 0x4718                  @ bx r3
    .align 2
    .arm
7:  mrs r1, CPSR
    str r1, [r8, #8]
    mrs r1, SPSR
    str r1, [r8, #12]
    msr CPSR_c, r7                 @ back to system mode
    msr CPSR_f, r7
    @ Thumb mov r0, pc delta
    adr r3, 9f
    adr r1, 8f
    orr r1, r1, #1
    bx  r1
    .thumb
8:  .hword 0x4678                  @ mov r0, pc
    .hword 0x4718                  @ bx r3
    .align 2
    .arm
9:  adr r1, 8b
    sub r0, r0, r1
    strb r0, [r8, #16]
    pop {r4-r7, pc}
    .ltorg

@ ── slot 19: LDMUSER — user-bank transfers with banked bases ─────────────
@ User-bank transfers with a banked base register, and the SPSR read in
@ the cycle after an LDM^ (does it come back OR'd with CPSR?).  All
@ experiments from IRQ mode, IRQs masked,
@ with sp_irq pointed at scratch; user r13 is parked on a marker value and
@ restored afterwards (system mode shares the user bank).
@ +0  word stored by `stmia r4, {r13}^`  (user r13 marker = CAFE0001?)
@ +4  word: r4 writeback delta after `stmia r4!, {r13}^` (UNPREDICTABLE)
@ +8  word: stored value of `stmia r13!, {r13}^` (banked base, user list)
@ +12 word: r13_irq delta after that (did writeback hit the banked bank?)
@ +16 word: user r13 delta after that (or the user bank?)
@ +20 word: mrs SPSR executed IMMEDIATELY after `ldmia r4, {r1}^`
@           (SPSR was pre-set to 0x600000D2; the OR-with-CPSR theory
@           predicts a merge, plain silicon predicts it unchanged)
@ +24 word: the r1 that ldm^ loaded (sanity: 0x12345678)
probe_ldmuser:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 19*SLOTSZ
    ldr r4, =EWDST
    ldr r0, =0x12345678            @ ldm^ source value
    str r0, [r4, #0x20]
    mrs r7, CPSR
    mov r9, sp                     @ park the user/system sp on a marker
    ldr r0, =0xCAFE0001
    mov sp, r0
    bic r0, r7, #0x1F              @ -> IRQ mode, I set
    orr r0, r0, #0x92
    msr CPSR_c, r0
    ldr sp, =SCRATCH + 0xF0        @ sp_irq: valid but unused scratch
    @ 1: plain user-bank store
    .word 0xE8C42000               @ stmia r4, {r13}^
    ldr r0, [r4]
    str r0, [r8, #0]
    @ 2: writeback + user list, non-banked base
    .word 0xE8E42000               @ stmia r4!, {r13}^   (UNPREDICTABLE)
    ldr r1, =EWDST
    sub r0, r4, r1
    str r0, [r8, #4]
    ldr r4, =EWDST                 @ restore r4 whatever happened
    @ 3: banked base + user list + writeback
    ldr r0, =EWDST + 0x40
    mov sp, r0                     @ r13_irq = base
    .word 0xE8ED2000               @ stmia r13!, {r13}^
    ldr r1, =EWDST + 0x40
    ldr r0, [r1]                   @ what got stored
    str r0, [r8, #8]
    sub r0, sp, r1                 @ banked writeback delta
    str r0, [r8, #12]
    @ 4: SPSR in the shadow of an ldm^
    ldr r0, =0x600000D2            @ distinct-but-legal pattern (IRQ mode)
    msr SPSR_cxsf, r0
    add r4, r4, #0x20
    .word 0xE8D40002               @ ldmia r4, {r1}^ (user-bank load)
    mrs r2, SPSR                   @ THE read theorized to come back OR'd
    str r2, [r8, #20]
    str r1, [r8, #24]
    sub r4, r4, #0x20
    msr CPSR_c, r7                 @ back to system mode
    ldr r0, =0xCAFE0001            @ user r13 delta from the marker
    sub r0, sp, r0
    str r0, [r8, #16]
    mov sp, r9                     @ real stack back
    pop {r4-r11, pc}
    .ltorg

@ ── slot 20: IRQWIN — when are IME / I-bit / IE sampled? ─────────────────
@ What takes priority when an IRQ asserts in the same cycle IE/IF/IME
@ are written, and when CPSR.I and the IRQ line are actually sampled.
@ A TM2 overflow is parked in IF, then one gate at a time is opened with
@ an 8-instruction
@ breadcrumb sled right behind the opening store; the IRQ handler records
@ the interrupted return address, i.e. HOW MANY sled instructions ran
@ before dispatch.
@ +0  halfword: sled byte offset for the IME 0->1 store
@ +2  halfword: sled byte offset for msr clearing CPSR.I
@ +4  halfword: sled byte offset for the IE 0->0x20 store
@ +6  halfword: of 16 back-to-back IF acks against a TM2 overflowing
@               every 16 cycles, how many reads saw IF still/again set
probe_irqwin:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 20*SLOTSZ
    ldr r7, =SCRATCH
    ldr r4, =0x04000200            @ r4 -> IE/IF, r4+8 -> IME
.macro iw_prime                    @ park a TM2-overflow bit in IF
    ldr r5, =0x04000108
    mov r0, #0
    str r0, [r5]
    str r0, [r7, #0x4C]            @ handler first-entry flag
    str r0, [r7, #0x50]            @ stale return address (0 = no dispatch)
    ldr r0, =0x00C0FFFF            @ reload 0xFFFF, enable + IRQ: one tick
    str r0, [r5]
    mov r1, #0x10000               @ BOUNDED: an emulator that never sets
1:  ldrh r0, [r4, #2]              @ IF here must not hang the whole ROM
    tst r0, #0x20
    bne 2f
    subs r1, r1, #1
    bne 1b
2:  mov r0, #0
    str r0, [r5]                   @ timer off again; IF stays parked
.endm
.macro iw_sled slot_off, base_lbl
    ldr r0, [r7, #0x50]            @ return address the handler saw
    adr r1, \base_lbl
    sub r0, r0, r1
    strh r0, [r8, #\slot_off]
.endm
    @ ── experiment 1: IME is the last gate to open ──
    mov r0, #0
    strh r0, [r4, #8]              @ IME off
    mov r0, #0x20
    strh r0, [r4]                  @ IE = timer2
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]              @ IME on — dispatch races the sled
iw1:
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    iw_sled 0, iw1
    mov r0, #0
    strh r0, [r4, #8]
    @ ── experiment 2: CPSR.I is the last gate ──
    mrs r5, CPSR
    orr r0, r5, #0x80
    msr CPSR_c, r0                 @ I set
    mov r0, #1
    strh r0, [r4, #8]              @ IME already on
    iw_prime
    mrs r0, CPSR
    bic r0, r0, #0x80
    msr CPSR_c, r0                 @ I cleared — dispatch races the sled
iw2:
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    iw_sled 2, iw2
    @ ── experiment 3: IE is the last gate ──
    mov r0, #0
    strh r0, [r4]                  @ IE off, IME stays on
    iw_prime
    mov r0, #0x20
    strh r0, [r4]                  @ IE on — dispatch races the sled
iw3:
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    add r6, r6, #1
    iw_sled 4, iw3
    mov r0, #0
    strh r0, [r4, #8]              @ IME off
    strh r0, [r4]                  @ IE off
    @ ── experiment 4: IF ack racing a fresh assertion ──
    ldr r5, =0x04000108
    str r0, [r5]
    ldr r0, =0x00C0FFF0            @ overflow every 16 cycles, repeating
    str r0, [r5]
    mov r6, #0                     @ survivors
    mov r2, #16
    mov r1, #0x20
1:  strh r1, [r4, #2]              @ ack timer2 IF
    ldrh r0, [r4, #2]              @ ...did it stay/return?
    tst r0, #0x20
    addne r6, r6, #1
    subs r2, r2, #1
    bne 1b
    strh r6, [r8, #6]
    mov r0, #0
    str r0, [r5]                   @ TM2 off
    strh r0, [r4, #2]              @ nothing pending... (write 0 = no ack)
    mov r0, #0x20
    strh r0, [r4, #2]              @ ack the parked bit properly
    pop {r4-r7, pc}
    .ltorg

@ ── slot 21: DMAEDGE — byte writes to DMA3CNT and disable-before-start ───
@ Can a byte-sized write of 0x80 to the wrong DMA3CNT byte still enable
@ the DMA (bus byte-mirroring), and does it affect all bits?  Plus
@ disable-before-start.  DMA3 is primed with valid src/dst/len before
@ each poke; the destination marker says if it ran.
@ +0  byte: transfer ran after strb 0x80 -> 0x040000DF (the enable byte)
@ +2  halfword: DMA3CNT_H readback after that
@ +4  byte: transfer ran after strb 0x80 -> 0x040000DE (LOW byte — enable
@           lives in the OTHER byte; 1 here = byte-mirroring)
@ +6  halfword: DMA3CNT_H readback after that
@ +8  byte: transfer ran after strb 0x80 -> 0x040000DD (CNT_L high byte)
@ +10 halfword: DMA3CNT_H readback after that
@ +12 byte: transfer ran when a vblank DMA was enabled then disabled
@           again before any vblank could trigger it
@ +14 halfword: DMA3CNT_H readback after that
probe_dmaedge:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 21*SLOTSZ
    ldr r4, =0x040000D4            @ DMA3SAD
.macro de_prime
    ldr r0, =rom_pattern
    str r0, [r4]                   @ SAD
    ldr r5, =EWDST + 0x100
    mov r0, #0
    str r0, [r5]                   @ clear the marker
    str r5, [r4, #4]               @ DAD
    mov r0, #4
    strh r0, [r4, #8]              @ CNT_L: 4 units
    mov r0, #0
    strh r0, [r4, #10]             @ CNT_H: fully disabled, plain config
.endm
.macro de_verdict slot_off
    ldr r5, =EWDST + 0x100
    ldr r0, [r5]
    cmp r0, #0
    movne r0, #1
    strb r0, [r8, #\slot_off]
    ldrh r0, [r4, #10]
    strh r0, [r8, #\slot_off + 2]
    mov r0, #0
    strh r0, [r4, #10]             @ off again
.endm
    de_prime
    mov r0, #0x80
    ldr r1, =0x040000DF
    strb r0, [r1]                  @ enable via its own byte
    nop
    nop
    nop
    nop
    de_verdict 0
    de_prime
    mov r0, #0x80
    ldr r1, =0x040000DE
    strb r0, [r1]                  @ the OTHER byte — should not enable
    nop
    nop
    nop
    nop
    de_verdict 4
    de_prime
    mov r0, #0x80
    ldr r1, =0x040000DD
    strb r0, [r1]                  @ CNT_L high byte
    nop
    nop
    nop
    nop
    de_verdict 8
    @ enable a vblank DMA, kill it before any vblank, then let one pass
    de_prime
    ldr r0, =0x9000                @ enable + vblank timing
    strh r0, [r4, #10]
    mov r0, #0
    strh r0, [r4, #10]             @ disabled before it could start
    bl  wait_vblank
    bl  wait_vblank
    de_verdict 12
    pop {r4-r7, pc}
    .ltorg

@ ── slot 22: CAPDMA — does video-capture DMA3 run every other frame? ─────
@ Does video-capture DMA3 run only every other frame (screen polarity
@ inversion)?  DMA3 is armed in Special timing with repeat from a fixed
@ ROM word into an incrementing EWRAM ring; the written-word count is
@ snapshotted after each of three frames.  Per-frame deltas of ~160*4
@ mean every frame/line; alternating deltas mean every other frame; 0
@ means Special DMA3 needs something this setup lacks.
@ +0/+4/+8  word counts after frames 1/2/3     +12  DMA3CNT_H readback
@ Hardware: one armed frame transfers 160 triggers then the enable
@ SELF-CLEARS, so the question only applies to the pattern games actually
@ use, re-arming every vblank:
@ +16/+20/+24  cumulative word counts after re-arming at three successive
@ vblanks (equal steps = every re-armed frame captures; a flat step =
@ every other frame)                            +28  final CNT_H readback
probe_capdma:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 22*SLOTSZ
    ldr r0, =CAPDST                @ zero the ring
    mov r1, #0x1000
    mov r2, #0
1:  str r2, [r0], #4
    subs r1, r1, #1
    bne 1b
    bl  wait_vblank                @ arm at a frame boundary
    ldr r4, =0x040000D4
    ldr r0, =rom_pattern           @ nonzero source, held fixed
    str r0, [r4]
    ldr r0, =CAPDST
    str r0, [r4, #4]
    mov r0, #4
    strh r0, [r4, #8]              @ 4 words per trigger
    ldr r0, =0xB700                @ enable+repeat+special+word+src-fixed
    strh r0, [r4, #10]
    mov r7, #0
2:  bl  wait_vblank
    bl  capdma_count
    str r0, [r8, r7]
    add r7, r7, #4
    cmp r7, #12
    blt 2b
    ldrh r0, [r4, #10]             @ still armed? (StopVideoTransferDMA q)
    strh r0, [r8, #12]
    mov r0, #0
    strh r0, [r4, #10]
    @ the game pattern — re-arm at each vblank, count per frame
    mov r7, #16
2:  bl  wait_vblank                @ frame boundary: arm for this frame
    ldr r0, =0xB700
    strh r0, [r4, #10]
    bl  wait_vblank                @ the armed frame has now run
    bl  capdma_count
    str r0, [r8, r7]
    add r7, r7, #4
    cmp r7, #28
    blt 2b
    ldrh r0, [r4, #10]
    strh r0, [r8, #28]             @ did the re-armed enable self-clear too
    mov r0, #0
    strh r0, [r4, #10]
    pop {r4-r7, pc}
capdma_count:                      @ -> r0 = nonzero words in the ring
    ldr r1, =CAPDST
    mov r2, #0x1000
    mov r0, #0
1:  ldr r3, [r1], #4
    cmp r3, #0
    addne r0, r0, #1
    subs r2, r2, #1
    bne 1b
    bx  lr
    .ltorg

@ ── slot 23: SWEEPQ — PSG sweep-unit specifics, CPU-visible via the ch1
@ active flag ─────────────────────────────────────────────────────────────
@ Sweep-unit corners: divider==0 behavior, the immediate recalc on
@ trigger, the second not-written-back recalc, and mid-note divider
@ changes.  Each row is "poll iterations until SOUNDCNT_X bit0 dropped"
@ (word, capped) — the competing models predict different death times.
@ +0  freq 1024, shift 1, period 0: period-0-acts-as-8 vs never-ticks
@ +4  freq 1400, shift 1, period 2: the IMMEDIATE trigger recalc already
@     overflows -> near-zero count if it exists
@ +8  freq 1300, shift 1, period 2: immediate recalc survives; dies on a
@     later tick (control for +4)
@ +12 freq 1000, shift 1, period 2: first tick writes 1500, its unwritten
@     SECOND check overflows -> dies tick 1 with the check, tick 2 without
@ +16 freq 1024, shift 1, period 7 -> period rewritten to 1 mid-note:
@     immediate reload vs next-reload
@ +20 control: length-63 death, no sweep (cross-check with PSGSTAT)
@ Hardware killed +16 INSTANTLY and +20 in 75 polls; +24/+28 decompose
@ those:
@ +24 the +16 experiment but rewriting NR10 with the SAME value 0x71:
@     separates "any NR10 write kills mid-note" from "the period change"
@ +28 the +20 length control re-run after two idle frames: separates a
@     trigger-adjacent length clock from frame-sequencer phase left over
@     from the preceding experiments
probe_sweepq:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 23*SLOTSZ
    ldr r4, =0x04000060            @ SOUND1CNT_L base
    ldr r5, =0x04000080            @ SOUNDCNT_L/H/X
    mov r0, #0x80
    strh r0, [r5, #4]              @ master enable
    ldr r0, =0x1177
    strh r0, [r5]                  @ route ch1
.macro sq_run sweep, freq, slot_off
    ldr r0, =\sweep
    strh r0, [r4]                  @ SOUND1CNT_L
    ldr r0, =0xF000
    strh r0, [r4, #2]              @ max envelope, no length
    ldr r0, =0x8000 + \freq
    strh r0, [r4, #4]              @ trigger, length disabled
    mov r6, #0
    ldr r7, =0x80000
9:  ldrh r0, [r5, #4]
    tst r0, #1
    beq 8f
    add r6, r6, #1
    cmp r6, r7
    blt 9b
8:  str r6, [r8, #\slot_off]
.endm
    sq_run 0x01, 1024, 0           @ shift 1, period 0, up
    sq_run 0x21, 1400, 4           @ shift 1, period 2, up
    sq_run 0x21, 1300, 8
    sq_run 0x21, 1000, 12
    @ mid-note divider change: start slow (period 7), rewrite to 1
    ldr r0, =0x71
    strh r0, [r4]
    ldr r0, =0xF000
    strh r0, [r4, #2]
    ldr r0, =0x8000 + 1024
    strh r0, [r4, #4]
    ldr r0, =20000                 @ ~1/8 of a period-7 tick
1:  subs r0, r0, #1
    bne 1b
    ldr r0, =0x11
    strh r0, [r4]                  @ period 7 -> 1 mid-note
    mov r6, #0
    ldr r7, =0x80000
2:  ldrh r0, [r5, #4]
    tst r0, #1
    beq 3f
    add r6, r6, #1
    cmp r6, r7
    blt 2b
3:  str r6, [r8, #16]
    @ control: pure length death
    mov r0, #0
    strh r0, [r4]                  @ sweep off
    ldr r0, =0xF03F                @ length 63
    strh r0, [r4, #2]
    ldr r0, =0xC000 + 1024         @ trigger + length enable
    strh r0, [r4, #4]
    mov r6, #0
    ldr r7, =0x80000
4:  ldrh r0, [r5, #4]
    tst r0, #1
    beq 5f
    add r6, r6, #1
    cmp r6, r7
    blt 4b
5:  str r6, [r8, #20]
    @ +24: mid-note rewrite with the SAME sweep value
    ldr r0, =0x71
    strh r0, [r4]
    ldr r0, =0xF000
    strh r0, [r4, #2]
    ldr r0, =0x8000 + 1024
    strh r0, [r4, #4]
    ldr r0, =20000
6:  subs r0, r0, #1
    bne 6b
    ldr r0, =0x71
    strh r0, [r4]                  @ 0x71 -> 0x71: no change at all
    mov r6, #0
    ldr r7, =0x80000
7:  ldrh r0, [r5, #4]
    tst r0, #1
    beq 8f
    add r6, r6, #1
    cmp r6, r7
    blt 7b
8:  str r6, [r8, #24]
    @ +28: length control again after two idle frames
    bl  wait_vblank
    bl  wait_vblank
    mov r0, #0
    strh r0, [r4]
    ldr r0, =0xF03F
    strh r0, [r4, #2]
    ldr r0, =0xC000 + 1024
    strh r0, [r4, #4]
    mov r6, #0
    ldr r7, =0x80000
9:  ldrh r0, [r5, #4]
    tst r0, #1
    beq 10f
    add r6, r6, #1
    cmp r6, r7
    blt 9b
10: str r6, [r8, #28]
    mov r0, #0
    strh r0, [r5, #4]              @ master off — silence again
    pop {r4-r7, pc}
    .ltorg

@ ── slot 24: BXDECODE — near-BX encodings: BX, no-op, or undefined? ──────
@ Encodings NEAR BX (SBO fields violated, the ARMv5 BLX word, BX r15).
@ Interactive (START on this page): candidates run from IWRAM with the
@ TM3 watchdog armed; breadcrumbs decide what actually executed.
@ Block layout per candidate (copied to BXBLOCK):
@   C+0  the candidate word, with r1 = thumb-pad address | 1
@   C+4  ARM fallthrough:  add r7, #2
@   C+8  ARM continuation: add r7, #4  (also the BX-r15 landing site)
@   C+12 bx r5 (recover)
@   pad  Thumb: add r7, #1 ; bx r5
@ r7 afterwards: 2+4=6 fell through, 1 took the BX to r1, 4 means the
@ candidate branched to $+8 (BX r15).  Watchdog phase byte 2 = it wedged
@ and the timer diverted the return.
@
@ A candidate can wedge the console beyond the IRQ watchdog's reach
@ (exception entry masks IRQs), so each START press runs ONE candidate
@ and the page redraws between presses; SELECT skips the next candidate (result byte
@ 0xDD) so a power cycle + skip harvests the survivors and the wedger is
@ identified by which press froze.
@ +0..+3  r7 per candidate (0xDD = skipped)   +4..+7  phase byte each
@ +8  0xAA all-four-done marker               +9  next candidate index
run_bxdecode:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 24*SLOTSZ
    ldrb r10, [r8, #9]             @ next candidate index
    cmp r10, #4
    bge bx_alldone
    cmp r10, #0                    @ +0 is ALSO candidate 0's result byte:
    moveq r0, #0                   @ only the first press may clear the
    streqb r0, [r8, #0]            @ 0x99 "press start" marker
    ldr r0, =bx_candidates
    ldr r9, [r0, r10, lsl #2]      @ candidate word
    @ build the block in IWRAM
    ldr r1, =BXBLOCK
    str r9, [r1, #0]
    ldr r0, =0xE2877002            @ add r7, r7, #2
    str r0, [r1, #4]
    ldr r0, =0xE2877004            @ add r7, r7, #4
    str r0, [r1, #8]
    ldr r0, =0xE12FFF15            @ bx r5
    str r0, [r1, #12]
    ldr r0, =0x47281C7F            @ thumb: adds r7, r7, #1 ; bx r5
    str r0, [r1, #16]
    ldr r2, =MARKER
    str sp, [r2, #12]
    mov r0, #0
    str r0, [r2, #16]
    ldr r0, =bx_recover
    str r0, [r2, #20]              @ watchdog divert target for THIS probe
    mrs r0, CPSR
    str r0, [r2, #24]              @ known-good CPSR — a candidate that
                                   @ decodes as a mode switch must not
                                   @ poison the following candidates
    mov r0, #1
    str r0, [r2, #8]               @ in-flight flag for the watchdog
    ldr r4, =0x0400010C            @ TM3 watchdog, 65536 cycles
    mov r0, #0
    str r0, [r4]
    ldr r0, =0x00C00000
    str r0, [r4]
    ldr r4, =0x04000200
    mov r0, #0x40
    strh r0, [r4]
    ldr r4, =0x04000208
    mov r0, #1
    strh r0, [r4]
    ldr r5, =bx_recover
    ldr r1, =BXBLOCK
    add r0, r1, #16
    orr r1, r0, #1                 @ r1 -> thumb pad (BX target)
    mov r7, #0
    ldr r0, =BXBLOCK
    bx  r0
bx_recover:
    ldr r2, =MARKER                @ r0-r7 are unbanked in every mode, so
    ldr r3, [r2, #24]              @ this sequence works even if the
    msr CPSR_cxsf, r3              @ candidate switched mode (r8/r10 come
    ldr sp, [r2, #12]              @ back with the mode restore)
    mov r0, #0                     @ watchdog off
    ldr r3, =0x04000208
    strh r0, [r3]
    ldr r3, =0x04000200
    strh r0, [r3]
    ldr r3, =0x0400010C
    str r0, [r3]
    strb r7, [r8, r10]             @ breadcrumb
    ldr r3, [r2, #8]               @ 1 = clean, 2 = watchdog fired
    add r0, r10, #4
    strb r3, [r8, r0]
    mov r0, #0
    str r0, [r2, #8]
    add r10, r10, #1
    strb r10, [r8, #9]             @ persist progress between presses
    cmp r10, #4
    movge r0, #0xAA
    strgeb r0, [r8, #8]
bx_alldone:
    pop {r4-r11, pc}

bx_skip:                           @ SELECT: mark the next candidate as
    ldr r8, =SLOTS + 24*SLOTSZ     @ skipped and move past it
    ldrb r1, [r8, #9]
    cmp r1, #4
    bxge lr
    mov r0, #0xDD
    strb r0, [r8, r1]              @ (this also replaces the 0x99 marker
    add r1, r1, #1                 @ when candidate 0 is the one skipped)
    strb r1, [r8, #9]
    cmp r1, #4
    movge r0, #0xAA
    strgeb r0, [r8, #8]
    bx  lr
bx_candidates:
    .word 0xE12FFF11               @ control: genuine BX r1
    .word 0xE12FFF31               @ the BLX-r1 encoding (ARMv5, not v4T)
    .word 0xE120FF11               @ BX with an SBO field violated
    .word 0xE12FFF1F               @ BX r15
    .ltorg

@ boot-time watchdog for recoverable UNPREDICTABLE rows (nothing in the
@ candidate path touches CPSR.I, so unlike BXDECODE the timer can always
@ fire): divert target deposited for the shared irq_handler diversion.
.macro wdg_arm rec
    ldr r2, =MARKER
    ldr r0, =\rec
    str r0, [r2, #20]
    mov r0, #1
    str r0, [r2, #8]
    ldr r2, =0x0400010C            @ TM3, 65536 cycles
    mov r0, #0
    str r0, [r2]
    ldr r0, =0x00C00000
    str r0, [r2]
    ldr r2, =0x04000200
    mov r0, #0x40
    strh r0, [r2]
    ldr r2, =0x04000208
    mov r0, #1
    strh r0, [r2]
.endm
.macro wdg_disarm
    ldr r2, =0x04000208
    mov r0, #0
    strh r0, [r2]
    ldr r2, =0x04000200
    strh r0, [r2]
    ldr r0, =0x3FFF
    strh r0, [r2, #2]
    ldr r2, =0x0400010C
    mov r0, #0
    str r0, [r2]
.endm

@ ── slot 25: THUMBPC2 — scope of the r15 SPSR-load + r15 writeback ───────
@ THUMBPC showed Thumb `cmp pc, r0` loading SPSR FLAGS into CPSR but
@ pinned SPSR's mode to the current mode.  Here SPSR = 0x9000009F (SYSTEM
@ mode, I set, N|V flags) while executing in IRQ mode, so the readback
@ mode bits say whether the restore is full-CPSR or flags-only; the
@ sibling hi-reg ADD/MOV pc forms get the same treatment; and the
@ LDM/LDR/STR base-writeback-to-r15 forms run under the timer watchdog
@ with distinct-breadcrumb sleds to find where execution lands.
@ +0  word CPSR after Thumb cmp pc, r0 (SPSR = 0x9000009F: mode bits 1F
@     here = full restore, 12 = flags-only)
@ +4  word SPSR read right after that (raw)
@ +8  word CPSR after Thumb add pc, r0 (same SPSR pattern)
@ +12 word CPSR after Thumb mov pc, r0
@ +16 byte r7 after add pc  (0 = branched to pad+8, 7 = fell through)
@ +17 byte r7 after mov pc  (0 = branched, 7 = fell through)
@ +18 byte r7 after `ldmia r15!, {r1}` sled (15 = executed as no-wb ldm,
@     12 = PC became base+4, 14 = PC became base, 8 = base+8)
@ +19 byte r7 after `str r1, [r15], #4` sled (same key)
@ +20 byte r7 after `ldr r1, [r15], #4` sled
@ +21 byte watchdog-fired bitmask for the three writeback rows
@ +24 word r1 the ldm-writeback loaded    +28 word r1 the ldr loaded
probe_thumbpc2:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 25*SLOTSZ
    mrs r9, CPSR                   @ saved good state (system mode)
    @ ── Thumb cmp pc, r0 with a DIFFERENT-mode SPSR ──
    bic r0, r9, #0x1F
    orr r0, r0, #0x92              @ IRQ mode, I set
    msr CPSR_c, r0
    ldr r0, =SCRATCH + 0xF0
    mov sp, r0                     @ sp_irq hygiene (never used)
    ldr r1, =0x9000009F            @ SYSTEM mode, I set, N|V
    msr SPSR_cxsf, r1
    msr CPSR_f, #0
    mov r0, #0
    adr r3, 21f
    adr r1, 20f
    orr r1, r1, #1
    bx  r1
    .thumb
20: .hword 0x4587                  @ cmp pc, r0
    .hword 0x4718                  @ bx r3
    .align 2
    .arm
21: mrs r1, CPSR
    str r1, [r8, #0]
    mrs r1, SPSR
    str r1, [r8, #4]
    msr CPSR_c, r9                 @ back to known system state
    msr CPSR_f, r9
    @ ── Thumb add pc, r0 (branch?  and does it touch CPSR?) ──
    bic r0, r9, #0x1F
    orr r0, r0, #0x92
    msr CPSR_c, r0
    ldr r1, =0x9000009F
    msr SPSR_cxsf, r1
    msr CPSR_f, #0
    mov r0, #4                     @ target = pad+4+4 = pad+8
    mov r7, #0
    adr r3, 23f
    adr r1, 22f
    orr r1, r1, #1
    bx  r1
    .thumb
22: .hword 0x4487                  @ add pc, r0
    .hword 0x3701                  @ +2: adds r7, #1   (fallthrough path)
    .hword 0x3702                  @ +4: adds r7, #2
    .hword 0x3704                  @ +6: adds r7, #4
    .hword 0x4718                  @ +8: bx r3         (branch target)
    .align 2
    .arm
23: mrs r1, CPSR
    str r1, [r8, #8]
    strb r7, [r8, #16]
    msr CPSR_c, r9
    @ ── Thumb mov pc, r0 ──
    bic r0, r9, #0x1F
    orr r0, r0, #0x92
    msr CPSR_c, r0
    ldr r1, =0x9000009F
    msr SPSR_cxsf, r1
    msr CPSR_f, #0
    adr r3, 25f
    adr r1, 24f
    add r0, r1, #7                 @ = pad+8 with bit0 set; ARM7TDMI MOV
    bic r0, r0, #1                 @ pc ignores bit0 — pass it even
    orr r1, r1, #1
    mov r7, #0
    bx  r1
    .thumb
24: .hword 0x4687                  @ mov pc, r0
    .hword 0x3701                  @ +2: adds r7, #1
    .hword 0x3702                  @ +4: adds r7, #2
    .hword 0x3704                  @ +6: adds r7, #4
    .hword 0x4718                  @ +8: bx r3
    .align 2
    .arm
25: mrs r1, CPSR
    str r1, [r8, #12]
    strb r7, [r8, #17]
    msr CPSR_c, r9
    msr CPSR_f, r9
    @ ── base-writeback-to-r15 rows, watchdogged ──
    mov r11, #0                    @ watchdog-fired bitmask
    wdg_arm tw_rec1
    mov r7, #0
    mov r1, #0
    .word 0xE8BF0002               @ ldmia r15!, {r1}
    add r7, r7, #1                 @ base+0-ish landings accumulate
    add r7, r7, #2                 @ base   (candidate+8)
    add r7, r7, #4                 @ base+4 (candidate+12)
    add r7, r7, #8                 @ base+8 (candidate+16)
tw_rec1:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #1
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #18]
    str r1, [r8, #24]
    wdg_arm tw_rec2
    mov r7, #0
    mov r1, #0
    .word 0xE48F1004               @ str r1, [r15], #4
    add r7, r7, #1
    add r7, r7, #2
    add r7, r7, #4
    add r7, r7, #8
tw_rec2:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #2
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #19]
    wdg_arm tw_rec3
    mov r7, #0
    mov r1, #0
    .word 0xE49F1004               @ ldr r1, [r15], #4
    add r7, r7, #1
    add r7, r7, #2
    add r7, r7, #4
    add r7, r7, #8
tw_rec3:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #4
    mov r0, #0
    str r0, [r2, #8]
    strb r7, [r8, #20]
    str r1, [r8, #28]
    strb r11, [r8, #21]
    mrs r0, CPSR                   @ leave with IRQs unmasked for irqwin2
    bic r0, r0, #0x80
    msr CPSR_c, r0
    pop {r4-r11, pc}
    .ltorg

@ ── slot 26: IRQWIN2 — the gate windows in CYCLES, and the same-cycle
@ IF-ack race ──────────────────────────────────────────────────────────────
@ IRQWIN gave the windows in uniform-width instructions (3/3/2).  Here
@ each gate's dispatch is TM0-timestamped (pre-store stamp vs the
@ handler's entry stamp), an EWRAM-load sled re-measures the IME window
@ with multi-cycle instructions (instructions-vs-cycles disambiguation),
@ and a one-shot TM2 overflow is swept cycle-by-cycle across an IF ack
@ write.
@ +0/+2/+4  halfword TM0 deltas (pre-store -> handler entry) for the
@           IME / IE / msr-I-clear gates
@ +6  halfword ldr-sled landing byte offset for the IME gate
@ +8..+15  ack-race bytes for overflow offsets k=0..7: bit0 = IF set
@          right after the ack, bit1 = IF set 8 nops later
probe_irqwin2:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 26*SLOTSZ
    ldr r7, =SCRATCH
    ldr r4, =0x04000200
    bl  tm_start
    @ ── IME gate, timestamped ──
    mov r0, #0
    strh r0, [r4, #8]
    mov r0, #0x20
    strh r0, [r4]
    iw_prime
    ldr r6, =0x04000100
    ldrh r5, [r6]                  @ pre-store stamp
    mov r0, #1
    strh r0, [r4, #8]
    bl  iw2_wait
    mov r0, #0
    strh r0, [r4, #8]
    ldrh r0, [r7, #0x48]
    sub r0, r0, r5
    strh r0, [r8, #0]
    @ ── IE gate, timestamped ──
    mov r0, #1
    strh r0, [r4, #8]
    mov r0, #0
    strh r0, [r4]
    iw_prime
    ldr r6, =0x04000100
    ldrh r5, [r6]
    mov r0, #0x20
    strh r0, [r4]
    bl  iw2_wait
    mov r0, #0
    strh r0, [r4]
    ldrh r0, [r7, #0x48]
    sub r0, r0, r5
    strh r0, [r8, #2]
    @ ── msr-I gate, timestamped ──
    mov r0, #0x20
    strh r0, [r4]
    mrs r6, CPSR
    orr r0, r6, #0x80
    msr CPSR_c, r0
    iw_prime
    ldr r6, =0x04000100
    ldrh r5, [r6]
    mrs r0, CPSR
    bic r0, r0, #0x80
    msr CPSR_c, r0
    bl  iw2_wait
    ldrh r0, [r7, #0x48]
    sub r0, r0, r5
    strh r0, [r8, #4]
    @ ── IME gate again, multi-cycle-instruction sled ──
    mov r0, #0
    strh r0, [r4, #8]
    iw_prime
    ldr r3, =EWDST
    mov r0, #1
    strh r0, [r4, #8]
iw2m:
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    iw_sled 6, iw2m
    mov r0, #0
    strh r0, [r4, #8]
    strh r0, [r4]                  @ IE off — ack race runs without IRQs
    @ ── ack racing a one-shot overflow, swept one cycle per row ──
.macro ar_one k
    ldr r5, =0x04000108
    mov r0, #0
    str r0, [r5]
    ldr r0, =0x3FFF
    strh r0, [r4, #2]              @ ack everything stale
    ldr r0, =0x00C00000 + 0xFFFC - (\k * 2)
    str r0, [r5]                   @ overflow lands (4+2k)+latency out
    mov r0, #0
    strh r0, [r5]                  @ NEXT reload = 0: the counter keeps
                                   @ its loaded value, but any repeat
                                   @ overflow is 65536 cycles away, so
                                   @ bit1 is not contaminated
    mov r1, #0x20
    strh r1, [r4, #2]              @ THE ack, racing the overflow
    ldrh r0, [r4, #2]
    and r0, r0, #0x20
    mov r2, r0, lsr #5             @ bit0: survived/reasserted immediately
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    ldrh r0, [r4, #2]
    tst r0, #0x20
    orrne r2, r2, #2               @ bit1: (re)set by 8 nops later
    strb r2, [r8, #8 + \k]
    mov r0, #0
    str r0, [r5]
    ldr r0, =0x3FFF
    strh r0, [r4, #2]
.endm
    ar_one 0
    ar_one 1
    ar_one 2
    ar_one 3
    ar_one 4
    ar_one 5
    ar_one 6
    ar_one 7
    pop {r4-r7, pc}
iw2_wait:                          @ bounded wait on the handler flag
    ldr r1, =0x40000
1:  ldr r0, [r7, #0x4C]
    cmp r0, #0
    bxne lr
    subs r1, r1, #1
    bne 1b
    bx  lr
    .ltorg

@ ── slot 27: IOBYTE — is byte-write mirroring bus-wide or DMA-specific? ──
@ DMAEDGE found strb 0x80 to DMA3CNT_H's upper byte landing in BOTH bytes
@ while lower-byte writes were ignored.  Here 0x44 is byte-written to the
@ low then high byte of eight READABLE registers, halfword readback after
@ each (original value restored between): a normal bus shows 0x44 in one
@ byte, mirroring shows both, an ignored write shows the original.
@ +0/+2   DISPCNT lo/hi     +4/+6   DISPSTAT     +8/+10  BG0CNT
@ +12/+14 WININ              +16/+18 BLDCNT       +20/+22 SOUND1CNT_L
@                                                 (master forced on)
@ +24/+26 IE                 +28/+30 DMA3CNT_H (0x44: no enable bit)
probe_iobyte:
    push {r4-r8, lr}
    ldr r8, =SLOTS + 27*SLOTSZ
    ldr r4, =IOBASE
.macro ib_one slot
    ldrh r6, [r5]
    mov r0, #0x44
    strb r0, [r5]
    ldrh r0, [r5]
    strh r0, [r8, #\slot]
    strh r6, [r5]
    mov r0, #0x44
    strb r0, [r5, #1]
    ldrh r0, [r5]
    strh r0, [r8, #\slot + 2]
    strh r6, [r5]
.endm
    mov r5, r4                     @ DISPCNT
    ib_one 0
    add r5, r4, #0x04              @ DISPSTAT
    ib_one 4
    add r5, r4, #0x08              @ BG0CNT
    ib_one 8
    add r5, r4, #0x48              @ WININ
    ib_one 12
    add r5, r4, #0x50              @ BLDCNT
    ib_one 16
    add r5, r4, #0x84              @ PSG master on for the NR10 row
    ldrh r7, [r5]
    mov r0, #0x80
    strh r0, [r5]
    add r5, r4, #0x60              @ SOUND1CNT_L
    ib_one 20
    add r5, r4, #0x84
    strh r7, [r5]                  @ master back to what it was
    add r5, r4, #0x200             @ IE (IME is off here)
    ib_one 24
    add r5, r4, #0xDE              @ DMA3CNT_H, enable bit NOT in 0x44
    ib_one 28
    pop {r4-r8, pc}
    .ltorg

@ ═══ pages 28-36: the discrimination pages — each isolates a model split
@ the earlier pages could not separate ═══════════════════════════════════

@ ── slot 28: LDMUSER2 — the post-ldm^ SPSR read, with DISJOINT flags ─────
@ LDMUSER's +20 row could not falsify the OR-with-CPSR theory:
@ CPSR's set flag bits were a subset of the SPSR pattern, so "unchanged"
@ and "OR'd" read identically.  Here SPSR flags = N|V (0x90000000) and
@ CPSR flags = Z|C (0x60000000) — disjoint — in IRQ mode, then
@ `ldmia r0, {r1-r7}^` (user-bank list, no PC) with an mrs SPSR in its
@ shadow.  Discriminators for the +0 word:
@   SPSR unchanged        -> 0x90000092
@   SPSR OR'd with CPSR   -> 0xF0000092
@   read returns CPSR     -> 0x60000092
@ +0  word: mrs SPSR on the VERY NEXT instruction after ldm^
@ +4  word: mrs SPSR TWO instructions after (one nop between) — is the
@           shadow window one instruction long?
@ +8  word: control — same SPSR/CPSR setup, no ldm^ (must read 0x90000092)
@ +12 word: CPSR right after the +0 experiment's mrs (sanity: the ldm^
@           must not have touched CPSR -> 0x60000092)
probe_ldmuser2:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 28*SLOTSZ
    mrs r9, CPSR
    bic r0, r9, #0x1F
    orr r0, r0, #0x92              @ IRQ mode, I set
    msr CPSR_c, r0
    ldr sp, =SCRATCH + 0xF0        @ sp_irq hygiene (never used)
    @ row 1: mrs in the immediate shadow
    ldr r0, =0x90000092            @ SPSR: N|V, IRQ mode, I
    msr SPSR_cxsf, r0
    ldr r0, =0x60000000            @ CPSR flags: Z|C — DISJOINT from SPSR
    msr CPSR_f, r0
    ldr r0, =EWDST + 0x200
    .word 0xE8D000FE               @ ldmia r0, {r1-r7}^
    mrs r0, SPSR                   @ THE read
    mrs r1, CPSR
    str r0, [r8, #0]
    str r1, [r8, #12]
    @ row 2: one instruction of daylight
    ldr r0, =0x90000092
    msr SPSR_cxsf, r0
    ldr r0, =0x60000000
    msr CPSR_f, r0
    ldr r0, =EWDST + 0x200
    .word 0xE8D000FE               @ ldmia r0, {r1-r7}^
    nop
    mrs r0, SPSR
    str r0, [r8, #4]
    @ row 3: control, no ldm^
    ldr r0, =0x90000092
    msr SPSR_cxsf, r0
    ldr r0, =0x60000000
    msr CPSR_f, r0
    mrs r0, SPSR
    str r0, [r8, #8]
    msr CPSR_c, r9                 @ back to system mode
    msr CPSR_f, r9
    pop {r4-r11, pc}
    .ltorg

@ ── slot 29: PCWB2 — the r15-writeback FUNCTIONAL FORM ───────────────────
@ THUMBPC2 measured only offset +4 post-indexed, which cannot separate
@ "PC := writeback address (+4 extra for ldr)" from "PC := base+4 (str) /
@ base+8 (ldr) fixed".  Five candidates run from EWRAM under the TM3
@ watchdog, each inside a breadcrumb block with pads BEFORE and AFTER:
@   B+0  add r7,#0x20   (C-8)      B+16 add r7,#2  (C+8  = base)
@   B+4  add r7,#0x40   (C-4)      B+20 add r7,#4  (C+12 = base+4)
@   B+8  the candidate  (C)        B+24 add r7,#8  (C+16 = base+8)
@   B+12 add r7,#1      (C+4)      B+28 add r7,#16 (C+20 = base+12)
@   B+32 bx r5 (recover)
@ r7 = sum from the landing point: 1F=C+4 (no wb / base-4), 1E=base,
@ 1C=base+4, 18=base+8, 10=base+12, 0=fell past the sled; a landing in
@ the pads BEFORE C re-executes the candidate (loop) — watchdog bit set.
@ Store-to-[base] candidates carry an IDENTITY payload in r1 (the very
@ instruction already at the target), so the block survives its own store.
@ Discriminators (writeback model vs fixed model; dingbat lands base+8
@ everywhere):
@ +0  byte r7, `str r1,[r15],#8`:  wb -> base+8 = 18; fixed(str)=base+4 -> 1C
@ +1  byte r7, `ldr r1,[r15],#8`:  wb+4 -> base+12 = 10; fixed(ldr)=base+8 -> 18
@ +2  byte r7, `str r1,[r15],#-4`: wb -> base-4 = 1F; fixed -> 1C
@ +3  byte r7, `str r1,[r15,#4]!`: pre-indexed wb = base+4 -> 1C either way
@       (a fixed-base+8 model -> 18)
@ +4  byte r7, `stmia r15!,{r1}`:  wb = base+4 -> 1C; no-wb (like ldm) -> 1F
@ +5  byte: watchdog-fired bitmask, bit per row (a=1..e=16)
@ +8  word: r1 after the ldr row (0 = load suppressed, E2877002 = loaded)
@ +12 word: [C+8] after the stm row    +16 word: [C+12] after the stm row
@       (a store that landed at the wrong address shows up here)
@ +20 word: r1 after the stm row (must still be the identity payload)
probe_pcwb2:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 29*SLOTSZ
    mov r11, #0                    @ watchdog-fired bitmask
.macro pw_setup cand
    ldr r0, =pcwb_blk
    ldr r1, =PCWB2BLK
    mov r2, #10
9:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 9b
    ldr r0, =\cand
    ldr r1, =PCWB2BLK
    str r0, [r1, #8]
.endm
.macro pw_run rec, preset, wdgbit
    wdg_arm \rec
    mov r7, #0
    ldr r1, =\preset
    ldr r5, =\rec
    ldr r0, =PCWB2BLK + 8
    bx  r0
\rec:
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    cmp r0, #2
    orreq r11, r11, #\wdgbit
    mov r0, #0
    str r0, [r2, #8]
.endm
    pw_setup 0xE48F1008            @ (a) str r1, [r15], #8
    pw_run pw_ra, 0xE2877002, 1
    strb r7, [r8, #0]
    pw_setup 0xE49F1008            @ (b) ldr r1, [r15], #8
    pw_run pw_rb, 0x00000000, 2
    strb r7, [r8, #1]
    str r1, [r8, #8]
    pw_setup 0xE40F1004            @ (c) str r1, [r15], #-4
    pw_run pw_rc, 0xE2877002, 4
    strb r7, [r8, #2]
    pw_setup 0xE5AF1004            @ (d) str r1, [r15, #4]!
    pw_run pw_rd, 0xE2877004, 8
    strb r7, [r8, #3]
    pw_setup 0xE8AF0002            @ (e) stmia r15!, {r1}
    pw_run pw_re, 0xE2877002, 16
    strb r7, [r8, #4]
    str r1, [r8, #20]
    ldr r0, =PCWB2BLK
    ldr r1, [r0, #16]              @ [C+8]
    str r1, [r8, #12]
    ldr r1, [r0, #20]              @ [C+12]
    str r1, [r8, #16]
    strb r11, [r8, #5]
    pop {r4-r11, pc}
    .ltorg
pcwb_blk:
    .word 0xE2877020               @ B+0:  C-8 pad
    .word 0xE2877040               @ B+4:  C-4 pad
    .word 0xE1A00000               @ B+8:  candidate (patched per row)
    .word 0xE2877001               @ B+12: C+4
    .word 0xE2877002               @ B+16: C+8  = base
    .word 0xE2877004               @ B+20: C+12 = base+4
    .word 0xE2877008               @ B+24: C+16 = base+8
    .word 0xE2877010               @ B+28: C+20 = base+12
    .word 0xE12FFF15               @ B+32: bx r5
    .word 0xE12FFF15               @ B+36: safety

@ ── slot 30: DMABYTE2 — the CNT_H byte-write anomaly, generalized ────────
@ DMAEDGE/IOBYTE pinned DMA3: an upper-byte strb 0x80 mirrors bit7 into BOTH
@ bytes, a lower-byte strb 0x80 stores NOTHING, yet a lower-byte 0x44
@ stores fine — bit7 is the anomaly, not the byte lane.  Open: does the
@ same hold on DMA0/1/2, and is the mirror whole-value or bit7-only?
@ Each row: prime DMAn (EWRAM 0x5A5A halfword -> cleared EWRAM dest,
@ count 1, CNT_H=0 via 16-bit writes), strb the payload, then record
@ did-it-run (dest == 5A5A) + CNT_H readback.
@ +0/+2   DMA1 upper-byte strb 0x80: ran + readback (mirror -> 0080,
@         normal -> 0000; either way the transfer runs)
@ +4/+6   DMA2 upper-byte strb 0x80: same
@ +8/+10  DMA0 upper-byte strb 0x80: same (internal-memory SAD only)
@ +12/+14 DMA3 upper-byte strb 0xC0: whole-value mirror -> low byte C0
@         (readback 40C0), bit7-only mirror -> 4080, no mirror -> 4000
@         (bit14=IRQ persists; enable self-clears after the run)
@ +16/+18 DMA3 lower-byte strb 0xC0: fully dropped -> 0000, partial
@         (bit6 stores, bit7 dropped) -> 0040, full store -> 00C0; no run
@ +20/+22 DMA3 upper-byte strb 0x40 (bit7 clear, control): normal store
@         -> 4000, no run; mirror-on-any-hi-write -> 4040
probe_dmabyte2:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 30*SLOTSZ
    ldr r0, =EWDST + 0x140
    ldr r1, =0x5A5A
    strh r1, [r0]                  @ the one-halfword source
.macro db2_prime base
    ldr r4, =\base
    ldr r0, =EWDST + 0x140
    str r0, [r4]                   @ SAD
    ldr r5, =EWDST + 0x180
    mov r0, #0
    str r0, [r5]                   @ clear the dest marker
    str r5, [r4, #4]               @ DAD
    mov r0, #1
    strh r0, [r4, #8]              @ CNT_L: 1 halfword
    mov r0, #0
    strh r0, [r4, #10]             @ CNT_H: fully disabled, plain config
.endm
.macro db2_row base, hilo, payload, slot_off
    db2_prime \base
    mov r0, #\payload
    strb r0, [r4, #10 + \hilo]
    nop
    nop
    nop
    nop
    ldr r5, =EWDST + 0x180
    ldrh r0, [r5]
    ldr r1, =0x5A5A
    cmp r0, r1
    moveq r0, #1
    movne r0, #0
    strb r0, [r8, #\slot_off]
    ldrh r0, [r4, #10]
    strh r0, [r8, #\slot_off + 2]
    mov r0, #0
    strh r0, [r4, #10]             @ off again
.endm
    db2_row 0x040000BC, 1, 0x80, 0     @ DMA1 hi
    db2_row 0x040000C8, 1, 0x80, 4     @ DMA2 hi
    db2_row 0x040000B0, 1, 0x80, 8     @ DMA0 hi
    db2_row 0x040000D4, 1, 0xC0, 12    @ DMA3 hi 0xC0
    db2_row 0x040000D4, 0, 0xC0, 16    @ DMA3 lo 0xC0
    db2_row 0x040000D4, 1, 0x40, 20    @ DMA3 hi 0x40 (control)
    ldr r1, =0x04000202
    ldr r0, =0x0F00                @ ack any DMA IF bits (IME was off)
    strh r0, [r1]
    pop {r4-r7, pc}
    .ltorg

@ ── slot 31: SWEEP2 — pinning the sweep model's writeback and boundary ───
@ SWEEPQ's model so far: an immediate check at trigger; a SECOND
@ trigger check re-using the SAME offset, failing strictly ABOVE 2048
@ (that strictness rests on the single freq-1024 anchor: 1536+512=2048
@ survived).  Unknown: does the trigger recalc WRITE BACK, and what is
@ the tick-path second-check offset/boundary?  All rows: ch1, increment,
@ sweep period 2 (~1 tick = 2/128 s = ~0xF75 polls),
@ poll count until the NR52 ch1 bit drops (word, capped 0x80000).
@ NOTE: "freq 2046/2047 shift 10" rows are not encodable (shift is 3
@ bits) — freq 2018/2033 shift 7 preserve the
@ discriminators exactly (second check = 2048 / first calc = 2048).
@ +0  freq 512, shift 1: death tick decodes writeback x tick-2nd-check:
@       tick 2 = writeback-at-trigger + tick-2nd-check
@       tick 3 = (no-writeback + 2nd-check) or (writeback + no-2nd-check)
@       tick 4 = no-writeback + no-2nd-check
@ +4  freq 2018, shift 7 (calc1 1950->2033, calc2 exactly 2048):
@       0 polls   = trigger 2nd check uses >=2048 (re-anchors strictness)
@       ~1 tick   = tick-path 2nd check uses >=2048
@       ~2 ticks  = tick primary check kills 2048 (GB-documented >2047)
@       ~3 ticks  = 2048 writes back and only 2064 dies (boundary >2048
@                   everywhere)
@ +8  freq 940, shift 1 (calc1 1410; same-offset 2nd = 1880, recalc'd
@     2nd = 2115): 0 polls = the trigger 2nd check RECALCULATES the
@     offset; ~2 ticks = same-offset model (extra anchor for SWEEPQ's
@     same-offset conclusion)
@ +12 freq 2033, shift 7 (calc1 exactly 2048, calc2 2063): consistency —
@     dies at trigger under EITHER strictness; surviving to a tick
@     falsifies the two-check trigger model
probe_sweep2:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 31*SLOTSZ
    ldr r4, =0x04000060            @ SOUND1CNT_L base
    ldr r5, =0x04000080            @ SOUNDCNT_L/H/X
    mov r0, #0x80
    strh r0, [r5, #4]              @ master enable
    ldr r0, =0x1177
    strh r0, [r5]                  @ route ch1
    mov r0, #2
    strh r0, [r5, #2]              @ PSG ratio 100%
    bl  wait_vblank                @ settle
    bl  wait_vblank
    sq_run 0x21, 512, 0            @ (a) shift 1, period 2
    bl  wait_vblank
    bl  wait_vblank
    sq_run 0x27, 2018, 4           @ (b) shift 7, period 2: 2nd check 2048
    bl  wait_vblank
    bl  wait_vblank
    sq_run 0x21, 940, 8            @ (c) same-offset vs recalc'd 2nd check
    bl  wait_vblank
    bl  wait_vblank
    sq_run 0x27, 2033, 12          @ (d) calc1 exactly 2048 (consistency)
    mov r0, #0
    strh r0, [r5, #4]              @ master off — silence again
    pop {r4-r7, pc}
    .ltorg

@ ── slot 32: IRQWIN3 — is the dispatch window CYCLE-based? ───────────────
@ IRQWIN2: after an IME store, dispatch lands 3 uniform ROM adds or 2
@ EWRAM loads into the sled (hw deltas 81/81/84 cycles) — width-dependent,
@ so the window looks cycle-counted.  Here the IME-gate sled instruction
@ cost is varied further; instructions-executed x per-instruction cost
@ triangulates the constant.  Sled offsets are the byte offset of the
@ interrupted return address (as IRQWIN).
@ +0  halfword: sled offset, 8x `mul r6, r10, r11` with r11=0x12345678
@     (4 I-cycles each: 1S+4I)  — a W-cycle window predicts ceil(W/cost)
@     instructions
@ +2  halfword: sled offset, 8x `ldr r0, [r9]` from ROM (waitstated data
@     fetch — the most expensive uniform sled)
@ +4  halfword: sled offset, mixed nop/ldr-ROM alternating (does a cheap
@     instruction at the window edge still complete?)
@ +8..+15  ack-race bytes, one-shot TM2 overflow swept COARSELY across
@     the IF-ack store: reload 0xFFF8 - 4k (overflow (8+4k)+latency
@     cycles after enable, k=0..7 — the previous 2-cycle sweep at
@     0xFFFC-2k landed entirely before the ack on hardware).
@     bit0 = IF set right after the ack, bit1 = IF set 8 nops later
probe_irqwin3:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 32*SLOTSZ
    ldr r7, =SCRATCH
    ldr r4, =0x04000200
    ldr r9, =rom_pattern
    mov r10, #1
    ldr r11, =0x12345678
    @ ── mul sled ──
    mov r0, #0
    strh r0, [r4, #8]              @ IME off
    mov r0, #0x20
    strh r0, [r4]                  @ IE = timer2
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]              @ IME on — dispatch races the sled
iw3a:
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    iw_sled 0, iw3a
    mov r0, #0
    strh r0, [r4, #8]
    @ ── ROM-load sled ──
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]
iw3b:
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    iw_sled 2, iw3b
    mov r0, #0
    strh r0, [r4, #8]
    @ ── mixed nop/ldr sled ──
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]
iw3c:
    nop
    ldr r0, [r9]
    nop
    ldr r0, [r9]
    nop
    ldr r0, [r9]
    nop
    ldr r0, [r9]
    iw_sled 4, iw3c
    mov r0, #0
    strh r0, [r4, #8]
    strh r0, [r4]                  @ IE off — ack race runs without IRQs
    @ ── the coarser ack-race sweep ──
.macro ar2_one k
    ldr r5, =0x04000108
    mov r0, #0
    str r0, [r5]
    ldr r0, =0x3FFF
    strh r0, [r4, #2]              @ ack everything stale
    ldr r0, =0x00C00000 + 0xFFF8 - (\k * 4)
    str r0, [r5]                   @ overflow lands (8+4k)+latency out
    mov r0, #0
    strh r0, [r5]                  @ next reload = 0 (repeat is 65536 away)
    mov r1, #0x20
    strh r1, [r4, #2]              @ THE ack, racing the overflow
    ldrh r0, [r4, #2]
    and r0, r0, #0x20
    mov r2, r0, lsr #5             @ bit0: survived/reasserted immediately
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    ldrh r0, [r4, #2]
    tst r0, #0x20
    orrne r2, r2, #2               @ bit1: (re)set by 8 nops later
    strb r2, [r8, #8 + \k]
    mov r0, #0
    str r0, [r5]
    ldr r0, =0x3FFF
    strh r0, [r4, #2]
.endm
    ar2_one 0
    ar2_one 1
    ar2_one 2
    ar2_one 3
    ar2_one 4
    ar2_one 5
    ar2_one 6
    ar2_one 7
    pop {r4-r11, pc}
    .ltorg

@ ── slot 33: IRQLAT2 — the TM2 IRQ-latency row, r5-clobber-fixed ─────────
@ IRQLAT's TM2 row as first built was invalid (irq_arm clobbers r5, so
@ the arming word hit IME and the stamp was stale); this page re-measures
@ the row plus arming-shape variants.  Layout per row is the
@ IRQLAT pair: trigger-side TM0 stamp / handler-entry TM0 stamp (the
@ mod-2^16 delta is the latency; TM0 free-runs from tm_start).
@ +0/+2   TM2 reload 0, enable+IRQ in ONE word (the retracted row —
@         overflow 65536 cycles after enable; TM0 wraps, delta still valid)
@ +4/+6   TM2 reload 0xFF00, enable+IRQ in one word (256-cycle overflow —
@         same latency expected if delivery is overflow-relative)
@ +8/+10  TM2 reload 0xFF00 armed in TWO halfword writes (reload first,
@         then CNT_H): does arming shape shift delivery?
@ +12/+14 TM2 reload 0xFFF0 (overflow ~16 cycles out — may land inside
@         the arming/stamp code; the stamp pair records which side)
probe_irqlat2:
    push {r4-r7, lr}
    ldr r8, =SLOTS + 33*SLOTSZ
    ldr r7, =SCRATCH
    bl  tm_start                   @ TM0/TM1 free-run as the session clock
.macro il2_row armlo, armhi, twowrite, slot_off
    mov r0, #0
    str r0, [r7, #0x4C]            @ handler first-entry flag
    ldr r5, =0x04000108            @ TM2
    str r0, [r5]
    irq_arm 0x20                   @ IE: timer 2 (clobbers r5!)
    ldr r5, =0x04000108            @ ...reload it (irq_arm clobbers r5)
.if \twowrite
    ldr r0, =\armlo
    strh r0, [r5]                  @ reload halfword first
    ldr r0, =\armhi
    strh r0, [r5, #2]              @ then CNT_H: enable + IRQ
.else
    ldr r0, =(\armhi << 16) | \armlo
    str r0, [r5]                   @ one 32-bit arming store
.endif
    mov r0, #0
    strh r0, [r5]                  @ NEXT reload = 0: the first overflow
                                   @ still comes off the armed reload, but
                                   @ repeats are 65536 cycles apart — a
                                   @ short reload left repeating IRQ-storms
                                   @ faster than the handler returns and
                                   @ livelocks the bounded spin
    ldr r6, =0x04000100
    ldrh r0, [r6]                  @ trigger-side stamp
    strh r0, [r8, #\slot_off]
    irq_spin
    irq_disarm
    mov r0, #0
    ldr r5, =0x04000108
    str r0, [r5]
    ldrh r0, [r7, #0x48]
    strh r0, [r8, #\slot_off + 2]
.endm
    il2_row 0x0000, 0x00C0, 0, 0
    il2_row 0xFF00, 0x00C0, 0, 4
    il2_row 0xFF00, 0x00C0, 1, 8
    il2_row 0xFFF0, 0x00C0, 0, 12
    bl  tm_stop
    pop {r4-r7, pc}
    .ltorg

@ ── slot 34: IOBYTE2 — DISPSTAT byte writes, falsifiably this time ───────
@ IOBYTE used payload 0x44, whose only storable DISPSTAT bit is 6, so
@ "byte writes ignored" and "bits 6-7 don't exist" were
@ indistinguishable.  0x38 hits bits 3-5
@ — the REAL IRQ-enable bits — so the two models finally split.  All
@ rows right after wait_vblank (status bits deterministic: bit0 set).
@ +0  halfword: readback after strb 0x38 -> DISPSTAT low byte
@       byte writes store -> 0x0039;  low byte ignores bytes -> 0x0001
@ +2  halfword: readback after strb 0x38 -> DISPSTAT high byte (LYC=0x38)
@       stores -> 0x3801;  ignored -> 0x0001
@ +4  halfword: control — 16-bit write 0x0038, readback (must be 0x0039)
@ +6  halfword: 16-bit write 0x0038 then strb 0x00 to the low byte:
@       byte-clear stores -> 0x0001;  ignored -> 0x0039
@ +8  halfword: the boot DISPSTAT this probe saved/restored (info)
probe_iobyte2:
    push {r4-r6, lr}
    ldr r8, =SLOTS + 34*SLOTSZ
    mov r4, #IOBASE
    add r5, r4, #4                 @ DISPSTAT
    ldrh r6, [r5]                  @ original value (restored after)
    strh r6, [r8, #8]
    bl  wait_vblank
    mov r0, #0x38
    strb r0, [r5]
    ldrh r0, [r5]
    strh r0, [r8, #0]
    strh r6, [r5]
    mov r0, #0x38
    strb r0, [r5, #1]              @ LYC = 0x38
    ldrh r0, [r5]
    strh r0, [r8, #2]
    strh r6, [r5]
    mov r0, #0x38
    strh r0, [r5]                  @ 16-bit control
    ldrh r0, [r5]
    strh r0, [r8, #4]
    mov r0, #0
    strb r0, [r5]                  @ byte-CLEAR on top of the 16-bit write
    ldrh r0, [r5]
    strh r0, [r8, #6]
    strh r6, [r5]                  @ restore
    ldr r1, =0x04000202
    ldr r0, =0x3FFF
    strh r0, [r1]                  @ ack anything the enables raised
    pop {r4-r6, pc}
    .ltorg

@ ── slot 35: THUMBPC3 — the cmp-pc restore at a HALFWORD boundary, and in
@ a mode with no SPSR ──────────────────────────────────────────────────────
@ THUMBPC2 showed a full CPSR:=SPSR restore on Thumb `cmp pc, r0`,
@ measured only at a word-aligned address with a T-set SPSR.  (a) runs it
@ at A with A%4==2 and SPSR.T=0 (N set, IRQ mode, I clear): the resume
@ address candidates A&~3 (=W) and (A+2)&~3 = (A+4)&~3 (=W+4) collapse to
@ two.  The block overlays Thumb and ARM decode:
@   W+0 .hword 0x4000  — with the cmp forms ARM word 0x45874000 =
@         strmi r4, [r7]  (only ever executed if ARM resumes at W;
@         SPSR.N=1 makes MI true; r7 -> a cleared scratch word, r4 =
@         0xC0DEC0DE marker — the store IS the resumed-at-W breadcrumb)
@   W+2 .hword 0x4587  — Thumb cmp pc, r0 (the entry point, A)
@   W+4 .hword 0x4728  — Thumb bx r5 (the stayed-in-Thumb escape); with
@         W+6 forms ARM word 0xE3874728 = orr r4, r7, #… (benign)
@   W+8 .word 0xE2866002 add r6,#2   W+12 bx r5
@ Verdicts: scratch=marker & r6=2 -> resumed ARM at W (A&~3);
@ scratch=0 & r6=2 -> resumed ARM at W+4 ((A+2)&~3); scratch=0 & r6=0 ->
@ stayed Thumb (no restore — dingbat's model); CPSR word confirms which
@ (0x800000xx = restored SPSR, 0x200000xx = compare flags).  Watchdogged.
@ Hardware answered (a) with an outcome the key did not list: scratch=0
@ AND r6=0 with a clean phase — hardware resumed ARM past BOTH overlay
@ words, at A+10 (the bx escape) or A+14 (the safety), which that block
@ could not tell apart.  (c) reruns the experiment with the ladder
@ extended: distinct breadcrumb adds at W+8/W+12/W+16 separate A+6 vs
@ A+10 vs A+14, r4 is captured to show whether the ARM word at W+4 (the
@ (A+2)&~3 resume — dingbat's model, `orr r4, r7, #0xA00000`) executed,
@ and the bx-r5 escape moves to W+20 with a safety at W+24.
@ +0  word: CPSR captured at recovery, row (a)
@ +4  word: the scratch word (0 or 0xC0DEC0DE)
@ +8  byte: r6      +9 byte: watchdog phase (1 clean / 2 fired)
@ +12 word: CPSR after (b) `cmp pc, r0` in SYSTEM mode (no SPSR exists);
@       flags preset to N|Z (0xC0000000), which no compare of pc vs 0 can
@       produce: 0xC00000xx -> "restore" wrote CPSR-as-SPSR back
@       (no-op), 0x200000xx -> plain compare; anything else = garbage
@       restore (watchdog phase says if it wandered)
@ +16 byte: watchdog phase for (b)
@ +17 byte: watchdog phase for (c)
@ +18 byte: r6 for (c) — the resume-point ladder key: 07 = resumed at
@       W+8 (A+6), 06 = W+12 (A+10), 04 = W+16 (A+14), 00 = W+20 (A+18)
@       or stayed Thumb (r4/CPSR split those)
@ +20 word: r4 for (c) — 0xC0DEC0DE untouched; 0x02A01080 = the W+4 ARM
@       word ran, i.e. resumed at (A+2)&~3 (dingbat's model)
@ +24 word: the scratch word for (c) (0xC0DEC0DE = the strmi at W ran,
@       i.e. resumed at A&~3)
@ +28 word: CPSR captured at recovery, row (c)
probe_thumbpc3:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 35*SLOTSZ
    mrs r9, CPSR
    @ ── (a) halfword-aligned cmp pc, T-clearing SPSR ──
    ldr r7, =SCRATCH + 0x80
    mov r0, #0
    str r0, [r7]                   @ clear the store-breadcrumb word
    bic r0, r9, #0x1F
    orr r0, r0, #0x12              @ IRQ mode, I CLEAR (watchdog reachable)
    msr CPSR_c, r0
    ldr sp, =SCRATCH + 0xF0
    ldr r1, =0x80000012            @ SPSR: N set, T CLEAR, IRQ mode, I clear
    msr SPSR_cxsf, r1
    wdg_arm tp3_rec
    ldr r4, =0xC0DEC0DE            @ the strmi payload
    mov r6, #0
    mov r0, #0                     @ cmp operand
    ldr r5, =tp3_rec
    ldr r1, =tp3_blk + 3           @ W+2, Thumb
    bx  r1
tp3_rec:
    mrs r10, CPSR                  @ capture BEFORE restoring
    msr CPSR_cxsf, r9
    wdg_disarm
    str r10, [r8, #0]
    ldr r0, [r7]
    str r0, [r8, #4]
    strb r6, [r8, #8]
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    strb r0, [r8, #9]
    mov r0, #0
    str r0, [r2, #8]
    @ ── (b) cmp pc in System mode (no real SPSR) ──
    wdg_arm tp3b_rec
    ldr r0, =0xC0000000
    msr CPSR_f, r0                 @ N|Z preset — unreachable by the compare
    mov r0, #0
    adr r3, tp3b_ret
    adr r1, tp3b_pad
    orr r1, r1, #1
    bx  r1
    .thumb
tp3b_pad:
    .hword 0x4587                  @ cmp pc, r0
    .hword 0x4718                  @ bx r3
    .hword 0x4718                  @ bx r3 (insurance: a skipped-slot
    .hword 0x4718                  @ resume still escapes cleanly)
    .align 2
    .arm
tp3b_ret:
    mrs r1, CPSR
    str r1, [r8, #12]
tp3b_rec:                          @ watchdog divert target (fallthrough
    msr CPSR_cxsf, r9              @ on the clean path)
    wdg_disarm
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    strb r0, [r8, #16]
    mov r0, #0
    str r0, [r2, #8]
    @ ── (c) the halfword-aligned cmp pc again, resume ladder extended ──
    ldr r7, =SCRATCH + 0x80
    mov r0, #0
    str r0, [r7]                   @ clear the store-breadcrumb word
    bic r0, r9, #0x1F
    orr r0, r0, #0x12              @ IRQ mode, I CLEAR (watchdog reachable)
    msr CPSR_c, r0
    ldr sp, =SCRATCH + 0xF0
    ldr r1, =0x80000012            @ SPSR: N set, T CLEAR, IRQ mode, I clear
    msr SPSR_cxsf, r1
    wdg_arm tp3c_rec
    ldr r4, =0xC0DEC0DE            @ strmi payload / untouched-r4 sentinel
    mov r6, #0
    mov r0, #0                     @ cmp operand
    ldr r5, =tp3c_rec
    ldr r1, =tp3c_blk + 3          @ W+2, Thumb
    bx  r1
tp3c_rec:
    mrs r10, CPSR                  @ capture BEFORE restoring
    msr CPSR_cxsf, r9
    wdg_disarm
    strb r6, [r8, #18]
    str r4, [r8, #20]
    ldr r0, [r7]
    str r0, [r8, #24]
    str r10, [r8, #28]
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    strb r0, [r8, #17]
    mov r0, #0
    str r0, [r2, #8]
    pop {r4-r11, pc}
    .ltorg
    .align 2
tp3_blk:                           @ W (word-aligned)
    .hword 0x4000                  @ W+0: ARM-overlay low half (see above)
    .hword 0x4587                  @ W+2: Thumb cmp pc, r0  <- entry (A)
    .hword 0x4728                  @ W+4: Thumb bx r5 / ARM-overlay low half
    .hword 0xE387                  @ W+6: ARM word W+4 = orr r4, r7, #…
    .word 0xE2866002               @ W+8:  add r6, r6, #2
    .word 0xE12FFF15               @ W+12: bx r5
    .word 0xE12FFF15               @ W+16: safety
    .align 2
tp3c_blk:                          @ W (word-aligned), the (c) ladder
    .hword 0x4000                  @ W+0: ARM-overlay low half (strmi)
    .hword 0x4587                  @ W+2: Thumb cmp pc, r0  <- entry (A)
    .hword 0x4728                  @ W+4: Thumb bx r5 / ARM-overlay low half
    .hword 0xE387                  @ W+6: ARM word W+4 = orr r4, r7, #0xA00000
    .word 0xE2866001               @ W+8:  add r6, r6, #1  (A+6)
    .word 0xE2866002               @ W+12: add r6, r6, #2  (A+10)
    .word 0xE2866004               @ W+16: add r6, r6, #4  (A+14)
    .word 0xE12FFF15               @ W+20: bx r5           (A+18)
    .word 0xE12FFF15               @ W+24: safety

@ ── slot 36: MSRTBIT2 — the T-bit quirk: immediate form, and mode+T ──────
@ MSRTBIT verified the register-form `msr CPSR_c, r0` T-set quirk
@ (resume A+8, SKIP A+10) from System mode.  Two scope questions remain:
@ does the IMMEDIATE form share the quirk, and does a write that sets T
@ AND switches mode in the same instruction behave identically (and does
@ the mode switch land)?  Both reuse msr_block's breadcrumb thumb sled
@ (r7 keys: 15=A+4, 14=A+6, 12=A+8 straight, 04=A+8-skip-A+10, 08=A+10,
@ 0=continued as ARM), copied to IWRAM, watchdogged, flags pinned
@ Z=1 C=1 N=0 so an ARM continuation nets out through the cond-skipped
@ pairs exactly as in MSRTBIT.
@ +0  byte r7, (a) `msr CPSR_c, #0x3F` (immediate: T + SYS + I clear),
@       run from System mode — silicon prediction 04 if the quirk is
@       form-independent
@ +1  byte watchdog phase (a)     +2 byte CPSR low byte at recovery (a)
@ +4  word marker the thumb str deposited (a)
@ +8  byte r7, (b) register form r0=0x3F run from IRQ mode — sets T and
@       switches IRQ->SYS in one write
@ +9  byte watchdog phase (b)     +10 byte CPSR low byte at recovery (b)
@       (0x1F before the restore = the mode switch landed in SYS)
@ +12 word marker word (b)
probe_msrtbit2:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 36*SLOTSZ
    mrs r9, CPSR
.macro ms2_copy patch
    ldr r0, =msr_block
    ldr r1, =IWBLOCK + 0x40
    ldmia r0!, {r2-r7}
    stmia r1!, {r2-r7}
.if \patch
    ldr r1, =IWBLOCK + 0x40
    ldr r0, =0xE321F03F            @ msr CPSR_c, #0x3F (immediate form)
    str r0, [r1]
.endif
    ldr r2, =MARKER
    mov r0, #0
    str r0, [r2, #0x30]            @ clear the thumb-str marker word
.endm
    @ ── (a) immediate form, from System mode ──
    ms2_copy 1
    wdg_arm ms2a_rec
    ldr r6, =MARKER + 0x30
    ldr r5, =ms2a_rec
    mov r7, #0
    cmp r7, #0                     @ pin Z=1 C=1 N=0
    ldr r1, =IWBLOCK + 0x40
    bx  r1
ms2a_rec:
    mrs r10, CPSR
    msr CPSR_cxsf, r9
    wdg_disarm
    strb r7, [r8, #0]
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    strb r0, [r8, #1]
    strb r10, [r8, #2]
    ldr r0, [r2, #0x30]
    str r0, [r8, #4]
    mov r0, #0
    str r0, [r2, #8]
    @ ── (b) register form: T + IRQ->SYS mode switch in one write ──
    ms2_copy 0
    bic r0, r9, #0x1F
    orr r0, r0, #0x12              @ IRQ mode, I CLEAR (watchdog reachable)
    msr CPSR_c, r0
    ldr sp, =SCRATCH + 0xF0
    wdg_arm ms2b_rec
    ldr r6, =MARKER + 0x30
    ldr r5, =ms2b_rec
    mov r7, #0
    mov r0, #0x3F                  @ SYS + T + I clear, in ONE msr
    cmp r7, #0                     @ pin Z=1 C=1 N=0
    ldr r1, =IWBLOCK + 0x40
    bx  r1
ms2b_rec:
    mrs r10, CPSR
    msr CPSR_cxsf, r9
    wdg_disarm
    strb r7, [r8, #8]
    ldr r2, =MARKER
    ldr r0, [r2, #8]
    strb r0, [r8, #9]
    strb r10, [r8, #10]
    ldr r0, [r2, #0x30]
    str r0, [r8, #12]
    mov r0, #0
    str r0, [r2, #8]
    pop {r4-r11, pc}
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
    @ the interactive pages carry their trigger hint
    cmp r9, #8
    cmpne r9, #24
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

    .arm
    .align 2
@ ═══════ pages 37-39 (v7): OBJ budget, OBJ geometry, DMA open bus ════════
@ Hooked in through probe_tail so every byte before this point sits where
@ session 4 measured it (main's `bl` changes only its target offset).
@ Pages 37/38 are VISUAL: the boot-time probe only stamps the slot with
@ the OAM configuration it will draw; the picture itself is drawn by the
@ viewer (vis_objbudget_page / vis_objgeom_page below draw_page) each time
@ the page is selected — mode 0, BG0 text, OBJ layer on.
.equ DOBSTUB,  0x03000400          @ DMAOPENBUS stubs (IWRAM copy)
.equ DOBSRC,   0x02006000          @ DMA0 source, 4 words, last = marker
.equ DOBDST,   0x02006100          @ DMA0 destination
.equ DOBDST3,  0x02006200          @ DMA3 (open-bus source) destination
.equ VISCHR,   0x06008000          @ BG0 char base 2: font, mark, swatches
.equ VISMAP,   0x0600C000          @ BG0 screen base 24 (32x32 map)
.equ OBJVRAM,  0x06010000
.equ OAM,      0x07000000
.equ PALBG,    0x05000000
.equ PALOBJ,   0x05000200

probe_tail:
    push {lr}
    bl  probe_msrtbit2
    ldr r0, =SLOTS + 37*SLOTSZ     @ zero the v7 slots (EWRAM boots as noise)
    mov r1, #0
    mov r2, #(3 * SLOTSZ / 4)
    bl  fill_words
    bl  probe_objbudget
    bl  probe_objgeom
    bl  probe_dmaopenbus
    bl  probe_tail3                @ v8 (pages 40-49): one more call at the
                                   @ very end, so no earlier byte moves
    pop {pc}

@ ── slot 37: OBJBUDGET (visual) — the per-line OBJ cycle budget running
@ out INSIDE a sprite ─────────────────────────────────────────────────────
@ GBATEK "LCD OBJ Overview": 1210 OBJ cycles per line (954 with DISPCNT.5),
@ a normal sprite costs its width.  Three bands of 64x32 sprites, OAM
@ order left to right:
@   FILL  18 identical light-grey sprites stacked at X=8 (18*64 = 1152)
@   TEST  one sprite at X=88: rows 0-15 a colour ramp (column c mod 8 ->
@         palette 1..8: black red blue green yellow magenta cyan grey),
@         rows 16-31 solid black; a 0-7 ruler sits under each 8px group
@   NEXT  one solid blue sprite at X=168 (OAM after TEST)
@ Band A (Y=16): the budget left for TEST is 1210-1152 = 58 cycles.
@ Band B (Y=56): the same, TEST horizontally flipped.
@ Band C (Y=96): control — the same three sprites with ONE filler, so
@ every pixel fits; what a complete TEST/NEXT look like.
@ Outcomes on bands A/B: TEST complete + NEXT missing = the exhausting
@ sprite still draws fully (dingbat); TEST cut after column 58 (ruler
@ group 7, black+red, then nothing) = hardware truncates at the cycle;
@ the cut column - 0 IS the remaining budget, so any other cut pins the
@ budget itself; band B says whether a flipped sprite is cut on its
@ screen-left or texture-left side; NEXT present = no budget at all.
@ Slot: +0 56h, +1 filler count, +2 sprite width, +3 DISPCNT.5, +4..+9
@ TEST attr0/1/2, +10 DISPCNT while shown — configuration, not results.
.equ OB_FILL_A0, 0x4010            @ Y=16, horizontal shape
.equ OB_FILL_A1, 0xC008            @ X=8, 64x32
.equ OB_FILL_A2, 512               @ grey tiles
.equ OB_TEST_A1, 0xC058            @ X=88
.equ OB_TEST_A2, 544
.equ OB_NEXT_A1, 0xC0A8            @ X=168
.equ OB_NEXT_A2, 576
.equ VIS_DISPCNT, 0x1140           @ mode 0, BG0, OBJ, 1D mapping
probe_objbudget:
    ldr r8, =SLOTS + 37*SLOTSZ
    mov r0, #0x56
    strb r0, [r8, #0]
    mov r0, #18
    strb r0, [r8, #1]
    mov r0, #64
    strb r0, [r8, #2]
    mov r0, #0
    strb r0, [r8, #3]
    ldr r0, =OB_FILL_A0
    strh r0, [r8, #4]
    ldr r0, =OB_TEST_A1
    strh r0, [r8, #6]
    ldr r0, =OB_TEST_A2
    strh r0, [r8, #8]
    ldr r0, =VIS_DISPCNT
    strh r0, [r8, #10]
    bx  lr
    .ltorg

@ ── slot 38: OBJGEOM (visual) — signed OBJ coordinates and OBJ VRAM wrap ─
@ X 504..511 (screen x = -8..-1): eight 8x8 sprites at Y = 40+8k, X = 504+k
@   (k = 0..7) with a column-ramp tile: k columns show at the LEFT edge on
@   rows 40+8k (a staircase; nothing for k=0).
@ Y 248..255 (y = -8..-1): eight 8x8 at X = 40+8k, Y = 248+k with a
@   row-ramp tile: k rows show at the TOP edge (staircase).
@ Y200: a 32x64 sprite at X=112, Y=200, texture rows 56-63 yellow, the
@   rest black: rows 0-7 of the screen show the yellow strip under every
@   wrap model (control for "Y wraps into the top at all").
@ Y130 DBL: a 32x64 texture in a 64x128 affine double-size box (2x scale,
@   pa=pd=0x80) at X=160, Y=130; texture rows 0-15 cyan, 16-47 black,
@   48-63 green.  The box spans lines 130..257:
@     cyan at rows 130-159 only        = y>159 -> y-256 (dingbat)
@     cyan at 130-159 AND green rows 0-1 = (line - Y) mod 256 < height
@     green rows 0-1 only              = GBATEK's "treated as Y>-128" note
@ T1020: a 16x32 8bpp sprite (1D mapping) at X=192, Y=40 named tile 1020.
@   An 8bpp tile is 64 bytes but tile numbers count 32, so its four tile
@   rows sit at byte 1020*32 + 64*row: rows 0-15 (tiles 1020-1023) are the
@   last 256 bytes of OBJ VRAM and are filled yellow; rows 16-31 address
@   0x8000-0x80FF, past the 32K end.  Legend swatches:
@     T0 green   = wrapped to OBJ tile 0 (dingbat: offset and 0x7FFF)
@     B0 red     = read the FIRST 4K of BG VRAM (0x06000000)
@     BL blue    = read the LAST 4K of BG VRAM (0x0600F000)
@     BM magenta = read some other BG VRAM (everything else is magenta)
@     white      = transparent / not fetched
@ Slot: +0 56h, +1 staircase count, +2..+7 DBL attr0/1/2, +8..+13 T1020
@ attr0/1/2, +14/+16 pa/pd — configuration, not results.
.equ OG_DBL_A0,  0x8382            @ Y=130, affine, double, vertical shape
.equ OG_DBL_A1,  0xC0A0            @ X=160, size 3 (32x64), param group 0
.equ OG_DBL_A2,  96
.equ OG_WRAP_A0, 0xA028            @ Y=40, 8bpp, vertical shape
.equ OG_WRAP_A1, 0x80C0            @ X=192, size 2 (16x32)
.equ OG_WRAP_A2, 1020
probe_objgeom:
    ldr r8, =SLOTS + 38*SLOTSZ
    mov r0, #0x56
    strb r0, [r8, #0]
    mov r0, #8
    strb r0, [r8, #1]
    ldr r0, =OG_DBL_A0
    strh r0, [r8, #2]
    ldr r0, =OG_DBL_A1
    strh r0, [r8, #4]
    ldr r0, =OG_DBL_A2
    strh r0, [r8, #6]
    ldr r0, =OG_WRAP_A0
    strh r0, [r8, #8]
    ldr r0, =OG_WRAP_A1
    strh r0, [r8, #10]
    ldr r0, =OG_WRAP_A2
    strh r0, [r8, #12]
    mov r0, #0x80
    strh r0, [r8, #14]
    strh r0, [r8, #16]
    bx  lr
    .ltorg

@ ── slot 39: DMAOPENBUS — how long the last DMA word stays on the bus ────
@ dingbat (bus.nim read_open_bus_value): an unmapped read by the DMA
@ itself, or by the ONE CPU instruction after the burst, returns the last
@ word the DMA moved; the window length is Assumed.  Every stub below runs
@ from IWRAM (32-bit, zero wait: one cycle per fetch, so the spacing is
@ exact) with r4 = DMA0 regs, r5 = 0x10000000 (unmapped; OPENBUS +12 shows
@ its idle value), r0 = DMA0CNT word.  DMA0 copies 4 words EWRAM->EWRAM,
@ the last one C0FFEE42; a value that is an instruction encoding instead
@ is the prefetch ([$+8] of the reading ldr, i.e. the ldr two below it).
@ Cycle count from the enabling store's data cycle t0 (str = 1S+1N, ldr =
@ 1S+1N+1I, nop = 1S; GBATEK: the DMA takes the bus 2 cycles after the
@ enable, stalling the CPU until the burst ends — the ldr's data cycle at
@ t0+2 either slips in before the grant or is the first access after it):
@ +0  word read by `ldr` #1, data cycle t0+2   (stub 0)
@ +4  `ldr` #2, t0+5 (+burst)   +8  #3, t0+8   +12  #4, t0+11
@ +16 stub 1: one nop between the store and `ldr` #1: t0+3
@ +20 stub 1 `ldr` #2: t0+6
@ +24/+28 stub 2: a DMA3 whose SOURCE is 0x10000000 (2 words -> EWRAM) is
@         enabled by the instruction right after DMA0's enable (its data
@         cycle at t0+2).  DMA3's own latch is primed with A5A5A5A5 by a
@         1-word EWRAM->EWRAM DMA3 just before, so the two words it writes
@         name the model outright:
@           C0FFEE42 = the DMA reads the shared bus latch (DMA0's word)
@           A5A5A5A5 = each channel repeats ITS own last word
@           00000000 = an unmapped DMA read delivers zero
@         (anything else is the value the gamepak/bus really drove).
@         Priming also makes the row independent of which earlier probe
@         last used DMA3.
probe_dmaopenbus:
    push {r4-r9, lr}
    ldr r8, =SLOTS + 39*SLOTSZ
    ldr r0, =DOBSRC
    ldr r1, =0x11111111
    str r1, [r0]
    ldr r1, =0x22222222
    str r1, [r0, #4]
    ldr r1, =0x33333333
    str r1, [r0, #8]
    ldr r1, =0xC0FFEE42
    str r1, [r0, #12]
    ldr r0, =DOBDST
    mov r1, #0
    mov r2, #4
    bl  fill_words
    ldr r0, =DOBDST3
    mov r1, #0
    mov r2, #4
    bl  fill_words
    ldr r0, =dob_stubs             @ copy the stubs into IWRAM
    ldr r1, =DOBSTUB
    mov r2, #(dob_stubs_end - dob_stubs) / 4
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b
    ldr r4, =0x040000B0            @ DMA0 SAD/DAD/CNT
    ldr r0, =DOBSRC
    str r0, [r4]
    ldr r0, =DOBDST
    str r0, [r4, #4]
    ldr r5, =0x10000000
    @ stub 0: four back-to-back reads
    mov r6, r8
    ldr r0, =0x84000004            @ enable, 32-bit, count 4
    ldr r1, =DOBSTUB               @ dob_stub0
    mov lr, pc
    bx  r1
    @ stub 1: one nop first
    add r6, r8, #16
    ldr r0, =0x84000004
    ldr r1, =DOBSTUB + 28          @ dob_stub1 (checked below)
    mov lr, pc
    bx  r1
    @ prime DMA3's own latch with A5A5A5A5 (1 word, EWRAM -> EWRAM)
    ldr r7, =0x040000D4            @ DMA3 SAD/DAD/CNT
    ldr r0, =DOBSRC + 16
    ldr r1, =0xA5A5A5A5
    str r1, [r0]
    str r0, [r7]
    ldr r0, =DOBSRC + 20
    str r0, [r7, #4]
    ldr r0, =0x84000001
    str r0, [r7, #8]
    nop
    @ stub 2: DMA3 reading open bus, enabled by the very next instruction
    ldr r0, =0x10000000
    str r0, [r7]
    ldr r0, =DOBDST3
    str r0, [r7, #4]
    ldr r0, =0x84000004
    ldr r1, =0x84000002            @ DMA3: enable, 32-bit, count 2
    ldr r2, =DOBSTUB + 52          @ dob_stub2
    mov lr, pc
    bx  r2
    ldr r0, =DOBDST3
    ldr r1, [r0]
    str r1, [r8, #24]
    ldr r1, [r0, #4]
    str r1, [r8, #28]
    pop {r4-r9, pc}
    .ltorg
dob_stubs:
dob_stub0:
    str r0, [r4, #8]               @ DMA0 go            t0 = its data cycle
    ldr r1, [r5]                   @ #1  data cycle t0+2
    ldr r2, [r5]                   @ #2  t0+5
    ldr r3, [r5]                   @ #3  t0+8
    ldr r9, [r5]                   @ #4  t0+11
    stmia r6, {r1, r2, r3, r9}
    bx  lr
dob_stub1:
    str r0, [r4, #8]
    nop
    ldr r1, [r5]                   @ #1  t0+3
    ldr r2, [r5]                   @ #2  t0+6
    stmia r6, {r1, r2}
    bx  lr
dob_stub2:
    str r0, [r4, #8]               @ DMA0 go
    str r1, [r7, #8]               @ DMA3 go (data cycle t0+2)
    nop
    nop
    bx  lr
dob_stubs_end:
.if (dob_stub1 - dob_stubs) != 28 || (dob_stub2 - dob_stubs) != 52
    .error "DMAOPENBUS stub offsets moved"
.endif

@ r0 = dst (word aligned), r1 = value, r2 = word count
fill_words:
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    bx  lr


@ v7 dispatcher for the viewer: the hex viewer's mode 3 first (a visual
@ page leaves mode 0 + OBJ on), then the picture routine or draw_page.
@ Lives after the include so draw_page and the data keep their addresses.
draw_page2:
    push {r4-r9, lr}
    mov r9, r0
    ldr r1, =IOBASE
    ldr r0, =0x0403
    strh r0, [r1]
    cmp r9, #37
    beq vis_objbudget_page
    cmp r9, #38
    beq vis_objgeom_page
    mov r0, r9
    bl  draw_page
    pop {r4-r9, pc}
    .ltorg

@ ═══════════════════ VISUAL PAGES (mode 0, BG0 text + OBJ) ══════════════
@ Canvas: BG0 (priority 3, 4bpp) with the font converted to tiles 0-38 at
@ VISCHR, tile 39 = corner registration mark (drawn in all four corners:
@ photowarp-style tools need a known frame), tiles 40-47 = solid swatches
@ of palette 1..8.  BG palette entry 0 (backdrop) is white, 1 black, then
@ red blue green yellow magenta cyan grey — the OBJ palette is the same
@ table, so a swatch is the same colour as the OBJ pixels it explains.
@ Text rows 17-19 (x < 160): "CRC xxxx ALL xxxx", the page name, the
@ title + page number, exactly the hex viewer's values.

vis_palette:
    .hword 0x7FFF, 0x0000, 0x001F, 0x7C00, 0x03E0, 0x03FF, 0x7C1F, 0x7FE0
    .hword 0x5AD6, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000
corner_mark:
    .byte 0xFF, 0x81, 0xBD, 0xBD, 0xBD, 0xBD, 0x81, 0xFF
    .align 2

@ r0 = 1bpp tiles (8 bytes each), r1 = 4bpp destination, r2 = tile count;
@ set bits become palette index 1
tiles_1bpp_to_4bpp:
    push {r4-r6, lr}
    mov r3, r2, lsl #3             @ rows
1:  ldrb r4, [r0], #1
    mov r5, #0
    mov r6, #0                     @ x
2:  mov r12, #0x80
    mov r12, r12, lsr r6
    tst r4, r12
    mov r12, r6, lsl #2            @ nibble x = bits 4x..4x+3
    mov r2, #1
    orrne r5, r5, r2, lsl r12
    add r6, r6, #1
    cmp r6, #8
    blt 2b
    str r5, [r1], #4
    subs r3, r3, #1
    bne 1b
    pop {r4-r6, pc}

@ r0 = cell x, r1 = cell y, r2 = tile -> BG0 map entry
vis_glyph:
    ldr r3, =VISMAP
    add r3, r3, r1, lsl #6
    add r3, r3, r0, lsl #1
    strh r2, [r3]
    bx  lr
    .ltorg

@ r0 = x, r1 = y, r2 = string (font tile bytes), r3 = length
vis_str:
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
1:  ldrb r2, [r6], #1
    mov r0, r4
    mov r1, r5
    bl  vis_glyph
    add r4, r4, #1
    subs r7, r7, #1
    bne 1b
    pop {r4-r7, pc}

@ r0 = x, r1 = y, r2 = byte
vis_hex8:
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r2, r6, lsr #4
    and r2, r2, #0xF
    add r2, r2, #1
    bl  vis_glyph
    and r2, r6, #0xF
    add r2, r2, #1
    add r0, r4, #1
    mov r1, r5
    bl  vis_glyph
    pop {r4-r6, pc}

.macro vis_text x, y, lbl
    mov r0, #\x
    mov r1, #\y
    ldr r2, =\lbl
    mov r3, #\lbl\()_len
    bl  vis_str
.endm
.macro vis_tile x, y, tile
    mov r0, #\x
    mov r1, #\y
    mov r2, #\tile
    bl  vis_glyph
.endm
.macro vis_fill dst, val, words
    ldr r0, =\dst
    ldr r1, =\val
    ldr r2, =\words
    bl  fill_words
.endm
.macro oam_put a0, a1, a2          @ r4 -> OAM entry, advances
    ldr r0, =((\a0) & 0xFFFF) | (((\a1) & 0xFFFF) << 16)
    str r0, [r4], #4
    ldr r0, =((\a2) & 0xFFFF)
    str r0, [r4], #4
.endm

@ mode-0 canvas: BG0 text, palettes, VRAM reference fills, OAM all
@ disabled, corner marks.  Leaves the screen in forced blank; the page
@ routine writes VIS_DISPCNT when its OAM is in place.
vis_setup:
    push {r4-r7, lr}
    mov r4, #IOBASE
    mov r0, #0x80                  @ forced blank while VRAM is rewritten
    strh r0, [r4]
    ldr r0, =0x180B                @ BG0: prio 3, char base 2, screen base 24
    strh r0, [r4, #8]
    mov r0, #0
    strh r0, [r4, #0x10]           @ BG0HOFS
    strh r0, [r4, #0x12]           @ BG0VOFS
    strh r0, [r4, #0x4C]           @ MOSAIC
    strh r0, [r4, #0x50]           @ BLDCNT off
    ldr r0, =vis_palette           @ BG palette 0 and OBJ palette 0
    ldr r1, =PALBG
    ldr r2, =PALOBJ
    mov r3, #8
1:  ldr r5, [r0], #4
    str r5, [r1], #4
    str r5, [r2], #4
    subs r3, r3, #1
    bne 1b
    @ BG VRAM reference fills: the OBJ VRAM wrap probe is an 8bpp sprite,
    @ so a fetched byte IS the palette index — these are indices 6/2/3
    @ (magenta / red / blue), not 4bpp bit patterns.
    vis_fill VRAM, 0x06060606, 0x4000          @ BG VRAM: magenta ...
    vis_fill VRAM, 0x02020202, 0x400           @ ... first 4K red
    vis_fill VRAM+0xF000, 0x03030303, 0x400    @ ... last 4K blue
    vis_fill OBJVRAM, 0, 0x2000                @ OBJ VRAM transparent
    vis_fill VISMAP, 0, 0x200                  @ map: all blank
    ldr r0, =font_data                         @ font -> tiles 0..38
    ldr r1, =VISCHR
    mov r2, #39
    bl  tiles_1bpp_to_4bpp
    ldr r0, =corner_mark                       @ tile 39
    ldr r1, =VISCHR + 39*32
    mov r2, #1
    bl  tiles_1bpp_to_4bpp
    ldr r5, =VISCHR + 40*32                    @ tiles 40..47: swatches
    ldr r6, =0x11111111
    mov r7, #8
2:  mov r0, r5
    mov r1, r6
    mov r2, #8
    bl  fill_words
    add r5, r5, #32
    ldr r0, =0x11111111
    add r6, r6, r0
    subs r7, r7, #1
    bne 2b
    ldr r0, =OAM                               @ every OBJ disabled
    ldr r1, =0x00000200
    mov r2, #0
    mov r3, #128
3:  str r1, [r0], #4
    str r2, [r0], #4
    subs r3, r3, #1
    bne 3b
    vis_tile 0, 0, 39
    vis_tile 29, 0, 39
    vis_tile 0, 19, 39
    vis_tile 29, 19, 39
    pop {r4-r7, pc}
    .ltorg

@ r9 = page: rows 17-19, x < 160
vis_footer:
    push {r4-r8, lr}
    vis_text 1, 17, str_crc
    ldr r0, =SLOTS
    mov r1, #SLOTSZ
    mla r0, r9, r1, r0
    bl  crc16
    mov r8, r0
    mov r0, #5
    mov r1, #17
    mov r2, r8, lsr #8
    bl  vis_hex8
    mov r0, #7
    mov r1, #17
    and r2, r8, #0xFF
    bl  vis_hex8
    vis_text 10, 17, str_all
    ldr r0, =SLOTS
    mov r1, #(NPAGES * SLOTSZ)
    bl  crc16
    mov r8, r0
    mov r0, #14
    mov r1, #17
    mov r2, r8, lsr #8
    bl  vis_hex8
    mov r0, #16
    mov r1, #17
    and r2, r8, #0xFF
    bl  vis_hex8
    mov r0, #1
    mov r1, #18
    ldr r2, =name_table
    mov r3, #10
    mla r2, r9, r3, r2
    bl  vis_str
    vis_text 1, 19, str_title
    vis_tile 12, 19, 26            @ 'P'
    mov r0, #13
    mov r1, #19
    mov r2, r9
    bl  vis_hex8
    pop {r4-r8, pc}
    .ltorg

@ ── page 37 picture (layout in probe_objbudget's comment) ────────────────
vis_objbudget_page:
    bl  vis_setup
    vis_fill OBJVRAM+512*32, 0x88888888, 256 @ FILL: 32 grey tiles
    vis_fill OBJVRAM+544*32, 0x87654321, 128 @ TEST rows 0-15: ramp
    vis_fill OBJVRAM+560*32, 0x11111111, 128 @ TEST rows 16-31: black
    vis_fill OBJVRAM+576*32, 0x33333333, 256 @ NEXT: blue
    ldr r4, =OAM
    .rept 18                                   @ band A: OAM 0-17 fill
    oam_put OB_FILL_A0, OB_FILL_A1, OB_FILL_A2
    .endr
    oam_put OB_FILL_A0, OB_TEST_A1, OB_TEST_A2 @ OAM 18 test
    oam_put OB_FILL_A0, OB_NEXT_A1, OB_NEXT_A2 @ OAM 19 next
    .rept 18                                   @ band B (Y=56): OAM 20-37
    oam_put OB_FILL_A0+40, OB_FILL_A1, OB_FILL_A2
    .endr
    oam_put OB_FILL_A0+40, OB_TEST_A1|0x1000, OB_TEST_A2  @ 38, hflip
    oam_put OB_FILL_A0+40, OB_NEXT_A1, OB_NEXT_A2           @ 39
    oam_put OB_FILL_A0+80, OB_FILL_A1, OB_FILL_A2   @ band C (Y=96): one
    oam_put OB_FILL_A0+80, OB_TEST_A1, OB_TEST_A2   @ filler, test, next
    oam_put OB_FILL_A0+80, OB_NEXT_A1, OB_NEXT_A2
    vis_text 1, 0, str_fill
    vis_text 11, 0, str_test
    vis_text 21, 0, str_next
    vis_text 11, 6, str_ruler                  @ under band A
    vis_text 11, 11, str_ruler                 @ under band B
    vis_text 1, 11, str_flip
    vis_text 11, 16, str_ruler                 @ under band C
    vis_text 1, 16, str_ctrl
    bl  vis_footer
    mov r1, #IOBASE
    ldr r0, =VIS_DISPCNT
    strh r0, [r1]
    pop {r4-r9, pc}
    .ltorg

@ ── page 38 picture (layout in probe_objgeom's comment) ──────────────────
vis_objgeom_page:
    bl  vis_setup
    vis_fill OBJVRAM, 0x04040404, 128          @ 8bpp tiles 0-15: green
    vis_fill OBJVRAM+32*32, 0x87654321, 8    @ tile 32: column ramp
    ldr r5, =OBJVRAM + 33*32                   @ tile 33: row ramp
    ldr r6, =0x11111111
    mov r7, #8
1:  str r6, [r5], #4
    ldr r0, =0x11111111
    add r6, r6, r0
    subs r7, r7, #1
    bne 1b
    vis_fill OBJVRAM+64*32, 0x11111111, 224  @ Y200: rows 0-55 black
    vis_fill OBJVRAM+92*32, 0x55555555, 32   @       rows 56-63 yellow
    vis_fill OBJVRAM+96*32, 0x77777777, 64   @ DBL: rows 0-15 cyan
    vis_fill OBJVRAM+104*32, 0x11111111, 128 @      rows 16-47 black
    vis_fill OBJVRAM+120*32, 0x44444444, 64  @      rows 48-63 green
    vis_fill OBJVRAM+1020*32, 0x05050505, 64 @ T1020 rows 0-15: yellow
    ldr r4, =OAM
    .irp k, 0, 1, 2, 3, 4, 5, 6, 7             @ OAM 0-7: X staircase
    oam_put 40+8*\k, 0x1F8+\k, 32
    .endr
    .irp k, 0, 1, 2, 3, 4, 5, 6, 7             @ OAM 8-15: Y staircase
    oam_put 248+\k, 40+8*\k, 33
    .endr
    oam_put 0x80C8, 0xC070, 64                 @ OAM 16: Y200 32x64
    oam_put OG_DBL_A0, OG_DBL_A1, OG_DBL_A2    @ OAM 17: Y130 DBL
    oam_put OG_WRAP_A0, OG_WRAP_A1, OG_WRAP_A2 @ OAM 18: T1020
    ldr r4, =OAM                               @ affine group 0: 2x scale
    mov r0, #0x80
    strh r0, [r4, #6]                          @ pa
    mov r0, #0
    strh r0, [r4, #14]                         @ pb
    strh r0, [r4, #22]                         @ pc
    mov r0, #0x80
    strh r0, [r4, #30]                         @ pd
    vis_text 5, 2, str_ystair
    vis_text 14, 2, str_y200
    vis_text 1, 4, str_xstair
    vis_text 24, 4, str_t1020
    vis_text 25, 9, str_lg_t0
    vis_tile 28, 9, 43                         @ green swatch
    vis_text 25, 10, str_lg_b0
    vis_tile 28, 10, 41                        @ red
    vis_text 25, 11, str_lg_bl
    vis_tile 28, 11, 42                        @ blue
    vis_text 25, 12, str_lg_bm
    vis_tile 28, 12, 45                        @ magenta
    vis_text 20, 15, str_dbl
    bl  vis_footer
    mov r1, #IOBASE
    ldr r0, =VIS_DISPCNT
    strh r0, [r1]
    pop {r4-r9, pc}
    .ltorg


@ ═════════ pages 40-49 (v8): the nine open GBA rows ══════════════════════
@ Hooked in through probe_tail -> probe_tail3, after every byte of the v1-v7
@ build, so pages 0-39 transcribe unchanged (verified by capturing both
@ binaries through hwprobe_capture.py and diffing).  Layouts, and the
@ instruction spacing every number depends on, are in the comment block
@ above each probe; tests/roms/README-probes-gba.md says what to photograph
@ and what each outcome pins.
.equ V8SCR,    0x02001080          @ v8 scratch: IRQ counters
.equ V8STUB,   0x03000500          @ v8 IWRAM stubs
.equ V8SRC,    0x0200A000          @ v8 EWRAM source area (16K)
.equ V8DST,    0x0200E000          @ v8 EWRAM destination area
.equ V8VSTUB,  0x06014000          @ v8 VRAM-resident stub (OBJ VRAM, past
                                   @ the mode-3 framebuffer; the viewer's
                                   @ vis_setup rewrites it before any visual
                                   @ page uses that address)
.equ TM0BASE,  0x04000100
.equ TM2BASE,  0x04000108
.equ TM3BASE,  0x0400010C
.equ IEADDR,   0x04000200          @ +2 = IF, +8 = IME
.equ HALTCNT,  0x04000301

probe_tail3:
    push {lr}
    ldr r0, =SLOTS + 40*SLOTSZ     @ v8 slots (EWRAM boots as noise)
    mov r1, #0
    mov r2, #(10 * SLOTSZ / 4)
    bl  fill_words
    ldr r0, =V8SCR
    mov r1, #0
    mov r2, #16
    bl  fill_words
    ldr r0, =MARKER                @ the watchdog "probe in flight" word is
    mov r1, #0                     @ EWRAM noise until run_msr_probe sets it
    str r1, [r0, #8]
    bl  probe_irqdecomp
    bl  probe_contend2
    bl  probe_multime
    bl  probe_timphase
    bl  probe_psgphase
    bl  probe_memctl
    bl  probe_dmatime
    bl  probe_iwcycle
    bl  probe_dmafifo
    bl  probe_undmode
    pop {pc}
    .ltorg

@ r0 = src, r1 = dst, r2 = word count
v8_copy:
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b
    bx  lr

@ TM2 + TM3 cascade: a second 32-bit cycle counter, for the page that needs
@ TM0 for something else (DMAFIFO drives the sound FIFO from TM0).  Same
@ shape as tm_start/tm_stop, so its fixed overhead is constant too.
v8_tm23_start:
    ldr r3, =TM2BASE
    mov r2, #0
    str r2, [r3]
    str r2, [r3, #4]
    ldr r1, =0x00840000            @ TM3: enable + cascade
    str r1, [r3, #4]
    ldr r2, =0x00800000            @ TM2: enable, prescaler 1
    str r2, [r3]
    bx  lr
v8_tm23_stop:                      @ -> r0 = 32-bit elapsed
    ldr r3, =TM2BASE
    ldrh r0, [r3]
    ldrh r1, [r3, #4]
    mov r2, #0
    str r2, [r3]
    str r2, [r3, #4]
    orr r0, r0, r1, lsl #16
    bx  lr
    .ltorg

@ ── slot 40: IRQDECOMP — the IRQ delivery pipeline, decomposed ───────────
@ IRQLAT/IRQLAT2 produced one number per source, and the constants fitted to
@ them (IRQ_SYNC_DELAY 3, HBLANK_IRQ_SYNC_DELAY 6) are one-row fits; session
@ 1 still had dingbat +18 on DMA3, +7/+31 on hblank and +12/+18 on vblank.
@ Every number below is (the handler's TM0 entry stamp) - (a TM0 stamp taken
@ by the instruction immediately before the arming store), so the BIOS
@ dispatch, the pipeline refill and the handler's own two instructions are
@ the same constant in every row and the DIFFERENCES between rows are the
@ pipeline.  TM0 free-runs at prescaler 1 for the whole page; the shared
@ irq_handler stamps only the first entry after SCRATCH+0x4C is cleared.
@
@ The timer rows use TM2 at prescaler 1, so the reload states the delay
@ exactly: reload FFF0 overflows 16 ticks after the enable, reload 0000
@ 65536 ticks (TM0 wraps in the same 65536, so the mod-2^16 delta is the
@ latency itself) and reload 0001 one tick sooner again.  A reload that
@ moves a row by anything other than its own arithmetic is the reload
@ reaching into the delivery path.
@ +0  (h) TM2 reload FFF0, ONE 32-bit CNT write, CPU running
@ +2  (h) the same armed as TWO halfword writes (CNT_L reload, then CNT_H)
@ +4  (h) TM2 reload 0000, one write   +6  (h) TM2 reload 0001, one write
@ +8  (h) TM2 reload FFF0, one write, then HALTCNT two instructions later
@ +10 (h) hblank, running     +12 (h) hblank, halted
@ +14 (h) vblank, running     +16 (h) vblank, halted
@ +18 (h) DMA3 complete, running       +20 (h) DMA3 complete, halted
@   The hblank and vblank rows are anchored: IME is off while the code waits
@   for the hblank flag to fall (a line start) or for VCOUNT to reach 158,
@   IF is acked, TM0 is stamped, and the IME write IS the arming store.  So
@   an hblank row is ~1006 cycles + latency, a vblank row ~2 lines +
@   latency, and (halted - running) is the halt-exit cost on its own.
@ +22..+29 (8 b) IF (low byte) read one instruction after `strh 0xFFFF,[IF]`
@   raced against a TM2 overflow, from an IWRAM stub (32-bit, zero wait: one
@   cycle per instruction).  The ack write's data cycle sits at
@   t0 + 2 + 3 + (24 - 2j) + 1 for j = 0..7 — t0+30 down to t0+16 — and the
@   overflow is near t0+18: the byte reads 20 while the ack lands before the
@   request and 00 after it.  A 00 too early, or a 20 too late, is the ack
@   winning (or losing) a same-cycle race with a fresh request.
@ +30 (b) progress marker: the row index, written before each halting row;
@         FF once the page finished
@ +31 (b) rows whose interrupt never arrived (the bounded spin gave up)
.macro id_clear
    mov r0, #0
    str r0, [r7, #0x4C]
.endm
@ r5 = trigger stamp; bounded spin, then the delta -> [r8, #off]
.macro id_delta off
    ldr r6, =0x00080000
9:  ldr r0, [r7, #0x4C]
    cmp r0, #0
    bne 7f
    subs r6, r6, #1
    bne 9b
    ldrb r0, [r8, #31]             @ never arrived: count it
    add r0, r0, #1
    strb r0, [r8, #31]
7:  ldrh r0, [r7, #0x48]
    sub r0, r0, r5
    strh r0, [r8, #\off]
.endm
.macro id_ie bits
    ldr r0, =IEADDR
    ldr r1, =\bits
    strh r1, [r0]
    ldr r1, =0x3FFF
    strh r1, [r0, #2]              @ ack everything stale
.endm
.macro id_ime v
    ldr r0, =IEADDR
    mov r1, #\v
    strh r1, [r0, #8]
.endm
.macro id_mark n
    mov r0, #\n
    strb r0, [r8, #30]
.endm
.macro id_halt
    ldr r0, =HALTCNT
    mov r1, #0
    strb r1, [r0]
.endm
.macro id_anchor_hb
    id_ime 0
    ldrh r0, [r4, #4]
    orr r0, r0, #0x10              @ DISPSTAT: hblank IRQ enable
    strh r0, [r4, #4]
1:  ldrh r0, [r4, #4]
    tst r0, #2
    beq 1b                         @ wait for the hblank flag HIGH
2:  ldrh r0, [r4, #4]
    tst r0, #2
    bne 2b                         @ ... then its FALL: a line start
    id_clear
    id_ie 0x0042                   @ IE: hblank + the timer-3 watchdog
.endm
.macro id_anchor_vb
    id_ime 0
    ldrh r0, [r4, #4]
    orr r0, r0, #0x08              @ DISPSTAT: vblank IRQ enable
    strh r0, [r4, #4]
1:  ldrh r0, [r4, #6]
    cmp r0, #157
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #158
    bne 2b
    id_clear
    id_ie 0x0041                   @ IE: vblank + the timer-3 watchdog
.endm
.macro id_dma3
    ldr r6, =0x040000D4            @ DMA3: SAD, DAD, CNT
    ldr r0, =rom_pattern
    str r0, [r6]
    ldr r0, =EWDST
    str r0, [r6, #4]
    id_clear
    id_ie 0x0840                   @ IE: DMA3 + the timer-3 watchdog
    id_ime 1
    ldr r1, =0xC4000004            @ enable + IRQ, word, count 4
.endm

@ The page installs its OWN interrupt handler.  The shared irq_handler
@ leaves the source running, and a TM2 reload of FFF0 re-overflows every 16
@ cycles — faster than the BIOS dispatcher can return — so the console
@ makes no forward progress at all.  This one stamps TM0 in its first two
@ instructions (exactly as irq_handler does, so the fixed entry cost is the
@ same constant in every row), then kills IME and TM2 so each row takes
@ exactly one interrupt.  irq_handler is put back at the end of the page.
v8_id_handler:
    ldr r0, =TM0BASE
    ldrh r1, [r0]                  @ entry stamp: the first thing, always
    ldr r0, =IEADDR
    mov r2, #0
    strh r2, [r0, #8]              @ IME off: one interrupt per row
    ldrh r2, [r0, #2]              @ IF
    strh r2, [r0, #2]              @ ... acknowledged
    ldr r0, =TM2BASE
    mov r2, #0
    str r2, [r0]                   @ TM2 off, so a 16-cycle reload cannot
    ldr r0, =SCRATCH               @ storm the dispatcher
    ldr r2, [r0, #0x4C]
    cmp r2, #0
    streqh r1, [r0, #0x48]
    moveq r2, #1
    streq r2, [r0, #0x4C]
    bx  lr
    .ltorg

@ TM2 armed by one 32-bit CNT write, and the delta recorded
.macro id_timer_row cnt, off, halt
    mov r0, #0
    str r0, [r9]                   @ TM2 off, so the enable reloads
    id_clear
    id_ie 0x0060                   @ IE: timer 2 + the timer-3 watchdog
    id_ime 1
    ldr r1, =\cnt
    ldrh r5, [r10]
    str r1, [r9]
.if \halt
    id_halt
.endif
    id_delta \off
    mov r0, #0
    str r0, [r9]
.endm

probe_irqdecomp:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 40*SLOTSZ
    ldr r7, =SCRATCH
    mov r4, #IOBASE
    ldr r9, =TM2BASE
    ldr r10, =TM0BASE
    ldr r11, =TM3BASE
    ldr r0, =0x03007FFC            @ our own handler for the whole page
    ldr r1, =v8_id_handler
    str r1, [r0]
    bl  tm_start                   @ TM0 free-runs as the session clock
    mov r0, #0                     @ watchdog: TM3 at prescaler 64, reload 0
    str r0, [r11]                  @ = 4.2M cycles, far longer than any row,
    ldr r0, =0x00C10000            @ so it only ever ends a stuck halt
    str r0, [r11]

    @ ── timer rows ──
    id_mark 0
    id_timer_row 0x00C0FFF0, 0, 0  @ reload FFF0: overflow 16 ticks out
    id_mark 1
    mov r0, #0                     @ the same arm as two halfword writes
    str r0, [r9]
    id_clear
    id_ie 0x0060
    id_ime 1
    ldr r1, =0xFFF0
    mov r2, #0xC0                  @ CNT_H: enable + IRQ, prescaler 1
    ldrh r5, [r10]
    strh r1, [r9]                  @ CNT_L first ...
    strh r2, [r9, #2]              @ ... then CNT_H
    id_delta 2
    mov r0, #0
    str r0, [r9]
    id_mark 2
    id_timer_row 0x00C00000, 4, 0  @ reload 0000: 65536 ticks
    id_mark 3
    id_timer_row 0x00C00001, 6, 0  @ reload 0001: one tick sooner
    id_mark 4                      @ from here the row halts the CPU
    id_timer_row 0x00C0FFF0, 8, 1

    @ ── hblank rows ──
    id_mark 5
    id_anchor_hb
    ldr r0, =IEADDR
    mov r1, #1
    ldrh r5, [r10]
    strh r1, [r0, #8]              @ the IME write is the arming store
    id_delta 10

    id_mark 6
    id_anchor_hb
    ldr r0, =IEADDR
    mov r1, #1
    ldrh r5, [r10]
    strh r1, [r0, #8]
    id_halt
    id_delta 12
    ldrh r0, [r4, #4]
    bic r0, r0, #0x10
    strh r0, [r4, #4]

    @ ── vblank rows ──
    id_mark 7
    id_anchor_vb
    ldr r0, =IEADDR
    mov r1, #1
    ldrh r5, [r10]
    strh r1, [r0, #8]
    id_delta 14

    id_mark 8
    id_anchor_vb
    ldr r0, =IEADDR
    mov r1, #1
    ldrh r5, [r10]
    strh r1, [r0, #8]
    id_halt
    id_delta 16
    ldrh r0, [r4, #4]
    bic r0, r0, #0x08
    strh r0, [r4, #4]

    @ ── DMA3-complete rows ──
    id_mark 9
    id_dma3
    ldrh r5, [r10]
    str r1, [r6, #8]
    id_delta 18

    id_mark 10
    id_dma3
    ldrh r5, [r10]
    str r1, [r6, #8]
    id_halt
    id_delta 20

    id_ime 0
    id_ie 0
    mov r0, #0
    str r0, [r11]                  @ watchdog off
    str r0, [r9]

    @ ── the IF acknowledge race (IME stays off: only IF moves) ──
    id_mark 11
    ldr r0, =v8_race_stub
    ldr r1, =V8STUB
    mov r2, #(v8_race_end - v8_race_stub) / 4
    bl  v8_copy
    mov r11, #0                    @ j
1:  mov r0, #0
    str r0, [r9]                   @ TM2 off, so the enable reloads
    ldr r0, =IEADDR
    ldr r1, =0x3FFF
    strh r1, [r0, #2]              @ ack every stale flag
    ldr r0, =0x00C0FFF0            @ enable + IRQ (so IF moves), reload FFF0
    mov r1, r9
    ldr r2, =0x04000202
    ldr r3, =0xFFFF
    mov r6, r11, lsl #3            @ two nops of sled per step
    ldr r12, =V8STUB
    mov lr, pc
    bx  r12
    add r0, r8, #22
    strb r5, [r0, r11]
    add r11, r11, #1
    cmp r11, #8
    blt 1b
    mov r0, #0
    str r0, [r9]
    ldr r0, =IEADDR
    ldr r1, =0x3FFF
    strh r1, [r0, #2]

    bl  tm_stop
    ldr r0, =0x03007FFC            @ hand the shared handler back
    ldr r1, =irq_handler
    str r1, [r0]
    id_mark 0xFF
    pop {r4-r11, pc}
    .ltorg

@ Runs from IWRAM (32-bit, zero wait: one cycle per instruction, so the
@ spacing is exact).  r0 = TM2 CNT word, r1 = TM2 base, r2 = IF address,
@ r3 = FFFF, r6 = sled byte offset -> r5 = IF read back.
@ str = 1S+1N (2), add pc = 2S+1N (3), nop = 1S.
v8_race_stub:
    str r0, [r1]                   @ t0: TM2 armed, overflow 16 ticks later
    add pc, pc, r6                 @ pc reads as the first sled nop
    nop
    .rept 24
    nop
    .endr
    strh r3, [r2]                  @ IF = FFFF: acknowledge everything
    ldrh r5, [r2]                  @ ... and read it straight back
    bx  lr
v8_race_end:

@ ── slot 41: CONTEND2 — contention with the renderer fully loaded ────────
@ CONTEND (slot 14) measured an idle-ish machine and dingbat matched it
@ exactly; bus.nim charges PRAM/VRAM/OAM a constant and models no renderer
@ contention at all, so this page loads the PPU as hard as the hardware
@ allows and re-measures.  Load: 128 OBJs of 64x64 at Y=40, X = 0..127, all
@ overlapping the sampled line, plus every background the mode has.
@ Each row is 16 back-to-back `ldrh` from one region, TM0/TM1-bracketed,
@ begun at the top of the visible part of line 40 (VCOUNT has just become
@ 40; 16 reads fit easily inside the 960-cycle visible window).  The IWRAM
@ rows are controls: the PPU never touches IWRAM, so movement there is
@ measurement drift, not contention.
@ +0/+2/+4/+6     PRAM / VRAM / OAM / IWRAM, mode 0, BG0-3 + OBJ, 128 OBJs
@ +8/+10/+12/+14  the same in mode 2 (affine BG2 + BG3) + OBJ, 128 OBJs
@ +16/+18/+20     PRAM / VRAM / OAM, mode 0, BG0-3, OBJ layer off
@ +22             the same 16 reads (of IWRAM) EXECUTED from a stub in VRAM,
@                 mode 0 + 128 OBJs: code-fetch contention, not data
@ +24/+26         VRAM / OAM with hblank-interval-free (DISPCNT.5) set
@ +28/+30         VRAM / IWRAM under forced blank: the free-access baseline
.equ C2_M0,    0x1F40              @ mode 0, BG0-3 + OBJ, 1D OBJ mapping
.equ C2_M2,    0x1C42              @ mode 2, BG2 + BG3 + OBJ, 1D
.equ C2_M0NO,  0x0F40              @ mode 0, BG0-3, no OBJ layer
.equ C2_HBF,   0x1F60              @ C2_M0 + hblank-interval-free
.equ C2_BLANK, 0x1F80              @ forced blank
.macro c2_row cfg, base, off
    ldr r0, =\cfg
    strh r0, [r4]
    wait_line40
    bl  tm_start
    ldr r2, =\base
    .rept 16
    ldrh r3, [r2]
    .endr
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
probe_contend2:
    push {r4-r9, lr}
    ldr r8, =SLOTS + 41*SLOTSZ
    mov r4, #IOBASE
    mov r0, #0x80                  @ forced blank while OAM is rewritten
    strh r0, [r4]
    ldr r0, =OAM                   @ 128 OBJs, 64x64, Y = 40, X = 0..127
    mov r1, #0
1:  mov r2, #40                    @ attr0: Y = 40, square, normal, 4bpp
    orr r3, r1, #0xC000            @ attr1: X = k, size 3 (64x64)
    orr r2, r2, r3, lsl #16
    str r2, [r0], #4
    mov r2, #0                     @ attr2: tile 0, priority 0
    str r2, [r0], #4
    add r1, r1, #1
    cmp r1, #128
    blt 1b
    mov r0, #0x100                 @ affine BG2/BG3: identity scale, so the
    strh r0, [r4, #0x20]           @ mode-2 rows fetch a real texture
    strh r0, [r4, #0x26]
    strh r0, [r4, #0x30]
    strh r0, [r4, #0x36]
    ldr r0, =v8_vram_stub          @ the VRAM-resident copy of the read row
    ldr r1, =V8VSTUB
    mov r2, #(v8_vram_end - v8_vram_stub) / 4
    bl  v8_copy

    c2_row C2_M0,   0x05000000, 0
    c2_row C2_M0,   0x06000000, 2
    c2_row C2_M0,   0x07000000, 4
    c2_row C2_M0,   0x03000000, 6
    c2_row C2_M2,   0x05000000, 8
    c2_row C2_M2,   0x06000000, 10
    c2_row C2_M2,   0x07000000, 12
    c2_row C2_M0NO, 0x05000000, 16
    c2_row C2_M0NO, 0x06000000, 18
    c2_row C2_M0NO, 0x07000000, 20

.macro c2_vrun cfg, off                @ the same sixteen reads, fetched
    ldr r0, =\cfg                      @ from the VRAM-resident stub
    strh r0, [r4]
    wait_line40
    bl  tm_start
    ldr r2, =0x03000000
    ldr r1, =V8VSTUB
    mov lr, pc
    bx  r1
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
    c2_vrun C2_M0,    22
    c2_vrun C2_BLANK, 14

    c2_row C2_HBF,   0x06000000, 24
    c2_row C2_HBF,   0x07000000, 26
    c2_row C2_BLANK, 0x06000000, 28
    c2_row C2_BLANK, 0x03000000, 30

    mov r0, #0x80                  @ park every OBJ again: vis_setup disables
    strh r0, [r4]                  @ them all, but nothing else would
    ldr r0, =OAM
    ldr r1, =0x00000200            @ attr0 bit 9 with bit 8 clear = disabled
    mov r2, #0
    mov r3, #128
2:  str r1, [r0], #4
    str r2, [r0], #4
    subs r3, r3, #1
    bne 2b
    ldr r0, =0x0403                @ restore the viewer's DISPCNT
    strh r0, [r4]
    pop {r4-r9, pc}
    .ltorg
v8_vram_stub:                      @ r2 = base; fetched from VRAM (16-bit)
    .rept 16
    ldrh r3, [r2]
    .endr
    bx  lr
v8_vram_end:

@ ── slot 42: MULTIME — the MUL family's carry, and early termination ─────
@ MULFLAGS (slot 7) caught hardware CLEARING C where dingbat sets it, on six
@ of eight operand pairs; one op and eight pairs cannot fit the function.
@ Here six ops run the SAME sixteen (Rm, Rs) pairs and only the C bit is
@ kept — one bit per pair, LSB = pair 0 — so a 16-pair carry matrix costs
@ two bytes a row.  Pairs 0-7 are MULFLAGS' table byte for byte (slot 7
@ therefore cross-checks this page); pairs 8-15 hold Rm at 12345678 and
@ sweep Rs through every early-termination class, which is the axis a fit
@ needs.
@   pair  Rm        Rs             pair  Rm        Rs
@   0     00000000  00000000       8     12345678  00000001
@   1     FFFFFFFF  FFFFFFFF       9     12345678  000000FF
@   2     000000FF  FF00FF00       10    12345678  00000100
@   3     12345678  9ABCDEF0       11    12345678  0000FFFF
@   4     0000FFFF  0000FFFF       12    12345678  00010000
@   5     80000000  00000002       13    12345678  00FFFFFF
@   6     FFFFFF00  00000100       14    12345678  01000000
@   7     00000001  FFFFFFFF       15    12345678  FFFFFFFF
@ The carry preset is pinned by `subs r10, r6, #0` (C := 1, no borrow) or
@ `adds r10, r6, #0` (C := 0, no carry out) immediately before the multiply,
@ and the accumulating ops start from zero in both halves.
@ +0  (h) MULS,   C preset 1      +2  (h) MULS,   C preset 0
@ +4  (h) MLAS,   C preset 1      +6  (h) MLAS,   C preset 0
@ +8  (h) UMULLS, C preset 1      +10 (h) SMULLS, C preset 1
@ +12 (h) UMLALS, C preset 1      +14 (h) SMLALS, C preset 1
@ +16..+31 (8 h) the early-termination sweep: cycles for sixteen back-to-
@   back `muls r0, r1, r2` with r1 = 12345678 fixed and r2 stepping through
@   00000012 / 00001234 / 00123456 / 12345678 and their negatives
@   FFFFFFEE / FFFFEDCC / FFEDCBAA / EDCBA988 — the four magnitude classes,
@   and the all-ones-above forms Booth termination is supposed to treat as
@   the same class.  The timed window also holds tm_start, tm_stop and two
@   `mov`s, the same constant in all eight rows, so (row - row) / 16 is the
@   m-cycle step between classes.
.macro mt_vec preset, off, op:vararg
    mov r6, #0                     @ pair index
    mov r9, #0                     @ carry bit vector
    ldr r7, =mul16_ops
1:  add r0, r7, r6, lsl #3
    ldr r1, [r0]                   @ Rm
    ldr r2, [r0, #4]               @ Rs
    mov r3, #0                     @ MLA accumulator
    mov r4, #0                     @ RdHi / accumulate high half
    mov r0, #0                     @ RdLo / accumulate low half
.if \preset
    subs r10, r6, #0               @ C := 1
.else
    adds r10, r6, #0               @ C := 0
.endif
    \op
    mrs r10, CPSR
    mov r11, #0
    tst r10, #0x20000000
    movne r11, #1
    orr r9, r9, r11, lsl r6
    add r6, r6, #1
    cmp r6, #16
    blt 1b
    strh r9, [r8, #\off]
.endm
probe_multime:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 42*SLOTSZ
    mt_vec 1, 0,  muls r0, r1, r2
    mt_vec 0, 2,  muls r0, r1, r2
    mt_vec 1, 4,  mlas r0, r1, r2, r3
    mt_vec 0, 6,  mlas r0, r1, r2, r3
    mt_vec 1, 8,  umulls r0, r4, r1, r2
    mt_vec 1, 10, smulls r0, r4, r1, r2
    mt_vec 1, 12, umlals r0, r4, r1, r2
    mt_vec 1, 14, smlals r0, r4, r1, r2

    mov r6, #0
    ldr r7, =mt_sweep
2:  ldr r5, =0x12345678
    ldr r4, [r7, r6, lsl #2]
    bl  tm_start                   @ clobbers r1-r3; r4-r7 survive
    mov r1, r5
    mov r2, r4
    .rept 16
    muls r0, r1, r2
    .endr
    bl  tm_stop
    add r3, r8, #16
    add r3, r3, r6, lsl #1
    strh r0, [r3]
    add r6, r6, #1
    cmp r6, #8
    blt 2b
    pop {r4-r11, pc}
    .ltorg
mul16_ops:
    .word 0x00000000, 0x00000000
    .word 0xFFFFFFFF, 0xFFFFFFFF
    .word 0x000000FF, 0xFF00FF00
    .word 0x12345678, 0x9ABCDEF0
    .word 0x0000FFFF, 0x0000FFFF
    .word 0x80000000, 0x00000002
    .word 0xFFFFFF00, 0x00000100
    .word 0x00000001, 0xFFFFFFFF
    .word 0x12345678, 0x00000001
    .word 0x12345678, 0x000000FF
    .word 0x12345678, 0x00000100
    .word 0x12345678, 0x0000FFFF
    .word 0x12345678, 0x00010000
    .word 0x12345678, 0x00FFFFFF
    .word 0x12345678, 0x01000000
    .word 0x12345678, 0xFFFFFFFF
mt_sweep:
    .word 0x00000012, 0x00001234, 0x00123456, 0x12345678
    .word 0xFFFFFFEE, 0xFFFFEDCC, 0xFFEDCBAA, 0xEDCBA988

@ ── slot 43: TIMPHASE — is the prescaler one divider, and is it shared? ──
@ TIMERS (slot 4) found a staircase (hw 07 07 07 06 06 06) when TM2 is
@ enabled k cycles later against a moving sample point: the prescaler is not
@ reset by the enable, it free-runs.  What that cannot say is whether the
@ four timers share ONE divider.  Every row here comes out of the same IWRAM
@ stub, which enables TM2, enables TM3 two cycles later, and samples both
@ after an identical delay — entered at eight sled offsets 12 cycles apart,
@ 96 cycles of stagger in all, one and a half prescaler-64 periods.
@   one shared divider  -> the TM2 and TM3 staircases step at the SAME sled
@                          offset and the counts never differ by more than 1
@   a divider per timer -> the two staircases step at unrelated offsets
@ +0..+7   (8 b) TM2 (prescaler 64) count, sled offsets j = 0..7
@ +8..+15  (8 b) TM3 (prescaler 64) count at those same instants
@ +16..+23 (8 b) TM2 count, same staircase, with `strh reload, [TM2CNT_L]`
@   executed one instruction behind the enable: a divider the reload write
@   realigns flattens this staircase against +0..+7
@ +24..+27 (4 b) TM2 at prescaler 256, sled offsets j = 0, 2, 4, 6 — the 256
@   tap of the same chain, which should staircase at four times the period
@ +28 (b) TM2's count when TM3 was ALREADY running at prescaler 64 (the stub
@   rewrites TM3's CNT with enable already set, which does not reload it)
@ +29 (b) TM3's count at that same instant: equal counts mean the freshly
@   enabled timer inherited the running one's phase
@ +30 (b) marker 54
@ +31 (b) TM0 (prescaler 1) low byte at the j = 0 sample: the absolute phase
@   anchor everything above is measured against
.macro tp_run stuboff, cnt2, cnt3, j, dst
    ldr r0, =\cnt2
    ldr r1, =TM2BASE
    ldr r3, =\cnt3
    mov r2, #(48 * \j)
    mov r6, #100                   @ delay iterations (~400 cycles)
    ldr r12, =V8STUB
    add r12, r12, #\stuboff
    mov lr, pc
    bx  r12
    strb r4, [r8, #\dst]
.endm
probe_timphase:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 43*SLOTSZ
    ldr r0, =v8_tp_stubs
    ldr r1, =V8STUB
    mov r2, #(v8_tp_end - v8_tp_stubs) / 4
    bl  v8_copy
    ldr r9, =TM2BASE
    mov r0, #0
    str r0, [r9]
    str r0, [r9, #4]

    .irp j, 0, 1, 2, 3, 4, 5, 6, 7
    mov r0, #0
    str r0, [r9]
    str r0, [r9, #4]
    tp_run 0, 0x00810000, 0x00810000, \j, (\j)
    strb r5, [r8, #(8 + \j)]
    .if \j == 0
    ldr r0, =TM0BASE               @ the prescaler-1 phase anchor
    ldrh r0, [r0]
    strb r0, [r8, #31]
    .endif
    .endr

    .irp j, 0, 1, 2, 3, 4, 5, 6, 7
    mov r0, #0
    str r0, [r9]
    str r0, [r9, #4]
    tp_run (v8_tp_reload - v8_tp_stubs), 0x00810000, 0x0000FFF0, \j, (16 + \j)
    .endr

    .irp j, 0, 2, 4, 6
    mov r0, #0
    str r0, [r9]
    str r0, [r9, #4]
    tp_run 0, 0x00820000, 0x00820000, \j, (24 + (\j / 2))
    .endr

    mov r0, #0                     @ TM3 already running, TM2 enabled into it
    str r0, [r9]
    str r0, [r9, #4]
    ldr r0, =0x00810000
    str r0, [r9, #4]
    mov r0, #40
1:  subs r0, r0, #1
    bne 1b
    tp_run 0, 0x00810000, 0x00810000, 0, 28
    strb r5, [r8, #29]
    mov r0, #0
    str r0, [r9]
    str r0, [r9, #4]
    mov r0, #0x54
    strb r0, [r8, #30]
    pop {r4-r11, pc}
    .ltorg

@ IWRAM stubs.  r0 = TM2 CNT word, r1 = TM2 base, r2 = sled byte offset,
@ r3 = TM3 CNT word (or, in the second stub, the reload halfword), r6 =
@ delay iterations -> r4 = TM2 count, r5 = TM3 count.  One cycle per
@ instruction, so a sled offset of 48 is exactly 12 cycles of stagger.
v8_tp_stubs:
    add pc, pc, r2
    nop
    .rept 96
    nop
    .endr
    str r0, [r1]                   @ TM2 enable
    str r3, [r1, #4]               @ TM3 enable, two cycles later
    mov r7, r6
1:  subs r7, r7, #1
    bne 1b
    ldrh r4, [r1]
    ldrh r5, [r1, #4]
    bx  lr
v8_tp_reload:
    add pc, pc, r2
    nop
    .rept 96
    nop
    .endr
    str r0, [r1]                   @ TM2 enable ...
    strh r3, [r1]                  @ ... and a reload write right behind it
    mov r7, r6
1:  subs r7, r7, #1
    bne 1b
    ldrh r4, [r1]
    mov r5, #0
    bx  lr
v8_tp_end:

@ ── slot 44: PSGPHASE — length expiry against the frame sequencer ────────
@ PSGSTAT (slot 10) polled ch1's active flag down from a length-63 trigger:
@ hardware took 2E1E iterations, dingbat 283A — 14 % early.  One number
@ cannot say whether dingbat's length clock runs fast or merely starts at
@ the wrong phase, because the 256 Hz length tick belongs to a free-running
@ frame sequencer and a trigger lands somewhere inside its period.  Every
@ row below is that same poll count (one `ldrh SOUNDCNT_X`, a test and an
@ increment per iteration; ~5.5 cycles on hardware), from triggers placed at
@ four offsets inside one 256 Hz period, with and without a SOUNDCNT_X
@ master off/on in front of the trigger.
@   master off/on RESETS the sequencer -> +0..+6 are equal, +8..+14 stagger
@   the sequencer free-runs regardless -> both blocks stagger alike
@ The delays are loop iterations, not cycles (a ROM `subs`/`bne` pair), and
@ the four of them span roughly one 65536-cycle length step.
@ +0/+2/+4/+6    (4 h) ch1 length 63, master off then on, the trigger
@   delayed 0 / 4000 / 8000 / 12000 iterations after the master-on write
@ +8/+10/+12/+14 (4 h) the same four delays, master left on throughout
@ +16 (h) length 62 (two 256 Hz steps), master toggled, no delay
@ +18 (h) length 60 (four steps), master toggled, no delay
@ +20 (h) ch1 length 63 with ch2 triggered by the very next store and both
@   polled in one loop: this is the ch1 count ...
@ +26 (h) ... and this is (ch2's count - ch1's count).  0 means one length
@   clock stands behind both channels.
@ +22 (h) ch1 length 63 retriggered while the previous tone is still running
@ +24 (b) SOUNDCNT_X right after the +0 trigger
@ +25 (b) SOUNDCNT_X right after that row's expiry
@ +28 (h) ch1 length 63 after SOUNDCNT_X was toggled off/on/off/on
@ +30 (b) marker 50    +31 (b) rows that hit the poll cap
.macro pp_init                     @ (re)program the PSG after a master-off
    mov r0, #0x80
    strh r0, [r4, #0x84]           @ SOUNDCNT_X: master on
    ldr r0, =0x1177
    strh r0, [r4, #0x80]           @ ch1 + ch2 both sides, full volume
    mov r0, #2
    strh r0, [r4, #0x82]           @ PSG ratio 100 %
.endm
.macro pp_delay n
.if \n
    ldr r0, =\n
1:  subs r0, r0, #1
    bne 1b
.endif
.endm
probe_psgphase:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 44*SLOTSZ
    mov r4, #IOBASE
    mov r9, #0                     @ poll-cap hits

    .irp d, 0, 4000, 8000, 12000
    mov r0, #0
    strh r0, [r4, #0x84]           @ master OFF (clears every PSG register)
    pp_init
    pp_delay \d
    ldr r0, =0xF0BF                @ envelope 15, duty 2, length 63
    ldr r1, =0xC400                @ trigger + length enable
    bl  v8_ch1_wait
    strh r3, [r8, #(0 + (\d / 4000) * 2)]
    .if \d == 0
    strb r6, [r8, #24]
    strb r7, [r8, #25]
    .endif
    .endr

    mov r0, #0                     @ master left on across the next four
    strh r0, [r4, #0x84]
    pp_init
    .irp d, 0, 4000, 8000, 12000
    pp_delay \d
    ldr r0, =0xF0BF
    ldr r1, =0xC400
    bl  v8_ch1_wait
    strh r3, [r8, #(8 + (\d / 4000) * 2)]
    .endr

    mov r0, #0
    strh r0, [r4, #0x84]
    pp_init
    ldr r0, =0xF0BE                @ length 62
    ldr r1, =0xC400
    bl  v8_ch1_wait
    strh r3, [r8, #16]

    mov r0, #0
    strh r0, [r4, #0x84]
    pp_init
    ldr r0, =0xF0BC                @ length 60
    ldr r1, =0xC400
    bl  v8_ch1_wait
    strh r3, [r8, #18]

    @ ch1 and ch2 triggered back to back, both length 63, polled together
    mov r0, #0
    strh r0, [r4, #0x84]
    pp_init
    ldr r0, =0xF0BF
    strh r0, [r4, #0x62]           @ ch1 NR11/NR12
    strh r0, [r4, #0x68]           @ ch2 NR21/NR22
    ldr r1, =0xC400
    strh r1, [r4, #0x64]           @ ch1 trigger
    strh r1, [r4, #0x6C]           @ ch2 trigger
    ldr r2, =0x00060000
    mov r3, #0                     @ iterations while ch1 was still active
    mov r5, #0                     @ iterations until ch2 dropped
1:  ldrh r0, [r4, #0x84]
    tst r0, #1
    addne r3, r3, #1
    tst r0, #2
    beq 2f
    add r5, r5, #1
    subs r2, r2, #1
    bne 1b
    add r9, r9, #1
2:  strh r3, [r8, #20]
    sub r0, r5, r3
    strh r0, [r8, #26]

    @ retrigger while the tone is still running
    mov r0, #0
    strh r0, [r4, #0x84]
    pp_init
    ldr r0, =0xF0BF
    strh r0, [r4, #0x62]
    ldr r1, =0xC400
    strh r1, [r4, #0x64]
    mov r0, #200
3:  subs r0, r0, #1
    bne 3b
    ldr r0, =0xF0BF
    ldr r1, =0xC400
    bl  v8_ch1_wait
    strh r3, [r8, #22]

    @ two master toggles in a row
    mov r0, #0
    strh r0, [r4, #0x84]
    mov r0, #0x80
    strh r0, [r4, #0x84]
    mov r0, #0
    strh r0, [r4, #0x84]
    pp_init
    ldr r0, =0xF0BF
    ldr r1, =0xC400
    bl  v8_ch1_wait
    strh r3, [r8, #28]

    mov r0, #0
    strh r0, [r4, #0x84]           @ leave the APU off, as PSGSTAT does
    mov r0, #0x50
    strb r0, [r8, #30]
    strb r9, [r8, #31]
    pop {r4-r11, pc}
    .ltorg

@ r4 = IOBASE, r0 = NR11/NR12 word, r1 = NR14 word -> r3 = poll iterations,
@ r6 = SOUNDCNT_X right after the trigger, r7 = SOUNDCNT_X after the drop;
@ r9 += 1 when the cap is hit.
v8_ch1_wait:
    strh r0, [r4, #0x62]
    strh r1, [r4, #0x64]
    ldrh r6, [r4, #0x84]
    ldr r2, =0x00060000
    mov r3, #0
1:  ldrh r0, [r4, #0x84]
    tst r0, #1
    beq 2f
    add r3, r3, #1
    subs r2, r2, #1
    bne 1b
    add r9, r9, #1
2:  ldrh r7, [r4, #0x84]
    bx  lr
    .ltorg

@ ── slot 45: MEMCTL — 0x04000800, the internal memory control ────────────
@ IDENT read 0D000020 on hardware; mmio.nim keeps the value for readback and
@ implements none of its effects.  Only the documented WS field (bits 24-27)
@ is written here, and only through a read-modify-write, so bit 0 (disable
@ WRAM) and bit 4 (enable the 256K WRAM) keep whatever the console booted
@ with.  WS = 14 is one wait, the well-known EWRAM overclock; WS = 4 is slow
@ but legal; WS = 15 locks the console up and is never written.
@ Each timing row is 16 back-to-back `ldr` from EWRAM, TM0/TM1-bracketed,
@ with the loop itself fetched from ROM, so only the data side moves.
@ +0  (w) 0x04000800 read at probe time
@ +4  (w) the same register through its +64K mirror at 0x04010800
@ +8  (w) and through 0x04FF0800
@ +12 (h) halfword read at 0x04000800   +14 (h) halfword at 0x04000802
@ +16..+19 (4 b) byte reads at 0x04000800..803 (GBATEK warns that 8- and
@   16-bit accesses to this register may not work: these four say whether)
@ +20 (h) 16 EWRAM word reads at the boot WS   +22 (h) the same at WS = 14
@ +24 (h) the same at WS = 4
@ +26 (b) the register's top byte read back after writing WS = 14
@ +27 (b) after writing WS = 4      +28 (b) after writing the boot value
@ +29 (b) the top byte at 0x04000800 after the boot value went in through
@   the 0x04010800 mirror (0D = the mirror really is the register)
@ +30 (b) progress marker: 01 before the first non-default write, FF at the
@   end   +31 (b) the register's low byte at the end (20 = restored)
.macro mc_time off
    bl  tm_start
    ldr r2, =V8DST
    .rept 16
    ldr r3, [r2]
    .endr
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
probe_memctl:
    push {r4-r9, lr}
    ldr r8, =SLOTS + 45*SLOTSZ
    ldr r5, =0x04000800
    ldr r6, [r5]                   @ the value to restore
    str r6, [r8, #0]
    ldr r1, =0x04010800
    ldr r0, [r1]
    str r0, [r8, #4]
    ldr r1, =0x04FF0800
    ldr r0, [r1]
    str r0, [r8, #8]
    ldrh r0, [r5]
    strh r0, [r8, #12]
    ldrh r0, [r5, #2]
    strh r0, [r8, #14]
    ldrb r0, [r5]
    strb r0, [r8, #16]
    ldrb r0, [r5, #1]
    strb r0, [r8, #17]
    ldrb r0, [r5, #2]
    strb r0, [r8, #18]
    ldrb r0, [r5, #3]
    strb r0, [r8, #19]

    str r6, [r5]                   @ the boot value, written back explicitly
    mc_time 20
    mov r0, #1
    strb r0, [r8, #30]             @ marker: the field writes start here
    bic r0, r6, #0x0F000000        @ WS := 14 (one wait; 15 would lock up)
    orr r0, r0, #0x0E000000
    str r0, [r5]
    mc_time 22
    ldr r0, [r5]
    mov r0, r0, lsr #24
    strb r0, [r8, #26]
    bic r0, r6, #0x0F000000        @ WS := 4 (slow, legal)
    orr r0, r0, #0x04000000
    str r0, [r5]
    mc_time 24
    ldr r0, [r5]
    mov r0, r0, lsr #24
    strb r0, [r8, #27]
    str r6, [r5]                   @ restore
    ldr r0, [r5]
    mov r0, r0, lsr #24
    strb r0, [r8, #28]
    ldr r1, =0x04010800            @ the same value, through the mirror
    str r6, [r1]
    ldr r0, [r5]
    mov r0, r0, lsr #24
    strb r0, [r8, #29]
    str r6, [r5]
    mov r0, #0xFF
    strb r0, [r8, #30]
    ldrb r0, [r5]
    strb r0, [r8, #31]
    pop {r4-r9, pc}
    .ltorg

@ ── slot 46: DMATIME — start delay, per-region cost, trigger instant ─────
@ +0  (h) TM0 read by the instruction right after the store that enables a
@   1-word immediate DMA0 (EWRAM -> EWRAM), counted from tm_start
@ +2  (h) the identical instruction stream with the enable bit CLEAR: the
@   baseline, so (+0 - +2) is the stall the enable cost the CPU
@ +4  (h) the same for 4 words     +6  (h) the same for 16 words
@ +8..+18 (6 h) tm_start/tm_stop around a 16-word DMA3 with source and
@   destination both in EWRAM (+8), IWRAM (+10), VRAM (+12), palette (+14),
@   OAM (+16), and ROM -> EWRAM (+18)
@ +20 (b) DISPSTAT low byte at the moment an hblank-started DMA's word was
@   first seen in memory      +21 (b) VCOUNT at that moment
@ +22/+23 (b,b) the same pair for a vblank-started DMA
@ +24 (h) TM0 cycles from the polled rise of the hblank flag to that word
@   appearing   +26 (h) the same for the vblank flag.  A DMA that fires on
@   the DISPSTAT edge itself reads near zero plus the poll granularity; one
@   that waits for the renderer reads longer.
@ +28 (h) (the handler's TM0 entry stamp) - (the TM0 stamp taken by the
@   instruction after the enabling store) for a 16-word DMA3 with IRQ:
@   positive means the CPU resumed first and the interrupt landed later
@ +30 (b) 1 if the LAST destination word was already in memory when the
@   instruction after the enabling store read it, else 0
@ +31 (b) marker 44
.macro dt_burst src, dst, off
    ldr r0, =\src
    str r0, [r6]
    ldr r0, =\dst
    str r0, [r6, #4]
    bl  tm_start
    ldr r1, =0x84000010            @ enable, 32-bit, count 16
    str r1, [r6, #8]
    bl  tm_stop
    strh r0, [r8, #\off]
.endm
.macro dt_start cnt, off
    ldr r0, =V8SRC
    str r0, [r5]
    ldr r0, =V8DST
    str r0, [r5, #4]
    bl  tm_start
    ldr r1, =\cnt
    str r1, [r5, #8]
    ldrh r9, [r10]                 @ TM0 the instant the CPU came back
    bl  tm_stop
    strh r9, [r8, #\off]
.endm
probe_dmatime:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 46*SLOTSZ
    ldr r7, =SCRATCH
    mov r4, #IOBASE
    ldr r10, =TM0BASE
    ldr r5, =0x040000B0            @ DMA0
    ldr r6, =0x040000D4            @ DMA3
    ldr r0, =V8SRC
    ldr r1, =0xC0FFEE46
    mov r2, #64
    bl  fill_words

    dt_start 0x84000001, 0
    dt_start 0x04000001, 2         @ the same stream, enable bit clear
    dt_start 0x84000004, 4
    dt_start 0x84000010, 6

    dt_burst V8SRC,      V8DST,      8
    dt_burst 0x03001000, 0x03001100, 10
    dt_burst 0x06010000, 0x06010100, 12
    dt_burst 0x05000000, 0x05000100, 14
    dt_burst 0x07000000, 0x07000100, 16
    dt_burst rom_pattern, V8DST,     18

    @ hblank-started DMA into a watched cell
    ldr r11, =V8DST + 0x400
    mov r0, #0
    str r0, [r11]
    ldr r0, =V8SRC
    str r0, [r6]
    str r11, [r6, #4]
1:  ldrh r0, [r4, #4]              @ park at a line start first
    tst r0, #2
    beq 1b
2:  ldrh r0, [r4, #4]
    tst r0, #2
    bne 2b
    ldr r0, =0xA4000001            @ enable, hblank timing, word, count 1
    str r0, [r6, #8]
    bl  tm_start
3:  ldrh r0, [r4, #4]              @ the hblank flag's rise
    tst r0, #2
    beq 3b
    ldrh r9, [r10]                 @ stamp the rise
4:  ldr r0, [r11]                  @ ... and the word landing
    cmp r0, #0
    beq 4b
    ldrh r1, [r10]
    sub r1, r1, r9
    ldrh r2, [r4, #4]
    strb r2, [r8, #20]
    ldrh r2, [r4, #6]
    strb r2, [r8, #21]
    strh r1, [r8, #24]
    bl  tm_stop

    @ vblank-started DMA
    mov r0, #0
    str r0, [r11]
    ldr r0, =V8SRC
    str r0, [r6]
    str r11, [r6, #4]
1:  ldrh r0, [r4, #6]              @ park well before line 160
    cmp r0, #100
    bne 1b
    ldr r0, =0x94000001            @ enable, vblank timing, word, count 1
    str r0, [r6, #8]
    bl  tm_start
2:  ldrh r0, [r4, #4]              @ the vblank flag's rise
    tst r0, #1
    beq 2b
    ldrh r9, [r10]
3:  ldr r0, [r11]
    cmp r0, #0
    beq 3b
    ldrh r1, [r10]
    sub r1, r1, r9
    ldrh r2, [r4, #4]
    strb r2, [r8, #22]
    ldrh r2, [r4, #6]
    strb r2, [r8, #23]
    strh r1, [r8, #26]
    bl  tm_stop

    @ the completion interrupt against the CPU's own resume
    ldr r0, =V8DST
    mov r1, #0
    mov r2, #16
    bl  fill_words
    mov r0, #0
    str r0, [r7, #0x4C]
    ldr r0, =IEADDR
    mov r1, #0x0800                @ IE: DMA3
    strh r1, [r0]
    ldr r1, =0x3FFF
    strh r1, [r0, #2]
    mov r1, #1
    strh r1, [r0, #8]              @ IME on
    ldr r0, =V8SRC
    str r0, [r6]
    ldr r0, =V8DST
    str r0, [r6, #4]
    ldr r12, =V8DST + 60           @ the burst's LAST destination word
    bl  tm_start
    ldr r1, =0xC4000010            @ enable + IRQ, word, count 16
    str r1, [r6, #8]
    ldrh r9, [r10]                 @ the CPU's own resume stamp
    ldr r11, [r12]                 @ ... and what is in memory by then
    ldr r6, =0x00080000
5:  ldr r0, [r7, #0x4C]
    cmp r0, #0
    bne 6f
    subs r6, r6, #1
    bne 5b
6:  ldrh r0, [r7, #0x48]
    sub r0, r0, r9
    strh r0, [r8, #28]
    ldr r3, =0xC0FFEE46
    cmp r11, r3
    moveq r0, #1
    movne r0, #0
    strb r0, [r8, #30]
    bl  tm_stop
    ldr r0, =IEADDR
    mov r1, #0
    strh r1, [r0, #8]
    strh r1, [r0]
    mov r0, #0x44
    strb r0, [r8, #31]
    pop {r4-r11, pc}
    .ltorg

@ ── slot 47: IWCYCLE — IntrWait's return path and the 03007FF8 protocol ──
@ hle_bios.nim rebuilds the BIOS IntrWait by hand, down to a hard-coded
@ 44-cycle wake path (INTRWAIT_TUNE) and a reconstructed register protocol.
@ This page runs the same calls against the real BIOS.  It installs its own
@ IRQ handler — the shared one never touches the BIOS flag mirror, and
@ IntrWait cannot return without a handler that does — and puts the shared
@ one back at the end.  Every wait is masked with the timer-3 watchdog bit
@ as well as the source under test, so a wait that would hang returns
@ anyway and +12 names the source that ended it (0001 = vblank, 0040 = the
@ watchdog rescued the row).
@ +0  (h) TM0 cycles for `swi 4` with r0 = 0, r1 = 0001 and the mirror
@   pre-set to 0001: the pure return path, with no halt at all
@ +2  (h) the mirror right after that call: which bits the BIOS cleared
@ +4  (h) r0 it returned      +6  (h) r3 it returned
@ +8  (h) the mirror after the same call with the mirror pre-set to FFFF:
@   does the BIOS clear only the bits it matched?
@ +10 (h) cycles for `swi 4` r0 = 1 (discard), r1 = 0041, entered two lines
@   before vblank      +12 (h) r0 it returned
@ +14 (h) cycles for `swi 5` (VBlankIntrWait) from the same anchor, run only
@   if +12 showed the vblank path working     +16 (h) the mirror after it
@ +18 (h) (the TM0 stamp taken by the instruction after the +10 call
@   returned) - (the handler's own entry stamp): the return path measured
@   from inside the interrupt, which is what INTRWAIT_TUNE models
@ +20 (h) the same for the `swi 5` at +14
@ +22 (h) low half of (sp after - sp before) across the +10 call (0 = the
@   BIOS popped both of its frames)
@ +24 (h) low half of r12 after that call (pre-set to 1234: the BIOS is
@   documented to hand the caller's r12 back)
@ +26 (h) low half of r2 after it (documented residue)
@ +28 (h) cycles for `swi 4` r0 = 0, r1 = 0041, mirror pre-set to 0, same
@   anchor: it must halt, so (+28 - +10) isolates the discard path
@ +30 (b) IME read back after the immediate-return call at +0
@ +31 (b) progress marker; 49 once the page finished
.macro iw_anchor
1:  ldrh r0, [r4, #6]
    cmp r0, #157
    bne 1b
2:  ldrh r0, [r4, #6]
    cmp r0, #158
    bne 2b
.endm
.macro iw_mirror v
    ldr r0, =0x03007FF8
    ldr r1, =\v
    strh r1, [r0]
.endm
.macro iw_wd on
    ldr r0, =TM3BASE
    mov r1, #0
    str r1, [r0]
.if \on
    ldr r1, =0x00C00000            @ enable + IRQ, prescaler 1, reload 0
    str r1, [r0]
.endif
.endm
probe_iwcycle:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 47*SLOTSZ
    ldr r7, =SCRATCH
    mov r4, #IOBASE
    ldr r10, =TM0BASE
    mov r0, #1
    strb r0, [r8, #31]
    ldr r0, =0x03007FFC            @ our own handler, restored at the end
    ldr r1, =v8_iw_handler
    str r1, [r0]
    ldrh r0, [r4, #4]
    orr r0, r0, #0x08              @ DISPSTAT: vblank IRQ enable
    strh r0, [r4, #4]
    iw_wd 0
    ldr r0, =IEADDR
    ldr r1, =0x0041                @ IE: vblank + timer 3
    strh r1, [r0]
    ldr r1, =0x3FFF
    strh r1, [r0, #2]
    mov r1, #1
    strh r1, [r0, #8]              @ IME on

    @ ── the immediate return: the flag is already in the mirror ──
    mov r0, #2
    strb r0, [r8, #31]
    iw_mirror 0x0001
    bl  tm_start
    mov r0, #0
    mov r1, #1
    swi 0x040000
    mov r5, r0
    mov r6, r3
    bl  tm_stop
    strh r0, [r8, #0]
    ldr r0, =0x03007FF8
    ldrh r0, [r0]
    strh r0, [r8, #2]
    strh r5, [r8, #4]
    strh r6, [r8, #6]
    ldr r0, =IEADDR
    ldrh r0, [r0, #8]
    strb r0, [r8, #30]
    iw_mirror 0xFFFF
    mov r0, #0
    mov r1, #1
    swi 0x040000
    ldr r0, =0x03007FF8
    ldrh r0, [r0]
    strh r0, [r8, #8]

    @ ── a real wait: discard, masking vblank and the watchdog ──
    mov r0, #3
    strb r0, [r8, #31]
    iw_anchor                      @ (vblank IRQs fire during the anchor, so
    iw_mirror 0                    @  the mirror is cleared AFTER it)
    mov r0, #0
    str r0, [r7, #0x4C]
    iw_wd 1
    mov r9, sp
    ldr r12, =0x1234
    bl  tm_start
    mov r0, #1
    ldr r1, =0x0041
    swi 0x040000
    ldrh r11, [r10]                @ stamp the return
    mov r5, r0
    mov r6, r2
    strh r12, [r8, #24]
    sub r9, sp, r9
    bl  tm_stop
    strh r0, [r8, #10]
    strh r5, [r8, #12]
    strh r9, [r8, #22]
    strh r6, [r8, #26]
    ldrh r0, [r7, #0x48]           @ the handler's entry stamp
    sub r0, r11, r0
    strh r0, [r8, #18]
    iw_wd 0

    @ ── VBlankIntrWait, only once the vblank path proved itself ──
    cmp r5, #1
    bne 9f
    mov r0, #4
    strb r0, [r8, #31]
    iw_anchor
    iw_mirror 0
    mov r0, #0
    str r0, [r7, #0x4C]
    bl  tm_start
    swi 0x050000
    ldrh r11, [r10]
    bl  tm_stop
    strh r0, [r8, #14]
    ldr r0, =0x03007FF8
    ldrh r0, [r0]
    strh r0, [r8, #16]
    ldrh r0, [r7, #0x48]
    sub r0, r11, r0
    strh r0, [r8, #20]
9:
    @ ── the same wait without the discard ──
    mov r0, #5
    strb r0, [r8, #31]
    iw_anchor
    iw_mirror 0
    iw_wd 1
    bl  tm_start
    mov r0, #0
    ldr r1, =0x0041
    swi 0x040000
    bl  tm_stop
    strh r0, [r8, #28]
    iw_wd 0

    ldr r0, =IEADDR
    mov r1, #0
    strh r1, [r0, #8]
    strh r1, [r0]
    ldrh r0, [r4, #4]
    bic r0, r0, #0x08
    strh r0, [r4, #4]
    ldr r0, =0x03007FFC            @ hand the shared handler back
    ldr r1, =irq_handler
    str r1, [r0]
    mov r0, #0x49
    strb r0, [r8, #31]
    pop {r4-r11, pc}
    .ltorg

@ What IntrWait needs from a user handler: stamp the first entry,
@ acknowledge IF, and OR the serviced bits into the BIOS flag mirror at
@ 0x03007FF8 (devkitARM's crt0 does the same with `strh r0, [ip, #-8]`).
@ Entered from the BIOS dispatcher, which has already saved r0-r3, r12, lr.
v8_iw_handler:
    ldr r0, =TM0BASE
    ldrh r1, [r0]
    ldr r0, =SCRATCH
    ldr r2, [r0, #0x4C]
    cmp r2, #0
    streqh r1, [r0, #0x48]
    moveq r2, #1
    streq r2, [r0, #0x4C]
    ldr r0, =IEADDR
    ldrh r1, [r0, #2]              @ IF
    strh r1, [r0, #2]              @ acknowledge
    ldr r0, =0x03007FF8
    ldrh r2, [r0]
    orr r2, r2, r1
    strh r2, [r0]
    bx  lr
    .ltorg

@ ── slot 48: DMAFIFO — is a FIFO request level-conditioned or latched? ───
@ dma.nim's run_pending drops a FIFO grant whose FIFO already holds 16 bytes
@ ("FIFO requests are level-conditioned on the FIFO, not edge-latched ...
@ Assumed; no ROM pins this") — a rule that came out of Densetsu no Sutafi 3
@ losing stream bytes, not out of hardware.  A FIFO destination cannot be
@ read back and DMA1SAD is write-only, so the observable here is the bus:
@ every row times the SAME 256-iteration ROM loop with the TM2/TM3 cascade
@ while DMA1 feeds FIFO A from EWRAM, and the cycles the loop lost are the
@ transfers that happened.  Timer 0 drives the FIFO, and its reload sets how
@ many overflows fall inside one 4-word burst — a burst is ~16-20 cycles, so
@ reload FFF8 (8 cycles an overflow) already puts two inside it and FFFC
@ four.  If a grant is edge-latched, those extra overflows queue extra
@ bursts and the loop loses far more cycles than the level-conditioned model
@ allows; if it is level-conditioned, the rows saturate.
@ +0  (h) loop cycles, TM0 reload FC00 (1024 cycles an overflow)
@ +2  (h) reload FF00 (256)     +4  (h) reload FFC0 (64)
@ +6  (h) reload FFF0 (16)      +8  (h) reload FFF8 (two per burst)
@ +10 (h) reload FFFC (four per burst)
@ +12 (h) the same loop with DMA1 disabled and TM0 still at reload FFFC:
@   the timer's own cost, to be subtracted from +10
@ +14 (h) the loop with DMA1 disabled and TM0 stopped: the bare loop
@ +16 (h) loop cycles for a single-shot (repeat off) DMA1 at reload FFFC —
@   one burst, unless a second grant was latched behind it
@ +18 (h) DMA1CNT_H read back after that row (8000 set = still enabled)
@ +20 (h) DMA1-complete interrupts counted over one loop at reload FFC0
@ +22 (h) the same at reload FC00.  These two are deliberately SLOW: one
@   interrupt per burst at reload FFF8 arrives every ~128 cycles, which is
@   less than a ROM handler plus the BIOS dispatcher costs, and the console
@   makes no forward progress at all.  They calibrate interrupts-per-burst
@   at a rate the CPU survives; the fast rows above are read off the bus.
@ +24 (h) loop cycles for the same experiment on DMA2 / FIFO B driven by
@   timer 1 at reload FFF8
@ +26 (h) SOUNDCNT_H read back: the configuration these rows ran under
@ +28 (h) loop cycles at reload FFF8 with the DMA source in ROM instead of
@   EWRAM — a different cost per word, so +8 and +28 together give the
@   cycles-per-transfer scale the counts are read off
@ +30 (b) marker 46   +31 (b) OR of every IF bit the counting handler saw
.equ DF_SOUNDH,   0x0306           @ PSG 100 %, DSA 100 %, DSA L+R, timer 0
.equ DF_SOUNDH_B, 0x7306           @ + DSB L+R, DSB timer 1
.equ DF_CNT,      0xB6400004       @ enable, special timing, 32-bit, repeat,
                                   @ destination fixed, count 4
.equ DF_CNT_IRQ,  0xF6400004       @ ... + IRQ on completion
.equ DF_CNT_ONCE, 0xB4400004       @ ... without repeat
.macro df_loop                     @ -> r0 = cycles
    bl  v8_tm23_start
    mov r3, #256
1:  subs r3, r3, #1
    bne 1b
    bl  v8_tm23_stop
.endm
.macro df_row src, reload, cnt     @ -> r0 = cycles
    ldr r0, =\src                  @ DMA1: SAD, DAD, CNT
    str r0, [r5]
    ldr r0, =0x040000A0            @ FIFO A
    str r0, [r5, #4]
    mov r0, #0
    str r0, [r6]                   @ TM0 off
    ldr r0, =\cnt
    str r0, [r5, #8]
    ldr r0, =0x00800000 + \reload
    str r0, [r6]                   @ TM0 on, prescaler 1
    df_loop
    mov r11, r0
    mov r0, #0
    str r0, [r5, #8]               @ DMA1 off
    str r0, [r6]                   @ TM0 off
    mov r0, r11
.endm
probe_dmafifo:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 48*SLOTSZ
    mov r4, #IOBASE
    ldr r5, =0x040000BC            @ DMA1 SAD
    ldr r6, =TM0BASE
    ldr r0, =V8SRC
    ldr r1, =0x10203040
    mov r2, #2048
    bl  fill_words
    mov r0, #0x80
    strh r0, [r4, #0x84]           @ SOUNDCNT_X: master on
    ldr r0, =DF_SOUNDH | 0x8800    @ ... resetting both FIFOs once
    strh r0, [r4, #0x82]
    ldr r0, =DF_SOUNDH
    strh r0, [r4, #0x82]

    df_row V8SRC, 0xFC00, DF_CNT
    strh r0, [r8, #0]
    df_row V8SRC, 0xFF00, DF_CNT
    strh r0, [r8, #2]
    df_row V8SRC, 0xFFC0, DF_CNT
    strh r0, [r8, #4]
    df_row V8SRC, 0xFFF0, DF_CNT
    strh r0, [r8, #6]
    df_row V8SRC, 0xFFF8, DF_CNT
    strh r0, [r8, #8]
    df_row V8SRC, 0xFFFC, DF_CNT
    strh r0, [r8, #10]

    mov r0, #0                     @ DMA1 off, the timer still hammering
    str r0, [r5, #8]
    ldr r0, =0x0080FFFC
    str r0, [r6]
    df_loop
    strh r0, [r8, #12]
    mov r0, #0
    str r0, [r6]
    df_loop                        @ ... and the bare loop
    strh r0, [r8, #14]

    df_row V8SRC, 0xFFFC, DF_CNT_ONCE
    strh r0, [r8, #16]
    ldrh r0, [r5, #10]             @ DMA1CNT_H
    strh r0, [r8, #18]

    @ ── the same rows counted as completion interrupts ──
    ldr r0, =0x03007FFC
    ldr r1, =v8_cnt_handler
    str r1, [r0]
    ldr r7, =V8SCR
    ldr r0, =IEADDR
    mov r1, #0x0200                @ IE: DMA1
    strh r1, [r0]
    ldr r1, =0x3FFF
    strh r1, [r0, #2]
    mov r1, #1
    strh r1, [r0, #8]              @ IME on
    mov r0, #0
    str r0, [r7]
    df_row V8SRC, 0xFFC0, DF_CNT_IRQ
    ldr r0, [r7]
    strh r0, [r8, #20]
    mov r0, #0
    str r0, [r7]
    df_row V8SRC, 0xFC00, DF_CNT_IRQ
    ldr r0, [r7]
    strh r0, [r8, #22]
    ldr r0, =IEADDR
    mov r1, #0
    strh r1, [r0, #8]
    strh r1, [r0]
    ldr r0, =0x03007FFC
    ldr r1, =irq_handler
    str r1, [r0]

    @ ── FIFO B on DMA2, driven by timer 1 ──
    ldr r0, =DF_SOUNDH_B
    strh r0, [r4, #0x82]
    ldr r0, =V8SRC
    ldr r1, =0x040000C8            @ DMA2 SAD
    str r0, [r1]
    ldr r0, =0x040000A4            @ FIFO B
    str r0, [r1, #4]
    mov r0, #0
    str r0, [r6, #4]               @ TM1 off
    ldr r0, =DF_CNT
    str r0, [r1, #8]
    ldr r0, =0x0080FFF8
    str r0, [r6, #4]               @ TM1 on
    df_loop
    strh r0, [r8, #24]
    mov r0, #0
    ldr r1, =0x040000C8
    str r0, [r1, #8]
    str r0, [r6, #4]
    ldrh r0, [r4, #0x82]
    strh r0, [r8, #26]

    @ ── the cycles-per-transfer scale: the same row from a ROM source ──
    df_row rom_pattern, 0xFFF8, DF_CNT
    strh r0, [r8, #28]

    mov r0, #0
    strh r0, [r4, #0x82]
    strh r0, [r4, #0x84]           @ the APU off again
    ldr r7, =V8SCR
    ldr r0, [r7, #4]
    strb r0, [r8, #31]
    mov r0, #0x46
    strb r0, [r8, #30]
    pop {r4-r11, pc}
    .ltorg

@ Counts entries, and remembers every IF bit it ever saw.
v8_cnt_handler:
    ldr r0, =IEADDR
    ldrh r1, [r0, #2]
    strh r1, [r0, #2]
    ldr r0, =V8SCR
    ldr r2, [r0]
    add r2, r2, #1
    str r2, [r0]
    ldr r2, [r0, #4]
    orr r2, r2, r1
    str r2, [r0, #4]
    bx  lr
    .ltorg

@ ── slot 49: UNDMODE — which bank an undefined CPSR mode selects ─────────
@ cpu.nim's mode_bank sends every pattern that is not one of the seven ARM
@ modes to the user bank ("Assumed; no ROM pins this"), and its comment
@ names the game that gets there: Prince of Tennis 2004 returns with SPSR
@ mode 1E.  Each banked r13 is loaded with a constant that names its bank,
@ then CPSR_c is written with an undefined mode number and r13 read straight
@ back, so the value IS the answer:
@   51515151 user/system   52525252 FIQ   53535353 abort   54545454 undefined
@   03007Fxx = one of the BIOS's own stacks (IRQ or supervisor)
@ Interrupts stay unmasked across the mode change, with TM3 armed as a
@ watchdog through the same MARKER protocol run_msr_probe uses, so an
@ interrupt can divert execution to und_recover if a pattern wedges the
@ pipeline; the progress byte at +28 is written before each mode write.
@ HOLD SELECT AT POWER-ON TO SKIP THIS PAGE — a console that dies here shows
@ nothing at all, and the other 49 pages are worth more than this one.
@ +0  (w) r13 read in mode 15   +4 (b) CPSR low byte there  +5 (b) r14 low
@ +8  (w) r13 read in mode 1A   +12 (b) CPSR low byte  +13 (b) r14 low byte
@ +16 (w) r13 read in mode 1E   +20 (b) CPSR low byte  +21 (b) r14 low byte
@ +24 (w) r13 read back in system mode afterwards (51515151 = the round trip
@   left the system bank alone)
@ +28 (b) progress marker: the last step started
@ +29 (b) the in-flight word as the recovery found it: 1 = the page
@   walked out on its own, 2 = the watchdog had to divert it
@ +30 (b) AA once the page ran to the end
@ +31 (b) EE, with 99 at +0, means SELECT was held and nothing ran
.macro un_probe mode, off, step
    mov r0, #\step
    strb r0, [r8, #28]
    msr CPSR_c, #\mode             @ undefined pattern, interrupts unmasked
    mov r6, sp                     @ r13 of whatever bank that selected
    mov r7, lr                     @ r14 of the same bank
    mrs r3, CPSR
    msr CPSR_c, #0xDF              @ system mode, interrupts masked again
    str r6, [r8, #\off]
    strb r3, [r8, #(\off + 4)]
    strb r7, [r8, #(\off + 5)]
.endm
probe_undmode:
    push {r4-r11, lr}
    ldr r8, =SLOTS + 49*SLOTSZ
    ldr r0, =0x04000130
    ldrh r0, [r0]
    tst r0, #4                     @ SELECT held (0 = pressed): skip
    bne 1f
    mov r0, #0x99
    strb r0, [r8, #0]
    mov r0, #0xEE
    strb r0, [r8, #31]
    pop {r4-r11, pc}
1:  mrs r4, CPSR                   @ the CPSR to put back
    mov r5, sp                     @ the real system stack pointer
    ldr r9, =MARKER
    str r5, [r9, #12]
    ldr r0, =und_recover
    str r0, [r9, #20]              @ where the watchdog should divert to
    mov r0, #1
    str r0, [r9, #8]               @ in-flight flag the watchdog looks at
    ldr r0, =TM3BASE
    mov r1, #0
    str r1, [r0]
    ldr r1, =0x00C00000            @ enable + IRQ, prescaler 1, reload 0
    str r1, [r0]
    ldr r0, =IEADDR
    mov r1, #0x40                  @ IE: timer 3
    strh r1, [r0]
    ldr r1, =0x3FFF
    strh r1, [r0, #2]
    mov r1, #1
    strh r1, [r0, #8]              @ IME on

    ldr r0, =0x52525252            @ name every bank before reading any
    msr CPSR_c, #0xD1              @ FIQ (which banks r8-r12: touch none)
    mov sp, r0
    msr CPSR_c, #0xDF
    ldr r0, =0x53535353
    msr CPSR_c, #0xD7              @ abort
    mov sp, r0
    msr CPSR_c, #0xDF
    ldr r0, =0x54545454
    msr CPSR_c, #0xDB              @ undefined
    mov sp, r0
    msr CPSR_c, #0xDF
    ldr r0, =0x51515151            @ system: r5 puts the real one back
    mov sp, r0

    un_probe 0x15, 0, 1
    un_probe 0x1A, 8, 2
    un_probe 0x1E, 16, 3
    mov r0, #4
    strb r0, [r8, #28]
    mov r6, sp
    str r6, [r8, #24]
und_recover:
    ldr r9, =MARKER
    ldr r0, [r9, #8]
    strb r0, [r8, #29]
    mov r0, #0
    str r0, [r9, #8]
    ldr r0, =IEADDR
    mov r1, #0
    strh r1, [r0, #8]
    strh r1, [r0]
    ldr r0, =TM3BASE
    str r1, [r0]
    ldr sp, [r9, #12]              @ the real system stack pointer
    msr CPSR_c, r4
    mov r0, #0xAA
    strb r0, [r8, #30]
    pop {r4-r11, pc}
    .ltorg
