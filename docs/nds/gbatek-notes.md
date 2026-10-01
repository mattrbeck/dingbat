# NDS hardware notes (from GBATEK), organised against the GBA core

Source: GBATEK single-page text (problemkaputt.de/gbatek.txt, fetched 2026-10-01),
NDS chapters plus the ARM CPU / CP15 / BIOS chapters. Everything here is GBATEK
unless tagged **[not GBATEK]**, which marks inference or general ARM
architecture knowledge that still has to be checked.

Conventions
- Hex is written `0x...`. "NDS9" = ARM9 side, "NDS7" = ARM7 side in DS mode.
- **Cycles are 33.513982 MHz bus cycles** unless marked otherwise. ARM9
  internal cycles are half cycles (66 MHz).
- Each subsystem is split into **SHARED** (same as GBA, the existing core
  applies), **CHANGED** (a GBA block with edits), and **NEW** (no GBA
  counterpart).
- DSi-only material is left out. Notes on DS-in-DSi-mode are left out too,
  except where a DS-mode game can see the difference.

---------------------------------------------------------------------------

## 0. Design-critical summary (read first)

1. There are two CPUs on one 33.51 MHz bus. The ARM9 core runs at 2x (67.03 MHz) but
   only TCM and cache hits reach that speed. Every bus access is in 33 MHz units,
   and ARM9 non-sequential accesses outside TCM/cache/main RAM pay **+3 cycles**.
   ARM9 opcode fetches are **always N32+3**, with no sequential fetch. The
   scheduler needs a 66 MHz (or half-cycle) timebase.
2. The ARM7 side is a 33 MHz ARM7TDMI. It runs GBA-style code with the same
   ISA, but its memory map and peripherals are new: no PPU, an SPI bus, an RTC,
   and a 16-channel sound unit.
3. VRAM is nine banks (A–I, 656 KB) mapped by `VRAMCNT_x` (MST/OFS). The 2D
   engines, the 3D texture unit, extended palettes and the ARM7 all see VRAM
   **through the bank mapping**. The PPU cannot index a flat array, so build
   per-region page tables at 16 KB granularity.
4. There are two 2D engines (A at `0x04000000`, B at `0x04001000`). Each is a
   GBA PPU with these edits: 256x192 output, 263 lines x 355 dots x 6 cycles,
   extended BG modes, 1D OBJ boundaries, bitmap OBJs, extended palettes, a fixed
   OBJ priority order, and master brightness. Engine A adds 3D-as-BG0, the large
   bitmap mode, VRAM/main-memory display and capture.
5. Byte writes to VRAM, palette and OAM are **ignored** on DS, unlike the GBA
   duplicate rule. The one exception is ARM7-mapped VRAM.
6. IRQ handler addresses are hardcoded in RAM: ARM9 at `[DTCM+0x3FFC]` with check
   flags at `[DTCM+0x3FF8]`, ARM7 at `[0x0380FFFC]` / `[0x0380FFF8]`. IE and IF are
   **32-bit**, and bits 16–24 are new.
7. ARM9 has no `HALTCNT`. It halts with `MCR p15,0,Rd,c7,c0,4`, which **hangs if
   IME=0**. ARM7 halts with `HALTCNT` (`0x4000301`, bits 6–7 = 2), as on the GBA.
8. ARM9 is ARMv5TE. It adds BLX, CLZ, Q-ops, DSP multiplies, LDRD/STRD, PLD and
   CP15. LDR/LDM/POP to PC **interwork** (bit 0 to T) unless CP15 control bit 15
   is set. MUL leaves C unchanged. A misaligned LDRH is force-aligned with no
   rotate. STM/LDM writeback rules change.
9. A direct boot copies the header to `0x27FFE00`. It copies the ARM9 and ARM7
   binaries per the header, writes the chip ID and user settings into
   `0x27FFxxx`, and sets the documented SP values, `POSTFLG=1`, `WRAMCNT=3`,
   CP15 and `SOUNDBIAS`. Games read the firmware (user settings, MAC) through the
   ARM7 SPI bus, so a synthetic firmware image with valid CRCs is needed.
10. Cart reads after boot are `B7aaaaaaaa000000` commands through `ROMCTRL`/`0x4100010`.
    KEY2 is decrypted in hardware, so an emulator can serve plaintext and ignore
    KEY2 entirely when it skips the BIOS cart boot.

---------------------------------------------------------------------------

## 1. CPUs and clocks

### 1.1 Clocks
| Item | Value |
|---|---|
| Bus clock | 33.513982 MHz (`0x1FF61FE` Hz). Measured closer to `0x1FF6231` |
| ARM7 | = bus clock (33.51 MHz). In GBA mode 16.76 MHz (bus/2) |
| ARM9 | 2x bus = 67.03 MHz, internal only (cache/TCM). External access at bus clock |
| Dot clock | bus/6 = 5.585664 MHz |
| Timers (both CPUs) | F = 33.513982 MHz (GBA: 16.78 MHz) |
| Sound | `SOUNDxTMR` counts at bus/2 (16.76 MHz): `timer = -(33513982/2)/freq` |
| Cart bus | `ROMCTRL.27`: 6.7 MHz (bus/5) or 4.2 MHz (bus/8) |

### 1.2 ARM7TDMI (NDS7). SHARED
- Identical core to the GBA (ARMv4T). No CP15, no cache, no TCM, no PU.
  Exception vectors at `0x00000000` (ARM7 BIOS).
- Misaligned LDRH and LDRSH behave as on the GBA (rotate / sign-byte quirks).

### 1.3 ARM946E-S (NDS9): ARMv5TE deltas versus ARMv4T

Main ID (`MRC p15,0,Rd,c0,c0,0`) = `0x41059461` (ARM, v5TE, part 946, rev 1).
Cache type = `0x0F0D2112`. TCM size = `0x00140180` (ITCM 32 KB, DTCM 16 KB).

**NEW instructions (encodings)**
| Instr | Encoding / semantics |
|---|---|
| BLX imm (ARM) | `cond=1111`, bits 27–25=`101`, bit 24=H: `PC=PC+8+imm24*4+H*2`, `LR=PC+4`, T=1 |
| BLX reg (ARM) | `cond 0001 0010 1111 1111 1111 0011 Rm`: `PC=Rm&~1`, T=`Rm.0`, `LR=PC+4` |
| BX (ARM) | unchanged (`...0001 Rm`). BXJ (`0010`) is v5TEJ only. On ARM9 treat as undefined or BX **[not GBATEK: the 946E-S has no J]** |
| BKPT (ARM) | `1110 0001 0010 imm12 0111 imm4`. Prefetch Abort vector, `R14_abt=PC+4` |
| CLZ | `cond 0001 0110 1111 Rd 1111 0001 Rm`. Rd=0..32, no flags. 1S |
| QADD/QSUB/QDADD/QDSUB | `cond 0001 0op0 Rn Rd 0000 0101 Rm`, op: 00=QADD, 01=QSUB, 10=QDADD, 11=QDSUB (bits 23–20 = 0000/0010/0100/0110). Saturate to s32 and set **CPSR.Q (bit 27)**. NZCV untouched. In QD*, `Rn*2` saturates first (and sets Q) |
| SMLAxy | MUL-space opcode bits 24–21=`1000`, bit 7=1, bit 4=0, bit 6=y (Rs top), bit 5=x (Rm top). `Rd=Rm.h*Rs.h+Rn`. Sets Q on 32-bit add overflow without saturating |
| SMLAWy / SMULWy | opcode `1001`. x bit (5)=0 → SMLAW (`Rd=(Rm*Rs.h)>>16+Rn`, Q on overflow), x=1 → SMULW (`Rd=(Rm*Rs.h)>>16`) |
| SMLALxy | opcode `1010`. `RdHiLo += Rm.h*Rs.h` (64-bit). Q never set |
| SMULxy | opcode `1011`. `Rd=Rm.h*Rs.h`. Halfword multiplies never touch NZCV |
| LDRD/STRD | halfword-transfer space, L=0, op (bits 6–5): 2=LDRD, 3=STRD. Rd must be even, pair is Rd,Rd+1. GBATEK says the address "must be 8-aligned" but on NDS align-4 works (forced align) |
| PLD | `1111 01 1 U 101 Rn 1111 offset` (= `LDRNVB R15`, P=1, W=0). Acts as a NOP |
| MCR/MRC p15 | `cond 1110 opc1 L Cn Rd 1111 opc2 1 Cm`. Only p15 is present. Other coprocessors, CDP/LDC/STC on p15, and MCR2/MRC2/LDC2/STC2/CDP2 (cond=1111) are undefined on NDS9. MRC with Rd=15 copies bits 31–28 into NZCV |
| MCRR/MRRC | v5TE encoding exists. No coprocessor uses it, so undefined in practice |
| Thumb BLX reg | THUMB.5 op=3 with MSBd=1: `0100 0111 1 Rs(4) 000`. `LR=PC+3` (Thumb bit set), T=`Rs.0`. R15 not allowed |
| Thumb BLX imm | 2nd half of BL pair `11101 off11` (off bit 0 must be 0): `PC=(LR+off*2)&~3`, `LR=next|1`, T=0 |
| Thumb BKPT | `1011 1110 imm8` |

**CHANGED behaviour (ARMv5 versus ARMv4T)**
| Area | ARMv4T (GBA/NDS7) | ARMv5TE (NDS9) |
|---|---|---|
| cond=`1111` | NV, never executes | "unconditional space": BLX imm, PLD, *2 coprocessor ops (undefined here). Everything else undefined **[not GBATEK: ARM ARM]** |
| LDR PC / LDM {..PC} / Thumb POP {PC} | T unchanged (POP ignores bit 0) | T = loaded bit 0 (interworking). Disabled when CP15 ctrl bit 15 ("Pre-ARMv5 mode") = 1 |
| ALU write to PC (MOV/ADD PC) | no interworking | still no interworking **[not GBATEK]** |
| MUL/MLA/MULL/MLAL with S | C destroyed (MULL: V destroyed?) | C and V unchanged. Only N and Z are set |
| Thumb MUL timing | 1S+mI (m=1..4) | 1S+3I fixed (always slow). No early-termination fast multiply at all on ARM9 |
| Misaligned LDRH | `[a-1] ROR 8` | `[a&~1]` forced align, no rotate |
| Misaligned LDRSH | behaves as LDRSB `[a]` | LDRSH `[a&~1]` |
| Misaligned LDR/SWP | rotate | rotate (unchanged) |
| STM with Rb in list + writeback | stores OLD base if Rb is first, else NEW | **always stores OLD base** |
| LDM with Rb in list + writeback | no writeback | ARM: writeback if Rb is the ONLY register or NOT the LAST. Thumb LDMIA: no writeback (as v4) |
| Empty rlist | loads/stores R15, Rb ±0x40 | R15 **not** transferred, Rb ±0x40 still applied |
| BKPT | undefined | Prefetch Abort |
| CPSR | bits 27..8 unused | bit 27 = Q (sticky saturation) |
| Exception base | `0x00000000` | CP15 ctrl bit 13: 0=`0x00000000`, 1=`0xFFFF0000` (NDS uses high vectors) |
| Data abort | n/a on GBA | PU violations raise Data/Prefetch Abort. ARM946E-S uses the "base restored" abort model (Rn restored) **[not GBATEK]**. Return with `SUBS PC,LR,#8` |
| Timing | GBA tables | `LDR`: 1S+1N+1L. `LDRB/LDRH/misaligned`: 1S+1N+2L. `STR`: 1S+1N. `Q*`, `SMULxy`, `SMLAxy`, `SMULW`, `SMLAW`: 1S+interlock. `SMLALxy`: 1S+1I+interlock. `CLZ`: 1S. Internal cycles are in 66 MHz units and may be skipped when the next op doesn't use the result |

The NDS9 IRQ handler at `[DTCM+0x3FFC]` may be ARM or Thumb (bit 0). The NDS7
handler must be ARM.

### 1.4 Exception vectors (both CPUs)
| Off | Exception | Mode | I/F |
|---|---|---|---|
| 0x00 | Reset | svc | I=1 F=1 |
| 0x04 | Undefined | und | I=1 |
| 0x08 | SWI | svc | I=1 |
| 0x0C | Prefetch abort / BKPT | abt | I=1 |
| 0x10 | Data abort | abt | I=1 |
| 0x18 | IRQ | irq | I=1 |
| 0x1C | FIQ | fiq | I=1 F=1 |

