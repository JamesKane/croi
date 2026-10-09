// The boot self-test's user program (K6b): exercises the object syscalls
// from user mode and exits with 0x600D, or with the number of the first
// check that failed. arg0 selects a mode; arg1 is a handle the kernel
// gave it (mode 1: a tracing resource).

#include <croi/syscall.h>

#include "shared.h"

#define ERR_BAD_HANDLE (-11)
#define ERR_INVALID_ARGS (-10)
#define ERR_TIMED_OUT (-21)
#define ERR_ACCESS_DENIED (-30)
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

[[noreturn]] static void exit_with(int64_t code) {
  sys(CROI_SYS_THREAD_EXIT, (uint64_t)code, 0, 0, 0, 0);
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

// Entered straight from the kernel, not called: on amd64 the stack is
// 16-byte aligned rather than 8 off, so realign (SSE spills need it).
#if defined(__x86_64__)
__attribute__((force_align_arg_pointer))
#endif
__attribute__((section(".text.start"))) [[noreturn]] void _start(uint64_t mode, uint64_t handle) {
  exit_with(mode == 1   ? marks((uint32_t)handle)
            : mode == 2 ? vdso(handle)
            : mode == 3 ? registers(handle & 0xFFFF, handle >> 16 & 1)
                        : objects());
}
