@ snd_tone ARM7: two channels straight from the registers (GBATEK "DS
@ Sound"), no library.
@   ch8  PSG square, duty 3 (50%), 440 Hz: sample rate 3520 Hz,
@        TMR = 0x10000 - 16756991 / 3520 = 0xED67; volume 64, pan 32 (left)
@   ch0  PCM8 sawtooth, 64 samples looped (PNT 0, LEN 16 words) at
@        220 Hz x 64 = 14080 Hz, TMR = 0x10000 - 1190 = 0xFB5A;
@        volume 48, pan 96 (right)
@ SOUNDCNT = 0x807F (enable, master 127), POWCNT2 bit0 = speakers.

	.arm
	.section .text
	.global _start
_start:
	ldr	r0, =0x04000304
	mov	r1, #1
	strh	r1, [r0]
	ldr	r0, =0x04000500
	ldr	r1, =0x807F
	strh	r1, [r0]

	ldr	r0, =0x04000480		@ channel 8
	ldr	r1, =0xED67
	strh	r1, [r0, #8]
	ldr	r1, =0xE3200040
	str	r1, [r0]

	ldr	r0, =0x04000400		@ channel 0
	adr	r1, saw
	str	r1, [r0, #4]
	ldr	r1, =0xFB5A
	str	r1, [r0, #8]		@ TMR, PNT = 0
	mov	r1, #16
	str	r1, [r0, #12]		@ LEN
	ldr	r1, =0x88600030
	str	r1, [r0]
forever:
	b	forever

	.pool
	.balign 4
saw:
	.set	v, -128
	.rept	64
	.byte	v & 0xFF
	.set	v, v + 4
	.endr
