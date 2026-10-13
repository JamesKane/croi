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
  uint64_t iommu_base;          // amd64: the first IOMMU's registers (DMAR or IVRS), or 0
  uint32_t iommu_type, padding3;  // its iommu_create type
  uint64_t ecam;                  // segment 0's ECAM (the MCFG's first window), or 0
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

// Submode 10's threads: each waits in its own way until killed.
static void port_blocker(uint64_t port) {
  croi_port_packet_t packet;
  sys(CROI_SYS_PORT_WAIT, port, ~0ull, (uint64_t)&packet, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 1, 0, 0, 0, 0);
}
static void counter_blocker(uint64_t counter) {
  sys(CROI_SYS_COUNTER_WAIT, counter, 1000, ~0ull, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 1, 0, 0, 0, 0);
}
static void user_spinner(uint64_t arg) {
  (void)arg;
  for (;;) {
  }
}
// Retries a call that fails at once, as a client loop does: its way back
// to user mode must notice the kill (amd64's SYSCALL path once didn't).
static void syscall_spinner(uint64_t arg) {
  (void)arg;
  for (;;) sys(CROI_SYS_HANDLE_CLOSE, 0x12340003, 0, 0, 0, 0);
}

static int64_t child_thread(uint32_t self, void (*entry)(uint64_t), uint64_t arg) {
  uint32_t thread = 0, stack = 0;
  uint64_t at = 0;
  if (sys(CROI_SYS_VMO_CREATE, STACK_SIZE, 0, (uint64_t)&stack, 0, 0) != 0) return 91;
  if (sys(CROI_SYS_VMO_MAP, stack, 0, STACK_SIZE, 3, (uint64_t)&at) != 0) return 92;
  if (sys6(CROI_SYS_THREAD_CREATE, self, (uint64_t)"w", 1, 0, (uint64_t)&thread, 0) != 0) return 93;
  if (sys(CROI_SYS_THREAD_START, thread, (uint64_t)entry, ENTRY_SP(at + STACK_SIZE), arg, 0) != 0) return 94;
  return 0;
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
  case 10: {  // Todhchai's compositor, roughly: threads waiting on a port,
              // a counter and a channel, one spinning; then killed
    uint32_t port = 0, counter = 0, a = 0, b = 0, event = 0;
    if (sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) != 0 ||
        sys(CROI_SYS_COUNTER_CREATE, 0, (uint64_t)&counter, 0, 0, 0) != 0 ||
        sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&a, (uint64_t)&b, 0, 0) != 0 ||
        sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&event, 0, 0, 0) != 0)
      return 90;
    int64_t failed = child_thread(self, port_blocker, port) | child_thread(self, counter_blocker, counter) |
                     child_thread(self, blocker, event) | child_thread(self, user_spinner, 0) |
                     child_thread(self, syscall_spinner, 0);
    if (failed) return failed;
    uint32_t observed = 0;
    sys(CROI_SYS_OBJECT_WAIT_ONE, a, CROI_SIGNAL_READABLE, ~0ull, (uint64_t)&observed, 0);  // until killed
    return 89;
  }
  case 11: {  // K14s: exit with this process's PAC signature of a fixed value
#if defined(__aarch64__)
    register uint64_t x17 __asm__("x17") = 0x0000000001234560ull;
    register uint64_t x16 __asm__("x16") = 7;
    __asm__ volatile("hint #8" : "+r"(x17) : "r"(x16));  // pacia1716
    return sys(CROI_SYS_PROCESS_EXIT, (int64_t)x17, 0, 0, 0, 0);
#else
    return sys(CROI_SYS_PROCESS_EXIT, 0x0000000001234560ll, 0, 0, 0, 0);
#endif
  }
  case 12: {  // K15a: commits a 2-page VMO (charging its account), then waits to be killed
    uint32_t vmo = 0, event = 0, observed = 0;
    if (sys(CROI_SYS_VMO_CREATE, 2 * 4096, 0, (uint64_t)&vmo, 0, 0) != 0 ||
        croi_syscall6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_COMMIT, 0, 2 * 4096, 0, 0) != 0 ||
        sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&event, 0, 0, 0) != 0)
      return 90;
    sys(CROI_SYS_OBJECT_WAIT_ONE, event, SIGNALED, ~0ull, (uint64_t)&observed, 0);
    return 89;
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
  slot[3] = 1;  // about to wait
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
  volatile uint64_t w1[4] = {a, 99, 0, 0}, w2[4] = {a, 99, 0, 0};
  uint32_t t1 = start_thread(s, futex_waiter, (uint64_t)w1), t2 = start_thread(s, futex_waiter, (uint64_t)w2);
  // Both about to wait, then time to block (a fixed 5 ms wasn't, for a
  // thread a loaded host started late).
  for (uint64_t until = now_ns() + 2000000000ull; !(w1[3] && w2[3]) && now_ns() < until;)
    sys(CROI_SYS_NANOSLEEP, now_ns() + 1000000, 0, 0, 0, 0);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 20000000, 0, 0, 0, 0);
  CHECK(160, sys6(CROI_SYS_FUTEX_REQUEUE, a, 0, 0, b, 2, 0) == 0);
  CHECK(161, sys(CROI_SYS_FUTEX_WAKE, a, 10, 0, 0, 0) == 0 && w1[2] == 0 && w2[2] == 0);  // nobody left on a
  CHECK(162, sys(CROI_SYS_FUTEX_WAKE, b, 2, 0, 0, 0) == 0);
  join(t1);
  join(t2);
  CHECK(163, w1[2] == 1 && w2[2] == 1 && w1[1] == 0 && w2[1] == 0);

  // wake_single_owner: one waiter wakes and owns the futex.
  volatile uint64_t w3[4] = {c, 99, 0, 0}, w4[4] = {c, 99, 0, 0};
  uint32_t t3 = start_thread(s, futex_waiter, (uint64_t)w3), t4 = start_thread(s, futex_waiter, (uint64_t)w4);
  for (uint64_t until = now_ns() + 2000000000ull; !(w3[3] && w4[3]) && now_ns() < until;)
    sys(CROI_SYS_NANOSLEEP, now_ns() + 1000000, 0, 0, 0, 0);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 20000000, 0, 0, 0, 0);
  CHECK(164, sys(CROI_SYS_FUTEX_WAKE_SINGLE_OWNER, c, 0, 0, 0, 0) == 0);
  // The woken one runs when it runs; then a moment for a wrong second.
  for (uint64_t until = now_ns() + 2000000000ull; !(w3[2] || w4[2]) && now_ns() < until;)
    sys(CROI_SYS_NANOSLEEP, now_ns() + 1000000, 0, 0, 0, 0);
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
#define ERR_UNAVAILABLE (-28)
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
#define ECAM 0xE0000000ull  // q35's (amd64's MSI test)
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

#if defined(__x86_64__) || defined(__aarch64__) || defined(__riscv)
// K12f: with interrupt remapping (VT-d) a message is in the remappable
// format (bit 4, SHV bit 3, data 0) and names an entry (the handle, in
// address bits 19:5 and 2) the kernel wrote; old-style messages are
// blocked.
static int remapped(uint64_t address) { return (address & 0x10) != 0; }
// K12g: with AMD-Vi remapping the address is the plain one and the data an
// index the kernel allocated (0x100 up; vectors are 0xB0-0xEF).
static int amd_remapped(uint32_t data) { return data >= 0x100; }
static uint32_t handle_of(uint32_t address) { return ((address >> 5) & 0x7FFF) | ((address >> 2) & 1) << 15; }

// K12h: on arm64 the message is the GICv3 ITS's doorbell and an EventID
// (the LPI less 8192); a move keeps it (MOVI); an event not mapped for a
// device goes nowhere.
#if defined(__aarch64__)
static const int its = 1;
#else
static const int its = 0;
#endif
// K12i: on rv64 the message is a hart's IMSIC file and an identity; a move
// changes the address (another hart's file), the data stays. No remapping
// without the RISC-V IOMMU's MSI page tables, so nothing to refuse (297).
#if defined(__riscv)
static const int imsic = 1;
#else
static const int imsic = 0;
#endif

static int64_t msi_test(const startup_t *s, uint32_t port) {
  if (imsic) {
    // rv64 without AIA (the PLIC): no MSIs at all.
    uint32_t probe = 0;
    int64_t status = sys(CROI_SYS_MSI_ALLOCATE, s->resource, 1, (uint64_t)&probe, 0, 0);
    if (status == ERR_NOT_SUPPORTED) return 0x600D;
    CHECK(281, status == 0);
    sys(CROI_SYS_HANDLE_CLOSE, probe, 0, 0, 0, 0);
  }
  volatile uint8_t *bus = 0;
  uint32_t bus_vmo = physical_vmo(s, s->ecam ? s->ecam : ECAM, 32 * 0x8000, &bus);  // bus 0, devices 0-31, function 0

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
                 (imsic ? info.target_addr != 0 && info.target_data == info.base_irq_id
                  : its ? info.target_addr != 0 && info.base_irq_id >= 8192 && info.target_data == info.base_irq_id - 8192
                  : remapped(info.target_addr)
                      ? (info.target_addr & ~0xFFFFFull) == 0xFEE00000 && (info.target_addr & 8) && info.target_data == 0
                  : amd_remapped(info.target_data)
                      ? info.target_addr == 0xFEE00000 && info.target_data < 0x800
                      : (info.target_addr & ~0xFF000ull) == 0xFEE00000 && info.target_data == info.base_irq_id) &&
                 (its || imsic || (info.base_irq_id >= 0xB0 && info.base_irq_id < 0xF0)) && info.num_irq == 1 &&
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
  // VT-d isn't checked: QEMU's model passes compatibility-format MSIs
  // through whatever CFI says (hardware with CFIS clear, as croi leaves
  // it, blocks them).
  if (its || amd_remapped(info.target_data)) {
    // An old-style message for the same vector is blocked: nothing arrives
    // (AMD-Vi: index 0xB0 up to 0xFF is no entry). arm64: an event not
    // mapped for edu, at the ITS's doorbell.
    cfg32_write(edu, cap + 4, its ? (uint32_t)info.target_addr : 0xFEE00000);
    *(volatile uint16_t *)(edu + cap + ((control & (1u << 7)) ? 0xC : 8)) =
        (uint16_t)(its ? info.target_data + 64 : info.base_irq_id);
    // Bound and acknowledged (an MSI stays masked until then, after the
    // wait above), so a delivery would arrive.
    CHECK(297, sys(CROI_SYS_INTERRUPT_BIND, intr, port, 78, CROI_INTERRUPT_BIND, 0) == 0 &&
                   sys(CROI_SYS_INTERRUPT_ACK, intr, 0, 0, 0, 0) == 0);
    edu_regs[0x60 / 4] = 4;
    CHECK(297, port_next(port, 20000000, &p) == ERR_TIMED_OUT);
    edu_regs[0x64 / 4] = 4;
    sys(CROI_SYS_INTERRUPT_BIND, intr, port, 0, CROI_INTERRUPT_UNBIND, 0);
  }
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
  // Remapped: one entry per vector (consecutive handles, data 0), the
  // move to CPU 1 a handle in its range (entries 128 + cpu * 64 + vector).
  int r = !its && !imsic && remapped(info.target_addr), amd = !its && !imsic && amd_remapped(info.target_data);
  CHECK(294, e[0] == (uint32_t)info.target_addr && e[1] == 0 && e[2] == info.target_data && (e[3] & 1) == 0 &&
                 (r ? handle_of(e[4]) == handle_of(e[0]) + 1 && e[6] == 0
                    : e[4] == (uint32_t)info.target_addr && e[6] == info.target_data + 1) && (e[7] & 1) == 0);
  CHECK(295, sys(CROI_SYS_INTERRUPT_SET_AFFINITY, x1, 1u << 1, 0, 0, 0) == 0 &&
                 (imsic ? e[4] != (uint32_t)info.target_addr && e[4] != 0 && e[6] == info.target_data + 1
                  : its   ? e[4] == (uint32_t)info.target_addr && e[6] == info.target_data + 1
                  : r     ? (handle_of(e[4]) - 128) / 64 == 1 && e[6] == 0
                  : amd ? e[4] == 0xFEE00000 && e[6] >= 0x100 && e[6] < 0x800 && e[6] != info.target_data + 1
                        : ((e[4] >> 12) & 0xFF) == 1 && e[6] >= 0xB0 && e[6] < 0xF0) &&
                 (e[7] & 1) == 0 && e[0] == (uint32_t)info.target_addr);
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
#if defined(__x86_64__)
                     ERR_INVALID_ARGS &&  // shorter than zx_iommu_desc_intel_t
#else
                     ERR_NOT_SUPPORTED &&
#endif
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

#if defined(__x86_64__) || defined(__aarch64__) || defined(__riscv)
// Mode 18, K12: VT-d with QEMU's intel-iommu (its DMAR covers the whole
// segment), AMD-Vi with its amd-iommu (the unit covers its segment) or
// arm64's SMMUv3 (Zircon's ARM_SMMU descriptor, requester ids through the
// IORT) or rv64's RISC-V IOMMU (its base, requester ids through the
// RIMT), whichever the kernel found (it passes the unit's registers and
// type in the startup block, where a driver would read the DMAR or IVRS),
// and edu's DMA engine (00:10.0, a 28-bit DMA mask). Through a pinned page and back; then to a read-only
// IOVA and to an unpinned one, which the IOMMU refuses (the kernel checks
// it counted the faults). 0x600E: no IOMMU or no edu, skipped.
static int edu_dma(volatile uint8_t *regs, uint64_t src, uint64_t dst, uint32_t to_ram) {
  *(volatile uint64_t *)(regs + 0x80) = src;
  *(volatile uint64_t *)(regs + 0x88) = dst;
  *(volatile uint64_t *)(regs + 0x90) = 64;
  *(volatile uint64_t *)(regs + 0x98) = 1 | to_ram << 1;  // start; direction (1: edu to RAM)
  uint64_t give_up = now_ns() + 2000000000ull;            // edu starts it 100 ms later
  while (*(volatile uint64_t *)(regs + 0x98) & 1) {
    if (now_ns() > give_up) return 0;
    sys(CROI_SYS_NANOSLEEP, now_ns() + 5000000, 0, 0, 0, 0);
  }
  return 1;
}

static int64_t iommu_test(const startup_t *s) {
  if (s->iommu_base == 0 || s->ecam == 0) return 0x600E;
  volatile uint8_t *bus = 0;
  uint32_t bus_vmo = physical_vmo(s, s->ecam, 32 * 0x8000, &bus);
  uint32_t cap = 0;
  uint32_t edu_at = find_device(bus, ~0u, 0x11e81234, 0x05, &cap);
  if (edu_at == 0) {
    sys(CROI_SYS_HANDLE_CLOSE, bus_vmo, 0, 0, 0, 0);
    return 0x600E;
  }
  uint64_t bdf = edu_at >> 15 << 3;  // bus 0, function 0
  volatile uint8_t *edu = bus + edu_at;

  // The unit: its registers must be the firmware's; one object at a time.
  // The x86 descriptors are 16 bytes with the register base first; the
  // SMMU's is the base alone.
  croi_iommu_desc_intel_t intel = {.register_base = s->iommu_base, .pci_segment = 0, .whole_segment = true};
  croi_iommu_desc_amd_t amd = {.register_base = s->iommu_base, .pci_segment = 0};
  void *desc_bytes = s->iommu_type == CROI_IOMMU_TYPE_AMD ? (void *)&amd : (void *)&intel;
  uint32_t type = s->iommu_type;
  uint64_t desc[2];
  __builtin_memcpy(desc, desc_bytes, sizeof desc);
  uint64_t desc_size = type == CROI_IOMMU_TYPE_ARM_SMMU || type == CROI_IOMMU_TYPE_RISCV ? 8 : sizeof desc;
  uint64_t elsewhere[2] = {desc[0] + 0x100000, desc[1]};
  uint32_t iommu = 0, again = 0, bti = 0, bti2 = 0;
  CHECK(400, sys(CROI_SYS_IOMMU_CREATE, s->resource, type, (uint64_t)&elsewhere, desc_size,
                 (uint64_t)&iommu) == ERR_NOT_FOUND &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, type, (uint64_t)&desc, desc_size + 8,
                     (uint64_t)&iommu) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, type, (uint64_t)&desc, desc_size,
                     (uint64_t)&iommu) == 0 &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, type, (uint64_t)&desc, desc_size,
                     (uint64_t)&again) == ERR_ALREADY_BOUND);
  // A device per BTI; no trust-decision record (it is translated).
  CHECK(401, sys(CROI_SYS_BTI_CREATE, iommu, 0, 0x10000, (uint64_t)&bti, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_BTI_CREATE, iommu, 0, bdf, (uint64_t)&bti, 0) == 0 &&
                 sys(CROI_SYS_BTI_CREATE, iommu, 0, bdf, (uint64_t)&bti2, 0) == ERR_ALREADY_BOUND &&
                 !log_has(s, "no-IOMMU BTI 0x80"));
  croi_bti_properties_t p = {};
  CHECK(402, sys(CROI_SYS_OBJECT_GET_INFO, bti, CROI_INFO_BTI_PROPERTIES, (uint64_t)&p, sizeof p, 0) == 0 &&
                 (p.address_bits == 39 || p.address_bits == 48));
  croi_bti_properties_t narrow = {.address_bits = 28, .memory_type = CROI_BTI_MEMORY_COHERENT};
  CHECK(403, sys(CROI_SYS_BTI_SET_PROPERTIES, bti, (uint64_t)&narrow, 0, 0, 0) == 0 &&
                 bti_info(bti).aspace_size == 1ull << 28);

  // Three pages: a source and a destination pinned read/write, a third
  // read only. I/O addresses come from the 28-bit window.
  uint32_t vmo = 0, pmt = 0, pmt_ro = 0;
  uint64_t addrs[2] = {0, 0}, ro = 0;
  CHECK(404, sys(CROI_SYS_VMO_CREATE, 3 * PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 bti_pin(bti, CROI_BTI_PERM_READ | CROI_BTI_PERM_WRITE, vmo, 2, 0, 2 * PAGE, addrs, &pmt) == 0 &&
                 bti_pin(bti, CROI_BTI_PERM_READ, vmo, 1, 2 * PAGE, PAGE, &ro, &pmt_ro) == 0 &&
                 addrs[0] % PAGE == 0 && addrs[1] == addrs[0] + PAGE && addrs[0] >= 0x100000 &&
                 ro + PAGE <= 1ull << 28 && addrs[1] + PAGE <= 1ull << 28 && bti_info(bti).pmo_count == 2);
  uint8_t pattern[64], back[64];
  for (int i = 0; i < 64; i++) pattern[i] = (uint8_t)(0xA0 + i);
  volatile uint8_t *regs = 0;
  uint32_t regs_vmo = physical_vmo(s, bar(edu, 0), PAGE, &regs);
  uint32_t command = cfg32(edu, 4) & 0xFFFF;
  cfg32_write(edu, 4, command | 1u << 1 | 1u << 2);  // memory, bus master
  CHECK(405, sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)pattern, 0, 64, 0) == 0 &&
                 edu_dma(regs, addrs[0], 0x40000, 0) && edu_dma(regs, 0x40000, addrs[1], 1) &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)back, PAGE, 64, 0) == 0 && back[0] == 0xA0 && back[63] == 0xDF);
  // Refused: a write to the read-only page, and to the unpinned pages.
  CHECK(406, edu_dma(regs, 0x40000, ro, 1) && sys(CROI_SYS_VMO_READ, vmo, (uint64_t)back, 2 * PAGE, 64, 0) == 0 &&
                 back[0] == 0 && back[63] == 0);
  uint64_t zero[8] = {0};
  CHECK(407, sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)zero, PAGE, 64, 0) == 0 &&
                 edu_dma(regs, 0x40000, addrs[1], 1) &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)back, PAGE, 64, 0) == 0 && back[0] == 0 && back[63] == 0);
  // K12j: the claimed device's MSIs still arrive. VT-d and AMD-Vi don't
  // translate interrupt requests; an SMMUv3 domain maps the ITS doorbell;
  // a RISC-V IOMMU context routes MSIs through its MSI page table (or maps
  // the IMSIC files). Where there are no MSIs (rv64's PLIC), skipped.
  uint32_t msi = 0;
  if (sys(CROI_SYS_MSI_ALLOCATE, s->resource, 1, (uint64_t)&msi, 0, 0) == 0) {
    croi_info_msi_t info = {0};
    croi_port_packet_t p;
    uint32_t intr = 0, mport = 0;
    uint16_t control = *(volatile uint16_t *)(edu + cap + 2);
    CHECK(409, sys(CROI_SYS_OBJECT_GET_INFO, msi, CROI_INFO_MSI, (uint64_t)&info, sizeof info, 0) == 0 &&
                   sys6(CROI_SYS_MSI_CREATE, msi, 0, 0, bus_vmo, edu_at + cap, (uint64_t)&intr) == 0 &&
                   sys(CROI_SYS_PORT_CREATE, CROI_PORT_BIND_TO_INTERRUPT, (uint64_t)&mport, 0, 0, 0) == 0 &&
                   sys(CROI_SYS_INTERRUPT_BIND, intr, mport, 79, CROI_INTERRUPT_BIND, 0) == 0);
    cfg32_write(edu, cap + 4, (uint32_t)info.target_addr);
    if (control & (1u << 7)) {
      cfg32_write(edu, cap + 8, (uint32_t)(info.target_addr >> 32));
      *(volatile uint16_t *)(edu + cap + 0xC) = (uint16_t)info.target_data;
    } else {
      *(volatile uint16_t *)(edu + cap + 8) = (uint16_t)info.target_data;
    }
    *(volatile uint16_t *)(edu + cap + 2) = (uint16_t)((control & ~(7u << 4)) | 1);  // one message, enabled
    cfg32_write(edu, 4, command | 1u << 1 | 1u << 2 | 1u << 10);                   // no INTx
    *(volatile uint32_t *)(regs + 0x60) = 8;
    CHECK(410, port_next(mport, 1000000000, &p) == 0 && p.type == CROI_PKT_TYPE_INTERRUPT && p.key == 79);
    *(volatile uint32_t *)(regs + 0x64) = 8;
    *(volatile uint16_t *)(edu + cap + 2) = control;
    sys(CROI_SYS_INTERRUPT_DESTROY, intr, 0, 0, 0, 0);
    sys(CROI_SYS_HANDLE_CLOSE, intr, 0, 0, 0, 0);
    sys(CROI_SYS_HANDLE_CLOSE, mport, 0, 0, 0, 0);
    sys(CROI_SYS_HANDLE_CLOSE, msi, 0, 0, 0, 0);
  }
  cfg32_write(edu, 4, command);
  sys(CROI_SYS_HANDLE_CLOSE, regs_vmo, 0, 0, 0, 0);

  // Quarantined, then the BTI goes: the device is blocked, so the pages
  // come back; the device can be claimed again, and the unit bound again.
  CHECK(408, sys(CROI_SYS_HANDLE_CLOSE, pmt_ro, 0, 0, 0, 0) == 0 && bti_info(bti).quarantine_count == 1 &&
                 sys(CROI_SYS_HANDLE_CLOSE, bti, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, 0, 3 * PAGE, 0) == 0 &&
                 sys(CROI_SYS_BTI_CREATE, iommu, 0, bdf, (uint64_t)&bti, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, bti, 0, 0, 0, 0) == 0 && sys(CROI_SYS_HANDLE_CLOSE, iommu, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, type, (uint64_t)&desc, desc_size,
                     (uint64_t)&iommu) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, iommu, 0, 0, 0, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, bus_vmo, 0, 0, 0, 0);
  return 0x600D;
}
#endif

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

// K14e (ext 5): an interrupt that hands its waiter an admitted context.
typedef struct {
  uint32_t interrupt;
  volatile uint32_t round;     // rounds done
  volatile uint32_t spinning;  // in round 3, waiting to be withdrawn
  volatile uint32_t release;
  volatile int64_t deadline[4], borrowed[4], cpu[4], start[4];
  volatile int64_t fell_back;  // round 1: ns until the spent budget sent it back to its own, or -1
  volatile int64_t withdrawn;  // round 3: back on its own while running, once the context was replaced
} handoff_waiter_t;

static void handoff_waiter(uint64_t arg) {
  handoff_waiter_t *w = (handoff_waiter_t *)arg;
  for (uint32_t i = 0; i < 4; i++) {
    sys(CROI_SYS_INTERRUPT_WAIT, w->interrupt, 0, 0, 0, 0);
    w->deadline[i] = sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0);
    w->borrowed[i] = sys(CROI_SYS_TEST_PROFILE, 10, 0, 0, 0, 0);
    w->cpu[i] = sys(CROI_SYS_TEST_PROFILE, 5, 0, 0, 0, 0);
    w->start[i] = sys(CROI_SYS_TEST_PROFILE, 3, 0, 0, 0, 0);
    uint64_t t0 = now_ns();
    if (i == 0) {
      while (now_ns() - t0 < 500000) {}  // some of the budget
    } else if (i == 1) {
      w->fell_back = -1;  // the rest, and past it
      while (now_ns() - t0 < 2000000000ull) {
        if (sys(CROI_SYS_TEST_PROFILE, 10, 0, 0, 0, 0) == -1) {
          w->fell_back = (int64_t)(now_ns() - t0);
          break;
        }
      }
    } else if (i == 3) {
      w->spinning = 1;
      while (!w->release && now_ns() - t0 < 5000000000ull) {}
      w->withdrawn = sys(CROI_SYS_TEST_PROFILE, 10, 0, 0, 0, 0) == -1 && sys(CROI_SYS_TEST_PROFILE, 0, 0, 0, 0, 0) == 0;
    }
    w->round = i + 1;
  }
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// Waits until `thread` is blocked in interrupt_wait (a trigger before
// that is consumed by the wait without a wakeup to hand anything on).
static int blocked_on_interrupt(uint32_t thread) {
  uint64_t give_up = now_ns() + 2000000000ull, counts[2];
  croi_info_thread_t info;
  while (now_ns() < give_up) {
    if (sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD, (uint64_t)&info, sizeof info, (uint64_t)&counts[0],
             (uint64_t)&counts[1]) == 0 && info.state == CROI_THREAD_STATE_BLOCKED_INTERRUPT)
      return 1;
    sleep_ns(200000);
  }
  return 0;
}

static int round_done(volatile uint32_t *round, uint32_t want) {
  uint64_t give_up = now_ns() + 5000000000ull;
  while (*round < want && now_ns() < give_up) sleep_ns(200000);
  return *round >= want;
}

static int64_t interrupt_handoff(const startup_t *s, uint32_t counter, uint32_t fair, uint32_t lend) {
  uint32_t v = 0, handoff = 0, huge = 0, port = 0, refusal = 99;
  // 2 ms of budget every 2 s: the CBS rule keeps one period across
  // wakeups that come within half a second.
  CHECK(628, deadline_profile(s->resource, 2000000, 2000000000, 2000000000, &handoff) == 0 &&
                 deadline_profile(s->resource, 10000000, 10000000, 10000000, &huge) == 0 &&
                 sys(CROI_SYS_INTERRUPT_CREATE, 0, 0, CROI_INTERRUPT_VIRTUAL, (uint64_t)&v, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0);
  // Interrupts only, deadline profiles only, admitted (refused with a
  // reason); its overruns go to a port.
  CHECK(629, sys(CROI_SYS_OBJECT_SET_PROFILE, counter, handoff, CROI_PROFILE_HANDOFF, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, v, fair, CROI_PROFILE_HANDOFF, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_THREAD_BIND_OVERRUN_PORT, v, port, 7, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, v, huge, CROI_PROFILE_HANDOFF, (uint64_t)&refusal, 0) == -3 &&
                 (refusal & 0xFF) == CROI_ADMISSION_CPU_OVERLOADED &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, v, handoff, CROI_PROFILE_HANDOFF, (uint64_t)&refusal, 0) == 0 &&
                 refusal == CROI_ADMISSION_ACCEPTED &&
                 sys(CROI_SYS_THREAD_BIND_OVERRUN_PORT, v, port, 7, 0, 0) == 0);
  handoff_waiter_t h;
  zero_bytes(&h, sizeof h);
  h.interrupt = v;
  uint32_t worker = start_thread(s, handoff_waiter, (uint64_t)&h);
  for (uint32_t i = 0; i < 3; i++) {
    CHECK(630, blocked_on_interrupt(worker) && sys(CROI_SYS_INTERRUPT_TRIGGER, v, 0, now_ns(), 0, 0) == 0 &&
                   round_done(&h.round, i + 1));
  }
  // A fair thread woken runs on the context's deadline, on its CPU.
  CHECK(631, h.deadline[0] == 1 && h.borrowed[0] >= 0 && h.borrowed[0] == h.cpu[0]);
  // Woken again within the period: the same period (one budget); when
  // that runs out it carries on on its own profile, an overrun reported.
  croi_port_packet_t p;
  CHECK(632, h.deadline[1] == 1 && h.start[1] == h.start[0] && h.fell_back >= 0 &&
                 port_next(port, 1000000000, &p) == 0 && p.type == CROI_PKT_TYPE_BUDGET_OVERRUN && p.key == 7 &&
                 p.payload[1] >= 1);
  // Woken while the budget is spent: on its own.
  CHECK(633, h.deadline[2] == 0 && h.borrowed[2] == -1);
  // A new context (fresh budget); replaced by a lend while the woken
  // thread runs on it, it is withdrawn at once.
  CHECK(634, sys(CROI_SYS_OBJECT_SET_PROFILE, v, handoff, CROI_PROFILE_HANDOFF, (uint64_t)&refusal, 0) == 0 &&
                 blocked_on_interrupt(worker) && sys(CROI_SYS_INTERRUPT_TRIGGER, v, 0, now_ns(), 0, 0) == 0 &&
                 round_done(&h.spinning, 1) && h.deadline[3] == 1 && h.borrowed[3] >= 0 &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, v, lend, 0, 0, 0) == 0);
  h.release = 1;
  join_checked(worker);
  CHECK(635, h.withdrawn == 1);
  uint32_t handles[] = {v, handoff, huge, port};
  for (int i = 0; i < 4; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0;
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
  int64_t handed = interrupt_handoff(s, counter, fair, deadline);
  if (handed != 0) return handed;
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
  // At least one sample: a thread a loaded host starts late still says
  // where it ran.
  do p->seen |= 1ull << sys(CROI_SYS_TEST_PROFILE, 5, 0, 0, 0, 0);
  while (!p->stop && now_ns() < p->until);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// K13a: SLICE children of a physical VMO (segment 0's ECAM: device 1's
// configuration space reads the same through a slice as through the
// parent), the rights and refusals, cache policies frozen, HANDLE_COUNT
// through a channel, and ZERO_CHILDREN following handles and mappings.
#ifndef ERR_ACCESS_DENIED_
#define ERR_ACCESS_DENIED_ (-30)
#endif
// K13c: sockets (Zircon's): stream and datagram, peek, a full buffer,
// dispositions, read threshold, ZX_INFO_SOCKET, user signals, peer close.
static int64_t sockets(const startup_t *s) {
  uint32_t a = 0, b = 0, observed = 0;
  uint64_t actual = 0;
  char buf[16];
  CHECK(450, sys(CROI_SYS_SOCKET_CREATE, 2, (uint64_t)&a, (uint64_t)&b, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_SOCKET_CREATE, CROI_SOCKET_STREAM, (uint64_t)&a, (uint64_t)&b, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, a, CROI_SIGNAL_WRITABLE, 0, (uint64_t)&observed, 0) == 0 &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, (uint64_t)buf, 4, (uint64_t)&actual) == ERR_SHOULD_WAIT);
  // Stream: bytes, a peek, the rest.
  CHECK(451, sys(CROI_SYS_SOCKET_WRITE, a, 0, (uint64_t)"abcdefghij", 10, (uint64_t)&actual) == 0 && actual == 10 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, CROI_SIGNAL_READABLE, 0, (uint64_t)&observed, 0) == 0 &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, (uint64_t)buf, 4, (uint64_t)&actual) == 0 && actual == 4 &&
                 buf[0] == 'a' && buf[3] == 'd' &&
                 sys(CROI_SYS_SOCKET_READ, b, CROI_SOCKET_PEEK, (uint64_t)buf, 3, (uint64_t)&actual) == 0 &&
                 actual == 3 && buf[0] == 'e' &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, (uint64_t)buf, 16, (uint64_t)&actual) == 0 && actual == 6 &&
                 buf[0] == 'e' && buf[5] == 'j' &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, CROI_SIGNAL_READABLE, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT);
  // Full: 4 KiB writes until SHOULD_WAIT (256 KiB), WRITABLE gone; a read
  // brings it back.
  uint32_t vmo = 0;
  uint64_t chunk = 0, total = 0;
  CHECK(452, sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, vmo, 0,
                      PAGE, (uint64_t)&chunk) == 0);
  int64_t status = 0;
  while ((status = sys(CROI_SYS_SOCKET_WRITE, a, 0, chunk, PAGE, (uint64_t)&actual)) == 0) total += actual;
  CHECK(453, status == ERR_SHOULD_WAIT && total == 64 * PAGE &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, a, CROI_SIGNAL_WRITABLE, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, chunk, PAGE, (uint64_t)&actual) == 0 && actual == PAGE &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, a, CROI_SIGNAL_WRITABLE, 0, (uint64_t)&observed, 0) == 0);
  croi_info_socket_t info = {0};
  CHECK(454, sys(CROI_SYS_OBJECT_GET_INFO, b, CROI_INFO_SOCKET, (uint64_t)&info, sizeof info, 0) == 0 &&
                 info.rx_buf_size == 63 * PAGE && info.rx_buf_max == 64 * PAGE && info.tx_buf_size == 0);
  while (sys(CROI_SYS_SOCKET_READ, b, 0, chunk, PAGE, (uint64_t)&actual) == 0) {}
  // Dispositions: a's writing off (BAD_STATE writing; b's empty reads are
  // BAD_STATE), then back on.
  CHECK(455, sys(CROI_SYS_SOCKET_SET_DISPOSITION, a, 3, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_SOCKET_SET_DISPOSITION, a, CROI_SOCKET_DISPOSITION_WRITE_DISABLED, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_SOCKET_WRITE, a, 0, (uint64_t)"x", 1, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, CROI_SOCKET_PEER_WRITE_DISABLED, 0, (uint64_t)&observed, 0) == 0 &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, (uint64_t)buf, 1, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_SOCKET_SET_DISPOSITION, b, 0, CROI_SOCKET_DISPOSITION_WRITE_ENABLED, 0, 0) == 0 &&
                 sys(CROI_SYS_SOCKET_WRITE, a, 0, (uint64_t)"x", 1, 0) == 0);
  // Read threshold: READ_THRESHOLD once 3 bytes wait.
  uint64_t threshold = 3, got = 0;
  CHECK(456, sys(CROI_SYS_OBJECT_SET_PROPERTY, b, CROI_PROP_SOCKET_RX_THRESHOLD, (uint64_t)&threshold, 8, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, CROI_SOCKET_READ_THRESHOLD, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_SOCKET_WRITE, a, 0, (uint64_t)"yz", 2, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, CROI_SOCKET_READ_THRESHOLD, 0, (uint64_t)&observed, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_PROPERTY, b, CROI_PROP_SOCKET_RX_THRESHOLD, (uint64_t)&got, 8, 0) == 0 &&
                 got == 3);
  // A user signal to the peer; then a gone: b drains, then PEER_CLOSED.
  CHECK(457, sys(CROI_SYS_OBJECT_SIGNAL_PEER, a, 0, 1u << 24, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, 1u << 24, 0, (uint64_t)&observed, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, a, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, CROI_SIGNAL_PEER_CLOSED, 0, (uint64_t)&observed, 0) == 0 &&
                 sys(CROI_SYS_SOCKET_WRITE, b, 0, (uint64_t)"x", 1, 0) == ERR_PEER_CLOSED &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, (uint64_t)buf, 16, (uint64_t)&actual) == 0 && actual == 3 &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, (uint64_t)buf, 16, (uint64_t)&actual) == ERR_PEER_CLOSED);
  sys(CROI_SYS_HANDLE_CLOSE, b, 0, 0, 0, 0);
  // Datagrams: whole messages; a short read drops the rest; a 0-byte read
  // consumes nothing; too big is OUT_OF_RANGE.
  CHECK(458, sys(CROI_SYS_SOCKET_CREATE, CROI_SOCKET_DATAGRAM, (uint64_t)&a, (uint64_t)&b, 0, 0) == 0 &&
                 sys(CROI_SYS_SOCKET_WRITE, a, 0, (uint64_t)"hello", 5, (uint64_t)&actual) == 0 && actual == 5 &&
                 sys(CROI_SYS_SOCKET_WRITE, a, 0, (uint64_t)"abc", 3, 0) == 0 &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, 0, 0, (uint64_t)&actual) == 0 && actual == 0 &&
                 sys(CROI_SYS_OBJECT_GET_INFO, b, CROI_INFO_SOCKET, (uint64_t)&info, sizeof info, 0) == 0 &&
                 info.rx_buf_size == 8 && info.rx_buf_available == 5 &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, (uint64_t)buf, 2, (uint64_t)&actual) == 0 && actual == 2 &&
                 buf[0] == 'h' && buf[1] == 'e' &&
                 sys(CROI_SYS_SOCKET_READ, b, 0, (uint64_t)buf, 16, (uint64_t)&actual) == 0 && actual == 3 &&
                 buf[0] == 'a' &&
                 sys(CROI_SYS_SOCKET_WRITE, a, 0, chunk, 300000, 0) == ERR_OUT_OF_RANGE);
  sys(CROI_SYS_HANDLE_CLOSE, a, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, b, 0, 0, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, chunk, PAGE, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  return 0;
}

