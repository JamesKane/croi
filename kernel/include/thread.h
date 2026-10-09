// Context switching (assembly, arch/<arch>/thread.S), for Kernel/Sched/.
//
// A switched-out thread's kernel stack holds its callee-saved integer
// registers and return address; its Thread record holds only that stack
// pointer. Kernel threads never touch FP/SIMD state (user FP state is
// saved separately, roadmap K6).

#pragma once

#include <stdint.h>

// Saves this thread's callee-saved registers on its stack, stores the stack
// pointer in *old_sp, then resumes the thread whose saved pointer is new_sp.
// Returns when something switches back to this thread.
void arch_context_switch(uint64_t *_Nonnull old_sp, uint64_t new_sp);

// Builds a new thread's initial frame below stack_top so that switching to
// it starts kernel_thread_main(thread). Returns the stack pointer to save.
uint64_t arch_thread_prepare(uint64_t stack_top, uint64_t thread);

// Swift (Kernel/Sched/Thread.swift). A new thread's first code.
[[noreturn]] void kernel_thread_main(uint64_t thread);
