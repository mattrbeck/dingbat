@ BIOS sound-driver probe runtime: IRQ handler and SWI wrappers.
@
@ Every wrapper brackets its SWI (or BIOS function call) with a byte store
@ to 0x04000FF0, which tests/biosdrv_probe.nim turns into a snapshot with a
@ cycle stamp: marker 0xF0 just before, 0xF1 just after. The registers the
@ call returns are stored to bd_regs (r0-r3, r12, sp, lr, cpsr) before the
@ second marker so the snapshot carries them.
        .syntax unified
        .arm
        .section .iwram, "ax", %progbits
        .align 2

        .global bd_regs
        .global bd_irq_count
        .global bd_irq_vsync
        .global bd_irq_main
        .global bd_irq_handler

@ IRQ handler (installed at 0x03007FFC): acknowledge IF, OR the flags into
@ the BIOS mirror, count V-blanks and optionally run SoundDriverVSync
@ (bd_irq_vsync != 0) straight after the acknowledge.
bd_irq_handler:
        mov     r3, #0x04000000
        ldr     r2, [r3, #0x200]        @ IE | IF << 16
        and     r0, r2, r2, lsr #16
        add     r1, r3, #0x200
        strh    r0, [r1, #2]            @ acknowledge
        ldr     r1, =0x03007FF8
        ldrh    r2, [r1]
        orr     r2, r2, r0
        strh    r2, [r1]
        tst     r0, #1
        bxeq    lr
        ldr     r1, =bd_irq_count
        ldr     r2, [r1]
        add     r2, r2, #1
        str     r2, [r1]
        ldr     r1, =bd_irq_vsync
        ldr     r1, [r1]
        cmp     r1, #0
        bxeq    lr
        swi     #0x1D0000               @ SoundDriverVSync
        bx      lr

        .pool

@ bd_swi_NN(r0, r1, r2, r3): the SWI with markers
        .macro  SWIWRAP n
        .global bd_swi_\n
bd_swi_\n:
        push    {r4-r11, lr}
        mov     r4, #0x04000000
        add     r4, r4, #0xFF0
        mov     r5, #0xF0
        strb    r5, [r4]
        swi     #0x\n\()0000
        push    {r0-r3}
        ldr     r5, =bd_regs
        pop     {r6-r9}
        stmia   r5!, {r6-r9}
        str     r12, [r5], #4
        str     sp, [r5], #4
        str     lr, [r5], #4
        mrs     r6, cpsr
        str     r6, [r5], #4
        mov     r5, #0xF1
        strb    r5, [r4]
        mov     r0, r6
        pop     {r4-r11, lr}
        bx      lr
        .pool
        .endm

        SWIWRAP 1A
        SWIWRAP 1B
        SWIWRAP 1C
        SWIWRAP 1D
        SWIWRAP 1E
        SWIWRAP 1F
        SWIWRAP 20
        SWIWRAP 21
        SWIWRAP 22
        SWIWRAP 23
        SWIWRAP 24
        SWIWRAP 28
        SWIWRAP 29
        SWIWRAP 2A

@ bd_callfn(fn, r0, r1, r2): call a (BIOS) function pointer with markers.
        .global bd_callfn
bd_callfn:
        push    {r4-r11, lr}
        mov     r12, r0
        mov     r0, r1
        mov     r1, r2
        mov     r2, r3
        mov     r4, #0x04000000
        add     r4, r4, #0xFF0
        mov     r5, #0xF0
        strb    r5, [r4]
        mov     lr, pc
        bx      r12
        push    {r0-r3}
        ldr     r5, =bd_regs
        pop     {r6-r9}
        stmia   r5!, {r6-r9}
        str     r12, [r5], #4
        str     sp, [r5], #4
        str     lr, [r5], #4
        mrs     r6, cpsr
        str     r6, [r5], #4
        mov     r5, #0xF1
        strb    r5, [r4]
        pop     {r4-r11, lr}
        bx      lr
        .pool

        .section .bss
        .align 2
bd_regs:        .space 32
bd_irq_count:   .space 4
bd_irq_vsync:   .space 4
bd_irq_main:    .space 4

@ Thumb wrappers in ROM (the caller's code region and ISA change the SWI's
@ return refill): same markers, no register capture.
        .text
        .thumb
        .macro  TSWIWRAP n
        .global bd_tswi_\n
        .thumb_func
bd_tswi_\n:
        push    {r4, r5, lr}
        ldr     r4, =0x04000FF0
        movs    r5, #0xF0
        strb    r5, [r4]
        swi     #0x\n
        movs    r5, #0xF1
        strb    r5, [r4]
        pop     {r4, r5}
        pop     {r3}
        bx      r3
        .pool
        .endm

        TSWIWRAP 1A
        TSWIWRAP 1B
        TSWIWRAP 1C
        TSWIWRAP 1D
        TSWIWRAP 1E
        TSWIWRAP 28
        TSWIWRAP 29

@ The same bracket in other regions and ISAs: ARM in ROM (bd_aswi_*), ARM in
@ EWRAM (bd_eswi_*), Thumb in EWRAM (bd_etswi_*)
        .macro  ASWIWRAP pfx n
        .global \pfx\()_\n
\pfx\()_\n:
        push    {r4, r5, lr}
        ldr     r4, =0x04000FF0
        mov     r5, #0xF0
        strb    r5, [r4]
        swi     #0x\n\()0000
        mov     r5, #0xF1
        strb    r5, [r4]
        pop     {r4, r5, lr}
        bx      lr
        .pool
        .endm
        .macro  TSWIWRAP2 pfx n
        .global \pfx\()_\n
        .thumb_func
\pfx\()_\n:
        push    {r4, r5, lr}
        ldr     r4, =0x04000FF0
        movs    r5, #0xF0
        strb    r5, [r4]
        swi     #0x\n
        movs    r5, #0xF1
        strb    r5, [r4]
        pop     {r4, r5}
        pop     {r3}
        bx      r3
        .pool
        .endm

        .text
        .arm
        ASWIWRAP bd_aswi 1A
        ASWIWRAP bd_aswi 1B
        ASWIWRAP bd_aswi 1D
        ASWIWRAP bd_aswi 28
        .section .ewram, "ax", %progbits
        .arm
        ASWIWRAP bd_eswi 1A
        ASWIWRAP bd_eswi 1B
        ASWIWRAP bd_eswi 1D
        ASWIWRAP bd_eswi 28
        .thumb
        TSWIWRAP2 bd_etswi 1A
        TSWIWRAP2 bd_etswi 1B
        TSWIWRAP2 bd_etswi 1D
        TSWIWRAP2 bd_etswi 28

@ bd_pswi(n, r0): SWI n (0x1A-0x2A) with r0 = the argument and r1-r3,
@ r12 = 0x11111111 / 0x22222222 / 0x33333333 / 0xCCCCCCCC, markers and
@ bd_regs as the other wrappers
        .section .iwram, "ax", %progbits
        .arm
        .global bd_pswi
bd_pswi:
        push    {r4-r11, lr}
        sub     r2, r0, #0x1A
        adr     r11, 1f
        add     r11, r11, r2, lsl #3
        mov     r0, r1
        ldr     r1, =0x11111111
        ldr     r2, =0x22222222
        ldr     r3, =0x33333333
        ldr     r12, =0xCCCCCCCC
        mov     r4, #0x04000000
        add     r4, r4, #0xFF0
        mov     r5, #0xF0
        strb    r5, [r4]
        mov     pc, r11
1:
        .irp    n, 1A,1B,1C,1D,1E,1F,20,21,22,23,24,25,26,27,28,29,2A
        swi     #0x\n\()0000
        b       2f
        .endr
2:
        push    {r0-r3}
        ldr     r5, =bd_regs
        pop     {r6-r9}
        stmia   r5!, {r6-r9}
        str     r12, [r5], #4
        str     sp, [r5], #4
        str     lr, [r5], #4
        mrs     r6, cpsr
        str     r6, [r5], #4
        mov     r5, #0xF1
        strb    r5, [r4]
        pop     {r4-r11, lr}
        bx      lr
        .pool
