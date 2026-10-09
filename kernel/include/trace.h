// Kernel trace ABI (roadmap "Trace", the core of requirement 18; NeoVectra
// ADR-0049 is the model). The ring and record layouts are read by user
// space through a capability (K5), so they are C. The category mask is
// here too, defined in trace.c: a C object is initialized statically,
// while a Swift global atomic is initialized lazily and would add a guard
// to every probe. A disabled probe is one relaxed load and a branch.

#pragma once

#include <stdint.h>

// Categories (bits of the mask).
enum : uint32_t {
  CROI_TRACE_SCHED = 1u << 0,
  CROI_TRACE_IRQ = 1u << 1,
  CROI_TRACE_VM = 1u << 2,       // K4
  CROI_TRACE_IPC = 1u << 3,      // K7
  CROI_TRACE_FUTEX = 1u << 4,    // K7
  CROI_TRACE_SYSCALL = 1u << 5,  // K6
  CROI_TRACE_SAMPLE = 1u << 6,   // K6
  CROI_TRACE_MARK = 1u << 7,     // marks (user space from K6; kernel tests now)
};

// Record kinds. 0x0000-0x3fff are croi's (kernel categories); 0x4000-
// 0x7fff belong to user space (Todhchai's Trace module defines them, e.g.
// zones, flows, counters, names) so kernel and user rings merge into one
// timeline; 0x8000-0xffff are reserved.
//
// Threads are named `task << 12 | thread` (a process's id, and the
// thread's index in it): kernel threads are task 0, idle threads 0.
enum : uint16_t {
  CROI_TK_USER_FIRST = 0x4000,
  CROI_TK_USER_LAST = 0x7fff,

  CROI_TK_SWITCH = 1,   // thread: previous; a: next; b: previous state
  CROI_TK_WAKE = 2,     // thread: waker; a: woken; b: CPU it was queued on
  CROI_TK_BLOCK = 3,    // thread: blocker; a: timeout (ns, or ~0)
  CROI_TK_PREEMPT = 4,  // thread: preempted; a: reason (CROI_TRACE_PREEMPT_*)
  CROI_TK_MIGRATE = 5,  // a: thread; b: from << 32 | to
  CROI_TK_OVERRUN = 6,  // thread: overrunning; a: overruns so far
  CROI_TK_IRQ_ENTER = 16,  // a: vector / INTID / scause
  CROI_TK_IRQ_EXIT = 17,   // a: as for enter
  CROI_TK_MARK = 112,      // a, b: 16 bytes of the marker's choosing
};

enum : uint64_t {
  CROI_TRACE_PREEMPT_BUDGET = 1,    // a deadline thread's budget ran out
  CROI_TRACE_PREEMPT_DEADLINE = 2,  // an earlier deadline became runnable
  CROI_TRACE_PREEMPT_SLICE = 3,     // a fair slice ended with others waiting
  CROI_TRACE_PREEMPT_RESERVED = 4,  // its CPU was reserved away from it
};

// One record: 32 bytes. `time` is the raw counter (see the ring's
// frequency).
typedef struct {
  uint64_t time;
  uint16_t kind;
  uint16_t cpu;
  uint32_t thread;
  uint64_t a;
  uint64_t b;
} croi_trace_record_t;

enum : uint32_t {
  CROI_TRACE_ONESHOT = 0,   // stop recording when full; count drops
  CROI_TRACE_CIRCULAR = 1,  // overwrite the oldest
};

// A CPU's ring: this header page, then `capacity` records (a power of
// two). `head` counts records ever written: the newest is at
// (head - 1) & (capacity - 1). Only that CPU writes, with interrupts
// masked; a record is complete before `head` moves past it.
typedef struct {
  uint64_t head;
  uint64_t capacity;
  uint64_t drops;
  uint64_t first_drop;  // counter values of the first and last drop
  uint64_t last_drop;
  uint64_t frequency;   // counter Hz
  uint64_t session;     // bumped by every start
  uint32_t mode;
  uint32_t cpu;
} croi_trace_ring_t;

extern uint32_t croi_trace_mask;

static inline uint32_t croi_trace_categories(void) {
  return __atomic_load_n(&croi_trace_mask, __ATOMIC_RELAXED);
}

static inline uint32_t croi_trace_categories_ordered(void) {
  return __atomic_load_n(&croi_trace_mask, __ATOMIC_SEQ_CST);
}

static inline void croi_trace_set_categories(uint32_t mask) {
  __atomic_store_n(&croi_trace_mask, mask, __ATOMIC_SEQ_CST);
}
