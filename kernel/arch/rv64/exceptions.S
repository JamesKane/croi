// rv64 trap entry. Assembly because it is the CPU's trap interface: stvec,
// register save/restore, sret.
//
// Supervisor-mode traps only for now. The entry builds an
// arch_exception_frame_t (kernel.h) on the current stack and calls
// arch_exception. The handler may change sepc and sstatus in the frame;
// they are written back before sret.
//
// Stack overflow: if the frame would land below a kernel stack (bit
// CROI_KERNEL_STACK_SHIFT set, see stack.h), the entry switches to the
// emergency stack first, since pushing on the overflowed stack would just
// fault again. sscratch holds t0 while checking (it is unused while there
// is no user mode; user traps will need it for the kernel stack).

#include "stack.h"

#define FRAME_SIZE     (38 * 8)
#define FRAME_SEPC     (32 * 8)
#define FRAME_SSTATUS  (33 * 8)
#define FRAME_SCAUSE   (34 * 8)
#define FRAME_STVAL    (35 * 8)
#define FRAME_OVERFLOW (36 * 8)

.macro SAVE n
    sd      x\n, (\n * 8)(sp)
.endm
.macro RESTORE n
    ld      x\n, (\n * 8)(sp)
.endm

.section .text.trap_entry, "ax", %progbits
.balign 4
trap_entry:
    csrw    sscratch, t0
    addi    t0, sp, -FRAME_SIZE
    srli    t0, t0, CROI_KERNEL_STACK_SHIFT
    andi    t0, t0, 1
    bnez    t0, 1f
    csrr    t0, sscratch
    addi    sp, sp, -FRAME_SIZE
    sd      zero, FRAME_OVERFLOW(sp)
    j       2f
1:  lla     sp, emergency_stack_top
    addi    sp, sp, -FRAME_SIZE
    sd      sp, FRAME_OVERFLOW(sp)  // any nonzero value marks the overflow
    csrr    t0, sscratch
2:  SAVE 1
    .irp n, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    SAVE \n
    .endr
    addi    t0, sp, FRAME_SIZE
    sd      t0, (2 * 8)(sp)         // sp at the time of the trap
    csrr    t0, sepc
    sd      t0, FRAME_SEPC(sp)
    csrr    t0, sstatus
    sd      t0, FRAME_SSTATUS(sp)
    csrr    t0, scause
    sd      t0, FRAME_SCAUSE(sp)
    csrr    t0, stval
    sd      t0, FRAME_STVAL(sp)

    mv      a0, sp
    call    arch_exception

    ld      t0, FRAME_SEPC(sp)
    csrw    sepc, t0
    ld      t0, FRAME_SSTATUS(sp)
    csrw    sstatus, t0
    RESTORE 1
    .irp n, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    RESTORE \n
    .endr
    addi    sp, sp, FRAME_SIZE
    sret

// Stack for handling a trap taken on an overflowed stack. Same geometry as
// a kernel stack so traps taken on it pass the check.
.section .bss.emergency_stack, "aw", %nobits
.balign 2 * CROI_KERNEL_STACK_SIZE
emergency_stack:
    .skip   CROI_KERNEL_STACK_SIZE
emergency_stack_top:

// void arch_init_exceptions(void) / void arch_ap_init_exceptions(void)
.section .text.arch_init_exceptions, "ax", %progbits
.globl arch_init_exceptions
.type arch_init_exceptions, %function
.globl arch_ap_init_exceptions
.type arch_ap_init_exceptions, %function
arch_init_exceptions:
arch_ap_init_exceptions:
    lla     t0, trap_entry          // direct mode: MODE bits 0
    csrw    stvec, t0
    ret
.size arch_init_exceptions, . - arch_init_exceptions

// void arch_breakpoint(void)
.globl arch_breakpoint
.type arch_breakpoint, %function
arch_breakpoint:
    ebreak
    ret
.size arch_breakpoint, . - arch_breakpoint
