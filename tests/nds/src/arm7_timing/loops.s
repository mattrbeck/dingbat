@ arm7_timing: the timed loops (ARM7, code in WRAM unless named). Each
@ takes r0 = passes, r1 = a data address where it needs one, and returns.

	.syntax unified
	.text

@ Thumb "SUB r0, #1 / BGT" (the loop GBATEK's WaitByLoop runs in BIOS)
	.thumb
	.global loop_thumb
	.thumb_func
loop_thumb:
1:	subs	r0, #1
	bgt	1b
	bx	lr

@ the same in ARM state
	.arm
	.global loop_arm
loop_arm:
1:	subs	r0, r0, #1
	bgt	1b
	bx	lr

@ 8 straight-line NOPs (MOV r0, r0) per pass in ARM state: the per-pass
@ cost minus loop_arm's is 8 sequential opcodes
	.global loop_arm_nop8
loop_arm_nop8:
1:	mov	r2, r2
	mov	r2, r2
	mov	r2, r2
	mov	r2, r2
	mov	r2, r2
	mov	r2, r2
	mov	r2, r2
	mov	r2, r2
	subs	r0, r0, #1
	bgt	1b
	bx	lr
	.global loop_arm_nop8_end
loop_arm_nop8_end:

@ 8 LDRH from r1 (sequential halfwords) per pass
	.global loop_ldrh8
loop_ldrh8:
1:	ldrh	r2, [r1]
	ldrh	r2, [r1, #2]
	ldrh	r2, [r1, #4]
	ldrh	r2, [r1, #6]
	ldrh	r2, [r1, #8]
	ldrh	r2, [r1, #10]
	ldrh	r2, [r1, #12]
	ldrh	r2, [r1, #14]
	subs	r0, r0, #1
	bgt	1b
	bx	lr

@ 8 LDR per pass
	.global loop_ldr8
loop_ldr8:
1:	ldr	r2, [r1]
	ldr	r2, [r1, #4]
	ldr	r2, [r1, #8]
	ldr	r2, [r1, #12]
	ldr	r2, [r1, #16]
	ldr	r2, [r1, #20]
	ldr	r2, [r1, #24]
	ldr	r2, [r1, #28]
	subs	r0, r0, #1
	bgt	1b
	bx	lr
	.global loop_ldr8_end
loop_ldr8_end:

@ 8 STR per pass
	.global loop_str8
loop_str8:
1:	str	r2, [r1]
	str	r2, [r1, #4]
	str	r2, [r1, #8]
	str	r2, [r1, #12]
	str	r2, [r1, #16]
	str	r2, [r1, #20]
	str	r2, [r1, #24]
	str	r2, [r1, #28]
	subs	r0, r0, #1
	bgt	1b
	bx	lr
	.global loop_str8_end
loop_str8_end:

@ LDMIA of 8 registers per pass
	.global loop_ldm8
loop_ldm8:
	push	{r4-r11}
1:	ldmia	r1, {r4-r11}
	subs	r0, r0, #1
	bgt	1b
	pop	{r4-r11}
	bx	lr

@ 8 MUL (small operands: one internal cycle each) per pass
	.global loop_mul8
loop_mul8:
	mov	r2, #3
1:	mul	r3, r2, r2
	mul	r3, r2, r2
	mul	r3, r2, r2
	mul	r3, r2, r2
	mul	r3, r2, r2
	mul	r3, r2, r2
	mul	r3, r2, r2
	mul	r3, r2, r2
	subs	r0, r0, #1
	bgt	1b
	bx	lr

@ a BL to a BX LR per pass (Thumb)
	.thumb
	.global loop_thumb_call
	.thumb_func
loop_thumb_call:
	push	{lr}
1:	bl	2f
	subs	r0, #1
	bgt	1b
	pop	{r1}
	bx	r1
	.thumb_func
2:	bx	lr

@ an untaken conditional branch per pass on top of loop_thumb
	.global loop_thumb_untaken
	.thumb_func
loop_thumb_untaken:
	movs	r2, #0
1:	cmp	r2, #1
	beq	2f
	subs	r0, #1
	bgt	1b
2:	bx	lr

@ a word copy per pass, as a crt0's copy loop: LDR from r1, STR to r1 + 64
	.arm
	.global loop_copy
loop_copy:
1:	ldr	r2, [r1]
	str	r2, [r1, #64]
	subs	r0, r0, #1
	bgt	1b
	bx	lr
	.global loop_copy_end
loop_copy_end:

	.end
