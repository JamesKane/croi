# croi roadmap

croi's first consumer is Todhchai (`../todhchai`). Its kernel requirements
are in `../todhchai/docs/croi-requirements.md` (items 1–19 and extensions
ext 1–10), and its milestone M2 ("croi reaches user space") was croi's
first big target, reached on 2026-10-10 (K8c). Its M3 (native tier 0)
closed the same day on croi's K9; M4 (native desktop v0) is next: K10
(agreed with Todhchai). This file orders croi's work so those needs are designed in
early, not bolted on later. Reviewed against the requirements on
2026-10-09 and re-synced on 2026-10-10.

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

## Budgets against Zircon (tools/zircon-bench)

When croi misses a budget, the question is whether the target is
attainable with Zircon's design at all. tools/zircon-bench runs m2's
bench, ported to Zircon at croi's reference pin, under the same VM on the
same machine, interleaved with croi's boots (README there: setup,
`compare.py`, and the rule for reading a missed budget). Every m2 budget
croi misses is mirrored there; one croi meets needs no mirror.

Figures at 6e93cf0, KVM, AMD Ryzen 7 9700X, six interleaved rounds on a
busy host (load 6.5-7.5), so patterns, not measurements. Medians:

| Budget (target) | croi | croi, no idle poll | Zircon | Zircon, no mitigations |
|---|---|---|---|---|
| `syscall.null` (100 ns) | 33 ns | 34 ns | 39 ns | 33 ns |
| `ipc.channel_call` (1 µs) | 1.45 µs | 1.39 µs | 2.24 µs | 2.04 µs |
| `port.wake_median` (2 µs) | 1.86 µs | 6.16 µs | 5.94 µs | 5.77 µs |
| `timer.wake_error_p99` (100 µs) | 26 µs | 35 µs | 1.84 ms | 2.02 ms |

Decisions (2026-10-10, agreed with Todhchai):
Accepted by Todhchai (2026-10-10): port wake is recorded as a
QEMU-with-polling figure until measured on hardware, and IRQ-wait wake is
judged on hardware only (Todhchai's edu driver reports ~12.7 µs under KVM
as information).

