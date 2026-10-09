// rv64 context switch. Assembly because it swaps stacks mid-function.
// The frame (112 bytes, low to high): ra, s0..s11. tp is per CPU, not per
// thread, and is left alone.

.section .text.arch_context_switch, "ax", %progbits

// void arch_context_switch(uint64_t *old_sp, uint64_t new_sp)
.globl arch_context_switch
.type arch_context_switch, %function
arch_context_switch:
    addi    sp, sp, -112
    sd      ra, 0(sp)
    sd      s0, 8(sp)
    sd      s1, 16(sp)
    sd      s2, 24(sp)
    sd      s3, 32(sp)
    sd      s4, 40(sp)
    sd      s5, 48(sp)
    sd      s6, 56(sp)
    sd      s7, 64(sp)
    sd      s8, 72(sp)
    sd      s9, 80(sp)
    sd      s10, 88(sp)
    sd      s11, 96(sp)
    sd      sp, 0(a0)
    mv      sp, a1
    ld      ra, 0(sp)
    ld      s0, 8(sp)
    ld      s1, 16(sp)
    ld      s2, 24(sp)
    ld      s3, 32(sp)
    ld      s4, 40(sp)
    ld      s5, 48(sp)
    ld      s6, 56(sp)
    ld      s7, 64(sp)
    ld      s8, 72(sp)
    ld      s9, 80(sp)
    ld      s10, 88(sp)
    ld      s11, 96(sp)
    addi    sp, sp, 112
    ret
.size arch_context_switch, . - arch_context_switch

// uint64_t arch_thread_prepare(uint64_t stack_top, uint64_t thread)
.globl arch_thread_prepare
.type arch_thread_prepare, %function
arch_thread_prepare:
    addi    a0, a0, -112
    lla     t0, arch_thread_trampoline
    sd      t0, 0(a0)               // ra
    sd      zero, 8(a0)             // s0
    sd      a1, 16(a0)              // s1: the thread
    sd      zero, 24(a0)
    sd      zero, 32(a0)
    sd      zero, 40(a0)
    sd      zero, 48(a0)
    sd      zero, 56(a0)
    sd      zero, 64(a0)
    sd      zero, 72(a0)
    sd      zero, 80(a0)
    sd      zero, 88(a0)
    sd      zero, 96(a0)
    ret
.size arch_thread_prepare, . - arch_thread_prepare

arch_thread_trampoline:
    mv      a0, s1
    call    kernel_thread_main
    unimp
