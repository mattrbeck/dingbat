@ A timer interrupt raised just before a preemptible DMA burst is still
@ taken (tests/irqburst_test.nim).
@
@ The CPU's interrupt synchroniser stops while a DMA holds the bus, so the
@ check that recognises a timer interrupt is held to the burst's end. A
@ burst that a higher-priority channel could preempt drains due events at
@ its transfer boundaries; a check drained there waits for the burst's end
@ to book it again. For a raise from before the burst nothing did: the
@ interrupt stayed pending with IME, CPSR.I and IE open, and every later
@ raise rode with the one in flight, so none was taken until something else
@ booked a check (docs/playtest-bugs.md §100, Famicom Mini Nazo no
@ Murasamejou: 39,272 cycles late, the FIFO DMA playing past its buffer).
@
@ The shape: DMA3 moves four words every H-blank (repeat, fixed addresses);
@ DMA0 stays armed on V-blank (repeat), so every DMA3 burst is preemptible;
@ timer 0 interrupts every 1231 cycles, one less than a line, so its
@ overflow walks one cycle a line across the H-blank DMA's grant and lands
@ on every phase within each 1232 lines. The CPU idles in IWRAM (`b .`,
@ one-cycle fetches), and no register write books a check: only the raises
@ and the handler's acknowledge do. Without the burst-end booking 6460
@ interrupts were taken for 6845 overflows in 30 frames.
@
@ The handler (from ROM, through the BIOS's IRQ vector) acknowledges timer
@ 0 and leaves at 0x02000000 the number of interrupts taken, at 0x02000004
@ the highest TM0 count it read on entry (0xFB31 + the cycles since the
@ overflow).
@
@ Build:
@   arm-none-eabi-as -mcpu=arm7tdmi -o irqburst.o irqburst.s
@   arm-none-eabi-ld -Ttext=0x08000000 -o irqburst.elf irqburst.o
@   arm-none-eabi-objcopy -O binary irqburst.elf irqburst.gba

    .arm
    .text
    .global _start

.equ PERIOD, 1231

_start:
    b   init
    .space 0xBC                    @ header (unchecked without the boot)

init:
    mov r0, #0x04000000
    mov r1, #0
    strh r1, [r0]                  @ DISPCNT: mode 0, not blanked
    ldr r1, =0xEAFFFFFE            @ b .
    mov r2, #0x03000000
    str r1, [r2]
    ldr r1, =handler
    ldr r2, =0x03007FFC            @ the user IRQ handler the BIOS calls
    str r1, [r2]
    ldr r1, =0x02001000            @ DMA0: one word every V-blank, fixed
    str r1, [r0, #0xB0]
    ldr r1, =0x02002000
    str r1, [r0, #0xB4]
    ldr r1, =0x93400001
    str r1, [r0, #0xB8]
    ldr r1, =0x02003000            @ DMA3: four words every H-blank,
    str r1, [r0, #0xD4]            @ 32-bit, repeat, fixed
    ldr r1, =0x02004000
    str r1, [r0, #0xD8]
    ldr r1, =0xA7400004
    str r1, [r0, #0xDC]
    add r2, r0, #0x200
    mov r1, #8                     @ IE: timer 0
    strh r1, [r2]
    mov r1, #1                     @ IME
    str r1, [r2, #8]
    ldr r1, =(0x00C00000 | (0x10000 - PERIOD))
    str r1, [r0, #0x100]           @ TM0: prescaler 1, IRQ, on
    msr cpsr_c, #0x1F              @ System mode, IRQs on
    mov pc, #0x03000000

handler:
    mov r0, #0x04000000
    add r2, r0, #0x100
    ldrh r1, [r2]                  @ TM0 now
    add r2, r0, #0x200
    mov r3, #8
    strh r3, [r2, #2]              @ IF: acknowledge timer 0
    mov r3, #0x02000000
    ldr r2, [r3]
    add r2, r2, #1
    str r2, [r3]                   @ interrupts taken
    ldr r2, [r3, #4]
    cmp r1, r2
    strhi r1, [r3, #4]             @ the highest TM0 on entry
    bx  lr

    .ltorg
