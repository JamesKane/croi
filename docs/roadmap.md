# croi roadmap

croi's first consumer is Todhchai (`../todhchai`). Its kernel requirements
are in `../todhchai/docs/croi-requirements.md` (items 1–19 and extensions
ext 1–10), and its milestone M2 ("croi reaches user space") is croi's next
big target. This file orders croi's work so those needs are designed in
early, not bolted on later. Reviewed against the requirements on
2026-10-09.

## M2 exit test (from Todhchai)

userboot starts a tier 0 Embedded Swift process from bootfs. The process
creates a channel pair, passes a VMO across, waits on a port with a
deadline timer, and prints over debuglog. This works on all three arches in
QEMU.

M2's exit also includes meeting Todhchai's kernel and IPC budgets under
KVM (amd64), measured from croi's own trace (item 18 core, below). The
proposed targets (todhchai docs/performance.md): null syscall < 100 ns,
same-core `channel_call` with donation < 1 µs, cross-core port wake < 2 µs,
real-time wake error p99 < 100 µs.

## Status against the requirements

| # | Item | Status |
|---|---|---|
| 1 | Handoff: bootfs, GOP framebuffer, command line | **Done** (K1): handoff v3. The bootfs format itself comes with userboot (K8) |
| 2 | Interrupt controllers, tickless timer, monotonic clock | **Done** (K2). ITS and AIA set up with the first MSI driver |
| 3 | PMM (contiguous, reclaim), heap, slab | **Done**, except ACPI-reclaim memory, which stays wired until ACPI parsing is finished |
| 4 | Threads, wait queues, PI owned wait queues, timers | Todo (K3) |
| 5 | Scheduler: fair + EDF | Todo (K3) |
| 6 | SMP: AP bring-up, IPIs, TLB shootdown, per-CPU data | **Done** |
| 7 | VMM phase A: VMARs, VMOs, faults, cache policy, huge pages | **Partial**: ArchAspace (map/unmap/protect/query, large pages), the kernel aspace, and the cache policy (K1; rv64 Svpbmt pending) exist. The rest is in K4 |
| 8 | Handles, rights, koids, dispatchers, signals, waits | Todo (K5) |
| 9 | Syscalls, user-copy, vDSO, user FP/SIMD | Todo (K6) |
| 10 | Channel, port, event(pair), futex with owner, timer | Todo (K7) |
| 11 | Job, process, thread, exceptions, job policy | Todo (K7) |
| 12 | userboot + bootfs | Todo (K8) |
| 18 (core) | ktrace rings, categories, user marks, tick and PMU sampling, per-thread PMU counters | Before M2, staged K3–K6 (see "Trace" below) |
| 13–19 | Resources/interrupt objects, BTI/PMT + IOMMU, FIFO/counter/stream/socket/clock/debuglog, pager, rings, debug syscalls | After M2 (K9+), with the designs constrained below |

## Milestones

Each milestone ends with boot self-tests on all three arches, like the work
so far.

