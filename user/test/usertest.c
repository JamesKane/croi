// The boot self-test's user program (K6b): exercises the object syscalls
// from user mode and exits with 0x600D, or with the number of the first
// check that failed. arg0 selects a mode; arg1 is a handle the kernel
// gave it (mode 1: a tracing resource).

#include <croi/syscall.h>

#include "pmu.h"
#include "shared.h"

#define ERR_BAD_HANDLE (-11)
#define ERR_INVALID_ARGS (-10)
#define ERR_OUT_OF_RANGE (-14)
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
  // Sizes round up to a page, as Zircon's do.
  uint32_t odd = 0;
  uint64_t odd_size = 0;
  CHECK(169, sys(CROI_SYS_VMO_CREATE, 3584, 0, (uint64_t)&odd, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_GET_SIZE, odd, (uint64_t)&odd_size, 0, 0, 0) == 0 && odd_size == 4096 &&
                 sys(CROI_SYS_HANDLE_CLOSE, odd, 0, 0, 0, 0) == 0);
  CHECK(181, sys(CROI_SYS_VMO_CREATE, ~0ull, 0, (uint64_t)&odd, 0, 0) == ERR_OUT_OF_RANGE);
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
  // cache_flush (version 2): user cache maintenance is allowed (arm64
  // SCTLR_EL1.UCI; rv64 senvcfg.CBCFE), so these don't trap.
  int32_t (*cache_flush)(const void *, uint64_t, uint32_t) =
      (int32_t (*)(const void *, uint64_t, uint32_t))(base + header->cache_flush);
  uint8_t lines[512];
  CHECK(54, header->version >= 2 && (t->dcache_line == 0 || (t->dcache_line & (t->dcache_line - 1)) == 0) &&
                cache_flush(lines + 3, 300, CROI_CACHE_FLUSH_DATA) == 0 &&
                cache_flush(lines, sizeof lines, CROI_CACHE_FLUSH_DATA | CROI_CACHE_FLUSH_INVALIDATE) == 0 &&
                cache_flush(lines, sizeof lines, CROI_CACHE_FLUSH_DATA | CROI_CACHE_FLUSH_INSN) == 0 &&
                cache_flush(lines, sizeof lines, CROI_CACHE_FLUSH_INVALIDATE) == ERR_INVALID_ARGS &&
                cache_flush(lines, sizeof lines, 0) == ERR_INVALID_ARGS);

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
  uint32_t resource, padding;  // the root resource
  uint32_t bootdata, padding2;  // the boot data VMO (read only)
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
  case 9: {  // in a job with reserved CPUs: exit with the CPUs it ran on
    uint64_t seen = 0;
    for (int i = 0; i < 300; i++) {
      seen |= 1ull << sys(CROI_SYS_TEST_PROFILE, 5, 0, 0, 0, 0);
      if (i % 10 == 0) sys(CROI_SYS_NANOSLEEP, now_ns() + 100000, 0, 0, 0, 0);
    }
    return sys(CROI_SYS_PROCESS_EXIT, (int64_t)seen, 0, 0, 0, 0);
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
  // Refusals consume the handles listed, as Zircon's do (unless the list
  // can't be read): without TRANSFER (the first error wins, the rest go
  // too); a repeat (gone by the second look); a bad channel handle.
  uint32_t two[2] = {0, 0};
  CHECK(122, sys(CROI_SYS_HANDLE_DUPLICATE, event, RIGHT_WAIT, (uint64_t)&two[0], 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, event, RIGHT_SAME, (uint64_t)&two[1], 0, 0) == 0 &&
                 chan_write(a, "x", 1, two, 2) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_HANDLE_CLOSE, two[0], 0, 0, 0, 0) == ERR_BAD_HANDLE &&
                 sys(CROI_SYS_HANDLE_CLOSE, two[1], 0, 0, 0, 0) == ERR_BAD_HANDLE);
  CHECK(147, sys(CROI_SYS_HANDLE_DUPLICATE, event, RIGHT_SAME, (uint64_t)&two[0], 0, 0) == 0 && (two[1] = two[0]) &&
                 chan_write(a, "x", 1, two, 2) == ERR_BAD_HANDLE &&
                 sys(CROI_SYS_HANDLE_CLOSE, two[0], 0, 0, 0, 0) == ERR_BAD_HANDLE);
  CHECK(148, sys(CROI_SYS_HANDLE_DUPLICATE, event, RIGHT_SAME, (uint64_t)&two[0], 0, 0) == 0 &&
                 chan_write(0x7FFFFFF0u, "x", 1, two, 1) == ERR_BAD_HANDLE &&
                 sys(CROI_SYS_HANDLE_CLOSE, two[0], 0, 0, 0, 0) == ERR_BAD_HANDLE);
  CHECK(149, sys(CROI_SYS_HANDLE_DUPLICATE, event, RIGHT_SAME, (uint64_t)&two[0], 0, 0) == 0 &&
                 chan_write(a, "x", 1, (const uint32_t *)0x10, 1) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_HANDLE_CLOSE, two[0], 0, 0, 0, 0) == 0);  // unreadable list: kept
  // The channel itself: refused, and its handle consumed too, which
  // closes this end (peer closed below).
  CHECK(123, chan_write(a, "bye", 3, 0, 0) == 0);
  CHECK(121, chan_write(a, "x", 1, &a, 1) == ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_HANDLE_CLOSE, a, 0, 0, 0, 0) == ERR_BAD_HANDLE);
  // Peer closed: signal, writes refused (consuming), reads drain then refuse.
  CHECK(124, wait_for(b, CROI_SIGNAL_PEER_CLOSED, 1000000000) & CROI_SIGNAL_PEER_CLOSED);
  CHECK(125, sys(CROI_SYS_HANDLE_DUPLICATE, event, RIGHT_SAME, (uint64_t)&two[0], 0, 0) == 0 &&
                 chan_write(b, "x", 1, two, 1) == ERR_PEER_CLOSED &&
                 sys(CROI_SYS_HANDLE_CLOSE, two[0], 0, 0, 0, 0) == ERR_BAD_HANDLE);
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
  CHECK(208, sys(CROI_SYS_TIMER_CANCEL, timer, 0, 0, 0, 0) == 0 &&
                 !(wait_for(timer, SIGNALED, 0) & SIGNALED));  // cancel clears a fired timer, as Zircon's
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

// User TLS registers survive switches: two threads, each with its own
// value (amd64 FS base via object_set_property; arm64 TPIDR_EL0 and rv64
// tp written directly), checked across sleeps.
typedef struct {
  uint32_t self;
  volatile uint32_t ok;
  uint64_t value;
} tls_worker_t;

static uint64_t tls_read(void) {
  uint64_t v;
#if defined(__x86_64__)
  __asm__ volatile("mov %%fs:0, %0" : "=r"(v));  // FS points at the value
#elif defined(__aarch64__)
  __asm__ volatile("mrs %0, tpidr_el0" : "=r"(v));
#else
  __asm__ volatile("mv %0, tp" : "=r"(v));
#endif
  return v;
}

