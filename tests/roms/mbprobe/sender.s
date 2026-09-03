@ sender.s — multiboot sender for the flashcart GBA (#1).  Menu of the
@ four payloads (UP/DOWN, A), the master-side "Required Transfer
@ Initiation" of GBATEK "Multiboot Transfer Protocol" in multiplay mode,
@ SWI 25h for the main block, then the result fetch-back and the same
@ hex-page viewer the payload shows.
@
@ Protocol as implemented (GBATEK table, master side, y = client_bit = 02):
@   S1  6200 -> 720x, 15 in a row; FFFF/other: wait 1/16 s and restart;
@       0000 ("slave entered mode") restarts the count without waiting
@   S2  6102 -> 720x
@   S3  0x60 header halfwords -> (60h-i)0x
@   S4  6200 -> 000x
@   S5  6202 -> 720x
@   S6  63pp until 73cc (pp = D1)  cc = client_data[1]; [2],[3] = SIOMULTI2/3
@   S7  64hh -> 73uu, hh = 11h + cc1 + cc2 + cc3
@   S8  SWI 25h, r0 = MultiBootParam, r1 = 1 (multiplay); 0 = ok
@ MultiBootParam (GBATEK "Multiboot Parameter Structure", 0x4C bytes):
@   14h handshake_data  19h client_data[3]  1Ch palette_data
@   1Eh client_bit  20h boot_srcp (image+0xC0)  24h boot_endp
@ Between transfers: wait for SIOCNT start clear, then ~36 us (GBATEK
@ "Multiboot Communication").
@
@ dingbat's HLE BIOS returns 1 from SWI 25h and its null SIO answers FFFF,
@ so in dingbat this ROM shows the menu and then "FAIL S1" after ~60 s.

.set IS_CHILD, 0
.include "mbprobe.inc"

.equ SIOCNT,    0x04000128
.equ SIOMULTI1, 0x04000122
.equ SIOMULTI2, 0x04000124
.equ SIOMULTI3, 0x04000126
.equ SIOMLT_SEND, 0x0400012A
.equ RCNT,      0x04000134
.equ PALETTE,   0xD1

    IMAGE_HEADER main

main:
    mov r0, #IOBASE
    add r0, r0, #0x208
    mov r1, #0
    strh r1, [r0]                  @ IME off
    ldr sp, =0x03007F00
    bl  vid_init
    bl  timer3_init
    bl  sio_parent_init
    mov r4, #0                     @ selected payload

@ ───────────────────────────── menu ─────────────────────────────────────
menu:
    bl  vid_init
    DRAW 1, 0, str_title
    DRAW 1, 7, str_link
    STATUS_MSG str_menu
    ldr r9, =0x3FF                 @ previous keys (all "held": wait for release)
menu_draw:
    mov r5, #0
1:  ldr r6, =payload_table
    add r6, r6, r5, lsl #4
    mov r0, #1
    add r1, r5, #2
    mov r2, #0x20
    cmp r5, r4
    moveq r2, #0x3E                @ '>'
    bl  draw_char
    mov r0, #3
    add r1, r5, #2
    ldr r2, [r6, #8]
    ldr r3, [r6, #12]
    bl  draw_str
    add r5, r5, #1
    cmp r5, #4
    bne 1b
menu_loop:
    bl  wait_vblank
    ldr r0, =SIOCNT                @ live SI / SD / ID so the cable end is visible
    ldrh r6, [r0]
    mov r0, #4
    mov r1, #7
    mov r2, r6, lsr #2
    and r2, r2, #1
    mov r3, #1
    bl  draw_hex
    mov r0, #9
    mov r1, #7
    mov r2, r6, lsr #3
    and r2, r2, #1
    mov r3, #1
    bl  draw_hex
    mov r0, #14
    mov r1, #7
    mov r2, r6, lsr #4
    and r2, r2, #3
    mov r3, #1
    bl  draw_hex
    bl  read_keys
    bic r1, r0, r9                 @ newly pressed
    mov r9, r0
    tst r1, #KEY_UP
    subne r4, r4, #1
    tst r1, #KEY_DOWN
    addne r4, r4, #1
    and r4, r4, #3
    tst r1, #(KEY_UP | KEY_DOWN)
    bne menu_draw
    tst r1, #KEY_A
    beq menu_loop

@ ───────────────────────────── send ─────────────────────────────────────
send:
    ldr r5, =payload_table
    add r5, r5, r4, lsl #4
    ldr r10, [r5]                  @ image start (its header is sent in S3)
    ldr r11, [r5, #4]              @ image end
    bl  sio_parent_init

    @ S1: recognition
    STATUS_MSG str_s1
    mov r6, #1
    mov r8, #0                     @ consecutive 720x
    ldr r9, =16*60                 @ ~60 s of restarts
s1: ldr r0, =0x6200
    bl  xfer
    mov r7, r0
    bl  is_720x
    cmp r0, #0
    beq 1f
    add r8, r8, #1
    cmp r8, #15
    blo s1
    b   s2
1:  mov r8, #0
    cmp r7, #0                     @ "slave entered correct mode now"
    beq s1
    ldr r0, =16384                 @ 1/16 s
    bl  delay
    bl  read_keys
    tst r0, #KEY_B
    bne abort
    subs r9, r9, #1
    bne s1
    b   fail

    @ S2: exchange master/slave info
s2: STATUS_MSG str_s2
    mov r6, #2
    ldr r0, =0x6102
    bl  xfer
    mov r7, r0
    bl  is_720x
    cmp r0, #0
    beq fail

    @ S3: header, 0x60 halfwords, replies count 60h..01h
    STATUS_MSG str_s3
    mov r6, #3
    mov r8, #0
s3: mov r0, r8, lsl #1
    ldrh r0, [r10, r0]
    bl  xfer
    mov r7, r0
    rsb r1, r8, #0x60
    cmp r1, r0, lsr #8
    bne fail
    tst r0, #2
    beq fail
    add r8, r8, #1
    cmp r8, #0x60
    bne s3

    @ S4: header done
    mov r6, #4
    ldr r0, =0x6200
    bl  xfer
    mov r7, r0
    cmp r0, #0x0002
    bne fail

    @ S5: info again
    mov r6, #5
    ldr r0, =0x6202
    bl  xfer
    mov r7, r0
    bl  is_720x
    cmp r0, #0
    beq fail

    @ S6: palette until 73cc
    STATUS_MSG str_s6
    mov r6, #6
    mov r8, #64
s6: ldr r0, =0x6300 | PALETTE
    bl  xfer
    mov r7, r0
    mov r1, r0, lsr #8
    cmp r1, #0x73
    beq 1f
    bl  is_720x
    cmp r0, #0
    beq fail
    ldr r0, =262                   @ 1 ms
    bl  delay
    subs r8, r8, #1
    bne s6
    b   fail
1:  ldr r1, =MBPARAM               @ zero the 0x4C-byte structure
    mov r2, #0
    mov r3, #0x4C / 4
2:  str r2, [r1], #4
    subs r3, r3, #1
    bne 2b
    ldr r1, =MBPARAM
    and r0, r7, #0xFF              @ client_data[1]
    strb r0, [r1, #0x19]
    mov r8, r0
    ldr r0, =SIOMULTI2
    ldrh r0, [r0]
    and r0, r0, #0xFF              @ client_data[2] (FF: no slave 2)
    strb r0, [r1, #0x1A]
    add r8, r8, r0
    ldr r0, =SIOMULTI3
    ldrh r0, [r0]
    and r0, r0, #0xFF
    strb r0, [r1, #0x1B]
    add r8, r8, r0
    add r8, r8, #0x11
    and r8, r8, #0xFF              @ handshake_data
    strb r8, [r1, #0x14]
    mov r0, #PALETTE
    strb r0, [r1, #0x1C]
    mov r0, #0x02                  @ client_bit: slave 1
    strb r0, [r1, #0x1E]
    add r0, r10, #0xC0
    str r0, [r1, #0x20]            @ boot_srcp
    str r11, [r1, #0x24]           @ boot_endp

    @ S7: handshake
    mov r6, #7
    orr r0, r8, #0x6400
    bl  xfer
    mov r7, r0
    mov r1, r0, lsr #8
    cmp r1, #0x73
    bne fail

    @ S8: SWI 25h
    STATUS_MSG str_s8
    mov r6, #8
    ldr r0, =MBPARAM
    mov r1, #1                     @ multiplay mode
    push {r4-r11}
    swi 0x250000
    pop {r4-r11}
    mov r7, r0
    cmp r0, #0
    bne fail

    @ fetch the slave's result: STATUS then 256 bytes
    STATUS_MSG str_wait
    bl  sio_parent_init
wait_slave:
    ldr r0, =SIO_REQ_STATUS
    bl  xfer
    ldr r1, =SIO_REQ_STATUS | 1
    cmp r0, r1
    beq fetch
    ldr r0, =1310                  @ 5 ms
    bl  delay
    bl  read_keys
    tst r0, #KEY_B
    bne abort
    b   wait_slave
fetch:
    STATUS_MSG str_fetch
    ldr r5, =RESULT
    mov r8, #0                     @ index
    mov r9, #0                     @ bytes that never echoed
1:  mov r10, #200
2:  orr r0, r8, #SIO_REQ_DATA
    bl  xfer
    cmp r8, r0, lsr #8
    beq 3f
    mov r0, #52                    @ 200 us
    bl  delay
    subs r10, r10, #1
    bne 2b
    mov r0, #0xEE
    add r9, r9, #1
3:  strb r0, [r5, r8]
    add r8, r8, #1
    cmp r8, #256
    bne 1b
    bl  vid_init
    ldr r5, =payload_table         @ title = payload name from its table entry
    add r5, r5, r4, lsl #4
    mov r0, #1
    mov r1, #0
    ldr r2, [r5, #8]
    ldr r3, [r5, #12]
    bl  draw_str
    cmp r9, #0
    ldreq r0, =str_ok
    moveq r1, #str_ok_len
    ldrne r0, =str_partial
    movne r1, #str_partial_len
    bl  draw_status
    mov r6, #0
4:  mov r0, r6
    bl  draw_page
5:  ldr r0, =(KEY_L | KEY_R | KEY_B)
    bl  wait_press
    tst r0, #KEY_B
    bne menu
    tst r0, #KEY_R
    addne r6, r6, #1
    tst r0, #KEY_L
    subne r6, r6, #1
    and r6, r6, #3
    b   4b

fail:                              @ r6 step, r7 last reply
    STATUS_MSG str_fail
    mov r0, #7
    mov r1, #9
    mov r2, r6
    mov r3, #1
    bl  draw_hex
    mov r0, #9
    mov r1, #9
    mov r2, r7
    mov r3, #4
    bl  draw_hex
    mov r0, #(KEY_A | KEY_B)
    bl  wait_press
    b   menu
abort:
    b   menu

@ ───────────────────────────── link (parent) ────────────────────────────
sio_parent_init:
    ldr r0, =RCNT
    mov r1, #0
    strh r1, [r0]
    ldr r0, =SIOCNT
    ldr r1, =0x2003                @ multiplay, 115200
    strh r1, [r0]
    bx  lr

xfer:                              @ r0 halfword -> r0 SIOMULTI1
    push {r4, lr}
    ldr r4, =SIOMLT_SEND
    strh r0, [r4]
    ldr r4, =SIOCNT
    ldrh r0, [r4]
    orr r0, r0, #0x80
    strh r0, [r4]
    ldr r1, =0x100000
1:  ldrh r0, [r4]
    tst r0, #0x80
    beq 2f
    subs r1, r1, #1
    bne 1b
2:  mov r0, #12                    @ >= 36 us
    bl  delay
    ldr r4, =SIOMULTI1
    ldrh r0, [r4]
    pop {r4, pc}

is_720x:                           @ r0 reply -> 1 if 72xx with bit 1 (slave 1)
    mov r1, r0, lsr #8
    cmp r1, #0x72
    movne r0, #0
    bxne lr
    tst r0, #2
    moveq r0, #0
    movne r0, #1
    bx  lr

DEFSTR str_title,   "MBPROBE SENDER"
DEFSTR str_link,    "SI=  SD=  ID="
DEFSTR str_menu,    "UP/DN PICK A SEND"
DEFSTR str_s1,      "S1 FIND SLAVE B=X"
DEFSTR str_s2,      "S2 INFO"
DEFSTR str_s3,      "S3 HEADER"
DEFSTR str_s6,      "S6 PALETTE"
DEFSTR str_s8,      "S8 SWI 25"
DEFSTR str_wait,    "SWI OK WAIT B=X"
DEFSTR str_fetch,   "FETCHING"
DEFSTR str_ok,      "OK L/R PAGE B=MENU"
DEFSTR str_partial, "GAPS=EE L/R B=MENU"
DEFSTR str_fail,    "FAIL S"
DEFSTR name_eeprom, "EEPROM SETTLE"
DEFSTR name_tilt,   "TILT STATUS"
DEFSTR name_gyro,   "GYRO EDGES"
DEFSTR name_mirror, "ROM MIRRORS"

    .ltorg
    .balign 4
payload_table:                     @ start, end, name, name length
    .word pl_eeprom, pl_eeprom_end, name_eeprom, name_eeprom_len
    .word pl_tilt,   pl_tilt_end,   name_tilt,   name_tilt_len
    .word pl_gyro,   pl_gyro_end,   name_gyro,   name_gyro_len
    .word pl_mirror, pl_mirror_end, name_mirror, name_mirror_len

    .include "mbcommon.inc"

    .balign 16
pl_eeprom:
    .incbin "build/payload_eeprom.mb"
pl_eeprom_end:
    .balign 16
pl_tilt:
    .incbin "build/payload_tilt.mb"
pl_tilt_end:
    .balign 16
pl_gyro:
    .incbin "build/payload_gyro.mb"
pl_gyro_end:
    .balign 16
pl_mirror:
    .incbin "build/payload_mirror.mb"
pl_mirror_end:
