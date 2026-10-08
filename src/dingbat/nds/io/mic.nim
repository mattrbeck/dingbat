## Microphone input: the frontend's sample stream, read by the touchscreen
## controller's AUX channel (GBATEK "DS Touch Screen Controller (TSC)",
## Microphone / AUX Channel). The DS samples the microphone only when the
## ARM7 asks the TSC for a conversion, so the stream is kept as a queue
## played out against emulated time: a conversion at master cycle t reads
## the stream where t has got to (linear between samples). An empty or
## run-dry queue is silence (0); a push longer than the queue's bound keeps
## all of it, so a whole recording can be pushed at once.

import ../sched
import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}

type
  Mic* = ref object
    buf: seq[int16]
    rd: int                   ## next whole sample
    acc: int64                ## fraction past `rd`, in 1/MASTER_HZ samples
    rate: int                 ## samples per second of the stream
    last: int64               ## master cycle the position was advanced to
    sched {.cursor.}: NdsScheduler

const
  MAX_LATENCY_DIV = 4         ## keep at most rate/4 (250 ms) queued, Assumed

proc new_mic*(sched: NdsScheduler): Mic = Mic(sched: sched)

proc advance(m: Mic) =
  let now = if m.sched != nil: m.sched.now else: 0'i64
  let dt = now - m.last
  m.last = now
  if dt <= 0 or m.rate <= 0 or m.rd >= m.buf.len: return
  m.acc += dt * int64(m.rate)
  let whole = m.acc div MASTER_HZ
  m.acc -= whole * MASTER_HZ
  if whole >= int64(m.buf.len - m.rd):
    m.rd = m.buf.len            # ran dry: the next push plays from its start
    m.acc = 0
  else:
    m.rd += int(whole)
  if m.rd >= 65536:
    m.buf = m.buf[m.rd .. ^1]
    m.rd = 0

proc push*(m: Mic; samples: openArray[int16]; rate: int) =
  ## Queue mono samples at `rate` Hz behind what is already queued.
  m.advance()
  if rate != m.rate:
    m.rate = rate
    m.acc = 0
  for s in samples: m.buf.add s
  let cap = max(rate div MAX_LATENCY_DIV, samples.len)
  if m.buf.len - m.rd > cap:
    m.rd = m.buf.len - cap
    m.acc = 0

proc clear*(m: Mic) =
  m.buf.setLen(0)
  m.rd = 0
  m.acc = 0

proc sample*(m: Mic): int =
  ## The input now, -32768..32767; 0 with nothing queued.
  m.advance()
  if m.rd >= m.buf.len: return 0
  let a = int(m.buf[m.rd])
  let b = if m.rd + 1 < m.buf.len: int(m.buf[m.rd + 1]) else: a
  a + int((int64(b - a) * m.acc) div MASTER_HZ)

proc queued*(m: Mic): int = m.buf.len - m.rd

{.pop.}
