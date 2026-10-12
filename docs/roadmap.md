# croi roadmap

croi's first consumer is Todhchai (`../todhchai`). Its kernel requirements
are in `../todhchai/docs/croi-requirements.md` (items 1–19 and extensions
ext 1–10), and its milestone M2 ("croi reaches user space") was croi's
first big target, reached on 2026-10-10 (K8c). Its M3 (native tier 0)
closed the same day on croi's K9; its M4 (native desktop v0) needed K10
(agreed with Todhchai), done on 2026-10-11 with M4's kernel budgets met
(idle desktop: 0 wakeups in 60 s). M5 (Vulkan over virtio-gpu) is next
for Todhchai; its asks on croi so far are covered by existing calls
(BAR sub-range physical VMOs with a per-VMO cache policy, counter_wait_async). This file orders croi's work so those needs are designed in
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
| 13 | Resources, interrupt objects, MSI, SMC | **Done**: resources and physical VMOs (K9a), interrupt objects (K9c), MSI/MSI-X on amd64 (K9d), the GICv3 ITS (K12h), RISC-V AIA (K12i), `smc_call` (K13i) |
| 14 | BTI/PMT and IOMMUs | **Done** (K9e, K12): VT-d, AMD-Vi, SMMUv3, SMMUv2 (unverified on hardware), the RISC-V IOMMU, interrupt remapping |
| 15 | FIFO, counter, stream, socket, clock, debuglog | **Done** (K8a, K10a, K13b, K13c, K13f) |
| 16 | Pager | **Done** (K13d, K13h), with eviction of clean pages under memory pressure (K14a) |
| 17 | Rings | Nothing needed from croi; Zircon's IOB not implemented |
| 19 | Debug syscalls | **Done** (K7d, K13g); a crashed process is kept frozen by its exception handler holding the exception (Fuchsia's Limbo pattern, tested) |
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
- **K10f: an idle system makes no wakeups (M4: 0 per second).** **Done**
  (2026-10-11): `idle.wakeups` is 0 on all three arches, lean and full
  (m2 counts every CPU's interrupts over 500 ms through Zircon's
  ZX_INFO_CPU_STATS). Fixed: stale timer hardware after cancel, the
  sampler's lapsing tick, deadlines rounded down to the counter, the
  self-test deadman. The SBSA watchdog refresh stays (every 20-25 s,
  `croi.watchdog=off` for none). Also fixed: a timeline waiter whose
  value was reached between its check and the tick being armed slept to
  its deadline (rv64 m2 hangs under host load). Self-tests that
  synchronized on fixed sleeps (futex checks 163-165, K10d's spinners,
  the sched early-wake round) wait for their threads now.
  After K10, from Todhchai's M4 bring-up (2026-10-11): amd64's SYSCALL
  return skipped the kill check, so a killed thread retrying failed calls
  ran until an interrupt caught it in user mode (mode 17 now kills a
  syscall retry loop); long TSC deadlines under KVM fired early by the
  host clock's skew (~30 ppm: measured against the HPET and armed later,
  so a 60 s sleep is one wakeup); process teardown and timer objects
  blocked instead of spinning on yield (a deadline thread lost a period
  per spin); `croi.kill_watch=1` reports kills that don't finish. First
  bench history recorded (bench/history/brimstone.tsv, 75d8a0c). croi's
  periodic kernel work audited and made event-driven or gated (the SBSA
  watchdog refresh, the debuglog dumper, the trace sampler's timer,
  idle polling's re-arming), and a budget line counting each CPU's
  wakeups over an idle window in the lean boot.

### K11: Todhchai M5, Vulkan and tier 1 foundations (agreed with Todhchai, 2026-10-11)

Todhchai's M5 (`../todhchai/docs/milestones/M5.md`) needs nothing new
from croi for the GPU path: BAR windows are physical VMOs with a per-VMO
cache policy, fences are counter_wait_async, DMA is M3's BTIs. Its tier 1
step (M5k: pthreads over futexes, ELF TLS, a dynamic linker) and the
loader that loads the client driver as a shared object need these, in
this order (confirmed; M5k is late in M5, so none blocks Todhchai before
then). Already there for M5k: user TLS (amd64 REGISTER_FS by the thread
itself, as Fuchsia's libc; arm64/rv64 thread pointers saved per thread)
and futex_requeue (K7c).

- **K11a: VMO children** (requirement 7, phase B). **Done** (2026-10-11):
  `vmo_create_child` (48) with SNAPSHOT_AT_LEAST_ON_WRITE, NO_WRITE: an
  anonymous child that reads as its parent (recursively) and copies each
  page in at its first touch; Zircon's rights. All Todhchai's dynamic
  linker needs (writable segments; NO_WRITE children over a library's
  range of bootfs or a file). SLICE and strict SNAPSHOT stay
  NOT_SUPPORTED until something needs them.
- **K11b: position-independent programs and randomness.** **Done**
  (2026-10-11): handoff v5 carries EFI_RNG_PROTOCOL bytes, the kernel's
  ChaCha20 CPRNG (with RDSEED/RDRAND, RNDR, counter jitter), syscalls
  181-182; static PIEs at random bases in ProgramLoader and userboot
  (vmar_allocate SPECIFIC, writable segments as K11a children of
  bootfs); userboot, m2 and the Swift test program are PIEs. ET_DYN
  loading in ProgramLoader and userboot (today "a PIE (not yet)"), with
  a randomized load base (ASLR) from `cprng_draw` (Zircon's
  zx_cprng_draw: RDRAND/RNDR/Zkr-seeded, for libc's stack guard, hash
  seeds and ASLR) and `cprng_add_entropy`.
- **K11c: ext 6 to user space** (GPU memory accounting: accounts,
  device-local VMOs, pressure packets, kernel-only since K4c). Deferred
  (agreed): under Venus the GPU's memory is the host's; it comes with a
  real GPU's driver.

Not in K11 (after M5 unless Todhchai's order says otherwise):
FIFO/socket/stream, the pager and debug syscalls (M5 and later); GPU
memory accounting syscalls (ext 6, with the GPU in M5); the IOMMUs (K12
below); the GICv3 ITS and RISC-V IMSIC;
the idle governor and frequency floor (ext 11, 12: hardware); rv64
targeted shootdowns with ASIDs; timer objects cancelled on last close;
the SMC resource.

### K12: IOMMUs (requirement 14; ahead of Todhchai's hardware milestones)

- **K12a: Intel VT-d.** **Done** (2026-10-11). Zircon's ABI
  (iommu_create INTEL with zx_iommu_desc_intel_t; the pinned Fuchsia
  has no Intel driver any more, so the driver follows the VT-d
  specification). A unit must be one the kernel's DMAR lists; creating
  it turns translation on with every device pass-through, so stub BTIs
  keep working. bti_create(iommu, 0, bdf) gives the device its own
  domain (legacy-mode second-level tables, 3 or 4 levels) with its RMRRs
  identity mapped; bti_pin maps I/O addresses from the BTI's window with
  the pin's permissions; unpin unmaps and invalidates the IOTLB before
  the VMO gets the pages back. A BTI that goes blocks its device, so its
  quarantined pages are released (with the stub they stay pinned).
  Faults: the fault event MSI, logged and counted. Tested on QEMU's
  intel-iommu with edu's DMA engine (boot test mode 18).
  Not yet (then; queued invalidation and interrupt remapping came in
  K12f): ATS/device TLBs, scopes behind
  bridges, large pages in domains, the boot-time decision for devices no
  driver claims (pass-through today; Zircon blocks them).
- **K12b: AMD-Vi.** **Done** (2026-10-11). croi's iommu_create type
  (0x10000, croi_iommu_desc_amd_t: the IVHD's registers and IVMD unity
  ranges), BTIs as VT-d's on a shared `IoDomain` layer; device table,
  command buffer with completion-wait polling, event log with its MSI.
  Tested on QEMU's amd-iommu (`boot-amd-iommu`). Not yet (interrupt
  remapping came in K12g): IVHD device scopes (a unit covers its segment), ATS, 5/6
  levels, restarting the event log after an overflow. Unverified on
  hardware (this host has an AMD IOMMU, but croi doesn't boot it here).
- **K12c: Arm SMMUv3.** **Done** (2026-10-11). Zircon's ARM_SMMU type
  and descriptor; IORT for SMMUs and requester-to-stream id mappings;
  linear stream table (bypass until claimed), command queue with
  CMD_SYNC, event queue on its wired interrupt; stage-1 domains (one CD,
  ASID per domain) on the shared `IoDomain` layer. Tested on QEMU's virt
  SMMUv3 with edu (mode 18 on arm64). Not yet: two-level stream tables
  (a linear one is 64 bytes per stream id: 4 MiB for QEMU's 65536),
  stage 2, queue MSIs, ATS/PRI, named-component stream ids.
- **K12d: Arm SMMUv1/v2 (MMU-500).** **Done** (2026-10-11), unverified on
  hardware. AbyssBSD's Q8B drivers are the reference (Fuchsia's arm_smmu
  never implemented its enforced mode): firmware's unit, used only
  through free entries and banks, CBAR 0x1f300 only, bank before S2CR
  before SMR, the caller's stream pairs (Zircon's id format plus a
  second pair). Tested on a RAM stand-in of the Q8B's apps SMMU. On the
  way: SMMUv3 units firmware left on are refused. Not yet: the GPU's
  split TTBR1 and per-process TTBR0 (Adreno; a GPU-specific interface),
  units firmware left disabled, extended stream ids, global faults, the
  Sky1's firmware-enabled SMMUv3s with RMRs (a board rule to hand them
  over).
- **K12e: the RISC-V IOMMU.** **Done** (2026-10-11). croi's type with a
  register base from the RIMT (platform or PCIe-based); device directory
  of pass-through contexts (base or extended format), command queue with
  IOFENCE.C, fault queue (polled); first-stage Sv48/Sv39 domains on the
  shared layer. Tested on QEMU's riscv-iommu-pci with edu, both context
  formats. Not yet (MSI page tables came in K12j): interrupts (IMSIC
  MSIs, wired lines), ATS/PRI, process directories, second
  stage. QEMU 10.2 builds no RIMT for its platform IOMMU (`iommu-sys`).
- **K12f: VT-d interrupt remapping.** **Done** (2026-10-11). The
  kernel brings VT-d units up at boot with queued invalidation and, where
  the platform offers it, remaps every IOAPIC pin and MSI through one
  shared table (fixed entries per GSI and per CPU and vector; source ids
  verified for IOAPICs and plain MSIs; compatibility format blocked),
  x2APIC destinations included: MSIs and IOAPIC routes to APIC ids above
  255 work. iommu_create binds boot's units. Not yet: posted interrupts,
  source verification for MSI-X, IOAPIC scopes behind bridges. Bench
  (KVM) boots keep remapping off (QEMU needs a split irqchip for it).
- **K12g: AMD-Vi interrupt remapping.** **Done** (2026-10-11). Units at
  boot; one shared 2048-entry table named by every device entry (an
  MSI-X table doesn't say which device it is, so no source
  verification: VT-d verifies IOAPICs and plain MSIs), IOAPIC indices =
  their vectors, MSI indices allocated with their vectors, 32-bit
  entries or 128-bit GA ones with x2APIC destinations, IASup required,
  enabled only where the IVRS describes every IOAPIC. Tested on QEMU's
  amd-iommu with and without xtsup. Not yet: per-device tables with
  source verification, guest/posted mode.
- **K12h: the GICv3 ITS (arm64 MSIs).** **Done** (2026-10-11). LPIs and
  their tables, collections per CPU, global EventIDs (allocations
  precede devices), DeviceIDs from the IORT (directly or through an
  SMMUv3's stream ids), the MSI-X table's owner found by walking PCI,
  MAPD/MAPTI/MOVI/DISCARD; SMMUv3 domains map the doorbell. Tested on
  QEMU virt (edu MSI, an unmapped event refused, virtio MSI-X, MOVI).
  On the way: mode 11's check 297 (a blocked message) never could fail
  (the interrupt was still masked from the wait before it); fixed, it
  runs for AMD-Vi and the ITS, and QEMU's VT-d turned out to pass
  compatibility-format MSIs whatever CFI says, so VT-d's blocking of
  them is per the specification, unverified. Not yet: GICv4, two-level
  device tables, several ITSs.
- **K12i: RISC-V AIA (rv64 MSIs).** **Done** (2026-10-11). IMSIC files
  per hart (Ssaia CSRs), the APLIC in MSI delivery mode for wired
  interrupts, global identities, MSIs through msi_allocate/msi_create;
  the PLIC stays where there is no AIA. The RISC-V IOMMU now comes up at
  boot (QEMU resets it Off, blocking its devices). Tested on QEMU virt
  with aia=aplic-imsic (`boot-aia`). Not yet: the RISC-V IOMMU's MSI page
  tables (remapping on rv64), IPIs through the IMSIC, guest files, APLIC
  direct mode, several sockets.
- **K12j: claimed devices' MSIs, and the RISC-V IOMMU's MSI page tables.**
  **Done** (2026-10-11). A test that a BTI-claimed device's MSI arrives,
  on every arch (it failed on rv64 first). RISC-V contexts: the
  supervisor files identity mapped (first stage), and with MSI_FLAT a
  flat MSI page table confining MSIs to them. Not yet: identity-level
  isolation on rv64 (MRIF mode or per-device guest files), the second
  stage the MSI tables are mainly for (guests).

### K13: Zircon pieces in Todhchai's order (2026-10-11)

Todhchai's order after M5j: FIFOs, then sockets and streams (stdio and
pipes for ported C programs), then the pager (File.map demand-paged);
none blocks it. A survey of Zircon's syscalls (vdso/*.fidl at the pin)
against croi's (about 88 of Zircon's 199) found these missing families
and objects besides: clock objects (croi has monotonic time only), iob,
debug (process_read/write_memory, task_suspend), restricted mode,
membarrier, SMC, ktrace/sampler (croi has its own trace and PMU calls);
vmar_op_range, object_wait_many, port_cancel_key, handle_close_many,
thread_start_regs, the channel *_etc calls; most info topics (PROCESS,
THREAD, VMO, maps, handle table) and the NAME property.

