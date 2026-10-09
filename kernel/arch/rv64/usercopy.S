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

// int arch_copy_from_user(void *dst, uint64_t src, uint64_t len)
.globl arch_copy_from_user
.type arch_copy_from_user, %function
arch_copy_from_user:
    li      t0, SSTATUS_SUM
    csrs    sstatus, t0
    beqz    a2, 3f
1:  lbu     t1, 0(a1)
    sb      t1, 0(a0)
    addi    a0, a0, 1
    addi    a1, a1, 1
    addi    a2, a2, -1
    bnez    a2, 1b
3:  csrc    sstatus, t0
    li      a0, 0
    ret
2:  li      t0, SSTATUS_SUM
    csrc    sstatus, t0
    li      a0, -1
    ret
FIXUP 1b, 2b
.size arch_copy_from_user, . - arch_copy_from_user

// int arch_copy_to_user(uint64_t dst, const void *src, uint64_t len)
.globl arch_copy_to_user
.type arch_copy_to_user, %function
arch_copy_to_user:
    li      t0, SSTATUS_SUM
    csrs    sstatus, t0
    beqz    a2, 3f
4:  lbu     t1, 0(a1)
1:  sb      t1, 0(a0)
    addi    a0, a0, 1
    addi    a1, a1, 1
    addi    a2, a2, -1
    bnez    a2, 4b
3:  csrc    sstatus, t0
    li      a0, 0
    ret
2:  li      t0, SSTATUS_SUM
    csrc    sstatus, t0
    li      a0, -1
    ret
FIXUP 1b, 2b
.size arch_copy_to_user, . - arch_copy_to_user

// int arch_user_probe_unprotected(uint64_t addr): a load from a user
// address with SUM clear, for the self-test: it must fault.
.globl arch_user_probe_unprotected
.type arch_user_probe_unprotected, %function
arch_user_probe_unprotected:
1:  ld      t1, 0(a0)
    li      a0, 0
    ret
2:  li      a0, -1
    ret
FIXUP 1b, 2b
.size arch_user_probe_unprotected, . - arch_user_probe_unprotected
