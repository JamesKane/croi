// rv64 CPU primitives Swift can't express: interrupt masking and the
// spin-wait hint. See kernel.h.

#define SSTATUS_SIE 0x2

.section .text.arch_cpu, "ax", %progbits

// uint64_t arch_interrupts_save(void): sstatus before clearing SIE.
.globl arch_interrupts_save
.type arch_interrupts_save, %function
arch_interrupts_save:
    csrrci  a0, sstatus, SSTATUS_SIE
    ret
.size arch_interrupts_save, . - arch_interrupts_save

// void arch_interrupts_restore(uint64_t state): only SIE is restored.
.globl arch_interrupts_restore
.type arch_interrupts_restore, %function
arch_interrupts_restore:
    andi    a0, a0, SSTATUS_SIE
    csrs    sstatus, a0
    ret
.size arch_interrupts_restore, . - arch_interrupts_restore

// bool arch_interrupts_enabled(void)
.globl arch_interrupts_enabled
.type arch_interrupts_enabled, %function
arch_interrupts_enabled:
    csrr    a0, sstatus
    srli    a0, a0, 1
    andi    a0, a0, 1
    ret
.size arch_interrupts_enabled, . - arch_interrupts_enabled

// void arch_spin_pause(void): Zihintpause `pause`, a FENCE hint (no-op)
// on harts without the extension.
.globl arch_spin_pause
.type arch_spin_pause, %function
arch_spin_pause:
    .insn i 0x0f, 0, x0, x0, 0x010
    ret
.size arch_spin_pause, . - arch_spin_pause
