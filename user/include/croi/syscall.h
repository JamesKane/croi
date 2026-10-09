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
  CROI_SYS_THREAD_EXIT = 2,        // (int64_t code)
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
  CROI_SYS_TRACE_CONFIGURE = 50,   // (resource, op, a, b, c, sample_hz)
  CROI_SYS_PMU_CONFIGURE = 51,     // (resource, op, a, b)
};

enum : uint64_t {  // CROI_SYS_TRACE_CONFIGURE ops
  CROI_TRACE_OP_START = 0,   // a: categories, b: pages per CPU, c: mode;
                             // sample_hz: the tick sampler's rate (0: 1 kHz)
  CROI_TRACE_OP_STOP = 1,
  CROI_TRACE_OP_REWIND = 2,
  CROI_TRACE_OP_MARK = 3,    // a, b: 16 bytes of the caller's
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
