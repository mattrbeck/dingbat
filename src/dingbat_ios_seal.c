/* The half of a save state that may run off the core's thread: what
 * dingbat_state_open (src/dingbat_ios.nim) leaves, finished as pack_state
 * would (src/dingbat/common/serialize.nim): the payload's fnv1a in the
 * 32-byte header, then everything after the header zlib-deflated. */
#include <stdint.h>
#include <string.h>
#include <zlib.h>

#define HEADER 32

long dingbat_state_seal_bound(long len) {
  return len < HEADER ? 0 : HEADER + (long)compressBound((uLong)(len - HEADER));
}

long dingbat_state_seal(const void *image, long len, void *out, long cap) {
  const uint8_t *img = image;
  uint8_t *o = out;
  if (len <= HEADER || cap <= HEADER) return 0;
  uint32_t plen = img[24] | (uint32_t)img[25] << 8 | (uint32_t)img[26] << 16 |
                  (uint32_t)img[27] << 24;
  if (plen > (uint32_t)(len - HEADER)) return 0;
  uint32_t h = 0x811C9DC5u;
  for (uint32_t i = 0; i < plen; i++) h = (h ^ img[HEADER + i]) * 0x01000193u;
  memcpy(o, img, HEADER);
  for (int i = 0; i < 4; i++) o[28 + i] = (uint8_t)(h >> (8 * i));
  uLongf n = (uLongf)(cap - HEADER);
  if (compress2(o + HEADER, &n, img + HEADER, (uLong)(len - HEADER), Z_BEST_SPEED) != Z_OK)
    return 0;
  return HEADER + (long)n;
}
