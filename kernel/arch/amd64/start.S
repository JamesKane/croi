// amd64 kernel entry. The loader jumps here in long mode with interrupts
// masked and the handoff pointer in %rdi, which is passed straight through.

#include "stack.h"

#define KERNEL_CS 0x08
#define KERNEL_DS 0x10

// PAT entries 0-7: WB, WC, UC-, UC, repeated. Index 1 becomes WC; 0 and 3
// keep firmware's WB and UC, which the loader's mappings use.
#define MSR_PAT       0x277
#define PAT_LOW       0x00070106
#define PAT_HIGH      0x00070106

.section .text.boot, "ax", @progbits
.globl _start
.type _start, @function
_start:
    lea     boot_stack_top(%rip), %rsp
    xor     %ebp, %ebp

    // Leave firmware's GDT behind: it lives in memory the handoff reports
    // as free. Reload CS with a far return, then the data segments.
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

    mov     %rdi, %r12
    call    arch_init_pat

    // No per-CPU record yet (arch_percpu reads 0).
    mov     $0xc0000101, %ecx       // IA32_GS_BASE
    xor     %eax, %eax
    xor     %edx, %edx
    wrmsr
    mov     %r12, %rdi

    call    kernel_main
    // kernel_main does not return.
.size _start, . - _start

.globl arch_halt
.type arch_halt, @function
arch_halt:
1:  cli
    hlt
    jmp     1b
.size arch_halt, . - arch_halt

// void arch_init_pat(void): this CPU's memory types (see PageTableFormat).
.section .text.arch_init_pat, "ax", @progbits
.globl arch_init_pat
.hidden arch_init_pat
.type arch_init_pat, @function
arch_init_pat:
    mov     $MSR_PAT, %ecx
    mov     $PAT_LOW, %eax
    mov     $PAT_HIGH, %edx
    wrmsr
    ret
.size arch_init_pat, . - arch_init_pat

// void arch_load_page_tables(uint64_t root, uint64_t root_high)
.section .text.arch_load_page_tables, "ax", @progbits
.globl arch_load_page_tables
.type arch_load_page_tables, @function
arch_load_page_tables:
    mov     %cr4, %rax
    or      $(1 << 7), %rax         // CR4.PGE: honor global mappings
    mov     %rax, %cr4
    mov     %rdi, %cr3
    ret
.size arch_load_page_tables, . - arch_load_page_tables

// Flat 64-bit code and data segments. Writable because lgdt sets the
// accessed bits; the descriptor holds an absolute (relocated) address.
.section .data.gdt, "aw", @progbits
.balign 16
// Layout fixed for syscall/sysret (STAR): kernel CS, kernel DS = CS + 8;
// user CS32, user DS = CS32 + 8, user CS64 = CS32 + 16. Copied per CPU by
// arch_install_cpu_descriptors, which fills in that CPU's TSS.
.globl gdt
.hidden gdt
gdt:
    .quad   0
    .quad   0x00af9a000000ffff      // 0x08 KERNEL_CS: ring 0, long mode code
    .quad   0x00cf92000000ffff      // 0x10 KERNEL_DS: ring 0 data
    .quad   0x00cffa000000ffff      // 0x18 USER_CS32: ring 3, 32-bit code (sysret)
    .quad   0x00cff2000000ffff      // 0x20 USER_DS: ring 3 data
    .quad   0x00affa000000ffff      // 0x28 USER_CS64: ring 3, long mode code
.globl gdt_tss
.hidden gdt_tss
gdt_tss:                            // 0x30 TSS (16 bytes)
    .quad   0
    .quad   0
gdt_end:
.globl gdt_pointer
.hidden gdt_pointer
gdt_pointer:
    .word   gdt_end - gdt - 1
    .quad   gdt

// void arch_continue_on_stack(uint64_t top)
.section .text.arch_continue_on_stack, "ax", @progbits
.globl arch_continue_on_stack
.type arch_continue_on_stack, @function
arch_continue_on_stack:
    mov     %rdi, %rsp
    xor     %ebp, %ebp
    call    kernel_main_continue
    ud2
.size arch_continue_on_stack, . - arch_continue_on_stack

// The boot stack has the same geometry as every kernel stack (stack.h).
.section .bss.boot_stack, "aw", @nobits
.balign 2 * CROI_KERNEL_STACK_SIZE
boot_stack:
    .skip   CROI_KERNEL_STACK_SIZE
boot_stack_top:

.section .text.arch_io, "ax", @progbits

// uint8_t arch_inb(uint16_t port)
.globl arch_inb
.type arch_inb, @function
arch_inb:
    mov     %edi, %edx
    inb     %dx, %al
    ret
.size arch_inb, . - arch_inb

// void arch_outb(uint16_t port, uint8_t value)
.globl arch_outb
.type arch_outb, @function
arch_outb:
    mov     %edi, %edx
    mov     %esi, %eax
    outb    %al, %dx
    ret
.size arch_outb, . - arch_outb
