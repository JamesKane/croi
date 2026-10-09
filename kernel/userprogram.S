// The K6b self-test's user program (user/test, built as a flat binary by
// CMake), included in the kernel image as data. Assembly only to .incbin
// it.

.section .rodata.user_program, "a"
.balign 16
.globl croi_user_program_start
croi_user_program_start:
    .incbin CROI_USER_PROGRAM
.globl croi_user_program_end
croi_user_program_end:

// The vDSO image (user/vdso), mapped into user address spaces.
.section .rodata.vdso, "a"
.balign 4096
.globl croi_vdso_start
croi_vdso_start:
    .incbin CROI_VDSO
.globl croi_vdso_end
croi_vdso_end:
