// arm64 kernel entry. The loader jumps here at EL1 with interrupts masked
// and the handoff pointer in x0, which is passed straight through.

#include "stack.h"

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

// void arch_load_page_tables(uint64_t root, uint64_t root_high)
.section .text.arch_load_page_tables, "ax", %progbits
.globl arch_load_page_tables
.type arch_load_page_tables, %function
arch_load_page_tables:
    dsb     ishst                   // table writes visible to the walker
    msr     ttbr0_el1, x0
    msr     ttbr1_el1, x1
    isb
    tlbi    vmalle1
    dsb     ish
    isb
    ret
.size arch_load_page_tables, . - arch_load_page_tables

// void arch_continue_on_stack(uint64_t top)
.section .text.arch_continue_on_stack, "ax", %progbits
.globl arch_continue_on_stack
.type arch_continue_on_stack, %function
arch_continue_on_stack:
    mov     sp, x0
    mov     x29, xzr
    mov     x30, xzr
    bl      kernel_main_continue
    udf     #0
.size arch_continue_on_stack, . - arch_continue_on_stack

// The boot stack has the same geometry as every kernel stack (stack.h).
.section .bss.boot_stack, "aw", %nobits
.balign 2 * CROI_KERNEL_STACK_SIZE
boot_stack:
    .skip   CROI_KERNEL_STACK_SIZE
boot_stack_top:

// uint64_t arch_current_el(void)
.section .text.arch_current_el, "ax", %progbits
.globl arch_current_el
.type arch_current_el, %function
arch_current_el:
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    ret
.size arch_current_el, . - arch_current_el
