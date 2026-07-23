## Scratch: calibrate HLE SWI cost models against real-BIOS execution.
## Runs the same controlled Huffman workloads under the real BIOS and under
## the HLE, measuring cycles from SWI issue to return, and prints both so the
## HLE model constants can be fitted (a9ca2a9 method).
##
## Usage: scratch_swicalib <bios.bin> <dummy.gba>
import std/[os, strutils, strformat]
import dingbat/gba/gba
import dingbat/common/test_output

const STUB = 0x03000100'u32

type Workload = object
  name: string
  data: seq[uint8]     # full huffman stream (header + tree + bitstream)
  src: uint32          # where to place it
  dst: uint32
  # expected model counters
  n_node, n_leaf, n_words, n_outw: int

proc make_huff(name: string; sym_bits: int; depth: int; n_out_bytes: int;
               src, dst: uint32): Workload =
  ## Build a Huffman stream where every symbol sits at `depth` bits down a
  ## left-spine tree: node0 -> (leaf, node) ... final node -> (leaf, leaf).
  ## We always emit the all-zeros path symbol (depth bits of 0 per symbol).
  result.name = name
  result.src = src
  result.dst = dst
  # Tree table: root + chain. Node byte: offset(6) | leaf flags.
  # Layout: size byte at 0, root at 1.
  # For depth d: nodes n_0..n_{d-1}; n_i at byte 1+i? Node addressing:
  # child pair addr = (node_addr &~1) + (offset+1)*2. We lay out:
  # addr1: root. children of root at addr2,3 (offset 0 from addr1&~1=0 -> 0+ (0+1)*2 = 2).
  # left child (addr2) = leaf (symbol) if depth==1 else internal node
  # right child (addr3) = leaf (dummy)
  # children of addr2: (2&~1)+ (off+1)*2 = 2 + (off+1)*2 -> choose off 0 -> 4,5
  # etc: internal node at even addr 2k, children at 2k+2, 2k+3 with offset 0.
  var tree: seq[uint8] = @[]
  # tree[0] reserved for size byte later; build node bytes from addr 1
  # We'll construct full table as bytes t[0..]; t[0]=size
  var t: seq[uint8] = newSeq[uint8](2 + 2 * depth)
  # root at index 1
  for i in 0 ..< depth:
    let node_idx = if i == 0: 1 else: 2 * i
    let is_last = i == depth - 1
    # left child is leaf when is_last; also make... we want the ZERO path to
    # hit a leaf only at final depth: left child leaf only at last level.
    # right child is always a leaf (never taken).
    var b: uint8 = 0  # offset 0
    if is_last: b = b or 0x80  # left leaf
    b = b or 0x40              # right leaf (unused path)
    t[node_idx] = b
    if is_last:
      let pair = (node_idx and not 1) + 2
      t[pair] = 0x05  # left leaf symbol (low nibble only: valid for 4-bit too)
      t[pair + 1] = 0x0A
  let table_len = t.len  # includes size byte
  t[0] = uint8(table_len div 2 - 1)
  # bitstream: each symbol = `depth` zero bits, MSB-first per 32-bit word
  let n_sym = n_out_bytes * 8 div sym_bits
  let total_bits = n_sym * depth
  let n_words = (total_bits + 31) div 32
  var bits = newSeq[uint8](n_words * 4)  # zero bits: all zero bytes
  var data: seq[uint8] = @[]
  let header = (uint32(n_out_bytes) shl 8) or 0x20'u32 or uint32(sym_bits)
  data.add uint8(header)
  data.add uint8(header shr 8)
  data.add uint8(header shr 16)
  data.add uint8(header shr 24)
  data.add t
  # align to 4 relative... BIOS aligns data_start = src+4+ (size+1)*2 rounded
  # to 4 ABSOLUTE. Ensure src word-aligned; pad to make our bits at aligned pos
  while (data.len mod 4) != 0: data.add 0'u8
  data.add bits
  result.data = data
  # counters
  let sym_leaf = 1
  result.n_leaf = n_sym * sym_leaf
  result.n_node = n_sym * (depth - 1)
  result.n_outw = n_out_bytes div 4
  result.n_words = n_words

