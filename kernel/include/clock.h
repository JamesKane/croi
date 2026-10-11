// Clock objects (K13f, Zircon's ZX_OBJ_TYPE_CLOCK): the ABI shared by the
// kernel and user space (user/include/croi/syscall.h includes it).
//
// A clock is an affine function of a reference timeline, set and adjusted
// by its owner (clock_update) and read by anyone with READ: before its
// first update it reads its backstop. croi's one difference from Zircon:
// the reference "ticks" are monotonic nanoseconds (croi's counter-to-ns
// conversion is a 32.32 multiplier with no exact u32/u32 ratio), so
// reference_ticks_to_synthetic equals reference_to_synthetic and the
// details' *_ticks fields are nanoseconds. CROI_CLOCK_OPT_BOOT is accepted
// and is the monotonic timeline (croi doesn't suspend).
//
// A MAPPABLE clock's page (vmar_map_clock, read only) holds
// croi_clock_page_t at offset 0, Zircon's layout, under a seqlock: wait
// for `seq_lock` even, read, check it unchanged. Its value at reference
// time r (monotonic ns) is b_off + floor((r - a_off) * num / den) of
// reference_ticks_to_synthetic, saturating.
#pragma once
#include <stdint.h>

enum : uint64_t {
  CROI_OBJ_TYPE_CLOCK = 30,
  CROI_CLOCK_OPT_MONOTONIC = 1u << 0,
  CROI_CLOCK_OPT_CONTINUOUS = 1u << 1,
  CROI_CLOCK_OPT_AUTO_START = 1u << 2,
  CROI_CLOCK_OPT_BOOT = 1u << 3,
  CROI_CLOCK_OPT_MAPPABLE = 1u << 4,
  CROI_CLOCK_OPTS_ALL = 0x1F,
  CROI_CLOCK_ARGS_VERSION_SHIFT = 58,  // options bits 63:58: the args version
  CROI_CLOCK_UPDATE_OPTION_VALUE_VALID = 1u << 0,  // SYNTHETIC_VALUE_VALID
  CROI_CLOCK_UPDATE_OPTION_RATE_ADJUST_VALID = 1u << 1,
  CROI_CLOCK_UPDATE_OPTION_ERROR_BOUND_VALID = 1u << 2,
  CROI_CLOCK_UPDATE_OPTION_REFERENCE_VALUE_VALID = 1u << 3,  // v2 only
  CROI_CLOCK_UNKNOWN_ERROR = 0xFFFFFFFFFFFFFFFFull,
  CROI_CLOCK_STARTED = 1u << 4,  // signals
  CROI_CLOCK_UPDATED = 1u << 5,  // pulsed at every update
  CROI_PA_CLOCK_UTC = 0x40,
  CROI_INFO_CLOCK_MAPPED_SIZE = 40,
};

enum : int32_t {
  CROI_CLOCK_UPDATE_MIN_RATE_ADJUST = -1000,  // ppm
  CROI_CLOCK_UPDATE_MAX_RATE_ADJUST = 1000,
};

#define CROI_CLOCK_ARGS_VERSION(n) ((uint64_t)(n) << CROI_CLOCK_ARGS_VERSION_SHIFT)

typedef struct {
  int64_t backstop_time;
} croi_clock_create_args_v1_t;

typedef struct {
  uint32_t synthetic_ticks;
  uint32_t reference_ticks;
} croi_clock_rate_t;

typedef struct {
  int64_t reference_offset;
  int64_t synthetic_offset;
  croi_clock_rate_t rate;
} croi_clock_transformation_t;

typedef struct {
  uint64_t options;
  int64_t backstop_time;
  croi_clock_transformation_t reference_ticks_to_synthetic;
  croi_clock_transformation_t reference_to_synthetic;
  uint64_t error_bound;
  int64_t query_ticks;
  int64_t last_value_update_ticks;
  int64_t last_rate_adjust_update_ticks;
  int64_t last_error_bounds_update_ticks;
  uint32_t generation_counter;
  uint8_t padding1[4];
} croi_clock_details_v1_t;

typedef struct {
  int32_t rate_adjust;
  uint8_t padding1[4];
  int64_t value;
  uint64_t error_bound;
} croi_clock_update_args_v1_t;

typedef struct {
  int32_t rate_adjust;
  uint8_t padding1[4];
  int64_t synthetic_value;
  int64_t reference_value;
  uint64_t error_bound;
} croi_clock_update_args_v2_t;

// The mapped page (Zircon's ClockTransformation, 112 bytes at offset 0).
typedef struct {
  uint64_t options;
  int64_t backstop_time;
  uint32_t seq_lock;
  uint32_t padding0;
  croi_clock_transformation_t reference_ticks_to_synthetic;
  croi_clock_transformation_t reference_to_synthetic;
  uint64_t error_bound;
  int64_t last_value_update_ticks;
  int64_t last_rate_adjust_update_ticks;
  int64_t last_error_bounds_update_ticks;
  int32_t cur_ppm_adj;
  uint32_t padding1;
} croi_clock_page_t;