// K13c: streams (Zircon's) over a two-page VMO with stream size 0: writes
// at the seek extend the stream size, reads stop there, seeks, append,
// a gap zero-filled, a write cut at the VMO's end, info and properties.
static int64_t streams(void) {
  uint32_t vmo = 0, st = 0, ro = 0;
  uint64_t actual = 0, at = 0, size = 0;
  char buf[32];
  croi_iovec_t two[2] = {{(void *)"hello ", 6}, {(void *)"world", 5}};
  croi_iovec_t in = {buf, sizeof buf};
  CHECK(460, sys(CROI_SYS_VMO_CREATE, 2 * PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == 2 * PAGE &&
                 sys(CROI_SYS_VMO_SET_STREAM_SIZE, vmo, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_STREAM_CREATE, 8, vmo, 0, (uint64_t)&st, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_STREAM_CREATE, CROI_STREAM_MODE_READ | CROI_STREAM_MODE_WRITE, vmo, 0, (uint64_t)&st, 0) == 0 &&
                 sys(CROI_SYS_STREAM_CREATE, CROI_STREAM_MODE_READ, vmo, 0, (uint64_t)&ro, 0) == 0);
  // Write at the seek; the read stops at the stream size.
  CHECK(461, sys(CROI_SYS_STREAM_WRITEV, st, 0, (uint64_t)two, 2, (uint64_t)&actual) == 0 && actual == 11 &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == 11 &&
                 sys(CROI_SYS_STREAM_READV, ro, 0, (uint64_t)&in, 1, (uint64_t)&actual) == 0 && actual == 11 &&
                 buf[0] == 'h' && buf[6] == 'w' && buf[10] == 'd' &&
                 sys(CROI_SYS_STREAM_READV, ro, 0, (uint64_t)&in, 1, (uint64_t)&actual) == 0 && actual == 0 &&
                 sys(CROI_SYS_STREAM_WRITEV, ro, 0, (uint64_t)two, 1, 0) == ERR_ACCESS_DENIED);
  // Seeks: END - 5 reads "world"; START negative is INVALID_ARGS.
  CHECK(462, sys(CROI_SYS_STREAM_SEEK, ro, CROI_STREAM_SEEK_ORIGIN_END, (uint64_t)-5, (uint64_t)&at, 0) == 0 && at == 6 &&
                 sys(CROI_SYS_STREAM_READV, ro, 0, (uint64_t)&in, 1, (uint64_t)&actual) == 0 && actual == 5 &&
                 buf[0] == 'w' &&
                 sys(CROI_SYS_STREAM_SEEK, ro, CROI_STREAM_SEEK_ORIGIN_START, (uint64_t)-1, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_STREAM_SEEK, ro, CROI_STREAM_SEEK_ORIGIN_CURRENT, (uint64_t)-100, 0, 0) == ERR_INVALID_ARGS);
  // Append ignores the seek; a write past the end zero-fills the gap.
  CHECK(463, sys(CROI_SYS_STREAM_SEEK, st, CROI_STREAM_SEEK_ORIGIN_START, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_STREAM_WRITEV, st, CROI_STREAM_APPEND, (uint64_t)&two[1], 1, (uint64_t)&actual) == 0 &&
                 actual == 5 &&
                 sys(CROI_SYS_STREAM_SEEK, st, CROI_STREAM_SEEK_ORIGIN_CURRENT, 0, (uint64_t)&at, 0) == 0 && at == 16 &&
                 sys6(CROI_SYS_STREAM_WRITEV_AT, st, 0, 20, (uint64_t)&two[1], 1, (uint64_t)&actual) == 0 && actual == 5 &&
                 sys6(CROI_SYS_STREAM_READV_AT, ro, 0, 11, (uint64_t)&in, 1, (uint64_t)&actual) == 0 && actual == 14 &&
                 buf[0] == 'w' && buf[5] == 0 && buf[8] == 0 && buf[9] == 'w');
  // At the VMO's end: cut short; at or past it OUT_OF_RANGE.
  CHECK(464, sys6(CROI_SYS_STREAM_WRITEV_AT, st, 0, 2 * PAGE - 3, (uint64_t)two, 1, (uint64_t)&actual) == 0 && actual == 3 &&
                 sys6(CROI_SYS_STREAM_WRITEV_AT, st, 0, 2 * PAGE, (uint64_t)two, 1, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == 2 * PAGE);
  // Info, append mode as a property, content size as a property (shrinking
  // zeroes what was past it).
  croi_info_stream_t info = {0};
  uint8_t append = 1;
  uint64_t content = 4;
  CHECK(465, sys(CROI_SYS_OBJECT_SET_PROPERTY, st, CROI_PROP_STREAM_MODE_APPEND, (uint64_t)&append, 1, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_INFO, st, CROI_INFO_STREAM, (uint64_t)&info, sizeof info, 0) == 0 &&
                 info.options == (CROI_STREAM_MODE_READ | CROI_STREAM_MODE_WRITE | CROI_STREAM_MODE_APPEND) &&
                 info.seek == 16 && info.content_size == 2 * PAGE &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, vmo, CROI_PROP_VMO_CONTENT_SIZE, (uint64_t)&content, 8, 0) == 0 &&
                 sys(CROI_SYS_STREAM_WRITEV, st, 0, (uint64_t)&two[1], 1, (uint64_t)&actual) == 0 && actual == 5 &&
                 sys6(CROI_SYS_STREAM_READV_AT, ro, 0, 0, (uint64_t)&in, 1, (uint64_t)&actual) == 0 && actual == 9 &&
                 buf[3] == 'l' && buf[4] == 'w' &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)buf, 20, 1, 0) == 0 && buf[0] == 0);
  sys(CROI_SYS_HANDLE_CLOSE, st, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, ro, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  return 0;
}

// K13d: the user pager. A pager thread serves READ requests from a port:
// each page filled with 'A' + its index, except page 3, which it fails
// with IO; DIRTY requests it grants; it records requests and the
// COMPLETE. slot: [0] port, [1] pager, [2] vmo, [3] reads, [4] last
// read's length, [5] COMPLETE seen, [6] dirty requests, [7] key.
static void pager_server(uint64_t arg) {
  volatile uint64_t *slot = (volatile uint64_t *)arg;
  croi_port_packet_t packet;
  char page[PAGE];
  while (sys(CROI_SYS_PORT_WAIT, (uint32_t)slot[0], now_ns() + 5000000000ull, (uint64_t)&packet, 0, 0) == 0) {
    uint64_t *req = (uint64_t *)&packet.payload;
    if (packet.type != CROI_PKT_TYPE_PAGE_REQUEST || packet.key != slot[7]) break;
    uint16_t command = (uint16_t)req[0];
    if (command == CROI_PAGER_VMO_COMPLETE) {
      slot[5] = 1;
      break;
    }
    uint64_t offset = req[1], length = req[2];
    if (command == CROI_PAGER_VMO_DIRTY) {
      slot[6]++;
      sys6(CROI_SYS_PAGER_OP_RANGE, (uint32_t)slot[1], CROI_PAGER_OP_DIRTY, (uint32_t)slot[2], offset, length, 0);
      continue;
    }
    slot[3]++;
    slot[4] = length;
    if (offset <= 3 * PAGE && 3 * PAGE < offset + length) {
      sys6(CROI_SYS_PAGER_OP_RANGE, (uint32_t)slot[1], CROI_PAGER_OP_FAIL, (uint32_t)slot[2], 3 * PAGE, PAGE,
           (uint64_t)(int64_t)-40);
      if (offset == 3 * PAGE) continue;
      length = 3 * PAGE - offset;
    }
    uint32_t aux = 0;
    sys(CROI_SYS_VMO_CREATE, length, 0, (uint64_t)&aux, 0, 0);
    for (uint64_t at = 0; at < length; at += PAGE) {
      for (int i = 0; i < PAGE; i++) page[i] = (char)('A' + (offset + at) / PAGE);
      sys(CROI_SYS_VMO_WRITE, aux, (uint64_t)page, at, PAGE, 0);
    }
    sys6(CROI_SYS_PAGER_SUPPLY_PAGES, (uint32_t)slot[1], (uint32_t)slot[2], offset, length, aux, 0);
    sys(CROI_SYS_HANDLE_CLOSE, aux, 0, 0, 0, 0);
  }
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t pager(const startup_t *s) {
  uint32_t pg = 0, port = 0, vmo = 0, other = 0, child = 0;
  uint64_t size = 0;
  CHECK(470, sys(CROI_SYS_PAGER_CREATE, 1, (uint64_t)&pg, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&pg, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, CROI_VMO_RESIZABLE | CROI_VMO_UNBOUNDED, port, 77, PAGE,
                      (uint64_t)&vmo) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, 0, port, 77, 4 * PAGE + 100, (uint64_t)&vmo) == 0 &&
                 sys(CROI_SYS_VMO_GET_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == 5 * PAGE &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == 4 * PAGE + 100 &&
                 sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&other, 0, 0) == 0);
  // Refusals: misaligned, a status FAIL won't take, a VMO not the pager's.
  CHECK(471, sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, vmo, 1, PAGE, other, 0) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_FAIL, vmo, 0, PAGE, (uint64_t)(int64_t)-10) ==
                     ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_FAIL, vmo, 0, PAGE, 0xFFFFFFD8ull) ==
                     ERR_INVALID_ARGS &&  // -40 zero-extended
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_FAIL, other, 0, PAGE, (uint64_t)(int64_t)-40) ==
                     ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, 99, vmo, 0, PAGE, 0) == ERR_NOT_SUPPORTED);
  volatile uint64_t slot[8] = {port, pg, vmo, 0, 0, 0, 0, 77};
  uint32_t server = start_thread(s, pager_server, (uint64_t)slot);
  // A fault: one request, one page.
  uint64_t at = 0;
  CHECK(472, sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, vmo, 0, 5 * PAGE,
                  (uint64_t)&at) == 0 &&
                 *(volatile char *)at == 'A' && *(volatile char *)(at + PAGE - 1) == 'A' && slot[3] == 1 &&
                 slot[4] == PAGE);
  // vmo_read across pages 1-2: one request for both.
  char buf[16];
  CHECK(473, sys(CROI_SYS_VMO_READ, vmo, (uint64_t)buf, PAGE + PAGE - 4, 8, 0) == 0 && buf[0] == 'B' &&
                 buf[4] == 'C' && slot[3] == 2 && slot[4] == 2 * PAGE &&
                 *(volatile char *)(at + 2 * PAGE) == 'C' && slot[3] == 2);
  // Page 3 fails: vmo_read gets the pager's status.
  CHECK(474, sys(CROI_SYS_VMO_READ, vmo, (uint64_t)buf, 3 * PAGE, 4, 0) == -40);
  // A snapshot child reads page 4 through to the pager.
  CHECK(475, sys6(CROI_SYS_VMO_CREATE_CHILD, vmo, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 4 * PAGE, PAGE,
                  (uint64_t)&child, 0) == 0 &&
                 sys(CROI_SYS_VMO_READ, child, (uint64_t)buf, 0, 4, 0) == 0 && buf[0] == 'E');
  // Dirty tracking (part 2) without TRAP_DIRTY: nothing written yet; a
  // write through a writable mapping (the clean page is mapped read only
  // until then) and a vmo_write dirty pages 0 and 1, one range; the stats
  // say modified once.
  uint64_t rw = 0, counts[2] = {0, 0};
  croi_pager_vmo_stats_t stats = {0};
  croi_vmo_dirty_range_t ranges[4];
  CHECK(477, sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)vmo << 32, 0, 5 * PAGE, (uint64_t)ranges,
                  sizeof ranges, (uint64_t)counts) == 0 && counts[0] == 0 && counts[1] == 0 &&
                 sys(CROI_SYS_PAGER_QUERY_VMO_STATS, pg, vmo, 0, (uint64_t)&stats, sizeof stats) == 0 &&
                 stats.modified == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, vmo, 0,
                      2 * PAGE, (uint64_t)&rw) == 0 &&
                 *(volatile char *)rw == 'A' &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)vmo << 32, 0, 5 * PAGE, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[1] == 0);  // a read dirties nothing
  *(volatile char *)rw = 'a';
  CHECK(478, sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)"b", PAGE, 1, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)vmo << 32, 0, 5 * PAGE, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[0] == 1 && counts[1] == 1 &&
                 ranges[0].offset == 0 && ranges[0].length == 2 * PAGE &&
                 sys(CROI_SYS_PAGER_QUERY_VMO_STATS, pg, vmo, CROI_PAGER_RESET_VMO_STATS, (uint64_t)&stats,
                     sizeof stats) == 0 && stats.modified == CROI_PAGER_VMO_STATS_MODIFIED &&
                 sys(CROI_SYS_PAGER_QUERY_VMO_STATS, pg, vmo, 0, (uint64_t)&stats, sizeof stats) == 0 &&
                 stats.modified == 0 && *(volatile char *)at == 'a');
  // Writeback: both await clean; page 0 written meanwhile stays dirty.
  CHECK(479, sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_BEGIN, vmo, 0, 2 * PAGE, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)vmo << 32, 0, 5 * PAGE, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[1] == 1 && ranges[0].length == 2 * PAGE);
  *(volatile char *)rw = 'x';
  CHECK(480, sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_END, vmo, 0, 2 * PAGE, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)vmo << 32, 0, 5 * PAGE, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[1] == 1 && ranges[0].offset == 0 &&
                 ranges[0].length == PAGE &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_DIRTY, vmo, 0, PAGE, 0) == ERR_NOT_SUPPORTED &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_BEGIN, vmo, 0, PAGE, 2) == ERR_INVALID_ARGS);
  // Detach: COMPLETE; dirty pages stay, clean ones (page 1, page 2) go;
  // missing ones are BAD_STATE.
  CHECK(476, sys(CROI_SYS_PAGER_DETACH_VMO, pg, vmo, 0, 0, 0) == 0 &&
                 wait_for(server, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull) && slot[5] == 1 &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)buf, 3 * PAGE, 4, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)buf, 2 * PAGE, 4, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)buf, 0, 4, 0) == 0 && buf[0] == 'x' &&
                 sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, vmo, 0, PAGE, other, 0) == ERR_BAD_STATE);
  sys(CROI_SYS_HANDLE_CLOSE, server, 0, 0, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, 5 * PAGE, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, rw, 2 * PAGE, 0, 0);
  // TRAP_DIRTY: writes wait for the pager's DIRTY (vmo_write, then a
  // write fault); DIRTY of a page not supplied is NOT_FOUND; closing the
  // VMO sends COMPLETE.
  uint32_t trap = 0;
  CHECK(481, sys6(CROI_SYS_PAGER_CREATE_VMO, pg, CROI_VMO_TRAP_DIRTY, port, 78, 2 * PAGE, (uint64_t)&trap) == 0);
  volatile uint64_t tslot[8] = {port, pg, trap, 0, 0, 0, 0, 78};
  server = start_thread(s, pager_server, (uint64_t)tslot);
  CHECK(482, sys(CROI_SYS_VMO_WRITE, trap, (uint64_t)"q", 0, 1, 0) == 0 && tslot[3] == 1 && tslot[6] == 1 &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_DIRTY, trap, PAGE, PAGE, 0) == ERR_NOT_FOUND &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, trap, 0,
                      2 * PAGE, (uint64_t)&rw) == 0 &&
                 *(volatile char *)(rw + PAGE) == 'B' && tslot[3] == 2 && tslot[6] == 1);
  *(volatile char *)(rw + PAGE) = 'r';
  CHECK(483, tslot[6] == 2 &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)trap << 32, 0, 2 * PAGE, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[1] == 1 && ranges[0].length == 2 * PAGE &&
                 sys(CROI_SYS_VMAR_UNMAP, s->vmar, rw, 2 * PAGE, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, trap, 0, 0, 0, 0) == 0 &&
                 wait_for(server, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull) && tslot[5] == 1);
  sys(CROI_SYS_HANDLE_CLOSE, server, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, child, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, other, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, port, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, pg, 0, 0, 0, 0);
  return 0;
}

// K13e: the small calls. A server for channel_call_etc: reads a request
// with read_etc and sends back its first word + 1 and the handle it got.
static void etc_server(uint64_t channel) {
  uint32_t request[2], actual[2];
  croi_handle_info_t info[1];
  if (wait_for((uint32_t)channel, CROI_SIGNAL_READABLE, 3000000000ull) & CROI_SIGNAL_READABLE &&
      sys6(CROI_SYS_CHANNEL_READ_ETC, (uint32_t)channel, 0, (uint64_t)request, (uint64_t)info,
           sizeof request | (uint64_t)1 << 32, (uint64_t)actual) == 0) {
    request[1] += 1;
    croi_handle_disposition_t back = {CROI_HANDLE_OP_MOVE, info[0].handle, 0, RIGHT_SAME, 0};
    sys6(CROI_SYS_CHANNEL_WRITE_ETC, (uint32_t)channel, 0, (uint64_t)request, sizeof request, (uint64_t)&back,
         actual[1]);
  }
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t small_calls(const startup_t *s) {
  // Names: set and read back (truncated to 31), WRONG_TYPE, thread names
  // from thread_create, a short buffer.
  uint32_t vmo = 0, ev = 0, ev2 = 0, thread = 0, sock[2] = {0, 0};
  char name[32];
  CHECK(490, sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&ev, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, vmo, CROI_PROP_NAME, (uint64_t)"buffer\0junk", 11, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_PROPERTY, vmo, CROI_PROP_NAME, (uint64_t)name, 31, 0) == ERR_BUFFER_TOO_SMALL &&
                 sys(CROI_SYS_OBJECT_GET_PROPERTY, vmo, CROI_PROP_NAME, (uint64_t)name, 32, 0) == 0 &&
                 name[0] == 'b' && name[5] == 'r' && name[6] == 0 && name[7] == 0 &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, vmo, CROI_PROP_NAME,
                     (uint64_t)"0123456789abcdefghijklmnopqrstuvwxyz", 36, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_PROPERTY, vmo, CROI_PROP_NAME, (uint64_t)name, 32, 0) == 0 &&
                 name[30] == 'u' && name[31] == 0 &&
                 sys(CROI_SYS_SOCKET_CREATE, 0, (uint64_t)&sock[0], (uint64_t)&sock[1], 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, sock[0], CROI_PROP_NAME, (uint64_t)"x", 1, 0) == ERR_WRONG_TYPE &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, ev, CROI_PROP_NAME, (uint64_t)"x", 1, 0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)sock, 2, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_THREAD_CREATE, s->process, (uint64_t)"worker", 6, 0, (uint64_t)&thread, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_PROPERTY, thread, CROI_PROP_NAME, (uint64_t)name, 32, 0) == 0 &&
                 name[0] == 'w' && name[5] == 'r' && name[6] == 0);
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
  // object_wait_many: the second item fires; count 0 times out; 65 is too
  // many; a bad handle writes nothing back.
  croi_wait_item_t items[2] = {{vmo, 1u << 0, 0xAA}, {ev, SIGNALED, 0xAA}};  // a VMO is never readable
  CHECK(491, sys(CROI_SYS_OBJECT_SIGNAL, ev, 0, SIGNALED, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_MANY, (uint64_t)items, 2, now_ns() + 1000000000ull, 0, 0) == 0 &&
                 (items[1].pending & SIGNALED) && !(items[0].pending & 1u) && items[0].pending != 0xAA &&
                 sys(CROI_SYS_OBJECT_WAIT_MANY, 0, 0, now_ns(), 0, 0) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_OBJECT_WAIT_MANY, (uint64_t)items, 65, 0, 0, 0) == ERR_OUT_OF_RANGE);
  items[0].handle = 0x7FFFFFF0u;
  items[1].pending = 0xAA;
  CHECK(492, sys(CROI_SYS_OBJECT_WAIT_MANY, (uint64_t)items, 2, 0, 0, 0) == ERR_BAD_HANDLE && items[1].pending == 0xAA);
  // handle_close_many: 0 skipped, a bad value reported, the rest closed.
  uint32_t list[4] = {0, 0, 0, 0};
  CHECK(493, sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&list[0], 0, 0, 0) == 0 &&
                 sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&list[3], 0, 0, 0) == 0 && (list[2] = 0x7FFFFFF0u) &&
                 sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)list, 4, 0, 0, 0) == ERR_BAD_HANDLE &&
                 sys(CROI_SYS_HANDLE_CLOSE, list[0], 0, 0, 0, 0) == ERR_BAD_HANDLE &&
                 sys(CROI_SYS_HANDLE_CLOSE, list[3], 0, 0, 0, 0) == ERR_BAD_HANDLE &&
                 sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)list, 2, 0, 0, 0) == ERR_BAD_HANDLE &&  // list[0] went
                 (list[0] = 0, sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)list, 2, 0, 0, 0) == 0));  // zeros skipped
  // port_cancel_key: an async wait and a queued user packet with key 5
  // go; key 6's stays.
  uint32_t port = 0;
  croi_port_packet_t packet = {0};
  CHECK(494, sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&ev2, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ASYNC, ev2, port, 5, SIGNALED, 0) == 0 && (packet.key = 5) &&
                 sys(CROI_SYS_PORT_QUEUE, port, (uint64_t)&packet, 0, 0, 0) == 0 && (packet.key = 6) &&
                 sys(CROI_SYS_PORT_QUEUE, port, (uint64_t)&packet, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CANCEL_KEY, port, 1, 5, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_PORT_CANCEL_KEY, port, 0, 5, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CANCEL_KEY, port, 0, 5, 0, 0) == ERR_NOT_FOUND &&
                 sys(CROI_SYS_OBJECT_SIGNAL, ev2, 0, SIGNALED, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_WAIT, port, 0, (uint64_t)&packet, 0, 0) == 0 && packet.key == 6 &&
                 sys(CROI_SYS_PORT_WAIT, port, 0, (uint64_t)&packet, 0, 0) == ERR_TIMED_OUT);
  sys(CROI_SYS_HANDLE_CLOSE, port, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, ev2, 0, 0, 0, 0);
  // Channel *_etc: a duplicate with fewer rights and its type checked
  // arrives as such; a wrong type is WRONG_TYPE in the entry's result and
  // consumes a MOVE; rights beyond the handle's INVALID_ARGS, the source
  // kept for a DUPLICATE.
  uint32_t a = 0, b = 0, actual[2] = {0, 0};
  croi_handle_info_t infos[2];
  char bytes[8];
  croi_handle_disposition_t dup = {CROI_HANDLE_OP_DUPLICATE, ev, 5, RIGHT_TRANSFER | RIGHT_WAIT, 0};
  CHECK(495, sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&a, (uint64_t)&b, 0, 0) == 0 &&
                 sys6(CROI_SYS_CHANNEL_WRITE_ETC, a, 0, (uint64_t)"hi", 2, (uint64_t)&dup, 1) == 0 &&
                 sys6(CROI_SYS_CHANNEL_READ_ETC, b, 0, (uint64_t)bytes, (uint64_t)infos,
                      sizeof bytes | (uint64_t)2 << 32, (uint64_t)actual) == 0 &&
                 actual[0] == 2 && actual[1] == 1 && infos[0].type == 5 &&
                 infos[0].rights == (RIGHT_TRANSFER | RIGHT_WAIT) && infos[0].unused == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, infos[0].handle, 0, 0, 0, 0) == 0);
  uint32_t moved = 0;
  CHECK(496, sys(CROI_SYS_HANDLE_DUPLICATE, ev, RIGHT_SAME, (uint64_t)&moved, 0, 0) == 0);
  croi_handle_disposition_t two[2] = {{CROI_HANDLE_OP_MOVE, moved, 4, RIGHT_SAME, 0},
                                      {CROI_HANDLE_OP_DUPLICATE, ev, 0, 0xFFFFFFFu, 0}};
  CHECK(497, sys6(CROI_SYS_CHANNEL_WRITE_ETC, a, 0, (uint64_t)"x", 1, (uint64_t)two, 2) == ERR_WRONG_TYPE &&
                 two[0].result == ERR_WRONG_TYPE && two[1].result == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_HANDLE_CLOSE, moved, 0, 0, 0, 0) == ERR_BAD_HANDLE &&
                 (wait_for(ev, SIGNALED, 0) & SIGNALED) &&  // the duplicated one still works
                 sys6(CROI_SYS_CHANNEL_READ_ETC, b, 1, (uint64_t)bytes, (uint64_t)infos, 0, (uint64_t)actual) ==
                     ERR_SHOULD_WAIT);
  // MAY_DISCARD drops a message that doesn't fit; call_etc round trip.
  uint32_t server = start_thread(s, etc_server, b);
  uint32_t request[2] = {0, 41}, reply[2] = {0, 0};
  croi_handle_disposition_t give = {CROI_HANDLE_OP_DUPLICATE, ev, 0, RIGHT_SAME, 0};
  croi_channel_call_etc_args_t args = {(uint64_t)request, (uint64_t)&give, (uint64_t)reply, (uint64_t)infos,
                                       sizeof request, 1, sizeof reply, 2};
  uint32_t got_bytes = 0, got_handles = 0;
  CHECK(498, sys6(CROI_SYS_CHANNEL_CALL_ETC, a, 0, now_ns() + 3000000000ull, (uint64_t)&args, (uint64_t)&got_bytes,
                  (uint64_t)&got_handles) == 0 &&
                 got_bytes == 8 && got_handles == 1 && reply[1] == 42 && infos[0].type == 5 &&
                 sys(CROI_SYS_HANDLE_CLOSE, infos[0].handle, 0, 0, 0, 0) == 0);
  join(server);
  uint32_t c = 0, d = 0;
  CHECK(499, sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&c, (uint64_t)&d, 0, 0) == 0 &&
                 sys6(CROI_SYS_CHANNEL_WRITE, c, 0, (uint64_t)"long message", 12, 0, 0) == 0 &&
                 sys6(CROI_SYS_CHANNEL_READ_ETC, d, 2, (uint64_t)bytes, 0, 4, (uint64_t)actual) == ERR_NOT_SUPPORTED &&
                 sys6(CROI_SYS_CHANNEL_READ_ETC, d, CROI_CHANNEL_READ_MAY_DISCARD, (uint64_t)bytes, 0, 4,
                      (uint64_t)actual) == ERR_BUFFER_TOO_SMALL && actual[0] == 12 &&
                 sys6(CROI_SYS_CHANNEL_READ_ETC, d, 0, (uint64_t)bytes, 0, 4, (uint64_t)actual) == ERR_SHOULD_WAIT);
  uint32_t rest[6] = {a, b, c, d, ev, vmo};
  sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)rest, 6, 0, 0, 0);
  return 0;
}

