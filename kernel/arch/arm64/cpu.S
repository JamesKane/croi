// arm64 CPU primitives Swift can't express: interrupt masking and the
// spin-wait hint. See kernel.h.

.section .text.arch_cpu, "ax", %progbits

// uint64_t arch_interrupts_save(void): DAIF before masking IRQ and FIQ.
.globl arch_interrupts_save
.type arch_interrupts_save, %function
arch_interrupts_save:
    mrs     x0, daif
    msr     daifset, #3             // I and F
    ret
.size arch_interrupts_save, . - arch_interrupts_save

// void arch_interrupts_restore(uint64_t state)
.globl arch_interrupts_restore
.type arch_interrupts_restore, %function
arch_interrupts_restore:
    msr     daif, x0
    ret
.size arch_interrupts_restore, . - arch_interrupts_restore

// bool arch_interrupts_enabled(void): IRQs unmasked.
.globl arch_interrupts_enabled
.type arch_interrupts_enabled, %function
arch_interrupts_enabled:
    mrs     x0, daif
    tst     x0, #(1 << 7)           // DAIF.I
    cset    w0, eq
    ret
.size arch_interrupts_enabled, . - arch_interrupts_enabled

// void arch_spin_pause(void)
.globl arch_spin_pause
.type arch_spin_pause, %function
arch_spin_pause:
    yield
    ret
.size arch_spin_pause, . - arch_spin_pause
