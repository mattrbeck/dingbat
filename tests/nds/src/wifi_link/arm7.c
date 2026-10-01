/* wifi_link ARM7: two DS talking over the wifi hardware, programmed from
   GBATEK's "DS Wifi" chapters with no library. Both consoles run this ROM;
   one holding A at boot is the host, the other the client.

   Host: beacons (W_TXBUF_BEACON, Nintendo tag DDh with game ID 0040D1B5h),
   answers each client data frame ("PING" k, LOC1) with one of its own
   ("PONG" k), then runs 8 multiplay rounds (W_TXBUF_CMD) addressed to slave
   1 and reads the replies.
   Client: scans for the beacon (W_RXFILTER bit 0), takes the host as BSSID,
   sends 4 PINGs and waits for each PONG, then becomes multiplay slave 1
   (W_AID_LOW) with a REPLY queued in W_TXBUF_REPLY1 for every CMD.

   Alone, each role still finishes (timeouts): the host's beacons and the
   CMD rounds without replies, the client's unanswered PINGs, all timed with
   W_US_COUNT -- the single-console behaviour docs/oracles.md compares.

   Results (wl.h RES), common:
     [0] 'WIFI' when done   [1] role: 1 host, 2 client
     [2] firmware[040h] | channel << 8 | own MAC[5] << 16 | peer MAC[5] << 24
   host:
     [3] IRQ14s (beacon timeslots) seen
     [4] W_TXSTAT after the first beacon | beacon TXHDR[00h] << 16
     [5] us between the first two beacons' IRQ07
     [6] us from a beacon's IRQ07 to its IRQ01
     [7] PINGs received | last PING RXHDR[00h] << 16
     [8] PONG results: bit k TXHDR[00h] = 1 (ACKed), bit 8+k = 3 (failed)
     [9] CMD rounds: [0:7] okay (status 1, no error flags), [8:15] status 5,
         [16:23] REPLY frames received
     [10] last REPLY RXHDR[00h] | RXHDR[08h] (length) << 16
     [11] last REPLY payload   [12] us from CMD request to IRQ12, round 0
     [13] last CMD TXHDR[02h] (slaves that missed) | W_TXSTAT << 16
     [14] us from CMD request to IRQ12, last round
   client:
     [3] beacons received   [4] first beacon RXHDR[00h] | RXHDR[06h] << 16
     [5] first beacon RXHDR[08h] (length)
     [6] us between the first two beacons' timestamps   [7] beacon game ID
     [8] PING results (as host [8])
     [9] PONGs received | last PONG RXHDR[00h] << 16   [10] last PONG payload
     [11] CMDs received | CMD RXHDR[00h] << 16   [12] last CMD payload
     [13] CMD ACKs received | ACK RXHDR[00h] << 16
     [14] us from PING 0 request to its end (all retries when alone)
     [15] W_TX_ERR_COUNT read after the PINGs
*/
#include "wl.h"

#define W(o) REG16(0x04808000u + (o))
#define WRAM(o) REG16(0x04804000u + (o)) /* byte offset into wifi RAM, even */
#define POWCNT2 REG16(0x04000304)
#define KEYINPUT REG16(0x04000130)
#define SPICNT REG16(0x040001C0)
#define SPIDATA REG16(0x040001C2)

#define CHANNEL 7
#define BEACON_INT 0x40          /* "ms" (1024 us) between beacons */
#define GAME_ID 0x0040D1B5u

/* wifi RAM layout (byte offsets): TX frames below the RX ring */
#define TX_BEACON 0x000
#define TX_LOC 0x200
#define TX_CMD 0x400
#define TX_REPLY_A 0x600
#define TX_REPLY_B 0x680
#define RX_BEGIN 0x0C00
#define RX_END 0x1F60

static u8 fw[0x200];
static u8 mac[6], peer[6];
static u32 frame;
static u16 last_vc;
static u32 beacons14;
static int host;

