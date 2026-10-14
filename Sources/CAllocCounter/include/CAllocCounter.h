#pragma once
#include <stdint.h>

/// Starts counting heap allocations made by the calling thread.
/// Measurements on different threads serialize; stop on the same thread.
/// Restarting on the owning thread resets its count without releasing ownership.
/// Existing malloc logging continues during the measurement. Counter controls
/// and external hook replacements must not be invoked from logger callbacks.
/// Independent hook writers must coordinate with measurements; libmalloc's
/// process-wide hook does not provide an atomic registration API.
/// ALLOC_COUNTER_TRACE prints allocation stacks; its own allocations are excluded.
void alloc_counter_start(void);
/// Stops counting and returns the number of allocations observed.
/// A thread without an active measurement returns zero without changing the hook.
/// Restores the previous logger if the counter still owns the hook. An owning
/// thread that exits without stopping releases its measurement automatically.
uint64_t alloc_counter_stop(void);
