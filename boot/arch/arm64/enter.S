// arm64 handoff to the kernel. Assembly because it changes exception level
// and translation regime; see loader.h for the contract.
//
// The kernel runs at EL1. Firmware may run (and so start us) at EL2; croi
// has no hypervisor, so from EL2 we configure EL2 to stay out of the way
// and drop to EL1. That can only happen after ExitBootServices, since boot
// services must be called at the firmware's own exception level.
//
// UEFI leaves the MMU on with its own MAIR/TCR. Changing those under a live
// MMU is unpredictable, so the MMU is turned off (we are identity mapped, so
// execution continues), the new regime installed, then the MMU re-enabled.
// The caller has cleaned everything the kernel will touch to PoC.

// MAIR: attr0 = Normal WB RA/WA, attr1 = Device-nGnRE, attr2 = Normal
// non-cacheable, attr3 = Device-nGnRnE (see PageTableFormat).
#define MAIR_VALUE 0x004404ff

// TCR: 48-bit VAs in both halves (T0SZ = T1SZ = 16), 4 KiB granules
// (TG0 = 0b00, TG1 = 0b10), walks inner/outer WB-WA and inner shareable.
// IPS is filled in from ID_AA64MMFR0_EL1.PARange.
#define TCR_VALUE 0xb5103510

#define SCTLR_M   (1 << 0)
#define SCTLR_C   (1 << 2)
#define SCTLR_I   (1 << 12)
#define SCTLR_WXN (1 << 19)

// SCTLR_EL1 RES1 bits (ARMv8.0) with everything else off, MMU included.
#define SCTLR_EL1_MMU_OFF 0x30d00800

// HCR_EL2: EL1 is AArch64 (RW). Everything else clear: no stage 2, no
// traps, interrupts routed to EL1, E2H/TGE off.
#define HCR_EL2_RW (1 << 31)

// CNTHCTL_EL2 (E2H = 0 layout): EL1 may use the physical counter and timer.
#define CNTHCTL_EL1PCTEN (1 << 0)
#define CNTHCTL_EL1PCEN  (1 << 1)

// ICC_SRE_EL2: GICv3 system registers enabled, and usable from EL1.
#define ICC_SRE_EL2_SRE    (1 << 0)
#define ICC_SRE_EL2_ENABLE (1 << 3)

// SPSR for the drop: EL1h (SP_EL1) with D, A, I and F masked.
#define SPSR_EL1H_MASKED 0x3c5

.section .text.croi_arch, "ax", %progbits

// void croi_arch_enter_kernel(root=x0, root_high=x1, entry=x2, handoff=x3)
.globl croi_arch_enter_kernel
.type croi_arch_enter_kernel, %function
croi_arch_enter_kernel:
    msr     daifset, #0xf

    mrs     x9, CurrentEL
    lsr     x9, x9, #2
    cmp     x9, #2
    b.ne    .Lat_el1

    // --- EL2: get out of the way and drop to EL1. ---

    // EL2 MMU off first: rewriting HCR_EL2.E2H under a live EL2&0 regime
    // is unsafe, and with E2H set the *_EL1 names below would hit EL2.
    mrs     x9, sctlr_el2
    bic     x9, x9, #SCTLR_M
    bic     x9, x9, #SCTLR_C
    bic     x9, x9, #SCTLR_I
    bic     x9, x9, #SCTLR_WXN
    msr     sctlr_el2, x9
    isb

    mov     x9, #HCR_EL2_RW
    msr     hcr_el2, x9
    isb

    mov     x9, #(CNTHCTL_EL1PCTEN | CNTHCTL_EL1PCEN)
    msr     cnthctl_el2, x9
    msr     cntvoff_el2, xzr
    // CPTR_EL2 (E2H = 0): trap none of FP/SIMD, SVE or SME. TZ (bit 8) and
    // TSM (bit 12) trap SVE/SME where those exist and are RES1 where not.
    mov     x9, #0x22ff
    mrs     x10, id_aa64pfr0_el1
    ubfx    x10, x10, #32, #4       // SVE
    cbnz    x10, .Lel2_has_sve
    orr     x9, x9, #(1 << 8)
.Lel2_has_sve:
    mrs     x10, id_aa64pfr1_el1
    ubfx    x10, x10, #24, #4       // SME
    cbnz    x10, .Lel2_has_sme
    orr     x9, x9, #(1 << 12)
.Lel2_has_sme:
    msr     cptr_el2, x9
    isb
    // EL2's vector-length limits: the hardware maximum (LEN = 15), so EL1
    // chooses (ZCR_EL2 and SMCR_EL2 reset to UNKNOWN values).
    mrs     x10, id_aa64pfr0_el1
    ubfx    x10, x10, #32, #4
    cbz     x10, .Lel2_no_sve
    mov     x9, #0xf
    msr     S3_4_C1_C2_0, x9        // ZCR_EL2
