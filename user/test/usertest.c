// The boot self-test's user program (K6b): exercises the object syscalls
// from user mode and exits with 0x600D, or with the number of the first
// check that failed. arg0 selects a mode; arg1 is a handle the kernel
// gave it (mode 1: a tracing resource).

#include <croi/syscall.h>

#include "pmu.h"
#include "shared.h"

#define ERR_BAD_HANDLE (-11)
#define ERR_INVALID_ARGS (-10)
#define ERR_TIMED_OUT (-21)
#define ERR_ACCESS_DENIED (-30)
#define ERR_BAD_STATE (-20)
#define ERR_NOT_SUPPORTED (-2)
#define ERR_BUFFER_TOO_SMALL (-15)
#define ERR_SHOULD_WAIT (-22)
#define ERR_PEER_CLOSED (-24)
#define RIGHT_SAME (1u << 31)
#define SIGNALED (1u << 3)
#define USER_SIGNAL_0 (1u << 24)
#define RIGHT_READ (1u << 2)
#define RIGHT_MAP (1u << 5)
#define RIGHT_DUPLICATE (1u << 0)
#define RIGHT_TRANSFER (1u << 1)
#define RIGHT_WAIT (1u << 14)

static inline int64_t sys(uint64_t n, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e) {
  return croi_syscall(n, a, b, c, d, e);
}

static inline int64_t sys6(uint64_t n, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f) {
  return croi_syscall6(n, a, b, c, d, e, f);
}

[[noreturn]] static void exit_with(int64_t code) {
  sys(CROI_SYS_PROCESS_EXIT, (uint64_t)code, 0, 0, 0, 0);
  for (;;) {
  }
}

#define CHECK(n, condition) \
  do {                      \
    if (!(condition)) exit_with(n); \
  } while (0)

static int64_t objects(void) {
  uint32_t event = 0, port = 0, dup = 0, vmo = 0, observed = 0;
  int64_t now = sys(CROI_SYS_CLOCK_MONOTONIC, 0, 0, 0, 0, 0);

  // Events, signals, waits.
  CHECK(1, sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&event, 0, 0, 0) == 0 && event != 0);
  CHECK(2, sys(CROI_SYS_OBJECT_WAIT_ONE, event, SIGNALED, (uint64_t)now + 1000000, (uint64_t)&observed, 0)
               == ERR_TIMED_OUT);
  CHECK(3, sys(CROI_SYS_OBJECT_SIGNAL, event, 0, SIGNALED, 0, 0) == 0);
  CHECK(4, sys(CROI_SYS_OBJECT_WAIT_ONE, event, SIGNALED, (uint64_t)now + 1000000000, (uint64_t)&observed, 0) == 0
               && (observed & SIGNALED));
  CHECK(5, sys(CROI_SYS_OBJECT_SIGNAL, event, 0, 1, 0, 0) == ERR_INVALID_ARGS);

  // Handles: duplicate with fewer rights, then a refused signal.
  CHECK(6, sys(CROI_SYS_HANDLE_DUPLICATE, event, RIGHT_WAIT | RIGHT_TRANSFER, (uint64_t)&dup, 0, 0) == 0);
  CHECK(7, sys(CROI_SYS_OBJECT_SIGNAL, dup, SIGNALED, 0, 0, 0) == ERR_ACCESS_DENIED);
  CHECK(8, sys(CROI_SYS_HANDLE_CLOSE, dup, 0, 0, 0, 0) == 0);
  CHECK(9, sys(CROI_SYS_HANDLE_CLOSE, dup, 0, 0, 0, 0) == ERR_BAD_HANDLE);

  // Ports: a user packet, then an async wait on the event.
  croi_port_packet_t packet = {.key = 42, .payload = {1, 2, 3, 4}};
  CHECK(10, sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0);
  CHECK(11, sys(CROI_SYS_PORT_QUEUE, port, (uint64_t)&packet, 0, 0, 0) == 0);
  croi_port_packet_t got = {0};
  CHECK(12, sys(CROI_SYS_PORT_WAIT, port, (uint64_t)now + 1000000000, (uint64_t)&got, 0, 0) == 0
                && got.key == 42 && got.payload[3] == 4);
  CHECK(13, sys(CROI_SYS_OBJECT_WAIT_ASYNC, event, port, 7, USER_SIGNAL_0, 0) == 0);
  CHECK(14, sys(CROI_SYS_OBJECT_SIGNAL, event, 0, USER_SIGNAL_0, 0, 0) == 0);
  CHECK(15, sys(CROI_SYS_PORT_WAIT, port, (uint64_t)now + 1000000000, (uint64_t)&got, 0, 0) == 0 && got.key == 7
                && got.type == 1 && (got.payload[0] >> 32) & USER_SIGNAL_0);

  // VMOs: write, read back, map and use directly.
  CHECK(16, sys(CROI_SYS_VMO_CREATE, 8192, 0, (uint64_t)&vmo, 0, 0) == 0);
  static const char text[] = "written through vmo_write";
  CHECK(17, sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)text, 4090, sizeof text, 0) == 0);  // spans two pages
  char back[sizeof text];
  CHECK(18, sys(CROI_SYS_VMO_READ, vmo, (uint64_t)back, 4090, sizeof back, 0) == 0);
  for (unsigned i = 0; i < sizeof text; i++) CHECK(19, back[i] == text[i]);
  uint64_t address = 0;
  CHECK(20, sys(CROI_SYS_VMO_MAP, vmo, 0, 8192, CROI_VM_READ | CROI_VM_WRITE, (uint64_t)&address) == 0);
  volatile char *mapped = (volatile char *)address;
  CHECK(21, mapped[4090] == 'w');
  mapped[0] = 'Z';
  CHECK(22, sys(CROI_SYS_VMO_READ, vmo, (uint64_t)back, 0, 1, 0) == 0 && back[0] == 'Z');

  // Bad pointers are errors, not crashes.
  CHECK(23, sys(CROI_SYS_EVENT_CREATE, 0, 0x10, 0, 0, 0) == ERR_INVALID_ARGS);
  CHECK(24, sys(CROI_SYS_VMO_READ, vmo, 0xFFFF800000000000ull, 0, 16, 0) == ERR_INVALID_ARGS);
  CHECK(25, sys(CROI_SYS_DEBUG_WRITE, 0x10, 4, 0, 0, 0) == ERR_INVALID_ARGS);
  // A kernel address valid on every arch (the kernel image): never copied.
  CHECK(29, sys(CROI_SYS_VMO_WRITE, vmo, 0xFFFFFFFF80000000ull, 0, 16, 0) == ERR_INVALID_ARGS);
  CHECK(30, sys(CROI_SYS_VMO_READ, vmo, 0xFFFFFFFF80000000ull, 0, 16, 0) == ERR_INVALID_ARGS);

  CHECK(26, sys(CROI_SYS_HANDLE_CLOSE, event, 0, 0, 0, 0) == 0);
  CHECK(27, sys(CROI_SYS_HANDLE_CLOSE, port, 0, 0, 0, 0) == 0);
  CHECK(28, sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0) == 0);
  static const char done[] = "object syscalls from user mode ok";
  sys(CROI_SYS_DEBUG_WRITE, (uint64_t)done, sizeof done - 1, 0, 0, 0);
  return 0x600D;
}

// Mode 1: user marks through trace_configure with the tracing resource.
static int64_t marks(uint32_t resource) {
  CHECK(40, sys(CROI_SYS_TRACE_CONFIGURE, resource, CROI_TRACE_OP_START, 1u << 7 | 1u << 5, 4, 0) == 0);
  CHECK(41, sys(CROI_SYS_TRACE_CONFIGURE, resource, CROI_TRACE_OP_MARK, 0xC401, 0xFEED, 0) == 0);
  CHECK(42, sys(CROI_SYS_TRACE_CONFIGURE, resource, CROI_TRACE_OP_STOP, 0, 0, 0) == 0);
  CHECK(43, sys(CROI_SYS_TRACE_CONFIGURE, 0x7FF, CROI_TRACE_OP_STOP, 0, 0, 0) == ERR_BAD_HANDLE);
  return 0x600D;
}