static void tls_worker(uint64_t arg) {
  tls_worker_t *w = (tls_worker_t *)arg;
  int good = 1;
#if defined(__x86_64__)
  uint64_t base = (uint64_t)&w->value, got = 0;
  good = sys(CROI_SYS_OBJECT_SET_PROPERTY, w->self, CROI_PROP_REGISTER_FS, (uint64_t)&base, 8, 0) == 0 &&
         sys(CROI_SYS_OBJECT_GET_PROPERTY, w->self, CROI_PROP_REGISTER_FS, (uint64_t)&got, 8, 0) == 0 &&
         got == base;
#elif defined(__aarch64__)
  __asm__ volatile("msr tpidr_el0, %0" ::"r"(w->value));
#else
  __asm__ volatile("mv tp, %0" ::"r"(w->value));
#endif
  for (int i = 0; i < 20 && good; i++) {
    sys(CROI_SYS_NANOSLEEP, now_ns() + 200000, 0, 0, 0, 0);
    good = tls_read() == w->value;
  }
  w->ok = good ? 1 : 2;
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static void tls(const startup_t *s) {
  tls_worker_t workers[2] = {{0, 0, 0x1111222233334444ull}, {0, 0, 0x5555666677778888ull}};
  for (int i = 0; i < 2; i++) {
    uint32_t stack = 0;
    uint64_t at = 0;
    CHECK(31, sys(CROI_SYS_VMO_CREATE, STACK_SIZE, 0, (uint64_t)&stack, 0, 0) == 0 &&
                  sys(CROI_SYS_VMO_MAP, stack, 0, STACK_SIZE, 3, (uint64_t)&at) == 0);
    sys(CROI_SYS_HANDLE_CLOSE, stack, 0, 0, 0, 0);
    CHECK(32, sys6(CROI_SYS_THREAD_CREATE, s->process, (uint64_t)"tls", 3, 0, (uint64_t)&workers[i].self, 0) == 0 &&
                  sys(CROI_SYS_THREAD_START, workers[i].self, (uint64_t)tls_worker, ENTRY_SP(at + STACK_SIZE),
                      (uint64_t)&workers[i], 0) == 0);
  }
  uint64_t base = 0x10000;
#if defined(__x86_64__)
  // Only the calling thread's own; canonical addresses only.
  CHECK(33, sys(CROI_SYS_OBJECT_SET_PROPERTY, workers[0].self, CROI_PROP_REGISTER_FS, (uint64_t)&base, 8, 0) ==
                ERR_ACCESS_DENIED);
#else
  CHECK(33, sys(CROI_SYS_OBJECT_SET_PROPERTY, workers[0].self, CROI_PROP_REGISTER_FS, (uint64_t)&base, 8, 0) ==
                ERR_NOT_SUPPORTED);
#endif
  for (int i = 0; i < 2; i++) {
    CHECK(34, wait_for(workers[i].self, CROI_SIGNAL_TASK_TERMINATED, 5000000000ull) & CROI_SIGNAL_TASK_TERMINATED);
    CHECK(35, workers[i].ok == 1);
    sys(CROI_SYS_HANDLE_CLOSE, workers[i].self, 0, 0, 0, 0);
  }
}

// A detached thread's end: unmap its own stack, close its own handle and
// exit in one call (Zircon's vmar_unmap_handle_close_thread_exit).
typedef struct {
  uint32_t vmar, self;
  uint64_t stack;
} unmap_exit_t;

static void unmap_exit_worker(uint64_t arg) {
  const unmap_exit_t *u = (const unmap_exit_t *)arg;
  sys(CROI_SYS_VMAR_UNMAP_HANDLE_CLOSE_THREAD_EXIT, u->vmar, u->stack, STACK_SIZE, u->self, 0);
  for (;;) {}  // not reached: the stack is gone
}

static void unmap_exit(const startup_t *s) {
  // Errors are vmar_unmap's, and the caller carries on.
  CHECK(36, sys(CROI_SYS_VMAR_UNMAP_HANDLE_CLOSE_THREAD_EXIT, 0x7FFFFFF0u, 0, 0, 0, 0) == ERR_BAD_HANDLE);
  unmap_exit_t u = {s->vmar, 0, 0};
  uint32_t stack = 0, watch = 0;
  CHECK(37, sys(CROI_SYS_VMO_CREATE, STACK_SIZE, 0, (uint64_t)&stack, 0, 0) == 0 &&
                sys(CROI_SYS_VMO_MAP, stack, 0, STACK_SIZE, 3, (uint64_t)&u.stack) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, stack, 0, 0, 0, 0);
  CHECK(38, sys6(CROI_SYS_THREAD_CREATE, s->process, (uint64_t)"ux", 2, 0, (uint64_t)&u.self, 0) == 0 &&
                sys(CROI_SYS_HANDLE_DUPLICATE, u.self, RIGHT_SAME, (uint64_t)&watch, 0, 0) == 0 &&
                sys(CROI_SYS_THREAD_START, u.self, (uint64_t)unmap_exit_worker, ENTRY_SP(u.stack + STACK_SIZE),
                    (uint64_t)&u, 0) == 0);
  CHECK(39, (wait_for(watch, CROI_SIGNAL_TASK_TERMINATED, 5000000000ull) & CROI_SIGNAL_TASK_TERMINATED) &&
                sys(CROI_SYS_HANDLE_CLOSE, u.self, 0, 0, 0, 0) == ERR_BAD_HANDLE &&
                sys(CROI_SYS_VMAR_PROTECT, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, u.stack, STACK_SIZE, 0, 0) != 0);
  sys(CROI_SYS_HANDLE_CLOSE, watch, 0, 0, 0, 0);
}

static int64_t exceptions(const startup_t *s) {
  tls(s);
  unmap_exit(s);
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

// Mode 10 (K9a): resources, physical VMOs, cache policy, VMO range ops.
// Per arch: a RAM address, a register page the kernel drives (its UART
// or HPET), and a harmless device page it doesn't, with a value to read.
#if defined(__x86_64__)
#define DRV_RAM 0x200000ull
#define DRV_KERNEL_MMIO 0xFED00000ull  // HPET (the clock calibrates with it)
#define DRV_DEVICE 0xE0000000ull       // q35 ECAM (OVMF): bus 0 device 0 is the host bridge
#define DRV_DEVICE_OFFSET 0
#define DRV_DEVICE_VALUE(v) (((v) & 0xFFFF) == 0x8086)
#elif defined(__aarch64__)
#define DRV_RAM 0x48000000ull
#define DRV_KERNEL_MMIO 0x09000000ull  // the PL011 console
#define DRV_DEVICE 0x09010000ull       // PL031 RTC: PeriphID0 is 0x31
#define DRV_DEVICE_OFFSET 0xFE0
#define DRV_DEVICE_VALUE(v) (((v) & 0xFF) == 0x31)
#else
#define DRV_RAM 0x88000000ull
#define DRV_KERNEL_MMIO 0x10000000ull  // the 16550 console
#define DRV_DEVICE 0x101000ull         // goldfish RTC: TIME_LOW counts
#define DRV_DEVICE_OFFSET 0
#define DRV_DEVICE_VALUE(v) ((v) != 0)
#endif
#define ERR_NOT_FOUND (-25)
#define ERR_WRONG_TYPE (-12)
#define PAGE 4096ull

static int64_t resource_create(uint32_t parent, uint32_t options, uint64_t base, uint64_t size, uint32_t *out) {
  return sys6(CROI_SYS_RESOURCE_CREATE, parent | (uint64_t)options << 32, base, size, (uint64_t)"drv", 3,
              (uint64_t)out);
}

#if defined(__x86_64__)
static void port_worker(uint64_t arg) {
  (void)arg;
  __asm__ volatile("outb %%al, $0x80" ::"a"(0));  // released: #GP
  sys(CROI_SYS_THREAD_EXIT, 1, 0, 0, 0, 0);
}
#endif

// K9b: maps [base, base + size), rounded out to pages, through a physical
// VMO under `resource` with `policy` and `perms`. Returns base's address.
static uint64_t map_physical(const startup_t *s, uint32_t resource, uint64_t base, uint64_t size, uint32_t policy,
                             uint32_t perms) {
  uint64_t first = base & ~(PAGE - 1), length = ((base + size + PAGE - 1) & ~(PAGE - 1)) - first, at = 0;
  uint32_t vmo = 0;
  CHECK(240, sys(CROI_SYS_VMO_CREATE_PHYSICAL, resource, first, length, (uint64_t)&vmo, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, vmo, policy, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)perms << 32, 0, vmo, 0, length, (uint64_t)&at) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  return at + (base - first);
}

static uint8_t checksum(const volatile uint8_t *bytes, uint64_t count) {
  uint8_t sum = 0;
  for (uint64_t i = 0; i < count; i++) sum += bytes[i];
  return sum;
}

// The MEM_CONFIG type of the range holding `paddr`, 0 if none.
static uint32_t mem_type(const croi_zbi_mem_range_t *ranges, uint64_t count, uint64_t paddr) {
  for (uint64_t i = 0; i < count; i++) {
    if (ranges[i].paddr <= paddr && paddr - ranges[i].paddr < ranges[i].length) return ranges[i].type;
  }
  return 0;
}

// Mode 10, K9b: the boot data (a ZBI container of firmware items, zbi.h)
// and firmware memory through physical VMOs: the ACPI tables (cached only),
// SMBIOS, and the framebuffer the kernel drew its pattern on.
static int64_t firmware(const startup_t *s) {
  uint64_t size = 0, at = 0, word = 0;
  CHECK(231, sys(CROI_SYS_VMO_GET_SIZE, s->bootdata, (uint64_t)&size, 0, 0, 0) == 0 && size >= PAGE &&
                 sys(CROI_SYS_VMO_WRITE, s->bootdata, (uint64_t)&word, 0, 8, 0) == ERR_ACCESS_DENIED &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0,
                      s->bootdata, 0, size, (uint64_t)&at) == ERR_ACCESS_DENIED &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, s->bootdata, 0, size,
                      (uint64_t)&at) == 0);
  const croi_zbi_header_t *container = (const croi_zbi_header_t *)at;
  CHECK(232, container->type == CROI_ZBI_TYPE_CONTAINER && container->extra == CROI_ZBI_CONTAINER_MAGIC &&
                 (container->flags & CROI_ZBI_FLAGS_VERSION) && container->magic == CROI_ZBI_ITEM_MAGIC &&
                 container->length % CROI_ZBI_ALIGNMENT == 0 && container->length + sizeof *container <= size);
  // Every item well formed; RSDP and MEM_CONFIG present.
  uint64_t rsdp = 0, smbios = 0, ranges_count = 0;
  const croi_zbi_mem_range_t *ranges = 0;
  const croi_zbi_swfb_t *fb = 0;
  for (uint64_t offset = sizeof *container; offset < sizeof *container + container->length;) {
    const croi_zbi_header_t *item = (const croi_zbi_header_t *)(at + offset);
    const void *payload = item + 1;
    CHECK(233, item->magic == CROI_ZBI_ITEM_MAGIC && (item->flags & CROI_ZBI_FLAGS_VERSION) &&
                   item->crc32 == CROI_ZBI_ITEM_NO_CRC32 &&
                   offset + sizeof *item + item->length <= sizeof *container + container->length);
    if (item->type == CROI_ZBI_TYPE_ACPI_RSDP && item->length == 8) rsdp = *(const uint64_t *)payload;
    if (item->type == CROI_ZBI_TYPE_SMBIOS && item->length == 8) smbios = *(const uint64_t *)payload;
    if (item->type == CROI_ZBI_TYPE_FRAMEBUFFER && item->length == sizeof *fb) fb = payload;
    if (item->type == CROI_ZBI_TYPE_MEM_CONFIG && item->length % sizeof *ranges == 0) {
      ranges = payload;
      ranges_count = item->length / sizeof *ranges;
    }
    offset += sizeof *item + ((item->length + CROI_ZBI_ALIGNMENT - 1) & ~(uint64_t)(CROI_ZBI_ALIGNMENT - 1));
  }
  CHECK(234, rsdp != 0 && ranges_count > 0);
  for (uint64_t i = 1; i < ranges_count; i++) {
    CHECK(235, ranges[i - 1].paddr + ranges[i - 1].length <= ranges[i].paddr);
  }
  // The RSDP is in firmware memory (RESERVED): readable through an MMIO
  // resource over it, cached only.
  uint32_t mmio = 0, vmo = 0;
  uint64_t first = rsdp & ~(PAGE - 1), pages = ((rsdp + 36 + PAGE - 1) & ~(PAGE - 1)) - first;
  CHECK(236, mem_type(ranges, ranges_count, rsdp) == CROI_ZBI_MEM_TYPE_RESERVED &&
                 mem_type(ranges, ranges_count, DRV_RAM) == CROI_ZBI_MEM_TYPE_RAM &&
                 resource_create(s->resource, CROI_RSRC_KIND_MMIO, first, pages, &mmio) == 0 &&
                 sys(CROI_SYS_VMO_CREATE_PHYSICAL, mmio, first, pages, (uint64_t)&vmo, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, vmo, CROI_CACHE_POLICY_UNCACHED, 0, 0, 0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, vmo, CROI_CACHE_POLICY_WRITE_COMBINING, 0, 0, 0) ==
                     ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0) == 0);
  const volatile uint8_t *table = (const volatile uint8_t *)map_physical(s, mmio, rsdp, 36, CROI_CACHE_POLICY_CACHED,
                                                                          CROI_VM_PERM_READ);
  CHECK(237, table[0] == 'R' && table[1] == 'S' && table[2] == 'D' && table[7] == ' ' && table[15] >= 2 &&
                 checksum(table, 36) == 0);
  uint64_t xsdt = *(const volatile uint64_t *)(table + 24);
  sys(CROI_SYS_HANDLE_CLOSE, mmio, 0, 0, 0, 0);
  // The XSDT, through the root resource: whole and summing to zero.
  table = (const volatile uint8_t *)map_physical(s, s->resource, xsdt, 36, CROI_CACHE_POLICY_CACHED, CROI_VM_PERM_READ);
  uint32_t length = *(const volatile uint32_t *)(table + 4);
  CHECK(238, table[0] == 'X' && table[1] == 'S' && table[2] == 'D' && table[3] == 'T' && length >= 36 &&
                 length < 65536);
  table = (const volatile uint8_t *)map_physical(s, s->resource, xsdt, length, CROI_CACHE_POLICY_CACHED,
                                                 CROI_VM_PERM_READ);
  CHECK(239, checksum(table, length) == 0);
  // RAM stays refused, whatever MEM_CONFIG range it is.
  for (uint64_t i = 0; i < ranges_count; i++) {
    if (ranges[i].type != CROI_ZBI_MEM_TYPE_RAM) continue;
    CHECK(241, sys(CROI_SYS_VMO_CREATE_PHYSICAL, s->resource, ranges[i].paddr, PAGE, (uint64_t)&vmo, 0) ==
                   ERR_ACCESS_DENIED);
  }
  // SMBIOS, if firmware has it: the entry point's anchor.
  if (smbios != 0) {
    table = (const volatile uint8_t *)map_physical(s, s->resource, smbios, 5, CROI_CACHE_POLICY_CACHED,
                                                   CROI_VM_PERM_READ);
    CHECK(242, table[0] == '_' && table[1] == 'S' && table[2] == 'M' &&
                   (table[3] == '_' || (table[3] == '3' && table[4] == '_')));
  }
  // The framebuffer (PERIPHERAL), mapped write-combining: the kernel's
  // pattern is there, background (16, 48, 96) and a (240, 192, 32) block
  // at (16, 16) sized 64x32.
  if (fb != 0) {
    uint32_t background, block;
    if (fb->format == CROI_ZBI_PIXEL_FORMAT_RGB_X888) {
      background = 0x103060, block = 0xF0C020;
    } else {
      CHECK(243, fb->format == CROI_ZBI_PIXEL_FORMAT_BGR_888_X);
      background = 0x603010, block = 0x20C0F0;
    }
    CHECK(244, mem_type(ranges, ranges_count, fb->base) == CROI_ZBI_MEM_TYPE_PERIPHERAL && fb->width >= 80 &&
                   fb->height >= 48 && fb->stride >= fb->width);
    const volatile uint32_t *pixels = (const volatile uint32_t *)map_physical(
        s, s->resource, fb->base, (uint64_t)fb->stride * fb->height * 4, CROI_CACHE_POLICY_WRITE_COMBINING,
        CROI_VM_PERM_READ | CROI_VM_PERM_WRITE);
    CHECK(245, (pixels[0] & 0xFFFFFF) == background && (pixels[30 * fb->stride + 40] & 0xFFFFFF) == block);
  }
  return 0x600D;
}

