// arm64 exception entry. Assembly because it is the CPU's exception
// interface: the VBAR_EL1 table, register save/restore, eret.
//
// Each of the 16 vector slots saves x0/x1, records its slot number and joins
// exception_common, which completes an arch_exception_frame_t (kernel.h) on
// the current stack and calls arch_exception. The handler may change elr and
// spsr in the frame; they are written back before eret.
//
// Stack overflow: if the frame would land below a kernel stack (bit
// CROI_KERNEL_STACK_SHIFT set, see stack.h), the vector switches to this
// CPU's emergency stack (PerCpu, via TPIDR_EL1; a .bss one before per-CPU
// data exists) first, since pushing on the overflowed stack would just
// fault again. The check needs a scratch register without touching memory,
// hence the add/sub exchange of sp and x0 (as Linux does). TPIDRRO_EL0
// briefly holds x0 on that path, so it is kernel scratch: user mode always
// gets it back as 0.
//
// From EL0 (slots 8-15) the stack is SP_EL1, which is the thread's kernel
// stack top (user frames sit right at the top, so popping one leaves it
// there for the next entry): no overflow check, and the user's SP_EL0 is
// saved in the frame and restored from it.

#include "stack.h"

#define FRAME_SIZE  (38 * 8)
#define FRAME_SP    (31 * 8)
#define FRAME_ELR   (32 * 8)
#define FRAME_SPSR  (33 * 8)
#define FRAME_ESR   (34 * 8)
#define FRAME_FAR   (35 * 8)
#define FRAME_SLOT  (36 * 8)

