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

// void arch_set_percpu(uint64_t percpu)
.globl arch_set_percpu
.type arch_set_percpu, %function
arch_set_percpu:
    msr     tpidr_el1, x0
    ret
.size arch_set_percpu, . - arch_set_percpu

// uint64_t arch_percpu(void)
.globl arch_percpu
.type arch_percpu, %function
arch_percpu:
    mrs     x0, tpidr_el1
    ret
.size arch_percpu, . - arch_percpu

// uint64_t arch_cpu_hardware_id(void): MPIDR_EL1 Aff3..Aff0.
.globl arch_cpu_hardware_id
.type arch_cpu_hardware_id, %function
arch_cpu_hardware_id:
    mrs     x0, mpidr_el1
    and     x1, x0, #0xffffff
    lsr     x0, x0, #32
    and     x0, x0, #0xff
    orr     x0, x1, x0, lsl #32
    ret
.size arch_cpu_hardware_id, . - arch_cpu_hardware_id

// void arch_clean_dcache(uint64_t va, uint64_t size)
.globl arch_clean_dcache
.type arch_clean_dcache, %function
arch_clean_dcache:
    mrs     x3, ctr_el0
    ubfx    x3, x3, #16, #4         // DminLine: log2(words per line)
    mov     x2, #4
    lsl     x2, x2, x3
    add     x1, x0, x1
    sub     x3, x2, #1
    bic     x0, x0, x3
1:  dc      cvac, x0
    add     x0, x0, x2
    cmp     x0, x1
    b.lo    1b
    dsb     sy
    ret
.size arch_clean_dcache, . - arch_clean_dcache

// void arch_idle(void): interrupts on, wait for one, forever.
.globl arch_idle
.type arch_idle, %function
arch_idle:
    msr     daifclr, #3             // I and F
1:  wfi
    b       1b
.size arch_idle, . - arch_idle

// void arch_tlb_invalidate_all(void): all CPUs (inner shareable).
.globl arch_tlb_invalidate_all
.type arch_tlb_invalidate_all, %function
arch_tlb_invalidate_all:
    dsb     ishst
    tlbi    vmalle1is
    dsb     ish
    isb
    ret
.size arch_tlb_invalidate_all, . - arch_tlb_invalidate_all

// GICv3 CPU interface (system registers).

// void arch_gicv3_cpu_init(void): system-register access on, all
// priorities unmasked, Group 1 enabled.
.globl arch_gicv3_cpu_init
.type arch_gicv3_cpu_init, %function
arch_gicv3_cpu_init:
    mrs     x0, ICC_SRE_EL1
    orr     x0, x0, #1              // SRE
    msr     ICC_SRE_EL1, x0
    isb
    mov     x0, #0xff
    msr     ICC_PMR_EL1, x0
    msr     ICC_BPR1_EL1, xzr
    mov     x0, #1
    msr     ICC_IGRPEN1_EL1, x0
    isb
    ret
.size arch_gicv3_cpu_init, . - arch_gicv3_cpu_init

// uint64_t arch_gicv3_ack(void): the INTID being handled (1023: spurious).
.globl arch_gicv3_ack
.type arch_gicv3_ack, %function
arch_gicv3_ack:
    mrs     x0, ICC_IAR1_EL1
    dsb     sy
    ret
.size arch_gicv3_ack, . - arch_gicv3_ack

// void arch_gicv3_eoi(uint64_t intid): EOImode 0, so this also deactivates.
.globl arch_gicv3_eoi
.type arch_gicv3_eoi, %function
arch_gicv3_eoi:
    msr     ICC_EOIR1_EL1, x0
    isb
    ret
.size arch_gicv3_eoi, . - arch_gicv3_eoi

// void arch_gicv3_send_sgi(uint64_t value): an ICC_SGI1R_EL1 value.
.globl arch_gicv3_send_sgi
.type arch_gicv3_send_sgi, %function
arch_gicv3_send_sgi:
    dsb     ishst                   // the mailbox write before the IPI
    msr     ICC_SGI1R_EL1, x0
    isb
    ret
.size arch_gicv3_send_sgi, . - arch_gicv3_send_sgi

// void arch_interrupts_enable(void)
.globl arch_interrupts_enable
.type arch_interrupts_enable, %function
arch_interrupts_enable:
    msr     daifclr, #3
    ret
.size arch_interrupts_enable, . - arch_interrupts_enable

// uint64_t arch_counter_read(void): CNTVCT_EL0, after earlier instructions.
.globl arch_counter_read
.type arch_counter_read, %function
arch_counter_read:
    isb
    mrs     x0, cntvct_el0
    ret
.size arch_counter_read, . - arch_counter_read

// uint64_t arch_counter_frequency(void)
.globl arch_counter_frequency
.type arch_counter_frequency, %function
arch_counter_frequency:
    mrs     x0, cntfrq_el0
    ret
.size arch_counter_frequency, . - arch_counter_frequency

// void arch_timer_arm(uint64_t deadline): virtual timer, enabled, unmasked.
.globl arch_timer_arm
.type arch_timer_arm, %function
arch_timer_arm:
    msr     cntv_cval_el0, x0
    mov     x1, #1                  // ENABLE, IMASK clear
    msr     cntv_ctl_el0, x1
    isb
    ret
.size arch_timer_arm, . - arch_timer_arm

// void arch_timer_disarm(void)
.globl arch_timer_disarm
.type arch_timer_disarm, %function
arch_timer_disarm:
    msr     cntv_ctl_el0, xzr
    isb
    ret
.size arch_timer_disarm, . - arch_timer_disarm

// uint32_t arch_cpu_core_type(void): MIDR implementer << 16 | part number.
.globl arch_cpu_core_type
.type arch_cpu_core_type, %function
arch_cpu_core_type:
    mrs     x1, midr_el1
    ubfx    x0, x1, #24, #8         // implementer
    ubfx    x1, x1, #4, #12         // part number
    orr     x0, x1, x0, lsl #16
    ret
.size arch_cpu_core_type, . - arch_cpu_core_type
