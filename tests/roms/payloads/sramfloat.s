@ payload: what the SRAM region reads on a cartridge with no SRAM or flash
@
@ WHY: Justice League Chronicles (U), an EEPROM cart, walks a heap list off
@ its end at boot: through the gamepak's open bus, round the address space,
@ and through 0x0E000000-0x0FFFFFFF three bytes a step while each word there
@ reads 0xFFFFFFFF. In dingbat and the second reference the walk takes ~600
@ frames (a dark screen between the DC logo and the menu); mGBA reads
@ something else there and is at the menu by f1200. With an empty slot the
@ console reads 0xFFFFFFFF at 0x0E000000 (docs/playtest-bugs.md section 11);
@ this asks with an EEPROM cart in the slot, whose /CS2 nothing answers.
@
@ RIG: as eesettle.s -- boot holding SELECT+START with the cart inserted
@ (an EEPROM cart: Super Mario Advance 3, any 4 Kbit or 64 Kbit one).
@ Read-only: the SRAM region is only loaded from, never written.
@
@ r0 bits 0..1  width: 0 ldrb, 1 ldrh, 2 ldr
@    bits 4..6  address: 0 0x0E000000, 1 0x0E000001, 2 0x0E00ABCD,
@               3 0x0F028761 (the walk's), 4 0x0FFFFFFF
@    bit 8      first load a halfword from the gamepak at 0x085A5A5A, so
@               the cartridge bus last carried 0x5A on A16-A23 (a floating
@               data bus that keeps its charge would read it back)
@ answer: the loaded value, zero-extended (ldrh/ldr rotate misaligned
@ addresses as the CPU does). 0xDEAD0001 = no cartridge header.
@
@ PROVENANCE: dingbat 0xFF/0xFFFF/0xFFFFFFFF on every cell (EEPROM carts:
@ storage/eeprom.nim, "reads float high (0xFF assumed)"; ldrh at an odd
@ address rotates to 0xFF0000FF). mgba answers the same on the wrapper ROM,
@ which names no backup chip (it makes the region SRAM, erased); on the
@ EEPROM game it behaves as if the region read 0: a dingbat build reading 0
@ there reaches the menu and the stage with mgba (f1200, f1800). Console:
@ not yet run.
    .arm
    .text
    .global _start
_start:
    stmfd sp!, {r4-r11, lr}
    mov r9, r0
    mov r0, #0x08000000
    ldr r1, [r0, #4]
    ldr r2, =0x51AEFF24
    cmp r1, r2
    ldreqb r1, [r0, #0xB2]
    cmpeq r1, #0x96
    ldrne r0, =0xDEAD0001
    bne done
    mov r1, r9, lsr #4
    and r1, r1, #7
    adr r2, addrs
    ldr r4, [r2, r1, lsl #2]
    ldr r5, =0x085A5A5A
    and r3, r9, #3
    tst r9, #0x100
    ldrneh r6, [r5]
    cmp r3, #1
    ldrltb r0, [r4]
    ldreqh r0, [r4]
    ldrgt r0, [r4]
done:
    ldmfd sp!, {r4-r11, lr}
    bx  lr
addrs:
    .word 0x0E000000, 0x0E000001, 0x0E00ABCD, 0x0F028761, 0x0FFFFFFF
    .word 0x0E000000, 0x0E000000, 0x0E000000
    .ltorg