// K13e part 2: info topics and vmar_op_range. A thread to inspect while
// it waits on a port.
static void port_sleeper(uint64_t port) {
  croi_port_packet_t packet;
  sys(CROI_SYS_PORT_WAIT, (uint32_t)port, now_ns() + 5000000000ull, (uint64_t)&packet, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int get_info(uint32_t handle, uint32_t topic, void *buffer, uint64_t size, uint64_t counts[2]) {
  return (int)sys6(CROI_SYS_OBJECT_GET_INFO, handle, topic, (uint64_t)buffer, size, (uint64_t)&counts[0],
                   (uint64_t)&counts[1]);
}

static int64_t info_topics(const startup_t *s) {
  uint64_t counts[2] = {9, 9};
  croi_info_process_t process = {0};
  CHECK(510, get_info(s->process, CROI_INFO_PROCESS, &process, 8, counts) == ERR_BUFFER_TOO_SMALL &&
                 counts[0] == 0 && counts[1] == 1 &&
                 get_info(s->process, CROI_INFO_PROCESS, &process, sizeof process, counts) == 0 &&
                 counts[0] == 1 && counts[1] == 1 && process.flags == CROI_INFO_PROCESS_FLAG_STARTED &&
                 process.start_time > 0 && process.start_time <= (int64_t)now_ns());
  // A thread waiting on a port: BLOCKED_PORT; its process's thread list
  // has it; once it exits DEAD, and THREAD_STATS BAD_STATE.
  uint32_t port = 0;
  CHECK(511, sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0);
  uint32_t sleeper = start_thread(s, port_sleeper, port);
  croi_info_thread_t thread;  // filled by the kernel (a zero initializer would need memset on rv64)
  thread.state = 0;
  uint64_t give_up = now_ns() + 2000000000ull;
  do {
    get_info(sleeper, CROI_INFO_THREAD, &thread, sizeof thread, counts);
  } while (thread.state != CROI_THREAD_STATE_BLOCKED_PORT && now_ns() < give_up);
  uint64_t koids[64];
  int listed = 0;
  CHECK(512, thread.state == CROI_THREAD_STATE_BLOCKED_PORT && thread.cpu_affinity_mask[0] != 0 &&
                 get_info(s->process, CROI_INFO_PROCESS_THREADS, koids, sizeof koids, counts) == 0 &&
                 counts[0] == counts[1] && counts[1] >= 2);
  for (uint64_t i = 0; i < counts[0]; i++) listed |= koids[i] == koid_of(sleeper);
  croi_info_thread_stats_t stats = {0};
  croi_port_packet_t wake = {0};
  CHECK(513, listed && get_info(sleeper, CROI_INFO_THREAD_STATS, &stats, sizeof stats, counts) == 0 &&
                 stats.last_scheduled_cpu != CROI_INFO_INVALID_CPU &&
                 sys(CROI_SYS_PORT_QUEUE, port, (uint64_t)&wake, 0, 0, 0) == 0 &&
                 (wait_for(sleeper, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull) & CROI_SIGNAL_TASK_TERMINATED) &&
                 get_info(sleeper, CROI_INFO_THREAD, &thread, sizeof thread, counts) == 0 &&
                 thread.state == CROI_THREAD_STATE_DEAD &&
                 get_info(sleeper, CROI_INFO_THREAD_STATS, &stats, sizeof stats, counts) == ERR_BAD_STATE);
  sys(CROI_SYS_HANDLE_CLOSE, sleeper, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, port, 0, 0, 0, 0);
  // Runtime: ours, and the job's at least as much; V1 is the first half.
  croi_info_task_runtime_t mine, jobs;
  CHECK(514, get_info(s->process, CROI_INFO_TASK_RUNTIME, &mine, sizeof mine, counts) == 0 && mine.cpu_time > 0 &&
                 get_info(s->job, CROI_INFO_TASK_RUNTIME_V1, &jobs, 16, counts) == 0 &&
                 jobs.cpu_time >= mine.cpu_time);
  // Jobs: a child job listed, ZX_INFO_JOB not exited.
  uint32_t child = 0;
  croi_info_job_t job = {0};
  CHECK(515, sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&child, 0, 0) == 0 &&
                 get_info(s->job, CROI_INFO_JOB_CHILDREN, koids, sizeof koids, counts) == 0 && counts[1] >= 1 &&
                 get_info(child, CROI_INFO_JOB, &job, sizeof job, counts) == 0 && job.exited == 0 &&
                 get_info(child, CROI_INFO_JOB_PROCESSES, koids, 0, counts) == 0 && counts[0] == 0 && counts[1] == 0);
  listed = 0;
  get_info(s->job, CROI_INFO_JOB_CHILDREN, koids, sizeof koids, counts);
  for (uint64_t i = 0; i < counts[0]; i++) listed |= koids[i] == koid_of(child);
  CHECK(516, listed && sys(CROI_SYS_TASK_KILL, child, 0, 0, 0, 0) == 0 &&
                 get_info(child, CROI_INFO_JOB, &job, sizeof job, counts) == 0 && job.exited == 1 &&
                 job.return_code == -1024);
  sys(CROI_SYS_HANDLE_CLOSE, child, 0, 0, 0, 0);
  // A VMO: koid, name, size, committed bytes, flags, rights.
  uint32_t vmo = 0;
  uint64_t at = 0;
  croi_info_vmo_t v;
  CHECK(517, sys(CROI_SYS_VMO_CREATE, 2 * PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, vmo, CROI_PROP_NAME, (uint64_t)"inspected", 9, 0) == 0 &&
                 sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)"x", 0, 1, 0) == 0 &&
                 get_info(vmo, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && v.koid == koid_of(vmo) &&
                 v.name[0] == 'i' && v.name[8] == 'd' && v.size_bytes == 2 * PAGE && v.committed_bytes == PAGE &&
                 v.flags == (CROI_INFO_VMO_TYPE_PAGED | CROI_INFO_VMO_VIA_HANDLE) && v.handle_rights != 0 &&
                 v.num_mappings == 0 && v.cache_policy == CROI_CACHE_POLICY_CACHED &&
                 get_info(vmo, CROI_INFO_VMO_V1, &v, 104, counts) == 0);
  // Mapped: vmar_op_range commits and decommits through the mapping; the
  // maps list it under the root VMAR; PROCESS_VMOS lists it twice.
  CHECK(518, sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, vmo, 0,
                  2 * PAGE, (uint64_t)&at) == 0 &&
                 sys6(CROI_SYS_VMAR_OP_RANGE, s->vmar, 99, at, PAGE, 0, 0) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_VMAR_OP_RANGE, s->vmar, CROI_VMAR_OP_COMMIT, at + 1, PAGE, 0, 0) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_VMAR_OP_RANGE, s->vmar, CROI_VMAR_OP_COMMIT, at, PAGE, 1, 0) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_VMAR_OP_RANGE, s->vmar, CROI_VMAR_OP_COMMIT, at, 3 * PAGE, 0, 0) == ERR_BAD_STATE &&
                 sys6(CROI_SYS_VMAR_OP_RANGE, s->vmar, CROI_VMAR_OP_COMMIT, at, 2 * PAGE - 5, 0, 0) == 0 &&
                 get_info(vmo, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && v.committed_bytes == 2 * PAGE &&
                 v.num_mappings == 1 && v.share_count == 1 &&
                 sys6(CROI_SYS_VMAR_OP_RANGE, s->vmar, CROI_VMAR_OP_DECOMMIT, at, PAGE, 0, 0) == 0 &&
                 get_info(vmo, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && v.committed_bytes == PAGE &&
                 *(volatile char *)at == 0 &&
                 sys6(CROI_SYS_VMAR_OP_RANGE, s->vmar, CROI_VMAR_OP_DONT_NEED, at, 2 * PAGE, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_OP_RANGE, s->vmar, CROI_VMAR_OP_MAP_RANGE, at, 2 * PAGE, 0, 0) == 0);
  // Big buffers in a scratch mapping (no writable statics here).
  uint32_t scratch_vmo = 0;
  uint64_t scratch = 0;
  CHECK(523, sys(CROI_SYS_VMO_CREATE, 16 * PAGE, 0, (uint64_t)&scratch_vmo, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0,
                      scratch_vmo, 0, 16 * PAGE, (uint64_t)&scratch) == 0);
  croi_info_maps_t *maps = (croi_info_maps_t *)scratch;
  int found = 0;
  CHECK(519, get_info(s->process, CROI_INFO_PROCESS_MAPS, maps, 16 * PAGE, counts) == 0 && counts[0] >= 3 &&
                 maps[0].type == CROI_INFO_MAPS_TYPE_ASPACE && maps[0].depth == 0 &&
                 maps[1].type == CROI_INFO_MAPS_TYPE_VMAR && maps[1].depth == 1 && maps[1].name[0] == 'r');
  for (uint64_t i = 0; i < counts[0]; i++) {
    if (maps[i].type == CROI_INFO_MAPS_TYPE_MAPPING && maps[i].base == at) {
      found = maps[i].size == 2 * PAGE && maps[i].depth == 2 && maps[i].name[0] == 'i' &&
              maps[i].u.mapping.vmo_koid == koid_of(vmo) &&
              maps[i].u.mapping.mmu_flags == (CROI_VM_PERM_READ | CROI_VM_PERM_WRITE);
    }
  }
  croi_info_vmo_t *vmos = (croi_info_vmo_t *)scratch;
  int via_handle = 0, via_mapping = 0;
  CHECK(520, found && get_info(s->process, CROI_INFO_PROCESS_VMOS, vmos, 16 * PAGE, counts) == 0);
  for (uint64_t i = 0; i < counts[0]; i++) {
    if (vmos[i].koid != koid_of(vmo)) continue;
    via_handle += (vmos[i].flags & CROI_INFO_VMO_VIA_HANDLE) != 0;
    via_mapping += (vmos[i].flags & CROI_INFO_VMO_VIA_MAPPING) != 0;
  }
  // The handle table: our VMO's handle with its koid and rights.
  croi_info_handle_extended_t *handles = (croi_info_handle_extended_t *)scratch;
  found = 0;
  CHECK(521, via_handle == 1 && via_mapping == 1 &&
                 get_info(s->process, CROI_INFO_HANDLE_TABLE, handles, 16 * PAGE, counts) == 0 && counts[1] >= 4);
  for (uint64_t i = 0; i < counts[0]; i++) {
    found |= handles[i].handle_value == vmo && handles[i].koid == koid_of(vmo) && handles[i].type == 3;
  }
  CHECK(522, found);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, 2 * PAGE, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, scratch, 16 * PAGE, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, scratch_vmo, 0, 0, 0, 0);
  return 0;
}

// K13f: clock objects. A clock's value at reference time r from its
// mapped page's transform (small spans only: plain 64-bit math).
static int64_t clock_at(const croi_clock_transformation_t *t, int64_t r) {
  if (t->rate.synthetic_ticks == 0) return t->synthetic_offset;
  int64_t d = r - t->reference_offset;
  return t->synthetic_offset + d * (int64_t)t->rate.synthetic_ticks / (int64_t)t->rate.reference_ticks;
}

static int64_t clocks(const startup_t *s) {
  uint32_t clock = 0, other = 0, port = 0, timer = 0;
  int64_t now = 0;
  croi_clock_create_args_v1_t create = {1000};
  croi_clock_details_v1_t d;
  croi_clock_update_args_v1_t up = {0, {0}, 0, 0};
  // Refusals at creation; a fresh clock reads its backstop until started.
  CHECK(530, sys(CROI_SYS_CLOCK_CREATE, 1u << 5, 0, (uint64_t)&clock, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_CLOCK_CREATE, CROI_CLOCK_OPT_CONTINUOUS, 0, (uint64_t)&clock, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_CLOCK_CREATE, 0, (uint64_t)&create, (uint64_t)&clock, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_CLOCK_CREATE, CROI_CLOCK_ARGS_VERSION(1) | CROI_CLOCK_OPT_MONOTONIC | CROI_CLOCK_OPT_MAPPABLE,
                     (uint64_t)&create, (uint64_t)&clock, 0, 0) == 0 &&
                 sys(CROI_SYS_CLOCK_READ, clock, (uint64_t)&now, 0, 0, 0) == 0 && now == 1000 &&
                 !(wait_for(clock, CROI_CLOCK_STARTED, 0) & CROI_CLOCK_STARTED) &&
                 sys(CROI_SYS_CLOCK_GET_DETAILS, clock, CROI_CLOCK_ARGS_VERSION(1), (uint64_t)&d, 0, 0) == 0 &&
                 d.generation_counter == 1 && d.backstop_time == 1000 && d.error_bound == CROI_CLOCK_UNKNOWN_ERROR &&
                 sys(CROI_SYS_CLOCK_GET_DETAILS, clock, 0, (uint64_t)&d, 0, 0) == ERR_INVALID_ARGS);
  // Starting: a rate alone is BAD_STATE; a value starts it (STARTED, and
  // an UPDATED pulse an async wait sees); backwards and below the backstop
  // refused; rates within +-1000 ppm.
  up.rate_adjust = 10;
  CHECK(531, sys(CROI_SYS_CLOCK_UPDATE, clock, CROI_CLOCK_ARGS_VERSION(1) | CROI_CLOCK_UPDATE_OPTION_RATE_ADJUST_VALID,
                 (uint64_t)&up, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ASYNC, clock, port, 9, CROI_CLOCK_UPDATED, 0) == 0);
  up.value = 5000000000ll;
  croi_port_packet_t packet;
  CHECK(532, sys(CROI_SYS_CLOCK_UPDATE, clock, CROI_CLOCK_ARGS_VERSION(1) | CROI_CLOCK_UPDATE_OPTION_VALUE_VALID,
                 (uint64_t)&up, 0, 0) == 0 &&
                 (wait_for(clock, CROI_CLOCK_STARTED, 0) & CROI_CLOCK_STARTED) &&
                 !(wait_for(clock, CROI_CLOCK_UPDATED, 0) & CROI_CLOCK_UPDATED) &&
                 sys(CROI_SYS_PORT_WAIT, port, 0, (uint64_t)&packet, 0, 0) == 0 && packet.key == 9 &&
                 sys(CROI_SYS_CLOCK_READ, clock, (uint64_t)&now, 0, 0, 0) == 0 && now >= 5000000000ll &&
                 now < 5000000000ll + 1000000000ll);
  up.value = 4000000000ll;
  CHECK(533, sys(CROI_SYS_CLOCK_UPDATE, clock, CROI_CLOCK_ARGS_VERSION(1) | CROI_CLOCK_UPDATE_OPTION_VALUE_VALID,
                 (uint64_t)&up, 0, 0) == ERR_INVALID_ARGS);
  up.rate_adjust = 2000;
  CHECK(534, sys(CROI_SYS_CLOCK_UPDATE, clock, CROI_CLOCK_ARGS_VERSION(1) | CROI_CLOCK_UPDATE_OPTION_RATE_ADJUST_VALID,
                 (uint64_t)&up, 0, 0) == ERR_INVALID_ARGS);
  up.rate_adjust = 500;
  up.error_bound = 77;
  CHECK(535, sys(CROI_SYS_CLOCK_UPDATE, clock,
                 CROI_CLOCK_ARGS_VERSION(1) | CROI_CLOCK_UPDATE_OPTION_RATE_ADJUST_VALID | CROI_CLOCK_UPDATE_OPTION_ERROR_BOUND_VALID,
                 (uint64_t)&up, 0, 0) == 0 &&
                 sys(CROI_SYS_CLOCK_GET_DETAILS, clock, CROI_CLOCK_ARGS_VERSION(1), (uint64_t)&d, 0, 0) == 0 &&
                 d.generation_counter == 3 && d.error_bound == 77 &&
                 d.reference_to_synthetic.rate.synthetic_ticks == 1000500 &&
                 d.reference_to_synthetic.rate.reference_ticks == 1000000);
  // Mapped: the page agrees with the details and with clock_read.
  uint64_t at = 0, size = 0, counts[2] = {0, 0};
  CHECK(536, sys6(CROI_SYS_VMAR_MAP_CLOCK, s->vmar, CROI_VM_PERM_READ | CROI_VM_PERM_WRITE, 0, clock, PAGE,
                  (uint64_t)&at) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_VMAR_MAP_CLOCK, s->vmar, CROI_VM_PERM_READ, 0, clock, 2 * PAGE, (uint64_t)&at) ==
                     ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_VMAR_MAP_CLOCK, s->vmar, CROI_VM_PERM_READ, 0, clock, PAGE, (uint64_t)&at) == 0 &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, clock, CROI_INFO_CLOCK_MAPPED_SIZE, (uint64_t)&size, 8,
                      (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 && size == PAGE);
  const volatile croi_clock_page_t *page = (const volatile croi_clock_page_t *)at;
  croi_clock_transformation_t t;
  uint32_t seq;
  do {
    seq = page->seq_lock;
    t.reference_offset = page->reference_ticks_to_synthetic.reference_offset;
    t.synthetic_offset = page->reference_ticks_to_synthetic.synthetic_offset;
    t.rate.synthetic_ticks = page->reference_ticks_to_synthetic.rate.synthetic_ticks;
    t.rate.reference_ticks = page->reference_ticks_to_synthetic.rate.reference_ticks;
  } while ((seq & 1) || seq != page->seq_lock);
  int64_t mapped = clock_at(&t, (int64_t)now_ns());
  CHECK(537, sys(CROI_SYS_CLOCK_READ, clock, (uint64_t)&now, 0, 0, 0) == 0 && seq == 6 && page->backstop_time == 1000 &&
                 page->error_bound == 77 && page->cur_ppm_adj == 500 && now >= mapped && now - mapped < 100000000);
  // AUTO_START: running from creation; CONTINUOUS: no jumps once started;
  // not mappable: INVALID_ARGS for vmar_map_clock; names; BOOT timers.
  create.backstop_time = 0;
  CHECK(538, sys(CROI_SYS_CLOCK_CREATE, CROI_CLOCK_OPT_MONOTONIC | CROI_CLOCK_OPT_CONTINUOUS | CROI_CLOCK_OPT_AUTO_START,
                 0, (uint64_t)&other, 0, 0) == 0 &&
                 (wait_for(other, CROI_CLOCK_STARTED, 0) & CROI_CLOCK_STARTED) &&
                 sys(CROI_SYS_CLOCK_READ, other, (uint64_t)&now, 0, 0, 0) == 0 &&
                 now <= (int64_t)now_ns() && (int64_t)now_ns() - now < 100000000 &&
                 sys(CROI_SYS_CLOCK_UPDATE, other, CROI_CLOCK_ARGS_VERSION(1) | CROI_CLOCK_UPDATE_OPTION_VALUE_VALID,
                     (uint64_t)&up, 0, 0) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_VMAR_MAP_CLOCK, s->vmar, CROI_VM_PERM_READ, 0, other, PAGE, (uint64_t)&size) ==
                     ERR_INVALID_ARGS &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, other, CROI_PROP_NAME, (uint64_t)"utc", 3, 0) == 0 &&
                 sys(CROI_SYS_TIMER_CREATE, 0, 1, (uint64_t)&timer, 0, 0) == 0 &&
                 sys(CROI_SYS_TIMER_CREATE, 0, 2, (uint64_t)&size, 0, 0) == ERR_INVALID_ARGS);
  create.backstop_time = (int64_t)now_ns() + 1000000000000ll;
  CHECK(539, sys(CROI_SYS_CLOCK_CREATE, CROI_CLOCK_ARGS_VERSION(1) | CROI_CLOCK_OPT_AUTO_START, (uint64_t)&create,
                 (uint64_t)&size, 0, 0) == ERR_INVALID_ARGS);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, PAGE, 0, 0);
  uint32_t rest[4] = {clock, other, port, timer};
  sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)rest, 4, 0, 0, 0);
  return 0;
}

// K13g: debugging. A thread that counts, to be suspended and resumed.
static void counting(uint64_t arg) {
  volatile uint64_t *count = (volatile uint64_t *)arg;
  for (;;) *count += 1;
}

static int64_t debugging(const startup_t *s) {
  // A running thread: suspended (SUSPENDED, its count stops, registers
  // readable, state SUSPENDED), then resumed by closing the token.
  volatile uint64_t count = 0;
  uint32_t worker = start_thread(s, counting, (uint64_t)&count);
  uint32_t token = 0;
  uint64_t give_up = now_ns() + 2000000000ull;
  while (count == 0 && now_ns() < give_up) {
  }
  croi_thread_state_general_regs_t regs;
  croi_info_thread_t thread;
  uint64_t counts[2];
  CHECK(540, sys(CROI_SYS_THREAD_READ_STATE, worker, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) ==
                 ERR_BAD_STATE &&
                 sys(CROI_SYS_TASK_SUSPEND, s->process, (uint64_t)&token, 0, 0, 0) == ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_TASK_SUSPEND, worker, (uint64_t)&token, 0, 0, 0) == 0 &&
                 (wait_for(worker, CROI_THREAD_SUSPENDED, 2000000000ull) & CROI_THREAD_SUSPENDED));
  uint64_t frozen = count;
  sys(CROI_SYS_NANOSLEEP, now_ns() + 20000000ull, 0, 0, 0, 0);
  CHECK(541, count == frozen &&
                 sys(CROI_SYS_THREAD_READ_STATE, worker, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) == 0 &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, worker, CROI_INFO_THREAD, (uint64_t)&thread, sizeof thread,
                      (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
                 thread.state == CROI_THREAD_STATE_SUSPENDED &&
                 sys(CROI_SYS_HANDLE_CLOSE, token, 0, 0, 0, 0) == 0 &&
                 (wait_for(worker, CROI_THREAD_RUNNING, 2000000000ull) & CROI_THREAD_RUNNING));
  give_up = now_ns() + 2000000000ull;
  while (count == frozen && now_ns() < give_up) {
  }
  CHECK(542, count != frozen && sys(CROI_SYS_TASK_KILL, worker, 0, 0, 0, 0) == 0);
  join(worker);
  // A thread blocked in port_wait: suspended (the wait ends and is made
  // again once resumed), then it still gets the packet.
  uint32_t port = 0;
  CHECK(543, sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0);
  uint32_t sleeper = start_thread(s, port_sleeper, port);
  give_up = now_ns() + 2000000000ull;
  do {
    sys6(CROI_SYS_OBJECT_GET_INFO, sleeper, CROI_INFO_THREAD, (uint64_t)&thread, sizeof thread, (uint64_t)&counts[0],
         (uint64_t)&counts[1]);
  } while (thread.state != CROI_THREAD_STATE_BLOCKED_PORT && now_ns() < give_up);
  CHECK(544, thread.state == CROI_THREAD_STATE_BLOCKED_PORT &&
                 sys(CROI_SYS_TASK_SUSPEND, sleeper, (uint64_t)&token, 0, 0, 0) == 0 &&
                 (wait_for(sleeper, CROI_THREAD_SUSPENDED, 2000000000ull) & CROI_THREAD_SUSPENDED) &&
                 sys(CROI_SYS_HANDLE_CLOSE, token, 0, 0, 0, 0) == 0);
  give_up = now_ns() + 2000000000ull;
  do {
    sys6(CROI_SYS_OBJECT_GET_INFO, sleeper, CROI_INFO_THREAD, (uint64_t)&thread, sizeof thread, (uint64_t)&counts[0],
         (uint64_t)&counts[1]);
  } while (thread.state != CROI_THREAD_STATE_BLOCKED_PORT && now_ns() < give_up);
  croi_port_packet_t wake = {0};
  CHECK(545, thread.state == CROI_THREAD_STATE_BLOCKED_PORT &&
                 sys(CROI_SYS_PORT_QUEUE, port, (uint64_t)&wake, 0, 0, 0) == 0 &&
                 (wait_for(sleeper, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull) & CROI_SIGNAL_TASK_TERMINATED));
  sys(CROI_SYS_HANDLE_CLOSE, sleeper, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, port, 0, 0, 0, 0);
  // Memory: read our own; an unmapped address NOT_FOUND; a write into a
  // read-only mapping lands in a private copy (the VMO keeps its bytes).
  uint64_t secret = 0x5EC12E7, got = 0, actual = 0, at = 0;
  uint32_t vmo = 0;
  char byte = 0;
  CHECK(546, sys(CROI_SYS_PROCESS_READ_MEMORY, s->process, (uint64_t)&secret, (uint64_t)&got, 8, (uint64_t)&actual) == 0 &&
                 got == secret && actual == 8 &&
                 sys(CROI_SYS_PROCESS_READ_MEMORY, s->process, 0x10, (uint64_t)&got, 8, 0) == ERR_NOT_FOUND &&
                 sys(CROI_SYS_PROCESS_READ_MEMORY, s->process, (uint64_t)&secret, (uint64_t)&got, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)"A", 0, 1, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, vmo, 0, PAGE, (uint64_t)&at) == 0 &&
                 sys(CROI_SYS_PROCESS_WRITE_MEMORY, s->process, at, (uint64_t)"B", 1, (uint64_t)&actual) == 0 &&
                 actual == 1 && *(volatile char *)at == 'B' &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)&byte, 0, 1, 0) == 0 && byte == 'A');
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, PAGE, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  return 0;
}

// K13g part 2: a debugger channel on our own process. A thread that hits
// a breakpoint.
static void breaker(uint64_t arg) {
  (void)arg;
#if defined(__x86_64__)
  __asm__ volatile("int3");
#elif defined(__aarch64__)
  __asm__ volatile("brk #0");
#else
  __asm__ volatile(".4byte 0x00100073");  // ebreak (uncompressed)
#endif
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static void quiet(uint64_t arg) {
  (void)arg;
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// The next exception on `channel`: its type, thread koid and handle.
static int next_exception(uint32_t channel, croi_exception_info_t *info, uint32_t *exception) {
  uint32_t actual[2];
  if (!(wait_for(channel, CROI_SIGNAL_READABLE, 3000000000ull) & CROI_SIGNAL_READABLE)) return 0;
  return chan_read(channel, info, exception, sizeof *info, 1, actual) == 0 && actual[1] == 1;
}

// The checks, with the debugger channel made (`channel`, our own
// process's), which the caller closes. (A failed CHECK exits the process,
// whose exit doesn't wait for its debugger: K13g's exitProcess.)
static int64_t debugger_checks(const startup_t *s, uint32_t *channel_out);

static int64_t debugger(const startup_t *s) {
  uint32_t channel = 0;
  int64_t result = debugger_checks(s, &channel);
  if (channel != 0) sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);
  return result;
}

static int64_t debugger_checks(const startup_t *s, uint32_t *channel_out) {
  uint32_t channel = 0, second = 0, exception = 0, job = 0, jobchannel = 0;
  croi_exception_info_t info;
  croi_info_process_t process;
  uint64_t counts[2];
  CHECK(550, sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, s->process, 2, (uint64_t)&channel, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, s->process, CROI_EXCEPTION_CHANNEL_DEBUGGER, (uint64_t)&channel,
                     0, 0) == 0 && (*channel_out = channel) &&
                 sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, s->process, CROI_EXCEPTION_CHANNEL_DEBUGGER, (uint64_t)&second,
                     0, 0) == ERR_ALREADY_BOUND &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, s->process, CROI_INFO_PROCESS, (uint64_t)&process, sizeof process,
                      (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
                 (process.flags & CROI_INFO_PROCESS_FLAG_DEBUGGER_ATTACHED));
  // A thread starting: THREAD_STARTING, its entry registers readable, the
  // report's type; then exiting: THREAD_EXITING, no registers.
  uint32_t thread = start_thread(s, quiet, 0);
  croi_thread_state_general_regs_t regs;
  croi_exception_report_t report;
  croi_info_thread_t state;
  uint32_t handled = CROI_EXCEPTION_STATE_HANDLED;
  CHECK(551, next_exception(channel, &info, &exception) && info.type == CROI_EXCP_THREAD_STARTING &&
                 info.tid == koid_of(thread) &&
                 sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) == 0 &&
#if defined(__x86_64__)
                 regs.rip == (uint64_t)quiet &&
#elif defined(__aarch64__)
                 regs.pc == (uint64_t)quiet &&
#else
                 regs.pc == (uint64_t)quiet &&
#endif
                 sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD_EXCEPTION_REPORT, (uint64_t)&report, sizeof report,
                      (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
                 report.header.type == CROI_EXCP_THREAD_STARTING && report.header.size == sizeof report &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD, (uint64_t)&state, sizeof state, (uint64_t)&counts[0],
                      (uint64_t)&counts[1]) == 0 &&
                 state.state == CROI_THREAD_STATE_BLOCKED_EXCEPTION &&
                 state.wait_exception_channel_type == CROI_EXCEPTION_CHANNEL_TYPE_DEBUGGER &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&handled, 4, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0);
  CHECK(552, next_exception(channel, &info, &exception) && info.type == CROI_EXCP_THREAD_EXITING &&
                 sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) ==
                     ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0);
  join(thread);
  // A breakpoint: the debugger first (the report's arch part); it asks
  // for a second chance and gets it back after the thread's and process's
  // turns (no channels), then ends the thread.
  uint32_t second_chance = CROI_EXCEPTION_STRATEGY_SECOND_CHANCE, exit_state = CROI_EXCEPTION_STATE_THREAD_EXIT;
  thread = start_thread(s, breaker, 0);
  CHECK(553, next_exception(channel, &info, &exception) && info.type == CROI_EXCP_THREAD_STARTING &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&handled, 4, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0 &&
                 next_exception(channel, &info, &exception) && info.type == CROI_EXCP_SW_BREAKPOINT &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD_EXCEPTION_REPORT, (uint64_t)&report, sizeof report,
                      (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
#if defined(__x86_64__)
                 report.context.arch.vector == 3 &&
#elif defined(__aarch64__)
                 (report.context.arch.esr >> 26) == 0x3C &&
#else
                 report.context.arch.cause == 3 &&
#endif
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STRATEGY, (uint64_t)&second_chance, 4, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0 &&
                 next_exception(channel, &info, &exception) && info.type == CROI_EXCP_SW_BREAKPOINT &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&exit_state, 4, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0 &&
                 next_exception(channel, &info, &exception) && info.type == CROI_EXCP_THREAD_EXITING &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0);
  join(thread);
  // Refusals: a thread can't have a debugger channel; jobs take several.
  CHECK(554, sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, s->vmar, 0, (uint64_t)&second, 0, 0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&job, 0, 0) == 0 &&
                 sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, job, CROI_EXCEPTION_CHANNEL_DEBUGGER, (uint64_t)&jobchannel, 0, 0) == 0 &&
                 sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, job, CROI_EXCEPTION_CHANNEL_DEBUGGER, (uint64_t)&second, 0, 0) == 0);
  croi_info_job_t jinfo;
  CHECK(555, sys6(CROI_SYS_OBJECT_GET_INFO, job, CROI_INFO_JOB, (uint64_t)&jinfo, sizeof jinfo, (uint64_t)&counts[0],
                  (uint64_t)&counts[1]) == 0 && jinfo.debugger_attached == 1 &&
                 sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0) == 0 && (*channel_out = 0, 1) &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, s->process, CROI_INFO_PROCESS, (uint64_t)&process, sizeof process,
                      (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
                 !(process.flags & CROI_INFO_PROCESS_FLAG_DEBUGGER_ATTACHED));
  uint32_t rest[3] = {jobchannel, second, job};
  sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)rest, 3, 0, 0, 0);
  return 0;
}

// K13g part 3: single-step and a hardware breakpoint, from a software
// breakpoint the debugger catches (whose frame is the thread's own).
static void __attribute__((noinline)) watched_call(void) {
  __asm__ volatile("");
}

static void stepper(uint64_t arg) {
  (void)arg;
#if defined(__x86_64__)
  __asm__ volatile("int3; nop; nop; nop");
#elif defined(__aarch64__)
  __asm__ volatile("brk #0; nop; nop; nop");
#else
  __asm__ volatile(".4byte 0x00100073; nop; nop; nop");
#endif
  watched_call();
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t stepping_checks(const startup_t *s, uint32_t *channel_out);

static int64_t stepping(const startup_t *s) {
  uint32_t channel = 0;
  int64_t result = stepping_checks(s, &channel);
  if (channel != 0) sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);
  return result;
}

static int resume(uint32_t exception) {
  uint32_t handled = CROI_EXCEPTION_STATE_HANDLED;
  return sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&handled, 4, 0) == 0 &&
         sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0;
}

static int64_t stepping_checks(const startup_t *s, uint32_t *channel_out) {
  uint32_t channel = 0, exception = 0, on = 1, off = 0;
  croi_exception_info_t info;
  croi_thread_state_general_regs_t regs;
  croi_thread_state_debug_regs_t debug_regs;
  CHECK(560, sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, s->process, CROI_EXCEPTION_CHANNEL_DEBUGGER, (uint64_t)&channel,
                 0, 0) == 0 && (*channel_out = channel));
  uint32_t thread = start_thread(s, stepper, 0);
  CHECK(561, next_exception(channel, &info, &exception) && info.type == CROI_EXCP_THREAD_STARTING && resume(exception) &&
                 next_exception(channel, &info, &exception) && info.type == CROI_EXCP_SW_BREAKPOINT &&
                 sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) == 0);
#if defined(__x86_64__)
  uint64_t after = regs.rip;  // past the int3
#else
  regs.pc += 4;  // past brk / ebreak
  uint64_t after = regs.pc;
  CHECK(562, sys(CROI_SYS_THREAD_WRITE_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) == 0);
#endif
  for (unsigned i = 0; i < sizeof debug_regs; i++) ((volatile char *)&debug_regs)[i] = 0;
#if defined(__x86_64__)
  debug_regs.dr[0] = (uint64_t)watched_call;
  debug_regs.dr7 = 1;  // L0, execute, one byte
#elif defined(__aarch64__)
  debug_regs.hw_bps[0].dbgbcr = 1;
  debug_regs.hw_bps[0].dbgbvr = (uint64_t)watched_call;
#endif
#if defined(__x86_64__) || defined(__aarch64__)
  CHECK(563, sys(CROI_SYS_THREAD_WRITE_STATE, thread, CROI_THREAD_STATE_SINGLE_STEP, (uint64_t)&on, 4, 0) == 0 &&
                 sys(CROI_SYS_THREAD_WRITE_STATE, thread, CROI_THREAD_STATE_DEBUG_REGS, (uint64_t)&debug_regs,
                     sizeof debug_regs, 0) == 0 &&
                 resume(exception) &&
                 next_exception(channel, &info, &exception) && info.type == CROI_EXCP_HW_BREAKPOINT &&
                 sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) == 0);
