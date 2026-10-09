// rv64 trap entry. Assembly because it is the CPU's trap interface: stvec,
// register save/restore, sret.
//
// Supervisor-mode traps only for now (no sscratch stack switch for user
// mode yet). The entry builds an arch_exception_frame_t (kernel.h) on the
// current stack and calls arch_exception. The handler may change sepc and
// sstatus in the frame; they are written back before sret.

#define FRAME_SIZE    (36 * 8)
#define FRAME_SEPC    (32 * 8)
#define FRAME_SSTATUS (33 * 8)
#define FRAME_SCAUSE  (34 * 8)
#define FRAME_STVAL   (35 * 8)

.macro SAVE n
    sd      x\n, (\n * 8)(sp)
.endm
.macro RESTORE n
    ld      x\n, (\n * 8)(sp)
.endm

.section .text.trap_entry, "ax", %progbits
.balign 4
trap_entry:
    addi    sp, sp, -FRAME_SIZE
    SAVE 1
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

// void arch_init_exceptions(void)
.section .text.arch_init_exceptions, "ax", %progbits
.globl arch_init_exceptions
.type arch_init_exceptions, %function
arch_init_exceptions:
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
