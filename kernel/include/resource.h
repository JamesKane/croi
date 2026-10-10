// Resources (K9a): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's kinds, flags, system
// bases and zx_info_resource_t (zircon/syscalls/resource.h, object.h).
#pragma once
#include <stdint.h>

enum : uint32_t {
  // Kinds (resource_create's options, low 16 bits).
  CROI_RSRC_KIND_MMIO = 0,
  CROI_RSRC_KIND_IRQ = 1,
  CROI_RSRC_KIND_IOPORT = 2,   // amd64 only
  CROI_RSRC_KIND_ROOT = 3,     // the root resource (Zircon's retired kind 3): every kind's ranged root
  CROI_RSRC_KIND_SMC = 4,      // arm64 only: SMCCC function IDs (croi scopes by function-ID range)
  CROI_RSRC_KIND_SYSTEM = 5,
  CROI_RSRC_KIND_COUNT = 6,
  // Flags (resource_create's options, high 16 bits).
  CROI_RSRC_FLAG_EXCLUSIVE = 0x00010000,
  CROI_RSRC_FLAGS_MASK = 0x00010000,

  // System resources (kind SYSTEM, size 1, at these bases).
  CROI_RSRC_SYSTEM_HYPERVISOR_BASE = 0,
  CROI_RSRC_SYSTEM_VMEX_BASE = 1,
  CROI_RSRC_SYSTEM_DEBUG_BASE = 2,
  CROI_RSRC_SYSTEM_INFO_BASE = 3,
  CROI_RSRC_SYSTEM_CPU_BASE = 4,
  CROI_RSRC_SYSTEM_POWER_BASE = 5,
  CROI_RSRC_SYSTEM_MEXEC_BASE = 6,
  CROI_RSRC_SYSTEM_ENERGY_INFO_BASE = 7,
  CROI_RSRC_SYSTEM_IOMMU_BASE = 8,
  CROI_RSRC_SYSTEM_PROFILE_BASE = 10,
  CROI_RSRC_SYSTEM_MSI_BASE = 11,
  CROI_RSRC_SYSTEM_DEBUGLOG_BASE = 12,
  CROI_RSRC_SYSTEM_STALL_BASE = 13,
  CROI_RSRC_SYSTEM_TRACING_BASE = 14,
  CROI_RSRC_SYSTEM_SAMPLING_BASE = 15,
  CROI_RSRC_SYSTEM_COUNT = 16,

  // object_get_info topic.
  CROI_INFO_RESOURCE = 18,
  CROI_MAX_NAME_LEN = 32,
};

// zx_info_resource_t.
typedef struct {
  uint32_t kind;
  uint32_t flags;
  uint64_t base;
  uint64_t size;  // 0 for a kind's ranged root
  char name[32];
} croi_info_resource_t;

static_assert(sizeof(croi_info_resource_t) == 56);
