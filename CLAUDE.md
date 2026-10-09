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

`docs/roadmap.md` orders croi's work (K1 handoff v3 + cache policy, K2
interrupts/IPIs/clock/timers, K3 threads + scheduling contexts, K4 VMM
phase A, K5 objects, K6 syscalls/vDSO/user SIMD, K7 IPC/processes, K8
userboot) against Todhchai's needs (`../todhchai/docs/croi-requirements.md`).
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
volume -> load + relocate it at its link address -> optional
`\croi\bootfs.img` (own memory type, CROI_MEM_BOOTFS) and `\croi\cmdline`
(copied into the handoff pages) -> GOP framebuffer (linear only) -> RSDP
from the UEFI
config table, early UART from ACPI SPCR (COM1 fallback on amd64) -> boot
page tables (all RAM identity mapped RWX, UART as device, kernel segments
W^X at CROI_KERNEL_BASE; Sv39 on rv64, TTBR0/TTBR1 on arm64) ->
ExitBootServices -> memory map converted into the handoff, framebuffer
range overlaid as CROI_MEM_FRAMEBUFFER -> handoff v3 ->
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
`boot-smoke-no-svpbmt` covers `-cpu rv64`. The framebuffer (CROI_MEM_FRAMEBUFFER) is in no PMM arena and not
in the cached physmap; `Framebuffer` maps it WC. The boot test draws a
pattern and checks it with a QEMU screendump (`qemu.sh --screendump`,
`tools/check-pixels.py`); arm64/rv64 get a framebuffer from
`-device ramfb`.

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
- Regions (K4b): each aspace keeps `regions` (sub-regions, sorted, with a
  parent; region 0 is the root) and non-overlapping `mappings`. A
  reservation's range is held for views: `mapView`/`unmapView` replace
  views under the aspace lock, so faults (which take the lock) see the old
  view or the new one, never a hole (ext 7). `unmap(range)` trims and
  splits mappings; `protect` splits at the edges. VMOs list the aspaces
  mapping them (`mappers`); `decommit` takes pages out of the VMO, then
  unmaps them from each aspace (held by a reference, skipped if `dead`),
  then frees them, so the aspace -> vmo lock order holds.
- Physical (K4b): `PhysicalMap` keeps every memory-map range that is RAM
  or firmware's; physical VMOs over them are refused (`.denied`).
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
  (made at boot) mints system resources; the tracing one (base 6, as
  Zircon) gates `TraceControl` (start, stop, rewind, mark, rings as
  read/map-only VMO handles).

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
- Not yet: per-CPU TSS/IST and emergency stacks (shared today),
  calibrated delays for INIT/SIPI (spin loops), CPU hotplug, a scheduler.

Interrupts (`Kernel/Irq/`, K2a): `Interrupts` initializes the controllers
before secondaries start and dispatches everything `arch_exception` sees
as an interrupt. amd64: local APIC (x2APIC when CPUID says so, else xAPIC
MMIO), legacy 8259s and every IOAPIC pin masked; vectors 0xF0 IPI, 0xFE
error, 0xFF spurious. arm64: GICv3 only (QEMU runs `gic-version=3`):
distributor with all SPIs masked, per-CPU redistributor found by
affinity, SGI 0 = IPI; the ITS is found but not set up yet. rv64: IPIs
are SBI `send_ipi` (supervisor software interrupt); IMSIC/APLIC/PLIC are
only counted. Device interrupts stay masked until drivers route them with
an affinity. `Ipi.callOthers(fn, arg)` runs a C function on every other
ready CPU and waits (Zircon's mp_sync_exec); waiters drain their own
mailbox, so cross-calls can't deadlock. `TlbShootdown.flushOthers` (amd64,
rv64) ends every ArchAspace map/unmap/protect. SpinLock restores the
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
virtual timer (GTDT PPI), rv64 SBI set_timer. The queue is a fixed array
per CPU for now; K3's thread timers will need an intrusive structure.
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
thread. Timer ids are only unique per CPU, and a thread can resume on
another CPU after any `switchAway`: re-read `Cpu.current` after one (a
stale CPU number in the preemption loop cancelled other CPUs' timers). Preemption: a timeslice (10 ms), or a wakeup onto an idle CPU,
sets a per-CPU request that is acted on when an interrupt returns.
Interrupt frames don't restore the per-CPU register (rv64 `tp` is skipped),
because a preempted thread can resume on another CPU. Queues are ordered
by `Thread.queueKey` (`QueueHead`). Leaving `locked` with interrupts on
is a preemption point. A wakeup aimed at the local
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
reason, migrate, overrun) and `irq` (enter/exit). The self-test enforces
an enabled event < 30 ns only when not emulated (CPUID hypervisor
signature isn't TCG): `boot-smoke-kvm` (amd64, when /dev/kvm exists) runs
it, ~19 ns today. amd64 `arch_percpu` is a %gs-relative load of the
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
