// rv64 kernel entry. The loader jumps here in S-mode with interrupts masked
// and the handoff pointer in a0, which is passed straight through.

#include "stack.h"

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

// void arch_load_page_tables(uint64_t root, uint64_t root_high)
.section .text.arch_load_page_tables, "ax", %progbits
.globl arch_load_page_tables
.type arch_load_page_tables, %function
arch_load_page_tables:
    srli    a0, a0, 12
    li      t0, (8 << 60)           // Sv39
    or      a0, a0, t0
    sfence.vma
    csrw    satp, a0
    sfence.vma
    ret
.size arch_load_page_tables, . - arch_load_page_tables

// void arch_continue_on_stack(uint64_t top)
.section .text.arch_continue_on_stack, "ax", %progbits
.globl arch_continue_on_stack
.type arch_continue_on_stack, %function
arch_continue_on_stack:
    mv      sp, a0
    mv      s0, zero
    mv      ra, zero
    call    kernel_main_continue
    unimp
.size arch_continue_on_stack, . - arch_continue_on_stack

// The boot stack has the same geometry as every kernel stack (stack.h).
.section .bss.boot_stack, "aw", %nobits
.balign 2 * CROI_KERNEL_STACK_SIZE
boot_stack:
    .skip   CROI_KERNEL_STACK_SIZE
boot_stack_top:
