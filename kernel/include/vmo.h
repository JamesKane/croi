// VMO operations for drivers (K9a): the ABI shared by the kernel and user
// space (user/include/croi/syscall.h includes it). Zircon's values
// (zircon/types.h).
#pragma once
#include <stdint.h>

enum : uint32_t {
  // vmo_op_range ops (croi has no pager or discardable VMOs: LOCK,
  // UNLOCK, TRY_LOCK, DONT_NEED, ALWAYS_NEED are NOT_SUPPORTED).
  CROI_VMO_OP_COMMIT = 1,
  CROI_VMO_OP_DECOMMIT = 2,
  CROI_VMO_OP_CACHE_SYNC = 6,
  CROI_VMO_OP_CACHE_INVALIDATE = 7,  // NOT_SUPPORTED (Zircon: only with debugging syscalls on)
  CROI_VMO_OP_CACHE_CLEAN = 8,
  CROI_VMO_OP_CACHE_CLEAN_INVALIDATE = 9,
  CROI_VMO_OP_ZERO = 10,
  CROI_VMO_OP_PREFETCH = 14,

  // vmo_set_cache_policy. UNCACHED and UNCACHED_DEVICE both map device
  // memory (arm64 Device-nGnRE, amd64 UC, rv64 Svpbmt IO).
  CROI_CACHE_POLICY_CACHED = 0,
  CROI_CACHE_POLICY_UNCACHED = 1,
  CROI_CACHE_POLICY_UNCACHED_DEVICE = 2,
  CROI_CACHE_POLICY_WRITE_COMBINING = 3,
  CROI_CACHE_POLICY_MASK = 3,

  // The vDSO's croi_cache_flush options.
  CROI_CACHE_FLUSH_INSN = 1u << 0,
  CROI_CACHE_FLUSH_DATA = 1u << 1,
  CROI_CACHE_FLUSH_INVALIDATE = 1u << 2,
};