- **`channel_call`, 1 µs: neither kernel meets it.** croi is 0.6-0.8 µs
  faster than Zircon, so Zircon is no evidence the target is attainable
  under KVM. The target stays as a hardware target; under KVM the
  1.6 µs ceiling (m2's limit) guards against regressions. Before any IPC
  rework, measure on hardware and trace the round trip (the candidates
  in K8c's notes above), rather than tuning blind.
- **`port.wake_median`, 2 µs: croi meets it only through idle polling**
  (`croi.idle_poll_us`, 200 µs by default under a hypervisor, 0 on
  hardware). Without polling croi and Zircon are level at ~6 µs: an IPI
  and a HLT exit under KVM. The budget depends on that mechanism; on
  hardware (no polling) it is unmeasured. Any change to the polling
  default is a change to this budget.
- **`timer.wake_error_p99`, 100 µs: croi meets it; Zircon misses it by
  ~20x** (errors spread over 0-2 ms, unexplained: not slack, pinning, the
  sleeper's profile or the TSC-deadline timer). croi without polling had
  one 1.5 ms boot too, so late wakes of a halted vCPU under host load are
  the suspect. Polling helps here as well.
- **`syscall.null`**: met by both; Zircon's mitigations cost ~6 ns.
- **`process.spawn_to_main`, 200 µs: croi meets it (~50 µs)**, so it is
  not mirrored. **`irq.wait_wake_median`, 5 µs** is a hardware target
  (KVM: ~12 µs, the wakeup IPI exiting); it needs hardware, not a KVM
  comparison.

## Status against the requirements

| # | Item | Status |
|---|---|---|
| 1 | Handoff: bootfs, GOP framebuffer, command line | **Done** (K1, K8b): handoff v3, Zircon's bootfs format |
| 2 | Interrupt controllers, tickless timer, monotonic clock | **Done** (K2). ITS and AIA set up with the first MSI driver |
| 3 | PMM (contiguous, reclaim), heap, slab | **Done**; ACPI-reclaim memory is never the PMM's (user space reads the tables, K9b) |
| 4 | Threads, wait queues, PI owned wait queues, timers | **Done** (K3) |
| 5 | Scheduler: fair + EDF | **Done** (K3c); profiles are objects since K8c |
| 6 | SMP: AP bring-up, IPIs, TLB shootdown, per-CPU data | **Done** |
| 7 | VMM phase A: VMARs, VMOs, faults, cache policy, huge pages | **Done** (K4, K7a VMARs) |
| 8 | Handles, rights, koids, dispatchers, signals, waits | **Done** (K5) |
| 9 | Syscalls, user-copy, vDSO, user FP/SIMD | **Done** (K6) |
| 10 | Channel, port, event(pair), futex with owner, timer | **Done** (K7b, K7c) |
| 11 | Job, process, thread, exceptions, job policy | **Done** (K7a, K7d) |
| 12 | userboot + bootfs | **Done** (K8b) |
| 18 (core) | ktrace rings, categories, user marks, tick and PMU sampling, per-thread PMU counters | **Done** (K3–K6, see "Trace" below) |
| 13 | Resources, interrupt objects, MSI | **Partial**: resources and physical VMOs (K9a), interrupt objects (K9c), MSI/MSI-X on amd64 (K9d). The GICv3 ITS and the IMSIC are left |
| 14 | BTI/PMT and IOMMUs | **Partial**: BTI/PMT without an IOMMU, contiguous VMOs, BTI properties (K9e). IOMMUs after M3 |
| 15–19 | FIFO/counter/stream/socket/clock/debuglog, pager, rings, debug syscalls | After M3, except debuglog (K8a) and exception channels (K7d). Item 17 needs nothing from croi |
| 20 | Firmware data for user space (ACPI tables and op regions, GOP framebuffer) behind resources | **Done** (K9b) |

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
**K7 is complete.**
**K8a done**: debuglog (objects, ring, dumper thread, syscalls 110-112),
`lib/elf` shared by the loader and kernel, `ProgramLoader` (ELF into a
process with a processargs bootstrap message), the C user runtime and
Embedded Swift user programs (`croi_user_program`); the boot test runs a
Swift program end to end. **K8b done**: bootfs (`tools/mkbootfs.py`,
pages adopted into a VMO), userboot in Embedded Swift starting
`userboot.next` from bootfs with processargs; boot tests wait for its
report. **K8c done**: bin/m2 runs the exit test on all three arches and
measures the budgets; `boot-smoke-kvm` enforces them (see K8c below).
**M2 is reached.**

- Channel, event, eventpair, port, timer (absolute deadline plus slack), and
  futex with an owner for PI.
- Job, process and thread objects, exceptions and job policy.

### K8: userboot + bootfs (requirement 12): the M2 exit test
Todhchai's M2 exit: userboot starts a tier 0 Embedded Swift process from
bootfs, which creates a channel pair, passes a VMO across, waits on a port
with a deadline timer and prints over debuglog, on all three arches in
QEMU; the kernel and IPC budgets (Todhchai performance.md §2) are measured
from croi's trace and met under KVM. Zircon's userboot (Rust at the pinned
revision) is the model; croi's is Embedded Swift like the rest.
- **K8a: debuglog and user Swift.** Log object (type 12) with
  `debuglog_create/write/read` over a kernel record ring that the console
  drains. A user build of Embedded Swift (`croi_user_swift`: its own
  swiftc command with the user flags, as `croi_user_binary` is for C) and
  a minimal user runtime in `user/lib` (mem*, stack guard, `putchar` over
  debuglog, `posix_memalign`/`free` over a VMAR). Programs are ELF
  executables from here on. Test: a Swift program printing over debuglog.
- **K8b: bootfs and userboot.** Zircon's bootfs format (directory of
  name, offset, length; page-aligned data) built by `tools/mkbootfs.py`
  into `esp/croi/bootfs.img`. The kernel makes a VMO that adopts the
  CROI_MEM_BOOTFS pages and starts userboot (an ELF in the kernel image)
  with K8a's `ProgramLoader`: handles (root job, root resource, bootfs
  VMO, vDSO VMO, debuglog) and the command line as its environment. userboot finds `userboot.next=` in bootfs, loads its
  ELF (text mapped from the bootfs VMO, data copied, bss zeroed), and
  starts it in a new process under the root job with a processargs
  message of its own.
- **K8c: the exit test and the budgets.** The M2 program (Embedded Swift)
  does the exit test above. A bench program in bootfs measures from the
  trace: `channel_call` round trip with donation (< 1 µs), port wake from
  another core (< 2 µs) and real-time wake error (p99 < 100 µs), next to
  K6's null syscall (< 100 ns); `boot-smoke-kvm` enforces them.
  **Done** (`user/m2`): profile objects (type 25, `profile_create`,
  `object_set_profile`), trace rings readable from user space, idle
  polling for cross-core wakes. Measured under KVM (2026-10-10, six
  runs): null syscall 32–36 ns, port wake median 1.70–1.80 µs, wake
  error p99 27–46 µs, all enforced. `channel_call` is 1.38–1.44 µs, above
  its 1 µs target: accepted for now and enforced against a 1.6 µs
  ceiling so it can't regress. The round trip is ~11k instructions with
  no single hot spot; candidates are word-size user copies, a per-CPU
  heap cache, no CallRecord allocation per call, fewer lock round trips
  in read/write, and a direct-switch fast path. Port wake p99 is noisy
  (2.6–77 µs: host scheduling of the vCPUs) and only the median is
  enforced. To revisit with Todhchai.

### K9: Todhchai M3, native tier 0 (requirements 7's syscalls, 13, 14 without an IOMMU, 20)
Todhchai's M3 (`../todhchai/docs/milestones/M3.md`) moves its services
onto croi, then adds devmgr, ACPI, PCI, virtio and a framebuffer console.
M3a–M3e are done on croi as it stands (M3e, N0's boot on a ramdisk,
runs on croi's head in Todhchai's `td ci`). M3f onwards need K9:

| Todhchai step | Needs from croi |
|---|---|
| M3f devmgr, ACPI, PCI over ECAM | K9a (MMIO, IO port resources), K9b (firmware data), K9c (interrupts) |
| M3g virtio-blk, Taisce on it | K9a, K9c, K9d (MSI), K9e (BTI with no IOMMU, contiguous VMOs) |
| M3h framebuffer console | K9b |
| M3i other virtio devices | as M3g |
| M3j exit and budgets | K9f |

Order (agreed with Todhchai, 2026-10-10): resources first, then item
20, which is small, needs only K9a's resources, and on its own unblocks
M3h's console and the ACPI half of M3f; the BTI and VMO-for-DMA work
matters only once virtio-blk lands.

Decided by Todhchai for M3: amd64 boots under KVM in `td ci`; arm64 and
rv64 build. croi still runs every K9 self-test on all three arches in
QEMU, and each arch's controller work below is in scope, but where an
arch's piece is large and only needed later (the GICv3 ITS, RISC-V
IMSIC MSIs, SMC) it may land after amd64's.