static int64_t drivers(const startup_t *s) {
  uint32_t root = s->resource, mmio = 0, other = 0, vmo = 0;
  // The root filter: RAM and the kernel's own registers.
  CHECK(210, sys(CROI_SYS_VMO_CREATE_PHYSICAL, root, DRV_RAM, PAGE, (uint64_t)&vmo, 0) == ERR_ACCESS_DENIED &&
                 resource_create(root, CROI_RSRC_KIND_MMIO, DRV_RAM, PAGE, &mmio) == ERR_ACCESS_DENIED &&
                 resource_create(root, CROI_RSRC_KIND_MMIO, DRV_KERNEL_MMIO, PAGE, &mmio) == ERR_ACCESS_DENIED);
  // An exclusive MMIO resource over the device page: overlaps refused
  // (exclusive or not), no children; info reports it.
  CHECK(211, resource_create(root, CROI_RSRC_KIND_MMIO | CROI_RSRC_FLAG_EXCLUSIVE, DRV_DEVICE, PAGE, &mmio) == 0);
  CHECK(212, resource_create(root, CROI_RSRC_KIND_MMIO | CROI_RSRC_FLAG_EXCLUSIVE, DRV_DEVICE, PAGE, &other) ==
                 ERR_NOT_FOUND &&
                 resource_create(root, CROI_RSRC_KIND_MMIO, DRV_DEVICE + 8, 8, &other) == ERR_NOT_FOUND &&
                 resource_create(mmio, CROI_RSRC_KIND_MMIO, DRV_DEVICE, 8, &other) == ERR_INVALID_ARGS);
  croi_info_resource_t info = {};
  CHECK(213, sys(CROI_SYS_OBJECT_GET_INFO, mmio, CROI_INFO_RESOURCE, (uint64_t)&info, sizeof info, 0) == 0 &&
                 info.kind == CROI_RSRC_KIND_MMIO && info.base == DRV_DEVICE && info.size == PAGE &&
                 (info.flags & CROI_RSRC_FLAG_EXCLUSIVE) && info.name[0] == 'd' && info.name[3] == 0);
  // A physical VMO through it: other kinds and ranges refused; mapped,
  // the device answers (uncached by default).
  uint32_t irq = 0;
  CHECK(214, resource_create(root, CROI_RSRC_KIND_IRQ, 40, 1, &irq) == 0 &&
                 sys(CROI_SYS_VMO_CREATE_PHYSICAL, irq, DRV_DEVICE, PAGE, (uint64_t)&vmo, 0) == ERR_WRONG_TYPE &&
                 sys(CROI_SYS_VMO_CREATE_PHYSICAL, mmio, DRV_DEVICE + PAGE, PAGE, (uint64_t)&vmo, 0) ==
                     ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_VMO_CREATE_PHYSICAL, mmio, DRV_DEVICE + 1, PAGE, (uint64_t)&vmo, 0) == ERR_INVALID_ARGS);
  CHECK(215, sys(CROI_SYS_VMO_CREATE_PHYSICAL, mmio, DRV_DEVICE, PAGE, (uint64_t)&vmo, 0) == 0);
  uint64_t at = 0, word = 0;
  CHECK(216, sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, vmo, 0, PAGE, (uint64_t)&at) == 0);
  word = *(volatile uint32_t *)(at + DRV_DEVICE_OFFSET);
  CHECK(217, DRV_DEVICE_VALUE(word));
  // Device memory: no vmo_read, no policy change while mapped.
  CHECK(218, sys(CROI_SYS_VMO_READ, vmo, (uint64_t)&word, 0, 8, 0) == ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, vmo, CROI_CACHE_POLICY_UNCACHED, 0, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_CACHE_CLEAN, 0, PAGE, 0) == 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, PAGE, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  // Closed, the range is free for anyone again.
  CHECK(219, sys(CROI_SYS_HANDLE_CLOSE, mmio, 0, 0, 0, 0) == 0 &&
                 resource_create(root, CROI_RSRC_KIND_MMIO, DRV_DEVICE, PAGE, &mmio) == 0 &&
                 resource_create(mmio, CROI_RSRC_KIND_MMIO, DRV_DEVICE + 0x100, 0x100, &other) == 0 &&
                 resource_create(other, CROI_RSRC_KIND_MMIO, DRV_DEVICE, 0x200, &irq) == ERR_ACCESS_DENIED);
  sys(CROI_SYS_HANDLE_CLOSE, other, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, mmio, 0, 0, 0, 0);
  // System resources: size 1 inside the system space.
  CHECK(220, resource_create(root, CROI_RSRC_KIND_SYSTEM, CROI_RSRC_SYSTEM_TRACING_BASE, 1, &other) == 0 &&
                 resource_create(root, CROI_RSRC_KIND_SYSTEM, CROI_RSRC_SYSTEM_COUNT, 1, &mmio) == ERR_NOT_FOUND &&
                 resource_create(root, 3, 0, 1, &mmio) == ERR_INVALID_ARGS);  // ROOT can't be minted
  sys(CROI_SYS_HANDLE_CLOSE, other, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, irq, 0, 0, 0, 0);

  // Cache policy on an anonymous VMO: only unmapped; read/write refused
  // once uncached; MAP needed; bad values refused.
  uint32_t anon = 0, readonly = 0;
  CHECK(221, sys(CROI_SYS_VMO_CREATE, 3 * PAGE, 0, (uint64_t)&anon, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, anon, 7, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, anon, 1u << 2 | 1u << 15, (uint64_t)&readonly, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, readonly, CROI_CACHE_POLICY_CACHED, 0, 0, 0) == ERR_ACCESS_DENIED);
  CHECK(222, sys(CROI_SYS_VMO_SET_CACHE_POLICY, anon, CROI_CACHE_POLICY_WRITE_COMBINING, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_READ, anon, (uint64_t)&word, 0, 8, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, anon, CROI_CACHE_POLICY_CACHED, 0, 0, 0) == 0);

  // Range ops: commit, write, zero part of it, read it back.
  uint8_t bytes[64];
  for (int i = 0; i < 64; i++) bytes[i] = 0xAB;
  CHECK(223, sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_COMMIT, 100, 2 * PAGE, 0) == 0 &&
                 sys(CROI_SYS_VMO_WRITE, anon, (uint64_t)bytes, PAGE - 32, 64, 0) == 0 &&
                 sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_ZERO, PAGE - 16, 32, 0) == 0 &&
                 sys(CROI_SYS_VMO_READ, anon, (uint64_t)bytes, PAGE - 32, 64, 0) == 0 &&
                 bytes[0] == 0xAB && bytes[15] == 0xAB && bytes[16] == 0 && bytes[47] == 0 && bytes[48] == 0xAB);
  CHECK(224, sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_ZERO, 0, 3 * PAGE, 0) == 0 &&
                 sys(CROI_SYS_VMO_READ, anon, (uint64_t)bytes, PAGE - 32, 64, 0) == 0 && bytes[0] == 0 &&
                 bytes[63] == 0);
  // Cache ops, decommit, and the refusals.
  CHECK(225, sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_CACHE_CLEAN, 8, 100, 0) == 0 &&
                 sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_CACHE_CLEAN_INVALIDATE, 0, 3 * PAGE, 0) == 0 &&
                 sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_CACHE_SYNC, 0, PAGE, 0) == 0 &&
                 sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_DECOMMIT, 0, 3 * PAGE, 0) == 0);
  CHECK(226, sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_CACHE_CLEAN, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_CACHE_INVALIDATE, 0, PAGE, 0) == ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_DECOMMIT, 1, PAGE, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_COMMIT, 2 * PAGE, 2 * PAGE, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_VMO_OP_RANGE, anon, 99, 0, PAGE, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMO_OP_RANGE, readonly, CROI_VMO_OP_COMMIT, 0, PAGE, 0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_VMO_OP_RANGE, readonly, CROI_VMO_OP_CACHE_CLEAN, 0, PAGE, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, readonly, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, anon, 0, 0, 0, 0);

  // amd64 IO ports: allowed after a request, refused again after the
  // release (a thread's outb then raises a general exception).
#if defined(__x86_64__)
  uint32_t ports = 0;
  CHECK(228, resource_create(root, CROI_RSRC_KIND_IOPORT, 0x80, 1, &ports) == 0 &&
                 resource_create(root, CROI_RSRC_KIND_IOPORT, 0x20, 2, &other) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_IOPORTS_REQUEST, ports, 0x81, 1, 0, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_IOPORTS_REQUEST, ports, 0x80, 1, 0, 0) == 0);
  __asm__ volatile("outb %%al, $0x80" ::"a"(0));
  CHECK(229, sys(CROI_SYS_IOPORTS_RELEASE, ports, 0x80, 1, 0, 0) == 0);
  uint32_t channel = exception_channel(s->process);
  uint32_t worker = start_thread(s, port_worker, 0);
  handle_exception(channel, s->process, CROI_EXCP_GENERAL, CROI_EXCEPTION_STATE_THREAD_EXIT, 0);
  CHECK(230, wait_for(worker, CROI_SIGNAL_TASK_TERMINATED, 5000000000ull) & CROI_SIGNAL_TASK_TERMINATED);
  sys(CROI_SYS_HANDLE_CLOSE, worker, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, ports, 0, 0, 0, 0);
#else
  CHECK(228, sys(CROI_SYS_IOPORTS_REQUEST, root, 0x80, 1, 0, 0) == ERR_NOT_SUPPORTED);
#endif

  // Zero-size VMOs exist (Zircon's).
  uint64_t size = 1;
  CHECK(227, sys(CROI_SYS_VMO_CREATE, 0, 0, (uint64_t)&anon, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_GET_SIZE, anon, (uint64_t)&size, 0, 0, 0) == 0 && size == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, anon, 0, 0, 0, 0) == 0);
  return firmware(s);
}

// Mode 11 (K9c): interrupt objects. Virtual ones through their whole
// state machine, then a real device per arch with a fixed interrupt:
// amd64 the CMOS RTC's periodic interrupt (GSI 8, edge), arm64 the PL031
// alarm (INTID 34, level), rv64 the goldfish RTC alarm (GSI 11, level).
#define ERR_ALREADY_BOUND (-27)
#define ERR_CANCELED (-23)
#if defined(__x86_64__)
#define IRQ_NUMBER 8
#define IRQ_LEVEL 0
#define IRQ_WAITS 16
static void outb(uint16_t port, uint8_t value) { __asm__ volatile("outb %0, %1" ::"a"(value), "Nd"(port)); }
static uint8_t inb(uint16_t port) {
  uint8_t value;
  __asm__ volatile("inb %1, %0" : "=a"(value) : "Nd"(port));
  return value;
}
static uint8_t cmos_read(uint8_t reg) {
  outb(0x70, 0x80 | reg);  // NMIs stay off while we poke
  return inb(0x71);
}
static void cmos_write(uint8_t reg, uint8_t value) {
  outb(0x70, 0x80 | reg);
  outb(0x71, value);
}
static volatile uint32_t *irq_device_setup(const startup_t *s) {
  uint32_t ports = 0;
  CHECK(250, resource_create(s->resource, CROI_RSRC_KIND_IOPORT, 0x70, 2, &ports) == 0 &&
                 sys(CROI_SYS_IOPORTS_REQUEST, ports, 0x70, 2, 0, 0) == 0);
  return 0;
}
static void irq_device_start(volatile uint32_t *regs) {  // 1024 Hz periodic
  (void)regs;
  cmos_write(0xA, (cmos_read(0xA) & 0xF0) | 6);
  cmos_write(0xB, cmos_read(0xB) | 0x40);
  cmos_read(0xC);
}
static void irq_device_clear(volatile uint32_t *regs) {
  (void)regs;
  cmos_read(0xC);
}
static void irq_device_stop(volatile uint32_t *regs) {
  (void)regs;
  cmos_write(0xB, cmos_read(0xB) & ~0x40);
  cmos_read(0xC);
}
#else
#if defined(__aarch64__)
#define IRQ_NUMBER 34
#define IRQ_DEVICE 0x09010000ull
#define IRQ_WAITS 1  // the PL031 matches whole seconds
#else
#define IRQ_NUMBER 11
#define IRQ_DEVICE 0x101000ull
#define IRQ_WAITS 8
#endif
#define IRQ_LEVEL 1
static volatile uint32_t *irq_device_setup(const startup_t *s) {
  return (volatile uint32_t *)map_physical(s, s->resource, IRQ_DEVICE, PAGE, CROI_CACHE_POLICY_UNCACHED_DEVICE,
                                           CROI_VM_PERM_READ | CROI_VM_PERM_WRITE);
}
#if defined(__aarch64__)
static void irq_device_start(volatile uint32_t *irq_regs) {  // the next second
  irq_regs[1] = irq_regs[0] + 1;      // RTCMR = RTCDR + 1
  irq_regs[4] = 1;                    // RTCIMSC
}
static void irq_device_clear(volatile uint32_t *irq_regs) { irq_regs[7] = 1; }  // RTCICR
static void irq_device_stop(volatile uint32_t *irq_regs) {
  irq_regs[4] = 0;
  irq_regs[7] = 1;
}
#else
static void irq_device_start(volatile uint32_t *irq_regs) {  // 1 ms from now
  uint64_t now = irq_regs[0];         // TIME_LOW latches TIME_HIGH
  now |= (uint64_t)irq_regs[1] << 32;
  now += 1000000;
  irq_regs[4] = 1;  // IRQ_ENABLED
  irq_regs[3] = (uint32_t)(now >> 32);
  irq_regs[2] = (uint32_t)now;  // ALARM_LOW arms it
}
static void irq_device_clear(volatile uint32_t *irq_regs) { irq_regs[7] = 1; }  // CLEAR_INTERRUPT
static void irq_device_stop(volatile uint32_t *irq_regs) {
  irq_regs[4] = 0;
  irq_regs[5] = 1;  // CLEAR_ALARM
  irq_regs[7] = 1;
}
#endif
#endif

static int64_t port_next(uint32_t port, uint64_t ns, croi_port_packet_t *packet) {
  return sys(CROI_SYS_PORT_WAIT, port, ns == 0 ? 0 : now_ns() + ns, (uint64_t)packet, 0, 0);
}

static void sleep_ns(uint64_t ns) { sys(CROI_SYS_NANOSLEEP, now_ns() + ns, 0, 0, 0, 0); }

