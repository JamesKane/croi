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

// Orders earlier stores to normal memory before later stores to device
// registers (arm64 dsb st, rv64 fence w,o, amd64 nothing): an IOMMU's
// tables before the register write that makes it walk them.
void arch_device_write_barrier(void);

// The smallest data cache line (amd64 CPUID.1 CLFLUSH size; arm64
// CTR_EL0.DminLine; rv64 0: the RHCT says, see VmoCache).
uint64_t arch_cache_line(void);

// The smallest instruction cache line where user code must sync the
// I-cache by line (arm64 CTR_EL0.IminLine), else 0.
uint64_t arch_icache_line(void);

// Makes code written at [addr, addr+size) (kernel virtual) visible to
// instruction fetch: arm64 dc cvau + ic ivau by line (broadcast), rv64
// fence.i on this hart only, amd64 nothing.
void arch_sync_icache(uint64_t addr, uint64_t size, uint64_t dline, uint64_t iline);
