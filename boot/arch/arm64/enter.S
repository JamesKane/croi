// arm64 handoff to the kernel. Assembly because it reprograms the EL1
// translation regime and jumps into it; see loader.h for the contract.
//
// UEFI leaves the MMU on with its own MAIR/TCR. Changing those under a live
// MMU is unpredictable, so the MMU is turned off (we are identity mapped, so
// execution continues), the new regime installed, then the MMU re-enabled.
// The caller has cleaned everything the kernel will touch to PoC.

// MAIR: attr0 = Normal WB RA/WA, attr1 = Device-nGnRE.
#define MAIR_VALUE 0x04ff

// TCR: 48-bit VAs in both halves (T0SZ = T1SZ = 16), 4 KiB granules
// (TG0 = 0b00, TG1 = 0b10), walks inner/outer WB-WA and inner shareable.
// IPS is filled in from ID_AA64MMFR0_EL1.PARange.
#define TCR_VALUE 0xb5103510

#define SCTLR_M   (1 << 0)
#define SCTLR_C   (1 << 2)
#define SCTLR_I   (1 << 12)
#define SCTLR_WXN (1 << 19)

.section .text.croi_arch, "ax", %progbits

// void croi_arch_enter_kernel(root=x0, root_high=x1, entry=x2, handoff=x3)
.globl croi_arch_enter_kernel
.type croi_arch_enter_kernel, %function
croi_arch_enter_kernel:
    msr     daifset, #0xf

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

    mov     x10, #MAIR_VALUE
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

// 2 if the firmware entered us at EL2 (dropping to EL1 is not done yet).
.globl croi_arch_unsupported
.type croi_arch_unsupported, %function
croi_arch_unsupported:
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #1
    csel    x0, xzr, x0, eq
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
