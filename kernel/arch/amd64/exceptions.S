// amd64 exception entry. Assembly because it is the CPU's interrupt
// interface: IDT/TSS formats, per-vector stubs, iretq, SYSCALL/SYSRET.
//
// Every vector has a 16-byte stub that pushes a zero error code if the CPU
// didn't, then the vector number, and joins isr_common, which completes an
// arch_exception_frame_t (see kernel.h) and calls arch_exception.
//
// From user mode (the saved CS has RPL 3) the CPU has already switched to
// the TSS's RSP0 (the thread's kernel stack top) and the entry swaps GS to
// the kernel's (swapgs); returning there swaps it back. While in the
// kernel GS_BASE is the PerCpu record and KERNEL_GS_BASE the user's; in
// user mode the other way round.

#include "stack.h"

#define KERNEL_CS   0x08
#define USER_DS     0x23
#define USER_CS64   0x2b
#define SYSCALL_VECTOR 0x100
#define TSS_SEL     0x30
#define IST_STACK_SIZE 16384

.section .text.isr, "ax", @progbits

.balign 16
isr_stubs:
.set vector, 0
.rept 256
    .balign 16
    // Vectors 8, 10-14, 17, 21, 29 and 30 push an error code.
    .if !((vector == 8) || ((vector >= 10) && (vector <= 14)) || (vector == 17) || (vector == 21) || (vector == 29) || (vector == 30))
    pushq   $0
    .endif
    pushq   $vector
    jmp     isr_common
    .set vector, vector + 1
.endr

isr_common:
    testb   $3, 24(%rsp)            // the interrupted CS: from user mode?
    jz      1f
    swapgs
1:  pushq   %rax
    pushq   %rbx
    pushq   %rcx
    pushq   %rdx
    pushq   %rsi
    pushq   %rdi
    pushq   %rbp
    pushq   %r8
    pushq   %r9
    pushq   %r10
    pushq   %r11
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15
    // The CPU aligned rsp to 16 before its 5 pushes; with ours that makes 22
    // quadwords, so rsp is 16-byte aligned for the call.
    mov     %rsp, %rdi
    cld
    call    arch_exception
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %r11
    popq    %r10
    popq    %r9
    popq    %r8
    popq    %rbp
    popq    %rdi
    popq    %rsi
    popq    %rdx
    popq    %rcx
    popq    %rbx
    popq    %rax
    add     $16, %rsp               // vector, error code
    testb   $3, 8(%rsp)             // back to user mode?
    jz      2f
    swapgs
2:  iretq

// SYSCALL from user mode: rcx = return rip, r11 = rflags, rax = number,
// arguments in rdi, rsi, rdx, r10, r8, r9. Interrupts are masked (FMASK).
// Builds the same frame as an interrupt (vector SYSCALL_VECTOR) on the
// thread's kernel stack, calls arch_syscall, and returns with sysretq. The
// rip it returns to is the one SYSCALL saved, so it is canonical (Swift
// must keep it so if it ever changes it).
.section .text.syscall_entry, "ax", @progbits
.globl syscall_entry
.type syscall_entry, @function
syscall_entry:
    swapgs
    mov     %rsp, %gs:CROI_PERCPU_USER_SP
    mov     %gs:CROI_PERCPU_KERNEL_SP, %rsp
    pushq   $USER_DS                // ss
    pushq   %gs:CROI_PERCPU_USER_SP // rsp
    pushq   %r11                    // rflags
    pushq   $USER_CS64              // cs
    pushq   %rcx                    // rip
    pushq   $0                      // error code
    pushq   $SYSCALL_VECTOR
    pushq   %rax
    pushq   %rbx
    pushq   %rcx
    pushq   %rdx
    pushq   %rsi
    pushq   %rdi
    pushq   %rbp
    pushq   %r8
    pushq   %r9
    pushq   %r10
    pushq   %r11
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15
    mov     %rsp, %rdi
    cld
    call    arch_syscall
    cli
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %r11
    popq    %r10
    popq    %r9
    popq    %r8
    popq    %rbp
    popq    %rdi
    popq    %rsi
    popq    %rdx
    popq    %rcx
    popq    %rbx
    popq    %rax
    add     $16, %rsp               // vector, error code
    mov     0(%rsp), %rcx           // rip
    mov     16(%rsp), %r11          // rflags
    mov     24(%rsp), %rsp          // the user stack
    swapgs
    sysretq
.size syscall_entry, . - syscall_entry

