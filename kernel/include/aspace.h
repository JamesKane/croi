// User address space primitives (assembly, arch/<arch>/cpu.S), for
// Kernel/Vm/UserAspace.swift.

#pragma once

#include <stdint.h>

// Makes `root` the user half's tables. amd64/rv64: `root` is a whole top-
// level table whose kernel half is the kernel's (shared entries); arm64:
// TTBR0 only. `asid` tags the entries (arm64, rv64); with `flush` the
// CPU's non-global entries are dropped as well (rv64 without ASIDs).
// amd64 has no ASIDs (yet): a CR3 load drops non-global entries.
void arch_switch_user_tables(uint64_t root, uint64_t asid, uint64_t flush);

// Drops the TLB entries tagged `asid`: arm64 on every CPU (broadcast),
// rv64 on this hart only (the caller reaches the others); amd64 nothing.
void arch_tlb_invalidate_asid(uint64_t asid);

// Brackets kernel accesses to user pages: amd64 stac/clac and arm64 PAN
// when croi_user_protection is set, rv64 sstatus.SUM.
void arch_user_access_begin(void);
void arch_user_access_end(void);

// Turns on this CPU's protection against the kernel touching (SMAP, PAN)
// or running (SMEP) user pages outside the accessors. Returns 1 if this
// CPU has it (amd64 SMAP / arm64 PAN; rv64 always: SUM is off by default).
uint64_t arch_user_protection_enable(void);

extern uint8_t croi_user_protection;

// How many ASID bits the MMU implements (amd64 0: no PCIDs used).
uint64_t arch_asid_bits(void);