.Lel2_no_sve:
    mrs     x10, id_aa64pfr1_el1
    ubfx    x10, x10, #24, #4
    cbz     x10, .Lel2_no_sme
    mov     x9, #0xf
    mrs     x10, S3_0_C0_C4_5       // ID_AA64SMFR0_EL1
    tbz     x10, #63, .Lel2_no_fa64
    orr     x9, x9, #(1 << 31)      // FA64: the full ISA in streaming mode
.Lel2_no_fa64:
    ubfx    x10, x10, #56, #4       // SMEver: SME2 has ZT0
    cbz     x10, .Lel2_no_zt0
    orr     x9, x9, #(1 << 30)      // EZT0: don't trap ZT0
.Lel2_no_zt0:
    msr     S3_4_C1_C2_6, x9        // SMCR_EL2
.Lel2_no_sme:
    msr     hstr_el2, xzr
    msr     vttbr_el2, xzr

    // EL1 reads of MIDR/MPIDR return these; give it the real values.
    mrs     x9, midr_el1
    msr     vpidr_el2, x9
    mrs     x9, mpidr_el1
    msr     vmpidr_el2, x9

    // Let EL1 use every PMU counter (HPMN = PMCR_EL0.N), if there is a PMU.
    mov     x10, xzr
    mrs     x9, id_aa64dfr0_el1
    ubfx    x9, x9, #8, #4          // PMUVer
    cbz     x9, 1f
    cmp     x9, #0xf                // IMPLEMENTATION DEFINED PMU
    b.eq    1f
    mrs     x10, pmcr_el0
    ubfx    x10, x10, #11, #5       // N
1:  msr     mdcr_el2, x10

    // GICv3 CPU interface: enable system register access from EL1.
    mrs     x9, id_aa64pfr0_el1
    ubfx    x9, x9, #24, #4         // GIC
    cbz     x9, 2f
    mrs     x9, ICC_SRE_EL2
    orr     x9, x9, #ICC_SRE_EL2_SRE
    orr     x9, x9, #ICC_SRE_EL2_ENABLE
    msr     ICC_SRE_EL2, x9
    isb
    msr     ICH_HCR_EL2, xzr
2:
    ldr     x9, =SCTLR_EL1_MMU_OFF
    msr     sctlr_el1, x9
    mov     x9, #SPSR_EL1H_MASKED
    msr     spsr_el2, x9
    adr     x9, .Lat_el1
    msr     elr_el2, x9
    isb
    eret

.Lat_el1:
    // MMU and caches off. WXN must stay clear: the identity map is RWX.
    mrs     x9, sctlr_el1
    bic     x9, x9, #SCTLR_M
    bic     x9, x9, #SCTLR_C
    bic     x9, x9, #SCTLR_I
    bic     x9, x9, #SCTLR_WXN
    msr     sctlr_el1, x9
    isb
    tlbi    vmalle1
    dsb     nsh
    isb

    ldr     x10, =MAIR_VALUE
    msr     mair_el1, x10
    ldr     x10, =TCR_VALUE
    mrs     x11, id_aa64mmfr0_el1
    and     x11, x11, #0x7
    bfi     x10, x11, #32, #3
    msr     tcr_el1, x10
    msr     ttbr0_el1, x0
    msr     ttbr1_el1, x1
    isb

    orr     x9, x9, #SCTLR_M
    orr     x9, x9, #SCTLR_C
    orr     x9, x9, #SCTLR_I
    msr     sctlr_el1, x9
    isb
    ic      iallu
    dsb     nsh
    isb

    mov     x0, x3
    br      x2
.size croi_arch_enter_kernel, . - croi_arch_enter_kernel

// The current EL if it is not EL1 or EL2 (EL1 is used directly, EL2 is
// dropped from in croi_arch_enter_kernel), else 0.
.globl croi_arch_unsupported
.type croi_arch_unsupported, %function
croi_arch_unsupported:
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    sub     x1, x0, #1
    cmp     x1, #1
    csel    x0, xzr, x0, ls         // EL1 or EL2 -> 0
    ret
.size croi_arch_unsupported, . - croi_arch_unsupported

// void croi_arch_clean_dcache(addr=x0, size=x1)
.globl croi_arch_clean_dcache
.type croi_arch_clean_dcache, %function
croi_arch_clean_dcache:
    mrs     x3, ctr_el0
    ubfx    x3, x3, #16, #4         // DminLine: log2(words per line)
    mov     x2, #4
    lsl     x2, x2, x3              // line size in bytes
    add     x1, x0, x1
    sub     x3, x2, #1
    bic     x0, x0, x3
1:  dc      civac, x0
    add     x0, x0, x2
    cmp     x0, x1
    b.lo    1b
    dsb     sy
    ret
.size croi_arch_clean_dcache, . - croi_arch_clean_dcache

.ltorg