### K1: Handoff v3 and cache policy (requirements 1, part of 7): done
Still open: rv64 Svpbmt (needs ISA detection from the RHCT, which comes
with K2's ACPI work), and a text console on the framebuffer (needs a font).
- Loader: read `\croi\bootfs.img` (`CROI_MEM_BOOTFS` range), GOP framebuffer
  (base, size, stride, pixel format), and the command line (loader options,
  or `\croi\cmdline`). Handoff v3.
- `MapAttributes.device: Bool` becomes a cache policy: cached, uncached,
  write-combining, and device (strongly ordered). This needs:
  - **amd64:** program the PAT so WC is available.
  - **arm64:** add MAIR indices for Normal-NC and Device-nGnRnE.
  - **rv64:** use Svpbmt when present; otherwise PMAs decide.
- The kernel maps the framebuffer write-combining, as a second console.
- *Why now:* item 1 is first on Todhchai's list, the loader code is fresh,
  and the cache policy change gets harder the more mappings exist.

### K2: Interrupts, IPIs, clock and timers (requirements 2, 6)
Progress: **K2 done.** K2c: per-CPU guarded exception stacks (amd64 own
GDT/TSS/IST1 with the syscall-ready GDT layout), Svpbmt from the RHCT,
PPTT topology and core types per CPU. **K2b**: monotonic clock with a vDSO-ready time page,
tickless per-CPU timers with deadline + slack coalescing, calibrated
delays. **K2a done**: controllers (x2APIC/xAPIC + IOAPIC masked, GICv3,
SBI IPIs with AIA/PLIC discovered), dispatch, IPIs, `Ipi.callOthers`, TLB
shootdown, interrupts on in idle. ITS and AIA (APLIC/IMSIC) setup moves to the drivers phase
(requirement 13), when the first MSI-capable device needs them.

- **Controllers.** Pick the MSI-capable controller on each arch now, because
  item 13 needs MSI/MSI-X with per-queue vectors:
  - **amd64:** local APIC (x2APIC when available) and IOAPIC, with a per-CPU
    vector allocator that MSI can draw from.
  - **arm64:** GICv3 with the ITS for MSIs (LPIs). GICv2 is supported only
    as QEMU's default.
  - **rv64:** AIA (APLIC + IMSIC) for MSIs. PLIC is the fallback for QEMU's
    default `virt` machine.
  - All controllers are discovered from the MADT (and IORT/RHCT where
    needed).
- **Routing designed for later extensions:**
  - Every IRQ has an explicit CPU affinity, so cores can be reserved for a
    job with no IRQ routing (ext 8).
  - The dispatch layer has a handler kind that wakes one specific thread
    directly, with no port queue (ext 5). The hook is in place now, even
    though threads come in K3.
- **IPIs:** a per-CPU mailbox. Kinds: TLB shootdown (replaces today's
  local-only invalidation on amd64/rv64), reschedule, generic call, halt.
- **Clock:** monotonic time from an invariant counter (TSC, CNTVCT, `time`
  CSR), calibrated at boot. The conversion parameters live in a page laid
  out for user space (the vDSO clock in K6), designed together with ext 9
  and ext 1 (see "Shared read-only pages" below).
- **Timers:** per-CPU tickless one-shot timers: TSC-deadline or LAPIC, the
  Arm generic timer, and Sstc `stimecmp` or the SBI timer. Timers are set to
  an absolute deadline plus slack, and real-time profiles get zero slack.
  Calibrated `udelay` replaces the INIT/SIPI spin loops.
- **Clean-up carried over from the SMP work:**
  - per-CPU TSS with IST (amd64)
  - per-CPU emergency stacks (arm64/rv64)
  - PPTT parsing into `PerCpu` (core type, cache sharing), the data source
    for ext 9

### K3: Threads and scheduling (requirements 4, 5)
Progress: **K3a done**: threads, context switch, per-CPU run queues,
blocking with timeouts, wakeup placement, timeslice and wakeup
preemption, join/detach/reaping. **K3b done**: priorities, owned wait
queues with transitive priority inheritance, kernel `Mutex` with handoff
by priority, a scheduler state dump. **K3c done**: scheduling contexts,
fair (weighted virtual runtime) + EDF (CBS budgets, capacity-scaled,
throttling, overruns), Zircon-rule profile inheritance, admission with
reasons and per-user accounts, capacity defaults by core type, reserved
CPUs, power hints. Not yet: IPC donation (ext 2, with channels in K7),
overrun port packets (K5 ports), the frame intent's display alignment
(ext 1/10), load balancing of fair threads between CPUs beyond wakeup
placement. **Trace core for K3 done**: per-CPU rings, `sched` and `irq`
categories, probe cost checked under KVM (`boot-smoke-kvm`: ~19 ns per
enabled event, a disabled probe one load and a branch). **K3d done**:
per-thread extended-state areas sized at boot from what every CPU shares
(QEMU: amd64 XSAVE 2.7 KB; arm64 SVE/SME 2048-bit, 8.75 KB + 74 KB lazy;
rv64 D + V128, 808 B); arm64 EL2 no longer traps SVE/SME. **K3 is
complete**; the save/restore code and lazy XFD/SME come with user threads
in K6.
- Threads, context switch and kernel threads. Wait queues, and owned wait
  queues with priority inheritance from day one.
- **Scheduling contexts are separate objects from threads** (seL4 MCS
  style). This is the basis for:
  - IPC deadline donation (ext 2), where a server runs on the caller's
    context;
  - budget overrun notification (ext 3);
  - admission control that returns accepted, or refused with a reason,
    against a per-user real-time budget (ext 4);
  - the `frame` intent hint aligned to the display timeline (ext 10).
- Fair plus EDF deadline scheduling. A CPU can be marked reserved for a job
  and is then skipped for everything else (ext 8).
- **Thread state** gets a per-thread extended-state area sized at boot from
  CPUID or the ID registers (XSAVE/AVX-512/AMX with lazy XFD; SVE/SME; RVV).
  Kernel threads never use it; user threads do from K6.

### Trace: the core of requirement 18, staged K3–K6
Todhchai measures its budgets from the first user process, so the trace
comes before M2 (the NeoVectra lesson: budgets declared early, measured
late, and missed). Model: NeoVectra ADR-0049 (kernel trace) and ADR-0050
(`pmu_configure`).
- **Format and cost, fixed in K3:** one ring per CPU of fixed 32-byte
  records (counter timestamp, kind, CPU, thread, two words), written only by
  its own CPU with interrupts masked, so no lock. Oneshot (drop and count)
  or circular. A probe is one relaxed load of the category mask and a
  branch, with arguments evaluated after the branch; an enabled event costs
  under 30 ns. Stopping waits on per-CPU "writing" flags, with no IPI.
  Records never hold kernel addresses: objects get trace ids.
- **K3:** the rings and the `sched` category (switch, block, wake with the
  waker, preempt, migrate), plus `irq`. The self-test checks the probe
  cost on each arch.
- **K4:** the ring memory becomes a VMO, plus the `vm` category (faults,
  VMO commits).
- **K5:** a root Resource carrying only a trace right, ahead of the
  other resources from item 13. `trace_configure` (start, stop, rewind,
  rings, mark) is gated on it.
- **K6:** the syscall entry, marks from user space, the `syscall` category,
  and sampling: a `SAMPLE` record plus frame-pointer `FRAMES`, kernel and
  user, with user frames read by the fault-safe copy. Sampling runs on the
  scheduler tick everywhere, at `sample_hz` on busy CPUs only, so idle
  CPUs stay tickless. PMU overflow sampling writes the same records, and
  per-thread PMU counters are saved at context switch. PMUs: x86
  architectural PerfMon, arm64 PMUv3, rv64 Sscofpmf (where present).
- **K7:** `ipc` (flow ids hashed from the channel's trace id and the txid,
  so a call and its reply share a flow) and `futex` waits.

### K4: VMM phase A (requirement 7)
Progress: **K4a done**: user address spaces (kernel half shared, ASIDs,
switched with threads), VMOs (anonymous, physical, contiguous), mappings
in the root region, demand-paging faults with fixup-based recovery, the
`vm` trace category, trace rings in VMOs. **K4b done**: sub-regions and
reservations with atomic view map/unmap (ext 7), partial unmap, protect,
commit/decommit, contiguous VMOs with an address limit and a boot-time
pool (loaning still to come), cache ops and cache policy changes, the RAM
deny list for physical VMOs, memory accounts with pressure and
device-local/pinned VMOs (ext 6), a sparse page list. **K4c done**
(decided 2026-10-09): protection keys where the hardware has them (amd64
PKU; arm64 POE detected only, until a target has it) give per-thread JIT
write toggling; elsewhere a JIT uses dual RW/RX views; W^X holds for every
other mapping. K4 is complete apart from page loaning and phase B
(copy-on-write clones).
- **VMOs:** anonymous, physical, contiguous, and **device-local**
  (BAR/VRAM/pinned). Device-local VMOs are accounted to the owning process
  for the combined CPU+GPU budget, never paged or evicted, and the budget
  sends a pressure packet (ext 6, F-109). The accounting fields go in from
  the first VMO.
- **VMARs:**
  - Reservations, with atomic map-view and unmap-view inside a reservation
    (ext 7, F-218).
  - Commit and decommit.
  - Per-thread W^X toggling inside an entitled reservation. Candidate
    mechanisms: amd64 PKU, arm64 POE, or per-thread page tables. Choose one
    before the VMAR API is frozen.
- **User address spaces:** the kernel-half top-level entries are allocated
  up front and shared, so later kernel mappings appear in every address
  space.
- Page faults with fault recovery, and huge pages. Copy-on-write clones
  (phase B) follow; the pager comes after M2.

### K5: Kernel objects (requirement 8)
Progress: **K5 done**: objects with koids, signals and observers; handle
tables with rights and generations; events; object_wait_one/many and
async waits; ports with user packets, cancel, and kernel packet sources
for budget overruns (ext 3) and memory pressure (ext 6); VMO and resource
objects; trace_configure gated by the tracing resource, rings handed out
as read-only VMOs (the trace plan's K5 step). Not yet: the counter
waitable at a value (item 15) and the display timeline (ext 1), which
the observer design leaves room for (per-observer triggers), and
interrupt/timer packets (with those objects).
- Handles (`~Copyable` in Swift), rights, koids, dispatchers (built on
  `Ref<T>`), signals and observers, and `object_wait_one/many/async`.
- **Ports** carry packets for IRQs, timers, signals and ext 3 overrun
  notifications. This is the "one wait" model.
- The signal machinery should also serve the **counter waitable at a value**
  (item 15) and the **display timeline** (ext 1), so both are ordinary
  dispatchers later.

### K6: Syscalls and user mode (requirement 9)
Progress: **K6a done**: user mode on all three arches (amd64 SYSCALL/
SYSRET + swapgs, arm64 EL0 vectors + svc, rv64 sscratch swap + ecall),
syscall dispatch, user faults and preemption, fault-recovering copies, a
built-in user test program; null syscall ~40 ns under KVM (budget 100).
**K6b done**: SMEP/SMAP, PAN, SUM discipline with protection faults
refused; range-checked user copies; object syscalls (handles, signals,
waits, events, ports, VMOs, trace_configure with user marks); the
`syscall` trace category; a C user test program built with user flags.
**K6c done**: the vDSO (clock without a syscall:
~13 ns vs 62 under KVM) with the time, topology and power pages (ext 9),
seqlocked and read only; user counter access; the kernel/user build
split (`croi_user_binary`, `CROI_USER_CFLAGS`). The vblank page (ext 1)
joins the same mechanism with the display driver. **K6d done**: user
FP/SIMD state switched with threads (XSAVE, Neon/SVE, F/D/RVV), user code
built for the baseline ISA with FP/SIMD. Deferred: lazy AMX through XFD and SME streaming
mode (neither available under QEMU TCG; both stay disabled/trapped), and
per-thread SVE vector lengths. **K6e done**: tick sampling (busy CPUs
only, idle tickless) with kernel and user frame-pointer stacks, PMU
per-thread counters and overflow sampling (Intel/AMD, PMUv3, SBI +
Sscofpmf), `pmu_configure`. The Intel backend awaits an Intel machine.
**K6 is complete.** Next: K7 (IPC and processes).
- Syscall entry/exit per arch, user-copy with fault recovery, and SMAP, PAN
  and SUM discipline.
- **vDSO** plus the shared read-only pages: clock, topology and power
  (ext 9), and vblank (ext 1).
- User FP/SIMD context switching from day one: lazy XFD for AMX, SVE/SME,
  and RVV (rv64 user space is `rv64gcv`). This revisits the arm64
  `TPIDRRO_EL0` and rv64 `sscratch` uses in exception entry.
- **Build:** split each arch's CMake configuration into a kernel set (no FP,
  today's global flags) and a user set (SIMD on). Today's flags are global
  per build tree, so they need to move onto targets first.

### K7: IPC and process objects (requirements 10, 11)
Progress: **K7a done**: job, process, thread and VMAR objects and their
syscalls (create, start, exit, kill, info, vmar allocate/map/unmap/
protect/destroy), per-process handle tables and address spaces with the
vDSO, last-thread teardown (handle cycles broken), interruptible waits for
kill. **K7b done**: channels (handle transfer,
calls with kernel txids, peer closed), eventpairs, object_get_info, the
`ipc` trace category with flow ids shared by call and reply
(`croi_flow_id` in ipc.h), and IPC deadline donation (ext 2) through
owned call queues. **K7c done**: futexes (wait/wake/requeue,
owners with inheritance, wake_single_owner, get_owner) and timer objects
with slack (zero for deadline profiles). **K7d done**: exception channels (thread,
process, job chain; HANDLED with rewritten registers, TRY_NEXT,
THREAD_EXIT) and job policy (deny, kill, exceptions, inheritance).
**K7 is complete.** Next: K8 (userboot and bootfs).

- Channel, event, eventpair, port, timer (absolute deadline plus slack), and
  futex with an owner for PI.
- Job, process and thread objects, exceptions and job policy.

### K8: userboot + bootfs (requirement 12): the M2 exit test

### After M2 (requirements 13–19 and the remaining extensions)
- Resources (MMIO, IRQ, IO port, root) and interrupt objects (port-bound,
  virtual, MSI/MSI-X per queue). The ext 5 fast path is exposed here.
- BTI/PMT and IOMMUs. SMMUv3 has Fuchsia reference code. VT-d, AMD-Vi and
  the RISC-V IOMMU need designs from their specs.
- FIFO, counter (ext), stream, socket, clock and debuglog. Debuglog may come
  earlier, since the M2 exit test prints over it.
- Pager, IOB or SPSC ring VMOs with futex doorbells, and debug syscalls.
  The trace core is pulled ahead of M2 (see "Trace").
- Todhchai M4 needs **ext 1** (display timeline) and **ext 4** (admission
  with a reason). Their foundations are in K2, K3 and K5.

## Review: board requirements (2026-10-09)

Todhchai's requirements gained notes from scouting the Orange Pi 6 Plus
(CIX Sky1) and Radxa Dragon Q8B (SC8280XP), which follow the amd64
reference machine. Each new point was checked against Zircon
(`../fuchsia`, pinned revision) to separate reusable designs from real
extensions.

**Zircon already has a design; follow it**
- **SMC from user space:** `zx_smc_call` with an SMC resource. Zircon scopes
  by SMCCC service-call number (OEN), not by function-ID range as the
  requirement says. The SCMI call on the Sky1 (`0xc2000001`) is a SiP call,
  so an OEN-scoped resource grants every SiP call. croi can scope by
  function-ID range, which is a small, deliberate extension.
- **VMO cache maintenance:** `zx_vmo_op_range` with `CACHE_SYNC`, `CLEAN`,
  `CLEAN_INVALIDATE` and `INVALIDATE`, plus the vDSO's `zx_cache_flush`.
  Zircon gates invalidate-only behind a debugging option, because it can
  discard data and expose stale memory. Clean+invalidate covers DMA from a
  non-coherent device. Keep that gate.
- **Physical VMOs for firmware carve-outs:** Zircon's root-resource filter
  denies MMIO resources that overlap RAM. croi's PMM already leaves reserved
  types out, so carve-outs only need to stay non-RAM in the handoff.
- **Thread-direct IRQ wakeup (ext 5):** `zx_interrupt_wait` already blocks a
  thread on an interrupt object and wakes it straight from the handler, with
  no port. ext 5 is mostly this. What's new would be scheduling-context
  handoff on the wakeup, which should be stated if it's meant.
- **Capacity-aware scheduling (item 5):** Zircon has a per-CPU processing
  rate, deadline utilization normalized per CPU, an energy model, and
  `zx_system_set_performance_info`. The rate is set from user space. Not
  in Zircon: admission (it has none; "TODO: shed load") and CPPC.
- **DBG2 console:** Zircon's acpi_lite parses DBG2 (16550 only). Its uart
  library has a Qualcomm GENI driver to study for the Q8B.
- **Contiguous pools:** Zircon has no kernel boot pool. It uses *page
  loaning*: a decommitted contiguous VMO lends its pages to the system and
  reclaims them on commit. A contiguous VMO created at boot plus loaning is
  the Zircon-shaped answer to the Q8B fragmentation problem, without
  wasting the pool.

**Genuine gaps (Zircon has nothing, or only a stub)**
- **Contiguous allocation with a physical address limit** (Q8B scan-out
  below 4 GiB). Trivial in croi's PMM: add it with K4's contiguous VMOs.
- **BTI properties:**
  - an IOVA window and a DMA address width;
  - a per-device memory type (Normal WB or Normal NC, never Device);
  - firmware identity regions (IORT RMR, DMAR RMRR);
  - leaving firmware-owned or hypervisor-policed IOMMUs alone;
  - VT-d and AMD-Vi.

  Zircon's SMMU BTI has a fixed window, no width and no memory-type
  control, and a stub BTI.
- **Interrupt affinity as policy:** Zircon's GICv3 can't set affinity (all
  SPIs go to CPU 0), and x86 MSIs go to the BSP. croi already routes
  nothing without an explicit affinity (K2a). Item 13 exposes it.
- **GICv3 MSI (ITS):** unimplemented in Zircon (`PANIC_UNIMPLEMENTED`).
  Already in croi's plan for the drivers phase.
- **Deep idle and wake timers:**
  - Zircon uses WFI for ordinary idle, a static PSCI suspend state, and a
    simple MWAIT governor on x86. It has no general broadcast timer, and no
    ARAT check on x86.
  - A deadline-aware idle governor with an always-on wake timer (ext 11) is
    new.
  - So is a CPPC frequency floor (ext 12); Zircon has only x86 HWP requests.
- **SError:** Zircon only counts it. Delivering a recoverable SError to the
  faulting process is new. croi currently panics on any SError.
- **GIC errata, the SBSA generic watchdog, board quirks:** none in Zircon
  beyond a devicetree-described watchdog. croi is ACPI-only, so kernel-level
  board rules need a data channel, i.e. handoff v4 from an ESP file keyed
  on SMBIOS / SoC ID. The rules cover the console access width, the
  watchdog refresh method, and IOMMUs to leave alone.

**Cross-cutting: AML.** `_CPC` (capacity, CPPC registers) and `_LPI` (idle
states) are AML, and croi's kernel doesn't run AML: Todhchai's interpreter
is in user space. Capacity, idle states and frequency-floor registers
therefore come from the user-space power service through privileged
calls, as Zircon's `zx_system_set_performance_info` does. Until then the
kernel uses only safe defaults:
- capacity from the core type;
- shallow idle (WFI/HLT, where per-CPU timers keep running);
- no frequency floor.

**What this changes in the plan**
- **K2 follow-ups (done):**
  - x86 ARAT recorded;
  - the GTDT's SBSA watchdog enabled and refreshed (`croi.watchdog=off`),
    with the Sky1's refresh method available;
  - the DBG2 console fallback (`loader.console=dbg2`);
  - the arm64 SError policy (corrected errors continue; the rest is fatal
    from the kernel).

  The watchdog and SError paths are unverified on hardware: QEMU has
  neither.
- **K3:**
  - Each CPU has a capacity (processing rate) from day one: a core-type
    default, overridable from user space. EDF admission, with a reason,
    counts budget in capacity-scaled time.
  - Admitted deadline work publishes a per-CPU wake-latency bound and a
    frequency-floor request. Only the hooks for now; enforcement comes in
    KP.
- **K4:**
  - contiguous VMOs with an address limit and alignment;
  - a boot-time contiguous reservation path, with page loaning later;
  - VMO cache ops: x86 `clflushopt`, arm64 `dc`, rv64 Zicbom;
  - physical VMOs checked against a RAM deny list.
- **KP, power (new, after K3; needs the user-space power service):**
  - an idle governor using `_LPI`-derived states, bounded by K3's latency
    bounds;
  - an always-on wake timer (MMIO generic timer, or a board timer such as
    the Sky1's GPT), and knowing which CPUs it can wake;
  - a CPPC minimum-performance floor.
- **Drivers phase:**
  - an SMC resource scoped by function-ID range;
  - BTI with window, width and memory type;
  - RMR/RMRR identity maps and leave-alone IOMMUs;
  - a BTI without an IOMMU, as a recorded trust decision;
  - VT-d first;
  - ITS and AIA MSIs;
  - interrupt affinity on interrupt objects.
- **Board bring-up:**
  - handoff v4 board rules;
  - a GENI UART;
  - GIC erratum checks keyed on IIDR.

## Shared read-only pages

ext 1 (next vblank per output), ext 9 (topology and power) and the vDSO
clock all want kernel data that user space reads without a syscall. Design
them as one mechanism in K2, used in K6:
- versioned pages with a sequence counter for consistent reads;
- the clock parameters written once;
- topology written at boot;
- power state and vblank updated by the kernel.

## Conventions shared with Todhchai

Most of these already hold in croi (see CLAUDE.md):
- Swift 6.4, with strict memory safety as an error
- typed throws, `~Copyable`, `Span`, `InlineArray`, `Atomic`
- `@c @implementation` across the C boundary, and typed C23 enum constants

Still to do:
- the kernel/user CMake flag split (K6);
- pinning the Fuchsia reference revision. `../fuchsia` is at
  `e8b19ec722db74727411b941cf3cd5d1fae5dfc8` (2026-10-09). Zircon's object
  layer is partly in Rust, and those versions are often the better model for
  `~Copyable` Swift.
