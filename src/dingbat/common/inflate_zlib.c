/* inflate_bound.nim's way into the zlib sources under vendor/zlib: one
 * stream, fed whole, drained into whatever buffer the caller has room for.
 * Built with Z_SOLO (no gz files, no allocator of zlib's own), Z_PREFIX
 * (its symbols are z_*, so a system libz in the same process is not
 * replaced by this one) and NO_GZIP. */
#include <stdlib.h>
#include <stddef.h>
#include "../vendor/zlib/zlib.h"

static voidpf dz_alloc(voidpf opaque, uInt items, uInt size) {
  (void)opaque;
  return calloc(items, size);
}

static void dz_free(voidpf opaque, voidpf p) {
  (void)opaque;
  free(p);
}

/* A stream over `len` bytes at `src`; `raw` for a bare deflate stream, else
 * one with the zlib header and Adler-32. NULL when it cannot be made. */
void *dingbat_inflate_open(const unsigned char *src, unsigned len, int raw) {
  z_stream *s = calloc(1, sizeof *s);
  if (!s) return NULL;
  s->zalloc = dz_alloc;
  s->zfree = dz_free;
  s->next_in = (z_const Bytef *)src;
  s->avail_in = len;
  if (inflateInit2(s, raw ? -15 : 15) != Z_OK) {
    free(s);
    return NULL;
  }
  return s;
}

/* Inflate into `cap` bytes at `dst`; *made is how many were written.
 * 1: the stream ended (*left is the input after it). 0: `dst` is full and
 * the stream has more. -1: the stream is damaged, cut short, or wants a
 * preset dictionary. */
int dingbat_inflate_run(void *stream, unsigned char *dst, unsigned cap,
                        unsigned *made, unsigned *left) {
  z_stream *s = stream;
  s->next_out = dst;
  s->avail_out = cap;
  int r = inflate(s, Z_FINISH);
  *made = cap - s->avail_out;
  *left = s->avail_in;
  if (r == Z_STREAM_END) return 1;
  if ((r == Z_OK || r == Z_BUF_ERROR) && s->avail_out == 0) return 0;
  return -1;
}

void dingbat_inflate_close(void *stream) {
  if (!stream) return;
  inflateEnd((z_stream *)stream);
  free(stream);
}
