## DS wifi (src/dingbat/nds/io/wifi.nim, nds/air.nim): consoles on one Air.
## First the wifi blocks alone, driven through their registers on their own
## schedulers (beacons, the address filter, ACKs and retries, the RX ring),
## then the wifi_link test ROM (tests/nds/src/wifi_link) on two whole
## machines in lockstep -- beacon scan, data frames both ways, multiplay
## rounds -- and on one machine alone. docs/nds/wifi.md has the model.
##
## Run with: nimble test_ndswifi   (the ROM part needs
## tests/nds/tools/build_wifi.sh; BIOS/firmware dumps from
## $DINGBAT_NDS_BIOS are used when present)

import std/[os, strutils]
import dingbat/nds/[nds, air]
import dingbat/nds/io/[irq, wifi]

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

proc hex(v: SomeInteger): string = "0x" & toHex(uint64(v), 8)

# ---------------------------------------------------------------------------
# Wifi blocks alone

type Station = object
  s: NdsScheduler
  w: Wifi

proc new_station(air: Air; mac: array[6, uint8]; fw: seq[uint8] = @[]): Station =
  result.s = new_nds_scheduler()
  result.w = new_wifi(result.s, IrqCtl())
  if air != nil: result.w.attach(air, fw)
  let w = result.w
  for i in 0..2: w.write16(0x04808018'u32 + uint32(2 * i), uint16(mac[2 * i]) or (uint16(mac[2 * i + 1]) shl 8))
  # GBATEK "DS Wifi Initialization", the parts the model looks at
  w.write16(0x04808036'u32, 0)          # W_POWER_US: on
  w.write16(0x04808030'u32, 0x8000)
  w.write16(0x04808050'u32, 0x4C00)     # RX ring 0C00h..1F60h
  w.write16(0x04808052'u32, 0x5F60)
  w.write16(0x04808056'u32, 0x0600)
  w.write16(0x0480805A'u32, 0x0600)
  w.write16(0x04808030'u32, 0x8001)
  w.write16(0x048080D0'u32, 0x0001)     # other BSSs' beacons
  w.write16(0x048080E0'u32, 0x0008)
  w.write16(0x04808004'u32, 1)          # W_MODE_RST
  w.write16(0x048080E8'u32, 1)          # W_US_COUNTCNT
  w.write16(0x0480803C'u32, 2)          # power up -> RX
  w.write16(0x04808010'u32, 0xFFFF)

proc run(st: var openArray[Station]; until: int64) =
  ## Lockstep in AIR_QUANTUM steps, each block's events at their times.
  var t = 0'i64
  for x in st: t = max(t, x.s.now)
  while t < until:
    let q = min(until, t + AIR_QUANTUM)
    for x in st:
      while x.s.next_at() <= q:
        x.s.now = max(x.s.now, x.s.next_at())
        var ev: NdsEvent
        var at: int64
        while x.s.pop_due(ev, at):
          if ev == evWifi: x.w.on_event()
      x.s.now = q
    t = q

proc us(n: int64): int64 = (n * MASTER_HZ + 999_999) div 1_000_000

proc put_frame(w: Wifi; off: int; fc: uint16; a1, a2, a3: array[6, uint8];
               body: openArray[uint8]; rate = 0x14'u16) =
  ## TX header + IEEE header + body at wifi RAM byte offset `off`.
  var b = newSeq[uint8](12 + 24 + body.len)
  b[8] = uint8(rate)
  let n = 24 + body.len + 4
  b[10] = uint8(n and 0xFF); b[11] = uint8(n shr 8)
  b[12] = uint8(fc and 0xFF); b[13] = uint8(fc shr 8)
  for i in 0..5:
    b[16 + i] = a1[i]; b[22 + i] = a2[i]; b[28 + i] = a3[i]
  for i, x in body: b[36 + i] = x
  if b.len mod 2 == 1: b.add 0
  for i in countup(0, b.len - 1, 2):
    w.write16(0x04804000'u32 + uint32(off + i), uint16(b[i]) or (uint16(b[i + 1]) shl 8))

proc rd(w: Wifi; o: int): uint16 = w.read16(0x04808000'u32 + uint32(o))
proc ram16(w: Wifi; byte_off: int): uint16 = w.ram[(byte_off shr 1) and 0xFFF]

const
  MAC_A = [0x00'u8, 0x09, 0xBF, 0x00, 0x00, 0xA1]
  MAC_B = [0x00'u8, 0x09, 0xBF, 0x00, 0x00, 0xB2]
  MAC_X = [0x00'u8, 0x09, 0xBF, 0x00, 0x00, 0xEE]
  BCAST = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

block beacon_and_filter:
  echo "beacons over the air"
  let air = new_air()
  var st = [new_station(air, MAC_A), new_station(air, MAC_B), new_station(air, MAC_X)]
  let a = st[0].w
  # A beacons every 16 "ms"
  var body = newSeq[uint8](12 + 4)
  body[8] = 16; body[10] = 0x21
  body[12] = 1; body[13] = 2; body[14] = 0x82; body[15] = 0x84
  a.put_frame(0, 0x0080, BCAST, MAC_A, MAC_A, body)
  a.write16(0x04808020'u32, 0x0900)   # BSSID = own MAC
  a.write16(0x04808022'u32, 0x00BF)
  a.write16(0x04808024'u32, 0xA100)
  a.write16(0x0480808C'u32, 16)
  a.write16(0x0480811C'u32, 16)
  a.write16(0x048080EA'u32, 1)
  a.write16(0x04808008'u32, 0x8000)   # TXSTAT + IRQ01 after beacons
  a.write16(0x04808080'u32, 0x8000)
  # X filters other BSSs out (RXFILTER bit 0 clear)
  st[2].w.write16(0x048080D0'u32, 0)
  st.run(us(40_000))
  let b = st[1].w
  let wr = int(b.rd(0x054))
  check wr != 0x600, "B stored A's beacons", "WRCSR " & hex(wr)
  let hdr = 0xC00
  check b.ram16(hdr) == 0x0011, "RXHDR[00h] = 0011h: beacon, other BSS", hex(b.ram16(hdr))
  check b.ram16(hdr + 6) == 0x14 and b.ram16(hdr + 8) == 24 + 16,
        "RXHDR rate 2 Mbit/s, length = header + body (no FCS)"
  check b.ram16(hdr + 12) == 0x0080 and b.ram16(hdr + 12 + 10) == 0x0900,
        "frame control and source address as sent"
  let ts0 = uint32(b.ram16(hdr + 36)) or (uint32(b.ram16(hdr + 38)) shl 16)
  let next = hdr + 12 + ((24 + 16 + 3) and not 3)
  let ts1 = uint32(b.ram16(next + 36)) or (uint32(b.ram16(next + 38)) shl 16)
  check ts1 - ts0 == 16 * 1024, "beacon timestamps 16 x 1024 us apart", $(ts1 - ts0)
  check (b.rd(0x010) and 0x41) == 0x41, "B: IRQ06 and IRQ00"
  check (a.rd(0x010) and 0x4082) == 0x4082 and a.rd(0x0B8) == 0x0301,
        "A: IRQ14, IRQ07, IRQ01 and W_TXSTAT 0301h"
  check st[2].w.rd(0x054) == 0x600, "X (RXFILTER bit 0 clear) ignores another BSS's beacon"
  # a different channel hears nothing
  let air2 = new_air()
  var fw = newSeq[uint8](0x200)
  fw[0x40] = 2
  for ch in 1..14:
    let e = (5'u32 shl 18) or uint32(0x1700 + ch)
    for k in 0..2: fw[0xF2 + (ch - 1) * 6 + k] = uint8((e shr (8 * k)) and 0xFF)
  var st2 = [new_station(air2, MAC_A, fw), new_station(air2, MAC_B, fw)]
  for (i, ch) in [(0, 1), (1, 7)]:
    st2[i].w.write16(0x0480817E'u32, uint16(0x1700 + ch))
    st2[i].w.write16(0x0480817C'u32, 0x0014)          # RF[05h] from the table
  check st2[0].w.channel == 1 and st2[1].w.channel == 7, "channel from the firmware RF table"
  let a2 = st2[0].w
  a2.put_frame(0, 0x0080, BCAST, MAC_A, MAC_A, body)
  a2.write16(0x0480808C'u32, 16); a2.write16(0x0480811C'u32, 16)
  a2.write16(0x048080EA'u32, 1); a2.write16(0x04808080'u32, 0x8000)
  st2.run(us(40_000))
  check st2[1].w.rd(0x054) == 0x600, "a console on channel 7 does not hear channel 1"

block unicast_ack:
  echo "station frames: ACK and retries"
  let air = new_air()
  var st = [new_station(air, MAC_A), new_station(air, MAC_B)]
  let a = st[0].w
  let body = [0x50'u8, 0x49, 0x4E, 0x47]
  # to B: received and ACKed on the first try
  a.put_frame(0x200, 0x0108, MAC_B, MAC_A, MAC_B, body)
  a.write16(0x0480802C'u32, 0x0707)
  a.write16(0x048080A0'u32, 0x8100)
  a.write16(0x048080AE'u32, 1)
  st.run(us(5_000))
  check a.ram16(0x200) == 0x0001 and a.rd(0x0B8) == 0x0001, "TXHDR 0001h, W_TXSTAT 0001h: ACKed"
  check (a.rd(0x02C) and 0xFF) == 7, "no retry used"
  check (st[1].w.ram16(0xC00) and 0x800F) == 0x0008, "B stored a data frame (no BSSID match)"
  # to a station nobody is: 1 + 7 tries, then status 0003h
  a.write16(0x04808010'u32, 0xFFFF)
  a.put_frame(0x200, 0x0108, MAC_X, MAC_A, MAC_X, body)
  let t0 = st[0].s.now
  a.write16(0x048080A0'u32, 0x8100)
  a.write16(0x048080AE'u32, 1)
  var done_at = 0'i64
  while done_at == 0 and st[0].s.now < t0 + us(20_000):
    st.run(st[0].s.now + AIR_QUANTUM)
    if (a.rd(0x0A0) and 0x8000) == 0: done_at = st[0].s.now
  let tries = 8'i64
  let per = 192 + (24 + 4 + 4) * 4 + 10 + 192 + 14 * 4   # frame + ACK timeout, us
  let took = (done_at - t0) * 1_000_000 div MASTER_HZ
  check a.ram16(0x200) == 0x0003 and (a.rd(0x0B8) and 3) == 3, "unanswered: TXHDR 0003h, W_TXSTAT failed"
  check abs(took - tries * per) <= 70, "8 attempts of frame + ACK timeout",
        $took & " us vs " & $(tries * per)
  check a.rd(0x1C0) == 8, "W_TX_ERR_COUNT counts every missed ACK", $a.rd(0x1C0)

block rx_ring:
  echo "RX ring"
  let air = new_air()
  var st = [new_station(air, MAC_A), new_station(air, MAC_B)]
  let a = st[0].w
  let b = st[1].w
  # a small ring at 1000h..1040h: room for one 52-byte entry, not two
  b.write16(0x04808050'u32, 0x5000)
  b.write16(0x04808052'u32, 0x5040)
  b.write16(0x04808056'u32, 0x0800)
  b.write16(0x0480805A'u32, 0x0800)
  b.write16(0x04808030'u32, 0x8001)
  var body = newSeq[uint8](16)
  for i in 0 ..< 16: body[i] = uint8(0xA0 + i)
  for n in 0..1:
    a.put_frame(0x200, 0x0108, MAC_B, MAC_A, MAC_B, body)
    a.write16(0x048080A0'u32, 0x8100)
    a.write16(0x048080AE'u32, 1)
    st.run(st[0].s.now + us(6_000))
  check b.rd(0x054) == 0x800 + (12 + 40) div 2, "first frame stored, WRCSR after it"
  # a dropped frame is not ACKed, so every try is dropped again
  check (b.rd(0x1B4) and 0xFF) == 8 and a.ram16(0x200) == 3,
        "second dropped on all 8 tries (W_RXSTAT RXBUF-full count), sender fails"
  # read it back through W_RXBUF_RD_DATA across the END -> BEGIN wrap
  b.write16(0x0480805A'u32, 0x0800 + 26)
  a.put_frame(0x200, 0x0108, MAC_B, MAC_A, MAC_B, body)
  a.write16(0x048080A0'u32, 0x8100)
  a.write16(0x048080AE'u32, 1)
  st.run(st[0].s.now + us(6_000))
  b.write16(0x04808058'u32, 0x1034)       # second entry starts at 1034h
  var got: seq[uint16]
  for i in 0 ..< 6: got.add b.rd(0x060)
  check got[0] == 0x0018 and got[4] == 40, "RX header read through RD_DATA", $got
  check b.rd(0x058) == 0x1000, "RD_ADDR wrapped END -> BEGIN", hex(b.rd(0x058))

# ---------------------------------------------------------------------------
# The wifi_link ROM on whole machines

let roms = getEnv("DINGBAT_NDS_ROMS", getHomeDir() / ".cache/dingbat-nds/roms")
let rom_path = roms / "wifi_link.nds"
let bios_dir = getEnv("DINGBAT_NDS_BIOS")

proc readbytes(p: string): seq[uint8] =
  if p.len == 0 or not fileExists(p): return @[]
  cast[seq[uint8]](readFile(p))

proc res(n: NDS; i: int): uint32 =
  let o = 0x200000 + 4 * i
  uint32(n.main_ram[o]) or (uint32(n.main_ram[o + 1]) shl 8) or
    (uint32(n.main_ram[o + 2]) shl 16) or (uint32(n.main_ram[o + 3]) shl 24)

const RES_MAGIC = 0x49464957'u32

if not fileExists(rom_path):
  echo "wifi_link ROM: missing (", rom_path, "; tests/nds/tools/build_wifi.sh), skipped"
else:
  let rom = readbytes(rom_path)
  let b9 = readbytes(if bios_dir.len > 0: bios_dir / "bios9.bin" else: "")
  let b7 = readbytes(if bios_dir.len > 0: bios_dir / "bios7.bin" else: "")
  var fw = readbytes(if bios_dir.len > 0: bios_dir / "firmware.bin" else: "")
  if fw.len == 0: fw = synth_firmware()
  var mac2: array[6, uint8]
  for i in 0..5: mac2[i] = fw[0x36 + i]
  mac2[5] = mac2[5] xor 0x5A

  proc machine(fw: seq[uint8]; host: bool): NDS =
    result = new_nds(rom, b9, b7, fw)
    if host: result.set_button(nbA, true)

  block two_consoles:
    echo "wifi_link: host + client"
    let host = machine(fw, true)
    let client = machine(firmware_with_mac(fw, mac2), false)
    let link = new_air_link(@[host, client])
    var f = 0
    while f < 900 and (host.res(0) != RES_MAGIC or client.res(0) != RES_MAGIC):
      link.run_frames(1)
      inc f
      if f == 10: host.set_button(nbA, false)
    echo "  (", f, " frames, ", link.air.frames, " frames on the air, ", link.air.late, " late)"
    check host.res(0) == RES_MAGIC and client.res(0) == RES_MAGIC, "both finished"
    check host.res(1) == 1 and client.res(1) == 2, "roles from the A button"
    check (host.res(2) shr 24) == uint32(mac2[5]) and (client.res(2) shr 24) == uint32(fw[0x3B]),
          "each learnt the other's MAC", hex(host.res(2)) & " " & hex(client.res(2))
    check host.res(3) >= 3, "host: beacon timeslots", $host.res(3)
    check (host.res(4) and 0xFFFF) == 0x0301 and (host.res(4) shr 16) == 1,
          "host: beacon W_TXSTAT 0301h, TXHDR 0001h", hex(host.res(4))
    check abs(int64(host.res(5)) - 0x40 * 1024) <= 40, "host: beacons 64 x 1024 us apart", $host.res(5)
    check abs(int64(host.res(6)) - 88 * 4) <= 40, "host: beacon IRQ07 -> IRQ01 = 88 bytes at 2 Mbit/s",
          $host.res(6)
    check client.res(3) >= 2, "client: beacons received", $client.res(3)
    check (client.res(4) and 0xFFFF) == 0x0011 and (client.res(4) shr 16) == 0x14,
          "client: beacon RXHDR 0011h at 2 Mbit/s", hex(client.res(4))
    check client.res(5) == 84, "client: beacon length 84 (88 less FCS)", $client.res(5)
    check client.res(6) == 0x40 * 1024, "client: timestamps 64 x 1024 us apart", $client.res(6)
    check client.res(7) == 0x0040D1B5'u32, "client: game ID from the Nintendo tag", hex(client.res(7))
    check (client.res(8) and 0xFFFF) == 0x000F, "client: 4 PINGs ACKed", hex(client.res(8))
    check (host.res(7) and 0xFFFF) == 4 and (host.res(7) shr 16) == 0x8018,
          "host: 4 PINGs, RXHDR 8018h (data, own BSS)", hex(host.res(7))
    check (host.res(8) and 0xFFFF) == 0x000F, "host: 4 PONGs ACKed", hex(host.res(8))
    check (client.res(9) and 0xFFFF) == 4 and client.res(10) == 3, "client: 4 PONGs, the last for PING 3",
          hex(client.res(9)) & " " & hex(client.res(10))
    check (host.res(9) and 0xFF) == 8 and ((host.res(9) shr 16) and 0xFF) == 8,
          "host: 8 multiplay rounds okay, 8 REPLYs", hex(host.res(9))
    check (host.res(10) and 0xFFFF) == 0x801E and (host.res(10) shr 16) == 28,
          "host: REPLY RXHDR 801Eh, 28 bytes", hex(host.res(10))
    check host.res(11) == 0x52504C07'u32, "host: last REPLY carries the client's 8th payload",
          hex(host.res(11))
    check (host.res(13) and 0xFFFF) == 0 and (host.res(13) shr 16) == 0x0B01,
          "host: no slave missed, W_TXSTAT 0B01h after the ACK", hex(host.res(13))
    check (client.res(11) and 0xFFFF) == 8 and (client.res(11) shr 16) == 0x801C,
          "client: 8 CMDs, RXHDR 801Ch", hex(client.res(11))
    check client.res(12) == 0x434D4407'u32, "client: last CMD payload", hex(client.res(12))
    check (client.res(13) and 0xFFFF) == 8 and (client.res(13) shr 16) == 0x801D,
          "client: 8 CMD ACKs, RXHDR 801Dh", hex(client.res(13))
    check link.air.late == 0, "no frame reached a receiver late"
    # the same run with the machines stepped in the other order inside each
    # quantum: identical results (docs/nds/wifi.md, Lockstep)
    let host2 = machine(fw, true)
    let client2 = machine(firmware_with_mac(fw, mac2), false)
    let link2 = new_air_link(@[client2, host2])
    for g in 0 ..< f:
      link2.run_frames(1)
      if g + 1 == 10: host2.set_button(nbA, false)
    var same = link2.air.frames == link.air.frames
    for i in 0 ..< 24:
      if host2.res(i) != host.res(i) or client2.res(i) != client.res(i): same = false
    check same and host2.main_ram == host.main_ram and client2.main_ram == client.main_ram,
          "machine order inside a quantum does not change anything"

  block host_alone:
    echo "wifi_link: host alone"
    let host = machine(fw, true)
    var f = 0
    while f < 900 and host.res(0) != RES_MAGIC:
      host.run_frame()
      inc f
    check host.res(0) == RES_MAGIC, "finished", $f & " frames"
    check (host.res(4) and 0xFFFF) == 0x0301, "beacons still go out", hex(host.res(4))
    check (host.res(9) shr 8 and 0xFF) == 8 and (host.res(13) and 0xFFFF) == 2,
          "every CMD round: TXHDR 0005h, slave 1 missing", hex(host.res(9)) & " " & hex(host.res(13))

  block client_alone:
    echo "wifi_link: client alone"
    let client = machine(fw, false)
    var f = 0
    while f < 900 and client.res(0) != RES_MAGIC:
      client.run_frame()
      inc f
    check client.res(0) == RES_MAGIC, "finished", $f & " frames"
    check client.res(3) == 0, "no beacons"
    check (client.res(8) and 0x1FF) == 0x100, "the PING fails (TXHDR 0003h)", hex(client.res(8))
    check client.res(15) == 8, "W_TX_ERR_COUNT 8", $client.res(15)

if failures > 0:
  echo failures, " FAILED"
  quit 1
echo "all passed"