static void tick(void) {
  u16 v = VCOUNT;
  if (v == 192 && last_vc != 192) frame++;
  last_vc = v;
  if (W(0x010) & 0x4000) { /* IRQ14: count beacon timeslots, keep W_IF clean */
    W(0x010) = 0x4000;
    beacons14++;
  }
  W(0x010) = 0xA000; /* IRQ13/15: not used */
}
static void wait_frames(u32 n) {
  u32 t = frame + n;
  while (frame < t) tick();
}
static u32 us(void) { /* low 32 bits of W_US_COUNT */
  u16 lo = W(0x0F8), hi = W(0x0FA);
  if (W(0x0F8) < lo) { lo = W(0x0F8); hi = W(0x0FA); }
  return lo | ((u32)hi << 16);
}

/* ---- firmware (SPI flash, GBATEK "DS Firmware Serial Flash Memory") ---- */
static u8 spi(u8 v) {
  SPIDATA = v;
  while (SPICNT & 0x80) {}
  return SPIDATA;
}
static void fw_read(u32 a, u8 *d, u32 n) {
  while (SPICNT & 0x80) {}
  SPICNT = 0x8900; /* enable, hold chip select, firmware, 4 MHz */
  spi(3);
  spi(a >> 16);
  spi(a >> 8);
  spi(a);
  for (u32 i = 0; i < n; i++) d[i] = spi(0);
  SPICNT = 0;
}
static u16 fw16(u32 o) { return fw[o] | (fw[o + 1] << 8); }
static u32 fw24(u32 o) { return fw[o] | (fw[o + 1] << 8) | ((u32)fw[o + 2] << 16); }

/* ---- BB and RF serial ports (GBATEK "Baseband Chip", "RF Chip") ---- */
static void bb_write(u8 i, u8 v) {
  while (W(0x15E) & 1) {}
  W(0x15A) = v;
  W(0x158) = 0x5000 | i;
  while (W(0x15E) & 1) {}
}
static u8 bb_read(u8 i) {
  while (W(0x15E) & 1) {}
  W(0x158) = 0x6000 | i;
  while (W(0x15E) & 1) {}
  return W(0x15C);
}
static void rf_write(u32 v) { /* type 2: 24 bits, index in 18-22 */
  while (W(0x180) & 1) {}
  W(0x17E) = v & 0xFFFF;
  W(0x17C) = (v >> 16) & 0xFF;
  while (W(0x180) & 1) {}
}

static void set_channel(int ch) {
  /* GBATEK "Wifi Change Channels Procedure", type 2 (firmware[040h] != 3) */
  if (fw[0x40] == 3) return;
  rf_write(fw24(0xF2 + (ch - 1) * 6));
  rf_write(fw24(0xF5 + (ch - 1) * 6));
  bb_write(0x1E, fw[0x146 + ch - 1]);
}

