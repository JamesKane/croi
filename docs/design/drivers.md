# Driver support: resources, interrupts, MSI, DMA, SMC

Part of croi's design notes (index in CLAUDE.md). IOMMUs are in iommu.md.

## Driver support (K9a)

Driver support, K9a (Kernel/Object/Resource.swift, User/DriverSyscalls.swift,
User/IoPorts.swift, include/resource.h, include/vmo.h; Todhchai M3):
- Resources are Zircon's: kind (MMIO 0, IRQ 1, IOPORT 2 amd64, SMC 4
  arm64, SYSTEM 5), base, size, flags, name. Size 0 is the kind's ranged
  root; the root resource (kind ROOT 3, PA_RESOURCE) is every kind's.
  userboot also gets each kind's ranged root (PA_MMIO_RESOURCE 0x50 ...
  PA_SYSTEM_RESOURCE 0x54) and passes them on. `resource_create` (130,
  parent | options << 32) follows Zircon's checks in order (WRITE on the
  parent; a child inside its parent; EXCLUSIVE only from a ranged root
  and no children of it; overlaps with an exclusive one NOT_FOUND).
  A ranged root refuses a range whose end (rounded to pages) wraps past
  2^64 (OUT_OF_RANGE, review round 1: the wrapped end passed every
  overlap test, so the MMIO root mapped all of RAM; check 688).
  `Resources.validate` is Zircon's validate_ranged_resource (non-strict:
  an MMIO resource grants the pages it touches); `check(system:)` uses
  it. `RootFilter` is the root filter: RAM (`PhysicalMap`; firmware
  ranges and RESERVED ones such as PCIe ECAM are allowed, as in Zircon),
  device registers the kernel maps (`mapPhysical` with device caching
  records them; the console UART, the amd64 LAPIC/MSI window, the GIC
  ITS), and on amd64 the 8259 and console UART ports.
  ZX_INFO_RESOURCE (18). The tracing base is Zircon's 14.
