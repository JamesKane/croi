// croi system calls, as user code makes them (K6b; the vDSO wraps them in
// K6c). Numbers are croi's own; status codes, rights, signals and packets
// follow Zircon's values. Arguments in the ABI's first six integer
// argument registers (amd64: rdi rsi rdx r10 r8 r9), number in rax / x16 /
// a7, result (a status, or a value) in rax / x0 / a0.

#pragma once

#include <stdint.h>

enum : uint64_t {
  CROI_SYS_NULL = 0,
  CROI_SYS_DEBUG_WRITE = 1,        // (const char *text, size_t length)
  CROI_SYS_THREAD_EXIT = 2,        // (int64_t code): the calling thread
  CROI_SYS_CLOCK_MONOTONIC = 3,    // () -> ns
  CROI_SYS_NANOSLEEP = 4,          // (deadline ns)
  CROI_SYS_TEST_REPORT = 5,        // (value) for the boot self-test
  CROI_SYS_HANDLE_CLOSE = 10,      // (handle)
  CROI_SYS_HANDLE_DUPLICATE = 11,  // (handle, rights, uint32_t *out)
  CROI_SYS_HANDLE_REPLACE = 12,    // (handle, rights, uint32_t *out)
  CROI_SYS_OBJECT_SIGNAL = 20,     // (handle, clear, set)
  CROI_SYS_OBJECT_WAIT_ONE = 21,   // (handle, signals, deadline, uint32_t *observed)
  CROI_SYS_OBJECT_WAIT_ASYNC = 22, // (handle, port, key, signals, options)
  CROI_SYS_EVENT_CREATE = 30,      // (options, uint32_t *out)
  CROI_SYS_PORT_CREATE = 31,       // (options, uint32_t *out)
  CROI_SYS_PORT_QUEUE = 32,        // (port, const croi_port_packet_t *packet)
  CROI_SYS_PORT_WAIT = 33,         // (port, deadline, croi_port_packet_t *packet)
  CROI_SYS_PORT_CANCEL = 34,       // (port, source handle, key)
  CROI_SYS_VMO_CREATE = 40,        // (size, options, uint32_t *out)
  CROI_SYS_VMO_READ = 41,          // (vmo, void *buffer, offset, length)
  CROI_SYS_VMO_WRITE = 42,         // (vmo, const void *buffer, offset, length)
  CROI_SYS_VMO_MAP = 43,           // (vmo, offset, length, rights bits, uint64_t *address); until VMARs (K7)
  CROI_SYS_VMO_GET_SIZE = 44,      // (vmo, uint64_t *size)
  // VMOs for drivers (K9a): Zircon's calls, values in vmo.h.
  CROI_SYS_VMO_OP_RANGE = 45,      // (vmo, op, offset, size, buffer, buffer_size)
  CROI_SYS_VMO_SET_CACHE_POLICY = 46,  // (vmo, policy)
  CROI_SYS_VMO_CREATE_PHYSICAL = 47,   // (MMIO resource, paddr, size, uint32_t *out)
  CROI_SYS_VMO_CREATE_CHILD = 48,      // (vmo, options, offset, size, uint32_t *out), K11a
  CROI_SYS_TRACE_CONFIGURE = 50,   // (resource, op, a, b, c, sample_hz)
  CROI_SYS_PMU_CONFIGURE = 51,     // (resource, op, a, b)
  // Jobs, processes, threads (K7a). Zircon's calls; vmar_* pack the VMAR
  // handle and options into the first argument (handle | options << 32).
  CROI_SYS_JOB_CREATE = 60,        // (parent, options, out)
  CROI_SYS_PROCESS_CREATE = 61,    // (job, name, name_len, options, out_process, out_vmar)
  CROI_SYS_PROCESS_START = 62,     // (process, thread, entry, stack, arg1 handle, arg2)
  CROI_SYS_PROCESS_EXIT = 63,      // (code)
  CROI_SYS_THREAD_CREATE = 64,     // (process, name, name_len, options, out)
  CROI_SYS_THREAD_START = 65,      // (thread, entry, stack, arg1, arg2)
  CROI_SYS_TASK_KILL = 67,         // (task)
  CROI_SYS_PROCESS_INFO = 68,      // (process, croi_process_info_t out)
  CROI_SYS_VMAR_ALLOCATE = 70,     // (parent | options << 32, offset, size, out_child, out_addr)
  CROI_SYS_VMAR_MAP = 71,          // (vmar | options << 32, vmar_offset, vmo, vmo_offset, len, out_addr)
  CROI_SYS_VMAR_UNMAP = 72,        // (vmar, addr, len)
  CROI_SYS_VMAR_PROTECT = 73,      // (vmar | options << 32, addr, len)
  CROI_SYS_VMAR_DESTROY = 74,      // (vmar)
  CROI_SYS_VMAR_UNMAP_HANDLE_CLOSE_THREAD_EXIT = 75,  // (vmar, addr, len, close_handle): no return on success
  // Channels, eventpairs (K7b): Zircon's, except channel_read packs its
  // capacities (bytes | handles << 32) and writes both actuals (two
  // uint32_t) through one pointer.
  CROI_SYS_CHANNEL_CREATE = 80,    // (options, out0, out1)
  CROI_SYS_CHANNEL_WRITE = 81,     // (channel, options, bytes, num_bytes, handles, num_handles)
  CROI_SYS_CHANNEL_READ = 82,      // (channel, options, bytes, handles, capacities, actuals)
  CROI_SYS_CHANNEL_CALL = 83,      // (channel, options, deadline, croi_channel_call_args_t *, actual_bytes, actual_handles)
  CROI_SYS_EVENTPAIR_CREATE = 84,  // (options, out0, out1)
  CROI_SYS_OBJECT_SIGNAL_PEER = 85,  // (handle, clear, set)
  CROI_SYS_OBJECT_GET_INFO = 86,   // (handle, topic, buffer, buffer_size)
  CROI_SYS_TEST_PROFILE = 6,       // (op) boot self-test only
  // Futexes and timers (K7c): Zircon's.
  CROI_SYS_FUTEX_WAIT = 90,        // (uint32_t *value, current, new_owner thread handle, deadline)
  CROI_SYS_FUTEX_WAKE = 91,        // (uint32_t *value, count)
  CROI_SYS_FUTEX_REQUEUE = 92,     // (uint32_t *value, wake_count, current, uint32_t *target, requeue_count, owner)
  CROI_SYS_FUTEX_WAKE_SINGLE_OWNER = 93,  // (uint32_t *value)
  CROI_SYS_FUTEX_GET_OWNER = 94,   // (uint32_t *value, uint64_t *koid)
  CROI_SYS_TIMER_CREATE = 95,      // (options: CROI_TIMER_SLACK_*, clock_id 0, out)
  CROI_SYS_TIMER_SET = 96,         // (timer, deadline, slack)
  CROI_SYS_TIMER_CANCEL = 97,      // (timer)
  // Exceptions and job policy (K7d): Zircon's.
  CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL = 100,  // (task, options, out)
  CROI_SYS_EXCEPTION_GET_THREAD = 101,   // (exception, out)
  CROI_SYS_EXCEPTION_GET_PROCESS = 102,  // (exception, out)
  CROI_SYS_OBJECT_GET_PROPERTY = 103,    // (handle, property, value, size)
  CROI_SYS_OBJECT_SET_PROPERTY = 104,    // (handle, property, value, size)
  CROI_SYS_THREAD_READ_STATE = 105,      // (thread, kind, buffer, size): while in an exception
  CROI_SYS_THREAD_WRITE_STATE = 106,     // (thread, kind, buffer, size)
  CROI_SYS_JOB_SET_POLICY = 107,         // (job, options, topic 0, croi_policy_basic_t *, count)
  CROI_SYS_JOB_SET_CPU_RESERVATION = 108, // (job, CPU resource, cpu_mask): task.h

