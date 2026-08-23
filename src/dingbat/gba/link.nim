# In-process lockstep link (docs/multiplayer.md).
#
# A Link owns N GBA cores and steps them in interleaved slices so no core
# runs more than ~LINK_SLICE cycles (plus one bounded step) ahead of the
# laggard. The initiating core of an SIO transfer schedules its completion
# through the normal etSerial path; when it fires, every peer is advanced
# to that cycle (run_to) before data latches and the transfer finishes on
# all cores at the same emulated time.
#
# Cross-core clock comparisons use int64 global time = per-core rebase
# offset + scheduler.cycles (CycleCount is uint32 on wasm).

import ../common/[scheduler, util]
import gba

const
  LINK_SLICE = 512
    ## Interleave granularity in cycles. Must stay well below the shortest
    ## multi-mode round (16 bits at 115.2 kbps = 2336 cycles) so a child is
    ## never a full round behind the parent when one starts.

type
  Link* = ref object
    cores*: seq[GBA]
    offsets: seq[int64]   # global(i) = offsets[i] + scheduler.cycles
    # Re-entrancy guard: core i is being advanced up the call stack, and
    # re-entering cpu.tick mid-instruction would corrupt it.
    active: seq[bool]
    frame_done: seq[bool]
    multi_active: bool
    multi_data: array[4, uint16]  # latched round words (0xFFFF = absent)
    # Count of SIO transfers initiated. Games drive these continuously while
    # linked and stop when done, so "not advancing" means the link is idle
    # (the mode register stays latched in multi mode afterwards).
    transfers*: int

  LockstepSioDriver* = ref object of SioDriver
    link: Link
    id: int  # cable position: 0 = multi-mode parent

when defined(linkTrace):
  # Trade-repro harness hooks: per completed multi round; per coalesced
  # serial IRQ; per single step longer than one multi round (2336 cycles).
  var onMultiRound*: proc(data: array[4, uint16]; multi: array[4, bool]) = nil
  var onCoalesce*: proc(core: int) = nil
  var onBigStep*: proc(g: GBA; dc: int; pc: uint32) = nil

# ---------------- clock plumbing ----------------

proc now(link: Link; i: int): int64 =
  link.offsets[i] + int64(link.cores[i].scheduler.cycles)

proc advance_once(gba: GBA) {.inline.} =
  # One bounded step. cpu.tick's halted branch drains events until wake or
  # frame end, which is unbounded for lockstep purposes, so fast_forward.
  when defined(linkTrace):
    let c0 = int64(gba.scheduler.cycles)
    let pc0 = gba.cpu.r[15]
  if gba.cpu.halted:
    gba.scheduler.fast_forward()
  else:
    gba.cpu.tick()
  when defined(linkTrace):
    if onBigStep != nil:
      let dc = int(int64(gba.scheduler.cycles) - c0)
      if dc > 2336:
        onBigStep(gba, dc, pc0)

proc run_to(link: Link; i: int; target: int64) =
  ## Advance core i until its global clock reaches `target`.
  if link.active[i]: return  # already being advanced up-stack
  let gba = link.cores[i]
  link.active[i] = true
  while link.offsets[i] + int64(gba.scheduler.cycles) < target:
    gba.advance_once()
  link.active[i] = false

proc step_frame*(link: Link) =
  ## Advance every core one video frame, always stepping the core with the
  ## smallest global clock. Frame boundaries land at the same global cycle
  ## on every core, so none enters the next frame early.
  for i in 0 ..< link.cores.len:
    link.frame_done[i] = false
    link.cores[i].frame_start_cycles = link.cores[i].scheduler.cycles
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
    let gba = link.cores[best]
    let local_target = gba.scheduler.cycles + CycleCount(LINK_SLICE)
    link.active[best] = true
    while gba.scheduler.cycles < local_target and gba.ppu.frame == 0:
      gba.advance_once()
    link.active[best] = false
    if gba.ppu.frame > 0:
      link.frame_done[best] = true
  for i in 0 ..< link.cores.len:
    link.offsets[i] += int64(link.cores[i].end_frame())

# ---------------- multi-player (16-bit) mode ----------------

proc start_multi(link: Link; parent: int) =
  # Parent start-bit rising edge: advance the children to the start cycle
  # and mark them busy. Words latch at completion (complete_multi).
  if link.multi_active: return  # hardware can't restart a round in flight
  link.multi_active = true
  inc link.transfers
  let start_t = link.now(parent)
  for i in 0 ..< link.cores.len:
    if i != parent:
      link.run_to(i, start_t)
      let serial = link.cores[i].serial
      if serial.sio_mode() == smMulti:
        serial.siocnt = serial.siocnt or 0x0080'u16  # children show busy
  let pserial = link.cores[parent].serial
  pserial.schedule_sio_completion(pserial.multi_transfer_cycles())