// A worker: interrupt_wait on `handle`; the status and time land here.
typedef struct {
  uint32_t handle;
  volatile int64_t status;
  volatile uint64_t time;
} irq_waiter_t;
static void irq_waiter(uint64_t arg) {
  irq_waiter_t *w = (irq_waiter_t *)arg;
  uint64_t time = 0;
  int64_t status = sys(CROI_SYS_INTERRUPT_WAIT, w->handle, (uint64_t)&time, 0, 0, 0);
  w->time = time;
  w->status = status;
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static void join_checked(uint32_t thread) {
  CHECK(251, wait_for(thread, CROI_SIGNAL_TASK_TERMINATED, 5000000000ull) & CROI_SIGNAL_TASK_TERMINATED);
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
}

static int64_t virtual_interrupts(const startup_t *s, uint32_t port) {
  uint32_t v = 0, v2 = 0, plain = 0;
  croi_port_packet_t p;
  uint64_t time = 0;
  CHECK(252, sys(CROI_SYS_INTERRUPT_CREATE, 0, 0, CROI_INTERRUPT_VIRTUAL | CROI_INTERRUPT_REMAP_IRQ, (uint64_t)&v,
                 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_INTERRUPT_CREATE, 0, 0, CROI_INTERRUPT_VIRTUAL, (uint64_t)&v, 0) == 0 &&
                 (wait_for(v, CROI_VIRTUAL_INTERRUPT_UNTRIGGERED, 0) & CROI_VIRTUAL_INTERRUPT_UNTRIGGERED) &&
                 sys(CROI_SYS_INTERRUPT_TRIGGER, v, 1, 5, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_INTERRUPT_SET_AFFINITY, v, 1, 0, 0, 0) == ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_INTERRUPT_ACK, v, 0, 0, 0, 0) == ERR_BAD_STATE);
  // Bound: a packet per trigger, the next only after an ack.
  CHECK(253, sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&plain, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_INTERRUPT_BIND, v, plain, 9, CROI_INTERRUPT_BIND, 0) == ERR_WRONG_TYPE &&
                 sys(CROI_SYS_INTERRUPT_BIND, v, port, 9, 2, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_INTERRUPT_BIND, v, port, 9, CROI_INTERRUPT_BIND, 0) == 0 &&
                 sys(CROI_SYS_INTERRUPT_BIND, v, port, 9, CROI_INTERRUPT_BIND, 0) == ERR_ALREADY_BOUND &&
                 sys(CROI_SYS_INTERRUPT_WAIT, v, 0, 0, 0, 0) == ERR_BAD_STATE);
  sys(CROI_SYS_HANDLE_CLOSE, plain, 0, 0, 0, 0);
  CHECK(254, sys(CROI_SYS_INTERRUPT_TRIGGER, v, 0, 1111, 0, 0) == 0 &&
                 !(wait_for(v, CROI_VIRTUAL_INTERRUPT_UNTRIGGERED, 0) & CROI_VIRTUAL_INTERRUPT_UNTRIGGERED) &&
                 port_next(port, 1000000000, &p) == 0 && p.type == CROI_PKT_TYPE_INTERRUPT && p.key == 9 &&
                 p.payload[0] == 1111);
  CHECK(255, sys(CROI_SYS_INTERRUPT_TRIGGER, v, 0, 2222, 0, 0) == 0 && port_next(port, 0, &p) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_INTERRUPT_ACK, v, 0, 0, 0, 0) == 0 && port_next(port, 0, &p) == 0 &&
                 p.payload[0] == 2222 &&
                 !(wait_for(v, CROI_VIRTUAL_INTERRUPT_UNTRIGGERED, 0) & CROI_VIRTUAL_INTERRUPT_UNTRIGGERED) &&
                 sys(CROI_SYS_INTERRUPT_ACK, v, 0, 0, 0, 0) == 0 &&
                 (wait_for(v, CROI_VIRTUAL_INTERRUPT_UNTRIGGERED, 0) & CROI_VIRTUAL_INTERRUPT_UNTRIGGERED));
  // Unbound with a packet queued: it counts as triggered again.
  CHECK(256, sys(CROI_SYS_INTERRUPT_TRIGGER, v, 0, 3333, 0, 0) == 0 &&
                 sys(CROI_SYS_INTERRUPT_BIND, v, port, 0, CROI_INTERRUPT_UNBIND, 0) == 0 &&
                 sys(CROI_SYS_INTERRUPT_BIND, v, port, 0, CROI_INTERRUPT_UNBIND, 0) == ERR_NOT_FOUND &&
                 port_next(port, 0, &p) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_INTERRUPT_WAIT, v, (uint64_t)&time, 0, 0, 0) == 0 && time == 3333);
  // A thread waiting: woken by a trigger; canceled by closing its handle.
  irq_waiter_t w = {.handle = v, .status = 1};
  uint32_t worker = start_thread(s, irq_waiter, (uint64_t)&w);
  sleep_ns(10000000);
  CHECK(257, sys(CROI_SYS_INTERRUPT_TRIGGER, v, 0, 4444, 0, 0) == 0);
  join_checked(worker);
  CHECK(258, w.status == 0 && w.time == 4444);
  CHECK(259, sys(CROI_SYS_HANDLE_DUPLICATE, v, 1u << 31, (uint64_t)&v2, 0, 0) == 0);
  w.handle = v2, w.status = 1;
  worker = start_thread(s, irq_waiter, (uint64_t)&w);
  sleep_ns(10000000);
  CHECK(260, sys(CROI_SYS_INTERRUPT_WAIT, v, 0, 0, 0, 0) == ERR_BAD_STATE &&  // one waiter at a time
                 sys(CROI_SYS_HANDLE_CLOSE, v2, 0, 0, 0, 0) == 0);
  join_checked(worker);
  CHECK(261, w.status == ERR_CANCELED);
  // Destroyed: a waiter wakes CANCELED, and so does everything after.
  w.handle = v, w.status = 1;
  worker = start_thread(s, irq_waiter, (uint64_t)&w);
  sleep_ns(10000000);
  CHECK(262, sys(CROI_SYS_INTERRUPT_DESTROY, v, 0, 0, 0, 0) == 0);
  join_checked(worker);
  CHECK(263, w.status == ERR_CANCELED && sys(CROI_SYS_INTERRUPT_TRIGGER, v, 0, 1, 0, 0) == ERR_CANCELED &&
                 sys(CROI_SYS_INTERRUPT_WAIT, v, 0, 0, 0, 0) == ERR_CANCELED &&
                 sys(CROI_SYS_HANDLE_CLOSE, v, 0, 0, 0, 0) == 0);
  return 0x600D;
}

// K9d: MSI. amd64: edu delivers a real MSI (port and wait); virtio-blk's
// MSI-X table (not enabled, so it never fires) shows the kernel
// programming, masking and moving its entries. Both are found by scanning
// bus 0 and skipped if absent (other machines boot this kernel too), and
// every config register touched is put back. Elsewhere msi_allocate is
// NOT_SUPPORTED until the ITS / IMSIC.
#if defined(__x86_64__)
#define ECAM 0xE0000000ull
// A physical VMO over [base, base + size) under the root resource, and a
// read/write uncached mapping of it.
static uint32_t physical_vmo(const startup_t *s, uint64_t base, uint64_t size, volatile uint8_t **at) {
  uint32_t vmo = 0;
  uint64_t address = 0;
  CHECK(280, sys(CROI_SYS_VMO_CREATE_PHYSICAL, s->resource, base, size, (uint64_t)&vmo, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, vmo,
                      0, size, (uint64_t)&address) == 0);
  *at = (volatile uint8_t *)address;
  return vmo;
}

static uint32_t cfg32(volatile uint8_t *cfg, uint32_t offset) { return *(volatile uint32_t *)(cfg + offset); }
static void cfg32_write(volatile uint8_t *cfg, uint32_t offset, uint32_t value) {
  *(volatile uint32_t *)(cfg + offset) = value;
}

// The offset of capability `id` in a function's config space, or 0.
static uint32_t capability(volatile uint8_t *cfg, uint8_t id) {
  if (!(cfg[6] & 0x10)) return 0;
  for (uint32_t at = cfg[0x34] & 0xFC, n = 0; at != 0 && n < 48; at = cfg[at + 1] & 0xFC, n++) {
    if (cfg[at] == id) return at;
  }
  return 0;
}

// A memory BAR's address (32 or 64-bit).
static uint64_t bar(volatile uint8_t *cfg, uint32_t index) {
  uint32_t low = cfg32(cfg, 0x10 + 4 * index);
  uint64_t address = low & ~0xFull;
  if (((low >> 1) & 3) == 2) address |= (uint64_t)cfg32(cfg, 0x14 + 4 * index) << 32;
  return address;
}

// Bus 0's function-0 device with this ID and capability, or 0.
static uint32_t find_device(volatile uint8_t *bus, uint32_t vendor_mask, uint32_t id, uint8_t cap, uint32_t *at) {
  for (uint32_t device = 0; device < 32; device++) {
    volatile uint8_t *cfg = bus + (device << 15);
    if ((cfg32(cfg, 0) & vendor_mask) == id && (*at = capability(cfg, cap)) != 0) return device << 15;
  }
  return 0;
}

static int64_t msi_test(const startup_t *s, uint32_t port) {
  volatile uint8_t *bus = 0;
  uint32_t bus_vmo = physical_vmo(s, ECAM, 32 * 0x8000, &bus);  // bus 0, devices 0-31, function 0

  // Allocations: the MSI resource; a power of two up to 32.
  uint32_t msi = 0, tracing = 0, intr = 0, other = 0, anon = 0;
  CHECK(283, resource_create(s->resource, CROI_RSRC_KIND_SYSTEM, CROI_RSRC_SYSTEM_TRACING_BASE, 1, &tracing) == 0 &&
                 sys(CROI_SYS_MSI_ALLOCATE, tracing, 1, (uint64_t)&msi, 0, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_MSI_ALLOCATE, s->resource, 3, (uint64_t)&msi, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_MSI_ALLOCATE, s->resource, 64, (uint64_t)&msi, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_MSI_ALLOCATE, s->resource, 1, (uint64_t)&msi, 0, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, tracing, 0, 0, 0, 0);
  croi_info_msi_t info = {};
  CHECK(284, sys(CROI_SYS_OBJECT_GET_INFO, msi, CROI_INFO_MSI, (uint64_t)&info, sizeof info, 0) == 0 &&
                 (info.target_addr & ~0xFF000ull) == 0xFEE00000 && info.target_data == info.base_irq_id &&
                 info.base_irq_id >= 0xB0 && info.base_irq_id < 0xF0 && info.num_irq == 1 &&
                 info.interrupt_count == 0);
  uint32_t cap = 0;
  uint32_t edu_at = find_device(bus, ~0u, 0x11e81234, 0x05, &cap);
  if (edu_at != 0) {
  volatile uint8_t *edu = bus + edu_at;
  uint32_t command = cfg32(edu, 4) & 0xFFFF;
  cfg32_write(edu, 4, command | 1u << 1 | 1u << 2 | 1u << 10);  // memory, bus master, no INTx
  // Interrupt objects: the capability must be MSI's; ids once each.
  CHECK(285, sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&anon, 0, 0) == 0 &&
                 sys6(CROI_SYS_MSI_CREATE, msi, 0, 0, anon, 0, (uint64_t)&intr) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_MSI_CREATE, msi, 0, 0, bus_vmo, edu_at, (uint64_t)&intr) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_MSI_CREATE, msi, 0, 1, bus_vmo, edu_at + cap, (uint64_t)&intr) ==
                     ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_MSI_CREATE, msi, 2, 0, bus_vmo, edu_at + cap, (uint64_t)&intr) ==
                     ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_MSI_CREATE, msi, 0, 0, bus_vmo, edu_at + cap, (uint64_t)&intr) == 0 &&
                 sys6(CROI_SYS_MSI_CREATE, msi, 0, 0, bus_vmo, edu_at + cap, (uint64_t)&other) ==
                     ERR_ALREADY_BOUND &&
                 sys(CROI_SYS_OBJECT_GET_INFO, msi, CROI_INFO_MSI, (uint64_t)&info, sizeof info, 0) == 0 &&
                 info.interrupt_count == 1 &&
                 sys(CROI_SYS_INTERRUPT_SET_AFFINITY, intr, 2, 0, 0, 0) == ERR_NOT_SUPPORTED);
  sys(CROI_SYS_HANDLE_CLOSE, anon, 0, 0, 0, 0);
  // The driver programs the capability from the info and enables MSI.
  uint16_t control = *(volatile uint16_t *)(edu + cap + 2);
  cfg32_write(edu, cap + 4, (uint32_t)info.target_addr);
  if (control & (1u << 7)) {
    cfg32_write(edu, cap + 8, (uint32_t)(info.target_addr >> 32));
    *(volatile uint16_t *)(edu + cap + 0xC) = (uint16_t)info.target_data;
  } else {
    *(volatile uint16_t *)(edu + cap + 8) = (uint16_t)info.target_data;
  }
  *(volatile uint16_t *)(edu + cap + 2) = (uint16_t)((control & ~(7u << 4)) | 1);  // one message, enabled

  // edu raises an interrupt when 0x60 is written; it reaches the port...
  volatile uint8_t *regs = 0;
  uint32_t regs_vmo = physical_vmo(s, bar(edu, 0), PAGE, &regs);
  volatile uint32_t *edu_regs = (volatile uint32_t *)regs;
  edu_regs[1] = 0x12345678;  // liveness: reads back inverted
  CHECK(286, edu_regs[1] == ~0x12345678u);
  croi_port_packet_t p;
  uint64_t before = now_ns();
  CHECK(287, sys(CROI_SYS_INTERRUPT_BIND, intr, port, 77, CROI_INTERRUPT_BIND, 0) == 0);
  edu_regs[0x60 / 4] = 1;
  CHECK(288, port_next(port, 1000000000, &p) == 0 && p.type == CROI_PKT_TYPE_INTERRUPT && p.key == 77 &&
                 p.payload[0] >= before && edu_regs[0x24 / 4] == 1);
  edu_regs[0x64 / 4] = 1;
  // ...and, unbound, a waiting thread.
  uint64_t time = 0;
  CHECK(289, sys(CROI_SYS_INTERRUPT_ACK, intr, 0, 0, 0, 0) == 0 && port_next(port, 20000000, &p) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_INTERRUPT_BIND, intr, port, 0, CROI_INTERRUPT_UNBIND, 0) == 0);
  before = now_ns();
  edu_regs[0x60 / 4] = 2;
  CHECK(290, sys(CROI_SYS_INTERRUPT_WAIT, intr, (uint64_t)&time, 0, 0, 0) == 0 && time >= before);
  edu_regs[0x64 / 4] = 2;
  *(volatile uint16_t *)(edu + cap + 2) = control;  // MSI as it was
  cfg32_write(edu, 4, command);                     // and the command register
  CHECK(291, sys(CROI_SYS_INTERRUPT_DESTROY, intr, 0, 0, 0, 0) == 0 && sys(CROI_SYS_HANDLE_CLOSE, intr, 0, 0, 0, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, regs_vmo, 0, 0, 0, 0);
  }
  sys(CROI_SYS_HANDLE_CLOSE, msi, 0, 0, 0, 0);

  // MSI-X: virtio-blk's table. Entries programmed from the allocation,
  // unmasked; entry 1 moved to CPU 1 (QEMU's APIC IDs are CPU numbers);
  // cleared and masked when the objects go.
  uint32_t msix = 0;
  uint32_t virtio_at = find_device(bus, 0xFFFF, 0x1af4, 0x11, &msix);
  if (virtio_at == 0) {
    sys(CROI_SYS_HANDLE_CLOSE, bus_vmo, 0, 0, 0, 0);
    return 0x600D;
  }
  volatile uint8_t *virtio = bus + virtio_at;
  CHECK(292, (*(volatile uint16_t *)(virtio + msix + 2) & 0x7FF) >= 1 &&
                 !(*(volatile uint16_t *)(virtio + msix + 2) & 0x8000));  // MSI-X not enabled
  uint32_t virtio_command = cfg32(virtio, 4) & 0xFFFF;
  cfg32_write(virtio, 4, virtio_command | 1u << 1);
  uint32_t table = cfg32(virtio, msix + 4);
  if (bar(virtio, table & 7) == 0) {  // no address assigned: nothing to look at
    cfg32_write(virtio, 4, virtio_command);
    sys(CROI_SYS_HANDLE_CLOSE, bus_vmo, 0, 0, 0, 0);
    return 0x600D;
  }
  uint64_t table_base = bar(virtio, table & 7) + (table & ~7u);
  volatile uint8_t *entries = 0;
  uint32_t table_vmo = physical_vmo(s, table_base & ~(PAGE - 1), PAGE, &entries);
  volatile uint32_t *e = (volatile uint32_t *)(entries + (table_base & (PAGE - 1)));
  uint32_t x0 = 0, x1 = 0;
  CHECK(293, sys(CROI_SYS_MSI_ALLOCATE, s->resource, 2, (uint64_t)&msi, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_INFO, msi, CROI_INFO_MSI, (uint64_t)&info, sizeof info, 0) == 0 &&
                 info.base_irq_id % 2 == 0 &&
                 sys6(CROI_SYS_MSI_CREATE, msi, CROI_MSI_MODE_MSI_X, 0, table_vmo, table_base & (PAGE - 1),
                      (uint64_t)&x0) == 0 &&
                 sys6(CROI_SYS_MSI_CREATE, msi, CROI_MSI_MODE_MSI_X, 1, table_vmo, table_base & (PAGE - 1),
                      (uint64_t)&x1) == 0);
  CHECK(294, e[0] == (uint32_t)info.target_addr && e[1] == 0 && e[2] == info.target_data && (e[3] & 1) == 0 &&
                 e[4] == (uint32_t)info.target_addr && e[6] == info.target_data + 1 && (e[7] & 1) == 0);
  CHECK(295, sys(CROI_SYS_INTERRUPT_SET_AFFINITY, x1, 1u << 1, 0, 0, 0) == 0 && ((e[4] >> 12) & 0xFF) == 1 &&
                 e[6] >= 0xB0 && e[6] < 0xF0 && (e[7] & 1) == 0 && e[0] == (uint32_t)info.target_addr);
  CHECK(296, sys(CROI_SYS_HANDLE_CLOSE, x1, 0, 0, 0, 0) == 0 && e[4] == 0 && e[6] == 0 && (e[7] & 1) == 1 &&
                 sys(CROI_SYS_HANDLE_CLOSE, x0, 0, 0, 0, 0) == 0 && e[0] == 0 && (e[3] & 1) == 1);
  cfg32_write(virtio, 4, virtio_command);
  sys(CROI_SYS_HANDLE_CLOSE, table_vmo, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, msi, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, bus_vmo, 0, 0, 0, 0);
  return 0x600D;
}
#else
static int64_t msi_test(const startup_t *s, uint32_t port) {
  (void)port;
  uint32_t msi = 0;
  CHECK(281, sys(CROI_SYS_MSI_ALLOCATE, s->resource, 1, (uint64_t)&msi, 0, 0) == ERR_NOT_SUPPORTED);
  return 0x600D;
}
#endif

