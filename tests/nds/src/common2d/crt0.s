@ Minimal ARM9 start for the no-library C test ROMs (2d_*): system mode
@ stack in main RAM, .bss cleared, then main(). IRQs stay off.

	.arm
	.section .text.start
	.global _start
_start:
	mov	r0, #0xDF		@ system mode, IRQ/FIQ masked
	msr	cpsr_c, r0
	ldr	sp, =0x02300000
	ldr	r0, =__bss_start
	ldr	r1, =__bss_end
	mov	r2, #0
1:	cmp	r0, r1
	strlo	r2, [r0], #4
	blo	1b
	bl	main
2:	b	2b

	.pool