/* ---- initialisation: GBATEK "DS Wifi Initialization" ---- */
static void wifi_init(void) {
  POWCNT2 |= 2;
  for (int i = 0; i < 3; i++) W(0x018 + 2 * i) = mac[2 * i] | (mac[2 * i + 1] << 8);
  W(0x012) = 0;
  W(0x036) = 0;
  wait_frames(1);
  W(0x168) = 0;
  if (fw[0x40] == 2) {
    u8 t = bb_read(1);
    bb_write(1, t & 0x7F);
    bb_write(1, t);
  }
  wait_frames(2);
  W(0x004) = 0; W(0x008) = 0; W(0x00A) = 0; W(0x012) = 0; W(0x010) = 0xFFFF;
  W(0x254) = 0; W(0x0B4) = 0xFFFF; W(0x080) = 0; W(0x02A) = 0; W(0x028) = 0;
  W(0x0E8) = 0; W(0x0EA) = 0; W(0x0EE) = 1; W(0x0EC) = 0x3F03; W(0x1A2) = 1;
  W(0x1A0) = 0; W(0x110) = 0x0800; W(0x0BC) = 1; W(0x0D4) = 3; W(0x0D8) = 4;
  W(0x0DA) = 0x0602; W(0x076) = 0;
  static const u16 cfg[16][2] = {
    {0x146, 0x44}, {0x148, 0x46}, {0x14A, 0x48}, {0x14C, 0x4A}, {0x120, 0x4C},
    {0x122, 0x4E}, {0x154, 0x50}, {0x144, 0x52}, {0x130, 0x54}, {0x132, 0x56},
    {0x140, 0x58}, {0x142, 0x5A}, {0x038, 0x5C}, {0x124, 0x5E}, {0x128, 0x60},
    {0x150, 0x62}};
  for (int i = 0; i < 16; i++) W(cfg[i][0]) = fw16(cfg[i][1]);
  if (fw[0x40] != 3) {
    W(0x184) = (fw[0x41] + 0x80) & 0x17F;
    for (int i = 0; i < fw[0x42]; i++) rf_write(fw24(0xCE + 3 * i));
  }
  W(0x160) = 0x0100;
  for (int i = 1; i <= 0x68; i++) bb_write(i, fw[0x64 + i]);
  W(0x02C) = 7;
  set_channel(CHANNEL);
  W(0x006) = (W(0x006) & ~7) | 2;
  bb_write(0x13, 0x00);
  bb_write(0x35, 0x1F);
  W(0x032) = 0x8000; W(0x134) = 0xFFFF; W(0x028) = 0; W(0x02A) = 0;
  W(0x0E8) = 1; W(0x038) = 0;
  W(0x020) = 0; W(0x022) = 0; W(0x024) = 0;
  W(0x0AE) = 0x000D;
  W(0x030) = 0x8000;
  W(0x050) = 0x4000 + RX_BEGIN;
  W(0x052) = 0x4000 + RX_END;
  W(0x056) = RX_BEGIN >> 1;
  W(0x05A) = RX_BEGIN >> 1;
  W(0x062) = 0;
  W(0x064) = 0;
  W(0x030) = 0x8001;
  W(0x030) = 0x8000;
  W(0x010) = 0xFFFF;
  W(0x012) = 0; /* polled, no IRQ handler */
  W(0x1AE) = 0x1FFF;
  W(0x1AA) = 0;
  if (host) {
    W(0x0D0) = 0x0001;
    W(0x0E0) = 0x000D; /* ignore STA-STA, DS-STA, DS-DS data */
  } else {
    W(0x0D0) = 0x0081; /* other BSSs' beacons; multiplay ACKs */
    W(0x0E0) = 0x000B; /* ignore STA-STA, STA-DS, DS-DS data */
  }
  W(0x0BC) = 1 | 6;    /* short preamble at 2 Mbit/s */
  W(0x008) = host ? 0xE000 : 0x1000;
  W(0x00A) = 0;
  W(0x004) = 1;
  W(0x0E8) = 1;
  W(0x0EA) = 1;
  W(0x048) = 0;
  W(0x038) &= ~2;
  W(0x0AE) = 2;
  W(0x03C) |= 2;
  W(0x0AC) = 0xFFFF;
  for (u32 t = frame + 10; frame < t && !(W(0x19C) & 0x80);) tick();
}

/* ---- frames in wifi RAM ---- */
static void put_mac(u32 off, const u8 *m) {
  for (int i = 0; i < 3; i++) WRAM(off + 2 * i) = m[2 * i] | (m[2 * i + 1] << 8);
}
static void put32(u32 off, u32 v) {
  WRAM(off) = v & 0xFFFF;
  WRAM(off + 2) = v >> 16;
}
/* TX header (GBATEK "Hardware TX Header") + 24-byte IEEE header; returns
   the byte offset of the frame body. len counts header + body + FCS. */
static u32 put_frame(u32 off, u16 fc, u16 dur, const u8 *a1, const u8 *a2, const u8 *a3,
                     u16 len) {
  for (int i = 0; i < 12; i += 2) WRAM(off + i) = 0;
  WRAM(off + 8) = 0x14; /* 2 Mbit/s */
  WRAM(off + 10) = len;
  WRAM(off + 12) = fc;
  WRAM(off + 14) = dur;
  put_mac(off + 16, a1);
  put_mac(off + 22, a2);
  put_mac(off + 28, a3);
  WRAM(off + 34) = 0;
  return off + 36;
}