proc poke(gba: GBA; adr: uint32; buf: seq[uint8]) =
  for i, b in buf:
    gba.bus[adr + uint32(i)] = b

proc poke_rom(gba: GBA; adr: uint32; buf: seq[uint8]) =
  let off = int(adr and 0x01FFFFFF'u32)
  for i, b in buf:
    gba.cartridge.rom[off + i] = b

proc run_one(bios: string; rom_path: string; w: Workload; use_hle: bool): int64 =
  let emu = new_gba(if use_hle: "" else: bios, rom_path,
                    run_bios = false, use_hle = use_hle)
  emu.test_output = new_test_output()
  emu.post_init()
  # place payload
  if (w.src shr 24) == 0x08:
    emu.poke_rom(w.src, w.data)
  else:
    emu.poke(w.src, w.data)
  # stub: swi 0x13 (Huffman), b self
  emu.bus.write_word(STUB, 0xEF130000'u32)
  emu.bus.write_word(STUB + 4, 0xEAFFFFFE'u32)
  emu.cpu.r[0] = w.src
  emu.cpu.r[1] = w.dst
  emu.cpu.r[2] = 0
  emu.cpu.r[3] = 0
  discard emu.cpu.set_reg(15, STUB)
  let t0 = int64(emu.scheduler.cycles) + int64(emu.bus.cycles)
  var guard = 0
  while emu.cpu.r[15] != STUB + 12:
    emu.cpu.tick()
    guard.inc
    if guard > 60_000_000:
      stderr.writeLine "guard tripped for ", w.name
      break
  result = int64(emu.scheduler.cycles) + int64(emu.bus.cycles) - t0

proc main() =
  let args = commandLineParams()
  let bios = args[0]
  let rom = args[1]
  var loads: seq[Workload] = @[]
  const ROMS = 0x08100000'u32
  const EWS = 0x02010000'u32
  const EWD = 0x02030000'u32
  const IWD = 0x03001000'u32
  loads.add make_huff("8bit d1 256B rom->ew", 8, 1, 256, ROMS, EWD)
  loads.add make_huff("8bit d1 1024B rom->ew", 8, 1, 1024, ROMS, EWD)
  loads.add make_huff("8bit d4 256B rom->ew", 8, 4, 256, ROMS, EWD)
  loads.add make_huff("8bit d4 1024B rom->ew", 8, 4, 1024, ROMS, EWD)
  loads.add make_huff("4bit d1 256B rom->ew", 4, 1, 256, ROMS, EWD)
  loads.add make_huff("4bit d3 1024B rom->ew", 4, 3, 1024, ROMS, EWD)
  loads.add make_huff("8bit d2 512B ew->ew", 8, 2, 512, EWS, EWD)
  loads.add make_huff("8bit d1 512B ew->iw", 8, 1, 512, EWS, IWD)
  loads.add make_huff("8bit d6 512B rom->iw", 8, 6, 512, ROMS, IWD)
  loads.add make_huff("4bit d8 512B rom->ew", 4, 8, 512, ROMS, EWD)
  loads.add make_huff("8bit d1 512B rom->ew", 8, 1, 512, ROMS, EWD)
  loads.add make_huff("8bit d2 512B rom->ew", 8, 2, 512, ROMS, EWD)
  loads.add make_huff("8bit d3 512B rom->ew", 8, 3, 512, ROMS, EWD)
  loads.add make_huff("8bit d5 512B rom->ew", 8, 5, 512, ROMS, EWD)
  loads.add make_huff("8bit d2 512B ew->ew2", 8, 2, 512, EWS, EWD)
  loads.add make_huff("8bit d3 512B ew->ew", 8, 3, 512, EWS, EWD)
  echo "name                        real       hle    diff   n_node n_leaf n_words n_outw"
  for w in loads:
    let r = run_one(bios, rom, w, false)
    let h = run_one(bios, rom, w, true)
    echo &"{w.name:>24}  {r:>9} {h:>9} {h - r:>7}   {w.n_node:>6} {w.n_leaf:>6} {w.n_words:>7} {w.n_outw:>6}"

main()
