@ flashprog.s -- how long does the cartridge's flash chip take to program a
@ byte, and to erase a sector?
@
@ WHAT: the chip's ID (ID mode, GBATEK "GBA Cart Backup Flash ROM"), then
@ one byte program or one 4 KB sector erase, timed with TM0 (prescaler 1)
@ cascaded into TM1, started just before the store that starts the chip
@ (the data byte after AA/55/A0, the 30h after AA/55/80/AA/55), polling the
@ byte from IWRAM until it reads back what was programmed (Data# polling:
@ while busy, bit 7 reads inverted) and answering the cycles from the timer
@ start to that read.
@ WHY: dingbat's flash has no busy state (storage/flash.nim): a program
@ lands at once and the first status read already returns the byte. Games
@ that write a sector a byte at a time and poll after each byte pace
@ themselves by it. Mario vs. Donkey Kong (FLASH512) writes its 4 KB save
@ sector when a level is cleared; at the playtest's level_clear dingbat
@ calls the game's status routine (copied to the stack, 0x03007E40) once a
@ byte and finishes the sector 503k cycles (1.8 frames) before mGBA, which
@ calls it ~1.95 times a byte, so the clear tally starts two frames apart
@ (docs/playtest-bugs.md, "Mario vs. Donkey Kong"). Advance Wars' first-boot
@ sector fill is the same question (section 35). GBATEK gives only the
@ timeouts for the Panasonic and Sanyo parts dingbat identifies as.
@
@ RIG: as eesettle.s -- boot holding SELECT+START with a FLASH cart in the
@ slot (a 64 KB one: Mario vs. Donkey Kong, Advance Wars), install the
@ monitor as usual. No cart header answers DEAD0001 without touching the
@ chip. Cells 0, 1 and 4 leave the save as it was (1 programs the last byte
@ with the value it already holds: no bit can change). Cells 2 and 3 touch
@ only sector 15 (0xF000-0xFFFF) and only when it is blank (all 0xFF, as an
@ unused sector is; else DEAD0002 without a write): 2 programs its last
@ byte 0xFF -> 0xFE and then erases the sector again; 3 erases the blank
@ sector. A power loss during them can only leave that unused sector
@ unerased. The console boots into the multiboot wait without running the
@ cart, so a 128 KB chip is on bank 0. An Atmel chip (manufacturer 1Fh)
@ programs 128-byte pages, not bytes: cells 1-3 answer DEAD0003 there.
@
@ r0 bits 0..3  n: 0  the ID: device << 8 | manufacturer (dingbat 1B32h,
@                     Panasonic; 1362h Sanyo, 1CC2h Macronix, D4BFh SST,
@                     3D1Fh Atmel), read in ID mode, then back to read mode
@                  1  program 0x0E00FFFF with its own value; cycles to the
@                     read that returns it
@                  2  sector 15 blank: program 0x0E00FFFF 0xFF -> 0xFE;
@                     cycles to the read of 0xFE; then erase the sector
@                     (not timed) and check it reads blank: bit 31 set if
@                     not
@                  3  sector 15 blank: erase it; cycles to the read of 0xFF
@                     at its first byte
@                  4  the poll alone, no command: the floor under 1-3
@    bit 8      run under WAITCNT 0 (SRAM region 4 waits): the setting
@               Mario vs. Donkey Kong writes its save under; else 8 waits
@    bit 9      the first poll ~100 cycles after the store that starts
@               the chip (a spin), as a game's poll comes late
@ answer: cycles (one per CPU cycle); FFFFFFFF = not done within the poll
@ limit (~1M polls, ~0.5 s); FFFFFFFE = DQ5 (time limit exceeded) read
@ while not done; DEAD0001 = no cartridge header; DEAD0002 = sector 15
@ not blank; DEAD0003 = an Atmel chip
@
@ PROVENANCE: a design, not yet run on the console. The emulators
@ (r0table.py flashprog ... --emulators-only, wrapper ROM with this file's
@ FLASH512 marker): the ID is 1B32 in dingbat and mgba, D4BF (SST) in the
@ second reference; cell 4 = 34 cycles (0x104: 30), and every program cell
@ is the floor plus the store in dingbat and the second reference (1, 2:
@ 51; 0x101, 0x102: 43; 0x201, 0x301: 147, 139) -- no busy state. mgba
@ answers so too until a sector erase has run in the session (cell 2's
@ restore, cell 3); from then on every program is busy ~640 cycles (1, 2:
@ 678; 0x101, 0x102: 673; 0x201, 0x301: 679), and its erase takes 30046
@ (3) / 30037 (0x103) against 45 / 37. The table's order runs the
@ non-erasing cells first.
@ On the console, a cell less cell 4 (or 0x104) is the chip's busy time:
@ what storage/flash.nim would model per chip ID.
    .include "probe.inc"
    .arm
    .text
    .global _start

.equ FLASH, 0x0E000000
.equ LAST,  0x0E00FFFF
.equ SECT,  0x0E00F000
.equ POLLS, 0x100000

@ the three-store command prefix: AA to 5555, 55 to 2AAA, \byte to 5555
    .macro fcmd byte
    mov r0, #0xAA
    strb r0, [r7]
    mov r0, #0x55
    strb r0, [r2]
    mov r0, #\byte
    strb r0, [r7]
    .endm