.macro VECTOR slot
    .balign 0x80
    sub     sp, sp, #FRAME_SIZE
    add     sp, sp, x0              // sp = frame + x0
    sub     x0, sp, x0              // x0 = frame
    tbnz    x0, #CROI_KERNEL_STACK_SHIFT, 1f
    sub     x0, sp, x0              // x0 = original x0
    sub     sp, sp, x0              // sp = frame
    stp     x0, x1, [sp, #0]
    mov     x0, #\slot
    b       exception_common
1:  sub     x0, sp, x0              // x0 = original x0
    msr     tpidrro_el0, x0
    mrs     x0, tpidr_el1           // this CPU's emergency stack, if it has one
    cbz     x0, 2f
    ldr     x0, [x0, #CROI_PERCPU_EMERGENCY_STACK]
    cbnz    x0, 3f
2:  adrp    x0, emergency_stack_top // boot-time fallback
    add     x0, x0, :lo12:emergency_stack_top
3:  sub     sp, x0, #FRAME_SIZE
    mrs     x0, tpidrro_el0
    stp     x0, x1, [sp, #0]
    mov     x0, #(16 + \slot)
    b       exception_common
.endm

.macro USER_VECTOR slot
    .balign 0x80
    sub     sp, sp, #FRAME_SIZE
    stp     x0, x1, [sp, #0]
    mov     x0, #\slot
    b       exception_common_user
.endm

.section .text.vectors, "ax", %progbits
.balign 2048
vectors:
    // Current EL with SP_EL0, then with SP_ELx, then lower EL (AArch64,
    // AArch32): synchronous, IRQ, FIQ, SError each.
    VECTOR 0
    VECTOR 1
    VECTOR 2
    VECTOR 3
    VECTOR 4
    VECTOR 5
    VECTOR 6
    VECTOR 7
    USER_VECTOR 8
    USER_VECTOR 9
    USER_VECTOR 10
    USER_VECTOR 11
    USER_VECTOR 12
    USER_VECTOR 13
    USER_VECTOR 14
    USER_VECTOR 15

exception_common:
    stp     x2, x3, [sp, #2 * 8]
    stp     x4, x5, [sp, #4 * 8]
    stp     x6, x7, [sp, #6 * 8]
    stp     x8, x9, [sp, #8 * 8]
    stp     x10, x11, [sp, #10 * 8]
    stp     x12, x13, [sp, #12 * 8]
    stp     x14, x15, [sp, #14 * 8]
    stp     x16, x17, [sp, #16 * 8]
    stp     x18, x19, [sp, #18 * 8]
    stp     x20, x21, [sp, #20 * 8]
    stp     x22, x23, [sp, #22 * 8]
    stp     x24, x25, [sp, #24 * 8]
    stp     x26, x27, [sp, #26 * 8]
    stp     x28, x29, [sp, #28 * 8]
    add     x1, sp, #FRAME_SIZE
    stp     x30, x1, [sp, #30 * 8]  // x30, sp
    mrs     x1, elr_el1
    mrs     x2, spsr_el1
    stp     x1, x2, [sp, #FRAME_ELR]
    mrs     x1, esr_el1
    mrs     x2, far_el1
    stp     x1, x2, [sp, #FRAME_ESR]
    str     x0, [sp, #FRAME_SLOT]

    mov     x0, sp
    bl      arch_exception

    ldp     x1, x2, [sp, #FRAME_ELR]
    msr     elr_el1, x1
    msr     spsr_el1, x2
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #2 * 8]
    ldp     x4, x5, [sp, #4 * 8]
    ldp     x6, x7, [sp, #6 * 8]
    ldp     x8, x9, [sp, #8 * 8]
    ldp     x10, x11, [sp, #10 * 8]
    ldp     x12, x13, [sp, #12 * 8]
    ldp     x14, x15, [sp, #14 * 8]
    ldp     x16, x17, [sp, #16 * 8]
    ldp     x18, x19, [sp, #18 * 8]
    ldp     x20, x21, [sp, #20 * 8]
    ldp     x22, x23, [sp, #22 * 8]
    ldp     x24, x25, [sp, #24 * 8]
    ldp     x26, x27, [sp, #26 * 8]
    ldp     x28, x29, [sp, #28 * 8]
    ldr     x30, [sp, #30 * 8]
    add     sp, sp, #FRAME_SIZE
    eret

exception_common_user:
    stp     x2, x3, [sp, #2 * 8]
    stp     x4, x5, [sp, #4 * 8]
    stp     x6, x7, [sp, #6 * 8]
    stp     x8, x9, [sp, #8 * 8]
    stp     x10, x11, [sp, #10 * 8]
    stp     x12, x13, [sp, #12 * 8]
    stp     x14, x15, [sp, #14 * 8]
    stp     x16, x17, [sp, #16 * 8]
    stp     x18, x19, [sp, #18 * 8]
    stp     x20, x21, [sp, #20 * 8]
    stp     x22, x23, [sp, #22 * 8]
    stp     x24, x25, [sp, #24 * 8]
    stp     x26, x27, [sp, #26 * 8]
    stp     x28, x29, [sp, #28 * 8]
    mrs     x1, sp_el0
    stp     x30, x1, [sp, #30 * 8]  // x30, the user's sp
    mrs     x1, elr_el1
    mrs     x2, spsr_el1
    stp     x1, x2, [sp, #FRAME_ELR]
    mrs     x1, esr_el1
    mrs     x2, far_el1
    stp     x1, x2, [sp, #FRAME_ESR]
    str     x0, [sp, #FRAME_SLOT]

    mov     x0, sp
    bl      arch_exception

    msr     daifset, #0xf
    ldp     x1, x2, [sp, #FRAME_ELR]
    msr     elr_el1, x1
    msr     spsr_el1, x2
    ldr     x1, [sp, #FRAME_SP]
    msr     sp_el0, x1
    msr     tpidrro_el0, xzr
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #2 * 8]
    ldp     x4, x5, [sp, #4 * 8]
    ldp     x6, x7, [sp, #6 * 8]
    ldp     x8, x9, [sp, #8 * 8]
    ldp     x10, x11, [sp, #10 * 8]
    ldp     x12, x13, [sp, #12 * 8]
    ldp     x14, x15, [sp, #14 * 8]
    ldp     x16, x17, [sp, #16 * 8]
    ldp     x18, x19, [sp, #18 * 8]
    ldp     x20, x21, [sp, #20 * 8]
    ldp     x22, x23, [sp, #22 * 8]
    ldp     x24, x25, [sp, #24 * 8]
    ldp     x26, x27, [sp, #26 * 8]
    ldp     x28, x29, [sp, #28 * 8]
    ldr     x30, [sp, #30 * 8]
    add     sp, sp, #FRAME_SIZE
    eret

// void arch_enter_user(x0 pc, x1 sp, x2 arg0, x3 arg1, x4 kernel_top):
// EL0t with interrupts unmasked.
.globl arch_enter_user
.type arch_enter_user, %function
arch_enter_user:
    msr     daifset, #0xf
    mov     sp, x4
    msr     sp_el0, x1
    msr     elr_el1, x0
    msr     spsr_el1, xzr
    msr     tpidrro_el0, xzr
    mov     x0, x2
    mov     x1, x3
    .irp n, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30
    mov     x\n, xzr
    .endr
    eret
.size arch_enter_user, . - arch_enter_user

// void arch_init_exceptions(void) / void arch_ap_init_exceptions(void)
.section .text.arch_init_exceptions, "ax", %progbits
.globl arch_init_exceptions
.type arch_init_exceptions, %function
.globl arch_ap_init_exceptions
.type arch_ap_init_exceptions, %function
arch_init_exceptions:
arch_ap_init_exceptions:
    adr     x0, vectors
    msr     vbar_el1, x0
    isb
    ret
.size arch_init_exceptions, . - arch_init_exceptions

// Emergency stack for overflows before a CPU has its own (boot only). Same
// geometry as a kernel stack so exceptions taken on it pass the check.
.section .bss.emergency_stack, "aw", %nobits
.balign 2 * CROI_KERNEL_STACK_SIZE
emergency_stack:
    .skip   CROI_KERNEL_STACK_SIZE
emergency_stack_top:

.section .text.arch_init_exceptions, "ax", %progbits
// void arch_breakpoint(void)
.globl arch_breakpoint
.type arch_breakpoint, %function
arch_breakpoint:
    brk     #0
    ret
.size arch_breakpoint, . - arch_breakpoint
