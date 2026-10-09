// amd64 context switch. Assembly because it swaps stacks mid-function.
// The frame (low to high): r15 r14 r13 r12 rbx rbp, return address.

.section .text.arch_context_switch, "ax", @progbits

// void arch_context_switch(uint64_t *old_sp, uint64_t new_sp)
.globl arch_context_switch
.type arch_context_switch, @function
arch_context_switch:
    push    %rbp
    push    %rbx
    push    %r12
    push    %r13
    push    %r14
    push    %r15
    mov     %rsp, (%rdi)
    mov     %rsi, %rsp
    pop     %r15
    pop     %r14
    pop     %r13
    pop     %r12
    pop     %rbx
    pop     %rbp
    ret
.size arch_context_switch, . - arch_context_switch

// uint64_t arch_thread_prepare(uint64_t stack_top, uint64_t thread)
// The return address lands at top - 16, so the trampoline starts with
// rsp = top - 8, as if it had been called (16-byte ABI alignment).
.globl arch_thread_prepare
.type arch_thread_prepare, @function
arch_thread_prepare:
    lea     -64(%rdi), %rax
    movq    $0, 0(%rax)             // r15
    movq    $0, 8(%rax)             // r14
    movq    $0, 16(%rax)            // r13
    movq    $0, 24(%rax)            // r12
    mov     %rsi, 32(%rax)          // rbx: the thread
    movq    $0, 40(%rax)            // rbp
    lea     arch_thread_trampoline(%rip), %rcx
    mov     %rcx, 48(%rax)          // return address
    movq    $0, 56(%rax)
    ret
.size arch_thread_prepare, . - arch_thread_prepare

arch_thread_trampoline:
    mov     %rbx, %rdi
    xor     %ebp, %ebp
    call    kernel_thread_main
    ud2
