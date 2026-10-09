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

// void arch_tlb_invalidate_page(uint64_t va): all ASIDs, all levels
// (including walk-cache entries), broadcast to the inner shareable domain.
.globl arch_tlb_invalidate_page
.type arch_tlb_invalidate_page, %function
arch_tlb_invalidate_page:
    dsb     ishst                   // the PTE write is visible to walkers
    ubfx    x0, x0, #12, #44        // VA[55:12]
    tlbi    vaae1is, x0
    dsb     ish
    isb
    ret
.size arch_tlb_invalidate_page, . - arch_tlb_invalidate_page
