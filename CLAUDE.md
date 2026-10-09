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

Kernel enters on the loader's page tables with the handoff's physical
address as its argument. Not yet supported: arm64 firmware entering at EL2
(reported as unsupported), amd64 5-level paging, KASLR.
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
- Loader and kernel have no heap: there is no malloc, so any hidden
  allocation fails the link (find it with `ld.lld --why-live=swift_slowAlloc`).
  `withTemporaryAllocation` can fall back to the heap; use `InlineArray`
  stack buffers instead.
- C constants Swift must see are typed C23 enums (`enum : uint64_t {...}`),
  not macros with casts, which Swift does not import.
- Linking uses `--orphan-handling=error`: new sections must be placed in
  `ld/image.ld` explicitly.
