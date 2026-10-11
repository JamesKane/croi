// VMO operations for drivers (K9a): the ABI shared by the kernel and user
// space (user/include/croi/syscall.h includes it). Zircon's values
// (zircon/types.h).
#pragma once
#include <stdint.h>

enum : uint32_t {
  // vmo_op_range ops (croi has no pager or discardable VMOs: LOCK,
  // UNLOCK, TRY_LOCK, DONT_NEED, ALWAYS_NEED are NOT_SUPPORTED).
  // vmo_create_child options (Zircon's ZX_VMO_CHILD_*). K11a supports
  // SNAPSHOT_AT_LEAST_ON_WRITE (each page copied in at the child's first
  // touch of it) with or without NO_WRITE. K13a: SLICE (with NO_WRITE or
  // alone) of a physical or contiguous VMO: the same pages at an offset,
  // page aligned and wholly inside the parent (INVALID_ARGS otherwise),
  // with the parent's cache policy; a slice of a slice is one of the root.
  // Slices of anonymous VMOs are NOT_SUPPORTED yet (Zircon has them), as
  // are the other kinds. A VMO with children, or a slice, can't change its
  // cache policy (BAD_STATE).
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

