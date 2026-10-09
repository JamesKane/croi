// Kernel entry points shared between assembly, C and Swift. Functions marked
// "Swift" are implemented with `@c @implementation`, so the compiler checks
// them against these declarations.

#pragma once

// Swift (Kernel/Main.swift). Entered from arch/<arch>/start.S on the boot
// stack with the loader's handoff block, or null when there is none.
[[noreturn]] void kernel_main(const void *_Nullable handoff);

// Assembly (arch/<arch>/start.S). Masks interrupts and idles the CPU forever.
[[noreturn]] void arch_halt(void);
