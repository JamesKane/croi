// Kernel entry points shared between assembly, C and Swift. Functions marked
// "Swift" are implemented with `@c @implementation`, so the compiler checks
// them against these declarations.

#pragma once

#include <stdint.h>

// Swift (Kernel/Main.swift). Entered from arch/<arch>/start.S on the boot
// stack with the physical address of the loader's croi_handoff_t (see
// lib/handoff), identity mapped.
[[noreturn]] void kernel_main(uint64_t handoff);

// Swift (Kernel/Main.swift). The rest of boot, on a guarded KernelStack.
[[noreturn]] void kernel_main_continue(void);

// Assembly (arch/<arch>/start.S). Masks interrupts and idles the CPU forever.
[[noreturn]] void arch_halt(void);

// Assembly (arch/<arch>/start.S). Switches to the stack whose top is `top`
// and calls kernel_main_continue; the old stack is abandoned.
[[noreturn]] void arch_continue_on_stack(uint64_t top);

// Assembly (arch/<arch>/start.S). Switches to new kernel page tables and
// flushes the TLB. The kernel image must be mapped identically in the old
// and new tables. amd64/rv64 use `root`; arm64 loads `root` into TTBR0 and
// `root_high` into TTBR1.
void arch_load_page_tables(uint64_t root, uint64_t root_high);

// --- CPU ----------------------------------------------------------------------
//
// Assembly (arch/<arch>/cpu.S).

// Masks interrupts on this CPU and returns the previous state, to be passed
// to arch_interrupts_restore. Nests: restore puts back exactly what was saved.
uint64_t arch_interrupts_save(void);
void arch_interrupts_restore(uint64_t state);
bool arch_interrupts_enabled(void);

// Spin-wait hint (x86 pause, arm64 yield, RISC-V Zihintpause pause).
void arch_spin_pause(void);

// The per-CPU register (amd64 GS base, arm64 TPIDR_EL1, rv64 tp): holds
// this CPU's PerCpu record, 0 until set. Zeroed at kernel entry.
void arch_set_percpu(uint64_t percpu);
uint64_t arch_percpu(void);

// This CPU's hardware ID: local APIC ID (amd64), MPIDR affinity (arm64).
// rv64 S-mode can't read its hart ID; returns 0 (the loader passes it).
uint64_t arch_cpu_hardware_id(void);

// Cleans data cache lines for [va, va+size) to the point of coherency, for
// data read with the MMU off (arm64; no-op where caches are coherent).
void arch_clean_dcache(uint64_t va, uint64_t size);

// Invalidates TLB (and page-walk cache) entries for va after its page-table
// entry changed. amd64 and rv64: this CPU only (shootdowns come with SMP);
// arm64: broadcast to all CPUs.
void arch_tlb_invalidate_page(uint64_t va);

// --- Exceptions ---------------------------------------------------------------
//
// Each arch's vectors (arch/<arch>/exceptions.S) save the interrupted state
// as an arch_exception_frame_t on the current stack and call
// arch_exception. Whatever the handler leaves in the frame is restored on
// return, so it can resume past an instruction or redirect execution.

#if defined(__x86_64__)
typedef struct {
  uint64_t r15, r14, r13, r12, r11, r10, r9, r8;
  uint64_t rbp, rdi, rsi, rdx, rcx, rbx, rax;
  uint64_t vector;
  uint64_t error_code;  // 0 for vectors where the CPU pushes none
  uint64_t rip, cs, rflags, rsp, ss;  // pushed by the CPU
} arch_exception_frame_t;
static_assert(sizeof(arch_exception_frame_t) == 22 * 8);
#elif defined(__aarch64__)
typedef struct {
  uint64_t x[31];
  uint64_t sp;     // at the time of the exception
  uint64_t elr;
  uint64_t spsr;
  uint64_t esr;
  uint64_t far;
  uint64_t slot;   // vector table entry, 0..15; +16 if taken on the
                   // emergency stack because the stack had overflowed
  uint64_t reserved;
} arch_exception_frame_t;
static_assert(sizeof(arch_exception_frame_t) == 38 * 8);
#elif defined(__riscv)
typedef struct {
  uint64_t x[32];  // x[0] unused; x[2] is sp at the time of the trap
  uint64_t sepc;
  uint64_t sstatus;
  uint64_t scause;
  uint64_t stval;
  uint64_t overflow;  // nonzero: taken on the emergency stack (stack overflow)
  uint64_t reserved;
} arch_exception_frame_t;
static_assert(sizeof(arch_exception_frame_t) == 38 * 8);
#endif

// Swift (Kernel/Exceptions.swift). Every exception lands here.
void arch_exception(arch_exception_frame_t *_Nonnull frame);

// Assembly (arch/<arch>/exceptions.S). Installs the exception vectors (and
// on amd64 the IDT and a TSS with a separate stack for #DF/NMI/#MC).
void arch_init_exceptions(void);

// Assembly (arch/<arch>/exceptions.S). Executes a breakpoint instruction;
// used to check the exception path round-trips.
void arch_breakpoint(void);

#if defined(__aarch64__)
// Assembly (arch/arm64/start.S). The current exception level.
uint64_t arch_current_el(void);
#endif

#if defined(__x86_64__)
// Assembly (arch/amd64/start.S). Port I/O, which Swift cannot express.
uint8_t arch_inb(uint16_t port);
void arch_outb(uint16_t port, uint8_t value);

// Assembly (arch/amd64/exceptions.S). The page-fault linear address.
uint64_t arch_read_cr2(void);
#endif

// Kernel image segment bounds (virtual), from ld/image.ld. Inline C because
// Swift cannot take the address of a linker-defined symbol.
#define CROI_IMAGE_SYMBOL(name)                                    \
  static inline uint64_t kernel_##name(void) {                    \
    extern const char __##name[] __attribute__((visibility("hidden"))); \
    return (uint64_t)(uintptr_t)__##name;                         \
  }
CROI_IMAGE_SYMBOL(image_start)
CROI_IMAGE_SYMBOL(text_end)
CROI_IMAGE_SYMBOL(rodata_start)
CROI_IMAGE_SYMBOL(rodata_end)
CROI_IMAGE_SYMBOL(data_start)
CROI_IMAGE_SYMBOL(image_end)
#undef CROI_IMAGE_SYMBOL

// --- Heap ---------------------------------------------------------------------
//
// Swift (Kernel/Heap.swift). The C allocation interface; the Embedded Swift
// runtime allocates through posix_memalign and free. Usable once the heap
// is up (after the PMM); before that, allocation fails.
#include <stddef.h>
int posix_memalign(void *_Nullable *_Nonnull memptr, size_t alignment, size_t size);
void *_Nullable malloc(size_t size);
void free(void *_Nullable ptr);
