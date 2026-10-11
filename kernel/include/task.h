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

  // Properties (object_get/set_property). amd64 only, on the calling
  // thread's own handle: its TLS bases (arm64 TPIDR_EL0 and rv64 tp are
  // user-writable registers). Then the exception's state.
  CROI_PROP_REGISTER_GS = 2,
  CROI_PROP_NAME = 3,  // char[32] (K13e): processes, threads, jobs, VMOs, BTIs; resources read only
  CROI_PROP_REGISTER_FS = 4,
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
// NZCV); fs_base/gs_base must be canonical.
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
  CROI_POL_NEW_SOCKET = 9,
  CROI_POL_NEW_FIFO = 10,
  CROI_POL_NEW_TIMER = 11,
  CROI_POL_NEW_PROCESS = 12,
  CROI_POL_NEW_PAGER = 14,
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

// object_get_info(process, CROI_INFO_TASK_STATS): Zircon's
// zx_info_task_stats_t (needs INSPECT; BAD_STATE once the process is
// gone). Mapped bytes per mapping; committed bytes are private when the
// VMO is mapped by this process only, else shared, and scaled-shared
// divides each shared range by the number of processes mapping it (croi
// has no copy-on-write clones). Physical VMOs count no committed bytes.
// The topic is versioned as Zircon's (topic | version << 28); _V1 is the
// first four fields.
enum : uint32_t {
  CROI_INFO_TASK_STATS = 12u | (1u << 28),
  CROI_INFO_TASK_STATS_V1 = 12u,
};

typedef struct {
  uint64_t mem_mapped_bytes;
  uint64_t mem_private_bytes;
  uint64_t mem_shared_bytes;
  uint64_t mem_scaled_shared_bytes;
  uint64_t mem_fractional_scaled_shared_bytes;  // 63-bit fixed point; 1 << 63 is a byte
} croi_info_task_stats_t;

static_assert(sizeof(croi_info_task_stats_t) == 40);

// object_get_info(thread, CROI_INFO_THREAD_TRACE) (croi's, K10d; INSPECT):
// the id croi's trace records name the thread by (task << 12 | index), so
// a user trace can be joined with croi's sched and ipc records.
enum : uint32_t {
  CROI_INFO_THREAD_TRACE = 0x10001,
};

typedef struct {
  uint32_t trace_id;
  uint32_t reserved;
} croi_info_thread_trace_t;

static_assert(sizeof(croi_info_thread_trace_t) == 8);

// job_set_cpu_reservation(job, resource, cpu_mask) (croi's, K10d, ext 8):
// the CPUs in the mask run only threads of this job and its descendants,
// and no other threads, timers or routed interrupts. Needs SET_POLICY on
// the job and the CPU system resource (or root); only while the job has
// no children (BAD_STATE), which then inherit it. The boot CPU can't be
// reserved (INVALID_ARGS); a CPU another job holds is ALREADY_BOUND, one
// with deadline reservations admitted for others NO_RESOURCES. Mask 0
// releases; the job's destruction releases too.

// Task and VMO info topics (K13e, Zircon's numbers and layouts).
// object_get_info(handle, topic, buffer, buffer_size, size_t *actual,
// size_t *avail): fixed-size topics write actual 1 (0 and
// BUFFER_TOO_SMALL if the buffer is short) and avail 1; list topics fill
// what fits and report how many there are, never BUFFER_TOO_SMALL.
enum : uint32_t {
  CROI_INFO_PROCESS = 3u | (1u << 28),        // croi_info_process_t (INSPECT)
  CROI_INFO_PROCESS_THREADS = 4u,             // koids (ENUMERATE)
  CROI_INFO_JOB_CHILDREN = 8u,                // koids (ENUMERATE)
  CROI_INFO_JOB_PROCESSES = 9u,               // koids (ENUMERATE)
  CROI_INFO_THREAD = 10u,                     // croi_info_thread_t (INSPECT)
  CROI_INFO_PROCESS_MAPS_V1 = 13u,            // croi_info_maps_t, 96-byte entries
  CROI_INFO_PROCESS_MAPS_V2 = 13u | (1u << 28),  // 104-byte entries
  CROI_INFO_PROCESS_MAPS = 13u | (2u << 28),  // croi_info_maps_t (INSPECT)
  CROI_INFO_PROCESS_VMOS_V1 = 14u,            // croi_info_vmo_t prefixes: 104,
  CROI_INFO_PROCESS_VMOS_V2 = 14u | (1u << 28),  // 120,
  CROI_INFO_PROCESS_VMOS_V3 = 14u | (2u << 28),  // 128 bytes
  CROI_INFO_PROCESS_VMOS = 14u | (3u << 28),  // croi_info_vmo_t (INSPECT)
  CROI_INFO_THREAD_STATS = 15u,               // croi_info_thread_stats_t (INSPECT)
  CROI_INFO_VMO_V1 = 23u,
  CROI_INFO_VMO_V2 = 23u | (1u << 28),
  CROI_INFO_VMO_V3 = 23u | (2u << 28),
  CROI_INFO_VMO = 23u | (3u << 28),           // croi_info_vmo_t (no rights needed)
  CROI_INFO_JOB = 24u,                        // croi_info_job_t (INSPECT)
  CROI_INFO_HANDLE_TABLE = 27u,               // croi_info_handle_extended_t (INSPECT | MANAGE_PROCESS | MANAGE_THREAD)
  CROI_INFO_TASK_RUNTIME_V1 = 30u,            // 16 bytes
  CROI_INFO_TASK_RUNTIME = 30u | (1u << 28),  // croi_info_task_runtime_t (INSPECT)

