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

// void arch_wait_for_interrupt(void): wfi wakes on a pending interrupt
// even while it is masked; unmasking then takes it.
.globl arch_wait_for_interrupt
.type arch_wait_for_interrupt, %function
arch_wait_for_interrupt:
    dsb     sy
    wfi
    msr     daifclr, #3
    isb
    msr     daifset, #3
    ret
.size arch_wait_for_interrupt, . - arch_wait_for_interrupt

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

// --- Extended state detection (xstate.h) --------------------------------

// uint64_t arch_arm64_id_register(uint32_t which)
.globl arch_arm64_id_register
.type arch_arm64_id_register, %function
arch_arm64_id_register:
    cmp     w0, #1
    b.eq    1f
    b.hi    2f
    mrs     x0, id_aa64pfr0_el1
    ret
1:  mrs     x0, id_aa64pfr1_el1
    ret
2:  mrs     x0, S3_0_C0_C4_5            // ID_AA64SMFR0_EL1
    ret
.size arch_arm64_id_register, . - arch_arm64_id_register

// CPACR_EL1: FPEN [21:20], ZEN [17:16], SMEN [25:24] = 0b11 (no traps).
#define CPACR_FP_SVE_SME ((3 << 20) | (3 << 16) | (3 << 24))

// uint64_t arch_sve_vector_length(uint64_t len)
.globl arch_sve_vector_length
.type arch_sve_vector_length, %function
arch_sve_vector_length:
    mrs     x2, cpacr_el1
    mov     x3, #((3 << 20) | (3 << 16))
    orr     x3, x2, x3
    msr     cpacr_el1, x3
    isb
    msr     S3_0_C1_C2_0, x0            // ZCR_EL1.LEN
    isb
    .inst   0x04bf5020                  // rdvl x0, #1
    msr     cpacr_el1, x2
    isb
    ret
.size arch_sve_vector_length, . - arch_sve_vector_length

// uint64_t arch_sme_vector_length(uint64_t len)
.globl arch_sme_vector_length
.type arch_sme_vector_length, %function
arch_sme_vector_length:
    mrs     x2, cpacr_el1
    mov     x3, #((3 << 20) | (3 << 24))
    orr     x3, x2, x3
    msr     cpacr_el1, x3
    isb
    msr     S3_0_C1_C2_6, x0            // SMCR_EL1.LEN
    isb
    .inst   0x04bf5820                  // rdsvl x0, #1
    msr     cpacr_el1, x2
    isb
    ret
.size arch_sme_vector_length, . - arch_sme_vector_length

// --- User address spaces (aspace.h) --------------------------------------

.globl arch_switch_user_tables
.type arch_switch_user_tables, %function
arch_switch_user_tables:
    orr     x0, x0, x1, lsl #48         // TTBR0_EL1.ASID (TCR_EL1.A1 = 0)
    msr     ttbr0_el1, x0
    isb
    ret
.size arch_switch_user_tables, . - arch_switch_user_tables

.globl arch_tlb_invalidate_asid
.type arch_tlb_invalidate_asid, %function
arch_tlb_invalidate_asid:
    lsl     x0, x0, #48
    dsb     ishst
    tlbi    aside1is, x0
    dsb     ish
    isb
    ret
.size arch_tlb_invalidate_asid, . - arch_tlb_invalidate_asid

.globl arch_user_access_begin
.type arch_user_access_begin, %function
arch_user_access_begin:
    adrp    x0, croi_user_protection
    ldrb    w0, [x0, :lo12:croi_user_protection]
    cbz     w0, 1f
    .inst   0xd500409f              // msr pan, #0
1:  ret
.size arch_user_access_begin, . - arch_user_access_begin

.globl arch_user_access_end
.type arch_user_access_end, %function
arch_user_access_end:
    adrp    x0, croi_user_protection
    ldrb    w0, [x0, :lo12:croi_user_protection]
    cbz     w0, 1f
    .inst   0xd500419f              // msr pan, #1
1:  ret
.size arch_user_access_end, . - arch_user_access_end