// Mode 2: the vDSO at `base`: its clock against the syscall's, the
// topology page, timing, and the power page's seqlock under a kernel
// writer (an equal pair must never read torn).
static int64_t vdso(uint64_t base) {
  const croi_vdso_header_t *header = (const croi_vdso_header_t *)base;
  CHECK(50, header->magic == CROI_VDSO_MAGIC);
  uint64_t (*clock)(void) = (uint64_t (*)(void))(base + header->clock_monotonic);
  const croi_topology_page_t *(*topology)(void) = (const croi_topology_page_t *(*)(void))(base + header->topology);
  const croi_power_page_t *(*power)(void) = (const croi_power_page_t *(*)(void))(base + header->power);

  uint64_t before = clock();
  uint64_t middle = (uint64_t)sys(CROI_SYS_CLOCK_MONOTONIC, 0, 0, 0, 0, 0);
  uint64_t after = clock();
  CHECK(51, before <= middle && middle <= after);
  const croi_topology_page_t *t = topology();
  CHECK(52, t->version == CROI_TOPOLOGY_PAGE_VERSION && t->cpu_count >= 1 && t->cpus[0].capacity >= 1);

  uint64_t t0 = clock();
  for (int i = 0; i < 1000; i++) clock();
  uint64_t t1 = clock();
  for (int i = 0; i < 1000; i++) sys(CROI_SYS_CLOCK_MONOTONIC, 0, 0, 0, 0, 0);
  uint64_t t2 = clock();

  const croi_power_page_t *p = power();
  uint64_t torn = 0, distinct = 0, last = 0;
  for (int i = 0; i < 200000; i++) {
    uint64_t s1 = __atomic_load_n(&p->sequence, __ATOMIC_ACQUIRE);
    if (s1 & 1) continue;
    uint64_t a = *(volatile const uint64_t *)&p->test_a;
    uint64_t b = *(volatile const uint64_t *)&p->test_b;
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    if (__atomic_load_n(&p->sequence, __ATOMIC_RELAXED) != s1) continue;
    if (a != b) torn++;
    if (a != last) {
      distinct++;
      last = a;
    }
  }
  CHECK(53, torn == 0);
  uint64_t vdso_ns = (t1 - t0) / 1000, syscall_ns = (t2 - t1) / 1000;
  sys(CROI_SYS_TEST_REPORT, (vdso_ns & 0xFFFF) | (syscall_ns & 0xFFFF) << 16 | distinct << 32, 0, 0, 0, 0);
  return 0x600D;
}

// Mode 3: FP/SIMD state survives switches. `arg` bits 0-15: a seed;
// bit 16: the vector extension is present (arm64 SVE, rv64 V). Loads seed-derived values into vector/FP
// registers, then 16 times spins (preemptible) and sleeps 300 us (so the
// other thread on this CPU runs in between, whatever the timeslice), and
// checks them, all in one asm block; then a double-precision
// computation across sleeps whose result the kernel compares between runs.
// Exit: 0x10000000 | hash of the result, or 0x200 + register number.
static int64_t registers(uint64_t seed, uint64_t sve) {
  uint64_t bad = 0;
#if defined(__x86_64__)
  __asm__ volatile(
      "mov %[s], %%rax\n"
      ".irp n, 8, 9, 10, 11, 12, 13, 14, 15\n movq %%rax, %%xmm\\n\n add $1, %%rax\n .endr\n"
      "mov $16, %%r12\n"
      "1: mov $50000, %%rcx\n"
      "2: dec %%rcx\n jnz 2b\n"
      "mov $3, %%eax\n syscall\n"  // clock, then sleep until 300 us on
      "lea 300000(%%rax), %%rdi\n mov $4, %%eax\n syscall\n"
      "dec %%r12\n jnz 1b\n"
      "mov %[s], %%rdx\n xor %[bad], %[bad]\n"
      ".irp n, 8, 9, 10, 11, 12, 13, 14, 15\n movq %%xmm\\n, %%rax\n cmp %%rdx, %%rax\n je 3f\n mov $\\n, %[bad]\n 3: add $1, %%rdx\n .endr\n"
      : [bad] "=&r"(bad)
      : [s] "r"(seed)
      : "rax", "rcx", "rdx", "rdi", "r11", "r12", "memory", "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14",
        "xmm15");
  (void)sve;
#elif defined(__aarch64__)
  uint64_t lanes = 0, last = 0;
  __asm__ volatile(
      "mov x9, %[s]\n"
      ".irp n, 8, 9, 10, 11, 12, 13, 14, 15\n fmov d\\n, x9\n add x9, x9, #1\n .endr\n"
      "cbz %[sve], 4f\n"
      ".arch_extension sve\n"
      "index z16.d, %[s], #1\n"  // every lane: seed + its number
      "4: mov x10, #16\n"
      "1: movz x11, #50000\n"
      "2: subs x11, x11, #1\n b.ne 2b\n"
      "mov x16, #3\n svc #0\n"
      "movz x11, #0x93e0\n movk x11, #0x4, lsl #16\n add x0, x0, x11\n"  // + 300000
      "mov x16, #4\n svc #0\n"
      "subs x10, x10, #1\n b.ne 1b\n"
      "mov x9, %[s]\n mov %[bad], #0\n"
      ".irp n, 8, 9, 10, 11, 12, 13, 14, 15\n fmov x12, d\\n\n cmp x12, x9\n b.eq 3f\n mov %[bad], #\\n\n 3: add x9, x9, #1\n .endr\n"
      "cbz %[sve], 5f\n"
      "cntd %[lanes]\n ptrue p1.d\n lastb %[last], p1, z16.d\n"
      "5:\n"
      : [bad] "=&r"(bad), [lanes] "=&r"(lanes), [last] "=&r"(last)
      : [s] "r"(seed), [sve] "r"(sve)
      : "x0", "x9", "x10", "x11", "x12", "x16", "p1", "z16", "memory", "d8", "d9", "d10", "d11", "d12", "d13",
        "d14", "d15");
  if (sve && last != seed + lanes - 1) bad = 16;  // the top lane of z16 was lost
#elif defined(__riscv)
  uint64_t last = 0;
  __asm__ volatile(
      "mv t1, %[s]\n"
      ".irp n, 8, 9, 10, 11, 12, 13, 14, 15\n fmv.d.x f\\n, t1\n addi t1, t1, 1\n .endr\n"
      ".option push\n .option arch, +v\n"
      "beqz %[sve], 4f\n"
      "vsetvli t2, zero, e64, m1, ta, ma\n vid.v v8\n vadd.vx v8, v8, %[s]\n"
      "4: li t3, 16\n"
      "1: li t4, 50000\n"
      "2: addi t4, t4, -1\n bnez t4, 2b\n"
      "li a7, 3\n ecall\n"
      "li t4, 300000\n add a0, a0, t4\n li a7, 4\n ecall\n"
      "addi t3, t3, -1\n bnez t3, 1b\n"
      "mv t1, %[s]\n li %[bad], 0\n"
      ".irp n, 8, 9, 10, 11, 12, 13, 14, 15\n fmv.x.d t5, f\\n\n beq t5, t1, 3f\n li %[bad], \\n\n 3: addi t1, t1, 1\n .endr\n"
      "beqz %[sve], 5f\n"
      "vsetvli t2, zero, e64, m1, ta, ma\n addi t2, t2, -1\n vslidedown.vx v9, v8, t2\n vmv.x.s %[last], v9\n"
      "add t2, t2, %[s]\n beq %[last], t2, 5f\n li %[bad], 16\n"
      "5:\n .option pop\n"
      : [bad] "=&r"(bad), [last] "=&r"(last)
      : [s] "r"(seed), [sve] "r"(sve)
      : "t1", "t2", "t3", "t4", "t5", "a0", "a7", "v8", "v9", "memory", "f8", "f9", "f10", "f11", "f12", "f13",
        "f14", "f15");
#endif
  if (bad) return 0x200 + (int64_t)bad;

  double acc = (double)seed;
  for (int i = 0; i < 200000; i++) {
    acc = acc * 1.0000001 + 0.5;
    if (i % 20000 == 0) sys(CROI_SYS_NANOSLEEP, 0, 0, 0, 0, 0);
  }
  uint64_t bits;
  __builtin_memcpy(&bits, &acc, sizeof bits);
  return 0x10000000 | (int64_t)((bits ^ bits >> 32) & 0x0FFFFFFF);
}

