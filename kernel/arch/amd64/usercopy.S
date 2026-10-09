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
