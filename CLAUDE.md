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

## Roadmap

`docs/roadmap.md` orders croi's work (K1 handoff + cache policy, K2
interrupts/IPIs/clock/timers, K3 threads + scheduling contexts, K4 VMM
phase A, K5 objects, K6 syscalls/vDSO/user SIMD, K7 IPC/processes, K8
userboot, K9 drivers/DMA/budgets for Todhchai's M3, K10 the desktop's
needs for its M4) against Todhchai's needs (`../todhchai/docs/croi-requirements.md`).
Check it before designing a subsystem: several extensions (MSI-capable
interrupts, IRQ affinity, scheduling contexts, device-local VMOs, shared
read-only pages) must be designed in from the start.

Reference source pin: `../fuchsia` at `e8b19ec722db74727411b941cf3cd5d1fae5dfc8`.

## Build

One CMake/Ninja tree per arch, `build/<arch>/`. Toolchain is pinned by
`.swift-version` and found through swiftly.

    cmake --workflow --preset amd64     # configure + build + QEMU smoke test
    cmake --build --preset arm64        # build only
    ninja -C build/rv64 run             # boot interactively (Ctrl-A x quits)

QEMU uses the edk2 firmware in `/usr/share/edk2` (`-DCROI_EDK2_DIR=` to
override); `build/<arch>/esp/` is served to it as a FAT drive.

## Todhchai's programs (todhchai-check)

`tools/todhchai-check.py <arch>` (ctest `todhchai-check`, label
`todhchai`) boots Todhchai's `td boot --next` test programs (sys-test,
pthread-test, tls-test, services-test) from its newest bootfs
(../todhchai or ../todhchai-c0, read only, copied) on this tree's loader
and kernel, with td boot's QEMU command (KVM on amd64). td ci builds croi
only from commits, so this is the pre-commit check of what croi changes
under Todhchai: review round 1's port 0xCF9 refusal passed every croi test
and failed sys-test (the check catches it). Launcher-manifest boots aren't
covered (their bootfs is assembled per test). Skipped (77) with no bootfs;
consoles in build/<arch>/todhchai/.

## Timing discipline (after Todhchai's docs/performance.md)

Tests judge correctness; timings are judged by the bench, against this
machine's history:

    tools/bench.py                      # 5 KVM boots x (full, lean): report
    tools/bench.py --record             # on a committed tree, quiet machine
    tools/bench.py --compare <commit>   # this tree vs a commit, interleaved

- Every budget is a `budget name=... value=... unit=... [limit=...]
  [target=...]` line (kernel `Budgets.report`, m2). Limits fail a boot
  only with `croi.enforce_budgets=1` on the command line and real timing
  (`-DCROI_CMDLINE=`, on a quiet machine); otherwise they are reported.
