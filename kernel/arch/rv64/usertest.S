// The boot self-test's user program (user.h), rv64. See the amd64 one for
// what each mode does. Syscalls: ecall with the number in a7, arguments in
// a0-a5, result in a0.

.section .rodata.user_test, "a", %progbits
.balign 16
.globl croi_user_test_start
croi_user_test_start:
    li      t0, 1
    beq     a0, t0, .Lfault
    li      t0, 2
    beq     a0, t0, .Lspin
    li      t0, 3
    beq     a0, t0, .Lprivileged

    li      s1, 0x1111
    li      s2, 0x2222
    li      s3, 0x3333
    li      s4, 0x4444
    li      s5, 0x5555
    li      a7, 3                   // clock
    ecall
    mv      s6, a0
    li      s7, 1000
.Lloop:
    li      a7, 0                   // null
    ecall
    addi    s7, s7, -1
    bnez    s7, .Lloop
    li      a7, 3
    ecall
    sub     a0, a0, s6
    li      a7, 5                   // report
    ecall
    lla     a0, .Lmessage
    li      a1, (.Lmessage_end - .Lmessage)
    li      a7, 1                   // debug_write
    ecall
    li      t0, 0x1111
    bne     s1, t0, .Lclobbered
    li      t0, 0x2222
    bne     s2, t0, .Lclobbered
    li      t0, 0x3333
    bne     s3, t0, .Lclobbered
    li      t0, 0x4444
    bne     s4, t0, .Lclobbered
    li      t0, 0x5555
    bne     s5, t0, .Lclobbered
    li      a0, 0x600d
    j       .Lexit
.Lclobbered:
    li      a0, 0xbad
.Lexit:
    li      a7, 2
    ecall
    unimp

.Lfault:
    li      t0, 0x10
    ld      a0, 0(t0)
    unimp

.Lspin:
    li      t1, 400000000
1:  addi    t1, t1, -1
    bnez    t1, 1b
    li      a0, 0x5917
    j       .Lexit

.Lprivileged:
    csrr    a0, satp                // S-mode CSR: illegal in U-mode
    unimp

.Lmessage:
    .ascii  "hello from user mode"
.Lmessage_end:
.balign 4
.globl croi_user_test_end
croi_user_test_end:
