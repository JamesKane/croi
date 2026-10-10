// Process entry for croi user programs (K8a): reads the bootstrap message
// (processargs.h), keeps its handles and strings, and runs main. C because
// it runs before anything else in the process and its entry stub must be
// assembly (a crt0): amd64 C code expects to have been called, with the
// stack 8 bytes off its 16-byte alignment, and no frame to return to.

#include <croi/runtime.h>

#if defined(__x86_64__)
__asm__(".section .text._start, \"ax\"\n"
        ".globl _start\n"
        "_start:\n"
        "  xor %ebp, %ebp\n"
        "  call croi_start\n"
        "  ud2\n"
        ".text\n");
#elif defined(__aarch64__)
__asm__(".section .text._start, \"ax\"\n"
        ".globl _start\n"
        "_start:\n"
        "  mov x29, #0\n"
        "  mov x30, #0\n"
        "  bl croi_start\n"
        "  brk #0\n"
        ".text\n");
#elif defined(__riscv)
// gp for linker relaxation, when the link defined __global_pointer$.
__asm__(".section .text._start, \"ax\"\n"
        ".globl _start\n"
        ".weak __global_pointer$\n"
        "_start:\n"
        ".option push\n"
        ".option norelax\n"
        "  lla gp, __global_pointer$\n"
        ".option pop\n"
        "  li fp, 0\n"
        "  li ra, 0\n"
        "  call croi_start\n"
        "  unimp\n"
        ".text\n");
#endif

enum {
  BOOTSTRAP_BYTES = 4096,
  BOOTSTRAP_HANDLES = 32,
  MAX_STRINGS = 32,
};

static _Alignas(8) char bootstrap[BOOTSTRAP_BYTES];
static uint32_t handles[BOOTSTRAP_HANDLES];
static uint32_t infos[BOOTSTRAP_HANDLES];
static uint32_t handle_count;
static char *args[MAX_STRINGS + 1];
static int args_count;
static char *environ[MAX_STRINGS + 1];
static int environ_count;
static uint64_t vdso;
static uint32_t process_self;
static uint32_t vmar_root;

int main(int argc, char **argv);
void croi_runtime_stdout(uint32_t log);  // stdout.c

// Splits `count` NUL-terminated strings at `offset` into `out`.
static int strings(uint32_t offset, uint32_t count, uint32_t size, char **out) {
  int n = 0;
  while (offset < size && (uint32_t)n < count && n < MAX_STRINGS) {
    out[n++] = bootstrap + offset;
    while (offset < size && bootstrap[offset] != 0) offset++;
    offset++;
  }
  out[n] = 0;
  return n;
}

static void read_bootstrap(uint32_t channel) {
  uint64_t actual = 0;
  int64_t status = croi_syscall6(CROI_SYS_CHANNEL_READ, channel, 0, (uint64_t)bootstrap, (uint64_t)handles,
                                 BOOTSTRAP_BYTES | (uint64_t)BOOTSTRAP_HANDLES << 32, (uint64_t)&actual);
  croi_syscall(CROI_SYS_HANDLE_CLOSE, channel, 0, 0, 0, 0);
  if (status != 0) return;
  uint32_t size = (uint32_t)actual;
  handle_count = (uint32_t)(actual >> 32);
  const croi_proc_args_t *header = (const croi_proc_args_t *)bootstrap;
  if (size < sizeof *header || header->protocol != CROI_PROCARGS_PROTOCOL ||
      header->version != CROI_PROCARGS_VERSION || header->handle_info_off > size ||
      (size - header->handle_info_off) / 4 < handle_count) {
    for (uint32_t i = 0; i < handle_count; i++) croi_syscall(CROI_SYS_HANDLE_CLOSE, handles[i], 0, 0, 0, 0);
    handle_count = 0;
    return;
  }
  for (uint32_t i = 0; i < handle_count; i++) {
    memcpy(&infos[i], bootstrap + header->handle_info_off + 4 * i, 4);
  }
  bootstrap[BOOTSTRAP_BYTES - 1] = 0;  // every string ends inside the buffer
  args_count = strings(header->args_off, header->args_num, size, args);
  environ_count = strings(header->environ_off, header->environ_num, size, environ);
}

uint32_t croi_take_startup_handle(uint32_t info) {
  for (uint32_t i = 0; i < handle_count; i++) {
    if (infos[i] == info && handles[i] != 0) {
      uint32_t handle = handles[i];
      handles[i] = 0;
      return handle;
    }
  }
  return 0;
}

uint32_t croi_process_self(void) { return process_self; }
uint32_t croi_vmar_root_self(void) { return vmar_root; }
uint64_t croi_vdso_base(void) { return vdso; }
int croi_environ_count(void) { return environ_count; }
const char *croi_environ(int index) { return index >= 0 && index < environ_count ? environ[index] : 0; }

[[noreturn]] void croi_exit(int64_t code) {
  croi_flush();
  croi_syscall(CROI_SYS_PROCESS_EXIT, (uint64_t)code, 0, 0, 0, 0);
  __builtin_trap();
}

[[noreturn, gnu::used]] void croi_start(uint64_t bootstrap_channel, uint64_t arg2, uint64_t vdso_base) {
  (void)arg2;
  vdso = vdso_base;
  if (bootstrap_channel != 0) read_bootstrap((uint32_t)bootstrap_channel);
  process_self = croi_take_startup_handle(croi_pa_hnd(CROI_PA_PROC_SELF, 0));
  vmar_root = croi_take_startup_handle(croi_pa_hnd(CROI_PA_VMAR_ROOT, 0));
  croi_runtime_stdout(croi_take_startup_handle(croi_pa_hnd(CROI_PA_FD, 1)));
  croi_exit(main(args_count, args));
}
