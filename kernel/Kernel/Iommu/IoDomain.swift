import CKernel
import PageTables

/// What the IOMMU drivers share (K12): a claimed device's translation
/// domain, its I/O virtual address allocator and its page tables, whose
/// formats differ only in their bits (VT-d second-level tables, AMD-Vi
/// host page tables, SMMU stage-1 VMSA tables, RISC-V Sv39/Sv48 first-
/// stage tables; all 512 entries of 64 bits and 4 KiB pages; addresses in
/// bits 51:12, RISC-V's as a PPN in bits 53:10). The unit-specific parts
/// (making a table write visible, invalidating the IOTLB) dispatch on
/// `kind`; each arch compiles its own drivers.
enum IommuKind: UInt8 {
    case vtd
    case amd
    case smmu
    case smmuV2  // its tables are SMMUv3's (VMSA stage 1)
    case riscv   // Sv39/Sv48
}

struct IoDomain: ~Copyable {
    let kind: IommuKind
    /// The unit's record (VtdUnit or AmdviUnit).
    let unit: UInt64
    let domainId: UInt16
    /// The device: bus << 8 | device << 3 | function.
    let deviceId: UInt16
    let root: UInt64  // physical
    let levels: Int
    /// Bits of I/O address translated (at most 12 + 9 x levels; SMMUv2
    /// units may take fewer, such as the Q8B's 36).
    let inputBits: UInt64
    /// Driver data (SMMUv3: the context descriptor's page; SMMUv2: the
    /// bank and stream match entries).
    var extra: UInt64 = 0
    let lock = SpinLock()
    /// Allocated IOVA ranges, sorted by base.
    var used = UniqueArray<IovaRange>()
    /// Table pages (freed with the domain).
    var tables = UniqueArray<UInt64>()
}

struct IovaRange {
    var base: UInt64
    var size: UInt64
}

@safe struct IoDomainPointer {
    let address: UInt64

    var pointee: IoDomain {
        unsafeAddress { unsafe UnsafePointer<IoDomain>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<IoDomain>(bitPattern: UInt(address))! }
    }
}

enum IoDomains {
    /// RISC-V: every IOMMU so far has Svpbmt (uncached BTIs map NC).
    nonisolated(unsafe) static var riscvPageBasedMemoryTypes = false

