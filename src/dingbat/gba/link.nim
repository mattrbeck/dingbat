# In-process lockstep link (phase 2 of docs/multiplayer.md).
#
# A Link owns N GBA cores and steps them in bounded, interleaved slices so
# no core's emulated clock gets ahead of the laggard by more than roughly
# LINK_SLICE cycles (plus bounded overshoot: one instruction, one DMA burst,
# or one halted fast-forward to the next scheduled event — PPU events cap
# that at ~1232 cycles). SIO transfers are resolved by the LockstepSioDriver
# bound to each core:
#
#  - The initiating core (multi-mode parent, or normal-mode internal-clock
#    master) schedules its completion through the normal etSerial path, so
#    completion timing/IRQ on the initiator is exactly the single-core
#    behavior.
#  - When that completion fires, the coordinator first advances every peer
#    core to the initiator's clock (run_to), then latches data and finishes
#    the transfer on every participating core at the same emulated time.
#    run_to is the single point a future network transport replaces: for a
#    remote peer, "advance peer to cycle X" becomes "block until the peer
#    reports it has reached cycle X".
#
# Cross-core clock comparisons use int64 global time = per-core rebase
# offset + scheduler.cycles; the per-frame rebase (gba.end_frame) feeds the
# offsets, so comparisons stay valid even though CycleCount is uint32 on
# wasm. Schedulers stay strictly per-core.

import ../common/[scheduler, util]
import gba

const
  LINK_SLICE = 512
    ## Interleave granularity in cycles. Must be comfortably below the
    ## shortest multi-mode round (16 bits at 115.2 kbps = 2336 cycles) so a
    ## child is never a full transfer behind the parent when a round starts,
    ## and small enough that data sampled "now" from a slightly-ahead peer
    ## is within one round of hardware truth. Normal-mode 8-bit fast
    ## transfers (72 cycles) are shorter than the window; their data is
    ## still exchanged at the exact completion cycle because run_to drives
    ## the peer forward before latching.

type
  Link* = ref object
    cores*: seq[GBA]
    # Global-time bookkeeping: global(i) = offsets[i] + scheduler.cycles.
    # Updated with each core's per-frame rebase base.
    offsets: seq[int64]
    # Re-entrancy guard: true while core i is being advanced somewhere up
    # the call stack (its clock is already within the lockstep window, and
    # re-entering cpu.tick mid-instruction would corrupt it).
    active: seq[bool]
    frame_done: seq[bool]
    # In-flight multi-mode round: values sampled from each unit's
    # SIOMLT_SEND at the round's start time (0xFFFF = absent).
    multi_active: bool
    multi_data: array[4, uint16]

  LockstepSioDriver* = ref object of SioDriver
    link: Link
    id: int  # cable position: 0 = multi-mode parent

# ---------------- clock plumbing ----------------

proc now(link: Link; i: int): int64 =
  link.offsets[i] + int64(link.cores[i].scheduler.cycles)

proc advance_once(gba: GBA) {.inline.} =
  # One bounded step: an instruction, or — when halted — a jump to the next
  # scheduled event. Never uses cpu.tick's halted branch, which drains
  # events until wake or frame end (unbounded for lockstep purposes).
  if gba.cpu.halted:
    gba.scheduler.fast_forward()
  else:
    gba.cpu.tick()

proc run_to(link: Link; i: int; target: int64) =
  ## Advance core i until its global clock reaches `target`.
  ##
  ## NETWORK-TRANSPORT BOUNDARY (phase 3): for a remote peer this is the
  ## one blocking step — "wait until peer i confirms it has reached cycle
  ## `target` and hand over its SIO state" — everything else in this module
  ## stays local.
  if link.active[i]: return  # already being advanced up-stack; its clock is
                             # within the lockstep window by construction
  let gba = link.cores[i]
  link.active[i] = true
  while link.offsets[i] + int64(gba.scheduler.cycles) < target:
    gba.advance_once()
  link.active[i] = false

