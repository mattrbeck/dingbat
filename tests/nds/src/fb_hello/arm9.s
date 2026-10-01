@ fb_hello ARM9: the smallest picture a DS can show.
@
@ Top screen only, engine A in VRAM display mode reading bank A. No BIOS
@ calls, no interrupts, no stack, no ARM7 cooperation; just stores. Expected
@ picture (256x192, BGR555):
@   red   = x / 8          (0..31, ramps left to right)
@   green = y * 21 / 128   (0..31, ramps top to bottom)
@   blue  = 31 - x / 8     (31..0, ramps right to left)
@ so top-left is blue, top-right red, bottom-left cyan, bottom-right yellow.
@
@ Registers (GBATEK):
@   POWCNT1  0x04000304 (16-bit) bit0 LCDs on, bit1 2D engine A,
@                                bit15 engine A on the top screen
@   VRAMCNT_A 0x04000240 (8-bit) 0x80 = enabled, MST 0 (LCDC, 0x06800000)
@   DISPCNT  0x04000000 (32-bit) bits16-17 = 2: VRAM display, bits18-19 = 0: bank A

	.arm
	.section .text
	.global _start
_start:
	ldr	r0, =0x04000304
	ldr	r1, =0x8003
	strh	r1, [r0]

	ldr	r0, =0x04000240
	mov	r1, #0x80
	strb	r1, [r0]

	mov	r0, #0x04000000
	mov	r1, #0x00020000
	str	r1, [r0]

	ldr	r0, =0x06800000		@ write pointer
	mov	r2, #0			@ y
	mov	r6, #21
yloop:
	mul	r3, r2, r6
	mov	r3, r3, lsr #7		@ green 0..31
	mov	r3, r3, lsl #5
	mov	r1, #0			@ x
xloop:
	mov	r4, r1, lsr #3		@ red
	rsb	r5, r4, #31		@ blue
	orr	r4, r4, r3
	orr	r4, r4, r5, lsl #10
	strh	r4, [r0], #2
	add	r1, r1, #1
	cmp	r1, #256
	blt	xloop
	add	r2, r2, #1
	cmp	r2, #192
	blt	yloop

forever:
	b	forever

	.pool
