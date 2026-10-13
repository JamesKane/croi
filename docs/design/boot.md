# Boot and early kernel

Loader, handoff, the kernel's first steps, ACPI discovery and boot budgets. Part of croi's design notes (index in CLAUDE.md).

## Loader

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

## Memory types

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

## Kernel entry and address space

Kernel (`kernel/Kernel/Main.swift`): validates the handoff, builds its own
page tables from free RAM with `BootAllocator` (front-to-back, never frees;
reads the handoff range table in place, which is CROI_MEM_HANDOFF and so
never handed out), and switches to them. Kernel address space
(`KernelLayout`): low half empty; physmap of all RAM at 0xffff800000000000
(amd64/arm64) or 0xffffffc000000000 (rv64 Sv39), RW + NX; device registers
the kernel uses are mapped in the physmap as device memory; the image at
its KASLR base with text RX, rodata R, data RW. amd64 loads its own GDT
first thing, since firmware's sits in memory reported free.

## Entering the kernel (EL2 drop)

Kernel enters on the loader's page tables with the handoff's physical
address as its argument, at EL1 on arm64: if firmware ran at EL2, the
trampoline neutralizes EL2 (HCR_EL2 = RW, plus API and APK since K14p;
timer, PMU and GICv3 sysregs
handed to EL1) and drops to EL1 after ExitBootServices. Not yet supported:
amd64 5-level paging, CPUs where HCR_EL2.E2H is RES1 (VHE-only).

## ACPI

ACPI (`Kernel/Acpi/`, after Zircon's acpi_lite): `AcpiTables` validates
RSDP/XSDT and finds tables by signature; `withPhysicalBytes` reads through
the physmap or a temporary mapping. `Madt.forEachCpu` yields local APIC /
x2APIC (amd64), GICC MPIDR (arm64) and RINTC hart IDs (rv64).

## Topology

Topology (`Kernel/Acpi/Pptt.swift`): `CpuTopology` in each PerCpu:
package, core, thread, last-level cache from the PPTT (by ACPI UID from
the MADT), and a core type each CPU reads itself (x86 hybrid CPUID 0x1A,
Arm MIDR). QEMU only has a PPTT on arm64 and never cache nodes, so a
boot self-test runs the walk on a hand-built table. This is the data for
the topology page (ext 9).

## Bring-up aids

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

## Boot budgets (K9f)

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