proc complete_multi(link: Link; parent: int) =
  # The parent's etSerial fired: every peer reaches the completion cycle
  # before data latches and IRQs fire.
  let serial = link.cores[parent].serial
  if not link.multi_active:
    # Mode was switched mid-flight; just clear busy on the initiator.
    serial.finish_sio_transfer()
    return
  let done_t = link.now(parent)
  for i in 0 ..< link.cores.len:
    if i != parent:
      link.run_to(i, done_t)
  # Latch SIOMLT_SEND at completion, not at the round's start: a unit whose
  # prior serial IRQ retires late would otherwise be sampled with a stale
  # word, which corrupts the partner's reassembled data.
  for slot in 0 ..< 4:
    link.multi_data[slot] = 0xFFFF'u16  # absent units read all-1s
  for i in 0 ..< link.cores.len:
    if i < 4 and link.cores[i].serial.sio_mode() == smMulti:
      link.multi_data[i] = link.cores[i].serial.siodata8
  for idx, core in link.cores:
    if core.serial.sio_mode() == smMulti:
      for slot in 0 ..< 4:
        core.serial.multi_recv[slot] = link.multi_data[slot]
      when defined(linkTrace):
        if onCoalesce != nil and core.interrupts.reg_if.serial and
           bit(core.serial.siocnt, 14):
          onCoalesce(idx)
      core.serial.finish_sio_transfer()
  # A peer that overshot this completion has not serviced the serial IRQ
  # yet; if the next transfer completed first the IF bit would merge and the
  # game's SIO handler would advance its command index once for two words
  # (the cross-game trade "communication error"). Drain each IRQ-driven peer
  # now, bounded to one transfer window and the frame.
  for i in 0 ..< link.cores.len:
    if i != parent and link.cores[i].serial.sio_mode() == smMulti and
       link.cores[i].interrupts.reg_ie.serial:
      let g = link.cores[i]
      let deadline = g.scheduler.cycles + CycleCount(2336)
      while g.interrupts.reg_if.serial and g.scheduler.cycles < deadline and
            g.ppu.frame == 0:
        advance_once(g)
  when defined(linkTrace):
    if onMultiRound != nil:
      var multi: array[4, bool]
      for i in 0 ..< min(4, link.cores.len):
        multi[i] = link.cores[i].serial.sio_mode() == smMulti
      onMultiRound(link.multi_data, multi)
  link.multi_active = false

# ---------------- normal (8/32-bit) mode ----------------

proc normal_peer(link: Link; m: int): int =
  # A normal-mode cable connects exactly two units.
  for i in 0 ..< link.cores.len:
    if i != m: return i
  -1