#if defined(__x86_64__)
  CHECK(564, regs.rip == after + 1 &&  // one nop
                 sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_DEBUG_REGS, (uint64_t)&debug_regs, sizeof debug_regs,
                     0) == 0 && (debug_regs.dr6 & (1u << 14)));  // BS
#else
  CHECK(564, regs.pc == after + 4);
#endif
  CHECK(565, sys(CROI_SYS_THREAD_WRITE_STATE, thread, CROI_THREAD_STATE_SINGLE_STEP, (uint64_t)&off, 4, 0) == 0 &&
                 resume(exception) &&
                 next_exception(channel, &info, &exception) && info.type == CROI_EXCP_HW_BREAKPOINT &&
                 sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) == 0 &&
                 sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_DEBUG_REGS, (uint64_t)&debug_regs, sizeof debug_regs,
                     0) == 0);
#if defined(__x86_64__)
  CHECK(566, regs.rip == (uint64_t)watched_call && (debug_regs.dr6 & 1u));  // B0
#else
  CHECK(566, regs.pc == (uint64_t)watched_call && debug_regs.hw_bps_count >= 1);
#endif
  for (unsigned i = 0; i < sizeof debug_regs; i++) ((volatile char *)&debug_regs)[i] = 0;
  CHECK(567, sys(CROI_SYS_THREAD_WRITE_STATE, thread, CROI_THREAD_STATE_DEBUG_REGS, (uint64_t)&debug_regs,
                 sizeof debug_regs, 0) == 0 && resume(exception));
#else
  CHECK(563, sys(CROI_SYS_THREAD_WRITE_STATE, thread, CROI_THREAD_STATE_SINGLE_STEP, (uint64_t)&on, 4, 0) ==
                 ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_THREAD_WRITE_STATE, thread, CROI_THREAD_STATE_DEBUG_REGS, (uint64_t)&debug_regs,
                     sizeof debug_regs, 0) == 0 &&
                 resume(exception));
  (void)after;
  (void)off;
#endif
  CHECK(568, next_exception(channel, &info, &exception) && info.type == CROI_EXCP_THREAD_EXITING &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0);
  join(thread);
  return 0;
}

// K13h: resizable VMOs.
static int64_t resizing(const startup_t *s) {
  uint32_t vmo = 0, plain = 0, weak = 0, child = 0, fixed = 0;
  uint64_t size = 0, at = 0, counts[2];
  croi_info_handle_basic_t basic;
  croi_info_vmo_t info;
  char byte = 1;
  // Created resizable: RESIZE on its handle, the info flag, the content
  // size the unaligned size; refusals.
  CHECK(570, sys(CROI_SYS_VMO_CREATE, 2 * PAGE + 100, CROI_VMO_CREATE_RESIZABLE | CROI_VMO_CREATE_UNBOUNDED,
                 (uint64_t)&vmo, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMO_CREATE, 2 * PAGE + 100, CROI_VMO_CREATE_RESIZABLE, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_INFO, vmo, CROI_INFO_HANDLE_BASIC, (uint64_t)&basic, sizeof basic, 0) == 0 &&
                 (basic.rights & CROI_RIGHT_RESIZE) &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, vmo, CROI_INFO_VMO, (uint64_t)&info, sizeof info, (uint64_t)&counts[0],
                      (uint64_t)&counts[1]) == 0 && (info.flags & CROI_INFO_VMO_RESIZABLE) && info.size_bytes == 3 * PAGE &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == 2 * PAGE + 100 &&
                 sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&plain, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_SIZE, plain, 2 * PAGE, 0, 0, 0) == ERR_UNAVAILABLE &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, vmo, RIGHT_READ | (1u << 3) | RIGHT_DUPLICATE, (uint64_t)&weak, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_SIZE, weak, PAGE, 0, 0, 0) == ERR_ACCESS_DENIED);
  // Mapped past its end; shrunk to 10 bytes (the tail zeroed, reads past
  // the end OUT_OF_RANGE), then grown and written through the mapping.
  CHECK(571, sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, vmo, 0,
                  4 * PAGE, (uint64_t)&at) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_REQUIRE_NON_RESIZABLE) << 32, 0,
                      vmo, 0, PAGE, (uint64_t)&size) == ERR_NOT_SUPPORTED);
  ((volatile char *)at)[20] = 'x';
  ((volatile char *)at)[PAGE] = 'y';
  CHECK(572, sys(CROI_SYS_VMO_SET_SIZE, vmo, 10, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_GET_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == PAGE &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == 10 &&
                 ((volatile char *)at)[20] == 0 &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)&byte, PAGE, 1, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_VMO_SET_SIZE, vmo, 3 * PAGE, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)&byte, PAGE, 1, 0) == 0 && byte == 0);
  ((volatile char *)at)[2 * PAGE] = 'z';
  CHECK(573, sys(CROI_SYS_VMO_READ, vmo, (uint64_t)&byte, 2 * PAGE, 1, 0) == 0 && byte == 'z');
  // Children: resizable only when asked for.
  CHECK(574, sys6(CROI_SYS_VMO_CREATE_CHILD, vmo, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE | CROI_VMO_CHILD_RESIZABLE, 0,
                  PAGE, (uint64_t)&child, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_SIZE, child, 4 * PAGE, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, child, 0, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_CREATE_CHILD, vmo, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 0, PAGE, (uint64_t)&child,
                      0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_INFO, child, CROI_INFO_HANDLE_BASIC, (uint64_t)&basic, sizeof basic, 0) == 0 &&
                 !(basic.rights & CROI_RIGHT_RESIZE) &&
                 sys(CROI_SYS_VMO_SET_SIZE, child, 2 * PAGE, 0, 0, 0) == ERR_UNAVAILABLE);
  // A resizable pager VMO grows into zeros nobody is asked for, reported
  // as a dirty zero range until written back.
  uint32_t pg = 0, port = 0, paged = 0;
  croi_vmo_dirty_range_t ranges[4];
  CHECK(575, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&pg, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, CROI_VMO_CREATE_RESIZABLE, port, 1, PAGE, (uint64_t)&paged) == 0 &&
                 sys(CROI_SYS_VMO_SET_SIZE, paged, 3 * PAGE, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)paged << 32, 0, 3 * PAGE, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[1] == 1 && ranges[0].offset == PAGE &&
                 ranges[0].length == 2 * PAGE && ranges[0].options == CROI_VMO_DIRTY_RANGE_IS_ZERO &&
                 sys(CROI_SYS_VMO_READ, paged, (uint64_t)&byte, 2 * PAGE, 1, 0) == 0 && byte == 0 &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_END, paged, PAGE, 2 * PAGE, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)paged << 32, 0, 3 * PAGE, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[1] == 1 && ranges[0].length == 2 * PAGE &&
                 // (K14k: the read committed nothing; END without BEGIN
                 // cleans nothing; BEGIN then END hands the zeros back.)
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_BEGIN, paged, PAGE, 2 * PAGE, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_END, paged, PAGE, 2 * PAGE, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)paged << 32, 0, 3 * PAGE, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[1] == 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, 4 * PAGE, 0, 0);
  uint32_t rest[8] = {vmo, plain, weak, child, fixed, pg, port, paged};
  sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)rest, 8, 0, 0, 0);
  return 0;
}

// K13i: smc_call. arm64: PSCI_VERSION through a one-function SMC resource
// (QEMU's PSCI answers through the FADT's conduit); a function outside it
// refused; the kernel's PSCI calls (CPU_OFF, SYSTEM_OFF) refused even to
// the root resource. Elsewhere NOT_SUPPORTED.
static int64_t smc(const startup_t *s) {
  croi_smc_parameters_t params;
  croi_smc_result_t result;
  for (unsigned i = 0; i < sizeof params; i++) ((volatile char *)&params)[i] = 0;
  params.func_id = 0x84000000u;  // PSCI_VERSION
  CHECK(580, sys(CROI_SYS_SMC_CALL, s->resource, 0, (uint64_t)&result, 0, 0) == ERR_INVALID_ARGS);
#if defined(__aarch64__)
  uint32_t one = 0, cpu_off = 0;
  CHECK(581, resource_create(s->resource, CROI_RSRC_KIND_SMC, 0x84000000u, 1, &one) == 0 &&
                 sys(CROI_SYS_SMC_CALL, one, (uint64_t)&params, (uint64_t)&result, 0, 0) == 0 &&
                 result.arg0 >= 2 && result.arg0 < 0x80000000u);
  params.func_id = 0x84000004u;  // AFFINITY_INFO: not this resource's
  CHECK(582, sys(CROI_SYS_SMC_CALL, one, (uint64_t)&params, (uint64_t)&result, 0, 0) == ERR_OUT_OF_RANGE &&
                 resource_create(s->resource, CROI_RSRC_KIND_SMC, 0x84000002u, 1, &cpu_off) == ERR_ACCESS_DENIED);
  params.func_id = 0x84000008u;  // SYSTEM_OFF: the kernel's
  CHECK(583, sys(CROI_SYS_SMC_CALL, s->resource, (uint64_t)&params, (uint64_t)&result, 0, 0) == ERR_ACCESS_DENIED);
  sys(CROI_SYS_HANDLE_CLOSE, one, 0, 0, 0, 0);
#else
  CHECK(581, sys(CROI_SYS_SMC_CALL, s->resource, (uint64_t)&params, (uint64_t)&result, 0, 0) == ERR_NOT_SUPPORTED);
#endif
  return 0;
}

// Requirement 19's post-mortem freeze (Fuchsia's "Limbo", user space on
// Zircon's mechanisms): a crashed thread stays in its exception while the
// handler holds the exception handle; meanwhile its registers and the
// process's memory are read, and the handle moves over a channel to
// another holder (a debugger), the thread still frozen, until released.
static void crasher(uint64_t arg) {
  *(volatile uint64_t *)arg = 0xC0FFEE;  // in the caller's frame: no writable statics here
  *(volatile uint64_t *)0x10 = 1;  // a fatal page fault
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t postmortem_checks(const startup_t *s, uint32_t *channel_out);

static int64_t postmortem(const startup_t *s) {
  uint32_t channel = 0;
  int64_t result = postmortem_checks(s, &channel);
  if (channel != 0) sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);
  return result;
}

static int64_t postmortem_checks(const startup_t *s, uint32_t *channel_out) {
  uint32_t channel = 0, exception = 0, a = 0, b = 0, moved = 0, actual[2];
  croi_exception_info_t info;
  croi_thread_state_general_regs_t regs;
  croi_exception_report_t report;
  croi_info_thread_t state;
  uint64_t counts[2], marker = 0;
  volatile uint64_t crash_marker = 0;
  CHECK(590, sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, s->process, 0, (uint64_t)&channel, 0, 0) == 0 &&
                 (*channel_out = channel));
  uint32_t thread = start_thread(s, crasher, (uint64_t)&crash_marker);
  CHECK(591, next_exception(channel, &info, &exception) && info.type == CROI_EXCP_FATAL_PAGE_FAULT &&
                 sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs, 0) == 0 &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD_EXCEPTION_REPORT, (uint64_t)&report, sizeof report,
                      (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
#if defined(__x86_64__)
                 report.context.arch.cr2 == 0x10 &&
#elif defined(__aarch64__)
                 report.context.arch.far == 0x10 &&
#else
                 report.context.arch.tval == 0x10 &&
#endif
                 sys(CROI_SYS_PROCESS_READ_MEMORY, s->process, (uint64_t)&crash_marker, (uint64_t)&marker, 8, 0) == 0 &&
                 marker == 0xC0FFEE);
  // Handed to another holder: still frozen in its exception.
  CHECK(592, sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&a, (uint64_t)&b, 0, 0) == 0 &&
                 sys6(CROI_SYS_CHANNEL_WRITE, a, 0, (uint64_t)"pm", 2, (uint64_t)&exception, 1) == 0 &&
                 sys6(CROI_SYS_CHANNEL_READ, b, 0, (uint64_t)&marker, (uint64_t)&moved, 8 | (uint64_t)1 << 32,
                      (uint64_t)actual) == 0 && actual[1] == 1);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 20000000ull, 0, 0, 0, 0);
  uint32_t exit_state = CROI_EXCEPTION_STATE_THREAD_EXIT;
  CHECK(593, sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD, (uint64_t)&state, sizeof state, (uint64_t)&counts[0],
                  (uint64_t)&counts[1]) == 0 &&
                 state.state == CROI_THREAD_STATE_BLOCKED_EXCEPTION &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, moved, CROI_PROP_EXCEPTION_STATE, (uint64_t)&exit_state, 4, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, moved, 0, 0, 0, 0) == 0 &&
                 (wait_for(thread, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull) & CROI_SIGNAL_TASK_TERMINATED));
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, a, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, b, 0, 0, 0, 0);
  return 0;
}

// Todhchai's report (2026-10-11): a contended futex lock whose waits carry
// a far-future finite deadline (INT64_MAX >> 1) must behave like one
// waiting forever. Drepper's mutex (0 free, 1 locked, 2 contended).
typedef struct {
  volatile uint32_t word;
  volatile uint64_t counter;
  uint64_t deadline;
  uint64_t rounds;
} futex_lock_t;

static void futex_lock(futex_lock_t *l) {
  uint32_t c = 0;
  if (__atomic_compare_exchange_n(&l->word, &c, 1, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) return;
  if (c != 2) c = __atomic_exchange_n(&l->word, 2, __ATOMIC_ACQUIRE);
  while (c != 0) {
    sys(CROI_SYS_FUTEX_WAIT, (uint64_t)&l->word, 2, 0, l->deadline, 0);
    c = __atomic_exchange_n(&l->word, 2, __ATOMIC_ACQUIRE);
  }
}

static void futex_unlock(futex_lock_t *l) {
  if (__atomic_fetch_sub(&l->word, 1, __ATOMIC_RELEASE) != 1) {
    __atomic_store_n(&l->word, 0, __ATOMIC_RELEASE);
    sys(CROI_SYS_FUTEX_WAKE, (uint64_t)&l->word, 1, 0, 0, 0);
  }
}

static void futex_locker(uint64_t arg) {
  futex_lock_t *l = (futex_lock_t *)arg;
  for (uint64_t i = 0; i < l->rounds; i++) {
    futex_lock(l);
    l->counter = l->counter + 1;
    futex_unlock(l);
  }
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static uint64_t contended_futex(const startup_t *s, uint64_t deadline) {
  futex_lock_t l = {0, 0, deadline, 2000};
  uint32_t threads[4];
  uint64_t start = now_ns();
  for (int i = 0; i < 4; i++) threads[i] = start_thread(s, futex_locker, (uint64_t)&l);
  for (int i = 0; i < 4; i++) {
    wait_for(threads[i], CROI_SIGNAL_TASK_TERMINATED, 60000000000ull);
    sys(CROI_SYS_HANDLE_CLOSE, threads[i], 0, 0, 0, 0);
  }
  return l.counter == 4 * 2000 ? now_ns() - start : ~0ull;
}

static int64_t futex_deadlines(const startup_t *s) {
  // The lock works with waits that never time out and with ones 146 years
  // out (under KVM the latter once took ~2000x longer: the kernel's time
  // self-test checks the cause, a hardware timer armed past what KVM can
  // convert).
  CHECK(620, contended_futex(s, 0x7FFFFFFFFFFFFFFFull) != ~0ull &&
                 contended_futex(s, 0x7FFFFFFFFFFFFFFFull >> 1) != ~0ull);
  return 0;
}

// K14f: page loaning. A contiguous VMO's decommitted pages are lent (free
// loaned memory grows by them, the VMO's committed bytes shrink); a
// mapping over them faults them back, COMMIT takes them back, both zeroed,
// and the VMO's end takes back what it lent. Slices refuse lent pages.
static uint64_t committed_of(uint32_t vmo, uint64_t *events);
static int64_t reclaim_hook(uint64_t op, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e);

static int kmem_loaned(const startup_t *s, uint64_t *loaned) {
  croi_info_kmem_stats_t k;
  uint64_t counts[2];
  if (get_info(s->resource, CROI_INFO_KMEM_STATS, &k, sizeof k, counts) != 0) return 0;
  *loaned = k.free_loaned_bytes;
  return 1;
}

static int64_t page_loaning(const startup_t *s) {
  uint32_t iommu = 0, bti = 0, vmo = 0, slice = 0;
  uint8_t desc = 0;
  uint64_t before = 0, created = 0, lent = 0, now = 0;
  CHECK(636, kmem_loaned(s, &before) &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, CROI_IOMMU_TYPE_STUB, (uint64_t)&desc, 1, (uint64_t)&iommu) == 0 &&
                 sys(CROI_SYS_BTI_CREATE, iommu, 0, 0, (uint64_t)&bti, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, 4 * PAGE, 0, (uint64_t)&vmo, 0) == 0 && kmem_loaned(s, &created));
  char page[PAGE];
  for (int i = 0; i < 4; i++) {
    for (int j = 0; j < PAGE; j++) page[j] = (char)('A' + i);
    sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)page, (uint64_t)i * PAGE, PAGE, 0);
  }
  // Decommit lends pages 1 and 2; a slice can't be made over them, nor a
  // decommit done while one exists.
  CHECK(637, sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, PAGE, 2 * PAGE, 0, 0) == 0 &&
                 committed_of(vmo, 0) == 2 * PAGE && kmem_loaned(s, &lent) && lent == created + 2 * PAGE);
  CHECK(638, sys6(CROI_SYS_VMO_CREATE_CHILD, vmo, CROI_VMO_CHILD_SLICE, 0, PAGE, (uint64_t)&slice, 0) == ERR_BAD_STATE);
  // Mapped: the pages kept read as written; touching a lent one takes it
  // back, zeroed.
  uint64_t at = 0;
  CHECK(639, sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, vmo, 0,
                  4 * PAGE, (uint64_t)&at) == 0);
  volatile const char *m = (volatile const char *)at;
  CHECK(640, m[0] == 'A' && m[3 * PAGE + 7] == 'D' && m[PAGE + 9] == 0 && committed_of(vmo, 0) == 3 * PAGE &&
                 kmem_loaned(s, &now) && now == created + PAGE);
  // COMMIT takes the other back, zeroed; then all four are its own again.
  CHECK(641, sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_COMMIT, 2 * PAGE, PAGE, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)page, 2 * PAGE, PAGE, 0) == 0 && page[0] == 0 &&
                 page[PAGE - 1] == 0 && committed_of(vmo, 0) == 4 * PAGE && kmem_loaned(s, &now) && now == created);
  // With a slice, no decommit; without, lent again and closed while lent:
  // the pages come back to the VMO's end and to wherever it came from.
  CHECK(642, sys6(CROI_SYS_VMO_CREATE_CHILD, vmo, CROI_VMO_CHILD_SLICE, 0, PAGE, (uint64_t)&slice, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, 0, PAGE, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_HANDLE_CLOSE, slice, 0, 0, 0, 0) == 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, 4 * PAGE, 0, 0);
  CHECK(643, sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, 0, 4 * PAGE, 0, 0) == 0 &&
                 committed_of(vmo, 0) == 0 && sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0) == 0 &&
                 kmem_loaned(s, &now) && now == before);
  uint32_t handles[2] = {bti, iommu};
  sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)handles, 2, 0, 0, 0);
  return 0;
}

// K14f, part 2: borrowers. A pager VMO's clean pages move onto lent pages
// at an aging pass (lent memory goes down by them, contents kept); a
// write or a pin swaps one back to an ordinary page; the lender taking
// its pages back evicts the borrowers, whose pager supplies them again.
// With this the only pager VMO, its pages 0 and 1 borrow the contiguous
// VMO's two pages (the loaned list hands out the latest lent first).
static int64_t page_borrowing(const startup_t *s) {
  uint32_t pg = 0, port = 0, vmo = 0, aux = 0, iommu = 0, bti = 0, contig = 0, pmt = 0;
  uint8_t desc = 0;
  char page[PAGE];
  CHECK(644, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&pg, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, 0, port, 92, 4 * PAGE, (uint64_t)&vmo) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, 4 * PAGE, 0, (uint64_t)&aux, 0, 0) == 0 &&
                 sys(CROI_SYS_IOMMU_CREATE, s->resource, CROI_IOMMU_TYPE_STUB, (uint64_t)&desc, 1, (uint64_t)&iommu) == 0 &&
                 sys(CROI_SYS_BTI_CREATE, iommu, 0, 0, (uint64_t)&bti, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, 2 * PAGE, 0, (uint64_t)&contig, 0) == 0);
  for (uint64_t i = 0; i < 4; i++) {
    for (int j = 0; j < PAGE; j++) page[j] = (char)('p' + i);
    sys(CROI_SYS_VMO_WRITE, aux, (uint64_t)page, i * PAGE, PAGE, 0);
  }
  volatile uint64_t slot[8] = {port, pg, vmo, 0, 0, 0, 0, 92};
  uint64_t lent0 = 0, lent1 = 0, lent2 = 0, lent3 = 0;
  CHECK(645, sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, vmo, 0, 4 * PAGE, aux, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, contig, CROI_VMO_OP_DECOMMIT, 0, 2 * PAGE, 0, 0) == 0 &&
                 kmem_loaned(s, &lent0) && reclaim_hook(6, 1, 0, 0, 0, 0) == 0 && kmem_loaned(s, &lent1) &&
                 lent0 - lent1 == 4 * PAGE);
  uint32_t server = start_thread(s, pager_server, (uint64_t)slot);
  int intact = 1;
  for (uint64_t i = 0; i < 4; i++) {
    intact &= sys(CROI_SYS_VMO_READ, vmo, (uint64_t)page, i * PAGE, PAGE, 0) == 0 && page[0] == (char)('p' + i) &&
              page[PAGE - 1] == (char)('p' + i);
  }
  // Borrowed, the pages read as supplied; a write swaps page 2 back to an
  // ordinary page (its lent one free again).
  CHECK(646, intact && slot[3] == 0 && sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)"X", 2 * PAGE, 1, 0) == 0 &&
                 kmem_loaned(s, &lent2) && lent2 == lent1 + PAGE &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)page, 2 * PAGE, PAGE, 0) == 0 && page[0] == 'X' &&
                 page[1] == 'r');
  // The contiguous VMO takes its pages back: pages 0 and 1 are evicted
  // from the pager VMO, then asked of the pager again; page 3 stays.
  CHECK(647, sys6(CROI_SYS_VMO_OP_RANGE, contig, CROI_VMO_OP_COMMIT, 0, 2 * PAGE, 0, 0) == 0 &&
                 committed_of(contig, 0) == 2 * PAGE && committed_of(vmo, 0) == 2 * PAGE &&
                 kmem_loaned(s, &lent3) && lent3 == lent2 &&
                 sys(CROI_SYS_VMO_READ, contig, (uint64_t)page, PAGE, PAGE, 0) == 0 && page[0] == 0);
  CHECK(648, sys(CROI_SYS_VMO_READ, vmo, (uint64_t)page, 0, PAGE, 0) == 0 && page[0] == 'A' &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)page, PAGE, PAGE, 0) == 0 && page[0] == 'B' &&
                 slot[3] == 2 && sys(CROI_SYS_VMO_READ, vmo, (uint64_t)page, 3 * PAGE, PAGE, 0) == 0 && page[0] == 's');
  // A pin swaps the borrowed page 3 back first.
  uint64_t addr = 0;
  CHECK(649, bti_pin(bti, CROI_BTI_PERM_READ, vmo, 1, 3 * PAGE, PAGE, &addr, &pmt) == 0 && kmem_loaned(s, &lent0) &&
                 lent0 == lent3 + PAGE && sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_READ, vmo, (uint64_t)page, 3 * PAGE, PAGE, 0) == 0 && page[0] == 's');
  sys(CROI_SYS_PAGER_DETACH_VMO, pg, vmo, 0, 0, 0);
  wait_for(server, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull);
  uint32_t handles[] = {server, vmo, aux, port, pg, contig, bti, iommu};
  for (int i = 0; i < 8; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0;
}

// K14d: thread_raise_exception. ZX_EXCP_USER goes to each job debugger
// from the caller's job up, one after the other, the reply ignored; with
// none it returns at once.
typedef struct {
  uint32_t data;
  volatile int64_t result;
} raise_t;

