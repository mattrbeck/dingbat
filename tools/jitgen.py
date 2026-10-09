#!/usr/bin/env python3
"""jitgen.py PROFILE... -o src/dingbat/nds/arm/jit_gen.nim [--cover 0.99] [--max-len 64]

The block translator prototype's front end (docs/nds/jit.md): reads opcode
profiles written by an `-d:nds_jitprof` ndsrun (DINGBAT_JITPROF=FILE; lines
"CPU PC OPCODE COUNT ENTRIES", PC bit 0 = Thumb) and writes the Nim blocks
arm/blocks.nim includes: one proc per block, each opcode a `jit_arm` /
`jit_thumb` call with its address and opcode as literals.

Blocks start where execution arrived other than from the opcode before
(ENTRIES > 0) and run on through the profile's opcodes at the next address
until an opcode that may change the pc, the mode or the Thumb state
unconditionally (B, BL, BX, writes to r15, LDM with r15, MSR, SWI,
coprocessor and undefined opcodes); conditional branches inside a block
leave it only when taken (the block checks next_pc after every opcode).
Hot blocks are kept until they cover --cover of the profile's opcodes.
"""
import sys, argparse, collections

ap = argparse.ArgumentParser()
ap.add_argument("profiles", nargs="+")
ap.add_argument("-o", "--out", required=True)
ap.add_argument("--cover", type=float, default=0.99)
ap.add_argument("--max-len", type=int, default=64)
ap.add_argument("--cpus", default="97")
ap.add_argument("--v2", action="store_true", help="pure opcodes without fetch checks, clock in locals")
ap.add_argument("--v3", action="store_true", help="--v2, and runs of pure opcodes as transactions on a shadow CPU")
ap.add_argument("--chain", action="store_true", help="blocks call the blocks their static branches reach")
args = ap.parse_args()

# (cpu, key) -> {opcode: [count, entries]}
prof = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0]))
for path in args.profiles:
    for line in open(path):
        cpu, key, op, cnt, ent = line.split()
        e = prof[(cpu, int(key, 16))][int(op, 16)]
        e[0] += int(cnt); e[1] += int(ent)

# the most frequent opcode per address
code = {}
for (cpu, key), ops in prof.items():
    op, (cnt, ent) = max(ops.items(), key=lambda kv: kv[1][0])
    tot = sum(v[0] for v in ops.values())
    ents = sum(v[1] for v in ops.values())
    code[(cpu, key)] = (op, tot, ents)


def arm_kind(i):
    """(ends, tc, lead_after) for an ARM opcode: ends = may change pc, mode or
    T unconditionally (the block stops after it); tc = may switch to Thumb
    without jumping (the block checks T after it); lead_after = the opcode
    after it starts a block of its own (the run loop gets there by itself)."""
    cond = i >> 28
    al = cond == 0xE
    if cond == 0xF:
        return True, True, True           # BLX imm, PLD, undefined
    if (i & 0x0FFFFFD0) == 0x012FFF10:
        return al, True, True             # BX / BLX register
    top = (i >> 25) & 7
    if top == 5:
        return al, False, True            # B / BL: a taken one leaves by next_pc
    if top == 7:
        if i & 0x01000000:
            return True, True, True       # SWI
        if i & 0x10:
            return False, ((i >> 12) & 15) == 15, True   # MCR / MRC: attn ends the block
        return True, True, True           # CDP: undefined
    if top == 6:
        return True, True, True           # LDC/STC: undefined
    if top == 4:
        if i & 0x8000 and i & 0x00100000:
            return al, True, True         # LDM with r15
        return False, False, False
    if top in (2, 3):
        if top == 3 and (i & 0x10):
            return True, True, True       # undefined
        pc = bool(i & 0x00100000) and ((i >> 12) & 15) == 15   # LDR pc
        return al and pc, pc, pc
    if top == 0 and (i & 0x90) == 0x90:
        if (i >> 5) & 3 == 0:
            return False, False, False    # MUL / SWP
        pc = bool(i & 0x00100000) and ((i >> 12) & 15) == 15   # LDRH pc
        return al and pc, pc, pc
    if (i & 0x01900000) == 0x01000000:
        if (i & 0xF0) == 0:
            msr = bool(i & 0x00200000)
            return False, msr, msr        # MRS / MSR
        if (i & 0x0FF000F0) == 0x01200070:
            return True, True, True       # BKPT
        return False, False, False        # CLZ, QADD.., SMLAxy
    if top == 1 and (i & 0x01900000) == 0x01000000:
        return False, True, True          # MSR immediate
    op = (i >> 21) & 15
    if 8 <= op <= 11:
        return False, False, False        # TST/TEQ/CMP/CMN
    pc = ((i >> 12) & 15) == 15           # writes r15
    return al and pc, pc, pc


