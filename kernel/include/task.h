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

enum : int64_t {  // return codes of processes the kernel ended (Zircon's)
  CROI_TASK_RETCODE_SYSCALL_KILL = -1024,
  CROI_TASK_RETCODE_POLICY_KILL = -1026,
  CROI_TASK_RETCODE_EXCEPTION_KILL = -1028,
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

// Exceptions (K7d; Zircon's). A message on an exception channel is a
// croi_exception_info_t plus one handle to the exception.
enum : uint32_t {
  CROI_EXCP_GENERAL = 0x008,
  CROI_EXCP_FATAL_PAGE_FAULT = 0x108,
  CROI_EXCP_UNDEFINED_INSTRUCTION = 0x208,
  CROI_EXCP_SW_BREAKPOINT = 0x308,
  CROI_EXCP_UNALIGNED_ACCESS = 0x508,
  CROI_EXCP_POLICY_ERROR = 0x8208,  // synthetic

  // The exception's state property (object_set_property).
  CROI_PROP_EXCEPTION_STATE = 16,
  CROI_EXCEPTION_STATE_TRY_NEXT = 0,
  CROI_EXCEPTION_STATE_HANDLED = 1,
  CROI_EXCEPTION_STATE_THREAD_EXIT = 2,

  // thread_read_state / thread_write_state kinds.
  CROI_THREAD_STATE_GENERAL_REGS = 0,
};

typedef struct {
  uint64_t pid;
  uint64_t tid;
  uint32_t type;
  uint32_t padding;
} croi_exception_info_t;

// General registers (zx_thread_state_general_regs_t's layout per arch).
// Writes keep only user-settable flags (amd64 arithmetic flags, arm64
// NZCV); fs_base/gs_base and tpidr read 0 and are ignored until croi
// keeps user TLS registers.
typedef struct {
#if defined(__x86_64__)
  uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp, r8, r9, r10, r11, r12, r13, r14, r15;
  uint64_t rip, rflags, fs_base, gs_base;
#elif defined(__aarch64__)
  uint64_t r[30];
  uint64_t lr, sp, pc, cpsr, tpidr;
#elif defined(__riscv)
  uint64_t pc;
  uint64_t x[31];  // ra, sp, gp, tp, t0-t2, s0, s1, a0-a7, s2-s11, t3-t6
#endif
} croi_thread_state_general_regs_t;

// Job policy (Zircon's ZX_POL_*): conditions, actions, options.
enum : uint32_t {
  CROI_POL_BAD_HANDLE = 0,
  CROI_POL_NEW_ANY = 3,
  CROI_POL_NEW_VMO = 4,
  CROI_POL_NEW_CHANNEL = 5,
  CROI_POL_NEW_EVENT = 6,
  CROI_POL_NEW_EVENTPAIR = 7,
  CROI_POL_NEW_PORT = 8,
  CROI_POL_NEW_TIMER = 11,
  CROI_POL_NEW_PROCESS = 12,
  CROI_POL_CONDITIONS = 16,

  CROI_POL_ACTION_ALLOW = 0,
  CROI_POL_ACTION_DENY = 1,
  CROI_POL_ACTION_ALLOW_EXCEPTION = 2,
  CROI_POL_ACTION_DENY_EXCEPTION = 3,
  CROI_POL_ACTION_KILL = 4,

  CROI_JOB_POL_RELATIVE = 0,
  CROI_JOB_POL_ABSOLUTE = 1,
};

typedef struct {
  uint32_t condition;
  uint32_t policy;
} croi_policy_basic_t;