static void raiser(uint64_t arg) {
  raise_t *r = (raise_t *)arg;
  croi_exception_context_t context = {};
  context.synth_code = CROI_EXCP_USER_CODE_USER0;
  context.synth_data = r->data;
  r->result = sys(CROI_SYS_THREAD_RAISE_EXCEPTION, CROI_EXCEPTION_TARGET_JOB_DEBUGGER, CROI_EXCP_USER,
                  (uint64_t)&context, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t user_exceptions(const startup_t *s) {
  croi_exception_context_t context = {};
  CHECK(623, sys(CROI_SYS_THREAD_RAISE_EXCEPTION, 0, CROI_EXCP_USER, (uint64_t)&context, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_THREAD_RAISE_EXCEPTION, CROI_EXCEPTION_TARGET_JOB_DEBUGGER, CROI_EXCP_THREAD_STARTING,
                     (uint64_t)&context, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_THREAD_RAISE_EXCEPTION, CROI_EXCEPTION_TARGET_JOB_DEBUGGER, CROI_EXCP_USER, 0, 0, 0) ==
                     ERR_INVALID_ARGS &&
                 sys(CROI_SYS_THREAD_RAISE_EXCEPTION, CROI_EXCEPTION_TARGET_JOB_DEBUGGER, CROI_EXCP_USER, 8, 0, 0) ==
                     ERR_INVALID_ARGS &&
                 sys(CROI_SYS_THREAD_RAISE_EXCEPTION, CROI_EXCEPTION_TARGET_JOB_DEBUGGER, CROI_EXCP_USER,
                     (uint64_t)&context, 0, 0) == 0);  // no debugger: nothing waits
  uint32_t first = 0, second = 0, exception = 0;
  croi_exception_info_t info;
  croi_exception_report_t report;
  croi_info_thread_t state;
  croi_thread_state_general_regs_t regs;
  uint64_t counts[2];
  uint32_t try_next = CROI_EXCEPTION_STATE_TRY_NEXT;
  CHECK(624, sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, s->job, CROI_EXCEPTION_CHANNEL_DEBUGGER, (uint64_t)&first,
                 0, 0) == 0 &&
                 sys(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, s->job, CROI_EXCEPTION_CHANNEL_DEBUGGER, (uint64_t)&second,
                     0, 0) == 0);
  raise_t raise = {42, -1};
  uint32_t thread = start_thread(s, raiser, (uint64_t)&raise);
  // The first debugger: the code and data in the report, the registers
  // readable, the thread blocked on a job debugger's channel.
  CHECK(625, next_exception(first, &info, &exception) && info.type == CROI_EXCP_USER && info.tid == koid_of(thread) &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD_EXCEPTION_REPORT, (uint64_t)&report,
                      sizeof report, (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
                 report.header.type == CROI_EXCP_USER && report.context.synth_code == CROI_EXCP_USER_CODE_USER0 &&
                 report.context.synth_data == 42 &&
                 sys(CROI_SYS_THREAD_READ_STATE, thread, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs,
                     0) == 0 &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD, (uint64_t)&state, sizeof state,
                      (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
                 state.state == CROI_THREAD_STATE_BLOCKED_EXCEPTION &&
                 state.wait_exception_channel_type == CROI_EXCEPTION_CHANNEL_TYPE_JOB_DEBUGGER &&
                 raise.result == -1 &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&try_next, 4, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0);
  // The second gets it next whatever the first replied; then the call
  // returns OK.
  CHECK(626, next_exception(second, &info, &exception) && info.type == CROI_EXCP_USER &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0);
  join(thread);
  uint32_t channels[2] = {first, second};
  croi_info_job_t job;
  // Closed, they no longer count as attached, and the next raise prunes
  // their kernel ends from our job (else they would outlive the test).
  CHECK(627, raise.result == 0 && sys(CROI_SYS_HANDLE_CLOSE_MANY, (uint64_t)channels, 2, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_THREAD_RAISE_EXCEPTION, CROI_EXCEPTION_TARGET_JOB_DEBUGGER, CROI_EXCP_USER,
                     (uint64_t)&context, 0, 0) == 0 &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, s->job, CROI_INFO_JOB, (uint64_t)&job, sizeof job, (uint64_t)&counts[0],
                      (uint64_t)&counts[1]) == 0 && job.debugger_attached == 0);
  return 0;
}

// K14b: a CPU's kernel timers are a list, not 32 slots: timer objects
// armed from one thread (so on one CPU, mostly) past the old limit all
// fire, and handle_replace keeps a timer armed (it closed the old handle
// first, and the last handle's close now cancels).
static int64_t many_timers(void) {
  enum { count = 100 };
  uint32_t timers[count];
  uint64_t deadline = now_ns() + 20000000;
  int created = 0, set = 0;
  for (int i = 0; i < count; i++) {
    if (sys(CROI_SYS_TIMER_CREATE, 0, 0, (uint64_t)&timers[i], 0, 0) != 0) break;
    created++;
    if (sys(CROI_SYS_TIMER_SET, timers[i], deadline + (uint64_t)i * 10000, 0, 0, 0) == 0) set++;
  }
  int fired = 0;
  for (int i = 0; i < created; i++) {
    if (wait_for(timers[i], SIGNALED, 2000000000) & SIGNALED) fired++;
    sys(CROI_SYS_HANDLE_CLOSE, timers[i], 0, 0, 0, 0);
  }
  CHECK(621, created == count && set == count && fired == count);
  uint32_t timer = 0, replaced = 0;
  CHECK(622, sys(CROI_SYS_TIMER_CREATE, 0, 0, (uint64_t)&timer, 0, 0) == 0 &&
                 sys(CROI_SYS_TIMER_SET, timer, now_ns() + 10000000, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_REPLACE, timer, 0x80000000u, (uint64_t)&replaced, 0, 0) == 0 &&  // SAME_RIGHTS
                 (wait_for(replaced, SIGNALED, 2000000000) & SIGNALED) &&
                 sys(CROI_SYS_HANDLE_CLOSE, replaced, 0, 0, 0, 0) == 0);
  return 0;
}

// K14a: reclamation. A pager VMO's clean pages are evicted oldest first
// (DONT_NEED first, ALWAYS_NEED and dirty pages kept, ALWAYS_NEED given up
// at OOM) and come back from the pager; a discardable VMO's lock states and
// its discard; the memory-pressure events, moved with test watermarks.
// Test hooks (syscall 6): 6 aging passes, 7 evict(pages, min age, ignore
// hints), 8 watermarks, 9 free bytes.
static int64_t reclaim_hook(uint64_t op, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e) {
  return sys6(CROI_SYS_TEST_PROFILE, op, a, b, c, d, e);
}

static uint64_t committed_of(uint32_t vmo, uint64_t *events) {
  croi_info_vmo_t v;
  uint64_t counts[2] = {0, 0};
  if (get_info(vmo, CROI_INFO_VMO, &v, sizeof v, counts) != 0) return ~0ull;
  if (events) *events = v.committed_change_events;
  return v.committed_bytes;
}

static int64_t reclaim(const startup_t *s) {
  uint32_t pg = 0, port = 0, vmo = 0, aux = 0;
  CHECK(600, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&pg, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, 0, port, 90, 8 * PAGE, (uint64_t)&vmo) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, 8 * PAGE, 0, (uint64_t)&aux, 0, 0) == 0);
  // Supplied up front as 'a' + index; the server supplies 'A' + index
  // later, so a page read again after eviction shows where it came from.
  char page[PAGE];
  for (uint64_t i = 0; i < 8; i++) {
    for (int j = 0; j < PAGE; j++) page[j] = (char)('a' + i);
    sys(CROI_SYS_VMO_WRITE, aux, (uint64_t)page, i * PAGE, PAGE, 0);
  }
  volatile uint64_t slot[8] = {port, pg, vmo, 0, 0, 0, 0, 90};
  uint64_t at = 0, events = 0;
  CHECK(601, sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, vmo, 0, 8 * PAGE, aux, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, vmo, 0, 8 * PAGE,
                      (uint64_t)&at) == 0);
  uint32_t server = start_thread(s, pager_server, (uint64_t)slot);
  int touched = 1;
  for (uint64_t i = 0; i < 8; i++) touched &= *(volatile char *)(at + i * PAGE) == (char)('a' + i);
  // An aging pass takes the accessed bits (every page age 1); then page 1
  // ALWAYS_NEED, page 2 DONT_NEED, page 3 dirty. The watchdog's eviction
  // (ages 6 and up) takes only page 2.
  CHECK(602, touched && committed_of(vmo, &events) == 8 * PAGE && events == 0 &&
                 reclaim_hook(6, 1, 0, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_ALWAYS_NEED, PAGE, PAGE, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DONT_NEED, 2 * PAGE, PAGE, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DONT_NEED, 0, 9 * PAGE, 0, 0) == ERR_OUT_OF_RANGE &&
                 sys6(CROI_SYS_VMO_OP_RANGE, aux, CROI_VMO_OP_DONT_NEED, 0, PAGE, 0, 0) == 0 &&  // ignored
                 sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)"D", 3 * PAGE, 1, 0) == 0);
  CHECK(603, reclaim_hook(7, 100, 6, 0, 0, 0) == 1 && committed_of(vmo, &events) == 7 * PAGE && events == 1 &&
                 slot[3] == 0);
  // Read again: the pager is asked (one READ) and supplies 'C'.
  CHECK(604, *(volatile char *)(at + 2 * PAGE) == 'C' && slot[3] == 1 && committed_of(vmo, 0) == 8 * PAGE);
  // Six passes untouched: every clean page is old; ALWAYS_NEED and the
  // dirty page stay.
  croi_info_kmem_stats_t k;
  CHECK(605, reclaim_hook(6, 6, 0, 0, 0, 0) == 0 &&
                 info(s->resource, CROI_INFO_KMEM_STATS, &k, sizeof k) == 0 &&
                 k.vmo_reclaim_total_bytes >= 7 * PAGE && k.vmo_reclaim_oldest_bytes >= 7 * PAGE &&
                 reclaim_hook(7, 100, 6, 0, 0, 0) == 6 && committed_of(vmo, &events) == 2 * PAGE && events >= 2 &&
                 *(volatile char *)(at + PAGE) == 'b' && slot[3] == 1);
  // At OOM the hint gives way (ages 2 and up; page 1 was just read, so
  // two passes first); the dirty page stays.
  CHECK(606, reclaim_hook(6, 2, 0, 0, 0, 0) == 0 && reclaim_hook(7, 100, 2, 1, 0, 0) == 1 && committed_of(vmo, 0) == PAGE &&
                 *(volatile char *)(at + 3 * PAGE) == 'D' && *(volatile char *)at == 'A' && slot[3] == 2);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, 8 * PAGE, 0, 0);
  CHECK(607, sys(CROI_SYS_PAGER_DETACH_VMO, pg, vmo, 0, 0, 0) == 0 &&
                 wait_for(server, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull));
  sys(CROI_SYS_HANDLE_CLOSE, server, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, port, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, pg, 0, 0, 0, 0);

  // Discardable: the whole range only, nested locks, the state LOCK
  // reports; unlocked and old, discarded whole; NOT_FOUND until locked.
  uint32_t d = 0, child = 0;
  croi_vmo_lock_state_t st;
  char buf[4] = {1, 1, 1, 1};
  croi_info_vmo_t v;
  uint64_t counts[2] = {0, 0};
  CHECK(610, sys(CROI_SYS_VMO_CREATE, 4 * PAGE, CROI_VMO_CREATE_DISCARDABLE, (uint64_t)&d, 0, 0) == 0 &&
                 get_info(d, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && (v.flags & CROI_INFO_VMO_DISCARDABLE) &&
                 sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_UNLOCK, 0, 4 * PAGE, 0, 0) == ERR_BAD_STATE &&
                 sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_LOCK, 0, PAGE, (uint64_t)&st, sizeof st) ==
                     ERR_OUT_OF_RANGE &&
                 sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_LOCK, 0, 4 * PAGE, (uint64_t)&st, 8) == ERR_INVALID_ARGS &&
                 sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_UNLOCK, 0, 4 * PAGE, 0, 0) == ERR_BAD_STATE &&
                 sys6(CROI_SYS_VMO_OP_RANGE, aux, CROI_VMO_OP_LOCK, 0, 8 * PAGE, (uint64_t)&st, sizeof st) ==
                     ERR_NOT_SUPPORTED &&
                 sys6(CROI_SYS_VMO_CREATE_CHILD, d, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 0, PAGE,
                      (uint64_t)&child, 0) == ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, d, CROI_CACHE_POLICY_UNCACHED, 0, 0, 0) == ERR_BAD_STATE);
  CHECK(611, sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_LOCK, 0, 4 * PAGE, (uint64_t)&st, sizeof st) == 0 &&
                 st.offset == 0 && st.size == 4 * PAGE && st.discarded_size == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_TRY_LOCK, 0, 4 * PAGE, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_WRITE, d, (uint64_t)"xyz", PAGE, 3, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_UNLOCK, 0, 4 * PAGE, 0, 0) == 0 &&
                 reclaim_hook(6, 6, 0, 0, 0, 0) == 0 &&
                 reclaim_hook(7, 100, 6, 0, 0, 0) == 0 &&  // still locked once
                 committed_of(d, 0) == PAGE &&
                 sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_UNLOCK, 0, 4 * PAGE, 0, 0) == 0 &&
                 info(s->resource, CROI_INFO_KMEM_STATS, &k, sizeof k) == 0 &&
                 k.vmo_discardable_unlocked_bytes >= PAGE);
  CHECK(612, reclaim_hook(6, 6, 0, 0, 0, 0) == 0 && reclaim_hook(7, 100, 6, 0, 0, 0) == 1 &&
                 committed_of(d, &events) == 0 && events == 1 &&
                 sys(CROI_SYS_VMO_READ, d, (uint64_t)buf, PAGE, 3, 0) == ERR_NOT_FOUND &&
                 sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_TRY_LOCK, 0, 4 * PAGE, 0, 0) == ERR_UNAVAILABLE &&
                 sys6(CROI_SYS_VMO_OP_RANGE, d, CROI_VMO_OP_LOCK, 0, 4 * PAGE, (uint64_t)&st, sizeof st) == 0 &&
                 st.discarded_size == 4 * PAGE &&
                 sys(CROI_SYS_VMO_READ, d, (uint64_t)buf, PAGE, 3, 0) == 0 && buf[0] == 0 && buf[2] == 0);
  sys(CROI_SYS_HANDLE_CLOSE, d, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, aux, 0, 0, 0, 0);

  // Memory pressure: the root job only (OUT_OF_MEMORY with
  // MANAGE_PROCESS); one event signaled; holders can't signal them.
  uint32_t ev[6] = {0}, job = 0, wrong = 0, limited = 0;
  CHECK(615, sys(CROI_SYS_SYSTEM_GET_EVENT, s->job, 9, (uint64_t)&wrong, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&job, 0, 0) == 0 &&
                 sys(CROI_SYS_SYSTEM_GET_EVENT, job, CROI_SYSTEM_EVENT_MEMORY_PRESSURE_NORMAL, (uint64_t)&wrong, 0,
                     0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, s->job, RIGHT_WAIT, (uint64_t)&limited, 0, 0) == 0 &&
                 sys(CROI_SYS_SYSTEM_GET_EVENT, limited, CROI_SYSTEM_EVENT_OUT_OF_MEMORY, (uint64_t)&wrong, 0, 0) ==
                     ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_SYSTEM_GET_EVENT, limited, CROI_SYSTEM_EVENT_MEMORY_PRESSURE_NORMAL, (uint64_t)&ev[0], 0,
                     0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, ev[0], 0, 0, 0, 0);
  int got = 1;
  for (uint32_t kind = 1; kind <= 5; kind++)
    got &= sys(CROI_SYS_SYSTEM_GET_EVENT, s->job, kind, (uint64_t)&ev[kind], 0, 0) == 0;
  CHECK(616, got && (wait_for(ev[CROI_SYSTEM_EVENT_MEMORY_PRESSURE_NORMAL], CROI_SIGNAL_SIGNALED, 0) &
                     CROI_SIGNAL_SIGNALED) &&
                 !(wait_for(ev[CROI_SYSTEM_EVENT_MEMORY_PRESSURE_WARNING], CROI_SIGNAL_SIGNALED, 0) &
                   CROI_SIGNAL_SIGNALED) &&
                 sys(CROI_SYS_OBJECT_SIGNAL, ev[1], 0, CROI_SIGNAL_SIGNALED, 0, 0) == ERR_ACCESS_DENIED);
  // Watermarks just below free memory (no hysteresis, no eviction delay):
  // 16 MiB committed is Warning, 32 MiB Critical, both freed Normal again.
  uint64_t free = (uint64_t)reclaim_hook(9, 0, 0, 0, 0, 0);
  uint64_t mib = 1ull << 20;
  uint32_t big[2] = {0, 0};
  CHECK(617, free > 64 * mib && reclaim_hook(8, free / 4, free - 24 * mib, free - 12 * mib, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, 16 * mib, 0, (uint64_t)&big[0], 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, big[0], CROI_VMO_OP_COMMIT, 0, 16 * mib, 0, 0) == 0 &&
                 (wait_for(ev[CROI_SYSTEM_EVENT_MEMORY_PRESSURE_WARNING], CROI_SIGNAL_SIGNALED, 2000000000ull) &
                  CROI_SIGNAL_SIGNALED) &&
                 !(wait_for(ev[CROI_SYSTEM_EVENT_MEMORY_PRESSURE_NORMAL], CROI_SIGNAL_SIGNALED, 0) &
                   CROI_SIGNAL_SIGNALED));
  CHECK(618, sys(CROI_SYS_VMO_CREATE, 16 * mib, 0, (uint64_t)&big[1], 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, big[1], CROI_VMO_OP_COMMIT, 0, 16 * mib, 0, 0) == 0 &&
                 (wait_for(ev[CROI_SYSTEM_EVENT_MEMORY_PRESSURE_CRITICAL], CROI_SIGNAL_SIGNALED, 2000000000ull) &
                  CROI_SIGNAL_SIGNALED) &&
                 !(wait_for(ev[CROI_SYSTEM_EVENT_MEMORY_PRESSURE_WARNING], CROI_SIGNAL_SIGNALED, 0) &
                   CROI_SIGNAL_SIGNALED));
  sys(CROI_SYS_HANDLE_CLOSE, big[0], 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, big[1], 0, 0, 0, 0);
  CHECK(619, (wait_for(ev[CROI_SYSTEM_EVENT_MEMORY_PRESSURE_NORMAL], CROI_SIGNAL_SIGNALED, 2000000000ull) &
              CROI_SIGNAL_SIGNALED) &&
                 !(wait_for(ev[CROI_SYSTEM_EVENT_MEMORY_PRESSURE_CRITICAL], CROI_SIGNAL_SIGNALED, 0) &
                   CROI_SIGNAL_SIGNALED) &&
                 reclaim_hook(8, 0, 0, 0, 0, 0) == 0);
  for (uint32_t kind = 1; kind <= 5; kind++) sys(CROI_SYS_HANDLE_CLOSE, ev[kind], 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, limited, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, job, 0, 0, 0, 0);
  return 0;
}

// K13b: FIFOs (Zircon's: records into the peer's ring, READABLE /
// WRITABLE / PEER_CLOSED, user signals to the peer) and
// vmo_replace_as_executable (a VMEX resource; the handle consumed).
static int64_t fifos_and_exec(const startup_t *s) {
  uint32_t a = 0, b = 0, observed = 0;
  uint64_t actual = 0;
  uint32_t rec[8] = {0}, got[8] = {0};
  CHECK(440, sys(CROI_SYS_FIFO_CREATE, 0, 4, 0, (uint64_t)&a, (uint64_t)&b) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_FIFO_CREATE, 1024, 8, 0, (uint64_t)&a, (uint64_t)&b) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_FIFO_CREATE, 4, 4, 1, (uint64_t)&a, (uint64_t)&b) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_FIFO_CREATE, 4, 4, 0, (uint64_t)&a, (uint64_t)&b) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, a, CROI_SIGNAL_WRITABLE, 0, (uint64_t)&observed, 0) == 0);
  for (int i = 0; i < 8; i++) rec[i] = 100 + i;
  // Six offered, four fit; then full: SHOULD_WAIT, a not WRITABLE, b READABLE.
  CHECK(441, sys(CROI_SYS_FIFO_WRITE, a, 8, (uint64_t)rec, 1, (uint64_t)&actual) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_FIFO_WRITE, a, 4, (uint64_t)rec, 6, (uint64_t)&actual) == 0 && actual == 4 &&
                 sys(CROI_SYS_FIFO_WRITE, a, 4, (uint64_t)rec, 1, (uint64_t)&actual) == ERR_SHOULD_WAIT &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, a, CROI_SIGNAL_WRITABLE, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, CROI_SIGNAL_READABLE, 0, (uint64_t)&observed, 0) == 0);
  // Read three, then the rest: order kept, a WRITABLE again, b empty.
  CHECK(442, sys(CROI_SYS_FIFO_READ, b, 4, (uint64_t)got, 3, (uint64_t)&actual) == 0 && actual == 3 &&
                 got[0] == 100 && got[2] == 102 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, a, CROI_SIGNAL_WRITABLE, 0, (uint64_t)&observed, 0) == 0 &&
                 sys(CROI_SYS_FIFO_READ, b, 4, (uint64_t)got, 8, (uint64_t)&actual) == 0 && actual == 1 &&
                 got[0] == 103 &&
                 sys(CROI_SYS_FIFO_READ, b, 4, (uint64_t)got, 1, 0) == ERR_SHOULD_WAIT &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, CROI_SIGNAL_READABLE, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT);
  // A user signal to the peer; then a closed peer.
  CHECK(443, sys(CROI_SYS_OBJECT_SIGNAL_PEER, a, 0, 1u << 24, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, b, 1u << 24, 0, (uint64_t)&observed, 0) == 0 &&
                 sys(CROI_SYS_FIFO_WRITE, b, 4, (uint64_t)rec, 1, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, b, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, a, CROI_SIGNAL_PEER_CLOSED, 0, (uint64_t)&observed, 0) == 0 &&
                 !(observed & CROI_SIGNAL_WRITABLE) &&
                 sys(CROI_SYS_FIFO_WRITE, a, 4, (uint64_t)rec, 1, 0) == ERR_PEER_CLOSED &&
                 sys(CROI_SYS_FIFO_READ, a, 4, (uint64_t)got, 1, 0) == 0 && got[0] == 100 &&
                 sys(CROI_SYS_FIFO_READ, a, 4, (uint64_t)got, 1, 0) == ERR_PEER_CLOSED);
  sys(CROI_SYS_HANDLE_CLOSE, a, 0, 0, 0, 0);

  // An anonymous VMO isn't executable until replaced with a VMEX resource;
  // a bad resource still takes the handle.
  uint32_t vmo = 0, exec = 0, other = 0;
  uint64_t at = 0;
  CHECK(444, sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_EXECUTE) << 32, 0, vmo,
                      0, PAGE, (uint64_t)&at) == ERR_ACCESS_DENIED_ &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, vmo, 1u << 31, (uint64_t)&other, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_REPLACE_AS_EXECUTABLE, other, vmo, (uint64_t)&exec, 0, 0) == ERR_WRONG_TYPE &&
                 sys(CROI_SYS_HANDLE_CLOSE, other, 0, 0, 0, 0) == ERR_BAD_HANDLE &&
                 sys(CROI_SYS_VMO_REPLACE_AS_EXECUTABLE, vmo, s->resource, (uint64_t)&exec, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0) == ERR_BAD_HANDLE &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_EXECUTE) << 32, 0, exec,
                      0, PAGE, (uint64_t)&at) == 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, PAGE, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, exec, 0, 0, 0, 0);
  return 0;
}

static int64_t vmo_child(uint32_t vmo, uint32_t options, uint64_t offset, uint64_t size, uint32_t *out) {
  return sys(CROI_SYS_VMO_CREATE_CHILD, vmo, options, offset, size, (uint64_t)out);
}

static int64_t vmo_slices(const startup_t *s) {
  if (s->ecam == 0) return 0;
  volatile uint8_t *whole = 0;
  uint32_t parent = physical_vmo(s, s->ecam, 0x10000, &whole);
  uint32_t observed = 0, slice = 0, deeper = 0, ro = 0, ro_slice = 0, nw_slice = 0, anon = 0, bad = 0;
  uint32_t zero = CROI_VMO_ZERO_CHILDREN, slice_option = CROI_VMO_CHILD_SLICE;
  CHECK(430, sys(CROI_SYS_OBJECT_WAIT_ONE, parent, zero, 0, (uint64_t)&observed, 0) == 0 && (observed & zero));
  CHECK(431, sys(CROI_SYS_VMO_CREATE, PAGE, CROI_VMO_CREATE_RESIZABLE, (uint64_t)&anon, 0, 0) == 0 &&
                 vmo_child(anon, slice_option, 0, PAGE, &bad) == ERR_NOT_SUPPORTED &&  // resizable (K14g)
                 vmo_child(parent, slice_option | CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 0, PAGE, &bad) ==
                     ERR_INVALID_ARGS &&
                 vmo_child(parent, slice_option, 8, PAGE, &bad) == ERR_INVALID_ARGS &&
                 vmo_child(parent, slice_option, 0x10000, PAGE, &bad) == ERR_INVALID_ARGS &&
                 vmo_child(parent, slice_option, 0xF000, 2 * PAGE, &bad) == ERR_INVALID_ARGS);
  sys(CROI_SYS_HANDLE_CLOSE, anon, 0, 0, 0, 0);
  // A slice over device 1's page clears ZERO_CHILDREN and reads as the parent.
  uint64_t at = 0, deep_at = 0;
  CHECK(432, vmo_child(parent, slice_option, 0x8000, PAGE, &slice) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, parent, zero, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, slice, 0, PAGE,
                      (uint64_t)&at) == 0 &&
                 *(volatile uint32_t *)at == *(volatile uint32_t *)(whole + 0x8000));
  // A slice of the slice is one of the parent (counted as the slice's
  // child, K14g); neither side's cache policy can change now.
  CHECK(433, vmo_child(slice, slice_option, 0, PAGE, &deeper) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, deeper, 0, PAGE,
                      (uint64_t)&deep_at) == 0 &&
                 *(volatile uint32_t *)deep_at == *(volatile uint32_t *)at &&
                 sys(CROI_SYS_VMAR_UNMAP, s->vmar, deep_at, PAGE, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, deeper, CROI_CACHE_POLICY_UNCACHED_DEVICE, 0, 0, 0) == ERR_BAD_STATE);
  sys(CROI_SYS_HANDLE_CLOSE, deeper, 0, 0, 0, 0);
  // Rights: a slice of a handle without WRITE has none; NO_WRITE takes it.
  uint64_t w = 0;
  uint32_t ro_rights = 1u << 0 | 1u << 1 | 1u << 2 | 1u << 5 | 1u << 14 | 1u << 15;  // dup, transfer, read, map, wait, inspect
  CHECK(434, sys(CROI_SYS_HANDLE_DUPLICATE, parent, ro_rights, (uint64_t)&ro, 0, 0) == 0 &&
                 vmo_child(ro, slice_option, 0, PAGE, &ro_slice) == 0 &&
                 vmo_child(parent, slice_option | CROI_VMO_CHILD_NO_WRITE, 0, PAGE, &nw_slice) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, ro_slice,
                      0, PAGE, (uint64_t)&w) == ERR_ACCESS_DENIED_ &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, nw_slice,
                      0, PAGE, (uint64_t)&w) == ERR_ACCESS_DENIED_);
  sys(CROI_SYS_HANDLE_CLOSE, ro_slice, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, nw_slice, 0, 0, 0, 0);
  // HANDLE_COUNT: two handles; one in flight still counts; back, then closed.
  croi_info_handle_count_t count = {0};
  uint32_t a = 0, b = 0, got = 0, actual[2] = {0, 0};
  CHECK(435, sys(CROI_SYS_OBJECT_GET_INFO, parent, CROI_INFO_HANDLE_COUNT, (uint64_t)&count, sizeof count, 0) == 0 &&
                 count.handle_count == 2 && sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&a, (uint64_t)&b, 0, 0) == 0 &&
                 chan_write(a, "", 0, &ro, 1) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_INFO, parent, CROI_INFO_HANDLE_COUNT, (uint64_t)&count, sizeof count, 0) == 0 &&
                 count.handle_count == 2 && chan_read(b, 0, &got, 0, 1, actual) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_INFO, parent, CROI_INFO_HANDLE_COUNT, (uint64_t)&count, sizeof count, 0) == 0 &&
                 count.handle_count == 2 && sys(CROI_SYS_HANDLE_CLOSE, got, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_INFO, parent, CROI_INFO_HANDLE_COUNT, (uint64_t)&count, sizeof count, 0) == 0 &&
                 count.handle_count == 1);
  sys(CROI_SYS_HANDLE_CLOSE, a, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, b, 0, 0, 0, 0);
  // The last slice's handle goes while it is mapped: still a child. The
  // unmap ends it, and ZERO_CHILDREN comes back.
  CHECK(436, sys(CROI_SYS_HANDLE_CLOSE, slice, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, parent, zero, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, PAGE, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, parent, zero, now_ns() + 1000000000ull, (uint64_t)&observed, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, parent, CROI_CACHE_POLICY_UNCACHED_DEVICE, 0, 0, 0) ==
                     ERR_BAD_STATE);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, (uint64_t)whole, 0x10000, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, parent, 0, 0, 0, 0);
  return 0;
}

// K11a: copy-on-first-touch VMO children. Returns 0 or the failed check.
static int64_t vmo_children(void) {
  enum { P = 4096 };
  uint32_t parent = 0, child = 0, grand = 0, ro = 0, other = 0;
  uint8_t byte = 0, page[64];
  if (sys(CROI_SYS_VMO_CREATE, 3 * P, 0, (uint64_t)&parent, 0, 0) != 0) return 410;
  byte = 'A';
  if (sys(CROI_SYS_VMO_WRITE, parent, (uint64_t)&byte, 0, 1, 0) != 0) return 410;
  byte = 'C';
  if (sys(CROI_SYS_VMO_WRITE, parent, (uint64_t)&byte, 2 * P, 1, 0) != 0) return 410;
  // Refusals: no type, unknown bits, an unaligned offset (the other kinds:
  // K14g's child_kinds).
  if (sys(CROI_SYS_VMO_CREATE_CHILD, parent, 0, 0, P, (uint64_t)&other) != ERR_INVALID_ARGS ||
      sys(CROI_SYS_VMO_CREATE_CHILD, parent, 1u << 9, 0, P, (uint64_t)&other) != ERR_INVALID_ARGS ||
      sys(CROI_SYS_VMO_CREATE_CHILD, parent, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 100, P, (uint64_t)&other) !=
          ERR_INVALID_ARGS)
    return 411;
  // A child one page longer than its parent.
  if (sys(CROI_SYS_VMO_CREATE_CHILD, parent, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 0, 4 * P,
          (uint64_t)&child) != 0)
    return 412;
  // Untouched, it reads the parent, including the parent's later writes.
  if (sys(CROI_SYS_VMO_READ, child, (uint64_t)&byte, 0, 1, 0) != 0 || byte != 'A') return 413;
  byte = 'B';
  sys(CROI_SYS_VMO_WRITE, parent, (uint64_t)&byte, 0, 1, 0);
  if (sys(CROI_SYS_VMO_READ, child, (uint64_t)&byte, 0, 1, 0) != 0 || byte != 'B') return 414;
  // Written, it has its own page; the parent is untouched.
  byte = 'X';
  if (sys(CROI_SYS_VMO_WRITE, child, (uint64_t)&byte, 0, 1, 0) != 0) return 415;
  sys(CROI_SYS_VMO_READ, parent, (uint64_t)&byte, 0, 1, 0);
  if (byte != 'B') return 416;
  sys(CROI_SYS_VMO_READ, child, (uint64_t)&byte, 0, 1, 0);
  if (byte != 'X') return 416;
  // Beyond the parent: zero; the parent's never-written page: zero; its third: 'C'.
  for (int i = 0; i < 64; i++) page[i] = 0xEE;
  if (sys(CROI_SYS_VMO_READ, child, (uint64_t)page, 3 * P, 64, 0) != 0) return 417;
  for (int i = 0; i < 64; i++)
    if (page[i] != 0) return 417;
  sys(CROI_SYS_VMO_READ, child, (uint64_t)&byte, P, 1, 0);
  if (byte != 0) return 417;
  sys(CROI_SYS_VMO_READ, child, (uint64_t)&byte, 2 * P, 1, 0);
  if (byte != 'C') return 417;
  // A grandchild sees its parent's copy; a decommit of a child is refused.
  if (sys(CROI_SYS_VMO_CREATE_CHILD, child, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 0, P, (uint64_t)&grand) != 0)
    return 418;
  sys(CROI_SYS_VMO_READ, grand, (uint64_t)&byte, 0, 1, 0);
  if (byte != 'X') return 418;
  if (sys6(CROI_SYS_VMO_OP_RANGE, child, CROI_VMO_OP_DECOMMIT, 0, P, 0, 0) != ERR_NOT_SUPPORTED) return 419;
  // Rights: a snapshot can be written and not executed; NO_WRITE can't be written.
  croi_info_handle_basic_t info;
  if (sys(CROI_SYS_OBJECT_GET_INFO, child, CROI_INFO_HANDLE_BASIC, (uint64_t)&info, sizeof info, 0) != 0 ||
      !(info.rights & (1u << 3)) || (info.rights & (1u << 4)))
    return 420;
  if (sys(CROI_SYS_VMO_CREATE_CHILD, parent, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE | CROI_VMO_CHILD_NO_WRITE, 0,
          P, (uint64_t)&ro) != 0 ||
      sys(CROI_SYS_VMO_WRITE, ro, (uint64_t)&byte, 0, 1, 0) != ERR_ACCESS_DENIED)
    return 421;
  // Mapped, a child faults its pages in from the parent.
  uint64_t at = 0;
  if (sys(CROI_SYS_VMO_MAP, child, 2 * P, P, 3, (uint64_t)&at) != 0 || *(volatile uint8_t *)at != 'C') return 422;
  *(volatile uint8_t *)at = 'Z';
  sys(CROI_SYS_VMO_READ, parent, (uint64_t)&byte, 2 * P, 1, 0);
  if (byte != 'C') return 422;
  uint32_t handles[] = {parent, child, grand, ro};
  for (int i = 0; i < 4; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0;
}

// K14g: the other child kinds. Bytes read and written through vmo_read /
// vmo_write (-1 on failure).
static int vmo_byte(uint32_t vmo, uint64_t offset) {
  uint8_t byte = 0;
  return sys(CROI_SYS_VMO_READ, vmo, (uint64_t)&byte, offset, 1, 0) == 0 ? byte : -1;
}

static int vmo_put(uint32_t vmo, uint64_t offset, uint8_t byte) {
  return sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)&byte, offset, 1, 0) == 0;
}

