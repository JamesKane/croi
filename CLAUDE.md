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

## Boot flow

Loader (`boot/Loader/Main.swift`): read `\croi\kernel.elf` from the boot
volume -> load + relocate it at its link address -> optional
`\croi\bootfs.img` (own memory type, CROI_MEM_BOOTFS) and `\croi\cmdline`
(copied into the handoff pages) -> GOP framebuffer (linear only) -> RSDP
and SMBIOS (3.x, else 2.x) from the UEFI config table, early UART from
ACPI SPCR (COM1 fallback on amd64) -> boot page tables (all RAM identity
mapped RWX, UART as device, kernel segments W^X at the KASLR base; Sv39
on rv64, TTBR0/TTBR1 on arm64) ->
ExitBootServices -> memory map converted into the handoff, framebuffer
range overlaid as CROI_MEM_FRAMEBUFFER (holes in it filled: q35's is a
PCI BAR no firmware range covers) -> handoff v5 (EFI_RNG_PROTOCOL entropy since v5) ->
`croi_arch_enter_kernel` (boot/arch/<arch>/enter.S). Loader allocations
use OS-defined memory types 0x80000001 (kernel) / 0x80000002 (handoff and
page tables) / 0x80000003 (bootfs) so they show up as CROI_MEM_KERNEL /
CROI_MEM_HANDOFF / CROI_MEM_BOOTFS. Nothing may call firmware after
ExitBootServices, including deinits: `BootVolume` (whose deinit closes the
volume) is consumed explicitly, because `bootKernel` never returns and
Swift may otherwise run the deinit at the very end.

Memory types (`CachePolicy` in lib/pagetables): cached, uncached,
writeCombining, device. amd64: the kernel programs the PAT (WB, WC, UC-,
UC) on every CPU (`arch_init_pat`); uncached = device = UC. arm64: MAIR set
by the loader (Normal WB, Device-nGnRE, Normal-NC, Device-nGnRnE); WC =
uncached = Normal-NC. rv64: Svpbmt when every RHCT ISA string lists it
(`PageTableFormat.svpbmt`, set by the kernel; NC for uncached/WC, IO for
device), else the PMAs decide. QEMU runs rv64 with `-cpu max` (Svpbmt);
`boot-smoke-no-svpbmt` covers `-cpu rv64`. The framebuffer
(CROI_MEM_FRAMEBUFFER) is in no PMM arena and not in the cached physmap;
`Framebuffer` maps it WC for the boot self-test, which draws a pattern
and unmaps it (user space owns it from then on, K9b), checked with a QEMU
screendump (`qemu.sh --screendump`, `tools/check-pixels.py`); arm64/rv64
get a framebuffer from `-device ramfb`.

Kernel (`kernel/Kernel/Main.swift`): validates the handoff, builds its own
page tables from free RAM with `BootAllocator` (front-to-back, never frees;
reads the handoff range table in place, which is CROI_MEM_HANDOFF and so
never handed out), and switches to them. Kernel address space
(`KernelLayout`): low half empty; physmap of all RAM at 0xffff800000000000
(amd64/arm64) or 0xffffffc000000000 (rv64 Sv39), RW + NX; device registers
the kernel uses are mapped in the physmap as device memory; the image at
its KASLR base with text RX, rodata R, data RW. amd64 loads its own GDT
first thing, since firmware's sits in memory reported free.

Physical memory (`Kernel/Pmm.swift`, global `pmm`, after Zircon's
PmmNode): arenas over contiguous RAM the kernel owns (free, kernel,
handoff, bootfs; ACPI reclaim, firmware runtime/NVS get none), each with
a `Page` array (32 B/page) carved by the boot allocator. Pages start `.wired`;
free RAM the boot allocator never handed out (it records exact spans) goes
on a doubly linked free list. amd64 keeps the first MiB wired for SMP
trampolines. `allocatePage`, `allocateContiguous(count, alignLog2:)`,
`free` (panics on double free), `endHandoff()` (frees the loader's handoff
data and boot page tables; nothing may read the handoff afterwards).
Guarded by `pmmLock`. ACPI reclaim is never the PMM's: user space reads
the tables there for good (K9b). Boot runs a PMM self-test.

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

User address spaces and VMOs (K4a, Kernel/Vm/):
- `UserAspace` (~Copyable owner of a heap `UserAspaceRecord`): lower-half
  tables (UserLayout: 2 MiB up to the half's top less 1 GiB) sharing the
  kernel half. amd64/rv64 copy the kernel root's upper 256 slots, which
  `populateKernelHalf` fills once at boot and `pinsTopLevel` keeps forever;
  arm64 uses TTBR0. ASIDs (arm64 8-bit, rv64 probed, amd64 none: CR3
  reload) are recycled with a flush. Threads carry `aspace`; switchAway
  loads the next thread's tables (kernel threads: the kernel's only).
  `MapAttributes.user` marks EL0/U pages (never global, never kernel-exec).
- `Vmo` (anonymous: zero pages committed on first touch; physical;
  contiguous) with a refcount held by the handle and every mapping;
  pages are PageState `.vmo`. Mappings (`Mapping`, rights read/write/
  execute) are kept sorted in the aspace; anonymous ones fault in,
  physical/contiguous ones map at once with large pages where aligned.
- Faults: only instructions in the `.croi_fixups` table (usercopy.h,
  `arch_user_load_u64`/`arch_user_store_u64`: arm64 ldtr/sttr, rv64 with
  SUM) may fault user memory in from the kernel; unresolvable faults
  resume at their recovery point with -1. The handler runs with the
  faulting context's interrupt state, so a CPU waiting for the aspace
  lock still answers the holder's TLB shootdown (it deadlocked masked).
  `vm` trace category: fault (resolved or refused) and commit records.
- Review round 1, part 2 (VM): `ArchAspace.unmap` chains emptied tables
  through their first entry (a page address, never present) and frees
  them after `flushOthers`; a failed eager map in `insert` unmaps what it
  mapped; `process_read_memory` retains the VMO under the aspace lock and
  `privatize` returns its child retained.
