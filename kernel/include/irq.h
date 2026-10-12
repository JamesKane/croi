// Interrupt-controller primitives Swift can't express (assembly,
// arch/<arch>/cpu.S), for Kernel/Irq/.

#pragma once

#include <stdint.h>

// Enables interrupts and waits for them forever (the idle loop).
[[noreturn]] void arch_idle(void);
// amd64 (K15c): MONITOR a private line, then sti; MWAIT with `hint`; cli
// (as arch_wait_for_interrupt's sti; hlt). Returns masked.
void arch_idle_mwait(uint32_t hint);

// Called with interrupts masked: waits until one is pending, lets it be
// taken, and returns with interrupts masked again. No wakeup is lost
// between the caller's last check and the wait.
void arch_wait_for_interrupt(void);

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

// AIA (K12i, Ssaia): the IMSIC's indirect registers through siselect /
// sireg (eidelivery 0x70, eithreshold 0x72, eie 0xC0 + 2k on RV64), and
// claiming the top pending identity (stopei: identity << 16 | priority,
// 0 when none).
uint64_t arch_rv_imsic_read(uint64_t select);
void arch_rv_imsic_write(uint64_t select, uint64_t value);
uint64_t arch_rv_imsic_claim(void);
#endif
