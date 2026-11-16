/* The online link's network threads, behind one event queue the main loop
 * drains (frontend/rtc.nim): libdatachannel calls back on its own threads,
 * and the signaling socket (a WebSocket, TLS-verified against the roots the
 * caller hands to dbn_init) and the goodbye POST run on threads of their
 * own, so nothing here ever blocks the frame. The Nim side is built with
 * threads off: no Nim code runs on these threads, only this file. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RTC_STATIC  /* linked in, not a DLL (Windows: no dllimport) */
#include <rtc/rtc.h>
#include <mbedtls/base64.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>

#ifdef _WIN32
#include <windows.h>
typedef CRITICAL_SECTION dbn_mutex;
static void mu_init(dbn_mutex *m) { InitializeCriticalSection(m); }
static void mu_lock(dbn_mutex *m) { EnterCriticalSection(m); }
static void mu_unlock(dbn_mutex *m) { LeaveCriticalSection(m); }
typedef struct { void (*f)(void *); void *arg; } thunk_t;
static DWORD WINAPI thunk(LPVOID p) {
  thunk_t t = *(thunk_t *)p;
  free(p);
  t.f(t.arg);
  return 0;
}
static int spawn(void (*f)(void *), void *arg) {
  thunk_t *t = malloc(sizeof *t);
  if (!t) return -1;
  t->f = f; t->arg = arg;
  HANDLE h = CreateThread(NULL, 0, thunk, t, 0, NULL);
  if (!h) { free(t); return -1; }
  CloseHandle(h);
  return 0;
}
#else
#include <pthread.h>
typedef pthread_mutex_t dbn_mutex;
static void mu_init(dbn_mutex *m) { pthread_mutex_init(m, NULL); }
static void mu_lock(dbn_mutex *m) { pthread_mutex_lock(m); }
static void mu_unlock(dbn_mutex *m) { pthread_mutex_unlock(m); }
typedef struct { void (*f)(void *); void *arg; } thunk_t;
static void *thunk(void *p) {
  thunk_t t = *(thunk_t *)p;
  free(p);
  t.f(t.arg);
  return NULL;
}
static int spawn(void (*f)(void *), void *arg) {
  thunk_t *t = malloc(sizeof *t);
  pthread_t th;
  if (!t) return -1;
  t->f = f; t->arg = arg;
  if (pthread_create(&th, NULL, thunk, t) != 0) { free(t); return -1; }
  pthread_detach(th);
  return 0;
}
#endif

/* Event kinds: keep in step with rtc.nim's EvKind. */
enum {
  EV_LOCAL_DESC = 1,  /* id pc, s1 sdp, s2 type */
  EV_LOCAL_CAND,      /* id pc, s1 candidate, s2 mid */
  EV_STATE,           /* id pc, a rtcState */
  EV_GATHERING,       /* id pc, a rtcGatheringState */
  EV_DATACHANNEL,     /* id pc, a dc: the friend's channel arrived */
  EV_DC_OPEN,         /* id dc */
  EV_DC_CLOSED,       /* id dc */
  EV_DC_MESSAGE,      /* id dc, data/len */
  EV_DC_LOW,          /* id dc: buffered amount fell to the threshold */
  EV_WS_OPEN,         /* id ws */
  EV_WS_CLOSED,       /* id ws, a 1 if it had opened */
  EV_WS_MESSAGE,      /* id ws, s1 text */
  EV_HTTP_DONE        /* id request, a HTTP status (0: failed) */
};

typedef struct dbn_event {
  int kind, id, a;
  char *s1, *s2;
  unsigned char *data;
  int len;
  struct dbn_event *next;
} dbn_event;

static dbn_mutex qmu;
static dbn_event *qhead, *qtail;
static int inited;
static mbedtls_x509_crt roots;
static int next_ws_id = 1;

static char *dup_str(const char *s) {
  if (!s) return NULL;
  size_t n = strlen(s);
  char *d = malloc(n + 1);
  if (d) memcpy(d, s, n + 1);
  return d;
}