  CROI_SYS_DEBUGLOG_CREATE = 110,  // (resource or 0, options: CROI_LOG_FLAG_READABLE, out)
  CROI_SYS_DEBUGLOG_WRITE = 111,   // (log, options: CROI_LOG_LOCAL, text, length <= 216)
  CROI_SYS_DEBUGLOG_READ = 112,    // (log, options 0, croi_log_record_t *buffer, length) -> record size
  CROI_SYS_PROFILE_CREATE = 120,     // (resource, options 0, const croi_profile_info_t *, out)
  CROI_SYS_OBJECT_SET_PROFILE = 121, // (thread | interrupt | counter | timeline, profile, options,
                                     //  uint32_t *refusal or 0, timeline with ALIGN_TIMELINE)
  CROI_SYS_THREAD_BIND_OVERRUN_PORT = 122, // (thread, port, key): profile.h
  // Resources and IO ports (K9a): Zircon's calls, values in resource.h.
  CROI_SYS_RESOURCE_CREATE = 130,  // (parent | options << 32, base, size, name, name_size, uint32_t *out)
  CROI_SYS_IOPORTS_REQUEST = 131,  // (IOPORT resource, io_addr, len): amd64
  CROI_SYS_IOPORTS_RELEASE = 132,  // (IOPORT resource, io_addr, len): amd64

