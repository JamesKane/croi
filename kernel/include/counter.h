// Counters (K10a): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's counter object (type
// 34: counter_create, add, read, write; the POSITIVE / NON_POSITIVE
// signals; default rights BASIC | READ | WRITE | SIGNAL) plus croi's
// extension, Todhchai's item 15: waiting until a counter reaches a value.
//
// counter_wait(counter, value, deadline) blocks until the counter's value
// is at least `value` (signed), the deadline passes (TIMED_OUT), or the
// handle it waits through is closed (CANCELED). counter_wait_async(counter,
// port, key, value) queues one CROI_PKT_TYPE_COUNTER packet when it is (at
// once if it already is); port_cancel(port, counter, key) drops it. Both
// need WAIT and READ (the result reveals the value, as add's does). These
// are the desktop's acquire fences and release values, and Vulkan's
// timeline semaphores later: counters used that way only grow.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_COUNTER_POSITIVE = 1u << 4,      // value > 0
  CROI_COUNTER_NON_POSITIVE = 1u << 5,  // value <= 0

  // Port packet type: payload[0] the value waited for, [1] the counter's
  // value when it was reached, [2] the time (ns).
  CROI_PKT_TYPE_COUNTER = 0x82,
};
