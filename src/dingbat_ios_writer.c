/* The iOS core's file writes on their own thread (src/dingbat_ios.nim sets
 * atomicfile's writer to this): a battery save the cores write from inside a
 * frame (temp file, fsync, rename: up to ~100 ms on a phone) would otherwise
 * hold up the display tick. Same steps as write_file_atomic, in order; a
 * write still queued for a path is replaced by a newer one. */
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct job {
  struct job *next;
  char *path;
  char *data;
  long len;
  int sync;
} job;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_more = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_idle = PTHREAD_COND_INITIALIZER;
static job *g_head, *g_tail;
static int g_busy, g_started;

static void write_one(const job *j) {
  char tmp[4096];
  if (snprintf(tmp, sizeof tmp, "%s.tmp%d", j->path, (int)getpid()) >= (int)sizeof tmp) return;
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  long off = 0;
  while (off < j->len) {
    ssize_t n = write(fd, j->data + off, (size_t)(j->len - off));
    if (n <= 0) break;
    off += n;
  }
  int ok = off == j->len && (!j->sync || fsync(fd) == 0);
  ok = close(fd) == 0 && ok;
  if (!ok || rename(tmp, j->path) != 0) unlink(tmp);
}

static void *run(void *arg) {
  (void)arg;
  pthread_mutex_lock(&g_lock);
  for (;;) {
    while (!g_head) {
      g_busy = 0;
      pthread_cond_broadcast(&g_idle);
      pthread_cond_wait(&g_more, &g_lock);
    }
    job *j = g_head;
    g_head = j->next;
    if (!g_head) g_tail = NULL;
    g_busy = 1;
    pthread_mutex_unlock(&g_lock);
    write_one(j);
    free(j->path);
    free(j->data);
    free(j);
    pthread_mutex_lock(&g_lock);
  }
  return NULL;
}

void dingbat_writer_put(const char *path, const void *data, long len, int sync) {
  char *copy = malloc(len > 0 ? (size_t)len : 1);
  if (!copy) return;
  if (len > 0) memcpy(copy, data, (size_t)len);
  pthread_mutex_lock(&g_lock);
  for (job *q = g_head; q; q = q->next) {
    if (strcmp(q->path, path) == 0) {
      free(q->data);
      q->data = copy;
      q->len = len;
      q->sync |= sync;
      pthread_mutex_unlock(&g_lock);
      return;
    }
  }
  job *j = calloc(1, sizeof *j);
  char *p = strdup(path);
  if (!j || !p) {
    free(j);
    free(p);
    free(copy);
    pthread_mutex_unlock(&g_lock);
    return;
  }
  j->path = p;
  j->data = copy;
  j->len = len;
  j->sync = sync;
  if (g_tail) g_tail->next = j; else g_head = j;
  g_tail = j;
  g_busy = 1;
  if (!g_started) {
    pthread_t t;
    if (pthread_create(&t, NULL, run, NULL) == 0) {
      pthread_detach(t);
      g_started = 1;
    }
  }
  if (!g_started) {
    /* No thread: write here, as before. */
    g_head = g_tail = NULL;
    g_busy = 0;
    pthread_mutex_unlock(&g_lock);
    write_one(j);
    free(j->path);
    free(j->data);
    free(j);
    return;
  }
  pthread_cond_signal(&g_more);
  pthread_mutex_unlock(&g_lock);
}

/* Returns once every write queued so far is on disk. */
void dingbat_writer_drain(void) {
  pthread_mutex_lock(&g_lock);
  while (g_busy) pthread_cond_wait(&g_idle, &g_lock);
  pthread_mutex_unlock(&g_lock);
}
