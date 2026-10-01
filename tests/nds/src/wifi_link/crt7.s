@ wifi_link ARM7 start: system mode, IRQs masked, stack at the top of ARM7
@ WRAM, .bss cleared, then main().

	.arm
	.section .text.start
	.global _start
_start:
	mov	r0, #0xDF
	msr	cpsr_c, r0
	ldr	sp, =0x0380FC00
	ldr	r0, =__bss_start
	ldr	r1, =__bss_end
	mov	r2, #0
1:	cmp	r0, r1
	strlo	r2, [r0], #4
	blo	1b
	bl	main
2:	b	2b

	.pool
