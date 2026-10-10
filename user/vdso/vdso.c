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

// Zircon's zx_cache_flush: data and/or instruction cache maintenance on
// [addr, addr+len) of the caller's own memory, by the lines the topology
// page publishes. 0, or CROI_ERR_INVALID_ARGS (-10) for bad options.
#define CACHE_FLUSH_INSN 1u
#define CACHE_FLUSH_DATA 2u
#define CACHE_FLUSH_INVALIDATE 4u

HIDDEN int32_t croi_vdso_cache_flush(const void *addr, uint64_t len, uint32_t options) {
  if (options == 0 || (options & ~(CACHE_FLUSH_INSN | CACHE_FLUSH_DATA | CACHE_FLUSH_INVALIDATE)) != 0 ||
      ((options & CACHE_FLUSH_INVALIDATE) && !(options & CACHE_FLUSH_DATA)))
    return -10;
  if (len == 0) return 0;
  uint64_t start = (uint64_t)addr, end = start + len;
  uint64_t dline = croi_vdso_topology_page.dcache_line;
#if defined(__x86_64__)
  // Instruction fetch is coherent; clflush writes back and invalidates.
  if ((options & CACHE_FLUSH_DATA) && dline != 0) {
    __asm__ volatile("mfence" ::: "memory");
    for (uint64_t p = start & ~(dline - 1); p < end; p += dline) __asm__ volatile("clflush (%0)" ::"r"(p) : "memory");
    __asm__ volatile("mfence" ::: "memory");
  }
#elif defined(__aarch64__)
  if ((options & CACHE_FLUSH_DATA) && dline != 0) {
    for (uint64_t p = start & ~(dline - 1); p < end; p += dline) {
      if (options & CACHE_FLUSH_INVALIDATE)
        __asm__ volatile("dc civac, %0" ::"r"(p) : "memory");
      else
        __asm__ volatile("dc cvac, %0" ::"r"(p) : "memory");
    }
    __asm__ volatile("dsb sy" ::: "memory");
  }
  if (options & CACHE_FLUSH_INSN) {
    uint64_t iline = croi_vdso_topology_page.icache_line;
    if (dline != 0) {
      for (uint64_t p = start & ~(dline - 1); p < end; p += dline) __asm__ volatile("dc cvau, %0" ::"r"(p) : "memory");
      __asm__ volatile("dsb ish" ::: "memory");
    }
    if (iline != 0) {
      for (uint64_t p = start & ~(iline - 1); p < end; p += iline) __asm__ volatile("ic ivau, %0" ::"r"(p) : "memory");
    }
    __asm__ volatile("dsb ish; isb" ::: "memory");
  }
#elif defined(__riscv)
  // Zicbom (dline != 0): cbo.clean / cbo.flush, encoded since the user
  // baseline ISA doesn't include it. Without it the platform is coherent.
  if ((options & CACHE_FLUSH_DATA) && dline != 0) {
    __asm__ volatile("fence rw, rw" ::: "memory");
    for (uint64_t p = start & ~(dline - 1); p < end; p += dline) {
      if (options & CACHE_FLUSH_INVALIDATE)
        __asm__ volatile(".insn i 0x0F, 2, x0, %0, 2" ::"r"(p) : "memory");  // cbo.flush
      else
        __asm__ volatile(".insn i 0x0F, 2, x0, %0, 1" ::"r"(p) : "memory");  // cbo.clean
    }
    __asm__ volatile("fence rw, rw" ::: "memory");
  }
  if (options & CACHE_FLUSH_INSN) __asm__ volatile("fence.i" ::: "memory");
#endif
  return 0;
}