static int64_t interrupts(const startup_t *s) {
  uint32_t port = 0, irq = 0, intr = 0, other = 0;
  croi_port_packet_t p;
  CHECK(264, sys(CROI_SYS_PORT_CREATE, 2, (uint64_t)&port, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_PORT_CREATE, CROI_PORT_BIND_TO_INTERRUPT, (uint64_t)&port, 0, 0, 0) == 0);
  int64_t result = virtual_interrupts(s, port);
  if (result != 0x600D) return result;

  // Creation: the IRQ resource must cover the number; one object per number.
  volatile uint32_t *regs = irq_device_setup(s);
  CHECK(265, resource_create(s->resource, CROI_RSRC_KIND_IRQ, IRQ_NUMBER, 1, &irq) == 0 &&
                 sys(CROI_SYS_INTERRUPT_CREATE, irq, IRQ_NUMBER + 1, 0, (uint64_t)&intr, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_INTERRUPT_CREATE, s->resource, 5000, 0, (uint64_t)&intr, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_INTERRUPT_CREATE, irq, IRQ_NUMBER, 1u << 8, (uint64_t)&intr, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_INTERRUPT_CREATE, irq, IRQ_NUMBER, CROI_INTERRUPT_MODE_EDGE_BOTH, (uint64_t)&intr, 0) ==
                     ERR_NOT_SUPPORTED);
  CHECK(266, sys(CROI_SYS_INTERRUPT_CREATE, irq, IRQ_NUMBER, 0, (uint64_t)&intr, 0) == 0 &&
                 sys(CROI_SYS_INTERRUPT_CREATE, irq, IRQ_NUMBER, 0, (uint64_t)&other, 0) == ERR_ALREADY_BOUND &&
                 sys(CROI_SYS_INTERRUPT_TRIGGER, intr, 0, 1, 0, 0) == ERR_BAD_STATE);
  // Affinity: to CPU 1 (the kernel checks where it was taken).
  CHECK(267, sys(CROI_SYS_INTERRUPT_SET_AFFINITY, intr, 0, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_INTERRUPT_SET_AFFINITY, intr, 1ull << 63, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_INTERRUPT_SET_AFFINITY, intr, 1u << 1, 0, 0, 0) == 0);

  // Bound to a port.
  CHECK(268, sys(CROI_SYS_INTERRUPT_BIND, intr, port, 42, CROI_INTERRUPT_BIND, 0) == 0);
  uint64_t before = now_ns();
  irq_device_start(regs);
  CHECK(269, port_next(port, 3000000000ull, &p) == 0 && p.type == CROI_PKT_TYPE_INTERRUPT && p.key == 42 &&
                 p.payload[0] >= before && p.payload[0] <= now_ns());
#if IRQ_LEVEL && !defined(__riscv)
  // Level: still asserted, so an ack without clearing it fires again.
  // (Not on rv64: QEMU's PLIC sets pending only on a rising line, so a
  // source completed while still high never comes back; real gateways
  // forward it again.)
  CHECK(270, sys(CROI_SYS_INTERRUPT_ACK, intr, 0, 0, 0, 0) == 0 && port_next(port, 500000000, &p) == 0 &&
                 p.key == 42);
  irq_device_stop(regs);
#elif IRQ_LEVEL
  irq_device_stop(regs);
#else
  // Edge: further edges while unacked are only remembered, then sent on ack.
  irq_device_clear(regs);
  sleep_ns(20000000);
  CHECK(270, port_next(port, 0, &p) == ERR_TIMED_OUT && sys(CROI_SYS_INTERRUPT_ACK, intr, 0, 0, 0, 0) == 0 &&
                 port_next(port, 500000000, &p) == 0 && p.key == 42);
  irq_device_stop(regs);
  for (int i = 0; i < 3 && port_next(port, 0, &p) != ERR_TIMED_OUT;) i++;
#endif
  // Quiet once the device is: ack, then nothing more.
  sys(CROI_SYS_INTERRUPT_ACK, intr, 0, 0, 0, 0);
  for (int i = 0; i < 3 && port_next(port, 20000000, &p) == 0; i++) sys(CROI_SYS_INTERRUPT_ACK, intr, 0, 0, 0, 0);
  CHECK(271, port_next(port, 50000000, &p) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_INTERRUPT_BIND, intr, port, 0, CROI_INTERRUPT_UNBIND, 0) == 0);

  // interrupt_wait: the woken thread's latency from the fire's timestamp.
  uint64_t latencies[IRQ_WAITS];
  irq_device_start(regs);
  for (int i = 0; i < IRQ_WAITS; i++) {
    uint64_t time = 0;
    CHECK(272, sys(CROI_SYS_INTERRUPT_WAIT, intr, (uint64_t)&time, 0, 0, 0) == 0 && time != 0);
    latencies[i] = now_ns() - time;
    irq_device_clear(regs);
#if IRQ_LEVEL
    if (i + 1 < IRQ_WAITS) irq_device_start(regs);
#endif
  }
  irq_device_stop(regs);
  for (int i = 1; i < IRQ_WAITS; i++) {  // insertion sort for the median
    uint64_t v = latencies[i];
    int j = i;
    for (; j > 0 && latencies[j - 1] > v; j--) latencies[j] = latencies[j - 1];
    latencies[j] = v;
  }
  sys(CROI_SYS_TEST_REPORT, latencies[IRQ_WAITS / 2], 0, 0, 0, 0);

  // Destroyed: everything is CANCELED; the number is free again.
  CHECK(273, sys(CROI_SYS_INTERRUPT_DESTROY, intr, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_INTERRUPT_ACK, intr, 0, 0, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_INTERRUPT_WAIT, intr, 0, 0, 0, 0) == ERR_CANCELED &&
                 sys(CROI_SYS_INTERRUPT_SET_AFFINITY, intr, 1, 0, 0, 0) == ERR_CANCELED &&
                 sys(CROI_SYS_HANDLE_CLOSE, intr, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_INTERRUPT_CREATE, irq, IRQ_NUMBER, 0, (uint64_t)&intr, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, intr, 0, 0, 0, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, irq, 0, 0, 0, 0);
  result = msi_test(s, port);
  sys(CROI_SYS_HANDLE_CLOSE, port, 0, 0, 0, 0);
  return result;
}

// Mode 12 (K9e): DMA through the stub IOMMU. BTIs, pinning (addresses,
// options, refusals), pinned pages held against decommit and cache policy
// changes, quarantine, contiguous VMOs, croi's BTI properties, and the
// debuglog record a no-IOMMU BTI leaves.
#define ERR_BAD_HANDLE (-11)
#define ERR_ACCESS_DENIED_ (-30)
#define ERR_NO_MEMORY (-4)
static int64_t bti_pin(uint32_t bti, uint32_t options, uint32_t vmo, uint64_t count, uint64_t offset, uint64_t size,
                       uint64_t *addrs, uint32_t *pmt) {
  return sys6(CROI_SYS_BTI_PIN, bti | (uint64_t)options << 32, vmo | count << 32, offset, size, (uint64_t)addrs,
              (uint64_t)pmt);
}

static croi_info_bti_t bti_info(uint32_t bti) {
  croi_info_bti_t info = {};
  CHECK(300, sys(CROI_SYS_OBJECT_GET_INFO, bti, CROI_INFO_BTI, (uint64_t)&info, sizeof info, 0) == 0);
  return info;
}

// Whether a debuglog record holds `text`.
static int log_has(const startup_t *s, const char *text) {
  uint32_t log = 0;
  CHECK(301, sys(CROI_SYS_DEBUGLOG_CREATE, s->resource, CROI_LOG_FLAG_READABLE, (uint64_t)&log, 0, 0) == 0);
  uint8_t record[CROI_LOG_RECORD_MAX];
  int found = 0;
  int64_t size;
  while (!found && (size = sys(CROI_SYS_DEBUGLOG_READ, log, 0, (uint64_t)record, sizeof record, 0)) > 0) {
    const croi_log_record_t *header = (const croi_log_record_t *)record;
    const char *data = (const char *)(record + sizeof *header);
    for (int i = 0; !found && i + 1 <= header->datalen; i++) {
      int j = 0;
      while (text[j] && i + j < header->datalen && data[i + j] == text[j]) j++;
      found = text[j] == 0;
    }
  }
  sys(CROI_SYS_HANDLE_CLOSE, log, 0, 0, 0, 0);
  return found;
}

