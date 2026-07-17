# In-process lockstep link between two GB/GBC cores — the Game Boy analog
# of gba/link.nim (see there for the full design rationale).
#
# The two cores are stepped in bounded, interleaved slices so neither's
# emulated clock gets ahead of the other by more than roughly LINK_SLICE
# cycles plus one instruction of overshoot. A serial transfer is resolved
# byte-at-a-time: the master (internal clock) shifts its 8 bits off its own
# DIV-derived serial clock exactly as a lone unit would (bit engine in
# serial.nim), and when the 8th shift lands the coordinator advances the
# peer to that emulated time and exchanges bytes full-duplex — the same
# deferred-completion discipline as the GBA lockstep link, and the same
# run_to() boundary a network transport would replace.
#
# Clock caveat: cross-core "global time" compares scheduler cycles, which
# count CPU cycles — a CGB core in double speed advances its scheduler 2x
# per wall-second. Two linked games track each other's speed mode in
# practice (both Pokemon GSC sides run the same code), so the skew bound
# only degrades by that factor during brief mismatched-speed windows.

import ../common/scheduler
import gb

const
  LINK_SLICE = 512
    ## Interleave granularity in cycles: well below one serial byte at the
    ## normal clock (8 x 512 = 4096 cycles) so the slave always gets its
    ## staging window between rounds, and equal to one bit period so data
    ## latched "now" from a slightly-ahead peer is within a bit of
    ## hardware truth. CGB-fast transfers (128 cycles) are shorter than
    ## the slice; their data still exchanges at the exact completion cycle
    ## because run_to drives the peer forward before latching.

type
  GbLink* = ref object
    cores*: seq[GB]
    # Global-time bookkeeping: global(i) = offsets[i] + scheduler.cycles,
    # updated with each core's per-frame rebase.
    offsets: seq[int64]
    # Re-entrancy guard: true while core i is being advanced up-stack.
    active: seq[bool]
    frame_done: seq[bool]
    # Monotonic count of serial transfers completed over the cable. Games
    # drive transfers continuously while the link is in use and stop when
    # they close it, so "count not advancing" is a game-agnostic idle
    # signal (same contract as gba/link.nim).
    transfers*: int

  LockstepGbSerialDriver* = ref object of GbSerialDriver
    link: GbLink
    id: int

# ---------------- clock plumbing ----------------

proc now(link: GbLink; i: int): int64 =
  link.offsets[i] + int64(link.cores[i].scheduler.cycles)

proc run_to(link: GbLink; i: int; target: int64) =
  ## Advance core i until its global clock reaches `target`. This is the
  ## network-transport boundary: for a remote peer it becomes "block until
  ## peer i confirms it has reached `target` and hand over its SB/SC".
  if link.active[i]: return  # already being advanced up-stack
  let gb = link.cores[i]
  link.active[i] = true
  while link.offsets[i] + int64(gb.scheduler.cycles) < target:
    gb.cpu.tick(gb)
  link.active[i] = false

proc step_frame*(link: GbLink) =
  ## Advance every core by one video frame, interleaved in bounded slices:
  ## always advance the core with the smallest global clock.
  for i in 0 ..< link.cores.len:
    link.frame_done[i] = false
  while true:
    var best = -1
    var best_t = int64.high
    for i in 0 ..< link.cores.len:
      if link.frame_done[i]: continue
      let t = link.now(i)
      if t < best_t:
        best = i
        best_t = t
    if best < 0: break
    let gb = link.cores[best]
    let local_target = gb.scheduler.cycles + CycleCount(LINK_SLICE)
    link.active[best] = true
    while gb.scheduler.cycles < local_target and not gb.ppu.frame:
      gb.cpu.tick(gb)
    link.active[best] = false
    if gb.ppu.frame:
      link.frame_done[best] = true
  for i in 0 ..< link.cores.len:
    link.cores[i].ppu.frame = false
    link.offsets[i] += int64(link.cores[i].scheduler.rebase())

# ---------------- transfer resolution ----------------

proc peer_of(link: GbLink; m: int): int =
  # A link cable connects exactly two units.
  for i in 0 ..< link.cores.len:
    if i != m: return i
  -1

proc complete_transfer(link: GbLink; m: int) =
  # Core m's internally-clocked transfer shifted its 8th bit. Advance the
  # peer to this emulated time, then exchange bytes full-duplex: the
  # master's clock shifts both shift registers whether or not the slave
  # set its enable bit — the slave only gets completion semantics (SC.7
  # clear + serial IRQ) if it had started with the external clock.
  let master = link.cores[m]
  let p = link.peer_of(m)
  if p < 0:
    master.serial.serial_finish_transfer(master)
    return
  link.run_to(p, link.now(m))
  inc link.transfers
  let slave = link.cores[p]
  if (slave.serial.sc and 0x01) == 0:
    # Peer's shift register is on the external clock (started or not):
    # its SB — staged after its previous serial IRQ, which run_to gave it
    # every chance to retire — lands in the master's SB and vice versa.
    master.serial.sb = slave.serial.sb
    slave.serial.sb = master.serial.out_latch
    let slave_started = (slave.serial.sc and 0x80) != 0
    master.serial.serial_finish_transfer(master)
    if slave_started:
      slave.serial.serial_finish_transfer(slave)
  else:
    # Peer is clocking its own transfer (line contention, no hardware
    # analog worth modeling): the master reads an idle-high line — the
    # bit engine already shifted in 1s.
    master.serial.serial_finish_transfer(master)

# ---------------- driver ----------------

method serial_complete*(drv: LockstepGbSerialDriver; gb: GB) =
  drv.link.complete_transfer(drv.id)

# ---------------- construction ----------------

proc new_gb_link*(cores: seq[GB]): GbLink =
  ## Wire already-initialized (post_init) cores into a lockstep link.
  doAssert cores.len == 2, "a GB link cable connects exactly two cores"
  result = GbLink(
    cores:      cores,
    offsets:    newSeq[int64](cores.len),
    active:     newSeq[bool](cores.len),
    frame_done: newSeq[bool](cores.len),
  )
  for i, core in cores:
    core.set_serial_driver(LockstepGbSerialDriver(link: result, id: i))
