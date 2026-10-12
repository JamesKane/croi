// rv64 handoff to the kernel. Assembly because it writes satp and jumps
// into the new address space; see loader.h for the contract.

#define SATP_MODE_SV39 (8 << 60)

.section .text.croi_arch, "ax", %progbits

// void croi_arch_enter_kernel(root=a0, root_high=a1, entry=a2, handoff=a3)
.globl croi_arch_enter_kernel
.type croi_arch_enter_kernel, %function
croi_arch_enter_kernel:
    csrci   sstatus, 0x2            // clear SIE
    srli    t0, a0, 12
    li      t1, SATP_MODE_SV39
    or      t0, t0, t1
    sfence.vma
    csrw    satp, t0
    sfence.vma
    fence.i                         // kernel text was written as data
    mv      a0, a3
    jr      a2
.size croi_arch_enter_kernel, . - croi_arch_enter_kernel

.globl croi_arch_unsupported
.type croi_arch_unsupported, %function
croi_arch_unsupported:
    li      a0, 0
    ret
.size croi_arch_unsupported, . - croi_arch_unsupported

// No random number instruction S-mode can count on (Zkr's seed CSR traps
// unless M-mode opened it): 0 with *strong = 0.
.globl croi_arch_entropy
.type croi_arch_entropy, %function
croi_arch_entropy:
    sd      zero, 0(a0)
    li      a0, 0
    ret
.size croi_arch_entropy, . - croi_arch_entropy

.globl croi_arch_counter
.type croi_arch_counter, %function
croi_arch_counter:
    rdtime  a0
    ret
.size croi_arch_counter, . - croi_arch_counter

// Data caches are coherent with page walks; fence.i covers instructions.
.globl croi_arch_clean_dcache
.type croi_arch_clean_dcache, %function
croi_arch_clean_dcache:
    ret
.size croi_arch_clean_dcache, . - croi_arch_clean_dcache