// Mode 5: pmu_configure from user mode: info, the thread's own cycle
// counter (rising, user code counted), and refusals.
static uint64_t pmu_call(uint64_t op, uint64_t a, uint64_t b) {
  return (uint64_t)sys(CROI_SYS_PMU_CONFIGURE, 0, op, a, b, 0);
}

static int64_t pmu(void) {
  croi_pmu_info_t info = {};
  CHECK(60, pmu_call(CROI_PMU_OP_INFO, (uint64_t)&info, 0) == 0);
  uint32_t cycles[1] = {CROI_PMU_CYCLES};
  if (info.kind == CROI_PMU_KIND_NONE) {
    CHECK(61, pmu_call(CROI_PMU_OP_THREAD_START, 1, (uint64_t)cycles) != 0);
    sys(CROI_SYS_TEST_REPORT, 0, 0, 0, 0, 0);
    return 0x600D;
  }
  CHECK(62, pmu_call(CROI_PMU_OP_THREAD_START, 1, (uint64_t)cycles) == 0);
  uint64_t first[4] = {}, second[4] = {};
  for (volatile int i = 0; i < 100000; i++) {}
  CHECK(63, pmu_call(CROI_PMU_OP_THREAD_READ, (uint64_t)first, 0) == 0 && first[0] > 0);
  for (volatile int i = 0; i < 100000; i++) {}
  CHECK(64, pmu_call(CROI_PMU_OP_THREAD_READ, (uint64_t)second, 0) == 0 && second[0] > first[0]);
  CHECK(65, pmu_call(CROI_PMU_OP_SAMPLE_START, CROI_PMU_CYCLES, 1000000) != 0);  // no resource
  uint32_t bogus[1] = {99};
  CHECK(66, pmu_call(CROI_PMU_OP_THREAD_START, 1, (uint64_t)bogus) != 0);
  CHECK(67, pmu_call(CROI_PMU_OP_THREAD_START, 9, (uint64_t)cycles) != 0);
  CHECK(68, pmu_call(CROI_PMU_OP_THREAD_READ, 0x10, 0) != 0);  // bad pointer
  CHECK(69, pmu_call(CROI_PMU_OP_THREAD_STOP, 0, 0) == 0);
  CHECK(70, pmu_call(CROI_PMU_OP_THREAD_READ, (uint64_t)first, 0) != 0);  // stopped
  sys(CROI_SYS_TEST_REPORT, second[0] - first[0], 0, 0, 0, 0);
  return 0x600D;
}

// Mode 6: processes (K7a). The kernel starts this program as a process and
// passes a startup block (handles it put in our table). We create children
// running this program: each gets its own process handle (as a transferred
// handle, so a process holding itself must still be torn down), runs one
// submode and ends; we check how. Then a job kill and VMARs.
typedef struct {
  uint32_t job, process, vmar, code_vmo;
  uint64_t code_size;
} startup_t;

#define CHILD_CODE 0x1000000ull
#define CHILD_STACK 0x2000000ull
#define STACK_SIZE 16384ull
#define ROOT_VMAR_BASE 0x200000ull
// A thread entered at a C function: on amd64 it expects to have been called.
#if defined(__x86_64__)
#define ENTRY_SP(top) ((top) - 8)
#else
#define ENTRY_SP(top) (top)
#endif

static uint64_t now_ns(void) { return (uint64_t)sys(CROI_SYS_CLOCK_MONOTONIC, 0, 0, 0, 0, 0); }

static uint32_t wait_terminated(uint32_t handle) {
  uint32_t observed = 0;
  sys(CROI_SYS_OBJECT_WAIT_ONE, handle, CROI_SIGNAL_TASK_TERMINATED, now_ns() + 5000000000ull, (uint64_t)&observed,
      0);
  return observed;
}

static int64_t return_code(uint32_t process) {
  croi_process_info_t info = {};
  if (sys(CROI_SYS_PROCESS_INFO, process, (uint64_t)&info, 0, 0, 0) != 0) return 0x7777;
  if ((info.flags & (CROI_PROCESS_INFO_STARTED | CROI_PROCESS_INFO_EXITED)) !=
      (CROI_PROCESS_INFO_STARTED | CROI_PROCESS_INFO_EXITED))
    return 0x7778;
  return info.return_code;
}

static uint32_t make_child(const startup_t *s, uint32_t job, uint32_t *thread_out) {
  uint32_t process = 0, vmar = 0, thread = 0, stack = 0;
  uint64_t at = 0;
  CHECK(80, sys6(CROI_SYS_PROCESS_CREATE, job, (uint64_t)"child", 5, 0, (uint64_t)&process, (uint64_t)&vmar) == 0);
  uint64_t code = vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_EXECUTE | CROI_VM_SPECIFIC) << 32;
  CHECK(81, sys6(CROI_SYS_VMAR_MAP, code, CHILD_CODE - ROOT_VMAR_BASE, s->code_vmo, 0, s->code_size, (uint64_t)&at)
                    == 0 && at == CHILD_CODE);
  CHECK(82, sys(CROI_SYS_VMO_CREATE, STACK_SIZE, 0, (uint64_t)&stack, 0, 0) == 0);
  uint64_t data = vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE | CROI_VM_SPECIFIC) << 32;
  CHECK(83, sys6(CROI_SYS_VMAR_MAP, data, CHILD_STACK - ROOT_VMAR_BASE, stack, 0, STACK_SIZE, (uint64_t)&at) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, stack, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmar, 0, 0, 0, 0);
  CHECK(84, sys6(CROI_SYS_THREAD_CREATE, process, (uint64_t)"main", 4, 0, (uint64_t)&thread, 0) == 0);
  *thread_out = thread;
  return process;
}

static void start_child(uint32_t process, uint32_t thread, uint64_t submode) {
  uint32_t self = 0;
  CHECK(85, sys(CROI_SYS_HANDLE_DUPLICATE, process, RIGHT_SAME, (uint64_t)&self, 0, 0) == 0);
  CHECK(86, sys6(CROI_SYS_PROCESS_START, process, thread, CHILD_CODE, CHILD_STACK + STACK_SIZE, self, submode) == 0);
  CHECK(79, sys6(CROI_SYS_PROCESS_START, process, thread, CHILD_CODE, CHILD_STACK + STACK_SIZE, 0, submode) ==
                ERR_BAD_STATE);  // only once
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
}

static uint32_t spawn_child(const startup_t *s, uint32_t job, uint64_t submode) {
  uint32_t thread = 0;
  uint32_t process = make_child(s, job, &thread);
  start_child(process, thread, submode);
  return process;
}

static void blocker(uint64_t event) {
  uint32_t observed = 0;
  sys(CROI_SYS_OBJECT_WAIT_ONE, event, SIGNALED, ~0ull, (uint64_t)&observed, 0);  // until killed
  sys(CROI_SYS_THREAD_EXIT, 1, 0, 0, 0, 0);
}