static int64_t child_kinds(const startup_t *s) {
  uint32_t parent = 0, snap = 0, aow = 0, chain = 0, bad = 0, iommu = 0, bti = 0, pmt = 0, contig = 0;
  uint64_t counts[2] = {0, 0}, addr = 0;
  uint8_t desc = 0;
  croi_info_vmo_t v;
  // SNAPSHOT of an anonymous VMO: what the parent shows now, isolated both
  // ways; a clone of the parent with its pages, decommit refused.
  CHECK(650, sys(CROI_SYS_VMO_CREATE, 3 * PAGE, 0, (uint64_t)&parent, 0, 0) == 0 && vmo_put(parent, 0, 'A') &&
                 vmo_put(parent, 2 * PAGE, 'C') &&
                 vmo_child(parent, CROI_VMO_CHILD_SNAPSHOT, 0, 4 * PAGE, &snap) == 0 && vmo_byte(snap, 0) == 'A' &&
                 vmo_put(parent, 0, 'B') && vmo_byte(snap, 0) == 'A' && vmo_put(snap, 2 * PAGE, 'X') &&
                 vmo_byte(parent, 2 * PAGE) == 'C' &&
                 get_info(snap, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && (v.flags & CROI_INFO_VMO_IS_COW_CLONE) &&
                 v.parent_koid == koid_of(parent) && v.committed_bytes == 2 * PAGE && vmo_byte(snap, 3 * PAGE) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, snap, CROI_VMO_OP_DECOMMIT, 0, PAGE, 0, 0) == ERR_NOT_SUPPORTED);
  // Through an at-least-on-write child: the parent's later writes show in
  // the child, not in a snapshot of it. Mapped, the snapshot faults in its
  // own copies.
  uint64_t at = 0;
  CHECK(651, vmo_child(parent, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 0, 3 * PAGE, &aow) == 0 &&
                 vmo_child(aow, CROI_VMO_CHILD_SNAPSHOT, 0, 3 * PAGE, &chain) == 0 && vmo_put(parent, 0, 'D') &&
                 vmo_byte(aow, 0) == 'D' && vmo_byte(chain, 0) == 'B' &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, chain, 0,
                      3 * PAGE, (uint64_t)&at) == 0 &&
                 *(volatile uint8_t *)(at + 2 * PAGE) == 'C' && (*(volatile uint8_t *)at = 'Y') == 'Y' &&
                 vmo_byte(aow, 0) == 'D' && vmo_byte(parent, 0) == 'D' &&
                 sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, 3 * PAGE, 0, 0) == 0 && vmo_byte(chain, 0) == 'Y');
  // Refused: pinned pages (BAD_STATE, every kind of an anonymous VMO, as
  // Zircon's), a contiguous VMO (INVALID_ARGS), a pager VMO (full only);
  // SNAPSHOT_MODIFIED of an anonymous VMO is a full snapshot.
  uint32_t pg = 0, port = 0, paged = 0, aux = 0, cow = 0, mod = 0, pmod = 0;
  CHECK(652, sys(CROI_SYS_IOMMU_CREATE, s->resource, CROI_IOMMU_TYPE_STUB, (uint64_t)&desc, 1, (uint64_t)&iommu) == 0 &&
                 sys(CROI_SYS_BTI_CREATE, iommu, 0, 0, (uint64_t)&bti, 0) == 0 &&
                 bti_pin(bti, CROI_BTI_PERM_READ, parent, 1, PAGE, PAGE, &addr, &pmt) == 0 &&
                 vmo_child(parent, CROI_VMO_CHILD_SNAPSHOT, 0, PAGE, &bad) == ERR_BAD_STATE &&
                 vmo_child(parent, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 0, PAGE, &bad) == ERR_BAD_STATE &&
                 sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE_CONTIGUOUS, bti, PAGE, 0, (uint64_t)&contig, 0) == 0 &&
                 vmo_child(contig, CROI_VMO_CHILD_SNAPSHOT, 0, PAGE, &bad) == ERR_INVALID_ARGS &&
                 vmo_child(contig, CROI_VMO_CHILD_REFERENCE, 0, 0, &bad) == ERR_NOT_SUPPORTED &&
                 vmo_child(parent, CROI_VMO_CHILD_SNAPSHOT | CROI_VMO_CHILD_SLICE, 0, PAGE, &bad) == ERR_INVALID_ARGS &&
                 vmo_child(parent, CROI_VMO_CHILD_SNAPSHOT_MODIFIED, 0, PAGE, &mod) == 0 && vmo_put(parent, 0, 'E') &&
                 vmo_byte(mod, 0) == 'D');
  // Under a pager: SNAPSHOT refused; SNAPSHOT_MODIFIED of the pager VMO
  // reads through; of a child, the child's own pages are snapshotted and
  // the rest still read through to the pager VMO.
  CHECK(653, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&pg, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, 0, port, 93, 2 * PAGE, (uint64_t)&paged) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, 2 * PAGE, 0, (uint64_t)&aux, 0, 0) == 0 && vmo_put(aux, 0, 'p') &&
                 vmo_put(aux, PAGE, 'q') && sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, paged, 0, 2 * PAGE, aux, 0) == 0 &&
                 vmo_child(paged, CROI_VMO_CHILD_SNAPSHOT, 0, PAGE, &bad) == ERR_NOT_SUPPORTED &&
                 vmo_child(paged, CROI_VMO_CHILD_SNAPSHOT_MODIFIED, 0, 2 * PAGE, &pmod) == 0 &&
                 vmo_byte(pmod, PAGE) == 'q' &&
                 vmo_child(paged, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 0, 2 * PAGE, &cow) == 0 &&
                 vmo_put(cow, 0, 'M') && vmo_child(cow, CROI_VMO_CHILD_SNAPSHOT_MODIFIED, 0, 2 * PAGE, &bad) == 0 &&
                 vmo_put(cow, 0, 'N') && vmo_byte(bad, 0) == 'M' && vmo_byte(bad, PAGE) == 'q' &&
                 get_info(bad, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && v.parent_koid == koid_of(cow) &&
                 vmo_child(cow, CROI_VMO_CHILD_SNAPSHOT, 0, PAGE, &snap) == ERR_NOT_SUPPORTED);
  sys(CROI_SYS_HANDLE_CLOSE, bad, 0, 0, 0, 0);
  uint32_t closing[] = {chain, aow, mod, pmod, cow, paged, aux, port, pg, contig, bti, iommu};
  for (int i = 0; i < 12; i++) sys(CROI_SYS_HANDLE_CLOSE, closing[i], 0, 0, 0, 0);

  // A slice of an anonymous VMO: its pages, from the offset, both ways, by
  // syscall and by mapping; its size; nothing attributed to it; the
  // parent's ZERO_CHILDREN cleared while it lives.
  uint32_t big = 0, slice = 0, deeper = 0, observed = 0, zero = CROI_VMO_ZERO_CHILDREN;
  uint64_t size = 0, mapped = 0;
  CHECK(654, sys(CROI_SYS_VMO_CREATE, 4 * PAGE, 0, (uint64_t)&big, 0, 0) == 0 && vmo_put(big, PAGE, 'S') &&
                 vmo_child(big, CROI_VMO_CHILD_SLICE, PAGE, 2 * PAGE, &slice) == 0 && vmo_byte(slice, 0) == 'S' &&
                 vmo_put(slice, PAGE + 5, 'T') && vmo_byte(big, 2 * PAGE + 5) == 'T' &&
                 sys(CROI_SYS_VMO_GET_SIZE, slice, (uint64_t)&size, 0, 0, 0) == 0 && size == 2 * PAGE &&
                 vmo_byte(slice, 2 * PAGE) == -1 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, slice, 0,
                      2 * PAGE, (uint64_t)&mapped) == 0 &&
                 *(volatile uint8_t *)mapped == 'S' && (*(volatile uint8_t *)(mapped + PAGE) = 'U') == 'U' &&
                 vmo_byte(big, 2 * PAGE) == 'U' && vmo_put(big, PAGE + 1, 'V') &&
                 *(volatile uint8_t *)(mapped + 1) == 'V' &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, slice, 0, 3 * PAGE,
                      (uint64_t)&at) != 0 &&
                 get_info(slice, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && v.committed_bytes == 0 &&
                 !(v.flags & CROI_INFO_VMO_IS_COW_CLONE) && v.parent_koid == koid_of(big) && v.size_bytes == 2 * PAGE &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, big, zero, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT);
  // Decommit and ZERO through it reach the parent's pages (and the
  // mapping); a slice of it is the parent's at the summed offset, counted
  // as the slice's child.
  // (The decommitted page is taken by another VMO first: a mapping left
  // on it would read that VMO's byte.)
  uint32_t spare = 0;
  CHECK(655, sys6(CROI_SYS_VMO_OP_RANGE, slice, CROI_VMO_OP_DECOMMIT, 0, PAGE, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&spare, 0, 0) == 0 && vmo_put(spare, 0, 'J') &&
                 *(volatile uint8_t *)mapped == 0 && vmo_byte(big, PAGE) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, spare, 0, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, slice, CROI_VMO_OP_ZERO, PAGE, 4, 0, 0) == 0 &&
                 vmo_byte(big, 2 * PAGE) == 0 && vmo_byte(big, 2 * PAGE + 5) == 'T' &&
                 vmo_child(slice, CROI_VMO_CHILD_SLICE, PAGE, PAGE, &deeper) == 0 && vmo_byte(deeper, 5) == 'T' &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, slice, zero, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT &&
                 sys(CROI_SYS_HANDLE_CLOSE, deeper, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, slice, zero, now_ns() + 1000000000ull, (uint64_t)&observed, 0) == 0);
  // Refused through a slice: snapshots of it (an anonymous one, Zircon's),
  // a reference, a window past it; the parent's cache policy is fixed.
  uint32_t grow = 0;
  CHECK(656, vmo_child(slice, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, 0, PAGE, &bad) == ERR_NOT_SUPPORTED &&
                 vmo_child(slice, CROI_VMO_CHILD_SNAPSHOT, 0, PAGE, &bad) == ERR_NOT_SUPPORTED &&
                 vmo_child(slice, CROI_VMO_CHILD_REFERENCE, 0, 0, &bad) == ERR_NOT_SUPPORTED &&
                 vmo_child(slice, CROI_VMO_CHILD_SLICE, PAGE, 2 * PAGE, &bad) == ERR_INVALID_ARGS &&
                 vmo_child(big, CROI_VMO_CHILD_SLICE, 100, PAGE, &bad) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMO_SET_CACHE_POLICY, big, CROI_CACHE_POLICY_UNCACHED, 0, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_VMO_CREATE, PAGE, CROI_VMO_CREATE_RESIZABLE, (uint64_t)&grow, 0, 0) == 0 &&
                 vmo_child(grow, CROI_VMO_CHILD_SLICE, 0, PAGE, &bad) == ERR_NOT_SUPPORTED);
  // The parent's handle goes; the slice (and its mapping) keep the pages.
  CHECK(657, sys(CROI_SYS_HANDLE_CLOSE, big, 0, 0, 0, 0) == 0 && vmo_byte(slice, PAGE + 5) == 'T' &&
                 (*(volatile uint8_t *)mapped = 'W') == 'W' && vmo_byte(slice, 0) == 'W' &&
                 sys(CROI_SYS_VMAR_UNMAP, s->vmar, mapped, 2 * PAGE, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, slice, 0, 0, 0, 0) == 0);

  // REFERENCE: the whole VMO, its pages and sizes, under its own koid.
  // Refusals in Zircon's order; RESIZABLE needs the parent resizable and
  // its handle's RESIZE; resizing the reference resizes the parent.
  uint32_t ref = 0, weak = 0, rref = 0, rsnap = 0;
  uint32_t no_resize = 1u << 0 | 1u << 1 | 1u << 2 | 1u << 3 | 1u << 5 | 1u << 14 | 1u << 15;
  CHECK(658, vmo_child(grow, CROI_VMO_CHILD_REFERENCE, PAGE, 0, &bad) == ERR_INVALID_ARGS &&
                 vmo_child(grow, CROI_VMO_CHILD_REFERENCE, 0, PAGE, &bad) == ERR_INVALID_ARGS &&
                 vmo_child(grow, CROI_VMO_CHILD_REFERENCE | CROI_VMO_CHILD_NO_WRITE | CROI_VMO_CHILD_RESIZABLE, 0, 0,
                           &bad) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, grow, no_resize, (uint64_t)&weak, 0, 0) == 0 &&
                 vmo_child(weak, CROI_VMO_CHILD_REFERENCE | CROI_VMO_CHILD_RESIZABLE, 0, 0, &bad) == ERR_ACCESS_DENIED_ &&
                 vmo_child(weak, CROI_VMO_CHILD_REFERENCE, 0, 0, &ref) == 0 &&
                 vmo_child(grow, CROI_VMO_CHILD_REFERENCE | CROI_VMO_CHILD_RESIZABLE, 0, 0, &rref) == 0 &&
                 vmo_put(grow, 7, 'R') && vmo_byte(ref, 7) == 'R' && vmo_put(rref, 8, 'Q') && vmo_byte(grow, 8) == 'Q' &&
                 koid_of(ref) != koid_of(grow) && sys(CROI_SYS_VMO_SET_SIZE, ref, 3 * PAGE, 0, 0, 0) ==
                     ERR_ACCESS_DENIED_ &&
                 sys(CROI_SYS_VMO_SET_SIZE, rref, 3 * PAGE, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_GET_SIZE, grow, (uint64_t)&size, 0, 0, 0) == 0 && size == 3 * PAGE &&
                 sys(CROI_SYS_VMO_GET_SIZE, ref, (uint64_t)&size, 0, 0, 0) == 0 && size == 3 * PAGE &&
                 vmo_put(ref, 2 * PAGE, 'G') && vmo_byte(grow, 2 * PAGE) == 'G');
  // The stream size is shared; a snapshot through a reference is of the
  // parent, counted as the reference's child; info names the parent.
  uint64_t content = 100;
  CHECK(659, sys(CROI_SYS_VMO_SET_STREAM_SIZE, grow, 100, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, ref, (uint64_t)&content, 0, 0, 0) == 0 && content == 100 &&
                 sys(CROI_SYS_VMO_SET_STREAM_SIZE, rref, 50, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, grow, (uint64_t)&content, 0, 0, 0) == 0 && content == 50 &&
                 vmo_child(ref, CROI_VMO_CHILD_SNAPSHOT, 0, PAGE, &rsnap) == 0 && vmo_byte(rsnap, 7) == 'R' &&
                 sys(CROI_SYS_OBJECT_WAIT_ONE, ref, zero, 0, (uint64_t)&observed, 0) == ERR_TIMED_OUT &&
                 get_info(rsnap, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && v.parent_koid == koid_of(ref) &&
                 get_info(ref, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && v.parent_koid == koid_of(grow) &&
                 v.committed_bytes == 0 && (v.flags & CROI_INFO_VMO_RESIZABLE) && v.size_bytes == 3 * PAGE);
  // A stream over a slice: its own stream size, its parent's pages.
  uint32_t window = 0, st = 0;
  uint64_t actual = 0;
  croi_iovec_t hello = {(void *)"hello", 5};
  CHECK(660, vmo_child(grow, CROI_VMO_CHILD_SLICE, PAGE, PAGE, &window) == ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_VMO_CREATE, 2 * PAGE, 0, (uint64_t)&big, 0, 0) == 0 &&
                 vmo_child(big, CROI_VMO_CHILD_SLICE, PAGE, PAGE, &window) == 0 &&
                 sys(CROI_SYS_VMO_SET_STREAM_SIZE, window, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_STREAM_CREATE, CROI_STREAM_MODE_WRITE, window, 0, (uint64_t)&st, 0) == 0 &&
                 sys(CROI_SYS_STREAM_WRITEV, st, 0, (uint64_t)&hello, 1, (uint64_t)&actual) == 0 && actual == 5 &&
                 vmo_byte(big, PAGE + 4) == 'o' &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, window, (uint64_t)&content, 0, 0, 0) == 0 && content == 5 &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, big, (uint64_t)&content, 0, 0, 0) == 0 && content == 2 * PAGE);
  uint32_t last[] = {st, window, big, rsnap, ref, rref, weak, grow, snap, parent};
  for (int i = 0; i < 10; i++) sys(CROI_SYS_HANDLE_CLOSE, last[i], 0, 0, 0, 0);
  return 0;
}

// K14h: vmo_read copies a page under its VMO's lock. A writer fills a
// page with 'V' and decommits it, over and over; a polluter does the same
// with 'J' in a VMO of its own, so a freed page soon holds 'J'. A reader
// copying a page after it was freed would see a 'J'.
typedef struct {
  uint32_t vmo;
  volatile int stop;
} copy_race_t;

static void race_fill(uint32_t vmo, char c, volatile int *stop) {
  char page[PAGE];
  for (int i = 0; i < PAGE; i++) page[i] = c;
  while (!*stop) {
    sys(CROI_SYS_VMO_WRITE, vmo, (uint64_t)page, 0, PAGE, 0);
    sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, 0, PAGE, 0, 0);
  }
}

static void race_writer(uint64_t arg) {
  copy_race_t *r = (copy_race_t *)arg;
  race_fill(r->vmo, 'V', &r->stop);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static void race_polluter(uint64_t arg) {
  copy_race_t *r = (copy_race_t *)arg;
  uint32_t own = 0;
  if (sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&own, 0, 0) == 0) race_fill(own, 'J', &r->stop);
  sys(CROI_SYS_HANDLE_CLOSE, own, 0, 0, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t copy_race(const startup_t *s) {
  copy_race_t r = {0, 0};
  char page[PAGE];
  CHECK(661, sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&r.vmo, 0, 0) == 0);
  uint32_t writer = start_thread(s, race_writer, (uint64_t)&r);
  uint32_t polluter = start_thread(s, race_polluter, (uint64_t)&r);
  uint64_t end = now_ns() + 300000000ull;
  int polluted = 0, reads = 0;
  while (now_ns() < end && !polluted) {
    if (sys(CROI_SYS_VMO_READ, r.vmo, (uint64_t)page, 0, PAGE, 0) != 0) break;
    reads++;
    for (int i = 0; i < PAGE; i++) polluted |= page[i] == 'J';
  }
  r.stop = 1;
  wait_for(writer, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull);
  wait_for(polluter, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull);
  uint32_t handles[] = {writer, polluter, r.vmo};
  for (int i = 0; i < 3; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  CHECK(662, !polluted && reads > 0);
  return 0;
}

// K14i: UNBOUNDED VMOs, Zircon's MAX_SIZE long with the requested size as
// their content size. Range operations over all of one cost what is
// present: each of these would take hours page by page.
static int64_t unbounded(const startup_t *s) {
  const uint64_t max = 0xFFFFFFFFFFFF0000ull, far = 1ull << 60;
  uint32_t vmo = 0, bad = 0, child = 0, slice = 0, st = 0;
  uint64_t size = 0, counts[2] = {0, 0}, mapped = 0, actual = 0;
  croi_info_vmo_t v;
  CHECK(663, sys(CROI_SYS_VMO_CREATE, max + 1, 0, (uint64_t)&bad, 0, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_VMO_CREATE, max + 1, CROI_VMO_CREATE_UNBOUNDED, (uint64_t)&bad, 0, 0) ==
                     ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_VMO_CREATE, 4 * PAGE + 100, CROI_VMO_CREATE_UNBOUNDED, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_GET_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == max &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == 4 * PAGE + 100 &&
                 get_info(vmo, CROI_INFO_VMO, &v, sizeof v, counts) == 0 && v.size_bytes == max &&
                 v.committed_bytes == 0 && sys(CROI_SYS_VMO_SET_SIZE, vmo, PAGE, 0, 0, 0) == ERR_UNAVAILABLE);
  // A page far out: written, read, mapped, a child's and a slice's.
  CHECK(664, vmo_put(vmo, far, 'U') && vmo_byte(vmo, far) == 'U' && committed_of(vmo, 0) == PAGE &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, vmo, far - PAGE, 2 * PAGE,
                      (uint64_t)&mapped) == 0 &&
                 *(volatile uint8_t *)(mapped + PAGE) == 'U' &&
                 sys(CROI_SYS_VMAR_UNMAP, s->vmar, mapped, 2 * PAGE, 0, 0) == 0 &&
                 vmo_child(vmo, CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE, far, PAGE, &child) == 0 &&
                 vmo_byte(child, 0) == 'U' && vmo_child(vmo, CROI_VMO_CHILD_SLICE, far - PAGE, 2 * PAGE, &slice) == 0 &&
                 vmo_byte(slice, PAGE) == 'U');
  sys(CROI_SYS_HANDLE_CLOSE, child, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, slice, 0, 0, 0, 0);
  // The whole VMO at once: cache clean, ZERO, DECOMMIT.
  CHECK(665, vmo_put(vmo, max - 1, 'Z') &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_CACHE_CLEAN, 0, max, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_ZERO, 1, max - 2, 0, 0) == 0 &&
                 vmo_byte(vmo, far) == 0 && vmo_byte(vmo, max - 1) == 'Z' && committed_of(vmo, 0) == 2 * PAGE &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, 0, max, 0, 0) == 0 &&
                 committed_of(vmo, 0) == 0);
  // A stream writes far out (the gap from the content size zeroed), and
  // the content size cut back zeroes everything past it.
  croi_iovec_t hello = {(void *)"hello", 5};
  CHECK(666, sys(CROI_SYS_STREAM_CREATE, CROI_STREAM_MODE_READ | CROI_STREAM_MODE_WRITE, vmo, 0, (uint64_t)&st, 0) == 0 &&
                 sys6(CROI_SYS_STREAM_WRITEV_AT, st, 0, far, (uint64_t)&hello, 1, (uint64_t)&actual) == 0 &&
                 actual == 5 && sys(CROI_SYS_VMO_GET_STREAM_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 &&
                 size == far + 5 && vmo_byte(vmo, far + 4) == 'o' &&
                 sys(CROI_SYS_VMO_SET_STREAM_SIZE, vmo, 10, 0, 0, 0) == 0 && vmo_byte(vmo, far + 4) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, st, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  // A pager VMO: refusals, sizes, a page supplied far out, dirty ranges
  // and writeback over the whole VMO, detach.
  uint32_t pg = 0, port = 0, aux = 0;
  croi_vmo_dirty_range_t ranges[4];
  CHECK(667, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&pg, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, CROI_VMO_UNBOUNDED, port, 94, max + 1, (uint64_t)&bad) ==
                     ERR_OUT_OF_RANGE &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, CROI_VMO_UNBOUNDED, port, 94, 100, (uint64_t)&vmo) == 0 &&
                 sys(CROI_SYS_VMO_GET_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == max &&
                 sys(CROI_SYS_VMO_GET_STREAM_SIZE, vmo, (uint64_t)&size, 0, 0, 0) == 0 && size == 100 &&
                 sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&aux, 0, 0) == 0 && vmo_put(aux, 0, 'P') &&
                 sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, vmo, far, PAGE, aux, 0) == 0 && vmo_byte(vmo, far) == 'P' &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)vmo << 32, 0, max, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[0] == 0 && counts[1] == 0);
  CHECK(668, vmo_put(vmo, far, 'W') &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)vmo << 32, 0, max, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[0] == 1 && ranges[0].offset == far &&
                 ranges[0].length == PAGE &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_BEGIN, vmo, 0, max, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_END, vmo, 0, max, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)vmo << 32, 0, max, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 && counts[0] == 0 &&
                 sys(CROI_SYS_PAGER_DETACH_VMO, pg, vmo, 0, 0, 0) == 0 && committed_of(vmo, 0) == 0);
  uint32_t handles[] = {vmo, aux, port, pg};
  for (int i = 0; i < 4; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0;
}

// K14k: zero intervals. Every page is supplied up front, so nothing here
// waits for a pager; a page the pager is asked for again is supplied.
static int dirty_ranges(uint32_t pg, uint32_t vmo, uint64_t end, croi_vmo_dirty_range_t *ranges, uint64_t *count) {
  uint64_t counts[2] = {0, 0};
  if (sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, pg | (uint64_t)vmo << 32, 0, end, (uint64_t)ranges,
           8 * sizeof *ranges, (uint64_t)counts) != 0)
    return 0;
  *count = counts[0];
  return 1;
}

static int range_is(const croi_vmo_dirty_range_t *r, uint64_t offset, uint64_t length, uint64_t options) {
  return r->offset == offset && r->length == length && r->options == options;
}

static int64_t zero_intervals(const startup_t *s) {
  const uint64_t Z = CROI_VMO_DIRTY_RANGE_IS_ZERO;
  uint32_t pg = 0, port = 0, vmo = 0, aux = 0, iommu = 0, bti = 0, pmt = 0;
  uint64_t n = 0, addr = 0, mapped = 0;
  uint8_t desc = 0;
  croi_vmo_dirty_range_t r[8];
  CHECK(669, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&pg, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, 0, port, 95, 8 * PAGE, (uint64_t)&vmo) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, 8 * PAGE, 0, (uint64_t)&aux, 0, 0) == 0);
  for (int i = 0; i < 8; i++) vmo_put(aux, (uint64_t)i * PAGE, (uint8_t)('a' + i)), vmo_put(aux, (uint64_t)i * PAGE + 99, 'q');
  // ZERO from inside page 1 to page 6: page 1's tail zeroed in place (dirty),
  // pages 2-5 a dirty zero interval, dropped; reading it commits nothing.
  CHECK(670, sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, vmo, 0, 8 * PAGE, aux, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, aux, 0, 0, 0, 0) == 0 &&  // emptied: a fresh one for later supplies
                 sys(CROI_SYS_VMO_CREATE, 8 * PAGE, 0, (uint64_t)&aux, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_ZERO, PAGE + 100, 5 * PAGE - 100, 0, 0) == 0 &&
                 vmo_byte(vmo, PAGE + 99) == 'q' && vmo_byte(vmo, PAGE + 100) == 0 && vmo_byte(vmo, 3 * PAGE) == 0 &&
                 vmo_byte(vmo, 6 * PAGE) == 'g' && committed_of(vmo, 0) == 4 * PAGE &&
                 dirty_ranges(pg, vmo, 8 * PAGE, r, &n) && n == 2 && range_is(&r[0], PAGE, PAGE, 0) &&
                 range_is(&r[1], 2 * PAGE, 4 * PAGE, Z));
  // A write and a read fault inside it commit dirty zero pages, splitting it.
  CHECK(671, vmo_put(vmo, 4 * PAGE, 'W') && vmo_byte(vmo, 4 * PAGE) == 'W' &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, vmo, 3 * PAGE, PAGE,
                      (uint64_t)&mapped) == 0 &&
                 *(volatile uint8_t *)mapped == 0 && sys(CROI_SYS_VMAR_UNMAP, s->vmar, mapped, PAGE, 0, 0) == 0 &&
                 dirty_ranges(pg, vmo, 8 * PAGE, r, &n) && n == 4 && range_is(&r[0], PAGE, PAGE, 0) &&
                 range_is(&r[1], 2 * PAGE, PAGE, Z) && range_is(&r[2], 3 * PAGE, 2 * PAGE, 0) &&
                 range_is(&r[3], 5 * PAGE, PAGE, Z));
  // Written back as zeros (IS_ZERO): the intervals go, the pages stay
  // dirty; the pager owns pages 2 and 5 again (a supply lands).
  CHECK(672, sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_BEGIN, vmo, 0, 8 * PAGE, Z) == 0 &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_END, vmo, 0, 8 * PAGE, 0) == 0 &&
                 dirty_ranges(pg, vmo, 8 * PAGE, r, &n) && n == 2 && range_is(&r[0], PAGE, PAGE, 0) &&
                 range_is(&r[1], 3 * PAGE, 2 * PAGE, 0) && vmo_put(aux, 2 * PAGE, 'C') && vmo_put(aux, 5 * PAGE, 'F') &&
                 sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, vmo, 2 * PAGE, PAGE, aux, 2 * PAGE) == 0 &&
                 sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, vmo, 5 * PAGE, PAGE, aux, 5 * PAGE) == 0 &&
                 vmo_byte(vmo, 2 * PAGE) == 'C' && vmo_byte(vmo, 5 * PAGE) == 'F');
  // A stream size cut: zeroed up to its page end (dirty), past it an
  // untracked interval (page 7 dropped, reading zero, never reported).
  CHECK(673, sys(CROI_SYS_VMO_SET_STREAM_SIZE, vmo, 6 * PAGE + 10, 0, 0, 0) == 0 &&
                 vmo_byte(vmo, 6 * PAGE) == 'g' && vmo_byte(vmo, 6 * PAGE + 99) == 0 && vmo_byte(vmo, 7 * PAGE) == 0 &&
                 dirty_ranges(pg, vmo, 8 * PAGE, r, &n) && n == 3 && range_is(&r[2], 6 * PAGE, PAGE, 0));
  // A pinned page in a ZERO is zeroed in place, stays, and is dirty.
  CHECK(674, sys(CROI_SYS_IOMMU_CREATE, s->resource, CROI_IOMMU_TYPE_STUB, (uint64_t)&desc, 1, (uint64_t)&iommu) == 0 &&
                 sys(CROI_SYS_BTI_CREATE, iommu, 0, 0, (uint64_t)&bti, 0) == 0 &&
                 bti_pin(bti, CROI_BTI_PERM_READ, vmo, 1, 0, PAGE, &addr, &pmt) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_ZERO, 0, PAGE, 0, 0) == 0 && vmo_byte(vmo, 0) == 0 &&
                 dirty_ranges(pg, vmo, 8 * PAGE, r, &n) && n == 3 && range_is(&r[0], 0, 2 * PAGE, 0) &&
                 sys(CROI_SYS_PMT_UNPIN, pmt, 0, 0, 0, 0) == 0);
  sys(CROI_SYS_PAGER_DETACH_VMO, pg, vmo, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  // All of an UNBOUNDED pager VMO zeroed at once: one interval.
  const uint64_t max = 0xFFFFFFFFFFFF0000ull;
  CHECK(675, sys6(CROI_SYS_PAGER_CREATE_VMO, pg, CROI_VMO_UNBOUNDED, port, 96, 0, (uint64_t)&vmo) == 0 &&
                 sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, vmo, 1ull << 50, PAGE, aux, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_ZERO, 0, max, 0, 0) == 0 && committed_of(vmo, 0) == 0 &&
                 vmo_byte(vmo, 1ull << 50) == 0 && dirty_ranges(pg, vmo, max, r, &n) && n == 1 &&
                 range_is(&r[0], 0, max, Z) &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_BEGIN, vmo, 0, max, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_WRITEBACK_END, vmo, 0, max, 0) == 0 &&
                 dirty_ranges(pg, vmo, max, r, &n) && n == 0);
  sys(CROI_SYS_PAGER_DETACH_VMO, pg, vmo, 0, 0, 0);
  uint32_t handles[] = {vmo, aux, port, pg, bti, iommu};
  for (int i = 0; i < 6; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0;
}

// K14p: user code's pointer authentication key isn't the kernel's. User
// code signs a value with PACIA1716 (hint-space: unchanged where PAC is off)
// and asks the kernel for its own key's signature of the same value.
// Review fixes: a mapping's rights never grow past what its VMO handle
// allowed (the vDSO's code and a read-only handle's mapping can't be
// protected writable), and a physical range that wraps is refused.
static int64_t mapping_ceilings(const startup_t *s, uint64_t vdso_base) {
  uint32_t vmo = 0, readOnly = 0, physical = 0;
  uint64_t at = 0;
  CHECK(686, sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, vmo, RIGHT_READ | RIGHT_MAP, (uint64_t)&readOnly, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, 0, readOnly, 0, PAGE,
                      (uint64_t)&at) == 0 &&
                 sys(CROI_SYS_VMAR_PROTECT, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, at,
                     PAGE, 0, 0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_VMAR_PROTECT, s->vmar | (uint64_t)CROI_VM_PERM_READ << 32, at, PAGE, 0, 0) == 0);
  CHECK(687, sys(CROI_SYS_VMAR_PROTECT, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32,
                 vdso_base, PAGE, 0, 0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_VMAR_PROTECT, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_EXECUTE) << 32,
                     vdso_base, PAGE, 0, 0) == 0);
  CHECK(688, sys(CROI_SYS_VMO_CREATE_PHYSICAL, s->resource, PAGE, 0ull - PAGE, (uint64_t)&physical, 0) != 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, at, PAGE, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, readOnly, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  return 0;
}

// Review round 1, part 2: what used to panic the kernel or reach freed or
// live kernel memory now fails cleanly.
static uint32_t unstarted_thread(const startup_t *s, uint64_t *sp) {
  uint32_t thread = 0, stack = 0;
  uint64_t at = 0;
  CHECK(140, sys(CROI_SYS_VMO_CREATE, STACK_SIZE, 0, (uint64_t)&stack, 0, 0) == 0);
  CHECK(141, sys(CROI_SYS_VMO_MAP, stack, 0, STACK_SIZE, 3, (uint64_t)&at) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, stack, 0, 0, 0, 0);
  CHECK(142, sys6(CROI_SYS_THREAD_CREATE, s->process, (uint64_t)"t", 1, 0, (uint64_t)&thread, 0) == 0);
  *sp = ENTRY_SP(at + STACK_SIZE);
  return thread;
}

typedef struct {
  uint32_t word, other;
} futex_cycle_t;

