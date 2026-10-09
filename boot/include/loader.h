// C-visible entry points of the loader: the Swift loader body (implemented
// with `@c @implementation`) and the per-arch assembly in arch/<arch>/.

#pragma once

#include "efi.h"

// Loader body (Loader/Main.swift), called by efi_main in entry.c.
EFI_STATUS croi_loader_main(EFI_HANDLE _Nullable image, EFI_SYSTEM_TABLE *_Nonnull system_table);

// Switch to the boot page tables and jump to the kernel entry point with the
// handoff's physical address as its first argument. Interrupts are masked.
//   amd64: root = PML4. arm64: root = TTBR0 (low half), root_high = TTBR1
//   (high half). rv64: root = Sv39 root table.
// Must be called after ExitBootServices, from identity-mapped code.
[[noreturn]] void croi_arch_enter_kernel(uint64_t root, uint64_t root_high, uint64_t entry, uint64_t handoff);

// Nonzero if the CPU state the firmware left is one the loader can't hand
// off from (5-level paging on amd64; EL3 on arm64, where EL2 is dropped
// from in croi_arch_enter_kernel). Codes are per arch.
uint64_t croi_arch_unsupported(void);

// Clean and invalidate data cache lines covering [addr, addr+size) to the
// point of coherency. No-op where caches are coherent with page walks/fetch.
void croi_arch_clean_dcache(uint64_t addr, uint64_t size);