    /// A domain record with an empty root table, or nil.
    static func make(_ kind: IommuKind, unit: UInt64, id: UInt16, deviceId: UInt16, levels: Int,
                     inputBits: UInt64? = nil) -> IoDomainPointer? {
        guard let root = zeroedPage() else { return nil }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<IoDomain>.size, alignment: 64) else {
            pmm.free(root)
            return nil
        }
        unsafe raw.bindMemory(to: IoDomain.self, capacity: 1).initialize(to: IoDomain(
            kind: kind, unit: unit, domainId: id, deviceId: deviceId, root: root, levels: levels,
            inputBits: inputBits ?? UInt64(12 + 9 * levels)))
        let domain = IoDomainPointer(address: UInt64(UInt(bitPattern: raw)))
        domain.pointee.tables.append(root)
        wrote(domain, root, KernelLayout.pageSize)
        return domain
    }

    /// Frees the tables and the record (no device points at them; the
    /// driver frees the id).
    static func free(_ domain: IoDomainPointer) {
        for i in 0..<domain.pointee.tables.count { pmm.free(domain.pointee.tables[i]) }
        let raw = unsafe UnsafeMutablePointer<IoDomain>(bitPattern: UInt(domain.address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }

    /// A zeroed page for tables (PMM, state mmu), or nil.
    static func zeroedPage() -> UInt64? {
        guard let phys = pmm.allocatePage(.mmu) else { return nil }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
        return phys
    }

    // MARK: IOVAs

    /// `size` bytes of I/O virtual addresses inside [low, high), first fit
    /// from 1 MiB (address 0 stays unmapped), or at `fixed`.
    static func reserve(_ domain: IoDomainPointer, at fixed: UInt64? = nil, size: UInt64,
                        low: UInt64 = 0, high: UInt64 = .max) throws(Status) -> UInt64 {
        let limit = min(high, 1 << domain.pointee.inputBits)
        return try domain.pointee.lock.withLock { () throws(Status) -> UInt64 in
            var candidate = fixed ?? max(low, 0x10_0000)
            var index = 0
            while index < domain.pointee.used.count {
                let r = domain.pointee.used[index]
                if r.base + r.size <= candidate { index += 1; continue }
                if candidate + size <= r.base { break }
                guard fixed == nil else { throw .alreadyBound }
                candidate = r.base + r.size
                index += 1
            }
            guard candidate + size <= limit, candidate + size > candidate else { throw .noMemory }
            domain.pointee.used.insert(IovaRange(base: candidate, size: size), at: index)
            return candidate
        }
    }

    static func release(_ domain: IoDomainPointer, iova: UInt64) {
        domain.pointee.lock.withLock {
            for i in 0..<domain.pointee.used.count where domain.pointee.used[i].base == iova {
                _ = domain.pointee.used.remove(at: i)
                return
            }
        }
    }

    /// Firmware's ranges the device may still be using (VT-d RMRRs, AMD-Vi
    /// unity maps): reserved and mapped at their own addresses.
    static func identityMap(_ domain: IoDomainPointer, _ base: UInt64, _ size: UInt64) throws(Status) {
        _ = try reserve(domain, at: base, size: size)
        var offset: UInt64 = 0
        while offset < size {
            try map(domain, iova: base + offset, phys: base + offset, write: true)
            offset += KernelLayout.pageSize
        }
    }

    // MARK: Page tables

    private static var addressMask: UInt64 { 0x000F_FFFF_FFFF_F000 }

    /// SMMU stage-1 tables (v3 and v2 alike).
    private static func vmsa(_ kind: IommuKind) -> Bool { kind == .smmu || kind == .smmuV2 }

    private static func present(_ kind: IommuKind, _ entry: UInt64) -> Bool {
        kind == .vtd ? entry & 3 != 0 : entry & 1 != 0
    }

    /// The next table's physical address in a directory entry.
    private static func next(_ kind: IommuKind, _ entry: UInt64) -> UInt64 {
        kind == .riscv ? ((entry >> 10) & ((1 << 44) - 1)) << 12 : entry & addressMask
    }

    /// RISC-V leaves: V, R, U (the IOMMU's requests are unprivileged), A;
    /// W and D to write (A and D preset: no hardware updates needed).
    private static var riscvPage: UInt64 { 1 | 1 << 1 | 1 << 4 | 1 << 6 }

    /// SMMU stage-1 leaf attributes: AF, not global (ASID-tagged), inner
    /// shareable, AP[1] set (the SMMU's transactions are unprivileged),
    /// AP[2] for read only; MAIR index 0 (normal write-back) or, uncached,
    /// 1 (normal non-cacheable), as the drivers program MAIR.
    private static var smmuPage: UInt64 { 3 | 1 << 10 | 1 << 11 | 3 << 8 | 1 << 6 }

    /// A table entry pointing at the next level's table (`level` is the
    /// level of the table holding it); permissions are the leaves'.
    private static func directory(_ kind: IommuKind, _ next: UInt64, level: Int) -> UInt64 {
        switch kind {
        case .vtd: return next | 3                                            // read, write
        case .amd: return next | 1 | UInt64(level - 1) << 9 | 1 << 61 | 1 << 62  // PR, next level, IR, IW
        case .smmu, .smmuV2: return next | 3                                       // a table
        case .riscv: return (next >> 12) << 10 | 1                                   // V only: a pointer
        }
    }

    private static func leaf(_ kind: IommuKind, _ phys: UInt64, write: Bool, cached: Bool) -> UInt64 {
        switch kind {
        case .vtd: return phys | 1 | (write ? 2 : 0)
        case .amd: return phys | 1 | 1 << 61 | (write ? 1 << 62 : 0)  // next level 0: a page
        case .smmu, .smmuV2: return phys | smmuPage | (write ? 0 : 1 << 7) | (cached ? 0 : 1 << 2)
        case .riscv:
            // Svpbmt NC for an uncached BTI where the IOMMU has it.
            let pbmt: UInt64 = !cached && IoDomains.riscvPageBasedMemoryTypes ? 1 << 61 : 0
            return (phys >> 12) << 10 | riscvPage | (write ? 1 << 2 | 1 << 7 : 0) | pbmt
        }
    }

    /// Maps one page (read, and write if asked). `cached` false gives the
    /// device's accesses normal non-cacheable attributes where the format
    /// carries them (SMMU: a non-coherent device's BTI).
    static func map(_ domain: IoDomainPointer, iova: UInt64, phys: UInt64, write: Bool,
                    cached: Bool = true) throws(Status) {
        let kind = domain.pointee.kind
        try domain.pointee.lock.withLock { () throws(Status) in
            var table = domain.pointee.root
            for level in stride(from: domain.pointee.levels, to: 1, by: -1) {
                let index = Int((iova >> UInt64(12 + 9 * (level - 1))) & 0x1FF)
                let slot = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))! + index
                if unsafe !present(kind, slot.pointee) {
                    guard let next = zeroedPage() else { throw .noMemory }
                    domain.pointee.tables.append(next)
                    wrote(domain, next, KernelLayout.pageSize)
                    unsafe slot.pointee = directory(kind, next, level: level)
                    wrote(domain, table + UInt64(index) * 8, 8)
                }
                table = unsafe next(kind, slot.pointee)
            }
            let index = Int((iova >> 12) & 0x1FF)
            let slot = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))! + index
            unsafe slot.pointee = leaf(kind, phys, write: write, cached: cached)
            wrote(domain, table + UInt64(index) * 8, 8)
        }
        #if arch(x86_64)
        if kind == .vtd, VtdUnitPointer(address: domain.pointee.unit).pointee.cachingMode {
            invalidate(domain)  // caching mode caches not-present entries too
        }
        #endif
    }

    /// Unmaps [iova, iova+size) and invalidates the domain's IOTLB: when it
    /// returns, the device can't reach those pages.
    static func unmap(_ domain: IoDomainPointer, iova: UInt64, size: UInt64) {
        let kind = domain.pointee.kind
        domain.pointee.lock.withLock {
            var at = iova
            while at < iova + size {
                var table = domain.pointee.root
                var found = true
                for level in stride(from: domain.pointee.levels, to: 1, by: -1) {
                    let index = Int((at >> UInt64(12 + 9 * (level - 1))) & 0x1FF)
                    let entry = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))![index]
                    guard present(kind, entry) else { found = false; break }
                    table = next(kind, entry)
                }
                if found {
                    let index = Int((at >> 12) & 0x1FF)
                    unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))![index] = 0
                    wrote(domain, table + UInt64(index) * 8, 8)
                }
                at += KernelLayout.pageSize
            }
        }
        invalidate(domain)
    }

    // MARK: Unit-specific

    /// The CPU wrote [phys, phys+size) of a table.
    private static func wrote(_ domain: IoDomainPointer, _ phys: UInt64, _ size: UInt64) {
        #if arch(x86_64)
        if domain.pointee.kind == .vtd { VtdUnitPointer(address: domain.pointee.unit).flushTables(phys, size) }
        // AMD-Vi page walks snoop the CPU's caches.
        #elseif arch(arm64)
        if domain.pointee.kind == .smmuV2 {
            SmmuV2UnitPointer(address: domain.pointee.unit).flushTables(phys, size)
        } else {
            SmmuUnitPointer(address: domain.pointee.unit).flushTables(phys, size)
        }
        #endif
        // RISC-V IOMMUs' walks are coherent (no capability says otherwise).
    }

    /// The domain's cached translations go.
    static func invalidate(_ domain: IoDomainPointer) {
        #if arch(x86_64)
        switch domain.pointee.kind {
        case .vtd:
            let unit = VtdUnitPointer(address: domain.pointee.unit)
            unit.pointee.lock.withLock { try? unit.invalidateIotlbLocked(domain: domain.pointee.domainId) }
        case .amd:
            AmdviUnitPointer(address: domain.pointee.unit).invalidatePages(domain: domain.pointee.domainId)
        case .smmu, .smmuV2, .riscv:
            break
        }
        #elseif arch(arm64)
        if domain.pointee.kind == .smmuV2 {
            SmmuV2UnitPointer(address: domain.pointee.unit).invalidateBank(Int(domain.pointee.domainId))
        } else {
            SmmuUnitPointer(address: domain.pointee.unit).invalidateAsid(domain.pointee.domainId)
        }
        #elseif arch(riscv64)
        RiscvIommuUnitPointer(address: domain.pointee.unit).invalidateDomain(domain.pointee.domainId)
        #endif
    }
}