static void futex_cycle_waiter(uint64_t arg) {
  futex_cycle_t *c = (futex_cycle_t *)arg;
  sys(CROI_SYS_FUTEX_WAIT, (uint64_t)&c->word, 0, c->other, now_ns() + 50000000ull, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static void nap_then_exit(uint64_t ns) {
  sys(CROI_SYS_NANOSLEEP, now_ns() + ns, 0, 0, 0, 0);
  sys(CROI_SYS_NANOSLEEP, now_ns() + 1000000, 0, 0, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static void timer_setter(uint64_t timer) {
  for (int i = 0; i < 3000; i++) sys(CROI_SYS_TIMER_SET, timer, now_ns() + 1000000000ull, 0, 0, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int ended(uint32_t thread) {
  int done = (wait_for(thread, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull) & CROI_SIGNAL_TASK_TERMINATED) != 0;
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
  return done;
}

static int64_t review_fixes(const startup_t *s) {
  // Two futex waits naming each other's thread as owner: the second is a
  // cycle through its own waiter (inheritance looped until a panic).
  futex_cycle_t cycle[2] = {{0, 0}, {0, 0}};
  uint64_t sp0 = 0, sp1 = 0;
  uint32_t t0 = unstarted_thread(s, &sp0), t1 = unstarted_thread(s, &sp1);
  cycle[0].other = t1;
  cycle[1].other = t0;
  CHECK(689, sys(CROI_SYS_THREAD_START, t0, (uint64_t)futex_cycle_waiter, sp0, (uint64_t)&cycle[0], 0) == 0 &&
                 sys(CROI_SYS_THREAD_START, t1, (uint64_t)futex_cycle_waiter, sp1, (uint64_t)&cycle[1], 0) == 0 &&
                 ended(t0) && ended(t1));
  // A thread suspended before its first entry has no user registers yet
  // (its kernel stack top was live kernel frames).
  uint64_t sp = 0;
  uint32_t parked = unstarted_thread(s, &sp), token = 0;
  croi_thread_state_general_regs_t regs;
  CHECK(690, sys(CROI_SYS_TASK_SUSPEND, parked, (uint64_t)&token, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_THREAD_START, parked, (uint64_t)nap_then_exit, sp, 1000, 0) == 0 &&
                 (wait_for(parked, CROI_THREAD_SUSPENDED, 2000000000ull) & CROI_THREAD_SUSPENDED) &&
                 sys(CROI_SYS_THREAD_READ_STATE, parked, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs, sizeof regs,
                     0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_THREAD_WRITE_STATE, parked, CROI_THREAD_STATE_GENERAL_REGS, (uint64_t)&regs,
                     sizeof regs, 0) == ERR_BAD_STATE);
  sys(CROI_SYS_HANDLE_CLOSE, token, 0, 0, 0, 0);
  CHECK(690, ended(parked));
  // Offsets that wrap past 2^64: out of range, not a trap.
  uint32_t vmo = 0, slice = 0;
  CHECK(691, sys(CROI_SYS_VMO_CREATE, 2 * PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE_CHILD, vmo, CROI_VMO_CHILD_SLICE, PAGE, PAGE, (uint64_t)&slice) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, slice, CROI_VMO_OP_COMMIT, 0ull - PAGE, 0, 0, 0) == ERR_OUT_OF_RANGE);
  sys(CROI_SYS_HANDLE_CLOSE, slice, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  CHECK(692, sys6(CROI_SYS_TRACE_CONFIGURE, s->resource, CROI_TRACE_OP_START, 0, 1ull << 63, 0, 0) == ERR_INVALID_ARGS);
  // A 2 s budget every 10 s, waking with budget left (its CBS products
  // passed 2^64).
  uint32_t profile = 0, napper = 0, refusal = 0;
  CHECK(693, deadline_profile(s->resource, 2000000000ll, 10000000000ll, 10000000000ll, &profile) == 0 &&
                 (napper = start_thread(s, nap_then_exit, 20000000)) != 0 &&
                 sys(CROI_SYS_OBJECT_SET_PROFILE, napper, profile, 0, (uint64_t)&refusal, 0) == 0 && ended(napper));
  sys(CROI_SYS_HANDLE_CLOSE, profile, 0, 0, 0, 0);
  // Two threads setting one timer at once (both armed its node: a panic).
  uint32_t timer = 0;
  CHECK(694, sys(CROI_SYS_TIMER_CREATE, 0, 0, (uint64_t)&timer, 0, 0) == 0);
  uint32_t a = start_thread(s, timer_setter, timer), b = start_thread(s, timer_setter, timer);
  CHECK(694, ended(a) && ended(b));
  sys(CROI_SYS_HANDLE_CLOSE, timer, 0, 0, 0, 0);
  return 0;
}

// Review round 1, the medium items.
typedef struct {
  uint32_t channel, tag;
  int64_t result;
  uint32_t reply[2];
} crossed_call_t;

static void crossed_caller(uint64_t arg) {
  crossed_call_t *c = (crossed_call_t *)arg;
  uint32_t request[2] = {0, c->tag};
  croi_channel_call_args_t args = {(uint64_t)request, 0, (uint64_t)c->reply, 0, sizeof request, 0, sizeof c->reply, 0};
  uint32_t bytes = 0, handles = 0;
  c->result = sys6(CROI_SYS_CHANNEL_CALL, c->channel, 0, now_ns() + 3000000000ull, (uint64_t)&args, (uint64_t)&bytes,
                   (uint64_t)&handles);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// Answers the call waiting in `channel` with tag + 100.
static int answer(uint32_t channel) {
  uint32_t message[2] = {0, 0}, actual[2] = {0, 0};
  if (!(wait_for(channel, CROI_SIGNAL_READABLE, 2000000000ull) & CROI_SIGNAL_READABLE) ||
      chan_read(channel, message, 0, sizeof message, 0, actual) != 0 || actual[0] != sizeof message)
    return 0;
  message[1] += 100;
  return chan_write(channel, message, sizeof message, 0, 0) == 0;
}

typedef struct {
  uint32_t channel, port;
  volatile int32_t refusedAt;
} flood_t;

static void flood(uint64_t arg) {
  flood_t *f = (flood_t *)arg;
  uint64_t message = 0;
  for (int i = 0; i < 3501; i++) chan_write(f->channel, &message, sizeof message, 0, 0);
  croi_port_packet_t packet = {};
  for (int i = 0; i < 5000; i++) {
    if (sys(CROI_SYS_PORT_QUEUE, f->port, (uint64_t)&packet, 0, 0, 0) == ERR_SHOULD_WAIT) {
      f->refusedAt = i;
      break;
    }
  }
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// The next exception is a POLICY_ERROR with `code`; resumed.
static int policy_exception(uint32_t channel, uint32_t code) {
  croi_exception_info_t info = {};
  uint32_t exception = 0, thread = 0, handled = CROI_EXCEPTION_STATE_HANDLED;
  croi_exception_report_t report = {};
  uint64_t counts[2];
  int ok = next_exception(channel, &info, &exception) && info.type == CROI_EXCP_POLICY_ERROR &&
           sys(CROI_SYS_EXCEPTION_GET_THREAD, exception, (uint64_t)&thread, 0, 0, 0) == 0 &&
           sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD_EXCEPTION_REPORT, (uint64_t)&report, sizeof report,
                (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
           report.context.synth_code == code &&
           sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&handled, 4, 0) == 0;
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0);
  return ok;
}

static int64_t review_medium(const startup_t *s) {
  // Both ends call at once: each request reaches the other end's queue
  // (their first txids are equal, and B's request was taken as A's reply).
  uint32_t a = 0, b = 0;
  CHECK(695, sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&a, (uint64_t)&b, 0, 0) == 0);
  crossed_call_t x = {a, 1, 1, {0, 0}}, y = {b, 2, 1, {0, 0}};
  uint32_t tx = start_thread(s, crossed_caller, (uint64_t)&x);
  sleep_ns(20000000);
  uint32_t ty = start_thread(s, crossed_caller, (uint64_t)&y);
  sleep_ns(20000000);
  CHECK(695, answer(b) && answer(a) && ended(tx) && ended(ty) && x.result == 0 && x.reply[1] == 101 &&
                 y.result == 0 && y.reply[1] == 102);
  sys(CROI_SYS_HANDLE_CLOSE, a, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, b, 0, 0, 0, 0);
  // Zircon's limits: a channel's 3501st queued message and a port's user
  // packets past 4096 raise policy exceptions (here handled and resumed).
  flood_t f = {0, 0, -1};
  uint32_t reader = 0;
  uint64_t sp = 0;
  CHECK(696, sys(CROI_SYS_CHANNEL_CREATE, 0, (uint64_t)&f.channel, (uint64_t)&reader, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&f.port, 0, 0, 0) == 0);
  uint32_t flooder = unstarted_thread(s, &sp), channel = exception_channel(flooder);
  CHECK(696, sys(CROI_SYS_THREAD_START, flooder, (uint64_t)flood, sp, (uint64_t)&f, 0) == 0 &&
                 policy_exception(channel, CROI_EXCP_POLICY_CODE_CHANNEL_FULL_WRITE));
  CHECK(697, policy_exception(channel, CROI_EXCP_POLICY_CODE_PORT_TOO_MANY_PACKETS) && ended(flooder) &&
                 f.refusedAt == 4097);
  uint32_t handles[] = {channel, f.channel, reader, f.port};
  for (int i = 0; i < 4; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0;
}

// Review round 1, the entry/exit code.
#if defined(__x86_64__)
static void far_return_to_32bit(uint64_t unused) {
  (void)unused;
  __asm__ volatile("pushq $0x1b\n"
                   "leaq 1f(%%rip), %%rax\n"
                   "pushq %%rax\n"
                   "lretq\n"
                   "1: ud2\n" ::: "rax", "memory");
}
#endif

#if defined(__aarch64__)
// Leaves `marker` in this CPU's TPIDR_EL0 (spinning a while so that the
// markers spread over every CPU).
static void mark_tls_and_exit(uint64_t marker) {
  __asm__ volatile("msr tpidr_el0, %0" ::"r"(marker));
  uint64_t until = now_ns() + 30000000;
  while (now_ns() < until) {
  }
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static void read_tls_and_exit(uint64_t slot) {
  uint64_t tls;
  __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tls));
  *(volatile uint64_t *)slot = tls;
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}
#endif

#if defined(__x86_64__)
typedef struct {
  uint32_t self;
  int64_t result;
} fs_probe_t;

// Asks for a kernel-half FS base for itself.
static void kernel_fs_base(uint64_t arg) {
  fs_probe_t *p = (fs_probe_t *)arg;
  uint64_t base = 0xffff800000001000ull;
  p->result = sys(CROI_SYS_OBJECT_SET_PROPERTY, p->self, CROI_PROP_REGISTER_FS, (uint64_t)&base, 8, 0);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}
#endif

// The low items: FS/GS bases in user space only, PSCI 1.3's SYSTEM_OFF2
// the kernel's.
static int64_t review_low(const startup_t *s) {
#if defined(__x86_64__)
  uint64_t sp = 0;
  fs_probe_t probe = {0, 1};
  probe.self = unstarted_thread(s, &sp);
  CHECK(701, sys(CROI_SYS_THREAD_START, probe.self, (uint64_t)kernel_fs_base, sp, (uint64_t)&probe, 0) == 0 &&
                 ended(probe.self) && probe.result == ERR_INVALID_ARGS);
#elif defined(__aarch64__)
  uint32_t off2 = 0;
  CHECK(702, resource_create(s->resource, CROI_RSRC_KIND_SMC, 0xC4000015u, 1, &off2) == ERR_ACCESS_DENIED &&
                 resource_create(s->resource, CROI_RSRC_KIND_SMC, 0x84000015u, 1, &off2) == ERR_ACCESS_DENIED);
#else
  (void)s;
#endif
  return 0;
}

static int64_t review_entry(const startup_t *s) {
  // An entry point outside user space is refused (amd64's iretq faulted
  // in ring 0 on a non-canonical one).
  uint64_t sp = 0;
  uint32_t bad = unstarted_thread(s, &sp);
  CHECK(698, sys(CROI_SYS_THREAD_START, bad, 0x0000800000000000ull, sp, 0, 0) == ERR_INVALID_ARGS);
  sys(CROI_SYS_HANDLE_CLOSE, bad, 0, 0, 0, 0);
#if defined(__x86_64__)
  // The 32-bit user code segment isn't present: a far return to it faults
  // on the segment (it reached 32-bit mode, whose SYSCALL went to an unset
  // CSTAR on AMD).
  uint32_t far = unstarted_thread(s, &sp), channel = exception_channel(far), exception = 0, thread = 0;
  uint32_t exit = CROI_EXCEPTION_STATE_THREAD_EXIT;
  croi_exception_info_t info = {};
  croi_exception_report_t report = {};
  uint64_t counts[2];
  CHECK(699, sys(CROI_SYS_THREAD_START, far, (uint64_t)far_return_to_32bit, sp, 0, 0) == 0 &&
                 next_exception(channel, &info, &exception) && info.type == CROI_EXCP_GENERAL &&
                 sys(CROI_SYS_EXCEPTION_GET_THREAD, exception, (uint64_t)&thread, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, thread, CROI_INFO_THREAD_EXCEPTION_REPORT, (uint64_t)&report,
                      sizeof report, (uint64_t)&counts[0], (uint64_t)&counts[1]) == 0 &&
                 report.context.arch.vector == 11 &&  // #NP
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&exit, 4, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0);
  CHECK(699, ended(far));
  sys(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);
#endif
#if defined(__aarch64__)
  // A new thread starts with its own TLS register (0), not the one the
  // last user thread on its CPU left (ours, here).
  // Spinners leave a marker in every CPU's register first.
  uint64_t saved, slots[8];
  const uint64_t marker = 0x5a5a5a5a00000000ull;
  __asm__ volatile("mrs %0, tpidr_el0" : "=r"(saved));
  __asm__ volatile("msr tpidr_el0, %0" ::"r"(marker));
  uint32_t spinners[8];
  int all = 1;
  for (int i = 0; i < 8; i++) spinners[i] = start_thread(s, mark_tls_and_exit, marker);
  for (int i = 0; i < 8; i++) all &= ended(spinners[i]);
  for (int i = 0; i < 8; i++) {
    slots[i] = 1;
    all &= ended(start_thread(s, read_tls_and_exit, (uint64_t)&slots[i])) && slots[i] == 0;
  }
  __asm__ volatile("msr tpidr_el0, %0" ::"r"(saved));
  CHECK(700, all);
#endif
  return 0;
}

// Negative tests from the second review (sockets, FIFOs, streams).
static int64_t review_queues(const startup_t *s) {
  // A full stream socket read one byte, then page by page: the ring's trim
  // freed every other page (unread data) when both ends fell in one page.
  uint32_t a = 0, b = 0, vmo = 0;
  uint64_t chunk = 0, actual = 0, written = 0;
  CHECK(703, sys(CROI_SYS_SOCKET_CREATE, CROI_SOCKET_STREAM, (uint64_t)&a, (uint64_t)&b, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, vmo,
                      0, PAGE, (uint64_t)&chunk) == 0);
  volatile uint8_t *bytes = (volatile uint8_t *)chunk;
  for (;;) {
    for (uint64_t i = 0; i < PAGE; i++) bytes[i] = (uint8_t)((written / PAGE) + i);
    if (sys(CROI_SYS_SOCKET_WRITE, a, 0, chunk, PAGE, (uint64_t)&actual) != 0) break;
    written += actual;
  }
  uint64_t got = 0;
  int intact = sys(CROI_SYS_SOCKET_READ, b, 0, chunk, 1, (uint64_t)&actual) == 0 && actual == 1 && bytes[0] == 0;
  got = 1;
  while (intact && got < written) {
    uint64_t want = written - got < PAGE ? written - got : PAGE;
    if (sys(CROI_SYS_SOCKET_READ, b, 0, chunk, want, (uint64_t)&actual) != 0 || actual != want) {
      intact = 0;
      break;
    }
    for (uint64_t i = 0; i < actual; i++) {
      uint64_t at = got + i;
      if (bytes[i] != (uint8_t)((at / PAGE) + at % PAGE)) intact = 0;
    }
    got += actual;
  }
  CHECK(703, written >= 64 * PAGE && intact && got == written);
  sys(CROI_SYS_HANDLE_CLOSE, a, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, b, 0, 0, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, chunk, PAGE, 0, 0);
  // Buffers near 2^64: a status, not a trap in the kernel's page-in.
  uint32_t st = 0;
  croi_iovec_t far = {(void *)0xFFFFFFFFFFFFF800ull, 0x1000};
  CHECK(704, sys(CROI_SYS_STREAM_CREATE, CROI_STREAM_MODE_READ | CROI_STREAM_MODE_WRITE, vmo, 0, (uint64_t)&st, 0) == 0 &&
                 sys6(CROI_SYS_STREAM_WRITEV_AT, st, 0, 0, (uint64_t)&far, 1, (uint64_t)&actual) < 0);
  CHECK(705, sys(CROI_SYS_VMO_WRITE, vmo, 0xFFFFFFFFFFFFF800ull, 0, 0x1000, 0) < 0 &&
                 sys(CROI_SYS_VMO_READ, vmo, 0xFFFFFFFFFFFFF800ull, 0, 0x1000, 0) < 0);
  sys(CROI_SYS_HANDLE_CLOSE, st, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  // FIFOs check in Zircon's order: empty or full before the buffer, the
  // peer before the record size.
  uint32_t fa = 0, fb = 0, rec[4] = {1, 2, 3, 4};
  CHECK(706, sys(CROI_SYS_FIFO_CREATE, 4, 4, 0, (uint64_t)&fa, (uint64_t)&fb) == 0 &&
                 sys(CROI_SYS_FIFO_READ, fb, 4, 0, 1, (uint64_t)&actual) == ERR_SHOULD_WAIT &&
                 sys(CROI_SYS_FIFO_WRITE, fa, 4, (uint64_t)rec, 4, (uint64_t)&actual) == 0 && actual == 4 &&
                 sys(CROI_SYS_FIFO_WRITE, fa, 4, 0, 1, (uint64_t)&actual) == ERR_SHOULD_WAIT &&
                 sys(CROI_SYS_HANDLE_CLOSE, fb, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_FIFO_WRITE, fa, 8, (uint64_t)rec, 1, (uint64_t)&actual) == ERR_PEER_CLOSED);
  sys(CROI_SYS_HANDLE_CLOSE, fa, 0, 0, 0, 0);
  return 0;
}

// Negative tests from the second review (pager, VMO ops).
// Review 2's open items (checks 737-): threads for the size lock tests.
// w[0] the stream or VMO, w[1] the result, w[2] done.
static void size_lock_writer(uint64_t arg) {
  volatile int64_t *w = (volatile int64_t *)arg;
  croi_iovec_t one = {(void *)"x", 1};
  uint64_t actual = 0;
  w[1] = sys6(CROI_SYS_STREAM_WRITEV_AT, (uint32_t)w[0], 0, (uint64_t)w[3], (uint64_t)&one, 1, (uint64_t)&actual);
  w[2] = 1;
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static void size_lock_resizer(uint64_t arg) {
  volatile int64_t *w = (volatile int64_t *)arg;
  w[1] = sys(CROI_SYS_VMO_SET_SIZE, (uint32_t)w[0], (uint64_t)w[3], 0, 0, 0);
  w[2] = 1;
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// 740: a pager answering every READ with 'P' pages until told to stop.
// r[0] port, [1] pager, [2] vmo, [3] stop, [4] supplies.
static void race_pager(uint64_t arg) {
  volatile uint64_t *r = (volatile uint64_t *)arg;
  croi_port_packet_t packet;
  char page[PAGE];
  for (int i = 0; i < PAGE; i++) page[i] = 'P';
  while (!r[3]) {
    if (sys(CROI_SYS_PORT_WAIT, (uint32_t)r[0], now_ns() + 50000000ull, (uint64_t)&packet, 0, 0) != 0) continue;
    uint64_t *req = (uint64_t *)&packet.payload;
    if (packet.type != CROI_PKT_TYPE_PAGE_REQUEST || (uint16_t)req[0] != CROI_PAGER_VMO_READ) continue;
    uint32_t aux = 0;
    sys(CROI_SYS_VMO_CREATE, req[2], 0, (uint64_t)&aux, 0, 0);
    for (uint64_t at = 0; at < req[2]; at += PAGE) sys(CROI_SYS_VMO_WRITE, aux, (uint64_t)page, at, PAGE, 0);
    sys6(CROI_SYS_PAGER_SUPPLY_PAGES, (uint32_t)r[1], (uint32_t)r[2], req[1], req[2], aux, 0);
    sys(CROI_SYS_HANDLE_CLOSE, aux, 0, 0, 0, 0);
    r[4]++;
  }
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// 740: reads page 0 until told to stop, keeping the slowest read and any
// failure. q[0] vmo, [1] stop, [2] reads, [3] slowest ns, [4] first error,
// [5] a read's start (0 between reads).
static void race_reader(uint64_t arg) {
  volatile uint64_t *q = (volatile uint64_t *)arg;
  char c = 0;
  while (!q[1]) {
    uint64_t start = now_ns();
    q[5] = start;
    int64_t result = sys(CROI_SYS_VMO_READ, (uint32_t)q[0], (uint64_t)&c, 0, 1, 0);
    q[5] = 0;
    uint64_t took = now_ns() - start;
    if (took > q[3]) q[3] = took;
    if (result != 0 && q[4] == 0) q[4] = (uint64_t)result;
    if (result == 0 && c != 'P' && c != 0 && q[4] == 0) q[4] = 1;
    q[2]++;
  }
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

// K15d: object_get_child (Zircon's), for Todhchai's Inspector.
static uint32_t handle_rights(uint32_t handle) {
  croi_info_handle_basic_t info;
  zero_bytes(&info, sizeof info);
  sys(CROI_SYS_OBJECT_GET_INFO, handle, CROI_INFO_HANDLE_BASIC, (uint64_t)&info, sizeof info, 0);
  return info.rights;
}

static int64_t get_child(const startup_t *s) {
  const uint32_t enumerate = 1u << 8, destroy = 1u << 9, inspect = 1u << 15;
  uint32_t job = 0, thread = 0, process = 0, found = 0, sub = 0, worker = 0, weak = 0, event = 0, none = 0;
  CHECK(746, sys(CROI_SYS_JOB_CREATE, s->job, 0, (uint64_t)&job, 0, 0) == 0);
  process = make_child(s, job, &thread);
  uint64_t jk = koid_of(job), pk = koid_of(process), tk = koid_of(thread);
  start_child(process, thread, 2);  // spins until killed
  // A job's process and child job, by koid; a process's thread with fewer rights.
  CHECK(746, sys(CROI_SYS_OBJECT_GET_CHILD, job, pk, RIGHT_SAME, (uint64_t)&found, 0) == 0 && koid_of(found) == pk &&
                 handle_rights(found) == handle_rights(job));
  CHECK(747, sys(CROI_SYS_OBJECT_GET_CHILD, s->job, jk, RIGHT_SAME, (uint64_t)&sub, 0) == 0 && koid_of(sub) == jk);
  CHECK(748, sys(CROI_SYS_OBJECT_GET_CHILD, found, tk, RIGHT_READ | inspect, (uint64_t)&worker, 0) == 0 &&
                 koid_of(worker) == tk && handle_rights(worker) == (RIGHT_READ | inspect));
  // Refusals, in Zircon's order: a bad handle, no ENUMERATE, rights beyond
  // the parent's, not a child (a grandchild, a thread of a job, nothing).
  CHECK(749, sys(CROI_SYS_HANDLE_DUPLICATE, job, inspect | enumerate, (uint64_t)&weak, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, job, inspect, (uint64_t)&none, 0, 0) == 0 &&
                 sys(CROI_SYS_EVENT_CREATE, 0, (uint64_t)&event, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, 0x12340003, pk, RIGHT_SAME, (uint64_t)&found, 0) == ERR_BAD_HANDLE &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, none, pk, RIGHT_SAME, (uint64_t)&found, 0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, event, pk, RIGHT_SAME, (uint64_t)&found, 0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, weak, pk, inspect | destroy, (uint64_t)&found, 0) == ERR_ACCESS_DENIED &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, weak, pk, RIGHT_SAME | inspect, (uint64_t)&found, 0) == ERR_ACCESS_DENIED);
  uint32_t got = 0;
  CHECK(750, sys(CROI_SYS_OBJECT_GET_CHILD, weak, pk, RIGHT_SAME, (uint64_t)&got, 0) == 0 &&
                 handle_rights(got) == (inspect | enumerate) &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, s->job, pk, RIGHT_SAME, (uint64_t)&found, 0) == ERR_NOT_FOUND &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, job, tk, RIGHT_SAME, (uint64_t)&found, 0) == ERR_NOT_FOUND &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, job, 1, RIGHT_SAME, (uint64_t)&found, 0) == ERR_NOT_FOUND);
  // Dead children aren't found, though handles to them are still open.
  uint32_t process2 = 0;
  CHECK(751, sys(CROI_SYS_OBJECT_GET_CHILD, job, pk, RIGHT_SAME, (uint64_t)&process2, 0) == 0 &&
                 sys(CROI_SYS_TASK_KILL, process, 0, 0, 0, 0) == 0 &&
                 (wait_terminated(process) & CROI_SIGNAL_TASK_TERMINATED) &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, job, pk, RIGHT_SAME, (uint64_t)&found, 0) == ERR_NOT_FOUND &&
                 sys(CROI_SYS_OBJECT_GET_CHILD, process2, tk, RIGHT_SAME, (uint64_t)&found, 0) == ERR_NOT_FOUND);
  // found is still 746's handle: refused calls write nothing.
  uint32_t handles[] = {job, thread, process, sub, worker, weak, event, none, got, process2, found};
  for (int i = 0; i < 11; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0;
}

static int64_t review_open(const startup_t *s) {
  // A stream write waiting for its VMO's pager holds that VMO's size lock
  // only: a write growing another VMO's stream goes ahead (737; one global
  // lock stalled it until the pager answered), while vmo_set_size of the
  // same VMO waits for it (738: the size can't move under the write).
  uint32_t pg = 0, port = 0, paged = 0, ps = 0, anon = 0, as = 0;
  CHECK(737, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&pg, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, CROI_VMO_RESIZABLE, port, 5, 4 * PAGE, (uint64_t)&paged) == 0 &&
                 sys(CROI_SYS_STREAM_CREATE, CROI_STREAM_MODE_WRITE, paged, 0, (uint64_t)&ps, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, 4 * PAGE, 0, (uint64_t)&anon, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_STREAM_SIZE, anon, 0, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_STREAM_CREATE, CROI_STREAM_MODE_WRITE, anon, 0, (uint64_t)&as, 0) == 0);
  volatile int64_t blocked[4] = {ps, 1, 0, 0}, other[4] = {as, 1, 0, 100}, resize[4] = {paged, 1, 0, 2 * PAGE};
  uint32_t t1 = start_thread(s, size_lock_writer, (uint64_t)blocked);
  croi_port_packet_t packet;
  CHECK(737, sys(CROI_SYS_PORT_WAIT, port, now_ns() + 5000000000ull, (uint64_t)&packet, 0, 0) == 0 &&
                 packet.type == CROI_PKT_TYPE_PAGE_REQUEST);
  sleep_ns(20000000);
  uint32_t t2 = start_thread(s, size_lock_writer, (uint64_t)other);
  uint32_t t3 = start_thread(s, size_lock_resizer, (uint64_t)resize);
  for (int i = 0; i < 100 && !other[2]; i++) sleep_ns(10000000);
  sleep_ns(50000000);
  int64_t other_done = other[2], other_result = other[1], resize_early = resize[2];
  // The pager answers: the write lands, then the resize.
  uint32_t aux = 0;
  sys(CROI_SYS_VMO_CREATE, 4 * PAGE, 0, (uint64_t)&aux, 0, 0);
  sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, paged, 0, 4 * PAGE, aux, 0);
  join(t1);
  join(t2);
  join(t3);
  uint64_t size = 0;
  CHECK(737, other_done && other_result == 0);
  CHECK(745, blocked[1] == 0);  // the blocked write landed once supplied
  CHECK(738, !resize_early && resize[1] == 0 &&
                 sys(CROI_SYS_VMO_GET_SIZE, paged, (uint64_t)&size, 0, 0, 0) == 0 && size == 2 * PAGE);
  uint32_t handles[] = {pg, port, paged, ps, anon, as, aux};
  for (int i = 0; i < 7; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);

  // 739: op DIRTY over a dirty zero interval (a TRAP_DIRTY VMO's grown
  // space) commits zero pages there, dirty (Zircon's; it was NOT_FOUND).
  uint32_t tp = 0, tport = 0, tv = 0;
  croi_vmo_dirty_range_t ranges[4];
  uint64_t counts[2] = {0, 0};
  croi_info_vmo_t info;
  zero_bytes(&info, sizeof info);
  char byte = 1;
  CHECK(739, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&tp, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&tport, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, tp, CROI_VMO_TRAP_DIRTY | CROI_VMO_RESIZABLE, tport, 9, PAGE,
                      (uint64_t)&tv) == 0 &&
                 sys(CROI_SYS_VMO_SET_SIZE, tv, 3 * PAGE, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, tp, CROI_PAGER_OP_DIRTY, tv, PAGE, 2 * PAGE, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_QUERY_DIRTY_RANGES, tp | (uint64_t)tv << 32, 0, 3 * PAGE, (uint64_t)ranges,
                      sizeof ranges, (uint64_t)counts) == 0 &&
                 counts[0] == 1 && ranges[0].offset == PAGE && ranges[0].length == 2 * PAGE && ranges[0].options == 0 &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, tv, CROI_INFO_VMO, (uint64_t)&info, sizeof info, 0, 0) == 0 &&
                 info.committed_bytes == 2 * PAGE &&
                 sys(CROI_SYS_VMO_READ, tv, (uint64_t)&byte, 2 * PAGE + 7, 1, 0) == 0 && byte == 0);
  sys(CROI_SYS_HANDLE_CLOSE, tv, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, tport, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, tp, 0, 0, 0, 0);

  // 740: a reader racing ZEROs: each round ZERO makes page 0 a zero
  // interval and a writeback hands it back to the pager. A read that saw
  // the gap just before a ZERO used to wait for a supply that never comes
  // (it skips zero intervals): 300 s. Every read here finishes promptly.
  uint32_t rp = 0, rport = 0, rv = 0;
  CHECK(740, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&rp, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&rport, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, rp, 0, rport, 3, PAGE, (uint64_t)&rv) == 0);
  volatile uint64_t r[5] = {rport, rp, rv, 0, 0}, q[6] = {rv, 0, 0, 0, 0, 0};
  uint32_t server = start_thread(s, race_pager, (uint64_t)r), reader = start_thread(s, race_reader, (uint64_t)q);
  int stuck = 0;
  for (int round = 0; round < 3000 && !stuck; round++) {
    sys6(CROI_SYS_VMO_OP_RANGE, rv, CROI_VMO_OP_ZERO, 0, PAGE, 0, 0);
    sys6(CROI_SYS_PAGER_OP_RANGE, rp, CROI_PAGER_OP_WRITEBACK_BEGIN, rv, 0, PAGE, 0);
    sys6(CROI_SYS_PAGER_OP_RANGE, rp, CROI_PAGER_OP_WRITEBACK_END, rv, 0, PAGE, 0);
    uint64_t since = q[5];
    if (since != 0 && now_ns() - since > 1000000000ull) stuck = 1;
  }
  for (int i = 0; i < 100 && !stuck; i++) {  // the last read, if any, finishes
    uint64_t since = q[5];
    if (since == 0) break;
    if (now_ns() - since > 1000000000ull) stuck = 1;
    sleep_ns(20000000);
  }
  uint64_t reads = q[2], slowest = q[3], error = q[4];
  q[1] = 1;
  r[3] = 1;
  sys6(CROI_SYS_PAGER_OP_RANGE, rp, CROI_PAGER_OP_FAIL, rv, 0, PAGE, (uint64_t)(int64_t)-40);  // frees a stuck reader
  join(reader);
  join(server);
  CHECK(741, !stuck);
  CHECK(742, reads > 100);
  CHECK(743, slowest < 1000000000ull);
  CHECK(744, error == 0);
  sys(CROI_SYS_HANDLE_CLOSE, rv, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, rport, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, rp, 0, 0, 0, 0);
  return 0;
}

static int64_t review_pager(const startup_t *s) {
  (void)s;
  uint32_t big = 0, anon = 0, ro = 0;
  croi_info_vmo_t info;
  zero_bytes(&info, sizeof info);  // (= {} calls memset, which this program lacks)
  uint64_t counts[2];
  CHECK(707, sys(CROI_SYS_VMO_CREATE, PAGE, CROI_VMO_RESIZABLE, (uint64_t)&big, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_SET_SIZE, big, 0xFFFFFFFFFFFFF000ull, 0, 0, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_VMO_SET_SIZE, big, 0xFFFFFFFFFFFF0001ull, 0, 0, 0) == ERR_OUT_OF_RANGE);
  // PREFETCH of an anonymous VMO commits nothing (through a READ handle).
  CHECK(708, sys(CROI_SYS_VMO_CREATE, 4 * PAGE, 0, (uint64_t)&anon, 0, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_DUPLICATE, anon, RIGHT_READ, (uint64_t)&ro, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, ro, CROI_VMO_OP_PREFETCH, 0, 4 * PAGE, 0, 0) == 0 &&
                 sys6(CROI_SYS_OBJECT_GET_INFO, anon, CROI_INFO_VMO, (uint64_t)&info, sizeof info, (uint64_t)&counts[0],
                      (uint64_t)&counts[1]) == 0 &&
                 info.committed_bytes == 0);
  // Hints on a VMO no pager backs are ignored, range and all; no
  // invalidate (NOT_SUPPORTED before rights).
  CHECK(709, sys6(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_DONT_NEED, 8 * PAGE, PAGE, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, anon, CROI_VMO_OP_ALWAYS_NEED, 0, ~0ull, 0, 0) == 0);
  CHECK(710, sys6(CROI_SYS_VMO_OP_RANGE, ro, CROI_VMO_OP_CACHE_INVALIDATE, 0, PAGE, 0, 0) == ERR_NOT_SUPPORTED);
  // A supply far past the pager VMO is refused before anything is taken
  // (it listed every page of the 1 TiB range); DIRTY's range before TRAP_DIRTY.
  uint32_t pg = 0, port = 0, paged = 0, aux = 0;
  CHECK(711, sys(CROI_SYS_PAGER_CREATE, 0, (uint64_t)&pg, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_CREATE_VMO, pg, 0, port, 1, 4 * PAGE, (uint64_t)&paged) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, 1ull << 40, 0, (uint64_t)&aux, 0, 0) == 0 &&
                 sys6(CROI_SYS_PAGER_SUPPLY_PAGES, pg, paged, 0, 1ull << 40, aux, 0) == ERR_OUT_OF_RANGE);
  CHECK(712, sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_DIRTY, paged, 8 * PAGE, PAGE, 0) == ERR_OUT_OF_RANGE &&
                 sys6(CROI_SYS_PAGER_OP_RANGE, pg, CROI_PAGER_OP_DIRTY, paged, 0, PAGE, 0) == ERR_NOT_SUPPORTED);
  uint32_t handles[] = {big, anon, ro, pg, port, paged, aux};
  for (int i = 0; i < 7; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0;
}

// K15a: memory accounts (account.h).
static croi_info_memory_account_t account_info(uint32_t account) {
  croi_info_memory_account_t info;
  zero_bytes(&info, sizeof info);
  uint64_t counts[2];
  sys6(CROI_SYS_OBJECT_GET_INFO, account, CROI_INFO_MEMORY_ACCOUNT, (uint64_t)&info, sizeof info, (uint64_t)&counts[0],
       (uint64_t)&counts[1]);
  return info;
}

static int pressure_packet(uint32_t port, uint64_t level, uint64_t charged) {
  croi_port_packet_t packet;
  zero_bytes(&packet, sizeof packet);
  return sys(CROI_SYS_PORT_WAIT, port, now_ns() + 1000000000ull, (uint64_t)&packet, 0, 0) == 0 &&
         packet.type == CROI_PKT_TYPE_MEMORY_PRESSURE && packet.key == 0xACC && packet.payload[3] == level &&
         packet.payload[1] == charged && packet.payload[0] == 8 * PAGE;
}