- The bench takes medians, judges each against the median of the last 5
  recorded runs in `bench/history/<host>.tsv` (a rise past both the
  rule's fraction and its floor regresses; RULES in tools/bench.py), and
  writes `bench/out/report.md` with every boot's console in
  `bench/out/logs/`. Advisory here (this is a shared machine: other
  agents, QEMU sessions, Todhchai's builds); `--enforce` only on a quiet,
  dedicated one. `--record` refuses a busy machine (load above a quarter
  of the CPUs), a dirty tree, or a regression without `--accept`.
- A regression is fixed or accepted in the open (roadmap), never
  silently; a limit is never loosened in the change that would fail it.
- Self-tests check mechanisms, not timing outcomes: the EDF test's
  fair-share ratio and deadline misses are reported budgets
  (`sched.fair_ratio_x10`, `edf.deadline_misses`), enforced only with
  `croi.enforce_budgets=1` (a starved vCPU misses deadlines whatever
  the scheduler does); starvation itself still fails.
- Before calling something a regression, compare interleaved
  (`--compare`): sequential runs on this machine mostly measure the
  machine (K9d: channel_call read 1.4-2.2 us for unchanged code, even
  at low load average).
- A missed budget is first checked against Zircon:
  `tools/zircon-bench/compare.py` boots m2's bench ported to Zircon (at
  the reference pin, from a jiri tree in ../fuchsia-jiri) interleaved
  with croi, lean and without idle polling. Zircon meets it: attainable,
  diff the paths; neither does: a roadmap decision; croi only in one
  configuration: record the dependency (docs/roadmap.md, "Budgets
  against Zircon"). A new m2 budget that croi misses is mirrored in
  `parity_bench.cc` and compare.py's BUDGETS, both sides together.

## Layout

- `boot/`     UEFI loader. Linked as an ELF static PIE, converted to PE32+
              by `tools/elf2efi.py` (LLVM has no RISC-V COFF backend).
- `kernel/`   Kernel image (static PIE linked at CROI_KERNEL_BASE, run at a
              random base: KASLR).
- `lib/handoff/` Loader -> kernel handoff ABI (`croi_handoff_t`, C header).
- `lib/fmt/`  `TextOutput`: allocation-free text formatting for both images.
- `lib/pagetables/` Page-table formats + generic builder (loader and kernel).
- `lib/rt/`   Freestanding C runtime the compilers call (mem*, stack guard).
- `lib/elf/`  `ElfImage`: ELF parsing and loading (loader, kernel, userboot).
- `user/`     User space: the runtime (`user/lib/runtime`), headers
              (`user/include`, module `CroiRuntime`), vDSO, test programs.
- `ld/image.ld` Shared linker script: one PT_LOAD per permission (W^X).
- `cmake/`    Toolchain file, per-arch settings, `croi_image()` helper.

## Design notes (docs/design/)

The subsystem notebook: what each part does, its Zircon counterpart, why
it diverges, what tests cover it, and the bugs that shaped it. Read the
relevant file before changing a subsystem, and update it in the same
change (new milestones add a section to the file they belong in).

| File | Contents |
|------|----------|
| `boot.md` | Loader and handoff, memory types, kernel entry and address space, EL2 drop, ACPI, topology, bring-up aids (console, watchdog, SError), boot budgets |
| `memory.md` | PMM, heap, kernel/user VM, VMOs and every child kind, JIT reservations, accounts, resizable/unbounded VMOs, user copies, the pager and zero intervals, reclamation, page loaning, memory stats |
| `cpu.md` | Locking, SMP, interrupts and TLB shootdowns, time and timers, exceptions, kernel stacks, threads, scheduling policy, inheritance, thread pins, xstate, deadline wakeups, CPU reservations, idle, power control, trace |
| `hardening.md` | CPRNG, static PIEs and ASLR, KASLR, PAC, BTI, guarded user pages |
| `user.md` | User mode per arch, user protection (SMAP/PAN/SUM), vDSO and shared pages, user FP/SIMD, sampling and PMU, debuglog, ProgramLoader, bootfs and userboot, m2 and its profiling modes |
| `objects.md` | Objects, handles, waits, ports, processes/jobs/VMARs, channels, futexes, timer objects, exceptions and job policy, counters, timelines, FIFOs, sockets, streams, small calls, info topics, clocks |
| `debugging.md` | Suspension, process memory access, debugger channels, single-step and hardware breakpoints |
| `drivers.md` | Resources, firmware boot data, interrupt objects, MSI (x86, ITS, AIA), DMA/BTIs without an IOMMU, SMC calls |
| `iommu.md` | VT-d (and interrupt remapping), AMD-Vi, SMMUv3, SMMUv1/v2, RISC-V IOMMU, claimed devices' MSIs |

Also: `docs/roadmap.md` (order, open items, decisions) and
`docs/zircon-divergences.md` (every deliberate difference from Zircon).

## Rules that cut across subsystems

- Lock orders: job -> process -> thread object -> scheduler; debuglog ->
  object -> scheduler -> port packets; aspace -> vmo (child -> parent) ->
  account -> heap -> pmm, and vm -> heap -> pmm for the kernel aspace;
  object -> vmo (ZERO_CHILDREN); socket mutex -> object; IRQ table ->
  object -> controller; IOMMU unitsLock -> unit -> table, domain -> unit;
  `Loans.mutex` outermost; the reclaim registry lock and the timer queue
  locks are leaves. Nothing takes an object lock under the scheduler lock.
- Nothing calls firmware after ExitBootServices, including deinits.
- Never send a waiting IPI (`Ipi.call`) holding the scheduler lock. Code
  that frees or unmaps kernel memory may wait for shootdown acks under
  `vmLock`, so it runs with interrupts on.
- Re-read `Cpu.current` after any `switchAway`: a thread may resume on
  another CPU. Timer ids are per CPU; a timer must never outlive its thread.
- Syscalls touch user memory only through `UserCopy` (range checked);
  only `.croi_fixups` instructions may fault on user memory.
- A thread object's `thread`, used after its lock drops, needs
  `Processes.pinnedThread`.
- Timers never fire early; an idle CPU arms nothing it doesn't need
  (`idle.wakeups` is always enforced).
- No mapping is writable and executable outside a JIT reservation.
- A failed `guard` may end `~Copyable` lifetimes early (their deinit runs
  before the else branch): join threads before judging them.
- Self-tests check mechanisms; timings are budgets (see Timing discipline).

## Conventions

- When C or asm is used, say why in the file's header comment. Today: UEFI
  calling-convention shims, entry/start code, compiler runtime, and the
  user runtime (the C symbols the Embedded Swift runtime calls).
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
- Kernel flag types are `BitFlags` (Object/Status.swift: `Rights`,
  `VmRights`), combined with `|` (`.read | .write`, `Rights()` for none),
  never `OptionSet`: an OptionSet array literal builds an Array, and
  whether the optimizer folded it away depended on unrelated nearby code
  (unrelated edits broke the no-ARC link three times). The build checks
  (`cmake/CheckNoOptionSet.cmake`).
- Reading a `~Copyable` value through an `unsafeAddress` accessor makes the
  owner unconsumable afterwards in 6.4.0; use `_read { yield ... }` (the
  SE-0474 `yielding borrow` spelling is still experimental). `borrow`
  accessors can't return through a raw pointer's `pointee`, and key paths
  don't support `~Copyable` types.
- `discard self` in Embedded Swift needs `@frozen` (public types only) or
  `@export(interface)` on the method; croi uses the latter.
- A non-mutating method called on a large global struct gets a copy of
  the whole struct (a bitwise `rep movsb`, even for a `~Copyable` one),
  and indexing an `InlineArray` field inside it can copy the array again:
  `pmm.page(for:)` copied ~1.6 KB per call (K14l). Make lookups on big
  globals `mutating` (the global's address is passed), and check hot paths
  with `llvm-objdump -d` for `rep movsb` of a struct's size.
- Swift precedence trap: `<<`/`>>` bind tighter than `*`, so write
  `(pages * pageSize) >> 20`, never `pages * pageSize >> 20`.
- C constants Swift must see are typed C23 enums (`enum : uint64_t {...}`),
  not macros with casts, which Swift does not import.
- Small Swift globals are fine (`nonisolated(unsafe) var`; zero/nil
  initializers are static at -Osize). Large tables and stacks go in
  assembly `.bss`: Swift still emits lazy initializers for them.
- Linking uses `--orphan-handling=error`: new sections must be placed in
  `ld/image.ld` explicitly.
