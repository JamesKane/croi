# IOMMUs

VT-d, AMD-Vi, SMMUv3, SMMUv1/v2 and the RISC-V IOMMU, plus interrupt remapping. Part of croi's design notes (index in CLAUDE.md).

## Shared parts (K12)

IOMMUs, K12 (Kernel/Iommu/, include/dma.h; every arch). `IoDomain.swift`
is shared: a claimed device's `IoDomain` (unit, kind, domain id, device id,
root, levels, `extra`), its IOVA allocator and page-table walks (VT-d,
AMD-Vi and SMMUv3 stage-1 entries differ only in bits; table writes and
IOTLB invalidation dispatch on `IommuKind`), and `Iommus` (attach/detach/
unbind for Dma.swift, `firstUnit` for the boot test). `Mcfg`
(Acpi/Mcfg.swift, every arch) has the ECAM windows. Kernel-owned
interrupts: `DeviceIrqs.setKernelMsiHandler` (amd64 MSIs) and
`setKernelHandler` (wired numbers, which drivers then can't bind), both
dispatched without `tableLock`. Boot test mode 18's startup block carries
the first unit's registers and type and segment 0's ECAM (words 5-7).

## Intel VT-d (K12a)

Intel VT-d, K12a (Kernel/Iommu/IntelIommu.swift):
- `Dmar` reads ACPI's DMAR at boot (its DRHDs); iommu_create(INTEL,
  zx_iommu_desc_intel_t) needs a register base it lists (NOT_FOUND) and
  binds one object per unit (ALREADY_BOUND; a unit whose object went can
  be bound again). `VtdUnit` (heap, never freed): a root table whose
  buses all point at one shared context table of pass-through entries
  (ECAP.PT required), translation enabled at creation, register-based
  invalidation (global context cache, domain-selective IOTLB), a fault
  event MSI to the boot CPU (`DeviceIrqs.setKernelMsiHandler`: kernel
  MSIs dispatched without `tableLock`) that logs and counts faults.