proc complete_normal(link: Link; m: int) =
  # Master completion: advance the slave to this cycle, then exchange
  # full-duplex. GBATEK: the master's clock shifts both registers whether or
  # not the slave set its start bit; the slave only gets busy-clear/IRQ if
  # it had started.
  let ms = link.cores[m].serial
  let p = link.normal_peer(m)
  if p < 0:
    ms.finish_sio_transfer()
    return
  link.run_to(p, link.now(m))
  let ps = link.cores[p].serial
  let is32 = ms.sio_mode() == smNormal32
  if ps.sio_mode() in {smNormal8, smNormal32}:
    if is32:
      swap ms.siodata32, ps.siodata32
    else:
      let mb = ms.siodata8 and 0x00FF'u16
      let pb = ps.siodata8 and 0x00FF'u16
      ms.siodata8 = (ms.siodata8 and 0xFF00'u16) or pb
      ps.siodata8 = (ps.siodata8 and 0xFF00'u16) or mb
    let slave_started = bit(ps.siocnt, 7)
    ms.finish_sio_transfer()
    if slave_started:
      ps.finish_sio_transfer()
  else:
    # Peer not listening on the serial lines: its SO floats high.
    if is32: ms.siodata32 = 0xFFFFFFFF'u32
    else: ms.siodata8 = ms.siodata8 or 0x00FF'u16
    ms.finish_sio_transfer()

# ---------------- driver methods ----------------

method sio_siocnt_status*(drv: LockstepSioDriver; serial: Serial; mode: SioMode): uint16 =
  case mode
  of smMulti:
    # GBATEK "SIO Multi-Player Mode": bit 2 SI = 0 parent / 1 child, bit 3
    # SD = 1 when all units are ready, bits 4-5 = unit ID, bit 6 error = 0.
    var v = uint16(drv.id and 3) shl 4
    if drv.id != 0: v = v or 0x0004'u16
    var all_ready = true
    for core in drv.link.cores:
      if core.serial.sio_mode() != smMulti:
        all_ready = false
        break
    if all_ready: v = v or 0x0008'u16
    v
  of smNormal8, smNormal32:
    # SI = the peer's SO (SIOCNT bit 3) while it is in a normal mode; else high.
    let p = drv.link.normal_peer(drv.id)
    if p >= 0:
      let ps = drv.link.cores[p].serial
      if ps.sio_mode() in {smNormal8, smNormal32}:
        if bit(ps.siocnt, 3): 0x0004'u16 else: 0x0000'u16
      else: 0x0004'u16
    else: 0x0004'u16
  else:
    procCall sio_siocnt_status(SioDriver(drv), serial, mode)

method sio_start*(drv: LockstepSioDriver; serial: Serial; mode: SioMode) =
  case mode
  of smNormal8, smNormal32:
    if bit(serial.siocnt, 0):  # internal clock: this unit is the master
      inc drv.link.transfers
      serial.schedule_sio_completion(serial.normal_transfer_cycles())
  of smMulti:
    if drv.id == 0:
      drv.link.start_multi(drv.id)
    else:
      # Children can't initiate; their start bit is a read-only busy flag.
      serial.siocnt = serial.siocnt and not 0x0080'u16
  else:
    discard

method sio_complete*(drv: LockstepSioDriver; serial: Serial; mode: SioMode) =
  case mode
  of smNormal8, smNormal32: drv.link.complete_normal(drv.id)
  of smMulti: drv.link.complete_multi(drv.id)
  else: serial.finish_sio_transfer()

# ---------------- construction ----------------

proc new_link*(cores: seq[GBA]): Link =
  ## Wire post_init cores into a lockstep link. Core 0 is the multi-mode parent.
  doAssert cores.len >= 2, "a link needs at least two cores"
  result = Link(
    cores:      cores,
    offsets:    newSeq[int64](cores.len),
    active:     newSeq[bool](cores.len),
    frame_done: newSeq[bool](cores.len),
  )
  for i, core in cores:
    core.set_sio_driver(LockstepSioDriver(link: result, id: i))

# ---------------- rollback support (see rollback.nim) ----------------
# Snapshots are valid at frame boundaries only (where state_payload is
# defined and where step_frame lands every core).

type
  LinkSnapshot* = object
    payloads: seq[string]           # each core's state_payload
    offsets: seq[int64]             # per-core global-clock rebase
    multi_active: bool              # in-flight multi round straddling the boundary
    multi_data: array[4, uint16]
    multi_recv: seq[array[4, uint16]] # each core's SIOMULTI0-3 receive latches

proc capture_state*(link: Link): LinkSnapshot =
  ## Frame-boundary only. `active`/`frame_done` are transient, so omitted.
  result.payloads = newSeq[string](link.cores.len)
  result.multi_recv = newSeq[array[4, uint16]](link.cores.len)
  for i, c in link.cores:
    result.payloads[i] = c.state_payload()
    # SIOMULTI0-3 latches are not in state_payload, but a rollback re-sim
    # can read them before the frame's round re-latches; without them the
    # replay diverges (in-game "communication error").
    result.multi_recv[i] = c.serial.multi_recv
  result.offsets = link.offsets
  result.multi_active = link.multi_active
  result.multi_data = link.multi_data

proc restore_state*(link: Link; s: LinkSnapshot) =
  ## Restore a snapshot from capture_state. Trusted in-process use only.
  doAssert s.payloads.len == link.cores.len, "snapshot core count mismatch"
  for i, c in link.cores:
    c.apply_state_payload(s.payloads[i])
    if i < s.multi_recv.len:
      c.serial.multi_recv = s.multi_recv[i]
  link.offsets = s.offsets
  link.multi_active = s.multi_active
  link.multi_data = s.multi_data

proc state_checksum*(link: Link): uint64 =
  ## FNV-1a over every core's serialized state, exchanged by peers to detect
  ## a desync. Covers only the cores: `offsets` is a local clock-rebase bias
  ## that legitimately differs between peers.
  result = 0xCBF29CE484222325'u64
  for c in link.cores:
    for ch in c.state_payload():
      result = (result xor uint64(byte(ch))) * 0x100000001B3'u64