Test device: QEMU's `edu` PCI device (all three machines) has INTx, MSI
and DMA, so the self-tests can cover a real interrupt, an MSI and a
pinned DMA without a driver stack. The boot tests add it.

- **K9a: resources and the VMO syscalls.** **Done** (2026-10-10): as
  below, plus I-cache sync after the kernel loads code and for
  CACHE_SYNC (arm64 hardware needed it; QEMU hid it), RESERVED memory
  ranges allowed under MMIO resources (PCIe ECAM sits in one on q35),
  and UNCACHED mapped as device memory. Details in CLAUDE.md. Zircon's resource kinds and
  numbers (MMIO 0, IRQ 1, IOPORT 2, SMC 4, SYSTEM 5) with ranges
  (`resource_create(parent, options, base, size, name)`, EXCLUSIVE, a
  child inside its parent's range; root mints all). An MMIO resource
  over RAM the PMM owns is refused, as Zircon's root filter does.
  Syscalls over K4's kernel-only VMOs: `vmo_create_physical` (an MMIO
  resource covering the range; default cache policy uncached-device),
  `vmo_set_cache_policy` (unmapped VMOs only), `vmo_op_range` (COMMIT,
  DECOMMIT, ZERO, and the CACHE_SYNC/CLEAN/CLEAN_INVALIDATE ops;
  INVALIDATE stays behind a debug option, as Zircon's), and the vDSO's
  `cache_flush`. User cache maintenance needs EL0/U-mode access opened:
  arm64 SCTLR_EL1.UCI (and UCT for the line size), rv64 senvcfg.CBCFE
  where Zicbom exists; amd64 `clflush(opt)` already works in user mode.
  amd64 `ioports_request`/`release` (IOPORT resource): a per-process I/O
  permission bitmap, loaded into the TSS at a switch between processes
  (Zircon's design; lazily, so a process without ports costs nothing).
  Also the deltas left: zero-size VMOs (Zircon allows them) and the
  tracing resource's base, which is 6 in croi and 14 (TRACING_BASE) in
  Zircon at the pin (6 is MEXEC): Todhchai's native tracer (M3e) asks
  for it by number.
- **K9b: firmware data for user space (item 20).** **Done** (2026-10-10):
  as below. The loader also fills holes in the framebuffer's range (q35's
  GOP framebuffer is a PCI BAR outside every firmware range), physical
  VMOs over firmware memory are always cached (the physmap maps it
  cached; other policies ACCESS_DENIED), and the boot data handle is
  Zircon's PA_VMO_BOOTDATA. Details in CLAUDE.md. Zircon tells user
  space about firmware through ZBI items (RSDP, SMBIOS, framebuffer,
  memory ranges), and its drivers read ACPI tables through physical VMOs
  under an MMIO resource. croi has no ZBI, so:
  - userboot gets one more startup handle: a read-only VMO of ZBI-format
    items (`ZBI_TYPE_ACPI_RSDP`, `ZBI_TYPE_SMBIOS`, `ZBI_TYPE_FRAMEBUFFER`,
    `ZBI_TYPE_MEM_CONFIG` for the firmware ranges), built from the
    handoff (agreed with Todhchai). Todhchai writes its own reader from
    the format (its principle: no third-party code), so a croi header
    (`include/zbi.h`, like processargs.h) gives every layout exactly:
    the item header and its alignment, and the RSDP, SMBIOS, FRAMEBUFFER
    (base, size, stride, format) and MEM_CONFIG payloads.
  - Physical VMOs over firmware ranges (ACPI reclaim and NVS, runtime
    services, reserved MMIO) are allowed with an MMIO resource that
    covers them; RAM the PMM owns stays refused. ACPI reclaim stays wired
    for good instead of going to the PMM after parsing, since user space
    reads the tables there (they are small).
  - The GOP framebuffer: a physical VMO under an MMIO resource over the
    CROI_MEM_FRAMEBUFFER range, mapped write-combining by the console.
    The kernel stops drawing to it once userboot runs (today only the
    boot self-test draws).
  - AML's SystemIO regions use K9a's IO ports; PCI config uses ECAM
    (MCFG ranges, MMIO) and, on amd64, ports 0xCF8/0xCFC.
- **K9c: interrupt objects (item 13).** **Done** (2026-10-10): as
  below with the PLIC on rv64 (QEMU's default; APLIC later), syscalls
  140-146. The boot test uses each machine's RTC rather than `edu`'s
  INTx (whose GSI comes from `_PRT`, i.e. user space): CMOS (amd64, edge),
  PL031 (arm64, level), goldfish (rv64, level). The budget isn't met
  under KVM yet: 11-18 us median from the fire to the woken thread, the
  interrupt on CPU 1 waking a thread on another CPU (VM exits for the
  wakeup IPI); measure on hardware. Details in CLAUDE.md. Zircon's calls:
  `interrupt_create(resource, vector, options)` (an IRQ resource
  covering the vector; EDGE/LEVEL and HIGH/LOW modes; VIRTUAL),
  `interrupt_bind` (to a port: a packet per interrupt, re-armed by
  `interrupt_ack`; a level interrupt stays masked until then),
  `interrupt_wait` (thread-direct, no port: ext 5's path; the
  scheduling-context handoff on wakeup is the extension, the hook
  exists), `interrupt_trigger` (virtual), `interrupt_destroy`. Every
  interrupt object gets a CPU affinity from policy (item 2), which Zircon
  lacks: an extension call, `interrupt_set_affinity(interrupt, cpu
  mask)` with a typed status (agreed with Todhchai; devmgr sets it per
  driver host from policy). Until it is set, the boot CPU. Controllers: amd64 IOAPIC pins (GSI
  numbering; MADT overrides for ISA IRQs; PCI INTx modes come from `_PRT`,
  i.e. user space), arm64 GICv3 SPIs (IROUTER for affinity), rv64
  APLIC/PLIC (QEMU virt with ACPI). Budget: IRQ to the driver thread
  running < 5 µs (Todhchai, on hardware; measured in QEMU from the irq
  and sched trace).
- **K9d: MSI and MSI-X (item 13).** **Done on amd64** (2026-10-10):
  as below, syscalls 147/148. Plain MSI's affinity is NOT_SUPPORTED (its
  driver programs the capability; MSI-X moves per vector). The test uses
  edu's MSI and virtio-blk's MSI-X table. ITS and IMSIC remain. Details
  in CLAUDE.md. Zircon's `msi_allocate(resource
  MSI_BASE 11, count)` and `msi_create(msi, options, id, vmo, offset)`
  (the MSI-X table in a BAR VMO, programmed by the kernel; masking
  through the table), each vector an interrupt object with its own
  affinity. amd64 first: LAPIC message address/data, vectors allocated
  per CPU. arm64 needs the GICv3 ITS (device and collection tables,
  LPIs; Zircon panics here), rv64 the IMSIC: designed now, implemented
  when those arches boot Todhchai (virtio-pci falls back to INTx there
  meanwhile).
- **K9e: BTI with no IOMMU, PMTs, contiguous VMOs (item 14, part).**
  **Done** (2026-10-10): as below, syscalls 150-156. The properties are
  set with croi's `bti_set_properties`, which only narrows (devmgr sets
  them, then grants the BTI). Details in CLAUDE.md.
  `iommu_create(resource IOMMU_BASE 8, DUMMY)`, `bti_create(iommu, 0,
  bti_id)`, `bti_pin(bti, options, vmo, offset, size, addrs)` returning a
  PMT, `pmt_unpin`, `bti_release_quarantine`, `vmo_create_contiguous(bti,
  size, alignment_log2)`. Pinned pages get a pin count: decommit and
  teardown wait for or refuse them, as Zircon's do. The BTI's croi
  properties are designed in now even with no IOMMU: a DMA address width
  (pins and contiguous allocations above it refused; contiguous VMOs use
  K4's address limit), an IOVA window (with no IOMMU, a physical range
  check) and the device's memory type. Creating a no-IOMMU BTI is a
  recorded trust decision: a debuglog record names the process and BTI
  id. VT-d (first, for the reference machine), AMD-Vi, SMMUv3 and the
  RISC-V IOMMU follow after M3.
- **K9f: M3's budgets and the rest.** **Done** (2026-10-10), except the
  SMC resource (after M3): `croi.selftest=off`, monotonic time from
  kernel entry (userboot at ~80 ms under KVM with self-tests off),
  spawn to main ~50 µs under KVM (200 µs budget; it was 0.8-2.4 ms
  until amd64 stopped sending an all-CPU TLB shootdown on every map),
  and croi's timing discipline after
  Todhchai's (CLAUDE.md "Timing discipline", tools/bench.py): budgets
  are reported by the boot and judged by the bench against per-machine
  history; ctest no longer fails on a busy host. Kernel entry to the text console
  < 100 ms: today every boot runs the whole self-test suite first, so a
  `croi.selftest=` option (off for Todhchai boots, on in croi's tests)
  and a trace mark at userboot start. Spawn to `main` < 200 µs: Todhchai
  measured 178 µs on croi's head under KVM (2026-10-10, its N0 boot),
  so this is a watch item: croi's own boot test gets a trace mark around
  `process_create` through the first user instruction. The SMC
  resource scoped by function-ID range (arm64; not needed in QEMU) can
  land here or after M3.

Todhchai's other M3 budgets (ring submit, futex wake with no sleeper,
cached reads, live queries, resident memory) are user-space work.

### K10: Todhchai M4, native desktop v0 (agreed with Todhchai, 2026-10-10)

Todhchai's M3 closed with every budget met on a quiet machine. M4 is the
native desktop: a compositor on the framebuffer with CPU composition,
input, audio on virtio-sound then HDA, the SDK's native backend, and
crash survival (exit: M1's minimal and synth programs run natively and
meet their numbers; the compositor nests two deep and can be killed).
K10 is what M4 needs from croi and no more (decided: M5's groundwork,
hardware bring-up, IOMMUs, the ITS/IMSIC and croi's own carry-overs come
after). Everything stays in QEMU; as in K9, each step lands as a commit
Todhchai can consume, with its self-test on all three arches and its
budget lines (CLAUDE.md "Timing discipline"). Order a to f, agreed:
M4 brings the compositor up before audio, and K10c must land before the
synth program can meet its zero-underrun exit; K10e may move to the end
if K10 splits (nothing else in M4 depends on it).

- **K10a: counters (item 15, ext).** **Done** (2026-10-10): syscalls
  160-165, counter wake ~1.6 µs under KVM (limit 2 µs). Zircon's counter object (type 34:
  `counter_create`, `add`, `read`, `write`; POSITIVE / NON_POSITIVE
  signals) plus the extension: waitable at a value. `counter_wait(counter,
  value, deadline)` blocks until the counter reaches `value`, and a
  port registration delivers one packet when it does, so a compositor's
  acquire fences and a client's release values (desktop.md: a counter
  value on the buffer's own timeline) need no polling. These become
  Vulkan timeline semaphores in M5, so the semantics follow them
  (monotonic use, 64-bit values). Budget: signal to a waiter on another
  core running, as port wake.
- **K10b: the display timeline (ext 1).** **Done** (2026-10-10): syscalls
  170-173, object type 48, display system resource base 16; vblank to
  the waiting deadline thread ~10 µs median, p99 under 40 µs (KVM). A kernel object a display
  driver advances (`timeline_advance` with the vblank's hardware
  timestamp, under a display resource), counting vblanks; waitable at a
  value like a counter and through ports; and a read-only page per
  timeline (the shared-pages scheme, ext 9: last vblank time, period,
  count, a synthesized flag) that clients read without a syscall. On the
  bare GOP framebuffer (no vblank interrupt) the kernel advances it from
  a timer at the mode's rate, marked synthesized, so M4 runs on it in
  QEMU (agreed: the kernel ticks it, not the driver, whose timer would add
  a wakeup and its jitter to every frame). The GOP display driver sets
  the refresh period and gets the synthesized flag; a real vblank driver
  later advances the same object from its interrupt. The synthetic tick
  runs only while something waits on the timeline or a frame-intent
  thread is aligned to it, so a static screen makes no wakeups (K10f).
  Budget: vblank (or synthetic tick) to the waiting thread running.
- **K10c: wakeups that carry a deadline (ext 5, ext 10).** **Done**
  (2026-10-10): `object_set_profile` on an interrupt, counter or timeline
  (WRITE, a deadline profile) makes it lend that deadline to each thread
  it wakes, from the wakeup until the thread next blocks (no admission:
  it joins the thread's own as inheritance does); the
  `CROI_PROFILE_ALIGN_TIMELINE` option with a timeline handle puts a
  deadline thread's periods on its vblanks. An interrupt
  object, a timeline wait and a counter wait can name a scheduling
  context: the thread they wake runs on it at once, with its deadline,
  as `channel_call` donation does (ext 2). Frame intent (stored only
  today) aligns a deadline thread's periods to a display timeline's
  vblanks, so the compositor's latch thread and a game's frame thread
  wake for the frame, not for an independent period. Audio DMA's
  interrupt to its thread is the same path.
- **K10d: kernel-only extensions to user space.** **Done** (2026-10-10):
  `thread_bind_overrun_port` (122), `job_set_cpu_reservation` (108, CPU
  system resource), CROI_INFO_THREAD_TRACE and CROI_INFO_DEBUGLOG (the
  dumper's printed count, not flow control: writers pace to it). Budget overruns to a
  port (ext 3) for a deadline thread's own profile; CPU reservation for a
  job (ext 8, gated by a system resource); a thread's trace id through
  `object_get_info` (Todhchai's ask: joining its user trace with croi's
  sched and ipc records); and debuglog flow control, or a readable
  position of the last record the dumper printed, so Todhchai's trace
  export through the debuglog stops pacing itself by a guess (its M3f).
- **K10e: power control (M4's shutdown < 500 ms).** **Done**
  (2026-10-11): syscall 180, power.h; the kernel's part ~20-180 µs under
  KVM (`power.shutdown_kernel`, limit 10 ms), the debuglog's drain to the
  console reported apart (`power.log_drain`, ~25 ms of queued lines over
  KVM serial; on a 115200-baud UART a backlog costs far more, so M4's
  shutdown path should keep its last words short). amd64's plain SHUTDOWN
  is NOT_SUPPORTED: \_S5 comes from user space, as agreed. Croi's boots
  now end with `userboot.shutdown=poweroff`. Zircon's
  `system_powerctl` under the power system resource: shutdown and reboot.
  amd64 takes the S5 sleep-type values from user space's AML (Zircon's
  ACPI_TRANSITION_S_STATE) and writes PM1a/b control (FADT), with the
  reset register for reboot; arm64 PSCI SYSTEM_OFF / SYSTEM_RESET; rv64
  SBI SRST. Budget: the call to QEMU exiting.
- **K10f: an idle system makes no wakeups (M4: 0 per second).** croi's
  periodic kernel work audited and made event-driven or gated (the SBSA
  watchdog refresh, the debuglog dumper, the trace sampler's timer,
  idle polling's re-arming), and a budget line counting each CPU's
  wakeups over an idle window in the lean boot.

Not in K10 (after M4 unless Todhchai's order says otherwise): VMO
children for the dynamic linker, FIFO/socket/stream, the pager and debug
syscalls (M5 and later); GPU memory accounting syscalls (ext 6, with the
GPU in M5); VT-d and the other IOMMUs; the GICv3 ITS and RISC-V IMSIC;
the idle governor and frequency floor (ext 11, 12: hardware); rv64
targeted shootdowns with ASIDs; timer objects cancelled on last close;
the SMC resource.

### After M3 (requirements 14–19 and the remaining extensions)
- IOMMUs: VT-d first, then AMD-Vi, SMMUv3 (Fuchsia reference code) and
  the RISC-V IOMMU, with the BTI properties above, RMR/RMRR identity
  maps and leave-alone IOMMUs.
- FIFO, counter (ext), stream, socket and clock (debuglog is done).
- Pager, and debug syscalls (debugger channels, process memory access,
  suspended start).
- Todhchai M4 needs **ext 1** (display timeline) and admission with a
  reason (**ext 4**, done in K8c's profile objects). Their foundations
  are in K2, K3 and K5.
- The `channel_call` budget (1 µs; ~1.4 µs at K8c), revisited with
  Todhchai.

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
