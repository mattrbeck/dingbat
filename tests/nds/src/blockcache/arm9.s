@ The ARM9 half of tests/nds_blockcache_test.nim (position-independent).
@ clang -target armv5te-none-eabi -c arm9.s
.syntax unified
.arm
start:
  mov r0, #0
  ldr r1, data_at
  mov r3, #0
  mov r9, #0
  ldr r12, timer            @ timer 0 at the bus clock (read below)
  mov r11, #0x00800000
  str r11, [r12]
loop:
  add r0, r0, #1
  mov lr, pc
  b func
  ands r2, r0, #7
  ldreq r5, alt1
  ldrne r5, alt2
  str r5, patch           @ the next opcode: self-modifying
patch:
  add r3, r3, #1
  mul r6, r3, r0
  adds r7, r6, r3, lsl r2
  movs r8, r7, lsr #3
  addcs r9, r9, #1
  mrs r10, cpsr
  clz r11, r7
  cmp r0, #0x10000000
  blo loop
  b start
func:
  push {r4, lr}
  add r4, r0, r3
  str r4, [r1], #4
  ldr r12, timer
  add r4, r4, r0
  ldrh r4, [r12]
  str r4, [r1, #8]
  tst r1, #0x400
  subne r1, r1, #0x400
  adr r12, thumbf + 1
  blx r12
  ldmia sp, {r4, r12}
  pop {r4, pc}
.thumb
.align 2
thumbf:
  movs r4, #3
  muls r4, r0
  lsls r4, r4, #2
  adds r3, r3, r4
  ldr r4, [r1]
  str r4, [r1, #4]
  push {r0, lr}
  bl thumbg
  pop {r0, pc}
thumbg:
  adds r0, r0, #0
  beq 1f
  subs r4, r4, #1
1:
  bx lr
.arm
.align 2
alt1:
  add r3, r3, #1
alt2:
  ldr r3, [r1, #4]          @ another kind of opcode: a load
data_at:
  .word 0x02200000
timer:
  .word 0x04000100
