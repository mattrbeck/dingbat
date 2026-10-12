@ The ARM7 half of tests/nds_blockcache_test.nim (position-independent):
@ multiplies whose time depends on the operands, data in its WRAM and main
@ RAM, self-modifying code, and a word it rewrites in the ARM9's code
@ (`ext`, filled in by the test; 0 = none).
@ clang -target armv4t-none-eabi -c arm7.s
.syntax unified
.arm
start:
  mov r0, #1
  ldr r1, data_at
  mov r3, #0
  ldr r9, timer             @ timer 0 counting at the bus clock: its value
  mov r11, #0x00800000      @ read below depends on the exact clock
  str r11, [r9]
loop:
  add r0, r0, r0, lsl #3
  eor r0, r0, r0, lsr #7
  mul r6, r0, r3
  mla r7, r6, r0, r3
  umull r8, r9, r0, r7
  add r3, r3, #1
  ldr r4, [r1, r3, lsl #2]
  str r7, [r1, #0x40]
  ldr r12, timer
  add r11, r7, r3
  ldrh r11, [r12]
  str r11, [r1, #0x44]
  ands r2, r3, #15
  ldreq r5, alt1
  ldrne r5, alt2
  str r5, patch
patch:
  add r10, r10, #1
  ldr r12, ext
  cmp r12, #0
  beq 2f
  tst r3, #0x3F
  ldreq r5, alt3
  ldrne r5, alt4
  str r5, [r12]
2:
  ldr r12, data2
  str r3, [r12]
  ldr r11, [r12, #4]
  b loop
.align 2
alt1:
  add r10, r10, #1
alt2:
  ldr r10, [r1, #8]         @ another kind of opcode: a load
alt3:
  add r3, r3, #1
alt4:
  eor r3, r3, r0, lsr #3
data_at:
  .word 0x0380C000
data2:
  .word 0x02300000
ext:
  .word 0
timer:
  .word 0x04000100