  // Interrupts (K9c): Zircon's calls, values in interrupt.h.
  CROI_SYS_INTERRUPT_CREATE = 140,   // (IRQ resource, number, options, uint32_t *out)
  CROI_SYS_INTERRUPT_BIND = 141,     // (interrupt, port, key, options)
  CROI_SYS_INTERRUPT_ACK = 142,      // (interrupt)
  CROI_SYS_INTERRUPT_WAIT = 143,     // (interrupt, uint64_t *timestamp or 0)
  CROI_SYS_INTERRUPT_DESTROY = 144,  // (interrupt)
  CROI_SYS_INTERRUPT_TRIGGER = 145,  // (interrupt, options 0, timestamp): virtual only
  CROI_SYS_INTERRUPT_SET_AFFINITY = 146,  // (interrupt, uint64_t cpu mask): croi's
  CROI_SYS_MSI_ALLOCATE = 147,       // (MSI resource, count, uint32_t *out)
  CROI_SYS_MSI_CREATE = 148,         // (allocation, options, id, vmo, vmo_offset, uint32_t *out)

  // DMA (K9e): Zircon's calls, values in dma.h.
  CROI_SYS_IOMMU_CREATE = 150,          // (IOMMU resource, type, desc, desc_size, uint32_t *out)
  CROI_SYS_BTI_CREATE = 151,            // (iommu, options 0, bti_id, uint32_t *out)
  CROI_SYS_BTI_PIN = 152,               // (bti | options << 32, vmo | addrs_count << 32, offset, size,
                                        //  uint64_t *addrs, uint32_t *pmt)
  CROI_SYS_BTI_RELEASE_QUARANTINE = 153,  // (bti)
  CROI_SYS_PMT_UNPIN = 154,             // (pmt): the handle is consumed
  CROI_SYS_VMO_CREATE_CONTIGUOUS = 155, // (bti, size, alignment_log2, uint32_t *out)
  CROI_SYS_BTI_SET_PROPERTIES = 156,    // (bti, const croi_bti_properties_t *): croi's, narrowing only

  // Counters (K10a): Zircon's calls, plus waiting at a value (counter.h).
  CROI_SYS_COUNTER_CREATE = 160,        // (options 0, uint32_t *out)
  CROI_SYS_COUNTER_ADD = 161,           // (counter, int64_t amount)
  CROI_SYS_COUNTER_READ = 162,          // (counter, int64_t *value)
  CROI_SYS_COUNTER_WRITE = 163,         // (counter, int64_t value)
  CROI_SYS_COUNTER_WAIT = 164,          // (counter, int64_t value, deadline): croi's
  CROI_SYS_COUNTER_WAIT_ASYNC = 165,    // (counter, port, key, int64_t value): croi's

  // Display timelines (K10b, croi's; timeline.h). Waits: the counter calls.
  CROI_SYS_TIMELINE_CREATE = 170,       // (display resource, options, period_ns, uint32_t *out)
  CROI_SYS_TIMELINE_ADVANCE = 171,      // (timeline, timestamp)
  CROI_SYS_TIMELINE_SET_PERIOD = 172,   // (timeline, period_ns)
  CROI_SYS_TIMELINE_GET_PAGE = 173,     // (timeline, uint32_t *vmo)

  // Power control (K10e; Zircon's, power.h).
  CROI_SYS_SYSTEM_POWERCTL = 180,       // (power resource, cmd, const croi_system_powerctl_arg_t *)

  // The kernel's CPRNG (K11b; Zircon's): at most CROI_CPRNG_MAX_LEN bytes.
  CROI_SYS_CPRNG_DRAW = 181,            // (void *buffer, length)
  CROI_SYS_CPRNG_ADD_ENTROPY = 182,     // (const void *buffer, length)
  CROI_CPRNG_MAX_LEN = 256,
};

enum : uint32_t {  // timer_create options (Zircon's ZX_TIMER_SLACK_*)
  CROI_TIMER_SLACK_CENTER = 0,
  CROI_TIMER_SLACK_EARLY = 1,
  CROI_TIMER_SLACK_LATE = 2,
};

// A new process's first thread starts with arg1 (a handle in the process)
// in the first argument register, arg2 in the second and the vDSO's base
// in the third.

#include "task.h"  // vmar options, task return codes, signals, croi_process_info_t
#include "ipc.h"   // channel signals and limits, call args, handle info, flow ids
#include "log.h"   // debuglog records, flags, severities
#include "profile.h"  // profile info, admission refusals
#include "resource.h" // resource kinds, flags, system bases, croi_info_resource_t
#include "vmo.h"      // vmo_op_range ops, cache policies, cache_flush options
#include "zbi.h"      // boot data items (CROI_PA_VMO_BOOTDATA)
#include "interrupt.h" // interrupt options, port binding, packet type
#include "dma.h"      // IOMMU types, bti_pin options, BTI info and properties
#include "counter.h"  // counter signals, value waits
#include "timeline.h" // display timelines, their page
#include "power.h"    // system_powerctl commands, croi_system_powerctl_arg_t

