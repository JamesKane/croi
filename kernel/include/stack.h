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

#ifndef __ASSEMBLER__
#include <stdint.h>

typedef struct {
  uint64_t emergency_stack_top;
  uint64_t self;  // set by arch_set_percpu
} croi_percpu_arch_t;
#endif
