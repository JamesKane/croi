# croi vs Zircon: known divergences

Every place croi's behaviour or ABI knowingly differs from Zircon at the
reference pin (`../fuchsia` at `e8b19ec722db74727411b941cf3cd5d1fae5dfc8`),
gathered from CLAUDE.md and docs/roadmap.md and maintained alongside them:
a change that adds, removes or settles a divergence updates this file too.
Each entry gives its kind: **deliberate** (a croi design choice), **not
yet** (a Zircon feature croi hasn't implemented) or **quirk parity** (croi
matches the pinned tree where upstream docs or expectations say otherwise).

## Scope

- **Boot and discovery** — UEFI + ACPI only (no devicetree, no other boot
  protocol, no ZBI around the boot image). Kind:
  deliberate. Impact: board ports; firmware data reaches user space as
  below.
- **No hypervisor** — Zircon's guest/VCPU objects are out of scope. Kind:
  deliberate. Impact: anything wanting virtualization.

## ABI and syscall packing

- **Direct syscalls, croi's numbers** — user programs call the kernel by
  croi's own syscall numbers (number in rax / x16 / a7) rather than through
  Zircon's vDSO entry points (croi's vDSO has a few functions, such as
  cache_flush, and the shared pages). Kind: deliberate. Impact: binaries built for Zircon
  don't run unmodified.
- **Six argument registers: packed handles** — calls with more arguments
  pack `handle | options << 32`: vmar_map and friends, resource_create
  (`parent | options << 32`), bti_pin (`bti | options << 32`, `vmo |
  addrs_count << 32`, eight arguments in six registers),
  pager_query_dirty_ranges (`pager | vmo << 32`, actual and avail through
  one `size_t out[2]`). Kind: deliberate. Impact: library wrappers.
- **channel_read capacities and actuals** — `bytes | handles << 32` packed
  into one argument each. Kind: deliberate. Impact: library wrappers.
