## DS event scheduler. One timeline in master cycles: the ARM9 clock
## (67.027964 MHz), twice the 33.513982 MHz system/bus clock that the ARM7,
## timers, DMA and display run from.
##
## Separate from common/scheduler.nim on purpose: that one's EventType enum
## ordinals are GB/GBA save-state format, and its CycleCount is 32-bit on
## wasm (docs/nds/spec.md, "Reuse"). The DS state (savestate.nim) stores
## the pending events in queue order with their absolute times; NdsEvent's
## members are part of its layout hash, so adding one refuses older states
## rather than misreading them.

type
  NdsEvent* = enum
    evHBlank        ## dot 256 of a line: H-blank flag, render, H-blank DMA
    evLineEnd       ## dot 355: next line, V-blank edges, VCOUNT match
    evTimer9_0, evTimer9_1, evTimer9_2, evTimer9_3
    evTimer7_0, evTimer7_1, evTimer7_2, evTimer7_3
    evCartDone      ## ROMCTRL transfer word ready / block done
    evGxFifo        ## geometry engine drain (gpu3d)
    evSpuSample     ## sound mixer tick (spu)
    evWifi          ## wifi timers / transmit end (io/wifi)
    evSpi           ## SPI transfer end: busy off, reply, IRQ (io/spi)
    evRtc           ## RTC /INT may change: alarm, minute, frequency (io/rtc)

  Pending = object
    at: int64
    kind: NdsEvent

  NdsScheduler* = ref object
    events: seq[Pending]      ## unsorted; there are ~a dozen at most
    now*: int64               ## master cycle the machine has reached
    next: int64               ## earliest `at` in events (high(int64) when empty)

const
  MASTER_HZ* = 67_027_964
  SYS_HZ* = MASTER_HZ div 2
  DOT_CYCLES* = 12            ## master cycles per dot (6 system cycles)
  LINE_DOTS* = 355
  LINE_CYCLES* = DOT_CYCLES * LINE_DOTS  ## 4260
  HBLANK_CYCLES* = 3212       ## H-blank flag rises 1606 bus cycles into a line
  LINES* = 263
  VISIBLE_LINES* = 192
  FRAME_CYCLES* = LINE_CYCLES * LINES    ## 1_120_380 -> 59.8261 Hz

proc new_nds_scheduler*(): NdsScheduler = NdsScheduler(next: high(int64))

proc refresh(s: NdsScheduler) {.inline.} =
  s.next = high(int64)
  for e in s.events:
    if e.at < s.next: s.next = e.at

proc schedule*(s: NdsScheduler; at: int64; kind: NdsEvent) =
  ## Book `kind` at absolute cycle `at`, replacing any pending booking.
  for e in s.events.mitems:
    if e.kind == kind:
      let was_next = e.at == s.next
      e.at = at
      if at < s.next: s.next = at
      elif was_next: s.refresh()
      return
  s.events.add(Pending(at: at, kind: kind))
  if at < s.next: s.next = at

proc cancel*(s: NdsScheduler; kind: NdsEvent) =
  for i in 0 ..< s.events.len:
    if s.events[i].kind == kind:
      s.events.del(i)
      s.refresh()
      return

proc is_scheduled*(s: NdsScheduler; kind: NdsEvent): bool =
  for e in s.events:
    if e.kind == kind: return true

proc next_at*(s: NdsScheduler): int64 {.inline.} = s.next

proc pop_due*(s: NdsScheduler; kind: var NdsEvent; at: var int64): bool =
  ## The earliest event due at or before `now`, removed from the queue.
  if s.next > s.now: return false
  var best = -1
  for i in 0 ..< s.events.len:
    if s.events[i].at <= s.now and (best < 0 or s.events[i].at < s.events[best].at):
      best = i
  if best < 0: return false
  kind = s.events[best].kind
  at = s.events[best].at
  s.events.del(best)
  s.refresh()
  true
