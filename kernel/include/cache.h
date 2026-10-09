// Cache maintenance by virtual address (assembly, arch/<arch>/cpu.S), for
// VMO cache ops (non-coherent DMA). Addresses are kernel virtual (the
// physmap), so the ops reach the memory whatever user mappings exist.

#pragma once

#include <stdint.h>

enum : uint32_t {
  CROI_CACHE_CLEAN = 1,             // write dirty lines back
  CROI_CACHE_INVALIDATE = 2,        // drop lines (amd64: clean and drop)
  CROI_CACHE_CLEAN_INVALIDATE = 3,  // both
};

// Applies `op` to every `line`-byte line overlapping [addr, addr+size),
// with barriers before and after. `line` 0: no cache ops on this CPU (rv64
// without Zicbom: the platform must be coherent), so nothing is done.
void arch_cache_op(uint64_t addr, uint64_t size, uint32_t op, uint64_t line);

// The smallest data cache line (amd64 CPUID.1 CLFLUSH size; arm64
// CTR_EL0.DminLine; rv64 0: the RHCT says, see VmoCache).
uint64_t arch_cache_line(void);