// A child: `self` is its own process handle, `submode` what to do.
static int64_t child(uint32_t self, uint64_t submode, uint64_t vdso) {
  switch (submode) {
  case 1:  // exit with a code, having found the vDSO
    return sys(CROI_SYS_PROCESS_EXIT, ((const croi_vdso_header_t *)vdso)->magic == CROI_VDSO_MAGIC ? 42 : 99, 0,
               0, 0, 0);
  case 2:  // spin until killed
    for (;;) {
    }
  case 3:  // fault: the exception kills the process
    *(volatile uint64_t *)0x10 = 1;
    return 98;
  case 4: {  // a second thread blocked in a wait; process_exit ends it too
    uint32_t event = 0, thread = 0, stack = 0;
    uint64_t at = 0;
    if (sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&event, 0, 0, 0) != 0) return 90;
    if (sys(CROI_SYS_VMO_CREATE, STACK_SIZE, 0, (uint64_t)&stack, 0, 0) != 0) return 91;
    if (sys(CROI_SYS_VMO_MAP, stack, 0, STACK_SIZE, 3, (uint64_t)&at) != 0) return 92;
    if (sys6(CROI_SYS_THREAD_CREATE, self, (uint64_t)"blocker", 7, 0, (uint64_t)&thread, 0) != 0) return 93;
    if (sys(CROI_SYS_THREAD_START, thread, (uint64_t)blocker, ENTRY_SP(at + STACK_SIZE), event, 0) != 0) return 94;
    sys(CROI_SYS_NANOSLEEP, now_ns() + 3000000, 0, 0, 0, 0);
    return sys(CROI_SYS_PROCESS_EXIT, 7, 0, 0, 0, 0);
  }
  case 5:  // fault, for a handler to move us (to recovered)
    *(volatile uint64_t *)0x10 = 1;
    return 96;
  case 6: {  // under a job policy: channels denied, bad handles kill
    uint32_t a = 0, b = 0;
    if (sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&a, (uint64_t)&b, 0, 0) != ERR_ACCESS_DENIED) return 55;
    sys(CROI_SYS_HANDLE_CLOSE, 0x12340003, 0, 0, 0, 0);
    return 56;  // survived the kill
  }
  case 7:  // a breakpoint
#if defined(__x86_64__)
    __asm__ volatile("int3");
#elif defined(__aarch64__)
    __asm__ volatile("brk #0");
#elif defined(__riscv)
    __asm__ volatile("ebreak");
#endif
    return 95;
  case 8: {  // NEW_EVENT is DENY_EXCEPTION: a handler sees it, the call is denied
    uint32_t event = 0;
    return sys(CROI_SYS_PROCESS_EXIT, sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&event, 0, 0, 0) == ERR_ACCESS_DENIED ? 60 : 61,
               0, 0, 0, 0);
  }
  }
  return 97;
}

// Where a handler moves a faulting child: exits with value + 1.
__attribute__((noinline)) static void recovered(uint64_t value) {
  sys(CROI_SYS_PROCESS_EXIT, value + 1, 0, 0, 0, 0);
  for (;;) {
  }
}

static int64_t processes(const startup_t *s) {
  uint32_t process = spawn_child(s, s->job, 1);
  CHECK(87, wait_terminated(process) & CROI_SIGNAL_TASK_TERMINATED);
  CHECK(88, return_code(process) == 42);
  uint32_t thread = 0;
  CHECK(89, sys6(CROI_SYS_THREAD_CREATE, process, 0, 0, 0, (uint64_t)&thread, 0) == ERR_BAD_STATE);
  sys(CROI_SYS_HANDLE_CLOSE, process, 0, 0, 0, 0);

  process = spawn_child(s, s->job, 2);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 2000000, 0, 0, 0, 0);
  CHECK(90, sys(CROI_SYS_TASK_KILL, process, 0, 0, 0, 0) == 0);
  CHECK(91, (wait_terminated(process) & CROI_SIGNAL_TASK_TERMINATED) &&
                return_code(process) == CROI_TASK_RETCODE_SYSCALL_KILL);
  sys(CROI_SYS_HANDLE_CLOSE, process, 0, 0, 0, 0);

  process = spawn_child(s, s->job, 3);
  CHECK(92, (wait_terminated(process) & CROI_SIGNAL_TASK_TERMINATED) &&
                return_code(process) == CROI_TASK_RETCODE_EXCEPTION_KILL);
  sys(CROI_SYS_HANDLE_CLOSE, process, 0, 0, 0, 0);

  process = spawn_child(s, s->job, 4);
  CHECK(93, (wait_terminated(process) & CROI_SIGNAL_TASK_TERMINATED) && return_code(process) == 7);
  sys(CROI_SYS_HANDLE_CLOSE, process, 0, 0, 0, 0);

  uint32_t job = 0, vmar = 0;
  CHECK(94, sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&job, 0, 0) == 0);
  process = spawn_child(s, job, 2);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 2000000, 0, 0, 0, 0);
  CHECK(95, sys(CROI_SYS_TASK_KILL, job, 0, 0, 0, 0) == 0);
  CHECK(96, wait_terminated(process) & CROI_SIGNAL_TASK_TERMINATED);
  CHECK(296, return_code(process) == CROI_TASK_RETCODE_SYSCALL_KILL);
  sys(CROI_SYS_HANDLE_CLOSE, process, 0, 0, 0, 0);
  CHECK(97, sys6(CROI_SYS_PROCESS_CREATE, job, 0, 0, 0, (uint64_t)&process, (uint64_t)&vmar) == ERR_BAD_STATE);
  sys(CROI_SYS_HANDLE_CLOSE, job, 0, 0, 0, 0);

  // VMARs: a sub-region that may map read/write, not execute.
  uint32_t sub = 0, vmo = 0;
  uint64_t base = 0, at = 0;
  uint64_t parent = s->vmar | (uint64_t)(CROI_VM_CAN_MAP_READ | CROI_VM_CAN_MAP_WRITE) << 32;
  CHECK(98, sys6(CROI_SYS_VMAR_ALLOCATE, parent, 0, 65536, (uint64_t)&sub, (uint64_t)&base, 0) == 0);
  CHECK(99, sys(CROI_SYS_VMO_CREATE, 8192, 0, (uint64_t)&vmo, 0, 0) == 0);
  uint64_t rw = sub | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32;
  CHECK(100, sys6(CROI_SYS_VMAR_MAP, rw, 0, vmo, 0, 8192, (uint64_t)&at) == 0 && at >= base && at < base + 65536);
  *(volatile uint64_t *)at = 0x1234;
  CHECK(101, *(volatile uint64_t *)at == 0x1234);
  uint64_t rx = sub | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_EXECUTE) << 32;
  CHECK(102, sys6(CROI_SYS_VMAR_MAP, rx, 0, vmo, 0, 8192, (uint64_t)&at) == ERR_ACCESS_DENIED);
  CHECK(103, sys(CROI_SYS_VMAR_PROTECT, sub | (uint64_t)CROI_VM_PERM_READ << 32, at, 8192, 0, 0) == 0);
  CHECK(104, *(volatile uint64_t *)at == 0x1234);
  CHECK(105, sys(CROI_SYS_VMAR_UNMAP, sub, at, 8192, 0, 0) == 0);
  CHECK(106, sys(CROI_SYS_VMAR_DESTROY, sub, 0, 0, 0, 0) == 0);
  CHECK(107, sys6(CROI_SYS_VMAR_MAP, rw, 0, vmo, 0, 8192, (uint64_t)&at) == ERR_BAD_STATE ||
                 sys6(CROI_SYS_VMAR_MAP, rw, 0, vmo, 0, 8192, (uint64_t)&at) < 0);
  sys(CROI_SYS_HANDLE_CLOSE, sub, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  return 0x600D;
}

