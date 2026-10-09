@ cheat_probe ARM9: something for a cheat code to change (web e2e,
@ docs/nds/features.md "Cheats"). Every V-blank the whole top screen is
@ filled with the BGR555 halfword at 0x02100000, which starts red (0x001F)
@ and which nothing in the program writes again; the word at 0x02100004
@ counts the frames. A cheat writing 0x02100000 paints the screen.
@
@ Top: engine A, VRAM display mode, bank A (as fb_both).
@ Bottom: engine B backdrop, magenta 0x7C1F (as fb_both).
@ Registers (GBATEK): POWCNT1 0x04000304, VRAMCNT_A 0x04000240, DISPCNT
@ 0x04000000 / 0x04001000, VCOUNT 0x04000006, PRAM B 0x05000400.

	.arm
	.section .text
	.global _start
_start:
	ldr	r0, =0x04000304
	ldr	r1, =0x8203
	strh	r1, [r0]

	ldr	r0, =0x04000240
	mov	r1, #0x80
	strb	r1, [r0]

	mov	r9, #0x04000000
	mov	r1, #0x00020000
	str	r1, [r9]

	ldr	r0, =0x04001000
	mov	r1, #0x00010000
	str	r1, [r0]

	ldr	r0, =0x05000400
	ldr	r1, =0x7C1F
	strh	r1, [r0]

	ldr	r8, =0x02100000
	mov	r1, #0x1F		@ red
	str	r1, [r8]
	mov	r1, #0
	str	r1, [r8, #4]

frame:
wait_leave:				@ out of line 192 ...
	ldrh	r1, [r9, #6]
	cmp	r1, #192
	beq	wait_leave
wait_enter:				@ ... and to it again: V-blank starts
	ldrh	r1, [r9, #6]
	cmp	r1, #192
	bne	wait_enter

	ldrh	r3, [r8]		@ the colour
	orr	r3, r3, r3, lsl #16
	ldr	r0, =0x06800000
	mov	r2, #24576		@ 256 x 192 halfwords, two a store
fill:
	str	r3, [r0], #4
	subs	r2, r2, #1
	bne	fill

	ldr	r1, [r8, #4]
	add	r1, r1, #1
	str	r1, [r8, #4]
	b	frame

	.pool