def thumb_kind(i):
    top5 = i >> 11
    if top5 == 0b11100:
        return True, False, True          # B
    if top5 in (0b11101, 0b11111):
        return True, True, True           # BLX / BL suffix
    if top5 == 0b11110:
        return False, False, False        # BL prefix
    if (i >> 8) in (0xDF, 0xDE, 0xBE):
        return True, True, True           # SWI, undefined, BKPT
    if (i >> 12) == 0xD:
        return False, False, True         # Bcc
    if (i >> 10) == 0b010001:
        op = (i >> 8) & 3
        if op == 3:
            return True, True, True       # BX / BLX
        rd = (i & 7) | ((i >> 4) & 8)
        pc = op != 1 and rd == 15         # ADD/MOV pc
        return pc, pc, pc
    if (i >> 8) == 0xBD:
        return True, True, True           # POP {.., pc}
    return False, False, False


def arm_pure(i):
    """ALU, multiply, MRS, CLZ, saturating and halfword multiplies, writing
    no r15: no data access, no jump, no CPSR control write, no exception."""
    if (i >> 28) == 0xF:
        return False
    top = (i >> 25) & 7
    if top not in (0, 1):
        return False
    rd, rn = (i >> 12) & 15, (i >> 16) & 15
    if top == 0 and (i & 0x90) == 0x90:
        if (i >> 5) & 3 != 0 or i & 0x01000000:
            return False                  # halfword transfers, SWP
        return rd != 15 and rn != 15      # MUL/MLA/UMULL..: Rd/RdHi in 19-16, RdLo in 15-12
    if (i & 0x01900000) == 0x01000000:
        if top == 1:
            return False                  # MSR immediate
        if (i & 0xF0) == 0:
            return not (i & 0x00200000) and rd != 15     # MRS (not MSR)
        if (i & 0x0FFF0FF0) == 0x016F0F10:
            return rd != 15               # CLZ
        if (i & 0x0F9000F0) == 0x01000050:
            return rd != 15               # QADD..
        if (i & 0x0F900090) == 0x01000080:
            return rd != 15 and rn != 15  # SMLAxy..
        return False
    op = (i >> 21) & 15
    return (8 <= op <= 11) or rd != 15


def thumb_pure(i):
    t3 = i >> 13
    if t3 == 0b000 or t3 == 0b001:
        return True                       # shifts, ADD/SUB, MOV/CMP/ADD/SUB immediate
    if (i >> 10) == 0b010000:
        return True                       # ALU operations
    if (i >> 10) == 0b010001:
        op = (i >> 8) & 3
        rd = (i & 7) | ((i >> 4) & 8)
        return op != 3 and (op == 1 or rd != 15)
    if (i >> 12) == 0b1010:
        return True                       # ADD rd, pc/sp, #imm
    if (i >> 8) == 0b10110000:
        return True                       # ADD sp, #imm
    return False


def written(i, thumb):
    """Registers a pure opcode may write (an over-approximation is harmless:
    the shadow holds the value from before for a register not written)."""
    if thumb:
        t3 = i >> 13
        if t3 == 0b000:
            return {i & 7}
        if t3 == 0b001:
            return {(i >> 8) & 7}
        if (i >> 10) == 0b010000:
            return {i & 7}
        if (i >> 10) == 0b010001:
            return {(i & 7) | ((i >> 4) & 8)}
        if (i >> 12) == 0b1010:
            return {(i >> 8) & 7}
        return {13}                       # ADD sp, #imm
    top = (i >> 25) & 7
    rd, rn = (i >> 12) & 15, (i >> 16) & 15
    if top == 0 and (i & 0x90) == 0x90:
        return {rd, rn}                   # multiplies: Rd/RdHi, RdLo/Rn
    if (i & 0x01900000) == 0x01000000:
        return {rd, rn}                   # MRS, CLZ, QADD.., SMLAxy..
    return {rd}


def is_pure(op, thumb):
    return thumb_pure(op) if thumb else arm_pure(op)


def kind(op, thumb):
    return thumb_kind(op) if thumb else arm_kind(op)


leaders = set()
for (cpu, key), (op, cnt, ents) in code.items():
    if cpu not in args.cpus:
        continue
    if ents > 0:
        leaders.add((cpu, key))
    if kind(op, key & 1)[2]:
        leaders.add((cpu, key + (2 if key & 1 else 4)))