static const u8 bcast[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
static const u8 mp_cmd_da[6] = {0x03, 0x09, 0xBF, 0x00, 0x00, 0x00};
static const u8 mp_reply_da[6] = {0x03, 0x09, 0xBF, 0x00, 0x00, 0x10};

static void build_beacon(void) {
  /* GBATEK "DS Wifi Nintendo Beacons": timestamp, interval, capability,
     rates, channel, TIM, tag DDh (24 bytes + 8 of our own) */
  u32 b = put_frame(TX_BEACON, 0x0080, 0, bcast, mac, mac, 88);
  for (int i = 0; i < 8; i += 2) WRAM(b + i) = 0;
  WRAM(b + 8) = BEACON_INT;
  WRAM(b + 10) = 0x0021;
  static const u8 tags[] = {
    0x01, 0x02, 0x82, 0x84,                   /* supported rates */
    0x03, 0x01, CHANNEL,                      /* channel */
    0x05, 0x05, 0x00, 0x02, 0x00, 0x00, 0x00, /* TIM */
    0xDD, 0x20, 0x00, 0x09, 0xBF, 0x00,       /* Nintendo OUI */
    0x0A, 0x00, 0x00, 0x00,                   /* post-beacon step, vsync */
    0x01, 0x00, 0x40, 0x00,                   /* fixed ID */
    0xB5, 0xD1, 0x40, 0x00,                   /* game ID */
    0x34, 0x12, 0x08, 0x01,                   /* stream, 8 extra bytes, type 1 */
    0x08, 0x00, 0x04, 0x00,                   /* CMD / REPLY data sizes */
    'D', 'I', 'N', 'G', 'B', 'A', 'T', '!', 0x00};
  for (u32 i = 0; i + 1 < sizeof(tags); i += 2) WRAM(b + 12 + i) = tags[i] | (tags[i + 1] << 8);
  W(0x084) = 12 + 4 + 3 + 2; /* W_TXBUF_TIM: TIM parameters in the body */
}

/* ---- receive ---- */
static u8 rx8(u32 off) {
  while (off >= RX_END) off -= RX_END - RX_BEGIN;
  u16 h = WRAM(off & ~1);
  return (off & 1) ? h >> 8 : h & 0xFF;
}
static u16 rx16(u32 off) { return rx8(off) | (rx8(off + 1) << 8); }
static u32 rx32(u32 off) { return rx16(off) | ((u32)rx16(off + 2) << 16); }

typedef struct {
  u16 flags, rate, len;
  u32 body; /* byte offset of the IEEE header */
} rxpkt;
static int rx_next(rxpkt *p) {
  if (W(0x054) == W(0x05A)) return 0;
  u32 b = W(0x05A) << 1;
  p->flags = rx16(b);
  p->rate = rx16(b + 6);
  p->len = rx16(b + 8);
  p->body = b + 12;
  u32 next = b + 12 + ((p->len + 3) & ~3);
  while (next >= RX_END) next -= RX_END - RX_BEGIN;
  W(0x05A) = next >> 1;
  return 1;
}

static void send_loc1(u32 off) {
  W(0x02C) = 0x0707;
  W(0x0A0) = 0x8000 | (off >> 1);
  W(0x0AE) = 1;
}
static int wait_loc1(u32 frames) { /* 1 when done, 0 on timeout */
  u32 t = frame + frames;
  while ((W(0x0A0) & 0x8000) && frame < t) tick();
  W(0x010) = 0x008A; /* IRQ07/03/01 */
  return !(W(0x0A0) & 0x8000);
}

/* ---- host ---- */
static void run_host(void) {
  for (int i = 0; i < 3; i++) W(0x020 + 2 * i) = mac[2 * i] | (mac[2 * i + 1] << 8);
  build_beacon();
  W(0x08C) = BEACON_INT;
  W(0x11C) = BEACON_INT;
  W(0x080) = 0x8000 | (TX_BEACON >> 1);
  W(0x010) = 0xFFFF;
  /* the first two beacons: TXSTAT, IRQ07 spacing, data time */
  u32 t7[2] = {0, 0}, t1 = 0;
  for (int n = 0; n < 2; n++) {
    u32 t = frame + 30;
    while (!(W(0x010) & 0x0080) && frame < t) tick();
    t7[n] = us();
    W(0x010) = 0x0080;
    while (!(W(0x010) & 0x0002) && frame < t) tick();
    if (n == 0) {
      t1 = us();
      RES[4] = W(0x0B8) | ((u32)WRAM(TX_BEACON) << 16);
    }
    W(0x010) = 0x0002;
  }
  RES[5] = t7[1] - t7[0];
  RES[6] = t1 - t7[0];
  /* data: answer PINGs */
  u32 pings = 0, pong_res = 0, client = 0;
  rxpkt p;
  for (u32 t = frame + 300; frame < t && pings < 4;) {
    tick();
    if (!rx_next(&p)) continue;
    if ((p.flags & 0xF) != 8 || rx32(p.body + 24) != 0x474E4950u) continue; /* "PING" */
    u32 k = rx32(p.body + 28);
    pings++;
    RES[7] = pings | ((u32)p.flags << 16);
    for (int i = 0; i < 6; i++) peer[i] = rx8(p.body + 10 + i);
    client = 1;
    u32 b = put_frame(TX_LOC, 0x0208, 0, peer, mac, mac, 24 + 8 + 4);
    put32(b, 0x474E4F50u); /* "PONG" */
    put32(b + 4, k);
    send_loc1(TX_LOC);
    wait_loc1(10);
    u16 s = WRAM(TX_LOC);
    if (s == 1) pong_res |= 1u << k;
    if (s == 3) pong_res |= 0x100u << k;
    RES[8] = pong_res;
  }
  wait_frames(2);
  /* multiplay rounds to slave 1 (timing as GBATEK "Multiplay Master") */
  u32 ok = 0, fail = 0, replies = 0;
  u16 host_time = 36 * 4 + 0x60, client_time = 32 * 4 + 0xD2;
  u16 all_time = 0xF0 + (client_time + 0x0A) * 1;
  for (u32 k = 0; k < 8; k++) {
    u32 b = put_frame(TX_CMD, 0x0228, all_time, mp_cmd_da, mac, mac, 24 + 8 + 4);
    WRAM(b) = client_time;
    WRAM(b + 2) = 0x0002;
    put32(b + 4, 0x434D4400u | k); /* "\0DMC" + k */
    W(0x0C0) = all_time;
    W(0x0C4) = client_time;
    W(0x118) = 0x180 + ((0x388 + client_time + host_time + 0x32) >> 3);
    W(0x010) = 0x1000;
    u32 t0 = us();
    W(0x090) = 0x8000 | (TX_CMD >> 1);
    W(0x0AE) = 2;
    for (u32 t = frame + 10; !(W(0x010) & 0x1000) && frame < t;) tick();
    u32 dt = us() - t0;
    if (k == 0) RES[12] = dt;
    RES[14] = dt;
    W(0x010) = 0x1000;
    u16 st = WRAM(TX_CMD), err = WRAM(TX_CMD + 2);
    if (st == 1 && err == 0) ok++;
    if (st == 5) fail++;
    RES[13] = err | ((u32)W(0x0B8) << 16);
    while (rx_next(&p)) {
      if ((p.flags & 0xF) != 0xE) continue;
      replies++;
      RES[10] = p.flags | ((u32)p.len << 16);
      RES[11] = rx32(p.body + 24);
    }
    RES[9] = ok | (fail << 8) | (replies << 16);
    wait_frames(1);
  }
  if (client) RES[2] |= (u32)peer[5] << 24;
}

/* ---- client ---- */
static void run_client(void) {
  rxpkt p;
  u32 seen = 0, ts0 = 0;
  /* scan: the host's beacons */
  for (u32 t = frame + 300; frame < t && seen < 2;) {
    tick();
    if (!rx_next(&p)) continue;
    if ((p.flags & 0xF) != 1) continue;
    u32 ts = rx32(p.body + 24);
    if (seen == 0) {
      RES[4] = p.flags | ((u32)p.rate << 16);
      RES[5] = p.len;
      RES[7] = rx32(p.body + 24 + 12 + 4 + 3 + 7 + 2 + 12);
      for (int i = 0; i < 6; i++) peer[i] = rx8(p.body + 10 + i);
      ts0 = ts;
    } else {
      RES[6] = ts - ts0;
    }
    seen++;
    RES[3] = seen;
  }
  if (seen) {
    for (int i = 0; i < 3; i++) W(0x020 + 2 * i) = peer[2 * i] | (peer[2 * i + 1] << 8);
    RES[2] |= (u32)peer[5] << 24;
  } else {
    for (int i = 0; i < 6; i++) peer[i] = 0x02 + i; /* nobody: a made-up station */
  }
  /* data: PING k, wait for PONG k */
  u32 ping_res = 0, pongs = 0;
  (void)W(0x1C0);
  for (u32 k = 0; k < 4; k++) {
    u32 b = put_frame(TX_LOC, 0x0108, 0, peer, mac, peer, 24 + 8 + 4);
    put32(b, 0x474E4950u); /* "PING" */
    put32(b + 4, k);
    u32 t0 = us();
    send_loc1(TX_LOC);
    wait_loc1(10);
    if (k == 0) RES[14] = us() - t0;
    u16 s = WRAM(TX_LOC);
    if (s == 1) ping_res |= 1u << k;
    if (s == 3) ping_res |= 0x100u << k;
    RES[8] = ping_res;
    for (u32 t = frame + 20; frame < t;) {
      tick();
      if (!rx_next(&p)) continue;
      if ((p.flags & 0xF) == 1) RES[3]++;
      if ((p.flags & 0xF) != 8 || rx32(p.body + 24) != 0x474E4F50u) continue;
      pongs++;
      RES[9] = pongs | ((u32)p.flags << 16);
      RES[10] = rx32(p.body + 28);
      break;
    }
    if (!seen) break; /* alone: one PING tells the failure path */
  }
  RES[15] = W(0x1C0);
  /* multiplay slave 1: a REPLY ready for every CMD */
  u32 cmds = 0, acks = 0, n = 0;
  u32 rb[2] = {TX_REPLY_A, TX_REPLY_B};
  u32 b = put_frame(rb[0], 0x0118, 0, peer, mac, mp_reply_da, 24 + 4 + 4);
  put32(b, 0x52504C00u); /* "\0LPR" + n */
  W(0x02A) = 1;
  W(0x028) = 1;
  W(0x094) = 0x8000 | (rb[0] >> 1);
  for (u32 t = frame + (seen ? 120 : 20); frame < t && cmds < 8;) {
    tick();
    if (!rx_next(&p)) continue;
    u16 ty = p.flags & 0xF;
    if ((p.flags & 0xF) == 1) RES[3]++;
    if (ty == 0xC) {
      cmds++;
      RES[11] = cmds | ((u32)p.flags << 16);
      RES[12] = rx32(p.body + 28);
      n++;
      u32 nb = put_frame(rb[n & 1], 0x0118, 0, peer, mac, mp_reply_da, 24 + 4 + 4);
      put32(nb, 0x52504C00u | n);
      W(0x094) = 0x8000 | (rb[n & 1] >> 1);
    }
    if (ty == 0xD) {
      acks++;
      RES[13] = acks | ((u32)p.flags << 16);
    }
  }
  wait_frames(2);
  while (rx_next(&p)) {
    if ((p.flags & 0xF) == 0xD) RES[13] = ++acks | ((u32)p.flags << 16);
  }
}

int main(void) {
  for (int i = 0; i < RESULT_WORDS; i++) RES[i] = 0;
  /* role: A held during the first frames = host */
  wait_frames(4);
  host = !(KEYINPUT & 1);
  fw_read(0, fw, sizeof(fw));
  for (int i = 0; i < 6; i++) mac[i] = fw[0x36 + i];
  RES[1] = host ? 1 : 2;
  wifi_init();
  RES[2] = fw[0x40] | (CHANNEL << 8) | ((u32)mac[5] << 16);
  if (host) run_host();
  else run_client();
  if (host) RES[3] = beacons14;
  RES[0] = RES_MAGIC;
  for (;;) tick();
}