static int64_t dma(const startup_t *s) {
  uint32_t iommu = 0, bti = 0, tracing = 0, vmo = 0, readonly = 0, pmt = 0, dup = 0;
  uint8_t desc = 0;
  CHECK(302, resource_create(s->resource, CROI_RSRC_KIND_SYSTEM, CROI_RSRC_SYSTEM_TRACING_BASE, 1, &tracing) == 0 &&
                 sys(CROI_SYS_IOMMU_CREATE, tracing, CROI_IOMMU_TYPE_STUB, (uint64_t)&desc, 1, (uint64_t)&iommu) ==
                     ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, CROI_IOMMU_TYPE_INTEL, (uint64_t)&desc, 1, (uint64_t)&iommu) ==
                     ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, 9, (uint64_t)&desc, 1, (uint64_t)&iommu) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, CROI_IOMMU_TYPE_STUB, 0, 0, (uint64_t)&iommu) ==
                     ERR_INVALID_ARGS &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, CROI_IOMMU_TYPE_STUB, (uint64_t)&desc, 1, (uint64_t)&iommu) ==
                     0);
  sys(CROI_SYS_HANDLE_CLOSE, tracing, 0, 0, 0, 0);
  CHECK(303, sys(CROI_SYS_BTI_CREATE, iommu, 1, 0x1234, (uint64_t)&bti, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_BTI_CREATE, iommu, 0, 0x1234, (uint64_t)&bti, 0) == 0 &&
                 log_has(s, "no-IOMMU BTI 0x1234"));
  croi_info_bti_t info = bti_info(bti);
  CHECK(304, info.minimum_contiguity == PAGE && info.pmo_count == 0 && info.quarantine_count == 0);

  // Per page: addresses page aligned; the pages held against decommit and
  // cache policy changes; ZERO still works (in place).
  uint64_t addrs[4] = {0, 0, 0, 0};
  uint32_t rw = CROI_BTI_PERM_READ | CROI_BTI_PERM_WRITE;
  CHECK(305, sys(CROI_SYS_VMO_CREATE, 4 * PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 bti_pin(bti, rw, vmo, 3, 0, 4 * PAGE, addrs, &pmt) == ERR_INVALID_ARGS &&
                 bti_pin(bti, rw, vmo, 4, 1, 4 * PAGE, addrs, &pmt) == ERR_INVALID_ARGS &&
                 bti_pin(bti, rw | CROI_BTI_CONTIGUOUS, vmo, 1, 0, 4 * PAGE, addrs, &pmt) == ERR_INVALID_ARGS &&
                 bti_pin(bti, rw | CROI_BTI_CONTIGUOUS | CROI_BTI_COMPRESS, vmo, 4, 0, 4 * PAGE, addrs, &pmt) ==
                     ERR_INVALID_ARGS &&
                 bti_pin(bti, 1u << 7, vmo, 4, 0, 4 * PAGE, addrs, &pmt) == ERR_INVALID_ARGS);
  CHECK(306, sys(CROI_SYS_HANDLE_DUPLICATE, vmo, 1u << 2 | 1u << 5 | 1u << 1, (uint64_t)&readonly, 0, 0) == 0 &&
                 bti_pin(bti, rw, readonly, 4, 0, 4 * PAGE, addrs, &pmt) == ERR_ACCESS_DENIED_ &&
                 bti_pin(bti, CROI_BTI_PERM_READ, readonly, 4, 0, 4 * PAGE, addrs, &pmt) == 0 &&
                 sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, readonly, 0, 0, 0, 0);
  uint8_t bytes[16];
  for (int i = 0; i < 16; i++) bytes[i] = 0x5A;
  CHECK(307, bti_pin(bti, rw, vmo, 4, 0, 4 * PAGE, addrs, &pmt) == 0 && addrs[0] != 0 && addrs[0] % PAGE == 0 &&
                 addrs[3] % PAGE == 0 && bti_info(bti).pmo_count == 1 &&
                 sys(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, 0, PAGE, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, vmo, CROI_CACHE_POLICY_UNCACHED, 0, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)bytes, PAGE, 16, 0) == 0 &&
                 sys(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_ZERO, 0, 4 * PAGE, 0) == 0 &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)bytes, PAGE, 16, 0) == 0 && bytes[0] == 0 && bytes[15] == 0);
  // The PMT can't be duplicated; unpin consumes its handle and frees the pages.
  CHECK(308, sys(CROI_SYS_HANDLE_DUPLICATE, pmt, 1u << 31, (uint64_t)&dup, 0, 0) == ERR_ACCESS_DENIED_ &&
                 sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, pmt, 0, 0, 0, 0) == ERR_BAD_HANDLE && bti_info(bti).pmo_count == 0 &&
                 sys(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, 0, PAGE, 0) == 0);
  // Closed without unpinning: quarantined until released.
  CHECK(309, bti_pin(bti, rw, vmo, 1, PAGE, PAGE, addrs, &pmt) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, pmt, 0, 0, 0, 0) == 0 && bti_info(bti).quarantine_count == 1 &&
                 bti_info(bti).pmo_count == 0 &&
                 sys(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, PAGE, PAGE, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_BTI_RELEASE_QUARANTINE, bti, 0, 0, 0, 0) == 0 && bti_info(bti).quarantine_count == 0 &&
                 sys(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, PAGE, PAGE, 0) == 0);

  // Contiguous VMOs: one address with CONTIGUOUS, consecutive pages without,
  // aligned as asked.
  uint32_t contig = 0;
  CHECK(310, sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, 0, 0, (uint64_t)&contig, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, PAGE + 1, 0, (uint64_t)&contig, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, PAGE, 11, (uint64_t)&contig, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, 3 * PAGE, 16, (uint64_t)&contig, 0) == 0 &&
                 bti_pin(bti, rw | CROI_BTI_CONTIGUOUS, contig, 1, 0, 3 * PAGE, addrs, &pmt) == 0 &&
                 addrs[0] % 0x10000 == 0 && sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0);
  uint64_t base = addrs[0];
  CHECK(311, bti_pin(bti, rw, contig, 3, 0, 3 * PAGE, addrs, &pmt) == 0 && addrs[0] == base &&
                 addrs[1] == base + PAGE && addrs[2] == base + 2 * PAGE && sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0);

  // Properties: defaults; only narrowing. The window is exactly the
  // contiguous VMO's pages, so any other memory is outside it.
  croi_bti_properties_t p = {};
  CHECK(312, sys(CROI_SYS_OBJECT_GET_INFO, bti, CROI_INFO_BTI_PROPERTIES, (uint64_t)&p, sizeof p, 0) == 0 &&
                 p.address_bits == 64 && p.memory_type == CROI_BTI_MEMORY_COHERENT && p.window_size == 0);
  uint32_t other = 0, inside = 0;
  CHECK(313, sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, PAGE, 0, (uint64_t)&other, 0) == 0);
  croi_bti_properties_t narrow = {.address_bits = 40, .memory_type = CROI_BTI_MEMORY_COHERENT,
                                  .window_base = base, .window_size = 3 * PAGE};
  croi_bti_properties_t wide = narrow;
  wide.address_bits = 48;
  CHECK(314, sys(CROI_SYS_BTI_SET_PROPERTIES, bti, (uint64_t)&narrow, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_BTI_SET_PROPERTIES, bti, (uint64_t)&wide, 0, 0, 0) == ERR_ACCESS_DENIED_ &&
                 (wide = narrow, wide.window_size = 4 * PAGE,
                  sys(CROI_SYS_BTI_SET_PROPERTIES, bti, (uint64_t)&wide, 0, 0, 0) == ERR_ACCESS_DENIED_) &&
                 (wide = narrow, wide.address_bits = 8,
                  sys(CROI_SYS_BTI_SET_PROPERTIES, bti, (uint64_t)&wide, 0, 0, 0) == ERR_INVALID_ARGS));
  // Inside pins; outside (another contiguous VMO, an anonymous page) doesn't.
  CHECK(315, bti_pin(bti, rw, contig, 3, 0, 3 * PAGE, addrs, &pmt) == 0 && sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0 &&
                 bti_pin(bti, rw, other, 1, 0, PAGE, addrs, &pmt) == ERR_OUT_OF_RANGE &&
                 bti_pin(bti, rw, vmo, 1, 0, PAGE, addrs, &pmt) == ERR_OUT_OF_RANGE && bti_info(bti).pmo_count == 0);
  // Contiguous allocations land inside: the window's pages, freed, are
  // the only place left.
  CHECK(316, sys(CROI_SYS_HANDLE_CLOSE, contig, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, 2 * PAGE, 0, (uint64_t)&inside, 0) == 0 &&
                 bti_pin(bti, rw | CROI_BTI_CONTIGUOUS, inside, 1, 0, 2 * PAGE, addrs, &pmt) == 0 && addrs[0] >= base &&
                 addrs[0] + 2 * PAGE <= base + 3 * PAGE);
  // Memory type: fixed while something is pinned; non-coherent memory is
  // uncached (vmo_read refuses it).
  croi_bti_properties_t noncoherent = narrow;
  noncoherent.memory_type = CROI_BTI_MEMORY_NONCOHERENT;
  CHECK(317, sys(CROI_SYS_BTI_SET_PROPERTIES, bti, (uint64_t)&noncoherent, 0, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0 && sys(CROI_SYS_HANDLE_CLOSE, inside, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_BTI_SET_PROPERTIES, bti, (uint64_t)&noncoherent, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, PAGE, 0, (uint64_t)&inside, 0) == 0 &&
                 sys(CROI_SYS_VMO_READ, inside, (uint64_t)bytes, 0, 8, 0) == ERR_BAD_STATE);
  sys(CROI_SYS_HANDLE_CLOSE, inside, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, other, 0, 0, 0, 0);
  // Width: 12 bits reach no RAM, so nothing pins and nothing allocates.
  uint32_t narrow_bti = 0;
  croi_bti_properties_t tiny = {.address_bits = 12, .memory_type = CROI_BTI_MEMORY_COHERENT};
  CHECK(318, sys(CROI_SYS_BTI_CREATE, iommu, 0, 0x5678, (uint64_t)&narrow_bti, 0) == 0 &&
                 sys(CROI_SYS_BTI_SET_PROPERTIES, narrow_bti, (uint64_t)&tiny, 0, 0, 0) == 0 &&
                 bti_pin(narrow_bti, rw, vmo, 1, 0, PAGE, addrs, &pmt) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, narrow_bti, PAGE, 0, (uint64_t)&inside, 0) == ERR_NO_MEMORY &&
                 sys(CROI_SYS_HANDLE_CLOSE, narrow_bti, 0, 0, 0, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, bti, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, iommu, 0, 0, 0, 0);
  return 0x600D;
}

// Mode 13: memory statistics (Todhchai's M3 resident-memory budget):
// ZX_INFO_TASK_STATS on processes, ZX_INFO_KMEM_STATS on the root
// resource. Private and shared move with one VMO mapped here and then in
// two children; this thread's stack may grow meanwhile, so private is
// checked within a few pages.
static int64_t info(uint32_t handle, uint32_t topic, void *buffer, uint64_t size) {
  return sys(CROI_SYS_OBJECT_GET_INFO, handle, topic, (uint64_t)buffer, size, 0);
}

// Scaled shared bytes with their fraction, as one 63-bit fixed-point number.
static unsigned __int128 scaled(const croi_info_task_stats_t *t) {
  return ((unsigned __int128)t->mem_scaled_shared_bytes << 63) + t->mem_fractional_scaled_shared_bytes;
}

static int64_t memory_stats(const startup_t *s) {
  // The children first: every process maps the vDSO, so its pages turn
  // shared as processes appear. Baselines are taken once they all exist.
  uint32_t child = 0, child_vmar = 0, other = 0, other_vmar = 0;
  CHECK(320, sys6(CROI_SYS_PROCESS_CREATE, s->job, (uint64_t)"stats", 5, 0, (uint64_t)&child, (uint64_t)&child_vmar) ==
                     0 &&
                 sys6(CROI_SYS_PROCESS_CREATE, s->job, (uint64_t)"stats", 5, 0, (uint64_t)&other, (uint64_t)&other_vmar) ==
                     0);
  croi_info_task_stats_t a, b, c, mine, theirs, theirs0, other0;
  CHECK(321, info(s->process, CROI_INFO_TASK_STATS, &a, sizeof a) == 0 && a.mem_mapped_bytes > 0 &&
                 a.mem_private_bytes > 0 && info(child, CROI_INFO_TASK_STATS, &theirs0, sizeof theirs0) == 0 &&
                 info(other, CROI_INFO_TASK_STATS, &other0, sizeof other0) == 0);
  // A VMO of 4 pages mapped here, 2 committed: private.
  uint32_t vmo = 0;
  uint64_t at = 0, there = 0;
  CHECK(322, sys(CROI_SYS_VMO_CREATE, 4 * PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, vmo,
                      0, 4 * PAGE, (uint64_t)&at) == 0);
  *(volatile uint64_t *)at = 1;
  *(volatile uint64_t *)(at + 2 * PAGE) = 1;
  CHECK(323, info(s->process, CROI_INFO_TASK_STATS, &b, sizeof b) == 0 &&
                 b.mem_mapped_bytes == a.mem_mapped_bytes + 4 * PAGE &&
                 b.mem_private_bytes >= a.mem_private_bytes + 2 * PAGE &&
                 b.mem_private_bytes <= a.mem_private_bytes + 6 * PAGE && b.mem_shared_bytes == a.mem_shared_bytes);
  // Mapped into a child too: shared, half of it each.
  CHECK(324, sys6(CROI_SYS_VMAR_MAP, child_vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, vmo, 0, 4 * PAGE,
                  (uint64_t)&there) == 0 &&
                 info(s->process, CROI_INFO_TASK_STATS, &mine, sizeof mine) == 0 &&
                 info(child, CROI_INFO_TASK_STATS, &theirs, sizeof theirs) == 0);
  CHECK(325, mine.mem_shared_bytes == a.mem_shared_bytes + 2 * PAGE &&
                 scaled(&mine) == scaled(&a) + ((unsigned __int128)PAGE << 63) &&
                 mine.mem_private_bytes + 2 * PAGE <= b.mem_private_bytes + 4 * PAGE);
  CHECK(326, theirs.mem_shared_bytes == theirs0.mem_shared_bytes + 2 * PAGE &&
                 scaled(&theirs) == scaled(&theirs0) + ((unsigned __int128)PAGE << 63) &&
                 theirs.mem_mapped_bytes == theirs0.mem_mapped_bytes + 4 * PAGE);
  // A third: 8192 / 3 = 2730 and two thirds of a byte, carried as a fraction.
  CHECK(327, sys6(CROI_SYS_VMAR_MAP, other_vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, vmo, 0, 4 * PAGE,
                  (uint64_t)&there) == 0 &&
                 info(other, CROI_INFO_TASK_STATS, &c, sizeof c) == 0 &&
                 c.mem_shared_bytes == other0.mem_shared_bytes + 2 * PAGE &&
                 scaled(&c) == scaled(&other0) + ((unsigned __int128)2730 << 63) + 0x5555555555555555ull);
  // Zircon's rules: INSPECT, a process, a big enough buffer; v1 is shorter.
  uint32_t weak = 0, thread = 0;
  croi_info_task_stats_t v1;
  v1.mem_fractional_scaled_shared_bytes = 77;
  CHECK(328, sys(CROI_SYS_HANDLE_DUPLICATE, child, 1u << 1, (uint64_t)&weak, 0, 0) == 0 &&
                 info(weak, CROI_INFO_TASK_STATS, &c, sizeof c) == ERR_ACCESS_DENIED_ &&
                 info(child, CROI_INFO_TASK_STATS, &c, 32) == ERR_BUFFER_TOO_SMALL &&
                 info(child, CROI_INFO_TASK_STATS_V1, &v1, 32) == 0 && v1.mem_shared_bytes == theirs.mem_shared_bytes &&
                 v1.mem_fractional_scaled_shared_bytes == 77 &&
                 sys6(CROI_SYS_THREAD_CREATE, child, (uint64_t)"t", 1, 0, (uint64_t)&thread, 0) == 0 &&
                 info(thread, CROI_INFO_TASK_STATS, &c, sizeof c) == ERR_WRONG_TYPE);
  sys(CROI_SYS_HANDLE_CLOSE, weak, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, child, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, child_vmar, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, other, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, other_vmar, 0, 0, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, 4 * PAGE, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);

  // Kernel memory: needs the INFO resource; the parts add up.
  croi_info_kmem_stats_t k;
  croi_info_kmem_stats_v1_t k1;
  uint32_t tracing = 0;
  CHECK(329, info(s->resource, CROI_INFO_KMEM_STATS, &k, sizeof k) == 0 && k.total_bytes > 0 && k.free_bytes > 0 &&
                 k.vmo_bytes > 0 && k.total_heap_bytes > 0 && k.mmu_overhead_bytes > 0 &&
                 k.free_bytes + k.wired_bytes + k.total_heap_bytes + k.vmo_bytes + k.mmu_overhead_bytes +
                         k.other_bytes <= k.total_bytes &&
                 info(s->resource, CROI_INFO_KMEM_STATS_V1, &k1, sizeof k1) == 0 && k1.total_bytes == k.total_bytes &&
                 info(s->resource, CROI_INFO_KMEM_STATS, &k, sizeof k1) == ERR_BUFFER_TOO_SMALL &&
                 resource_create(s->resource, CROI_RSRC_KIND_SYSTEM, CROI_RSRC_SYSTEM_TRACING_BASE, 1, &tracing) == 0 &&
                 info(tracing, CROI_INFO_KMEM_STATS, &k, sizeof k) != 0 &&
                 info(s->process, CROI_INFO_KMEM_STATS, &k, sizeof k) == ERR_WRONG_TYPE);
  sys(CROI_SYS_HANDLE_CLOSE, tracing, 0, 0, 0, 0);
  return 0x600D;
}

