// rv64 trap entry. Assembly because it is the CPU's trap interface: stvec,
// register save/restore, sret.
//
// The entry builds an arch_exception_frame_t (kernel.h) and calls
// arch_exception. The handler may change sepc and sstatus in the frame;
// they are written back before sret.
//
// sscratch tells the two origins apart (as Linux does): 0 while in S-mode,
// this CPU's PerCpu (the kernel's tp) while in U-mode. The entry swaps it
// with tp: nonzero means a trap from U-mode, whose frame goes at the top of
// the thread's kernel stack (PerCpu kernel_sp) with the user's sp and tp
// saved in it; returning there restores them and puts the PerCpu back in
// sscratch.
//
// Stack overflow: if the frame would land below a kernel stack (bit
// CROI_KERNEL_STACK_SHIFT set, see stack.h), the entry switches to this
// CPU's emergency stack (PerCpu, via tp; a .bss one before per-CPU data
// exists) first, since pushing on the overflowed stack would just
// fault again. sscratch holds t0 while checking, and is zeroed again after.

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
    csrrw   tp, sscratch, tp
    bnez    tp, .Lfrom_user
    csrrw   tp, sscratch, tp        // from S-mode: tp back, sscratch 0 again
    csrw    sscratch, t0
    addi    t0, sp, -FRAME_SIZE
    srli    t0, t0, CROI_KERNEL_STACK_SHIFT
    andi    t0, t0, 1
    bnez    t0, 1f
    csrrw   t0, sscratch, zero      // t0 back; sscratch stays 0 in S-mode
    addi    sp, sp, -FRAME_SIZE
    sd      zero, FRAME_OVERFLOW(sp)
    j       2f
1:  beqz    tp, 3f                  // this CPU's emergency stack, if it has one
    ld      t0, CROI_PERCPU_EMERGENCY_STACK(tp)
    beqz    t0, 3f
    mv      sp, t0
    j       4f
3:  lla     sp, emergency_stack_top // boot-time fallback
4:  addi    sp, sp, -FRAME_SIZE
    sd      sp, FRAME_OVERFLOW(sp)  // any nonzero value marks the overflow
    csrrw   t0, sscratch, zero
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
    // Not tp (x4): it is per CPU, and a thread preempted here can resume
    // on another hart.
    .irp n, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    RESTORE \n
    .endr
    addi    sp, sp, FRAME_SIZE
    sret

.Lfrom_user:
    sd      sp, CROI_PERCPU_USER_SP(tp)
    ld      sp, CROI_PERCPU_KERNEL_SP(tp)
    addi    sp, sp, -FRAME_SIZE
    sd      zero, FRAME_OVERFLOW(sp)
    SAVE 1
    SAVE 3
    .irp n, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    SAVE \n
    .endr
    ld      t0, CROI_PERCPU_USER_SP(tp)
    sd      t0, (2 * 8)(sp)         // the user's sp
    csrrw   t0, sscratch, zero      // the user's tp; S-mode now
    sd      t0, (4 * 8)(sp)
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

    csrci   sstatus, 0x2
    ld      t0, FRAME_SEPC(sp)
    csrw    sepc, t0
    ld      t0, FRAME_SSTATUS(sp)
    csrw    sstatus, t0
    csrw    sscratch, tp            // this CPU's PerCpu (the thread may have moved)
    RESTORE 1
    RESTORE 3
    RESTORE 4                       // the user's tp
    .irp n, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    RESTORE \n
    .endr
    ld      sp, (2 * 8)(sp)         // the user's sp, last
    sret

// void arch_enter_user(a0 pc, a1 sp, a2 arg0, a3 arg1, a4 kernel_top): to
// U-mode with interrupts on (SPIE), SUM off; the kernel stack top is
// already in PerCpu kernel_sp.
.globl arch_enter_user
.type arch_enter_user, %function
arch_enter_user:
    csrci   sstatus, 0x2
    csrw    sscratch, tp
    csrw    sepc, a0
    li      t0, (1 << 8) | (1 << 18)    // SPP, SUM
    csrc    sstatus, t0
    li      t0, (1 << 5)                // SPIE
    csrs    sstatus, t0
    mv      sp, a1
    mv      a0, a2
    mv      a1, a3
    .irp n, 1, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    li      x\n, 0
    .endr
    sret
.size arch_enter_user, . - arch_enter_user

// Emergency stack for overflows before a CPU has its own (boot only). Same
// geometry as a kernel stack so traps taken on it pass the check.
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
    csrw    sscratch, zero          // S-mode (firmware may have left anything)
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
