// rv64 secondary CPU startup. Assembly because the hart starts with the
// MMU off at a physical address (SBI HSM hart_start).
//
// Entry: a0 = hart ID, a1 = croi_ap_startup_t (physical), satp = 0, S-mode.
// Writing satp makes the next fetch (at a physical address the kernel page
// tables don't map) fault; stvec points at the continuation's virtual
// address, so the fault lands there with the kernel address space live.

#include "smp.h"

#define SATP_MODE_SV39 (8 << 60)

.section .text.arch_ap_entry, "ax", %progbits
.balign 4
.globl arch_ap_entry
.type arch_ap_entry, %function
arch_ap_entry:
    csrw    sie, zero
    csrci   sstatus, 0x2
    ld      t0, CROI_AP_ROOT(a1)
    ld      sp, CROI_AP_STACK(a1)
    ld      tp, CROI_AP_PERCPU(a1)
    ld      t2, CROI_AP_DELTA(a1)
    lla     t1, 1f
    add     t1, t1, t2
    csrw    stvec, t1
    sfence.vma
    csrw    satp, t0
    nop                             // faults: we are still at a physical address
.balign 4
1:  mv      s0, zero
    mv      ra, zero
    mv      a0, tp
    call    kernel_ap_main
    unimp
.size arch_ap_entry, . - arch_ap_entry

// void arch_ap_capture_mmu(croi_ap_startup_t *block)
.section .text.arch_ap_capture_mmu, "ax", %progbits
.globl arch_ap_capture_mmu
.type arch_ap_capture_mmu, %function
arch_ap_capture_mmu:
    csrr    t0, satp
    sd      t0, CROI_AP_ROOT(a0)
    ret
.size arch_ap_capture_mmu, . - arch_ap_capture_mmu

// long arch_sbi_call(eid, fid, arg0, arg1, arg2): SBI error code.
.globl arch_sbi_call
.type arch_sbi_call, %function
arch_sbi_call:
    mv      a7, a0
    mv      a6, a1
    mv      a0, a2
    mv      a1, a3
    mv      a2, a4
    ecall
    ret
.size arch_sbi_call, . - arch_sbi_call
