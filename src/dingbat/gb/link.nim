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

when defined(gbLinkTrace):
  # Debug hook (-d:gbLinkTrace): one call per completed transfer with the
  # master id, the bytes exchanged, and whether the slave was ready. The
  # harness prints these to reconstruct the link protocol. Compiled out
  # of normal builds.
  var onGbTransfer*: proc(master: int; master_out, slave_out: uint8;
                          slave_sc: uint8; slave_got_irq: bool) = nil
  var bothInternalCount*: int = 0  # transfers where the peer was also internal-clock

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
  let master_out = master.serial.out_latch
  var slave_out = 0xFF'u8
  var slave_got_irq = false
  # A transfer exchanges bytes only when the peer is a LISTENING external-
  # clock slave (SC bit0=0 external, bit7=1 transfer enabled). An unarmed
  # peer — not started, or clocking its own transfer — isn't driving its
  # SO line, so the master clocks in idle-high 1s (0xFF), exactly as on
  # hardware. Feeding the master the peer's latched SB while it wasn't
  # listening was the desync bug: it let a game latch a role/handshake byte
  # from a peer that never actually sent it that cycle.
  let slave_listening = (slave.serial.sc and 0x81) == 0x80
  if slave_listening:
    slave_out = slave.serial.sb
    master.serial.sb = slave.serial.sb
    slave.serial.sb = master.serial.out_latch
    master.serial.serial_finish_transfer(master)
    slave.serial.serial_finish_transfer(slave)
    slave_got_irq = true
  else:
    master.serial.sb = 0xFF'u8
    master.serial.serial_finish_transfer(master)
    when defined(gbLinkTrace):
      if (slave.serial.sc and 0x01) != 0: inc bothInternalCount
  when defined(gbLinkTrace):
    if onGbTransfer != nil:
      onGbTransfer(m, master_out, slave_out, slave.serial.sc, slave_got_irq)

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
  # NOTE on perfect symmetry: two cores fed BYTE-IDENTICAL state AND input
  # both choose the internal-clock master role on the same cycle and deadlock
  # (every transfer "both-internal", neither establishes) — real hardware
  # avoids this only because two units' independent oscillators drift. This
  # never happens in practice: distinct saves diverge immediately, and the
  # frontend drives the two players' input separately (browser click-to-focus
  # gives one core input at a time), which is enough asymmetry. Handled at the
  # input layer, deliberately not with an artificial in-core clock skew that
  # would perturb single-core-accurate timing.