- Review round 1, part 4 (entry/exit): `Processes.start` refuses entry
  points at or above `UserLayout.top` (UserTraps.enter kills as a
  backstop); amd64 GDT 0x18 (USER_CS32, only STAR's sysret base) is not
  present, CSTAR is `syscall_compat_refused` (sysretl with -2, no stack
  or GS), SYSENTER MSRs are 0; `isr_common` executes clac (with SMAP)
  before anything; rv64 trap entry clears SUM after saving sstatus;
  `setAspace` loads the thread's TLS (FS/GS, TPIDR_EL0); register and
  debug-state access go through `Exceptions.withStopped` (under the
  thread object's lock); arm64 SError/FIQ from EL0 take the SError policy
  (contained or restartable ones become the process's exception).
- Review round 1, part 3: Zircon's resource limits raise POLICY_ERROR
  with the code as synth_code (`Policy.limitException`, task.h
  CROI_EXCP_POLICY_CODE_*): a channel write leaving more than
  `Channels.maxPending` (3500) queued (the message still goes),
  port_queue past `Ports.maxUserPackets` (4096 user packets, then
  SHOULD_WAIT), a port's `maxObservers`th (50000) async wait (still
  registered). Unhandled, the process dies. `HandleTable.get(have:)`
  returns a handle's rights from the same lookup as its object.
- Mapping ceilings (review round 1): each `Mapping` keeps `ceiling`, the
  rights it may ever have (vmar_map: the VMO handle's read/write/execute;
  kernel mappings: what they were mapped with; a `sharedReadOnly` VMO:
  read), and `protect` refuses more with ACCESS_DENIED (`VmError.
  accessDenied`). Before, a root-VMAR handle could protect the shared
  vDSO writable. Mode 17's checks 686-687 (686 failed without it).
- Regions (K4b): each aspace keeps `regions` (sub-regions, sorted, with a
  parent; region 0 is the root) and non-overlapping `mappings`. A
  reservation's range is held for views: `mapView`/`unmapView` replace
  views under the aspace lock, so faults (which take the lock) see the old
  view or the new one, never a hole (ext 7). `unmap(range)` trims and
  splits mappings; `protect` splits at the edges. VMOs list the aspaces
  mapping them (`mappers`); `decommit` takes pages out of the VMO, then
  unmaps them from each aspace (held by a reference, skipped if `dead`),
  then frees them, so the aspace -> vmo lock order holds.
- Physical (K4b, K9b): `PhysicalMap` keeps the memory-map ranges that
  are RAM (and persistent/unusable memory); physical VMOs over them are
  refused (`.denied`). Firmware memory the physmap maps cached (ACPI
  reclaim and NVS, UEFI runtime) is allowed but only whole, and such a
  VMO is always cached (`cachedFirmware`; `setCachePolicy` refuses
  anything else), so no mapping disagrees with the physmap.
  Contiguous VMOs take an address `limit` and come from `ContiguousPool`
  first (`croi.contiguous_pool=<MiB>`, default 8, below 4 GiB if it can).
  `cacheOp` (include/cache.h: clflush, dc cvac/ivac/civac, Zicbom cbo.*
  when the RHCT lists it) and `setCachePolicy` (unmapped VMOs only).
- Accounts (ext 6): `MemoryAccount` limit + pressure level; anonymous VMOs
  charge per committed page, contiguous (pinned) and `deviceLocal` VMOs in
  full and are `neverEvict`; over-budget commits fail; the pressure hook
  fires once per crossing and re-arms below 80% of the level.
- Anonymous pages live in a sparse 512-way radix `PageList`.
- W^X and JIT (K4c, Vm/Jit.swift): no mapping is writable and executable
  (map, mapView and protect refuse it), except in a JIT reservation
  (`allocateRegion(reservation: true, jit: true)`) on hardware with
  protection keys: amd64 PKU (CR4.PKE on every CPU), where the
  reservation gets a key (1-15, `MapAttributes.protectionKey`, PTE bits
  62:59), its pages map RWX, and each thread's PKRU (`Thread.pkru`,
  loaded at switch; user threads start with writes to keys 1-15
  disabled) gates writes per thread (`Scheduler.setJitWritable`; WRPKRU
  in user space). A PKU fault (error code bit 5) is refused outright.
  Without keys (arm64: POE is Armv9.4 and neither target board has it;
  rv64) a JIT maps two views of one VMO, RW and RX. Swift note: a failed
  `guard` may end the lifetime of `~Copyable` values early (their deinit
  runs before the else branch), so join threads before judging them.
- Lock order: aspace -> vmo -> account -> heap -> pmm (and vm for the
  kernel aspace).

User mode (K6a, Kernel/User/, include/user.h): a user thread's registers
are an arch_exception_frame_t at the top of its kernel stack while it is in
the kernel; `UserTraps.enter` (setAspace, `Scheduler.setKernelStack`,
`arch_enter_user`) drops to user mode, and traps/syscalls/interrupts come
back through `arch_exception` (`ExceptionFrame.fromUser`) to
`UserTraps.handle`: interrupts preempt as usual, syscalls go to
`Syscalls.dispatch` (interrupts on), user page faults resolve through the
VM or kill the thread, anything else kills it (exit codes
`killedByFault`/`killedByException` until K7's exception channels).
switchAway keeps PerCpu `kernel_sp` (and the amd64 TSS RSP0) at the next
thread's stack top.
- amd64: swapgs on every user entry/exit (in the kernel GS_BASE is the
  PerCpu, KERNEL_GS_BASE the user's); SYSCALL (LSTAR `syscall_entry`,
  number in rax, args rdi rsi rdx r10 r8 r9) builds the same frame
  (vector 0x100) and returns with sysretq (the rip is SYSCALL's, so
  canonical); STAR/FMASK in `arch_syscall_init`, per CPU.
  `arch_syscall` runs `UserTraps.leaving()` after the dispatch, as every
  other way back to user mode does (it didn't: a killed thread retrying
  failing syscalls ran on until an interrupt caught it in user mode).
- arm64: EL0 vectors (slots 8-15) skip the overflow check and save/restore
  SP_EL0; SP_EL1 is the stack top because user frames sit there; svc #0
  with the number in x16 (Zircon's); TPIDRRO_EL0 is kernel scratch and 0
  for user mode. IRQs from EL0 are slot 9.
- rv64: sscratch is 0 in S-mode (set in arch_init_exceptions: firmware
  leaves anything) and the PerCpu in U-mode; the entry swaps it with tp
  to tell the origins apart; ecall with the number in a7.
- `arch_copy_from_user`/`to_user`: byte loops listed in .croi_fixups
  (arm64 ldtrb/sttrb; rv64 with SUM).
- K6b: user-access protection on every CPU (`arch_user_protection_enable`,
  `croi_user_protection`): amd64 SMEP + SMAP (stac/clac in the accessors
  and `arch_user_access_begin/end`), arm64 PAN set on every kernel entry
  (SPAN clear; accessors use ldtr/sttr, which PAN doesn't block), rv64 SUM
  only inside the accessors. A fault the protection caused
  (`ExceptionFrame.userAccessBlocked`) goes straight to recovery.
  Syscalls touch user memory only through `UserCopy`, which checks the
  user range first: the arch copies don't, and on amd64/rv64 would write
  kernel pages through a pointer user space chose (a test caught it).
  The object syscalls (user/include/croi/syscall.h: handles, signals,
  waits, events, ports, VMOs, vmo_map until VMARs, trace_configure) use
  the thread's `handleTable` (K7: the process's). `syscall` trace
  category (enter/exit). User programs: `user/` is built with user flags
  (CMake custom command, static at the address the kernel maps it) and
  included with `.incbin` (kernel/userprogram.S).
- K6c: shared read-only pages (include/shared.h, Kernel/User/Vdso.swift):
  the time page, a topology page and a power page (ext 9), each with a
  seqlock sequence (`SharedPages.write` bumps it odd/even); the scheduler
  republishes a CPU's capacity and power hints when they change
  (`publishPowerHints`, outside its lock). The vDSO (user/vdso: header
  with function offsets at byte 0, code, then the three pages, all
  reached PC-relatively) is mapped by `Vdso.map` into a region of its
  own: code read/execute, pages read only (`Vmo(sharedKernelPage:)`, the
  only RAM a physical VMO may cover, never writable). User counter
  access per CPU (`arch_user_counter_enable`: arm64 CNTKCTL_EL1.EL0VCTEN,
  rv64 scounteren.TM). User binaries come from `croi_user_binary`
  (cmake/CroiUser.cmake) with `CROI_USER_CFLAGS` (cmake/arch).
- K6d: user FP/SIMD. Every user thread gets an ExtendedState area at
  `UserTraps.enter`; `Scheduler` saves the outgoing and restores the
  incoming thread's state at each switch (`arch_xstate_save/restore`,
  arch cpu.S; kernel threads have none, and the kernel never uses FP, so
  traps and syscalls don't save it). `croi_xstate_config` picks the
  format: amd64 XSAVE with XCR0 = the shared features less PKRU (the
  scheduler switches it) and AMX tiles; arm64 Neon, or SVE Z/P/FFR at the
  boot vector length; rv64 F/D, plus V at vlenb (sstatus FS/VS on for
  user threads). Not yet: lazy AMX via XFD, SME/streaming mode (trapped),
  per-thread SVE vector length. User code is built for the baseline ISA
  with FP/SIMD (`CROI_USER_CFLAGS`: x86-64, Armv8, rv64gc; SVE, V and
  AVX are run-time options); amd64 `_start` realigns its stack.
- K6e, sampling (Kernel/Trace/Sampler.swift): with CROI_TRACE_SAMPLE on,
  each CPU running a thread samples it every 1/sample_hz (trace_configure
  start's sixth argument, default 1 kHz): a SAMPLE record (PC, frame
  count, source) and FRAMES records (two return addresses each, up to
  16), consecutive in the ring. Kernel addresses are image offsets with
  CROI_SAMPLE_KERNEL set. Frame-pointer walks: kernel frames only inside
  the interrupted 32 KiB stack block; user frames via `UserCopy`, and a
  thread sampled in a syscall continues into its user frames (the frame
  at its kernel stack top). Any fixup fault in interrupt context goes
  straight to recovery (`PerCpu.interruptFrame`, set by
  `Interrupts.handle`), so nothing pages in from an interrupt. The
  sampling timer is armed at a switch to a thread and lapses on a tick
  that finds the CPU idle, so idle CPUs stay tickless. Kernel and user
  code keep frame pointers; amd64 user `_start` is a crt-style stub that
  calls C (a C entry with a 16-aligned stack misaligns rbp).
- K6e, PMU (Kernel/Trace/Pmu.swift, include/pmu.h, syscall 51
  pmu_configure): per-thread counters (up to 4 generic or raw events;
  `Thread.pmu`, stopped and accumulated at switch-out, restarted at
  switch-in) and overflow sampling into the same SAMPLE records (source
  1 + generic event) with the tracing resource. The sampling counter is
  stopped while a CPU idles. amd64: Intel architectural PerfMon (CPUID
  0xA, full-width writes) or AMD core counters (PerfCtrExtCore, PerfMonV2
  global control), LVTPC vector 0xF8 (not NMI: masked code isn't
  sampled); arm64 PMUv3 (overflow PPI from the GICC's performance GSIV,
  offset 20); rv64 SBI PMU (counters chosen per event by the SBI) with
  Sscofpmf's LCOFI (interrupt 13) when the RHCT lists it. QEMU TCG amd64
  has no PMU; KVM on this AMD host covers the AMD backend; the Intel
  backend is unverified until it runs on an Intel machine. QEMU arm64
  counts instructions only with icount, so its tests use cycles.
- User threads killed by a fault or exception are logged (cause and PC)
  until K7's exception channels report them.
- The boot test runs `usertest.S` (per arch) from a VMO: registers kept
  across syscalls, a message, a fault and a privileged instruction killed,
  preemption of user code; it reports the null syscall time (KVM: ~40 ns).

Kernel objects (K5, Kernel/Object/; Zircon's status codes, rights,
signals and object types, so the ABI matches):
- Every object record starts with an `ObjectHeader` (type, koid from 1024,
  signals, observers, lock, atomic refcount); `ObjectPointer` reaches it,
  `Objects.destroy` frees by type. Not `Ref<T>`: objects mutate under
  their own lock, like VMOs and aspaces. `ObjectRef` (~Copyable) is a
  reference held by kernel code; handles hold one each.
- `HandleTable` (per process from K7): slots of (object, rights); a value
  is slot + 8-bit generation + Zircon's fixed low bits, so stale handles
  fail. get (bad handle, wrong type, access denied, in that order),
  duplicate/replace (rights subset or sameRights), close (cancels waits
  through the handle). `HandleTable.withBorrowed` for threads sharing one.
- Waiting: observers on an object's list; `updateSignals` runs them under
  the object lock. `ObjectWait.one/many` (deadlines, canceled on close;
  WaitState on the heap so no trigger outlives it). Ports (`PortObject`):
  FIFO of `PortPacket` (zx_port_packet_t layout), `Ports.queue/wait/
  cancel`; `Observers.waitAsync` is one-shot with EDGE and TIMESTAMP,
  its packet allocated at registration. Lock order: object -> scheduler
  -> port packets (object locks may be held while taking the scheduler
  lock; nothing takes them under it).
- `PacketSource`: kernel events reporting to a port with one owned,
  coalescing packet (count): budget overruns (ext 3,
  `SchedContext.bindOverrunPort`, fired under the scheduler lock) and
  memory pressure (ext 6, `MemoryAccount.bindPressurePort`).
- `VmoObject` (default rights as ZX_DEFAULT_VMO_RIGHTS; `forMapping`
  needs map plus read/write/execute per access). `ResourceObject`: root
  (made at boot) mints system resources; the tracing one (base 14, as
  Zircon) gates `TraceControl` (start, stop, rewind, mark, rings as
  read/map-only VMO handles).

Processes (K7a, Kernel/Object/Process.swift, include/task.h, syscalls
60-74 in User/TaskSyscalls.swift):
- Job (17), process (1), thread (2) and VMAR (18) objects, Zircon's
  rights and TERMINATED signal. A root job at boot. A process owns its
  `UserAspace` (the vDSO mapped at creation) and `HandleTable`; threads'
  syscalls use the process's table. Its first thread gets the transferred
  handle, arg2 and the vDSO base in the first three argument registers
  (`arch_enter_user` takes three); a C entry on amd64 needs a call-aligned
  stack (crt-style stub, or start sp at top - 8).
- Each user scheduler thread holds a reference to its thread object
  (`Thread.object`), which holds the process. The last running thread
  tears the process down from its own context: `setAspace(nil)`, close
  every handle (so a process holding its own handle still dies), wait
  until earlier exiters have left the address space, destroy it. A
  process whose threads never ran is torn down by its last reference.
- Kill (`task_kill`, process_exit, a fault until K7d's exceptions):
  `Scheduler.interrupt` marks the thread; interruptible waits (syscall
  waits: object/port waits, nanosleep: `block(interruptible: true)`) end
  with `.interrupted`, a running thread is preempted, and every return to
  user mode (`UserTraps.leaving`) exits a marked thread. Return codes
  -1024 (killed), -1026 (policy) and -1028 (exception), Zircon's. Kernel-only waits stay
  uninterruptible.
- VMARs wrap K4 regions (`UserAspace.withView`); `vmar_map` and friends
  pack handle | options << 32 into one register (six argument
  registers). A dead address space refuses operations under its lock
  (`VmError.dead`). User code has `croi_syscall6`.
  `vmar_unmap_handle_close_thread_exit` (75) is a syscall (Zircon's is
  vDSO code): `Syscalls.run` exits the thread after the handle-table
  borrow ends, so no frame holds a reference; a failed close raises an
  undefined-instruction exception (Zircon's vDSO traps).
- User TLS (`Thread.tls`/`gs`, switched in `switchUserTls`): amd64 FS
  and user GS bases only through object_set/get_property REGISTER_FS/GS
  (4/2; the calling thread's own handle, canonical; CR4.FSGSBASE stays
  off, so the record is the truth and a per-CPU cache skips unchanged
  WRMSRs); arm64 TPIDR_EL0 saved and restored per user thread; rv64 tp
  is in the frame. thread_read/write_state carry them.
- `vmo_create` rounds sizes up to a page (Zircon's RoundSize); size 0
  makes a zero-size VMO, as Zircon's (since K9a).
- `object_get_child` (78, K15d; Zircon's, for Todhchai's Inspector,
  `Processes.child`): a job's child job or process, or a process's
  thread, by koid. ENUMERATE on the parent, SAME_RIGHTS (exactly) for the
  parent handle's rights or a subset of them (else ACCESS_DENIED), a koid
  not a live child NOT_FOUND (dead threads and processes stay listed
  until their last reference, so they are filtered: Zircon drops them
  at exit), other parents WRONG_TYPE. Mode 17's checks 746-751.
- Lock order: job -> process -> thread object -> scheduler.

Channels (K7b, Kernel/Object/Channel.swift, include/ipc.h, syscalls 80-86
in User/IpcSyscalls.swift):
- Channel (4) and eventpair (16) endpoints share a `PeerShared` (lock,
  channel id = smaller koid); peers link without references and reach
  each other with `ObjectPointer.tryRetain`. Messages (bytes up to 64
  KiB, up to 64 handles) are one heap block owning a reference per
  handle; as in Zircon, write and call consume every listed handle
  whether or not they succeed (`build` takes each out of the table,
  closing the bad ones, first error wins: TRANSFER, not the channel
  itself, a repeat finds BAD_HANDLE), unless the list can't be read. Closing an endpoint
  raises PEER_CLOSED on the peer, ends calls waiting on it, and frees
  unread messages outside the lock. READABLE/WRITABLE/PEER_CLOSED are
  object signals, so waits and ports see them.
- `channel_call`: the kernel writes a txid (high bit set) into the first
  four bytes; a write whose txid matches a pending call on the peer goes
  straight to that caller. Ext 2 donation: the thread that reads a call
  becomes the owner of the caller's call-record queue
  (`Scheduler.setOwner`, refused if it would close a cycle), so K3b
  inheritance lends it the caller's profile until the reply; an exiting
  thread drops what it owns (`dropOwnership`). `channel_read` packs its
  capacities (bytes | handles << 32) and actuals.
- `ipc` trace: CHANNEL_WRITE/READ and DONATE records carry
  `croi_flow_id(channel id, txid)` (ipc.h, splitmix64 finalizer), which
  user space computes from `object_get_info(HANDLE_BASIC)` koids and the
  txid, so a call and its reply share one flow.
- Test-only syscall 6 (`TestHooks.profile`; NOT_SUPPORTED unless
  `croi.test=1` or `croi.debug_syscalls=on`, since review round 1: its
  hooks reboot, evict and sign with the kernel's key): bind to / report a deadline
  context a self-test provides, until profiles are objects.

Futexes and timers (K7c, Kernel/Object/Futex.swift, TimerObject.swift,
syscalls 90-97 in User/SyncSyscalls.swift):
- Futexes keyed by (address space, user address) in a 256-bucket table
  under the scheduler lock, which is the futex lock: a wait reads the
  word with `UserCopy.wordNoPageIn` (PerCpu.noPageIn: a fault goes to
  recovery; the wait drops the lock, pages it in and retries), compares
  and blocks under it. Records are allocated outside the lock and retire
  when no waiter refers to them (`users`: a woken waiter hasn't run yet
  when its waker returns), the queue is empty and nobody owns them;
  `Thread.futex` follows a waiter through requeue. Owners use K7b's
  `setOwner` (a cycle leaves the futex unowned); wake clears the owner,
  wake_single_owner hands it to the woken thread. `futex` trace records.
- Out-pointer checks (`Syscalls.check`) ask the address space whether
  writable mappings cover the range (`UserAspace.covers`): nothing is
  read or written, so any size works and a concurrent user write isn't
  clobbered; the copy out still recovers from faults. K14m: a thread
  caches the mapping its last check found (`Thread.coverStart/End`) with
  the address space's `mapGeneration` (bumped under its lock at every
  change to `mappings`), and a check inside it with the generation
  unchanged skips the lock.
- Timer objects (22): set arms the object's own timer node on the calling
  CPU, holding a reference (generation numbers ignore stale callbacks;
  cancel takes the node out of the arming CPU's queue from anywhere);
  slack windows as Zircon's center/early/late; zero slack for a
  thread on a deadline profile. Set and cancel clear SIGNALED (cancel
  too for a timer that already fired, as Zircon's). The last handle's
  close cancels (K14b: `Objects.lastHandleClosed`, Zircon's
  on_zero_handles, run from `HandleTable.close`, a freed message's
  handles and `releaseTaken`; handle_replace adds the new handle before
  closing the old so the count never passes through 0).

Exceptions and job policy (K7d, Kernel/Object/Exception.swift, task.h,
syscalls 100-107 in User/ExceptionSyscalls.swift):
- A user fault or exception (`UserTraps.offer`, typed per arch by
  `ExceptionFrame.exceptionType`) is offered to the thread's, process's,
  then each job's exception channel up the tree. The kernel keeps its
  end of each (`task_create_exception_channel`; ALREADY_BOUND while the
  user end is open); a message is croi_exception_info_t plus a handle to
  an exception object (29). The faulting thread waits (interruptibly)
  until the object's last reference goes, then: HANDLED resumes it with
  whatever `thread_write_state` put in its frame (`ThreadObject.
  exceptionFrame`, general registers only while in an exception),
  THREAD_EXIT ends it, TRY_NEXT moves on; unhandled kills the process
  (-1028). amd64 #BP's IDT gate is DPL 3 so a user int3 is a breakpoint.
- Job policy (`Policy`): an action per ZX_POL condition in each job,
  copied to child jobs at creation, settable only while the job has no
  children (ABSOLUTE refuses conflicts, RELATIVE skips them; NEW_ANY
  expands to every NEW_*). Creation syscalls check NEW_*; a BAD_HANDLE
  result checks BAD_HANDLE. KILL marks the process killed and lets the
  syscall unwind (Swift frames hold references) before the thread exits
  on its way out; *_EXCEPTION raise POLICY_ERROR first.
- Not yet: SError delivery to the faulting process. (Debugger channels
  and exception reports came in K13g.)

Debuglog and user programs (K8a, Kernel/Object/DebugLog.swift,
Kernel/User/ProgramLoader.swift, include/log.h, include/processargs.h,
syscalls 110-112):
- `DebugLog`: one ring of 512 fixed 256-byte croi_log_record_t slots
  (oldest overwritten), Zircon's record layout. Log objects (type 12):
  write-only ones need no resource, READABLE ones the debuglog system
  resource (base 12) or root; each reader has its own position (starts at
  the oldest record) and READABLE while behind. A `dlog-dumper` thread
  prints every record as `[sssss.mmm] pid:tid> text`. Lock order:
  debuglog -> object -> scheduler.
- Console: `ConsoleLock` serializes `Uart.write` calls between CPUs
  (recursive holders pass, waiters give up after 10^8 spins so a panic
  can't hang); the dumper's `writeLines` waits up to 50 ms for another
  CPU to finish a line it is writing in pieces.
- `ProgramLoader.start`: an ET_EXEC from kernel memory into a new process
  (each PT_LOAD copied into its own VMO, stack of PT_GNU_STACK's size or
  256 KiB) and a bootstrap channel whose first message is Zircon's
  processargs: PROC_SELF, THREAD_SELF, VMAR_ROOT, then the caller's
  handles (PA_FD 1 = stdout debuglog, PA_RESOURCE, ...), argv[0], the
  environment. PT_GNU_RELRO's pages are read only once relocated (K14c).
  Static PIEs load at a random base (K11b).
- User programs (`croi_user_program` in cmake/CroiUser.cmake): C and/or
  Embedded Swift, linked at 0x1000000 with separate page-aligned
  segments, against the user runtime (user/lib/runtime, C: `_start` reads
  the bootstrap message, `croi_take_startup_handle`, stdout line-buffered
  into debuglog records, a size-class heap over 64 KiB VMO chunks in the
  root VMAR, plus lib/rt). Swift user code imports `CroiRuntime`
  (user/include/module.modulemap); the ABI headers it reaches are module
  `CroiAbi` in kernel/include (which CKernel re-exports through abi.h), so
  user code never builds the kernel's private headers. User Swift isn't
  bound by the kernel's no-ARC rule (low-half addresses). The boot test
  runs user/test/swift: stdout, heap, environment, debuglog round trip.

bootfs and userboot (K8b, Kernel/User/Userboot.swift, user/userboot,
tools/mkbootfs.py):
- bootfs.img is Zircon's bootfs format (no ZBI around it), built by
  `tools/mkbootfs.py` from the `bootfs` target (today `bin/m2`). The
  kernel adopts the loader's CROI_MEM_BOOTFS pages into an anonymous VMO
  (`Vmo(adopting:)`, `Pmm.adopt`: wired -> vmo; freed when the VMO goes).
- After "boot complete" the kernel starts userboot (an ELF in the kernel
  image, Embedded Swift, compiling lib/elf's source in) with
  `ProgramLoader`: root job, root resource, bootfs VMO (with EXECUTE),
  a stdout debuglog, and the command line's words as its environment
  (`BootOptions.withEnvironment`).
- userboot maps bootfs, finds `userboot.next=` (default bin/launcher;
  the build appends `userboot.next=${CROI_USERBOOT_NEXT}`, default
  bin/m2, to the ESP cmdline), loads its ELF into a new process
  (segments that are all file mapped straight from the bootfs VMO, others
  copied; stack from PT_GNU_STACK), passes on every handle it got plus a
  new stdout in a processargs message, starts it, waits, and prints
  `userboot: <name> exited with <code>`. Boot tests wait for that line
  with code 0 (`CROI_BOOT_DONE`).
- Syscalls added for it: `vmo_get_size` (44) and object_get_info
  CROI_INFO_VMAR (base, length). Embedded Swift `String ==` needs the
  Unicode tables (not linked): compare bytes.

The M2 exit test and budgets (K8c, user/m2, Kernel/Object/ProfileObject.swift,
include/profile.h):
- `bin/m2` is userboot.next (CROI_USERBOOT_NEXT): channel pair, a VMO
  passed across, a port wait with a deadline timer, debuglog output; then
  it measures the budgets from the trace (user marks via TRACE_OP_RINGS, 4:
  each CPU's ring as a read/map-only VMO) and reports them as `budget`
  lines (K9f: enforced only with `croi.enforce_budgets=1` where
  `croi_timing_is_real()`, user/lib/runtime/timing.c; see "Timing
  discipline"). KVM: null 32-36 ns,
  channel_call ~1.4 µs (target 1 µs, enforced against 1.6 µs for now),
  port wake median ~1.75 µs (p99 noisy, not enforced), wake error p99
  27-46 µs. Measure wake error with `Sys.now()` directly: converting trace
  counter time from an anchor mark was off by up to 170 µs.
- Profile objects (25): `profile_create` (120, profile system resource
  base 10 or root; zx_profile_info_t), `object_set_profile` (121: MANAGE_THREAD on
  the thread, APPLY_PROFILE on the profile), refusal reasons (ext 4) in an out-parameter.
  Test-only syscall 6 is still used by the kernel self-test.
- Under a hypervisor an idle CPU polls for `croi.idle_poll_us` (default
  200, 0 on hardware) before halting, announced in `pollingCpus`, so a
  cross-core wake skips the IPI (and its VM exits).
- `m2.ipc_profile=1` on the command line (K14l): after the channel_call
  batches m2 traces 200 more with syscall, scheduler and IPC records (and
  any kernel `CROI_TK_MARK` probes added while chasing something) and
  prints a call's events with the median gap before each, then samples PCs
  at 10 kHz over 300,000 calls and prints the top ones (kernel ones as
  image offsets with bit 63 set; samples land where interrupts come back
  on, so masked stretches show at their end).
- `m2.wake_profile=1` (K14n): one fair thread, then four, timing out on a
  port every 5 ms (Todhchai's executor), printed as lateness (deadline to
  user space by the vDSO clock) split into the timer interrupt arriving
  late and the kernel's interrupt-to-user path, plus a few wakes' records.
- `m2.portwake_profile=1` (K14o): the port wake bench again, traced,
  each wake's records from both CPUs merged in time (signal entry to
  port_wait exit), median gap before each.
- Timed wakes under KVM (K14n): every VM exit cost ~4-5 us on this host.
  `LocalApic.endOfInterrupt` uses KVM's PV EOI where offered (per-CPU
  words in one page, MSR 0x4B564D04; `croi.pv_eoi=off`), testing and
  clearing the bit in one instruction (`arch_test_and_clear_bit0`, btr):
  KVM may clear it at the exit it takes for a newly pending interrupt, and
  a separate test and clear skipped the needed EOI write, leaving the
  vector in service (half the full KVM boots hung). An x86 timer interrupt
  no longer disarms the spent TSC deadline. Under a hypervisor the timer
  hardware is armed early by `Timers.wakeLead` (a running average of how
  late interrupts came after the armed time, capped at 50 us;
  `croi.timer_lead=off`) and the interrupt waits out the rest, so timers
  still never run early. A fair thread's 5 ms port_wait timeout: ~3-6 us
  late (median), from 15-40.
- Hot-path notes from the budget work: `Scheduler.locked` drops the lock
  through `cancelTimeout` (one round trip); `Timers.arm` writes the
  hardware only for a sooner timer and `cancel` leaves it armed (the
  invariant: armed no later than the earliest pending `latest`; the
  interrupt re-arms via `program`); amd64 saves with XSAVEOPT; the heap's
  double-free walk runs only for an object still poisoned;
  `UserAspace.covers` binary-searches; `ObjectWait.one` returns at once
  if the signals are already set. Channel and port default rights are
  Zircon's (no DUPLICATE; ports no WAIT). -O was worse than -Osize.

Driver support, K9a (Kernel/Object/Resource.swift, User/DriverSyscalls.swift,
User/IoPorts.swift, include/resource.h, include/vmo.h; Todhchai M3):
- Resources are Zircon's: kind (MMIO 0, IRQ 1, IOPORT 2 amd64, SMC 4
  arm64, SYSTEM 5), base, size, flags, name. Size 0 is the kind's ranged
  root; the root resource (kind ROOT 3, PA_RESOURCE) is every kind's.
  userboot also gets each kind's ranged root (PA_MMIO_RESOURCE 0x50 ...
  PA_SYSTEM_RESOURCE 0x54) and passes them on. `resource_create` (130,
  parent | options << 32) follows Zircon's checks in order (WRITE on the
  parent; a child inside its parent; EXCLUSIVE only from a ranged root
  and no children of it; overlaps with an exclusive one NOT_FOUND).
  A ranged root refuses a range whose end (rounded to pages) wraps past
  2^64 (OUT_OF_RANGE, review round 1: the wrapped end passed every
  overlap test, so the MMIO root mapped all of RAM; check 688).
  `Resources.validate` is Zircon's validate_ranged_resource (non-strict:
  an MMIO resource grants the pages it touches); `check(system:)` uses
  it. `RootFilter` is the root filter: RAM (`PhysicalMap`; firmware
  ranges and RESERVED ones such as PCIe ECAM are allowed, as in Zircon),
  device registers the kernel maps (`mapPhysical` with device caching
  records them; the console UART, the amd64 LAPIC/MSI window, the GIC
  ITS), and on amd64 the 8259 and console UART ports.
  ZX_INFO_RESOURCE (18). The tracing base is Zircon's 14.
- VMOs: `vmo_create_physical` (47; MMIO resource; uncached-device by
  default), `vmo_set_cache_policy` (46; MAP right; unmapped only, else
  BAD_STATE; UNCACHED and UNCACHED_DEVICE both map `.device`, so arm64
  gets Device-nGnRE where Zircon uses nGnRnE for UNCACHED),
  `vmo_op_range` (45: COMMIT/PREFETCH round out, DECOMMIT aligned, ZERO
  by bytes, cache CLEAN/CLEAN_INVALIDATE by bytes, CACHE_SYNC syncs the
  I-cache, CACHE_INVALIDATE NOT_SUPPORTED). vmo_read/write refuse device
  VMOs (NOT_SUPPORTED) and uncached ones (BAD_STATE). Zero-size
  anonymous VMOs exist. `Vmo.syncInstructions` (arm64 dc cvau + ic ivau,
  rv64 fence.i plus SBI remote fence.i) runs after ProgramLoader copies
  code; user loaders (userboot, Todhchai's) must do the same through
  `cache_flush` on arm64 hardware (QEMU TCG is coherent).
- The vDSO header is version 2 with `cache_flush` (Zircon's
  zx_cache_flush; runtime `croi_cache_flush`); the topology page
  (version 2) publishes `dcache_line`/`icache_line`. User cache ops are
  opened on every CPU (`arch_user_cache_enable`: arm64 SCTLR_EL1.UCI and
  UCT, rv64 senvcfg.CBCFE with Zicbom).
- amd64 IO ports (131/132): each CPU's TSS carries an 8 KiB I/O bitmap
  (deny all); a process's bitmap lives on its `UserAspaceRecord` with a
  never-reused id, copied in at a switch to a user thread when the
  loaded id differs, and pushed by IPI to every CPU that has it loaded
  or runs the process when it changes (so a release is immediate).
- Boot test mode 10 (`ProcessSelfTest.runDrivers`, startup block word 3
  is the root resource) reads a device register through a physical VMO
  per arch (q35 ECAM at 0xE0000000, the PL031, the goldfish RTC).

Firmware data for user space, K9b (Kernel/User/BootData.swift,
include/zbi.h; Todhchai item 20):
- Boot data: one ZBI container (Zircon's format; croi has no ZBI
  otherwise) of ACPI_RSDP, SMBIOS, FRAMEBUFFER (zbi_swfb_t; GOP BGRX is
  RGB_X888, RGBX is BGR_888_X) and MEM_CONFIG (RAM the kernel owns,
  PERIPHERAL for MMIO and the framebuffer, RESERVED for the rest)
  items. `BootData.build` writes it into boot allocator pages before the
  PMM takes over (the memory map lives in handoff memory); `makeObject`
  adopts them into a VMO. userboot gets it read only (no WRITE) as
  Zircon's PA_VMO_BOOTDATA (0x1A) and passes it on. zbi.h is the whole
  contract (Todhchai writes its own reader).
- Firmware memory is read through physical VMOs under an MMIO resource
  (always cached, see Physical above); RAM stays refused. The kernel
  unmaps the framebuffer after its self-test, so a driver's physical VMO
  over it (WRITE_COMBINING) is its only mapping.
- Boot test mode 10 continues (startup block word 4 is the boot data):
  the container and every item well formed, the RSDP through a narrow
  MMIO resource (uncached and WC refused), the XSDT's checksum, every
  MEM_CONFIG RAM range refused, the SMBIOS anchor, and the kernel's
  framebuffer pattern read back write-combining. QEMU has SMBIOS and a
  framebuffer on all three machines.

Interrupt objects, K9c (Kernel/Object/InterruptObject.swift,
Kernel/Irq/DeviceIrqs.swift, include/interrupt.h, syscalls 140-146 in
User/DriverSyscalls.swift; Todhchai item 13):
- Zircon's InterruptDispatcher: states IDLE / TRIGGERED / NEEDACK /
  WAITING / DESTROYED, delivered as a port packet (type 7, payload[0] the
  timestamp; the port needs BIND_TO_INTERRUPT, and its interrupt packets
  are a list of their own read first, owned by the object so firing never
  allocates) or to one thread in interrupt_wait. Level interrupts are
  masked when they fire and unmasked on ack / the next wait. Virtual
  interrupts (interrupt_trigger) carry UNTRIGGERED (signal 4). Rights are
  Zircon's (bind READ + port WRITE, ack WRITE, wait WAIT, trigger SIGNAL).
  Timestamps are monotonic (no suspend, so boot time is the same).
- Numbers: amd64 GSI (IOAPIC pins, vector 0x30 + GSI below 0x80; MADT
  overrides for MODE_DEFAULT and REMAP_IRQ; else ISA edge-high, PCI
  level-low), arm64 INTID (GICv3 SPIs; active high only), rv64 GSI (PLIC
  sources, the RINTC's context per hart; active high only).
  EDGE_BOTH is NOT_SUPPORTED. One object per number (ALREADY_BOUND).
- `interrupt_set_affinity` (146, croi's): routes to the lowest CPU of the
  mask with `interruptsReady` (IOAPIC physical destination, IROUTER, PLIC
  enable bits); INVALID_ARGS when none, NOT_SUPPORTED for virtual ones.
  Until set, the boot CPU. CPUs another job reserved are skipped (K10d).
- `DeviceIrqs`: handler table (heap, by number) under `tableLock`, held
  while a handler runs, so `unregister` means no handler is running; lock
  order table -> object -> controller (and object -> scheduler -> port
  packets). A number with no handler is masked when it fires.
- Differences from Zircon: closing the handle a thread waits through
  cancels its interrupt_wait (as object waits; Zircon cancels on the last
  handle). The object is destroyed with its last reference. Ext 5's
  scheduling-context handoff (K14e) wakes through `signal`.
- Boot test mode 11 (`ProcessSelfTest.runInterrupts`): virtual interrupts
  through every state, then each machine's RTC (amd64 CMOS periodic, GSI
  8, edge; arm64 PL031, INTID 34, level; rv64 goldfish, GSI 11, level)
  by port and by wait, routed to CPU 1 (the kernel checks where it was
  taken). It reports the median wait wake (fire timestamp to the woken
  thread reading the clock): KVM 11-18 us, the interrupt on CPU 1 waking
  a thread elsewhere. QEMU's PLIC pends only on a rising line, so rv64
  skips the "acked while still asserted fires again" check.

MSI, K9d (Kernel/Object/MsiObject.swift, DeviceIrqs MSI part,
include/interrupt.h; syscalls 147 msi_allocate, 148 msi_create):
- Zircon's model: an allocation object (type 32, rights BASIC) of `count`
  (power of two, up to 32) contiguous vectors aligned to `count` on the
  boot CPU, from the MSI system resource (base 11); ZX_INFO_MSI (28)
  gives target address/data. `msi_create` makes interrupt object `id`:
  MSI-X (option 1) programs the table entry in the VMO (physical,
  uncached) and masks through its vector control; plain MSI checks the
  capability (ID 5) and masks through per-vector mask bits if present;
  the driver programs the capability itself. MSIs behave as level
  interrupts (masked while delivered). Destroying an MSI-X object clears
  and masks its entry.
- amd64: vectors 0xB0..<0xF0 per CPU (`DeviceIrqs.allocateMsi`), handler
  table by (CPU, vector), message 0xFEE00000 | APIC ID << 12 (IDs above
  255 NOT_SUPPORTED), or with interrupt remapping (K12f) the remappable
  format naming the (CPU, vector) entry, written by `DeviceIrqs.prepareMsi`
  at msi_create and retarget and cleared by `releaseMsi`. set_affinity moves an
  MSI-X vector: a vector on the new CPU, the entry rewritten under its
  mask, the old vector dropped; plain MSI is NOT_SUPPORTED (the driver
  owns the capability). arm64: through the GICv3 ITS (K12h, below); rv64:
  through AIA's IMSICs (K12i, below), else NOT_SUPPORTED (the PLIC).
- The kernel's mappings of MSI-X tables and capabilities are `shared`
  (`mapPhysical(shared:)`): they don't enter the root filter's list of
  kernel MMIO, so the driver keeps its resource over them.
- Boot test (mode 11, amd64; croi's QEMU gets `-device edu,addr=0x10`):
  edu's MSI by port and by wait, with the driver programming the
  capability from the info; a virtio device's MSI-X table (MSI-X not
  enabled, so it never fires) read back after create, a move to CPU 1,
  and close. Both are found by scanning bus 0 and skipped when absent,
  and the config registers touched are restored: Todhchai boots this
  kernel on other machine shapes, with its own edu driver (INTx). KVM
  timing note: channel_call in m2 reads 1.4-2.8 us when the host is
  busy; compare builds interleaved, not one after the other.

DMA, K9e (Kernel/Object/Dma.swift, User/DmaSyscalls.swift, include/dma.h;
syscalls 150-156; Todhchai item 14 without an IOMMU):
- Zircon's iommu_create (stub only: one-byte descriptor; INTEL/ARM_SMMU
  NOT_SUPPORTED), bti_create, bti_pin (bti | options << 32, vmo |
  addrs_count << 32: eight arguments in six registers; per page,
  CONTIGUOUS for a contiguous VMO, COMPRESS = pages for the stub; Zircon's
  rights and option checks), pmt_unpin (consumes the handle),
  bti_release_quarantine, vmo_create_contiguous; ZX_INFO_BTI (20).
  Objects: IOMMU 23, BTI 24, PMT 26 (INSPECT only, so its one handle is
  its only one). Device addresses are physical (no translation).
- Pinning (`Vmo.pin`/`unpin`, `VmoRecord.pins`): commits the range and
  records it; decommit refuses pinned pages (VmError.pinned ->
  BAD_STATE), ZERO zeroes them in place, the cache policy can't change.
- Quarantine: closing a PMT's handle while pinned (process death too)
  moves it to its BTI's list (the BTI holds it; it drops its own
  reference to the BTI); bti_release_quarantine unpins them. A BTI that
  dies with quarantined PMTs leaves them pinned for good and says so in
  the debuglog (Zircon's orphan). PMT state changes under the BTI lock.
- croi's BTI properties (`bti_set_properties`, 156; CROI_INFO_BTI_
  PROPERTIES 0x10000): address width, window and memory type. Narrowing
  only (ACCESS_DENIED on a widening), the memory type only while nothing
  is pinned or quarantined. Pins outside are OUT_OF_RANGE;
  vmo_create_contiguous allocates inside (`floor`/`limit` through
  ContiguousPool and the PMM) with the memory type as cache policy
  (non-coherent: uncached). devmgr narrows before granting the BTI.
- Creating a no-IOMMU BTI writes a WARNING debuglog record naming the
  BTI id and the creating process's koid (a recorded trust decision).
- Boot test mode 12 (`ProcessSelfTest.runDma`): all of the above,
  including the debuglog record, with windows chosen so the checks don't
  depend on where pages land. Not covered: quarantine through process
  death, and a BTI dying with PMTs quarantined.

IOMMUs, K12 (Kernel/Iommu/, include/dma.h; every arch). `IoDomain.swift`
is shared: a claimed device's `IoDomain` (unit, kind, domain id, device id,
root, levels, `extra`), its IOVA allocator and page-table walks (VT-d,
AMD-Vi and SMMUv3 stage-1 entries differ only in bits; table writes and
IOTLB invalidation dispatch on `IommuKind`), and `Iommus` (attach/detach/
unbind for Dma.swift, `firstUnit` for the boot test). `Mcfg`
(Acpi/Mcfg.swift, every arch) has the ECAM windows. Kernel-owned
interrupts: `DeviceIrqs.setKernelMsiHandler` (amd64 MSIs) and
`setKernelHandler` (wired numbers, which drivers then can't bind), both
dispatched without `tableLock`. Boot test mode 18's startup block carries
the first unit's registers and type and segment 0's ECAM (words 5-7).

Intel VT-d, K12a (Kernel/Iommu/IntelIommu.swift):
- `Dmar` reads ACPI's DMAR at boot (its DRHDs); iommu_create(INTEL,
  zx_iommu_desc_intel_t) needs a register base it lists (NOT_FOUND) and
  binds one object per unit (ALREADY_BOUND; a unit whose object went can
  be bound again). `VtdUnit` (heap, never freed): a root table whose
  buses all point at one shared context table of pass-through entries
  (ECAP.PT required), translation enabled at creation, register-based
  invalidation (global context cache, domain-selective IOTLB), a fault
  event MSI to the boot CPU (`DeviceIrqs.setKernelMsiHandler`: kernel
  MSIs dispatched without `tableLock`) that logs and counts faults.
- bti_create(iommu, 0, bdf): `Vtd.attach` claims an endpoint in the
  unit's scope (whole segment less the listed ones, or the listed ones;
  one hop only) with a `VtdDomain` (ids from a bitmap; the bus gets a
  private copy of the context table); RMRRs naming it are identity
  mapped. Pins reserve IOVAs (first fit from 1 MiB, inside the BTI's
  window and address bits, which start at the domain's input width),
  map page by page with the pin's write permission, and the PMT keeps
  the base; `Dma.release` unmaps (IOTLB invalidated) before unpinning.
  A dying BTI detaches (not-present context entry: the device is
  blocked) and then releases its quarantine. Behind an IOMMU,
  vmo_create_contiguous(bti) doesn't constrain physical placement.
- Lock order: unitsLock (a Mutex) -> unit -> table, domain -> unit.
- QEMU amd64 runs `-device intel-iommu` (before edu; intremap=on,eim=on
  under TCG, off under KVM: see interrupt remapping below). Boot
  test mode 18 (`ProcessSelfTest.runIommu`; startup word 5 is the first
  DRHD, a driver reads the DMAR itself): edu's DMA engine copies through
  pinned IOVAs, a write to a read-only and to an unpinned IOVA fault
  (QEMU prints its own lines for those), re-claim and re-bind.

RISC-V AIA: the APLIC and IMSICs, K12i (Kernel/Irq/Aia.swift; cpu.S
`arch_rv_imsic_*` through siselect/sireg/stopei by CSR number):
- Used where the MADT has an IMSIC, RINTCs with IMSIC files and an
  S-level APLIC, and every hart has Ssaia; else the PLIC, as before.
  `Aia.initialize` (instead of `Plic.initialize`): hart index = a file's
  place among the files; every source inactive and disabled; domaincfg
  IE + DM (MSI delivery; the root domain's MSI addresses are firmware's).
  Each hart: eidelivery 1, eithreshold 0, every eie bit, SEIE.
- Identities are global: a wired source s is identity s (APLIC target:
  hart index, EIID s; sourcecfg level-high or rising-edge); MSIs take
  consecutive, aligned identities from the first multiple of 64 above
  the sources. scause 9 claims through stopei (`claimAll`): wired to
  `DeviceIrqs.dispatch`, MSIs to `dispatchMsi`. Masking: the APLIC's
  clrienum/setienum (a level source also gets setipnum on unmask: in MSI
  mode it pends again only on a new edge, and the write counts only
  while the line is asserted), MSIs at the device. The MSI message is
  the hart's file and the identity; set_affinity rewrites the address.
- The RISC-V IOMMU now comes up at boot (`RiscvIommus.boot`, devices
  passed through): QEMU resets it Off, which blocked edu's MSIs.
- QEMU: `qemu.sh --aia` (`aia=aplic-imsic`); test `boot-aia` runs the
  whole boot test there.

A claimed device's MSIs, K12j (RiscvIommus.mapInterruptFiles; mode 18's
checks 409-410 on every arch: edu's MSI through its BTI's domain):
- VT-d and AMD-Vi don't translate interrupt requests; SMMUv3 domains map
  the ITS doorbell (K12h, first exercised here).
- RISC-V: MSI page tables apply to a context's guest-physical addresses,
  the first stage's output, so every hart's supervisor file is identity
  mapped in the domain; with MSI_FLAT (extended contexts) the context's
  msiptp is Flat over one per-unit table (one write-through entry per
  hart index, built at the first claim; mask = the hart-index bits above
  the files' stride, pattern = the lowest file), confining MSIs to those
  files. Verified in QEMU (invalid entries stop delivery). The identity
  written isn't restricted (that needs MRIF mode or a device's own guest
  files), so rv64 still has no identity-level remapping and check 297
  skips it. `boot-riscv-iommu-base` (no MSI_FLAT, with AIA) covers the
  identity-mapped files alone.

The GICv3 ITS: MSIs on arm64, K12h (Kernel/Irq/Its.swift, DeviceIrqs'
arm64 MSI part, MsiObject):
- `Its.initialize` (from `GicV3.initializeBootCpu`; bounded spins, the
  clock isn't up): device and collection tables (64 KiB pages, a flat
  device table of up to 2^16 DeviceIDs), a 4 KiB command queue, one
  LPI configuration table (14 INTID bits: LPIs 8192-16383). Each CPU
  (`enableThisCpu`, from `GicV3.initializeThisCpu`): PROPBASER, its own
  pending table (64 KiB aligned, PTZ), EnableLPIs, MAPC (ICID = CPU,
  RDbase per GITS_TYPER.PTA) + SYNC.
- EventIDs are global (msi_allocate precedes knowing the device): 2048,
  allocations consecutive and aligned, LPI = 8192 + EventID, each
  device's ITT covering all 2048. The message is GITS_TRANSLATER and the
  EventID. msi_create finds the device (plain MSI: `Mcfg.requesterId` of
  the capability; MSI-X: `Pci.msixOwner`, the function whose MSI-X
  capability names that table address, walking buses from the MCFG
  window through bridges, a bus mapped when first read), its DeviceID
  (`Iort.itsDeviceId`: a root complex's mapping to an ITS group, or via
  an SMMUv3's stream id and that SMMU's mappings), then MAPD (once per
  device), the LPI enabled, MAPTI, INV, SYNC; set_affinity is MOVI (the
  message stays); destroy DISCARDs. LPIs dispatch through `DeviceIrqs`'
  table lock (`dispatchMsi`).
- SMMUv3 domains identity-map the doorbell page, so a claimed device's
  MSIs still reach the ITS (Linux's MSI window).
- Mode 11's msi_test runs on arm64 (edu's MSI, an event not mapped for
  edu refused, virtio MSI-X entries, MOVI to CPU 1).

VT-d interrupt remapping and queued invalidation, K12f (Kernel/Iommu/
InterruptRemapping.swift, IntelIommu.swift):
- `Vtd.boot` (right after `Dmar.initialize`) brings up every DMAR unit:
  registers, firmware's enables turned off, the invalidation queue where
  ECAP.QI (256 128-bit descriptors; batches end with a wait descriptor
  writing a sequence number to a polled page; FSTS.IQE logged; the
  register interface only on units without one), the fault event (the
  unit's own MSI isn't remapped: compatibility format, FEUADDR for x2APIC
  ids). Translation starts at the first iommu_create bind
  (`enableTranslation`); `Vtd.create` only binds boot's units.
- Remapping on when the DMAR's INTR_REMAP flag, every unit's IR and QI,
  EIM if the CPUs use x2APIC, and no `croi.intremap=off`: one 8192-entry
  table shared by every unit (IRTA, EIME, SIRTP, global IEC, IRE; CFI
  clear, so compatibility-format interrupts are blocked). Fixed entries:
  GSI g -> g (IOAPIC pins get remappable RTEs, `IoApic.programRemapped`,
  verified against the IOAPIC's source id from the DMAR's IOAPIC scopes
  and the MADT ids `IoApic` now keeps), MSI (cpu, vector) -> 128 + cpu x
  64 + vector - 0xB0 (linear, so multi-message subhandles land right;
  a plain MSI verifies the requester id `Mcfg.requesterId` gives its
  capability's address; MSI-X entries are unverified). A change is
  invalidated (IEC by index) on every unit. With EIME, 32-bit APIC ids
  are destinations: the 255 limits fall away.
- QEMU: TCG boots run `intel-iommu,intremap=on,eim=on` (eim=auto leaves
  EIM off under TCG); KVM boots (the bench) keep intremap=off, since KVM
  needs a split irqchip for it, which would move the IOAPIC into QEMU and
  change every interrupt timing on record. QEMU's VT-d passes
  compatibility-format MSIs through whatever CFI says (and never sets
  GSTS.CFIS), so croi's blocking of them (CFIS clear) is per the
  specification, unverified under QEMU. Mode 11's checks read either
  format; check 297 (an old-style or unmapped MSI from edu is not
  delivered) runs for AMD-Vi and the ITS only, after acknowledging the
  interrupt (an MSI stays masked after interrupt_wait until then: the
  first version of 297 passed whatever happened). Test
  `boot-intremap-off` keeps the compatibility path covered.

AMD-Vi, K12b (Kernel/Iommu/AmdIommu.swift; croi's type CROI_IOMMU_TYPE_AMD
= 0x10000 with croi_iommu_desc_amd_t, Zircon has none):
- `Ivrs` (IVHDs: registers, segment, the IOMMU's own device id and
  capability offset) and `Mcfg` (ECAM windows) are read at boot. A unit
  must be an IVHD's (NOT_FOUND), covers its segment except itself; unity
  ranges in the descriptor (IVMD) are identity mapped for the devices
  they name.
- `AmdviUnit`: a 2 MiB device table for every device id (entries invalid:
  untranslated), a one-page command buffer (each batch ends with a
  COMPLETION_WAIT storing a sequence number to a semaphore page the CPU
  polls) and event log, whose interrupt is an MSI the kernel writes into
  the IOMMU function's MSI capability (`mapPhysical(shared:)` of its
  config page, bus mastering on). Claimed: V, TV, mode 4, IR, IW, domain
  id; released: V and TV with mode 0 and no permissions (blocked). Event
  batches log the first four and count the rest.
- K12g: `Amdvi.boot` (after `Ivrs.initialize`) brings up every IVRS unit
  at boot (as VT-d's; `create` binds). Interrupt remapping when every
  unit has IASup, the IVRS's special device entries (type 0x48, variety
  1) describe every MADT IOAPIC (Linux's rule), and XT + GA or no APIC id
  above 255 (the MADT's): one 2048-entry table that every device table
  entry names (word 2: IV, IntTabLen 11, IntCtl remapped; 128-bit
  entries with GAEn + XTEn, else 32-bit), no source verification (an
  MSI-X table doesn't name its device). Indices: IOAPIC pin = its vector
  0x30 + GSI (the redirection entry is unchanged, so EOI broadcasts
  match); MSIs from 0x100, allocated with their vectors in
  `DeviceIrqs.allocateMsi` (`InterruptRemapping.allocateMsiIndices`,
  consecutive and aligned), message 0xFEE00000 with the index as data.
  Every change: INVALIDATE_IOMMU_ALL. The IOMMU's own event MSI is
  compatibility format (not remapped).
- QEMU: `qemu.sh --iommu amd` (`amd-iommu,intremap=on` under TCG, off
  under KVM, `dma-remap=on`; `--iommu amd-xt` adds xtsup=on: test
  `boot-amd-iommu-xt`;
  without dma-remap QEMU 10.2 doesn't translate emulated devices, and
  edu's test DMA wrote physical memory); test `boot-amd-iommu`. QEMU's
  events carry address 0, and a refused 64-byte DMA logs one fault per
  4-byte access.

Arm SMMUv3, K12c (Kernel/Iommu/SmmuV3.swift; Zircon's ARM_SMMU type and
descriptor, but Zircon's driver is SMMUv2 from a device tree):
- `Iort` reads SMMUv3 nodes (registers, COHACC, event GSIV), SMMUv1/v2
  bases (NOT_SUPPORTED) and root-complex id mappings into SMMUv3s:
  bti_create's id is a requester id, `Iort.streamId` maps it.
- `SmmuUnit`: a linear stream table sized to the highest stream id the
  IORT routes there (entries bypass, SHCFG incoming), a 256-entry command
  queue (batches end with CMD_SYNC; consumption = done; CMDQ_ERR logged),
  a 128-entry event queue on the wired event interrupt (edge, boot CPU),
  CR1 cacheable walks only when coherent (else tables, CDs and commands
  are cleaned to memory). Claimed: break-before-make to stage-1 (config
  101) through a context descriptor page per domain (ASID = domain id,
  T0SZ 16, 4 KiB, AA64, R and A, AFFD, MAIR 0x44FF); leaves are AF, inner
  shareable, AP[1] set, AP[2] for read only. Released: abort (config 000).
- QEMU arm64 now has `-device edu,addr=0x10` behind its `iommu=smmuv3`;
  mode 18 runs there (F_PERMISSION and F_TRANSLATION events).
- A unit firmware left enabled (CR0.SMMUEN) is refused, BAD_STATE: the
  Q8B's PCIe SMMUv3 is firmware-reserved and policed by its hypervisor.

Arm SMMUv1/v2, K12d (Kernel/Iommu/SmmuV2.swift; AbyssBSD's qcom_smmu and
qcom_apps_smmu on the Q8B are the reference, freebsd-src branch
radxa-dragon-q8b, `5cf2c7fd99`; its docs/boards/radxa-dragon-q8b/lessons.md
lists what resets that SoC):
- `Iort.v2Nodes`: base, span, coherent walks, per-bank context
  interrupts (GSIV | edge, heap). iommu_create picks v2 or v3 by node.
- Firmware owns the unit: never a global register, never a reset. Free:
  an entry invalid and faulting; a bank no valid translating entry uses
  whose CBAR is 0 or that this driver set up (`ours`). Claim: bank (CBAR
  only ever 0x1f300, TCR T0SZ from IDR2.UBS, ASID = bank, MAIR 0x44FF,
  SCTLR M|TRE|AFE|CFRE|ASIDPNE and CFIE once its interrupt is the
  kernel's), then each S2CR, then each SMR, with `arch_device_write_
  barrier` (cache.h: dsb st) between. Release: SMR 0, S2CR fault, SCTLR 0,
  TLBIASID + sync. The pairs come from bti_create (dma.h).
- `IoDomain.inputBits` is stored (36 on the Q8B: walks start at level 1,
  3 levels); `IoDomains.map(cached:)` picks MAIR index 1 for a
  non-coherent BTI (SMMUv2 and v3).
- No QEMU model: `SmmuV2SelfTest` (arm64 boot self-test) runs the driver
  on a RAM stand-in set up as the Q8B's apps SMMU (register writes logged
  through `SmmuV2Unit.log`): nothing but the claimed entries and bank
  written, CBAR 0x1f300 only, bank then S2CR then SMR (verified to fail
  with the order swapped), overlaps refused, leaf bits, release, reuse,
  firmware's banks never taken. Unverified on hardware.

The RISC-V IOMMU, K12e (Kernel/Iommu/RiscvIommu.swift; croi's type
CROI_IOMMU_TYPE_RISCV = 0x10001, descriptor { register_base }):
- `Rimt` reads ACPI's RIMT (IOMMU nodes: base, or PCIe-based with segment
  and B/D/F, whose BAR 0 is the base; root-complex id mappings, "number of
  IDs" a count). A PCIe-based IOMMU gets memory space and bus mastering
  before its registers are read (all-ones otherwise).
- `RiscvIommuUnit`: refused if firmware left it translating (ddtp mode >
  Bare: BAD_STATE). A device directory with a pass-through context (V,
  both stages Bare) for every device id the RIMT routes there: 2 levels of
  32-byte contexts, or 3 of 64-byte ones when capabilities.MSI_FLAT makes
  contexts extended; command queue ending batches with IOFENCE.C (AV) to
  a semaphore word; fault queue, drained when faults are counted and
  after each unmap's invalidation (no interrupts: they are IMSIC MSIs or
  wired lines). Claimed: context invalid, IODIR.INVAL_DDT, then iohgatp
  Bare, ta PSCID (= domain id), fsc Sv48/Sv39 + root, valid; released:
  invalid. Leaves V|R|U|A (+W|D), Svpbmt NC for uncached BTIs where every
  unit has Svpbmt (`IoDomains.riscvPageBasedMemoryTypes`).
- QEMU rv64: `-device riscv-iommu-pci,addr=0x8` (QEMU 10.2 puts only the
  PCI IOMMU in the RIMT; `iommu-sys=on` makes the device but no RIMT), at
  slot 8 so the other devices keep their slots (moved, edk2's saved boot
  entries go stale and it drops to its shell) and below edu (the RIMT
  routes the ids above the IOMMU's own). `qemu.sh --iommu base`
  (intremap=off: no MSI_FLAT) covers base contexts; test
  `boot-riscv-iommu-base`.

Reservations, atomic views and the JIT, K15b (ext 7, F-218; task.h
CROI_VM_RESERVATION/JIT, vmar_map_view 244, CROI_INFO_VMAR_JIT 0x10004;
agreed with Todhchai 2026-10-12):
- vmar_allocate's RESERVATION makes a child VMAR that holds its range for
  views: vmar_map and sub-VMARs refused there; vmar_map_view installs a
  view, atomically replacing what was there (K4b's `mapView`, with the VMO
  handle's rights as the protect ceiling); vmar_unmap, vmar_protect and
  vmar_op_range work on views; an unviewed page faults (guards by
  omission). JIT implies RESERVATION and takes a protection key on amd64
  with PKU: keys are per address space (`UserAspaceRecord.jitKeys`, 1-15;
  K4c had 15 system-wide), and with none left the reservation is quietly
  views-only (Todhchai's choice; the info says which). Executable views
  need a VMO handle with EXECUTE (VMEX).
- Only RWX views carry the key: RW and RX views are key 0, so dual views
  work in a keyed reservation too (they faulted: threads start with
  keyed writes disabled).
- Threads open a key's writes themselves (WRPKRU; they start with keys
  1-15 write-disabled); the scheduler reads the outgoing user thread's
  PKRU back at every switch (it only loaded the stored one, so a user
  WRPKRU was lost and the per-CPU cache could skip the next load).
- Mode 17's `jit_views` (checks 722-728; 726 needs PKU, which TCG -cpu
  max has, and fails without the switch-out PKRU save).

Memory accounts, K15a (Kernel/Object/AccountObject.swift,
Vm/MemoryAccount.swift, include/account.h, syscalls 240-243; Todhchai ext 6,
its F-109; agreed with Todhchai 2026-10-12; croi's, Zircon has none):
- An account object (type 49; BASIC, WRITE and croi's CHARGE right, 1 <<
  25) over a `MemoryAccountRecord`: a limit, warning and critical levels
  (percent of it; entered at the threshold, left below 80% of it), one
  coalescing pressure packet (type 0x81: payload[0] limit, [1] charged,
  [2] changes, [3] level) on every level change. account_create needs the
  MEMORY system resource (base 17) or root; account_set_limit never goes
  below what is charged (BAD_STATE); CROI_INFO_MEMORY_ACCOUNT (0x10003).
- A process charges its `ProcessObject.account`: its creator's at
  process_create (`Accounts.current()`), replaced by process_set_account
  (process WRITE, account CHARGE) only before it starts. Charged: the
  VMOs it creates (vmo_create, snapshot children, vmo_create_contiguous);
  CROI_VMO_CHARGE_TO (1 << 30) names another account (CHARGE): vmo_create's
  fourth argument, vmo_create_child's sixth (a physical SLICE then charges
  its whole size, never evicted: device-local), vmo_create_contiguous's
  alignment argument bits 63:32. A VMO keeps its account wherever its
  handles go. Not charged: physical VMOs, aliases, pager VMOs (v1),
  kernel memory and page tables. Launchers pass a process its own account
  as CROI_PA_MEMORY_ACCOUNT (0x41).
- Charge follows `committedPages` everywhere pages enter or leave an
  anonymous VMO: commit, decommit, `take`, resize, snapshot copies (charged
  per page as they copy in), discard and eviction, release. Over the
  limit a commit fails: NO_MEMORY from syscalls, a fatal page fault from a
  fault.
- Mode 17's `memory_accounts` (checks 713-721; child submode 12; 717
  and 721 fail without the before-start rule and snapshot charging).

Counters, K10a (Kernel/Object/Counter.swift, User/CounterSyscalls.swift,
include/counter.h, syscalls 160-165):
- Zircon's counter (type 34; create, add, read, write; POSITIVE /
  NON_POSITIVE; add needs READ and WRITE, OUT_OF_RANGE on overflow) plus
  croi's waits at a value: `counter_wait(counter, value, deadline)` and
  `counter_wait_async(counter, port, key, value)` (one packet of type
  0x82: target, value reached, time), needing WAIT and READ.
- A value wait is an observer with a threshold (`Observer.byValue`,
  `atValue`): `Observers.notify` fires it when the counter's value
  reaches it, so registration, cancellation on handle close, port_cancel
  and port delivery are the signal waits'.
- Each thread keeps its WaitState (`Thread.waitState`, freed with the
  thread; `WaitStatePointer.forCurrentThread`), so a counter wait
  allocates only its observer; the wait reads how it ended in the same
  scheduler-lock pass that blocks. That took counter wake from ~2.5 to
  ~1.6 µs. ObjectWait still allocates a WaitState per wait.
- Budget `counter.wake_median` (m2, as port wake: counter_add's entry on
  CPU 1 to counter_wait's exit on CPU 2; limit 2 µs): KVM ~1.6 µs.
- Boot test mode 14 (`ProcessSelfTest.runCounters`).

Display timelines, K10b (Kernel/Object/Timeline.swift, include/timeline.h,
syscalls 170-173 in User/CounterSyscalls.swift; Todhchai ext 1):
- croi's object (type 48), created under the display system resource
  (base 16, croi's): a vblank count, waited on with the counter calls
  (`Counters.waitable` takes a counter or a timeline; value observers;
  `Observers.notify` asks `Counters.valueLocked` for both types).
- Driven: `timeline_advance(timeline, timestamp)` counts a vblank at the
  hardware's time. Synthetic (`CROI_TIMELINE_SYNTHETIC`, the GOP
  framebuffer): the value is base_count + (now - base_time) / period, and
  `Timelines.watchLocked` (after a value observer is added) arms one
  kernel timer, zero slack, for the earliest vblank any waiter needs; the
  firing notifies and re-arms for the next. Nothing waiting, nothing
  armed: a static screen makes no wakeups. The armed timer holds a
  reference; a generation makes a superseded one a no-op.
- `timeline_set_period` re-bases at the current vblank (the count carries
  on). `timeline_get_page`: a read-only handle to a one-page contiguous
  VMO (`sharedReadOnly`: mappings read only, cache policy fixed) holding
  croi_timeline_page_t under a seqlock (period, base count and time,
  synthesized flag), written only at creation, period changes and
  advances.
- Budget `timeline.wake_p99` (m2: the deadline thread on its own CPU
  waiting for each next vblank of a 1 ms synthetic timeline, from the
  page's vblank time; limit 100 µs): KVM median ~10 µs, p99 17-35 µs.
- Boot test mode 15 (`ProcessSelfTest.runTimelines`).

Deadline-carrying wakeups, K10c (Todhchai ext 5 and 10; profile.h):
- `object_set_profile(target, profile, options, refusal, timeline)`: on an
  interrupt, counter or timeline (WRITE; deadline profiles only, no
  options) the object stores the profile (`lend`), and `Observers.notify`
  / `InterruptObjects` wake through `Scheduler.wakeAll(queue, lending:)`:
  the woken thread's `Thread.lent` joins its effective profile as an
  inherited one (computeEffective), with a period starting at the
  wakeup, and `block` drops it. Not admitted, as channel_call donation
  isn't. A thread that sees the event before it blocks borrows nothing.
- `CROI_PROFILE_ALIGN_TIMELINE` on a thread with a deadline profile
  (BAD_STATE without one): its context keeps the timeline (a reference)
  and its page address; `startPeriod`/`nextPeriod` read the page under
  its seqlock (`vblankGrid`) and start periods on vblanks, only while
  the thread runs on its own context's parameters. The current period is
  re-aligned at once. `SchedContextRecord.intent` is still stored only.
- Test hooks 3/4 (syscall 6) return the running thread's period start
  and deadline. Boot test mode 16 (`ProcessSelfTest.runDeadlineWakeups`).
- Ext 5 proper, K14e (profile.h `CROI_PROFILE_HANDOFF`): object_set_profile
  on an interrupt with that option admits the deadline profile as a
  context the object owns (`InterruptObject.context`; refusals as for
  threads, `Profiles.admit`). `signal` wakes through
  `Scheduler.wakeAll(queue, handingOff:)`: `borrow` makes it the woken
  thread's `context` (its own kept in `homeContext`, its own period and
  budget in `home*`), so placement (the context's CPU), stealing (admitted
  threads stay) and overrun counting follow it. The context keeps the
  period and budget across wakeups (`handoff*`, written back by
  `giveBack`; `makeReady` applies the CBS rule), so wakeups share one
  budget; a wakeup while it is spent wakes the thread on its own. The
  borrow ends when the thread blocks, when the budget runs out (`requeue`:
  an overrun on the context, then its own profile, not throttling), at
  exit, when its own profile changes, or when the context is replaced or
  the object destroyed (`Scheduler.withdraw`, then destroyed). One
  borrower at a time (`borrower`). thread_bind_overrun_port takes the
  interrupt (WRITE) for its context's overruns. A lend replaces a handoff
  and vice versa. Test hook 10 is the borrowed context's CPU or -1
  (syscall 6 sends only ops 6-9 to the reclaim hooks now).

Kernel-only extensions reaching user space, K10d (task.h, profile.h,
log.h; Todhchai ext 3 and 8, its trace export):
- `thread_bind_overrun_port` (122; MANAGE_THREAD, port WRITE): the
  thread's own deadline context (`profileContext`, from
  object_set_profile; else BAD_STATE) gets a PacketSource of type 0x80
  (payload[1] total overruns, [2] since last read), swapped under the
  scheduler lock so the context's deinit retires whichever is bound.
  Overruns count only while the thread runs on its context's own profile
  (not a lent or inherited one).
- `job_set_cpu_reservation` (108; SET_POLICY on the job, CPU system
  resource base 4 or root): `Scheduler.setReservation` reserves the
  mask's CPUs for tag = the job's koid, all or nothing (boot CPU
  INVALID_ARGS, another tag's CPU ALREADY_BOUND, other tags' deadline
  contexts admitted there NO_RESOURCES), only while the job has no
  children and no inherited tag (BAD_STATE). Child jobs and processes
  copy the tag at creation, threads get it at spawn (`Thread.reservation`;
  a context's own tag wins in `tag`), deadline contexts are admitted with
  it. Mask 0 or the job's destruction releases. `interrupt_set_affinity`
  skips CPUs reserved for another tag (`mayRoute`); interrupts routed
  before a reservation stay where they are.
- object_get_info CROI_INFO_THREAD_TRACE (0x10001, INSPECT): task << 12
  | index, as trace records name the thread. CROI_INFO_DEBUGLOG (0x10002,
  any log handle): records written and records the dumper has finished
  (`DebugLog.printed`, stored after the console write).
- Test hook 5 (syscall 6) returns the current CPU. Boot test mode 17
  (`ProcessSelfTest.runExtensions`; child submode 9 reports its CPUs).
- Fixed on the way (since K8c): `Syscalls.dispatch` called
  `preemptIfRequested` with interrupts on, so a thread could read its CPU,
  be preempted and moved, and take the scheduler lock in the old CPU's
  name (rv64: "released by a CPU that doesn't hold it", ~2 boots in 3
  with mode 17). It masks interrupts itself now, and `lockMasked` panics
  if called with them on. A retiring PacketSource takes its queued packet
  back out of the port (`Ports.unqueue`); it used to wait for a reader
  that might never come, keeping the port alive.

Power control, K10e (Kernel/Power.swift, include/power.h, syscall 180;
Todhchai M4's shutdown):
- `system_powerctl(resource, cmd, arg)`: Zircon's commands and
  zx_system_powerctl_arg_t, under the power system resource (base 5) or
  root. SHUTDOWN / REBOOT / ACPI_TRANSITION_S_STATE(S5) check that the
  machine can, then give the debuglog up to 100 ms to reach the console,
  halt the other CPUs (`Ipi.stopOthers`, a mailbox kind that halts
  masked), print `croi kernel: powering off` / `rebooting` and budget
  `power.shutdown_kernel` / `power.reboot_kernel` (syscall entry to the
  hardware write, less the console wait: KVM ~20-180 µs, limit 10 ms)
  and `power.log_drain` (the wait itself: KVM ~25 ms of m2's last lines,
  a serial byte per VM exit), and act; failure after that halts.
  At the drain's end the dumper is made quiet (it stops at a line's end,
  so no CPU is halted holding the console), the UART is drained
  (`Uart.drain`: an emulator drops what it still holds at power off), and
  the hardware is asked twice, a second apart, before "didn't act".
- `croi.kill_watch=1` (lockup reports): 1 s after a task_kill of a
  process, a kernel thread holding it prints its threads,
  `Scheduler.dump` (with eligibility timers, period starts, kill marks)
  and, from each CPU running one of its threads, where it was
  interrupted plus a frame-pointer backtrace, and for each live thread
  the syscall it entered by and (amd64) its switched-out kernel frames
  (`Ipi.requestReport`, a
  mailbox kind that doesn't wait; addresses as they are, for
  llvm-symbolizer) if it isn't dead. It holds the process that second,
  so self-tests' leak checks see it later.
- Deadlines at or past INT64_MAX (Zircon's ZX_TIME_INFINITE) arm no
  timer in `Scheduler.block`; each used to hold a timer-queue slot. Everything else
  (suspend, hotplug, PL1, bootloader/recovery) is NOT_SUPPORTED.
- amd64: no SHUTDOWN (NOT_SUPPORTED): user space passes \_S5's sleep
  types (ACPI_TRANSITION_S_STATE, target 5), written to PM1a/b control
  (SLP_TYP, then SLP_EN) or the hardware-reduced sleep control register;
  system I/O registers only. Reboot: FADT reset register, then 0xCF9,
  then the 8042. arm64: PSCI SYSTEM_OFF / SYSTEM_RESET (FADT conduit).
  rv64: SBI SRST, legacy shutdown as fallback.
- `userboot.shutdown=poweroff|reboot` (user/userboot/Power.swift): after
  its program exits, userboot powers off or resets (it keeps duplicates
  of the root resource and boot data for it; on amd64 it finds `\_S5`
  by scanning the DSDT bytes, no AML). The build's cmdline has
  `CROI_USERBOOT_SHUTDOWN` (default poweroff), so boot tests pass
  `qemu.sh --exits`: after the expected line QEMU must exit by itself
  (boot-smoke doesn't: its screendump is taken at that line).
  `boot-reboot` (lean) expects the reset; test runs use -no-reboot.
  With --screendump, qemu.sh adds `-action shutdown=pause` so the screen
  can still be read after the guest powers off.
  bench.py passes --exits to trees that support it and records the budget.
- Boot test mode 17 checks the refusals (and, since K10f, kills a
  process with threads in port, counter and event waits plus a spinner
  30 times, each TERMINATED within 500 ms).

Deadline-aware idle, K15c (Kernel/Sched/Idle.swift, include/power.h,
syscall 245; Todhchai ext 11):
- `cpu_set_idle_states(resource, cpu, croi_idle_state_t *, count)`: the
  POWER system resource (base 5) or root; up to 8 states, exit latencies
  non-decreasing, known flags only, a method this CPU has (HALT; MWAIT
  with a hint, amd64 with CPUID MONITOR; PSCI CPU_SUSPEND with a power
  state, arm64 with PSCI), else INVALID_ARGS / NOT_SUPPORTED; count 0
  removes the table. The table (heap, `PerCpu.idleTable`) is swapped under
  `Idle.lock` and the CPU, if idle, kicked to choose again.
- `Idle.enter` (the idle loop's halt, after `Timers.settle`): the deepest
  state whose target residency is at most the time to the CPU's next
  timer (`Timers.nextLatest`) and whose exit latency is at most its
  wake-latency bound (`Scheduler.wakeLatencyBound`); states with
  TIMER_STOPS or CONTEXT_LOST are skipped (no always-on wake timer or
  context save yet), too-slow ones demoted, each counted; none fits: a
  plain halt. Entries are counted at entry, residency at exit. amd64
  MWAIT is `sti; mwait; cli` (as the halt; QEMU TCG raises #GP for ECX
  bit 0, the masked break event).
- The bound: admitted deadline contexts on the CPU, and (K15c) interrupt
  objects with a deadline profile lent or handed off, at the CPU they are
  routed to (`Scheduler.setInterruptLatency`, from
  `InterruptObjects.latencyChanged`: set_profile, set_affinity, destroy).
  A changed bound kicks an idle CPU.
- object_get_info(INFO resource or root, CROI_INFO_CPU_IDLE_STATES =
  0x10005): croi_idle_state_stats_t per CPU and state (entries,
  residency, demoted, skipped), then one with state DEFAULT for plain
  halts; actual/avail as list topics.
- Mode 17's checks 729-736 (refusals; a deep state entered, a
  TIMER_STOPS one skipped; an interrupt's deadline profile demoting CPU 0
  until it closes; MWAIT where the CPU has it, PSCI standby on arm64).

An idle machine makes no wakeups, K10f (M4: 0 per second;
resource.h CROI_INFO_CPU_STATS, Smp.swift `CpuStats`):
- object_get_info(INFO resource or root, CROI_INFO_CPU_STATS = 16):
  Zircon's zx_info_cpu_stats_t per CPU, as many as fit, returning the
  count (no actual/avail pointers). Filled: idle_time, context_switches,
  yields, ints (other interrupts), timer_ints, timers (callbacks),
  syscalls, reschedule_ipis, generic_ipis (counted per IPI interrupt).
- m2's last measurement: wait until the dumper has printed everything
  (CROI_INFO_DEBUGLOG), fault in both stats buffers, sleep 500 ms (up
  to three windows, the quietest kept: a periodic wakeup shows in each,
  a straggler a loaded TCG host ran late in one), and
  report every interrupt any CPU took less its own wake as budget
  `idle.wakeups` (unit count, limit 1, always enforced: not a timing).
  Its line shows per-CPU counts by kind for diagnosis.
- What used to wake an idle CPU: `Timers.cancel` leaves the hardware
  armed (hot path), so `Timers.settle()` re-arms for the earliest timer
  still pending (or disarms) on idle entry, before the idle poll, which
  takes interrupts; the sampler's tick lapsed once per idle stretch (and
  after a stop), now cancelled on a switch to idle; deadline-to-counter
  conversion rounded down (rv64's 10 MHz timebase fired up to a tick
  early, then re-armed), now up; the self-test deadman stays armed 20 s
  (disarmed when the self-tests end); a page fault in the window
  broadcasts a shootdown on rv64 (m2 faults its buffers in first).
- Found on the way: a synthetic timeline's value is the clock's, so a
  vblank could pass between counter_wait's check and `watchLocked`,
  which then saw the waiter's value reached and armed nothing: the
  waiter slept until its deadline (m2 on rv64 under host load, ~1 boot
  in 5). `watchLocked` now notifies observers already satisfied.
- Early timer interrupts (each re-arm was a second wakeup): under KVM a
  TSC deadline becomes a host timer on the host's NTP-disciplined clock,
  ~28-34 ppm ahead of our TSC time here (a 60 s sleep came ~1.7 ms
  early). On amd64 under a hypervisor the skew is measured against the
  HPET (which runs on the host's clock) when a deadline 1 s or more out
  is armed and the baseline from boot has doubled; `Timers.leadPpm`
  (shared) arms long deadlines that much later, and an interrupt that
  still comes early raises it. One that comes at most 1 ms early
  (`Timers.earlyTolerance`) waits for the deadline. Timers never run
  early; a long one may run a few ppm late. The TSC frequency comes
  from kvmclock's scale when KVM offers it (no 10 ms HPET loop at boot),
  or a hypervisor leaf 0x40000010. Settled again right before the
  halt (an idle thread switched away mid-poll resumes past the first).
- The hardware is never armed further out than `Timers.maxDistance`
  (2^40 ns, ~18 min; one wakeup per cap for a far timer): KVM converts a
  TSC deadline to host ns in 64 bits (delta x 10^6 / tsc_khz), which
  wraps past ~6000 s, and futex waits with a deadline 146 years out ran
  ~2000x slower under KVM (Todhchai's pthread test: 39 s and a hang).
  The time self-test checks the cap; mode 17's check 620 runs a
  contended futex lock with both kinds of deadline.
- Left: the SBSA watchdog's refresh, now every 20-25 s with slack
  (`croi.watchdog=off` removes it; QEMU has none). The debuglog dumper,
  timeline ticks and idle polling were already event-driven.

VMO children, K11a (Vmo.swift `init(childOf:)`, VmoObject
`createChild`, vmo.h CROI_VMO_CHILD_*, syscall 48):
- `vmo_create_child(vmo, options, offset, size, out)`: SNAPSHOT_AT_LEAST_
  ON_WRITE of an anonymous VMO (a child too), optionally NO_WRITE. The
  child is an anonymous VMO with `parent`/`parentOffset` (a reference):
  an uncommitted page reads as the parent's (`content(at:)`, recursive;
  zero past the parent's end), and its first touch, read or write,
  copies it in (`commit`; Zircon's "at least on write" allows it, so no
  hidden nodes). Lock order child -> parent. Decommit on a child is
  NOT_SUPPORTED (its page would read as the parent's again); ZERO
  writes zeros into a copy. Rights as Zircon: the parent handle's (needs
  DUPLICATE and READ) plus GET/SET_PROPERTY; WRITE added and EXECUTE
  removed unless NO_WRITE removes WRITE. (SLICE came in K13a,
  CHILD_RESIZABLE in K13h, the other kinds in K14g.) Mode 17 checks it
  (`vmo_children`).

The other child kinds, K14g (Vmo.swift `Vmo.snapshot`, `init(sliceOf:)`,
`init(referenceOf:)`; VmoObject `createChild` in Zircon's order):
- Snapshots (`Vmo.Snapshot`): SNAPSHOT copies every page its parent shows
  in range at creation (`copyContent`, level by level up the chain, each
  under its lock), so nothing reads through (no hidden nodes; see
  docs/zircon-divergences.md). SNAPSHOT_MODIFIED is that too, except
  under a pager: of the pager VMO it is at least on write; of a child, the
  child's own pages are copied and the rest read through to the child's
  parent up to `parentLimit`. Zircon's refusals: physical NOT_SUPPORTED,
  contiguous INVALID_ARGS, uncached BAD_STATE, SNAPSHOT under a pager
  NOT_SUPPORTED, any clone of an anonymous VMO through a slice
  NOT_SUPPORTED or with pinned pages BAD_STATE (at least on write too:
  Zircon's is bidirectional there). `VmoRecord.clone` marks every
  snapshot child (IS_COW_CLONE; DECOMMIT NOT_SUPPORTED).
- Aliases (`VmoRecord.isAlias`): a SLICE of an anonymous VMO (wholly
  inside; not of a resizable one) or a REFERENCE (offset and size 0; not
  of a slice or contiguous VMO; RESIZABLE only of a resizable VMO and with
  RESIZE on the parent handle). No pages of their own: `parent` is the
  root, `target` gives (root, offset). Syscalls resolve them (vmo_read/
  write, op_range, bti_pin, streams), and `Mapping` keeps the root and
  root offset in `vmo`/`offset` with the mapped VMO in `holder` (the
  mapping's reference; koid and name in the info topics), so faults,
  `unmapEverywhere` and reclaim work on the root unchanged. A reference's
  size and stream size are its root's (`sizeOwner`): vmo_set_size through
  one resizes the root; a slice has its own stream size over the root's
  pages. Aliases have nothing attributed (Zircon's rule). The root's
  `aliases` count freezes its cache policy.
- `VmoRecord.owner`: the VMO a child was created from when that isn't its
  `parent` (an alias of an alias, a full snapshot, a modified snapshot
  reading through to its grandparent); its ZERO_CHILDREN and ZX_INFO_VMO
  parent_koid follow `owner`, else `parent`. A slice of a slice (K13a's
  physical ones too) is now its slice's child.
- `withContent(at:)` copies a parent's page under that parent's lock
  (a child's first touch did it after dropping the lock, so a concurrent
  decommit could hand it a freed, reused page).
- Mode 17's `child_kinds` (checks 650-660).

UNBOUNDED VMOs, K14i (`Vmos.maxSize`, `Vmos.createSize`; Zircon's
parse_create_syscall_flags): vmo_create and pager_create_vmo with
UNBOUNDED make a VMO of 0xFFFF_FFFF_FFFF_0000 bytes (Zircon's MAX_SIZE:
every page round-up below it stays in range) whose content size is the
size given (OUT_OF_RANGE past MAX_SIZE; RESIZABLE with it INVALID_ARGS);
bounded sizes past MAX_SIZE are OUT_OF_RANGE too. Range operations cost
what is present, not the range: `PageList.next(from:before:)` skips empty
subtrees, used by decommit (`takePresent`), `zero` (a plain VMO's middle
decommitted, the ends zeroed in place) and `zeroOwn`, cache ops and
instruction sync (`forEachPage`), resize, pager detach, writeback
(`forEachStateLocked`), dirty ranges, and ALWAYS_NEED's swaps back.
vmo_set_stream_size zeroes up to the new size's page end and, past it,
only what is committed (Zircon's untracked zeroing, without zero
markers; K14k: a pager VMO's become an untracked zero interval). Still
per page: COMMIT, PREFETCH, ALWAYS_NEED's paging in, ZERO under
TRAP_DIRTY. Mode 17's `unbounded` (checks 663-668).

Zero intervals, K14k (Pager.swift `ZeroInterval`, `VmoRecord.zeros`;
Zircon's): a pager VMO keeps sorted, disjoint ranges of absent pages that
read as zeros the pager is never asked for, each dirty, awaiting clean or
untracked (`zeroStateLocked` binary-searches; `carveZerosLocked`,
`addZerosLocked` merging neighbours, `changeZerosLocked`). Made by ZERO
(`Pagers.zeroPages`: whole pages dropped, pinned ones zeroed in place and
dirty instead, waiting readers let go; `ensureWritableForZero` makes only
the partial ends present), a grow (dirty) and a stream size cut past its
page end (untracked). Reads copy zeros and commit nothing
(`readsAsZero`, `VmoUserCopy.zeros`); a write, fault or `prepareWrite`
commits a zeroed, dirty page and splits the interval; supply skips them;
read-ahead requests stop at one. query_dirty_ranges reports dirty and
awaiting ones with IS_ZERO; WRITEBACK_BEGIN makes dirty ones awaiting
clean (with IS_ZERO it leaves pages alone: Zircon's race), END removes
the awaiting ones (the pager supplies the range again). Under TRAP_DIRTY
ZERO still zeroes page by page (the pager would have to approve the
dirtying first). Mode 17's `zero_intervals` (checks 669-675).

Copies between user memory and VMO pages, K14h (Vm/Vmo.swift
`VmoUserCopy`; vmo_read/write, streams, process_read/write_memory): a
page is read or written only under the lock of the VMO that has it
(`withContent`, `ownLocked`), so a decommit, eviction, swap or shrink
can't free it mid-copy (they used to look it up, drop the lock and copy:
a freed page reused by another VMO leaked its bytes). The copy runs
under that spinlock without paging in (`UserCopy.toNoPageIn` /
`fromNoPageIn`, PerCpu.noPageIn); a chunk that faults is paged in with
no lock held (`pageIn`: `UserAspaces.handleFault` per page) and retried,
up to `attempts` times. `.absent` commits (`VmoUserCopy.commit`) or
waits for the next `Pagers.ensure*`. Mode 17's `copy_race` (661-662:
writer, polluter and reader threads) failed 3 of 3 KVM boots with the
copy outside the lock.

VMO slices, ZERO_CHILDREN and handle counts, K13a (Vmo.swift `init(sliceOf:)`,
`childAdded`/`childGone`; VmoObject; agreed with Todhchai for the GPU
driver host's BAR windows):
- `vmo_create_child` SLICE (alone or with NO_WRITE; anything else with it
  INVALID_ARGS) of a physical or contiguous VMO: a VMO of the same kind
  over [offset, offset+size) of its pages (page aligned, wholly inside,
  else INVALID_ARGS), with its cache policy and memory flags, `slice`
  set (a contiguous slice frees nothing); a slice of a slice is one of
  the root. Rights: the parent handle's plus GET/SET_PROPERTY, less WRITE
  with NO_WRITE. Anonymous parents: K14g's aliases.
- Every VMO record counts its live children (K11a's snapshots too) and
  knows its object (`VmoRecord.object`, cleared by the object's destroy).
  ZERO_CHILDREN (signal bit 3) is set at wrap, cleared by `childAdded`,
  set again by `childGone` (the child record's last reference: its last
  handle and last mapping); both update the signal under the object's
  lock and recheck the count there (Zircon's double check). Lock order
  object -> vmo there.
- A VMO with children, or a slice, can't change its cache policy
  (`VmError.badState`, BAD_STATE).
- `ObjectHeader.handleCount`: +1 in `HandleTable.add` and in
  `MessagePointer.setHandle` (a handle in flight), -1 in close/take, at
  channel_read's install and in a message's `free`. object_get_info
  CROI_INFO_HANDLE_COUNT (19, Zircon's), INSPECT.
- vmo_create_physical's rights are now Zircon's (the default VMO rights:
  WAIT, INSPECT and SIGNAL, no EXECUTE).
- Mode 17's `vmo_slices`: on segment 0's ECAM, refusals, reads through a
  slice and a slice of it, cache policies frozen, rights, the count
  through a channel round trip, ZERO_CHILDREN after the last unmap.

FIFOs and executable VMOs, K13b (Kernel/Object/Fifo.swift; syscalls 87-89
in IpcSyscalls, 49 in Syscalls; Todhchai's block, input and GPU rings):
- Zircon's FIFO (type 19, ZX_DEFAULT_FIFO_RIGHTS): `fifo_create(count,
  size, options, out0, out1)` (count and size non-zero, count x size at
  most 4096, else OUT_OF_RANGE; NEW_FIFO policy, condition 10), each
  endpoint a heap ring of records its holder reads; a write fills the
  peer's ring. `fifo_write/read(fifo, elem_size, data, count, actual)`
  move as many whole records as fit or are there (size mismatch or count
  0 OUT_OF_RANGE; none: SHOULD_WAIT, or PEER_CLOSED with no peer and,
  for reads, nothing left). READABLE / WRITABLE (room in the peer's
  ring) / PEER_CLOSED (the peer's last close, which also clears
  WRITABLE) kept under the pair's `PeerShared` lock. User bytes go
  through a heap bounce buffer outside the lock (reads check the
  destination writable first). signal_peer and related koids cover
  FIFOs.
- `vmo_replace_as_executable(vmo, vmex, out)` (49): the vmex must be the
  VMEX system resource (base 1) or root; the new handle has the old
  rights plus EXECUTE; the old handle is gone either way (Zircon's).
- Mode 17's `fifos_and_exec`.

Sockets, K13c (Kernel/Object/Socket.swift, User/SocketSyscalls.swift,
syscalls 190-193; ipc.h):
- Zircon's socket (type 14, ZX_DEFAULT_SOCKET_RIGHTS incl. MANAGE_SOCKET
  1 << 20), STREAM or DATAGRAM, the pinned tree's error orders and signal
  rules (its spec, quirks included, is in the K13c roadmap notes): writes
  fill the peer's buffer (stream: short writes; datagram: all or nothing,
  OUT_OF_RANGE above capacity); reads (PEEK; a datagram read shorter than
  the message drops the rest; size 0 consumes nothing); empty: SHOULD_WAIT,
  BAD_STATE once the peer disabled writing, PEER_CLOSED with no peer;
  set_disposition (WRITE_DISABLED / WRITE_ENABLED per side, BAD_STATE
  re-enabling before the old data is read, MANAGE_SOCKET); thresholds
  (properties 12/13, READ_THRESHOLD / WRITE_THRESHOLD); ZX_INFO_SOCKET
  (22); user signals to the peer; NEW_SOCKET policy (9).
- Receive buffers are rings of up to 64 PMM pages (256 KiB; Zircon's is
  264160), a page allocated when written and freed when drained; a
  datagram has a 4-byte length in the ring (counted against capacity).
  The pair shares a `SocketShared` with a blocking `Mutex`, so user copies
  go straight into and out of the ring (they may fault and page in);
  lock order mutex -> object.
- Mode 17's `sockets`.

Streams, K13c (Kernel/Object/Stream.swift, User/StreamSyscalls.swift,
syscalls 194-201; vmo.h):
- Zircon's stream (type 31; ZX_DEFAULT_STREAM_RIGHTS, READ / WRITE by
  mode, APPEND adds none; no policy) over an anonymous VMO (else
  WRONG_TYPE): create, writev/readv (at the seek, which moves under the
  stream's Mutex), writev_at/readv_at, seek (START/CURRENT/END, checked
  arithmetic), ZX_INFO_STREAM (26), ZX_PROP_STREAM_MODE_APPEND (19).
  `croi_iovec_t` (capacity uint64_t: the ABI headers have no size_t).
- The stream size (`VmoRecord.streamSize`, nil = the VMO's size):
  vmo_get_stream_size (200, no rights; 0 for non-anonymous),
  vmo_set_stream_size (201, WRITE; OUT_OF_RANGE past the VMO; zeroes from
  min(old, new) to the VMO's end), ZX_PROP_VMO_CONTENT_SIZE (17). Reads
  stop at it; writes zero-fill a gap past it and grow it by what lands;
  a write at or past the VMO's end is OUT_OF_RANGE, one reaching it cut
  short (streams never grow their VMO, as the pinned tree's don't:
  vmo_set_size does, K13h); append writes at
  the stream size. Size changes (stream writes, vmo_set_stream_size,
  vmo_set_size) hold their VMO's size lock (`Streams.withSizeLock`, as
  Zircon's per-VMO StreamSizeManager: a wait queue on the VmoRecord,
  `sizeQueue`, made on first use; review 2 replaced one global Mutex,
  which a pager wait held for every stream). A user buffer that faults ends
  a transfer short, NOT_FOUND if nothing moved. vmo_write doesn't move
  the stream size (as Zircon).
- Mode 17's `streams`.

The user pager, K13d (Kernel/Object/Pager.swift, User/PagerSyscalls.swift,
syscalls 202-208; vmo.h; Todhchai's page cache and mmap for Taisce):
- Zircon's pager (type 28; INSPECT, TRANSFER, ATTACH_VMO 1 << 23,
  MANAGE_VMO; NEW_PAGER policy 14, pager_create_vmo checks NEW_VMO):
  pager_create, pager_create_vmo(pager, options, port, key, size), with
  the size rounded to pages and an unaligned one as the stream size;
  RESIZABLE / UNBOUNDED NOT_SUPPORTED (no resizable VMOs).
  pager_detach_vmo, pager_supply_pages (pages moved from an anonymous aux
  VMO with no parent, `Vmo.take`; aux gaps supplied as zeros; pages the
  VMO has kept), pager_op_range FAIL (IO, IO_DATA_INTEGRITY, BAD_STATE,
  NO_SPACE, BUFFER_TOO_SMALL, sign-extended). Pager checks in the pinned
  tree's order (pager.rs); the koid check is INVALID_ARGS.
- A pager VMO is anonymous with `VmoRecord.pager` (a `PagerSource`: port,
  key, outstanding ranges, waiters); its snapshot children have
  `readsFromPager`. `commit(at:)` never zero-fills a page a pager owes;
  `VmoPointer.pagerGap(at:)` finds the pager VMO and offset a read would
  wait for, and `Pagers.ensure(vmo, offset, readAhead:)` requests (one
  READ packet, type 9, per new range: from the page up to the read-ahead,
  cut at a present page or the next outstanding range, at most 256 pages)
  and waits (interruptible; 300 s, Zircon's overtime: TIMED_OUT). Callers:
  the fault handler (retains the mapping's VMO and waits outside the
  aspace lock, then retries; a fault taken with interrupts masked doesn't
  wait), vmo_read/write (the rest of the copy as read-ahead), streams,
  vmo_op_range COMMIT/PREFETCH/ZERO, bti_pin. ZERO on a pager VMO makes
  a zero interval of its whole pages (K14k; TRAP_DIRTY VMOs zero in
  place); DECOMMIT is NOT_SUPPORTED.
- FAIL: waiters whose page is in the range get the status (vmo_read
  returns it; a fault is refused: exception); others on an overlapping
  request ask again. Detach (pager_detach_vmo, or the VMO's last
  reference): waiters wake to BAD_STATE, clean pages are dropped (dirty,
  awaiting-clean and pinned ones stay for writeback), one COMPLETE
  packet. The pager's last handle detaches its VMOs without COMPLETE.
- Dirty tracking (part 2): `VmoRecord.states` (a PageList: PageDirt
  dirty 1, awaiting clean 2, absent clean) and `modified`. A pager VMO's
  clean pages are mapped read only even through writable mappings (the
  fault path, and `UserAspace.protect`, which never grants write to a
  pager VMO's present pages), so the first write faults into
  `Pagers.prepareWrite`: the page becomes dirty, after a DIRTY request
  (type 9, command 2) the pager answers with op DIRTY if the VMO has
  TRAP_DIRTY; the fault then makes the entry writable. Kernel writes
  (vmo_write, streams, ZERO) go through `ensureWritable`. op DIRTY
  (TRAP_DIRTY only, else NOT_SUPPORTED; a page not supplied NOT_FOUND),
  WRITEBACK_BEGIN (dirty -> awaiting clean, unmapped everywhere:
  `VmoPointer.unmapEverywhere`, so a write meanwhile dirties again; dirty
  zero intervals too, and with IS_ZERO only those, K14k), WRITEBACK_END
  (awaiting -> clean; zero intervals awaiting clean go). pager_query_dirty_ranges (207: pager | vmo << 32, offset,
  length, buffer, buffer_size, size_t out[2] = actual, avail; ranges of
  pages not clean, options 0) and pager_query_vmo_stats (208; MODIFIED,
  RESET_VMO_STATS).
- Differences from Zircon: a packet per request (Zircon: one in flight
  per VMO), none withdrawn when a request resolves before it is read; the
  source holds its port.
- (Eviction of clean pages and the hints came in K14a, resizable pager
  VMOs in K13h, unbounded ones in K14i, zero intervals in K14k.)
- Mode 17's `pager`: a pager thread serving a fault, a two-page vmo_read
  (one request), a FAIL, a snapshot child reading through; writes through
  a mapping and vmo_write, dirty ranges, stats, a writeback with a write
  during it, detach dropping clean pages; a TRAP_DIRTY VMO's DIRTY
  requests from vmo_write and a write fault.

The small calls, K13e part 1 (syscalls 210-215 in User/IpcSyscalls.swift,
Kernel/Object/Names.swift; ipc.h, task.h; the pinned tree's semantics):
- object_wait_many (210, croi_wait_item_t): count 0 sleeps to the deadline
  and is TIMED_OUT, over 64 OUT_OF_RANGE, a bad item writes nothing back,
  otherwise every pending is written back (OK, TIMED_OUT, CANCELED; only
  the closed handle's item gets HANDLE_CLOSED).
- handle_close_many (211): 0 skipped, bad values BAD_HANDLE with the rest
  still closed, 64 per chunk.
- port_cancel_key (212): every async wait to the port with the key,
  whatever its source, and every queued packet with it (user ones too;
  not kernel sources' or interrupts'), NOT_FOUND if none. Each port keeps
  `watched` (an object address per observer to it, under its packets
  lock; Observers.add/remove, notify, handleClosed and port_cancel keep
  it), safe because an object loses its observers before its last
  reference.
- channel_write_etc / read_etc / call_etc (213-215): croi_handle_
  disposition_t (MOVE or DUPLICATE, type 0 = any, rights reduced or
  SAME_RIGHTS, result per entry) and croi_handle_info_t, Zircon's order of
  checks (TRANSFER, not the channel itself, type, rights subset; DUPLICATE
  needs DUPLICATE); every entry processed, MOVE consumes whatever happens,
  the array copied back if any failed. channel_read(_etc) now check the
  handle first and refuse unknown options with NOT_SUPPORTED;
  CROI_CHANNEL_READ_MAY_DISCARD drops a message that doesn't fit.
- ZX_PROP_NAME (3): 32-byte names (31 + NUL) on processes, threads (BAD_
  STATE once dead), jobs, BTIs and VMOs (in the VmoRecord), resources read
  only, others WRONG_TYPE; process_create and thread_create now store
  theirs.
- Mode 17's `small_calls`.

Info topics and vmar_op_range, K13e part 2 (User/InfoTopics.swift,
TaskSyscalls `vmarOpRange`, syscall 76; task.h, vmo.h):
- object_get_info takes Zircon's actual and avail (fifth and sixth
  arguments, optional). Fixed-size topics: actual 1 (0 and BUFFER_TOO_
  SMALL when short), avail 1; lists fill what fits and give the total.
  Topics are matched on bits 27:0 with the version in 31:28.
- PROCESS (STARTED / EXITED, `ProcessObject.startTime`), THREAD (state
  from ThreadObject and the scheduler; a blocked thread's BLOCKED_* reason
  from the syscall in its user frame, a page fault's PAGER;
  `exceptionChannelType` while an exception is offered; affinity in
  mask[0]), THREAD_STATS (BAD_STATE once dead), TASK_RUNTIME (cpu and
  queue time: `Thread.totalRuntime` grows in `charge`, `queueTime` at
  switch-in from `readySince`; exiting threads add theirs to the process,
  dying processes and jobs to their job), JOB (return code -1024 after
  task_kill), JOB_CHILDREN / JOB_PROCESSES / PROCESS_THREADS (koids,
  ENUMERATE), VMO (no rights needed; koid kept on the VmoRecord, flags,
  committed/private/scaled bytes; V1-V3 prefixes), PROCESS_VMOS (VMO
  handles then one entry per mapping; running processes only),
  PROCESS_MAPS (aspace, then regions and mappings depth first; V1/V2
  entries), HANDLE_TABLE (INSPECT | MANAGE_PROCESS | MANAGE_THREAD;
  `HandleTable.snapshot`). Not tracked: page-fault and lock-contention
  time. (Debugger attachment: K13g.)
- vmar_op_range (76): COMMIT, DECOMMIT, MAP_RANGE, ZERO, DONT_NEED and
  ALWAYS_NEED (K14a's hints), PREFETCH; rights by op on the VMAR
  handle, then per mapping; gaps BAD_STATE; mappings of sub-VMARs only
  with OP_CHILDREN (never for COMMIT/DECOMMIT/PREFETCH). Checked whole
  under the aspace lock, then done piece by piece without it (pagers may
  be waited for); `UserAspacePointer.mapPresent` maps what the VMO has.
- Mode 17's `info_topics`.

Clock objects, K13f (Kernel/Object/ClockObject.swift, User/ClockSyscalls.swift,
syscalls 216-219 and 77; clock.h):
- Zircon's clock (type 30; rights BASIC | IO | SIGNAL | PROPERTY, MAP for
  a MAPPABLE one; no policy): clock_create (options MONOTONIC, CONTINUOUS,
  AUTO_START, BOOT, MAPPABLE; args version in bits 63:58, v1 backstop),
  clock_read, clock_get_details (v1), clock_update (v1 value / rate ppm
  +-1000 / error bound, v2 with a reference value), vmar_map_clock (77:
  read-only, one page), ZX_INFO_CLOCK_MAPPED_SIZE (40), NAME. Zircon's
  checks and rules: unstarted reads the backstop and only a value starts
  it (BAD_STATE), MONOTONIC never back, CONTINUOUS no jumps once started,
  never below the backstop; STARTED set at the start, UPDATED pulsed at
  every update (set then cleared: waits and async waits see it).
- croi's reference "ticks" are monotonic ns (the counter's 32.32 scale has
  no u32/u32 ratio): reference_ticks_to_synthetic = reference_to_
  synthetic and the details' tick fields are ns. BOOT is monotonic (no
  suspend); timer_create takes clock id BOOT (1) too.
- State is croi_clock_page_t (Zircon's mapped layout) in the object under
  its lock; a MAPPABLE clock publishes it to a one-page read-only
  contiguous VMO under `seq_lock` (generation = seq / 2, 1 when created).
  Values: b_off + floor((r - a_off) * num / den), saturating (128-bit).
  PA_CLOCK_UTC (0x40) is defined; nothing creates a UTC clock yet.
- Mode 17's `clocks`.

Suspension and process memory, K13g part 1 (Kernel/Object/Debug.swift,
User/DebugSyscalls.swift, syscalls 230-232; task.h):
- task_suspend (232; Zircon's task_suspend_token too): WRITE on a thread
  or process (not the caller's own: NOT_SUPPORTED; others WRONG_TYPE),
  a token (type 27, TRANSFER | INSPECT) that resumes it when closed.
  `ThreadObject.suspendCount` (atomic); the scheduler thread's
  `suspendPending` makes `UserTraps.leaving` (and the first entry) park it
  on `suspendQueue` until the count is 0 or it is killed, `suspended` and
  the SUSPENDED / RUNNING signals (1 << 5 / 1 << 4) meanwhile; ZX_INFO_
  THREAD says SUSPENDED; thread_read/write_state work on its stack-top
  frame. A process counts once and suspends each thread; threads started
  meanwhile start suspended.
- Blocked threads: Zircon wakes interruptible waits with INTR_RETRY and the
  vDSO re-issues the call; croi's programs call the kernel directly, so
  the kernel restarts: `Syscalls.restartable` (nanosleep, wait_one,
  port_wait, vmo_read, futex_wait, interrupt_wait, counter_wait, readv,
  readv_at, wait_many) marks `Thread.restartable`;
  `Scheduler.requestSuspend` ends such a wait (`suspendRetry`), and
  dispatch leaves the result unwritten and rewinds the PC over the syscall
  (`ExceptionFrame.restartSyscall`: amd64 rip - 2, arm64 elr - 4, rv64 sepc
  not yet advanced). A pager wait under a user page fault is left the
  same way (the fault is taken again). Other waits (channel_call,
  exceptions) suspend when they end.
- process_read_memory (230; READ | WRITE) / process_write_memory (231;
  WRITE; `croi.debug_syscalls=on`, implied by croi.test=1, else
  NOT_SUPPORTED): within the one mapping at the address (NOT_FOUND
  otherwise), clamped, OUT_OF_RANGE for nothing; pager pages waited for;
  writing a mapping that isn't writable first gives it a private snapshot
  child (`UserAspacePointer.privatize`, Zircon's ForceWritable), the vDSO
  refused; executable code written is synced for instruction fetch.
- Mode 17's `debugging`.

Debugger channels, K13g part 2 (Kernel/Object/Exception.swift; task.h):
- task_create_exception_channel in Zircon's order: options (DEBUGGER 1),
  NEW_CHANNEL policy, INSPECT | DUPLICATE | TRANSFER | MANAGE_THREAD,
  a thread's debugger INVALID_ARGS, non-tasks WRONG_TYPE, a job or process
  without ENUMERATE ACCESS_DENIED; the user end TRANSFER | WAIT | READ. A
  process's debugger channel (`ProcessObject.debugChannel`, one:
  ALREADY_BOUND while open) or a job's (`debugChannels`, up to 32, closed
  ones pruned).
- Routing (`Exceptions.raise` / `deliver`, a `Handlers` list of channel
  and type): architectural and policy exceptions go to the process's
  debugger, the thread's, the process's channel, the debugger again if it
  set ZX_PROP_EXCEPTION_STRATEGY (18) to SECOND_CHANCE (debugger
  exceptions only, else BAD_STATE), then each job's. Synthetic
  (`raiseSynthetic`): PROCESS_STARTING to every job debugger up from the
  job (the initial thread, `startsProcess`), THREAD_STARTING to the process
  debugger with a frame of the entry registers it may change (read back
  before entering user mode: pc, sp, three arguments), THREAD_EXITING
  with no registers (state NOT_SUPPORTED) to each handler, the reply
  ignored.
- While an exception is offered the thread keeps its report (`inException`,
  `exceptionReport`): ZX_INFO_THREAD_EXCEPTION_REPORT (11 | 1 << 28, V1
  11), croi_exception_report_t with Zircon's arch part (amd64 vector,
  error code, cr2; arm64 ESR, FAR; rv64 scause, stval); THREAD info gives
  the channel type. ZX_INFO_PROCESS DEBUGGER_ATTACHED and ZX_INFO_JOB
  debugger_attached while a debugger channel is open.
- process_exit marks the caller killed before it exits (Zircon kills it
  too), so its THREAD_EXITING doesn't wait for a debugger: a process that
  was its own debugger hung there.
- thread_raise_exception (236, K14d; Zircon's): options
  TARGET_JOB_DEBUGGER, type ZX_EXCP_USER (0x8309) and a readable
  croi_exception_context_t, else INVALID_ARGS; the caller offers it to
  every job debugger from its process's job up, one at a time, the reply
  ignored (`Exceptions.raiseUser`), with synth_code/synth_data in the
  report and the syscall's registers readable. Walking a job's debugger
  list (this, PROCESS_STARTING, an attach) prunes closed channels.
- Mode 17's `debugger`: our own process's debugger sees a thread start
  (registers) and exit, a breakpoint with a second chance.
- Post-mortem freeze (Todhchai requirement 19) is user space's, as on
  Fuchsia (its crash service's "Limbo"): a crashed thread stays in its
  exception while a handler holds the exception handle; its registers,
  exception report and the process's memory can be read, the handle can
  move over a channel to a debugger, and the thread stays frozen until
  its holder resumes or ends it. Mode 17's `postmortem` checks the flow.

Single-step and hardware breakpoints, K13g part 3 (Kernel/Object/HardwareDebug.swift,
cpu.S `arch_debug_*`; task.h):
- thread_read/write_state kinds DEBUG_REGS (4, croi_thread_state_debug_
  regs_t per arch) and SINGLE_STEP (5, u32 0/1), on a stopped thread
  (suspended or in an exception); writes need debugging syscalls (Zircon's
  bit test gates both). A thread's state is `Thread.debugState` (heap
  DebugState from its first write), loaded at a switch to it and cleared
  at a switch to one without (`cpus[].debugLoaded`).
- amd64: TF in the frame's RFLAGS (stays until cleared); DR0-3 (0 or user
  addresses), DR6 (user bits B0-3, BD, BS, BT) and DR7 (L/G0-3, RW/LEN;
  LE/GE/bit 10 forced). A user #DB is HW_BREAKPOINT with DR6 saved for the
  debugger and reset; a kernel #DB (a user watchpoint hit by a user copy)
  is ignored.
- arm64: MDSCR_EL1.SS per thread plus SPSR.SS in the frame (one
  instruction per write, Zircon's); breakpoint and watchpoint pairs up to
  ID_AA64DFR0_EL1's counts, EL0 only (control registers rebuilt from
  their E bit), MDSCR_EL1.MDE while any is enabled; EC 0x30/0x32/0x34 from
  EL0 are HW_BREAKPOINT, a watchpoint's FAR/ESR saved. The OS lock (set at
  reset, it disables debug exceptions) is cleared on every CPU.
- rv64: single-step NOT_SUPPORTED, debug registers a u32 written and
  ignored (Zircon's).
- Mode 17's `stepping`: from a software breakpoint, one stepped
  instruction and a hardware breakpoint on a function (QEMU TCG delivers
  both on amd64 and arm64).

Resizable VMOs, K13h (Vmo.swift `resize`, VmoObject `create`/`setSize`,
PageList `grow`, syscall 233; vmo.h, task.h):
- vmo_create's options (it ignored them): RESIZABLE (1 << 1); UNBOUNDED
  NOT_SUPPORTED (with RESIZABLE INVALID_ARGS, first), DISCARDABLE (K14a),
  others INVALID_ARGS; an unaligned size is the content
  size. RESIZE (1 << 22) only on a resizable VMO's handles; snapshot
  children are resizable with CHILD_RESIZABLE (RESIZE then, never the
  parent's); pager_create_vmo takes RESIZABLE. ZX_INFO_VMO's RESIZABLE.
- vmo_set_size (233) in Zircon's order: WRITE; RESIZE if resizable
  (ACCESS_DENIED); physical/contiguous UNAVAILABLE; rounding overflow
  OUT_OF_RANGE; not resizable UNAVAILABLE; pinned pages cut off BAD_STATE.
  `VmoRecord.size` changes under the VMO lock: a shrink frees the pages
  past it (unmapped everywhere first) and wakes pager waiters there
  (`Pagers.cut`); a grow deepens the page lists (`PageList.grow`: a new
  root over the old). The content size becomes the exact size and the last
  page's tail past it reads zero.
- Past the end: `commit`/`lookup` refuse it under the lock, so faults fail
  (fatal page fault), vmo_read/write are OUT_OF_RANGE (also when shrunk
  meanwhile). An anonymous VMO may be mapped past its end (Zircon's: it
  may grow); vmar_map takes REQUIRE_NON_RESIZABLE (NOT_SUPPORTED on a
  resizable VMO) and ALLOW_FAULTS (accepted).
- A pager VMO's grown space is a dirty zero interval (K14k's
  `ZeroInterval`): zeros owed to nobody, reported with IS_ZERO, handed
  back to the pager by WRITEBACK_BEGIN then END.
- Differences: a snapshot child of a parent that shrinks reads zeros past
  the cut only while the parent is that small (Zircon clamps it for good);
  streams still never grow their VMO (the pinned tree's either).
- Mode 17's `resizing`.

SMC calls, K13i (User/SmcSyscalls.swift, smp.S `arch_smccc_call`, syscall
234; resource.h; Todhchai requirement 13):
- smc_call(resource, croi_smc_parameters_t *, croi_smc_result_t *):
  Zircon's layouts and order (null pointers INVALID_ARGS, the parameters
  read, the resource validated, the call, the result written). arm64:
  w0 the function ID, x1-x6, w7 = secure_os_id << 16 | client_id; result
  x0-x3 and x6. Through the FADT's PSCI conduit (`Power.psci`: SMC, or
  HVC where firmware runs at EL2, as under QEMU; Zircon always uses SMC).
  Elsewhere NOT_SUPPORTED (after the validation).
- SMC resources are function-ID ranges (Zircon's are 6-bit service call
  numbers: an OEN-scoped resource grants every SiP call, the board review's
  reason). The root filter refuses the PSCI calls that change CPU or system
  state (CPU_SUSPEND/OFF/ON, MIGRATE, SYSTEM_OFF/RESET/RESET2/SUSPEND,
  CPU_FREEZE, CPU_DEFAULT_SUSPEND, both conventions): the kernel's, even
  to the root resource (system_powerctl is the way).
- Yielding calls (bit 31 clear) with `croi.smccc_qcom=on` follow
  Qualcomm's resume protocol under one Mutex (Zircon's arm64_smccc_qcom):
  while x0 is INTERRUPTED (1), call again with function ID 1 and the x6
  session id. The Q8B needs it.
- Mode 17's `smc`: PSCI_VERSION through a one-function resource on arm64
  (QEMU's PSCI over HVC), OUT_OF_RANGE outside it, CPU_OFF and SYSTEM_OFF
  refused.

Randomness, K11b (Kernel/Random.swift, syscalls 181-182; handoff v5):
- The loader reads 32 bytes from EFI_RNG_PROTOCOL if the firmware has
  one (edk2 over virtio-rng: qemu.sh adds `-device virtio-rng-pci`) into
  the handoff (`entropy`, `entropy_size`; v5, 232 bytes). The kernel's
  CPRNG is ChaCha20 (RFC 8439 block, known-answer checked at boot) with
  fast key erasure, seeded first thing in kernel_main from that, the
  CPU's RNG instruction (`arch_hw_random`: amd64 RDSEED, else RDRAND;
  arm64 RNDR when ID_AA64ISAR0_EL1 says so; rv64 none, Zkr's seed CSR
  traps unless M-mode opened it) and counter jitter; the boot line names
  the sources and warns when jitter is all there was. The handoff's copies
  (the kernel's and, since review round 1, the loader's page)
  of the seed are cleared.
- `cprng_draw(buffer, length)` (181) and `cprng_add_entropy` (182):
  Zircon's, at most 256 bytes (CROI_CPRNG_MAX_LEN), INVALID_ARGS beyond
  or for a bad buffer. `Random.word()` for kernel use (ASLR).

Static PIEs and ASLR, K11b (lib/elf `forEachRelocation`,
ProgramLoader `randomBase`, userboot `randomPlace`; cmake `PIE`):
- `croi_user_program(... PIE ...)` builds a static PIE (-fPIE C and
  Swift importer flags, the runtime's -fPIE flavor libcroi-runtime-pie.a,
  `ld.lld -static -pie --no-dynamic-linker -ztext`, linked at 0).
  userboot and bin/m2 are PIEs, so every boot loads both ways; ET_EXEC
  programs (Todhchai's, the self-tests' fixed-address ones) still load
  where linked.
- An ET_EXEC may have a dynamic section (a program linked
  --export-dynamic to host dlopen'd libraries, Todhchai's M5k): it is
  only a symbol table, refused only if it has RELA, REL or JMPREL
  entries to apply (REL and JMPREL are refused for PIEs too). The program
  self-test runs user/test/swift a third time built that way
  (`croi_user_program(... EXPORT_DYNAMIC ...)`: lld makes the section for
  a non-PIC executable only with a shared object linked, so an empty one
  goes in --as-needed).
- Relocations: R_*_RELATIVE only; `ElfImage.forEachRelocation(in:)`
  reads PT_DYNAMIC and the RELA table from the file, and the loaders
  write `base - linkBase + addend` into the segment's VMO before mapping
  it (so RELRO-to-be pages are written while writable).
- RELRO (K14c): `ElfImage.relro` is PT_GNU_RELRO's pages (it must lie in
  one writable PT_LOAD; both ends rounded down to a page, glibc's rule;
  lld makes it a page-padded RW segment of its own), and both loaders
  make them read only after relocating (ProgramLoader `protect`,
  userboot `vmar_protect`). The runtime's `croi_relro_read_only()`
  (user/lib/runtime/image.c: the program's own headers via
  `__ehdr_start`, then PROCESS_MAPS) is checked by user/test/swift (the
  kernel's loader, PIE and ET_EXEC) and bin/m2 (userboot's). Todhchai's
  loader must do the same for its programs.
- Bases: a random page in the lower half of the user range (kernel:
  `Random.word()`, `UserAspace.isRangeFree`, 16 tries; userboot:
  cprng_draw and `vmar_allocate` with SPECIFIC, croi's now as Zircon's,
  ALREADY_EXISTS on a collision, retried). userboot maps writable
  segments as K11a children of the file's range of bootfs (copied at
  first touch, the tail past the file's bytes zeroed with
  vmo_op_range ZERO), read-only ones straight from bootfs.

Memory statistics (Todhchai's M3 resident-memory budget; task.h,
resource.h, UserAspace.taskStats, Kernel/Object/KernelMemory.swift):
- object_get_info(process, CROI_INFO_TASK_STATS = 12 | 1 << 28, or _V1 =
  12 for the first 32 bytes), Zircon's zx_info_task_stats_t, INSPECT:
  per mapping, mapped bytes, and committed bytes (anonymous: the page
  list's count in range; contiguous: all; physical: none) as private if
  only this address space maps the VMO, else shared and scaled by the
  number of address spaces, with the fraction in 63-bit fixed point.
  Every process maps the vDSO, so its code is shared once there are two.
- object_get_info(INFO system resource or root, CROI_INFO_KMEM_STATS =
  17 | 1 << 28, or _V1 = 17): total, free, wired, heap (slab + large
  pages, free = less bytes in use), vmo, mmu, other (allocated), from a
  scan of the PMM's page records (`Pmm.pageCounts`), and K14a's reclaim
  fields. The rest are 0.
- Boot test mode 13 (`ProcessSelfTest.runMemoryStats`).

Reclamation, K14a (Kernel/Vm/Reclaim.swift, vmo.h, syscall 235; Zircon's
PageQueues + Evictor + MemoryWatchdog without the page queues):
- Reclaimable VMOs (pager VMOs from creation, DISCARDABLE ones) are on one
  list (`Reclaim.register`, links in VmoRecord, unlinked by the last
  release; `tryRetain` to walk it). Each page record has `reclaimAge`
  (aging passes since its last access, up to 7) and `reclaimFlags`
  (ALWAYS_NEED, DONT_NEED), reset at allocation.
- Accesses make a page newest (`Reclaim.touch`): `commit(at:)` and
  `lookup(at:)` of a reclaimable VMO (under its lock, so a reader that
  just looked a page up keeps it), the fault path, and accessed bits,
  harvested from every mapping before each aging pass and eviction
  (`ArchAspace.harvestAccessed` clears them, local invalidate, then
  `flushAccessed`). arm64 has no hardware AF management (TCR.HA off) and
  rv64 may be Svade: an access then faults on a present PTE, and
  handleFault's present branch sets the bit (`markAccessed`); without it
  the fault loops (verified: arm64 hangs).
- The "reclaim" kernel thread ages every `croi.reclaim.aging_ms` (15 s)
  only while reclaimable VMOs exist, so an idle machine still makes no
  wakeups. Eviction (`Reclaim.evict(target:minAge:ignoreHint:)`, one at a
  time under a Mutex): DONT_NEED first, then oldest first down to
  `minAge` (6 for the watchdog, 2 at OOM, ages 0-1 never); clean,
  unpinned pages of attached pager VMOs, ALWAYS_NEED only with
  ignoreHint; a discardable VMO goes whole when its first committed
  page's turn comes. Pages are taken out under the VMO lock, unmapped run
  by run, then freed; the pager is asked again on the next access.
  `reclamationEvents` is ZX_INFO_VMO's committed_change_events.
- DISCARDABLE (vmo_create option 4, with RESIZABLE allowed; no children,
  cache policy stays cached): LOCK / TRY_LOCK / UNLOCK through
  vmo_op_range (READ or WRITE; whole VMO else OUT_OF_RANGE; LOCK checks
  its buffer after locking and unlocks on failure; UNLOCK at count 0
  BAD_STATE; TRY_LOCK of a discarded VMO UNAVAILABLE). States unset /
  locked / reclaimable / discarded (`DiscardState`): reclaimable only
  after a lock and unlock; discarded, commit and lookups fail (faults
  kill, vmo_read/write NOT_FOUND) until LOCK, which reports
  discarded_size = size.
- Hints (vmo_op_range and vmar_op_range 12/13, no rights): pager VMOs
  (a snapshot child's go to its pager ancestor), others ignore them.
  ALWAYS_NEED pages the range in and is sticky for those pages.
- Memory watchdog (Zircon's, `croi.oom.*`: outofmemory_mb 50,
  imminent_oom_delta_mb 10, critical_mb 150, warning_mb 300, debounce_mb
  1, hysteresis_seconds 10, eviction_delay_ms 5000, evict_at_warning,
  eviction_delta_at_oom_mb 10, reboot_timeout_ms 50000,
  trigger_on_alloc_failure, enable=0; out of order: off). The PMM wakes
  it when the free count leaves the current level's band
  (`Pmm.setFreeMemorySignal`; also a failed single-page allocation) via a
  zero-delay timer, since it may be under any lock. One event object per
  level, exactly one SIGNALED; system_get_event(root job, kind): handles
  WAIT | DUPLICATE | TRANSFER, OUT_OF_MEMORY needs MANAGE_PROCESS, other
  jobs ACCESS_DENIED. Worse levels signal at once, better ones after the
  hysteresis; a worse level at or below critical evicts (after the
  delay) to the critical watermark + debounce; OOM evicts at once (ages
  2+, hints ignored), then signals, logs and reboots after the timeout
  (`Power.reboot`). Log lines go to the debuglog (`KernelLog.write`, which
  DMA's warnings use too).
- KMEM_STATS: vmo_reclaim_total/newest/oldest bytes, discardable
  locked/unlocked bytes. Test hooks (syscall 6): 6 aging passes, 7 evict,
  8 watermarks/hysteresis/delay (0: the command line's), 9 free bytes.
- Tests: mode 17's `reclaim` (checks 600-619: eviction order, refault from
  the pager, hints, dirty pages kept, discardable states, the events moved
  by test watermarks); `boot-oom` (watermarks above RAM: OOM at boot,
  reboot). Lock order: aspace -> vmo (harvest); the registry lock is a
  leaf (heap below it).

Page loaning, K14f (Kernel/Vm/Loans.swift, Pmm.swift's loaning part;
Zircon's physical page borrowing; Todhchai requirement 3):
- Lenders: a contiguous VMO's decommitted range (vmo_op_range DECOMMIT,
  `Loans.decommit`; refused on slices, with children, over pinned pages)
  and the contiguous pool's free pages (lent at boot and on each free,
  taken back by `ContiguousPool.allocate`). `croi.ppb.loan=off` turns it
  off (contiguous DECOMMIT NOT_SUPPORTED again, the pool idle).
- PMM: lent free pages are PageState `.freeLoaned` on their own list,
  which only `allocateLoaned` (a borrower) draws from; `Page.loaned` /
  `loanCancelled` in `reclaimFlags`; a borrowed page keeps its borrower
  in `next` (VmoRecord) and `prev` (index). A borrowed page's free goes
  back to the loaned list, or to its lender if cancelled. `unloan` is
  the lender's step: back (free, or not lent), evict (borrowed), wait (in
  transit). KMEM free_loaned_bytes.
- A contiguous VMO's lent pages are bits in `VmoRecord.lent`: `lookup` /
  `commit(at:)` see them absent, eager mapping skips them (the mapper
  registered and the bits read in one locked step: `addMapper(lentIn:)`),
  the fault path and every `Pagers.ensure*` take them back through
  `Loans.ensure` (zeroed; written back for uncached VMOs), as does pin;
  slices of a VMO with lent pages are BAD_STATE; the VMO's end takes them
  back first (`endOfLender`). `Loans.mutex` (outermost) serializes lending
  and taking back. Attribution and ZX_INFO_VMO count lent pages out.
- Borrowers (part 2): only a pager VMO's clean pages (not TRAP_DIRTY, not
  detached, never pinned: `VmoRecord.everPinned`), swapped onto free lent
  pages by each aging pass (`Loans.borrow`, Zircon's borrow-on-MRU; age
  and hints copied, `copyReclaimState`); the originals are freed for
  anyone. `Loans.unborrow` swaps one back to an ordinary page before
  `prepareWrite` dirties it, before a pin, and on ALWAYS_NEED. Taking a
  page back evicts it from its borrower (`unloan` retains the borrower
  under pmmLock while the backlink is good; the pager supplies the page
  again). Eviction (K14a) evicts borrowed pages like any. The write-fault
  path that makes an entry writable first checks it maps the VMO's
  current page (a read-only entry can outlive a swap until its unmap).
- Mode 17's `page_loaning` (checks 636-643) and `page_borrowing`
  (644-649).

Boot budgets, K9f (Kernel/Trace/Budgets.swift, BootOptions.swift's
`SelfTests`, tools/bench.py):
- `boot-lean-icount` (arm64, rv64): the lean boot under QEMU
  `-icount shift=auto,sleep=off -rtc clock=vm`, guest time from
  instruction counts, so host load can't stretch it. Not amd64 (QEMU
  10.2 aborts, "Bad icount read") and not full boots: icount runs the
  CPUs in turn, a steady steal the deadline self-tests can't absorb.
- `croi.selftest=off` skips the self-test suite (early PMM/heap/VM/SMP
  tests, the framebuffer pattern, everything after the scheduler is up;
  the APs skip their lock-contention run). Todhchai boots with it;
  croi's ctest keeps it on, and `boot-lean` (every arch) boots with it.
- Monotonic time counts from kernel entry (`Clock.markEntry`, the first
  line of kernel_main; the counter there is the clock's base), so a
  timestamp is time since entry. `Userboot.start` reports
  `boot.userboot_start` (KVM, self-tests off: ~80 ms, target 100 ms for
  Todhchai's first console frame) or `boot.userboot_start_selftests`
  (~2.1 s).
- Spawn to main: userboot reads the clock before process_create and puts
  `croi.spawn_ns=<ns>` in the next program's environment; m2 reports
  `process.spawn_to_main` from the first line of main (limit 200 µs).
  KVM: ~50 µs (userboot's create + load ~22 µs, thread spawn ~7, to the
  user entry ~7, to _start ~6, runtime init ~6). It was 0.8-2.4 ms
  while every amd64 user page fault waited for an all-CPU shootdown.
- `irq.wait_wake_median` (target 5 µs, a hardware budget; ~12 µs under
  KVM, where the wakeup IPI exits).

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
- Secondaries run `kernel_ap_main`: exception vectors (amd64: shared IDT;
  each CPU then installs its own GDT copy, TSS and guarded exception
  stack, `CpuStacks.installThisCpu`), self-test, then the scheduler's idle.
- Boot self-test: per-CPU identity, and all CPUs incrementing a counter
  with a non-atomic load+store under one SpinLock after a start barrier
  (verified to fail without the lock).
- Not yet: CPU hotplug. (Per-CPU TSS/IST and exception stacks, the
  calibrated INIT/SIPI delays (`Clock.delay`) and the scheduler came
  later: see Kernel stacks, Time and Threads.)

Interrupts (`Kernel/Irq/`, K2a): `Interrupts` initializes the controllers
before secondaries start and dispatches everything `arch_exception` sees
as an interrupt. amd64: local APIC (x2APIC when CPUID says so, else xAPIC
MMIO), legacy 8259s and every IOAPIC pin masked; vectors 0xF0 IPI, 0xFE
error, 0xFF spurious. arm64: GICv3 only (QEMU runs `gic-version=3`):
distributor with all SPIs masked, per-CPU redistributor found by
affinity, SGI 0 = IPI; the ITS is found but not set up yet. rv64: IPIs
are SBI `send_ipi` (supervisor software interrupt); the PLIC takes
device interrupts (K9c), IMSIC/APLIC are only counted. Device interrupts
stay masked until an interrupt object takes them (K9c). `Ipi.callOthers(fn, arg)` runs a C function on every other
ready CPU and waits (Zircon's mp_sync_exec); waiters drain their own
mailbox, so cross-calls can't deadlock. `TlbShootdown.flushOthers` (amd64,
rv64) ends every ArchAspace unmap/protect, and map on rv64 only: amd64
caches no not-present entries, so filling a hole needs no remote flush
(K9f: the all-CPU IPI on every user page fault was most of spawn to main,
and it waits on any CPU writing the console with interrupts masked).
A user address space's unmap/protect goes only to the CPUs in its
`activeCpus` (Zircon's x86 active_cpus; `ArchAspace.owner` names the
record; set before the tables load, cleared after; the mask is read
with a locked RMW after the page-table stores, a full fence on x86):
amd64, and rv64 without ASIDs, where a CPU loading the tables later
starts with none of its entries. rv64 with ASIDs keeps entries across
switches, so it broadcasts (as Zircon's riscv64 does); arm64 broadcasts
in hardware. Kernel tables: every CPU. `TlbShootdown.received(cpu)`
counts what each CPU took; `ShootdownSelfTest` checks a reader on
another CPU faults after unmap and protect, and (where targeted) that
an idle bystander takes none of the IPIs. SpinLock restores the
caller's interrupt state while spinning, so a CPU waiting on `vmLock`
still answers the shootdown from the holder. Secondaries idle in
`arch_idle` with interrupts on; boot ends with "boot complete, idling".
The boot test checks sync calls and that a remapped page is seen by every
CPU (verified to fail without remote flushes).

Time (`Kernel/Time/`, K2b): `Clock` gives monotonic ns from the arch
counter (amd64 TSC calibrated by CPUID 0x15 or the HPET; arm64 CNTVCT_EL0
at CNTFRQ_EL0; rv64 `time` at the RHCT timebase). Its parameters live in
a `croi_time_page_t` (include/time.h, a PMM page) that K6 maps into user
space for the vDSO: ns = ((counter - base) * mult) >> 32, 128-bit product.
`Clock.delay` is the calibrated busy wait (INIT/SIPI use it). `Timers`:
tickless per-CPU one-shot timers, `arm(deadline:slack:callback, arg)` /
`cancel`, run on the arming CPU in interrupt context. Hardware is armed
for the earliest deadline+slack; when it fires every due timer runs, so
overlapping windows coalesce and zero slack is exact. amd64 TSC-deadline
(LAPIC one-shot fallback, tested with `-cpu max,-tsc-deadline`), arm64
virtual timer (GTDT PPI), rv64 SBI set_timer. K14b: each CPU's queue is
a list by `latest` under a leaf lock (`TimerNode`s; the head arms the
hardware; `maxSlack` bounds the interrupt's walk for due timers). Kernel
code with a fixed number of timers uses the CPU's 32 slots (`arm(deadline:
...)` -> id, `cancel(id)` on that CPU); anything whose count user space
decides owns a node in its record (thread timeouts, timer objects,
timelines: `arm(node, ...)`, never fails; `cancel(node, on: cpu)` from any
CPU, false once it fired, when on another CPU its callback may still be
running). A thread whose timeout fired elsewhere as it cancelled waits
that CPU out by IPI (`timeoutStragglers`) before leaving the scheduler.
It was a 32-entry array: a 33rd thread blocking with a deadline on one CPU
panicked, a 33rd timer object was NO_RESOURCES.
QEMU TCG has no TSC-deadline mode, so amd64 TCG runs use the LAPIC
one-shot timer: its count comes from the same counter read that bounds
the deadline (a second read past it wrapped the delta and fired a due
timer 68.7 s late; the time self-test arms 200 already-due timers).
`Scheduler.dump` shows each CPU's pending timers, what the hardware is
armed for, interrupt counts, and on amd64 the dumping CPU's ISR/IRR/LVTT.
For lockups, `qemu.sh --registers-on 'ipi mailbox|PANIC'` prints every
CPU's PC and frame-pointer backtrace when the deadman dump (or a panic)
appears (`qemu-monitor.py backtrace`; symbolize with llvm-symbolizer).
Anything that frees or unmaps kernel memory may wait for TLB-shootdown
acknowledgements while holding vmLock, so it must run with interrupts on:
the idle loop reaps dead threads (freeing their stacks) with interrupts
enabled. Reaping masked deadlocked two reaping CPUs (the sched self-test
stresses it: 6 of 6 KVM boots hung before the fix).
`lib/rt/int128.c` supplies `__udivti3`/`__umodti3`, which
`dividingFullWidth` needs (there is no compiler-rt).

Topology (`Kernel/Acpi/Pptt.swift`): `CpuTopology` in each PerCpu:
package, core, thread, last-level cache from the PPTT (by ACPI UID from
the MADT), and a core type each CPU reads itself (x86 hybrid CPUID 0x1A,
Arm MIDR). QEMU only has a PPTT on arm64 and never cache nodes, so a
boot self-test runs the walk on a hand-built table. This is the data for
the topology page (ext 9).

Threads (K3a, Kernel/Sched/): `Scheduler.spawn` returns a `ThreadHandle`
(`~Copyable`; `join()` frees the thread, dropping it detaches). Thread
records are heap allocations reached through `ThreadPointer`; `savedSp` must
stay their first field (arch_context_switch stores through the record
address). One global scheduler lock protects all thread, run-queue and
wait-queue state. It is taken masked (`lockMasked`) and handed across the
switch: the resumed thread releases it (`finishSwitch`). Never send a
waiting IPI (`Ipi.call`) while holding it. Use `Scheduler.locked { ... }`
to check a condition and `block(on:deadline:)` without lost wakeups.
Timers belong to the CPU that armed them, so a timeout left on another CPU
is cancelled by IPI after the lock drops; a timer must never outlive its
thread. A timeout that fires while its thread is awake (woken, not yet
running) clears the thread's timer id, so a condition loop blocking again
for the same deadline arms a new one (it used to keep the fired id and
wait forever; the sched self-test forces that window). Timer ids are only unique per CPU, and a thread can resume on
another CPU after any `switchAway`: re-read `Cpu.current` after one (a
stale CPU number in the preemption loop cancelled other CPUs' timers). Preemption: a timeslice (10 ms), or a wakeup onto an idle CPU,
sets a per-CPU request that is acted on when an interrupt returns.
Interrupt frames don't restore the per-CPU register (rv64 `tp` is skipped),
because a preempted thread can resume on another CPU. Queues are ordered
by `Thread.queueKey` (`QueueHead`). Leaving `locked` with interrupts on
is a preemption point. Load balancing (Zircon's idle-time work stealing):
a CPU about to switch to idle, and an idle CPU each time it wakes, takes
the first waiting fair thread it may run (affinity, reservation; not one
admitted to a CPU) from the CPU with the most fair threads waiting
(`Scheduler.steal`; its vruntime lag carried over as at a wakeup;
`steals` counts them, a MIGRATE trace record each); queued threads are
always switched out (the lock is held across a switch), so any may move.
The sched self-test pins two spinners to one CPU, frees them, and has
another CPU go idle: it must take one. Fixed on the way: a ready thread
`requeue` must move (its CPU now reserved for another job, its affinity
changed) kept the old CPU's vruntime instead of its lag rebased onto the
new CPU's minimum; arriving from a CPU it had to itself it waited ~300 ms
behind the new CPU's threads (the EDF self-test's reservation part, once
stealing made it likelier). A wakeup aimed at the local
CPU only sets a request bit, so the idle loop and `preemptIfRequested`
recheck after every switch (`finishSwitch` can make a thread ready here).

Policy (K3c, Zircon's two disciplines; Sched/Profile.swift): a thread's
`Profile` is fair (weight; priorities 0...31 map through Zircon's table)
or deadline (`DeadlineParams`: capacity of reference-core work within
deadline, every period). Per CPU: a fair queue by virtual runtime (ns x
1024 / weight; slice = 16 ms target latency x weight share, >= 0.75 ms;
tickless when alone), a deadline queue by absolute deadline (always
first), and a throttled queue of reservations waiting for their next
period (an eligibility timer). Deadline budgets are charged in
capacity-scaled time and enforced by the slice timer; running out counts
an overrun on the context (ext 3 hook); `yield()` ends a deadline
thread's period. CBS rule on wakeup. Scheduling contexts
(`SchedContext`, ~Copyable owner of a `SchedContextRecord`) are separate
from threads: a fair weight, or a deadline reservation admitted by
`Scheduler.admit` on one CPU (biggest capacity that fits under 85%), with
`AdmissionRefusal` reasons and a per-user `SchedAccount` budget (ext 4);
admitted threads never migrate. CPU capacity defaults from the core type
(`CoreCapacity`, biggest = 1024), overridable by `setCapacity` (the power
service's call). `reserve(cpu:tag:)` (ext 8). Each CPU publishes
`powerHints` (wake-latency bound, frequency floor) for KP. `frame` intent
(ext 10) is stored only.

Thread pins (review round 1): code that reads a thread object's `thread`
under its lock and uses it after (futex owners, object_set_profile,
overrun ports, timeline alignment) takes `Processes.pinnedThread`, which
pins the record (`Scheduler.pin`, under the object lock: exit clears
`thread` under it first); the reaper leaves a pinned zombie to the last
`unpin`. `dropOwnership` marks the thread `exiting`, and `setOwner`
refuses exiting or dead owners and (futex waits) a chain through the
waiter itself (`adding:`): two waits naming each other looped inheritance
into a panic. `Thread.enteredUser` (set just before `arch_enter_user`)
gates register access to a suspended thread: one parked in
`UserTraps.enter` has only kernel frames at its stack top (BAD_STATE).

Priority inheritance (K3b, with K3c's profiles): a `QueueHead` with an
`owner` is an owned wait queue. Its waiters lend their effective profile to
the owner and on down the chain (`updateEffectiveProfile`), by Zircon's
rules: fair weights add; deadline utilizations add with the tightest
deadline, and turn a fair owner into a deadline one. `Mutex` (Thread.swift) is the
kernel's blocking lock on one: unlock hands it to the highest-priority
waiter, and recursion or a deadlock cycle panics (K7's futex will refuse
the owner instead, as Zircon does). A thread may not exit holding one.
`Scheduler.dump` prints every CPU and thread (all are on `allThreads`);
the boot self-tests arm a 20 s deadman that calls it.

Extended register state (K3d, Sched/ExtendedState.swift, include/xstate.h):
measured on every CPU at boot (IPI call), the shared subset kept (user
threads migrate): amd64 CPUID 0xD (standard-format XSAVE size; AMX tile
data lazy behind XFD), arm64 FP/SIMD, SVE and SME vector lengths
(rdvl/rdsvl with CPACR traps lifted only for the probe; every CPU's
ZCR_EL1/SMCR_EL1 then set to the smallest), rv64 F/D/V from the RHCT
plus `vlenb`. `eagerSize` bytes per user thread (saved each switch) +
`lazySize` on first use (AMX tiles, SME ZA/streaming state).
`spawn(extendedState: true)` allocates the area; kernel threads have
none and never touch FP. The save/restore code is K6's. The arm64 EL2
drop sets CPTR_EL2 from the ID registers (TZ/TSM are traps where SVE/SME
exist, RES1 otherwise: 0x33ff trapped both) and opens ZCR_EL2/SMCR_EL2.

Trace (Kernel/Trace/, include/trace.h; roadmap "Trace", K3 part):
per-CPU rings (header page + power-of-two records of 32 bytes,
`croi_trace_record_t`: raw counter time, kind, CPU, thread trace id
`task << 12 | thread`, two words), written only by their own CPU with
interrupts masked, no lock; oneshot (drop + count) or circular. Probes are
`Trace.event(category, kind, a, b)`, inlined: the mask
(`croi_trace_mask`, a C global in kernel/trace.c because Swift globals
initialize lazily and would add a guard) is one relaxed load and a branch;
arguments are evaluated only when on. `stop()` clears the mask and waits
for each CPU's `traceWriting` flag (seq_cst on both sides, no IPI).
Categories now: `sched` (switch, wake with the waker, block, preempt with a
reason, migrate, overrun) and `irq` (enter/exit). The self-test reports
an enabled event's cost (budget `trace.probe_enabled`, limit 30 ns,
enforced as "Timing discipline" says; `Budgets.timingIsReal` is the
CPUID check), ~18 ns under KVM. amd64 `arch_percpu` is a %gs-relative load of the
record's `self` field (CROI_PERCPU_SELF), not rdmsr; GS points at a
zeroed dummy record until a CPU has its own.

Bring-up aids (K2 follow-ups from the board review in docs/roadmap.md):
- Console: the loader takes SPCR, then DBG2 (CIX Sky1 has no SPCR), then
  COM1 on PCs; `loader.console=dbg2` in `\croi\cmdline` tries DBG2 first
  (test `boot-dbg2-console`). Qualcomm GENI (type 0x13) isn't supported yet.
- `Timers.alwaysRunning`: x86 ARAT (CPUID 6 EAX[2]); without it deep
  C-states stop the APIC timer.
- `Watchdog` (Kernel/Time/Watchdog.swift): the GTDT's SBSA generic
  watchdog, 30 s timeout, refreshed every 5 s by a timer;
  `croi.watchdog=off` disables it. `SbsaWatchdog.RefreshMethod` has the
  Sky1's WOR-write refresh for a board rule to pick. QEMU has no SBSA
  watchdog, so the self-test only covers GTDT parsing and register
  programming on RAM stand-ins; it is unverified on hardware.
- arm64 SError policy (`SErrorPolicy`): corrected errors are counted and
  execution continues; everything else from the kernel is reported and
  panics. Recoverable kinds go to the faulting process once user mode
  exists. QEMU can't inject SErrors; the classifier is tested on synthetic
  ESR values.

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
the CPU runs on must keep this geometry. Each CPU installs its own guarded
exception stack (`CpuStacks.installThisCpu`): amd64 gets its own GDT copy
and TSS with IST1 on it; arm64/rv64 store it in `croi_percpu_arch_t`
(stack.h), the first field of PerCpu, which exception entry reads through
TPIDR_EL1 / tp. The .bss emergency/IST stacks only cover early boot.
amd64 GDT layout is fixed for syscall/sysret: 0x08 kernel CS, 0x10 kernel
DS, 0x18 user CS32, 0x20 user DS, 0x28 user CS64, 0x30 TSS. A CPU must
have its local interrupt controller up before it maps anything (mapping
can trigger a TLB shootdown, which sends IPIs). A deliberate fault in kernel code must use a
volatile access, or LLVM may delete it (e.g. stores to const symbols).

Kernel enters on the loader's page tables with the handoff's physical
address as its argument, at EL1 on arm64: if firmware ran at EL2, the
trampoline neutralizes EL2 (HCR_EL2 = RW, plus API and APK since K14p;
timer, PMU and GICv3 sysregs
handed to EL1) and drops to EL1 after ExitBootServices. Not yet supported:
amd64 5-level paging, CPUs where HCR_EL2.E2H is RES1 (VHE-only).

KASLR (K14j; handoff.h CROI_KASLR_*, boot/Loader `kaslrEntropy`,
KernelLayout `randomized`/`describeImage`): the loader picks the kernel's
base, 2 MiB aligned (any segment's alignment), anywhere the image fits in
a window that ends at the link address: 48-bit amd64/arm64 the last
512 GiB top-level slot (~2^18 bases), rv64 the Sv39 high half's last
62 GiB (~2^15). Bits from EFI_RNG_PROTOCOL, else RDRAND/RNDR
(`croi_arch_entropy`), else the counter (the loader says WEAK). The
relocations (R_*_RELATIVE only) are applied for that base
(`ElfImage.load(runningAt:)`); the kernel already used run-time addresses
throughout (image symbols PC-relative, the handoff's kernel_virt, the
sampler's image offsets). `croi.kaslr=off` loads at the link address. The
kernel panics on an image outside the window (or, with self-tests, at the
link address without croi.kaslr=off). It prints `kaslr: image
<start>-<end>, link <link>` at boot and after every PANIC line: kernel
addresses in a log map to the ELF's as address - start + link.
qemu.sh's `--registers-on` backtraces do that (qemu-monitor.py `backtrace
<start> <end> <link>`). Physical placement isn't randomized (the physmap
shows it anyway).

Pointer authentication, arm64 (K14p; Main.swift `PointerAuth`, cpu.S
`arch_pac_*`, `croi_pac_keys` in kernel.h): the kernel's Swift and C are
built with -mbranch-protection=pac-ret (kernel/CMakeLists.txt), so every
non-leaf function signs its return address with the APIA key and checks
it before returning (paciasp/autiasp: hint space, NOPs without PAuth or
with it off). One random kernel key per boot on every CPU, chosen before
`arch_continue_on_stack`, and one per process (K14s: random in its
`UserAspaceRecord`, `pacKeyLo/Hi`); the key registers serve EL0 and EL1
alike, so entry from EL0 loads the kernel's (`arch_pac_load_kernel_key`,
before any signed code) and every return to EL0 the running process's
(`arch_pac_load_user_key`, also in `arch_enter_user`), read from the
CPU's `croi_percpu_arch_t` (CROI_PERCPU_PAC_USER), where the scheduler
copies it at each switch to a user thread and in `setAspace` (a new
thread takes its address space after the switch to it: the first version
missed that, and a second thread signed with the previous process's key).
SCTLR_EL1.EnIA is set only on paths that never return through an earlier
frame (`arch_pac_enable` in `arch_continue_on_stack` and before
`kernel_ap_main`): a function entered before it would fail its own check.
Both EL2 drops set HCR_EL2.API|APK (else the instructions trap to an EL2
with no handler). Kernel stack walks strip the signatures
(`arch_pac_strip`, XPACLRI; qemu-monitor.py does the same by bit 55); a
failure with FEAT_FPAC is EC 0x1C, "pointer authentication failure".
`croi.pac=off`, or no address authentication (ID_AA64ISAR1/2): unsigned.
The boot self-test checks signing and that another key signs differently;
mode 17's check 676 that user code's signature isn't the kernel's (it
failed with the return path's key load removed), 683-685 that another
thread of the process signs alike and a child process differently (683
failed with one key for every process). User programs aren't built with
pac-ret (their own choice).

Branch target identification, arm64 (K14q; Main.swift `BranchTargets`,
cpu.S `arch_bti_*`, PageTableFormat `guardedKernelText`): built with
-mbranch-protection=pac-ret+bti (croi-rt with bti), so compiled code
carries a landing pad (BTI, or the PACIASP already there) wherever it is
reached by an indirect branch; hand-written assembly reached by `br`/`blr`
must start with `bti j`/`bti c` (today only the PMU sysreg jump tables,
16-byte entries; direct `bl`, `ret` and `eret` need none). With FEAT_BTI
(ID_AA64PFR1_EL1.BT) and no `croi.bti=off`, executable kernel leaves get
the guarded-page bit (50; decided before the kernel's tables are built,
the command line read through the loader's identity map) and
SCTLR_EL1.BT1 is set. A stray indirect branch is EC 0x0D, "branch target
exception". The boot self-test branches to a non-pad instruction
(`arch_bti_probe`) and arch_exception sends it on to a recovery point,
clearing SPSR.BTYPE (else the recovery instruction is checked too); with
the jump tables' pads removed the PMU self-test faults.

Guarded user pages (K14r): `CROI_VM_PERM_GUARDED` (task.h, 1 << 30,
croi's) on vmar_map/vmar_protect makes an executable mapping guarded
(`VmRights.guarded`, `MapAttributes.guarded`, bit 50 where FEAT_BTI is in
use; accepted and ignored elsewhere; PROCESS_MAPS reports it). Programs
opt in through their ELF: `ElfImage.branchTargets` reads PT_GNU_PROPERTY's
GNU_PROPERTY_AARCH64_FEATURE_1_AND (bit 0, BTI), which lld sets only when
every object has landing pads; ProgramLoader and userboot then map the
executable segments guarded. croi's arm64 user code is built with
-mbranch-protection=bti (CROI_USER_CFLAGS): userboot, m2 and the Swift
test programs come out marked (an unmarked program, `hello`, runs
unguarded). The vDSO (every entry `bti c`) is always mapped guarded. A
user branch target exception is CROI_EXCP_GENERAL. Mode 17's checks
677-678: through a guarded mapping a BTI C routine is reached and a NOP
one refused (the thread's exception); through a plain one either runs
(678 failed with the user bit not encoded).
- `ld/image.ld` Shared linker script: one PT_LOAD per permission (W^X).
- `cmake/`    Toolchain file, per-arch settings, `croi_image()` helper.

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
