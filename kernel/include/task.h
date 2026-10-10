// Jobs, processes, threads and VMARs: the ABI shared by the kernel and
// user space (user/include/croi/syscall.h includes it). C, because both
// sides need the same constants and layouts.
#pragma once
#include <stdint.h>

enum : uint32_t {  // vmar options (Zircon's ZX_VM_*)
  CROI_VM_PERM_READ = 1u << 0,
  CROI_VM_PERM_WRITE = 1u << 1,
  CROI_VM_PERM_EXECUTE = 1u << 2,
  CROI_VM_SPECIFIC = 1u << 4,
  CROI_VM_CAN_MAP_READ = 1u << 7,
  CROI_VM_CAN_MAP_WRITE = 1u << 8,
  CROI_VM_CAN_MAP_EXECUTE = 1u << 9,
};

enum : int64_t {  // return codes of processes the kernel ended
  CROI_TASK_RETCODE_SYSCALL_KILL = -1024,
  CROI_TASK_RETCODE_EXCEPTION_KILL = -1025,
};

enum : uint32_t {  // signals
  CROI_SIGNAL_TASK_TERMINATED = 1u << 3,
  CROI_SIGNAL_THREAD_RUNNING = 1u << 4,
};

enum : uint32_t {  // croi_process_info_t flags
  CROI_PROCESS_INFO_STARTED = 1u << 0,
  CROI_PROCESS_INFO_EXITED = 1u << 1,
};

typedef struct {
  int64_t return_code;
  uint32_t flags;
  uint32_t reserved;
} croi_process_info_t;
