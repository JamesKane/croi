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
consumer, the Todhchai OS, runs its services on croi natively. Performance
targets come from Todhchai and are measured with croi's own trace, under
KVM on amd64:

| Measurement | Today | Budget |
|---|---|---|
| Null syscall | ~35 ns | < 100 ns |
| `channel_call` round trip, one core, deadline donation | ~1.4 µs | < 1 µs (not met yet; enforced at 1.6 µs) |
| Port wake from another core (median) | ~1.75 µs | < 2 µs |
| Real-time wake error, p99 | 27–46 µs | < 100 µs |
| `clock_get_monotonic` via the vDSO | ~12 ns | — |
| Enabled trace event | ~18 ns | < 30 ns |

The kernel is about 19k lines of Swift and 4.1k lines of assembly (three
architectures), with about 100 lines of C (the compiler runtime and two
globals Swift would initialize lazily), plus the C headers that define
the loader, kernel and user ABIs.

## Progress

**M2, croi reaches user space, is done** (2026-10-10). userboot starts a
Swift process from bootfs. The process creates a channel pair, passes a
VMO across it, waits on a port with a deadline timer, and prints over
debuglog, on all three architectures; the budgets above are checked on
every KVM boot.

The next target is **M3, Todhchai's native tier 0**: devmgr, ACPI, PCI,
virtio-blk and a framebuffer console on croi. Todhchai's services already
boot from bootfs on croi under KVM; what they still need from the kernel
is driver support (milestone K9 below).

| Milestone | Scope | Status |
|---|---|---|
| K1 | UEFI loader, handoff v3 (bootfs, cmdline, framebuffer), cache policy | ✅ |
| K2 | Interrupt controllers, IPIs, TLB shootdown, monotonic clock, tickless timers, topology | ✅ |
| K3 | Threads, priority inheritance, scheduling contexts, fair + EDF, admission, extended state | ✅ |
| Trace | Per-CPU rings; `sched`, `irq`, `vm`, `syscall`, `ipc` (flows), `futex` categories; user marks; tick and PMU sampling; per-thread PMU counters | ✅ |
| K4 | User address spaces, VMOs, regions and views, demand paging, accounts, W^X/JIT | ✅ (COW clones and page loaning later) |
| K5 | Objects, handles, rights, signals, waits, ports, resources | ✅ |
| K6 | Syscalls, SMEP/SMAP/PAN/SUM, user copies, vDSO + shared pages, user FP/SIMD | ✅ |
| K7 | Channels, eventpairs, timers, futexes with owners; jobs, processes, threads, exceptions, job policy | ✅ |
| K8 | Debuglog, ELF loading, Swift user programs, bootfs + userboot, the M2 exit test and budgets | ✅ |
| K9 | M3: resources, VMO syscalls, firmware data, interrupt objects, MSI, BTI without an IOMMU | ⬜ next |
| Later | IOMMUs (VT-d first), FIFOs/counters/sockets/streams/clocks, pager, debugger syscalls | ⬜ after M3 |

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
- **Interrupts:** every IRQ has an explicit CPU affinity. GICv3 ITS and
  RISC-V AIA MSIs are planned (Zircon's ITS is unimplemented).
- **IOMMUs as a core feature:** VT-d, AMD-Vi, SMMUv3 and the RISC-V IOMMU,
  with BTIs that carry an IOVA window, a DMA width and a memory type.
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

Each boot runs the kernel's self-tests (PMM, heap, SMP, IPIs and
shootdowns, timers, the scheduler, the VM, objects, user mode, IPC,
processes and exceptions, and a framebuffer screendump check), then
userboot starts `bin/m2`, the M2 exit test. On amd64 with `/dev/kvm`,
`boot-smoke-kvm` also enforces the budgets.

## Layout

| Path | Contents |
|---|---|
| `boot/` | UEFI loader (ELF static PIE converted to PE32+ by `tools/elf2efi.py`) |
| `kernel/Kernel/` | The kernel in Swift: `Vm/`, `Sched/`, `Object/`, `User/`, `Irq/`, `Time/`, `Acpi/`, `Trace/` |
| `kernel/arch/` | Per-arch assembly: entry, exceptions, context switch, SMP trampolines, user copies |
| `lib/` | Shared by loader and kernel: handoff ABI, page tables, text formatting, C runtime |
| `user/` | User-space headers (`croi/syscall.h`), the C user runtime, the vDSO, userboot, `m2` and test programs |
| `tools/` | `mkbootfs.py`, `elf2efi.py`, the QEMU runner and its helpers |
| `docs/` | Roadmap |

`CLAUDE.md` is the detailed design notebook for each subsystem.

## License

BSD 3-Clause; see [`LICENSE`](LICENSE).
