// amd64 kernel entry. The loader jumps here in long mode with interrupts
// masked and the handoff pointer in %rdi, which is passed straight through.

.section .text.boot, "ax", @progbits
.globl _start
.type _start, @function
_start:
    lea     boot_stack_top(%rip), %rsp
    xor     %ebp, %ebp
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