static int64_t memory_accounts(const startup_t *s) {
  uint32_t account = 0, port = 0, vmo = 0;
  // 8 pages; warning at 50% (4 pages), critical at 75% (6), left below 80%.
  CHECK(713, sys(CROI_SYS_ACCOUNT_CREATE, s->resource, 8 * PAGE, 50 | 75ull << 32, (uint64_t)&account, 0) == 0 &&
                 sys(CROI_SYS_ACCOUNT_CREATE, s->resource, PAGE, 101, (uint64_t)&port, 0) == ERR_INVALID_ARGS &&
                 account_info(account).limit == 8 * PAGE && account_info(account).warning_bytes == 4 * PAGE &&
                 account_info(account).critical_bytes == 6 * PAGE && account_info(account).charged == 0);
  // Charged as pages commit, to the account CHARGE_TO names; NO_MEMORY past it.
  CHECK(714, sys(CROI_SYS_PORT_CREATE, 0, (uint64_t)&port, 0, 0, 0) == 0 &&
                 sys(CROI_SYS_ACCOUNT_BIND_PRESSURE_PORT, account, port, 0xACC, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, 16 * PAGE, CROI_VMO_CHARGE_TO, (uint64_t)&vmo, account, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_COMMIT, 0, 3 * PAGE, 0, 0) == 0 &&
                 account_info(account).charged == 3 * PAGE && account_info(account).level == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_COMMIT, 0, 9 * PAGE, 0, 0) == ERR_NO_MEMORY);
  // The levels, each change a packet: up to warning and critical, then
  // down to normal (decommitted to 2 pages, below 80% of both).
  sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, 0, 16 * PAGE, 0, 0);
  // The failed commit crossed both levels on its way to the limit: drain
  // that packet first.
  croi_port_packet_t stale;
  while (sys(CROI_SYS_PORT_WAIT, port, 0, (uint64_t)&stale, 0, 0) == 0) {}
  CHECK(715, sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_COMMIT, 0, 4 * PAGE, 0, 0) == 0 &&
                 pressure_packet(port, CROI_MEMORY_LEVEL_WARNING, 4 * PAGE));
  CHECK(719, sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_COMMIT, 0, 6 * PAGE, 0, 0) == 0 &&
                 pressure_packet(port, CROI_MEMORY_LEVEL_CRITICAL, 6 * PAGE));
  // Two entries into pressure: the failed commit's, and this one.
  CHECK(720, sys6(CROI_SYS_VMO_OP_RANGE, vmo, CROI_VMO_OP_DECOMMIT, 2 * PAGE, 4 * PAGE, 0, 0) == 0 &&
                 pressure_packet(port, CROI_MEMORY_LEVEL_NORMAL, 2 * PAGE) &&
                 account_info(account).pressure_events == 2);
  // The limit never drops below what is charged.
  CHECK(716, sys(CROI_SYS_ACCOUNT_SET_LIMIT, account, PAGE, 0, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_ACCOUNT_SET_LIMIT, account, 8 * PAGE, 0, 0, 0) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);
  CHECK(716, account_info(account).charged == 0);
  // A snapshot charges the pages it copies in, and gives them back.
  uint32_t source = 0, copy = 0;
  CHECK(721, sys(CROI_SYS_VMO_CREATE, 2 * PAGE, 0, (uint64_t)&source, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, source, CROI_VMO_OP_COMMIT, 0, 2 * PAGE, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMO_CREATE_CHILD, source, CROI_VMO_CHILD_SNAPSHOT | CROI_VMO_CHARGE_TO, 0, 2 * PAGE,
                      (uint64_t)&copy, account) == 0 &&
                 account_info(account).charged == 2 * PAGE &&
                 sys(CROI_SYS_HANDLE_CLOSE, copy, 0, 0, 0, 0) == 0 && account_info(account).charged == 0);
  sys(CROI_SYS_HANDLE_CLOSE, source, 0, 0, 0, 0);
  // A process charges the account it was given (before it starts).
  uint32_t thread = 0, child = make_child(s, s->job, &thread);
  CHECK(717, sys(CROI_SYS_PROCESS_SET_ACCOUNT, child, account, 0, 0, 0) == 0);
  start_child(child, thread, 12);
  uint64_t until = now_ns() + 3000000000ull;
  while (account_info(account).charged != 2 * PAGE && now_ns() < until) sleep_ns(1000000);
  CHECK(717, account_info(account).charged == 2 * PAGE &&
                 sys(CROI_SYS_PROCESS_SET_ACCOUNT, child, account, 0, 0, 0) == ERR_BAD_STATE &&
                 sys(CROI_SYS_TASK_KILL, child, 0, 0, 0, 0) == 0 &&
                 (wait_terminated(child) & CROI_SIGNAL_TASK_TERMINATED));
  sys(CROI_SYS_HANDLE_CLOSE, child, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
  until = now_ns() + 3000000000ull;
  while (account_info(account).charged != 0 && now_ns() < until) sleep_ns(1000000);
  CHECK(717, account_info(account).charged == 0);
  // Device-local: a physical VMO's slice charged in full, until it goes; a
  // reference takes no account.
  if (s->ecam) {
    uint32_t physical = 0, slice = 0, anon = 0, reference = 0;
    CHECK(718, sys(CROI_SYS_VMO_CREATE_PHYSICAL, s->resource, s->ecam, 4 * PAGE, (uint64_t)&physical, 0) == 0 &&
                   sys6(CROI_SYS_VMO_CREATE_CHILD, physical, CROI_VMO_CHILD_SLICE | CROI_VMO_CHARGE_TO, 0, 2 * PAGE,
                        (uint64_t)&slice, account) == 0 &&
                   account_info(account).charged == 2 * PAGE &&
                   sys(CROI_SYS_HANDLE_CLOSE, slice, 0, 0, 0, 0) == 0 && account_info(account).charged == 0 &&
                   sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&anon, 0, 0) == 0 &&
                   sys6(CROI_SYS_VMO_CREATE_CHILD, anon, CROI_VMO_CHILD_REFERENCE | CROI_VMO_CHARGE_TO, 0, 0,
                        (uint64_t)&reference, account) == ERR_INVALID_ARGS);
    sys(CROI_SYS_HANDLE_CLOSE, physical, 0, 0, 0, 0);
    sys(CROI_SYS_HANDLE_CLOSE, anon, 0, 0, 0, 0);
  }
  sys(CROI_SYS_HANDLE_CLOSE, port, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, account, 0, 0, 0, 0);
  return 0;
}

// K15b: reservations, atomic views and the JIT (ext 7).
static croi_info_vmar_jit_t vmar_jit_info(uint32_t vmar) {
  croi_info_vmar_jit_t info = {0, 0, 0, 0};
  uint64_t counts[2];
  sys6(CROI_SYS_OBJECT_GET_INFO, vmar, CROI_INFO_VMAR_JIT, (uint64_t)&info, sizeof info, (uint64_t)&counts[0],
       (uint64_t)&counts[1]);
  return info;
}

#if defined(__x86_64__)
static uint32_t read_pkru(void) {
  uint32_t eax, edx;
  __asm__ volatile("rdpkru" : "=a"(eax), "=d"(edx) : "c"(0));
  return eax;
}
static void write_pkru(uint32_t value) { __asm__ volatile("wrpkru" ::"a"(value), "c"(0), "d"(0) : "memory"); }

static void pkru_reader(uint64_t slot) {
  *(volatile uint32_t *)slot = read_pkru();
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}
#endif

// A function returning 42, as each arch encodes it.
#if defined(__x86_64__)
static const uint8_t answer_code[] = {0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3};  // mov $42, %eax; ret
#elif defined(__aarch64__)
static const uint32_t answer_code[] = {0x52800540, 0xd65f03c0};  // mov w0, #42; ret
#else
static const uint32_t answer_code[] = {0x02a00513, 0x00008067};  // li a0, 42; ret
#endif

static int64_t jit_views(const startup_t *s) {
  const uint32_t all = CROI_VM_CAN_MAP_READ | CROI_VM_CAN_MAP_WRITE | CROI_VM_CAN_MAP_EXECUTE;
  const uint32_t rw = CROI_VM_PERM_READ | CROI_VM_PERM_WRITE, rx = CROI_VM_PERM_READ | CROI_VM_PERM_EXECUTE;
  uint32_t reservation = 0, a = 0, b = 0;
  uint64_t base = 0, at = 0;
  // A reservation: views only.
  CHECK(722, sys6(CROI_SYS_VMAR_ALLOCATE, s->vmar | (uint64_t)(all | CROI_VM_RESERVATION) << 32, 0, 16 * PAGE,
                  (uint64_t)&reservation, (uint64_t)&base, 0) == 0 &&
                 vmar_jit_info(reservation).flags == CROI_VMAR_JIT_FLAG_RESERVATION &&
                 vmar_jit_info(reservation).mechanism == CROI_JIT_MECHANISM_VIEWS &&
                 vmar_jit_info(s->vmar).mechanism == CROI_JIT_MECHANISM_NONE &&
                 sys(CROI_SYS_VMO_CREATE, 2 * PAGE, 0, (uint64_t)&a, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_CREATE, 2 * PAGE, 0, (uint64_t)&b, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, reservation | (uint64_t)rw << 32, 0, a, 0, PAGE, (uint64_t)&at) ==
                     ERR_INVALID_ARGS);
  // A view replaced by another VMO's pages.
  uint32_t one = 1, two = 2;
  volatile uint32_t *word = (volatile uint32_t *)base;
  CHECK(723, sys(CROI_SYS_VMO_WRITE, a, (uint64_t)&one, 0, 4, 0) == 0 &&
                 sys(CROI_SYS_VMO_WRITE, b, (uint64_t)&two, 0, 4, 0) == 0 &&
                 sys(CROI_SYS_VMAR_MAP_VIEW, reservation | (uint64_t)rw << 32, 0, a, 0, 2 * PAGE) == 0 &&
                 *word == 1 &&
                 sys(CROI_SYS_VMAR_MAP_VIEW, reservation | (uint64_t)rw << 32, 0, b, 0, 2 * PAGE) == 0 && *word == 2);
  // W^X outside a JIT reservation with a key; protect and commit on views.
  // (an executable VMO, so that it is W^X that refuses, not the rights)
  uint32_t plain = 0, exec = 0;
  CHECK(724, sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&plain, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_REPLACE_AS_EXECUTABLE, plain, s->resource, (uint64_t)&exec, 0, 0) == 0 &&
                 sys(CROI_SYS_VMAR_MAP_VIEW, reservation | (uint64_t)(rw | CROI_VM_PERM_EXECUTE) << 32, 4 * PAGE, exec,
                     0, PAGE) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_VMAR_MAP_VIEW, reservation | (uint64_t)rx << 32, 4 * PAGE, exec, 0, PAGE) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, exec, 0, 0, 0, 0);
  CHECK(727, sys6(CROI_SYS_VMAR_OP_RANGE, reservation, CROI_VMO_OP_COMMIT, base, 2 * PAGE, 0, 0) == 0 &&
                 sys(CROI_SYS_VMAR_PROTECT, reservation | (uint64_t)CROI_VM_PERM_READ << 32, base, 2 * PAGE, 0, 0) == 0 &&
                 *word == 2);
  sys(CROI_SYS_VMAR_DESTROY, reservation, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, reservation, 0, 0, 0, 0);
  // A reservation at a chosen place.
  uint32_t fixed = 0;
  uint64_t fixed_base = 0, offset = 0x40000000ull;
  CHECK(728, sys6(CROI_SYS_VMAR_ALLOCATE, s->vmar | (uint64_t)(all | CROI_VM_RESERVATION | CROI_VM_SPECIFIC) << 32,
                  offset, 4 * PAGE, (uint64_t)&fixed, (uint64_t)&fixed_base, 0) == 0);
  croi_info_vmar_t root = {0, 0};
  uint64_t counts[2];
  CHECK(728, sys6(CROI_SYS_OBJECT_GET_INFO, s->vmar, CROI_INFO_VMAR, (uint64_t)&root, sizeof root, (uint64_t)&counts[0],
                  (uint64_t)&counts[1]) == 0 &&
                 fixed_base == root.base + offset);
  sys(CROI_SYS_VMAR_DESTROY, fixed, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, fixed, 0, 0, 0, 0);
  // A JIT by dual views: written through RW, called through RX, one
  // executable VMO (VMEX).
  uint32_t jit = 0, raw = 0, code = 0;
  uint64_t jit_base = 0;
  CHECK(725, sys6(CROI_SYS_VMAR_ALLOCATE, s->vmar | (uint64_t)(all | CROI_VM_JIT) << 32, 0, 8 * PAGE, (uint64_t)&jit,
                  (uint64_t)&jit_base, 0) == 0 &&
                 (vmar_jit_info(jit).flags & CROI_VMAR_JIT_FLAG_JIT) &&
                 sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&raw, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_REPLACE_AS_EXECUTABLE, raw, s->resource, (uint64_t)&code, 0, 0) == 0 &&
                 sys(CROI_SYS_VMAR_MAP_VIEW, jit | (uint64_t)rw << 32, 0, code, 0, PAGE) == 0 &&
                 sys(CROI_SYS_VMAR_MAP_VIEW, jit | (uint64_t)rx << 32, 4 * PAGE, code, 0, PAGE) == 0);
  volatile uint8_t *writable = (volatile uint8_t *)jit_base;
  for (unsigned i = 0; i < sizeof answer_code; i++) writable[i] = ((const uint8_t *)answer_code)[i];
  CHECK(725, sys6(CROI_SYS_VMO_OP_RANGE, code, CROI_VMO_OP_CACHE_SYNC, 0, PAGE, 0, 0) == 0 &&
                 ((uint64_t (*)(void))(jit_base + 4 * PAGE))() == 42);
#if defined(__x86_64__)
  // With protection keys: an RWX view; writes open for this thread alone
  // (WRPKRU), kept across a switch; another thread's stay closed.
  if (vmar_jit_info(jit).mechanism == CROI_JIT_MECHANISM_PROTECTION_KEYS) {
    uint32_t key = vmar_jit_info(jit).key, closed = read_pkru();
    uint32_t open = closed & ~(3u << (2 * key));
    volatile uint32_t other = 0;
    CHECK(726, key >= 1 && key <= 15 && (closed & (2u << (2 * key))) &&
                   sys(CROI_SYS_VMAR_MAP_VIEW, jit | (uint64_t)(rw | CROI_VM_PERM_EXECUTE) << 32, 2 * PAGE, code, 0,
                       PAGE) == 0);
    write_pkru(open);
    sleep_ns(2000000);  // switched out and back: the PKRU it set comes back
    uint32_t after = read_pkru();
    uint32_t reader = start_thread(s, pkru_reader, (uint64_t)&other);
    int reader_ok = ended(reader);
    write_pkru(closed);
    CHECK(726, after == open && reader_ok && (other & (2u << (2 * key))) != 0);
  }
#endif
  sys(CROI_SYS_VMAR_DESTROY, jit, 0, 0, 0, 0);
  uint32_t handles[] = {jit, code, a, b};
  for (int i = 0; i < 4; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  return 0;
}

// K15c: deadline-aware idle (power.h).
// `all` is a mapped buffer of 128 records (this program has no writable data).
static croi_idle_state_stats_t idle_stats_in(croi_idle_state_stats_t *all, const startup_t *s, uint32_t cpu,
                                             uint32_t state) {
  croi_idle_state_stats_t none;
  zero_bytes(&none, sizeof none);
  uint64_t actual = 0, avail = 0;
  if (sys6(CROI_SYS_OBJECT_GET_INFO, s->resource, CROI_INFO_CPU_IDLE_STATES, (uint64_t)all, 128 * sizeof *all,
           (uint64_t)&actual, (uint64_t)&avail) != 0)
    return none;
  for (uint64_t i = 0; i < actual; i++)
    if (all[i].cpu == cpu && all[i].state == state) return all[i];
  return none;
}

static int64_t idle_states(const startup_t *s) {
  uint32_t buffer_vmo = 0;
  uint64_t buffer = 0;
  CHECK(729, sys(CROI_SYS_VMO_CREATE, 2 * PAGE, 0, (uint64_t)&buffer_vmo, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, buffer_vmo,
                      0, 2 * PAGE, (uint64_t)&buffer) == 0);
  sys(CROI_SYS_HANDLE_CLOSE, buffer_vmo, 0, 0, 0, 0);
#define idle_stats(s, cpu, state) idle_stats_in((croi_idle_state_stats_t *)buffer, s, cpu, state)
  croi_idle_state_t table[9];
  zero_bytes(table, sizeof table);
  for (int i = 0; i < 9; i++) {
    table[i].exit_latency_ns = 1000 * (uint64_t)(i + 1);
    table[i].target_residency_ns = 1000;
    table[i].method = CROI_IDLE_METHOD_HALT;
  }
  // Refusals: too many, latencies out of order, unknown flags, a method
  // this CPU lacks.
  croi_idle_state_t backwards[2] = {table[1], table[0]}, flagged = table[0], foreign = table[0];
  flagged.flags = 1u << 7;
#if defined(__x86_64__)
  foreign.method = CROI_IDLE_METHOD_PSCI;
#else
  foreign.method = CROI_IDLE_METHOD_MWAIT;
#endif
  CHECK(729, sys(CROI_SYS_CPU_SET_IDLE_STATES, s->resource, 0, (uint64_t)table, 9, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_CPU_SET_IDLE_STATES, s->resource, 0, (uint64_t)backwards, 2, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_CPU_SET_IDLE_STATES, s->resource, 0, (uint64_t)&flagged, 1, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_CPU_SET_IDLE_STATES, s->resource, 0, (uint64_t)&foreign, 1, 0) == ERR_NOT_SUPPORTED);
  // CPU 0: a shallow state, and a deep one (10 ms to wake); a third that
  // stops the timer is skipped, never entered.
  croi_idle_state_t three[3] = {table[0], table[1], table[2]};
  three[1].exit_latency_ns = 10000000;
  three[2].exit_latency_ns = 10000000;
  three[2].flags = CROI_IDLE_FLAG_TIMER_STOPS;
  CHECK(730, sys(CROI_SYS_CPU_SET_IDLE_STATES, s->resource, 0, (uint64_t)three, 3, 0) == 0);
  sleep_ns(50000000);
  croi_idle_state_stats_t deep = idle_stats(s, 0, 1), stops = idle_stats(s, 0, 2);
  croi_idle_state_stats_t shallow = idle_stats(s, 0, 0), plain = idle_stats(s, 0, CROI_IDLE_STATE_DEFAULT);
  CHECK(734, shallow.entries + deep.entries + stops.entries + plain.entries + stops.skipped + deep.demoted > 0);  // the info works
  CHECK(735, deep.demoted == 0);
  CHECK(736, stops.skipped > 0);
  CHECK(730, deep.entries > 0 && stops.entries == 0);
  // An interrupt on CPU 0 with a deadline profile (100 us every 1 ms: a
  // bound of ~0.9 ms) keeps CPU 0 out of the 10 ms state until it goes.
  uint32_t v = 0, profile = 0;
  // (The profile makes CPU 0 choose again at once: counted from before it.)
  CHECK(731, deadline_profile(s->resource, 100000, 1000000, 1000000, &profile) == 0 &&
                 sys(CROI_SYS_INTERRUPT_CREATE, 0, 0, CROI_INTERRUPT_VIRTUAL, (uint64_t)&v, 0) == 0);
  croi_idle_state_stats_t before = idle_stats(s, 0, 1);
  CHECK(731, sys(CROI_SYS_OBJECT_SET_PROFILE, v, profile, 0, 0, 0) == 0);
  sleep_ns(50000000);
  croi_idle_state_stats_t during = idle_stats(s, 0, 1);
  sys(CROI_SYS_HANDLE_CLOSE, v, 0, 0, 0, 0);
  sleep_ns(50000000);
  croi_idle_state_stats_t after = idle_stats(s, 0, 1);
  CHECK(731, during.entries == before.entries && during.demoted > before.demoted && after.entries > during.entries);
  sys(CROI_SYS_HANDLE_CLOSE, profile, 0, 0, 0, 0);
  CHECK(731, sys(CROI_SYS_CPU_SET_IDLE_STATES, s->resource, 0, 0, 0, 0) == 0);
  // The hardware's own: MWAIT (amd64, where the CPU has MONITOR) and PSCI
  // standby (arm64), on CPU 0.
  croi_idle_state_t hardware = table[0];
#if defined(__x86_64__)
  hardware.method = CROI_IDLE_METHOD_MWAIT;
  hardware.param = 0;  // C1
  int64_t installed = sys(CROI_SYS_CPU_SET_IDLE_STATES, s->resource, 0, (uint64_t)&hardware, 1, 0);
  CHECK(732, installed == 0 || installed == ERR_NOT_SUPPORTED);
  if (installed == 0) {
    sleep_ns(50000000);
    CHECK(732, idle_stats(s, 0, 0).entries > 0);
  }
#elif defined(__aarch64__)
  hardware.method = CROI_IDLE_METHOD_PSCI;
  hardware.param = 0;  // standby
  CHECK(733, sys(CROI_SYS_CPU_SET_IDLE_STATES, s->resource, 0, (uint64_t)&hardware, 1, 0) == 0);
  sleep_ns(50000000);
  CHECK(733, idle_stats(s, 0, 0).entries > 0);
#endif
  sys(CROI_SYS_CPU_SET_IDLE_STATES, s->resource, 0, 0, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, buffer, 2 * PAGE, 0, 0);
#undef idle_stats
  return 0;
}

static uint64_t pac_sign(uint64_t value, uint64_t modifier) {
#if defined(__aarch64__)
  register uint64_t x17 __asm__("x17") = value;
  register uint64_t x16 __asm__("x16") = modifier;
  __asm__ volatile("hint #8" : "+r"(x17) : "r"(x16));  // pacia1716
  return x17;
#else
  (void)modifier;
  return value;
#endif
}

static void pac_signer(uint64_t out) {
  *(volatile uint64_t *)out = pac_sign(0x0000000001234560ull, 7);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t pointer_auth(const startup_t *s) {
#if defined(__aarch64__)
  const uint64_t value = 0x0000000001234560ull, modifier = 7;
  uint64_t mine = pac_sign(value, modifier);
  uint64_t kernel = (uint64_t)sys6(CROI_SYS_TEST_PROFILE, 11, value, modifier, 0, 0, 0);
  if (kernel == value) return 0;  // PAC off (croi.pac=off, or not implemented)
  CHECK(676, mine != value && mine != kernel);
  // K14s: a key per process: another thread of ours signs alike, a child
  // process differently (its exit code is its signature).
  volatile uint64_t theirs = 0;
  uint32_t thread = start_thread(s, pac_signer, (uint64_t)&theirs);
  uint32_t child = spawn_child(s, s->job, 11);
  CHECK(684, (wait_for(thread, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull) & CROI_SIGNAL_TASK_TERMINATED));
  CHECK(685, theirs == mine);
  CHECK(683, (wait_terminated(child) & CROI_SIGNAL_TASK_TERMINATED) &&
                 (uint64_t)return_code(child) != mine && (uint64_t)return_code(child) != value &&
                 (uint64_t)return_code(child) != kernel);
  sys(CROI_SYS_HANDLE_CLOSE, thread, 0, 0, 0, 0);
  sys(CROI_SYS_HANDLE_CLOSE, child, 0, 0, 0, 0);
#else
  (void)s;
#endif
  return 0;
}

// K14r: guarded user pages (BTI). Two routines in a page: one starting
// with a NOP (no landing pad), one with BTI C. Through a guarded mapping an
// indirect call reaches only the second; through a plain one, either.
__attribute__((noinline)) static uint64_t bti_call(uint64_t routine) {
  return ((uint64_t (*)(void))routine)();  // blr
}

static void bti_stray(uint64_t routine) {
  bti_call(routine);
  sys(CROI_SYS_THREAD_EXIT, 0, 0, 0, 0, 0);
}

static int64_t guarded_pages(const startup_t *s) {
#if defined(__aarch64__)
  if (sys6(CROI_SYS_TEST_PROFILE, 12, 0, 0, 0, 0, 0) != 1) return 0;  // no BTI (croi.bti=off, or none)
  const uint32_t code[8] = {0xd503201f, 0xd2800020, 0xd65f03c0, 0xd503201f,   // nop; mov x0, #1; ret
                            0xd503245f, 0xd2800040, 0xd65f03c0, 0xd503201f};  // bti c; mov x0, #2; ret
  uint32_t vmo = 0;
  uint64_t guarded = 0, plain = 0;
  const uint32_t rx = CROI_VM_PERM_READ | CROI_VM_PERM_EXECUTE;
  uint32_t raw = 0;
  CHECK(677, sys(CROI_SYS_VMO_CREATE, PAGE, 0, (uint64_t)&raw, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_WRITE, raw, (uint64_t)code, 0, sizeof code, 0) == 0 &&
                 sys6(CROI_SYS_VMO_OP_RANGE, raw, CROI_VMO_OP_CACHE_SYNC, 0, sizeof code, 0, 0) == 0 &&
                 sys(CROI_SYS_VMO_REPLACE_AS_EXECUTABLE, raw, s->resource, (uint64_t)&vmo, 0, 0) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)(rx | CROI_VM_PERM_GUARDED) << 32, 0, vmo, 0, PAGE,
                      (uint64_t)&guarded) == 0 &&
                 sys6(CROI_SYS_VMAR_MAP, s->vmar | (uint64_t)rx << 32, 0, vmo, 0, PAGE, (uint64_t)&plain) == 0 &&
                 bti_call(guarded + 16) == 2 && bti_call(plain) == 1 && bti_call(plain + 16) == 2);
  // The stray call into the guarded copy: the thread's exception, ended.
  uint32_t channel = exception_channel(s->process), exception = 0;
  croi_exception_info_t info = {};
  uint32_t thread = start_thread(s, bti_stray, guarded);
  uint32_t exit = CROI_EXCEPTION_STATE_THREAD_EXIT;
  CHECK(678, next_exception(channel, &info, &exception) && info.type == CROI_EXCP_GENERAL &&
                 sys(CROI_SYS_OBJECT_SET_PROPERTY, exception, CROI_PROP_EXCEPTION_STATE, (uint64_t)&exit, 4, 0) == 0 &&
                 sys(CROI_SYS_HANDLE_CLOSE, exception, 0, 0, 0, 0) == 0 &&
                 (wait_for(thread, CROI_SIGNAL_TASK_TERMINATED, 3000000000ull) & CROI_SIGNAL_TASK_TERMINATED));
  uint32_t handles[] = {thread, channel, vmo};
  for (int i = 0; i < 3; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, guarded, PAGE, 0, 0);
  sys(CROI_SYS_VMAR_UNMAP, s->vmar, plain, PAGE, 0, 0);
#endif
  return 0;
}

// K11b: the kernel's CPRNG.
static int64_t cprng_checks(void) {
  uint8_t a[256], b[256];
  for (int i = 0; i < 256; i++) a[i] = b[i] = 0;
  if (sys(CROI_SYS_CPRNG_DRAW, (uint64_t)a, 256, 0, 0, 0) != 0 ||
      sys(CROI_SYS_CPRNG_DRAW, (uint64_t)b, 32, 0, 0, 0) != 0)
    return 430;
  int same = 0, zero = 0;
  for (int i = 0; i < 32; i++) {
    same += a[i] == b[i];
    zero += a[i] == 0;
  }
  if (same > 8 || zero > 8) return 431;  // two draws alike, or mostly zero
  if (sys(CROI_SYS_CPRNG_DRAW, (uint64_t)a, 257, 0, 0, 0) != ERR_INVALID_ARGS ||
      sys(CROI_SYS_CPRNG_DRAW, 0x10, 16, 0, 0, 0) != ERR_INVALID_ARGS ||
      sys(CROI_SYS_CPRNG_ADD_ENTROPY, (uint64_t)b, 64, 0, 0, 0) != 0 ||
      sys(CROI_SYS_CPRNG_ADD_ENTROPY, (uint64_t)b, 257, 0, 0, 0) != ERR_INVALID_ARGS ||
      sys(CROI_SYS_CPRNG_DRAW, (uint64_t)a, 0, 0, 0, 0) != 0)
    return 432;
  return 0;
}

static int64_t extensions(const startup_t *s, uint64_t vdso_base) {
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
  // Killing a process whose threads wait in different ways (one spins)
  // ends it promptly (Todhchai's compositor kill, M4).
  for (int round = 0; round < 30; round++) {
    uint32_t victim = spawn_child(s, s->job, 10);
    sys(CROI_SYS_NANOSLEEP, now_ns() + 2000000 + (uint64_t)round * 100000, 0, 0, 0, 0);
    uint64_t killed = now_ns();
    CHECK(404, sys(CROI_SYS_TASK_KILL, victim, 0, 0, 0, 0) == 0);
    uint32_t observed = 0;
    sys(CROI_SYS_OBJECT_WAIT_ONE, victim, CROI_SIGNAL_TASK_TERMINATED, killed + 500000000ull, (uint64_t)&observed, 0);
    CHECK(405, observed & CROI_SIGNAL_TASK_TERMINATED);
    sys(CROI_SYS_HANDLE_CLOSE, victim, 0, 0, 0, 0);
  }

  int64_t children = vmo_children();
  if (children != 0) return children;
  int64_t slices = vmo_slices(s);
  if (slices != 0) return slices;
  int64_t kinds = child_kinds(s);
  if (kinds != 0) return kinds;
  int64_t raced = copy_race(s);
  if (raced != 0) return raced;
  int64_t unbound = unbounded(s);
  if (unbound != 0) return unbound;
  int64_t zeroed = zero_intervals(s);
  if (zeroed != 0) return zeroed;
  int64_t ceilings = mapping_ceilings(s, vdso_base);
  if (ceilings != 0) return ceilings;
  int64_t fixes = review_fixes(s);
  if (fixes != 0) return fixes;
  int64_t medium = review_medium(s);
  if (medium != 0) return medium;
  int64_t entry = review_entry(s);
  if (entry != 0) return entry;
  int64_t low = review_low(s);
  if (low != 0) return low;
  int64_t queues = review_queues(s);
  if (queues != 0) return queues;
  int64_t pagerReview = review_pager(s);
  if (pagerReview != 0) return pagerReview;
  int64_t open = review_open(s);
  if (open != 0) return open;
  int64_t child_by_koid = get_child(s);
  if (child_by_koid != 0) return child_by_koid;
  int64_t accounts = memory_accounts(s);
  if (accounts != 0) return accounts;
  int64_t views = jit_views(s);
  if (views != 0) return views;
  int64_t idle = idle_states(s);
  if (idle != 0) return idle;
  int64_t signedPointers = pointer_auth(s);
  if (signedPointers != 0) return signedPointers;
  int64_t guardedCode = guarded_pages(s);
  if (guardedCode != 0) return guardedCode;
  int64_t fifos = fifos_and_exec(s);
  if (fifos != 0) return fifos;
  int64_t socks = sockets(s);
  if (socks != 0) return socks;
  int64_t strs = streams();
  if (strs != 0) return strs;
  int64_t pg = pager(s);
  if (pg != 0) return pg;
  int64_t small = small_calls(s);
  if (small != 0) return small;
  int64_t topics = info_topics(s);
  if (topics != 0) return topics;
  int64_t clk = clocks(s);
  if (clk != 0) return clk;
  int64_t dbg = debugging(s);
  if (dbg != 0) return dbg;
  int64_t attached = debugger(s);
  if (attached != 0) return attached;
  int64_t stepped = stepping(s);
  if (stepped != 0) return stepped;
  int64_t resized = resizing(s);
  if (resized != 0) return resized;
  int64_t smcs = smc(s);
  if (smcs != 0) return smcs;
  int64_t frozen = postmortem(s);
  if (frozen != 0) return frozen;
  int64_t futexes = futex_deadlines(s);
  if (futexes != 0) return futexes;
  int64_t timers = many_timers();
  if (timers != 0) return timers;
  int64_t raised = user_exceptions(s);
  if (raised != 0) return raised;
  int64_t loaning = page_loaning(s);
  if (loaning != 0) return loaning;
  int64_t borrowing = page_borrowing(s);
  if (borrowing != 0) return borrowing;
  int64_t reclaimed = reclaim(s);
  if (reclaimed != 0) return reclaimed;
  int64_t random = cprng_checks();
  if (random != 0) return random;

  // system_powerctl's refusals (K10e; the real thing ends the boot, under
  // userboot.shutdown=): the resource, then the command, then its argument.
  uint32_t power = 0;
  CHECK(400, resource_create(s->resource, CROI_RSRC_KIND_SYSTEM, CROI_RSRC_SYSTEM_POWER_BASE, 1, &power) == 0 &&
                 sys(CROI_SYS_SYSTEM_POWERCTL, tracing, CROI_SYSTEM_POWERCTL_REBOOT, 0, 0, 0) == ERR_OUT_OF_RANGE &&
                 sys(CROI_SYS_SYSTEM_POWERCTL, power, 0, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_SYSTEM_POWERCTL, s->resource, 10, 0, 0, 0) == ERR_INVALID_ARGS &&
                 sys(CROI_SYS_SYSTEM_POWERCTL, power, CROI_SYSTEM_POWERCTL_ENABLE_ALL_CPUS, 0, 0, 0) == ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_SYSTEM_POWERCTL, power, CROI_SYSTEM_POWERCTL_REBOOT_BOOTLOADER, 0, 0, 0) ==
                     ERR_NOT_SUPPORTED);
  croi_system_powerctl_arg_t s_state;
  zero_bytes(&s_state, sizeof s_state);
  s_state.acpi_transition_s_state.target_s_state = 3;
#if defined(__x86_64__)
  // amd64 needs \_S5's values: SHUTDOWN alone can't, suspend isn't there.
  CHECK(401, sys(CROI_SYS_SYSTEM_POWERCTL, power, CROI_SYSTEM_POWERCTL_SHUTDOWN, 0, 0, 0) == ERR_NOT_SUPPORTED &&
                 sys(CROI_SYS_SYSTEM_POWERCTL, power, CROI_SYSTEM_POWERCTL_ACPI_TRANSITION_S_STATE, 0x10, 0, 0) ==
                     ERR_INVALID_ARGS &&
                 sys(CROI_SYS_SYSTEM_POWERCTL, power, CROI_SYSTEM_POWERCTL_ACPI_TRANSITION_S_STATE,
                     (uint64_t)&s_state, 0, 0) == ERR_NOT_SUPPORTED);
  s_state.acpi_transition_s_state.target_s_state = 5;
  s_state.acpi_transition_s_state.sleep_type_b = 8;
  CHECK(402, sys(CROI_SYS_SYSTEM_POWERCTL, power, CROI_SYSTEM_POWERCTL_ACPI_TRANSITION_S_STATE,
                 (uint64_t)&s_state, 0, 0) == ERR_INVALID_ARGS);
  s_state.acpi_transition_s_state.target_s_state = 6;
  s_state.acpi_transition_s_state.sleep_type_b = 0;
  CHECK(403, sys(CROI_SYS_SYSTEM_POWERCTL, power, CROI_SYSTEM_POWERCTL_ACPI_TRANSITION_S_STATE,
                 (uint64_t)&s_state, 0, 0) == ERR_INVALID_ARGS);
#else
  CHECK(401, sys(CROI_SYS_SYSTEM_POWERCTL, power, CROI_SYSTEM_POWERCTL_ACPI_TRANSITION_S_STATE,
                 (uint64_t)&s_state, 0, 0) == ERR_NOT_SUPPORTED);
#endif
  uint32_t handles[] = {port, deadline, log, other, tracing, power};
  for (int i = 0; i < 6; i++) sys(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
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
            : mode == 17 ? extensions((const startup_t *)handle, vdso_base)
#if defined(__x86_64__) || defined(__aarch64__) || defined(__riscv)
            : mode == 18 ? iommu_test((const startup_t *)handle)
#endif
            : mode >= 0x400 ? child((uint32_t)mode, handle, vdso_base)
                        : objects());
}
