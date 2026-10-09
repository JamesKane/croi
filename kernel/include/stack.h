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
