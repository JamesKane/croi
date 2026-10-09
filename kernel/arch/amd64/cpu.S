// amd64 CPU primitives Swift can't express: interrupt masking and the
// spin-wait hint. See kernel.h.

.section .text.arch_cpu, "ax", @progbits

// uint64_t arch_interrupts_save(void): RFLAGS before masking.
.globl arch_interrupts_save
.type arch_interrupts_save, @function
arch_interrupts_save:
    pushfq
    popq    %rax
    cli
    ret
.size arch_interrupts_save, . - arch_interrupts_save

// void arch_interrupts_restore(uint64_t state)
.globl arch_interrupts_restore
.type arch_interrupts_restore, @function
arch_interrupts_restore:
    test    $(1 << 9), %edi         // RFLAGS.IF
    jz      1f
    sti
1:  ret
.size arch_interrupts_restore, . - arch_interrupts_restore

// bool arch_interrupts_enabled(void)
.globl arch_interrupts_enabled
.type arch_interrupts_enabled, @function
arch_interrupts_enabled:
    pushfq
    popq    %rax
    shr     $9, %eax
    and     $1, %eax
    ret
.size arch_interrupts_enabled, . - arch_interrupts_enabled

// void arch_spin_pause(void)
.globl arch_spin_pause
.type arch_spin_pause, @function
arch_spin_pause:
    pause
    ret
.size arch_spin_pause, . - arch_spin_pause

// void arch_tlb_invalidate_page(uint64_t va): this CPU only. invlpg also
// drops paging-structure cache entries used to translate va.
.globl arch_tlb_invalidate_page
.type arch_tlb_invalidate_page, @function
arch_tlb_invalidate_page:
    invlpg  (%rdi)
    ret
.size arch_tlb_invalidate_page, . - arch_tlb_invalidate_page
