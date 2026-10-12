// arm64 secondary CPU startup. Assembly because the CPU starts with the MMU
// off at a physical address (PSCI CPU_ON), possibly at EL2.
//
// Entry: x0 = croi_ap_startup_t (physical). If at EL2, drop to EL1 exactly
// as the loader does. Then install the kernel's MAIR/TCR/TTBRs (captured
// from the boot CPU) and turn the MMU on: the next fetch, still at a
// physical address, faults (TTBR0 maps nothing), and VBAR_EL1 points at
// ap_vectors' virtual address, whose current-EL synchronous slot jumps to
// the continuation with the kernel address space live.

#include "smp.h"

#define SCTLR_EL1_MMU_OFF 0x30d00800
#define HCR_EL2_RW        (1 << 31)
#define SPSR_EL1H_MASKED  0x3c5

.section .text.arch_ap_entry, "ax", %progbits
.balign 2048
ap_vectors:
    b       ap_continue             // current EL with SP_EL0, synchronous
    .balign 0x200
    b       ap_continue             // current EL with SP_ELx, synchronous
    .balign 2048

.globl arch_ap_entry
.type arch_ap_entry, %function
arch_ap_entry:
    msr     daifset, #0xf
    mov     x19, x0

    mrs     x9, CurrentEL
    lsr     x9, x9, #2
    cmp     x9, #2
    b.ne    1f
    // EL2: keep out of the way and drop to EL1 (see boot/arch/arm64/enter.S).
    mov     x9, #HCR_EL2_RW
    movk    x9, #0x300, lsl #32     // API | APK: EL1's pointer authentication untrapped (K14p)
    msr     hcr_el2, x9
    mov     x9, #3                  // CNTHCTL_EL2: EL1PCTEN | EL1PCEN
    msr     cnthctl_el2, x9
    msr     cntvoff_el2, xzr
    // CPTR_EL2 (E2H = 0): trap none of FP/SIMD, SVE or SME. TZ (bit 8) and
    // TSM (bit 12) trap SVE/SME where those exist and are RES1 where not.
    mov     x9, #0x22ff
    mrs     x10, id_aa64pfr0_el1
    ubfx    x10, x10, #32, #4       // SVE
    cbnz    x10, .Lap_el2_has_sve
    orr     x9, x9, #(1 << 8)
.Lap_el2_has_sve:
    mrs     x10, id_aa64pfr1_el1
    ubfx    x10, x10, #24, #4       // SME
    cbnz    x10, .Lap_el2_has_sme
    orr     x9, x9, #(1 << 12)
.Lap_el2_has_sme:
    msr     cptr_el2, x9
    isb
    // EL2's vector-length limits: the hardware maximum (LEN = 15), so EL1
    // chooses (ZCR_EL2 and SMCR_EL2 reset to UNKNOWN values).
    mrs     x10, id_aa64pfr0_el1
    ubfx    x10, x10, #32, #4
    cbz     x10, .Lap_el2_no_sve
    mov     x9, #0xf
    msr     S3_4_C1_C2_0, x9        // ZCR_EL2
.Lap_el2_no_sve:
    mrs     x10, id_aa64pfr1_el1
    ubfx    x10, x10, #24, #4
    cbz     x10, .Lap_el2_no_sme
    mov     x9, #0xf
    mrs     x10, S3_0_C0_C4_5       // ID_AA64SMFR0_EL1
    tbz     x10, #63, .Lap_el2_no_fa64
    orr     x9, x9, #(1 << 31)      // FA64: the full ISA in streaming mode
.Lap_el2_no_fa64:
    ubfx    x10, x10, #56, #4       // SMEver: SME2 has ZT0
    cbz     x10, .Lap_el2_no_zt0
    orr     x9, x9, #(1 << 30)      // EZT0: don't trap ZT0
.Lap_el2_no_zt0:
    msr     S3_4_C1_C2_6, x9        // SMCR_EL2
.Lap_el2_no_sme:
    // MDCR_EL2 as the loader sets it (review fix: left UNKNOWN here, so
    // TDE/TDA/TPM could trap debug and PMU use to an EL2 with no vectors):
    // every PMU counter to EL1 (HPMN = PMCR_EL0.N), no traps.
    mov     x10, xzr
    mrs     x9, id_aa64dfr0_el1
    ubfx    x9, x9, #8, #4          // PMUVer
    cbz     x9, .Lap_el2_mdcr
    cmp     x9, #0xf                // IMPLEMENTATION DEFINED PMU
    b.eq    .Lap_el2_mdcr
    mrs     x10, pmcr_el0
    ubfx    x10, x10, #11, #5       // N