_start:
    probe_enter
    ldrh r0, [r5, #4]
    str r0, savedws                @ WAITCNT
    @ a Nintendo header: logo's first word and the fixed 0x96 at 0xB2
    mov r0, #0x08000000
    ldr r1, [r0, #4]
    ldr r2, =0x51AEFF24
    cmp r1, r2
    ldreqb r1, [r0, #0xB2]
    cmpeq r1, #0x96
    ldrne r0, =0xDEAD0001
    bne done
    tst r9, #0x100
    moveq r0, #3                   @ SRAM region 8 waits, the library's
    movne r0, #0                   @ bit 8: WAITCNT 0 (SRAM 4 waits)
    strh r0, [r5, #4]
    and r0, r9, #0x200
    str r0, delay                  @ bit 9: the first poll ~100 cycles late
    and r9, r9, #15                @ n
    mov r6, #FLASH
    ldr r7, =0x0E005555
    ldr r2, =0x0E002AAA

    @ the ID, for every cell (the answer of n = 0)
    fcmd 0x90
    bl  settle
    ldrb r0, [r6]
    ldrb r1, [r6, #1]
    orr r0, r0, r1, lsl #8
    str r0, chipid
    fcmd 0xF0
    mov r0, #0xF0
    strb r0, [r6]                  @ some parts leave ID mode on a plain F0
    bl  settle
    ldr r0, chipid
    cmp r9, #0
    beq done
    cmp r9, #4
    beq control
    and r1, r0, #0xFF
    cmp r1, #0x1F
    ldreq r0, =0xDEAD0003
    beq done
    cmp r9, #1
    beq same_value
    bl  sector_blank
    ldrne r0, =0xDEAD0002
    bne done
    cmp r9, #3
    beq erase_only

    @ n = 2: a real program, then the sector erased again
    ldr r3, =LAST
    mov r1, #0xFE
    bl  program_timed
    str r0, answer
    bl  erase_timed
    bl  sector_blank
    ldr r0, answer
    orrne r0, r0, #0x80000000
    b   done

same_value:
    ldr r3, =LAST
    ldrb r1, [r3]
    bl  program_timed
    b   done

erase_only:
    bl  erase_timed
    b   done

control:
    ldr r3, =LAST
    ldrb r1, [r3]
    bl  timers_start
    bl  poll
    b   done

done:
    ldr r1, savedws
    strh r1, [r5, #4]
    probe_leave

@ program r1 at r3 -> r0 = cycles to the read returning it
program_timed:
    stmfd sp!, {lr}
    fcmd 0xA0
    bl  timers_start
    strb r1, [r3]
    ldr r0, delay
    cmp r0, #0
    movne r0, #25
1:  subnes r0, r0, #1
    bne 1b
    bl  poll
    ldmfd sp!, {pc}

@ erase sector 15 -> r0 = cycles to the read of 0xFF at its first byte
erase_timed:
    stmfd sp!, {lr}
    fcmd 0x80
    mov r0, #0xAA
    strb r0, [r7]
    mov r0, #0x55
    strb r0, [r2]
    ldr r3, =SECT
    mov r1, #0xFF
    bl  timers_start
    mov r0, #0x30
    strb r0, [r3]
    bl  poll
    ldmfd sp!, {pc}

@ poll [r3] until it reads r1 -> r0 = TM1:TM0, FFFFFFFF / FFFFFFFE
poll:
    stmfd sp!, {r2, lr}
    ldr r2, =POLLS
1:  ldrb r0, [r3]
    cmp r0, r1
    beq 3f
    tst r0, #0x20                  @ DQ5: the chip says its time ran out
    bne 2f
    subs r2, r2, #1
    bne 1b
    mvn r0, #0
    b   4f
2:  ldrb r0, [r3]                  @ DQ5 and a read after it still not done
    cmp r0, r1
    beq 3f
    mov r0, #0xF0
    strb r0, [r6]                  @ back to read mode
    mvn r0, #1
    b   4f
3:  bl  read_timers
4:  ldmfd sp!, {r2, pc}

@ Z set when sector 15 reads 0xFF throughout
sector_blank:
    ldr r3, =SECT
    add r1, r3, #0x1000
1:  ldrb r0, [r3], #1
    cmp r0, #0xFF
    bxne lr
    cmp r3, r1
    bne 1b
    cmp r0, #0xFF
    bx  lr

@ TM0 and TM1 cleared, TM1 cascaded, TM0 started (prescaler 1)
timers_start:
    mov r0, #0
    str r0, [r10]
    str r0, [r10, #4]
    ldr r0, =0x00840000
    str r0, [r10, #4]
    str r11, [r10]
    bx  lr

@ -> r0 = TM1:TM0, carry-safe (r1 kept)
read_timers:
    stmfd sp!, {r1, r2}
1:  ldrh r1, [r10, #4]
    ldrh r0, [r10]
    ldrh r2, [r10, #4]
    cmp r1, r2
    bne 1b
    orr r0, r0, r1, lsl #16
    ldmfd sp!, {r1, r2}
    bx  lr

@ ~20 us (GBATEK: the library waits after entering and leaving ID mode)
settle:
    mov r0, #0x200
1:  subs r0, r0, #1
    bne 1b
    bx  lr

    .ltorg
    .balign 4
savedws: .word 0
answer:  .word 0
chipid:  .word 0
delay:   .word 0
    @ the save-type marker: the emulators' cartridge wrapper carries these
    @ bytes, so it gets a 64 KB flash
    .ascii "FLASH512_V131"
    .balign 4
    probe_data
