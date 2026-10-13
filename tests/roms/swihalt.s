@ Halt and Stop called from the cartridge (tests/swihalt_test.nim).
@
@ With Nintendo's image mapped and the HLE taking the cartridge's SWIs
@ (hle_after_bios, mode 2; or the HLE with a BIOS file given), a Halt from
@ ROM was taken by the HLE, which parked the CPU in the image's code at
@ 0x164 with the HLE's own three-word SVC frame under it; the image's
@ return pops four, so the caller's r11 and r12 were clobbered, the SVC
@ stack ended a word high and the return went through the word above the
@ frame, to 0. This ROM makes the calls and leaves what each one returned
@ with in EWRAM.
@
@ Three Halts from ARM, three from Thumb (each woken by the V-blank
@ interrupt), then a Stop from ARM and one from Thumb (each woken by the
@ keypad interrupt: the harness presses A while the CPU is stopped).
@
@ Results, one 16-byte record per call at 0x02000000 + 16*k (k = 0..7):
@   +0  0x600D0000 | k        written after the SWI returned
@   +4  sp after the call      (the System stack: 0x03007F00 throughout)
@   +8  r11 after the call     (set to 0x11110000 | k before it)
@   +12 r10 after the call     (set to 0x10100000 | k before it)
@ 0x02000100: 0x600DD0E5 once every call has returned.
@
@ Build:
@   arm-none-eabi-as -mcpu=arm7tdmi -o swihalt.o swihalt.s
@   arm-none-eabi-ld -Ttext=0x08000000 -o swihalt.elf swihalt.o
@   arm-none-eabi-objcopy -O binary swihalt.elf swihalt.gba

    .arm
    .text
    .global _start

.equ RESULTS, 0x02000000
.equ DONE,    0x02000100

_start:
    b   init
    .space 0xBC                    @ header (unchecked without the boot)

init:
    ldr r0, =0x03007FFC            @ the user IRQ handler the BIOS calls
    adr r1, irq_handler
    str r1, [r0]
    ldr r0, =0x04000000
    mov r1, #8                     @ DISPSTAT: V-blank IRQ
    strh r1, [r0, #4]
    ldr r1, =0x4001                @ KEYCNT: IRQ on A
    ldr r2, =0x04000132
    strh r1, [r2]
    ldr r2, =0x04000200
    ldr r1, =0x1001                @ IE: V-blank, keypad
    strh r1, [r2]
    mov r1, #1                     @ IME
    strh r1, [r2, #8]
    ldr r12, =RESULTS
    mov r9, #0                     @ k

    @ Three Halts from ARM
arm_halts:
    bl  arm_set
    swi 0x020000
    bl  arm_record
    cmp r9, #3
    blt arm_halts

    @ Three Halts from Thumb, then a Stop from ARM, then one from Thumb
    adr r0, thumb_halts + 1
    bx  r0

arm_set:                           @ the sentinels for call k
    ldr r11, =0x11110000
    orr r11, r11, r9
    ldr r10, =0x10100000
    orr r10, r10, r9
    bx  lr

arm_record:                        @ record call k, k += 1
    ldr r0, =0x600D0000
    orr r0, r0, r9
    add r1, r12, r9, lsl #4
    str r0, [r1]
    str sp, [r1, #4]
    str r11, [r1, #8]
    str r10, [r1, #12]
    add r9, r9, #1
    bx  lr

arm_stop:
    bl  arm_set
    swi 0x030000
    bl  arm_record
    adr r0, thumb_stop + 1
    bx  r0

irq_handler:                       @ ARM, called from the BIOS's IRQ handler
    ldr r3, =0x04000200
    ldrh r1, [r3, #2]
    strh r1, [r3, #2]              @ acknowledge IF
    ldr r2, =0x03007FF8            @ and raise the BIOS's flags
    ldrh r0, [r2]
    orr r0, r0, r1
    strh r0, [r2]
    bx  lr

    .ltorg

    .thumb
    .align 2
thumb_halts:
    bl  thumb_set
    swi 2
    bl  thumb_record
    cmp r1, #6
    blt thumb_halts
    ldr r0, =arm_stop
    bx  r0

thumb_stop:
    bl  thumb_set
    swi 3
    bl  thumb_record
    ldr r0, =DONE
    ldr r1, =0x600DD0E5
    str r1, [r0]
spin:
    b   spin

thumb_set:                         @ r11 = 0x11110000 | k, r10 = 0x10100000 | k
    ldr r0, =0x11110000
    add r0, r9
    mov r11, r0
    ldr r0, =0x10100000
    add r0, r9
    mov r10, r0
    bx  lr

thumb_record:                      @ record call k, k += 1; leaves r1 = k
    ldr r0, =0x600D0000
    add r0, r9
    mov r1, r9
    lsl r1, r1, #4
    add r1, r12
    str r0, [r1]
    mov r2, sp
    str r2, [r1, #4]
    mov r2, r11
    str r2, [r1, #8]
    mov r2, r10
    str r2, [r1, #12]
    mov r1, r9
    add r1, #1
    mov r9, r1
    bx  lr

    .ltorg
