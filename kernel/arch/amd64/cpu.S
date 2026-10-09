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

#define MSR_GS_BASE 0xc0000101

// void arch_set_percpu(uint64_t percpu)
.globl arch_set_percpu
.type arch_set_percpu, @function
arch_set_percpu:
    mov     $MSR_GS_BASE, %ecx
    mov     %edi, %eax
    mov     %rdi, %rdx
    shr     $32, %rdx
    wrmsr
    ret
.size arch_set_percpu, . - arch_set_percpu

// uint64_t arch_percpu(void)
.globl arch_percpu
.type arch_percpu, @function
arch_percpu:
    mov     $MSR_GS_BASE, %ecx
    rdmsr
    shl     $32, %rdx
    or      %rdx, %rax
    ret
.size arch_percpu, . - arch_percpu

// uint64_t arch_cpu_hardware_id(void): x2APIC ID (CPUID 0xB) if
// available, else the xAPIC ID (CPUID 1).
.globl arch_cpu_hardware_id
.type arch_cpu_hardware_id, @function
arch_cpu_hardware_id:
    push    %rbx
    xor     %eax, %eax
    cpuid
    cmp     $0xb, %eax
    jb      1f
    mov     $0xb, %eax
    xor     %ecx, %ecx
    cpuid
    mov     %edx, %eax
    pop     %rbx
    ret
1:  mov     $1, %eax
    cpuid
    mov     %ebx, %eax
    shr     $24, %eax
    pop     %rbx
    ret
.size arch_cpu_hardware_id, . - arch_cpu_hardware_id

// Caches are coherent on x86.
.globl arch_clean_dcache
.type arch_clean_dcache, @function
arch_clean_dcache:
    ret
.size arch_clean_dcache, . - arch_clean_dcache
