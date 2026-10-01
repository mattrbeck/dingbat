## DS event scheduler. One timeline in master cycles: the ARM9 clock
## (67.027964 MHz), twice the 33.513982 MHz system/bus clock that the ARM7,
## timers, DMA and display run from.
##
## Separate from common/scheduler.nim on purpose: that one's EventType enum
## ordinals are GB/GBA save-state format, and its CycleCount is 32-bit on
## wasm. The DS has no save-state format yet, so its events stay local until
## it does (docs/nds/spec.md, "Reuse").

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

  Pending = object
    at: int64
    kind: NdsEvent

  NdsScheduler* = ref object
    events: seq[Pending]      ## unsorted; there are ~a dozen at most
    now*: int64               ## master cycle the machine has reached

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

proc new_nds_scheduler*(): NdsScheduler = NdsScheduler()

proc schedule*(s: NdsScheduler; at: int64; kind: NdsEvent) =
  ## Book `kind` at absolute cycle `at`, replacing any pending booking.
  for e in s.events.mitems:
    if e.kind == kind:
      e.at = at
      return
  s.events.add(Pending(at: at, kind: kind))

proc cancel*(s: NdsScheduler; kind: NdsEvent) =
  for i in 0 ..< s.events.len:
    if s.events[i].kind == kind:
      s.events.del(i)
      return

proc is_scheduled*(s: NdsScheduler; kind: NdsEvent): bool =
  for e in s.events:
    if e.kind == kind: return true

proc next_at*(s: NdsScheduler): int64 =
  result = high(int64)
  for e in s.events:
    if e.at < result: result = e.at

proc pop_due*(s: NdsScheduler; kind: var NdsEvent; at: var int64): bool =
  ## The earliest event due at or before `now`, removed from the queue.
  var best = -1
  for i in 0 ..< s.events.len:
    if s.events[i].at <= s.now and (best < 0 or s.events[i].at < s.events[best].at):
      best = i
  if best < 0: return false
  kind = s.events[best].kind
  at = s.events[best].at
  s.events.del(best)
  true
