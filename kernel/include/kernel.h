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

// Assembly (arch/<arch>/start.S). Switches to new kernel page tables and
// flushes the TLB. The kernel image must be mapped identically in the old
// and new tables. amd64/rv64 use `root`; arm64 loads `root` into TTBR0 and
// `root_high` into TTBR1.
void arch_load_page_tables(uint64_t root, uint64_t root_high);

#if defined(__aarch64__)
// Assembly (arch/arm64/start.S). The current exception level.
uint64_t arch_current_el(void);
#endif

#if defined(__x86_64__)
// Assembly (arch/amd64/start.S). Port I/O, which Swift cannot express.
uint8_t arch_inb(uint16_t port);
void arch_outb(uint16_t port, uint8_t value);
#endif

// Kernel image segment bounds (virtual), from ld/image.ld. Inline C because
// Swift cannot take the address of a linker-defined symbol.
#define CROI_IMAGE_SYMBOL(name)                                    \
  static inline uint64_t kernel_##name(void) {                    \
    extern const char __##name[] __attribute__((visibility("hidden"))); \
    return (uint64_t)(uintptr_t)__##name;                         \
  }
CROI_IMAGE_SYMBOL(image_start)
CROI_IMAGE_SYMBOL(text_end)
CROI_IMAGE_SYMBOL(rodata_start)
CROI_IMAGE_SYMBOL(rodata_end)
CROI_IMAGE_SYMBOL(data_start)
CROI_IMAGE_SYMBOL(image_end)
#undef CROI_IMAGE_SYMBOL