// void arch_enter_user(pc, sp, arg0, arg1, kernel_top)
.globl arch_enter_user
.type arch_enter_user, @function
arch_enter_user:
    cli
    mov     %r8, %rsp
    pushq   $USER_DS                // ss
    pushq   %rsi                    // rsp
    pushq   $0x202                  // rflags: IF
    pushq   $USER_CS64              // cs
    pushq   %rdi                    // rip
    mov     %rdx, %rdi
    mov     %rcx, %rsi
    xor     %eax, %eax
    xor     %ebx, %ebx
    xor     %ecx, %ecx
    xor     %edx, %edx
    xor     %ebp, %ebp
    xor     %r8d, %r8d
    xor     %r9d, %r9d
    xor     %r10d, %r10d
    xor     %r11d, %r11d
    xor     %r12d, %r12d
    xor     %r13d, %r13d
    xor     %r14d, %r14d
    xor     %r15d, %r15d
    swapgs
    iretq
.size arch_enter_user, . - arch_enter_user

// void arch_syscall_init(void): EFER.SCE; STAR kernel CS 0x08 (SS 0x10),
// SYSRET base 0x18 (CS 0x28 | 3, SS 0x20 | 3); LSTAR; FMASK clears IF,
// DF, TF and AC on entry.
.globl arch_syscall_init
.type arch_syscall_init, @function
arch_syscall_init:
    mov     $0xc0000080, %ecx       // EFER
    rdmsr
    or      $1, %eax                // SCE
    wrmsr
    mov     $0xc0000081, %ecx       // STAR
    xor     %eax, %eax
    mov     $((0x18 | 3) << 16 | KERNEL_CS), %edx
    wrmsr
    mov     $0xc0000082, %ecx       // LSTAR
    lea     syscall_entry(%rip), %rax
    mov     %rax, %rdx
    shr     $32, %rdx
    wrmsr
    mov     $0xc0000084, %ecx       // FMASK
    mov     $((1 << 9) | (1 << 10) | (1 << 8) | (1 << 18)), %eax
    xor     %edx, %edx
    wrmsr
    mov     $0xc0000102, %ecx       // KERNEL_GS_BASE: the user's GS, 0
    xor     %eax, %eax
    xor     %edx, %edx
    wrmsr
    ret
.size arch_syscall_init, . - arch_syscall_init

// void arch_init_exceptions(void)
.section .text.arch_init_exceptions, "ax", @progbits
.globl arch_init_exceptions
.type arch_init_exceptions, @function
arch_init_exceptions:
    // IDT: 256 interrupt gates (present, DPL 0, type 0xE) to the stubs.
    // NMI (2), #DF (8) and #MC (18) switch to IST1.
    lea     idt(%rip), %rdi
    lea     isr_stubs(%rip), %rsi
    xor     %ecx, %ecx
1:  mov     %rsi, %rax
    movw    %ax, 0(%rdi)            // offset 15:0
    movw    $KERNEL_CS, 2(%rdi)
    xor     %edx, %edx
    cmp     $2, %ecx
    sete    %dl
    cmp     $8, %ecx
    sete    %r8b
    or      %r8b, %dl
    cmp     $18, %ecx
    sete    %r8b
    or      %r8b, %dl
    movb    %dl, 4(%rdi)            // IST index
    movb    $0x8e, 5(%rdi)
    shr     $16, %rax
    movw    %ax, 6(%rdi)            // offset 31:16
    shr     $16, %rax
    movl    %eax, 8(%rdi)           // offset 63:32
    movl    $0, 12(%rdi)
    add     $16, %rdi
    add     $16, %rsi
    inc     %ecx
    cmp     $256, %ecx
    jb      1b

    // TSS: IST1 = top of ist_stack; no I/O bitmap.
    lea     tss(%rip), %rdi
    lea     ist_stack_top(%rip), %rax
    mov     %rax, 36(%rdi)          // IST1
    movw    $104, 102(%rdi)         // I/O map base = sizeof(TSS)

    // 64-bit TSS descriptor at selector 0x30 of the boot GDT.
    lea     gdt_tss(%rip), %rsi
    mov     %rdi, %rax
    mov     $103, %rdx              // limit
    mov     %rax, %rcx
    and     $0xffffff, %rcx
    shl     $16, %rcx
    or      %rcx, %rdx              // base 23:0
    mov     $0x89, %rcx             // present, 64-bit TSS (available)
    shl     $40, %rcx
    or      %rcx, %rdx
    mov     %rax, %rcx
    shr     $24, %rcx
    and     $0xff, %rcx
    shl     $56, %rcx
    or      %rcx, %rdx              // base 31:24
    mov     %rdx, 0(%rsi)
    shr     $32, %rax
    mov     %rax, 8(%rsi)           // base 63:32

    lidt    idt_pointer(%rip)
    mov     $TSS_SEL, %ax
    ltr     %ax
    ret
