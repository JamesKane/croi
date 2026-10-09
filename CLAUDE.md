# croi

A rewrite of Fuchsia's Zircon microkernel in Embedded Swift 6.4, with C23 or
assembly only where Swift cannot do the job. Targets amd64, arm64 and rv64.
Reference source: `../fuchsia/zircon/` (port semantics, not C++ structure).

## Scope

- UEFI + ACPI only for boot and hardware discovery. No devicetree, no other
  boot protocols.
- No hypervisor.
- IOMMU support is core (VT-d, AMD-Vi, SMMUv3, RISC-V IOMMU).
- Observability (tracing, debuglog, crashlog, lockup detection) is in scope.

## Build

One CMake/Ninja tree per arch, `build/<arch>/`. Toolchain is pinned by
`.swift-version` and found through swiftly.

    cmake --workflow --preset amd64     # configure + build + QEMU smoke test
    cmake --build --preset arm64        # build only
    ninja -C build/rv64 run             # boot interactively (Ctrl-A x quits)

QEMU uses the edk2 firmware in `/usr/share/edk2` (`-DCROI_EDK2_DIR=` to
override); `build/<arch>/esp/` is served to it as a FAT drive.

## Layout

- `boot/`     UEFI loader. Linked as an ELF static PIE, converted to PE32+
              by `tools/elf2efi.py` (LLVM has no RISC-V COFF backend).
- `kernel/`   Kernel image (static PIE at CROI_KERNEL_BASE).
- `lib/handoff/` Loader -> kernel handoff ABI (`croi_handoff_t`, C header).
- `lib/fmt/`  `TextOutput`: allocation-free text formatting for both images.
- `lib/pagetables/` Page-table formats + generic builder (loader and kernel).
- `lib/rt/`   Freestanding C runtime the compilers call (mem*, stack guard).

## Boot flow

Loader (`boot/Loader/Main.swift`): read `\croi\kernel.elf` from the boot
volume -> load + relocate it at its link address -> RSDP from the UEFI
config table, early UART from ACPI SPCR (COM1 fallback on amd64) -> boot
page tables (all RAM identity mapped RWX, UART as device, kernel segments
W^X at CROI_KERNEL_BASE; Sv39 on rv64, TTBR0/TTBR1 on arm64) ->
ExitBootServices -> memory map converted into the handoff ->
`croi_arch_enter_kernel` (boot/arch/<arch>/enter.S). Loader allocations
use OS-defined memory types 0x80000001 (kernel) / 0x80000002 (handoff and
page tables) so they show up as CROI_MEM_KERNEL / CROI_MEM_HANDOFF.

Kernel (`kernel/Kernel/Main.swift`): validates the handoff, builds its own
page tables from free RAM with `BootAllocator` (front-to-back, never frees;
reads the handoff range table in place, which is CROI_MEM_HANDOFF and so
never handed out), and switches to them. Kernel address space
(`KernelLayout`): low half empty; physmap of all RAM at 0xffff800000000000
(amd64/arm64) or 0xffffffc000000000 (rv64 Sv39), RW + NX; device registers
the kernel uses are mapped in the physmap as device memory; the image at
CROI_KERNEL_BASE with text RX, rodata R, data RW. amd64 loads its own GDT
first thing, since firmware's sits in memory reported free.

Physical memory (`Kernel/Pmm.swift`, global `pmm`, after Zircon's
PmmNode): arenas over contiguous RAM the kernel owns (free, kernel,
handoff, ACPI reclaim; firmware runtime/NVS get none), each with a `Page`
array (32 B/page) carved by the boot allocator. Pages start `.wired`;
free RAM the boot allocator never handed out (it records exact spans) goes
on a doubly linked free list. amd64 keeps the first MiB wired for SMP
trampolines. `allocatePage`, `allocateContiguous(count, alignLog2:)`,
`free` (panics on double free), `endHandoff()` (frees the loader's handoff
data and boot page tables; nothing may read the handoff afterwards).
Guarded by `pmmLock`. ACPI reclaim stays wired until ACPI is parsed. Boot
runs a PMM self-test.

Kernel heap (`Kernel/Heap.swift`, global `heap`): PMM pages (state `.heap`)
through the physmap, like Zircon's. Requests up to 2 KiB use one-page slabs
in 13 size classes (per-slab free lists; empty slabs go back to the PMM);
larger or >2 KiB-aligned requests get contiguous PMM pages. Bookkeeping is
in the `Page` records (no headers). `free` validates, catches double frees
and poisons. `posix_memalign`/`malloc`/`free` are `@c @implementation`
(the Swift runtime allocates through them). Guarded by `heapLock`.