// uint64_t arch_user_protection_enable(void): with FEAT_PAN
// (ID_AA64MMFR1_EL1.PAN), PSTATE.PAN set now and on every exception entry
// (SCTLR_EL1.SPAN clear). EL0 execution by EL1 is never allowed anyway
// (user pages are PXN).
.globl arch_user_protection_enable
.type arch_user_protection_enable, %function
arch_user_protection_enable:
    mrs     x0, id_aa64mmfr1_el1
    ubfx    x0, x0, #20, #4
    cbz     x0, 1f
    mrs     x1, sctlr_el1
    bic     x1, x1, #(1 << 23)      // SPAN
    msr     sctlr_el1, x1
    isb
    .inst   0xd500419f              // msr pan, #1
    mov     x0, #1
1:  ret
.size arch_user_protection_enable, . - arch_user_protection_enable

// 8 (TCR_EL1.AS = 0, set by the loader).
.globl arch_asid_bits
.type arch_asid_bits, %function
arch_asid_bits:
    mov     x0, #8
    ret
.size arch_asid_bits, . - arch_asid_bits

// --- Cache maintenance (cache.h) -----------------------------------------

// void arch_cache_op(x0 addr, x1 size, w2 op, x3 line)
.globl arch_cache_op
.type arch_cache_op, %function
arch_cache_op:
    cbz     x3, 9f
    add     x1, x0, x1                  // end
    sub     x4, x3, #1
    bic     x0, x0, x4                  // first line
    dsb     sy
    cmp     w2, #1
    b.eq    1f
    cmp     w2, #2
    b.eq    2f
3:  dc      civac, x0
    add     x0, x0, x3
    cmp     x0, x1
    b.lo    3b
    b       8f
1:  dc      cvac, x0
    add     x0, x0, x3
    cmp     x0, x1
    b.lo    1b
    b       8f
2:  dc      ivac, x0
    add     x0, x0, x3
    cmp     x0, x1
    b.lo    2b
8:  dsb     sy
9:  ret
.size arch_cache_op, . - arch_cache_op

// void arch_device_write_barrier(void): dsb st, so stores to normal memory
// (an IOMMU's tables) are visible before a later device-register store.
.globl arch_device_write_barrier
.type arch_device_write_barrier, %function
arch_device_write_barrier:
    dsb     st
    ret
.size arch_device_write_barrier, . - arch_device_write_barrier

// uint64_t arch_cache_line(void): 4 << CTR_EL0.DminLine bytes.
.globl arch_cache_line
.type arch_cache_line, %function
arch_cache_line:
    mrs     x1, ctr_el0
    ubfx    x1, x1, #16, #4
    mov     x0, #4
    lsl     x0, x0, x1
    ret
.size arch_cache_line, . - arch_cache_line

// void arch_sync_icache(uint64_t addr, uint64_t size, uint64_t dline, uint64_t iline):
// new code at [addr, addr+size) visible to instruction fetch on every
// CPU: clean to the point of unification, invalidate the I-cache lines
// (ic ivau broadcasts in the inner shareable domain).
.globl arch_sync_icache
.type arch_sync_icache, %function
arch_sync_icache:
    add     x1, x0, x1                  // end
    mov     x5, x0
    sub     x4, x2, #1
    bic     x0, x0, x4
1:  dc      cvau, x0
    add     x0, x0, x2
    cmp     x0, x1
    b.lo    1b
    dsb     ish
    sub     x4, x3, #1
    bic     x0, x5, x4
2:  ic      ivau, x0
    add     x0, x0, x3
    cmp     x0, x1
    b.lo    2b
    dsb     ish
    isb
    ret
.size arch_sync_icache, . - arch_sync_icache

// uint64_t arch_icache_line(void): 4 << CTR_EL0.IminLine.
.globl arch_icache_line
.type arch_icache_line, %function
arch_icache_line:
    mrs     x1, ctr_el0
    and     x1, x1, #0xf
    mov     x0, #4
    lsl     x0, x0, x1
    ret
.size arch_icache_line, . - arch_icache_line

// uint64_t arch_has_poe(void): ID_AA64MMFR3_EL1.S1POE [19:16] != 0.
.globl arch_has_poe
.type arch_has_poe, %function
arch_has_poe:
    mrs     x0, S3_0_C0_C7_3            // ID_AA64MMFR3_EL1
    ubfx    x0, x0, #16, #4
    ret
.size arch_has_poe, . - arch_has_poe