static void push(int kind, int id, int a, const char *s1, const char *s2,
                 const void *data, int len) {
  dbn_event *e = calloc(1, sizeof *e);
  if (!e) return;
  e->kind = kind; e->id = id; e->a = a;
  e->s1 = dup_str(s1);
  e->s2 = dup_str(s2);
  if (data && len > 0) {
    e->data = malloc((size_t)len);
    if (e->data) { memcpy(e->data, data, (size_t)len); e->len = len; }
  }
  mu_lock(&qmu);
  if (qtail) qtail->next = e; else qhead = e;
  qtail = e;
  mu_unlock(&qmu);
}

dbn_event *dbn_poll(void) {
  if (!inited) return NULL;
  mu_lock(&qmu);
  dbn_event *e = qhead;
  if (e) {
    qhead = e->next;
    if (!qhead) qtail = NULL;
    e->next = NULL;
  }
  mu_unlock(&qmu);
  return e;
}

void dbn_event_free(dbn_event *e) {
  if (!e) return;
  free(e->s1); free(e->s2); free(e->data); free(e);
}

/* `pem`: the roots the signaling server's certificate must chain to
 * (NUL-terminated). Returns 0, or -1 if they did not parse. */
int dbn_init(const char *pem, int len) {
  if (inited) return 0;
  mu_init(&qmu);
  mbedtls_x509_crt_init(&roots);
  inited = 1;
  rtcInitLogger(RTC_LOG_WARNING, NULL);
  return mbedtls_x509_crt_parse(&roots, (const unsigned char *)pem, (size_t)len + 1) == 0 ? 0 : -1;
}

/* ───────────────────────── WebRTC ───────────────────────── */

static void RTC_API on_dc_open(int dc, void *u) { (void)u; push(EV_DC_OPEN, dc, 0, NULL, NULL, NULL, 0); }
static void RTC_API on_dc_closed(int dc, void *u) { (void)u; push(EV_DC_CLOSED, dc, 0, NULL, NULL, NULL, 0); }
static void RTC_API on_dc_message(int dc, const char *msg, int size, void *u) {
  (void)u;
  if (size < 0) return;  /* text: the link speaks binary only */
  push(EV_DC_MESSAGE, dc, 0, NULL, NULL, msg, size);
}
static void RTC_API on_dc_low(int dc, void *u) { (void)u; push(EV_DC_LOW, dc, 0, NULL, NULL, NULL, 0); }

static void wire_dc(int dc) {
  rtcSetUserPointer(dc, NULL);
  rtcSetOpenCallback(dc, on_dc_open);
  rtcSetClosedCallback(dc, on_dc_closed);
  rtcSetMessageCallback(dc, on_dc_message);
  rtcSetBufferedAmountLowCallback(dc, on_dc_low);
}

static void RTC_API on_local_desc(int pc, const char *sdp, const char *type, void *u) {
  (void)u; push(EV_LOCAL_DESC, pc, 0, sdp, type, NULL, 0);
}
static void RTC_API on_local_cand(int pc, const char *cand, const char *mid, void *u) {
  (void)u; push(EV_LOCAL_CAND, pc, 0, cand, mid ? mid : "0", NULL, 0);
}
static void RTC_API on_state(int pc, rtcState st, void *u) {
  (void)u; push(EV_STATE, pc, (int)st, NULL, NULL, NULL, 0);
}
static void RTC_API on_gathering(int pc, rtcGatheringState st, void *u) {
  (void)u; push(EV_GATHERING, pc, (int)st, NULL, NULL, NULL, 0);
}
static void RTC_API on_datachannel(int pc, int dc, void *u) {
  (void)u;
  /* Wired here, on libdatachannel's thread: the channel may open (and the
   * friend's first messages land) before the main loop sees it. */
  wire_dc(dc);
  push(EV_DATACHANNEL, pc, dc, NULL, NULL, NULL, 0);
  if (rtcIsOpen(dc)) push(EV_DC_OPEN, dc, 0, NULL, NULL, NULL, 0);
}

