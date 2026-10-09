// Secondary CPU startup block, shared by the arch trampolines (assembly)
// and Swift (Kernel/Smp.swift).
//
// A starting CPU runs the trampoline at a physical address with its MMU
// off and reads this block (also by physical address) to join the kernel's
// address space: page-table registers, its stack and its per-CPU record.

#pragma once

#define CROI_AP_STACK   0   // initial stack pointer (virtual)
#define CROI_AP_PERCPU  8   // PerCpu record (virtual), for the per-CPU register
#define CROI_AP_DELTA   16  // kernel virtual minus physical address
#define CROI_AP_ROOT    24  // amd64 CR3; arm64 TTBR1_EL1; rv64 satp
#define CROI_AP_ROOT_LO 32  // arm64 TTBR0_EL1; amd64 low (<4 GiB) bootstrap PML4
#define CROI_AP_MAIR    40  // arm64 only
#define CROI_AP_TCR     48  // arm64 only
#define CROI_AP_SCTLR   56  // arm64 only
#define CROI_AP_SIZE    64

#ifndef __ASSEMBLER__
#include <stdint.h>

typedef struct {
  uint64_t stack;
  uint64_t percpu;
  uint64_t delta;
  uint64_t root;
  uint64_t root_low;
  uint64_t mair;
  uint64_t tcr;
  uint64_t sctlr;
} croi_ap_startup_t;

static_assert(sizeof(croi_ap_startup_t) == CROI_AP_SIZE);

// Assembly (arch/<arch>/smp.S). The trampoline's entry point; started at
// its physical address. rv64: a0 = hart ID, a1 = startup block (physical).
// arm64: x0 = startup block (physical).
void arch_ap_entry(void);

// Assembly (arch/<arch>/smp.S). Copies this CPU's MMU configuration into
// the block's arch fields, so secondaries match it.
void arch_ap_capture_mmu(croi_ap_startup_t *_Nonnull block);

// Assembly (arch/<arch>/exceptions.S, smp.S). Exception setup on a
// secondary CPU: the shared vectors (amd64: IDT only, no TSS yet).
void arch_ap_init_exceptions(void);

#if defined(__x86_64__)
// Assembly (arch/amd64/smp.S). Copies the real-mode trampoline to `dest`
// (the physmap view of `dest_phys`, below 1 MiB) and patches it.
void arch_ap_prepare_trampoline(void *_Nonnull dest, uint64_t dest_phys, uint64_t bootstrap_cr3,
                                const croi_ap_startup_t *_Nonnull block);
uint64_t arch_rdmsr(uint32_t msr);
void arch_wrmsr(uint32_t msr, uint64_t value);
#endif

#if defined(__riscv)
// Assembly (arch/rv64/smp.S). An SBI call; returns the SBI error code.
long arch_sbi_call(uint64_t eid, uint64_t fid, uint64_t arg0, uint64_t arg1, uint64_t arg2);
#endif

#if defined(__aarch64__)
// Assembly (arch/arm64/smp.S). A PSCI call via SMC, or HVC if use_hvc.
uint64_t arch_psci_call(uint64_t fid, uint64_t arg1, uint64_t arg2, uint64_t arg3, uint64_t use_hvc);
#endif

// The trampoline's (virtual) address. Inline C because Swift can't take a
// C function's address as an integer.
static inline uint64_t arch_ap_entry_address(void) {
  return (uint64_t)(uintptr_t)&arch_ap_entry;
}

// Swift (Kernel/Smp.swift). A secondary CPU's first Swift code, on its
// own stack with the per-CPU register set. `percpu` is its PerCpu record.
[[noreturn]] void kernel_ap_main(uint64_t percpu);
#endif
