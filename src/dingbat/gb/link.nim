# In-process lockstep link between two GB/GBC cores (the GB analogue of
# gba/link.nim). The cores are stepped in interleaved LINK_SLICE-bounded
# slices; a serial transfer is resolved byte-at-a-time: the master shifts its
# 8 bits off its own DIV-derived clock (serial.nim), and on the 8th shift the
# coordinator advances the peer to that emulated time and exchanges bytes
# full-duplex. run_to() is the boundary a network transport would replace.
# Global time compares scheduler cycles, which count CPU cycles, so a
# double-speed CGB core skews the bound by 2x while the speeds differ.

import ../common/scheduler
import gb

const
  LINK_SLICE = 512
    ## Interleave granularity in cycles: one bit period at the normal clock,
    ## so the slave gets its staging window between rounds. CGB-fast
    ## transfers are shorter than the slice; run_to still drives the peer to
    ## the exact completion cycle before latching.

type
  GbLink* = ref object
    cores*: seq[GB]
    # global(i) = offsets[i] + scheduler.cycles, updated per-frame rebase.
    offsets: seq[int64]
    # Re-entrancy guard: core i is being advanced up-stack.
    active: seq[bool]
    frame_done: seq[bool]
    # Completed transfers; "not advancing" is the game-agnostic idle signal
    # (same contract as gba/link.nim).
    transfers*: int

  LockstepGbSerialDriver* = ref object of GbSerialDriver
    link: GbLink
    id: int

# ---------------- clock plumbing ----------------

proc now(link: GbLink; i: int): int64 =
  link.offsets[i] + int64(link.cores[i].scheduler.cycles)

proc run_to(link: GbLink; i: int; target: int64) =
  ## Advance core i until its global clock reaches `target` (the network
  ## transport boundary).
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
    # gb_rebase, not scheduler.rebase: the APU deadlines live outside the
    # event array (gb/apu.nim).
    link.offsets[i] += int64(link.cores[i].gb_rebase())

when defined(gbLinkTrace):
  # Debug hook: one call per completed transfer (compiled out normally).
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
  # Core m's internally-clocked transfer shifted its 8th bit: advance the
  # peer to this time and exchange bytes. The slave only gets completion
  # (SC.7 clear + IRQ) if it had started with the external clock.
  let master = link.cores[m]
  let p = link.peer_of(m)
  if p < 0:
    master.serial.serial_finish_transfer(master)
    return
  link.run_to(p, link.now(m))
  inc link.transfers
  let slave = link.cores[p]
  # Captured before the exchange rewrites SB; for the gbLinkTrace hook.
  let master_out {.used.} = master.serial.out_latch
  var slave_out = 0xFF'u8
  var slave_got_irq = false
  # Bytes are exchanged only with a LISTENING external-clock slave (SC.0 = 0,
  # SC.7 = 1). An unarmed peer is not driving SO, so the master clocks in
  # 0xFF; feeding it the peer's latched SB instead let games latch a
  # handshake byte the peer never sent (desync).
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

method serial_peer_committed*(drv: LockstepGbSerialDriver): bool =
  ## complete_transfer finished the transfer on BOTH cores, so this side
  ## cannot be rewound alone (base method in serial.nim).
  true

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
  # Two cores with byte-identical state AND input both pick the master role
  # on the same cycle and deadlock (hardware escapes via oscillator drift).
  # Distinct saves and per-player input are enough asymmetry; deliberately
  # not an artificial in-core clock skew.

# ---------------- rollback support ----------------
#
# Snapshots are valid at frame boundaries only. GB in-flight serial state is
# already inside each core's state_payload (GB_SEC_SER), so a snapshot is the
# two payloads plus the cross-core clock offsets.

type
  GbLinkSnapshot* = object
    payloads: seq[string]   # each core's state_payload
    offsets: seq[int64]     # per-core global-clock rebase
    transfers: int          # cable activity counter (kept so idle detection
                            # doesn't jump backwards across a rollback)

proc capture_state*(link: GbLink): GbLinkSnapshot =
  ## Frame-boundary only; `active`/`frame_done` are transient in step_frame.
  result.payloads = newSeq[string](link.cores.len)
  for i, c in link.cores:
    result.payloads[i] = c.state_payload()
  result.offsets = link.offsets
  result.transfers = link.transfers

proc restore_state*(link: GbLink; s: GbLinkSnapshot) =
  ## Restore a snapshot from capture_state. Trusted in-process use only.
  doAssert s.payloads.len == link.cores.len, "snapshot core count mismatch"
  for i, c in link.cores:
    c.apply_state_payload(s.payloads[i])
  link.offsets = s.offsets
  link.transfers = s.transfers

proc state_checksum*(link: GbLink): uint64 =
  ## FNV-1a over both cores' state, exchanged to detect a desync. `offsets`
  ## are a local rebase bias that differs between peers, so they are excluded.
  result = 0xCBF29CE484222325'u64
  for c in link.cores:
    for ch in c.state_payload():
      result = (result xor uint64(byte(ch))) * 0x100000001B3'u64