// Mode 7: channels, eventpairs and calls (K7b), as a process. A server
// thread answers calls; the client binds itself to a deadline context the
// kernel provides (test_profile) and checks the server ran on it while
// serving (ext 2). The last call's flow id goes to the kernel, which finds
// it in the ipc trace records.
static int64_t chan_read(uint32_t channel, void *bytes, uint32_t *handles, uint32_t num_bytes, uint32_t num_handles,
                         uint32_t actual[2]) {
  return sys6(CROI_SYS_CHANNEL_READ, channel, 0, (uint64_t)bytes, (uint64_t)handles,
              num_bytes | (uint64_t)num_handles << 32, (uint64_t)actual);
}

static int64_t chan_write(uint32_t channel, const void *bytes, uint32_t num_bytes, const uint32_t *handles,
                          uint32_t num_handles) {
  return sys6(CROI_SYS_CHANNEL_WRITE, channel, 0, (uint64_t)bytes, num_bytes, (uint64_t)handles, num_handles);
}

static uint32_t wait_for(uint32_t handle, uint32_t signals, uint64_t ns) {
  uint32_t observed = 0;
  sys(CROI_SYS_OBJECT_WAIT_ONE, handle, signals, now_ns() + ns, (uint64_t)&observed, 0);
  return observed;
}

// Answers calls: reply = txid, request + 1, whether it is running on a
// deadline profile now. "quit" ends it.
static void server(uint64_t channel) {
  uint32_t buffer[16];
  uint32_t actual[2];
  for (;;) {
    uint32_t observed = wait_for((uint32_t)channel, CROI_SIGNAL_READABLE | CROI_SIGNAL_PEER_CLOSED, 10000000000ull);
    if (chan_read((uint32_t)channel, buffer, 0, sizeof buffer, 0, actual) != 0) {
      if (observed & CROI_SIGNAL_PEER_CLOSED) break;
      continue;
    }
    if (actual[0] == 8 && buffer[1] == 0x74697571) break;  // "quit"
    // Work for 1 ms, then look, giving it up to 50 ms: the caller lends its
    // profile once it has blocked on the call, which can be just after we
    // read it (or, under emulation, rather later).
    uint64_t until = now_ns() + 1000000, give_up = now_ns() + 50000000;
    while (now_ns() < until) {
    }
    while (sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0) != 1 && now_ns() < give_up) {
    }
    uint32_t reply[3] = {buffer[0], buffer[1] + 1, (uint32_t)sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0)};
    chan_write((uint32_t)channel, reply, sizeof reply, 0, 0);
  }
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// Calls on a channel nobody answers; its result goes to *(int64_t *)slot.
static void lonely_caller(uint64_t slot) {
  uint64_t *out = (uint64_t *)slot;
  uint32_t request[2] = {0, 1}, reply[4];
  croi_channel_call_args_t args = {(uint64_t)request, 0, (uint64_t)reply, 0, sizeof request, 0, sizeof reply, 0};
  uint32_t bytes = 0, handles = 0;
  out[1] = (uint64_t)sys6(CROI_SYS_CHANNEL_CALL, (uint32_t)out[0], 0, now_ns() + 5000000000ull, (uint64_t)&args,
                          (uint64_t)&bytes, (uint64_t)&handles);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static uint32_t start_thread(const startup_t *s, void (*entry)(uint64_t), uint64_t arg) {
  uint32_t thread = 0, stack = 0;
  uint64_t at = 0;
  CHECK(140, sys(CROI_SYS_VMO_CREATE, STACK_SIZE, 0, (uint64_t)&stack, 0, 0) == 0);
  CHECK(141, sys(CROI_SYS_VMO_MAP, stack, 0, STACK_SIZE, 3, (uint64_t)&at) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, stack, 0, 0, 0, 0);
  CHECK(142, sys6(CROI_SYS_THREAD_CREATE, s->process, (uint64_t)"t", 1, 0, (uint64_t)&thread, 0) == 0);
  CHECK(143, sys(CROI_SYS_THREAD_START, thread, (uint64_t)entry, ENTRY_SP(at + STACK_SIZE), arg, 0) == 0);
  return thread;
}

static int64_t ipc(const startup_t *s) {
  uint32_t a = 0, b = 0;
  CHECK(110, sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&a, (uint64_t)&b, 0, 0) == 0);
  croi_info_handle_basic_t ia = {}, ib = {};
  CHECK(111, sys(CROI_SYS_OBJECT_GET_INFO, a, CROI_INFO_HANDLE_BASIC, (uint64_t)&ia, sizeof ia, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_INFO, b, CROI_INFO_HANDLE_BASIC, (uint64_t)&ib, sizeof ib, 0) == 0 &&
                 ia.related_koid == ib.koid && ib.related_koid == ia.koid && ia.type == 4);
  uint32_t actual[2] = {0, 0}, handles[4];
  char buffer[64];
  CHECK(112, chan_read(b, buffer, handles, sizeof buffer, 4, actual) == ERR_SHOULD_WAIT);

  // A message with a handle: the handle leaves our table and works there.
  uint32_t event = 0, dup = 0;
  CHECK(113, sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&event, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, event, RIGHT_SAME, (uint64_t)&dup, 0, 0) == 0);
  CHECK(114, chan_write(a, "hello", 5, &dup, 1) == 0);
  CHECK(115, sys(CROI_SYS_HANDLE_CLOSE, dup, 0, 0, 0, 0) == ERR_BAD_HANDLE);
  CHECK(116, wait_for(b, CROI_SIGNAL_READABLE, 1000000000) & CROI_SIGNAL_READABLE);
  CHECK(117, chan_read(b, buffer, handles, 2, 1, actual) == ERR_BUFFER_TOO_SMALL && actual[0] == 5 && actual[1] == 1);
  CHECK(118, chan_read(b, buffer, handles, sizeof buffer, 4, actual) == 0 && actual[0] == 5 && actual[1] == 1 &&
                 buffer[0] == 'h' && buffer[4] == 'o');
  CHECK(119, sys(CROI_SYS_OBJECT_SIGNAL, handles[0], 0, SIGNALED, 0, 0) == 0 &&
                 (wait_for(event, SIGNALED, 1000000000) & SIGNALED));
  CHECK(120, !(wait_for(b, CROI_SIGNAL_READABLE, 0) & CROI_SIGNAL_READABLE));
  // Refusals: the channel itself; a handle without TRANSFER (it stays).
  CHECK(121, chan_write(a, "x", 1, &a, 1) == ERR_NOT_SUPPORTED);
  uint32_t no_transfer = 0;
  CHECK(122, sys(CROI_SYS_HANDLE_DUPLICATE, event, RIGHT_WAIT, (uint64_t)&no_transfer, 0, 0) == 0 &&
                 chan_write(a, "x", 1, &no_transfer, 1) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_HANDLE_CLOSE, no_transfer, 0, 0, 0, 0) == 0);
  // Peer closed: signal, writes refused, reads drain then refuse.
  CHECK(123, chan_write(a, "bye", 3, 0, 0) == 0 && sys(CROI_SYS_HANDLE_CLOSE, a, 0, 0, 0, 0) == 0);
  CHECK(124, wait_for(b, CROI_SIGNAL_PEER_CLOSED, 1000000000) & CROI_SIGNAL_PEER_CLOSED);
  CHECK(125, chan_write(b, "x", 1, 0, 0) == ERR_PEER_CLOSED);
  CHECK(126, chan_read(b, buffer, handles, sizeof buffer, 4, actual) == 0 && actual[0] == 3);
  CHECK(127, chan_read(b, buffer, handles, sizeof buffer, 4, actual) == ERR_PEER_CLOSED);
  sys(CROI_SYS_HANDLE_CLOSE, b, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, handles[0], 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, event, 0, 0, 0, 0);

  // Eventpairs.
  uint32_t p = 0, q = 0;
  CHECK(128, sys(CROI_SYS_EVENTPAIR_CREATE, 0, (uint64_t)&p, (uint64_t)&q, 0, 0) == 0);
  CHECK(129, sys(CROI_SYS_OBJECT_SIGNAL_PEER, p, 0, SIGNALED, 0, 0) == 0 && (wait_for(q, SIGNALED, 1000000000) & SIGNALED));
  CHECK(130, sys(CROI_SYS_HANDLE_CLOSE, p, 0, 0, 0, 0) == 0 &&
                 (wait_for(q, CROI_SIGNAL_PEER_CLOSED, 1000000000) & CROI_SIGNAL_PEER_CLOSED));
  sys(CROI_SYS_HANDLE_CLOSE, q, 0, 0, 0, 0);

  // Calls to a server thread; the client on a deadline profile lends it.
  uint32_t client = 0, served = 0;
  CHECK(131, sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&client, (uint64_t)&served, 0, 0) == 0);
  uint32_t server_thread = start_thread(s, server, served);
  int donating = sys(CROI_SYS_TEST_PROFILE, 1, 0, 0, 0, 0) == 0;
  CHECK(132, donating && sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0) == 1);
  uint32_t request[2] = {0, 41}, reply[4] = {0, 0, 0, 0};
  croi_channel_call_args_t args = {(uint64_t)request, 0, (uint64_t)reply, 0, sizeof request, 0, sizeof reply, 0};
  uint32_t got_bytes = 0, got_handles = 0;
  for (int i = 0; i < 3; i++) {
    request[1] = 41 + (uint32_t)i;
    CHECK(133, sys6(CROI_SYS_CHANNEL_CALL, client, 0, now_ns() + 2000000000ull, (uint64_t)&args, (uint64_t)&got_bytes,
                    (uint64_t)&got_handles) == 0 && got_bytes == 12 && reply[1] == 42 + (uint32_t)i &&
                   (reply[0] & 0x80000000u));
    CHECK(134, reply[2] == 1);  // the server ran on our deadline
  }
  uint32_t last_txid = reply[0];
  CHECK(135, sys(CROI_SYS_TEST_PROFILE, 2, 0, 0, 0, 0) == 0);
  CHECK(136, sys6(CROI_SYS_CHANNEL_CALL, client, 0, now_ns() + 2000000000ull, (uint64_t)&args, (uint64_t)&got_bytes,
                  (uint64_t)&got_handles) == 0 && reply[2] == 0);  // fair caller: nothing lent
  // A call that times out; its reply then arrives as an ordinary message.
  CHECK(137, sys6(CROI_SYS_CHANNEL_CALL, client, 0, now_ns(), (uint64_t)&args, (uint64_t)&got_bytes,
                  (uint64_t)&got_handles) == ERR_TIMED_OUT);
  CHECK(138, (wait_for(client, CROI_SIGNAL_READABLE, 1000000000) & CROI_SIGNAL_READABLE) &&
                 chan_read(client, buffer, handles, sizeof buffer, 4, actual) == 0 && actual[0] == 12);
  uint32_t quit[2] = {0, 0x74697571};
  CHECK(139, chan_write(client, quit, sizeof quit, 0, 0) == 0);
  CHECK(144, wait_for(server_thread, CROI_SIGNAL_TASK_TERMINATED, 2000000000) & CROI_SIGNAL_TASK_TERMINATED);
  croi_info_handle_basic_t ic = {};
  sys(CROI_SYS_OBJECT_GET_INFO, client, CROI_INFO_HANDLE_BASIC, (uint64_t)&ic, sizeof ic, 0);
  uint64_t channel_id = ic.koid < ic.related_koid ? ic.koid : ic.related_koid;
  sys(CROI_SYS_HANDLE_CLOSE, client, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, served, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, server_thread, 0, 0, 0, 0);

  // A call whose peer closes while it waits.
  uint32_t x = 0, y = 0;
  CHECK(145, sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&x, (uint64_t)&y, 0, 0) == 0);
  uint64_t slot[2] = {x, 1};
  uint32_t caller = start_thread(s, lonely_caller, (uint64_t)slot);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 3000000, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, y, 0, 0, 0, 0);
  CHECK(146, (wait_for(caller, CROI_SIGNAL_TASK_TERMINATED, 2000000000) & CROI_SIGNAL_TASK_TERMINATED) &&
                 (int64_t)slot[1] == ERR_PEER_CLOSED);
  sys(CROI_SYS_HANDLE_CLOSE, caller, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, x, 0, 0, 0, 0);

  sys(CROI_SYS_TEST_REPORT, croi_flow_id(channel_id, last_txid), 0, 0, 0, 0);
  return 0x600D;
}