/* A peer connection with every callback wired; -1 on failure. */
int dbn_pc_create(const char **ice, int n) {
  rtcConfiguration cfg;
  memset(&cfg, 0, sizeof cfg);
  cfg.iceServers = ice;
  cfg.iceServersCount = n;
  int pc = rtcCreatePeerConnection(&cfg);
  if (pc < 0) return -1;
  rtcSetUserPointer(pc, NULL);
  rtcSetLocalDescriptionCallback(pc, on_local_desc);
  rtcSetLocalCandidateCallback(pc, on_local_cand);
  rtcSetStateChangeCallback(pc, on_state);
  rtcSetGatheringStateChangeCallback(pc, on_gathering);
  rtcSetDataChannelCallback(pc, on_datachannel);
  return pc;
}

/* The offerer's reliable, ordered channel (and with it the offer). */
int dbn_dc_create(int pc, const char *label) {
  rtcDataChannelInit init;
  memset(&init, 0, sizeof init);
  int dc = rtcCreateDataChannelEx(pc, label, &init);
  if (dc < 0) return -1;
  wire_dc(dc);
  return dc;
}

/* ─────────────────── the signaling WebSocket ─────────────────── */

typedef struct out_msg { char *text; int len; struct out_msg *next; } out_msg;

typedef struct ws_conn {
  int id;
  int tls;
  char host[256], port[8], path[512];
  char *post_body;  /* a POST (dbn_https_post) instead of a WebSocket */
  mbedtls_net_context net;
  mbedtls_ssl_context ssl;
  mbedtls_ssl_config conf;
  mbedtls_entropy_context entropy;
  mbedtls_ctr_drbg_context drbg;
  out_msg *out_head, *out_tail;
  int closing;  /* the main loop let go: say nothing more */
  struct ws_conn *next;
} ws_conn;

static ws_conn *conns;  /* under qmu */

static ws_conn *find(int id) {
  for (ws_conn *c = conns; c; c = c->next)
    if (c->id == id) return c;
  return NULL;
}

static int parse_url(ws_conn *c, const char *url) {
  const char *p;
  if (strncmp(url, "wss://", 6) == 0) { c->tls = 1; p = url + 6; strcpy(c->port, "443"); }
  else if (strncmp(url, "https://", 8) == 0) { c->tls = 1; p = url + 8; strcpy(c->port, "443"); }
  else if (strncmp(url, "ws://", 5) == 0) { c->tls = 0; p = url + 5; strcpy(c->port, "80"); }
  else if (strncmp(url, "http://", 7) == 0) { c->tls = 0; p = url + 7; strcpy(c->port, "80"); }
  else return -1;
  const char *slash = strchr(p, '/');
  const char *end = slash ? slash : p + strlen(p);
  const char *colon = memchr(p, ':', (size_t)(end - p));
  const char *hend = colon ? colon : end;
  if (hend == p || (size_t)(hend - p) >= sizeof c->host) return -1;
  memcpy(c->host, p, (size_t)(hend - p));
  c->host[hend - p] = 0;
  if (colon) {
    size_t n = (size_t)(end - colon - 1);
    if (n == 0 || n >= sizeof c->port) return -1;
    memcpy(c->port, colon + 1, n);
    c->port[n] = 0;
  }
  if (strlen(slash ? slash : "/") >= sizeof c->path) return -1;
  strcpy(c->path, slash ? slash : "/");
  return 0;
}

static int io_send(ws_conn *c, const unsigned char *b, size_t n) {
  while (n > 0) {
    int r = c->tls ? mbedtls_ssl_write(&c->ssl, b, n) : mbedtls_net_send(&c->net, b, n);
    if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
    if (r <= 0) return -1;
    b += r; n -= (size_t)r;
  }
  return 0;
}

/* Bytes read, 0 on a timeout, -1 when the connection is over. */
static int io_recv(ws_conn *c, unsigned char *b, size_t n) {
  int r = c->tls ? mbedtls_ssl_read(&c->ssl, b, n) : mbedtls_net_recv_timeout(&c->net, b, n, 20);
  if (r > 0) return r;
  if (r == MBEDTLS_ERR_SSL_TIMEOUT || r == MBEDTLS_ERR_SSL_WANT_READ ||
      r == MBEDTLS_ERR_SSL_WANT_WRITE || r == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET)
    return 0;
  return -1;
}

