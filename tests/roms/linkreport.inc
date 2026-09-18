@ linkreport.inc — let a probe ROM send its results down the link cable
@ instead of being photographed off the screen.
@
@ Every probe here already ends with its observations in a block of memory
@ and a viewer that pages through them as hex. Transcribing those pages from
@ photographs is the slow, error-prone half of a hardware session. Include
@ this, call link_report_init once the block is filled, and call
@ link_report_poll from the viewer's own loop: the screen keeps working
@ exactly as before, and a host on the other end of the cable can read the
@ block out directly. tools/hwlink/gblink.py has the host side.
@
@ Nothing blocks. The console is the link's slave, so with no cable attached
@ no transfer ever completes and link_report_poll does nothing at all, which
@ is what keeps this safe to add to a ROM that is also run on its own.
@
@ The block is streamed in a loop as
@
@     'LRPT' | count | word 0 | word 1 | ... | word count-1 | 'LRPT' | ...
@
@ so a host can start listening at any moment, find the magic, and take the
@ count words that follow. That matters because the adapter drops a transfer
@ now and then; read the block twice and compare.
@
@ Needs: 12 bytes of scratch at lr_state, and the includer's own .align.

.equ LR_MAGIC,    0x4C525054       @ 'LRPT'
.equ LR_SIODATA32, 0x04000120
.equ LR_SIOCNT,    0x04000128
.equ LR_RCNT,      0x04000134

@ r0 = address of the result block, r1 = how many 32-bit words it holds
link_report_init:
    stmfd sp!, {r4, lr}
    ldr r4, =lr_state
    str r0, [r4, #0]               @ block
    str r1, [r4, #4]               @ count
    mov r0, #0
    str r0, [r4, #8]               @ position: 0 magic, 1 count, 2+ data
    ldr r1, =LR_RCNT               @ serial mode, chosen by SIOCNT
    strh r0, [r1]
    bl  lr_stage
    ldmfd sp!, {r4, pc}

@ Call once per viewer iteration. Cheap, and a no-op without a cable.
link_report_poll:
    stmfd sp!, {r4, lr}
    ldr r1, =LR_SIOCNT
    ldrh r0, [r1]
    tst r0, #0x80                  @ still waiting for the host's clock?
    bne 1f
    ldr r4, =lr_state
    ldr r0, [r4, #8]               @ that word went out: move on
    add r0, r0, #1
    ldr r1, [r4, #4]
    add r1, r1, #2                 @ magic and count precede the data
    cmp r0, r1
    movcs r0, #0
    str r0, [r4, #8]
    bl  lr_stage
1:  ldmfd sp!, {r4, pc}

@ Put the word for the current position in SIODATA32 and arm the port.
lr_stage:
    ldr r4, =lr_state
    ldr r0, [r4, #8]
    cmp r0, #0
    ldreq r1, =LR_MAGIC
    beq 2f
    cmp r0, #1
    ldreq r1, [r4, #4]
    beq 2f
    sub r0, r0, #2
    ldr r1, [r4, #0]
    ldr r1, [r1, r0, lsl #2]
2:  ldr r0, =LR_SIODATA32
    str r1, [r0]
    mov r1, #0x1000                @ 32-bit transfer, external clock (slave)
    orr r1, r1, #0x80              @ ready
    strh r1, [r0, #8]
    bx  lr

    .ltorg                         @ this file's own literals

    .align 2
lr_state:
    .word 0                        @ block address
    .word 0                        @ word count
    .word 0                        @ position in the stream