- VMOs: `vmo_create_physical` (47; MMIO resource; uncached-device by
  default), `vmo_set_cache_policy` (46; MAP right; unmapped only, else
  BAD_STATE; UNCACHED and UNCACHED_DEVICE both map `.device`, so arm64
  gets Device-nGnRE where Zircon uses nGnRnE for UNCACHED),
  `vmo_op_range` (45: COMMIT/PREFETCH round out, DECOMMIT aligned, ZERO
  by bytes, cache CLEAN/CLEAN_INVALIDATE by bytes, CACHE_SYNC syncs the
  I-cache, CACHE_INVALIDATE NOT_SUPPORTED). vmo_read/write refuse device
  VMOs (NOT_SUPPORTED) and uncached ones (BAD_STATE). Zero-size
  anonymous VMOs exist. `Vmo.syncInstructions` (arm64 dc cvau + ic ivau,
  rv64 fence.i plus SBI remote fence.i) runs after ProgramLoader copies
  code; user loaders (userboot, Todhchai's) must do the same through
  `cache_flush` on arm64 hardware (QEMU TCG is coherent).
- The vDSO header is version 2 with `cache_flush` (Zircon's
  zx_cache_flush; runtime `croi_cache_flush`); the topology page
  (version 2) publishes `dcache_line`/`icache_line`. User cache ops are
  opened on every CPU (`arch_user_cache_enable`: arm64 SCTLR_EL1.UCI and
  UCT, rv64 senvcfg.CBCFE with Zicbom).
- amd64 IO ports (131/132): each CPU's TSS carries an 8 KiB I/O bitmap
  (deny all); a process's bitmap lives on its `UserAspaceRecord` with a
  never-reused id, copied in at a switch to a user thread when the
  loaded id differs, and pushed by IPI to every CPU that has it loaded
  or runs the process when it changes (so a release is immediate).
- Boot test mode 10 (`ProcessSelfTest.runDrivers`, startup block word 3
  is the root resource) reads a device register through a physical VMO
  per arch (q35 ECAM at 0xE0000000, the PL031, the goldfish RTC).

## Firmware data for user space (K9b)

Firmware data for user space, K9b (Kernel/User/BootData.swift,
include/zbi.h; Todhchai item 20):
- Boot data: one ZBI container (Zircon's format; croi has no ZBI
  otherwise) of ACPI_RSDP, SMBIOS, FRAMEBUFFER (zbi_swfb_t; GOP BGRX is
  RGB_X888, RGBX is BGR_888_X) and MEM_CONFIG (RAM the kernel owns,
  PERIPHERAL for MMIO and the framebuffer, RESERVED for the rest)
  items. `BootData.build` writes it into boot allocator pages before the
  PMM takes over (the memory map lives in handoff memory); `makeObject`
  adopts them into a VMO. userboot gets it read only (no WRITE) as
  Zircon's PA_VMO_BOOTDATA (0x1A) and passes it on. zbi.h is the whole
  contract (Todhchai writes its own reader).
- Firmware memory is read through physical VMOs under an MMIO resource
  (always cached, see Physical above); RAM stays refused. The kernel
  unmaps the framebuffer after its self-test, so a driver's physical VMO
  over it (WRITE_COMBINING) is its only mapping.
- Boot test mode 10 continues (startup block word 4 is the boot data):
  the container and every item well formed, the RSDP through a narrow
  MMIO resource (uncached and WC refused), the XSDT's checksum, every
  MEM_CONFIG RAM range refused, the SMBIOS anchor, and the kernel's
  framebuffer pattern read back write-combining. QEMU has SMBIOS and a
  framebuffer on all three machines.

## Interrupt objects (K9c)

Interrupt objects, K9c (Kernel/Object/InterruptObject.swift,
Kernel/Irq/DeviceIrqs.swift, include/interrupt.h, syscalls 140-146 in
User/DriverSyscalls.swift; Todhchai item 13):
- Zircon's InterruptDispatcher: states IDLE / TRIGGERED / NEEDACK /
  WAITING / DESTROYED, delivered as a port packet (type 7, payload[0] the
  timestamp; the port needs BIND_TO_INTERRUPT, and its interrupt packets
  are a list of their own read first, owned by the object so firing never
  allocates) or to one thread in interrupt_wait. Level interrupts are
  masked when they fire and unmasked on ack / the next wait. Virtual
  interrupts (interrupt_trigger) carry UNTRIGGERED (signal 4). Rights are
  Zircon's (bind READ + port WRITE, ack WRITE, wait WAIT, trigger SIGNAL).
  Timestamps are monotonic (no suspend, so boot time is the same).
- Numbers: amd64 GSI (IOAPIC pins, vector 0x30 + GSI below 0x80; MADT
  overrides for MODE_DEFAULT and REMAP_IRQ; else ISA edge-high, PCI
  level-low), arm64 INTID (GICv3 SPIs; active high only), rv64 GSI (PLIC
  sources, the RINTC's context per hart; active high only).
  EDGE_BOTH is NOT_SUPPORTED. One object per number (ALREADY_BOUND).
- `interrupt_set_affinity` (146, croi's): routes to the lowest CPU of the
  mask with `interruptsReady` (IOAPIC physical destination, IROUTER, PLIC
  enable bits); INVALID_ARGS when none, NOT_SUPPORTED for virtual ones.
  Until set, the boot CPU. CPUs another job reserved are skipped (K10d).
- `DeviceIrqs`: handler table (heap, by number) under `tableLock`, held
  while a handler runs, so `unregister` means no handler is running; lock
  order table -> object -> controller (and object -> scheduler -> port
  packets). A number with no handler is masked when it fires.
- Differences from Zircon: closing the handle a thread waits through
  cancels its interrupt_wait (as object waits; Zircon cancels on the last
  handle). The object is destroyed with its last reference. Ext 5's
  scheduling-context handoff (K14e) wakes through `signal`.
- Boot test mode 11 (`ProcessSelfTest.runInterrupts`): virtual interrupts
  through every state, then each machine's RTC (amd64 CMOS periodic, GSI
  8, edge; arm64 PL031, INTID 34, level; rv64 goldfish, GSI 11, level)
  by port and by wait, routed to CPU 1 (the kernel checks where it was
  taken). It reports the median wait wake (fire timestamp to the woken
  thread reading the clock): KVM 11-18 us, the interrupt on CPU 1 waking
  a thread elsewhere. QEMU's PLIC pends only on a rising line, so rv64
  skips the "acked while still asserted fires again" check.

## MSI (K9d)

MSI, K9d (Kernel/Object/MsiObject.swift, DeviceIrqs MSI part,
include/interrupt.h; syscalls 147 msi_allocate, 148 msi_create):
- Zircon's model: an allocation object (type 32, rights BASIC) of `count`
  (power of two, up to 32) contiguous vectors aligned to `count` on the
  boot CPU, from the MSI system resource (base 11); ZX_INFO_MSI (28)
  gives target address/data. `msi_create` makes interrupt object `id`:
  MSI-X (option 1) programs the table entry in the VMO (physical,
  uncached) and masks through its vector control; plain MSI checks the
  capability (ID 5) and masks through per-vector mask bits if present;
  the driver programs the capability itself. MSIs behave as level
  interrupts (masked while delivered). Destroying an MSI-X object clears
  and masks its entry.
- amd64: vectors 0xB0..<0xF0 per CPU (`DeviceIrqs.allocateMsi`), handler
  table by (CPU, vector), message 0xFEE00000 | APIC ID << 12 (IDs above
  255 NOT_SUPPORTED), or with interrupt remapping (K12f) the remappable
  format naming the (CPU, vector) entry, written by `DeviceIrqs.prepareMsi`
  at msi_create and retarget and cleared by `releaseMsi`. set_affinity moves an
  MSI-X vector: a vector on the new CPU, the entry rewritten under its
  mask, the old vector dropped; plain MSI is NOT_SUPPORTED (the driver
  owns the capability). arm64: through the GICv3 ITS (K12h, below); rv64:
  through AIA's IMSICs (K12i, below), else NOT_SUPPORTED (the PLIC).
- The kernel's mappings of MSI-X tables and capabilities are `shared`
  (`mapPhysical(shared:)`): they don't enter the root filter's list of
  kernel MMIO, so the driver keeps its resource over them.
- Boot test (mode 11, amd64; croi's QEMU gets `-device edu,addr=0x10`):
  edu's MSI by port and by wait, with the driver programming the
  capability from the info; a virtio device's MSI-X table (MSI-X not
  enabled, so it never fires) read back after create, a move to CPU 1,
  and close. Both are found by scanning bus 0 and skipped when absent,
  and the config registers touched are restored: Todhchai boots this
  kernel on other machine shapes, with its own edu driver (INTx). KVM
  timing note: channel_call in m2 reads 1.4-2.8 us when the host is
  busy; compare builds interleaved, not one after the other.

## The GICv3 ITS: MSIs on arm64 (K12h)

The GICv3 ITS: MSIs on arm64, K12h (Kernel/Irq/Its.swift, DeviceIrqs'
arm64 MSI part, MsiObject):
- `Its.initialize` (from `GicV3.initializeBootCpu`; bounded spins, the
  clock isn't up): device and collection tables (64 KiB pages, a flat
  device table of up to 2^16 DeviceIDs), a 4 KiB command queue, one
  LPI configuration table (14 INTID bits: LPIs 8192-16383). Each CPU
  (`enableThisCpu`, from `GicV3.initializeThisCpu`): PROPBASER, its own
  pending table (64 KiB aligned, PTZ), EnableLPIs, MAPC (ICID = CPU,
  RDbase per GITS_TYPER.PTA) + SYNC.
- EventIDs are global (msi_allocate precedes knowing the device): 2048,
  allocations consecutive and aligned, LPI = 8192 + EventID, each
  device's ITT covering all 2048. The message is GITS_TRANSLATER and the
  EventID. msi_create finds the device (plain MSI: `Mcfg.requesterId` of
  the capability; MSI-X: `Pci.msixOwner`, the function whose MSI-X
  capability names that table address, walking buses from the MCFG
  window through bridges, a bus mapped when first read), its DeviceID
  (`Iort.itsDeviceId`: a root complex's mapping to an ITS group, or via
  an SMMUv3's stream id and that SMMU's mappings), then MAPD (once per
  device), the LPI enabled, MAPTI, INV, SYNC; set_affinity is MOVI (the
  message stays); destroy DISCARDs. LPIs dispatch through `DeviceIrqs`'
  table lock (`dispatchMsi`).
- SMMUv3 domains identity-map the doorbell page, so a claimed device's
  MSIs still reach the ITS (Linux's MSI window).
- Mode 11's msi_test runs on arm64 (edu's MSI, an event not mapped for
  edu refused, virtio MSI-X entries, MOVI to CPU 1).

## RISC-V AIA: the APLIC and IMSICs (K12i)

RISC-V AIA: the APLIC and IMSICs, K12i (Kernel/Irq/Aia.swift; cpu.S
`arch_rv_imsic_*` through siselect/sireg/stopei by CSR number):
- Used where the MADT has an IMSIC, RINTCs with IMSIC files and an
  S-level APLIC, and every hart has Ssaia; else the PLIC, as before.
  `Aia.initialize` (instead of `Plic.initialize`): hart index = a file's
  place among the files; every source inactive and disabled; domaincfg
  IE + DM (MSI delivery; the root domain's MSI addresses are firmware's).
  Each hart: eidelivery 1, eithreshold 0, every eie bit, SEIE.
- Identities are global: a wired source s is identity s (APLIC target:
  hart index, EIID s; sourcecfg level-high or rising-edge); MSIs take
  consecutive, aligned identities from the first multiple of 64 above
  the sources. scause 9 claims through stopei (`claimAll`): wired to
  `DeviceIrqs.dispatch`, MSIs to `dispatchMsi`. Masking: the APLIC's
  clrienum/setienum (a level source also gets setipnum on unmask: in MSI
  mode it pends again only on a new edge, and the write counts only
  while the line is asserted), MSIs at the device. The MSI message is
  the hart's file and the identity; set_affinity rewrites the address.
- The RISC-V IOMMU now comes up at boot (`RiscvIommus.boot`, devices
  passed through): QEMU resets it Off, which blocked edu's MSIs.
- QEMU: `qemu.sh --aia` (`aia=aplic-imsic`); test `boot-aia` runs the
  whole boot test there.

## DMA (K9e)

DMA, K9e (Kernel/Object/Dma.swift, User/DmaSyscalls.swift, include/dma.h;
syscalls 150-156; Todhchai item 14 without an IOMMU):
- Zircon's iommu_create (stub only: one-byte descriptor; INTEL/ARM_SMMU
  NOT_SUPPORTED), bti_create, bti_pin (bti | options << 32, vmo |
  addrs_count << 32: eight arguments in six registers; per page,
  CONTIGUOUS for a contiguous VMO, COMPRESS = pages for the stub; Zircon's
  rights and option checks), pmt_unpin (consumes the handle),
  bti_release_quarantine, vmo_create_contiguous; ZX_INFO_BTI (20).
  Objects: IOMMU 23, BTI 24, PMT 26 (INSPECT only, so its one handle is
  its only one). Device addresses are physical (no translation).
- Pinning (`Vmo.pin`/`unpin`, `VmoRecord.pins`): commits the range and
  records it; decommit refuses pinned pages (VmError.pinned ->
  BAD_STATE), ZERO zeroes them in place, the cache policy can't change.
- Quarantine: closing a PMT's handle while pinned (process death too)
  moves it to its BTI's list (the BTI holds it; it drops its own
  reference to the BTI); bti_release_quarantine unpins them. A BTI that
  dies with quarantined PMTs leaves them pinned for good and says so in
  the debuglog (Zircon's orphan). PMT state changes under the BTI lock.
- croi's BTI properties (`bti_set_properties`, 156; CROI_INFO_BTI_
  PROPERTIES 0x10000): address width, window and memory type. Narrowing
  only (ACCESS_DENIED on a widening), the memory type only while nothing
  is pinned or quarantined. Pins outside are OUT_OF_RANGE;
  vmo_create_contiguous allocates inside (`floor`/`limit` through
  ContiguousPool and the PMM) with the memory type as cache policy
  (non-coherent: uncached). devmgr narrows before granting the BTI.
