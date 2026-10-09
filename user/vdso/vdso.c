// croi's vDSO (K6c): code every process gets, mapped read/execute with the
// shared read-only pages right after it (time, topology, power), which it
// reaches PC-relatively, so it works wherever it is mapped. Built with
// user flags, position independent, no writable data.

#include <stdint.h>

#include "shared.h"
#include "time.h"

#define HIDDEN __attribute__((visibility("hidden")))

// The data pages, placed by vdso.ld after the code.
extern const croi_time_page_t croi_vdso_time_page HIDDEN;
extern const croi_topology_page_t croi_vdso_topology_page HIDDEN;
extern const croi_power_page_t croi_vdso_power_page HIDDEN;

static inline uint64_t counter(void) {
#if defined(__x86_64__)
  uint32_t low, high;
  __asm__ volatile("lfence; rdtsc" : "=a"(low), "=d"(high));
  return (uint64_t)high << 32 | low;
#elif defined(__aarch64__)
  uint64_t value;
  __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(value));
  return value;
#elif defined(__riscv)
  uint64_t value;
  __asm__ volatile("rdtime %0" : "=r"(value));
  return value;
#endif
}

// Monotonic nanoseconds, as Clock.now: ((counter - base) * mult) >> 32.
HIDDEN uint64_t croi_vdso_clock_monotonic(void) {
  const croi_time_page_t *page = &croi_vdso_time_page;
  for (;;) {
    uint64_t sequence = __atomic_load_n(&page->sequence, __ATOMIC_ACQUIRE);
    if (sequence & 1) continue;
    uint64_t base = page->counter_base, mult = page->ns_mult;
    uint64_t now = counter();
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    if (__atomic_load_n(&page->sequence, __ATOMIC_RELAXED) != sequence) continue;
    return (uint64_t)(((unsigned __int128)(now - base) * mult) >> 32);
  }
}

HIDDEN const croi_topology_page_t *croi_vdso_topology(void) { return &croi_vdso_topology_page; }
HIDDEN const croi_power_page_t *croi_vdso_power(void) { return &croi_vdso_power_page; }
