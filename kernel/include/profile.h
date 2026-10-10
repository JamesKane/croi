// Profile objects (K8c): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's zx_profile_info_t
// layout and flags; admission refusal reasons are croi's (ext 4).
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_PROFILE_INFO_FLAG_PRIORITY = 1u << 0,
  CROI_PROFILE_INFO_FLAG_CPU_MASK = 1u << 1,
  CROI_PROFILE_INFO_FLAG_DEADLINE = 1u << 2,

  CROI_PRIORITY_LOWEST = 0,
  CROI_PRIORITY_DEFAULT = 16,
  CROI_PRIORITY_HIGHEST = 31,

  // The system resource that gates profile_create (or the root resource).
  CROI_RSRC_SYSTEM_PROFILE_BASE = 10,

  // object_set_profile's refusal out-parameter, when admission refuses a
  // deadline profile (status NO_RESOURCES; INVALID_ARGS for parameters).
  CROI_ADMISSION_ACCEPTED = 0,
  CROI_ADMISSION_NO_ELIGIBLE_CPU = 1,  // the CPU mask leaves no usable CPU
  CROI_ADMISSION_CPU_OVERLOADED = 2,   // every eligible CPU is full (reason word: cpu << 8 | 2)
  CROI_ADMISSION_ACCOUNT_EXHAUSTED = 3,
};

// zx_sched_deadline_params_t: ns. 50 µs <= capacity <= relative_deadline
// <= period <= 10 s.
typedef struct {
  int64_t capacity;
  int64_t relative_deadline;
  int64_t period;
} croi_sched_deadline_params_t;

// zx_profile_info_t (96 bytes).
typedef struct {
  uint32_t flags;
  uint8_t padding1[4];
  union {
    struct {
      int32_t priority;
      uint8_t padding2[20];
    };
    croi_sched_deadline_params_t deadline_params;
  };
  uint64_t cpu_mask[8];  // zx_cpu_set_t: bit n is CPU n
} croi_profile_info_t;

static_assert(sizeof(croi_profile_info_t) == 96);