  CROI_INFO_PROCESS_FLAG_STARTED = 1u << 0,
  CROI_INFO_PROCESS_FLAG_EXITED = 1u << 1,
  CROI_INFO_PROCESS_FLAG_DEBUGGER_ATTACHED = 1u << 2,

  CROI_THREAD_STATE_NEW = 0x0000,
  CROI_THREAD_STATE_RUNNING = 0x0001,
  CROI_THREAD_STATE_SUSPENDED = 0x0002,
  CROI_THREAD_STATE_BLOCKED = 0x0003,
  CROI_THREAD_STATE_DYING = 0x0004,
  CROI_THREAD_STATE_DEAD = 0x0005,
  CROI_THREAD_STATE_BLOCKED_EXCEPTION = 0x0103,
  CROI_THREAD_STATE_BLOCKED_SLEEPING = 0x0203,
  CROI_THREAD_STATE_BLOCKED_FUTEX = 0x0303,
  CROI_THREAD_STATE_BLOCKED_PORT = 0x0403,
  CROI_THREAD_STATE_BLOCKED_CHANNEL = 0x0503,
  CROI_THREAD_STATE_BLOCKED_WAIT_ONE = 0x0603,
  CROI_THREAD_STATE_BLOCKED_WAIT_MANY = 0x0703,
  CROI_THREAD_STATE_BLOCKED_INTERRUPT = 0x0803,
  CROI_THREAD_STATE_BLOCKED_PAGER = 0x0903,

  CROI_INFO_MAPS_TYPE_NONE = 0,
  CROI_INFO_MAPS_TYPE_ASPACE = 1,
  CROI_INFO_MAPS_TYPE_VMAR = 2,
  CROI_INFO_MAPS_TYPE_MAPPING = 3,

  CROI_INFO_INVALID_CPU = 0xFFFFFFFFu,

  // K13g: suspension (task_suspend's token, Zircon's type 27) and its signals.
  CROI_OBJ_TYPE_SUSPEND_TOKEN = 27,
  CROI_THREAD_RUNNING = 1u << 4,
  CROI_THREAD_SUSPENDED = 1u << 5,
};

// zx_info_process_t.
typedef struct {
  int64_t return_code;
  int64_t start_time;
  uint32_t flags;
  uint8_t padding[4];
} croi_info_process_t;

// zx_info_thread_t (cpu_affinity_mask: zx_cpu_set_t, 512 CPUs).
typedef struct {
  uint32_t state;
  uint32_t wait_exception_channel_type;
  uint64_t cpu_affinity_mask[8];
} croi_info_thread_t;

// zx_info_thread_stats_t.
typedef struct {
  int64_t total_runtime;
  uint32_t last_scheduled_cpu;
  uint8_t padding[4];
} croi_info_thread_stats_t;

// zx_info_task_runtime_t.
typedef struct {
  int64_t cpu_time;
  int64_t queue_time;
  int64_t page_fault_time;
  int64_t lock_contention_time;
} croi_info_task_runtime_t;

// zx_info_job_t.
typedef struct {
  int64_t return_code;
  uint8_t exited;
  uint8_t kill_on_oom;
  uint8_t debugger_attached;
  uint8_t padding[5];
} croi_info_job_t;

// zx_info_handle_extended_t.
typedef struct {
  uint32_t type;
  uint32_t handle_value;
  uint32_t rights;
  uint32_t reserved;
  uint64_t koid;
  uint64_t related_koid;
  uint64_t peer_owner_koid;
} croi_info_handle_extended_t;

// zx_info_maps_mapping_t.
typedef struct {
  uint32_t mmu_flags;  // CROI_VM_PERM_*
  uint8_t padding1[4];
  uint64_t vmo_koid;
  uint64_t vmo_offset;
  uint64_t committed_bytes;
  uint64_t populated_bytes;
  uint64_t committed_private_bytes;
  uint64_t populated_private_bytes;
  uint64_t committed_scaled_bytes;
  uint64_t populated_scaled_bytes;
  uint64_t committed_fractional_scaled_bytes;
  uint64_t populated_fractional_scaled_bytes;
} croi_info_maps_mapping_t;

// zx_info_maps_t: depth-first, pre-order (aspace at depth 0).
typedef struct {
  char name[32];
  uint64_t base;
  uint64_t size;
  uint64_t depth;
  uint32_t type;  // CROI_INFO_MAPS_TYPE_*
  uint8_t padding1[4];
  union {
    croi_info_maps_mapping_t mapping;
    uint8_t reserved[88];
  } u;
} croi_info_maps_t;