// Mode 8: futexes and timers (K7c), as a process. Waiter threads report
// through slots on our stack: [0] the futex word's address, [1] the
// result, [2] done.
static void futex_waiter(uint64_t arg) {
  volatile uint64_t *slot = (volatile uint64_t *)arg;
  slot[1] = (uint64_t)sys(CROI_SYS_FUTEX_WAIT, slot[0], 0, 0, now_ns() + 3000000000ull, 0);
  slot[2] = 1;
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// The owner in the inheritance check: once it sees itself on a deadline
// profile (lent by the waiter), it records that and its koid as the
// futex's owner reports it, and wakes the waiter. slot: [0] word address,
// [1] seen deadline, [2] owner koid, [3] done.
static void futex_owner(uint64_t arg) {
  volatile uint64_t *slot = (volatile uint64_t *)arg;
  uint64_t give_up = now_ns() + 2000000000ull;
  while (now_ns() < give_up && sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0) != 1) {
  }
  slot[1] = (uint64_t)sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0);
  uint64_t koid = 0;
  sys(CROI_SYS_FUTEX_GET_OWNER, slot[0], (uint64_t)&koid, 0, 0, 0);
  slot[2] = koid;
  sys(CROI_SYS_FUTEX_WAKE, slot[0], 1, 0, 0, 0);
  slot[3] = 1;
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static uint64_t koid_of(uint32_t handle) {
  croi_info_handle_basic_t info = {};
  sys(CROI_SYS_OBJECT_GET_INFO, handle, CROI_INFO_HANDLE_BASIC, (uint64_t)&info, sizeof info, 0);
  return info.koid;
}

static void join(uint32_t thread) {
  wait_for(thread, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull);
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
}