proc step_frame*(link: Link) =
  ## Advance every core by one video frame, interleaved in bounded slices:
  ## always advance the core with the smallest global clock, so skew never
  ## exceeds LINK_SLICE plus bounded overshoot. Frame boundaries land at the
  ## same global cycle on every core (280896 cycles from reset), so no core
  ## enters the next frame while another still runs the current one.
  for i in 0 ..< link.cores.len:
    link.frame_done[i] = false
    link.cores[i].cpu.count_cycles = 0
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
    while gba.scheduler.cycles < local_target and not gba.ppu.frame:
      gba.advance_once()
    link.active[best] = false
    if gba.ppu.frame:
      link.frame_done[best] = true
  for i in 0 ..< link.cores.len:
    link.offsets[i] += int64(link.cores[i].end_frame())

# ---------------- multi-player (16-bit) mode ----------------

proc start_multi(link: Link; parent: int) =
  # The parent's start-bit rising edge opens a round. Sample every unit's
  # SIOMLT_SEND at the round's start time (hardware latches the outgoing
  # word when the parent's clock starts driving) and mark children busy.
  if link.multi_active: return  # hardware can't restart a round in flight
  link.multi_active = true
  let start_t = link.now(parent)
  for slot in 0 ..< 4:
    link.multi_data[slot] = 0xFFFF'u16  # absent units read all-1s
  for i in 0 ..< link.cores.len:
    if i != parent:
      link.run_to(i, start_t)
    let serial = link.cores[i].serial
    if i < 4 and serial.sio_mode() == smMulti:
      link.multi_data[i] = serial.siodata8
      if i != parent:
        serial.siocnt = serial.siocnt or 0x0080'u16  # children show busy
  let pserial = link.cores[parent].serial
  pserial.schedule_sio_completion(pserial.multi_transfer_cycles())

proc complete_multi(link: Link; parent: int) =
  # The parent's etSerial fired: every peer must reach the completion cycle
  # before data latches and IRQs fire (deferred-completion discipline; see
  # run_to for the phase-3 network boundary).
  let serial = link.cores[parent].serial
  if not link.multi_active:
    # Mode was switched mid-flight; just clear busy on the initiator.
    serial.finish_sio_transfer()
    return
  let done_t = link.now(parent)
  for i in 0 ..< link.cores.len:
    if i != parent:
      link.run_to(i, done_t)
  for core in link.cores:
    if core.serial.sio_mode() == smMulti:
      for slot in 0 ..< 4:
        core.serial.multi_recv[slot] = link.multi_data[slot]
      # Clears busy and raises the serial IRQ per-core if that core
      # enabled it — all at the same emulated time.
      core.serial.finish_sio_transfer()
  link.multi_active = false

# ---------------- normal (8/32-bit) mode ----------------

proc normal_peer(link: Link; m: int): int =
  # A normal-mode cable connects exactly two units; with N=2 the peer is
  # simply the other core. (>2 cores in normal mode has no hardware analog.)
  for i in 0 ..< link.cores.len:
    if i != m: return i
  -1

proc complete_normal(link: Link; m: int) =
  # The master's internally-clocked transfer completed. Advance the slave to
  # the completion cycle (deferred completion; network boundary in run_to),
  # then exchange full-duplex: each unit's outgoing register lands in the
  # other's. Per GBATEK the master's clock shifts both registers whether or
  # not the slave set its start bit — the slave only gets busy-clear/IRQ
  # semantics if it had actually started (SO/SI handshaking is up to games).
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
    # GBATEK "SIO Multi-Player Mode": bit 2 SI = 0 parent / 1 child (cable
    # position), bit 3 SD = 1 when all units on the bus are ready (in multi
    # mode), bits 4-5 = this unit's ID, bit 6 error = 0.
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
    # Bit 2 SI input = the peer's SO output (SIOCNT bit 3) while the peer
    # sits in a normal serial mode; otherwise the line floats high.
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
    if bit(serial.siocnt, 0):
      # Internal clock: this unit is the master and drives the exchange.
      serial.schedule_sio_completion(serial.normal_transfer_cycles())
    # External clock: the transfer runs when the master starts one.
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
  ## Wire already-initialized (post_init) cores into a lockstep link. Core 0
  ## is the multi-mode parent (head of the cable).
  doAssert cores.len >= 2, "a link needs at least two cores"
  result = Link(
    cores:      cores,
    offsets:    newSeq[int64](cores.len),
    active:     newSeq[bool](cores.len),
    frame_done: newSeq[bool](cores.len),
  )
  for i, core in cores:
    core.set_sio_driver(LockstepSioDriver(link: result, id: i))