Base is `0xFFFF0000` on NDS9 (BIOS) and `0x00000000` on NDS7 (BIOS). The debug
handler pointer lives at `[0x27FFD9C]` (NDS9) and `[0x380FFDC]` (NDS7). Memory
below each pointer is the debug stack. The BIOS calls it for und, aborts, FIQ,
a jump to reset after POSTFLG, and unused SWIs 0..0x1F.

### 1.5 CP15 (NDS9 only)

Access: `MCR/MRC p15,0,Rd,Cn,Cm,op2` (opc1=0 except BIST/debug regs).

| Cn,Cm,op2 | Register | NDS notes |
|---|---|---|
| c0,c0,0 | Main ID | `0x41059461` |
| c0,c0,1 | Cache type | `0x0F0D2112` (I=8 KB, D=4 KB, 4-way, 32 B lines, type 7) |
| c0,c0,2 | TCM size | `0x00140180` |
| c0,c0,3..7 | mirror of c0,c0,0 | |
| c1,c0,0 | Control | see below |
| c2,c0,0 / c2,c0,1 | PU cachable bits, data / instr | bits 0–7 = region 0..7 |
| c3,c0,0 | PU write-bufferable (data) | bits 0–7. 0=write-through, 1=write-back |
| c5,c0,0 / c5,c0,1 | PU access perm data / instr (2 bits/region) | |
| c5,c0,2 / c5,c0,3 | PU extended AP data / instr (4 bits/region) | AP: 0=none, 1=priv RW, 2=priv RW + user R, 3=RW/RW, 5=priv R, 6=R/R |
| c6,c0..c7,0 (and op2=1 mirror) | PU region 0..7 | bit 0 enable, bits 1–5 X (size=2<<X, X=11 (4 KB)..31 (4 GB)), bits 12–31 base (size-aligned). Region 7 has highest priority. Background = no access. On NDS the `,1` registers mirror the `,0` ones (unified regions) |
| c7,cm,op2 | cache ops / halt (W) | see below |
| c9,c0,0 / c9,c0,1 | D/I cache lockdown (format B) | |
| c9,c1,0 | DTCM base/size | bits 1–5 N (size=512<<N, min N=3 (4 KB)), bits 12–31 base (size-aligned) |
| c9,c1,1 | ITCM base/size | same layout. **Base fixed 0** on NDS, size settable (mirrors) |
| c13,c0,0 | FCSE PID | read-only 0 on NDS |
| c13,c0,1 / c13,c1,1 | Trace process ID | R/W, no effect |
| opc1 0..3, c15 | BIST / cache debug | diagnostics only |

