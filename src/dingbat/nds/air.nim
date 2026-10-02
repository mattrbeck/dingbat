## Two or more DS in one process on one radio (io/wifi.nim's `Air`),
## stepped in lockstep so the frames one console transmits reach the others
## at their air time. docs/nds/wifi.md has the model.
##
## Every machine runs to the same master-cycle target before any goes
## further. A frame is posted when its carrier starts and first acts on a
## receiver after its preamble, 96 us at the least, so a quantum shorter than
## that keeps every delivery in the receiver's future: no rollback, no
## reordering, and the result does not depend on the order the machines run
## in a quantum.

import nds
import io/[wifi, spi]

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

const
  AIR_QUANTUM* = 4096'i64   ## master cycles per lockstep step: 61 us < 96 us

type
  AirLink* = ref object
    machines*: seq[NDS]
    air*: Air
    now*: int64             ## common master clock (every machine is here between steps)

proc firmware_with_mac*(fw: seq[uint8]; mac: array[6, uint8]): seq[uint8] =
  ## A copy of `fw` with another console MAC (firmware[036h]) and its wifi
  ## settings CRC16 (firmware[02Ah], initial value 0, over 02Ch..02Ch +
  ## [02Ch]-1: GBATEK "DS Firmware Header") made valid again, so two
  ## consoles in one process can have one dump and two addresses.
  result = fw
  if result.len < 0x200: return
  for i in 0..5: result[0x36 + i] = mac[i]
  let n = int(result[0x2C]) or (int(result[0x2D]) shl 8)
  if n > 0 and 0x2C + n <= result.len:
    let c = crc16(result.toOpenArray(0x2C, 0x2C + n - 1), 0)
    result[0x2A] = uint8(c and 0xFF)
    result[0x2B] = uint8(c shr 8)

proc new_air_link*(machines: seq[NDS]): AirLink =
  ## Join `machines` (built, not yet run apart: their clocks are taken as
  ## one) on a new Air.
  result = AirLink(machines: machines, air: new_air())
  for m in machines: result.now = max(result.now, m.sched.now)
  for m in machines:
    m.wifi.attach(result.air, m.spi.firmware, result.now - m.sched.now)

proc step*(l: AirLink; cycles: int64) =
  ## Advance every machine by `cycles`, in quanta.
  let target = l.now + cycles
  while l.now < target:
    let q = min(target, l.now + AIR_QUANTUM)
    for m in l.machines:
      m.run_until(q - m.wifi.air_offset)
    l.now = q

proc run_frames*(l: AirLink; frames: int) =
  ## Advance every machine by `frames` video frames (the machines started
  ## together, so their frames stay aligned).
  for _ in 0 ..< frames:
    for m in l.machines: m.frame_done = false
    l.step(FRAME_CYCLES)

{.pop.}
