#include "CScrollbackChecksum.h"

#include <string.h>

#if defined(__ARM_FEATURE_CRC32)
#include <arm_acle.h>
#endif

int swiftty_crc32c_accelerated(void) {
#if defined(__ARM_FEATURE_CRC32)
  return 1;
#else
  return 0;
#endif
}

uint32_t swiftty_crc32c_update(uint32_t crc, const void *data, size_t count) {
#if defined(__ARM_FEATURE_CRC32)
  const uint8_t *p = data;
  while (count >= 32) {
    uint64_t v[4];
    memcpy(v, p, sizeof v);
    crc = __crc32cd(crc, v[0]);
    crc = __crc32cd(crc, v[1]);
    crc = __crc32cd(crc, v[2]);
    crc = __crc32cd(crc, v[3]);
    p += 32;
    count -= 32;
  }
  while (count >= 8) {
    uint64_t v;
    memcpy(&v, p, sizeof v);
    crc = __crc32cd(crc, v);
    p += 8;
    count -= 8;
  }
  while (count > 0) {
    crc = __crc32cb(crc, *p++);
    count -= 1;
  }
  return crc;
#else
  (void)data;
  (void)count;
  return crc;
#endif
}
