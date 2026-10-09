// Kernel entry points shared between assembly, C and Swift. Functions marked
// "Swift" are implemented with `@c @implementation`, so the compiler checks
// them against these declarations.

#pragma once

#include <stdint.h>

// Swift (Kernel/Main.swift). Entered from arch/<arch>/start.S on the boot
// stack with the physical address of the loader's croi_handoff_t (see
// lib/handoff), identity mapped.
[[noreturn]] void kernel_main(uint64_t handoff);

// Assembly (arch/<arch>/start.S). Masks interrupts and idles the CPU forever.
[[noreturn]] void arch_halt(void);

#if defined(__aarch64__)
// Assembly (arch/arm64/start.S). The current exception level.
uint64_t arch_current_el(void);
#endif

#if defined(__x86_64__)
// Assembly (arch/amd64/start.S). Port I/O, which Swift cannot express.
uint8_t arch_inb(uint16_t port);
void arch_outb(uint16_t port, uint8_t value);
#endif
