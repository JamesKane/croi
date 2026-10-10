// User mode entry and exit (assembly, arch/<arch>/exceptions.S and
// usercopy.S), for Kernel/User/. A user thread's registers live in an
// arch_exception_frame_t at the top of its kernel stack whenever it is in
// the kernel; returning to user mode restores them from there.

#pragma once

#include <stdint.h>
#include "kernel.h"

// Drops to user mode at `pc` with stack `sp` and `arg0`/`arg1` in the first
// two argument registers, every other register zero. The kernel stack is
// reset to `kernel_top` (whatever was on it is gone). Never returns: the
// thread comes back only through traps, interrupts and syscalls.
[[noreturn]] void arch_enter_user(uint64_t pc, uint64_t sp, uint64_t arg0, uint64_t arg1, uint64_t arg2,
                                  uint64_t kernel_top);

// Byte copies between kernel and user memory with fault recovery: 0, or
// -1 if a user page couldn't be reached (see usercopy.h's fixups).
int arch_copy_from_user(void *_Nonnull dst, uint64_t src, uint64_t len);
int arch_copy_to_user(uint64_t dst, const void *_Nonnull src, uint64_t len);

// The built-in user test program (position independent), for the boot
// self-test: copied into a VMO and run in user mode.
extern const uint8_t croi_user_test_start[];
extern const uint8_t croi_user_test_end[];
static inline uint64_t croi_user_test_address(void) { return (uint64_t)croi_user_test_start; }
static inline uint64_t croi_user_test_size(void) { return (uint64_t)(croi_user_test_end - croi_user_test_start); }

// The K6b self-test's C program (user/test), a flat binary linked to run
// at UserSelfTest.codeAt.
extern const uint8_t croi_user_program_start[];
extern const uint8_t croi_user_program_end[];
static inline uint64_t croi_user_program_address(void) { return (uint64_t)croi_user_program_start; }
static inline uint64_t croi_user_program_size(void) {
  return (uint64_t)(croi_user_program_end - croi_user_program_start);
}

// The vDSO image (user/vdso): header (shared.h) and code.
extern const uint8_t croi_vdso_start[];
extern const uint8_t croi_vdso_end[];
static inline uint64_t croi_vdso_address(void) { return (uint64_t)croi_vdso_start; }
static inline uint64_t croi_vdso_size(void) { return (uint64_t)(croi_vdso_end - croi_vdso_start); }

#if defined(__x86_64__)
// SYSCALL setup on this CPU: EFER.SCE, STAR, LSTAR, FMASK.
void arch_syscall_init(void);
// Swift (Kernel/User/Syscalls.swift): the SYSCALL entry's handler.
void arch_syscall(arch_exception_frame_t *_Nonnull frame);
#endif
