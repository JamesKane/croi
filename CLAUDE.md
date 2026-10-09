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
data and boot page tables; nothing may read the handoff afterwards). No
lock yet: single CPU, interrupts masked. ACPI reclaim stays wired until
ACPI is parsed. Boot runs a PMM self-test.

Kernel heap (`Kernel/Heap.swift`, global `heap`): PMM pages (state `.heap`)
through the physmap, like Zircon's. Requests up to 2 KiB use one-page slabs
in 13 size classes (per-slab free lists; empty slabs go back to the PMM);
larger or >2 KiB-aligned requests get contiguous PMM pages. Bookkeeping is
in the `Page` records (no headers). `free` validates, catches double frees
and poisons. `posix_memalign`/`malloc`/`free` are `@c @implementation`
(the Swift runtime allocates through them). Not locked yet.

Exceptions: `arch/<arch>/exceptions.S` saves an `arch_exception_frame_t`
(kernel.h) and calls Swift `arch_exception` (Kernel/Exceptions.swift);
the handler may edit the frame to resume elsewhere. Installed at the top
of kernel_main. amd64: IDT of 256 stubs, TSS with IST1 for NMI/#DF/#MC.
arm64: VBAR_EL1. rv64: stvec, S-mode traps only. Breakpoints resume (the
boot test checks one round trip); anything else prints a register dump to
`panicConsole` and halts via `panic()`. No stack guard pages yet, so kernel
stack overflow is not caught. A deliberate fault in kernel code must use a
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
- Swift precedence trap: `<<`/`>>` bind tighter than `*`, so write
  `(pages * pageSize) >> 20`, never `pages * pageSize >> 20`.
- C constants Swift must see are typed C23 enums (`enum : uint64_t {...}`),
  not macros with casts, which Swift does not import.
- Small Swift globals are fine (`nonisolated(unsafe) var`; zero/nil
  initializers are static at -Osize). Large tables and stacks go in
  assembly `.bss`: Swift still emits lazy initializers for them.
- Linking uses `--orphan-handling=error`: new sections must be placed in
  `ld/image.ld` explicitly.