Locking (`Kernel/SpinLock.swift`): `SpinLock` masks interrupts on this CPU
while held (Zircon's SpinLock + IrqSave) and spins test-and-test-and-set;
`withLock { }` is the API (releases on throw). The lock word holds the
holder's CPU + 1, so a recursive acquire or a release by a non-holder
panics. `Cpu.current` comes from the per-CPU register. Lock order: vm ->
heap -> pmm (each calls the next with its own lock held). Locks are global `let`s
next to the global state they guard; public mutating methods of `Pmm` and
`Heap` take the lock and call `*Locked` internals. Restoring an
*enabled* interrupt state is untested until interrupt controllers exist.

Virtual memory (`Kernel/Vm/`, after Zircon's VmAspace/ArchVmAspace):
- `ArchAspace`: map / unmap / protect / query on live page tables. Tables
  from the PMM (`.mmu`) via the physmap; partly covered large pages are
  split; emptied tables go back to the PMM (never roots). Each change is
  followed by `arch_tlb_invalidate_page` (amd64/rv64 local only until SMP
  shootdowns; arm64 broadcast). arm64 uses break-before-make when block
  size or memory type changes, so never split the physmap (the tables are
  reached through it).
- `KernelAspace` (global `kernelAspace`, `vmLock`): region allocator over
  KernelLayout's dynamic range (first fit, sorted `UniqueArray`, guard page
  on both sides of every region). `allocate(pages:)` (fresh zeroed PMM
  pages, RW+NX), `mapPhysical` (e.g. MMIO), `reserve` (address space only;
  map via `withArch`), `free`. Not yet: VMOs/VMARs/user aspaces; kernel
  top-level entries are created on demand, so on amd64/rv64 they must be
  pre-populated before user address spaces copy the kernel half.

ACPI (`Kernel/Acpi/`, after Zircon's acpi_lite): `AcpiTables` validates
RSDP/XSDT and finds tables by signature; `withPhysicalBytes` reads through
the physmap or a temporary mapping. `Madt.forEachCpu` yields local APIC /
x2APIC (amd64), GICC MPIDR (arm64) and RINTC hart IDs (rv64).

SMP (`Kernel/Smp.swift`, `include/smp.h`, `arch/<arch>/smp.S`):
- `PerCpu` records (heap, never freed) found through the per-CPU register
  (amd64 GS base, arm64 TPIDR_EL1, rv64 tp; zeroed at kernel entry);
  `Cpu.current` reads it. The boot CPU's record is installed on its
  guarded stack; rv64 learns its boot hart ID from the handoff (v2,
  RISCV_EFI_BOOT_PROTOCOL), since S-mode can't read it.
- Every other enabled MADT CPU gets a guarded KernelStack and a startup
  block (`croi_ap_startup_t`, read by physical address with the MMU off)
  and is started one at a time: rv64 SBI HSM hart_start; arm64 PSCI CPU_ON
  (SMC/HVC from the FADT boot flags; repeats the EL2->EL1 drop); amd64
  INIT-SIPI-SIPI with a real-mode trampoline copied to a low page the PMM
  set aside (`lowTrampolinePage`) and a temporary bootstrap PML4 below
  4 GiB. Trampolines turn the MMU on at a physical PC and let the next
  fetch fault into a vector/stvec that holds the continuation's virtual
  address (rv64, arm64); amd64 jumps via the bootstrap PML4's kernel half.
- Secondaries run `kernel_ap_main`: exception vectors (amd64: shared IDT,
  no TSS yet), self-test, then idle with interrupts masked.
- Boot self-test: per-CPU identity, and all CPUs incrementing a counter
  with a non-atomic load+store under one SpinLock after a start barrier
  (verified to fail without the lock).
- Not yet: TLB shootdowns (amd64/rv64 invalidation is still local, so no
  kernel mapping may change while secondaries could use it), per-CPU
  TSS/IST and emergency stacks (shared today), calibrated delays for
  INIT/SIPI (spin loops), CPU hotplug, a scheduler.

Exceptions: `arch/<arch>/exceptions.S` saves an `arch_exception_frame_t`
(kernel.h) and calls Swift `arch_exception` (Kernel/Exceptions.swift);
the handler may edit the frame to resume elsewhere. Installed at the top
of kernel_main. amd64: IDT of 256 stubs, TSS with IST1 for NMI/#DF/#MC.
arm64: VBAR_EL1. rv64: stvec, S-mode traps only. Breakpoints resume (the
boot test checks one round trip); anything else prints a register dump to
`panicConsole` and halts via `panic()`.

Kernel stacks (`Kernel/KernelStack.swift`, geometry in `include/stack.h`):
16 KiB from `kernelAspace`, aligned to 32 KiB, guard pages both sides;
`~Copyable`, freed on drop (`keepForever()` for permanent ones). The .bss
boot stack is only used until the VM is up: kernel_main then switches to a
guarded stack (`arch_continue_on_stack` -> `kernel_main_continue`).
Overflow is reported, not a hang: amd64 escalates to #DF on IST1; arm64
and rv64 exception entry test bit CROI_KERNEL_STACK_SHIFT of the would-be
frame address (clear on every valid stack thanks to the alignment) and
switch to a .bss emergency stack (arm64 stashes x0 in TPIDRRO_EL0, rv64
uses sscratch: both must be revisited when user mode arrives). Every stack
the CPU runs on must keep this geometry. IST1 and the emergency stacks are
still unguarded .bss, one per system until per-CPU data exists. A deliberate fault in kernel code must use a
volatile access, or LLVM may delete it (e.g. stores to const symbols).

Kernel enters on the loader's page tables with the handoff's physical
address as its argument, at EL1 on arm64: if firmware ran at EL2, the
trampoline neutralizes EL2 (HCR_EL2 = RW only; timer, PMU and GICv3 sysregs
handed to EL1) and drops to EL1 after ExitBootServices. Not yet supported:
amd64 5-level paging, KASLR, CPUs where HCR_EL2.E2H is RES1 (VHE-only).
EL2 does not yet un-trap pointer authentication (HCR_EL2.API/APK), so the
kernel must not use PAC until it does.
- `ld/image.ld` Shared linker script: one PT_LOAD per permission (W^X).
- `cmake/`    Toolchain file, per-arch settings, `croi_image()` helper.

## Conventions

- When C or asm is used, say why in the file's header comment. Today: UEFI
  calling-convention shims, entry/start code, compiler runtime.
- C boundary: declare in a header, implement in Swift with
  `@c @implementation`. The Swift function must keep the C name
  (`kernel_main`); `@c(name)` and `swift_name` don't work with it in 6.4.0.
- Swift is built with `-strict-memory-safety` (errors): every unsafe use is
  marked `unsafe`; types that wrap raw pointers are `@safe` with `@unsafe`
  initializers documenting the contract.
- Prefer 6.4 / ownership-era APIs: `Span`/`MutableSpan`/`RawSpan`,
  `InlineArray`, span-based `withTemporaryAllocation`, `~Copyable` types,
  `UniqueBox`/`UniqueArray` (no CoW), typed throws, `Atomic`
  (Synchronization), `@section`/`@used`. Avoid existentials and untyped
  `throws` in kernel paths (they allocate); `PerformanceHints` warns.
  Span-returning properties need `@_lifetime(...)` (Lifetimes feature is on).
- No floating point in kernel code. On amd64 Swift can't be built with x87
  disabled, so `Double` would compile silently to x87; don't use it.
- The loader has no heap: there is no malloc, so any hidden allocation
  fails the link (find it with `ld.lld --why-live=swift_slowAlloc`).
  `withTemporaryAllocation` can fall back to the heap; use `InlineArray`
  stack buffers instead.
- **The kernel is ownership-only: no ARC.** Embedded Swift (64-bit) treats
  any object whose address has bit 63 set as immortal
  (`HeapObject.immortalObjectPointerBit` in EmbeddedRuntime.swift), and
  every higher-half address has it. So `swift_retain`/`swift_release` are
  no-ops for kernel objects and uniqueness checks fail: classes, boxes for
  captured vars, existentials and Array/String/Dictionary/Set storage would
  leak (and CoW would copy on every mutation). Use `~Copyable` types,
  `UniqueBox`/`UniqueArray`, and `Ref<T>` (Kernel/Ref.swift: intrusive
  atomic count like Zircon's fbl::RefPtr; `share()` adds an owner, the last
  drop frees). `cmake/CheckNoArc.cmake` fails the kernel link if any
  refcounting entry point survives --gc-sections.
- Reading a `~Copyable` value through an `unsafeAddress` accessor makes the
  owner unconsumable afterwards in 6.4.0; use `_read { yield ... }` (the
  SE-0474 `yielding borrow` spelling is still experimental). `borrow`
  accessors can't return through a raw pointer's `pointee`, and key paths
  don't support `~Copyable` types.
- `discard self` in Embedded Swift needs `@frozen` (public types only) or
  `@export(interface)` on the method; croi uses the latter.
- Swift precedence trap: `<<`/`>>` bind tighter than `*`, so write
  `(pages * pageSize) >> 20`, never `pages * pageSize >> 20`.
- C constants Swift must see are typed C23 enums (`enum : uint64_t {...}`),
  not macros with casts, which Swift does not import.
- Small Swift globals are fine (`nonisolated(unsafe) var`; zero/nil
  initializers are static at -Osize). Large tables and stacks go in
  assembly `.bss`: Swift still emits lazy initializers for them.
- Linking uses `--orphan-handling=error`: new sections must be placed in
  `ld/image.ld` explicitly.
