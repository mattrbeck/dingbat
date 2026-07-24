# msrthumb.gba — what does an ARM7TDMI do when `MSR` writes the CPSR T bit?

A hardware probe for one specific unknown in the CPU core: an `MSR` that flips
CPSR.T while two instructions are already inside the pipeline. ARM calls this
UNPREDICTABLE, so every emulator has invented a model. This ROM measures what
the silicon actually does.

```
python3 tests/roms/msrthumb_build.py      # -> tests/roms/msrthumb.gba (32 KiB)
```

It boots on real hardware (valid Nintendo logo + header checksum), needs no
save media, takes no input, and prints its results on screen a few frames in.
Photograph the screen and read the table below.

## Why this matters

`MSR` cannot normally change execution state — that is what `BX` is for — but
at least one commercial game does it anyway. **Pokémon Pinball: Ruby & Sapphire**
(BPPE) ends its intro decompressor with:

```
086BC080: E129F002   msr  cpsr_fc, r2     ; r2 has mode=SYS and T set
086BC084: 00000000                        ; harmless if executed as Thumb
086BC088: E0A04700                        ; low halfword 0x4700 = Thumb `bx r0`
```

The ROM is authored precisely for a mid-pipeline state switch: the word after
the `msr` is inert, and the *low halfword* of the word after that is `bx r0`
into the freshly decompressed code. Under any model that discards those two
prefetched words the game boots into garbage. It works on hardware, so the
switch must honour something — the open question is exactly *what*.

## What the probe does

The `msr` sits at address **A**. When T flips, A+4 has already been decoded as
ARM and A+8 has already been fetched as an ARM word. The two payload words are
chosen so that every plausible reinterpretation leaves a different, harmless
fingerprint. (`msrthumb_build.py` disassembles both words under both decoders
on every build, so these claims are machine-checked, not asserted.)

| word | as ARM | as Thumb (low half) | as Thumb (high half) |
|---|---|---|---|
| `W1` = `0x35813404` at A+4 | `strcc r3,[r1,#0x404]` → writes `0xA5A5A5A5` to `0x02000404` | `add r4,#4` → R4=`04` | `add r5,#0x81` → R5=`81` |
| `W2` = `0x37813609` at A+8 | `strcc r3,[r1,r9,lsl #12]` (r9=0) → writes `0xA5A5A5A5` to `0x02000000` | `add r6,#9` → R6=`09` | `add r7,#0x81` → R7=`81` |

Carry is cleared before the `msr`, so the `cc` conditions are **true** — an
ARM-decoded slot really does store. R4–R7 start at zero. Whichever path is
taken, execution converges on a Thumb `b` at A+12; the ARM word containing that
branch is `cond=cs`, a no-op with carry clear, so an emulator that ignores the
T write entirely is *reported* rather than crashing the test.

## Reading the screen

```
P- MEM MSK R4 R5 R6 R7 F CYCL
P0 ROM 20  00 00 09 00 0 00EB
```

* **MEM** — where the probe ran: `ROM` (16-bit cart bus + prefetch), `IWR`
  (IWRAM, 32-bit bus), `EWR` (EWRAM). The pipeline fetch width differs between
  them, which is exactly the sort of thing that could change the answer.
* **MSK** — what the `msr` operand set: `20` = T only, `32` = T *and* a mode
  switch to IRQ (a real banked-register switch), `3F` = SYS+T, Pinball's own value.
* **R4 R5 R6 R7** — the marker registers, as above.
* **F** — flags: bit0 = W1 completed as an ARM instruction, bit1 = W2 completed
  as an ARM instruction, bit2 = the T write did not take effect at all.
* **CYCL** — timer ticks across the probe, including a constant harness
  overhead. Only compare rows that share the same MEM.
* `P6`/`P7` are the literal Pinball shape and print **BX OK** when the guest's
  own prefetched `bx r0` is honoured, **BX NO** otherwise.
* A row of `--` means that probe never completed. Rows are painted *before*
  each probe runs, so if the CPU wedges on some behaviour this test did not
  anticipate, the first `--` row names the probe that did it. `ALL PROBES
  COMPLETED` at the bottom means all eight returned.

### Signature → model

| R4 R5 R6 R7 | F | what the hardware did |
|---|---|---|
| `00 00 09 00` | 0 | A+4 slot killed; A+8 low half runs as Thumb; **A+10 skipped**, resume at A+12 — *the model mGBA and dingbat implement today* |
| `00 00 09 81` | 0 | A+4 slot killed; A+8 **and** A+10 both run as Thumb |
| `00 00 09 81` | 1 | A+4 completes as ARM (pipeline not flushed), then A+8 and A+10 as Thumb |
| `00 00 09 00` | 1 | A+4 completes as ARM, A+8 as Thumb, A+10 skipped |
| `04 81 09 81` | 0 | all four halfwords re-decoded as Thumb |
| `00 00 00 00` | 0 | pipeline fully flushed, refetched at A+12 |
| anything | 4 | the T write was ignored entirely |

## What the emulators say today

Measured with this ROM, 2026-07-24:

| emulator | P0–P5 | P6/P7 |
|---|---|---|
| dingbat | `00 00 09 00` F=0 | BX OK |
| mGBA 0.10.x | `00 00 09 00` F=0 | BX OK |
| NanoBoyAdvance | **SIGSEGV** | — |

dingbat and mGBA agree exactly (only the cycle column differs). That is not
independent confirmation: `arm.nim`'s handler was written *from* mGBA's, and
its comment claims the model is "mGBA-verified hardware" — mGBA-derived would
be the honest description. Nobody has checked it against silicon.

The specific thing nobody has checked is the **A+10 skip**. mGBA's `MSR`
handler sets `prefetch[0]` to a Thumb `nop`, `prefetch[1]` to the low halfword
of the word at PC, and advances PC by only 2 — which, worked through its
pipeline, means the halfword at A+10 is never executed. dingbat reproduces
that. It is invisible in Pokémon Pinball because the instruction at A+8 is a
branch, so A+10 would never have run anyway. If the hardware column comes back
`00 00 09 81`, both emulators are wrong in the same place and both need the
same one-line fix.

### NanoBoyAdvance

NBA has no model at all — `src/nba/src/arm/handlers/handler32.inl:217` carries
`// TODO: handle code that alters the Thumb-bit.` and writes the T bit straight
into `state.cpsr` without touching the pipeline. On the next step its `Run()`
sees `cpsr.f.thumb` set and dispatches the still-32-bit prefetched ARM word
through the Thumb table:

```cpp
(this->*s_opcode_lut_16[instruction >> 6])(instruction);   // arm7tdmi.hpp:73
```

`s_opcode_lut_16` is `std::array<Handler16, 1024>`, and `instruction >> 6` for
a full ARM word runs to 0x3FFFFFF — an out-of-bounds read followed by a call
through whatever member-function pointer it lands on. That is a
memory-safety bug reachable from ROM content, not just a wrong result. This ROM
is a 32 KiB reproducer for it (exit 139).

## Follow-ups this ROM does not cover

* **User mode.** A control-byte write from USR should be ignored, so T should
  not change. Not probed here: USR is a one-way door on this core without an
  exception to climb back out of, and the answer is well documented.
* **Regression test.** No CI guard is wired up on purpose — locking in the
  current signature would freeze a model that is still a guess. Once the
  hardware column exists, `--mode=screenshot` plus a framebuffer hash is the
  cheap way to pin it.
