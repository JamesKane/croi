// Per-thread JIT write gating (assembly, arch/<arch>/cpu.S), for
// Kernel/Vm/Jit.swift: amd64 protection keys (PKU).

#pragma once

#include <stdint.h>

#if defined(__x86_64__)
// Sets CR4.PKE on this CPU if CPUID says PKU exists; returns 1 if it did.
uint64_t arch_pku_enable(void);
// This CPU's PKRU (per thread: switched by the scheduler).
uint32_t arch_read_pkru(void);
void arch_write_pkru(uint32_t value);
#endif

#if defined(__aarch64__)
// ID_AA64MMFR3_EL1.S1POE: permission overlays (Armv9.4). Detected only;
// croi uses dual views until hardware with POE exists.
uint64_t arch_has_poe(void);
#endif
