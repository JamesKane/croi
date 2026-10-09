#include "stack.h"
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

// void arch_set_percpu(uint64_t percpu): GS base points at the record,
// whose `self` field (CROI_PERCPU_SELF) holds its own address, so
// arch_percpu is one %gs-relative load instead of an rdmsr (~100 cycles,
// on every Cpu.current). 0 points GS at a record whose `self` is 0.
.globl arch_set_percpu
.type arch_set_percpu, @function
arch_set_percpu:
    test    %rdi, %rdi
    jnz     1f
    lea     no_percpu(%rip), %rax
    jmp     2f
1:  mov     %rdi, CROI_PERCPU_SELF(%rdi)
    mov     %rdi, %rax
2:  mov     %rax, %rdx
    shr     $32, %rdx
    mov     $MSR_GS_BASE, %ecx
    wrmsr
    ret
.size arch_set_percpu, . - arch_set_percpu

// uint64_t arch_percpu(void)
.globl arch_percpu
.type arch_percpu, @function
arch_percpu:
    mov     %gs:CROI_PERCPU_SELF, %rax
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

// void arch_idle(void): interrupts on, halt until one arrives, forever.
.globl arch_idle
.type arch_idle, @function
arch_idle:
1:  sti
    hlt
    jmp     1b
.size arch_idle, . - arch_idle

// void arch_wait_for_interrupt(void): sti's one-instruction shadow means
// the interrupt can't arrive before hlt.
.globl arch_wait_for_interrupt
.type arch_wait_for_interrupt, @function
arch_wait_for_interrupt:
    sti
    hlt
    cli
    ret
.size arch_wait_for_interrupt, . - arch_wait_for_interrupt

// void arch_tlb_invalidate_all(void): this CPU, global entries included
// (toggling CR4.PGE flushes them; a CR3 reload alone would not).
.globl arch_tlb_invalidate_all
.type arch_tlb_invalidate_all, @function
arch_tlb_invalidate_all:
    mov     %cr4, %rax
    mov     %rax, %rcx
    and     $~(1 << 7), %rcx
    mov     %rcx, %cr4
    mov     %rax, %cr4
    ret
.size arch_tlb_invalidate_all, . - arch_tlb_invalidate_all

// void arch_interrupts_enable(void)
.globl arch_interrupts_enable
.type arch_interrupts_enable, @function
arch_interrupts_enable:
    sti
    ret
.size arch_interrupts_enable, . - arch_interrupts_enable

// void arch_cpuid(uint32_t leaf, uint32_t subleaf, uint32_t out[4]): eax, ebx, ecx, edx.
.globl arch_cpuid
.type arch_cpuid, @function
arch_cpuid:
    push    %rbx
    mov     %rdx, %r8
    mov     %edi, %eax
    mov     %esi, %ecx
    cpuid
    mov     %eax, 0(%r8)
    mov     %ebx, 4(%r8)
    mov     %ecx, 8(%r8)
    mov     %edx, 12(%r8)
    pop     %rbx
    ret
.size arch_cpuid, . - arch_cpuid

// uint64_t arch_counter_read(void): TSC, not reordered with earlier loads.
.globl arch_counter_read
.type arch_counter_read, @function
arch_counter_read:
    lfence
    rdtsc
    shl     $32, %rdx
    or      %rdx, %rax
    ret
.size arch_counter_read, . - arch_counter_read

// uint32_t arch_cpu_core_type(void): CPUID 0x1A EAX[31:24] on hybrid
// parts (CPUID 7 EDX bit 15), else 0.
.globl arch_cpu_core_type
.type arch_cpu_core_type, @function
arch_cpu_core_type:
    push    %rbx
    xor     %eax, %eax
    cpuid
    cmp     $0x1a, %eax
    jb      1f
    mov     $7, %eax
    xor     %ecx, %ecx
    cpuid
    bt      $15, %edx               // hybrid
    jnc     1f
    mov     $0x1a, %eax
    xor     %ecx, %ecx
    cpuid
    shr     $24, %eax
    pop     %rbx
    ret
1:  xor     %eax, %eax
    pop     %rbx
    ret
.size arch_cpu_core_type, . - arch_cpu_core_type

// GS points here until a CPU has its PerCpu record: `self` reads 0.
.section .bss.no_percpu, "aw", @nobits
.balign 16
no_percpu:
    .zero 16

// --- User address spaces (aspace.h) --------------------------------------
.section .text.arch_aspace, "ax", @progbits

.globl arch_switch_user_tables
.type arch_switch_user_tables, @function
arch_switch_user_tables:
    mov     %rdi, %cr3
    ret
.size arch_switch_user_tables, . - arch_switch_user_tables

.globl arch_tlb_invalidate_asid
.type arch_tlb_invalidate_asid, @function
arch_tlb_invalidate_asid:
    ret
.size arch_tlb_invalidate_asid, . - arch_tlb_invalidate_asid

.globl arch_user_access_begin
.type arch_user_access_begin, @function
arch_user_access_begin:
    cmpb    $0, croi_user_protection(%rip)
    je      1f
    stac
1:  ret
.size arch_user_access_begin, . - arch_user_access_begin

.globl arch_user_access_end
.type arch_user_access_end, @function
arch_user_access_end:
    cmpb    $0, croi_user_protection(%rip)
    je      1f
    clac
1:  ret
.size arch_user_access_end, . - arch_user_access_end

// uint64_t arch_user_protection_enable(void): CPUID.7.0:EBX SMEP (7) and
// SMAP (20) -> CR4 bits 20 and 21.
.globl arch_user_protection_enable
.type arch_user_protection_enable, @function
arch_user_protection_enable:
    push    %rbx
    mov     $7, %eax
    xor     %ecx, %ecx
    cpuid
    mov     %cr4, %rax
    test    $(1 << 7), %ebx
    jz      1f
    or      $(1 << 20), %rax        // SMEP