/// What Dma.swift calls: claiming and releasing devices, whatever the unit.
enum Iommus {
    /// `id` is bti_create's: a PCI requester id (bus << 8 | device << 3 |
    /// function; an SMMUv3 maps it to a stream id through the IORT), or on
    /// an SMMUv2 stream match pairs (SmmuV2.attach).
    static func attach(_ kind: IommuKind, unit: UInt64, id: UInt64) throws(Status) -> IoDomainPointer {
        #if arch(x86_64)
        guard id <= 0xFFFF else { throw .outOfRange }
        switch kind {
        case .vtd: return try Vtd.attach(VtdUnitPointer(address: unit), bdf: UInt16(id))
        case .amd: return try Amdvi.attach(AmdviUnitPointer(address: unit), deviceId: UInt16(id))
        case .smmu, .smmuV2, .riscv: throw .notSupported
        }
        #elseif arch(arm64)
        if kind == .smmuV2 { return try SmmuV2.attach(SmmuV2UnitPointer(address: unit), streams: id) }
        guard id <= 0xFFFF else { throw .outOfRange }
        return try SmmuV3.attach(SmmuUnitPointer(address: unit), requesterId: UInt16(id))
        #elseif arch(riscv64)
        guard id <= 0xFFFF else { throw .outOfRange }
        return try RiscvIommus.attach(RiscvIommuUnitPointer(address: unit), requesterId: UInt16(id))
        #else
        throw .notSupported
        #endif
    }