// Mode 14 (K10a): counters. Zircon's semantics (signals, overflow,
// rights), then croi's waits at a value: blocking, cancelled by a close,
// and as port packets (immediate, later, cancelled).
typedef struct {
  uint32_t handle;
  int64_t target;
  volatile int64_t status;
} counter_waiter_t;
static void counter_waiter(uint64_t arg) {
  counter_waiter_t *w = (counter_waiter_t *)arg;
  w->status = sys(CROI_SYS_COUNTER_WAIT, w->handle, (uint64_t)w->target, ~0ull, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t counters(const startup_t *s) {
  uint32_t c = 0, weak = 0, port = 0;
  int64_t value = -1;
  CHECK(340, sys(CROI_SYS_COUNTER_CREATE, 1, (uint64_t)&c, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_COUNTER_CREATE, 0, (uint64_t)&c, 0, 0, 0) == 0 &&
                 (wait_for(c, CROI_COUNTER_NON_POSITIVE, 0) & CROI_COUNTER_NON_POSITIVE) &&
                 sys(CROI_SYS_COUNTER_READ, c, (uint64_t)&value, 0, 0, 0) == 0 && value == 0);
  CHECK(341, sys(CROI_SYS_COUNTER_ADD, c, 5, 0, 0, 0) == 0 &&
                 (wait_for(c, CROI_COUNTER_POSITIVE, 0) & (CROI_COUNTER_POSITIVE | CROI_COUNTER_NON_POSITIVE)) ==
                     CROI_COUNTER_POSITIVE &&
                 sys(CROI_SYS_COUNTER_WRITE, c, (uint64_t)-3, 0, 0, 0) == 0 &&
                 (wait_for(c, CROI_COUNTER_NON_POSITIVE, 0) & CROI_COUNTER_NON_POSITIVE) &&
                 sys(CROI_SYS_COUNTER_WRITE, c, 0x7FFFFFFFFFFFFFFFull, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_COUNTER_ADD, c, 1, 0, 0, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_COUNTER_READ, c, (uint64_t)&value, 0, 0, 0) == 0 && value == 0x7FFFFFFFFFFFFFFFll &&
                 sys(CROI_SYS_COUNTER_READ, c, 0, 0, 0, 0) == ERR_INVALID_ARGS);
  // Rights: add needs READ and WRITE, a value wait WAIT and READ.
  CHECK(342, sys(CROI_SYS_HANDLE_DUPLICATE, c, 1u << 2 | 1u << 14, (uint64_t)&weak, 0, 0) == 0 &&  // READ, WAIT
                 sys(CROI_SYS_COUNTER_ADD, weak, 1, 0, 0, 0) == ERR_ACCESS_DENIED_ &&
                 sys(CROI_SYS_COUNTER_WRITE, weak, 1, 0, 0, 0) == ERR_ACCESS_DENIED_ &&
                 sys(CROI_SYS_COUNTER_READ, weak, (uint64_t)&value, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, weak, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, c, 1u << 14, (uint64_t)&weak, 0, 0) == 0 &&  // WAIT only
                 sys(CROI_SYS_COUNTER_WAIT, weak, 0, 0, 0, 0) == ERR_ACCESS_DENIED_ &&
                 sys(CROI_SYS_HANDLE_CLOSE, weak, 0, 0, 0, 0) == 0);
  // Waits at a value: met at once, timed out, woken only once reached.
  CHECK(343, sys(CROI_SYS_COUNTER_WRITE, c, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_COUNTER_WAIT, c, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_COUNTER_WAIT, c, (uint64_t)-5, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_COUNTER_WAIT, c, 3, now_ns() + 1000000, 0, 0) == ERR_TIMED_OUT);
  counter_waiter_t w = {.handle = c, .target = 10, .status = 1};
  uint32_t worker = start_thread(s, counter_waiter, (uint64_t)&w);
  sleep_ns(10000000);
  CHECK(344, sys(CROI_SYS_COUNTER_ADD, c, 5, 0, 0, 0) == 0);
  sleep_ns(10000000);
  CHECK(345, w.status == 1 && sys(CROI_SYS_COUNTER_ADD, c, 5, 0, 0, 0) == 0);
  join_checked(worker);
  CHECK(346, w.status == 0);
  // Closing the handle a thread waits through cancels its wait.
  CHECK(347, sys(CROI_SYS_HANDLE_DUPLICATE, c, 1u << 31, (uint64_t)&weak, 0, 0) == 0);
  w.handle = weak, w.target = 1000, w.status = 1;
  worker = start_thread(s, counter_waiter, (uint64_t)&w);
  sleep_ns(10000000);
  CHECK(348, sys(CROI_SYS_HANDLE_CLOSE, weak, 0, 0, 0, 0) == 0);
  join_checked(worker);
  CHECK(349, w.status == ERR_CANCELED);
  // Port packets: later, at once, cancelled.
  croi_port_packet_t p;
  uint64_t before = now_ns();
  CHECK(350, sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_COUNTER_WAIT_ASYNC, c, port, 7, 20, 0) == 0 && port_next(port, 0, &p) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_COUNTER_WRITE, c, 25, 0, 0, 0) == 0 && port_next(port, 0, &p) == 0 &&
                 p.type == CROI_PKT_TYPE_COUNTER && p.key == 7 && p.payload[0] == 20 && p.payload[1] == 25 &&
                 p.payload[2] >= before && port_next(port, 0, &p) == ERR_TIMED_OUT);
  CHECK(351, sys(CROI_SYS_COUNTER_WAIT_ASYNC, c, port, 8, 25, 0) == 0 && port_next(port, 0, &p) == 0 && p.key == 8 &&
                 p.payload[1] == 25 && sys(CROI_SYS_COUNTER_WAIT_ASYNC, c, port, 9, 100, 0) == 0 &&
                 sys(CROI_SYS_PORT_CANCEL, port, c, 9, 0, 0) == 0 && sys(CROI_SYS_COUNTER_WRITE, c, 200, 0, 0, 0) == 0 &&
                 port_next(port, 0, &p) == ERR_TIMED_OUT);
  sys(CROI_SYS_HANDLE_CLOSE, port, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, c, 0, 0, 0, 0);
  return 0x600D;
}

// Mode 15 (K10b): display timelines. A synthetic one (the kernel's,
// from the time): its page, waits for the next vblank (blocking and by
// port), a period change; a driven one, advanced at a timestamp; rights.
static int64_t page_count(volatile const croi_timeline_page_t *page, uint64_t t) {
  return page->base_count + (int64_t)((t - page->base_time_ns) / page->period_ns);
}

static int64_t timelines(const startup_t *s) {
  uint32_t t = 0, tracing = 0, page_vmo = 0, port = 0, weak = 0, driven = 0;
  uint64_t at = 0;
  CHECK(360, resource_create(s->resource, CROI_RSRC_KIND_SYSTEM, CROI_RSRC_SYSTEM_TRACING_BASE, 1, &tracing) == 0 &&
                 sys(CROI_SYS_TIMELINE_CREATE, tracing, CROI_TIMELINE_SYNTHETIC, 2000000, (uint64_t)&t, 0) ==
                     ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_TIMELINE_CREATE, s->resource, 1u << 5, 2000000, (uint64_t)&t, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_TIMELINE_CREATE, s->resource, CROI_TIMELINE_SYNTHETIC, 1000, (uint64_t)&t, 0) ==
                     ERR_INVALID_ARGS &&
                 sys(CROI_SYS_TIMELINE_CREATE, s->resource, CROI_TIMELINE_SYNTHETIC, 2000000, (uint64_t)&t, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, tracing, 0, 0, 0, 0);
  // The page: read only, cached only, and what it says.
  CHECK(361, sys(CROI_SYS_TIMELINE_GET_PAGE, t, (uint64_t)&page_vmo, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0,
                      page_vmo, 0, PAGE, (uint64_t)&at) != 0 &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, page_vmo, CROI_CACHE_POLICY_UNCACHED, 0, 0, 0) == ERR_ACCESS_DENIED_ &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, page_vmo, 0, PAGE,
                      (uint64_t)&at) == 0);
  volatile const croi_timeline_page_t *page = (volatile const croi_timeline_page_t *)at;
  int64_t value = -1;
  CHECK(362, page->version == CROI_TIMELINE_PAGE_VERSION && (page->flags & CROI_TIMELINE_PAGE_SYNTHESIZED) &&
                 page->period_ns == 2000000 && (page->sequence & 1) == 0 &&
                 sys(CROI_SYS_COUNTER_READ, t, (uint64_t)&value, 0, 0, 0) == 0 &&
                 value >= page_count(page, now_ns()) - 1 && value <= page_count(page, now_ns()) &&
                 sys(CROI_SYS_COUNTER_ADD, t, 1, 0, 0, 0) == ERR_WRONG_TYPE &&
                 sys(CROI_SYS_TIMELINE_ADVANCE, t, 5, 0, 0, 0) == ERR_BAD_STATE);
  // The next vblank: not before its time, not much after.
  for (int i = 0; i < 3; i++) {
    CHECK(363, sys(CROI_SYS_COUNTER_READ, t, (uint64_t)&value, 0, 0, 0) == 0);
    uint64_t due = page->base_time_ns + (uint64_t)(value + 1 - page->base_count) * page->period_ns;
    CHECK(364, sys(CROI_SYS_COUNTER_WAIT, t, (uint64_t)(value + 1), now_ns() + 100000000, 0, 0) == 0);
    uint64_t woke = now_ns();
    CHECK(365, woke >= due && woke - due < 5000000);
  }
  // By port, two vblanks ahead.
  croi_port_packet_t p;
  CHECK(366, sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_COUNTER_READ, t, (uint64_t)&value, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_COUNTER_WAIT_ASYNC, t, port, 5, (uint64_t)(value + 2), 0) == 0 &&
                 port_next(port, 100000000, &p) == 0 && p.type == CROI_PKT_TYPE_COUNTER && p.key == 5 &&
                 (int64_t)p.payload[1] >= value + 2);
  // A new period: the count carries on.
  int64_t before = 0, after = 0;
  CHECK(367, sys(CROI_SYS_COUNTER_READ, t, (uint64_t)&before, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_TIMELINE_SET_PERIOD, t, 4000000, 0, 0, 0) == 0 && page->period_ns == 4000000 &&
                 sys(CROI_SYS_COUNTER_READ, t, (uint64_t)&after, 0, 0, 0) == 0 && after >= before &&
                 after <= before + 1 && sys(CROI_SYS_COUNTER_WAIT, t, (uint64_t)(after + 1), now_ns() + 100000000, 0, 0) == 0);
  // Rights: a client's handle (READ, WAIT) can't drive it.
  CHECK(368, sys(CROI_SYS_HANDLE_DUPLICATE, t, 1u << 2 | 1u << 14, (uint64_t)&weak, 0, 0) == 0 &&
                 sys(CROI_SYS_TIMELINE_SET_PERIOD, weak, 3000000, 0, 0, 0) == ERR_ACCESS_DENIED_ &&
                 sys(CROI_SYS_COUNTER_WAIT, weak, 0, 0, 0, 0) == 0);
  // Driven: a waiter wakes when the driver counts a vblank.
  CHECK(369, sys(CROI_SYS_TIMELINE_CREATE, s->resource, 0, 16666666, (uint64_t)&driven, 0) == 0 &&
                 sys(CROI_SYS_COUNTER_READ, driven, (uint64_t)&value, 0, 0, 0) == 0 && value == 0);
  counter_waiter_t w = {.handle = driven, .target = 1, .status = 1};
  uint32_t worker = start_thread(s, counter_waiter, (uint64_t)&w);
  sleep_ns(10000000);
  CHECK(370, w.status == 1 && sys(CROI_SYS_TIMELINE_ADVANCE, driven, 12345678, 0, 0, 0) == 0);
  join_checked(worker);
  uint32_t driven_page = 0;
  uint64_t driven_at = 0;
  CHECK(371, w.status == 0 && sys(CROI_SYS_TIMELINE_GET_PAGE, driven, (uint64_t)&driven_page, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, driven_page, 0, PAGE,
                      (uint64_t)&driven_at) == 0 &&
                 ((volatile const croi_timeline_page_t *)driven_at)->base_count == 1 &&
                 ((volatile const croi_timeline_page_t *)driven_at)->base_time_ns == 12345678 &&
                 ((volatile const croi_timeline_page_t *)driven_at)->flags == 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, PAGE, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, driven_at, PAGE, 0, 0);
  uint32_t handles[] = {t, page_vmo, port, weak, driven, driven_page};
  for (int i = 0; i < 6; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0x600D;
}