- **K13b: FIFOs and vmo_replace_as_executable.** **Done** (2026-10-11).
- **K13c: sockets and streams.** **Done** (2026-10-11): Zircon's
  semantics from the pinned tree (its Rust dispatchers), quirks included.
  Socket buffers are 256 KiB page rings (Zircon: 264160 bytes of mbufs);
  datagram lengths are counted in the ring. Streams never grow their VMO
  (the pinned tree records the RESIZE right and never reads it either;
  resizable VMOs came in K13h); one global lock serializes stream-size
  changes where Zircon has a per-VMO StreamSizeManager.
- **K13d: the pager.** **Done** (2026-10-11), in two parts: pager
  objects and VMOs, READ requests (faults, kernel copies, streams,
  commit, pin, snapshot children reading through), supply, FAIL, detach
  and COMPLETE; then dirty tracking (TRAP_DIRTY and DIRTY requests, op
  DIRTY, WRITEBACK_BEGIN/END, query_dirty_ranges, query_vmo_stats, clean
  pages dropped at detach). Not yet (eviction came in K14a): zero
  intervals (beyond K13h's grown space), unbounded pager VMOs.
- **K13e: the small calls.** **Done** (2026-10-11), in two parts:
  object_wait_many, handle_close_many, port_cancel_key, the channel *_etc
  calls, ZX_PROP_NAME; then vmar_op_range and the info topics (PROCESS,
  THREAD, THREAD_STATS, TASK_RUNTIME, JOB, JOB_CHILDREN, JOB_PROCESSES,
  PROCESS_THREADS, VMO, PROCESS_VMOS, PROCESS_MAPS, HANDLE_TABLE).
- **K13f: clock objects.** **Done** (2026-10-11): Zircon's clocks,
  mappable ones included; reference ticks are monotonic ns. A UTC clock
  for user space (PA_CLOCK_UTC) is the time service's to create.
- **K13g: debugging.** **Done** (2026-10-11), in three parts:
  task_suspend and tokens (syscalls restarted in the kernel for the waits
  that can be), process_read/write_memory; debugger channels (process and
  job), PROCESS/THREAD_STARTING and THREAD_EXITING, second chance,
  exception reports; single-step and hardware breakpoints (amd64, arm64).
- **K14a: eviction and reclaim.** **Done** (2026-10-11): page ages from
  accessed bits (arm64 access-flag and rv64 Svade faults set them again),
  an aging pass every 15 s while reclaimable VMOs exist, eviction of clean
  pager pages oldest first (DONT_NEED first, ALWAYS_NEED kept short of
  OOM), DISCARDABLE VMOs (LOCK / TRY_LOCK / UNLOCK, discarded whole),
  Zircon's memory watchdog (levels, one event each through
  system_get_event, eviction at critical, OOM eviction then reboot),
  KMEM_STATS' reclaim fields, committed_change_events. Not yet: jobkill
  at OOM, compression, zero-page dedupe, page-table reclaim, page loaning.
