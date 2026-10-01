@ snd_tone ARM9: solid backdrops so the page shows the ROM is running
@ (top green, bottom blue). The sound is all on the ARM7 (arm7.s).
@
@   POWCNT1   0x04000304 bit0 LCDs, bit1 2D A, bit9 2D B, bit15 A on top
@   DISPCNT   0x04000000 / DISPCNT_B 0x04001000: mode 1, no layers
@   PRAM      0x05000000 (A) / 0x05000400 (B) BG entry 0 = backdrop

	.arm
	.section .text
	.global _start
_start:
	ldr	r0, =0x04000304
	ldr	r1, =0x8203
	strh	r1, [r0]
	mov	r0, #0x04000000
	mov	r1, #0x00010000
	str	r1, [r0]
	ldr	r0, =0x04001000
	str	r1, [r0]
	mov	r0, #0x05000000
	ldr	r1, =0x03E0		@ green
	strh	r1, [r0]
	ldr	r0, =0x05000400
	ldr	r1, =0x7C00		@ blue
	strh	r1, [r0]
forever:
	b	forever

	.pool
