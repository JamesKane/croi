// rv64 user access with fault recovery (usercopy.h). Assembly so that the
// faulting instruction's address is known and listed in .croi_fixups.
// sstatus.SUM opens user pages to S-mode for the access only; a fault
// restores sstatus from the trap frame, so the recovery path clears it.

.macro FIXUP insn, recovery
    .pushsection .croi_fixups, "a"
    .balign 4
    .4byte \insn - .
    .4byte \recovery - .
    .popsection
.endm

#define SSTATUS_SUM (1 << 18)

.section .text.usercopy, "ax", %progbits

// int arch_user_load_u64(uint64_t addr, uint64_t *out)
.globl arch_user_load_u64
.type arch_user_load_u64, %function
arch_user_load_u64:
    li      t0, SSTATUS_SUM
    csrs    sstatus, t0
1:  ld      t1, 0(a0)
    csrc    sstatus, t0
    sd      t1, 0(a1)
    li      a0, 0
    ret
2:  li      t0, SSTATUS_SUM
    csrc    sstatus, t0
    li      a0, -1
    ret
FIXUP 1b, 2b
.size arch_user_load_u64, . - arch_user_load_u64

// int arch_user_store_u64(uint64_t addr, uint64_t value)
.globl arch_user_store_u64
.type arch_user_store_u64, %function
arch_user_store_u64:
    li      t0, SSTATUS_SUM
    csrs    sstatus, t0
1:  sd      a1, 0(a0)
    csrc    sstatus, t0
    li      a0, 0
    ret
2:  li      t0, SSTATUS_SUM
    csrc    sstatus, t0
    li      a0, -1
    ret
FIXUP 1b, 2b
.size arch_user_store_u64, . - arch_user_store_u64
