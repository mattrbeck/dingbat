#!/bin/sh
# Build armwrestler (ARM9 CPU test) and arm7wrestler (ARM7 CPU test) from
# their upstream assembly with plain binutils + mknds.py, no libnds.
#
#   build_wrestlers.sh [workdir]
#
# Fetches https://github.com/mic-/armwrestler and
# https://github.com/Arisotura/arm7wrestler into workdir (default: a temp dir)
# and writes roms/armwrestler.nds and roms/arm7wrestler.nds.
#
# armwrestler ships its own crt0 + linker script (ARM9 at 0x02004000) and
# builds as upstream's makeawds.bat does. arm7wrestler was written against an
# old libnds (crt0 + irqInit + VBlankIntrWait on the ARM9), so here:
#   - the ARM7 test gets a small crt0 that sets the IRQ/SVC/SYS stacks to the
#     BIOS defaults (GBATEK) and branches to the upstream `main`;
#   - the ARM9 side is replaced by an equivalent 20-line copier that polls
#     DISPSTAT for VBlank instead of needing interrupts, and copies the
#     ARM7's 256x192 BGR555 frame from main RAM 0x02700000 (a mirror of
#     0x02300000) to LCDC VRAM bank A each frame.
# The 8x8 font both tests .incbin is not in armwrestler's repository; the
# copy in arm7wrestler (same author's font) is used for both.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
if command -v arm-none-eabi-as >/dev/null 2>&1; then
  X=arm-none-eabi-
else
  X=/opt/devkitpro/devkitARM/bin/arm-none-eabi-
fi
w=${1:-$(mktemp -d)}
mkdir -p "$w"
cd "$w"

# The upstream sources trip many deprecation/UNPREDICTABLE warnings on
# purpose (they test exactly those encodings): show the log only on failure.
asm() {
  if ! ${X}as "$@" 2>"$w/as.log"; then cat "$w/as.log" >&2; return 1; fi
}

fetch() { # owner/repo dir
  [ -d "$2" ] && return 0
  mkdir -p "$2"
  curl -sfL "https://codeload.github.com/$1/tar.gz/HEAD" | tar xz -C "$2" --strip-components 1
}
fetch mic-/armwrestler armwrestler
fetch Arisotura/arm7wrestler arm7wrestler
font="$w/arm7wrestler/arm7/data"

# --- armwrestler: ARM9 runs the tests, draws into LCDC VRAM ---------------
a=armwrestler
asm -march=armv5te -I "$font" -o $a/awr9.o $a/armwrestler-ds.asm
asm -march=armv5te -mthumb -I "$font" -o $a/twr9.o $a/thumbwrestler-ds.asm
asm -march=armv5te -o $a/crt0.o $a/ds_arm9_crt0.S
${X}ld -T $a/ds_arm9.ld -e _start -o $a/arm9.elf $a/crt0.o $a/awr9.o $a/twr9.o
${X}objcopy -O binary $a/arm9.elf $a/arm9.bin
asm -march=armv4t -o $a/awr7.o $a/armwrestler-arm7.asm
${X}ld -Ttext=0x03800000 -e arm7_main -o $a/arm7.elf $a/awr7.o
${X}objcopy -O binary $a/arm7.elf $a/arm7.bin
python3 "$here/tools/mknds.py" -9 $a/arm9.bin -7 $a/arm7.bin --title ARMWRESTLER \
  --arm9-addr 0x02004000 --arm7-addr 0x03800000 -o "$here/roms/armwrestler.nds"

# --- arm7wrestler: ARM7 runs the tests, ARM9 only displays -----------------
b=arm7wrestler
cat > $b/show9.s <<'EOF'
	.arm
	.text
	.global _start
_start:	mov	r0, #0x04000000		@ IME = 0
	add	r0, r0, #0x208
	strh	r0, [r0]
	ldr	r0, =0x830F		@ POWCNT1: LCDs, 2D A+B, 3D, A on top
	ldr	r1, =0x04000304
	strh	r0, [r1]
	mov	r0, #0x80		@ VRAMCNT_A: LCDC at 0x06800000
	ldr	r1, =0x04000240
	strb	r0, [r1]
	mov	r0, #0x04000000		@ DISPCNT: VRAM display, bank A
	mov	r1, #0x00020000
	str	r1, [r0]
frame:	ldrh	r1, [r0, #4]		@ wait for DISPSTAT.0 to go 0 then 1
	tst	r1, #1
	bne	frame
1:	ldrh	r1, [r0, #4]
	tst	r1, #1
	beq	1b
	ldr	r1, =0x02700000
	ldr	r2, =0x06800000
	mov	r3, #256*192*2/16
2:	ldmia	r1!, {r4-r7}
	stmia	r2!, {r4-r7}
	subs	r3, r3, #1
	bne	2b
	b	frame
	.pool
EOF
cat > $b/crt7.s <<'EOF'
	.arm
	.text
	.global _start
_start:	mov	r0, #0xD2		@ IRQ mode, IRQ/FIQ masked
	msr	cpsr_c, r0
	ldr	sp, =0x0380FFB0
	mov	r0, #0xD3		@ SVC mode
	msr	cpsr_c, r0
	ldr	sp, =0x0380FFDC
	mov	r0, #0xDF		@ SYS mode
	msr	cpsr_c, r0
	ldr	sp, =0x0380FF00
	b	main
	.pool
EOF
asm -march=armv5te -o $b/show9.o $b/show9.s
${X}ld -Ttext=0x02000000 -e _start -o $b/arm9.elf $b/show9.o
${X}objcopy -O binary $b/arm9.elf $b/arm9.bin
# armv5te on purpose: the ARM7 test deliberately executes v5 opcodes (CLZ,
# QADD, SMLAxy, LDRD) to check that the ARM7 rejects or ignores them.
asm -march=armv5te -o $b/crt7.o $b/crt7.s
asm -march=armv5te -I "$font" -o $b/awr7.o $b/arm7/source/armwrestler-ds.s
asm -march=armv5te -mthumb -I "$font" -o $b/twr7.o $b/arm7/source/thumbwrestler-ds.s
${X}ld -Ttext=0x037F8000 -e _start -o $b/arm7.elf $b/crt7.o $b/awr7.o $b/twr7.o
${X}objcopy -O binary $b/arm7.elf $b/arm7.bin
python3 "$here/tools/mknds.py" -9 $b/arm9.bin -7 $b/arm7.bin --title ARM7WRESTLER \
  -o "$here/roms/arm7wrestler.nds"
