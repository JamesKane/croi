// arm64 context switch. Assembly because it swaps stacks mid-function.
// The frame (96 bytes, low to high): x19..x28, x29 (fp), x30 (lr).

.section .text.arch_context_switch, "ax", %progbits

// void arch_context_switch(uint64_t *old_sp, uint64_t new_sp)
.globl arch_context_switch
.type arch_context_switch, %function
arch_context_switch:
    sub     sp, sp, #96
    stp     x19, x20, [sp, #0]
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    stp     x25, x26, [sp, #48]
    stp     x27, x28, [sp, #64]
    stp     x29, x30, [sp, #80]
    mov     x2, sp
    str     x2, [x0]
    mov     sp, x1
    ldp     x19, x20, [sp, #0]
    ldp     x21, x22, [sp, #16]
    ldp     x23, x24, [sp, #32]
    ldp     x25, x26, [sp, #48]
    ldp     x27, x28, [sp, #64]
    ldp     x29, x30, [sp, #80]
    add     sp, sp, #96
    ret
.size arch_context_switch, . - arch_context_switch

// uint64_t arch_thread_prepare(uint64_t stack_top, uint64_t thread)
.globl arch_thread_prepare
.type arch_thread_prepare, %function
arch_thread_prepare:
    sub     x0, x0, #96
    stp     x1, xzr, [x0, #0]       // x19: the thread
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #32]
    stp     xzr, xzr, [x0, #48]
    stp     xzr, xzr, [x0, #64]
    adr     x2, arch_thread_trampoline
    stp     xzr, x2, [x0, #80]      // fp = 0, lr = trampoline
    ret
.size arch_thread_prepare, . - arch_thread_prepare

arch_thread_trampoline:
    mov     x0, x19
    bl      kernel_thread_main
    udf     #0
