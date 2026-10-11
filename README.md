# croi

**A Zircon-style microkernel written in Embedded Swift.**

croi (Irish *croí*, "heart") rewrites Fuchsia's Zircon kernel in Embedded
Swift 6.4. It keeps Zircon's object model, syscall semantics and ABI
constants, but replaces C++ with Swift's ownership model. The kernel has no
ARC and no garbage collection. It uses `~Copyable` types, typed throws and
`Span`, and every unsafe operation is marked under
`-strict-memory-safety`. C and assembly are used only where Swift can't be:
entry code, trap vectors, context switches, user-copy fixups and the
compiler runtime.

It boots on **amd64, arm64 and rv64** from UEFI with ACPI and runs SMP on
all three. userboot starts Embedded Swift programs from a Zircon-format
bootfs, in processes that talk over channels and ports. Its first
consumer, the Todhchai OS, runs on croi natively: its launcher and
services, devmgr with ACPI and PCI, drivers for virtio devices with
interrupts and DMA, a file system on virtio-blk, and a framebuffer
console. Performance targets come from Todhchai and are measured with
croi's own trace, under KVM on amd64 (a shared machine, so typical
figures):

| Measurement | Today | Budget |
|---|---|---|
| Kernel entry to userboot (self-tests off) | ~77 ms | < 100 ms to the console's first frame |
| Spawn a program until its `main` runs | ~50 µs | < 200 µs |
| Null syscall | ~33 ns | < 100 ns |
| `channel_call` round trip, one core, deadline donation | ~1.45 µs | < 1 µs, a hardware target: Zircon measures ~2.2 µs on the same VM |
| Port wake from another core (median) | ~1.85 µs | < 2 µs (with croi's idle polling under a hypervisor) |
| Real-time wake error, p99 | ~26 µs | < 100 µs |
| Interrupt to the waiting thread (median) | ~12 µs | < 5 µs on hardware |
| Enabled trace event | ~18 ns | < 30 ns |

The kernel is about 22k lines of Swift and 3.9k lines of assembly (three
architectures), with about 100 lines of C (the compiler runtime and two
globals Swift would initialize lazily), plus the C headers that define
the loader, kernel and user ABIs.

## Progress

**Todhchai's M2 (croi reaches user space) and M3 (native tier 0) are
done** (2026-10-10). M3 ran Todhchai's services, devmgr, its drivers, a
file system on virtio-blk and a framebuffer console on croi, with every
system budget met under KVM, resident memory included (2-2.5 MiB at the
console against 32 MiB).

**K10, the kernel side of Todhchai's M4 (native desktop v0), is done**
(2026-10-11): counters and display timelines a compositor waits on,
wakeups that carry a deadline, overrun ports and CPU reservation, power
control, and an idle machine that takes no wakeups (Todhchai's idle
desktop: 0 in 60 s). Bringing M4 up on croi also found and fixed a
killed thread that ran on until an unrelated interrupt (amd64's SYSCALL
return skipped the kill check) and long timers firing early under KVM.
Next is what Todhchai's M5 (Vulkan over virtio-gpu) needs, then the
deferred list below.

| Milestone | Scope | Status |
|---|---|---|
| K1 | UEFI loader, handoff (bootfs, cmdline, framebuffer, SMBIOS), cache policy | ✅ |
| K2 | Interrupt controllers, IPIs, TLB shootdown, monotonic clock, tickless timers, topology | ✅ |
| K3 | Threads, priority inheritance, scheduling contexts, fair + EDF, admission, extended state | ✅ |
| Trace | Per-CPU rings; `sched`, `irq`, `vm`, `syscall`, `ipc` (flows), `futex` categories; user marks; tick and PMU sampling; per-thread PMU counters | ✅ |
| K4 | User address spaces, VMOs, regions and views, demand paging, accounts, W^X/JIT | ✅ (COW clones and page loaning later) |
| K5 | Objects, handles, rights, signals, waits, ports, resources | ✅ |
| K6 | Syscalls, SMEP/SMAP/PAN/SUM, user copies, vDSO + shared pages, user FP/SIMD | ✅ |
| K7 | Channels, eventpairs, timers, futexes with owners; jobs, processes, threads, exceptions, job policy | ✅ |
| K8 | Debuglog, ELF loading, Swift user programs, bootfs + userboot, the M2 exit test and budgets | ✅ |
| K9 | M3: resources, physical VMOs, firmware data (ZBI items), interrupt objects with affinity, MSI/MSI-X (amd64), BTI without an IOMMU, boot budgets, task and kernel memory stats | ✅ |
| K10 | M4: counters, display timeline, wakeups that carry a deadline, frame intent, overrun ports, CPU reservation, power control, no idle wakeups, CPU stats | ✅ |
| Later | IOMMUs (VT-d first), GICv3 ITS and RISC-V IMSIC, FIFOs/sockets/streams, VMO clones, pager, debugger syscalls | ⬜ after M4 |

See [`docs/roadmap.md`](docs/roadmap.md) for the detailed plan and the
requirement-by-requirement mapping.

## Relationship to Zircon

croi ports Zircon's *semantics*, not its C++ structure. The reference is
`../fuchsia/zircon/` at a pinned revision (see `CLAUDE.md`).

### Kept

What a Zircon user-space program would recognize:

- **Object model:** koids, handles with rights and generations, signals,
  observers, `object_wait_one/many/async`, and Zircon's status codes,
  rights, signal bits and object type numbers.
- **Ports** with the `zx_port_packet_t` layout as the single wait
  primitive.
- **VMOs and VMARs:** anonymous, physical and contiguous VMOs; demand
  paging; commit/decommit; cache operations and cache policy.
- **Scheduler disciplines:** fair (weighted virtual runtime, Zircon's
  priority table) plus deadline (EDF), with Zircon's profile-inheritance
  rules through owned wait queues.
- **vDSO** as the user-space interface, with the clock readable without a
  syscall.
- **Resources** gating privileged operations; the root resource mints the
  rest.
- **IPC and tasks:** channels (with `channel_call` transaction ids),
  events, eventpairs, futexes with owners, timers with slack, jobs,
  processes, threads, exception channels and job policy.
- **Startup:** Zircon's bootfs format, userboot, and the processargs
  bootstrap message; debuglog with Zircon's record layout.
- **Profiles:** `profile_create` / `object_set_profile` with
  `zx_profile_info_t`.
- **Internal designs followed closely:** PmmNode-style physical memory,
  a physmap-backed heap, `acpi_lite`-style table parsing, `mp_sync_exec`
  cross-calls, and RefPtr-style intrusive reference counts.

### Replaced

| Zircon | croi |
|---|---|
| C++ (and some Rust) | Embedded Swift 6.4, ownership only (`~Copyable`, `Ref<T>`, `UniqueArray`) |
| physboot, ZBI, boot shims | A UEFI loader with its own handoff ABI (`lib/handoff`) |
| Devicetree and platform IDs | ACPI only (MADT, SPCR/DBG2, GTDT, PPTT, RHCT, IORT, DMAR…) |
| cmpctmalloc | Slab heap: 13 size classes, bookkeeping in the page records |
| Thread-bound scheduler state | Scheduling contexts separate from threads (seL4 MCS style) |
| ktrace format | Per-CPU 32-byte record rings, lock-free, exported as read-only VMOs, with flow ids shared by a call and its reply |
| Rust userboot | userboot in Embedded Swift |
| GN / Bazel | CMake + Ninja, one tree per architecture |

### Modified or extended

These are additions Todhchai needs. Each was checked against Zircon first.

- **Real-time:** admission control that refuses with a reason against a
  per-user budget; capacity-aware EDF on heterogeneous cores; budget
  overrun packets to a port; IPC deadline donation through
  `channel_call`; reserved CPUs.
- **Memory:** memory accounts with pressure packets; device-local and
  pinned VMOs that are never evicted; atomic view replacement inside a
  reservation; contiguous VMOs with a physical address limit and a boot
  pool.
- **W^X everywhere:** JIT reservations get per-thread write toggling with
  amd64 protection keys, or dual RW/RX views where the hardware has none.
- **Shared read-only pages:** topology, power hints and (later) vblank
  timing, seqlocked and mapped next to the vDSO.
- **Interrupts:** every IRQ, and each MSI-X vector, has an explicit CPU
  affinity (`interrupt_set_affinity`). GICv3 ITS and RISC-V AIA MSIs are
  planned (Zircon's ITS is unimplemented).
- **DMA:** BTIs carry a DMA address width, a window of device addresses
  and a memory type, which can only be narrowed; a BTI with no IOMMU is a
  recorded trust decision. IOMMUs are a core feature to come: VT-d,
  AMD-Vi, SMMUv3 and the RISC-V IOMMU.
- **Firmware data for user space:** ACPI tables, SMBIOS and the GOP
  framebuffer reach drivers as ZBI-format boot data and physical VMOs
  under resources, with no ZBI boot protocol.
- **Hardening and board bring-up:** SMEP/SMAP, PAN and SUM on every CPU;
  the SBSA watchdog; an arm64 SError policy; DBG2 consoles; SMC resources
  scoped by function-ID range.

### Left out

- **The hypervisor** (guests, VCPUs).
- **Non-UEFI boot:** no devicetree, no ZBI, no legacy BIOS or vendor
  bootloader protocols.
- **Architectures** other than amd64, arm64 and rv64.
- **Fuchsia above the kernel:** components, FIDL, Driver Framework and
  the rest. Todhchai supplies the user space.

## Building

The toolchain is pinned in `.swift-version` and found through
[swiftly](https://github.com/swiftlang/swiftly). QEMU runs with edk2
firmware from `/usr/share/edk2`.

```sh
cmake --workflow --preset amd64     # configure, build, QEMU smoke test
cmake --build --preset arm64        # build only
ninja -C build/rv64 run             # boot interactively (Ctrl-A x quits)
```

Each test boot runs the kernel's self-tests (PMM, heap, SMP, IPIs and
shootdowns, timers, the scheduler, the VM, objects, user mode, IPC,
processes and exceptions, resources, interrupts, MSI, DMA, counters,
timelines, power control refusals, and a framebuffer screendump check),
then userboot starts `bin/m2`, the M2 exit test, which ends by counting
an idle machine's wakeups; then userboot powers the machine off
(`userboot.shutdown=poweroff`) and QEMU must exit by itself.
`croi.selftest=off` on the kernel command line skips the self-tests, as
Todhchai's boots do (`boot-lean` tests that path; on arm64 and rv64
`boot-lean-icount` runs it with guest time from instruction counts).

Timings are judged separately from correctness, after Todhchai's
discipline: every budget is printed as a `budget name=... value=...`
line, and

```sh
tools/bench.py                       # KVM boots: medians against this machine's history
tools/bench.py --compare <commit>    # this tree against a commit, boots interleaved
tools/zircon-bench/compare.py        # the same budgets measured on Zircon, interleaved
```

A missed budget is checked against Zircon first: if Zircon meets it the
target is attainable, if neither does it is a design decision
(`docs/roadmap.md`, "Budgets against Zircon").

## Layout

| Path | Contents |
|---|---|
| `boot/` | UEFI loader (ELF static PIE converted to PE32+ by `tools/elf2efi.py`) |
| `kernel/Kernel/` | The kernel in Swift: `Vm/`, `Sched/`, `Object/`, `User/`, `Irq/`, `Time/`, `Acpi/`, `Trace/` |
| `kernel/arch/` | Per-arch assembly: entry, exceptions, context switch, SMP trampolines, user copies |
| `lib/` | Shared by loader and kernel: handoff ABI, page tables, text formatting, C runtime |
| `user/` | User-space headers (`croi/syscall.h`), the C user runtime, the vDSO, userboot, `m2` and test programs |
| `tools/` | `mkbootfs.py`, `elf2efi.py`, the QEMU runner, `bench.py`, and `zircon-bench/` (croi's budgets on Zircon) |
| `bench/history/` | Recorded budget runs per machine (`tools/bench.py --record`) |
| `docs/` | Roadmap |

`CLAUDE.md` is the detailed design notebook for each subsystem.

## License

BSD 3-Clause; see [`LICENSE`](LICENSE).
