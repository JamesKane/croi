// VMO operations for drivers (K9a): the ABI shared by the kernel and user
// space (user/include/croi/syscall.h includes it). Zircon's values
// (zircon/types.h).
#pragma once
#include <stdint.h>

enum : uint32_t {
  // vmo_op_range ops (Zircon's values; LOCK, UNLOCK, TRY_LOCK and the
  // DONT_NEED / ALWAYS_NEED hints with K14a's reclamation, below).
  // vmo_create_child options (Zircon's ZX_VMO_CHILD_*). K11a supports
  // SNAPSHOT_AT_LEAST_ON_WRITE (each page copied in at the child's first
  // touch of it) with or without NO_WRITE. K13a: SLICE (with NO_WRITE or
  // alone) of a physical or contiguous VMO: the same pages at an offset,
  // page aligned and wholly inside the parent (INVALID_ARGS otherwise),
  // with the parent's cache policy; a slice of a slice is one of the root.
  // K14g: the rest, in Zircon's order of checks: SNAPSHOT (isolated both
  // ways; not under a pager), SNAPSHOT_MODIFIED, SLICE of an anonymous VMO
  // (not a resizable one) and REFERENCE (offset and size 0; RESIZABLE only
  // of a resizable VMO, with RESIZE on the handle). A VMO with children, or
  // a slice or reference, can't change its cache policy (BAD_STATE).
  CROI_VMO_CHILD_SNAPSHOT = 1u << 0,
  CROI_VMO_CHILD_RESIZABLE = 1u << 2,
  CROI_VMO_CHILD_SLICE = 1u << 3,
  CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE = 1u << 4,
  CROI_VMO_CHILD_NO_WRITE = 1u << 5,
  CROI_VMO_CHILD_REFERENCE = 1u << 6,
  CROI_VMO_CHILD_SNAPSHOT_MODIFIED = 1u << 7,
  // VMO signal (K13a, Zircon's): no children. Asserted from creation; a
  // child clears it; set again once the last child is gone, which is after
  // its last handle and its last mapping.
  CROI_VMO_ZERO_CHILDREN = 1u << 3,

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

// Streams (K13c, Zircon's): stream_create modes, writev's option, seek
// origins, properties, info; zx_iovec_t.
enum : uint32_t {
  CROI_STREAM_MODE_READ = 1u << 0,
  CROI_STREAM_MODE_WRITE = 1u << 1,
  CROI_STREAM_MODE_APPEND = 1u << 2,
  CROI_STREAM_APPEND = 1u << 0,
  CROI_STREAM_SEEK_ORIGIN_START = 0,
  CROI_STREAM_SEEK_ORIGIN_CURRENT = 1,
  CROI_STREAM_SEEK_ORIGIN_END = 2,
  CROI_PROP_VMO_CONTENT_SIZE = 17,   // uint64_t: the stream size
  CROI_PROP_STREAM_MODE_APPEND = 19, // uint8_t
  CROI_INFO_STREAM = 26,             // croi_info_stream_t (INSPECT)
};

typedef struct {
  void *buffer;
  uint64_t capacity;  // size_t
} croi_iovec_t;

// zx_info_stream_t.
typedef struct {
  uint32_t options;
  uint8_t padding[4];
  uint64_t seek;
  uint64_t content_size;
} croi_info_stream_t;

// The user pager (K13d, Zircon's): pager_create_vmo options, page request
// packets (type 9: payload command | flags << 16, offset, length),
// pager_op_range ops, query structures.
enum : uint32_t {
  CROI_VMO_RESIZABLE = 1u << 1,
  CROI_VMO_DISCARDABLE = 1u << 2,
  CROI_VMO_TRAP_DIRTY = 1u << 3,
  CROI_VMO_UNBOUNDED = 1u << 4,
  CROI_PKT_TYPE_PAGE_REQUEST = 9,
  CROI_PAGER_VMO_READ = 0,
  CROI_PAGER_VMO_COMPLETE = 1,
  CROI_PAGER_VMO_DIRTY = 2,
  CROI_PAGER_OP_FAIL = 1,
  CROI_PAGER_OP_DIRTY = 2,
  CROI_PAGER_OP_WRITEBACK_BEGIN = 3,
  CROI_PAGER_OP_WRITEBACK_END = 4,
  CROI_VMO_DIRTY_RANGE_IS_ZERO = 1,
  CROI_PAGER_VMO_STATS_MODIFIED = 1,
  CROI_PAGER_RESET_VMO_STATS = 1,
};

// zx_vmo_dirty_range_t.
typedef struct {
  uint64_t offset;
  uint64_t length;
  uint64_t options;
} croi_vmo_dirty_range_t;

// zx_pager_vmo_stats_t.
typedef struct {
  uint32_t modified;
} croi_pager_vmo_stats_t;

// zx_info_vmo_t (ZX_INFO_VMO, ZX_INFO_PROCESS_VMOS; K13e). Flags as
// Zircon's: TYPE_PAGED 1 (physical: 0), RESIZABLE 2, IS_COW_CLONE 4,
// VIA_HANDLE 8, VIA_MAPPING 0x10, PAGER_BACKED 0x20, CONTIGUOUS 0x40.
// cache_policy: CROI_CACHE_POLICY_*.
enum : uint32_t {
  CROI_INFO_VMO_TYPE_PAGED = 1u << 0,
  CROI_INFO_VMO_RESIZABLE = 1u << 1,
  CROI_INFO_VMO_IS_COW_CLONE = 1u << 2,
  CROI_INFO_VMO_VIA_HANDLE = 1u << 3,
  CROI_INFO_VMO_VIA_MAPPING = 1u << 4,
  CROI_INFO_VMO_PAGER_BACKED = 1u << 5,
  CROI_INFO_VMO_CONTIGUOUS = 1u << 6,
  CROI_INFO_VMO_DISCARDABLE = 1u << 7,  // K14a
};

typedef struct {
  uint64_t koid;
  char name[32];
  uint64_t size_bytes;
  uint64_t parent_koid;
  uint64_t num_children;
  uint64_t num_mappings;
  uint64_t share_count;
  uint32_t flags;
  uint8_t padding1[4];
  uint64_t committed_bytes;
  uint32_t handle_rights;
  uint32_t cache_policy;
  uint64_t metadata_bytes;
  uint64_t committed_change_events;
  uint64_t populated_bytes;
  uint64_t committed_private_bytes;
  uint64_t populated_private_bytes;
  uint64_t committed_scaled_bytes;
  uint64_t populated_scaled_bytes;
  uint64_t committed_fractional_scaled_bytes;
  uint64_t populated_fractional_scaled_bytes;
} croi_info_vmo_t;

// vmar_op_range ops (K13e, Zircon's values).
enum : uint32_t {
  CROI_VMAR_OP_COMMIT = 1,
  CROI_VMAR_OP_DECOMMIT = 2,
  CROI_VMAR_OP_MAP_RANGE = 3,
  CROI_VMAR_OP_ZERO = 10,
  CROI_VMAR_OP_DONT_NEED = 12,
  CROI_VMAR_OP_ALWAYS_NEED = 13,
  CROI_VMAR_OP_PREFETCH = 14,
};

// Resizable VMOs (K13h): vmo_create's options, the RESIZE right (only a
// resizable VMO's handles get it), and the info flag
// (CROI_INFO_VMO_RESIZABLE above).
enum : uint32_t {
  CROI_VMO_CREATE_RESIZABLE = 1u << 1,  // = CROI_VMO_RESIZABLE
  CROI_VMO_CREATE_UNBOUNDED = 1u << 4,  // K14i: Zircon's MAX_SIZE, content size = size (with RESIZABLE: INVALID_ARGS)
  CROI_RIGHT_RESIZE = 1u << 22,
};

// Reclamation (K14a, Zircon's): DISCARDABLE VMOs (vmo_create option; whole
// VMO LOCK / TRY_LOCK / UNLOCK through vmo_op_range, needing READ or WRITE;
// LOCK writes a croi_vmo_lock_state_t whose discarded_size is the VMO's
// size if it had been discarded, else 0; a discarded VMO's pages are gone
// and every access fails NOT_FOUND until the next LOCK), the eviction
// hints DONT_NEED / ALWAYS_NEED (pager VMOs; no rights needed; ignored
// elsewhere), and the memory-pressure events of system_get_event (root
// job; OUT_OF_MEMORY needs MANAGE_PROCESS; one level signaled at a time).
enum : uint32_t {
  CROI_VMO_CREATE_DISCARDABLE = 1u << 2,
  CROI_VMO_OP_LOCK = 3,
  CROI_VMO_OP_UNLOCK = 4,
  CROI_VMO_OP_TRY_LOCK = 11,
  CROI_VMO_OP_DONT_NEED = 12,
  CROI_VMO_OP_ALWAYS_NEED = 13,
  CROI_SYSTEM_EVENT_OUT_OF_MEMORY = 1,
  CROI_SYSTEM_EVENT_MEMORY_PRESSURE_CRITICAL = 2,
  CROI_SYSTEM_EVENT_MEMORY_PRESSURE_WARNING = 3,
  CROI_SYSTEM_EVENT_MEMORY_PRESSURE_NORMAL = 4,
  CROI_SYSTEM_EVENT_IMMINENT_OUT_OF_MEMORY = 5,
};

typedef struct {
  uint64_t offset;
  uint64_t size;
  uint64_t discarded_offset;
  uint64_t discarded_size;
} croi_vmo_lock_state_t;
