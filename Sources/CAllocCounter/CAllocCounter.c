#include "CAllocCounter.h"
#include <pthread.h>
#include <stdatomic.h>
#include <execinfo.h>
#include <stdlib.h>

// libmalloc's process-wide logger must not allocate while handling an event.
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2,
                              uintptr_t arg3, uintptr_t result,
                              uint32_t num_hot_frames_to_skip);
extern malloc_logger_t *malloc_logger;

#define MALLOC_LOG_TYPE_ALLOCATE 2

struct measurement {
  uint64_t count;
  int active;
  int trace;
  int inside_trace;
};

static pthread_mutex_t ownership = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t state_once = PTHREAD_ONCE_INIT;
static pthread_key_t state_key;
static _Atomic(malloc_logger_t *) previous_logger;

static void logger(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);

static void finish(struct measurement *state) {
  state->active = 0;
  if (malloc_logger == logger) {
    malloc_logger = atomic_load_explicit(&previous_logger, memory_order_acquire);
  }
  if (pthread_mutex_unlock(&ownership) != 0) abort();
}

static void destroy_state(void *value) {
  struct measurement *state = value;
  // pthread clears the key before invoking its destructor. Any allocation
  // caused by cleanup sees no local measurement, never a freed state.
  if (state->active) finish(state);
  free(state);
}

static void make_key(void) {
  if (pthread_key_create(&state_key, destroy_state) != 0) abort();
}

static struct measurement *local_state(void) {
  // The once fast path and getspecific do not allocate. Avoid C thread-local
  // access in the hook: first-use Mach-O TLV setup can itself allocate.
  if (pthread_once(&state_once, make_key) != 0) abort();
  return pthread_getspecific(state_key);
}

static void logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3,
                   uintptr_t result, uint32_t skip) {
  struct measurement *state = local_state();
  if ((type & MALLOC_LOG_TYPE_ALLOCATE) && state && state->active &&
      !state->inside_trace) {
    state->count++;
    if (state->trace) {
      state->inside_trace = 1;
      void *frames[32];
      int n = backtrace(frames, 32);
      backtrace_symbols_fd(frames, n, 2);
      state->inside_trace = 0;
    }
  }
  malloc_logger_t *previous = atomic_load_explicit(&previous_logger, memory_order_acquire);
  if (previous) previous(type, a1, a2, a3, result, skip);
}

void alloc_counter_start(void) {
  struct measurement *state = local_state();
  if (!state || !state->active) {
    if (pthread_mutex_lock(&ownership) != 0) abort();
    if (!state) {
      state = calloc(1, sizeof(*state));
      if (!state) abort();
      if (pthread_setspecific(state_key, state) != 0) {
        free(state);
        abort();
      }
    }
  }
  // Restarting on the owning thread resets the sample, not its ownership.
  state->active = 0;
  if (malloc_logger != logger) {
    atomic_store_explicit(&previous_logger, malloc_logger, memory_order_release);
  }
  state->trace = getenv("ALLOC_COUNTER_TRACE") != 0;
  state->inside_trace = 0;
  state->count = 0;
  state->active = 1;
  malloc_logger = logger;
}

uint64_t alloc_counter_stop(void) {
  struct measurement *state = local_state();
  if (!state || !state->active) return 0;
  uint64_t result = state->count;
  finish(state);
  return result;
}