.size arch_init_exceptions, . - arch_init_exceptions

// void arch_breakpoint(void)
.globl arch_breakpoint
.type arch_breakpoint, @function
arch_breakpoint:
    int3
    ret
.size arch_breakpoint, . - arch_breakpoint

// uint64_t arch_read_cr2(void)
.globl arch_read_cr2
.type arch_read_cr2, @function
arch_read_cr2:
    mov     %cr2, %rax
    ret
.size arch_read_cr2, . - arch_read_cr2

// The descriptor holds an absolute (relocated) address, so it is writable data.
.section .data.idt_pointer, "aw", @progbits
.balign 16
.globl idt_pointer
.hidden idt_pointer
idt_pointer:
    .word   256 * 16 - 1
    .quad   idt

.section .bss.idt, "aw", @nobits
.balign 4096
idt:
    .skip   256 * 16
.balign 16
tss:
    .skip   104
.balign 16
ist_stack:
    .skip   IST_STACK_SIZE
ist_stack_top:

#define GDT_SIZE    (8 * 8)         // 6 segments + the 16-byte TSS descriptor
#define TSS_SIZE    104

// void arch_install_cpu_descriptors(void *gdt, void *tss, uint64_t ist1_top)
// This CPU's own GDT (a copy of the boot one) and TSS, with IST1 (NMI,
// #DF, #MC) on its own stack. gdt: GDT_SIZE bytes, tss: TSS_SIZE bytes.
.section .text.arch_install_cpu_descriptors, "ax", @progbits
.globl arch_install_cpu_descriptors
.type arch_install_cpu_descriptors, @function
arch_install_cpu_descriptors:
    // GDT: the six segment descriptors from the boot GDT.
    push    %rdi
    push    %rsi
    lea     gdt(%rip), %rsi
    mov     $(6 * 8), %ecx
    rep movsb
    pop     %rsi
    pop     %rdi
    // TSS: zeroed, IST1, no I/O bitmap.
    push    %rdi
    mov     %rsi, %rdi
    xor     %eax, %eax
    mov     $TSS_SIZE, %ecx
    rep stosb
    pop     %rdi
    mov     %rdx, 36(%rsi)          // IST1
    movw    $TSS_SIZE, 102(%rsi)    // I/O map base: none
    // TSS descriptor at 0x30.
    mov     %rsi, %rax
    mov     $(TSS_SIZE - 1), %rdx
    mov     %rax, %rcx
    and     $0xffffff, %rcx
    shl     $16, %rcx
    or      %rcx, %rdx
    mov     $0x89, %rcx
    shl     $40, %rcx
    or      %rcx, %rdx
    mov     %rax, %rcx
    shr     $24, %rcx
    and     $0xff, %rcx
    shl     $56, %rcx
    or      %rcx, %rdx
    mov     %rdx, 0x30(%rdi)
    shr     $32, %rax
    mov     %rax, 0x38(%rdi)
    // Load it: lgdt from a descriptor on the stack, reload CS/DS/ES/SS
    // (FS/GS are untouched: GS holds the per-CPU base), then the TR.
    sub     $16, %rsp
    movw    $(GDT_SIZE - 1), (%rsp)
    mov     %rdi, 2(%rsp)
    lgdt    (%rsp)
    add     $16, %rsp
    lea     1f(%rip), %rax
    pushq   $0x08
    pushq   %rax
    lretq
1:  mov     $0x10, %eax
    mov     %eax, %ds
    mov     %eax, %es
    mov     %eax, %ss
    mov     $TSS_SEL, %ax
    ltr     %ax
    ret
.size arch_install_cpu_descriptors, . - arch_install_cpu_descriptors

// uint64_t arch_ist1_top(void): IST1 of the TSS this CPU has loaded.
.globl arch_ist1_top
.type arch_ist1_top, @function
arch_ist1_top:
    sub     $16, %rsp
    sgdt    (%rsp)
    mov     2(%rsp), %rcx           // GDT base
    add     $16, %rsp
    str     %ax
    movzwl  %ax, %eax
    add     %rax, %rcx              // TSS descriptor
    mov     (%rcx), %rax
    mov     %rax, %rdx
    shr     $16, %rdx
    and     $0xffffff, %rdx         // base 23:0
    mov     %rax, %rsi
    shr     $56, %rsi
    shl     $24, %rsi               // base 31:24
    or      %rsi, %rdx
    mov     8(%rcx), %rsi
    shl     $32, %rsi               // base 63:32
    or      %rsi, %rdx
    mov     36(%rdx), %rax
    ret
.size arch_ist1_top, . - arch_ist1_top