// void arch_user_counter_enable(void): what EL0 may reach on this CPU, set
// to known values (review fix: CNTKCTL was ORed into, the rest left as
// firmware or reset had them). CNTKCTL_EL1 = EL0VCTEN (bit 1: CNTVCT_EL0
// and CNTFRQ_EL0, not the timers themselves); MDSCR_EL1 = TDCC (bit 12:
// no debug comms channel from EL0); PMUSERENR_EL0 = 0 (the PMU code opens
// what it needs); SCTLR_EL1.UMA (bit 9) clear (EL0 can't mask interrupts).
.globl arch_user_counter_enable
.type arch_user_counter_enable, %function
arch_user_counter_enable:
    mov     x0, #(1 << 1)
    msr     cntkctl_el1, x0
    mov     x0, #(1 << 12)
    msr     mdscr_el1, x0
    msr     pmuserenr_el0, xzr
    mrs     x0, sctlr_el1
    bic     x0, x0, #(1 << 9)
    msr     sctlr_el1, x0
    isb
    ret
.size arch_user_counter_enable, . - arch_user_counter_enable

// void arch_user_cache_enable(uint64_t zicbom): SCTLR_EL1.UCI (bit 26):
// EL0 may use dc cvau/cvac/civac and ic ivau (the vDSO's cache_flush);
// UCT (bit 15): EL0 may read CTR_EL0.
.globl arch_user_cache_enable
.type arch_user_cache_enable, %function
arch_user_cache_enable:
    mrs     x0, sctlr_el1
    orr     x0, x0, #(1 << 26)
    orr     x0, x0, #(1 << 15)
    msr     sctlr_el1, x0
    isb
    ret
.size arch_user_cache_enable, . - arch_user_cache_enable

// --- User extended state (xstate.h) ---------------------------------------
// Layout: without SVE, q0-q31 then FPSR, FPCR. With SVE (VL bytes): z0-z31
// (32 x VL), p0-p15 and FFR (17 x VL/8), then FPSR, FPCR. The Neon
// registers are the low 128 bits of the Z registers.

.arch_extension sve

// void arch_xstate_enable(void): CPACR_EL1.FPEN (and ZEN with SVE): no
// traps at EL0 or EL1. SME stays trapped (not supported yet).
.globl arch_xstate_enable
.type arch_xstate_enable, %function
arch_xstate_enable:
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)              // FPEN
    adrp    x1, croi_xstate_config
    ldr     x1, [x1, :lo12:croi_xstate_config]
    cbz     x1, 1f
    orr     x0, x0, #(3 << 16)              // ZEN
1:  msr     cpacr_el1, x0
    isb
    ret
.size arch_xstate_enable, . - arch_xstate_enable

