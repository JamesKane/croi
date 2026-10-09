// amd64 user access with fault recovery (usercopy.h). Assembly so that the
// faulting instruction's address is known and listed in .croi_fixups.

.macro FIXUP insn, recovery
    .pushsection .croi_fixups, "a"
    .balign 4
    .long \insn - .
    .long \recovery - .
    .popsection
.endm

.section .text.usercopy, "ax", @progbits

// int arch_user_load_u64(uint64_t addr, uint64_t *out)
.globl arch_user_load_u64
.type arch_user_load_u64, @function
arch_user_load_u64:
1:  mov     (%rdi), %rax
    mov     %rax, (%rsi)
    xor     %eax, %eax
    ret
2:  mov     $-1, %eax
    ret
FIXUP 1b, 2b
.size arch_user_load_u64, . - arch_user_load_u64

// int arch_user_store_u64(uint64_t addr, uint64_t value)
.globl arch_user_store_u64
.type arch_user_store_u64, @function
arch_user_store_u64:
1:  mov     %rsi, (%rdi)
    xor     %eax, %eax
    ret
2:  mov     $-1, %eax
    ret
FIXUP 1b, 2b
.size arch_user_store_u64, . - arch_user_store_u64

// int arch_copy_from_user(void *dst, uint64_t src, uint64_t len)
.globl arch_copy_from_user
.type arch_copy_from_user, @function
arch_copy_from_user:
    test    %rdx, %rdx
    jz      3f
1:  movb    (%rsi), %al
    movb    %al, (%rdi)
    inc     %rsi
    inc     %rdi
    dec     %rdx
    jnz     1b
3:  xor     %eax, %eax
    ret
2:  mov     $-1, %eax
    ret
FIXUP 1b, 2b
.size arch_copy_from_user, . - arch_copy_from_user

// int arch_copy_to_user(uint64_t dst, const void *src, uint64_t len)
.globl arch_copy_to_user
.type arch_copy_to_user, @function
arch_copy_to_user:
    test    %rdx, %rdx
    jz      3f
    movb    (%rsi), %al
1:  movb    %al, (%rdi)
    inc     %rsi
    inc     %rdi
    dec     %rdx
    jz      3f
    movb    (%rsi), %al
    jmp     1b
3:  xor     %eax, %eax
    ret
2:  mov     $-1, %eax
    ret
FIXUP 1b, 2b
.size arch_copy_to_user, . - arch_copy_to_user
