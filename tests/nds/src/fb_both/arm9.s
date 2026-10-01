@ fb_both ARM9: fb_hello's gradient on the top screen, plus a solid
@ backdrop from engine B on the bottom screen.
@
@ Top (engine A, VRAM display mode, bank A), 256x192 BGR555:
@   red = x / 8, green = y * 21 / 128, blue = 31 - x / 8
@   top-left blue, top-right red, bottom-left cyan, bottom-right yellow.
@ Bottom (engine B, graphics mode, no layers enabled): every pixel is the
@   engine B backdrop, BG palette entry 0 = 0x7C1F (magenta: red 31, blue 31).
@
@ Registers (GBATEK):
@   POWCNT1   0x04000304 (16-bit) bit0 LCDs, bit1 2D A, bit9 2D B,
@                                 bit15 engine A on the top screen
@   VRAMCNT_A 0x04000240 (8-bit)  0x80 = enabled, LCDC at 0x06800000
@   DISPCNT   0x04000000 (32-bit) display mode 2 (VRAM), bank A
@   DISPCNT_B 0x04001000 (32-bit) display mode 1 (graphics), BG0-3/OBJ off
@   PRAM B    0x05000400 (16-bit) engine B BG palette entry 0 = backdrop

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

	mov	r0, #0x04000000
	mov	r1, #0x00020000
	str	r1, [r0]

	ldr	r0, =0x04001000
	mov	r1, #0x00010000
	str	r1, [r0]

	ldr	r0, =0x05000400
	ldr	r1, =0x7C1F
	strh	r1, [r0]

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