.Lap_el2_mdcr:                      // (named: a "1f" above skips the drop)
    msr     mdcr_el2, x10
    msr     hstr_el2, xzr
    msr     vttbr_el2, xzr
    mrs     x9, midr_el1
    msr     vpidr_el2, x9
    mrs     x9, mpidr_el1
    msr     vmpidr_el2, x9
    mrs     x9, id_aa64pfr0_el1
    ubfx    x9, x9, #24, #4         // GICv3 system registers?
    cbz     x9, 2f
    mrs     x9, ICC_SRE_EL2
    orr     x9, x9, #0x1            // SRE
    orr     x9, x9, #0x8            // Enable
    msr     ICC_SRE_EL2, x9
    isb
    msr     ICH_HCR_EL2, xzr
2:  ldr     x9, =SCTLR_EL1_MMU_OFF
    msr     sctlr_el1, x9
    mov     x9, #SPSR_EL1H_MASKED
    msr     spsr_el2, x9
    adr     x9, 1f
    msr     elr_el2, x9
    isb
    eret

1:  ldr     x1, [x19, #CROI_AP_MAIR]
    msr     mair_el1, x1
    ldr     x1, [x19, #CROI_AP_TCR]
    msr     tcr_el1, x1
    ldr     x1, [x19, #CROI_AP_ROOT_LO]
    msr     ttbr0_el1, x1
    ldr     x1, [x19, #CROI_AP_ROOT]
    msr     ttbr1_el1, x1
    ldr     x20, [x19, #CROI_AP_STACK]
    ldr     x21, [x19, #CROI_AP_PERCPU]
    ldr     x22, [x19, #CROI_AP_DELTA]
    adr     x1, ap_vectors
    add     x1, x1, x22
    msr     vbar_el1, x1
    isb
    tlbi    vmalle1
    dsb     nsh
    isb
    ldr     x1, [x19, #CROI_AP_SCTLR]
    msr     sctlr_el1, x1           // MMU on; the next fetch faults into ap_vectors
    isb
    b       .

ap_continue:
    msr     spsel, #1               // the kernel runs on SP_EL1
    mov     sp, x20
    msr     tpidr_el1, x21
    ic      iallu
    dsb     nsh
    isb
    mov     x29, xzr
    mov     x30, xzr
    bl      arch_pac_enable         // K14p: the boot CPU's keys; never returns past here
    mov     x0, x21
    bl      kernel_ap_main
    udf     #0
.size arch_ap_entry, . - arch_ap_entry
.ltorg

// void arch_ap_capture_mmu(croi_ap_startup_t *block)
.section .text.arch_ap_capture_mmu, "ax", %progbits
.globl arch_ap_capture_mmu
.type arch_ap_capture_mmu, %function
arch_ap_capture_mmu:
    mrs     x1, ttbr1_el1
    str     x1, [x0, #CROI_AP_ROOT]
    mrs     x1, ttbr0_el1
    str     x1, [x0, #CROI_AP_ROOT_LO]
    mrs     x1, mair_el1
    str     x1, [x0, #CROI_AP_MAIR]
    mrs     x1, tcr_el1
    str     x1, [x0, #CROI_AP_TCR]
    mrs     x1, sctlr_el1
    str     x1, [x0, #CROI_AP_SCTLR]
    ret
.size arch_ap_capture_mmu, . - arch_ap_capture_mmu

// uint64_t arch_psci_call(fid, a1, a2, a3, use_hvc): PSCI return value.
.globl arch_psci_call
.type arch_psci_call, %function
arch_psci_call:
    cbnz    x4, 1f
    smc     #0
    ret
1:  hvc     #0
    ret
.size arch_psci_call, . - arch_psci_call

// void arch_smccc_call(params, result, use_hvc) (K13i, smc_call): w0 the
// function ID, x1-x6 the arguments, w7 secure_os_id << 16 | client_id;
// the result x0-x3 and x6. SMCCC may clobber x0-x17 (caller-saved).
.globl arch_smccc_call
.type arch_smccc_call, %function
arch_smccc_call:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x1
    mov     x20, x2
    mov     x9, x0
    ldr     w0, [x9, #0]
    ldr     x1, [x9, #8]
    ldr     x2, [x9, #16]
    ldr     x3, [x9, #24]
    ldr     x4, [x9, #32]
    ldr     x5, [x9, #40]
    ldr     x6, [x9, #48]
    ldrh    w10, [x9, #56]
    ldrh    w11, [x9, #58]
    orr     w7, w10, w11, lsl #16
    cbnz    x20, 1f
    smc     #0
    b       2f
1:  hvc     #0
2:  stp     x0, x1, [x19]
    stp     x2, x3, [x19, #16]
    str     x6, [x19, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
.size arch_smccc_call, . - arch_smccc_call