**Control register (c1,c0,0)**. On NDS bits 0, 2, 7 and 12–19 are R/W, bits 3–6
always read 1, and every other bit reads 0.
| Bit | Meaning |
|---|---|
| 0 | PU enable |
| 2 | D-cache enable |
| 3–6 | fixed 1 (write buffer, 32-bit exceptions, 32-bit addr, late abort) |
| 7 | Endian (big when set. Leave 0) |
| 12 | I-cache enable |
| 13 | Exception vectors: 0=`0x00000000`, 1=`0xFFFF0000` |
| 14 | Cache replacement: 0=pseudo-random, 1=round-robin |
| 15 | Pre-ARMv5 mode: 1 = LDM/LDR/POP PC do **not** interwork |
| 16 | DTCM enable |
| 17 | DTCM load mode (write-only) |
| 18 | ITCM enable |
| 19 | ITCM load mode (write-only. Doesn't apply to SWP) |

**c7 commands used on NDS9**
| c7,Cm,op2 | Op |
|---|---|
| c0,4 and c8,2 | Wait for interrupt (halt). Hangs if IME=0 per the BIOS note. Wakes when (IE&IF)≠0 |
| c5,0 / c5,1 | Invalidate whole I-cache / I-line (VA) |
| c6,0 / c6,1 | Invalidate whole D-cache / D-line (VA) |
| c10,1 / c10,2 | Clean D-line (VA / set-index) |
| c10,4 | Drain write buffer (listed "-" for ARM9 in GBATEK, but games issue it. Treat as a NOP) |
| c13,1 | Prefetch I-line |
| c14,1 / c14,2 | Clean+invalidate D-line |

**TCM.** ITCM is 32 KB at base 0, mirrored across the configured virtual
size (the firmware uses 32 MB, giving mirrors at `0..0x1FFFFFF`). DTCM is
16 KB and moveable. ITCM wins where the two overlap. TCM is CPU-only (DMA
cannot reach it) and is never cached. ITCM serves code and data. DTCM is
data-only, so opcode fetches from the DTCM range go to the bus. Load mode makes
TCM write-only so `LDR [x]; STR [x]` copies main RAM into TCM at the same
address.

**Recommended PU layout (GBATEK table, as register values computed here):**
| Rgn | Name | Base | Size | c6 value | Cache | WBuf | Code | Data |
|---|---|---|---|---|---|---|---|---|
| 0 | I/O + VRAM | `0x04000000` | 64 MB | `0x04000033` | - | - | RW | RW |
| 1 | Main RAM | `0x02000000` | 4 MB | `0x0200002B` | on | on | RW | RW |
| 2 | ARM7-dedicated | `0x027C0000` | 256 KB | `0x027C0023` | - | - | - | - |
| 3 | GBA slot | `0x08000000` | 128 MB | `0x08000035` | - | - | - | RW |
| 4 | DTCM | `0x027C0000` | 16 KB | `0x027C001B` | - | - | - | RW |
| 5 | ITCM | `0x01000000` | 32 KB | `0x0100001D` | - | - | RW | RW |
| 6 | BIOS | `0xFFFF0000` | 32 KB | `0xFFFF001D` | on | - | R | R |
| 7 | Shared work | `0x027FF000` | 4 KB | `0x027FF017` | - | - | - | RW |

**Cache.** 4-way set-associative, 32-byte lines, read-allocate. Write-through
or write-back is chosen per PU region, and lines can be locked down. For
emulation, functional correctness needs no cache model as long as DMA and CPU
writes stay coherent. Cost, though, does depend on hit or miss (see §3). A
cheap model is "a cached region costs 0.5 cycles per access" plus an optional
tag model later.

### 1.6 ARM9 bus timing quirks (affects the scheduler)
- ARM9 opcode fetches are always **N32 + 3 waits**. S32 doesn't exist for code.
  Thumb fetches two opcodes per 32-bit read, which also happens on 16-bit buses
  and after branches.
- ARM9 data: sequential is allowed, but every **non-sequential** access outside
  TCM/cache pays +3. `LDRH` on a 16-bit bus = N16+3. `LDR` = N16+S16+3.
  `LDM` = N16+(2n-1)·S16+3.
- The ARM9 has separate code and data buses. Cost can be `max(code,data)` when
  the two touch different regions and the op is LDR/LDRB/LDRH (not LDM, not
  ITCM data). DTCM and D-cache data can cost 0. Uncached main-RAM code plus
  other data costs ≈ code+data−2.
- Main RAM always carries the +3 non-sequential penalty, **including on ARM7**.
- The ARM9 can run in parallel with DMA only from TCM/cache. Any bus access
  stalls it until the DMA ends.

---------------------------------------------------------------------------

## 2. Memory maps

### 2.1 NDS9 map
| Range | Region | Bus | Notes |
|---|---|---|---|
| `0x00000000` (+mirrors to vsize) | ITCM 32 KB | internal | fixed base, CPU only |
| movable (default `0x027C0000`, BIOS SoftReset assumes `0x00800000`) | DTCM 16 KB | internal | data only |
| `0x02000000–0x02FFFFFF` | Main RAM 4 MB (mirrored. 8 MB on debug units) | 16-bit | |
| `0x03000000–0x03FFFFFF` | Shared WRAM 0/16/32 KB (mirrored) | 32-bit | `WRAMCNT`. With 0 KB the range is undefined on ARM9 |
| `0x04000000` | ARM9 I/O | 32-bit | undefined I/O reads 0 |
| `0x05000000` | Palette 2 KB (mirrored) | 16-bit | A-BG `+000`, A-OBJ `+200`, B-BG `+400`, B-OBJ `+600` |
| `0x06000000` | Engine A BG VRAM (max 512 KB) | 16-bit | via VRAMCNT |
| `0x06200000` | Engine B BG VRAM (max 128 KB) | 16-bit | |
| `0x06400000` | Engine A OBJ VRAM (max 256 KB) | 16-bit | |
| `0x06600000` | Engine B OBJ VRAM (max 128 KB) | 16-bit | |
| `0x06800000` | LCDC VRAM (max 656 KB) | 16-bit | plain CPU view |
| `0x07000000` | OAM 2 KB (mirrored) | 32-bit | A `+000`, B `+400` |
| `0x08000000` | GBA slot ROM (32 MB) | 16-bit | only if `EXMEMCNT.7=0` (ARM9) |
| `0x0A000000` | GBA slot SRAM (64 KB, repeats) | 8-bit | |
| `0xFFFF0000` | ARM9 BIOS (32 KB window, 3 KB used) | 32-bit | no read protection |

### 2.2 NDS7 map
| Range | Region | Notes |
|---|---|---|
| `0x00000000` | ARM7 BIOS 16 KB | `BIOSPROT` read protection |
| `0x02000000` | Main RAM 4 MB (shared with ARM9) | |
| `0x03000000–0x037FFFFF` | Shared WRAM 0/16/32 KB | with 0 KB this range **mirrors ARM7 WRAM** |
| `0x03800000–0x03FFFFFF` | ARM7 WRAM 64 KB (mirrored) | `0x37F8000` gives 32K shared + 64K private as one continuous 96 KB when `WRAMCNT=3` |
| `0x04000000` | ARM7 I/O | |
| `0x04800000` | Wifi WS0 (I/O + 8 KB wifi RAM at `0x4804000`) | |
| `0x04808000` | Wifi WS1 (mirror, other waitstates) | |
| `0x06000000` | VRAM C/D as ARM7 WRAM (max 256 KB) | MST=2. STRB works here only |
| `0x08000000` / `0x0A000000` | GBA slot ROM / SRAM | if `EXMEMCNT.7=1` |

**Mirroring rule:** a 16 MB block that holds a defined region mirrors that
region across the unused rest of the block. TCM and BIOS don't mirror. A
16 MB block with nothing defined in it is undefined.

**GBA slot open bus** (no cart): SRAM reads `0xFF`. ROM reads `addr/2` for
6/8-cycle settings, `addr/2 | 0xFE08`-ish for 10, and `0xFFFF` for 18. On the
**deselected CPU** the whole `0x08000000–0x0AFFFFFF` reads `0x00`. Digimon Story
Super Xros Wars depends on that.

### 2.3 EXMEMCNT `0x4000204` (NDS9 R/W) / EXMEMSTAT (NDS7, bits 7–15 R)
| Bit | Meaning |
|---|---|
| 0–1 | GBA slot SRAM time: 10, 8, 6, 18 cycles |
| 2–3 | GBA slot ROM 1st access: 10, 8, 6, 18 |
| 4 | GBA slot ROM 2nd access: 6, 4 |
| 5–6 | PHI out: low, 4.19, 8.38, 16.76 MHz |
| 7 | GBA slot owner: 0=ARM9, 1=ARM7 |
| 11 | NDS slot owner: 0=ARM9, 1=ARM7 (this gates `0x40001A0–0x40001BB` and `0x4100010`) |
| 13 | "always set" (RAM enable / CE2) |
| 14 | Main RAM interface: 1=synchronous (normal) |
| 15 | Main RAM priority: 0=ARM9, 1=ARM7 |

Bits 0–6 are per-CPU (each CPU keeps its own copy). Bits 7–15 are written by
ARM9 only and read by both.

### 2.4 WRAMCNT `0x4000247` (NDS9 W/R) / WRAMSTAT `0x4000241` (NDS7 R)
| Value | ARM9 sees | ARM7 sees |
|---|---|---|
| 0 | 32 KB (both halves) | none (mirrors ARM7 WRAM) |
| 1 | 2nd 16 KB | 1st 16 KB |
| 2 | 1st 16 KB | 2nd 16 KB |
| 3 | none (undefined) | 32 KB |
The allocated block mirrors through the whole window.

### 2.5 VRAM banks

`VRAMCNT_A..I` are at `0x4000240..0x4000246`, `0x4000248`, `0x4000249` (W, 8-bit;
`0x4000247` is WRAMCNT).
| Bit | Meaning |
|---|---|
| 0–2 | MST (bit 2 unused by A, B, H, I) |
| 3–4 | OFS 0–3 (unused by E, H, I) |
| 7 | Enable |

| Bank | Size | LCDC address (MST=0) |
|---|---|---|
| A | 128K | `0x6800000–0x681FFFF` |
| B | 128K | `0x6820000–0x683FFFF` |
| C | 128K | `0x6840000–0x685FFFF` |
| D | 128K | `0x6860000–0x687FFFF` |
| E | 64K | `0x6880000–0x688FFFF` |
| F | 16K | `0x6890000–0x6893FFF` |
| G | 16K | `0x6894000–0x6897FFF` |
| H | 32K | `0x6898000–0x689FFFF` |
| I | 16K | `0x68A0000–0x68A3FFF` |

**Full MST/OFS table**
| Target | Banks | MST | Address / slot |
|---|---|---|---|
| A BG VRAM (512K) | A, B, C, D | 1 | `0x6000000 + 0x20000*OFS` |
| | E | 1 | `0x6000000` |
| | F, G | 1 | `0x6000000 + 0x4000*OFS.0 + 0x10000*OFS.1` |
| A OBJ VRAM (256K) | A, B | 2 | `0x6400000 + 0x20000*OFS.0` (OFS.1 must be 0) |
| | E | 2 | `0x6400000` |
| | F, G | 2 | `0x6400000 + 0x4000*OFS.0 + 0x10000*OFS.1` |
| A BG ext palette | E | 4 | slots 0–3 (only lower 32K used) |
| | F, G | 4 | OFS=0: slots 0–1. OFS=1: slots 2–3 |
| A OBJ ext palette | F, G | 5 | slot 0 (lower 8K used) |
| 3D texture image (rear plane in slots 2–3) | A, B, C, D | 3 | texture slot OFS (each slot 128K) |
| 3D texture palette | E | 3 | tex-pal slots 0–3 (64K) |
| | F, G | 3 | tex-pal slot `OFS.0 + OFS.1*4` → 0, 1, 4, 5 (16K each) |
| B BG VRAM (128K) | C | 4 | `0x6200000` |
| | H | 1 | `0x6200000` |
| | I | 1 | `0x6208000` |
| B OBJ VRAM (128K) | D | 4 | `0x6600000` |
| | I | 2 | `0x6600000` |
| B BG ext palette | H | 2 | slots 0–3 |
| B OBJ ext palette | I | 3 | slot 0 (lower 8K) |
| ARM7 WRAM | C, D | 2 | `0x6000000 + 0x20000*OFS.0` (ARM7 address space) |

- In ext-palette and texture modes the bank is **not CPU-visible**. Software
  has to switch it to LCDC to fill it.
- `VRAMSTAT 0x4000240` (NDS7 R): bit 0 = C is mapped to ARM7, bit 1 = D is
  mapped to ARM7 (enable AND MST=2).
- Byte writes (STRB) to VRAM, palette and OAM are ignored on NDS9. On the ARM7
  WRAM mapping they work.
- Where two banks map to the same address, reads OR the banks together and
  writes go to both **[not GBATEK: widely reported, verify]**.
- Implementation: keep a page table at 16 KB granularity per address window
  (A-BG 32 pages, A-OBJ 16, B-BG 8, B-OBJ 8, LCDC 41, ARM7 16). The texture
  slots (4×128K), texture-palette slots (6×16K) and ext-palette slots (A-BG
  4×8K, A-OBJ 8K, B-BG 4×8K, B-OBJ 8K) are separate tables used by the renderer.
  Each entry is a list of banks to OR. Rebuild the table on any VRAMCNT write.

### 2.6 BIOS protection
- `BIOSPROT 0x4000308` (NDS7, 32-bit, write-once). The BIOS sets it to `0x1204`.
  Reads of `0..BIOSPROT-1` succeed only when the PC is below BIOSPROT. Reads of
  `BIOSPROT..0x3FFF` succeed only when the PC is inside the BIOS. Otherwise
  they read `0xFF`. The NDS9 BIOS is unprotected.
- NDS7 SWIs refuse BIOS source addresses in software (except GetCRC16).

### 2.7 Main RAM control
`0x27FFFFE` is the on-chip PSRAM control port (magic LDRH/STRH sequences). The
BIOS init writes `EXMEMCNT=0x2000`, then runs the magic sequence, then writes
`EXMEMCNT=0x6000`. An emulator can ignore it **[not GBATEK]**.

---------------------------------------------------------------------------

## 3. Memory timing (33 MHz cycles, cache/TCM off)

| Region | NDS7 code N32/S32/N16/S16 | NDS9 code N32/S32/N16/S16 | Bus width |
|---|---|---|---|
| Main RAM | 9 / 2 / 8 / 1 | 9 / 9 / 4.5 / 4.5 | 16 |
| WRAM, BIOS, I/O, OAM | 1 / 1 / 1 / 1 | 4 / 4 / 2 / 2 | 32 |
| VRAM, palette | 2 / 2 / 1 / 1 | 5 / 5 / 2.5 / 2.5 | 16 |
| GBA ROM (10,6) | 16 / 12 / 10 / 6 | 19 / 19 / 9.5 / 9.5 | 16 |
| TCM, cache hit | – | 0.5 | 32 |

| Region | NDS7 data N32/S32/N16/S16 | NDS9 data N32/S32/N16/S16 |
|---|---|---|
| Main RAM | 10 / 2 / 9 / 1 | 10 / 2 / 9 / 1 |
| WRAM, BIOS, I/O, OAM | 1 / 1 / 1 / 1 | 4 / 1 / 4 / 1 |
| VRAM, palette | 1? / 2 / 1 / 1 | 5 / 2 / 4 / 1 |
| GBA ROM (10,6) | 15 / 12 / 9 / 6 | 19 / 12 / 13 / 6 |
| GBA RAM (10) | 9 / 10 / 9 / 10 | 13 / 10 / 13 / 10 |
| TCM / D-cache hit | – | 0.5 |
| Cache miss | – | line fill: BIOS 11, main RAM 23 |

- 8-bit accesses cost the same as 16-bit.
- VRAM: the display reads VRAM once every 6 cycles, and a concurrent ARM9 VRAM
  access gets +1 wait. Forced blank (`DISPCNT.7`) removes the wait. Capture adds
  writes, so the rate becomes one access per 3 cycles. ARM7-mapped VRAM never
  waits.
- When both DMA source and destination are in main RAM, every access becomes
  non-sequential.
- `WIFIWAITCNT 0x4000206` (NDS7): WS0 N = 10/8/6/18 and S = 6/4; WS1 N =
  10/8/6/18 and S = 10/4. The firmware sets `0x0030`. The register is only
  reachable when `POWCNT2.1` is set.
- Main RAM priority is decided by `EXMEMCNT.15`. Contention between the CPUs is
  not documented in detail.

---------------------------------------------------------------------------

## 4. 2D display

### 4.1 Frame timing
| Item | Value |
|---|---|
| Visible | 256 x 192 |
| Dots per line | 355 (256 visible + 99 blank), 6 cycles each = **2130 cycles/line** |
| Lines | 263 (192 visible + 71 blank) |
| Frame | 263 × 2130 = 560190 cycles → 59.8261 Hz. Line rate 15.7343 kHz |
| VBlank flag | lines 192..261 (clear in line 262, as on the GBA) |
| HBlank flag | 0 for 1606 cycles on NDS9 (1613 on NDS7), then 1 until line end |
| 3D vblank | lines 191..213 (23 lines). Rendering starts at line 214 and keeps 48 lines buffered |
| Colour depth | LCD 18-bit. 2D is 15-bit, 3D is 18-bit, master brightness works in 6-bit |

### 4.2 Engines and power
| Region | Engine A | Engine B |
|---|---|---|
| I/O | `0x4000000` | `0x4001000` |
| Palette | `0x5000000` (1K) | `0x5000400` (1K) |
| BG VRAM | `0x6000000` (max 512K) | `0x6200000` (max 128K) |
| OBJ VRAM | `0x6400000` (max 256K) | `0x6600000` (max 128K) |
| OAM | `0x7000000` (1K) | `0x7000400` (1K) |
| Extras | 3D on BG0, large bitmap (mode 6), VRAM display, main-memory display, capture | – |

`DISPSTAT`/`VCOUNT` exist once, at `0x4000004`/`0x4000006`, shared by both
engines and readable from both CPUs. Engine B has no copies.
Engine B registers sit at A+0x1000: `0x4001008–0x400105F` and `0x400106C`.

**POWCNT1 `0x4000304`** (NDS9)
| Bit | Meaning |
|---|---|
| 0 | Both LCDs on |
| 1 | 2D engine A (ports 0x008–0x05F, palette 0x5000000) |
| 2 | 3D rendering engine (ports 0x320–0x3FF) |
| 3 | 3D geometry engine (ports 0x400–0x6FF) |
| 9 | 2D engine B (0x1008–0x105F, palette 0x5000400) |
| 15 | Display swap: 0 = engine A on lower screen, 1 = engine A on upper |

While a block is powered off its ports are read-only and its palette reads as
zero. Issue a SwapBuffers after enabling 3D.

### 4.3 DISPCNT `0x4000000` / `0x4001000`: CHANGED

| Bit | Engine | Meaning (GBA meaning in brackets) |
|---|---|---|
| 0–2 | A+B | BG mode 0–6 (0–5 on GBA) |
| 3 | A | BG0 2D/3D select (GBA: CGB mode) |
| 4 | A+B | Tile OBJ mapping 0=2D, 1=1D (GBA bit 6) |
| 5 | A+B | Bitmap OBJ 2D dimension: 0=128x512, 1=256x256 (GBA: HBlank free) |
| 6 | A+B | Bitmap OBJ mapping 0=2D, 1=1D |
| 7 | A+B | Forced blank (same) |
| 8–15 | A+B | BG0–3/OBJ enable, WIN0/WIN1/OBJWIN enable (same) |
| 16–17 | A+B | Display mode: 0=off (white), 1=normal, 2=VRAM display (A only), 3=main-memory display (A only). (GBA: green swap) |
| 18–19 | A | VRAM block A..D for display mode 2 and capture source B |
| 20–21 | A+B | Tile OBJ 1D boundary (32 << n bytes) |
| 22 | A | Bitmap OBJ 1D boundary (128 / 256 bytes) |
| 23 | A+B | OBJ processing during HBlank (moved from GBA bit 5) |
| 24–26 | A | Character base, 64K steps (added to BGxCNT's) |
| 27–29 | A | Screen base, 64K steps (added to BGxCNT's) |
| 30 | A+B | BG extended palettes enable |
| 31 | A+B | OBJ extended palettes enable |

SHARED: BG0–3 HOFS/VOFS, affine BG2/3 PA–PD/X/Y (`0x4000020–0x400003F`),
WIN0H/WIN1H/WIN0V/WIN1V/WININ/WINOUT, MOSAIC, BLDCNT/BLDALPHA/BLDY
(`0x4000050–0x4000054`). All are mirrored at +0x1000 for engine B.

### 4.4 DISPSTAT / VCOUNT: CHANGED
- `DISPSTAT` bits 0–5 are as on the GBA. **Bit 7 = LYC bit 8**. Bits 8–15 =
  LYC bits 0–7, so the compare range is 0..262.
- `VCOUNT` bits 0–8 = LY (0..262). VCOUNT is **writable** (link sync). Write it
  only while LY is in 202..212, and only with values in 202..212.
- Window glitch: WIN0V/WIN1V compare only the low 8 bits of LY. A Y1 of 0..6
  therefore triggers in lines 0x100..0x106 (inside VBlank), so the window is
  already active at line 0. For X, X1=0 means the left edge and X2=0 means 256.
  X1=X2=0 shows no window, so a window is at most 255 px wide.

### 4.5 BG modes: CHANGED/NEW
| Mode | BG0 | BG1 | BG2 | BG3 |
|---|---|---|---|---|
| 0 | Text/3D | Text | Text | Text |
| 1 | Text/3D | Text | Text | Affine |
| 2 | Text/3D | Text | Affine | Affine |
| 3 | Text/3D | Text | Text | Extended |
| 4 | Text/3D | Text | Affine | Extended |
| 5 | Text/3D | Text | Extended | Extended |
| 6 | 3D | – | Large bitmap | – |
| 7 | reserved | | | |

Engine B has no mode 6, and its BG0 is always text. GBA bitmap modes 3/4/5
don't exist as such. The "extended" BGs replace them.

**Extended BG sub-mode** (`BGxCNT.7`, `BGxCNT.2`)
| bit 7 | bit 2 | Mode |
|---|---|---|
| 0 | (char base LSB) | Affine "text-like": 16-bit map entries (tile 10b, H/V flip, pal 4b), 8bpp tiles, affine transform. The palette nibble selects the ext palette when DISPCNT.30 is set |
| 1 | 0 | Affine 256-colour bitmap |
| 1 | 1 | Affine direct-colour bitmap. **bit 15 = alpha (0 = transparent)** |

**Large bitmap (mode 6, BG2, engine A only):** affine 256-colour, uses all
512K of BG VRAM, and ignores the screen base.

**BGxCNT: CHANGED**
- Bits 2–5 = char base in 16K steps (was bits 2–3).
- Bit 13 on BG0/BG1 = ext palette slot (BG0: slot 0 or 2. BG1: slot 1 or 3).
- Bit 13 on BG2/BG3 = area overflow. It now **also applies to bitmap modes**.
- Engine A tile/map base = `BGxCNT_base + DISPCNT.24-26/27-29 * 64K`. Engine B
  has no DISPCNT term.
- Bitmap BGs use the screen base as `BGxCNT.8-12 * 16K` (no DISPCNT term).
  Mode 6 ignores the screen base.

| BGxCNT size | Text | Affine | Ext bitmap | Large bitmap |
|---|---|---|---|---|
| 0 | 256x256 | 128x128 | 128x128 | 512x1024 |
| 1 | 512x256 | 256x256 | 256x256 | 1024x512 |
| 2 | 256x512 | 512x512 | 512x256 | – |
| 3 | 512x512 | 1024x1024 | 512x512 | – |

Bitmaps larger than 128K are engine A only.

**3D as BG0** (`DISPCNT.3=1`, engine A):
- `BG0CNT.0-1` sets priority. All other BG0CNT bits are ignored (no mosaic).
- `BG0HOFS` scrolls the layer over 512 px (256 px of image, then 256
  transparent). There is no vertical scroll or affine transform.
- Blending: 3D as 2nd target uses EVA/EVB. 3D as 1st target uses the per-pixel
  3D alpha (EVA=a/2, EVB=16−a/2). Brightness works as usual.
- Windows apply. When 3D is the top layer, alpha blending may be forced
  (uncertain).

### 4.6 OBJs: CHANGED
- OAM is 1K per engine, with the same 128-entry, 8-byte format.
- **Priority fix:** OBJ-vs-OBJ order uses the 9-bit key (BG priority, OAM
  index). The GBA "priority bug" is gone.
- **Vertical wrap:** a sprite near the bottom shows at both the bottom and the
  top (the GBA wraps to the top only). GBA mode keeps the old behaviour.
- **Tile mapping** (`DISPCNT.4`, `20–21`)
  | bit 4 | 20–21 | Mapping | Boundary | Max |
  |---|---|---|---|---|
  | 0 | x | 2D | 32 B | 32K |
  | 1 | 0 | 1D | 32 | 32K |
  | 1 | 1 | 1D | 64 | 64K |
  | 1 | 2 | 1D | 128 | 128K |
  | 1 | 3 | 1D | 256 | 256K (B: 128K) |

  Tile address = `tileno * boundary`. Tiles are still 8x8.
- **Bitmap OBJ:** `attr0.10-11 = 3` (prohibited on the GBA). Pixels are 15-bit
  colour with bit 15 = alpha. Set `attr0.13` to 0. `attr2.12-15` = per-OBJ alpha
  (instead of palette).
  | bit 6 | bit 5 | bit 22 | Mapping | Boundary | Max |
  |---|---|---|---|---|---|
  | 0 | 0 | x | 2D, 128 px wide | 8x8 | 128K |
  | 0 | 1 | x | 2D, 256 px wide | 8x8 | 128K |
  | 1 | 0 | 0 | 1D | 128 B | 128K |
  | 1 | 0 | 1 | 1D | 256 B | 256K (A only) |
  | 1 | 1 | x | reserved | | |

  1D address = `tileno(0..0x3FF) * boundary`. 2D address =
  `(tileno & maskX)*0x10 + (tileno & ~maskX)*0x80`, where maskX = 0x0F (128 px)
  or 0x1F (256 px).

### 4.7 Extended palettes: NEW
- BG (`DISPCNT.30`): four slots of 8K, each 16 palettes x 256 colours. BG0..3
  use slots 0..3 by default. BG0 and BG1 can be moved to slots 2/3 with
  `BGxCNT.13`. The ext palette applies to 256-colour **text** tiles and to
  16-bit-entry affine BGs (palette taken from the map entry). The standard
  palette is still used for 16-colour tiles, 8-bit-entry affine, 256-colour
  bitmaps, and the backdrop (colour 0 of BG palette 0).
- OBJ (`DISPCNT.31`): 16 palettes x 256 colours in 8K (VRAM F/G/I, lower 8K).
  256-colour OBJs then use the palette number from `attr2.12-15`.
- Ext palette memory is only visible to the renderer (see VRAM table).
  Colour 0 is transparent.

### 4.8 Master brightness `0x400006C` / `0x400106C`: NEW
| Bit | Meaning |
|---|---|
| 0–4 | Factor 0..16 (>16 = 16) |
| 14–15 | Mode: 0=off, 1=up, 2=down, 3=reserved |

Up: `c = c + (63−c)·f/16`. Down: `c = c − c·f/16`, on 6-bit channels.
It applies after everything, including display modes 2 and 3.

### 4.9 Capture and main-memory display: NEW (engine A)
**DISPCAPCNT `0x4000064`** (32-bit R/W)
| Bit | Meaning |
|---|---|
| 0–4 | EVA 0..16 |
| 8–12 | EVB 0..16 |
| 16–17 | Write VRAM block A..D (must be LCDC-mapped) |
| 18–19 | Write offset ×0x8000 |
| 20–21 | Size: 128x128, 256x64, 256x128, 256x192 |
| 24 | Source A: 0 = BG+3D+OBJ composite, 1 = 3D only |
| 25 | Source B: 0 = VRAM (block from DISPCNT.18–19), 1 = main-memory FIFO |
| 26–27 | Read offset ×0x8000 (ignored in VRAM display mode) |
| 29–30 | Source select: 0=A, 1=B, 2/3 = A·EVA + B·EVB blended |
| 31 | Enable/busy. Starts at the next line 0, auto-clears at line 192 |

- Offsets wrap within 128K. Output is 15-bit plus alpha bit 15.
- Blend: `I = (Ia·αa·EVA + Ib·αb·EVB)/16`. `α = (αa & EVA>0) | (αb & EVB>0)`.
- Captures smaller than full size take the top-left region.

**DISP_MMEM_FIFO `0x4000068`** (W): feed with DMA mode 4 (main-memory
display), 32-bit units, count 4, destination fixed at this port, source in main
RAM. Each transfer moves 8 pixels (15-bit). It starts at the next frame.

### 4.10 Output path (block diagram summary)
- Engine A + 3D → layering/effects → (display mode 1). The output feeds capture
  source A.
- VRAM display (mode 2), main-memory FIFO (mode 3) and capture source B are
  all A-side inputs.
- Engine A → master bright A → screen chosen by `POWCNT1.15`. Engine B → master
  bright B → the other screen.
- Engine A's BG/OBJ draw from banks A–G. Engine B's draw from C, D, H, I.

---------------------------------------------------------------------------

## 5. 3D engine: NEW (shape-level)

### 5.1 Structure
- **Geometry engine:** a command FIFO (256 entries) plus a PIPE (4 entries).
  Each entry is 40 bits (8-bit command + 32-bit parameter). It holds matrix
  state and lighting, and writes Polygon RAM and Vertex RAM.
- **Double-buffered Polygon/Vertex RAM:** max **2048 polygons** (104K) and
  **6144 vertices** (144K) per buffer.
- `SWAP_BUFFERS` waits for the next VBlank (line 192), then swaps. The
  geometry engine stalls until then.
- **Rendering engine:** scanline-based with a 48-line cache. Rendering starts at
  line 214 and outputs from line 263/0 on. The texture VRAM slots must stay
  mapped while it renders. The render control registers (`0x4000060`,
  `0x4000330–0x40003BF`) are **not** double-buffered.
- Module shape: `GxFifo` → `GeometryEngine` (matrices, stacks, lighting,
  clipping, viewport transform) → `PolyRam[2]` → `Rasterizer` (per frame or
  per line, z/w-buffer, textures from the VRAM slot tables, toon, edge, fog,
  AA, alpha) → 256x192 18-bit + alpha line buffer → engine A BG0 and capture.

### 5.2 I/O map
| Addr | Size | Name |
|---|---|---|
| `0x4000060` | 2 | DISP3DCNT |
| `0x4000320` | 1 | RDLINES_COUNT (R): min buffered lines−2 in the previous frame |
| `0x4000330` | 0x10 | EDGE_COLOR 0..7 |
| `0x4000340` | 1 | ALPHA_TEST_REF (0..31) |
| `0x4000350` | 4 | CLEAR_COLOR (RGB5, bit 15 fog, bits 16–20 alpha, bits 24–29 poly ID) |
| `0x4000354` | 2 | CLEAR_DEPTH |
| `0x4000356` | 2 | CLRIMAGE_OFFSET (rear-plane bitmap scroll) |
| `0x4000358` | 4 | FOG_COLOR |
| `0x400035C` | 2 | FOG_OFFSET |
| `0x4000360` | 0x20 | FOG_TABLE (32) |
| `0x4000380` | 0x40 | TOON_TABLE (32 colours) |
| `0x4000400` | 0x40 | GXFIFO (W, mirrored ×16 words for STM/STRD) |
| `0x4000440–0x40005CC` | | command ports |
| `0x4000600` | 4 | GXSTAT |
| `0x4000604` | 4 | RAM_COUNT: polys bits 0–11, verts bits 16–28 |
| `0x4000610` | 2 | DISP_1DOT_DEPTH (not FIFO'd, takes effect at once) |
| `0x4000620` | 0x10 | POS_RESULT |
| `0x4000630` | 6 | VEC_RESULT |
| `0x4000640` | 0x40 | CLIPMTX_RESULT (4x4) |
| `0x4000680` | 0x24 | VECMTX_RESULT (3x3) |

### 5.3 Commands (port, ID, params, cycles)
| Port | ID | P | Cyc | Command |
|---|---|---|---|---|
| – | 00 | 0 | – | NOP (padding in packed form) |
| 440 | 10 | 1 | 1 | MTX_MODE (0=proj, 1=pos, 2=pos+vec, 3=texture) |
| 444 | 11 | 0 | 17 | MTX_PUSH |
| 448 | 12 | 1 | 36 | MTX_POP (signed 6-bit offset) |
| 44C | 13 | 1 | 17 | MTX_STORE (index 0..30) |
| 450 | 14 | 1 | 36 | MTX_RESTORE |
| 454 | 15 | 0 | 19 | MTX_IDENTITY |
| 458 | 16 | 16 | 34 | MTX_LOAD_4x4 |
| 45C | 17 | 12 | 30 | MTX_LOAD_4x3 |
| 460 | 18 | 16 | 35* | MTX_MULT_4x4 |
| 464 | 19 | 12 | 31* | MTX_MULT_4x3 |
| 468 | 1A | 9 | 28* | MTX_MULT_3x3 |
| 46C | 1B | 3 | 22 | MTX_SCALE (position matrix only, even in mode 2) |
| 470 | 1C | 3 | 22* | MTX_TRANS |
| 480 | 20 | 1 | 1 | COLOR |
| 484 | 21 | 1 | 9–12 | NORMAL |
| 488 | 22 | 1 | 1 | TEXCOORD (s,t: 1.11.4) |
| 48C | 23 | 2 | 9 | VTX_16 |
| 490 | 24 | 1 | 8 | VTX_10 |
| 494/498/49C | 25/26/27 | 1 | 8 | VTX_XY / XZ / YZ |
| 4A0 | 28 | 1 | 8 | VTX_DIFF |
| 4A4 | 29 | 1 | 1 | POLYGON_ATTR (latched at BEGIN_VTXS) |
| 4A8 | 2A | 1 | 1 | TEXIMAGE_PARAM |
| 4AC | 2B | 1 | 1 | PLTT_BASE |
| 4C0 | 30 | 1 | 4 | DIF_AMB |
| 4C4 | 31 | 1 | 4 | SPE_EMI |
| 4C8 | 32 | 1 | 6 | LIGHT_VECTOR |
| 4CC | 33 | 1 | 1 | LIGHT_COLOR |
| 4D0 | 34 | 32 | 32 | SHININESS |
| 500 | 40 | 1 | 1 | BEGIN_VTXS (0=tri, 1=quad, 2=tri strip, 3=quad strip) |
| 504 | 41 | 0 | 1 | END_VTXS (no-op) |
| 540 | 50 | 1 | 392 | SWAP_BUFFERS (bit 0: manual translucent sort, bit 1: W-buffer). Waits for VBlank, then 392 cycles |
| 580 | 60 | 1 | 1 | VIEWPORT (x1, y1, x2, y2 bytes. y origin at the bottom) |
| 5C0 | 70 | 3 | 103 | BOX_TEST |
| 5C4 | 71 | 2 | 9 | POS_TEST |
| 5C8 | 72 | 1 | 5 | VEC_TEST |

\* +30 cycles in MTX_MODE 2. Invalid IDs are ignored and take no parameters.

**FIFO rules**
- A packed command word holds up to 4 command IDs (LSB first). Their
  parameters follow in order. The last non-zero command in a word must take
  parameters.
- Writing to a command port pushes command + parameter. A command with no
  parameters needs one dummy write.
- A full FIFO **stalls the writing CPU and the bus** (DMA and ARM7 too).
- DMA mode 7 (GX FIFO) fires while the FIFO is less than half full and
  transfers **112 words** per burst.
- The PIPE fills directly while the FIFO is empty. When the PIPE drops below 3
  entries, 2 move over from the FIFO.

**GXSTAT `0x4000600`**
| Bit | Meaning |
|---|---|
| 0 | Test busy |
| 1 | BoxTest result |
| 8–12 | Position/vector stack level |
| 13 | Projection stack level |
| 14 | Matrix stack busy |
| 15 | Stack overflow/underflow error (write 1 to ack; also resets the projection SP) |
| 16–24 | FIFO count (0..256) |
| 25 | Less than half full |
| 26 | Empty |
| 27 | Geometry busy |
| 30–31 | FIFO IRQ: 0=never, 1=less than half full, 2=empty |

The FIFO IRQ (`IF.21`) is **level-triggered**: IF stays set while the
condition holds.

**Matrix stacks**
| Stack | Entries | SP width |
|---|---|---|
| Projection | 1 | 1 bit |
| Position + vector | 31 (32nd entry exists but flags an error) | 6 bits (GXSTAT shows 5) |
| Texture | 1 | 1 bit |

The upper half of each stack mirrors the lower half. In mode 1 the push, pop,
store and restore commands act on both the position and vector stacks.
`ClipMatrix = Position × Projection` is recomputed whenever either changes.
Fixed point is 20.12.

**Other key formats**
- **DISP3DCNT `0x4000060`:**
  | Bit | Meaning |
  |---|---|
  | 0 | Texture |
  | 1 | Toon (0) / highlight (1) |
  | 2 | Alpha test |
  | 3 | Alpha blend |
  | 4 | Anti-aliasing |
  | 5 | Edge marking |
  | 6 | Fog alpha-only |
  | 7 | Fog enable |
  | 8–11 | Fog shift |
  | 12 | RDLINES underflow (write 1 to ack) |
  | 13 | Poly/vertex RAM overflow (write 1 to ack) |
  | 14 | Rear plane is a bitmap (texture slots 2/3) |
- **POLYGON_ATTR:**
  | Bit | Meaning |
  |---|---|
  | 0–3 | Lights |
  | 4–5 | Mode (modulate, decal, toon/highlight, shadow) |
  | 6 | Back face |
  | 7 | Front face |
  | 11 | Translucent depth update |
  | 12 | Far-plane clip vs hide |
  | 13 | 1-dot polygons |
  | 14 | Depth test equal (±0x200 tolerance) |
  | 15 | Fog |
  | 16–20 | Alpha (0 = wireframe) |
  | 24–29 | Polygon ID |
- **TEXIMAGE_PARAM:**
  | Bit | Meaning |
  |---|---|
  | 0–15 | VRAM offset/8 |
  | 16–17 | Repeat S/T |
  | 18–19 | Flip S/T |
  | 20–22 | S size (8<<n) |
  | 23–25 | T size (8<<n) |
  | 26–28 | Format: 0 none, 1 A3I5, 2 4-col, 3 16-col, 4 256-col, 5 4x4 compressed, 6 A5I3, 7 direct |
  | 29 | Colour 0 transparent |
  | 30–31 | Texcoord transform mode |
- **PLTT_BASE:** bits 0–12, in 16-byte units (8-byte units for the 4-colour
  format).
- **COLOR:** 5-bit to 6-bit expansion is `x*2+(x+31)/32`.
- An incomplete polygon list at SwapBuffers locks up the 3D hardware
  permanently.

---------------------------------------------------------------------------

## 6. IPC: NEW

**IPCSYNC `0x4000180`** (both CPUs)
| Bit | Dir | Meaning |
|---|---|---|
| 0–3 | R | Remote CPU's bits 8–11 |
| 8–11 | R/W | Output to the remote CPU |
| 13 | W | Send IRQ to the remote CPU (sets its IF.16 if its bit 14 is set) |
| 14 | R/W | Enable IRQ from the remote CPU |

**IPCFIFOCNT `0x4000184`**
| Bit | Dir | Meaning |
|---|---|---|
| 0 | R | Send FIFO empty |
| 1 | R | Send FIFO full |
| 2 | R/W | Send-empty IRQ enable |
| 3 | W | Clear send FIFO |
| 8 | R | Recv FIFO empty |
| 9 | R | Recv FIFO full |
| 10 | R/W | Recv-not-empty IRQ enable |
| 14 | R/W | Error: read while empty or write while full (write 1 to ack) |
| 15 | R/W | FIFO enable |

**IPCFIFOSEND `0x4000188`** (W) and **IPCFIFORECV `0x4100000`** (R): 16 words
each direction. One CPU's send FIFO is the other CPU's receive FIFO.
- With the FIFO disabled, sends are dropped without setting the error bit, and
  reads return the oldest word without popping it.
- Reading while empty returns the last word received (or 0 after a clear) and
  sets the error bit.
- The FIFO IRQs are **edge-triggered**:
  - IF.17 rises on the 0→1 edge of `(cnt.2 & send-empty)`.
  - IF.18 rises on the 0→1 edge of `(cnt.10 & !recv-empty)`.

  Enabling the IRQ while the condition already holds also gives an edge.
- Neither CPU sees waitstates on these registers.

---------------------------------------------------------------------------

## 7. Interrupts: CHANGED

| Reg | Addr | Width | Note |
|---|---|---|---|
| IME | `0x4000208` | bit 0 | same as GBA |
| IE | `0x4000210` | **32-bit** | GBA: 16-bit at 0x200 |
| IF | `0x4000214` | **32-bit** (write 1 to ack) | GBA: 0x202 |

| Bit | Source | CPU |
|---|---|---|
| 0–6 | VBlank, HBlank, VCount, Timer 0..3 | both |
| 7 | SIO/RCNT/RTC | NDS7 only |
| 8–11 | DMA 0..3 | both |
| 12 | Keypad | both |
| 13 | GBA slot (external) | both |
| 16 | IPC sync | both |
| 17 | IPC send FIFO empty | both |
| 18 | IPC recv FIFO not empty | both |
| 19 | NDS slot transfer complete | both (whichever owns the slot) |
| 20 | NDS slot IREQ_MC | both |
| 21 | Geometry FIFO | NDS9 |
| 22 | Screens unfolding (hinge) | NDS7 |
| 23 | SPI bus | NDS7 |
| 24 | Wifi | NDS7 |

**BIOS IRQ dispatch** (the HLE stub must reproduce it):
- ARM9: IRQ vector `0xFFFF0018`. Handler pointer at `[DTCM+0x3FFC]`, which may
  be Thumb.
- ARM7: IRQ vector `0x00000018`. Handler pointer at `[0x380FFFC]` (as
  `0x3FFFFFC` via the mirror). ARM only.
- The stub saves {r0–r3, r12, lr}, calls the handler with `LR` set to the
  return stub, restores, and returns with `SUBS PC,LR,#4`. The ARM9 stub finds
  DTCM through CP15 c9,c1,0 **[not GBATEK]**.
- `IntrWait` and `VBlankIntrWait` poll the check flags at `[DTCM+0x3FF8]` (ARM9)
  or `[0x380FFF8]` (ARM7). These are 32-bit, where the GBA's
  `[0x3007FF8]` is 16-bit. User handlers must OR the acknowledged bits in.

---------------------------------------------------------------------------

## 8. Timers, DMA, maths

### 8.1 Timers: SHARED
Same registers as the GBA (`0x4000100–0x400010F`, TMxCNT_L/H, prescaler
F/1, F/64, F/256, F/1024, count-up, IRQ) on both CPUs, but F = 33.513982 MHz.
They no longer drive sound (DS channels have their own timers).

### 8.2 DMA: CHANGED
Registers are as on the GBA (`0x40000B0+12*n`: SAD, DAD, CNT 32-bit), and
**all of them are R/W** (write-only on the GBA). The GBA gamepak-DRQ bit 27
(CNT_H.11) is gone.

**NDS9 DMA**
- Word count is 21 bits (1..0x1FFFFF, 0 = 0x200000). SAD and DAD span
  `0..0x0FFFFFFE` on every channel.
- Start mode is `CNT bits 27–29`:
  | Mode | Start |
  |---|---|
  | 0 | Immediate |
  | 1 | VBlank |
  | 2 | HBlank (not during VBlank) |
  | 3 | Start of display (sync to line start) |
  | 4 | Main-memory display FIFO |
  | 5 | DS cart slot (`0x4100010` word ready) |
  | 6 | GBA cart slot |
  | 7 | Geometry FIFO (fires while half empty, 112 words per burst) |
- **DMAxFILL `0x40000E0/E4/E8/EC`** (NDS9 only, R/W): 4 words of plain storage,
  used as a fixed source for memfill since DMA can't read TCM.
- DMA can't reach ITCM or DTCM. Software must drain or clean the caches around
  DMA. The ARM9 keeps running during DMA only while it stays inside TCM/cache.

**NDS7 DMA**
- GBA limits on count (0x4000, or 0x10000 for DMA3) and addresses (some
  channels limited to `0x07FFFFFE`).
- Start mode is `CNT bits 28–29`:
  | Mode | Start |
  |---|---|
  | 0 | Immediate |
  | 1 | VBlank |
  | 2 | DS cart slot |
  | 3 | DMA0/2: wifi. DMA1/3: GBA slot |
- There is no HBlank DMA on ARM7 and no FIFO sound DMA (sound channels fetch on
  their own).

Priority is DMA0 highest, as on the GBA. Channel enable, repeat and reload
semantics are the same.

### 8.3 Maths unit (NDS9): NEW
**DIVCNT `0x4000280`**
| Bit | Meaning |
|---|---|
| 0–1 | Mode (see table) |
| 14 | Div by zero: set when the **full 64-bit** DENOM is 0 |
| 15 | Busy |

| Mode | Operation | Cycles |
|---|---|---|
| 0 | 32/32 → 32, 32 | 18 |
| 1 (and 3) | 64/32 → 64, 32 | 34 |
| 2 | 64/64 → 64, 64 | 34 |

| Addr | Register |
|---|---|
| `0x4000290` | DIV_NUMER (64-bit signed) |
| `0x4000298` | DIV_DENOM |
| `0x40002A0` | DIV_RESULT (R, sign-extended to 64) |
| `0x40002A8` | DIVREM_RESULT (R) |

- A write to DIVCNT, NUMER or DENOM starts a new division.
- Divide by zero: remainder = numer, result = ±1 with the sign opposite to
  numer.
- `−MAX/−1` returns −MAX.
- In mode 0, an overflow (div0 or −MAX/−1) **inverts the upper 32 bits** of the
  sign-extended result.

**SQRTCNT `0x40002B0`**
| Bit | Meaning |
|---|---|
| 0 | 0 = 32-bit input, 1 = 64-bit input |
| 15 | Busy, 13 cycles |

`SQRT_RESULT 0x40002B4` (u32). `SQRT_PARAM 0x40002B8` (u64). A write to
SQRTCNT or PARAM starts a new root.

Both units count in 33 MHz cycles. The BIOS Div/Sqrt SWIs don't use this
hardware (they are pure software).

---------------------------------------------------------------------------

## 9. Keys

- **SHARED:** KEYINPUT `0x4000130` and KEYCNT `0x4000132` exist on both CPUs
  (A, B, Select, Start, D-pad, R, L, active low), each with its own keypad IRQ.
- **NEW:** EXTKEYIN `0x4000136` (NDS7, R)
  | Bit | Meaning |
  |---|---|
  | 0 | X (0 = pressed) |
  | 1 | Y |
  | 3 | Debug button |
  | 6 | Pen down (0 = touching. /PENIRQ from the TSC) |
  | 7 | Hinge (1 = closed) |
  | 2, 4, 5 | read 1 |
  | 8–15 | read 0 |
- X and Y raise no IRQ. The hinge raises IF.22 (NDS7) and can't be disabled at
  the source. Set RCNT `0x4000134` to `0x80xx` (general-purpose mode) before
  reading EXTKEYIN or the RTC.
- Touch coordinates are read over SPI from the TSC (§10.2), not from a
  register.

---------------------------------------------------------------------------

## 10. ARM7-side peripherals

### 10.1 SPI bus: NEW
**SPICNT `0x40001C0`**
| Bit | Meaning |
|---|---|
| 0–1 | Baud: 4 MHz, 2 MHz, 1 MHz, 512 kHz |
| 7 | Busy |
| 8–9 | Device: 0 = power manager, 1 = firmware flash, 2 = touchscreen |
| 10 | 16-bit mode (bugged) |
| 11 | Chip-select hold |
| 14 | IRQ enable (IF.23 on completion) |
| 15 | Enable |

**SPIDATA `0x40001C2`**: bits 0–7. A write starts the transfer, and the reply
is read back after busy clears. The transfer takes 8 bits at the chosen baud
(4 MHz ≈ 8×8.4 = 67 cycles) **[derived]**. Chip select drops after a transfer
that has hold=0.

**Firmware flash** (256 KB, ST M45PE20). Commands, MSB first:
| Cmd | Name | Notes |
|---|---|---|
| 06 | WREN | |
| 04 | WRDI | |
| 9F | RDID | `20 40 12` |
| 05 | RDSR | bit 0 WIP, bit 1 WEL |
| 03 | READ | 3-byte address, then data streams |
| 0B | FAST READ | address + dummy byte |
| 0A | Page write | |
| 02 | Page program | |
| DB | Page erase | |
| D8 | Sector erase | |
| B9 / AB | Deep power-down / release | |

| Range | Contents |
|---|---|
| `0x00000–0x00029` | Header |
| `0x0002A–0x001FF` | Wifi calibration |
| `0x00200–0x3F9FF` | Firmware code/data |
| `0x3FA00–0x3FCFF` | Wifi access points 1–3 |
| `0x3FE00` / `0x3FF00` | User settings 0 and 1 |

Firmware header fields: `[0x08]` ID "MAC"+n, `[0x1D]` console type (`0xFF`=DS,
`0x20`=Lite), `[0x20]` user settings offset/8, `[0x36]` wifi MAC (6 bytes).

**User settings** (0x100 bytes each; the first 0x70 are copied to RAM `0x27FFC80`)
| Off | Size | Field |
|---|---|---|
| 0x00 | 2 | Version = 5 |
| 0x02 | 1 | Favourite colour |
| 0x03/0x04 | 1+1 | Birthday month/day |
| 0x06 | 20 | Nickname (UTF-16) |
| 0x1A | 2 | Nickname length |
| 0x1C | 52 | Message |
| 0x50 | 2 | Message length |
| 0x52 | 2 | Alarm hour/minute |
| 0x58 | 4 | Touch cal adc x1,y1 (12-bit) |
| 0x5C | 2 | scr x1,y1 (8-bit) |
| 0x5E | 4 | adc x2,y2 |
| 0x62 | 2 | scr x2,y2 |
| 0x64 | 2 | Language bits 0–2 (0=JP, 1=EN, ...), bit 3 GBA screen, bits 4–5 backlight, bit 6 autostart, bits 9–15 "settings ok" flags |
| 0x66 | 1 | Year |
| 0x68 | 4 | RTC offset |
| 0x70 | 2 | Update counter (0..0x7F) |
| 0x72 | 2 | CRC16 (initial 0xFFFF) over 0x00..0x6F |

The newer area is the one whose count equals `(other+1)&0x7F`.

**TSC (touchscreen controller, TSC2046)**
- Control byte (MSB first): bit 7 start, bits 4–6 channel, bit 3 8-bit mode,
  bit 2 single-ended, bits 0–1 power-down.
- Channels: 1 = Y, 5 = X, 3/4 = Z1/Z2, 6 = AUX (microphone), 0/7 = temperature,
  2 = battery (reads 0).
- The reply is 1 dummy bit plus 12 bits, MSB first, spread over the next 2 SPI
  bytes.
- Released: X reads 0, Y reads 0xFFF.
- Screen position = `(adc−adc1)*(scr2−scr1)/(adc2−adc1) + (scr1−1)`, using the
  firmware calibration.

**Power manager**
- The index byte has bit 7 = read and bits 0–6 = register.
- Reg 0: bit 0 sound amp, bit 1 mute, bit 2 lower backlight, bit 3 upper
  backlight, bits 4–5 LED, bit 6 **shut down**.
- Reg 1: battery low. Reg 2: mic amp enable. Reg 3: mic gain.
- Reg 4 (Lite): backlight level and external power.
- On the original DS, registers 4..0x7F mirror 0..3.

### 10.2 RTC `0x4000138` (NDS7, 8-bit GPIO): CHANGED from GBA cart RTC
- The chip is a Seiko S-35180, the same family as the GBA cart RTC (S-3511),
  bit-banged over 3 wires.
- Port bits: 0 data I/O, 1 SCK, 2 CS, 4/5/6 = direction for 0/1/2.
- Commands are `0110 ccc r` sent LSB first, where ccc selects:
  | ccc | Register | Bytes |
  |---|---|---|
  | 0 | Stat1 | 1 |
  | 4 | Stat2 | 1 |
  | 2 | Date+time | 7 |
  | 6 | Time | 3 |
  | 1 | INT1 alarm/freq | |
  | 5 | INT2 alarm | |
  | 3 | Clock adjust | |
  | 7 | Free register | |
- Data is BCD, year 2000..2099.
- Stat1: bit 0 reset, bit 1 24-hour mode, bits 4/5 INT flags, bit 6 power-low,
  bit 7 power-off.
- The RTC's /INT is wired to SIO SI. It raises IF.7 when `RCNT=0x8144`/`0x8100`.
- dingbat's `gba/rtc.nim` + `rtc_calendar.nim` (S-3511 protocol) is close. The
  differences are the register set (stat2, alarms) and the GPIO bit layout.

### 10.3 Sound (NDS7, `0x4000400–0x400051F`): NEW (no GBA reuse except mixer plumbing)
16 channels × 16 bytes at `0x4000400 + 0x10*n`:
| Off | Reg | Bits |
|---|---|---|
| +0 | SOUNDxCNT | 0–6 vol mul, 8–9 vol div (÷1, 2, 4, 16), 15 hold, 16–22 pan (0..127, 64 = centre), 24–26 PSG duty, 27–28 repeat (0=manual, 1=loop, 2=one-shot), 29–30 format (0=PCM8, 1=PCM16, 2=IMA-ADPCM, 3=PSG/noise), 31 start/busy |
| +4 | SOUNDxSAD | bits 0–26, word-aligned |
| +8 | SOUNDxTMR | 16-bit. Sample rate = 16.756991 MHz / (0x10000−tmr) |
| +A | SOUNDxPNT | loop start, in words |
| +C | SOUNDxLEN | bits 0–21, words. PNT+LEN must be at least 4 words or the channel hangs |

Rules:
- PSG square on channels 8–13: duty (n+1)/8, starting LOW, frequency = rate/8.
- Noise on channels 14–15: `X>>=1; if carry {out=LOW; X^=0x6000} else out=HIGH`,
  with X=0x7FFF at start.
- Start latency after the start bit: PSG 1 sample, PCM 3 samples, ADPCM 11
  samples.
- ADPCM: a 32-bit header (PCM16 initial value + index 0..88), then 4-bit
  nibbles, low nibble first. A loop restores the predictor/index saved at the
  loop point.
- One-shot clears busy at the start of the last sample.

Control registers:
| Addr | Reg | Bits |
|---|---|---|
| `0x4000500` | SOUNDCNT | 0–6 master vol, 8–9 L source (mixer/ch1/ch3/ch1+3), 10–11 R source, 12 ch1 not to mixer, 13 ch3 not to mixer, 15 master enable |
| `0x4000504` | SOUNDBIAS | 0–9, normally 0x200. Bias always applies |
| `0x4000508` / `0x4000509` | SNDCAP0CNT / SNDCAP1CNT | bit 0 add ch1→ch0 (ch3→ch2), bit 1 source (mixer / ch0 or ch2), bit 2 one-shot, bit 3 PCM8, bit 7 start |
| `0x4000510` / `0x4000518` | SNDCAPxDAD | capture destination |
| `0x4000514` / `0x400051C` | SNDCAPxLEN | 16-bit, words |

- Capture runs on the timer of channel 1 or 3.
- Mixer: about 1.05 MHz internally, 24-bit. Output is PWM at 32.768 kHz,
  10-bit, clipped to 0..0x3FF after the bias.
- Volume: `N = reg` for 0..126 and 128 for 127. `vol = data*N/128`. Pan L
  `(128−N)/128`, R `N/128`. Master `N/128/64`.
- A full integer pipeline table is in GBATEK under "DS Sound Notes".

### 10.4 Power and misc control
**POWCNT2 `0x4000304`** (NDS7): bit 0 speakers (initially 1), bit 1 wifi
(initially 0; gates `0x4000206` and `0x4800000–0x480FFFF`).

**HALTCNT `0x4000301`** (NDS7, 8-bit): bits 6–7 = 0 none, 1 GBA mode, 2 halt,
3 sleep. Halt waits for (IE & IF) ≠ 0 and **ignores IME**.
- The GBA used bit 7 alone (0x00 = halt, 0x80 = stop).
- On DS, CustomHalt values are 0x80 = halt and 0xC0 = sleep.

**POSTFLG `0x4000300`**: bit 0 is set after boot and can't be cleared again.
- NDS9: bit 1 is plain R/W.
- NDS7: writable only from BIOS code.
- NDS games misbehave when it is 0.

**Wifi** (addresses only): WS0 `0x4800000–0x4807FFF` (I/O registers +
8 KB RAM at `0x4804000`), WS1 `0x4808000–0x480FFFF` (mirror). Wifi IRQ is IF.24.
DMA0/2 mode 3 is the wifi DMA. Stub it: games probe the chip ID at
`0x4808000`, and the firmware writes the configuration. A full model is out of
scope.

**SIO** (NDS7): the GBA SIO registers exist (`0x4000120–0x400012A`, RCNT
`0x4000134`) with no connector. RCNT bits act as GPIO. SI carries the RTC
interrupt.

---------------------------------------------------------------------------

## 11. Cartridge (NDS slot): NEW

### 11.1 Header (`0x000–0x16F` is loaded to `0x27FFE00`)
| Off | Size | Field |
|---|---|---|
| 0x000 | 12 | Title |
| 0x00C | 4 | Gamecode |
| 0x010 | 2 | Maker |
| 0x012 | 1 | Unit code (0 = NDS) |
| 0x013 | 1 | KEY2 seed select (0..7) |
| 0x014 | 1 | Chip size = 128 KB << n |
| 0x01E | 1 | ROM version |
| 0x01F | 1 | Autostart |
| **0x020** | 4 | **ARM9 ROM offset** (≥ 0x4000, 0x1000-aligned) |
| **0x024** | 4 | **ARM9 entry** (0x2000000..0x23BFE00) |
| **0x028** | 4 | **ARM9 RAM address** |
| **0x02C** | 4 | **ARM9 size** (max 0x3BFE00) |
| **0x030** | 4 | **ARM7 ROM offset** (≥ 0x8000) |
| **0x034** | 4 | **ARM7 entry** (0x2000000..0x23BFE00 or 0x37F8000..0x3807E00) |
| **0x038** | 4 | **ARM7 RAM address** |
| **0x03C** | 4 | **ARM7 size** (max 0x3BFE00, or 0xFE00 when loading to WRAM) |
| 0x040/0x044 | 4+4 | FNT offset/size |
| 0x048/0x04C | 4+4 | FAT offset/size |
| 0x050/0x054 | 4+4 | ARM9 overlay table |
| 0x058/0x05C | 4+4 | ARM7 overlay table |
| 0x060 | 4 | ROMCTRL for normal commands (usually 0x00586000) |
| 0x064 | 4 | ROMCTRL for KEY1 commands (0x001808F8) |
| 0x068 | 4 | Icon/title offset |
| 0x06C | 2 | Secure area CRC16 over ROM `[hdr.020]..0x7FFF` |
| 0x06E | 2 | Secure area delay (131 kHz units) |
| 0x070/0x074 | 4+4 | ARM9/ARM7 autoload hook |
| 0x078 | 8 | Secure area disable |
| 0x080 | 4 | Used ROM size |
| 0x084 | 4 | Header size (0x4000) |
| 0x0C0 | 0x9C | Nintendo logo |
| 0x15C | 2 | Logo CRC = 0xCF56 |
| 0x15E | 2 | Header CRC16 over 0x000–0x15D |
| 0x160–0x16B | | Debug ROM offset/size/RAM address |

CRC16 is the BIOS GetCRC16 algorithm with initial 0xFFFF (§12.4).

### 11.2 Secure area
- The secure area is ROM `0x4000–0x7FFF`, present when the ARM9 ROM offset is
  below 0x8000. Its first 2 KB are additionally KEY1-encrypted.
- The first 8 bytes, once decrypted, read "encryObj". The BIOS replaces them
  with `0xE7FFDEFF 0xE7FFDEFF`. With a bad ID it fills the whole 2 KB with
  `0xE7FFDEFF`.
- Direct boot needs a **decrypted** dump, as most dumps are. If the first 8
  bytes read "encryObj", replace them with `E7FFDEFF E7FFDEFF`.
- An encrypted dump needs KEY1 (Blowfish), whose 0x1048-byte P/S table comes
  from ARM7 BIOS `0x30–0x1077`.
- Retail carts can't read ROM `0x1000–0x3FFF`.

### 11.3 Registers (owner set by `EXMEMCNT.11`)
**AUXSPICNT `0x40001A0`**
| Bit | Meaning |
|---|---|
| 0–1 | SPI baud (4 MHz, 2, 1, 0.5) |
| 6 | SPI chip-select hold |
| 7 | SPI busy |
| 13 | Slot mode: 0 = ROM, 1 = backup SPI |
| 14 | Transfer-ready IRQ enable (IF.19) |
| 15 | Slot enable |

`AUXSPIDATA 0x40001A2`: 8-bit. A write starts the transfer.

**ROMCTRL `0x40001A4`**
| Bit | Meaning |
|---|---|
| 0–12 | KEY1 gap1 |
| 13 | KEY2 data |
| 14 | "SE" |
| 15 | Apply seed (W) |
| 16–21 | Gap2 |
| 22 | KEY2 command |
| 23 | **Data word ready (DRQ)** |
| 24–26 | Block size: 0 = none, 1..6 = 0x100<<n, 7 = 4 bytes |
| 27 | CLK: 0 = bus/5, 1 = bus/8 |
| 28 | Gap clocks |
| 29 | Release reset (set once) |
| 30 | Write direction |
| 31 | Start/busy |

**Command `0x40001A8–0x40001AF`**: 8 bytes, with the **first byte sent at the
lowest address** (MSB first).

**Data `0x4100010`**: 32-bit read. Read it when bit 23 is set, or use DMA
(source fixed, count 1, 32-bit, repeat, mode 5 on ARM9 or 2 on ARM7).
IF.19 is raised at the end of a block.

KEY2 seed registers: `0x40001B0/B4` (low 32 bits) and `0x40001B8/BA` (high
7 bits).

Transfer timing **[derived]**: per byte 5 or 8 cycles (bit 27). Gap1 clocks
come before the first data, gap2 clocks after each 0x200 bytes. DRQ is raised
every 4 bytes.

### 11.4 Protocol (what the emulator must answer)
| Command | Phase | Reply |
|---|---|---|
| `9F00000000000000` | raw | dummy (0xFF) |
| `0000000000000000` | raw | header (0x200, repeats) |
| `9000000000000000` | raw | chip ID (4 bytes, repeats) |
| `3C...` | raw | enter KEY1 mode |
| `4.../1.../2.../6.../A...` | KEY1 | KEY2 on, chip ID, secure block (4 KB, 0x910 dummy bytes first), KEY2 off, enter main mode |
| `B7aaaaaaaa000000` | KEY2 | **data read** (0x200 by default) |
| `B800000000000000` | KEY2 | chip ID |

- Chip ID examples:
  | ID | Cart |
  |---|---|
  | `C2 0F 00 00` | 16 MB Macronix |
  | `C2 1F 00 00` | 32 MB |
  | `C2 3F 00 00` | 64 MB |
  | `C2 7F 00 80` | 128 MB, new protocol |

  Bit 31 set means the newer protocol variant. Byte 1 is `(size_MB−1)` for
  sizes up to 128 MB. The BIOS stores the ID at `0x27FF800`/`0x27FFC00`, and
  games compare B8 against it as an anti-piracy check.
- B7 rules:
  - Reads below 0x8000 redirect to `0x8000 + (addr & 0x1FF)`.
  - A read wraps inside its 4 KB block.
  - Addresses beyond the ROM mirror back into it, and some games test this.
- KEY2 is a 39-bit LFSR pair XORed onto the stream:
  - Seed0 = `mmmnnn<<15 + 0x6000 + seedbyte[hdr.13]`. Seed1 = `0x5C879B9B05`.
  - Each step: `x = (((x>>5)^(x>>17)^(x>>18)^(x>>31))&0xFF) + (x<<8)`.
    y follows the same form with taps 5, 23, 18, 31.
  - `data ^= x^y`.
  - The hardware decrypts on both ends, so the CPU never sees ciphertext. An
    emulator can ignore KEY2.
- KEY1 (Blowfish keyed by the gamecode) only matters for real-BIOS boot and
  encrypted secure areas.

### 11.5 Backup (AUXSPI, mode bit 13 = 1)
| Type | Sizes | Commands |
|---|---|---|
| EEPROM 0.5K | 0.5K | `03`/`0B` read lo/hi, `02`/`0A` write lo/hi, 1-byte address |
| EEPROM / FRAM | 8K–64K | `03`/`02` with 2-byte address |
| EEPROM | 128K | 3-byte address |
| FLASH | 256K–1M | Flash command set (see firmware above), 3-byte address, `0A` write, `D8`/`DB` erase |

All types share `05` RDSR, `01` WRSR, `06` WREN, `04` WRDI, and `9F` RDID
(FLASH only; others read FF).

Type and size are not in the header. Detect them from access patterns (bytes
sent after CS for the address width) or use a game database. GBATEK notes
quirky titles: Over the Hedge, and Rune Factory, which should be forced to
64 KB.

---------------------------------------------------------------------------

## 12. Boot

### 12.1 Real boot outline
1. The ARM7 BIOS reads the cart header (raw), runs the KEY1 handshake and
   loads the secure area.
2. The firmware (from SPI flash, decrypted with KEY1 using "MACP" and LZ77) runs
   the menu and loads the ARM9 and ARM7 binaries through B7 commands.
3. Both CPUs jump to their entry points.

### 12.2 Direct boot checklist (skip BIOS + firmware)
**Memory**
| Action | Detail |
|---|---|
| Copy ARM9 binary | `ROM[hdr.020 .. +hdr.02C]` → `hdr.028`, then fix the secure-area ID (§11.2) |
| Copy ARM7 binary | `ROM[hdr.030 .. +hdr.03C]` → `hdr.038` (main RAM or `0x37F8000`) |
| `0x27FFE00..0x27FFF6F` | Header bytes `0x000..0x16F` |
| `0x27FF800` / `0x27FFC00` | Chip ID 1 |
| `0x27FF804` / `0x27FFC04` | Chip ID 2 (same value) |
| `0x27FF808` / `0x27FFC08` | Header CRC (`hdr.15E`) |
| `0x27FF80A` / `0x27FFC0A` | Secure CRC (`hdr.06C`) |
| `0x27FF80C`, `0x27FF80E` | 0 (CRC okay, secure okay) |
| `0x27FF810` | 0xFFFF (boot task) |
| `0x27FF850` / `0x27FFC10` | 0x5835 (NDS7 BIOS CRC) |
| `0x27FF880` | 7 |
| `0x27FF884` | 6 (boot handshake values) |
| `0x27FF864` | 0 |
| `0x27FF868` | firmware user-settings address (`fw[0x20]*8`, e.g. 0x3FE00) |
| `0x27FFC30..0x27FFC3B` | GBA cart header bytes (0xFF.. if no cart) |
| `0x27FFC3C` | frame counter (any value) |
| `0x27FFC40` | **1** (boot indicator; some games require it) |
| `0x27FFC80..0x27FFCEF` | user settings (0x70 bytes, newest copy) |
| `0x380F980` | 0xFBDD37BB (odd but documented) |
| Everything else | zero |

**CPU registers**
| CPU | r0–r11 | r12, lr, pc | sp_sys | sp_irq | sp_svc | Mode |
|---|---|---|---|---|---|---|
| NDS9 | 0 | entry | `0x3002F7C` | `0x3003F80` | `0x3003FC0` | system, ARM, IRQs off **[not GBATEK]** |
| NDS7 | 0 | entry | `0x380FD80` | `0x380FF80` | `0x380FFC0` | system, ARM |

lr and SPSR in irq and svc modes are 0. Entry bit 0 is not used for T at boot,
since the header entries are ARM.

**CP15** (GBATEK gives no post-firmware dump; these values are derived)
- Control: `0x00012078` (the value SoftReset sets: high vectors, DTCM on, PU and
  caches off). The SDK crt0 reprograms CP15 anyway.
- DTCM (c9,c1,0): `0x027C000A` (0x027C0000, 16K) per the GBATEK default. The
  BIOS SoftReset assumes `0x0080000A`.
- ITCM (c9,c1,1): `0x00000020` (32 MB virtual size, which the firmware uses).
- The PU regions can be set per §1.5, or left disabled.
- **[not GBATEK]** A post-firmware CP15 dump from hardware would settle this.
  The `gba-hardware` skill can't do it (it is GBA-only), so this needs a DS
  homebrew probe.

**I/O**
| Register | Value |
|---|---|
| POSTFLG (both) | 1 |
| WRAMCNT | 3 (all shared WRAM to ARM7, needed for `0x37F8000` loads) |
| EXMEMCNT | `0x6000` (sync RAM, ARM9 owns both slots, ARM9 RAM priority). Game crt0 may change it |
| POWCNT1 | enable LCD + 2D A + 2D B (`0x0203`). Firmware-dependent; games set it themselves |
| POWCNT2 | 1 |
| SOUNDBIAS | 0x200 (the BIOS SoundBias ramp) |
| IME / IE / IF | 0 |
| BIOSPROT | 0x1204 (only matters with a real ARM7 BIOS) |
| ROMCTRL | cart in KEY2 main-data mode. Bit 29 (reset released) set. Plaintext reads |
| SPI / RTC / TSC / power manager | answer per §10 |

**Firmware image**: synthesize 256 KB with a header (console type `0xFF`, user
settings offset `0x3FE00/8`), wifi calibration (MAC address, CRC) and two
user-settings copies with valid CRC16. Games read nickname, language and touch
calibration from flash or RAM.

### 12.3 BIOS SWI tables (HLE targets)
Numbers come from the Thumb `SWI nn`. ARM mode uses `SWI nn<<16`, and the BIOS
reads the top byte.

| Function | GBA | NDS7 | NDS9 | Notes |
|---|---|---|---|---|
| SoftReset | 00 | 00 | 00 | Different stacks (below). Jumps to `[0x27FFE34]` (NDS7) / `[0x27FFE24]` (NDS9). NDS9 also flushes caches and sets CP15 ctrl to `0x12078` |
| RegisterRamReset | 01 | – | – | removed |
| WaitByLoop | – | 03 | 03 | `r0` count of `SUB/BGT` loop iterations. 1 ms ≈ 0x20BA (ARM7), 0x4174 (ARM9 cached), 0x105D (ARM9 uncached) |
| IntrWait | 04 | 04 | 04 | `r0` 1 = discard old flags, `r1` mask. Forces IME=1. Flags at the hardcoded check address. **NDS9 bug:** r0=0 still waits for at least one IRQ |
| VBlankIntrWait | 05 | 05 | 05 | r0=r1=1, then IntrWait |
| Halt | 02 | 06 | 06 | NDS7: HALTCNT=0x80. NDS9: CP15 WFI (hangs if IME=0). NDS9 destroys r0 |
| Sleep/Stop | 03 | 07 | – | NDS7 only |
| SoundBias | 19 | 08 | – | `r0` 0 → level 0, else 0x200. `r1` delay per step |
| Div | 06 | 09 | 09 | r0/r1 → r0 = quotient, r1 = remainder, r3 = abs(quotient). Software |
| Sqrt | 08 | 0D | 0D | Software |
| CpuSet | 0B | 0B | 0B | r2: bits 0–20 count, bit 24 fill, bit 26 32-bit. NDS7 rejects BIOS-range sources |
| CpuFastSet | 0C | 0C | 0C | Any word count on NDS (no round-up to 8). Only the first quarter runs fast (BIOS bug; matters for timing only) |
| GetCRC16 | – | 0E | 0E | r0 initial, r1 address, r2 length → r0 CRC, r3 = last halfword. Table `C0C1, C181, C301, C601, CC01, D801, F001, A001` |
| IsDebugger | – | 0F | 0F | r0 0 = retail 4 MB. Scribbles a halfword at `0x27FFFFA` (NDS7) / `0x27FFFF8` (NDS9) |
| BitUnPack | 10 | 10 | 10 | |
| LZ77 Wram (8-bit write) | 11 | 11 | 11 | |
| LZ77 by callback (16-bit write) | – | 12 | 12 | replaces GBA 12 "Vram" |
| Huffman by callback | 13 | 13 | 13 | GBA 13 is ReadNormal |
| RL Wram | 14 | 14 | 14 | |
| RL by callback (16-bit write) | – | 15 | 15 | replaces GBA 15 "Vram" |
| Diff8 Wram | 16 | – | 16 | |
| Diff16 | 18 | – | 18 | |
| GetSineTable | – | 1A | – | r0 0..0x3F |
| GetPitchTable | – | 1B | – | r0 0..0x2FF |
| GetVolumeTable | – | 1C | – | r0 0..0x2D3 |
| GetBootProcs | – | 1D | – | firmware internal |
| CustomHalt | 27 | 1F | – | r2 → HALTCNT (0x80 halt, 0xC0 sleep, 0x40 GBA mode) |
| CustomPost | – | – | 1F | r0 → POSTFLG |

- **Removed on NDS:** ArcTan, ArcTan2, BgAffineSet, ObjAffineSet,
  GetBiosChecksum, MultiBoot, HardReset, and every Sound driver call. Invalid
  numbers jump to 0 (the debug handler).
- **Callback decompressors:** `r2` = user parameter (Huffman: a 0x200-byte temp
  buffer), `r3` = a struct of 5 function pointers:
  `{open(src,dst,param)→header word, close (optional), get8(src), get16, get32}`.
  The pointers may be ARM or Thumb. The return value is the decompressed length
  or a negative error. HLE must call back into guest code, which needs a
  "call guest function and resume" mechanism in the CPU.
- **SoftReset stacks:**
  | CPU | sp_svc | sp_irq | sp_sys | Clears |
  |---|---|---|---|---|
  | NDS7 | `0x380FFDC` | `0x380FFB0` | `0x380FF00` | `0x380FE00–0x380FFFF` |
  | NDS9 | `0x0803FC0` | `0x0803FA0` | `0x0803EC0` | `DTCM+0x3E00..0x3FFF` |

### 12.4 CRC16 (GetCRC16, header/secure/firmware CRCs)
```
crc = init (0xFFFF)
for each byte b: crc ^= b; for j in 0..7: carry = crc&1; crc >>= 1; if carry: crc ^= (val[j] << (7-j))
val = C0C1,C181,C301,C601,CC01,D801,F001,A001
```
This is the reflected 0xA001 CRC-16/MODBUS. A standard table-driven
CRC-16/MODBUS gives the same result **[not GBATEK; cross-check with logo CRC 0xCF56]**.

---------------------------------------------------------------------------

## 13. What the dingbat GBA core can reuse

Based on hardware sharing and on how `src/dingbat/gba` is built today: every
component is a `ref object` with a `{.cursor.}` back-pointer to `GBA`, wired
through one `Bus` and one `Scheduler`, with save-state-ordered `EventType`
values in `common/scheduler.nim`.

| Component | Hardware relation | Reuse verdict |
|---|---|---|
| ARM7TDMI interpreter (`gba/cpu.nim`, `arm/`, `thumb/`) | NDS7 is the identical core. NDS9 is a superset (v5TE) | **ISA logic reusable, coupling not.** The decoders hard-wire `cpu.gba.bus` and GBA-specific timing: prefetch buffer, ROM refill, `waitloop`, LDM^ glitch, IRQ-window synchroniser, contention. For DS, parameterise the CPU over a bus interface (or a generic `[B]`) and a feature flag `v5te: static bool`, so the LUT builder compiles two decoders. The v5 deltas in §1.3 (interworking loads, MUL flags, LDRH alignment, STM/LDM writeback, BLX, CLZ, Q-ops, SMULxy, LDRD/STRD, cond=1111 space, CP15 MCR/MRC) are mostly localised to existing handlers. The prefetch, waitloop and GBA bus-glitch machinery must be optional per instance |
| HLE BIOS (`gba/hle_bios.nim`) | Div, Sqrt, CpuSet, CpuFastSet, BitUnPack, LZ77/RL/Huff (normal), Diff, IntrWait/Halt are the same algorithms at new numbers | **Algorithms reusable.** Renumber per §12.3, widen the IF mirror to 32 bits at the new addresses, and add callback decompressors, WaitByLoop, GetCRC16, IsDebugger and the sine/pitch/volume tables (which need dumped tables or an equivalent derivation). ARM9 halt is the CP15 WFI. The IRQ vector stub reads the handler from DTCM+0x3FFC / 0x380FFFC |
| PPU (`gba/ppu.nim`) text/affine BG, OBJ, windows, mosaic, blending, compositor | 2D engines are "extended GBA PPU" | **Core rendering reusable, with structural edits.** Width 240→256, lines 160/228 → 192/263, dot rate 4 → 6 cycles. VRAM reads must go through the bank page table (§2.5) instead of a flat `vram` array (biggest change, and it touches hot paths). Char/screen base widening plus the DISPCNT 64K offsets. 1D OBJ boundary. Bitmap OBJs. 9-bit OBJ priority (replaces GBA OBJ-priority emulation). Vertical wrap both ways. Ext palettes. Extended affine modes and large bitmap. Area overflow on bitmaps. Window Y compares the low 8 bits. Byte-write-ignore. Master brightness. Capture and display modes 2/3. Two instances (A, B) with engine-specific feature gating. The GBA bitmap modes 3–5 are not needed in DS mode |
| Timers (`gba/timer.nim`) | identical except F=33.51 MHz | **Directly reusable**, one instance per CPU. Scale the cycles: if the scheduler runs at 66 MHz, tick timers at /2. The FIFO-sound hookups are unused |
| DMA (`gba/dma.nim`) | same channel model. NDS9 adds 3-bit modes, 21-bit counts, R/W registers, FILL regs. NDS7 2-bit modes | **Mostly reusable** after parameterising: start-mode decode per CPU, count/address masks, readable registers, new triggers (start-of-display, main-memory FIFO, cart DRQ, GXFIFO half-empty, wifi). Remove GBA sound-FIFO and video-capture special modes from the DS path. TCM bypass: DMA uses the bus view, never the CPU's TCM overlay |
| IRQ controller (`gba/interrupts.nim`) | same IME/IE/IF semantics. 32-bit regs at 0x208/0x210/0x214. New sources | **Reusable** after widening to 32 bits and moving the offsets. The IRQ_LAST_WAITS synchroniser is GBA-measured timing and can be off for DS at first. One instance per CPU. Level-triggered GX FIFO IRQ and edge-triggered IPC FIFO IRQs need care |
| Keypad (`gba/keypad.nim`) | KEYINPUT/KEYCNT identical on both CPUs | **Directly reusable** (two instances sharing one input state) + a small EXTKEYIN/touch/hinge module on ARM7 |
| Scheduler (`common/scheduler.nim`) | DS needs two CPUs interleaved on one timebase | **Reusable engine**, but `EventType` is a global, save-state-ordered enum. DS events must be appended (or the enum split per system). Timebase: 66 MHz ARM9 cycles is simplest (ARM7 and bus events ×2). Run the CPUs in lockstep slices (e.g. ARM9 for N cycles, then ARM7 catches up), with sync points at IPC, shared-RAM and IRQ boundaries |
| RTC (`gba/rtc.nim`, `rtc_calendar.nim`) | DS RTC is the same Seiko family on a different GPIO layout | **Calendar reusable.** The protocol needs a register-set and port-bit adapter |
| APU / PSG (`gba/apu*`, `common/psg*`) | DS sound is a different design (16 PCM/ADPCM/PSG channels) | **Not reusable** apart from the resampler/output plumbing (`common/resampler.nim`). The DS PSG square/noise is unrelated to the GB PSG |
| Save storage (`gba/storage*`) | DS backup is SPI EEPROM/FLASH/FRAM | **New module.** File I/O, atomic save and the save-webhook plumbing are reusable |
| GBA slot | NDS can map GBA cart ROM/SRAM at `0x08000000` | Optional (Rumble Pak / GBA-slot accessories). Not needed for most games |

**Net-new modules:** VRAM bank mapper, ARM946E-S CP15 (+TCM, PU optional,
cache-cost model), IPC, maths unit, 3D geometry + rasterizer, display capture
and master brightness, SPI hub (firmware flash, TSC, power manager), DS sound,
cart protocol + AUXSPI backup, a wifi stub, and direct-boot setup.

---------------------------------------------------------------------------

## 14. Open items / not covered by GBATEK
- Exact CP15 state and I/O state after the retail firmware hands over (only
  partially documented; §12.2 is a best guess).
- ORed reads from overlapping VRAM banks, and VRAM read/write behaviour on
  disabled banks.
- ARM9 bus arbitration between the CPUs and DMA, and main RAM contention timing.
- The 3D rasterizer's exact rules (GBATEK says "about 92% understood").
  Polygon edge, interpolation and depth precision need other sources or
  hardware probes.
- The ARM946E-S data-abort model, the BXJ treatment, and the undefined
  cond=1111 space should be confirmed with an ARM ARM or hardware tests.
