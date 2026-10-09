// amd64 kernel entry. The loader jumps here in long mode with interrupts
// masked and the handoff pointer in %rdi, which is passed straight through.

#define KERNEL_CS 0x08
#define KERNEL_DS 0x10

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
gdt:
    .quad   0
    .quad   0x00af9a000000ffff      // KERNEL_CS: present, ring 0, code, long mode
    .quad   0x00cf92000000ffff      // KERNEL_DS: present, ring 0, data, writable
gdt_end:
gdt_pointer:
    .word   gdt_end - gdt - 1
    .quad   gdt

.section .bss.boot_stack, "aw", @nobits
.balign 16
boot_stack:
    .skip   16384
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