blocks = []  # (cpu, start key, [(addr, op, tc)], weight)
work = sorted(leaders)
seen = set()
while work:
    cpu, key = work.pop()
    if (cpu, key) in seen or (cpu, key) not in code:
        continue
    seen.add((cpu, key))
    thumb = key & 1
    size = 2 if thumb else 4
    ops = []
    k = key
    while True:
        c = code.get((cpu, k))
        if c is None:
            break
        if len(ops) == args.max_len:
            work.append((cpu, k))     # the rest: a block of its own
            break
        o = c[0]
        ends, tc, _ = kind(o, thumb)
        ops.append((k & ~1, o, tc))
        if ends:
            break
        k += size
    if ops:
        blocks.append((cpu, key, ops, max(1, code[(cpu, key)][2])))

# weight: opcodes the block would run per entry, at most; keep hot blocks
# until they cover the profile's opcodes
total = collections.Counter()
for (cpu, key), (op, cnt, ents) in code.items():
    total[cpu] += cnt
covered = set()
kept = []
blocks.sort(key=lambda b: -sum(code[(b[0], a | (b[1] & 1))][1] for a, _, _ in b[2]))
need = {c: args.cover * total[c] for c in total}
cov = collections.Counter()
for b in blocks:
    cpu = b[0]
    if cov[cpu] >= need[cpu]:
        continue
    kept.append(b)
    for a, _, _ in b[2]:
        k = (cpu, a | (b[1] & 1))
        if k not in covered:
            covered.add(k)
            cov[cpu] += code[k][1]

out = []
out.append("# Generated by tools/jitgen.py from " + ", ".join(args.profiles))
out.append("# Blocks: " + ", ".join(f"ARM{c} {sum(1 for b in kept if b[0] == c)} ({cov[c] / max(1, total[c]) * 100:.1f} % of profiled opcodes)" for c in sorted(total)))
names = collections.defaultdict(list)
kept_keys = {(b[0], b[1]) for b in kept}
if args.chain:
    # forward declarations: blocks call the blocks their branches reach
    for cpu, key, ops, _ in kept:
        out.append(f"proc jb{cpu}_{key:08x}[B](cpu: ArmCpu[B]; until: int64) {{.nimcall.}}")


def static_targets(ops, thumb):
    """Keys of the places a block's opcodes may jump to that are known
    statically (B, BL, Bcc; Thumb B, Bcc, BL), in the same state, and the
    address after its last opcode."""
    ts = []
    for j, (a, o, _) in enumerate(ops):
        if thumb:
            if (o >> 12) == 0xD and (o >> 8) & 15 < 14:
                off = o & 0xFF
                off = off - 256 if off & 0x80 else off
                ts.append((a + 4 + off * 2) | 1)
            elif (o >> 11) == 0b11100:
                off = o & 0x7FF
                off = off - 2048 if off & 0x400 else off
                ts.append((a + 4 + off * 2) | 1)
            elif (o >> 11) == 0b11111 and j > 0 and (ops[j - 1][1] >> 11) == 0b11110:
                hi = ops[j - 1][1] & 0x7FF
                hi = hi - 2048 if hi & 0x400 else hi
                ts.append(((a - 2 + 4 + (hi << 12) + (o & 0x7FF) * 2) & 0xFFFFFFFF) | 1)
        else:
            if ((o >> 25) & 7) == 5 and (o >> 28) != 0xF:
                off = o & 0xFFFFFF
                off = off - (1 << 24) if off & 0x800000 else off
                ts.append((a + 8 + off * 4) & 0xFFFFFFFF)
    last = ops[-1][0]
    ts.append((last + (2 if thumb else 4)) | (1 if thumb else 0))
    return sorted(set(ts))


