// Channels, eventpairs and object info: the ABI shared by the kernel and
// user space (user/include/croi/syscall.h includes it). Zircon's layouts.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_CHANNEL_MAX_BYTES = 65536,
  CROI_CHANNEL_MAX_HANDLES = 64,
  // Signals (Zircon's ZX_CHANNEL_* / ZX_EVENTPAIR_PEER_CLOSED).
  CROI_SIGNAL_READABLE = 1u << 0,
  CROI_SIGNAL_WRITABLE = 1u << 1,
  CROI_SIGNAL_PEER_CLOSED = 1u << 2,
  CROI_SIGNAL_SIGNALED = 1u << 3,  // events, timers (ZX_EVENT_SIGNALED)
  // object_get_info topics.
  CROI_INFO_HANDLE_BASIC = 2,
  CROI_INFO_VMAR = 7,  // croi_info_vmar_t (needs INSPECT)
  // croi_info_handle_count_t (needs INSPECT, K13a): handles to the object
  // in every handle table and in channel messages in flight. A mapping
  // keeps a VMO alive without a handle: see vmo.h's ZERO_CHILDREN.
  CROI_INFO_HANDLE_COUNT = 19,
};

// zx_info_handle_count_t.
typedef struct {
  uint32_t handle_count;
} croi_info_handle_count_t;

// Sockets (K13c, Zircon's): create options, read options, dispositions,
// signals beyond READABLE/WRITABLE/PEER_CLOSED, threshold properties, info.
enum : uint32_t {
  CROI_SOCKET_STREAM = 0,
  CROI_SOCKET_DATAGRAM = 1u << 0,
  CROI_SOCKET_PEEK = 1u << 3,
  CROI_SOCKET_DISPOSITION_WRITE_DISABLED = 1u << 0,
  CROI_SOCKET_DISPOSITION_WRITE_ENABLED = 1u << 1,
  CROI_SOCKET_PEER_WRITE_DISABLED = 1u << 4,
  CROI_SOCKET_WRITE_DISABLED = 1u << 5,
  CROI_SOCKET_READ_THRESHOLD = 1u << 10,
  CROI_SOCKET_WRITE_THRESHOLD = 1u << 11,
  CROI_PROP_SOCKET_RX_THRESHOLD = 12,  // size_t
  CROI_PROP_SOCKET_TX_THRESHOLD = 13,
  CROI_INFO_SOCKET = 22,               // croi_info_socket_t (INSPECT)
};

// zx_info_socket_t.
typedef struct {
  uint32_t options;
  uint8_t padding[4];
  uint64_t rx_buf_max;
  uint64_t rx_buf_size;
  uint64_t rx_buf_available;
  uint64_t tx_buf_max;
  uint64_t tx_buf_size;
} croi_info_socket_t;

// zx_info_vmar_t.
typedef struct {
  uint64_t base;
  uint64_t len;
} croi_info_vmar_t;

// zx_channel_call_args_t.
typedef struct {
  uint64_t wr_bytes;    // const void *
  uint64_t wr_handles;  // const uint32_t *
  uint64_t rd_bytes;    // void *
  uint64_t rd_handles;  // uint32_t *
  uint32_t wr_num_bytes;
  uint32_t wr_num_handles;
  uint32_t rd_num_bytes;
  uint32_t rd_num_handles;
} croi_channel_call_args_t;

// The channel *_etc calls (K13e, Zircon's): handle dispositions written,
// handle infos read; channel_read(_etc)'s MAY_DISCARD.
enum : uint32_t {
  CROI_HANDLE_OP_MOVE = 0,
  CROI_HANDLE_OP_DUPLICATE = 1,
  CROI_CHANNEL_READ_MAY_DISCARD = 1,
  CROI_WAIT_MANY_MAX_ITEMS = 64,
};

// zx_handle_disposition_t (20 bytes).
typedef struct {
  uint32_t operation;
  uint32_t handle;
  uint32_t type;     // 0: any
  uint32_t rights;   // or CROI_RIGHT_SAME_RIGHTS
  int32_t result;    // written back for entries that failed
} croi_handle_disposition_t;

// zx_handle_info_t.
typedef struct {
  uint32_t handle;
  uint32_t type;
  uint32_t rights;
  uint32_t unused;
} croi_handle_info_t;

// zx_channel_call_etc_args_t.
typedef struct {
  uint64_t wr_bytes;    // const void *
  uint64_t wr_handles;  // croi_handle_disposition_t *
  uint64_t rd_bytes;    // void *
  uint64_t rd_handles;  // croi_handle_info_t *
  uint32_t wr_num_bytes;
  uint32_t wr_num_handles;
  uint32_t rd_num_bytes;
  uint32_t rd_num_handles;
} croi_channel_call_etc_args_t;

// zx_wait_item_t.
typedef struct {
  uint32_t handle;
  uint32_t waitfor;
  uint32_t pending;
} croi_wait_item_t;

// zx_info_handle_basic_t.
typedef struct {
  uint64_t koid;
  uint32_t rights;
  uint32_t type;
  uint64_t related_koid;  // the peer's, for channels and eventpairs
  uint32_t reserved[2];
} croi_info_handle_basic_t;

// The flow id of a channel message (trace records, K7b): both ends compute
// it from what they share, the channel's id (the smaller of its two
// endpoints' koids, from CROI_INFO_HANDLE_BASIC) and the message's txid
// (its first four bytes), so a call and its reply share one flow and
// nothing extra is sent. splitmix64's finalizer over channel * golden
// ratio + txid.
static inline uint64_t croi_flow_id(uint64_t channel, uint32_t txid) {
  uint64_t z = channel * 0x9E3779B97F4A7C15ull + txid;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}
