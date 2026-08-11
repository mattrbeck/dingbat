@ irqwin.s — WHAT: when a pending IRQ is unblocked by a store to IME or
@ IE, or by an `msr` clearing CPSR.I, how many more instructions execute
@ before the dispatch?  Emulators model this window with guessed
@ constants.
@
@ HOW: a TM2 overflow is parked in IF (iw_prime: run the timer once,
@ poll until IF shows the bit, timer off — the bit stays).  Then one
@ gate at a time is opened with an 8-instruction breadcrumb sled of
@ 1-cycle `add`s right behind the opening store; the shared IRQ handler
@ records the interrupted return address, i.e. HOW FAR the sled ran
@ before dispatch (iw_sled converts it to a byte offset).  Further IME
@ runs vary the sled composition: EWRAM loads, 4-I-cycle muls,
@ waitstated ROM loads, and a mixed nop/ROM-load sled — multi-cycle
@ instructions disambiguate instruction-counted from cycle-counted
@ sampling, and the mixed sled asks whether a cheap instruction at the
@ window edge still completes.  Finally, 16 back-to-back IF acks race
@ a TM2 that overflows every 16 cycles, counting how many acks saw the
@ flag still (or again) set.
@
@ WHY the expected values: hardware dispatches after THREE sled
@ instructions for the IME and IE stores (offset 000C) but after TWO
@ for the msr (0008); with the EWRAM-load sled after TWO loads (0008),
@ with the mul sled after TWO muls (0008), with the ROM-load sled
@ after TWO loads (0008), and with the mixed nop/ldr sled after THREE
@ instructions (000C) — one cycle-counted window predicts every sled's
@ count (ceil(W/cost)); an instruction-counted window would land all
@ six at the same offset.  The ack-race count was 8 of 16 on hardware;
@ it is a bus-phase-sensitive count, so the slot stores it as a word
@ at +12 and it is RANGE-checked (6..10) rather than exact-checked — a
@ false red on real hardware would be worse than a loose band.
@
@ PROVENANCE: verified on GBA SP AGS-001 (sessions 2-4, gbaedge pages
@ 20 IRQWIN, 26 IRQWIN2 and 32 IRQWIN3 — session 4's IRQWIN3 carried
@ the mul/ROM-load/mixed sleds and matched dingbat byte-perfect); see
@ docs/hwprobe-results-agb.md.
    .arm
    .text
    .global _start
_start:
    b   header_end
    .space 0x9C
    .space 0x20
header_end:
    b   main
rom_name:
    .ascii "IRQ WINDOW"
    .equ rom_name_len, . - rom_name
    .align 2
    .include "defs.inc"

probe:
    push {r4-r11, lr}
    ldr r8, =SLOT
    ldr r7, =SCRATCH
    ldr r4, =0x04000200            @ r4 -> IE/IF, r4+8 -> IME
    ldr r9, =rom_pattern           @ ROM-load sled source
    mov r10, #1                    @ mul sled operands
    ldr r11, =0x12345678
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
    @ ── experiment 3b: IME gate again, EWRAM-load sled ──
    iw_prime
    ldr r3, =EWDST
    mov r0, #1
    strh r0, [r4, #8]              @ IME on — dispatch races the sled
iw4:
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    ldr r0, [r3]
    iw_sled 8, iw4
    mov r0, #0
    strh r0, [r4, #8]              @ IME off
    @ ── experiment 3c: IME gate, mul sled (1S + 4I cycles each) ──
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]              @ IME on — dispatch races the sled
iw5:
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    mul r6, r10, r11
    iw_sled 16, iw5
    mov r0, #0
    strh r0, [r4, #8]              @ IME off
    @ ── experiment 3d: IME gate, waitstated ROM-load sled ──
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]              @ IME on — dispatch races the sled
iw6:
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    ldr r0, [r9]
    iw_sled 18, iw6
    mov r0, #0
    strh r0, [r4, #8]              @ IME off
    @ ── experiment 3e: IME gate, mixed nop/ROM-load sled ──
    iw_prime
    mov r0, #1
    strh r0, [r4, #8]              @ IME on — dispatch races the sled
iw7:
    nop
    ldr r0, [r9]
    nop
    ldr r0, [r9]
    nop
    ldr r0, [r9]
    nop
    ldr r0, [r9]
    iw_sled 20, iw7
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
    str r6, [r8, #12]
    mov r0, #0
    str r0, [r5]                   @ TM2 off
    mov r0, #0x20
    strh r0, [r4, #2]              @ ack the parked bit
    pop {r4-r11, pc}
    .ltorg
rom_pattern:
    .word 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00


@ hardware-verified expectations (see README: exact / range / info cells)
    .align 2
expected:
    .byte 0x0C,0x00,0x08,0x00,0x0C,0x00,0x00,0x00
    .byte 0x08,0x00,0x00,0x00,0x08,0x00,0x00,0x00
    .byte 0x08,0x00,0x08,0x00,0x0C,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
classes:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x02,0x02,0x02,0x02
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .align 2
ranges:
    .word 12, 6, 10
    .word 0xFFFFFFFF
    .include "runtime.inc"
