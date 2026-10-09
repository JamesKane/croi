// Kernel access to user memory (assembly, arch/<arch>/usercopy.S): each
// access instruction is listed in the .croi_fixups table, so a fault on it
// that the VM can't resolve returns -1 instead of panicking (Zircon's user
// copy with fault recovery). Only these instructions may fault user pages
// in from the kernel. K6 grows them into user_copy.

#pragma once

#include <stdint.h>

// 0 and *out = the word at user address `addr`, or -1.
int arch_user_load_u64(uint64_t addr, uint64_t *_Nonnull out);
// 0 after storing `value` at user address `addr`, or -1.
int arch_user_store_u64(uint64_t addr, uint64_t value);

// The fixup table: pairs of 32-bit offsets, each from its own slot, to the
// faulting instruction and to where to resume.
typedef struct {
  int32_t instruction;
  int32_t recovery;
} croi_fixup_t;
extern const croi_fixup_t __fixups_start[];
extern const croi_fixup_t __fixups_end[];

// The table's bounds (Swift can't import arrays of unknown size).
static inline uint64_t croi_fixups_begin(void) { return (uint64_t)__fixups_start; }
static inline uint64_t croi_fixups_end(void) { return (uint64_t)__fixups_end; }
