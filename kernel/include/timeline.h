// The display timeline (K10b; Todhchai ext 1): the ABI shared by the
// kernel and user space (user/include/croi/syscall.h includes it). A croi
// object (type CROI_OBJ_TYPE_TIMELINE, outside Zircon's numbers) whose
// value counts vblanks.
//
// timeline_create(display system resource, options, period_ns, out): a
// display driver's. With CROI_TIMELINE_SYNTHETIC (the bare GOP framebuffer,
// no vblank interrupt) the kernel keeps it: its value is a function of the
// time (base_count + (now - base_time) / period), and the kernel fires a
// timer only for the earliest vblank something waits for, so a static
// screen costs no wakeups. Otherwise timeline_advance(timeline, timestamp)
// counts one vblank at the hardware's timestamp (BAD_STATE on a synthetic
// one). timeline_set_period changes the rate, keeping the count. Both
// need WRITE.
//
// Waiting is a counter's: counter_wait / counter_wait_async / counter_read
// take a timeline handle (WAIT and READ), so "the next vblank" is a wait
// for the current value + 1. timeline_get_page returns a read-only VMO of
// one croi_timeline_page_t, which clients map to know the vblank times
// without a syscall: read `sequence`, the fields, `sequence` again, and
// retry if it changed or is odd. On a synthetic timeline the vblank count
// at time t is base_count + (t - base_time) / period_ns; on a driven one,
// base_time is the last vblank's timestamp and base_count its number.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_OBJ_TYPE_TIMELINE = 48,
  CROI_TIMELINE_SYNTHETIC = 1u << 0,      // timeline_create option
  CROI_TIMELINE_PAGE_SYNTHESIZED = 1u << 0,  // croi_timeline_page_t.flags
  CROI_TIMELINE_PAGE_VERSION = 1,
};

typedef struct {
  uint64_t sequence;  // odd while the kernel writes
  uint32_t version;   // CROI_TIMELINE_PAGE_VERSION
  uint32_t flags;     // CROI_TIMELINE_PAGE_*
  uint64_t period_ns;
  int64_t base_count;
  uint64_t base_time_ns;  // monotonic
} croi_timeline_page_t;

static_assert(sizeof(croi_timeline_page_t) == 40);
