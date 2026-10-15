@ sramloop.s -- what does a byte stored to the cartridge's SRAM cost code
@ running from the cartridge's ROM with the prefetcher on?
@
@ WHAT: the seven-instruction Thumb copy loop Hamtaro - Rainbow Rescue
@ writes its save with (ldrb r0,[r5] from EWRAM; strb r0,[r4] to SRAM;
@ adds r5; adds r4; subs r3; cmp r3,r1; bne), entered from IWRAM with
@ r3 = n - 1, run from the gamepak, and timed with TM0 (prescaler 1) from
@ just before the `bx` into it to the first instruction after its own
@ `pop {r4, r5}; pop {r0}; bx r0` brings it home. Cells at two n give the
@ cost of one byte: (T(64) - T(16)) / 48.
@ WHY: dingbat lets the prefetcher read ROM through an SRAM access, so the
@ four ALU ops after the strb come out of a full buffer: 27.8 cycles a
@ byte in the game, where mGBA charges 31.0, and the game's quit save ends
@ a frame before both references (docs/playtest-bugs.md §84, "Hamtaro -
@ Rainbow Rescue"). SRAM is on the ROM's pins, so the access must hold the
@ bus. A rule that stops the prefetcher for it and keeps what it had
@ buffered (branch sram-holds-gamepak-bus) gives 29.0; one that also
@ empties the buffer, as a ROM data access does, about 31.8. The console's
@ figure says which, if either, and the EWRAM-destination control (bit 9)
@ says the loop's other costs are the ones slotexec.s measured.
@
@ RIG: Hamtaro - Rainbow Rescue (A84P) in the slot, the console booted
@ holding SELECT+START (GBATEK "Multiboot Slave with Cartridge"), the
@ monitor installed as usual. The loop executed is the cart's own, at
@ 0x081B79BA (checked byte for byte first). SRAM 0x7F00-0x7F3F is first
@ read into EWRAM and the loop writes those same bytes back, at the game's
@ own WAITCNT (0x4017: SRAM 8 waits, WS0 3/1); bit 10 reads it back. With
@ no such cart the payload looks for its own copy of the loop in the
@ gamepak (the emulators' payloadrun.s wrapper carries one, at the same
@ word phase) and, finding neither, answers DEAD0001 without writing.
@
@ r0 bits 0..7  n, the bytes copied (1..255)
@    bit  8     prefetcher off (WAITCNT 0x0017)
@    bit  9     control: the destination is EWRAM, not SRAM
@    bit  10    answer instead the bytes of SRAM that differ from the
@               buffer after the copy (0 = the save is as it was)
@ answer: TM0 cycles; DEAD0001 = no loop to run
@
@ PROVENANCE: dingbat, dingbat-bios, mgba (r0table.py sramloop ...
@ --emulators-only), in that section's table: a byte 28.0 (dingbat), 31.0
@ (mgba). Console: not yet run.
    .include "probe.inc"
    .arm
    .text
    .global _start

.equ SRAMBUF, 0x0E007F00
.equ EWBUF,   0x02030000
.equ EWDST,   0x02031000
.equ CARTLOOP, 0x081B79BA

_start:
    probe_enter
    ldrh r7, [r5, #4]
    str r7, [r12, #32]             @ WAITCNT, restored below

    @ the loop: the cart's own, or our copy in the wrapper's gamepak image
    ldr r6, =CARTLOOP
    ldr r0, =loop
    mov r1, #0
1:  ldrh r2, [r6, r1]
    ldrh r3, [r0, r1]
    cmp r2, r3
    bne 2f
    add r1, r1, #2
    cmp r1, #(loop_end - loop)
    blt 1b
    b found
2:  ldr r6, =0x08000000            @ search the first 64 KB for our marker
    ldr r2, =0x4C4D5253            @ 'SRML'
    ldr r3, =0x08010000
3:  ldr r1, [r6], #4
    cmp r1, r2
    beq 4f
    cmp r6, r3
    blt 3b
    ldr r0, =0xDEAD0001
    b out
4:  add r6, r6, #2                 @ the marker's halfword pad: loop at 2 mod 4
found:
    orr r6, r6, #1

    tst r9, #0x100
    ldreq r0, =0x4017
    ldrne r0, =0x0017
    strh r0, [r5, #4]              @ the cell's WAITCNT (SRAM 8 waits either way)

    and r7, r9, #0xFF
    cmp r7, #0
    moveq r7, #1                   @ n
    @ the bytes the loop will write: SRAM's own (left as found)
    ldr r2, =SRAMBUF
    ldr r3, =EWBUF
    mov r1, #0
5:  ldrb r0, [r2, r1]
    strb r0, [r3, r1]
    add r1, r1, #1
    cmp r1, r7
    blt 5b

    ldr r2, =ret
    sub sp, sp, #12                @ what the loop's pops take back:
    str r4, [sp]                   @ r4 and r5 (the kit's), then the way
    str r5, [sp, #4]               @ home, an ARM address
    str r2, [sp, #8]
    ldr r5, =EWBUF                 @ src
    tst r9, #0x200
    ldreq r4, =SRAMBUF             @ dst
    ldrne r4, =EWDST
    sub r3, r7, #1
    mvn r1, #0
    str r11, [r10]                 @ TM0 starts
    bx r6
    .align 2
ret:
    ldrh r0, [r10]                 @ T
    tst r9, #0x400
    beq out
    ldr r2, =SRAMBUF               @ integrity: SRAM against the buffer
    ldr r3, =EWBUF
    mov r1, #0
    mov r0, #0
6:  ldrb r6, [r2, r1]
    ldrb r8, [r3, r1]
    cmp r6, r8
    addne r0, r0, #1
    add r1, r1, #1
    cmp r1, r7
    blt 6b
    ldr r8, =0x040000B0            @ probe_leave's
out:
    ldr r1, [r12, #32]
    strh r1, [r5, #4]
    probe_leave

    @ The loop as the cart has it, and the two pops it returns through.
    @ In the emulators the wrapper copies this payload into its gamepak image
    @ too, so this copy runs from the gamepak there; the marker finds it.
    .align 2
    .word 0x4C4D5253
    .hword 0
    .thumb
loop:
    ldrb r0, [r5]
    strb r0, [r4]
    add r5, #1
    add r4, #1
    sub r3, #1
    cmp r3, r1
    bne loop
    pop {r4, r5}
    pop {r0}
    bx r0
loop_end:
    .arm
    .align 2
    probe_data
