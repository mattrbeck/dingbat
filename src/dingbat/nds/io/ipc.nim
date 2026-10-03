## Inter-processor communication: IPCSYNC 0x4000180 (4-bit mailbox each
## way + IRQ request), IPCFIFOCNT 0x4000184, IPCFIFOSEND 0x4000188 and
## IPCFIFORECV 0x4100000 -- two 16-word FIFOs, one per direction.

import std/deques
import irq

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

type
  IpcEnd* = ref object
    ## One CPU's side. `send` is the FIFO this CPU writes; the other side's
    ## `recv` is the same deque.
    sync_out*: uint8          ## bits 8-11 written by this CPU
    sync_irq_enable*: bool    ## bit 14
    fifo_enable*: bool        ## IPCFIFOCNT bit 15
    send_empty_irq*, recv_irq*: bool  ## bits 2 / 10
    error*: bool              ## bit 14: read empty / write full
    last_recv*: uint32
    irq* {.cursor.}: IrqCtl

  Ipc* = ref object
    arm9*, arm7*: IpcEnd
    q*: array[2, Deque[uint32]]  ## [0] arm9 -> arm7, [1] arm7 -> arm9

proc new_ipc*(irq9, irq7: IrqCtl): Ipc =
  Ipc(arm9: IpcEnd(irq: irq9), arm7: IpcEnd(irq: irq7),
      q: [initDeque[uint32](16), initDeque[uint32](16)])

proc sides(p: Ipc; is9: bool): (IpcEnd, IpcEnd) =
  if is9: (p.arm9, p.arm7) else: (p.arm7, p.arm9)

template send_q(p: Ipc; is9: bool): untyped = p.q[if is9: 0 else: 1]
template recv_q(p: Ipc; is9: bool): untyped = p.q[if is9: 1 else: 0]

proc read_sync*(p: Ipc; is9: bool): uint32 =
  let (me, other) = p.sides(is9)
  uint32(other.sync_out and 0xF) or (uint32(me.sync_out) shl 8) or
    (if me.sync_irq_enable: 0x4000'u32 else: 0)

proc write_sync*(p: Ipc; is9: bool; v, mask: uint32) =
  let (me, other) = p.sides(is9)
  if (mask and 0xFF00) != 0:
    me.sync_out = uint8((v shr 8) and 0xF)
    me.sync_irq_enable = (v and 0x4000) != 0
    if (v and 0x2000) != 0 and other.sync_irq_enable:
      other.irq.raise_irq(irqIpcSync)

proc read_fifocnt*(p: Ipc; is9: bool): uint32 =
  let (me, _) = p.sides(is9)
  let s = p.send_q(is9).len
  let r = p.recv_q(is9).len
  result = (if s == 0: 1'u32 else: 0) or (if s >= 16: 2'u32 else: 0) or
           (if me.send_empty_irq: 4'u32 else: 0) or
           (if r == 0: 0x100'u32 else: 0) or (if r >= 16: 0x200'u32 else: 0) or
           (if me.recv_irq: 0x400'u32 else: 0) or
           (if me.error: 0x4000'u32 else: 0) or (if me.fifo_enable: 0x8000'u32 else: 0)

proc write_fifocnt*(p: Ipc; is9: bool; v, mask: uint32) =
  let (me, _) = p.sides(is9)
  if (mask and 0xFF) != 0:
    let was = me.send_empty_irq
    me.send_empty_irq = (v and 4) != 0
    let had = p.send_q(is9).len > 0
    if (v and 8) != 0: p.send_q(is9).clear()
    # IF.17 rises on the 0->1 edge of (enable and send-empty): enabling it
    # over an empty FIFO, or clearing a non-empty FIFO while enabled
    let empty = p.send_q(is9).len == 0
    if me.send_empty_irq and empty and (not was or had):
      me.irq.raise_irq(irqIpcSendEmpty)
  if (mask and 0xFF00) != 0:
    let was = me.recv_irq
    me.recv_irq = (v and 0x400) != 0
    if (v and 0x4000) != 0: me.error = false
    me.fifo_enable = (v and 0x8000) != 0
    if me.recv_irq and not was and p.recv_q(is9).len > 0:
      me.irq.raise_irq(irqIpcRecvNotEmpty)

proc send*(p: Ipc; is9: bool; v: uint32) =
  let (me, other) = p.sides(is9)
  if not me.fifo_enable: return
  let q = addr p.send_q(is9)
  if q[].len >= 16:
    me.error = true
    return
  let was_empty = q[].len == 0
  q[].addLast(v)
  if was_empty and other.recv_irq: other.irq.raise_irq(irqIpcRecvNotEmpty)

proc recv*(p: Ipc; is9: bool): uint32 =
  let (me, other) = p.sides(is9)
  let q = addr p.recv_q(is9)
  if not me.fifo_enable:
    return if q[].len > 0: q[].peekFirst else: me.last_recv
  if q[].len == 0:
    me.error = true
    return me.last_recv
  me.last_recv = q[].popFirst
  if q[].len == 0 and other.send_empty_irq: other.irq.raise_irq(irqIpcSendEmpty)
  me.last_recv

{.pop.}