static int is_closing(ws_conn *c) {
  mu_lock(&qmu);
  int v = c->closing;
  mu_unlock(&qmu);
  return v;
}

static int dial(ws_conn *c) {
  if (mbedtls_net_connect(&c->net, c->host, c->port, MBEDTLS_NET_PROTO_TCP) != 0) return -1;
  if (!c->tls) return 0;
  if (mbedtls_ctr_drbg_seed(&c->drbg, mbedtls_entropy_func, &c->entropy, NULL, 0) != 0) return -1;
  if (mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                  MBEDTLS_SSL_PRESET_DEFAULT) != 0) return -1;
  /* TLS 1.2 keeps this thread off PSA's process-wide state, which
   * libdatachannel's threads use too (mbedTLS is built without
   * MBEDTLS_THREADING_C). */
  mbedtls_ssl_conf_max_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_2);
  mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
  mbedtls_ssl_conf_ca_chain(&c->conf, &roots, NULL);
  mbedtls_ssl_conf_rng(&c->conf, mbedtls_ctr_drbg_random, &c->drbg);
  mbedtls_ssl_conf_read_timeout(&c->conf, 20);
  if (mbedtls_ssl_setup(&c->ssl, &c->conf) != 0) return -1;
  if (mbedtls_ssl_set_hostname(&c->ssl, c->host) != 0) return -1;
  mbedtls_ssl_set_bio(&c->ssl, &c->net, mbedtls_net_send, NULL, mbedtls_net_recv_timeout);
  int r;
  while ((r = mbedtls_ssl_handshake(&c->ssl)) != 0) {
    if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE ||
        r == MBEDTLS_ERR_SSL_TIMEOUT) {
      if (is_closing(c)) return -1;
      continue;
    }
    char err[128];
    mbedtls_strerror(r, err, sizeof err);
    fprintf(stderr, "netlink: TLS to %s failed: %s (verify flags 0x%x)\n", c->host, err,
            mbedtls_ssl_get_verify_result(&c->ssl));
    return -1;
  }
  return 0;
}

/* Reads the reply head into buf (NUL-terminated); returns its length and
 * leaves any bytes after it at buf + *head_len .. buf + returned. */
static int read_head(ws_conn *c, char *buf, int cap, int *head_len) {
  int n = 0, waited = 0;
  while (n < cap - 1) {
    int r = io_recv(c, (unsigned char *)buf + n, (size_t)(cap - 1 - n));
    if (r < 0) return -1;
    if (r == 0) {
      if (is_closing(c) || ++waited > 500) return -1;  /* 10 s */
      continue;
    }
    n += r;
    buf[n] = 0;
    char *e = strstr(buf, "\r\n\r\n");
    if (e) { *head_len = (int)(e - buf) + 4; return n; }
  }
  return -1;
}

static void ws_send_frame(ws_conn *c, int opcode, const char *p, int len) {
  unsigned char hdr[14], mask[4];
  int h = 0;
  hdr[h++] = (unsigned char)(0x80 | opcode);
  if (len < 126) hdr[h++] = (unsigned char)(0x80 | len);
  else if (len < 65536) { hdr[h++] = 0x80 | 126; hdr[h++] = (unsigned char)(len >> 8); hdr[h++] = (unsigned char)len; }
  else {
    hdr[h++] = 0x80 | 127;
    for (int i = 7; i >= 0; i--) hdr[h++] = (unsigned char)(i < 4 ? ((unsigned)len >> (8 * i)) : 0);
  }
  if (c->tls) mbedtls_ctr_drbg_random(&c->drbg, mask, 4);
  else { unsigned r = (unsigned)rand(); memcpy(mask, &r, 4); }
  memcpy(hdr + h, mask, 4);
  h += 4;
  unsigned char *frame = malloc((size_t)h + (size_t)len);
  if (!frame) return;
  memcpy(frame, hdr, (size_t)h);
  for (int i = 0; i < len; i++) frame[h + i] = (unsigned char)p[i] ^ mask[i & 3];
  io_send(c, frame, (size_t)h + (size_t)len);
  free(frame);
}

