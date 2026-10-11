// The shared read-only pages (roadmap "Shared read-only pages"): kernel
// data user space reads without a syscall, through the vDSO. Each starts
// with a seqlock sequence (odd while the kernel writes) and a version.
// croi_time_page_t (time.h) is the first; these follow it in the vDSO's
// data area: time, topology, power.

#pragma once

#include <stdint.h>

enum : uint32_t {
  CROI_TOPOLOGY_PAGE_VERSION = 2,
  CROI_POWER_PAGE_VERSION = 1,
  CROI_SHARED_MAX_CPUS = 64,
};

// Ext 9: where each CPU sits and what it is (written at boot; capacity
// when the power service changes it).
typedef struct {
  uint32_t core_type;  // amd64 hybrid type / arm64 MIDR implementer<<16|part / 0
  uint32_t capacity;   // 1024 = the biggest core
  uint32_t package;
  uint32_t core;
  uint32_t thread;     // 1: an SMT thread of its core
  uint32_t last_level_cache;
} croi_topology_cpu_t;

typedef struct {
  uint64_t sequence;
  uint32_t version;
  uint32_t cpu_count;
  croi_topology_cpu_t cpus[CROI_SHARED_MAX_CPUS];
  // Version 2: the smallest cache lines user cache maintenance steps by
  // (0: none needed or possible; rv64 without Zicbom is coherent).
  uint32_t dcache_line;
  uint32_t icache_line;
} croi_topology_page_t;

// Ext 9: each CPU's published power hints (K3c: the wake-latency bound and
// frequency floor admitted deadline work needs), for the power service.
typedef struct {
  uint64_t wake_latency_ns;  // ~0: no bound
  uint64_t frequency_floor;  // fraction of capacity, 1 << 20 = all of it
} croi_power_cpu_t;

typedef struct {
  uint64_t sequence;
  uint32_t version;
  uint32_t cpu_count;
  croi_power_cpu_t cpus[CROI_SHARED_MAX_CPUS];
  // Self-test only: written as an equal pair under the seqlock.
  uint64_t test_a;
  uint64_t test_b;
} croi_power_page_t;

// The vDSO image's header, at its first byte: offsets of its functions
// from the header (K8's loader can use ELF symbols instead).
typedef struct {
  uint32_t magic;    // CROI_VDSO_MAGIC
  uint32_t version;
  uint32_t clock_monotonic;  // uint64_t (void)
  uint32_t topology;         // const croi_topology_page_t *(void)
  uint32_t power;            // const croi_power_page_t *(void)
  uint32_t code_size;        // bytes of code; the three data pages follow, page aligned
  // Version 2:
  uint32_t cache_flush;      // int32_t (const void *addr, uint64_t len, uint32_t options): Zircon's
} croi_vdso_header_t;

enum : uint32_t { CROI_VDSO_MAGIC = 0x53445643 /* "CVDS" */ };

// User access to the counter, per CPU: arm64 CNTKCTL_EL1.EL0VCTEN, rv64
// scounteren.TM; amd64 nothing (rdtsc is allowed while CR4.TSD is clear).
void arch_user_counter_enable(void);

// Hardware debug (K13g). amd64: DR0-3, DR6, DR7 by number (0-3, 6, 7).
// arm64: the OS lock cleared (per CPU, at start); MDSCR_EL1; the
// breakpoint / watchpoint registers loaded from a
// croi_thread_state_debug_regs_t (the first `bps` / `wps` pairs), or zeroed;
// ID_AA64DFR0_EL1.
uint64_t arch_debug_read(uint64_t n);
void arch_debug_write(uint64_t n, uint64_t value);
void arch_debug_cpu_init(void);
void arch_debug_load(const void *_Nullable regs, uint64_t mdscr, uint64_t bps, uint64_t wps);
uint64_t arch_debug_features(void);

// User cache maintenance (the vDSO's cache_flush), per CPU: arm64
// SCTLR_EL1.UCI/UCT, rv64 senvcfg.CBCFE when `zicbom`; amd64 nothing.
void arch_user_cache_enable(uint64_t zicbom);