- **K14f: page loaning.** **Done** (2026-10-11), in two parts: lenders (a
  contiguous VMO's decommitted range, the contiguous pool's free pages)
  and taking pages back (faults, COMMIT, pins, accesses, the VMO's end,
  pool allocation); then borrowers (a pager VMO's clean pages, swapped
  onto lent ones by the aging pass, swapped back before a write, a pin or
  ALWAYS_NEED) and their eviction when a lender wants its page. On by
  default (`croi.ppb.loan=off`). Requirement 3's pool no longer holds
  memory idle.
- **Review round 1 (2026-10-12): adversarial review, seven readers by
  area.** Part 1: mapping ceilings for vmar_protect (the vDSO and
  read-only handles' mappings could be made writable), syscall 6 gated to
  test boots, ranged-root ranges that wrap. Part 2 (checks 689-694, each
  but the channel and table fixes seen to fail without its fix): register
  access to a thread parked before its first user entry (live kernel
  stack), emptied page tables freed only after the remote shootdown,
  channel_read takes only a message that fits what it checked, thread
  records pinned while futex/profile code uses them, process_read_memory
  retains under the lock, a failed eager map unmaps what it mapped,
  timer_set under one lock, futex cycles through the waiter refused,
  wrapping or 64-bit-overflowing arithmetic in trace_configure, slice
  op_range, the CBS rule and bti_pin. Not a bug after all: READABLE
  (Channels' read re-checks after clearing). Open, by severity:
  - medium: handle object and
    rights read in two lookups; channel_call txids collide when both ends
    call; futex records leak when a timed-out waiter named an owner;
    SMMU registers grantable before the first iommu_create; no caps on
    port packets, channel queues, async waits; ObjectWait.many leaves
    observers on allocation failure; resource_create overflow (fixed
    with the wrap check).
  - low: the EFI seed isn't wiped from the handoff page or stacks;
    userboot/ElfImage overflow traps on malformed ELFs; PPTT short
    nodes; SMC filter misses SYSTEM_OFF2; arm64 msi_create cleanup
    DISCARDs unmapped events; VT-d bti_create double bind race.
  - not reviewed: the rest of the arch entry code (privileged bits via
    thread_write_state, sysret canonical checks, swapgs paths).
- **K14s: per-process user PAC keys.** **Done** (2026-10-12): each
  address space gets a random APIA key, copied to the CPU's per-CPU
  record at switches and loaded at every return to EL0, so a process
  can't forge another's signed pointers.
- **K14r: guarded user pages.** **Done** (2026-10-12): CROI_VM_PERM_GUARDED,
  the ELF BTI property read by both loaders, croi's arm64 user programs
  and vDSO built with landing pads and run guarded.
- **K14q: arm64 branch target identification.** **Done** (2026-10-12):
  kernel text guarded where FEAT_BTI exists, landing pads from the
  compiler (pac-ret+bti) and in the PMU jump tables, BT1, a self-test that
  takes and recovers a branch target exception. Not yet: guarded user
  pages (an ELF opt-in), per-process user PAC keys.
- **K14p: arm64 pointer authentication.** **Done** (2026-10-12): the
  kernel signs return addresses (pac-ret, APIA) with a random per-boot key,
  user space gets another (swapped at every entry and return), EL2 drops
  untrap PAC, stack walks strip signatures. Swift 6.4 passes
  -Xcc -mbranch-protection=pac-ret through to its code generation (checked
  first). QEMU -cpu max covers it (EL1 and EL2 boots). Not yet: BTI,
  per-process user keys.
- **K14o: cross-CPU port wake, looked at.** (2026-10-12) m2's port wake
  profile (`m2.portwake_profile=1`) puts the ~1.65 us in a dozen steps of
  100-250 ns: the signaller's handle lookup and object retain (cache lines
  the waiter's CPU just wrote: the process's handle-table lock, the
  event's header), the observer, port queue and wake (~350 ns), the
  waiter's switch bookkeeping (~260 ns), XSAVE restore (~110 ns), the
  packet record's release (~140 ns) and copy out. No single cost like
  K14l's or K14n's; keeping user tables loaded across idle measured
  worse, and a lock-free handle lookup needs safe reclamation croi lacks.
  Left as is: ~3.5x Zircon's on this host and under its 2 us budget.
- **K14n: timed wakes under KVM.** **Done** (2026-10-12), from Todhchai's
  report (a 5 ms Task.sleep 20-60 us late; their executor's workers time
  out on one port). m2's wake profile split it: the timer interrupt ~14-20
  us late (KVM waking a halted vCPU) and ~10-20 us from it to user space,
  mostly VM exits at ~4-5 us each. KVM PV EOI (atomic test-and-clear;
  a split one hung half the boots), no disarm of a spent x86 deadline,
  and a learned timer lead under hypervisors: a fair thread's timeout ~3-6
  us late (median) from 15-40, four together 11-13 us from ~20. Bench vs
  1f0ade5: timeline.wake_median 10.6 -> 4.8 us, edf.worst_wake -36%,
  timer.wake_error_p99 -18%, port wake -12%, irq wait -10%. Left for
  Todhchai: one timer sleeper instead of a herd (each extra wake migrates
  by IPI, ~2.6 us).
- **K14m: channel_call, part 2.** **Done** (2026-10-12): out-pointer
  checks inside the mapping a thread's last check found skip the address
  space's lock while its `mapGeneration` holds (three checks per call
  took ~150 ns), and a call's txid and registration share one lock.
  Interleaved (5 boots): channel_call 1352 -> 1230 ns. The IPI paths'
  "copies" from part 1 were the ICR offset 0x300, not copies. Left: the
  XSAVE switch (~130 ns each way), the four syscalls and two switches the
  bench's server loop makes (wait_one, read, write), ~50-80 ns steps of
  locking and signalling between them. Under KVM 1 µs isn't reached;
  further gains need changes of structure (a combined reply-and-wait, as
  Zircon's own servers don't have either).
- **K14l: channel_call, part 1.** **Done** (2026-10-12): m2's IPC profile
  mode (`m2.ipc_profile=1`: per-event gaps and PC samples) found each heap
  free spending ~190 ns in `pmm.page(for:)`, which copied the whole Pmm
  (850 bytes) and then its arena table per arena; the lookups are
  `mutating` now. Interleaved (5 boots): channel_call 1563 -> 1352 ns,
  counter.wake_median 1804 -> 1144 ns, boot.userboot_start 78.9 -> 65.3 ms.
  Left in the call (probes, KVM): three out-pointer checks each taking the
  address space's lock (~150 ns), the XSAVE switch (~130 ns per switch;
  lazy switching is out, LazyFP).
