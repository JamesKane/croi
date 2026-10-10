// Process bootstrap messages (K8; Zircon's processargs, zircon/processargs.h):
// the ABI shared by the kernel (which starts userboot) and user space. A new
// process's first thread gets a channel handle in its first argument
// register; the first message on it is a croi_proc_args_t header followed
// by a uint32_t handle-info word per handle (CROI_PA_HND), then the
// argument and environment strings, each NUL-terminated.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_PROCARGS_PROTOCOL = 0x4150585d,  // "MXPA"
  CROI_PROCARGS_VERSION = 0x0001000,

  // Handle types (the low byte of an info word; the argument is bits 16-31).
  CROI_PA_PROC_SELF = 0x01,
  CROI_PA_THREAD_SELF = 0x02,
  CROI_PA_JOB_DEFAULT = 0x03,
  CROI_PA_VMAR_ROOT = 0x04,
  CROI_PA_VMAR_LOADED = 0x05,
  CROI_PA_VMO_VDSO = 0x11,
  CROI_PA_VMO_STACK = 0x13,
  CROI_PA_VMO_EXECUTABLE = 0x14,
  CROI_PA_VMO_BOOTFS = 0x1B,
  CROI_PA_FD = 0x30,              // argument: the fd (1: stdout, a debuglog)
  CROI_PA_RESOURCE = 0x3F,        // argument 0: the root resource
  CROI_PA_USER0 = 0xF0,
};

// Zircon's PA_HND(type, arg).
static inline uint32_t croi_pa_hnd(uint32_t type, uint32_t arg) {
  return (type & 0xFF) | ((arg & 0xFFFF) << 16);
}

// zx_proc_args_t.
typedef struct {
  uint32_t protocol;
  uint32_t version;
  uint32_t handle_info_off;  // uint32_t per handle, in the message's order
  uint32_t args_off;         // args_num NUL-terminated strings
  uint32_t args_num;
  uint32_t environ_off;      // environ_num NUL-terminated strings
  uint32_t environ_num;
  uint32_t names_off;        // names_num NUL-terminated strings (unused)
  uint32_t names_num;
} croi_proc_args_t;
