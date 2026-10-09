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

It boots on **amd64, arm64 and rv64** from UEFI with ACPI, runs SMP on all
three, and already runs preemptible user-mode code with a vDSO. Performance
targets come from its first consumer, the
Todhchai OS, and are measured with croi's own trace
(amd64 under KVM):

| Measurement | Today | Budget |
|---|---|---|
| Null syscall | ~40 ns | < 100 ns |
| `clock_get_monotonic` via vDSO | ~13 ns | — |
| Enabled trace event | ~19 ns | < 30 ns |

About 15k lines of Swift, 3.9k lines of assembly (three architectures),
and about 100 lines of kernel-side C, plus the C headers that define the
loader, kernel and user ABIs.

## Progress

The next major target is **M2: croi reaches user space**. userboot starts
a Swift process from bootfs. The process creates a channel pair, passes a
VMO across it, waits on a port with a deadline timer, and prints over
debuglog. All of this has to work on all three architectures, within
Todhchai's latency budgets.

**M2 requirements: 9 of 13 done, 1 partial**

```
[████████████████████████████████████░░░░░░░░░]  ~75%
```

| Milestone | Scope | Status |
|---|---|---|
| K1 | UEFI loader, handoff v3 (bootfs, cmdline, framebuffer), cache policy | ✅ |
| K2 | Interrupt controllers, IPIs, TLB shootdown, monotonic clock, tickless timers, topology | ✅ |
| K3 | Threads, priority inheritance, scheduling contexts, fair + EDF, admission, extended state | ✅ |
| Trace | Per-CPU rings; `sched`, `irq`, `vm` and `syscall` categories; user marks | 🟡 sampling and PMU next (K6e) |
| K4 | User address spaces, VMOs, regions and views, demand paging, accounts, W^X/JIT | ✅ (COW clones and page loaning later) |
| K5 | Objects, handles, rights, signals, waits, ports, resources | ✅ |
| K6 | Syscalls, SMEP/SMAP/PAN/SUM, user copies, vDSO + shared pages, user FP/SIMD | 🟡 K6a–d done, K6e in progress |
| K7 | Channels, eventpairs, timers, futex; jobs, processes, threads, exceptions | ⬜ |
| K8 | userboot + bootfs: the M2 exit test | ⬜ |
| K9+ | Interrupt objects, BTI/PMT + IOMMUs, sockets/FIFOs/streams, debuglog, pager | ⬜ after M2 |

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
- **Planned with the same semantics:** channels, events, eventpairs,
  futexes with owners, timers, jobs, processes, threads, exception
  channels, job policy, userboot and bootfs.
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
| ktrace format | Per-CPU 32-byte record rings, lock-free, exported as read-only VMOs |
| GN / Bazel | CMake + Ninja, one tree per architecture |

### Modified or extended

These are additions Todhchai needs. Each was checked against Zircon first.

- **Real-time:** admission control that refuses with a reason against a
  per-user budget; capacity-aware EDF on heterogeneous cores; budget
  overrun packets to a port; IPC deadline donation (K7); reserved CPUs.
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

Each boot runs the kernel's self-tests: PMM, heap, SMP, IPIs and
shootdowns, timers, the scheduler, the VM, objects, user mode and a
framebuffer screendump check.

## Layout

| Path | Contents |
|---|---|
| `boot/` | UEFI loader (ELF static PIE converted to PE32+ by `tools/elf2efi.py`) |
| `kernel/Kernel/` | The kernel in Swift: `Vm/`, `Sched/`, `Object/`, `User/`, `Irq/`, `Time/`, `Acpi/`, `Trace/` |
| `kernel/arch/` | Per-arch assembly: entry, exceptions, context switch, SMP trampolines, user copies |
| `lib/` | Shared by loader and kernel: handoff ABI, page tables, text formatting, C runtime |
| `user/` | User-space headers (`croi/syscall.h`), the vDSO and test programs |
| `docs/` | Roadmap |

`CLAUDE.md` is the detailed design notebook for each subsystem.

## License

BSD 3-Clause; see [`LICENSE`](LICENSE).
