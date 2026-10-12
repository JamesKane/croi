// Profile objects (K8c): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's zx_profile_info_t
// layout and flags; admission refusal reasons are croi's (ext 4).
#pragma once
#include <stdint.h>
#include "resource.h"  // CROI_RSRC_SYSTEM_PROFILE_BASE gates profile_create

enum : uint32_t {
  CROI_PROFILE_INFO_FLAG_PRIORITY = 1u << 0,
  CROI_PROFILE_INFO_FLAG_CPU_MASK = 1u << 1,
  CROI_PROFILE_INFO_FLAG_DEADLINE = 1u << 2,

  CROI_PRIORITY_LOWEST = 0,
  CROI_PRIORITY_DEFAULT = 16,
  CROI_PRIORITY_HIGHEST = 31,

  // object_set_profile's refusal out-parameter, when admission refuses a
  // deadline profile (status NO_RESOURCES; INVALID_ARGS for parameters).
  CROI_ADMISSION_ACCEPTED = 0,
  CROI_ADMISSION_NO_ELIGIBLE_CPU = 1,  // the CPU mask leaves no usable CPU
  CROI_ADMISSION_CPU_OVERLOADED = 2,   // every eligible CPU is full (reason word: cpu << 8 | 2)
  CROI_ADMISSION_ACCOUNT_EXHAUSTED = 3,

  // object_set_profile options (croi's, K10c): with a deadline profile on
  // a thread, its periods start on a display timeline's vblanks (ext 10);
  // the timeline's handle (READ) is the fifth argument.
  CROI_PROFILE_ALIGN_TIMELINE = 1u << 0,
  // With a deadline profile on an interrupt object (ext 5, K14e): admit
  // it as a scheduling context the object owns (refused with a reason as
  // for threads) and hand that to the interrupt_wait thread it wakes.
  CROI_PROFILE_HANDOFF = 1u << 1,
};

// object_set_profile(target, profile, options, refusal, timeline) also
// takes an interrupt, counter or display timeline as its target (WRITE
// right; a deadline profile): the object then lends that deadline to each
// thread it wakes directly (interrupt_wait, counter_wait): the thread runs
// on it from its wakeup, with a period starting there, until it next
// blocks (ext 5, as channel_call donation). No admission: the lent
// deadline joins the thread's own as inheritance does.
//
// With CROI_PROFILE_HANDOFF, an interrupt object instead owns an admitted
// context: the thread interrupt_wait wakes runs on it at once (on its
// CPU, with its deadline) until it blocks again, and every wakeup shares
// the context's budget for its period (the CBS rule at each). A thread
// that spends it has an overrun counted on the context
// (thread_bind_overrun_port on the interrupt reports them) and carries on
// on its own profile; a wakeup while it is spent wakes the thread on its
// own. A lend replaces a handoff and vice versa.

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

// thread_bind_overrun_port(thread, port, key) (croi's, K10d, ext 3):
// MANAGE_THREAD on a thread with a deadline profile of its own (from
// object_set_profile; else BAD_STATE), WRITE on the port. Each period the
// thread's budget runs out before it yields, the port gets one coalescing
// packet: payload[1] the context's total overruns, payload[2] how many
// since the packet was last read. Binding again replaces the port.
enum : uint32_t {
  CROI_PKT_TYPE_BUDGET_OVERRUN = 0x80,
};