    /// Blocks the device and frees its domain.
    static func detach(_ domain: IoDomainPointer) {
        #if arch(x86_64)
        switch domain.pointee.kind {
        case .vtd: Vtd.detach(domain)
        case .amd: Amdvi.detach(domain)
        case .smmu, .smmuV2, .riscv: break
        }
        #elseif arch(arm64)
        if domain.pointee.kind == .smmuV2 { SmmuV2.detach(domain) } else { SmmuV3.detach(domain) }
        #elseif arch(riscv64)
        RiscvIommus.detach(domain)
        #endif
    }

    static func unbind(_ kind: IommuKind, unit: UInt64) {
        #if arch(x86_64)
        switch kind {
        case .vtd: Vtd.unbind(unit)
        case .amd: Amdvi.unbind(unit)
        case .smmu, .smmuV2, .riscv: break
        }
        #elseif arch(arm64)
        if kind == .smmuV2 { SmmuV2.unbind(unit) } else { SmmuV3.unbind(unit) }
        #elseif arch(riscv64)
        RiscvIommus.unbind(unit)
        #endif
    }

    /// Faults every unit has recorded (self-test).
    static func faultsCounted() -> UInt64 {
        #if arch(x86_64)
        return Vtd.faultsCounted() + Amdvi.faultsCounted()
        #elseif arch(arm64)
        return SmmuV3.faultsCounted() + SmmuV2.faultsCounted()
        #elseif arch(riscv64)
        return RiscvIommus.faultsCounted()
        #else
        return 0
        #endif
    }

    /// The first unit the firmware describes, for the self-test's user
    /// side (a driver reads the ACPI tables itself): its type and registers.
    static func firstUnit() -> (type: UInt32, base: UInt64)? {
        #if arch(x86_64)
        if Dmar.count > 0 { return (UInt32(CROI_IOMMU_TYPE_INTEL), Dmar.units[0].registerBase) }
        if Ivrs.count > 0 { return (UInt32(CROI_IOMMU_TYPE_AMD), Ivrs.units[0].registerBase) }
        #elseif arch(arm64)
        if Iort.smmuCount > 0 { return (UInt32(CROI_IOMMU_TYPE_ARM_SMMU), Iort.smmus[0].registerBase) }
        #elseif arch(riscv64)
        if Rimt.count > 0, let base = Rimt.registerBase(0) { return (UInt32(CROI_IOMMU_TYPE_RISCV), base) }
        #endif
        return nil
    }

    /// The name the self-test prints.
    static var firstUnitName: StaticString {
        #if arch(x86_64)
        return Dmar.count > 0 ? "VT-d" : "AMD-Vi"
        #elseif arch(arm64)
        return "SMMUv3"
        #else
        return "RISC-V IOMMU"
        #endif
    }
}
