@ fb_both ARM7: nothing to do. Spins at its entry point.

	.arm
	.section .text
	.global _start
_start:
	b	_start
