// rv64 kernel entry. The loader jumps here in S-mode with interrupts masked
// and the handoff pointer in a0, which is passed straight through.

.section .text.boot, "ax", %progbits
.globl _start
.type _start, %function
_start:
    lla     sp, boot_stack_top
    mv      s0, zero
    mv      ra, zero
    call    kernel_main
    // kernel_main does not return.
.size _start, . - _start

.globl arch_halt
.type arch_halt, %function
arch_halt:
    csrci   sstatus, 0x2        // clear SIE
1:  wfi
    j       1b
.size arch_halt, . - arch_halt

.section .bss.boot_stack, "aw", %nobits
.balign 16
boot_stack:
    .skip   16384
boot_stack_top:
