// The boot self-test's user program (user.h), arm64. See the amd64 one
// for what each mode does. Syscalls: svc #0 with the number in x16
// (Zircon's convention), arguments in x0-x5, result in x0.

.section .rodata.user_test, "a", %progbits
.balign 16
.globl croi_user_test_start
croi_user_test_start:
    cmp     x0, #1
    b.eq    .Lfault
    cmp     x0, #2
    b.eq    .Lspin
    cmp     x0, #3
    b.eq    .Lprivileged

    mov     x19, #0x111
    mov     x20, #0x222
    mov     x21, #0x333
    mov     x22, #0x444
    mov     x23, #0x555
    mov     x16, #3                 // clock
    svc     #0
    mov     x24, x0
    mov     x25, #1000
.Lloop:
    mov     x16, #0                 // null
    svc     #0
    subs    x25, x25, #1
    b.ne    .Lloop
    mov     x16, #3
    svc     #0
    sub     x0, x0, x24
    mov     x16, #5                 // report
    svc     #0
    adr     x0, .Lmessage
    mov     x1, #(.Lmessage_end - .Lmessage)
    mov     x16, #1                 // debug_write
    svc     #0
    cmp     x19, #0x111
    b.ne    .Lclobbered
    cmp     x20, #0x222
    b.ne    .Lclobbered
    cmp     x21, #0x333
    b.ne    .Lclobbered
    cmp     x22, #0x444
    b.ne    .Lclobbered
    cmp     x23, #0x555
    b.ne    .Lclobbered
    mov     x0, #0x600d
    b       .Lexit
.Lclobbered:
    mov     x0, #0xbad
.Lexit:
    mov     x16, #2
    svc     #0
    udf     #0

.Lfault:
    mov     x1, #0x10
    ldr     x0, [x1]
    udf     #0

.Lspin:
    movz    x9, #0x8400
    movk    x9, #0x17d7, lsl #16    // 400000000
1:  subs    x9, x9, #1
    b.ne    1b
    mov     x0, #0x5917
    b       .Lexit

.Lprivileged:
    mrs     x0, ttbr0_el1           // undefined at EL0
    udf     #0

.Lmessage:
    .ascii  "hello from user mode"
.Lmessage_end:
.balign 4
.globl croi_user_test_end
croi_user_test_end:
