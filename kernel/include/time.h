// Time: the counter, per-CPU timer hardware (assembly, arch/<arch>/cpu.S),
// and the clock parameters page.
//
// croi_time_page_t is the first of the shared read-only pages (roadmap
// "Shared read-only pages"): K6 maps it into user address spaces so the
// vDSO can read the monotonic clock without a syscall. Keep it a stable,
// versioned layout.

#pragma once

#include <stdint.h>

enum : uint32_t {
  CROI_COUNTER_TSC = 1,        // amd64 time-stamp counter
  CROI_COUNTER_ARM_VIRTUAL,    // arm64 CNTVCT_EL0
  CROI_COUNTER_RISCV_TIME,     // rv64 time CSR
};

enum : uint32_t { CROI_TIME_PAGE_VERSION = 1 };

typedef struct {
  // Seqlock: odd while the kernel is updating the fields below. Readers
  // retry if it is odd or changes across their read.
  uint64_t sequence;
  uint32_t version;       // CROI_TIME_PAGE_VERSION
  uint32_t counter_kind;  // CROI_COUNTER_*
  uint64_t counter_frequency;  // Hz
  uint64_t counter_base;       // raw counter value at monotonic time 0
  // Monotonic nanoseconds = ((counter - counter_base) * ns_mult) >> 32,
  // with a 128-bit product.
  uint64_t ns_mult;
} croi_time_page_t;

static_assert(sizeof(croi_time_page_t) == 40);

// The raw counter, ordered against surrounding instructions.
uint64_t arch_counter_read(void);

#if defined(__aarch64__)
// CNTFRQ_EL0.
uint64_t arch_counter_frequency(void);
// The virtual timer: fire when CNTVCT_EL0 >= deadline / stop.
void arch_timer_arm(uint64_t deadline);
void arch_timer_disarm(void);
#endif