- **K14k: zero intervals.** **Done** (2026-10-12): pager VMOs keep
  Zircon's zero intervals (dirty, awaiting clean, untracked): ZERO, a
  grow and a stream size cut make them, reads copy zeros without
  committing, writes split them, query_dirty_ranges reports them
  (IS_ZERO), WRITEBACK_BEGIN/END hand them back to the pager. An
  UNBOUNDED pager VMO zeroes whole in one step. Fixed on the way: a
  kernel write to an absent page of a grown range looped in prepareWrite.
- **K14j: KASLR.** **Done** (2026-10-12): the loader maps the kernel at a
  random 2 MiB-aligned base below its link address (~2^18 bases on amd64
  and arm64, ~2^15 on rv64) from EFI_RNG_PROTOCOL, the CPU's RNG or (weak,
  said so) the counter; `croi.kaslr=off`. Boots, panics and qemu.sh's
  backtraces name the image's range and link address for symbolizing.
- **K14i: UNBOUNDED VMOs.** **Done** (2026-10-12): vmo_create and
  pager_create_vmo make a VMO of Zircon's MAX_SIZE (2^64 - 64 KiB) whose
  content size is the size asked for; sizes past MAX_SIZE are
  OUT_OF_RANGE. Range operations walk only present pages (`PageList.next`:
  decommit, ZERO, cache ops, resize, detach, writeback, dirty ranges,
  hints), and the stream size zeroes past its new end untracked. Fixed on
  the way: the time self-test's owned-timer probe assumed it could cancel
  before a 2 ms deadline (a loaded TCG host fired some first).
