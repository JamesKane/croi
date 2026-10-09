// Extended register state detection (assembly, arch/<arch>/cpu.S), for
// Kernel/Sched/ExtendedState.swift. The kernel itself never uses FP/SIMD:
// these only measure what user threads (K6) will need saved.

#pragma once

#include <stdint.h>

#if defined(__aarch64__)
enum : uint32_t {
  CROI_ID_AA64PFR0 = 0,
  CROI_ID_AA64PFR1 = 1,
  CROI_ID_AA64SMFR0 = 2,
};
uint64_t arch_arm64_id_register(uint32_t which);
// The largest SVE vector length (bytes) this CPU offers: ZCR_EL1.LEN is
// left at `len` (0..15) afterwards, 15 asking for the hardware maximum.
// CPACR_EL1 traps are lifted only for the call.
uint64_t arch_sve_vector_length(uint64_t len);
// The same for SME's streaming vector length (SMCR_EL1).
uint64_t arch_sme_vector_length(uint64_t len);
#endif

#if defined(__riscv)
// vlenb: the V extension's vector register length in bytes (only call it
// when the V extension is present). sstatus.VS is on only for the read.
uint64_t arch_rv_vlenb(void);
#endif