for cpu, key, ops, _ in kept:
    thumb = key & 1
    name = f"jb{cpu}_{key:08x}"
    names[cpu].append((key, name))
    fn = "jit_thumb" if thumb else "jit_arm"
    out.append(f"proc {name}[B](cpu: ArmCpu[B]; until: int64) {{.nimcall.}} =")
    if args.v2 or args.v3:
        # pure opcodes in the line (ARM9: 32 bytes) or page (ARM7: 4 KB) of
        # the opcode before; `lineok` (set after every other opcode, kept by
        # pure ones) says at run time that the bus's sequential path holds
        if args.v3:
            out.append("  mixin fetch_peek32, fetch_peek16")
        out.append("  var cyc = cpu.cycles")
        out.append("  var cnt = cpu.instr_count")
        out.append("  var lineok = false")
        out.append("  block run:")
        unit = 5 if cpu == "9" else 12
        sfx = "thumb" if thumb else "arm"
        size = 2 if thumb else 4
        kinds = []
        for j, (a, o, tc) in enumerate(ops):
            prev = ops[j - 1] if j else None
            seq = prev is not None and (prev[0] >> unit) == (a >> unit)
            last = j == len(ops) - 1
            kinds.append("pure" if seq and is_pure(o, thumb) and not last else "full")
        j = 0
        nrun = 0
        while j < len(ops):
            # a run: pure opcodes j..e-1 in one line (each SEQ after the one before)
            e = j
            while args.v3 and e < len(ops) and kinds[e] == "pure" and (e == j or kinds[e - 1] == "pure"):
                e += 1
            if e - j >= 2:
                nrun += 1
                run = ops[j:e]
                wr = sorted(set().union(*(written(o, thumb) for _, o, _ in run)))
                peek = "fetch_peek16" if thumb else "fetch_peek32"
                ex = "thumb_dispatch" if thumb else "exec_arm_const"
                out.append(f"    block r{nrun}:")
                out.append("      if lineok:")
                out.append("        var buf {.noinit.}: jit_shadow(cpu)")
                out.append("        let sc {.cursor.} = cast[ArmCpu[B]](addr buf)")
                out.append("        sc.r = cpu.r; sc.cpsr = cpu.cpsr; sc.spsr = cpu.spsr; sc.icycles = 0")
                out.append("        var same = true")
                for a, o, _ in run:
                    out.append(f"        same = same and {peek}(cpu.bus, 0x{a:08X}'u32) == 0x{o:08X}'u32")
                    out.append(f"        sc.cur_pc = 0x{a:08X}'u32; sc.r[15] = 0x{a + 2 * size:08X}'u32; sc.{ex}(0x{o:08X}'u32)")
                out.append(f"        let cost = jit_run_cost(cpu, sc, {len(run)}, {size})")
                out.append("        if same and cyc + cost < until:")
                for r in wr:
                    out.append(f"          cpu.r[{r}] = sc.r[{r}]")
                out.append("          cpu.cpsr = sc.cpsr")
                out.append(f"          cpu.jit_run_commit(0x{run[-1][0]:08X}'u32, {size})")
                out.append(f"          cyc += cost; cnt += {len(run)}")
                out.append(f"          break r{nrun}")
                for a, o, _ in run:
                    out.append(f"      if not cpu.jit_pure_{sfx}(until, 0x{a:08X}'u32, 0x{o:08X}'u32, cyc, cnt, lineok): break run")
                j = e
                continue
            a, o, tc = ops[j]
            last = j == len(ops) - 1
            if kinds[j] == "pure":
                call = f"cpu.jit_pure_{sfx}(until, 0x{a:08X}'u32, 0x{o:08X}'u32, cyc, cnt, lineok)"
            else:
                call = f"cpu.jit_full_{sfx}(until, 0x{a:08X}'u32, 0x{o:08X}'u32, {'true' if tc else 'false'}, cyc, cnt, lineok)"
            out.append(f"    if not {call}: break run" if not last else f"    discard {call}")
            j += 1
        out.append("  cpu.cycles = cyc")
        out.append("  cpu.instr_count = cnt")
        if args.chain:
            # where the run loop would look the next block up and call it
            # (no attn, below until, in this state), call it from here
            ts = [t for t in static_targets(ops, thumb) if (cpu, t) in kept_keys]
            if ts:
                tcheck = "!= 0" if thumb else "== 0"
                out.append(f"  if not cpu.attn and cyc < until and (cpu.cpsr and FLAG_T) {tcheck} and jit_depth < JIT_CHAIN:")
                out.append(f"    inc jit_depth")
                out.append(f"    case cpu.next_pc")
                for t in ts:
                    out.append(f"    of 0x{t & ~1:08X}'u32: jb{cpu}_{t:08x}(cpu, until)")
                out.append(f"    else: discard")
                out.append(f"    dec jit_depth")
        continue
    for j, (a, o, tc) in enumerate(ops):
        call = f"cpu.{fn}(until, 0x{a:08X}'u32, 0x{o:08X}'u32{', true' if tc else ''})"
        if j == len(ops) - 1:
            out.append(f"  discard {call}")
        else:
            out.append(f"  if not {call}: return")
for cpu in "97":
    lst = names.get(cpu, [])
    if lst:
        items = ",\n    ".join(f"(0x{k:08X}'u32, JitFn[B]({n}[B]))" for k, n in lst)
        out.append(f"template jit_blocks{cpu}*(B: typedesc): untyped =\n  [{items}]")
    else:
        out.append(f"template jit_blocks{cpu}*(B: typedesc): untyped = newSeq[(uint32, JitFn[B])]()")
open(args.out, "w").write("\n".join(out) + "\n")
sys.stderr.write(out[1] + "\n")
sys.stderr.write("opcodes in blocks: " + ", ".join(f"ARM{c} {sum(len(b[2]) for b in kept if b[0] == c)}" for c in sorted(total)) + "\n")