static void conn_free(ws_conn *c) {
  mu_lock(&qmu);
  for (ws_conn **pp = &conns; *pp; pp = &(*pp)->next)
    if (*pp == c) { *pp = c->next; break; }
  out_msg *o = c->out_head;
  mu_unlock(&qmu);
  while (o) { out_msg *n = o->next; free(o->text); free(o); o = n; }
  if (c->tls) {
    mbedtls_ssl_free(&c->ssl);
    mbedtls_ssl_config_free(&c->conf);
    mbedtls_ctr_drbg_free(&c->drbg);
    mbedtls_entropy_free(&c->entropy);
  }
  mbedtls_net_free(&c->net);
  free(c->post_body);
  free(c);
}

static void ws_thread(void *arg) {
  ws_conn *c = arg;
  int opened = 0;
  char *buf = NULL;
  size_t blen = 0, bcap = 0;
  char *msg = NULL;  /* a fragmented text message, gathered */
  size_t mlen = 0;
  if (dial(c) != 0) goto done;
  {
    unsigned char key[16], key64[32];
    size_t k64;
    if (c->tls) mbedtls_ctr_drbg_random(&c->drbg, key, sizeof key);
    else for (int i = 0; i < 16; i++) key[i] = (unsigned char)rand();
    mbedtls_base64_encode(key64, sizeof key64, &k64, key, sizeof key);
    char req[1024];
    int n = snprintf(req, sizeof req,
                     "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                     "Sec-WebSocket-Key: %.*s\r\nSec-WebSocket-Version: 13\r\n\r\n",
                     c->path, c->host, (int)k64, key64);
    if (n <= 0 || n >= (int)sizeof req || io_send(c, (unsigned char *)req, (size_t)n) != 0) goto done;
  }
  {
    char head[4096];
    int hl = 0;
    int n = read_head(c, head, sizeof head, &hl);
    if (n < 0 || strncmp(head, "HTTP/1.1 101", 12) != 0) goto done;
    bcap = 8192;
    buf = malloc(bcap);
    if (!buf) goto done;
    blen = (size_t)(n - hl);
    memcpy(buf, head + hl, blen);
  }
  if (is_closing(c)) goto done;
  opened = 1;
  push(EV_WS_OPEN, c->id, 0, NULL, NULL, NULL, 0);
  for (;;) {
    mu_lock(&qmu);
    int closing = c->closing;
    out_msg *o = c->out_head;
    c->out_head = c->out_tail = NULL;
    mu_unlock(&qmu);
    while (o) {
      out_msg *n = o->next;
      if (!closing) ws_send_frame(c, 1, o->text, o->len);
      free(o->text); free(o);
      o = n;
    }
    if (closing) { ws_send_frame(c, 8, "\x03\xe8", 2); break; }
    if (bcap - blen < 4096) {
      bcap *= 2;
      char *nb = realloc(buf, bcap);
      if (!nb) break;
      buf = nb;
    }
    int r = io_recv(c, (unsigned char *)buf + blen, bcap - blen);
    if (r < 0) break;
    blen += (size_t)r;
    /* Every whole frame in the buffer (the server never masks). */
    int over = 0;
    for (;;) {
      if (blen < 2) break;
      unsigned char *b = (unsigned char *)buf;
      int fin = b[0] & 0x80, op = b[0] & 0x0f;
      uint64_t len = b[1] & 0x7f;
      size_t h = 2;
      if (len == 126) { if (blen < 4) break; len = ((uint64_t)b[2] << 8) | b[3]; h = 4; }
      else if (len == 127) {
        if (blen < 10) break;
        len = 0;
        for (int i = 0; i < 8; i++) len = (len << 8) | b[2 + i];
        h = 10;
      }
      if (b[1] & 0x80) h += 4;  /* masked: not from a server, but skip the key */
      if (len > (1u << 24)) { over = 1; break; }
      if (blen < h + len) break;
      const char *p = buf + h;
      if (op == 1 || op == 2 || op == 0) {
        char *nm = realloc(msg, mlen + (size_t)len + 1);
        if (!nm) { over = 1; break; }
        msg = nm;
        memcpy(msg + mlen, p, (size_t)len);
        mlen += (size_t)len;
        if (fin) {
          msg[mlen] = 0;
          push(EV_WS_MESSAGE, c->id, 0, msg, NULL, NULL, 0);
          mlen = 0;
        }
      } else if (op == 8) {
        over = 1;
      } else if (op == 9) {
        ws_send_frame(c, 10, p, (int)len);
      }
      memmove(buf, buf + h + len, blen - h - (size_t)len);
      blen -= h + (size_t)len;
      if (over) break;
    }
    if (over) break;
  }
done:
  free(buf);
  free(msg);
  if (!is_closing(c)) push(EV_WS_CLOSED, c->id, opened, NULL, NULL, NULL, 0);
  conn_free(c);
}