enum : uint64_t {  // CROI_SYS_TRACE_CONFIGURE ops
  CROI_TRACE_OP_START = 0,   // a: categories, b: pages per CPU, c: mode;
                             // sample_hz: the tick sampler's rate (0: 1 kHz)
  CROI_TRACE_OP_STOP = 1,
  CROI_TRACE_OP_REWIND = 2,
  CROI_TRACE_OP_MARK = 3,    // a, b: 16 bytes of the caller's
  CROI_TRACE_OP_RINGS = 4,   // a: uint32_t handles[], b: capacity (>= CPUs); returns the
                             // count: each CPU's ring (croi_trace_ring_t), read/map only
};

enum : uint64_t {  // CROI_SYS_PMU_CONFIGURE ops (events: pmu.h)
  CROI_PMU_OP_INFO = 0,          // a: croi_pmu_info_t out (no resource needed)
  CROI_PMU_OP_SAMPLE_START = 1,  // a: event, b: period (tracing resource)
  CROI_PMU_OP_SAMPLE_STOP = 2,   // (tracing resource)
  CROI_PMU_OP_THREAD_START = 3,  // a: count (1-4), b: uint32_t events[count];
                                 // the calling thread, from zero
  CROI_PMU_OP_THREAD_READ = 4,   // a: uint64_t[4] out
  CROI_PMU_OP_THREAD_STOP = 5,
};

enum : uint64_t {  // CROI_SYS_VMO_MAP rights
  CROI_VM_READ = 1,
  CROI_VM_WRITE = 2,
  CROI_VM_EXECUTE = 4,
};

typedef struct {
  uint64_t key;
  uint32_t type;
  int32_t status;
  uint64_t payload[4];  // signal packets: trigger | observed << 32, count, timestamp
} croi_port_packet_t;

static inline int64_t croi_syscall(uint64_t number, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                                   uint64_t a4) {
#if defined(__x86_64__)
  register uint64_t r10 __asm__("r10") = a3;
  register uint64_t r8 __asm__("r8") = a4;
  int64_t result;
  __asm__ volatile("syscall"
                   : "=a"(result)
                   : "a"(number), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8)
                   : "rcx", "r11", "memory");
  return result;
#elif defined(__aarch64__)
  register uint64_t x16 __asm__("x16") = number;
  register uint64_t x0 __asm__("x0") = a0;
  register uint64_t x1 __asm__("x1") = a1;
  register uint64_t x2 __asm__("x2") = a2;
  register uint64_t x3 __asm__("x3") = a3;
  register uint64_t x4 __asm__("x4") = a4;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x16), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
  return (int64_t)x0;
#elif defined(__riscv)
  register uint64_t a7 __asm__("a7") = number;
  register uint64_t r0 __asm__("a0") = a0;
  register uint64_t r1 __asm__("a1") = a1;
  register uint64_t r2 __asm__("a2") = a2;
  register uint64_t r3 __asm__("a3") = a3;
  register uint64_t r4 __asm__("a4") = a4;
  __asm__ volatile("ecall" : "+r"(r0) : "r"(a7), "r"(r1), "r"(r2), "r"(r3), "r"(r4) : "memory");
  return (int64_t)r0;
#endif
}

// Six arguments (the sixth in r9 / x5 / a5).
static inline int64_t croi_syscall6(uint64_t number, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                                    uint64_t a4, uint64_t a5) {
#if defined(__x86_64__)
  register uint64_t r10 __asm__("r10") = a3;
  register uint64_t r8 __asm__("r8") = a4;
  register uint64_t r9 __asm__("r9") = a5;
  int64_t result;
  __asm__ volatile("syscall"
                   : "=a"(result)
                   : "a"(number), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8), "r"(r9)
                   : "rcx", "r11", "memory");
  return result;
#elif defined(__aarch64__)
  register uint64_t x16 __asm__("x16") = number;
  register uint64_t x0 __asm__("x0") = a0;
  register uint64_t x1 __asm__("x1") = a1;
  register uint64_t x2 __asm__("x2") = a2;
  register uint64_t x3 __asm__("x3") = a3;
  register uint64_t x4 __asm__("x4") = a4;
  register uint64_t x5 __asm__("x5") = a5;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x16), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
  return (int64_t)x0;
#elif defined(__riscv)
  register uint64_t a7 __asm__("a7") = number;
  register uint64_t r0 __asm__("a0") = a0;
  register uint64_t r1 __asm__("a1") = a1;
  register uint64_t r2 __asm__("a2") = a2;
  register uint64_t r3 __asm__("a3") = a3;
  register uint64_t r4 __asm__("a4") = a4;
  register uint64_t r5 __asm__("a5") = a5;
  __asm__ volatile("ecall" : "+r"(r0) : "r"(a7), "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5) : "memory");
  return (int64_t)r0;
#endif
}
