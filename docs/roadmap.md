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

## Status against the requirements

| # | Item | Status |
|---|---|---|
| 1 | Handoff: bootfs, GOP framebuffer, command line | **Done** (K1): handoff v3. The bootfs format itself comes with userboot (K8) |
| 2 | Interrupt controllers, tickless timer, monotonic clock | Todo (K2) |
| 3 | PMM (contiguous, reclaim), heap, slab | **Done**, except ACPI-reclaim memory, which stays wired until ACPI parsing is finished |
| 4 | Threads, wait queues, PI owned wait queues, timers | Todo (K3) |
| 5 | Scheduler: fair + EDF | Todo (K3) |
| 6 | SMP: AP bring-up, IPIs, TLB shootdown, per-CPU data | **Partial**: AP bring-up and per-CPU data are done. IPIs and TLB shootdown are in K2 |
| 7 | VMM phase A: VMARs, VMOs, faults, cache policy, huge pages | **Partial**: ArchAspace (map/unmap/protect/query, large pages), the kernel aspace, and the cache policy (K1; rv64 Svpbmt pending) exist. The rest is in K4 |
| 8 | Handles, rights, koids, dispatchers, signals, waits | Todo (K5) |
| 9 | Syscalls, user-copy, vDSO, user FP/SIMD | Todo (K6) |
| 10 | Channel, port, event(pair), futex with owner, timer | Todo (K7) |
| 11 | Job, process, thread, exceptions, job policy | Todo (K7) |
| 12 | userboot + bootfs | Todo (K8) |
| 13–19 | Resources/interrupt objects, BTI/PMT + IOMMU, FIFO/counter/stream/socket/clock/debuglog, pager, rings, ktrace, debug syscalls | After M2 (K9+), with the designs constrained below |

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

### K4: VMM phase A (requirement 7)
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
- Handles (`~Copyable` in Swift), rights, koids, dispatchers (built on
  `Ref<T>`), signals and observers, and `object_wait_one/many/async`.
- **Ports** carry packets for IRQs, timers, signals and ext 3 overrun
  notifications. This is the "one wait" model.
- The signal machinery should also serve the **counter waitable at a value**
  (item 15) and the **display timeline** (ext 1), so both are ordinary
  dispatchers later.

### K6: Syscalls and user mode (requirement 9)
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
- Pager, IOB or SPSC ring VMOs with futex doorbells, ktrace and the sampler,
  and debug syscalls.
- Todhchai M4 needs **ext 1** (display timeline) and **ext 4** (admission
  with a reason). Their foundations are in K2, K3 and K5.

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
