// Kernel stack geometry, shared by assembly and Swift (macros only).
//
// Every kernel stack is CROI_KERNEL_STACK_SIZE bytes, aligned to twice its
// size, with an unmapped guard page below. Bit CROI_KERNEL_STACK_SHIFT is
// therefore clear for every address on a valid stack and set just below
// one, which lets arm64/rv64 exception entry detect an overflowed stack
// from the stack pointer alone and switch to an emergency stack.

#pragma once

#define CROI_KERNEL_STACK_SHIFT 14
#define CROI_KERNEL_STACK_SIZE (1 << CROI_KERNEL_STACK_SHIFT)

// The start of every PerCpu record (the per-CPU register points at it):
// fields exception entry reads with nothing but that register.
#define CROI_PERCPU_EMERGENCY_STACK 0  // top of this CPU's emergency stack, or 0
#define CROI_PERCPU_SELF 8             // the record's own address (amd64: read via %gs)
#define CROI_PERCPU_KERNEL_SP 16       // the running thread's kernel stack top (user entry)
#define CROI_PERCPU_USER_SP 24         // scratch: the user sp at entry (amd64 syscall, rv64)
#define CROI_PERCPU_TSS 32             // amd64: this CPU's TSS (RSP0 at offset 4)

#ifndef __ASSEMBLER__
#include <stdint.h>

typedef struct {
  uint64_t emergency_stack_top;
  uint64_t self;  // set by arch_set_percpu
  uint64_t kernel_sp;
  uint64_t user_sp;
  uint64_t tss;
} croi_percpu_arch_t;
#endif
