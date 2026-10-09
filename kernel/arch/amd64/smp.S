// amd64 secondary CPU startup. Assembly because the CPU starts in 16-bit
// real mode at a page below 1 MiB (INIT-SIPI-SIPI) and must be walked
// through protected mode into long mode.
//
// arch_ap_prepare_trampoline copies ap_trampoline to that page and patches
// in its addresses, a bootstrap CR3 (below 4 GiB, mapping the trampoline
// page 1:1 plus the kernel half) and the startup block. The trampoline
// ends by jumping to ap_long_mode (kernel text, virtual), which switches
// to the kernel's own CR3 and calls kernel_ap_main.

#include "smp.h"

#define KERNEL_CS 0x08
#define KERNEL_DS 0x10
#define T_CODE32  0x08              // trampoline GDT selectors
#define T_DATA    0x10
#define T_CODE64  0x18

// Offsets of the patched fields from ap_trampoline.
#define T_OFF(sym) ((sym) - ap_trampoline)

.section .text.ap_trampoline, "ax", @progbits
.balign 16
.code16
ap_trampoline:
    cli
    cld
    mov     %cs, %ax
    mov     %ax, %ds
    movzx   %ax, %ebx
    shl     $4, %ebx                // ebx = trampoline linear address
    lgdtl   T_OFF(t_gdt_pointer)
    mov     %cr0, %eax
    or      $1, %eax                // PE
    mov     %eax, %cr0
    ljmpl   *T_OFF(t_far32)

.code32
t_protected:
    mov     $T_DATA, %ax
    mov     %ax, %ds
    mov     %ax, %es
    mov     %ax, %ss
    mov     %cr4, %eax
    or      $(1 << 5), %eax         // PAE
    mov     %eax, %cr4
    mov     T_OFF(t_cr3)(%ebx), %eax
    mov     %eax, %cr3
    mov     $0xc0000080, %ecx       // EFER: LME, NXE
    rdmsr
    or      $((1 << 8) | (1 << 11)), %eax
    wrmsr
    mov     %cr0, %eax
    or      $((1 << 31) | (1 << 16)), %eax  // PG, WP
    mov     %eax, %cr0
    ljmpl   *T_OFF(t_far64)(%ebx)

.code64
t_long:
    mov     %ebx, %ebx              // upper half is undefined after the mode switch
    jmp     *T_OFF(t_entry64)(%rbx)

.balign 8
t_gdt:
    .quad   0
    .quad   0x00cf9a000000ffff      // T_CODE32: flat 32-bit code
    .quad   0x00cf92000000ffff      // T_DATA: flat data
    .quad   0x00af9a000000ffff      // T_CODE64: long mode code
t_gdt_end:
t_gdt_pointer:
    .word   t_gdt_end - t_gdt - 1
    .long   0                       // patched: linear address of t_gdt
t_far32:
    .long   0                       // patched: linear address of t_protected
    .word   T_CODE32
t_far64:
    .long   0                       // patched: linear address of t_long
    .word   T_CODE64
.balign 8
t_cr3:
    .quad   0                       // patched: bootstrap PML4
t_entry64:
    .quad   0                       // patched: ap_long_mode (virtual)
t_block:
    .skip   CROI_AP_SIZE            // patched: copy of the startup block
ap_trampoline_end:

// void arch_ap_prepare_trampoline(void *dest, uint64_t dest_phys,
//                                 uint64_t bootstrap_cr3, const croi_ap_startup_t *block)
// dest is where dest_phys can be written (the physmap).
.section .text.arch_ap_prepare_trampoline, "ax", @progbits
.globl arch_ap_prepare_trampoline
.type arch_ap_prepare_trampoline, @function
arch_ap_prepare_trampoline:
    push    %rdi
    push    %rsi
    push    %rdx
    push    %rcx
    lea     ap_trampoline(%rip), %rsi
    mov     $(ap_trampoline_end - ap_trampoline), %rcx
    rep movsb
    pop     %rcx
    pop     %rdx
    pop     %rsi
    pop     %rdi
    lea     T_OFF(t_gdt)(%rsi), %rax
    mov     %eax, T_OFF(t_gdt_pointer) + 2(%rdi)
    lea     T_OFF(t_protected)(%rsi), %rax
    mov     %eax, T_OFF(t_far32)(%rdi)
    lea     T_OFF(t_long)(%rsi), %rax
    mov     %eax, T_OFF(t_far64)(%rdi)
    mov     %rdx, T_OFF(t_cr3)(%rdi)
    lea     ap_long_mode(%rip), %rax
    mov     %rax, T_OFF(t_entry64)(%rdi)
    // Copy the startup block.
    lea     T_OFF(t_block)(%rdi), %rdi
    mov     %rcx, %rsi
    mov     $CROI_AP_SIZE, %ecx
    rep movsb
    ret
.size arch_ap_prepare_trampoline, . - arch_ap_prepare_trampoline

// Long mode, at a kernel virtual address, still on the bootstrap CR3 with
// rbx = trampoline (identity mapped). Read everything from the block, then
// switch to the kernel CR3, GDT and segments, and the per-CPU register.
.section .text.ap_long_mode, "ax", @progbits
ap_long_mode:
    mov     T_OFF(t_block) + CROI_AP_STACK(%rbx), %rsp
    mov     T_OFF(t_block) + CROI_AP_PERCPU(%rbx), %r12
    mov     T_OFF(t_block) + CROI_AP_ROOT(%rbx), %rax
    mov     %rax, %cr3
    mov     %cr4, %rax
    or      $(1 << 7), %rax         // PGE, as on the boot CPU
    mov     %rax, %cr4
    lgdt    gdt_pointer(%rip)
    lea     1f(%rip), %rax
    pushq   $KERNEL_CS
    pushq   %rax
    lretq
1:  mov     $KERNEL_DS, %eax
    mov     %eax, %ds
    mov     %eax, %es
    mov     %eax, %ss
    xor     %eax, %eax
    mov     %eax, %fs
    mov     %eax, %gs
    mov     %r12, %rdi
    call    arch_set_percpu
    xor     %ebp, %ebp
    mov     %r12, %rdi
    call    kernel_ap_main
    ud2

// void arch_ap_capture_mmu(croi_ap_startup_t *block)
.section .text.arch_ap_capture_mmu, "ax", @progbits
.globl arch_ap_capture_mmu
.type arch_ap_capture_mmu, @function
arch_ap_capture_mmu:
    mov     %cr3, %rax
    mov     %rax, CROI_AP_ROOT(%rdi)
    ret
.size arch_ap_capture_mmu, . - arch_ap_capture_mmu

// uint64_t arch_rdmsr(uint32_t msr) / void arch_wrmsr(uint32_t msr, uint64_t value)
.globl arch_rdmsr
.type arch_rdmsr, @function
arch_rdmsr:
    mov     %edi, %ecx
    rdmsr
    shl     $32, %rdx
    or      %rdx, %rax
    ret
.size arch_rdmsr, . - arch_rdmsr

.globl arch_wrmsr
.type arch_wrmsr, @function
arch_wrmsr:
    mov     %edi, %ecx
    mov     %esi, %eax
    mov     %rsi, %rdx
    shr     $32, %rdx
    wrmsr
    ret
.size arch_wrmsr, . - arch_wrmsr

// void arch_ap_init_exceptions(void): secondaries share the IDT. They get
// no TSS (so no IST stacks) until there are per-CPU TSSes.
.globl arch_ap_init_exceptions
.type arch_ap_init_exceptions, @function
arch_ap_init_exceptions:
    lidt    idt_pointer(%rip)
    ret
.size arch_ap_init_exceptions, . - arch_ap_init_exceptions
