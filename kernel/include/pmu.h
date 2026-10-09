// Performance monitoring unit access (K6e). Assembly, because the
// registers are system registers or CSRs with no Swift spelling: arm64
// PMUv3 sysregs, rv64 counter CSRs and SBI calls with five arguments
// (amd64 uses arch_rdmsr/arch_wrmsr).
#pragma once
#include <stdint.h>

// Generic events (the ABI's; Pmu maps them per arch). Raw arch event
// codes have CROI_PMU_RAW set.
enum : uint32_t {
  CROI_PMU_CYCLES = 0,
  CROI_PMU_INSTRUCTIONS = 1,
  CROI_PMU_CACHE_MISSES = 2,
  CROI_PMU_BRANCH_MISSES = 3,
  CROI_PMU_GENERIC_EVENTS = 4,
  CROI_PMU_RAW = 1u << 31,
};

// What pmu_configure's info operation returns.
typedef struct {
  uint32_t kind;          // CROI_PMU_KIND_*
  uint32_t counters;      // programmable counters the kernel may use
  uint32_t events;        // bit n: generic event n is supported
  uint32_t sampling;      // overflow sampling available (1) or not (0)
} croi_pmu_info_t;

enum : uint32_t {
  CROI_PMU_KIND_NONE = 0,
  CROI_PMU_KIND_INTEL = 1,  // architectural PerfMon
  CROI_PMU_KIND_AMD = 2,    // core counters (PerfCtrExtCore / legacy)
  CROI_PMU_KIND_ARM = 3,    // PMUv3
  CROI_PMU_KIND_SBI = 4,    // RISC-V SBI PMU (+ Sscofpmf for overflow)
  CROI_PMU_THREAD_EVENTS = 4,  // events a thread may count at once
};

#if defined(__aarch64__)
enum : uint32_t {
  CROI_PMU_PMCR = 0,
  CROI_PMU_PMCNTENSET = 1,
  CROI_PMU_PMCNTENCLR = 2,
  CROI_PMU_PMINTENSET = 3,
  CROI_PMU_PMINTENCLR = 4,
  CROI_PMU_PMOVSCLR = 5,
  CROI_PMU_PMCEID0 = 6,
  CROI_PMU_PMCCFILTR = 7,
  CROI_PMU_PMUSERENR = 8,
  CROI_PMU_DFR0 = 9,  // ID_AA64DFR0_EL1 (read only)
};
uint64_t arch_pmu_sysreg_read(uint32_t which);
void arch_pmu_sysreg_write(uint32_t which, uint64_t value);
// Event counter n (PMSELR_EL0 + PMXEV*).
uint64_t arch_pmu_counter_read(uint32_t n);
void arch_pmu_counter_write(uint32_t n, uint64_t value);
void arch_pmu_event_type(uint32_t n, uint64_t type);
#endif

#if defined(__riscv)
// Reads counter CSR `csr` (0xC00-0xC1F: cycle, time, instret, hpmcounterN);
// 0 for anything else.
uint64_t arch_rv_counter_read(uint32_t csr);
// SBI call with five arguments: returns the error; *value gets a1.
long arch_sbi_call5(uint64_t eid, uint64_t fid, uint64_t arg0, uint64_t arg1, uint64_t arg2, uint64_t arg3,
                    uint64_t arg4, uint64_t *_Nonnull value);
uint64_t arch_rv_scountovf(void);
void arch_rv_lcofi_enable(void);
#endif