// Byte by byte, through volatile: a plain loop or `= {0}` becomes a memset
// call, which this program doesn't link.
static void zero_bytes(void *p, uint64_t n) {
  for (volatile uint8_t *b = p; n--; b++) *b = 0;
}

// Mode 16 (K10c): deadline-carrying wakeups (ext 5) and frame-aligned
// periods (ext 10).
static int64_t deadline_profile(uint32_t resource, int64_t capacity, int64_t deadline, int64_t period,
                                uint32_t *out) {
  croi_profile_info_t info;
  zero_bytes(&info, sizeof info);
  info.flags = CROI_PROFILE_INFO_FLAG_DEADLINE;
  info.deadline_params.capacity = capacity;
  info.deadline_params.relative_deadline = deadline;
  info.deadline_params.period = period;
  return sys(CROI_SYS_PROFILE_CREATE, resource, 0, (uint64_t)&info, (uint64_t)out, 0);
}

typedef struct {
  uint32_t handle;
  volatile int64_t status;
  volatile int64_t deadline_on_wake, period_start, deadline_after_block;
} lent_waiter_t;

static void lent_waiter(uint64_t arg) {
  lent_waiter_t *w = (lent_waiter_t *)arg;
  w->deadline_on_wake = sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0);  // fair before
  w->status = sys(CROI_SYS_COUNTER_WAIT, w->handle, 1, ~0ull, 0, 0);
  w->deadline_on_wake += 2 * sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0);  // 2: deadline now, fair before
  w->period_start = sys(CROI_SYS_TEST_PROFILE, 3, 0, 0, 0, 0);
  sleep_ns(1000000);
  w->deadline_after_block = sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

typedef struct {
  volatile uint32_t go;
  volatile uint32_t done;
  volatile int64_t starts[4];
} aligned_worker_t;

static void aligned_worker(uint64_t arg) {
  aligned_worker_t *w = (aligned_worker_t *)arg;
  while (!w->go) sys(CROI_SYS_NANOSLEEP, 0, 0, 0, 0, 0);
  for (int i = 0; i < 4; i++) {
    w->starts[i] = sys(CROI_SYS_TEST_PROFILE, 3, 0, 0, 0, 0);
    sleep_ns(3100000);  // wake into a new period
  }
  w->done = 1;
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t deadline_wakeups(const startup_t *s) {
  uint32_t deadline = 0, fair = 0, counter = 0, weak = 0, t = 0, page_vmo = 0;
  croi_profile_info_t info;
  zero_bytes(&info, sizeof info);
  info.flags = CROI_PROFILE_INFO_FLAG_PRIORITY;
  info.priority = 20;
  CHECK(380, deadline_profile(s->resource, 1000000, 4000000, 4000000, &deadline) == 0 &&
                 sys(CROI_SYS_PROFILE_CREATE, s->resource, 0, (uint64_t)&info, (uint64_t)&fair, 0) == 0 &&
                 sys(CROI_SYS_COUNTER_CREATE, 0, (uint64_t)&counter, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, counter, 1u << 2 | 1u << 14, (uint64_t)&weak, 0, 0) == 0);
  // An event lends only a deadline, needs WRITE, and takes no options.
  CHECK(381, sys(CROI_SYS_OBJECT_SET_PROFILE, counter, fair, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, weak, deadline, 0, 0, 0) == ERR_ACCESS_DENIED_ &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, counter, deadline, CROI_PROFILE_ALIGN_TIMELINE, 0, 0) ==
                     ERR_INVALID_ARGS &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, counter, deadline, 0, 0, 0) == 0);
  // A fair thread woken by the counter runs on its deadline, from the
  // wakeup, until it blocks again.
  lent_waiter_t w = {.handle = counter, .status = 1};
  uint32_t worker = start_thread(s, lent_waiter, (uint64_t)&w);
  sleep_ns(10000000);
  uint64_t added = now_ns();
  CHECK(382, w.status == 1 && sys(CROI_SYS_COUNTER_ADD, counter, 1, 0, 0, 0) == 0);
  join_checked(worker);
  CHECK(383, w.status == 0 && w.deadline_on_wake == 2 && (uint64_t)w.period_start >= added &&
                 (uint64_t)w.period_start < now_ns());
  CHECK(384, w.deadline_after_block == 0);
  // Frame alignment: a deadline thread's periods start on vblanks.
  CHECK(385, sys(CROI_SYS_TIMELINE_CREATE, s->resource, CROI_TIMELINE_SYNTHETIC, 2000000, (uint64_t)&t, 0) == 0 &&
                 sys(CROI_SYS_TIMELINE_GET_PAGE, t, (uint64_t)&page_vmo, 0, 0, 0) == 0);
  uint64_t at = 0;
  CHECK(386, sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, page_vmo, 0, PAGE,
                  (uint64_t)&at) == 0);
  volatile const croi_timeline_page_t *page = (volatile const croi_timeline_page_t *)at;
  aligned_worker_t a;
  zero_bytes(&a, sizeof a);
  worker = start_thread(s, aligned_worker, (uint64_t)&a);
  uint32_t refusal = 99;
  // Without a deadline profile there is nothing to align.
  CHECK(387, sys(CROI_SYS_OBJECT_SET_PROFILE, worker, fair, CROI_PROFILE_ALIGN_TIMELINE, (uint64_t)&refusal, t) ==
                 ERR_BAD_STATE &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, worker, deadline, CROI_PROFILE_ALIGN_TIMELINE, (uint64_t)&refusal,
                     t) == 0 &&
                 refusal == CROI_ADMISSION_ACCEPTED);
  a.go = 1;
  join_checked(worker);
  for (int i = 0; i < 4; i++) {
    uint64_t start = (uint64_t)a.starts[i];
    CHECK(388, a.done && start >= page->base_time_ns && (start - page->base_time_ns) % page->period_ns == 0);
  }
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, PAGE, 0, 0);
  uint32_t handles[] = {deadline, fair, counter, weak, t, page_vmo};
  for (int i = 0; i < 6; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0x600D;
}

// Mode 17 (K10d): kernel-only extensions reaching user space.
typedef struct {
  volatile uint64_t until;
  volatile uint64_t seen;  // CPUs it ran on
  volatile uint32_t stop;
} spinner_t;

static void spinner(uint64_t arg) {
  spinner_t *p = (spinner_t *)arg;
  while (!p->stop && now_ns() < p->until) p->seen |= 1ull << sys(CROI_SYS_TEST_PROFILE, 5, 0, 0, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t extensions(const startup_t *s) {
  // A thread's trace id: task << 12 | index, distinct per thread.
  // They spin until told to stop (5 s at most): on a slow emulator a fixed
  // 20 ms ran out before the deadline profile below could overrun.
  spinner_t one = {.until = now_ns() + 5000000000ull}, two = {.until = now_ns() + 5000000000ull};
  uint32_t a = start_thread(s, spinner, (uint64_t)&one), b = start_thread(s, spinner, (uint64_t)&two);
  croi_info_thread_trace_t ta, tb;
  CHECK(390, info(a, CROI_INFO_THREAD_TRACE, &ta, sizeof ta) == 0 && info(b, CROI_INFO_THREAD_TRACE, &tb, sizeof tb) == 0 &&
                 ta.trace_id != tb.trace_id && (ta.trace_id >> 12) == (tb.trace_id >> 12) && (ta.trace_id & 0xFFF) != 0 &&
                 info(s->process, CROI_INFO_THREAD_TRACE, &ta, sizeof ta) == ERR_WRONG_TYPE);
  // Overruns to a port: a deadline thread spinning past its budget.
  uint32_t port = 0, deadline = 0, refusal = 0;
  croi_profile_info_t profile;
  zero_bytes(&profile, sizeof profile);
  profile.flags = CROI_PROFILE_INFO_FLAG_DEADLINE;
  profile.deadline_params.capacity = 1000000;
  profile.deadline_params.relative_deadline = 5000000;
  profile.deadline_params.period = 5000000;
  CHECK(391, sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_THREAD_BIND_OVERRUN_PORT, a, port, 7, 0, 0) == ERR_BAD_STATE &&  // no profile yet
                 sys(CROI_SYS_PROFILE_CREATE, s->resource, 0, (uint64_t)&profile, (uint64_t)&deadline, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, a, deadline, 0, (uint64_t)&refusal, 0) == 0 &&
                 sys(CROI_SYS_THREAD_BIND_OVERRUN_PORT, a, port, 7, 0, 0) == 0);
  croi_port_packet_t p;
  CHECK(392, port_next(port, 100000000, &p) == 0 && p.type == CROI_PKT_TYPE_BUDGET_OVERRUN && p.key == 7 &&
                 p.payload[1] >= 1 && p.payload[2] >= 1);
  one.stop = two.stop = 1;
  join_checked(a);
  join_checked(b);
  // The debuglog's dumper catches up with what was written.
  uint32_t log = 0;
  croi_info_debuglog_t d;
  CHECK(393, sys(CROI_SYS_DEBUGLOG_CREATE, 0, 0, (uint64_t)&log, 0, 0) == 0 &&
                 sys(CROI_SYS_DEBUGLOG_WRITE, log, 0, (uint64_t)"k10d: paced", 11, 0) == 0 &&
                 info(log, CROI_INFO_DEBUGLOG, &d, sizeof d) == 0 && d.written >= 1 && d.printed <= d.written);
  uint64_t target = d.written, give_up = now_ns() + 2000000000;
  while (now_ns() < give_up && info(log, CROI_INFO_DEBUGLOG, &d, sizeof d) == 0 && d.printed < target) sleep_ns(1000000);
  CHECK(394, d.printed >= target);
  // CPU 3 reserved for a job: its process runs there only, nobody else does.
  uint32_t job = 0, other = 0, tracing = 0;
  CHECK(395, sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&job, 0, 0) == 0 &&
                 sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&other, 0, 0) == 0 &&
                 resource_create(s->resource, CROI_RSRC_KIND_SYSTEM, CROI_RSRC_SYSTEM_TRACING_BASE, 1, &tracing) == 0 &&
                 sys(CROI_SYS_JOB_SET_CPU_RESERVATION, job, tracing, 1u << 3, 0, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_JOB_SET_CPU_RESERVATION, job, s->resource, 1u << 0 | 1u << 3, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_JOB_SET_CPU_RESERVATION, job, s->resource, 1u << 3, 0, 0) == 0 &&
                 sys(CROI_SYS_JOB_SET_CPU_RESERVATION, other, s->resource, 1u << 3, 0, 0) == ERR_ALREADY_BOUND);
  spinner_t loads[3];
  uint32_t workers[3];
  for (int i = 0; i < 3; i++) {
    loads[i].until = now_ns() + 30000000;
    loads[i].seen = 0;
    loads[i].stop = 0;
    workers[i] = start_thread(s, spinner, (uint64_t)&loads[i]);
  }
  uint32_t process = spawn_child(s, job, 9);
  CHECK(396, (wait_terminated(process) & CROI_SIGNAL_TASK_TERMINATED) && return_code(process) == 1 << 3);
  for (int i = 0; i < 3; i++) {
    join_checked(workers[i]);
    CHECK(397, loads[i].seen != 0 && !(loads[i].seen & 1 << 3));
  }
  // A job with children can't change it; its end releases the CPU.
  CHECK(398, sys(CROI_SYS_JOB_SET_CPU_RESERVATION, job, s->resource, 0, 0, 0) == ERR_BAD_STATE);
  sys(CROI_SYS_HANDLE_CLOSE, process, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, job, 0, 0, 0, 0);
  int64_t taken = -1;
  for (uint64_t until = now_ns() + 2000000000; now_ns() < until; sleep_ns(1000000)) {
    taken = sys(CROI_SYS_JOB_SET_CPU_RESERVATION, other, s->resource, 1u << 3, 0, 0);
    if (taken != ERR_ALREADY_BOUND) break;
  }
  CHECK(399, taken == 0 && sys(CROI_SYS_JOB_SET_CPU_RESERVATION, other, s->resource, 0, 0, 0) == 0);
  uint32_t handles[] = {port, deadline, log, other, tracing};
  for (int i = 0; i < 5; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
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
            : mode == 10 ? drivers((const startup_t *)handle)
            : mode == 11 ? interrupts((const startup_t *)handle)
            : mode == 12 ? dma((const startup_t *)handle)
            : mode == 13 ? memory_stats((const startup_t *)handle)
            : mode == 14 ? counters((const startup_t *)handle)
            : mode == 15 ? timelines((const startup_t *)handle)
            : mode == 16 ? deadline_wakeups((const startup_t *)handle)
            : mode == 17 ? extensions((const startup_t *)handle)
            : mode >= 0x400 ? child((uint32_t)mode, handle, vdso_base)
                        : objects());
}