static ws_conn *conn_new(const char *url) {
  ws_conn *c = calloc(1, sizeof *c);
  if (!c) return NULL;
  if (parse_url(c, url) != 0) { free(c); return NULL; }
  mbedtls_net_init(&c->net);
  if (c->tls) {
    mbedtls_ssl_init(&c->ssl);
    mbedtls_ssl_config_init(&c->conf);
    mbedtls_entropy_init(&c->entropy);
    mbedtls_ctr_drbg_init(&c->drbg);
  }
  mu_lock(&qmu);
  c->id = next_ws_id++;
  c->next = conns;
  conns = c;
  mu_unlock(&qmu);
  return c;
}

/* Dial `url` (ws:// or wss://); events EV_WS_*. Returns its id, or -1. */
int dbn_ws_open(const char *url) {
  if (!inited) return -1;
  ws_conn *c = conn_new(url);
  if (!c) return -1;
  int id = c->id;
  if (spawn(ws_thread, c) != 0) { conn_free(c); return -1; }
  return id;
}

/* Queue a text message; dropped once the socket is closing or gone. */
void dbn_ws_send(int id, const char *text, int len) {
  mu_lock(&qmu);
  ws_conn *c = find(id);
  if (c && !c->closing && !c->post_body) {
    out_msg *o = calloc(1, sizeof *o);
    if (o && (o->text = malloc((size_t)len + 1))) {
      memcpy(o->text, text, (size_t)len);
      o->text[len] = 0;
      o->len = len;
      if (c->out_tail) c->out_tail->next = o; else c->out_head = o;
      c->out_tail = o;
    } else {
      free(o);
    }
  }
  mu_unlock(&qmu);
}

/* Our own close: no more events for it. */
void dbn_ws_close(int id) {
  mu_lock(&qmu);
  ws_conn *c = find(id);
  if (c && !c->post_body) c->closing = 1;
  mu_unlock(&qmu);
}

static void post_thread(void *arg) {
  ws_conn *c = arg;
  int status = 0;
  if (dial(c) == 0) {
    size_t bl = strlen(c->post_body);
    char req[1024];
    int n = snprintf(req, sizeof req,
                     "POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: text/plain;charset=UTF-8\r\n"
                     "Content-Length: %lu\r\nConnection: close\r\n\r\n",
                     c->path, c->host, (unsigned long)bl);  /* msvcrt: no %zu */
    if (n > 0 && n < (int)sizeof req && io_send(c, (unsigned char *)req, (size_t)n) == 0 &&
        io_send(c, (unsigned char *)c->post_body, bl) == 0) {
      char head[2048];
      int hl = 0;
      if (read_head(c, head, sizeof head, &hl) > 0 && strncmp(head, "HTTP/1.", 7) == 0)
        status = atoi(head + 9);
    }
  }
  push(EV_HTTP_DONE, c->id, status, NULL, NULL, NULL, 0);
  conn_free(c);
}

/* POST `body` to `url` (http:// or https://), once, off the main thread;
 * EV_HTTP_DONE says how it went. Returns its id, or -1. */
int dbn_https_post(const char *url, const char *body) {
  if (!inited) return -1;
  ws_conn *c = conn_new(url);
  if (!c) return -1;
  c->post_body = dup_str(body);
  int id = c->id;
  if (!c->post_body || spawn(post_thread, c) != 0) { conn_free(c); return -1; }
  return id;
}