static int64_t sync_objects(const startup_t *s) {
  volatile uint32_t words[4] = {0, 0, 0, 0};
  uint64_t a = (uint64_t)&words[0], b = (uint64_t)&words[1], c = (uint64_t)&words[2];
  CHECK(150, sys(CROI_SYS_FUTEX_WAIT, a, 1, 0, now_ns() + 1000000000ull, 0) == ERR_BAD_STATE);
  CHECK(151, sys(CROI_SYS_FUTEX_WAIT, a, 0, 0, now_ns(), 0) == ERR_TIMED_OUT);
  CHECK(152, sys(CROI_SYS_FUTEX_WAIT, a + 1, 0, 0, now_ns(), 0) == ERR_INVALID_ARGS);
  CHECK(153, sys(CROI_SYS_FUTEX_WAKE, a, 10, 0, 0, 0) == 0);  // nobody waiting

  // Inheritance: we wait on a deadline profile with a fair thread as the
  // futex's owner; it must run on our deadline until it wakes us.
  volatile uint64_t owner_slot[4] = {a, 0, 0, 0};
  uint32_t owner = start_thread(s, futex_owner, (uint64_t)owner_slot);
  CHECK(154, sys(CROI_SYS_TEST_PROFILE, 1, 0, 0, 0, 0) == 0);
  CHECK(155, sys(CROI_SYS_FUTEX_WAIT, a, 0, owner, now_ns() + 3000000000ull, 0) == 0);
  CHECK(156, sys(CROI_SYS_TEST_PROFILE, 2, 0, 0, 0, 0) == 0);
  wait_for(owner, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull);
  CHECK(157, owner_slot[3] == 1 && owner_slot[1] == 1);  // it ran on our deadline
  CHECK(158, owner_slot[2] == koid_of(owner));          // and was the futex's owner
  sys(CROI_SYS_HANDLE_CLOSE, owner, 0, 0, 0, 0);
  uint64_t koid = 1;
  CHECK(159, sys(CROI_SYS_FUTEX_GET_OWNER, a, (uint64_t)&koid, 0, 0, 0) == 0 && koid == 0);  // wake cleared it

  // Requeue: two waiters on a, moved to b, woken there.
  volatile uint64_t w1[3] = {a, 99, 0}, w2[3] = {a, 99, 0};
  uint32_t t1 = start_thread(s, futex_waiter, (uint64_t)w1), t2 = start_thread(s, futex_waiter, (uint64_t)w2);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 5000000, 0, 0, 0, 0);
  CHECK(160, sys6(CROI_SYS_FUTEX_REQUEUE, a, 0, 0, b, 2, 0) == 0);
  CHECK(161, sys(CROI_SYS_FUTEX_WAKE, a, 10, 0, 0, 0) == 0 && w1[2] == 0 && w2[2] == 0);  // nobody left on a
  CHECK(162, sys(CROI_SYS_FUTEX_WAKE, b, 2, 0, 0, 0) == 0);
  join(t1);
  join(t2);
  CHECK(163, w1[2] == 1 && w2[2] == 1 && w1[1] == 0 && w2[1] == 0);

  // wake_single_owner: one waiter wakes and owns the futex.
  volatile uint64_t w3[3] = {c, 99, 0}, w4[3] = {c, 99, 0};
  uint32_t t3 = start_thread(s, futex_waiter, (uint64_t)w3), t4 = start_thread(s, futex_waiter, (uint64_t)w4);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 5000000, 0, 0, 0, 0);
  CHECK(164, sys(CROI_SYS_FUTEX_WAKE_SINGLE_OWNER, c, 0, 0, 0, 0) == 0);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 2000000, 0, 0, 0, 0);
  CHECK(165, (w3[2] == 1) != (w4[2] == 1));
  uint32_t woke = w3[2] == 1 ? t3 : t4;
  koid = 0;
  CHECK(166, sys(CROI_SYS_FUTEX_GET_OWNER, c, (uint64_t)&koid, 0, 0, 0) == 0 &&
                 (koid == koid_of(woke) || koid == 0));  // 0 once the woken thread has exited
  CHECK(167, sys(CROI_SYS_FUTEX_WAKE, c, 1, 0, 0, 0) == 0);
  join(t3);
  join(t4);
  CHECK(168, w3[1] == 0 && w4[1] == 0);

  // Timers.
  uint32_t timer = 0;
  CHECK(170, sys(CROI_SYS_TIMER_CREATE, CROI_TIMER_SLACK_LATE, 0, (uint64_t)&timer, 0, 0) == 0);
  uint64_t deadline = now_ns() + 5000000;
  CHECK(171, sys(CROI_SYS_TIMER_SET, timer, deadline, 0, 0, 0) == 0);
  CHECK(172, (wait_for(timer, SIGNALED, 2000000000ull) & SIGNALED) && now_ns() >= deadline);
  CHECK(173, sys(CROI_SYS_TIMER_SET, timer, now_ns() + 50000000, 0, 0, 0) == 0 &&
                 !(wait_for(timer, SIGNALED, 0) & SIGNALED));  // a set clears SIGNALED
  CHECK(174, sys(CROI_SYS_TIMER_CANCEL, timer, 0, 0, 0, 0) == 0 &&
                 !(wait_for(timer, SIGNALED, 100000000) & SIGNALED));
  CHECK(175, sys(CROI_SYS_TIMER_SET, timer, 1, 0, 0, 0) == 0 &&
                 (wait_for(timer, SIGNALED, 1000000000) & SIGNALED));  // already due
  // A deadline profile gets zero slack: half a second of late slack ignored.
  CHECK(176, sys(CROI_SYS_TEST_PROFILE, 1, 0, 0, 0, 0) == 0);
  deadline = now_ns() + 5000000;
  CHECK(177, sys(CROI_SYS_TIMER_SET, timer, deadline, 500000000, 0, 0) == 0);
  CHECK(178, (wait_for(timer, SIGNALED, 2000000000ull) & SIGNALED) && now_ns() < deadline + 200000000);
  CHECK(179, sys(CROI_SYS_TEST_PROFILE, 2, 0, 0, 0, 0) == 0);
  // Closing an armed timer: it fires later, harmlessly.
  CHECK(180, sys(CROI_SYS_TIMER_SET, timer, now_ns() + 20000000, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, timer, 0, 0, 0, 0) == 0);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 60000000, 0, 0, 0, 0);
  return 0x600D;
}

// Mode 9: exceptions and job policy (K7d), as a process.
#define ERR_ALREADY_BOUND (-27)
#define ERR_ALREADY_EXISTS (-26)

// Takes one exception from `channel`: checks its type and process, and
// either passes it on (state < 0: TRY_NEXT), or sets `state` (moving the
// thread to recovered(value) when HANDLED).
static void handle_exception(uint32_t channel, uint32_t process, uint32_t type, int state, uint64_t value) {
  croi_exception_info_t info = {};
  uint32_t exception = 0, actual[2] = {0, 0};
  CHECK(185, wait_for(channel, CROI_SIGNAL_READABLE, 5000000000ull) & CROI_SIGNAL_READABLE);
  CHECK(186, chan_read(channel, &info, &exception, sizeof info, 1, actual) == 0 && actual[0] == sizeof info &&
                 actual[1] == 1);
  CHECK(187, info.type == type && info.pid == koid_of(process));
  if (state < 0) {
    sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0);
    return;
  }
  if (state == CROI_EXCEPTION_STATE_HANDLED) {
    uint32_t thread = 0;
    croi_thread_state_general_regs_t regs;
    CHECK(188, sys(CROI_SYS_EXCEPTION_GET_THREAD, exception, (uint64_t)&thread, 0, 0, 0) == 0 &&
                   sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) == 0);
#if defined(__x86_64__)
    regs.rip = (uint64_t)recovered;
    regs.rdi = value;
    regs.rsp = (regs.rsp & ~15ull) - 8;
#elif defined(__aarch64__)
    regs.pc = (uint64_t)recovered;
    regs.r[0] = value;
    regs.sp &= ~15ull;
#elif defined(__riscv)
    regs.pc = (uint64_t)recovered;
    regs.x[9] = value;  // a0
    regs.x[1] &= ~15ull;  // sp
#endif
    CHECK(189, sys(CROI_SYS_THREAD_WRITE_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) == 0);
    sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
  }
  uint32_t value32 = (uint32_t)state;
  CHECK(184, sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&value32, 4, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0);
}

static uint32_t exception_channel(uint32_t task) {
  uint32_t channel = 0;
  CHECK(183, sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, task, 0, (uint64_t)&channel, 0, 0) == 0);
  return channel;
}

static int64_t finished(uint32_t process) {
  CHECK(182, wait_for(process, CROI_SIGNAL_TASK_TERMINATED, 5000000000ull) & CROI_SIGNAL_TASK_TERMINATED);
  int64_t code = return_code(process);
  sys(CROI_SYS_HANDLE_CLOSE, process, 0, 0, 0, 0);
  return code;
}

