// Interrupt-controller primitives Swift can't express (assembly,
// arch/<arch>/cpu.S), for Kernel/Irq/.

#pragma once

#include <stdint.h>

// Enables interrupts and waits for them forever (the idle loop).
[[noreturn]] void arch_idle(void);

// Unmasks interrupts on this CPU.
void arch_interrupts_enable(void);

// Invalidates every TLB entry, global ones included. amd64/rv64: this CPU;
// arm64: all CPUs.
void arch_tlb_invalidate_all(void);

#if defined(__x86_64__)
void arch_cpuid(uint32_t leaf, uint32_t subleaf, uint32_t out[_Nonnull 4]);
#endif

#if defined(__aarch64__)
void arch_gicv3_cpu_init(void);
uint64_t arch_gicv3_ack(void);
void arch_gicv3_eoi(uint64_t intid);
void arch_gicv3_send_sgi(uint64_t value);
#endif

#if defined(__riscv)
void arch_rv_sie_set(uint64_t mask);
void arch_rv_sie_clear(uint64_t mask);
void arch_rv_sip_clear(uint64_t mask);
#endif
