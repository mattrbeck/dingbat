@ linkecho.s — the smallest multiboot image that proves the hardware link
@ works (built by linkecho.py, uploaded by tools/hwlink/gblink.py).  It
@ paints the screen green and then answers every 32-bit serial transfer with
@ a known word, so the host can read the proof back with nobody watching the
@ console.  Both halves matter: the screen shows a person the upload landed,
@ the echo shows the harness that a probe ROM can report its own results
@ instead of being photographed.

    .arm
    .text
    .global _start

.equ DISPCNT,   0x04000000
.equ VRAM,      0x06000000
.equ SIODATA32, 0x04000120
.equ SIOCNT,    0x04000128
.equ RCNT,      0x04000134
.equ MAGIC,     0xC0DE1234

_start:
    b   main                       @ 0x00: the BIOS enters here
    .space 0x9C                    @ 0x04-0x9F: logo (patched by the builder)
    .space 0x20                    @ 0xA0-0xBF: title/codes (patched)
main:
    ldr r0, =DISPCNT
    ldr r1, =0x0403                @ mode 3, BG2 on
    strh r1, [r0]

    ldr r0, =VRAM
    ldr r1, =0x03E0                @ BGR555 green
    orr r1, r1, r1, lsl #16
    ldr r2, =(240 * 160 / 2)
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b

    ldr r0, =RCNT                  @ serial mode, chosen by SIOCNT
    mov r1, #0
    strh r1, [r0]
    ldr r5, =SIODATA32
    ldr r6, =SIOCNT
    ldr r7, =MAGIC

sio_loop:
    str r7, [r5]                   @ what the master will clock out of us
    mov r1, #0x1000                @ 32-bit transfer, external clock (slave)
    orr r1, r1, #0x80              @ ready
    strh r1, [r6]
2:  ldrh r1, [r6]                  @ wait for the master to clock it through
    tst r1, #0x80
    bne 2b
    b   sio_loop
