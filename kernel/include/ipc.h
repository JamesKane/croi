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
  // object_get_info topics.
  CROI_INFO_HANDLE_BASIC = 2,
};

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