- **K14h: VMO copies under the page's lock.** **Done** (2026-10-12):
  vmo_read/write, streams and process_read/write_memory copied a page
  after dropping its VMO's lock, so a concurrent decommit or eviction
  could free it and another VMO's data be read (or written over). The
  copy now holds the owner's lock without paging in; a user fault drops
  it, pages in and retries.
- **K14g: the other VMO child kinds.** **Done** (2026-10-12): SNAPSHOT
  (copied at creation), SNAPSHOT_MODIFIED (a full snapshot, or under a
  pager the child's own pages copied and the rest read through), slices
  of anonymous VMOs and REFERENCE children (aliases sharing their root's
  pages; references share its sizes and resize it), in Zircon's order of
  checks; clones of anonymous VMOs refuse pinned pages and slices, as
  Zircon's do. Slices of slices count as the slice's children (they were
  the root's). Fixed on the way: a child's first touch copied its
  parent's page after dropping the parent's lock, so a concurrent
  decommit could hand it a freed page.
- **K14e: scheduling-context handoff on interrupt wakeup (ext 5).**
  **Done** (2026-10-11): object_set_profile with CROI_PROFILE_HANDOFF on
  an interrupt admits a deadline context the object owns; the thread
  interrupt_wait wakes runs on it at once (its CPU and deadline) until it
  blocks, and wakeups share the context's budget per period (CBS rule),
  so an interrupt storm is bounded: a spent budget is an overrun on the
  context (reported through thread_bind_overrun_port on the interrupt)
  and the thread carries on on its own profile. Withdrawn when replaced
  or destroyed. K10c's unadmitted lend stays for counters and timelines.
- **K14d: thread_raise_exception.** **Done** (2026-10-11): ZX_EXCP_USER
  to every job debugger up the tree, single shot (each reply ignored),
  Zircon's checks; closed job debugger channels are now pruned whenever
  the list is walked, not only at the next attach.
- **K14c: RELRO.** **Done** (2026-10-11): PT_GNU_RELRO's pages read only
  once relocated, in the kernel's loader and userboot's, checked by the
  programs themselves (user/test/swift, bin/m2: their own mappings through
  PROCESS_MAPS; each fails with its loader's protect removed).
- **K14b: timer queues.** **Done** (2026-10-11): each CPU's timers are a
  list (owned nodes for thread timeouts, timer objects and timelines, so
  arming those never fails; 32 slots stay for the kernel's fixed timers),
  cancellable from any CPU; timer objects cancelled when their last handle
  closes (Zircon's on_zero_handles). Fixed: a 33rd thread blocking with a
  deadline on one CPU panicked the kernel; a superseded timeline timer
  stayed queued until it fired. Interleaved bench (2 x 7 boots per
  profile against 798fff3): everything within noise but
  counter.wake_median, +18% (1449 against 1224 ns). That budget is bimodal
  per boot in both trees with the same modes (~1.2 and ~1.75 us); this
  tree landed in the fast one in 6 boots of 14, 798fff3 in 10. The waiter
  arms no timer (its deadline is infinite), so it looks like a per-boot
  placement or layout effect, not path cost; the recorded history is 1.68
  us and the limit 2 us. Accepted; to be looked at if the slow mode
  dominates in recorded runs.
- **K13j: load balancing.** **Done** (2026-10-11): idle-time work
  stealing of fair threads (Zircon's), from a CPU going idle and an idle
  CPU waking. Interleaved bench: irq.wait_wake_median -60%..-67%, the rest
  within noise. Fixed on the way: a thread moved by `requeue` kept its old
  CPU's vruntime (a ~300 ms stall).
- **K13i: smc_call.** **Done** (2026-10-11): Zircon's call and layouts,
  SMC resources by function-ID range, the FADT's conduit, the kernel's
  PSCI calls refused, Qualcomm's resume protocol behind
  `croi.smccc_qcom=on`.
- **K13h: resizable VMOs.** **Done** (2026-10-11): RESIZABLE for VMOs,
  snapshot children and pager VMOs, vmo_set_size, mapping past the end,
  a pager VMO's grown space as dirty zeros. Still not: UNBOUNDED,
  DISCARDABLE, streams growing their VMO (the pinned tree doesn't either).

### Open items (2026-10-11)

What is still open after K13, gathered from the milestones above, CLAUDE.md's
"Not yet" notes and Todhchai's requirements. Where croi knowingly differs
from Zircon, see docs/zircon-divergences.md.

**Todhchai's requirements and extensions**
- Requirement 3: done (the contiguous pool, and since K14f page loaning,
  which lends its idle pages). Left: ACPI-reclaim memory stays wired, as
  user space reads the firmware tables there for good (K9b).
- Requirement 9: lazy AMX through XFD, SME streaming mode, per-thread SVE
  vector lengths (none available under QEMU TCG).
- Requirement 1: the GENI UART (Q8B); a text console on the framebuffer.
- Extensions: 10 (the frame intent: stored only), 11 and 12 (an idle
  governor and the frequency floor: KP, which needs the power service).

**Zircon pieces not yet in croi**
- VM: done (eviction and reclaim in K14a, the other child kinds in
  K14g, UNBOUNDED VMOs in K14i, zero intervals in K14k).
- IOB, restricted mode, membarrier, the ktrace/sampler syscalls (croi has
  its own).

**Kernel internals**
- amd64 5-level paging, VHE-only arm64 CPUs. (Kernel pointer
  authentication came in K14p, BTI in K14q-K14r, per-process user keys
  in K14s.)
- IOMMUs: ATS, two-level SMMUv3 stream tables, stage 2, posted
  interrupts, source verification for MSI-X, identity-level MSI isolation
  on rv64; SMMUv2 and every unit unverified on hardware.
- Board bring-up: handoff v4 board rules, GIC erratum checks; the
  watchdog and SError paths unverified on hardware; SError delivery to
  the faulting process.
- Budgets: channel_call's 1 µs target (~1.4 µs under KVM).

### K13a (agreed with Todhchai, 2026-10-11): VMO slices and ZERO_CHILDREN

Todhchai's GPU driver host (M5g) hands clients VMOs over windows of
virtio-gpu's shared-memory BAR and must not reuse a window while any
client can still reach it, by handle or by mapping. A handle count
(ZX_INFO_HANDLE_COUNT) misses mappings, so the agreed interface is
Zircon's: the host keeps one physical VMO per window and gives clients
`vmo_create_child` SLICE children (physical parents included: the same
pages and the parent's cache policy, no copy); the parent raises
ZX_VMO_ZERO_CHILDREN when its last child goes (mappings hold children),
which the host waits for (wait_async on its port) before reuse.
ZX_INFO_HANDLE_COUNT (Zircon's topic 19) comes along for parity;
Todhchai won't depend on it. **Done** (2026-10-11), moved ahead of K12g
at the user's call: slices of physical and contiguous VMOs (anonymous
ones NOT_SUPPORTED yet), ZERO_CHILDREN for every child kind, the handle
count (tables and messages in flight), and vmo_create_physical's
rights corrected to Zircon's (WAIT was missing: the host couldn't have
waited on its windows).

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