1:  xor     %edx, %edx
    test    $(1 << 20), %ebx
    jz      2f
    or      $(1 << 21), %rax        // SMAP
    mov     $1, %edx
2:  mov     %rax, %cr4
    mov     %rdx, %rax
    pop     %rbx
    ret
.size arch_user_protection_enable, . - arch_user_protection_enable

.globl arch_asid_bits
.type arch_asid_bits, @function
arch_asid_bits:
    xor     %eax, %eax
    ret
.size arch_asid_bits, . - arch_asid_bits

// --- Cache maintenance (cache.h) -----------------------------------------

// void arch_cache_op(addr, size, op, line): clflush writes back and drops,
// so every op is clean+invalidate here.
.globl arch_cache_op
.type arch_cache_op, @function
arch_cache_op:
    test    %rcx, %rcx
    jz      2f
    lea     (%rdi, %rsi), %rsi          // end
    lea     -1(%rcx), %rax
    not     %rax
    and     %rax, %rdi                  // first line
    mfence
1:  clflush (%rdi)
    add     %rcx, %rdi
    cmp     %rsi, %rdi
    jb      1b
    mfence
2:  ret
.size arch_cache_op, . - arch_cache_op

// uint64_t arch_cache_line(void): CPUID.1 EBX[15:8] x 8 bytes.
.globl arch_cache_line
.type arch_cache_line, @function
arch_cache_line:
    push    %rbx
    mov     $1, %eax
    xor     %ecx, %ecx
    cpuid
    shr     $8, %ebx
    and     $0xff, %ebx
    lea     (, %rbx, 8), %rax
    pop     %rbx
    ret
.size arch_cache_line, . - arch_cache_line

// --- Protection keys (jit.h) ----------------------------------------------

// uint64_t arch_pku_enable(void): CPUID.7.0:ECX[3] PKU -> CR4.PKE (bit 22).
.globl arch_pku_enable
.type arch_pku_enable, @function
arch_pku_enable:
    push    %rbx
    mov     $7, %eax
    xor     %ecx, %ecx
    cpuid
    xor     %eax, %eax
    test    $(1 << 3), %ecx
    jz      1f
    mov     %cr4, %rax
    or      $(1 << 22), %rax
    mov     %rax, %cr4
    mov     $1, %eax
1:  pop     %rbx
    ret
.size arch_pku_enable, . - arch_pku_enable

// uint32_t arch_read_pkru(void)
.globl arch_read_pkru
.type arch_read_pkru, @function
arch_read_pkru:
    xor     %ecx, %ecx
    rdpkru
    ret
.size arch_read_pkru, . - arch_read_pkru

// void arch_write_pkru(uint32_t value)
.globl arch_write_pkru
.type arch_write_pkru, @function
arch_write_pkru:
    mov     %edi, %eax
    xor     %ecx, %ecx
    xor     %edx, %edx
    wrpkru
    ret
.size arch_write_pkru, . - arch_write_pkru

// void arch_user_counter_enable(void): CR4.TSD clear, so rdtsc works in user mode.
.globl arch_user_counter_enable
.type arch_user_counter_enable, @function
arch_user_counter_enable:
    mov     %cr4, %rax
    and     $~(1 << 2), %rax
    mov     %rax, %cr4
    ret
.size arch_user_counter_enable, . - arch_user_counter_enable

// --- User extended state (xstate.h) ---------------------------------------

// void arch_xstate_enable(void): CR4.OSFXSR, OSXMMEXCPT; with a feature
// mask, CR4.OSXSAVE and XCR0 = the mask. CR0.EM off, MP on, TS off.
.globl arch_xstate_enable
.type arch_xstate_enable, @function
arch_xstate_enable:
    mov     %cr0, %rax
    and     $~((1 << 2) | (1 << 3)), %rax  // EM, TS
    or      $(1 << 1), %rax                // MP
    mov     %rax, %cr0
    mov     %cr4, %rax
    or      $((1 << 9) | (1 << 10)), %rax  // OSFXSR, OSXMMEXCPT
    mov     croi_xstate_config(%rip), %rcx
    test    %rcx, %rcx
    jz      1f
    or      $(1 << 18), %rax               // OSXSAVE
    mov     %rax, %cr4
    mov     %ecx, %eax
    shr     $32, %rcx
    mov     %ecx, %edx
    xor     %ecx, %ecx                     // XCR0
    xsetbv
    ret
1:  mov     %rax, %cr4
    ret
.size arch_xstate_enable, . - arch_xstate_enable

// void arch_xstate_save(void *area)
.globl arch_xstate_save
.type arch_xstate_save, @function
arch_xstate_save:
    mov     croi_xstate_config(%rip), %rax
    test    %rax, %rax
    jz      1f
    mov     %rax, %rdx
    shr     $32, %rdx
    xsave64 (%rdi)
    ret
1:  fxsave64 (%rdi)
    ret
.size arch_xstate_save, . - arch_xstate_save

// void arch_xstate_restore(const void *area)
.globl arch_xstate_restore
.type arch_xstate_restore, @function
arch_xstate_restore:
    mov     croi_xstate_config(%rip), %rax
    test    %rax, %rax
    jz      1f
    mov     %rax, %rdx
    shr     $32, %rdx
    xrstor64 (%rdi)
    ret
1:  fxrstor64 (%rdi)
    ret
.size arch_xstate_restore, . - arch_xstate_restore
