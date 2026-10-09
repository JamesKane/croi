// arm64 user access with fault recovery (usercopy.h). Assembly so that the
// faulting instruction's address is known and listed in .croi_fixups.
// ldtr/sttr access as EL0 would, so user permissions apply.

.macro FIXUP insn, recovery
    .pushsection .croi_fixups, "a"
    .balign 4
    .long \insn - .
    .long \recovery - .
    .popsection
.endm

.section .text.usercopy, "ax", %progbits

// int arch_user_load_u64(uint64_t addr, uint64_t *out)
.globl arch_user_load_u64
.type arch_user_load_u64, %function
arch_user_load_u64:
1:  ldtr    x2, [x0]
    str     x2, [x1]
    mov     w0, #0
    ret
2:  mov     w0, #-1
    ret
FIXUP 1b, 2b
.size arch_user_load_u64, . - arch_user_load_u64

// int arch_user_store_u64(uint64_t addr, uint64_t value)
.globl arch_user_store_u64
.type arch_user_store_u64, %function
arch_user_store_u64:
1:  sttr    x1, [x0]
    mov     w0, #0
    ret
2:  mov     w0, #-1
    ret
FIXUP 1b, 2b
.size arch_user_store_u64, . - arch_user_store_u64
