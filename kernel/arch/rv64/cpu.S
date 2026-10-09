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

// void arch_tlb_invalidate_page(uint64_t va): this hart, all levels for va.
.globl arch_tlb_invalidate_page
.type arch_tlb_invalidate_page, %function
arch_tlb_invalidate_page:
    sfence.vma a0, zero
    ret
.size arch_tlb_invalidate_page, . - arch_tlb_invalidate_page

// void arch_set_percpu(uint64_t percpu): tp holds it in the kernel.
.globl arch_set_percpu
.type arch_set_percpu, %function
arch_set_percpu:
    mv      tp, a0
    ret
.size arch_set_percpu, . - arch_set_percpu

// uint64_t arch_percpu(void)
.globl arch_percpu
.type arch_percpu, %function
arch_percpu:
    mv      a0, tp
    ret
.size arch_percpu, . - arch_percpu

// uint64_t arch_cpu_hardware_id(void): unknowable in S-mode.
.globl arch_cpu_hardware_id
.type arch_cpu_hardware_id, %function
arch_cpu_hardware_id:
    li      a0, 0
    ret
.size arch_cpu_hardware_id, . - arch_cpu_hardware_id

// Caches are coherent with uncached accesses on RISC-V platforms we run on.
.globl arch_clean_dcache
.type arch_clean_dcache, %function
arch_clean_dcache:
    ret
.size arch_clean_dcache, . - arch_clean_dcache

// void arch_idle(void): interrupts on, wait for one, forever.
.globl arch_idle
.type arch_idle, %function
arch_idle:
    csrsi   sstatus, 0x2            // SIE
1:  wfi
    j       1b
.size arch_idle, . - arch_idle

// void arch_tlb_invalidate_all(void): this hart.
.globl arch_tlb_invalidate_all
.type arch_tlb_invalidate_all, %function
arch_tlb_invalidate_all:
    sfence.vma
    ret
.size arch_tlb_invalidate_all, . - arch_tlb_invalidate_all

// void arch_rv_sie_set(uint64_t mask) / void arch_rv_sie_clear(uint64_t mask)
// void arch_rv_sip_clear(uint64_t mask)
.globl arch_rv_sie_set
.type arch_rv_sie_set, %function
arch_rv_sie_set:
    csrs    sie, a0
    ret
.size arch_rv_sie_set, . - arch_rv_sie_set

.globl arch_rv_sie_clear
.type arch_rv_sie_clear, %function
arch_rv_sie_clear:
    csrc    sie, a0
    ret
.size arch_rv_sie_clear, . - arch_rv_sie_clear

.globl arch_rv_sip_clear
.type arch_rv_sip_clear, %function
arch_rv_sip_clear:
    csrc    sip, a0
    ret
.size arch_rv_sip_clear, . - arch_rv_sip_clear

// void arch_interrupts_enable(void)
.globl arch_interrupts_enable
.type arch_interrupts_enable, %function
arch_interrupts_enable:
    csrsi   sstatus, 0x2
    ret
.size arch_interrupts_enable, . - arch_interrupts_enable

// uint64_t arch_counter_read(void): the time CSR.
.globl arch_counter_read
.type arch_counter_read, %function
arch_counter_read:
    fence   iorw, iorw
    rdtime  a0
    ret
.size arch_counter_read, . - arch_counter_read

// uint32_t arch_cpu_core_type(void): nothing to tell cores apart by yet.
.globl arch_cpu_core_type
.type arch_cpu_core_type, %function
arch_cpu_core_type:
    li      a0, 0
    ret
.size arch_cpu_core_type, . - arch_cpu_core_type