- bti_create(iommu, 0, bdf): `Vtd.attach` claims an endpoint in the
  unit's scope (whole segment less the listed ones, or the listed ones;
  one hop only) with a `VtdDomain` (ids from a bitmap; the bus gets a
  private copy of the context table); RMRRs naming it are identity
  mapped. Pins reserve IOVAs (first fit from 1 MiB, inside the BTI's
  window and address bits, which start at the domain's input width),
  map page by page with the pin's write permission, and the PMT keeps
  the base; `Dma.release` unmaps (IOTLB invalidated) before unpinning.
  A dying BTI detaches (not-present context entry: the device is
  blocked) and then releases its quarantine. Behind an IOMMU,
  vmo_create_contiguous(bti) doesn't constrain physical placement.
- Lock order: unitsLock (a Mutex) -> unit -> table, domain -> unit.
- QEMU amd64 runs `-device intel-iommu` (before edu; intremap=on,eim=on
  under TCG, off under KVM: see interrupt remapping below). Boot
  test mode 18 (`ProcessSelfTest.runIommu`; startup word 5 is the first
  DRHD, a driver reads the DMAR itself): edu's DMA engine copies through
  pinned IOVAs, a write to a read-only and to an unpinned IOVA fault
  (QEMU prints its own lines for those), re-claim and re-bind.

## VT-d interrupt remapping and queued invalidation (K12f)

VT-d interrupt remapping and queued invalidation, K12f (Kernel/Iommu/
InterruptRemapping.swift, IntelIommu.swift):
- `Vtd.boot` (right after `Dmar.initialize`) brings up every DMAR unit:
  registers, firmware's enables turned off, the invalidation queue where
  ECAP.QI (256 128-bit descriptors; batches end with a wait descriptor
  writing a sequence number to a polled page; FSTS.IQE logged; the
  register interface only on units without one), the fault event (the
  unit's own MSI isn't remapped: compatibility format, FEUADDR for x2APIC
  ids). Translation starts at the first iommu_create bind
  (`enableTranslation`); `Vtd.create` only binds boot's units.
- Remapping on when the DMAR's INTR_REMAP flag, every unit's IR and QI,
  EIM if the CPUs use x2APIC, and no `croi.intremap=off`: one 8192-entry
  table shared by every unit (IRTA, EIME, SIRTP, global IEC, IRE; CFI
  clear, so compatibility-format interrupts are blocked). Fixed entries:
  GSI g -> g (IOAPIC pins get remappable RTEs, `IoApic.programRemapped`,
  verified against the IOAPIC's source id from the DMAR's IOAPIC scopes
  and the MADT ids `IoApic` now keeps), MSI (cpu, vector) -> 128 + cpu x
  64 + vector - 0xB0 (linear, so multi-message subhandles land right;
  a plain MSI verifies the requester id `Mcfg.requesterId` gives its
  capability's address; MSI-X entries are unverified). A change is
  invalidated (IEC by index) on every unit. With EIME, 32-bit APIC ids
  are destinations: the 255 limits fall away.
- QEMU: TCG boots run `intel-iommu,intremap=on,eim=on` (eim=auto leaves
  EIM off under TCG); KVM boots (the bench) keep intremap=off, since KVM
  needs a split irqchip for it, which would move the IOAPIC into QEMU and
  change every interrupt timing on record. QEMU's VT-d passes
  compatibility-format MSIs through whatever CFI says (and never sets
  GSTS.CFIS), so croi's blocking of them (CFIS clear) is per the
  specification, unverified under QEMU. Mode 11's checks read either
  format; check 297 (an old-style or unmapped MSI from edu is not
  delivered) runs for AMD-Vi and the ITS only, after acknowledging the
  interrupt (an MSI stays masked after interrupt_wait until then: the
  first version of 297 passed whatever happened). Test
  `boot-intremap-off` keeps the compatibility path covered.

## AMD-Vi (K12b)

AMD-Vi, K12b (Kernel/Iommu/AmdIommu.swift; croi's type CROI_IOMMU_TYPE_AMD
= 0x10000 with croi_iommu_desc_amd_t, Zircon has none):
- `Ivrs` (IVHDs: registers, segment, the IOMMU's own device id and
  capability offset) and `Mcfg` (ECAM windows) are read at boot. A unit
  must be an IVHD's (NOT_FOUND), covers its segment except itself; unity
  ranges in the descriptor (IVMD) are identity mapped for the devices
  they name.
- `AmdviUnit`: a 2 MiB device table for every device id (entries invalid:
  untranslated), a one-page command buffer (each batch ends with a
  COMPLETION_WAIT storing a sequence number to a semaphore page the CPU
  polls) and event log, whose interrupt is an MSI the kernel writes into
  the IOMMU function's MSI capability (`mapPhysical(shared:)` of its
  config page, bus mastering on). Claimed: V, TV, mode 4, IR, IW, domain
  id; released: V and TV with mode 0 and no permissions (blocked). Event
  batches log the first four and count the rest.
- K12g: `Amdvi.boot` (after `Ivrs.initialize`) brings up every IVRS unit
  at boot (as VT-d's; `create` binds). Interrupt remapping when every
  unit has IASup, the IVRS's special device entries (type 0x48, variety
  1) describe every MADT IOAPIC (Linux's rule), and XT + GA or no APIC id
  above 255 (the MADT's): one 2048-entry table that every device table
  entry names (word 2: IV, IntTabLen 11, IntCtl remapped; 128-bit
  entries with GAEn + XTEn, else 32-bit), no source verification (an
  MSI-X table doesn't name its device). Indices: IOAPIC pin = its vector
  0x30 + GSI (the redirection entry is unchanged, so EOI broadcasts
  match); MSIs from 0x100, allocated with their vectors in
  `DeviceIrqs.allocateMsi` (`InterruptRemapping.allocateMsiIndices`,
  consecutive and aligned), message 0xFEE00000 with the index as data.
  Every change: INVALIDATE_IOMMU_ALL. The IOMMU's own event MSI is
  compatibility format (not remapped).
- QEMU: `qemu.sh --iommu amd` (`amd-iommu,intremap=on` under TCG, off
  under KVM, `dma-remap=on`; `--iommu amd-xt` adds xtsup=on: test
  `boot-amd-iommu-xt`;
  without dma-remap QEMU 10.2 doesn't translate emulated devices, and
  edu's test DMA wrote physical memory); test `boot-amd-iommu`. QEMU's
  events carry address 0, and a refused 64-byte DMA logs one fault per
  4-byte access.

## Arm SMMUv3 (K12c)

Arm SMMUv3, K12c (Kernel/Iommu/SmmuV3.swift; Zircon's ARM_SMMU type and
descriptor, but Zircon's driver is SMMUv2 from a device tree):
- `Iort` reads SMMUv3 nodes (registers, COHACC, event GSIV), SMMUv1/v2
  bases (NOT_SUPPORTED) and root-complex id mappings into SMMUv3s:
  bti_create's id is a requester id, `Iort.streamId` maps it.
- `SmmuUnit`: a linear stream table sized to the highest stream id the
  IORT routes there (entries bypass, SHCFG incoming), a 256-entry command
  queue (batches end with CMD_SYNC; consumption = done; CMDQ_ERR logged),
  a 128-entry event queue on the wired event interrupt (edge, boot CPU),
  CR1 cacheable walks only when coherent (else tables, CDs and commands
  are cleaned to memory). Claimed: break-before-make to stage-1 (config
  101) through a context descriptor page per domain (ASID = domain id,
  T0SZ 16, 4 KiB, AA64, R and A, AFFD, MAIR 0x44FF); leaves are AF, inner
  shareable, AP[1] set, AP[2] for read only. Released: abort (config 000).
- QEMU arm64 now has `-device edu,addr=0x10` behind its `iommu=smmuv3`;
  mode 18 runs there (F_PERMISSION and F_TRANSLATION events).
- A unit firmware left enabled (CR0.SMMUEN) is refused, BAD_STATE: the
  Q8B's PCIe SMMUv3 is firmware-reserved and policed by its hypervisor.

## Arm SMMUv1/v2 (K12d)

Arm SMMUv1/v2, K12d (Kernel/Iommu/SmmuV2.swift; AbyssBSD's qcom_smmu and
qcom_apps_smmu on the Q8B are the reference, freebsd-src branch
radxa-dragon-q8b, `5cf2c7fd99`; its docs/boards/radxa-dragon-q8b/lessons.md
lists what resets that SoC):
- `Iort.v2Nodes`: base, span, coherent walks, per-bank context
  interrupts (GSIV | edge, heap). iommu_create picks v2 or v3 by node.
- Firmware owns the unit: never a global register, never a reset. Free:
  an entry invalid and faulting; a bank no valid translating entry uses
  whose CBAR is 0 or that this driver set up (`ours`). Claim: bank (CBAR
  only ever 0x1f300, TCR T0SZ from IDR2.UBS, ASID = bank, MAIR 0x44FF,
  SCTLR M|TRE|AFE|CFRE|ASIDPNE and CFIE once its interrupt is the
  kernel's), then each S2CR, then each SMR, with `arch_device_write_
  barrier` (cache.h: dsb st) between. Release: SMR 0, S2CR fault, SCTLR 0,
  TLBIASID + sync. The pairs come from bti_create (dma.h).
- `IoDomain.inputBits` is stored (36 on the Q8B: walks start at level 1,
  3 levels); `IoDomains.map(cached:)` picks MAIR index 1 for a
  non-coherent BTI (SMMUv2 and v3).
- No QEMU model: `SmmuV2SelfTest` (arm64 boot self-test) runs the driver
  on a RAM stand-in set up as the Q8B's apps SMMU (register writes logged
  through `SmmuV2Unit.log`): nothing but the claimed entries and bank
  written, CBAR 0x1f300 only, bank then S2CR then SMR (verified to fail
  with the order swapped), overlaps refused, leaf bits, release, reuse,
  firmware's banks never taken. Unverified on hardware.

## The RISC-V IOMMU (K12e)

The RISC-V IOMMU, K12e (Kernel/Iommu/RiscvIommu.swift; croi's type
CROI_IOMMU_TYPE_RISCV = 0x10001, descriptor { register_base }):
- `Rimt` reads ACPI's RIMT (IOMMU nodes: base, or PCIe-based with segment
  and B/D/F, whose BAR 0 is the base; root-complex id mappings, "number of
  IDs" a count). A PCIe-based IOMMU gets memory space and bus mastering
  before its registers are read (all-ones otherwise).
- `RiscvIommuUnit`: refused if firmware left it translating (ddtp mode >
  Bare: BAD_STATE). A device directory with a pass-through context (V,
  both stages Bare) for every device id the RIMT routes there: 2 levels of
  32-byte contexts, or 3 of 64-byte ones when capabilities.MSI_FLAT makes
  contexts extended; command queue ending batches with IOFENCE.C (AV) to
  a semaphore word; fault queue, drained when faults are counted and
  after each unmap's invalidation (no interrupts: they are IMSIC MSIs or
  wired lines). Claimed: context invalid, IODIR.INVAL_DDT, then iohgatp
  Bare, ta PSCID (= domain id), fsc Sv48/Sv39 + root, valid; released:
  invalid. Leaves V|R|U|A (+W|D), Svpbmt NC for uncached BTIs where every
  unit has Svpbmt (`IoDomains.riscvPageBasedMemoryTypes`).
- QEMU rv64: `-device riscv-iommu-pci,addr=0x8` (QEMU 10.2 puts only the
  PCI IOMMU in the RIMT; `iommu-sys=on` makes the device but no RIMT), at
  slot 8 so the other devices keep their slots (moved, edk2's saved boot
  entries go stale and it drops to its shell) and below edu (the RIMT
  routes the ids above the IOMMU's own). `qemu.sh --iommu base`
  (intremap=off: no MSI_FLAT) covers base contexts; test
  `boot-riscv-iommu-base`.

## A claimed device's MSIs (K12j)

A claimed device's MSIs, K12j (RiscvIommus.mapInterruptFiles; mode 18's
checks 409-410 on every arch: edu's MSI through its BTI's domain):
- VT-d and AMD-Vi don't translate interrupt requests; SMMUv3 domains map
  the ITS doorbell (K12h, first exercised here).
- RISC-V: MSI page tables apply to a context's guest-physical addresses,
  the first stage's output, so every hart's supervisor file is identity
  mapped in the domain; with MSI_FLAT (extended contexts) the context's
  msiptp is Flat over one per-unit table (one write-through entry per
  hart index, built at the first claim; mask = the hart-index bits above
  the files' stride, pattern = the lowest file), confining MSIs to those
  files. Verified in QEMU (invalid entries stop delivery). The identity
  written isn't restricted (that needs MRIF mode or a device's own guest
  files), so rv64 still has no identity-level remapping and check 297
  skips it. `boot-riscv-iommu-base` (no MSI_FLAT, with AIA) covers the
  identity-mapped files alone.