- Creating a no-IOMMU BTI writes a WARNING debuglog record naming the
  BTI id and the creating process's koid (a recorded trust decision).
- Boot test mode 12 (`ProcessSelfTest.runDma`): all of the above,
  including the debuglog record, with windows chosen so the checks don't
  depend on where pages land. Not covered: quarantine through process
  death, and a BTI dying with PMTs quarantined.

## SMC calls (K13i)

SMC calls, K13i (User/SmcSyscalls.swift, smp.S `arch_smccc_call`, syscall
234; resource.h; Todhchai requirement 13):
- smc_call(resource, croi_smc_parameters_t *, croi_smc_result_t *):
  Zircon's layouts and order (null pointers INVALID_ARGS, the parameters
  read, the resource validated, the call, the result written). arm64:
  w0 the function ID, x1-x6, w7 = secure_os_id << 16 | client_id; result
  x0-x3 and x6. Through the FADT's PSCI conduit (`Power.psci`: SMC, or
  HVC where firmware runs at EL2, as under QEMU; Zircon always uses SMC).
  Elsewhere NOT_SUPPORTED (after the validation).
- SMC resources are function-ID ranges (Zircon's are 6-bit service call
  numbers: an OEN-scoped resource grants every SiP call, the board review's
  reason). The root filter refuses the PSCI calls that change CPU or system
  state (CPU_SUSPEND/OFF/ON, MIGRATE, SYSTEM_OFF/RESET/RESET2/SUSPEND,
  CPU_FREEZE, CPU_DEFAULT_SUSPEND, both conventions): the kernel's, even
  to the root resource (system_powerctl is the way).
- Yielding calls (bit 31 clear) with `croi.smccc_qcom=on` follow
  Qualcomm's resume protocol under one Mutex (Zircon's arm64_smccc_qcom):
  while x0 is INTERRUPTED (1), call again with function ID 1 and the x6
  session id. The Q8B needs it.
- Mode 17's `smc`: PSCI_VERSION through a one-function resource on arm64
  (QEMU's PSCI over HVC), OUT_OF_RANGE outside it, CPU_OFF and SYSTEM_OFF
  refused.
