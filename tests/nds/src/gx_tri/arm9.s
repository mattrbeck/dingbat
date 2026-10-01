@ gx_tri ARM9: the 3D engine with no library. One frame of geometry is
@ sent once; the rendering engine then redraws it every frame.
@
@ Top screen (engine A, BG0 = 3D) over a dark blue rear plane (0x2042):
@   left:  a triangle, red bottom-left, green bottom-right, blue top
@          (command ports 0x4000480/48C, one STR per parameter)
@   right: a yellow quad (0x03FF) sent as packed commands to GXFIFO
@ The projection matrix goes in as one unpacked MTX_LOAD_4x4 written with
@ STM to the GXFIFO mirror (command + 16 parameters).
@
@ Registers (GBATEK, "DS 3D"):
@   POWCNT1   0x04000304 bits 0 LCDs, 1 2D A, 2 3D render, 3 3D geometry,
@                        9 2D B, 15 engine A on top
@   DISPCNT   0x04000000 mode 1 (graphics), BG0 on (bit 8), BG0 = 3D (bit 3)
@   CLEAR_COLOR 0x04000350 / CLEAR_DEPTH 0x04000354, VIEWPORT 0x04000580,
@   MTX_MODE 0x04000440, MTX_IDENTITY 0x04000454, POLYGON_ATTR 0x040004A4,
@   BEGIN_VTXS 0x04000500, COLOR 0x04000480, VTX_16 0x0400048C,
@   SWAP_BUFFERS 0x04000540, GXFIFO 0x04000400

	.arm
	.section .text
	.global _start
_start:
	ldr	r0, =0x04000304
	ldr	r1, =0x820F
	strh	r1, [r0]

	ldr	r0, =writes		@ (address, value) pairs, address 0 ends
1:	ldmia	r0!, {r1, r2}
	cmp	r1, #0
	beq	2f
	str	r2, [r1]
	b	1b
2:
	ldr	r0, =0x04000400		@ projection: unpacked MTX_LOAD_4x4 by STM
	ldr	r1, =proj
	ldmia	r1!, {r2-r10}
	stmia	r0, {r2-r10}		@ command 0x16 + m[0..7]
	ldmia	r1!, {r2-r9}
	stmia	r0, {r2-r9}		@ m[8..15]

	ldr	r0, =writes2
3:	ldmia	r0!, {r1, r2}
	cmp	r1, #0
	beq	forever
	str	r2, [r1]
	b	3b

forever:
	b	forever

	.pool

	.align 2
writes:
	.word 0x04000000, 0x00010108	@ DISPCNT: mode 1, BG0 on, BG0 = 3D
	.word 0x04000008, 0x00000000	@ BG0CNT: priority 0
	.word 0x04000060, 0x00000000	@ DISP3DCNT
	.word 0x04000350, 0x3F1F2042	@ CLEAR_COLOR: rgb (2,2,8), alpha 31, ID 63
	.word 0x04000354, 0x00007FFF	@ CLEAR_DEPTH
	.word 0x04000580, 0xBFFF0000	@ VIEWPORT 0,0 - 255,191
	.word 0x04000440, 0x00000000	@ MTX_MODE projection
	.word 0, 0

proj:
	.word 0x16			@ MTX_LOAD_4x4, unpacked
	.word 0x1000, 0, 0, 0		@ identity
	.word 0, 0x1000, 0, 0
	.word 0, 0, 0x1000, 0
	.word 0, 0, 0, 0x1000

writes2:
	.word 0x04000440, 0x00000001	@ MTX_MODE position
	.word 0x04000454, 0x00000000	@ MTX_IDENTITY
	.word 0x040004A4, 0x001F00C0	@ POLYGON_ATTR: alpha 31, front + back
	.word 0x04000500, 0x00000000	@ BEGIN_VTXS: triangles
	.word 0x04000480, 0x0000001F	@ COLOR red
	.word 0x0400048C, 0xF4CDF19A	@ VTX_16 (-0.9, -0.7)
	.word 0x0400048C, 0x00000000	@        z 0
	.word 0x04000480, 0x000003E0	@ COLOR green
	.word 0x0400048C, 0xF4CDFE66	@ VTX_16 (-0.1, -0.7)
	.word 0x0400048C, 0x00000000
	.word 0x04000480, 0x00007C00	@ COLOR blue
	.word 0x0400048C, 0x0B33F800	@ VTX_16 (-0.5, 0.7)
	.word 0x0400048C, 0x00000000
	.word 0x04000400, 0x23234020	@ packed: COLOR, BEGIN_VTXS, VTX_16, VTX_16
	.word 0x04000400, 0x000003FF	@   COLOR yellow
	.word 0x04000400, 0x00000001	@   BEGIN_VTXS: quads
	.word 0x04000400, 0xF4CD019A	@   VTX_16 (0.1, -0.7)
	.word 0x04000400, 0x00000000
	.word 0x04000400, 0xF4CD0E66	@   VTX_16 (0.9, -0.7)
	.word 0x04000400, 0x00000000
	.word 0x04000400, 0x00002323	@ packed: VTX_16, VTX_16
	.word 0x04000400, 0x0B330E66	@   VTX_16 (0.9, 0.7)
	.word 0x04000400, 0x00000000
	.word 0x04000400, 0x0B33019A	@   VTX_16 (0.1, 0.7)
	.word 0x04000400, 0x00000000
	.word 0x04000540, 0x00000000	@ SWAP_BUFFERS
	.word 0, 0