static int64_t exceptions(const startup_t *s) {
  uint32_t thread = 0, channel = 0, other = 0;

  // A process's handler moves the faulting thread on.
  uint32_t process = make_child(s, s->job, &thread);
  channel = exception_channel(process);
  CHECK(190, sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, process, 0, (uint64_t)&other, 0, 0) == ERR_ALREADY_BOUND);
  start_child(process, thread, 5);
  handle_exception(channel, process, CROI_EXCP_FATAL_PAGE_FAULT, CROI_EXCEPTION_STATE_HANDLED, 77);
  CHECK(191, finished(process) == 78);
  sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);

  // Order: the process's channel passes it on, the job's takes it.
  uint32_t job = 0;
  CHECK(192, sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&job, 0, 0) == 0);
  uint32_t job_channel = exception_channel(job);
  process = make_child(s, job, &thread);
  channel = exception_channel(process);
  start_child(process, thread, 5);
  handle_exception(channel, process, CROI_EXCP_FATAL_PAGE_FAULT, -1, 0);
  handle_exception(job_channel, process, CROI_EXCP_FATAL_PAGE_FAULT, CROI_EXCEPTION_STATE_HANDLED, 80);
  CHECK(193, finished(process) == 81);
  sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);

  // A breakpoint; then THREAD_EXIT (its only thread: the process ends, 0).
  process = make_child(s, job, &thread);
  channel = exception_channel(process);
  start_child(process, thread, 7);
  handle_exception(channel, process, CROI_EXCP_SW_BREAKPOINT, CROI_EXCEPTION_STATE_HANDLED, 90);
  CHECK(194, finished(process) == 91);
  sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);
  process = make_child(s, job, &thread);
  channel = exception_channel(process);
  start_child(process, thread, 5);
  handle_exception(channel, process, CROI_EXCP_FATAL_PAGE_FAULT, -1, 0);  // process: next
  handle_exception(job_channel, process, CROI_EXCP_FATAL_PAGE_FAULT, CROI_EXCEPTION_STATE_THREAD_EXIT, 0);
  CHECK(195, finished(process) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, job_channel, 0, 0, 0, 0);

  // No handler listening (its channel closed): the exception kills.
  process = make_child(s, job, &thread);
  channel = exception_channel(process);
  sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);
  start_child(process, thread, 5);
  CHECK(196, finished(process) == CROI_TASK_RETCODE_EXCEPTION_KILL);
  sys(CROI_SYS_HANDLE_CLOSE, job, 0, 0, 0, 0);

  // Job policy: channels denied, a bad handle kills; inherited by a child
  // job; fixed once the job has children; ABSOLUTE conflicts refused.
  uint32_t strict = 0, inner = 0;
  CHECK(197, sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&strict, 0, 0) == 0);
  croi_policy_basic_t policy[2] = {{CROI_POL_NEW_CHANNEL, CROI_POL_ACTION_DENY},
                                   {CROI_POL_BAD_HANDLE, CROI_POL_ACTION_KILL}};
  CHECK(198, sys(CROI_SYS_JOB_SET_POLICY, strict, CROI_JOB_POL_ABSOLUTE, 0, (uint64_t)policy, 2) == 0);
  croi_policy_basic_t conflict = {CROI_POL_NEW_CHANNEL, CROI_POL_ACTION_KILL};
  CHECK(199, sys(CROI_SYS_JOB_SET_POLICY, strict, CROI_JOB_POL_ABSOLUTE, 0, (uint64_t)&conflict, 1) == ERR_ALREADY_EXISTS &&
                 sys(CROI_SYS_JOB_SET_POLICY, strict, CROI_JOB_POL_RELATIVE, 0, (uint64_t)&conflict, 1) == 0);
  CHECK(200, sys(CROI_SYS_JOB_CREATE, strict, 0, (uint64_t)&inner, 0, 0) == 0);
  CHECK(201, sys(CROI_SYS_JOB_SET_POLICY, strict, CROI_JOB_POL_RELATIVE, 0, (uint64_t)policy, 2) == ERR_BAD_STATE);
  process = spawn_child(s, strict, 6);
  CHECK(202, finished(process) == CROI_TASK_RETCODE_POLICY_KILL);
  process = spawn_child(s, inner, 6);
  CHECK(203, finished(process) == CROI_TASK_RETCODE_POLICY_KILL);
  sys(CROI_SYS_HANDLE_CLOSE, inner, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, strict, 0, 0, 0, 0);

  // DENY_EXCEPTION: a POLICY_ERROR exception, then the call is denied.
  uint32_t watched = 0;
  CHECK(204, sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&watched, 0, 0) == 0);
  croi_policy_basic_t events = {CROI_POL_NEW_EVENT, CROI_POL_ACTION_DENY_EXCEPTION};
  CHECK(205, sys(CROI_SYS_JOB_SET_POLICY, watched, CROI_JOB_POL_ABSOLUTE, 0, (uint64_t)&events, 1) == 0);
  job_channel = exception_channel(watched);
  process = spawn_child(s, watched, 8);
  uint32_t resume = CROI_EXCEPTION_STATE_HANDLED;
  {
    croi_exception_info_t info = {};
    uint32_t exception = 0, actual[2] = {0, 0};
    CHECK(206, (wait_for(job_channel, CROI_SIGNAL_READABLE, 5000000000ull) & CROI_SIGNAL_READABLE) &&
                   chan_read(job_channel, &info, &exception, sizeof info, 1, actual) == 0 &&
                   info.type == CROI_EXCP_POLICY_ERROR);
    sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&resume, 4, 0);
    sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0);
  }
  CHECK(207, finished(process) == 60);
  sys(CROI_SYS_HANDLE_CLOSE, job_channel, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, watched, 0, 0, 0, 0);
  return 0x600D;
}

// Mode 4: something to sample. Three frames deep, spin for `ns`, with a
// clock syscall every 64 iterations (so some samples land in the kernel
// and must continue into these frames).
__attribute__((noinline)) static uint64_t spin3(uint64_t ns) {
  uint64_t end = (uint64_t)sys(CROI_SYS_CLOCK_MONOTONIC, 0, 0, 0, 0, 0) + ns, n = 0;
  for (;;) {
    for (int i = 0; i < 64; i++) __asm__ volatile("" ::: "memory");
    n++;
    if ((uint64_t)sys(CROI_SYS_CLOCK_MONOTONIC, 0, 0, 0, 0, 0) >= end) return n;
  }
}
__attribute__((noinline)) static uint64_t spin2(uint64_t ns) { return spin3(ns) + 1; }
__attribute__((noinline)) static uint64_t spin1(uint64_t ns) { return spin2(ns) + 1; }

// Entered straight from the kernel with a 16-byte aligned stack. On amd64
// a C function expects to have been called (8 off), so _start is a stub
// that calls test_main, as a crt0 would.
#if defined(__x86_64__)
__asm__(".section .text.start, \"ax\"\n"
        ".globl _start\n"
        "_start:\n"
        "  xor %ebp, %ebp\n"
        "  call test_main\n"
        "  ud2\n"
        ".text\n");
[[noreturn]] __attribute__((used)) void test_main(uint64_t mode, uint64_t handle, uint64_t vdso_base) {
#else
__attribute__((section(".text.start"))) [[noreturn]] void _start(uint64_t mode, uint64_t handle, uint64_t vdso_base) {
#endif
  exit_with(mode == 1   ? marks((uint32_t)handle)
            : mode == 2 ? vdso(handle)
            : mode == 3 ? registers(handle & 0xFFFF, handle >> 16 & 1)
            : mode == 4 ? (spin1(handle) > 2 ? 0x600D : 1)
            : mode == 5 ? pmu()
            : mode == 6 ? processes((const startup_t *)handle)
            : mode == 7 ? ipc((const startup_t *)handle)
            : mode == 8 ? sync_objects((const startup_t *)handle)
            : mode == 9 ? exceptions((const startup_t *)handle)
            : mode >= 0x400 ? child((uint32_t)mode, handle, vdso_base)
                        : objects());
}
