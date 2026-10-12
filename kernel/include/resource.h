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
  CROI_RSRC_SYSTEM_DISPLAY_BASE = 16,  // croi's: display timelines (K10b)
  CROI_RSRC_SYSTEM_MEMORY_BASE = 17,   // croi's: memory accounts (K15a, account.h)
  CROI_RSRC_SYSTEM_COUNT = 18,

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

// object_get_info(resource, CROI_INFO_CPU_STATS) (K10f): Zircon's
// zx_info_cpu_stats_t per CPU, on a handle to the INFO system resource (or
// root); the buffer holds as many as fit and the call returns how many it
// wrote (croi's object_get_info has no actual/avail pointers). croi fills
// cpu_number, flags (ONLINE), idle_time, context_switches, yields, ints
// (device and other interrupts), timer_ints, timers (callbacks run),
// syscalls, reschedule_ipis and generic_ipis; the rest are 0. On an idle
// machine every interrupt a CPU takes is a wakeup.
enum : uint32_t {
  CROI_INFO_CPU_STATS = 16u,
  CROI_INFO_CPU_STATS_FLAG_ONLINE = 1u << 0,
};

typedef struct {
  uint32_t cpu_number;
  uint32_t flags;
  int64_t idle_time;
  int64_t normalized_busy_time;
  uint64_t reschedules;
  uint64_t context_switches;
  uint64_t irq_preempts;
  uint64_t preempts;
  uint64_t yields;
  uint64_t ints;
  uint64_t timer_ints;
  uint64_t timers;
  uint64_t page_faults;
  uint64_t exceptions;
  uint64_t syscalls;
  uint64_t reschedule_ipis;
  uint64_t generic_ipis;
  uint64_t active_energy_consumption_nj;
  uint64_t idle_energy_consumption_nj;
} croi_info_cpu_stats_t;

static_assert(sizeof(croi_info_cpu_stats_t) == 144);

// object_get_info(resource, CROI_INFO_KMEM_STATS): Zircon's
// zx_info_kmem_stats_t, on a handle to the INFO system resource (or root).
// croi fills: total (RAM the PMM manages), free, wired (kernel image,
// boot allocations, pinned firmware memory), heap total and free,
// vmo, mmu_overhead (page tables), and other (allocated, untracked).
// K14a fills the reclaim and discardable fields (Vm/Reclaim.swift); the
// rest (loaned, ipc, cache, slab, zram, reclaim_disabled) are 0.
// _V1 is Zircon's zx_info_kmem_stats_v1_t.
enum : uint32_t {
  CROI_INFO_KMEM_STATS = 17u | (1u << 28),
  CROI_INFO_KMEM_STATS_V1 = 17u,
};

typedef struct {
  uint64_t total_bytes;
  uint64_t free_bytes;
  uint64_t free_loaned_bytes;
  uint64_t wired_bytes;
  uint64_t total_heap_bytes;
  uint64_t free_heap_bytes;
  uint64_t vmo_bytes;
  uint64_t mmu_overhead_bytes;
  uint64_t ipc_bytes;
  uint64_t cache_bytes;
  uint64_t slab_bytes;
  uint64_t zram_bytes;
  uint64_t other_bytes;
  uint64_t vmo_reclaim_total_bytes;
  uint64_t vmo_reclaim_newest_bytes;
  uint64_t vmo_reclaim_oldest_bytes;
  uint64_t vmo_reclaim_disabled_bytes;
  uint64_t vmo_discardable_locked_bytes;
  uint64_t vmo_discardable_unlocked_bytes;
} croi_info_kmem_stats_t;

typedef struct {
  uint64_t total_bytes;
  uint64_t free_bytes;
  uint64_t wired_bytes;
  uint64_t total_heap_bytes;
  uint64_t free_heap_bytes;
  uint64_t vmo_bytes;
  uint64_t mmu_overhead_bytes;
  uint64_t ipc_bytes;
  uint64_t other_bytes;
} croi_info_kmem_stats_v1_t;

static_assert(sizeof(croi_info_kmem_stats_t) == 152);
static_assert(sizeof(croi_info_kmem_stats_v1_t) == 72);

// smc_call (K13i; Zircon's zx_smc_call, arm64 only): an SMCCC call through
// the FADT's conduit (SMC or HVC) with an SMC resource covering the
// function ID (croi scopes SMC resources by function ID, Zircon by the
// 6-bit service call number). w0 = func_id, x1-x6 the arguments, w7 =
// secure_os_id << 16 | client_id; the result is x0-x3 and x6. PSCI calls
// that change CPU or system state are the kernel's (refused for every
// resource). NOT_SUPPORTED off arm64.
typedef struct {
  uint32_t func_id;
  uint8_t padding1[4];
  uint64_t arg1;
  uint64_t arg2;
  uint64_t arg3;
  uint64_t arg4;
  uint64_t arg5;
  uint64_t arg6;
  uint16_t client_id;
  uint16_t secure_os_id;
  uint8_t padding2[4];
} croi_smc_parameters_t;

typedef struct {
  uint64_t arg0;
  uint64_t arg1;
  uint64_t arg2;
  uint64_t arg3;
  uint64_t arg6;  // a session id, for some implementations
} croi_smc_result_t;