- **vmar_unmap_handle_close_thread_exit is a syscall** (75) — Zircon's is
  vDSO code; a failed close raises an undefined-instruction exception (as
  Zircon's vDSO traps). Kind: deliberate. Impact: none for callers.
- **`croi_iovec_t`** — capacity is `uint64_t` (the ABI headers have no
  `size_t`). Kind: deliberate. Impact: identical layout on 64-bit.
- **CPU_STATS returns a count** — object_get_info CROI_INFO_CPU_STATS fills
  as many records as fit and returns the count, without actual/avail
  pointers (CLAUDE.md K10f; other topics take Zircon's actual and avail as
  fifth and sixth arguments since K13e). Kind: deliberate. Impact: m2 and
  stats tools.
- **Test-only syscall 6** (`TestHooks`) — croi's self-test hook. Kind:
  deliberate. Impact: none outside tests.

## Handles, objects and IPC

- **interrupt_wait cancelled by its handle** — closing the handle a thread
  waits through cancels its interrupt_wait (as object waits do); Zircon
  cancels on the last handle. Kind: deliberate. Impact: drivers closing
  duplicates.
- **Interrupt object lifetime** — destroyed with its last reference
  (listed under "Differences from Zircon", K9c). Kind: deliberate. Impact:
  low.
- **Missing families** — IOB, restricted mode, membarrier, the
  ktrace/sampler syscalls (croi has its own trace and PMU calls). Kind:
  not yet. Impact: ports of Fuchsia code using them.

## Sockets, streams and FIFOs

- **Socket buffer size** — receive buffers are rings of up to 64 pages,
  256 KiB; Zircon's hold 264160 bytes of mbufs. Kind: deliberate. Impact:
  low; capacity visible in ZX_INFO_SOCKET.
- **Datagram header accounting** — each datagram's 4-byte length lives in
  the ring and counts against capacity. Kind: deliberate. Impact: slightly
  fewer small datagrams fit.
- **Socket semantics** — the pinned tree's Rust dispatcher, error orders
  and signal rules with its quirks. Kind: quirk parity. Impact: none vs
  the pin.
- **Stream size lock** — one global Mutex serializes stream-size changes;
  Zircon has a per-VMO StreamSizeManager. Kind: deliberate. Impact:
  contention only under many concurrent appenders.
- **Streams never grow their VMO** — a write at or past the VMO's end is
  OUT_OF_RANGE, one reaching it is cut short. This matches the pinned tree
  (it records the RESIZE right / can_resize and never reads it), although
  upstream docs say streams grow resizable VMOs. Kind: quirk parity.
  Impact: none vs the pin; filesystems resize the VMO first.

## VM and VMOs

- **Snapshot child of a shrinking parent** (K13h) — croi's child reads
  zeros past the cut only while the parent stays that small; Zircon clamps
  the child's parent limit permanently. Kind: deliberate (simplification).
  Impact: low; within at-least-on-write semantics. Fix: a per-child parent
  limit clamped at shrink.
- **UNBOUNDED VMOs** — NOT_SUPPORTED in vmo_create and pager_create_vmo.
  Kind: not yet. Impact: matters if Fuchsia filesystem code (which uses
  unbounded pager VMOs) is ported; moderate work (near-2^64 sizes, an
  overflow audit).
- **K11a children copy on first touch** — a SNAPSHOT_AT_LEAST_ON_WRITE
  child copies a parent page at its first read or write (allowed by "at
  least on write"; no hidden nodes); DECOMMIT on a child is NOT_SUPPORTED
  and ZERO writes zeros into a copy. Kind: deliberate. Impact: more memory
  for read-mostly children.
- **Full snapshots copy at creation** (K14g) — SNAPSHOT (and
  SNAPSHOT_MODIFIED wherever Zircon makes it a full snapshot) copies every
  page the parent shows in range when the child is created; Zircon moves
  them into a hidden node both sides share until written. Contents and
  isolation are the same; the copy costs memory and time up front, and a
  write racing the creation may land in the snapshot on one page and not
  on another (Zircon's is atomic). The parent itself stays a plain VMO,
  so it can still DECOMMIT (Zircon's parent, now under a hidden node,
  can't). Kind: deliberate (no hidden nodes). Impact: memory for large
  snapshots that are mostly never written; racy writers only.
- **Aliases' mapping counts** (K14g) — ZX_INFO_VMO's num_mappings for a
  slice or reference of an anonymous VMO is 0: mappings of it are listed
  on its root. Kind: simplification. Impact: diagnostics only.
- **arm64 UNCACHED** — vmo_set_cache_policy maps UNCACHED and
  UNCACHED_DEVICE both as device memory, so arm64 gets Device-nGnRE where
  Zircon uses Device-nGnRnE for UNCACHED. Kind: deliberate. Impact: arm64
  drivers relying on UNCACHED being Normal-NC-like or nGnRnE.
- **CACHE_INVALIDATE** — vmo_op_range answers NOT_SUPPORTED; Zircon offers
  invalidate-only behind a debugging option (croi keeps the gate closed).
  Kind: deliberate. Impact: none for correct DMA code (use
  CLEAN_INVALIDATE).
- **No zero intervals** — ZERO on a pager VMO zeroes pages in place
  (Zircon makes a zero interval); WRITEBACK_BEGIN's IS_ZERO is a no-op
  (K13h's grown space is the one dirty-zero range). Kind: not yet. Impact:
  memory use for sparse zeroed files.
- **KMEM_STATS fields** — total, free, wired, heap, vmo, mmu, other and
  (K14a) the reclaim and discardable fields filled; loaned, ipc, cache,
  slab, zram and reclaim_disabled are 0. Kind: not yet. Impact: memory
  dashboards.
- **Page loaning** — as Zircon's for decommitted contiguous VMOs (K14f),
  plus croi's boot contiguous pool lending its free pages; on by default
  (`croi.ppb.loan=off`; Zircon's kernel.ppb.loan and borrow-on-mru
  default off). Borrowing happens at aging passes (Zircon: on the MRU
  sweep), and taking a page back always evicts (Zircon's
  replace-on-unloan copy isn't there). Kind: deliberate. Impact: none.

## Reclamation (K14a)

- **No page queues** — Zircon keeps every page on one of its queues (an
  8-generation LRU ring, isolate lists); croi keeps a list of reclaimable
  VMOs and an age in each page record, and walks them. Ages, the two
  protected newest ages, DONT_NEED first and the watchdog's oldest-only
  eviction behave as Zircon's. Kind: deliberate (simplification). Impact:
  eviction and aging cost grows with reclaimable pages, not with need.
- **Aging only while reclaimable VMOs exist** — no aging thread wakeups on
  a machine with no pager or discardable VMOs (M4's idle machine); no
  active-ratio early aging (the 15 s maximum interval only). Kind:
  deliberate. Impact: low.
- **Single pages** — evicted page by page; Zircon takes the aligned 64 KiB
  block around a chosen page. Kind: deliberate. Impact: more READ
  requests on refault.
- **Discardable VMOs age like pager pages** — reclaimable once unlocked,
  by their first page's age; with Zircon's default options (anonymous
  reclaim off) a discardable VMO is never discarded. Kind: deliberate (the
  documented behaviour). Impact: discardable memory actually goes.
- **Discard takes pages before unmapping** — croi takes a discarded VMO's
  (or an evicted page's) pages under its lock, then unmaps, then frees
  (Zircon unmaps under the VMO lock, which croi's aspace -> vmo lock order
  doesn't allow); a write through a stale mapping in that window is lost,
  which for a discard only matters if a LOCK lands in the same window.
  Kind: deliberate. Impact: very low.
- **OOM** — reboot only (`croi.oom.reboot_timeout_ms`, Zircon's 50 s
  default), and no HaltToken, so the wait is never cut short; no jobkill
  behaviour, no ZX_PROP_JOB_KILL_ON_OOM; no continuous eviction mode; no
  delayed CAN_WAIT allocations below OOM. Kind: not yet. Impact: a system
  that wants to survive OOM by killing jobs.
- **Hints on snapshot children** — DONT_NEED / ALWAYS_NEED through a child
  of a pager VMO apply to the pager VMO's pages over the whole range,
  including pages the child has already copied. Kind: deliberate. Impact:
  none.
- **Not yet**: compression (zram), zero-page dedupe, page-table reclaim,
  high-priority VMOs (`reclaim_disabled_bytes` 0), memory
  stall watching. Kind: not yet.

## Pager

- **One packet per request** — each new range gets its own READ/DIRTY
  packet; Zircon keeps one request in flight per VMO. Kind: deliberate.
  Impact: a pager may see more, smaller packets.
- **No withdrawal** — a packet isn't taken back when its request resolves
  before the pager reads it. Kind: deliberate. Impact: pagers must
  tolerate stale requests (supplying already-present pages is harmless).
- **Source holds its port** — a pager VMO's source keeps a reference to
  its port. Kind: deliberate. Impact: the port lives as long as the
  source.
- **DECOMMIT on a pager VMO** — NOT_SUPPORTED. Kind: not yet. Impact: low.
- **Eviction** — clean pages are never evicted (dropped only at detach);
  ALWAYS_NEED / DONT_NEED hints have no effect. Kind: not yet. Impact:
  page-cache memory isn't reclaimed under pressure.

## Clocks and time

- **Reference ticks are monotonic ns** — the counter's 32.32 scale has no
  u32/u32 ratio, so reference_ticks_to_synthetic equals
  reference_to_synthetic and clock_get_details' tick fields are ns. Kind:
  deliberate. Impact: code converting raw ticks itself.
- **BOOT is monotonic** — no suspend, so the boot timeline equals the
  monotonic one (timer_create takes BOOT too; interrupt timestamps are
  monotonic). Kind: deliberate (until suspend exists). Impact: none today.
- **No UTC clock from the kernel** — PA_CLOCK_UTC is defined but nothing
  creates one; it is the time service's to create. Kind: deliberate.
  Impact: user space must provide UTC.

## Tasks, exceptions and debugging

- **Syscall restart in the kernel** — for suspension Zircon wakes
  interruptible waits with INTR_RETRY and its vDSO re-issues the call;
  croi's programs call the kernel directly, so the kernel rewinds the PC
  over the syscall for the restartable waits (nanosleep, wait_one,
  wait_many, port_wait, vmo_read, futex_wait, interrupt_wait,
  counter_wait, readv, readv_at). Other waits (channel_call, exceptions)
  suspend when they end. Kind: deliberate. Impact: debuggers see the PC at
  the syscall instruction.
- **Debugging syscalls option** — process_write_memory and debug-register
  / single-step writes need `croi.debug_syscalls=on` (implied by
  `croi.test=1`), else NOT_SUPPORTED. Kind: deliberate (croi's option
  name). Impact: debugger setup on croi boots.
- **process_exit marks the caller killed** before it exits, so its
  THREAD_EXITING doesn't wait for a debugger. Kind: quirk parity (Zircon
  kills it too). Impact: none.
- **rv64 debugging** — single-step NOT_SUPPORTED, debug registers a u32
  written and ignored. Kind: quirk parity (Zircon's). Impact: none vs the
  pin.
- **SError** — kernel SErrors other than corrected ones panic; delivery of
  a recoverable SError to the faulting process is planned (Zircon only
  counts SErrors). Kind: deliberate / not yet. Impact: arm64 hardware
  errors.
- **Thread info** — page-fault and lock-contention time aren't tracked.
  Kind: not yet. Impact: profilers.

## Drivers, interrupts, DMA and IOMMUs

- **AMD and RISC-V IOMMU types are croi's** — iommu_create types
  CROI_IOMMU_TYPE_AMD (0x10000, croi_iommu_desc_amd_t) and
  CROI_IOMMU_TYPE_RISCV (0x10001, `{ register_base }`); Zircon has
  neither. Kind: deliberate. Impact: drivers on AMD or RISC-V machines.
- **ARM_SMMU means SMMUv3 (and v1/v2 by IORT node)** — Zircon's type and
  descriptor, but Zircon's driver is SMMUv2 from a devicetree. Kind:
  deliberate. Impact: none for callers.
- **Intel VT-d** — the pinned Fuchsia has no Intel driver; croi's follows
  the specification behind Zircon's ABI. Devices no driver claims stay
  pass-through (Zircon blocks them). Kind: deliberate / not yet. Impact:
  unclaimed devices can DMA anywhere.
- **No-IOMMU BTI warning** — creating one writes a WARNING debuglog record
  (a recorded trust decision). Kind: deliberate. Impact: log noise only.
- **amd64 MSI destinations** — without interrupt remapping, APIC ids above
  255 are NOT_SUPPORTED. Kind: not yet (remapping lifts it). Impact:
  large machines without VT-d/AMD-Vi remapping.
- **Plain MSI affinity** — interrupt_set_affinity is NOT_SUPPORTED for
  plain MSI (the driver owns the capability); MSI-X moves per vector.
  Kind: deliberate. Impact: drivers of MSI-only devices.
- **arm64 MSIs work** — croi drives the GICv3 ITS; Zircon's is
  unimplemented (panics). Kind: deliberate. Impact: none (strictly more).
- **SMC resources by function ID** (K13i) — an SMC resource is a range of
  SMCCC function IDs; Zircon's is a range of 6-bit service call numbers
  (OEN), so a Zircon-style resource (base 0x02, size 1: SiP) doesn't
  carry over. Kind: deliberate (an OEN grants every SiP call). Impact:
  drivers and devmgr making SMC resources.
- **smc_call's conduit** — the FADT's PSCI conduit (HVC where firmware
  runs at EL2); Zircon always issues SMC. Kind: deliberate. Impact: none
  where firmware is at EL3.
- **The kernel's PSCI calls refused** — CPU_ON/OFF/SUSPEND, MIGRATE,
  SYSTEM_OFF/RESET/RESET2/SUSPEND, CPU_FREEZE, CPU_DEFAULT_SUSPEND can't
  be reached through smc_call or an SMC resource, even the root's; Zircon
  doesn't filter. Kind: deliberate. Impact: none (system_powerctl).
- **Qualcomm yielding calls** — behind `croi.smccc_qcom=on` (Zircon's
  boot option arm64_smccc_qcom). Kind: parity, croi's option name.
- **powerctl on amd64** — plain SHUTDOWN is NOT_SUPPORTED: user space
  passes \_S5's sleep types with ACPI_TRANSITION_S_STATE; suspend,
  hotplug, PL1 and bootloader/recovery reboots are NOT_SUPPORTED on every
  arch. Kind: deliberate / not yet. Impact: power services.

## Boot and loading

- **No ZBI** — bootfs.img is Zircon's bootfs format without a ZBI around
  it; firmware data (RSDP, SMBIOS, framebuffer, memory map) reaches
  userboot as a ZBI-format container in PA_VMO_BOOTDATA built by the
  kernel. Kind: deliberate. Impact: user space reads `include/zbi.h`
  items only.

## croi additions (not in Zircon)

- `counter_wait` / `counter_wait_async` — wait for a counter to reach a
  value (packet type 0x82).
- Display timelines (type 48, syscalls 170-173) — vblank counters with a
  read-only page; synthetic on the GOP framebuffer.
- Deadline-carrying wakeups — object_set_profile on interrupts, counters
  and timelines; CROI_PROFILE_ALIGN_TIMELINE.
- Admission refusal reasons — profile_create / object_set_profile report
  why a deadline profile was refused (Zircon has no admission).
- channel_call donation — the reader of a call inherits the caller's
  profile until the reply.
- `thread_bind_overrun_port` (122) — budget-overrun packets (type 0x80).
- `job_set_cpu_reservation` (108) — CPUs reserved for a job.
- `interrupt_set_affinity` (146) — route an interrupt to a CPU mask.
- `bti_set_properties` (156) and CROI_INFO_BTI_PROPERTIES — narrow a BTI's
  address width, window and memory type.
- CROI_INFO_THREAD_TRACE, CROI_INFO_DEBUGLOG — trace id of a thread; the
  dumper's printed count.
- `trace_configure`, `pmu_configure` (51) — croi's per-CPU trace rings,
  sampling and PMU counters.
- Topology and power pages in the vDSO's shared pages.
- `croi_flow_id` — user-computable flow ids joining channel calls and
  replies in traces.
- Display system resource (base 16).
- Memory accounts and pressure packets (ext 6) — kernel-only today.
- `croi.kill_watch=1` — lockup report after task_kill.