// void arch_xstate_save(void *area)
.globl arch_xstate_save
.type arch_xstate_save, %function
arch_xstate_save:
    adrp    x1, croi_xstate_config
    ldr     x1, [x1, :lo12:croi_xstate_config]
    cbnz    x1, 2f
    stp     q0, q1, [x0, #0]
    stp     q2, q3, [x0, #32]
    stp     q4, q5, [x0, #64]
    stp     q6, q7, [x0, #96]
    stp     q8, q9, [x0, #128]
    stp     q10, q11, [x0, #160]
    stp     q12, q13, [x0, #192]
    stp     q14, q15, [x0, #224]
    stp     q16, q17, [x0, #256]
    stp     q18, q19, [x0, #288]
    stp     q20, q21, [x0, #320]
    stp     q22, q23, [x0, #352]
    stp     q24, q25, [x0, #384]
    stp     q26, q27, [x0, #416]
    stp     q28, q29, [x0, #448]
    stp     q30, q31, [x0, #480]
    add     x2, x0, #512
    b       3f
2:  .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    str     z\n, [x0, #\n, mul vl]
    .endr
    addvl   x2, x0, #16                     // the predicates, 32 VLs on
    addvl   x2, x2, #16
    .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    str     p\n, [x2, #\n, mul vl]
    .endr
    rdffr   p0.b
    str     p0, [x2, #16, mul vl]
    addpl   x2, x2, #17
3:  mrs     x3, fpsr
    mrs     x4, fpcr
    stp     x3, x4, [x2]
    ret
.size arch_xstate_save, . - arch_xstate_save

// void arch_xstate_restore(const void *area)
.globl arch_xstate_restore
.type arch_xstate_restore, %function
arch_xstate_restore:
    adrp    x1, croi_xstate_config
    ldr     x1, [x1, :lo12:croi_xstate_config]
    cbnz    x1, 2f
    ldp     q0, q1, [x0, #0]
    ldp     q2, q3, [x0, #32]
    ldp     q4, q5, [x0, #64]
    ldp     q6, q7, [x0, #96]
    ldp     q8, q9, [x0, #128]
    ldp     q10, q11, [x0, #160]
    ldp     q12, q13, [x0, #192]
    ldp     q14, q15, [x0, #224]
    ldp     q16, q17, [x0, #256]
    ldp     q18, q19, [x0, #288]
    ldp     q20, q21, [x0, #320]
    ldp     q22, q23, [x0, #352]
    ldp     q24, q25, [x0, #384]
    ldp     q26, q27, [x0, #416]
    ldp     q28, q29, [x0, #448]
    ldp     q30, q31, [x0, #480]
    add     x2, x0, #512
    b       3f
2:  .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    ldr     z\n, [x0, #\n, mul vl]
    .endr
    addvl   x2, x0, #16
    addvl   x2, x2, #16
    ldr     p0, [x2, #16, mul vl]           // FFR first, through p0
    wrffr   p0.b
    .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    ldr     p\n, [x2, #\n, mul vl]
    .endr
    addpl   x2, x2, #17
3:  ldp     x3, x4, [x2]
    msr     fpsr, x3
    msr     fpcr, x4
    ret
.size arch_xstate_restore, . - arch_xstate_restore

// --- PMUv3 (pmu.h) ---------------------------------------------------------

// uint64_t arch_pmu_sysreg_read(uint32_t which)
.globl arch_pmu_sysreg_read
.type arch_pmu_sysreg_read, %function
arch_pmu_sysreg_read:
    cmp     w0, #9
    b.hi    9f
    adr     x1, 1f
    add     x1, x1, x0, lsl #4    // 16-byte entries: bti j first (K14q)
    br      x1
1:  hint    #36                         // bti j
    mrs     x0, pmcr_el0
    ret
    nop
    hint    #36                         // bti j
    mrs     x0, pmcntenset_el0
    ret
    nop
    hint    #36                         // bti j
    mrs     x0, pmcntenclr_el0
    ret
    nop
    hint    #36                         // bti j
    mrs     x0, pmintenset_el1
    ret
    nop
    hint    #36                         // bti j
    mrs     x0, pmintenclr_el1
    ret
    nop
    hint    #36                         // bti j
    mrs     x0, pmovsclr_el0
    ret
    nop
    hint    #36                         // bti j
    mrs     x0, pmceid0_el0
    ret
    nop
    hint    #36                         // bti j
    mrs     x0, pmccfiltr_el0
    ret
    nop
    hint    #36                         // bti j
    mrs     x0, pmuserenr_el0
    ret
    nop
    hint    #36                         // bti j
    mrs     x0, id_aa64dfr0_el1
    ret
    nop
9:  mov     x0, #0
    ret
.size arch_pmu_sysreg_read, . - arch_pmu_sysreg_read

// void arch_pmu_sysreg_write(uint32_t which, uint64_t value)
.globl arch_pmu_sysreg_write
.type arch_pmu_sysreg_write, %function
arch_pmu_sysreg_write:
    cmp     w0, #8
    b.hi    9f
    adr     x2, 1f
    add     x2, x2, x0, lsl #4    // 16-byte entries: bti j first (K14q)
    br      x2
1:  hint    #36                         // bti j
    msr     pmcr_el0, x1
    b       8f
    nop
    hint    #36                         // bti j
    msr     pmcntenset_el0, x1
    b       8f
    nop
    hint    #36                         // bti j
    msr     pmcntenclr_el0, x1
    b       8f
    nop
    hint    #36                         // bti j
    msr     pmintenset_el1, x1
    b       8f
    nop
    hint    #36                         // bti j
    msr     pmintenclr_el1, x1
    b       8f
    nop
    hint    #36                         // bti j
    msr     pmovsclr_el0, x1
    b       8f
    nop
    hint    #36                         // bti j
    nop                                     // PMCEID0 is read only
    b       8f
    nop
    hint    #36                         // bti j
    msr     pmccfiltr_el0, x1
    b       8f
    nop
    hint    #36                         // bti j
    msr     pmuserenr_el0, x1
    b       8f
    nop
8:  isb
9:  ret
.size arch_pmu_sysreg_write, . - arch_pmu_sysreg_write

// uint64_t arch_pmu_counter_read(uint32_t n)
.globl arch_pmu_counter_read
.type arch_pmu_counter_read, %function
arch_pmu_counter_read:
    msr     pmselr_el0, x0
    isb
    mrs     x0, pmxevcntr_el0
    ret
.size arch_pmu_counter_read, . - arch_pmu_counter_read

// void arch_pmu_counter_write(uint32_t n, uint64_t value)
.globl arch_pmu_counter_write
.type arch_pmu_counter_write, %function
arch_pmu_counter_write:
    msr     pmselr_el0, x0
    isb
    msr     pmxevcntr_el0, x1
    isb
    ret
.size arch_pmu_counter_write, . - arch_pmu_counter_write

// void arch_pmu_event_type(uint32_t n, uint64_t type)
.globl arch_pmu_event_type
.type arch_pmu_event_type, %function
arch_pmu_event_type:
    msr     pmselr_el0, x0
    isb
    msr     pmxevtyper_el0, x1
    isb
    ret
.size arch_pmu_event_type, . - arch_pmu_event_type

// uint64_t arch_user_tls_read(void): TPIDR_EL0 (user.h)
.globl arch_user_tls_read
.type arch_user_tls_read, %function
arch_user_tls_read:
    mrs     x0, tpidr_el0
    ret
.size arch_user_tls_read, . - arch_user_tls_read

// void arch_user_tls_write(uint64_t value)
.globl arch_user_tls_write
.type arch_user_tls_write, %function
arch_user_tls_write:
    msr     tpidr_el0, x0
    ret
.size arch_user_tls_write, . - arch_user_tls_write

// int arch_hw_random(uint64_t *out): 64 bits from RNDR (FEAT_RNG), retried;
// 0 without it. Assembly: the system register and its NZCV result.
.section .text.arch_hw_random, "ax", %progbits
.globl arch_hw_random
.type arch_hw_random, %function
arch_hw_random:
    mrs     x1, id_aa64isar0_el1
    ubfx    x1, x1, #60, #4         // RNDR
    cbz     x1, 2f
    mov     x2, #16
1:  mrs     x1, s3_3_c2_c4_0        // RNDR: Z set on failure
    b.ne    3f
    subs    x2, x2, #1
    b.ne    1b
2:  mov     w0, #0
    ret
3:  str     x1, [x0]
    mov     w0, #1
    ret
.size arch_hw_random, . - arch_hw_random

// Hardware debug (K13g). The OS lock is set at reset and keeps debug
// exceptions (breakpoints, single-step) off: cleared on every CPU.
.globl arch_debug_cpu_init
.type arch_debug_cpu_init, %function
arch_debug_cpu_init:
    msr     oslar_el1, xzr
    isb
    ret
.size arch_debug_cpu_init, . - arch_debug_cpu_init

// void arch_debug_load(regs or NULL, mdscr, bps, wps): the first `bps`
// breakpoint and `wps` watchpoint pairs from a croi_thread_state_debug_
// regs_t (zero with NULL), then MDSCR_EL1 (SS bit 0, MDE bit 15).
.globl arch_debug_load
.type arch_debug_load, %function
arch_debug_load:
    mov     x9, #(1 << 12)          // off while the pairs change (TDCC kept)
    msr     mdscr_el1, x9
    isb
    cmp     x2, #0
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #0]
    ldr     x10, [x0, #8]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr0_el1, x9
    msr     dbgbvr0_el1, x10
1:
    cmp     x3, #0
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #256]
    ldr     x10, [x0, #264]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr0_el1, x9
    msr     dbgwvr0_el1, x10
1:
    cmp     x2, #1
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #16]
    ldr     x10, [x0, #24]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr1_el1, x9
    msr     dbgbvr1_el1, x10
1:
    cmp     x3, #1
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #272]
    ldr     x10, [x0, #280]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr1_el1, x9
    msr     dbgwvr1_el1, x10
1:
    cmp     x2, #2
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #32]
    ldr     x10, [x0, #40]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr2_el1, x9
    msr     dbgbvr2_el1, x10
1:
    cmp     x3, #2
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #288]
    ldr     x10, [x0, #296]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr2_el1, x9
    msr     dbgwvr2_el1, x10
1:
    cmp     x2, #3
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #48]
    ldr     x10, [x0, #56]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr3_el1, x9
    msr     dbgbvr3_el1, x10
1:
    cmp     x3, #3
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #304]
    ldr     x10, [x0, #312]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr3_el1, x9
    msr     dbgwvr3_el1, x10
1:
    cmp     x2, #4
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #64]
    ldr     x10, [x0, #72]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr4_el1, x9
    msr     dbgbvr4_el1, x10
1:
    cmp     x3, #4
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #320]
    ldr     x10, [x0, #328]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr4_el1, x9
    msr     dbgwvr4_el1, x10
1:
    cmp     x2, #5
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #80]
    ldr     x10, [x0, #88]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr5_el1, x9
    msr     dbgbvr5_el1, x10
1:
    cmp     x3, #5
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #336]
    ldr     x10, [x0, #344]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr5_el1, x9
    msr     dbgwvr5_el1, x10
1:
    cmp     x2, #6
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #96]
    ldr     x10, [x0, #104]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr6_el1, x9
    msr     dbgbvr6_el1, x10
1:
    cmp     x3, #6
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #352]
    ldr     x10, [x0, #360]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr6_el1, x9
    msr     dbgwvr6_el1, x10
1:
    cmp     x2, #7
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #112]
    ldr     x10, [x0, #120]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr7_el1, x9
    msr     dbgbvr7_el1, x10
1:
    cmp     x3, #7
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #368]
    ldr     x10, [x0, #376]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr7_el1, x9
    msr     dbgwvr7_el1, x10
1:
    cmp     x2, #8
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #128]
    ldr     x10, [x0, #136]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr8_el1, x9
    msr     dbgbvr8_el1, x10
1:
    cmp     x3, #8
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #384]
    ldr     x10, [x0, #392]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr8_el1, x9
    msr     dbgwvr8_el1, x10
1:
    cmp     x2, #9
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #144]
    ldr     x10, [x0, #152]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr9_el1, x9
    msr     dbgbvr9_el1, x10
1:
    cmp     x3, #9
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #400]
    ldr     x10, [x0, #408]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr9_el1, x9
    msr     dbgwvr9_el1, x10
1:
    cmp     x2, #10
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #160]
    ldr     x10, [x0, #168]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr10_el1, x9
    msr     dbgbvr10_el1, x10
1:
    cmp     x3, #10
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #416]
    ldr     x10, [x0, #424]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr10_el1, x9
    msr     dbgwvr10_el1, x10
1:
    cmp     x2, #11
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #176]
    ldr     x10, [x0, #184]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr11_el1, x9
    msr     dbgbvr11_el1, x10
1:
    cmp     x3, #11
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #432]
    ldr     x10, [x0, #440]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr11_el1, x9
    msr     dbgwvr11_el1, x10
1:
    cmp     x2, #12
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #192]
    ldr     x10, [x0, #200]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr12_el1, x9
    msr     dbgbvr12_el1, x10
1:
    cmp     x3, #12
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #448]
    ldr     x10, [x0, #456]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr12_el1, x9
    msr     dbgwvr12_el1, x10
1:
    cmp     x2, #13
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #208]
    ldr     x10, [x0, #216]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr13_el1, x9
    msr     dbgbvr13_el1, x10
1:
    cmp     x3, #13
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #464]
    ldr     x10, [x0, #472]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr13_el1, x9
    msr     dbgwvr13_el1, x10
1:
    cmp     x2, #14
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #224]
    ldr     x10, [x0, #232]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr14_el1, x9
    msr     dbgbvr14_el1, x10
1:
    cmp     x3, #14
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #480]
    ldr     x10, [x0, #488]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr14_el1, x9
    msr     dbgwvr14_el1, x10
1:
    cmp     x2, #15
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #240]
    ldr     x10, [x0, #248]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgbcr15_el1, x9
    msr     dbgbvr15_el1, x10
1:
    cmp     x3, #15
    b.ls    1f
    cbz     x0, 2f
    ldr     w9, [x0, #496]
    ldr     x10, [x0, #504]
    b       3f
2:  mov     x9, xzr
    mov     x10, xzr
3:  msr     dbgwcr15_el1, x9
    msr     dbgwvr15_el1, x10
1:
    orr     x1, x1, #(1 << 12)      // TDCC always
    msr     mdscr_el1, x1
    isb
    ret
.size arch_debug_load, . - arch_debug_load

.globl arch_debug_features
.type arch_debug_features, %function
arch_debug_features:
    mrs     x0, id_aa64dfr0_el1
    ret
.size arch_debug_features, . - arch_debug_features

// amd64's; nothing here.
.globl arch_debug_read
.type arch_debug_read, %function
arch_debug_read:
    mov     x0, xzr
    ret
.size arch_debug_read, . - arch_debug_read
.globl arch_debug_write
.type arch_debug_write, %function
arch_debug_write:
    ret
.size arch_debug_write, . - arch_debug_write

#include "stack.h"

// Pointer authentication (K14p): return addresses signed with the APIA key
// (the kernel is built with -mbranch-protection=pac-ret; paciasp/autiasp
// are hint-space, so NOPs where PAC isn't implemented or enabled). The key
// registers serve EL1 and EL0 alike, so the kernel's key is loaded on every
// entry from EL0 and a user key on every return: user code can't sign or
// check with the kernel's. These functions use x9-x11 only (callers in the
// entry and exit paths rely on it) and are never signed themselves.
#define APIAKEYLO_EL1 S3_0_C2_C1_0
#define APIAKEYHI_EL1 S3_0_C2_C1_1
#define ID_AA64ISAR2_EL1 S3_0_C0_C6_2

.section .text.arch_pac, "ax", %progbits

// void arch_pac_load_kernel_key(void) / arch_pac_load_user_key(void):
// nothing unless croi_pac_keys.enabled.
.globl arch_pac_load_kernel_key
.type arch_pac_load_kernel_key, %function
arch_pac_load_kernel_key:
    adrp    x9, croi_pac_keys
    add     x9, x9, :lo12:croi_pac_keys
    ldr     w10, [x9, #16]
    cbz     w10, 1f
    ldp     x10, x11, [x9, #0]
    msr     APIAKEYLO_EL1, x10
    msr     APIAKEYHI_EL1, x11
    isb
1:  ret
.size arch_pac_load_kernel_key, . - arch_pac_load_kernel_key

.globl arch_pac_load_user_key
.type arch_pac_load_user_key, %function
arch_pac_load_user_key:
    adrp    x9, croi_pac_keys
    add     x9, x9, :lo12:croi_pac_keys
    ldr     w10, [x9, #16]
    cbz     w10, 1f
    mrs     x9, tpidr_el1                       // this CPU's PerCpu: the running
    ldp     x10, x11, [x9, #CROI_PERCPU_PAC_USER] // process's key (K14s)
    msr     APIAKEYLO_EL1, x10
    msr     APIAKEYHI_EL1, x11
    isb
1:  ret
.size arch_pac_load_user_key, . - arch_pac_load_user_key

// void arch_pac_set_key(uint64_t lo, uint64_t hi)
.globl arch_pac_set_key
.type arch_pac_set_key, %function
arch_pac_set_key:
    msr     APIAKEYLO_EL1, x0
    msr     APIAKEYHI_EL1, x1
    isb
    ret
.size arch_pac_set_key, . - arch_pac_set_key

// void arch_pac_enable(void): this CPU on the kernel's key with
// SCTLR_EL1.EnIA set, if croi_pac_keys.enabled. Only from a path that never
// returns through a frame entered before it (its return address unsigned,
// it would fail authentication): arch_continue_on_stack, the AP entry.
.globl arch_pac_enable
.type arch_pac_enable, %function
arch_pac_enable:
    mov     x12, x30
    bl      arch_pac_load_kernel_key
    mov     x30, x12
    adrp    x9, croi_pac_keys
    add     x9, x9, :lo12:croi_pac_keys
    ldr     w10, [x9, #16]
    cbz     w10, 1f
    mrs     x10, sctlr_el1
    orr     x10, x10, #(1 << 31)        // EnIA
    msr     sctlr_el1, x10
    isb
1:  ret
.size arch_pac_enable, . - arch_pac_enable

// uint64_t arch_pac_supported(void): address authentication with any
// algorithm (ID_AA64ISAR1_EL1 APA or API, ID_AA64ISAR2_EL1 APA3).
.globl arch_pac_supported
.type arch_pac_supported, %function
arch_pac_supported:
    mrs     x0, id_aa64isar1_el1
    and     x0, x0, #0xff0
    mrs     x1, ID_AA64ISAR2_EL1
    ubfx    x1, x1, #12, #4
    orr     x0, x0, x1
    ret
.size arch_pac_supported, . - arch_pac_supported

// uint64_t arch_pac_sign(uint64_t pointer, uint64_t modifier): PACIA1716
// with the key loaded now (the pointer back unchanged when PAC is off).
.globl arch_pac_sign
.type arch_pac_sign, %function
arch_pac_sign:
    mov     x17, x0
    mov     x16, x1
    hint    #8                          // pacia1716
    mov     x0, x17
    ret
.size arch_pac_sign, . - arch_pac_sign

// The keys (Pac.swift fills them before arch_pac_enable runs anywhere).
.section .bss.croi_pac_keys, "aw", %nobits
.balign 16
.globl croi_pac_keys
croi_pac_keys:
    .skip   24

// uint64_t arch_pac_strip(uint64_t pointer): the pointer without its PAC
// (XPACLRI on x30; a NOP, the pointer as it was, without PAuth). For
// frame-pointer walks over signed return addresses.
.section .text.arch_pac_strip, "ax", %progbits
.globl arch_pac_strip
.type arch_pac_strip, %function
arch_pac_strip:
    mov     x9, x30
    mov     x30, x0
    hint    #7                          // xpaclri
    mov     x0, x30
    mov     x30, x9
    ret
.size arch_pac_strip, . - arch_pac_strip

// Branch target identification (K14q): the kernel's text is mapped
// guarded (GP), so an indirect branch must land on a BTI (or PACIxSP)
// instruction; the compiler puts them where its code is reached that way,
// and the jump tables above have theirs.

// uint64_t arch_bti_supported(void): ID_AA64PFR1_EL1.BT.
.section .text.arch_bti, "ax", %progbits
.globl arch_bti_supported
.type arch_bti_supported, %function
arch_bti_supported:
    mrs     x0, id_aa64pfr1_el1
    and     x0, x0, #0xf
    ret
.size arch_bti_supported, . - arch_bti_supported

// void arch_bti_enable(void): SCTLR_EL1.BT1 (PACIxSP is a landing pad for
// calls only, as BTI c).
.globl arch_bti_enable
.type arch_bti_enable, %function
arch_bti_enable:
    mrs     x9, sctlr_el1
    orr     x9, x9, #(1 << 36)
    msr     sctlr_el1, x9
    isb
    ret
.size arch_bti_enable, . - arch_bti_enable

// uint64_t arch_bti_probe(void): branches (br) to an instruction that is
// no landing pad. Guarded, that is a branch target exception, which
// arch_exception sends on to the recovery point (1); unguarded it runs (0).
.globl arch_bti_probe
.type arch_bti_probe, %function
arch_bti_probe:
    adr     x9, croi_bti_probe_target
    br      x9
croi_bti_probe_target:
    mov     x0, #0
    ret
croi_bti_probe_recovery:
    mov     x0, #1
    ret
.size arch_bti_probe, . - arch_bti_probe

// uint64_t arch_bti_probe_target(void) / arch_bti_probe_recovery(void)
.globl arch_bti_probe_target
.type arch_bti_probe_target, %function
arch_bti_probe_target:
    adr     x0, croi_bti_probe_target
    ret
.size arch_bti_probe_target, . - arch_bti_probe_target

.globl arch_bti_probe_recovery
.type arch_bti_probe_recovery, %function
arch_bti_probe_recovery:
    adr     x0, croi_bti_probe_recovery
    ret
.size arch_bti_probe_recovery, . - arch_bti_probe_recovery
