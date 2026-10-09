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
    msr     hcr_el2, x9
    mov     x9, #3                  // CNTHCTL_EL2: EL1PCTEN | EL1PCEN
    msr     cnthctl_el2, x9
    msr     cntvoff_el2, xzr
    mov     x9, #0x33ff             // CPTR_EL2: RES1 only
    msr     cptr_el2, x9
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
