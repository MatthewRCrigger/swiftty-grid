#include "CAllocCounter.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

typedef void(logger_t)(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);
extern logger_t *malloc_logger;
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "failed: %s\n", #value); exit(1); } } while (0)
static _Atomic unsigned observed;
static void observer(uint32_t type, uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d, uint32_t e) {
  (void)a; (void)b; (void)c; (void)d; (void)e;
  if (type & 2) atomic_fetch_add(&observed, 1);
}
static void replacement(uint32_t type, uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d, uint32_t e) {
  observer(type, a, b, c, d, e);
}
static void emit(unsigned count) {
  for (unsigned i = 0; i < count; ++i) malloc_logger(2, 0, 0, 0, 0, 0);
}
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int go, attempted, acquired;
static uint64_t other_count;
static void *foreign_stop(void *unused) {
  (void)unused;
  CHECK(pthread_mutex_lock(&gate) == 0);
  while (!go) CHECK(pthread_cond_wait(&condition, &gate) == 0);
  CHECK(pthread_mutex_unlock(&gate) == 0);
  emit(13); // Other threads still reach the observer, outside the owner's sample.
  other_count = alloc_counter_stop();
  return NULL;
}
static void *contender(void *unused) {
  (void)unused;
  CHECK(pthread_mutex_lock(&gate) == 0);
  while (!go) CHECK(pthread_cond_wait(&condition, &gate) == 0);
  attempted = 1;
  CHECK(pthread_cond_broadcast(&condition) == 0);
  CHECK(pthread_mutex_unlock(&gate) == 0);
  alloc_counter_start();
  CHECK(pthread_mutex_lock(&gate) == 0);
  acquired = 1;
  CHECK(pthread_cond_broadcast(&condition) == 0);
  CHECK(pthread_mutex_unlock(&gate) == 0);
  emit(11);
  other_count = alloc_counter_stop();
  return NULL;
}
static void *abandon(void *unused) {
  (void)unused;
  alloc_counter_start();
  emit(4);
  return NULL; // Key destructor must relinquish both hook and ownership.
}
static void run(const char *mode) {
  if (strcmp(mode, "foreign-stop") == 0) {
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, foreign_stop, NULL) == 0);
    alloc_counter_start();
    emit(7);
    CHECK(pthread_mutex_lock(&gate) == 0);
    go = 1;
    CHECK(pthread_cond_signal(&condition) == 0);
    CHECK(pthread_mutex_unlock(&gate) == 0);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(other_count == 0);
    CHECK(malloc_logger != observer);
    emit(3);
    CHECK(alloc_counter_stop() >= 10);
    CHECK(malloc_logger == observer);
    CHECK(atomic_load(&observed) >= 23);
  } else if (strcmp(mode, "handoff") == 0) {
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, contender, NULL) == 0);
    alloc_counter_start();
    CHECK(pthread_mutex_lock(&gate) == 0);
    go = 1;
    CHECK(pthread_cond_signal(&condition) == 0);
    while (!attempted) CHECK(pthread_cond_wait(&condition, &gate) == 0);
    struct timespec deadline;
    CHECK(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_nsec += 100000000;
    if (deadline.tv_nsec >= 1000000000) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000; }
    while (!acquired) {
      int result = pthread_cond_timedwait(&condition, &gate, &deadline);
      if (result == ETIMEDOUT) break;
      CHECK(result == 0);
    }
    CHECK(!acquired);
    CHECK(pthread_mutex_unlock(&gate) == 0);
    emit(5);
    CHECK(alloc_counter_stop() >= 5);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(other_count == 11);
    CHECK(malloc_logger == observer);
  } else if (strcmp(mode, "abandon") == 0) {
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, abandon, NULL) == 0);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(malloc_logger == observer);
    alloc_counter_start(); emit(2);
    CHECK(alloc_counter_stop() == 2);
  } else if (strcmp(mode, "restart") == 0) {
    alloc_counter_start(); emit(7);
    alloc_counter_start(); emit(3);
    CHECK(alloc_counter_stop() == 3);
    CHECK(malloc_logger == observer);
    CHECK(atomic_load(&observed) >= 10);
  } else if (strcmp(mode, "replaced") == 0) {
    alloc_counter_start(); emit(2);
    malloc_logger = replacement;
    CHECK(alloc_counter_stop() == 2);
    CHECK(malloc_logger == replacement);
    alloc_counter_start(); emit(1);
    CHECK(alloc_counter_stop() == 1);
    CHECK(malloc_logger == replacement);
  } else if (strcmp(mode, "trace") == 0) {
    CHECK(setenv("ALLOC_COUNTER_TRACE", "1", 1) == 0);
    alloc_counter_start(); emit(1);
    CHECK(alloc_counter_stop() == 1);
    CHECK(malloc_logger == observer);
  } else if (strcmp(mode, "heap") == 0) {
    alloc_counter_start();
    // An indirect volatile call keeps optimized builds from eliding the sample.
    void *(*volatile allocate)(size_t) = malloc;
    void *data = allocate(4096);
    CHECK(data != NULL);
    memset(data, 1, 4096);
    CHECK(alloc_counter_stop() >= 1);
    free(data);
  } else { CHECK(0); }
}
int main(int argc, char **argv) {
  CHECK(argc == 2);
  unsetenv("ALLOC_COUNTER_TRACE");
  logger_t *saved = malloc_logger;
  malloc_logger = observer;
  run(argv[1]);
  malloc_logger = saved;
  printf("passed %s\n", argv[1]);
  return 0;
}
