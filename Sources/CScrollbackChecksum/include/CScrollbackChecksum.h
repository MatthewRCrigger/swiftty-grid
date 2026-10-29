#ifndef CSCROLLBACKCHECKSUM_H
#define CSCROLLBACKCHECKSUM_H

#include <stddef.h>
#include <stdint.h>

/// Nonzero when `swiftty_crc32c_update` uses the CPU's CRC32C instructions.
int swiftty_crc32c_accelerated(void);

/// CRC-32C (Castagnoli) of `count` bytes, continuing from `crc` (the
/// inverted running value; start with 0xFFFFFFFF and invert the result).
/// Only meaningful when `swiftty_crc32c_accelerated()` is nonzero.
uint32_t swiftty_crc32c_update(uint32_t crc, const void *data, size_t count);

#endif
