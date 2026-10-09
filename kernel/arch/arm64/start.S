// arm64 kernel entry. The loader jumps here at EL1 with interrupts masked
// and the handoff pointer in x0, which is passed straight through.

.section .text.boot, "ax", %progbits
.globl _start
.type _start, %function
_start:
    adrp    x9, boot_stack_top
    add     x9, x9, :lo12:boot_stack_top
    mov     sp, x9
    mov     x29, xzr
    mov     x30, xzr
    bl      kernel_main
    // kernel_main does not return.
.size _start, . - _start

.globl arch_halt
.type arch_halt, %function
arch_halt:
    msr     daifset, #0xf
1:  wfi
    b       1b
.size arch_halt, . - arch_halt

.section .bss.boot_stack, "aw", %nobits
.balign 16
boot_stack:
    .skip   16384
boot_stack_top:
